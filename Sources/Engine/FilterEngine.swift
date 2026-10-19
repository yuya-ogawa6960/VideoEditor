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
        AppLifecycle.shared.isInBackground ? cpu : gpu
    }
}

enum FilterEngine {

    static func apply(_ settings: FilterSettings, to image: CIImage) -> CIImage {
        if settings.isIdentity { return image }
        let extent = image.extent
        var output = image

        // 1. プリセット(LUT。強度で元画像とブレンド)
        if settings.preset != .none && settings.intensity > 0 {
            let filtered = presetImage(settings.preset, image: image)
            output = blend(original: image, filtered: filtered, intensity: settings.intensity)
        }

        // 2. 明るさ / コントラスト / 彩度
        let adj = settings.adjustments
        if !adj.isIdentity {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: NSNumber(value: adj.brightness),
                kCIInputContrastKey: NSNumber(value: adj.contrast),
                kCIInputSaturationKey: NSNumber(value: adj.saturation)
            ])
        }

        if extent.isInfinite || extent.isEmpty { return output }
        return output.cropped(to: extent)
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
