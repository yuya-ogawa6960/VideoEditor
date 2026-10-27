import Foundation
import CoreImage
import CoreGraphics

// =====================================================================
// モザイク / ぼかしの描画(VideoCompositor から、元の映像を描いた直後に呼ぶ)。
// オーバーレイ(ワイプ・写真・Bロール)はこの上に重なるので、モザイクはかからない。
// テキスト・字幕・透かしはこの後に重なるので、モザイクはかからない。
// =====================================================================

enum MosaicRenderer {
    /// 時刻 time に表示中のモザイクを frame にかける。
    /// 1 つのモザイクは下の映像を 2 回使う(ぼかす元と、背景)。そのまま重ねると、モザイクが 1 つ増えるごとに
    /// それより前の描画(映像の読み込み・色・オーバーレイ)が倍々にやり直され、数個で書き出しが止まったように
    /// 遅くなっていた。各段を「中間結果」にして 1 回だけ描き、効果もモザイクの範囲の周りだけで計算する
    static func apply(_ clips: [TextClip], to frame: CIImage, time: Double, canvasSize: CGSize) -> CIImage {
        guard canvasSize.width >= 2, canvasSize.height >= 2 else { return frame }
        let active = clips.filter { $0.isMosaic && $0.contains(timelineTime: time) }
        guard !active.isEmpty else { return frame }
        var result = frame.insertingIntermediate(cache: false)
        for clip in active {
            result = applyOne(clip, to: result, time: time, canvasSize: canvasSize).insertingIntermediate(cache: false)
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
        let block: CGFloat = max(4, shortSide * (0.012 + 0.05 * strength))
        let radius: CGFloat = max(2, shortSide * (0.01 + 0.045 * strength))

        // 回転後の範囲を囲む四角(ここだけを描き換える)と、効果の計算に使う少し広い範囲
        let angle = placement.rotation.isFinite ? CGFloat(placement.rotation * Double.pi / 180) : 0
        let boundsWidth = abs(rect.width * cos(angle)) + abs(rect.height * sin(angle))
        let boundsHeight = abs(rect.width * sin(angle)) + abs(rect.height * cos(angle))
        let area = CGRect(x: rect.midX - boundsWidth / 2, y: rect.midY - boundsHeight / 2,
                          width: boundsWidth, height: boundsHeight).intersection(canvas)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return frame }
        let margin: CGFloat = (style.kind == .blur) ? radius * 3 : block * 2
        let region = area.insetBy(dx: -margin, dy: -margin).intersection(canvas)

        let source = frame.cropped(to: region).clampedToExtent()
        let effect: CIImage
        switch style.kind {
        case .pixelate:
            effect = source.applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                kCIInputScaleKey: block
            ])
        case .blur:
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
        let black = CIImage(color: CIColor.black).cropped(to: area)
        let mask = shape.transformed(by: transform).composited(over: black).cropped(to: area)
        let patch = effect.cropped(to: area).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: frame.cropped(to: area),
            kCIInputMaskImageKey: mask
        ]).cropped(to: area)
        return patch.composited(over: frame)
    }
}
