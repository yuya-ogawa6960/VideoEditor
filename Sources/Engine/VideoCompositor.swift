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

    init(timeRange: CMTimeRange,
         mainTrackID: CMPersistentTrackID,
         mainTransform: CGAffineTransform,
         angleSegments: [VideoCompositorAngleSegment],
         filter: FilterSettings,
         subtitles: [VideoCompositorSubtitle],
         subtitleStyle: SubtitleStyle,
         scaling: ScalingMode,
         renderSize: CGSize) {
        self.timeRange = timeRange
        self.mainTrackID = mainTrackID
        self.mainTransform = mainTransform
        self.angleSegments = angleSegments
        self.filter = filter
        self.subtitles = subtitles
        self.subtitleStyle = subtitleStyle
        self.scaling = scaling
        self.renderSize = renderSize

        var ids: [CMPersistentTrackID] = [mainTrackID]
        for seg in angleSegments where !ids.contains(seg.trackID) {
            ids.append(seg.trackID)
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
                                   renderSize: renderSize)
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
                let placed = Self.place(image, canvasSize: size, scaling: instruction.scaling)
                frame = placed.composited(over: frame)
            }

            // 字幕
            let seconds = time.seconds
            for subtitle in instruction.subtitles where seconds >= subtitle.start && seconds < subtitle.end {
                if let subImage = SubtitleRenderer.image(lines: subtitle.lines,
                                                         style: instruction.subtitleStyle,
                                                         renderSize: size) {
                    frame = subImage.composited(over: frame)
                }
            }
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
