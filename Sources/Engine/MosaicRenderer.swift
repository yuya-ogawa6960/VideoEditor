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
        guard let style = clip.mosaic,
              let placement = clip.mosaicPlacement(at: time, in: canvasSize) else { return frame }
        let topLeftRect = placement.rect
        let canvas = CGRect(origin: .zero, size: canvasSize)
        // CoreImage は左下原点
        let rect = CGRect(x: topLeftRect.minX,
                          y: canvasSize.height - topLeftRect.maxY,
                          width: topLeftRect.width,
                          height: topLeftRect.height)
        guard rect.width >= 1, rect.height >= 1 else { return frame }

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

        // 形のマスクを原点中心で作り、回転してから範囲の中心へ動かす(回転は時計回りが正)
        let shape: CIImage
        switch style.shape {
        case .rectangle:
            shape = CIImage(color: CIColor.white)
                .cropped(to: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        case .ellipse:
            // 半径 100 の円のグラデーション(内側が白)を楕円に引き伸ばす
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": 96,
                "inputRadius1": 100,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black
            ])?.outputImage else { return frame }
            shape = gradient.transformed(by: CGAffineTransform(scaleX: rect.width / 200, y: rect.height / 200))
        }
        var transform = CGAffineTransform.identity
        let rotation = placement.rotation
        if rotation.isFinite, abs(rotation) > 0.01 {
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(-rotation * Double.pi / 180)))
        }
        transform = transform.concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        let black = CIImage(color: CIColor.black).cropped(to: canvas)
        let mask = shape.transformed(by: transform).composited(over: black).cropped(to: canvas)
        return effect.cropped(to: canvas).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: frame,
            kCIInputMaskImageKey: mask
        ])
    }
}
