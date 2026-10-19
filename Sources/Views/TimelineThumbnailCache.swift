import SwiftUI
import UIKit

// =====================================================================
// タイムライン用サムネイルのキャッシュ(クリップ URL + 元素材上の時刻 をキーにする)
// 写真(静止画)のサムネイルは URL だけをキーにする。
// =====================================================================

final class TimelineThumbnailCache: @unchecked Sendable {
    static let shared = TimelineThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var failedKeys = Set<String>()

    /// ズーム段階に応じてサムネイル時刻を丸める刻み(秒)
    private static let quantizeSteps: [Double] = [0.25, 0.5, 1, 2, 4, 8, 15, 30, 60, 120, 300, 600]

    private init() {
        cache.countLimit = 800
    }

    static func key(url: URL, time: Double) -> String {
        let centis = time.isFinite ? Int((time * 100).rounded()) : 0
        return url.path + "#" + String(centis)
    }

    /// 写真(静止画)サムネイルのキー
    static func imageKey(url: URL) -> String {
        url.path + "#image"
    }

    /// サムネイル 1 枚が表す元素材の長さ(tileSpan 秒)に合わせて時刻を丸める。
    /// 丸めることでズームを変えてもキャッシュが再利用されやすくなる。
    static func quantizedTime(_ seconds: Double, tileSpan: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        var step = 600.0
        for s in quantizeSteps where s >= tileSpan * 0.5 {
            step = s
            break
        }
        let rounded = (seconds / step).rounded() * step
        let upper = max(0, duration - 0.05)
        return min(max(0, rounded), upper)
    }

    func cachedImage(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func image(url: URL, time: Double) async -> UIImage? {
        let key = Self.key(url: url, time: time)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        let failed = lock.withLock { failedKeys.contains(key) }
        if failed { return nil }

        let image = await MediaStore.thumbnail(for: url, at: time, maxPixel: 180)
        if let image {
            cache.setObject(image, forKey: key as NSString)
        } else if !Task.isCancelled {
            lock.withLock {
                _ = failedKeys.insert(key)
            }
        }
        return image
    }

    /// 写真ファイルのサムネイル(EXIF の向きを反映)。読めない場合は nil
    func imageThumbnail(url: URL) async -> UIImage? {
        let key = Self.imageKey(url: url)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        let failed = lock.withLock { failedKeys.contains(key) }
        if failed { return nil }

        let work = Task.detached(priority: .utility) { () -> UIImage? in
            MediaStore.makeImageClipThumbnail(url: url, maxPixel: 180)
        }
        let image = await work.value
        if let image {
            cache.setObject(image, forKey: key as NSString)
        } else if !Task.isCancelled {
            lock.withLock {
                _ = failedKeys.insert(key)
            }
        }
        return image
    }
}

/// サムネイル 1 枚。読み込みは少し待ってから行う(高速スクロール中の無駄な生成を防ぐ)
struct TimelineThumbnailTile: View {
    let url: URL
    let time: Double
    let placeholder: UIImage?
    /// true なら写真ファイルとして読み込む(time は使わない)
    var isImage: Bool = false

    @State private var loaded: UIImage? = nil
    @State private var loadedKey: String = ""

    var body: some View {
        let key = isImage
            ? TimelineThumbnailCache.imageKey(url: url)
            : TimelineThumbnailCache.key(url: url, time: time)
        let current: UIImage? = (loadedKey == key ? loaded : nil)
            ?? TimelineThumbnailCache.shared.cachedImage(forKey: key)
            ?? loaded
            ?? placeholder

        ZStack {
            if let current {
                Image(uiImage: current)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.22)
            }
        }
        .task(id: key) {
            if let hit = TimelineThumbnailCache.shared.cachedImage(forKey: key) {
                loaded = hit
                loadedKey = key
                return
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let image: UIImage?
            if isImage {
                image = await TimelineThumbnailCache.shared.imageThumbnail(url: url)
            } else {
                image = await TimelineThumbnailCache.shared.image(url: url, time: time)
            }
            if Task.isCancelled { return }
            if let image {
                loaded = image
                loadedKey = key
            }
        }
    }
}

// =====================================================================
// 波形のキャッシュ(URL ごとに 1 回だけ解析し、同時に来た要求は 1 つの解析にまとめる)
// 解析本体は AudioAnalysis.waveform(for:) に任せ、ここでは
// - 同期的に引ける参照(初回描画用)
// - 失敗(音声トラックなしなど)の記憶
// - 重複要求の統合
// を受け持つ。
// =====================================================================

final class TimelineWaveformCache: @unchecked Sendable {
    static let shared = TimelineWaveformCache()

    /// 波形の解像度(1 秒あたりのバケット数)
    static let samplesPerSecond: Double = 50

    private final class Box {
        let waveform: AudioWaveform
        init(_ waveform: AudioWaveform) { self.waveform = waveform }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var failedPaths = Set<String>()
    private var inFlight: [String: Task<AudioWaveform?, Never>] = [:]

    private init() {
        cache.countLimit = 64
    }

    /// 読み込み済みなら同期的に返す(初回描画用)。未読み込みなら nil
    func cached(for url: URL) -> AudioWaveform? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) {
            return hit.waveform
        }
        if let shared = AudioAnalysis.cachedWaveform(for: url, samplesPerSecond: Self.samplesPerSecond) {
            cache.setObject(Box(shared), forKey: key)
            return shared
        }
        return nil
    }

    /// 波形を読み込む(失敗・音声なしは nil)。同じ URL への同時要求は 1 回の解析にまとめる。
    /// 呼び出し側の Task がキャンセルされても解析は続け、結果はキャッシュに残す。
    func waveform(for url: URL) async -> AudioWaveform? {
        if let hit = cached(for: url) { return hit }
        let path = url.path
        let rate = Self.samplesPerSecond

        var task: Task<AudioWaveform?, Never>? = nil
        lock.lock()
        if failedPaths.contains(path) {
            task = nil
        } else if let running = inFlight[path] {
            task = running
        } else {
            let newTask: Task<AudioWaveform?, Never> = Task(priority: .utility) {
                do {
                    return try await AudioAnalysis.waveform(for: url, samplesPerSecond: rate)
                } catch {
                    return nil
                }
            }
            inFlight[path] = newTask
            task = newTask
        }
        lock.unlock()

        guard let task else { return nil }
        let result = await task.value

        lock.lock()
        inFlight[path] = nil
        if let result {
            cache.setObject(Box(result), forKey: path as NSString)
        } else {
            failedPaths.insert(path)
        }
        lock.unlock()
        return result
    }
}
