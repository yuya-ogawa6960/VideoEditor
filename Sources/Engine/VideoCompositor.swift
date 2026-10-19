import Foundation
import AVFoundation
import CoreImage
import CoreVideo

// =====================================================================
// VideoCompositor: カスタム AVVideoCompositing
// プレビュー(AVPlayerItem)と書き出し(AVAssetReaderVideoCompositionOutput)で
// 同じ描画になるよう、全ての処理をここで行う。
// =====================================================================

/// マルチカムのアングル区間(出力タイムライン上)
struct VideoCompositorAngleSegment {
    let timeRange: CMTimeRange
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
}

/// 出力タイムライン上の字幕(表示行は事前計算済み)
struct VideoCompositorSubtitle {
    let start: Double
    let end: Double
    let lines: [String]
}

/// メイン映像の上に重ねる Bロール / ワイプ / 写真(コンポジタ命令に渡すプレーンデータ)
/// 時刻はすべて出力タイムライン上の秒。
struct VideoCompositorOverlay {
    let id: UUID
    /// 動画オーバーレイのコンポジショントラック。写真(または挿入できなかった動画)は nil
    let trackID: CMPersistentTrackID?
    let isImage: Bool
    let url: URL
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let start: Double
    let duration: Double
    let speed: Double
    let sourceStart: Double
    let frame: NormalizedRect
    let fit: OverlayFit
    let opacity: Double
    let cornerRadius: Double
    let kenBurns: KenBurns
    let filter: FilterSettings
    let fadeIn: Double
    let fadeOut: Double

    init(overlay: OverlayClip, trackID: CMPersistentTrackID?, preferredTransform: CGAffineTransform? = nil) {
        self.id = overlay.id
        self.trackID = trackID
        self.isImage = overlay.isImage
        self.url = overlay.url
        self.naturalSize = overlay.naturalSize
        self.preferredTransform = preferredTransform ?? overlay.preferredTransform
        self.start = overlay.start
        self.duration = overlay.duration
        self.speed = max(overlay.speed, 0.01)
        self.sourceStart = overlay.sourceStart
        self.frame = overlay.frame.clamped()
        self.fit = overlay.fit
        self.opacity = min(max(overlay.opacity, 0), 1)
        self.cornerRadius = min(max(overlay.cornerRadius, 0), 0.5)
        self.kenBurns = overlay.kenBurns
        self.filter = overlay.filter
        self.fadeIn = max(0, overlay.fadeIn)
        self.fadeOut = max(0, overlay.fadeOut)
    }

    var end: Double { start + duration }

    /// 動画を描くために必要なソーストラックか(写真は不要)
    var needsSourceFrame: Bool { !isImage && trackID != nil }

    func contains(timelineTime time: Double) -> Bool {
        time >= start && time < end
    }

    func intersects(_ range: CMTimeRange) -> Bool {
        let rs = range.start.seconds
        let re = range.end.seconds
        guard rs.isFinite, re.isFinite else { return true }
        return end > rs && start < re
    }

    /// 進行度 0...1(Ken Burns 用)
    func progress(at time: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max((time - start) / duration, 0), 1)
    }

    /// フェードを含む不透明度(OverlayClip.effectiveOpacity と同じ計算)
    func effectiveOpacity(at time: Double) -> Double {
        guard duration > 0 else { return 0 }
        let local = time - start
        guard local >= 0, local <= duration else { return 0 }
        var factor = 1.0
        if fadeIn > 0, local < fadeIn {
            factor = min(factor, local / fadeIn)
        }
        if fadeOut > 0, duration - local < fadeOut {
            factor = min(factor, (duration - local) / fadeOut)
        }
        return max(0, min(1, factor)) * opacity
    }
}

/// 1クリップ分の描画指示(プレーンデータのみ保持)
final class VideoCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    // AVVideoCompositionInstructionProtocol
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    // 描画情報
    let mainTrackID: CMPersistentTrackID
    let mainTransform: CGAffineTransform
    let angleSegments: [VideoCompositorAngleSegment]
    let filter: FilterSettings
    let subtitles: [VideoCompositorSubtitle]
    let subtitleStyle: SubtitleStyle
    let scaling: ScalingMode
    let renderSize: CGSize
    /// ドキュメンタリー風の仕上げ(作品全体で共通)
    let documentary: DocumentaryRenderInfo
    /// この区間に重なる Bロール / ワイプ / 写真(開始時刻順)
    let mediaOverlays: [VideoCompositorOverlay]

    init(timeRange: CMTimeRange,
         mainTrackID: CMPersistentTrackID,
         mainTransform: CGAffineTransform,
         angleSegments: [VideoCompositorAngleSegment],
         filter: FilterSettings,
         subtitles: [VideoCompositorSubtitle],
         subtitleStyle: SubtitleStyle,
         scaling: ScalingMode,
         renderSize: CGSize,
         documentary: DocumentaryRenderInfo = .empty,
         mediaOverlays: [VideoCompositorOverlay] = []) {
        self.timeRange = timeRange
        self.mainTrackID = mainTrackID
        self.mainTransform = mainTransform
        self.angleSegments = angleSegments
        self.filter = filter
        self.subtitles = subtitles
        self.subtitleStyle = subtitleStyle
        self.scaling = scaling
        self.renderSize = renderSize
        self.documentary = documentary
        self.mediaOverlays = mediaOverlays

        var ids: [CMPersistentTrackID] = [mainTrackID]
        for seg in angleSegments where !ids.contains(seg.trackID) {
            ids.append(seg.trackID)
        }
        for overlay in mediaOverlays {
            if let trackID = overlay.trackID, overlay.intersects(timeRange), !ids.contains(trackID) {
                ids.append(trackID)
            }
        }
        self.requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
        super.init()
    }

    /// 同じ内容で timeRange だけ差し替えたコピー
    func withTimeRange(_ newRange: CMTimeRange) -> VideoCompositorInstruction {
        VideoCompositorInstruction(timeRange: newRange,
                                   mainTrackID: mainTrackID,
                                   mainTransform: mainTransform,
                                   angleSegments: angleSegments,
                                   filter: filter,
                                   subtitles: subtitles,
                                   subtitleStyle: subtitleStyle,
                                   scaling: scaling,
                                   renderSize: renderSize,
                                   documentary: documentary,
                                   mediaOverlays: mediaOverlays)
    }

    /// 同じ内容でドキュメンタリー情報だけ差し替えたコピー
    func withDocumentary(_ info: DocumentaryRenderInfo) -> VideoCompositorInstruction {
        VideoCompositorInstruction(timeRange: timeRange,
                                   mainTrackID: mainTrackID,
                                   mainTransform: mainTransform,
                                   angleSegments: angleSegments,
                                   filter: filter,
                                   subtitles: subtitles,
                                   subtitleStyle: subtitleStyle,
                                   scaling: scaling,
                                   renderSize: renderSize,
                                   documentary: info,
                                   mediaOverlays: mediaOverlays)
    }

    /// 同じ内容でオーバーレイだけ差し替えたコピー(この区間に重なるものだけを保持する)
    func withMediaOverlays(_ overlays: [VideoCompositorOverlay]) -> VideoCompositorInstruction {
        let relevant = overlays.filter { $0.intersects(timeRange) }
        return VideoCompositorInstruction(timeRange: timeRange,
                                          mainTrackID: mainTrackID,
                                          mainTransform: mainTransform,
                                          angleSegments: angleSegments,
                                          filter: filter,
                                          subtitles: subtitles,
                                          subtitleStyle: subtitleStyle,
                                          scaling: scaling,
                                          renderSize: renderSize,
                                          documentary: documentary,
                                          mediaOverlays: relevant)
    }

    func angleSegment(at time: CMTime) -> VideoCompositorAngleSegment? {
        for seg in angleSegments where seg.timeRange.containsTime(time) {
            return seg
        }
        return nil
    }
}

enum VideoCompositorError: Error {
    case noOutputBuffer
}

final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    private let renderQueue = DispatchQueue(label: "VideoEditor.VideoCompositor.render", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: Int = 0

    override init() {
        super.init()
    }

    // MARK: AVVideoCompositing

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // 出力バッファは各リクエストの renderContext から取得するので保持不要
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let request = asyncVideoCompositionRequest
        let requestGeneration = currentGeneration()
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            if requestGeneration != self.currentGeneration() {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                do {
                    let buffer = try self.render(request)
                    request.finish(withComposedVideoFrame: buffer)
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    // MARK: 描画

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else {
            throw VideoCompositorError.noOutputBuffer
        }
        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)
        var frame = CIImage(color: CIColor.black).cropped(to: canvas)

        if let instruction = request.videoCompositionInstruction as? VideoCompositorInstruction {
            let time = request.compositionTime
            let seconds = time.seconds
            let documentary = instruction.documentary

            // ソース選択: アングル区間ならアングルトラック、フレームが無ければメインにフォールバック
            var sourceBuffer: CVPixelBuffer? = nil
            var transform = instruction.mainTransform
            if let segment = instruction.angleSegment(at: time),
               let angleBuffer = request.sourceFrame(byTrackID: segment.trackID) {
                sourceBuffer = angleBuffer
                transform = segment.transform
            }
            if sourceBuffer == nil {
                sourceBuffer = request.sourceFrame(byTrackID: instruction.mainTrackID)
                transform = instruction.mainTransform
            }

            if let sourceBuffer {
                var image = CIImage(cvPixelBuffer: sourceBuffer)
                image = Self.oriented(image, transform: transform)
                image = FilterEngine.apply(instruction.filter, to: image)
                var placed = Self.place(image, canvasSize: size, scaling: instruction.scaling)
                // 全体のルック(余白は透明のままなので黒帯は黒のまま)
                placed = DocumentaryRenderer.applyLook(placed, info: documentary)
                frame = placed.composited(over: frame)
            }

            // Bロール / ワイプ / 写真(メイン映像とルックの後、質感・テロップ・字幕・黒帯・フェードの前)
            if !instruction.mediaOverlays.isEmpty {
                frame = OverlayRenderer.draw(instruction.mediaOverlays,
                                             over: frame,
                                             time: seconds,
                                             request: request,
                                             canvasSize: size)
            }

            // 周辺減光 → フィルム粒子 → 章タイトル / テロップ
            frame = DocumentaryRenderer.applyTexture(frame, time: seconds, info: documentary, canvasSize: size)
            frame = DocumentaryRenderer.applyOverlays(frame, time: seconds, info: documentary, canvasSize: size)

            // 字幕(シネスコ黒帯があるときは映像部分の内側へずらす)
            let bar = DocumentaryRenderer.letterboxBarHeight(canvasSize: size, style: documentary.style)
            for subtitle in instruction.subtitles where seconds >= subtitle.start && seconds < subtitle.end {
                if var subImage = SubtitleRenderer.image(lines: subtitle.lines,
                                                         style: instruction.subtitleStyle,
                                                         renderSize: size) {
                    if bar > 0 {
                        switch instruction.subtitleStyle.position {
                        case .bottom:
                            subImage = subImage.transformed(by: CGAffineTransform(translationX: 0, y: bar))
                        case .top:
                            subImage = subImage.transformed(by: CGAffineTransform(translationX: 0, y: -bar))
                        case .center:
                            break
                        }
                    }
                    frame = subImage.composited(over: frame)
                }
            }

            // シネスコ黒帯 → 黒フェード
            frame = DocumentaryRenderer.applyFinish(frame, time: seconds, info: documentary, canvasSize: size)
        }

        frame = frame.cropped(to: canvas)
        FilterEngineContexts.current.render(frame, to: output, bounds: canvas,
                                            colorSpace: FilterEngineContexts.colorSpace)
        return output
    }

    /// preferredTransform(UIKit 座標系 = 左上原点)を CoreImage 座標系(左下原点)で適用し、原点を (0,0) に揃える
    static func oriented(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        if transform.isIdentity { return image }
        let extent = image.extent
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        let combined = flipIn.concatenating(transform).concatenating(flipOut)
        let transformed = image.transformed(by: combined)
        let e = transformed.extent
        return transformed.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    /// キャンバスへの配置(fit: 黒帯 / fitBlur: ぼかし背景 / fill: 中央クロップ)
    static func place(_ image: CIImage, canvasSize: CGSize, scaling: ScalingMode) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return CIImage.empty() }

        let fitScale = min(canvasSize.width / extent.width, canvasSize.height / extent.height)
        let fillScale = max(canvasSize.width / extent.width, canvasSize.height / extent.height)

        func scaledCentered(_ scale: CGFloat) -> CIImage {
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let e = scaled.extent
            let dx = (canvasSize.width - e.width) / 2 - e.origin.x
            let dy = (canvasSize.height - e.height) / 2 - e.origin.y
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }

        switch scaling {
        case .fit:
            return scaledCentered(fitScale).cropped(to: canvas)
        case .fill:
            return scaledCentered(fillScale).cropped(to: canvas)
        case .fitBlur:
            let foreground = scaledCentered(fitScale).cropped(to: canvas)
            // 縦横比が同じなら背景は不要
            if abs(fitScale - fillScale) < 0.0001 { return foreground }
            let sigma = Double(max(canvasSize.width, canvasSize.height)) * 0.025
            let background = scaledCentered(fillScale)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: NSNumber(value: -0.08),
                    kCIInputContrastKey: NSNumber(value: 1.0),
                    kCIInputSaturationKey: NSNumber(value: 1.0)
                ])
                .cropped(to: canvas)
            return foreground.composited(over: background)
        }
    }
}
