import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Vision

// =====================================================================
// 自動リフレーム(人物追尾)の解析と、解析系で共用するコマ読み出し(パーティション A)。
//
// AnalysisFrameReader:
//   AVAssetReader で BGRA のコマを縮小して読み出し、preferredTransform を反映して
//   「正立(表示どおりの向き)」の CVPixelBuffer にしてから順に渡す。
//   Vision に渡す画像はすべて正立なので、orientation は常に .up、
//   結果の boundingBox(左下原点・正規化)は y を反転するだけで左上原点の NormalizedRect になる。
//   handler はバックグラウンドのスレッドで順番に呼ばれる(false を返すと中断)。
//   呼び出し側 Task のキャンセルで読み出しを止める。
//
// VisionReframe.analyze:
//   `step` 秒ごとのコマに VNDetectFaceRectanglesRequest と VNDetectHumanRectanglesRequest を
//   かけ、大きく・中央に近く・直前の位置に近い被写体を 1 つ選ぶ。検出できないコマは直前の位置を
//   保持(先頭の未検出区間は最初の検出位置で埋める)。サンプルは元素材上の秒。
//   progress は 0...1 をバックグラウンドのスレッドから呼ぶ。
// =====================================================================

enum VisionAnalysisError: LocalizedError {
    case noVideoTrack
    case stillImage
    case invalidRange
    case noFrames
    case noSubjectDetected
    case trackingLost
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "映像トラックがありません")
        case .stillImage: return String(localized: "写真のクリップは解析できません")
        case .invalidRange: return String(localized: "解析する範囲が短すぎます")
        case .noFrames: return String(localized: "コマを読み取れませんでした")
        case .noSubjectDetected: return String(localized: "人物や顔が見つかりませんでした")
        case .trackingLost: return String(localized: "対象を追跡できませんでした。もう少し大きく囲ってお試しください")
        case .readFailed(let detail): return String(localized: "映像の読み込みに失敗しました: \(detail)")
        }
    }
}

// MARK: - コマ読み出し(解析用)

enum AnalysisFrameReader {

    /// [start, end](元素材上の秒)のコマを約 fps コマ/秒、長辺 maxDimension px 以下の正立 BGRA で順に渡す。
    /// fps <= 0 ならすべてのコマ。handler(buffer, 元素材上の秒) が false を返すと中断する(エラーにはならない)。
    static func readFrames(url: URL, start: Double, end: Double, fps: Double, maxDimension: Int,
                           handler: @escaping (CVPixelBuffer, Double) -> Bool) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VisionAnalysisError.noVideoTrack }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let assetDuration = try await asset.load(.duration).seconds

        let rangeStart = max(0, min(start, end))
        var rangeEnd = max(start, end)
        if assetDuration.isFinite && assetDuration > 0 { rangeEnd = min(rangeEnd, assetDuration) }
        guard rangeEnd - rangeStart > 0.02 else { throw VisionAnalysisError.invalidRange }
        try Task.checkCancellation()

        let flag = MediaToolsCancelFlag()
        // 解析中の画面に「AI が見ているコマ」として出す(間引いて縮小。AnalysisPeek)
        let peekingHandler: (CVPixelBuffer, Double) -> Bool = { buffer, time in
            AnalysisPeek.shared.post(buffer)
            return handler(buffer, time)
        }
        let work = Task.detached(priority: .userInitiated) {
            try AnalysisFrameReader.readBlocking(asset: asset, track: track, naturalSize: naturalSize,
                                                 transform: transform, start: rangeStart, end: rangeEnd,
                                                 fps: fps, maxDimension: maxDimension, flag: flag, handler: peekingHandler)
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            flag.cancel()
            work.cancel()
        }
    }

    private static func readBlocking(asset: AVURLAsset, track: AVAssetTrack, naturalSize: CGSize,
                                     transform: CGAffineTransform, start: Double, end: Double,
                                     fps: Double, maxDimension: Int, flag: MediaToolsCancelFlag,
                                     handler: (CVPixelBuffer, Double) -> Bool) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VisionAnalysisError.readFailed(error.localizedDescription)
        }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))

        // 縮小サイズ(自然サイズ基準、偶数)
        let naturalWidth = max(1.0, Double(naturalSize.width))
        let naturalHeight = max(1.0, Double(naturalSize.height))
        let longest = max(naturalWidth, naturalHeight)
        let scale: Double = min(1.0, Double(max(16, maxDimension)) / longest)
        let decodedWidth = max(16, Int((naturalWidth * scale).rounded()) & ~1)
        let decodedHeight = max(16, Int((naturalHeight * scale).rounded()) & ~1)

        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if scale < 1 {
            settings[kCVPixelBufferWidthKey as String] = decodedWidth
            settings[kCVPixelBufferHeightKey as String] = decodedHeight
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VisionAnalysisError.readFailed(String(localized: "映像出力を追加できません")) }
        reader.add(output)
        guard reader.startReading() else {
            throw VisionAnalysisError.readFailed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
        }

        // 正立したサイズのバッファプール
        let upright = orientedSize(naturalSize: CGSize(width: decodedWidth, height: decodedHeight), transform: transform)
        let outWidth = max(16, Int(upright.width.rounded()) & ~1)
        let outHeight = max(16, Int(upright.height.rounded()) & ~1)
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outWidth,
            kCVPixelBufferHeightKey as String: outHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        var poolRef: CVPixelBufferPool?
        _ = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &poolRef)
        guard let pool = poolRef else { throw VisionAnalysisError.readFailed(String(localized: "バッファを確保できません")) }

        let bounds = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let interval: Double = fps > 0 ? 1.0 / fps : 0
        var nextTime = start - 1
        var delivered = 0

        while let sample = output.copyNextSampleBuffer() {
            if flag.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            if interval > 0, pts < nextTime { continue }
            // 次に採用するコマの時刻(わずかな時刻ゆらぎで 1 コマ飛ばさないよう 4 ms 手前)
            nextTime = pts + interval - 0.004

            var image = CIImage(cvPixelBuffer: imageBuffer)
            image = orientedImage(image, transform: transform)
            var outBuffer: CVPixelBuffer?
            _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
            guard let destination = outBuffer else { throw VisionAnalysisError.readFailed(String(localized: "バッファを確保できません")) }
            // 裏で GPU を使う許可が無いときは CPU で描く(FilterEngineContexts.current)
            FilterEngineContexts.current.render(image, to: destination, bounds: bounds, colorSpace: colorSpace)
            delivered += 1
            if !handler(destination, pts) {
                reader.cancelReading()
                return
            }
        }
        if flag.isCancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        if reader.status == .failed {
            throw VisionAnalysisError.readFailed(reader.error?.localizedDescription ?? String(localized: "不明なエラー"))
        }
        if delivered == 0 {
            throw VisionAnalysisError.noFrames
        }
    }

    /// preferredTransform(UIKit 座標系 = 左上原点)を CoreImage 座標系(左下原点)で適用し、原点を (0,0) に揃える
    /// (VideoCompositor.oriented と同じ計算。解析側が他パーティションの変更に左右されないよう持つ)
    private static func orientedImage(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        if transform.isIdentity { return image }
        let extent = image.extent
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        let combined = flipIn.concatenating(transform).concatenating(flipOut)
        let transformed = image.transformed(by: combined)
        let e = transformed.extent
        return transformed.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    // MARK: 座標変換

    /// Vision の boundingBox(左下原点・正規化)→ 左上原点の NormalizedRect
    static func topLeftRect(fromVision box: CGRect) -> NormalizedRect {
        NormalizedRect(x: Double(box.minX), y: 1 - Double(box.maxY),
                       width: Double(box.width), height: Double(box.height)).clamped()
    }

    /// 左上原点の NormalizedRect → Vision の boundingBox(左下原点)
    static func visionRect(fromTopLeft rect: NormalizedRect) -> CGRect {
        let r = rect.clamped()
        return CGRect(x: r.x, y: 1 - r.y - r.height, width: r.width, height: r.height)
    }

    /// BGRA バッファから縮小した輝度列(0...255)を取り出す(動き量の計算用)。stride ピクセルごとにサンプリング
    static func lumaSamples(of buffer: CVPixelBuffer, stride: Int) -> [Float] {
        let step = max(1, stride)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var result: [Float] = []
        result.reserveCapacity((width / step + 1) * (height / step + 1))
        var y = 0
        while y < height {
            let row = pointer + y * bytesPerRow
            var x = 0
            while x < width {
                let p = row + x * 4
                let b = Int(p[0])
                let g = Int(p[1])
                let r = Int(p[2])
                let luma = (r + 2 * g + b) / 4
                result.append(Float(luma))
                x += step
            }
            y += step
        }
        return result
    }
}

// MARK: - 自動リフレーム

enum VisionReframe {
    /// 解析用のコマの長辺(px)
    static let frameDimension = 640

    private struct Candidate {
        var rect: NormalizedRect   // 左上原点
        var confidence: Double
        var isFace: Bool
    }

    private final class State {
        var samples: [ReframeSample] = []
        var lastCenter: NormalizedPoint?
        var detections = 0
        var frames = 0
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        init() {
            humanRequest.upperBodyOnly = true
        }
    }

    /// clip のトリミング範囲を `step` 秒ごとに解析し、注目点の軌跡を返す(enabled = true、smoothing / zoom は clip の値を引き継ぐ)。
    /// 人物も顔も一度も見つからないときは VisionAnalysisError.noSubjectDetected。
    static func analyze(clip: Clip, step: Double = 0.25, progress: ((Double) -> Void)?) async throws -> ReframeTrack {
        guard !clip.isStill else { throw VisionAnalysisError.stillImage }
        let start = clip.startTime
        let end = clip.endTime
        guard end - start > 0.05 else { throw VisionAnalysisError.invalidRange }
        let url = clip.url
        let span = end - start
        let fps = 1.0 / max(0.05, step)
        let state = State()

        try await AnalysisFrameReader.readFrames(url: url, start: start, end: end, fps: fps,
                                                 maxDimension: frameDimension) { buffer, time in
            state.frames += 1
            let candidate = detect(in: buffer, state: state)
            if let candidate {
                let center = focusPoint(for: candidate)
                state.samples.append(ReframeSample(time: time, center: center, confidence: candidate.confidence))
                state.lastCenter = center
                state.detections += 1
            } else if let last = state.lastCenter {
                state.samples.append(ReframeSample(time: time, center: last, confidence: 0))
            } else {
                // 先頭の未検出区間: あとで最初の検出位置で埋める
                state.samples.append(ReframeSample(time: time, center: .center, confidence: -1))
            }
            progress?(min(1, max(0, (time - start) / span)))
            return true
        }
        try Task.checkCancellation()

        guard state.detections > 0 else { throw VisionAnalysisError.noSubjectDetected }
        var samples = state.samples
        // 先頭の未検出区間を最初の検出位置で埋める
        if let firstDetected = samples.first(where: { $0.confidence >= 0 }) {
            for i in samples.indices where samples[i].confidence < 0 {
                samples[i].center = firstDetected.center
                samples[i].confidence = 0
            }
        }
        samples = medianFiltered(samples)
        if samples.count == 1, let only = samples.first {
            samples.append(ReframeSample(time: only.time + max(step, 0.1), center: only.center, confidence: only.confidence))
        }
        progress?(1)

        var track = clip.reframe
        track.enabled = true
        track.samples = samples
        return track
    }

    // MARK: 検出

    private static func detect(in buffer: CVPixelBuffer, state: State) -> Candidate? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            VisionCompute.prepare([state.faceRequest, state.humanRequest])
            try handler.perform([state.faceRequest, state.humanRequest])
        } catch {
            return nil
        }
        var faces: [Candidate] = []
        for observation in state.faceRequest.results ?? [] {
            let rect = AnalysisFrameReader.topLeftRect(fromVision: observation.boundingBox)
            faces.append(Candidate(rect: rect, confidence: Double(observation.confidence), isFace: true))
        }
        var humans: [Candidate] = []
        for observation in state.humanRequest.results ?? [] {
            let rect = AnalysisFrameReader.topLeftRect(fromVision: observation.boundingBox)
            humans.append(Candidate(rect: rect, confidence: Double(observation.confidence), isFace: false))
        }
        // 顔が十分な大きさで見つかっていれば顔を優先、なければ人物の矩形
        let usableFaces = faces.filter { $0.rect.height >= 0.03 }
        let pool = usableFaces.isEmpty ? humans : usableFaces
        guard !pool.isEmpty else { return nil }
        var best: Candidate?
        var bestScore = -1.0
        for candidate in pool {
            let s = score(candidate, previous: state.lastCenter)
            if s > bestScore {
                bestScore = s
                best = candidate
            }
        }
        return best
    }

    /// 大きさ × 中央への近さ × 直前の位置との連続性 × 確からしさ
    private static func score(_ candidate: Candidate, previous: NormalizedPoint?) -> Double {
        let r = candidate.rect
        let size = sqrt(max(1e-6, r.width * r.height))
        let cx = r.midX
        let cy = r.midY
        let dxCenter = cx - 0.5
        let dyCenter = cy - 0.5
        let distCenter = sqrt(dxCenter * dxCenter + dyCenter * dyCenter)
        let centrality = 1 - min(1, distCenter / 0.7)
        var continuity = 1.0
        if let previous {
            let px = cx - previous.x
            let py = cy - previous.y
            let dist = sqrt(px * px + py * py)
            continuity = 1 - min(1, dist / 0.5)
        }
        let confidence = min(1, max(0, candidate.confidence))
        let a = 0.5 + 0.5 * centrality
        let b = 0.6 + 0.4 * continuity
        let c = 0.5 + 0.5 * confidence
        return size * a * b * c
    }

    /// 注目点: 顔は中心をわずかに下げる(頭上に余白)、人物は上半身あたり
    private static func focusPoint(for candidate: Candidate) -> NormalizedPoint {
        let r = candidate.rect
        if candidate.isFace {
            let y = min(1, r.midY + 0.08)
            return NormalizedPoint(x: r.midX, y: y)
        }
        let y = r.y + r.height * 0.3
        return NormalizedPoint(x: r.midX, y: min(1, max(0, y)))
    }

    /// 3 点の中央値で単発の外れ値を抑える(時刻と確からしさはそのまま)
    private static func medianFiltered(_ samples: [ReframeSample]) -> [ReframeSample] {
        guard samples.count >= 3 else { return samples }
        var result = samples
        for i in 1..<(samples.count - 1) {
            let xs = [samples[i - 1].center.x, samples[i].center.x, samples[i + 1].center.x].sorted()
            let ys = [samples[i - 1].center.y, samples[i].center.y, samples[i + 1].center.y].sorted()
            result[i].center = NormalizedPoint(x: xs[1], y: ys[1])
        }
        return result
    }
}
