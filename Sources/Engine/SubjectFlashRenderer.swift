import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision

// =====================================================================
// SubjectFlashRenderer: 人物・被写体だけパッと光らせる(SubjectFlash)と、
// トランジションの「白飛びフラッシュ」の明るく飛ばす処理。
// 切り抜きは光っている間のコマだけ Vision で作る(人物: 人物の切り抜き、被写体: 前景の切り抜き)。
// VideoCompositor の描画キューから同期で呼ばれる。切り抜けなかったときは元の画像のまま返す。
// =====================================================================

enum SubjectFlashRenderer {

    /// 明るく白っぽく飛ばした画像(色は少し残して鮮やかにする)。strength 0 ... 1
    static func overexposed(_ image: CIImage, strength: Double) -> CIImage {
        let s = min(max(strength, 0), 1)
        guard s > 0.001 else { return image }
        return image
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: NSNumber(value: 2.4 * s)])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: NSNumber(value: 1 + 0.35 * s),
                kCIInputBrightnessKey: NSNumber(value: 0.06 * s),
                kCIInputContrastKey: NSNumber(value: 1.0)
            ])
    }

    /// placed(キャンバス大、余白は透明)の被写体だけを amount(0 ... 1)だけ光らせる
    static func apply(_ flash: SubjectFlash, amount: Double, to placed: CIImage, canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        guard amount > 0.001, canvas.width >= 2, canvas.height >= 2,
              let mask = subjectMask(for: flash, image: placed, canvas: canvas) else { return placed }

        // 被写体を明るく飛ばす
        let bright = overexposed(placed, strength: amount).cropped(to: canvas)
        var result = bright.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: placed,
            kCIInputMaskImageKey: mask
        ]).cropped(to: canvas)

        // まわりに光のふち(切り抜きをぼかして、温かい白をスクリーンで重ねる)
        if flash.glow {
            let sigma = Double(min(canvas.width, canvas.height)) * 0.025
            let halo = mask.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: canvas)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(0.85 * amount), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: CGFloat(0.85 * amount), y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: CGFloat(0.85 * amount), y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
            let warm = CIImage(color: CIColor(red: 1, green: 0.96, blue: 0.88)).cropped(to: canvas)
            let clear = CIImage(color: CIColor.clear).cropped(to: canvas)
            let glowLayer = warm.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: halo
            ])
            result = glowLayer.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: result
            ]).cropped(to: canvas)
        }
        return result
    }

    // MARK: - 切り抜き

    /// 光らせる部分(キャンバス大、白 = 被写体)。見つからなければ nil(切り抜きは SegmentationMasks.swift)
    private static func subjectMask(for flash: SubjectFlash, image: CIImage, canvas: CGRect) -> CIImage? {
        // 透明な余白は黒にしてから渡す
        let input = image.composited(over: CIImage(color: CIColor.black).cropped(to: canvas)).cropped(to: canvas)
        let kind: SegmentationMasks.Kind
        switch flash.target {
        case .person:
            kind = .person(accurate: false)
        case .subject:
            kind = .foreground(point: nil)
        case .tapped:
            kind = .foreground(point: flash.point)
        }
        return SegmentationMasks.mask(for: input, in: canvas, kind: kind)
    }
}
