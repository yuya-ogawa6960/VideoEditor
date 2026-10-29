import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreTransferable
import PhotosUI

// =====================================================================
// 動く画像(GIF / APNG / アニメーション WebP)の読み込みとキャッシュ。
// 写真オーバーレイとして置いた GIF を、コンポジタ(OverlayRenderer)が毎フレーム
// frame(url:at:) で取り出して描く(オーバーレイの長さいっぱい繰り返す)。
// 一度 ImageIO で全コマを読み(長辺 720px まで縮小)、ファイルごとに持っておくので
// フレームごとの読み直しはしない。コマが多すぎる・大きすぎるときは N コマおきに間引く。
// =====================================================================

/// 読み込んだ 1 ファイル分のコマ
final class AnimatedImageSequence {
    let frames: [CIImage]
    /// 各コマの開始時刻(秒、先頭が 0)
    let starts: [Double]
    /// 1 周の長さ(秒)
    let duration: Double
    /// メモリ量(NSCache のコスト)
    let cost: Int

    init(frames: [CIImage], delays: [Double], cost: Int) {
        self.frames = frames
        var starts: [Double] = []
        starts.reserveCapacity(delays.count)
        var total = 0.0
        for delay in delays {
            starts.append(total)
            total += max(0, delay)
        }
        self.starts = starts
        self.duration = total
        self.cost = cost
    }

    var frameCount: Int { frames.count }

    /// 時刻 time(秒)のコマ。1 周を超えたら繰り返す
    func frame(at time: Double) -> CIImage? {
        guard let first = frames.first else { return nil }
        guard frames.count > 1, duration > 0, time.isFinite else { return first }
        var t = time.truncatingRemainder(dividingBy: duration)
        if t < 0 { t += duration }
        // starts は昇順なので、t 以下の最後のコマを二分探索で探す
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= t {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return frames[low]
    }
}

final class AnimatedImageCache {
    static let shared = AnimatedImageCache()

    /// コマの長辺の上限(px)
    static let maxPixelSize = 720
    /// 1 ファイルあたりのコマ数の上限
    static let maxFrames = 300
    /// 1 ファイルあたりのメモリの上限(およそ 60 MB)
    static let maxBytes = 60 * 1024 * 1024
    /// 動く可能性のある拡張子(これ以外は見ない)
    static let animatedExtensions: Set<String> = ["gif", "png", "apng", "webp"]

    private let cache: NSCache<NSString, AnimatedImageSequence>
    private let lock = NSLock()
    /// 同じファイルを複数のスレッドから同時に読まないためのファイルごとのロック
    private var fileLocks: [String: NSLock] = [:]
    /// ファイルパス → 動く画像か(毎回ファイルを開き直さないため)
    private var animatedFlags: [String: Bool] = [:]
    /// 読めなかったファイル(毎フレーム読み直さない)
    private var failed: Set<String> = []

    private init() {
        let c = NSCache<NSString, AnimatedImageSequence>()
        c.countLimit = 8
        c.totalCostLimit = 3 * Self.maxBytes
        cache = c
    }

    // MARK: - 判定

    /// 拡張子からして動く画像の可能性があるか(GIF / PNG / WebP)
    static func mightBeAnimated(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && animatedExtensions.contains(ext)
    }

    /// コマが 2 つ以上ある動く画像か(結果はパスごとに覚えておく)
    static func isAnimated(url: URL) -> Bool {
        shared.isAnimated(url: url)
    }

    func isAnimated(url: URL) -> Bool {
        guard Self.mightBeAnimated(url) else { return false }
        let key = url.path
        lock.lock()
        if let flag = animatedFlags[key] {
            lock.unlock()
            return flag
        }
        lock.unlock()
        var result = false
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, options) {
            result = CGImageSourceGetCount(source) > 1
        }
        lock.lock()
        animatedFlags[key] = result
        lock.unlock()
        return result
    }

    // MARK: - 取り出し

    /// 時刻 time(秒、画像の先頭が 0)のコマ。読めなければ nil
    func frame(url: URL, at time: Double) -> CIImage? {
        sequence(url: url)?.frame(at: time)
    }

    /// 1 周の長さ(秒)。読めなければ 0
    func loopDuration(url: URL) -> Double {
        sequence(url: url)?.duration ?? 0
    }

    /// GIF をオーバーレイにしたときの最初の長さ(秒)。写真と同じ 4 秒以上で、1 周の切れ目に合わせる
    static func suggestedOverlayDuration(for url: URL) -> Double {
        let base = MediaStore.defaultImageOverlayDuration
        let loop = shared.loopDuration(url: url)
        guard loop > 0.05 else { return base }
        let loops = max(1, (base / loop).rounded(.up))
        let fitted = loop * loops
        if fitted <= 15 { return fitted }
        if loop <= 15 { return max(base, loop * (15 / loop).rounded(.down)) }
        return min(loop, 30)
    }

    /// 全コマ(ファイルごとに一度だけ読む)
    func sequence(url: URL) -> AnimatedImageSequence? {
        let path = url.path
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        lock.lock()
        if failed.contains(path) {
            lock.unlock()
            return nil
        }
        let fileLock: NSLock
        if let existing = fileLocks[path] {
            fileLock = existing
        } else {
            fileLock = NSLock()
            fileLocks[path] = fileLock
        }
        lock.unlock()

        fileLock.lock()
        defer { fileLock.unlock() }
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = Self.decode(url: url) else {
            lock.lock()
            failed.insert(path)
            lock.unlock()
            return nil
        }
        cache.setObject(decoded, forKey: key, cost: decoded.cost)
        return decoded
    }

    /// キャッシュを空にする(メモリ警告など)
    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        failed.removeAll()
        lock.unlock()
    }

    // MARK: - 読み込み(ImageIO)

    private static func decode(url: URL) -> AnimatedImageSequence? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let first = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        // コマ数とメモリの上限から、何コマおきに残すか決める
        let bytesPerFrame = max(1, first.bytesPerRow * first.height)
        let framesByMemory = max(1, maxBytes / bytesPerFrame)
        let limit = max(1, min(maxFrames, framesByMemory))
        let step = max(1, Int((Double(count) / Double(limit)).rounded(.up)))

        let delays: [Double] = (0..<count).map { Self.delay(source, index: $0) }
        var frames: [CIImage] = []
        var keptDelays: [Double] = []
        var cost = 0
        var index = 0
        while index < count {
            let cg: CGImage?
            if index == 0 {
                cg = first
            } else {
                cg = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary)
            }
            // 間引いたコマの表示時間は、残したコマにまとめる
            let end = min(index + step, count)
            let keptDelay = delays[index..<end].reduce(0, +)
            if let cg {
                frames.append(CIImage(cgImage: cg))
                keptDelays.append(keptDelay)
                cost += cg.bytesPerRow * cg.height
            } else if !keptDelays.isEmpty {
                // 読めなかったコマは前のコマを延ばす
                keptDelays[keptDelays.count - 1] += keptDelay
            }
            index += step
        }
        guard !frames.isEmpty else { return nil }
        return AnimatedImageSequence(frames: frames, delays: keptDelays, cost: cost)
    }

    /// コマの表示時間(秒)。GIF / APNG / WebP の順に見る。
    /// 0(「できるだけ速く」)はブラウザと同じく 0.1 秒にし、最短 0.02 秒
    private static func delay(_ source: CGImageSource, index: Int) -> Double {
        let fallback = 0.1
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return fallback
        }
        let candidates: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ]
        for candidate in candidates {
            guard let dictionary = props[candidate.dictionary] as? [CFString: Any] else { continue }
            let unclamped = (dictionary[candidate.unclamped] as? NSNumber)?.doubleValue
            let clamped = (dictionary[candidate.clamped] as? NSNumber)?.doubleValue
            let raw = unclamped ?? clamped ?? fallback
            if !raw.isFinite || raw <= 0.011 { return fallback }
            return max(0.02, raw)
        }
        return fallback
    }
}

// MARK: - 写真ライブラリ・「ファイル」からの受け取り

/// PhotosPicker の GIF を受け取る(.gif のまま mediaDirectory にコピー。写真(PickedPhoto)だと jpg になることがあるため)
struct PickedGIF: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .gif) { gif in
            SentTransferredFile(gif.url)
        } importing: { received in
            let copied = try PickedGIF.copyIntoMediaDirectory(received.file)
            return PickedGIF(url: copied)
        }
        DataRepresentation(importedContentType: .gif) { data in
            let destination = MediaStore.uniqueDestination(forFileName: "animation.gif")
            try data.write(to: destination, options: .atomic)
            return PickedGIF(url: destination)
        }
    }

    private static func copyIntoMediaDirectory(_ file: URL) throws -> URL {
        var baseName = file.deletingPathExtension().lastPathComponent
        if baseName.isEmpty { baseName = "animation" }
        let destination = MediaStore.uniqueDestination(forFileName: "\(baseName).gif")
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }
}

extension VideoCompositorOverlay {
    /// 出力時刻 time に対応する、動く画像の先頭からの秒(左端をトリミングした分 = sourceStart も進める。写真なので速度は見ない)
    func animatedImageTime(at time: Double) -> Double {
        max(0, sourceStart) + (time - start)
    }
}

extension PhotosPickerItem {
    /// 選んだ項目が GIF か(GIF でない画像は写真として受け取る)
    var isGIF: Bool {
        supportedContentTypes.contains { $0.conforms(to: .gif) }
    }
}

enum AnimatedImageImport {
    /// 「ファイル」で選んだ GIF を一時フォルダ("Drop-…"、起動時に片づく)に "<NNN>-<元の名前>" でコピーする。
    /// ドラッグ&ドロップと同じ取り込み(importOverlayFiles)に渡す(取り込み後に一時ファイルは消える)
    static func copyToTemporary(_ urls: [URL]) async -> [URL] {
        await Task.detached(priority: .userInitiated) { () -> [URL] in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var result: [URL] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                var name = url.lastPathComponent
                if name.isEmpty { name = "animation.gif" }
                let destination = folder.appendingPathComponent(String(format: "%03d-", index + 1) + name)
                var coordinationError: NSError?
                var copied = false
                // 「ファイル」の項目(iCloud Drive など)がまだ端末にないときはダウンロードを待つ
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                                                  error: &coordinationError) { readable in
                    do {
                        try FileManager.default.copyItem(at: readable, to: destination)
                        copied = true
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
                if copied { result.append(destination) }
            }
            return result
        }.value
    }
}
