import Foundation
import CoreGraphics
import CoreImage

// =====================================================================
// EnhanceFilters: 画質補正(ClipEnhancements → CoreImage)
//
// - denoise(ノイズ除去): CINoiseReduction(noiseLevel 0.02 × d、sharpness 0.4)。フィルタより前に掛ける
// - retouch(美肌): 顔検出をしない近似。肌色(色相 5°〜45°・彩度 0.15〜0.75・ある程度の明るさ)の
//   マスクを CIColorCube で作り、ぼかした画像(σ = 3 + 5r)をそのマスク × (r × 0.8) で重ねる。
//   髪や背景の肌色に近い部分も少しなめらかになるが、毎フレームの顔検出より軽く、
//   プレビューと書き出しで同じ結果になる。フィルタより前に掛ける
// - sharpenUpscale(簡易高画質化): キャンバスに配置した後に掛ける。元素材がキャンバスより小さい
//   (拡大された)ときは CIUnsharpMask(半径 2.5、強さ 0.3 + 0.7s)、そうでなければ弱い CISharpenLuminance
// =====================================================================

enum EnhanceFilters {

    // MARK: - 公開 API

    /// フィルタより前に掛ける補正(ノイズ除去 → 美肌)
    static func applyPreFilters(_ enhance: ClipEnhancements, to image: CIImage) -> CIImage {
        var out = image
        if enhance.denoise > 0.001 {
            out = denoise(out, amount: enhance.denoise)
        }
        if enhance.retouch > 0.001 {
            out = retouch(out, amount: enhance.retouch)
        }
        return out
    }

    /// 映像のノイズ除去 0...1
    static func denoise(_ image: CIImage, amount: Double) -> CIImage {
        let d = GeometryMath.clamp(amount, 0, 1)
        guard d > 0.001 else { return image }
        let extent = image.extent
        let out = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": NSNumber(value: 0.02 * d),
            "inputSharpness": NSNumber(value: 0.4)
        ])
        return cropped(out, to: extent)
    }

    /// 美肌 0...1(肌色マスク × ぼかし)
    static func retouch(_ image: CIImage, amount: Double) -> CIImage {
        let r = GeometryMath.clamp(amount, 0, 1)
        guard r > 0.001 else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        let sigma = 3 + 5 * r
        let smooth = GeometryMath.blurred(image, sigma: sigma)
        var mask = skinMask(for: image)
        mask = GeometryMath.blurred(mask, sigma: 2)
        mask = GeometryMath.withAlpha(mask, r * 0.8)
        let out = smooth.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ])
        return cropped(out, to: extent)
    }

    /// 簡易高画質化 0...1。upscaled = 元素材がキャンバスより小さく拡大されたとき
    static func sharpen(_ image: CIImage, amount: Double, upscaled: Bool) -> CIImage {
        let s = GeometryMath.clamp(amount, 0, 1)
        guard s > 0.001 else { return image }
        let extent = image.extent
        let out: CIImage
        if upscaled {
            out = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: NSNumber(value: 2.5),
                kCIInputIntensityKey: NSNumber(value: 0.3 + 0.7 * s)
            ])
        } else {
            out = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: NSNumber(value: 0.5 * s)
            ])
        }
        return cropped(out, to: extent)
    }

    /// 肌色らしさ(0 = 違う、1 = 肌色)のグレースケール画像。白 × アルファ(premultiplied)
    static func skinMask(for image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": NSNumber(value: skinCubeDimension),
            "inputCubeData": skinCubeData
        ])
    }

    // MARK: - 内部

    private static func cropped(_ image: CIImage, to extent: CGRect) -> CIImage {
        if extent.isInfinite || extent.isEmpty { return image }
        return image.cropped(to: extent)
    }

    private static let skinCubeDimension = 32

    /// 肌色マスク用の 3D LUT(一度だけ生成)
    private static let skinCubeData: Data = makeSkinCube(dimension: skinCubeDimension)

    private static func makeSkinCube(dimension n: Int) -> Data {
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        let denominator = Double(max(1, n - 1))
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Double(r) / denominator
                    let gf = Double(g) / denominator
                    let bf = Double(b) / denominator
                    let w = Float(skinWeight(r: rf, g: gf, b: bf))
                    cube[i] = w
                    cube[i + 1] = w
                    cube[i + 2] = w
                    cube[i + 3] = w
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 色相 5°〜45°、彩度 0.15〜0.75、明るさ 0.15 以上をなだらかに 1 にする
    private static func skinWeight(r: Double, g: Double, b: Double) -> Double {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        guard maxC > 0.1, delta > 0.001 else { return 0 }
        let sat = delta / maxC
        var hue: Double
        if maxC == r {
            hue = (g - b) / delta
        } else if maxC == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue = hue * 60
        if hue < 0 { hue += 360 }
        if hue > 300 { hue -= 360 }   // 赤寄り(357° など)を -3° として扱う
        let hueWeight = window(hue, lower: 5, upper: 45, soft: 8)
        let satWeight = window(sat, lower: 0.15, upper: 0.75, soft: 0.08)
        let valueWeight = GeometryMath.smoothstep((maxC - 0.15) / 0.2)
        return hueWeight * satWeight * valueWeight
    }

    /// lower...upper で 1、その外側 soft 幅でなだらかに 0
    private static func window(_ x: Double, lower: Double, upper: Double, soft: Double) -> Double {
        let rise = GeometryMath.smoothstep((x - (lower - soft)) / (2 * soft))
        let fall = 1 - GeometryMath.smoothstep((x - (upper - soft)) / (2 * soft))
        return rise * fall
    }
}
