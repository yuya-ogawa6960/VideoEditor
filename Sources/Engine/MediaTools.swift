import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreText
import UIKit
import ImageIO

// =====================================================================
// 素材まわりの道具(パーティション A)。
//   - 音声抽出(m4a)、逆再生コピー、フリーズフレーム画像
//   - フォント(.ttf/.otf)の読み込みと登録、LUT(.cube)の読み込み
// 重い処理は専用のキューで行い、呼び出し側 Task のキャンセルで中断する。
// =====================================================================

enum MediaToolsError: LocalizedError {
    case noVideoTrack
    case noAudioTrack
    case invalidRange
    case cannotCreateSession
    case cannotReadFrame
    case cannotEncodeImage
    case invalidFont
    case invalidLUT(String)
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "映像トラックがありません")
        case .noAudioTrack: return String(localized: "音声トラックがありません")
        case .invalidRange: return String(localized: "範囲が正しくありません")
        case .cannotCreateSession: return String(localized: "変換の準備ができませんでした")
        case .cannotReadFrame: return String(localized: "コマを読み取れませんでした")
        case .cannotEncodeImage: return String(localized: "画像に変換できませんでした")
        case .invalidFont: return String(localized: "フォントファイルとして読み込めませんでした(.ttf / .otf を選んでください)")
        case .invalidLUT(let detail): return String(localized: "LUT(.cube)として読み込めませんでした: \(detail)")
        case .readFailed(let detail): return String(localized: "読み込みに失敗しました: \(detail)")
        case .writeFailed(let detail): return String(localized: "書き込みに失敗しました: \(detail)")
        }
    }
}

/// バックグラウンドの同期処理に渡すキャンセルフラグ(スレッドセーフ)
final class MediaToolsCancelFlag {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

enum MediaTools {
    private static let workQueue = DispatchQueue(label: "com.personal.videoeditor.mediatools",
                                                 qos: .userInitiated,
                                                 attributes: .concurrent)

    // MARK: - 共通ヘルパー

    /// 同期処理を専用キューで実行し、呼び出し側 Task のキャンセルをフラグで伝える
    private static func runBlocking<T>(flag: MediaToolsCancelFlag, _ work: @escaping () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                workQueue.async {
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let value = try work()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// 同じ名前があるときに「名前 2.ext」「名前 3.ext」… を返す
    private static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(fileName)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2
        while index < 10_000 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
        return directory.appendingPathComponent("\(UUID().uuidString)_\(fileName)")
    }

    private static func ensureDirectory(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - フォント

    private static let fontLock = NSLock()
    private static var registeredFontPaths: Set<String> = []
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// Documents/Media/Fonts(必要に応じて作成)
    static var fontsDirectory: URL {
        let dir = MediaStore.mediaDirectory.appendingPathComponent("Fonts", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    private static func storedFontURLs() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: fontsDirectory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { fontExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// フォントファイルをプロセスに登録する(登録済みなら何もしない)
    @discardableResult
    private static func registerFont(at url: URL) -> Bool {
        fontLock.lock()
        let already = registeredFontPaths.contains(url.path)
        fontLock.unlock()
        if already { return true }

        var errorRef: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
        if !ok {
            if let error = errorRef?.takeRetainedValue() {
                let code = CFErrorGetCode(error)
                // 105 = すでに登録済み / 305 = 同名のフォントが登録済み → 使える状態なので成功扱い
                if code != 105 && code != 305 {
                    return false
                }
            } else {
                return false
            }
        }
        fontLock.lock()
        registeredFontPaths.insert(url.path)
        fontLock.unlock()
        return true
    }

    /// ファイルに含まれるフォントの PostScript 名(.ttc は複数)
    private static func postScriptNames(at url: URL) -> [String] {
        guard let array = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) else { return [] }
        let count = CFArrayGetCount(array)
        var names: [String] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let descriptor = unsafeBitCast(raw, to: CTFontDescriptor.self)
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, !name.isEmpty {
                names.append(name)
            }
        }
        return names
    }

    /// 起動時に呼ぶ。保存済みのフォントをすべて登録する
    static func registerStoredFonts() {
        BundledFonts.registerAll()
        for url in storedFontURLs() {
            registerFont(at: url)
        }
    }

    /// 読み込み済みフォントの PostScript 名(登録もしておく)
    static func storedFontNames() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for url in storedFontURLs() {
            registerFont(at: url)
            for name in postScriptNames(at: url) where !seen.contains(name) {
                seen.insert(name)
                result.append(name)
            }
        }
        return result
    }

    /// .ttf / .otf を Fonts フォルダにコピーして登録し、PostScript 名を返す
    static func importFont(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard fontExtensions.contains(url.pathExtension.lowercased()) else {
            throw MediaToolsError.invalidFont
        }
        let names = postScriptNames(at: url)
        guard let first = names.first else {
            throw MediaToolsError.invalidFont
        }
        let fm = FileManager.default
        let directory = fontsDirectory
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            if fileSize(destination) == fileSize(url) {
                // 同じファイルがすでにある
                guard registerFont(at: destination) else { throw MediaToolsError.invalidFont }
                return first
            }
            destination = uniqueURL(in: directory, fileName: url.lastPathComponent)
        }
        try fm.copyItem(at: url, to: destination)
        guard registerFont(at: destination) else {
            try? fm.removeItem(at: destination)
            throw MediaToolsError.invalidFont
        }
        return first
    }

    // MARK: - LUT(.cube)

    /// Documents/Media/LUTs(必要に応じて作成)
    static var lutDirectory: URL {
        let dir = FilterLUT.lutDirectory
        ensureDirectory(dir)
        return dir
    }

    /// 保存済みの LUT ファイル名(名前順)
    static func storedLUTNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: lutDirectory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map { $0.lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// .cube を LUTs フォルダにコピーし、ファイル名を返す(壊れたファイルは読み込まない)
    static func importLUT(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard url.pathExtension.lowercased() == "cube" else {
            throw MediaToolsError.invalidLUT(String(localized: "拡張子が .cube ではありません"))
        }
        do {
            _ = try FilterLUT.loadCube(url: url)
        } catch {
            throw MediaToolsError.invalidLUT(error.localizedDescription)
        }
        let fm = FileManager.default
        let directory = lutDirectory
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            if fileSize(destination) == fileSize(url) {
                return destination.lastPathComponent
            }
            destination = uniqueURL(in: directory, fileName: url.lastPathComponent)
        }
        try fm.copyItem(at: url, to: destination)
        FilterLUT.invalidateFileCache()
        return destination.lastPathComponent
    }

    // MARK: - 音声抽出

    /// 動画から音声だけを m4a(AAC)として mediaDirectory に書き出す。start / end は元素材上の秒(nil = 全体)
    static func extractAudio(from url: URL, start: Double?, end: Double?) async throws -> URL {
        let base = MediaStore.displayName(for: url, fallback: String(localized: "音声"))
        let destination = MediaStore.uniqueDestination(forFileName: "\(base).m4a")
        try await exportAudio(from: url, start: start, end: end, to: destination)
        return destination
    }

    /// 音声だけを m4a(AAC)に書き出す(内部用。AudioEffectsRenderer も使う)
    static func exportAudio(from url: URL, start: Double?, end: Double?, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw MediaToolsError.noAudioTrack }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaToolsError.cannotCreateSession
        }
        if start != nil || end != nil {
            let total = try await asset.load(.duration).seconds
            let s = max(0, start ?? 0)
            var e = end ?? total
            if total.isFinite && total > 0 { e = min(e, total) }
            guard e - s > 0.01 else { throw MediaToolsError.invalidRange }
            session.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                            end: CMTime(seconds: e, preferredTimescale: 600))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try await session.export(to: destination, as: .m4a)
    }

    // MARK: - フリーズフレーム

    /// 指定した時刻(元素材上の秒)のコマを JPEG として mediaDirectory に保存し、その URL を返す(向きは反映済み)
    static func freezeFrameImage(from url: URL, at seconds: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

        var cgImage: CGImage?
        if let result = try? await generator.image(at: time) {
            cgImage = result.image
        } else {
            // 厳密な時刻で取れないときは許容幅を広げて再試行
            let relaxed = AVAssetImageGenerator(asset: asset)
            relaxed.appliesPreferredTrackTransform = true
            relaxed.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            relaxed.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let result = try? await relaxed.image(at: time) {
                cgImage = result.image
            }
        }
        guard let cgImage else { throw MediaToolsError.cannotReadFrame }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw MediaToolsError.cannotEncodeImage }
        let destination = MediaStore.uniqueDestination(forFileName: "freeze.jpg")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - 逆再生

    /// [start, end](元素材上の秒)を逆再生にした .mov を mediaDirectory に作る。
    /// 映像は末尾から少しずつ読み出して逆順に書き、音声はサンプル順を反転する(どちらも元の長さと同じ)。
    /// progress は 0...1 をバックグラウンドのスレッドから呼ぶ。呼び出し側 Task のキャンセルで中断する。
    static func reversedCopy(of url: URL, start: Double, end: Double, progress: ((Double) -> Void)?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw MediaToolsError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (naturalSize, transform, nominalFrameRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let assetDuration = try await asset.load(.duration).seconds

        let rangeStart = max(0, min(start, end))
        var rangeEnd = max(start, end)
        if assetDuration.isFinite && assetDuration > 0 {
            rangeEnd = min(rangeEnd, assetDuration)
        }
        if !rangeEnd.isFinite || rangeEnd <= rangeStart { rangeEnd = assetDuration }
        guard rangeEnd - rangeStart > 0.05 else { throw MediaToolsError.invalidRange }

        let fm = FileManager.default
        let tempDirectory = fm.temporaryDirectory.appendingPathComponent("VideoManiaReverse_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDirectory) }

        let base = MediaStore.displayName(for: url, fallback: String(localized: "動画"))
        let destination = MediaStore.uniqueDestination(forFileName: "\(base)_reversed.mov")
        let flag = MediaToolsCancelFlag()
        let report: (Double) -> Void = { value in
            progress?(min(max(value, 0), 1))
        }

        // 1. 映像(映像のみの .mov)
        let videoOnlyURL = tempDirectory.appendingPathComponent("video.mov")
        try await runBlocking(flag: flag) {
            try reverseVideoBlocking(asset: asset,
                                     track: videoTrack,
                                     naturalSize: naturalSize,
                                     transform: transform,
                                     nominalFrameRate: nominalFrameRate,
                                     rangeStart: rangeStart,
                                     rangeEnd: rangeEnd,
                                     destination: videoOnlyURL,
                                     flag: flag) { value in
                report(value * 0.8)
            }
        }
        try Task.checkCancellation()

        // 2. 音声(失敗しても映像だけで続ける)
        var reversedAudioURL: URL?
        if !audioTracks.isEmpty {
            let extracted = tempDirectory.appendingPathComponent("audio.m4a")
            let reversed = tempDirectory.appendingPathComponent("audio_reversed.m4a")
            do {
                try await exportAudio(from: url, start: rangeStart, end: rangeEnd, to: extracted)
                try await runBlocking(flag: flag) {
                    try reverseAudioBlocking(source: extracted, destination: reversed, flag: flag) { value in
                        report(0.8 + value * 0.12)
                    }
                }
                reversedAudioURL = reversed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reversedAudioURL = nil
            }
        }
        try Task.checkCancellation()

        // 3. 映像と音声をひとつのファイルにまとめる
        if let audioURL = reversedAudioURL {
            do {
                try await mux(video: videoOnlyURL, audio: audioURL, to: destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
                try fm.moveItem(at: videoOnlyURL, to: destination)
            }
        } else {
            try fm.moveItem(at: videoOnlyURL, to: destination)
        }
        report(1)
        return destination
    }

    /// 映像を逆順に書き出す(同期。専用キューで実行)
    private static func reverseVideoBlocking(asset: AVURLAsset,
                                             track: AVAssetTrack,
                                             naturalSize: CGSize,
                                             transform: CGAffineTransform,
                                             nominalFrameRate: Float,
                                             rangeStart: Double,
                                             rangeEnd: Double,
                                             destination: URL,
                                             flag: MediaToolsCancelFlag,
                                             progress: @escaping (Double) -> Void) throws {
        let fullRange = CMTimeRange(start: CMTime(seconds: rangeStart, preferredTimescale: 600),
                                    end: CMTime(seconds: rangeEnd, preferredTimescale: 600))

        // パス 1: 各コマの表示時刻を集める(圧縮のまま読むので速い)
        var times: [CMTime] = []
        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = fullRange
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaToolsError.readFailed(String(localized: "映像の読み込みを設定できません")) }
            reader.add(output)
            guard reader.startReading() else {
                throw MediaToolsError.readFailed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
            }
            while let sample = output.copyNextSampleBuffer() {
                if flag.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isValid && CMSampleBufferGetNumSamples(sample) > 0 {
                    times.append(pts)
                }
            }
            if reader.status == .failed {
                throw MediaToolsError.readFailed(reader.error?.localizedDescription ?? String(localized: "不明なエラー"))
            }
        }
        times.sort { CMTimeCompare($0, $1) < 0 }
        guard let firstTime = times.first, let lastTime = times.last else {
            throw MediaToolsError.cannotReadFrame
        }
        let frameCount = times.count

        var averageFrameDuration = CMTime(value: 1, timescale: 30)
        if frameCount > 1 {
            let span = CMTimeSubtract(lastTime, firstTime).seconds
            if span > 0 {
                averageFrameDuration = CMTime(seconds: span / Double(frameCount - 1), preferredTimescale: 600)
            }
        } else if nominalFrameRate > 0 {
            averageFrameDuration = CMTime(seconds: 1 / Double(nominalFrameRate), preferredTimescale: 600)
        }

        // Writer(元の向き情報はそのまま transform に持たせる)
        let width = max(2, Int(naturalSize.width.rounded()) & ~1)
        let height = max(2, Int(naturalSize.height.rounded()) & ~1)
        let useHEVC = min(width, height) >= 2160
        let bitrate = min(80_000_000, max(3_000_000, Int(Double(width * height) * 8)))
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        if !useHEVC {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let codec: AVVideoCodecType = useHEVC ? .hevc : .h264
        let settings: [String: Any] = [
            AVVideoCodecKey: codec.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else { throw MediaToolsError.writeFailed(String(localized: "映像の書き込みを設定できません")) }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaToolsError.writeFailed(writer.error?.localizedDescription ?? String(localized: "書き込みを開始できません"))
        }
        writer.startSession(atSourceTime: .zero)

        func failWriter(_ message: String) -> Error {
            let error = writer.error
            if writer.status == .writing { writer.cancelWriting() }
            return error ?? MediaToolsError.writeFailed(message)
        }

        // パス 2: 末尾のかたまりから順に復号して逆順に書く(メモリは約 160 MB まで)
        let bytesPerFrame = Double(width * height) * 1.5
        let framesPerChunk = max(4, min(60, Int(160_000_000 / max(1, bytesPerFrame))))
        let pixelSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        let epsilon = CMTime(value: 1, timescale: 6000)
        var written = 0
        var lastOutputTime = CMTime.zero
        var chunkEnd = frameCount

        while chunkEnd > 0 {
            if flag.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            let chunkStart = max(0, chunkEnd - framesPerChunk)
            let chunkRange = CMTimeRange(start: times[chunkStart], end: CMTimeAdd(times[chunkEnd - 1], epsilon))

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = chunkRange
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: pixelSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw failWriter(String(localized: "映像の読み込みを設定できません")) }
            reader.add(output)
            guard reader.startReading() else {
                throw failWriter(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
            }

            var frames: [(time: CMTime, buffer: CVPixelBuffer)] = []
            frames.reserveCapacity(chunkEnd - chunkStart)
            while let sample = output.copyNextSampleBuffer() {
                if flag.isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw CancellationError()
                }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if CMTimeCompare(pts, times[chunkStart]) < 0 { continue }
                frames.append((time: pts, buffer: buffer))
            }
            if reader.status == .failed {
                throw failWriter(reader.error?.localizedDescription ?? String(localized: "映像の読み込みに失敗しました"))
            }

            frames.sort { CMTimeCompare($0.time, $1.time) < 0 }
            for frame in frames.reversed() {
                let outTime = CMTimeSubtract(lastTime, frame.time)
                if written > 0 && CMTimeCompare(outTime, lastOutputTime) <= 0 {
                    continue   // 同じ時刻のコマは飛ばす(時刻は単調増加でなければならない)
                }
                while !input.isReadyForMoreMediaData {
                    if flag.isCancelled || writer.status != .writing { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if flag.isCancelled {
                    writer.cancelWriting()
                    throw CancellationError()
                }
                guard writer.status == .writing else { throw failWriter(String(localized: "書き込みが中断されました")) }
                guard adaptor.append(frame.buffer, withPresentationTime: outTime) else {
                    throw failWriter(String(localized: "コマを書き込めませんでした"))
                }
                lastOutputTime = outTime
                written += 1
            }
            frames.removeAll()
            progress(Double(frameCount - chunkStart) / Double(max(1, frameCount)))
            chunkEnd = chunkStart
        }

        guard written > 0 else { throw failWriter(String(localized: "書き込めるコマがありませんでした")) }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeAdd(lastOutputTime, averageFrameDuration))
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? MediaToolsError.writeFailed(String(localized: "書き込みを完了できませんでした"))
        }
    }

    /// 音声ファイル(m4a)のサンプル順を反転して m4a(AAC)に書く(同期。専用キューで実行)
    private static func reverseAudioBlocking(source: URL,
                                             destination: URL,
                                             flag: MediaToolsCancelFlag,
                                             progress: @escaping (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let totalFrames = input.length
        guard totalFrames > 0, format.channelCount > 0 else { throw MediaToolsError.noAudioTrack }
        guard !format.isInterleaved, format.commonFormat == .pcmFormatFloat32 else {
            throw MediaToolsError.readFailed(String(localized: "対応していない音声形式です"))
        }
        let channels = Int(format.channelCount)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 192_000
        ]
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        let output = try AVAudioFile(forWriting: destination,
                                     settings: outputSettings,
                                     commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        let blockFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw MediaToolsError.readFailed(String(localized: "バッファを確保できません"))
        }

        var position = totalFrames
        while position > 0 {
            if flag.isCancelled { throw CancellationError() }
            let count = AVAudioFrameCount(min(AVAudioFramePosition(blockFrames), position))
            position -= AVAudioFramePosition(count)
            input.framePosition = position
            try input.read(into: buffer, frameCount: count)
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            guard let data = buffer.floatChannelData else {
                throw MediaToolsError.readFailed(String(localized: "音声データを読めません"))
            }
            for c in 0..<channels {
                let p = data[c]
                var i = 0
                var j = n - 1
                while i < j {
                    let tmp = p[i]
                    p[i] = p[j]
                    p[j] = tmp
                    i += 1
                    j -= 1
                }
            }
            try output.write(from: buffer)
            progress(Double(totalFrames - position) / Double(totalFrames))
        }
    }

    /// 映像のみの .mov と音声ファイルを 1 つの .mov にまとめる(再エンコードなし)
    private static func mux(video videoURL: URL, audio audioURL: URL, to destination: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MediaToolsError.noVideoTrack
        }
        let videoDuration = try await videoAsset.load(.duration)
        let videoTransform = try await videoTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaToolsError.writeFailed(String(localized: "映像トラックを作成できません"))
        }
        try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = videoTransform

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let audioDuration = try await audioAsset.load(.duration)
            let duration = CMTimeMinimum(audioDuration, videoDuration)
            if duration.seconds > 0,
               let compositionAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaToolsError.cannotCreateSession
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try await session.export(to: destination, as: .mov)
    }
}
