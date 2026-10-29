import Foundation
import CoreImage
import CoreGraphics

// =====================================================================
// メインクリップのキーフレームの描画(VideoCompositor.renderLayer の配置のあと)。
// キャンバスの中心まわりに 大きさ → 回転 → 位置 の順でかけ、不透明度で薄くする。
// 「ぼかし」背景のときは、背景は動かさず、前の映像だけを動かす(背景ごと動くと端が黒くなるため)。
// =====================================================================

enum ClipKeyframeRenderer {

    /// 位置・大きさ・回転が動いていないか
    static func isStill(_ value: KeyframeInterpolator.Value) -> Bool {
        abs(value.center.x - 0.5) < 0.0001 && abs(value.center.y - 0.5) < 0.0001
            && abs(value.scale - 1) < 0.0001 && abs(value.rotation) < 0.001
    }

    /// キャンバス(CoreImage の左下原点)の中で動かす変換
    static func transform(for value: KeyframeInterpolator.Value, canvasSize: CGSize) -> CGAffineTransform {
        let w = canvasSize.width
        let h = canvasSize.height
        let cx = w / 2
        let cy = h / 2
        // 位置は左上が 0(上へ動かすと y が小さくなる)。CoreImage は下が 0 なので y を反転する
        let dx = CGFloat(value.center.x - 0.5) * w
        let dy = -CGFloat(value.center.y - 0.5) * h
        let scale = CGFloat(value.scale.isFinite ? min(max(value.scale, 0.01), 20) : 1)
        // 時計回りが正(CoreImage の角度は反時計回りが正)
        let angle = -CGFloat(value.rotation.isFinite ? value.rotation : 0) * .pi / 180
        var t = CGAffineTransform(translationX: -cx, y: -cy)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(rotationAngle: angle))
        t = t.concatenating(CGAffineTransform(translationX: cx + dx, y: cy + dy))
        return t
    }

    /// placed: 配置済み(キャンバス大)の映像。source: 配置前の映像(ぼかし背景を作り直すときに使う)
    static func apply(_ value: KeyframeInterpolator.Value,
                      to placed: CIImage,
                      source: CIImage,
                      blurBackground: Bool,
                      canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let moves = !isStill(value)
        var result = placed
        if moves {
            let t = transform(for: value, canvasSize: canvasSize)
            if blurBackground, let background = blurredBackground(source, canvasSize: canvasSize) {
                let foreground = VideoCompositor.place(source, canvasSize: canvasSize, scaling: .fit)
                    .transformed(by: t)
                result = foreground.composited(over: background)
            } else {
                result = placed.transformed(by: t)
            }
        }
        result = GeometryMath.withAlpha(result, value.opacity.isFinite ? value.opacity : 1)
        return result.cropped(to: canvas)
    }

    /// 「ぼかし」配置の背景だけ(VideoCompositor.place の fitBlur と同じ作り方)。縦横比が同じなら nil
    static func blurredBackground(_ image: CIImage, canvasSize: CGSize) -> CIImage? {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let fitScale = min(canvasSize.width / extent.width, canvasSize.height / extent.height)
        let fillScale = max(canvasSize.width / extent.width, canvasSize.height / extent.height)
        if abs(fitScale - fillScale) < 0.0001 { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let e = scaled.extent
        let dx = (canvasSize.width - e.width) / 2 - e.origin.x
        let dy = (canvasSize.height - e.height) / 2 - e.origin.y
        let sigma = Double(max(canvasSize.width, canvasSize.height)) * 0.025
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: NSNumber(value: -0.08),
                kCIInputContrastKey: NSNumber(value: 1.0),
                kCIInputSaturationKey: NSNumber(value: 1.0)
            ])
            .cropped(to: canvas)
    }
}
