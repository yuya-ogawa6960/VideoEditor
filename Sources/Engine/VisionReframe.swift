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
//
// CompositedFrameReader: 合成後(プレビュー・書き出しと同じ VideoCompositor)のコマを読む。
//   顔モザイクとトラッキングは「実際に見えている映像」で探して追う(座標はキャンバス、時刻は出力タイムライン)。
// ClipGeometryMapping / ClipCanvasMapping: 元の絵の点が、クリップの加工・配置のあとでどこに映るか(合成と同じ順)。
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

// MARK: - 合成後のコマ読み出し(顔モザイク・トラッキング)

/// 合成後のコマ(見えているとおりの映像)を読む。クリップの拡大・切り抜き・反転・回転・リフレーム・キーフレーム・
/// 並べた枠・マルチカメラのアングル・重ねた素材(V2 以上)がすべて入った絵なので、元の素材の座標から置き直す必要がない。
/// 座標はキャンバスの正規化座標(左上原点)、時刻は出力タイムライン上の秒
enum CompositedFrameReader {
    /// 映像だけの状態(文字・ステッカー・モザイク・字幕・手書き・章タイトル・テロップ・透かし・ナレーションを外す)。
    /// 上に重ねた文字で顔や物を見失わないように、また、すでにあるモザイクで顔が隠れて見つからなくならないように
    static func videoOnly(_ snapshot: ProjectSnapshot) -> ProjectSnapshot {
        var s = snapshot
        s.textClips = []
        s.subtitles = []
        s.drawings = []
        s.titleCards = []
        s.lowerThirds = []
        s.narration = []
        s.watermark = WatermarkSettings()
        return s
    }

    /// プレビューの大きさで合成を組み立てる
    static func build(_ snapshot: ProjectSnapshot) async throws -> BuiltComposition {
        try await CompositionBuilder.build(snapshot, purpose: .preview)
    }

    /// time(出力上の秒)の合成後のコマ
    static func image(of built: BuiltComposition, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let total = built.duration.seconds
        var seconds = max(0, time)
        if total.isFinite, total > 0.1 {
            seconds = min(seconds, total - 0.05)
        }
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// [start, end](出力上の秒)の合成後のコマを約 fps コマ/秒で順に渡す(BGRA、キャンバスの大きさ)。
    /// handler(buffer, 出力上の秒) が false を返すと中断する(エラーにはならない)。呼び出し側 Task のキャンセルで止める
    static func readFrames(of built: BuiltComposition, start: Double, end: Double, fps: Double,
                           handler: @escaping (CVPixelBuffer, Double) -> Bool) async throws {
        let asset: AVAsset = built.composition
        let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw VisionAnalysisError.noVideoTrack }
        let total = built.duration.seconds
        let rangeStart = max(0, min(start, end))
        var rangeEnd = max(start, end)
        if total.isFinite, total > 0 { rangeEnd = min(rangeEnd, total) }
        guard rangeEnd - rangeStart > 0.02 else { throw VisionAnalysisError.invalidRange }
        try Task.checkCancellation()

        // 1 秒に fps コマだけ合成させる(作品のコマ数のまま全部合成すると時間がかかる)
        var videoComposition: AVVideoComposition = built.videoComposition
        if fps > 0, let copy = built.videoComposition.mutableCopy() as? AVMutableVideoComposition {
            let rate = Int32(min(max(fps.rounded(), 1), 60))
            copy.frameDuration = CMTime(value: 1, timescale: rate)
            videoComposition = copy
        }
        let finalComposition = videoComposition
        let readEnd = rangeEnd
        let flag = MediaToolsCancelFlag()
        let work = Task.detached(priority: .userInitiated) {
            try CompositedFrameReader.readBlocking(asset: asset, tracks: tracks, videoComposition: finalComposition,
                                                   start: rangeStart, end: readEnd, fps: fps, flag: flag,
                                                   handler: handler)
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            flag.cancel()
            work.cancel()
        }
    }

    private static func readBlocking(asset: AVAsset, tracks: [AVAssetTrack], videoComposition: AVVideoComposition,
                                     start: Double, end: Double, fps: Double, flag: MediaToolsCancelFlag,
                                     handler: (CVPixelBuffer, Double) -> Bool) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VisionAnalysisError.readFailed(error.localizedDescription)
        }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VisionAnalysisError.readFailed(String(localized: "映像出力を追加できません")) }
        reader.add(output)
        guard reader.startReading() else {
            throw VisionAnalysisError.readFailed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
        }

        let interval: Double = fps > 0 ? 1.0 / fps : 0
        var nextTime = start - 1
        var delivered = 0
        while let sample = output.copyNextSampleBuffer() {
            if flag.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            if interval > 0, pts < nextTime { continue }
            nextTime = pts + interval - 0.004
            delivered += 1
            // 解析中の画面に「AI が見ているコマ」として出す
            AnalysisPeek.shared.post(buffer)
            if !handler(buffer, pts) {
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
}

// MARK: - 元の絵 → 加工・配置のあとの位置

/// 元の絵(向き反映済み、左上原点の正規化)の点を、ClipGeometry(90° 回転 → 反転 → 切り抜き → ズーム・位置)の
/// あとの絵の正規化座標に移す(GeometryMath.applyClipGeometry と同じ順。整数への丸めは見ない)。外に出た点も丸めない
enum ClipGeometryMapping {
    static func point(_ p: NormalizedPoint, geometry g: ClipGeometry) -> NormalizedPoint {
        if g.isIdentity { return p }
        var x = p.x
        var y = p.y
        // 1. 90 度単位の回転(時計回り): (x, y) → (1 - y, x)
        let turns = ((g.rotationQuarterTurns % 4) + 4) % 4
        if turns > 0 {
            for _ in 0..<turns {
                let nx = 1 - y
                let ny = x
                x = nx
                y = ny
            }
        }
        // 2. 反転
        if g.flipHorizontal { x = 1 - x }
        if g.flipVertical { y = 1 - y }
        // 3. 切り抜き
        let crop = g.crop.clamped()
        if !crop.isFull {
            x = (x - crop.x) / max(crop.width, 0.0001)
            y = (y - crop.y) / max(crop.height, 0.0001)
        }
        // 4. ズーム・位置(見える範囲は 1/zoom、中心は 0.5 + offset で、範囲の中に収める)
        let zoom = GeometryMath.clamp(g.zoom, 1, 8)
        let ox = GeometryMath.clamp(g.offsetX, -0.5, 0.5)
        let oy = GeometryMath.clamp(g.offsetY, -0.5, 0.5)
        if zoom > 1.0001 || ox != 0 || oy != 0 {
            let visible = 1 / zoom
            let x0 = min(max(0.5 + ox - visible / 2, 0), max(0, 1 - visible))
            let y0 = min(max(0.5 + oy - visible / 2, 0), max(0, 1 - visible))
            x = (x - x0) * zoom
            y = (y - y0) * zoom
        }
        return NormalizedPoint(x: x, y: y)
    }
}

/// メインのクリップの元の絵(向き反映済み、左上原点の正規化)→ キャンバス(左上原点の正規化)の変換。
/// VideoCompositor.renderLayer と同じ順: 回転・反転・切り抜き・ズーム → オートリフレームの窓 → 置き場所(収め方・並べた枠)
/// → クリップのキーフレーム。手ぶれ補正の小さな動き・リフレームのなめらかな追従の遅れ・イン/アウトの動きは入れない。
/// マルチカメラで別のカメラに切り替えている所は、そのカメラの絵の大きさで考える(リフレームはかけない。合成と同じ)
enum ClipCanvasMapping {
    static func transform(clip: Clip, sourceTime: Double, canvasSize: CGSize, scaling: ScalingMode) -> CGAffineTransform {
        let canvasW = max(Double(canvasSize.width), 1)
        let canvasH = max(Double(canvasSize.height), 1)
        let g = clip.geometry
        var size = clip.displaySize
        var usesAngle = false
        if clip.multicam.isActive {
            let index = clip.multicam.angleIndex(at: sourceTime)
            if index > 0, index <= clip.multicam.angles.count {
                size = clip.multicam.angles[index - 1].displaySize
                usesAngle = true
            }
        }
        var w = Double(size.width)
        var h = Double(size.height)
        guard w >= 1, h >= 1 else { return .identity }
        // 正規化 → ピクセル(左上原点)
        var t = CGAffineTransform(scaleX: CGFloat(w), y: CGFloat(h))
        if !g.isIdentity {
            // 90 度単位の回転(時計回り): (x, y) → (h - y, x)。大きさは入れ替わる
            let turns = ((g.rotationQuarterTurns % 4) + 4) % 4
            if turns > 0 {
                for _ in 0..<turns {
                    t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0))
                    swap(&w, &h)
                }
            }
            if g.flipHorizontal {
                t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(w), ty: 0))
            }
            if g.flipVertical {
                t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h)))
            }
            let crop = g.crop.clamped()
            if !crop.isFull {
                t = t.concatenating(CGAffineTransform(translationX: CGFloat(-crop.x * w), y: CGFloat(-crop.y * h)))
                w *= crop.width
                h *= crop.height
            }
            let zoom = GeometryMath.clamp(g.zoom, 1, 8)
            let ox = GeometryMath.clamp(g.offsetX, -0.5, 0.5)
            let oy = GeometryMath.clamp(g.offsetY, -0.5, 0.5)
            if zoom > 1.0001 || ox != 0 || oy != 0 {
                let vw = w / zoom
                let vh = h / zoom
                let x0 = min(max((0.5 + ox) * w - vw / 2, 0), max(0, w - vw))
                let y0 = min(max((0.5 + oy) * h - vh / 2, 0), max(0, h - vh))
                t = t.concatenating(CGAffineTransform(translationX: CGFloat(-x0), y: CGFloat(-y0)))
                w = vw
                h = vh
            }
        }
        // 置き場所(V2 と並べたときは画面の一部を埋める)
        let pane = g.canvasFrame
        var paneX = 0.0
        var paneY = 0.0
        var paneW = canvasW
        var paneH = canvasH
        var placeScaling = scaling
        if !pane.isFull {
            let x0 = max(pane.x, 0) * canvasW
            let x1 = min(pane.maxX, 1) * canvasW
            let y0 = max(pane.y, 0) * canvasH
            let y1 = min(pane.maxY, 1) * canvasH
            paneX = x0
            paneY = y0
            paneW = max(x1 - x0, 1)
            paneH = max(y1 - y0, 1)
            placeScaling = .fill
        }
        // オートリフレームの窓(合成と同じ条件。窓は「埋める」で置く)
        if !clip.isStill, !usesAngle, clip.reframe.isActive {
            let canvasAspect = paneW / paneH
            let imageAspect = w / h
            let aspectDiffers = abs(canvasAspect - imageAspect) / imageAspect > 0.02
            if placeScaling == .fill || aspectDiffers {
                let zoom = GeometryMath.clamp(clip.reframe.zoom, 1, 4)
                var cropW: Double
                var cropH: Double
                if imageAspect > canvasAspect {
                    cropH = h
                    cropW = cropH * canvasAspect
                } else {
                    cropW = w
                    cropH = cropW / canvasAspect
                }
                cropW = max(2, cropW / zoom)
                cropH = max(2, cropH / zoom)
                let target = ClipGeometryMapping.point(clip.reframe.center(at: sourceTime), geometry: g)
                var cx = GeometryMath.clamp(target.x, 0, 1) * w
                var cy = GeometryMath.clamp(target.y, 0, 1) * h
                cx = min(max(cx, cropW / 2), w - cropW / 2)
                cy = min(max(cy, cropH / 2), h - cropH / 2)
                t = t.concatenating(CGAffineTransform(translationX: CGFloat(-(cx - cropW / 2)), y: CGFloat(-(cy - cropH / 2))))
                w = cropW
                h = cropH
                placeScaling = .fill
            }
        }
        // 置く(収める・ぼかしは内接、拡大は外接。中央に)
        let sx = paneW / w
        let sy = paneH / h
        let s = placeScaling == .fill ? max(sx, sy) : min(sx, sy)
        t = t.concatenating(CGAffineTransform(translationX: CGFloat(-w / 2), y: CGFloat(-h / 2)))
        t = t.concatenating(CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s)))
        t = t.concatenating(CGAffineTransform(translationX: CGFloat(paneX + paneW / 2), y: CGFloat(paneY + paneH / 2)))
        // クリップのキーフレーム(キャンバスの中心まわりに 大きさ → 回転 → 位置。ClipKeyframeRenderer と同じ)
        if !clip.keyframes.isEmpty {
            let v = clip.keyframeValue(atSourceTime: sourceTime)
            if !ClipKeyframeRenderer.isStill(v) {
                let scale = v.scale.isFinite ? min(max(v.scale, 0.01), 20) : 1
                let angle = (v.rotation.isFinite ? v.rotation : 0) * Double.pi / 180
                t = t.concatenating(CGAffineTransform(translationX: CGFloat(-canvasW / 2), y: CGFloat(-canvasH / 2)))
                t = t.concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
                t = t.concatenating(CGAffineTransform(translationX: CGFloat(canvasW / 2 + (v.center.x - 0.5) * canvasW),
                                                      y: CGFloat(canvasH / 2 + (v.center.y - 0.5) * canvasH)))
            }
        }
        // ピクセル → 正規化
        return t.concatenating(CGAffineTransform(scaleX: CGFloat(1 / canvasW), y: CGFloat(1 / canvasH)))
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
        let samples = try await analyzeSamples(url: clip.url, start: clip.startTime, end: clip.endTime,
                                               step: step, progress: progress)
        var track = clip.reframe
        track.enabled = true
        track.samples = samples
        return track
    }

    /// url の [start, end](元素材上の秒)を解析した注目点の軌跡(V2 の顔の追いかけでも使う)
    static func analyzeSamples(url: URL, start: Double, end: Double, step: Double = 0.25,
                               progress: ((Double) -> Void)?) async throws -> [ReframeSample] {
        guard end - start > 0.05 else { throw VisionAnalysisError.invalidRange }
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
        return samples
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
