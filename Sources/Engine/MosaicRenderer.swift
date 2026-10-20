import Foundation
import CoreImage
import CoreGraphics

// =====================================================================
// モザイク / ぼかしの描画(VideoCompositor から、映像とオーバーレイを重ねた直後に呼ぶ)。
// テキスト・字幕・透かしはこの後に重なるので、モザイクはかからない。
// =====================================================================

enum MosaicRenderer {
    /// 時刻 time に表示中のモザイクを frame にかける
    static func apply(_ clips: [TextClip], to frame: CIImage, time: Double, canvasSize: CGSize) -> CIImage {
        guard canvasSize.width >= 2, canvasSize.height >= 2 else { return frame }
        var result = frame
        for clip in clips where clip.isMosaic && clip.contains(timelineTime: time) {
            result = applyOne(clip, to: result, time: time, canvasSize: canvasSize)
        }
        return result
    }

    private static func applyOne(_ clip: TextClip, to frame: CIImage, time: Double, canvasSize: CGSize) -> CIImage {
        guard let style = clip.mosaic, let topLeftRect = clip.mosaicRect(at: time, in: canvasSize) else { return frame }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        // CoreImage は左下原点
        let rect = CGRect(x: topLeftRect.minX,
                          y: canvasSize.height - topLeftRect.maxY,
                          width: topLeftRect.width,
                          height: topLeftRect.height)
        guard rect.width >= 1, rect.height >= 1, rect.intersects(canvas) else { return frame }

        let shortSide: CGFloat = min(canvasSize.width, canvasSize.height)
        let strength: CGFloat = CGFloat(GeometryMath.clamp(style.strength, 0, 1))
        let source = frame.clampedToExtent()
        let effect: CIImage
        switch style.kind {
        case .pixelate:
            let block: CGFloat = max(4, shortSide * (0.012 + 0.05 * strength))
            effect = source.applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                kCIInputScaleKey: block
            ])
        case .blur:
            let radius: CGFloat = max(2, shortSide * (0.01 + 0.045 * strength))
            effect = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        }

        switch style.shape {
        case .rectangle:
            return effect.cropped(to: rect.intersection(canvas)).composited(over: frame)
        case .ellipse:
            // 半径 100 の円のグラデーション(内側が白)を、範囲の楕円に引き伸ばしてマスクにする
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": 96,
                "inputRadius1": 100,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black
            ])?.outputImage else {
                return effect.cropped(to: rect.intersection(canvas)).composited(over: frame)
            }
            let mask = gradient
                .transformed(by: CGAffineTransform(scaleX: rect.width / 200, y: rect.height / 200))
                .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
                .cropped(to: canvas)
            return effect.cropped(to: canvas).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: frame,
                kCIInputMaskImageKey: mask
            ])
        }
    }
}
