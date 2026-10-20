import Foundation
import UIKit
import CoreImage

// =====================================================================
// FilterEngine: FilterSettings → CoreImage 処理
// プレビュー・書き出し(VideoCompositor)とフィルタ一覧のサムネイルで共通利用する。
// 色作りは FilterLUT(手続き生成の 3D LUT)で行うため、サムネイルと動画は同じ見た目になる。
// =====================================================================

/// CIContext を一度だけ生成して共有する(GPU / CPU)。
/// バックグラウンドでは GPU が使えないため CPU (software renderer) に切り替える。
/// ただし iOS 26+ の継続処理で GPU の使用が許可されている間(AppLifecycle.shared.backgroundGPUAllowed)は GPU のまま。
enum FilterEngineContexts {
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// GPU コンテキスト(static let は遅延・スレッドセーフに初期化される)
    static let gpu: CIContext = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false
    ])

    /// CPU コンテキスト(バックグラウンド用)
    static let cpu: CIContext = CIContext(options: [
        .useSoftwareRenderer: true,
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false
    ])

    /// 現在の状態に応じたコンテキスト
    static var current: CIContext {
        let lifecycle = AppLifecycle.shared
        if lifecycle.isInBackground && !lifecycle.backgroundGPUAllowed {
            return cpu
        }
        return gpu
    }
}

enum FilterEngine {

    /// 順序: 読み込んだ LUT(.cube、設定時はプリセットより優先)またはプリセット → 色調整 → HSL
    static func apply(_ settings: FilterSettings, to image: CIImage) -> CIImage {
        if settings.isIdentity { return image }
        let extent = image.extent
        var output = image

        // 1. 読み込んだ LUT(強度でブレンド)。読めないときはプリセットへフォールバック
        var usedFileLUT = false
        if let name = settings.lutFileName, settings.lutIntensity > 0,
           let file = FilterLUT.fileCube(named: name) {
            let graded = FilterLUT.apply(file.data, dimension: file.size, to: image)
            output = blend(original: image, filtered: graded, intensity: settings.lutIntensity)
            usedFileLUT = true
        }

        // 1'. プリセット(LUT。強度で元画像とブレンド)
        if !usedFileLUT && settings.preset != .none && settings.intensity > 0 {
            let filtered = presetImage(settings.preset, image: image)
            output = blend(original: image, filtered: filtered, intensity: settings.intensity)
        }

        // 2. 明るさ / コントラスト / 彩度 → 3. 露出 / 色温度 / ハイライト・シャドウ / シャープネス
        let adj = settings.adjustments
        if !adj.isIdentity {
            output = applyAdjustments(adj, to: output)
        }

        // 4. HSL(色相帯ごと)
        if !settings.hsl.isIdentity, let cube = FilterLUT.hslCube(for: settings.hsl) {
            output = FilterLUT.apply(cube, to: output)
        }

        if extent.isInfinite || extent.isEmpty { return output }
        return output.cropped(to: extent)
    }

    // MARK: - 自動補正 / 色合わせ

    /// CoreImage の自動補正(露出・色かぶり・コントラスト)を適用する
    static func autoEnhance(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let filters = image.autoAdjustmentFilters(options: [
            CIImageAutoAdjustmentOption.enhance: true,
            CIImageAutoAdjustmentOption.redEye: false
        ])
        var output = image
        for filter in filters {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let result = filter.outputImage {
                output = result
            }
        }
        if extent.isInfinite || extent.isEmpty { return output }
        return output.cropped(to: extent)
    }

    /// 参照画像(reference)の平均的な明るさ・彩度・色温度に source を近づける色調整を提案する
    static func suggestedAdjustments(toMatch reference: UIImage, from source: UIImage) -> ColorAdjustments {
        guard let refCG = ScopeAnalyzer.cgImage(from: reference),
              let srcCG = ScopeAnalyzer.cgImage(from: source),
              let ref = ScopeAnalyzer.colorStatistics(refCG),
              let src = ScopeAnalyzer.colorStatistics(srcCG) else {
            return ColorAdjustments()
        }
        var adj = ColorAdjustments()
        adj.brightness = clamp(Double(ref.meanLuma - src.meanLuma) * 0.9, -0.5, 0.5)
        adj.contrast = clamp(Double(ref.lumaStdDev) / max(Double(src.lumaStdDev), 0.02), 0.7, 1.4)
        adj.saturation = clamp(Double(ref.meanSaturation) / max(Double(src.meanSaturation), 0.02), 0.5, 1.6)
        adj.temperature = clamp(Double(ref.warmth - src.warmth) * 3.0, -1, 1)
        return roundedAdjustments(adj)
    }

    /// 画像の平均輝度・コントラスト・彩度から控えめな自動補正値を求める
    static func autoEnhanceAdjustments(for image: UIImage) -> ColorAdjustments {
        guard let cg = ScopeAnalyzer.cgImage(from: image),
              let stats = ScopeAnalyzer.colorStatistics(cg) else {
            return ColorAdjustments()
        }
        var adj = ColorAdjustments()
        let targetLuma: Double = 0.46
        adj.brightness = clamp((targetLuma - Double(stats.meanLuma)) * 0.6, -0.25, 0.25)
        let targetStdDev: Double = 0.21
        adj.contrast = clamp(targetStdDev / max(Double(stats.lumaStdDev), 0.03), 0.9, 1.25)
        let meanSat = Double(stats.meanSaturation)
        if meanSat < 0.22 {
            adj.saturation = clamp(1 + (0.22 - meanSat) * 1.5, 1, 1.3)
        }
        if stats.darkFraction > 0.35 {
            adj.shadows = clamp(Double(stats.darkFraction - 0.35) * 1.2, 0, 0.4)
        }
        if stats.brightFraction > 0.2 {
            adj.highlights = -clamp(Double(stats.brightFraction - 0.2) * 1.5, 0, 0.4)
        }
        return roundedAdjustments(adj)
    }

    /// スライダーで扱いやすいよう 0.01 単位に丸める
    private static func roundedAdjustments(_ adj: ColorAdjustments) -> ColorAdjustments {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var out = adj
        out.brightness = r(adj.brightness)
        out.contrast = r(adj.contrast)
        out.saturation = r(adj.saturation)
        out.exposure = r(adj.exposure)
        out.temperature = r(adj.temperature)
        out.highlights = r(adj.highlights)
        out.shadows = r(adj.shadows)
        out.sharpness = r(adj.sharpness)
        return out
    }

    /// 色調整(ColorAdjustments)だけを適用する。順序: 基本の CIColorControls → 露出 → 色温度
    /// → ハイライト・シャドウ → シャープネス
    static func applyAdjustments(_ adj: ColorAdjustments, to image: CIImage) -> CIImage {
        if adj.isIdentity { return image }
        var output = image

        let highlights = clamp(adj.highlights, -1, 1)
        let shadows = clamp(adj.shadows, -1, 1)

        // 基本: 明るさ / コントラスト / 彩度(正のハイライトは明るさを少し足して表現する)
        let brightness = adj.brightness + 0.05 * max(0, highlights)
        if brightness != 0 || adj.contrast != 1 || adj.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: NSNumber(value: brightness),
                kCIInputContrastKey: NSNumber(value: max(0, adj.contrast)),
                kCIInputSaturationKey: NSNumber(value: max(0, adj.saturation))
            ])
        }

        // 露出(EV)
        if adj.exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: NSNumber(value: clamp(adj.exposure, -4, 4))
            ])
        }

        // 色温度(負で青く、正で暖かく)
        if adj.temperature != 0 {
            let target = 6500 + clamp(adj.temperature, -1, 1) * 2500
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(target), y: 0)
            ])
        }

        // ハイライト(負で明部を抑える: 1 → 0.3)/ シャドウ(正で暗部を持ち上げる)
        if highlights < 0 || shadows != 0 {
            let highlightAmount = 1 - max(0, -highlights) * 0.7
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": NSNumber(value: highlightAmount),
                "inputShadowAmount": NSNumber(value: shadows),
                "inputRadius": NSNumber(value: 0)
            ])
        }

        // シャープネス
        if adj.sharpness > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: NSNumber(value: clamp(adj.sharpness, 0, 1) * 1.5)
            ])
        }
        return output
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, lower), upper)
    }

    /// 作品全体のルック(LookPreset)を適用。intensity 0...1 で元画像とブレンド。
    /// 透明部分(fit 時の余白など)は透明のまま保たれる。
    static func applyLook(_ look: LookPreset, intensity: Double, to image: CIImage) -> CIImage {
        guard look != .none, intensity > 0, let cube = FilterLUT.cube(for: look) else { return image }
        let extent = image.extent
        let graded = FilterLUT.apply(cube, to: image)
        let output = blend(original: image, filtered: graded, intensity: intensity)
        if extent.isInfinite || extent.isEmpty { return output }
        return output.cropped(to: extent)
    }

    /// フィルタ選択 UI 用のサムネイル
    static func preview(_ image: UIImage, settings: FilterSettings) -> UIImage? {
        renderPreview(image) { apply(settings, to: $0) }
    }

    /// ルック選択 UI 用のサムネイル(クリップのフィルタ → ルックの順。書き出しと同じ処理)
    static func previewLook(_ image: UIImage, look: LookPreset, intensity: Double = 1,
                            settings: FilterSettings = FilterSettings()) -> UIImage? {
        renderPreview(image) { input in
            applyLook(look, intensity: intensity, to: apply(settings, to: input))
        }
    }

    /// 「画質」パネル用のサムネイル(ノイズ除去 → 美肌 → フィルタ → 簡易高画質化。コンポジタと同じ順)
    static func previewEnhance(_ image: UIImage, enhance: ClipEnhancements,
                               settings: FilterSettings = FilterSettings()) -> UIImage? {
        renderPreview(image) { input in
            var output = EnhanceFilters.applyPreFilters(enhance, to: input)
            output = apply(settings, to: output)
            if enhance.sharpenUpscale > 0.001 {
                output = EnhanceFilters.sharpen(output, amount: enhance.sharpenUpscale, upscaled: false)
            }
            return output
        }
    }

    /// 「マスク」パネル用のサムネイル(キャンバス比率の画像にマスクを掛ける。外は黒)
    static func previewMask(_ image: UIImage, mask: MaskSettings) -> UIImage? {
        renderPreview(image) { input in
            let extent = input.extent
            guard mask.isActive, !extent.isInfinite, !extent.isEmpty else { return input }
            let black = CIImage(color: CIColor.black).cropped(to: extent)
            return MaskRenderer.apply(mask, to: input, canvasSize: extent.size).composited(over: black)
        }
    }

    // MARK: - 内部

    private static func renderPreview(_ image: UIImage, _ process: (CIImage) -> CIImage) -> UIImage? {
        let input: CIImage
        if let cg = image.cgImage {
            input = CIImage(cgImage: cg).oriented(filterEngineOrientation(image.imageOrientation))
        } else if let ci = image.ciImage {
            input = ci
        } else {
            return nil
        }
        // 原点を (0,0) に揃える
        let normalized = input.transformed(by: CGAffineTransform(translationX: -input.extent.origin.x,
                                                                  y: -input.extent.origin.y))
        let output = process(normalized)
        let rect = normalized.extent
        guard !rect.isEmpty, !rect.isInfinite else { return nil }
        guard let cg = FilterEngineContexts.current.createCGImage(output, from: rect) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    /// intensity 0 = 元画像, 1 = フィルタ後
    private static func blend(original: CIImage, filtered: CIImage, intensity: Double) -> CIImage {
        let t = min(max(intensity, 0), 1)
        if t >= 0.999 { return filtered }
        if t <= 0.001 { return original }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: filtered,
            kCIInputTimeKey: NSNumber(value: t)
        ])
    }

    // MARK: - プリセット

    private static func presetImage(_ preset: FilterPreset, image: CIImage) -> CIImage {
        guard let cube = FilterLUT.cube(for: preset) else { return image }
        let extent = image.extent
        var result = FilterLUT.apply(cube, to: image)

        if preset == .vignette {
            if extent.isInfinite || extent.isEmpty {
                result = result.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: NSNumber(value: 0.8),
                    kCIInputRadiusKey: NSNumber(value: 1.5)
                ])
            } else {
                // 画像サイズに依存しないよう、ピクセル単位で指定できる CIVignetteEffect を使う
                let center = CIVector(x: extent.midX, y: extent.midY)
                let radius = hypot(extent.width, extent.height) * 0.5 * 0.85
                result = result.applyingFilter("CIVignetteEffect", parameters: [
                    kCIInputCenterKey: center,
                    kCIInputRadiusKey: NSNumber(value: Double(radius)),
                    kCIInputIntensityKey: NSNumber(value: 0.75)
                ])
            }
        }

        if extent.isInfinite || extent.isEmpty { return result }
        return result.cropped(to: extent)
    }
}

private func filterEngineOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch o {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
}
