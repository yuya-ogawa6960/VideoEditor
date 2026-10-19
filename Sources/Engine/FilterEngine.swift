import Foundation
import UIKit
import CoreImage

// =====================================================================
// FilterEngine: FilterSettings → CoreImage 処理
// プレビュー・書き出し(VideoCompositor)とフィルタ一覧のサムネイルで共通利用する。
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

        // 1. プリセット(強度でブレンド)
        if settings.preset != .none && settings.intensity > 0 {
            let filtered = presetImage(settings.preset, image: image)
            let intensity = min(max(settings.intensity, 0), 1)
            if intensity >= 0.999 {
                output = filtered
            } else {
                // time 0 = 元画像, 1 = フィルタ後
                output = image.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: filtered,
                    kCIInputTimeKey: NSNumber(value: intensity)
                ])
            }
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

    /// フィルタ選択 UI 用のサムネイル
    static func preview(_ image: UIImage, settings: FilterSettings) -> UIImage? {
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
        let output = apply(settings, to: normalized)
        let rect = normalized.extent
        guard !rect.isEmpty, !rect.isInfinite else { return nil }
        guard let cg = FilterEngineContexts.current.createCGImage(output, from: rect) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    // MARK: - プリセット

    private static func presetImage(_ preset: FilterPreset, image: CIImage) -> CIImage {
        let extent = image.extent
        let result: CIImage
        switch preset {
        case .none:
            return image
        case .mono:
            result = image.applyingFilter("CIPhotoEffectMono", parameters: [:])
        case .noir:
            result = image.applyingFilter("CIPhotoEffectNoir", parameters: [:])
        case .chrome:
            result = image.applyingFilter("CIPhotoEffectChrome", parameters: [:])
        case .fade:
            result = image.applyingFilter("CIPhotoEffectFade", parameters: [:])
        case .instant:
            result = image.applyingFilter("CIPhotoEffectInstant", parameters: [:])
        case .process:
            result = image.applyingFilter("CIPhotoEffectProcess", parameters: [:])
        case .transfer:
            result = image.applyingFilter("CIPhotoEffectTransfer", parameters: [:])
        case .tonal:
            result = image.applyingFilter("CIPhotoEffectTonal", parameters: [:])
        case .sepia:
            result = image.applyingFilter("CISepiaTone", parameters: [
                kCIInputIntensityKey: NSNumber(value: 1.0)
            ])
        case .vivid:
            result = image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": NSNumber(value: 0.6)])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: NSNumber(value: 1.3),
                    kCIInputContrastKey: NSNumber(value: 1.06),
                    kCIInputBrightnessKey: NSNumber(value: 0.0)
                ])
        case .cool:
            // 撮影時の光源を低い色温度とみなして補正 → 青寄り
            result = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 5000, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        case .warm:
            // 撮影時の光源を高い色温度とみなして補正 → 暖色寄り
            result = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 8500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        case .vignette:
            if extent.isInfinite || extent.isEmpty {
                result = image.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: NSNumber(value: 1.0),
                    kCIInputRadiusKey: NSNumber(value: 1.5)
                ])
            } else {
                // 画像サイズに依存しないよう、ピクセル単位で指定できる CIVignetteEffect を使う
                let center = CIVector(x: extent.midX, y: extent.midY)
                let radius = hypot(extent.width, extent.height) * 0.5 * 0.85
                result = image.applyingFilter("CIVignetteEffect", parameters: [
                    kCIInputCenterKey: center,
                    kCIInputRadiusKey: NSNumber(value: Double(radius)),
                    kCIInputIntensityKey: NSNumber(value: 0.9)
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
