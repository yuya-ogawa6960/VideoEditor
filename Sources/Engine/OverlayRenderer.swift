import Foundation
import AVFoundation
import CoreImage
import UIKit

// =====================================================================
// OverlayRenderer: Bロール / ワイプ(PiP) / 写真クリップを 1 フレームに重ねる
// VideoCompositor から毎フレーム呼ばれる。
// 手順(オーバーレイごと): ソース画像 → Ken Burns クロップ → フィルタ → 枠に収める(fill / fit)
//   → 角丸マスク → 回転(キーフレーム) → 不透明度(フェード込み) → 合成(通常 or ブレンドモード)
// キーフレームがあるときは枠の中心・大きさ・回転・不透明度を KeyframeInterpolator の値で置き換える。
// CoreImage は左下原点、NormalizedRect は左上原点なので y を変換する。
// 写真の CIImage と角丸マスクはサイズごとにキャッシュして、毎フレームの確保を避ける。
// WatermarkRenderer: 透かし(画像または文字)を隅に描く。
// =====================================================================

enum OverlayRenderer {

    // MARK: - 公開 API

    /// frame(キャンバス全面、左下原点)の上に、時刻 time に表示中のオーバーレイを開始時刻順に重ねる
    static func draw(_ overlays: [VideoCompositorOverlay],
                     over frame: CIImage,
                     time: Double,
                     request: AVAsynchronousVideoCompositionRequest,
                     canvasSize: CGSize) -> CIImage {
        guard canvasSize.width >= 2, canvasSize.height >= 2 else { return frame }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        var out = frame
        for overlay in overlays where overlay.contains(timelineTime: time) {
            let fade = overlay.fadeFactor(at: time)
            if fade <= 0.001 { continue }

            let source: CIImage?
            if overlay.isImage {
                source = cachedImage(url: overlay.url, canvasSize: canvasSize)
            } else if let trackID = overlay.trackID,
                      let buffer = request.sourceFrame(byTrackID: trackID) {
                source = VideoCompositor.oriented(CIImage(cvPixelBuffer: buffer), transform: overlay.preferredTransform)
            } else {
                source = nil
            }
            guard let source else { continue }

            if let rendered = Self.image(for: overlay, source: source, time: time, fade: fade, canvasSize: canvasSize) {
                out = composite(rendered, over: out, blendMode: overlay.blendMode, canvas: canvas)
            }
        }
        return out.cropped(to: canvas)
    }

    /// 1 つのオーバーレイを、キャンバス上の位置に配置した CIImage にする(合成前)。
    /// source は原点 (0,0)・向き反映済みの画像。fade はフェードイン/アウトの係数(不透明度は含まない)
    static func image(for overlay: VideoCompositorOverlay,
                      source: CIImage,
                      time: Double,
                      fade: Double,
                      canvasSize: CGSize) -> CIImage? {
        var image = GeometryMath.normalizedToOrigin(source)
        let sourceExtent = image.extent
        guard sourceExtent.width >= 1, sourceExtent.height >= 1, !sourceExtent.isInfinite else { return nil }

        // 1. 写真の 3D ズーム(奥行き)。有効なら Ken Burns の代わりに使う
        if overlay.isImage, overlay.parallax.enabled {
            let depth = DepthParallaxRenderer.depth(for: overlay.url)
            image = DepthParallaxRenderer.render(image: image,
                                                 depth: depth,
                                                 parallax: overlay.parallax,
                                                 progress: overlay.progress(at: time))
        } else if overlay.kenBurns.enabled {
            // 1'. Ken Burns(ソース画像上の表示範囲。左上原点 → 左下原点)
            let crop = overlay.kenBurns.crop(at: overlay.progress(at: time)).clamped()
            if !crop.isFull {
                let cropRect = GeometryMath.rect(topLeft: crop, in: sourceExtent.size)
                if cropRect.width >= 1, cropRect.height >= 1 {
                    image = GeometryMath.normalizedToOrigin(image.cropped(to: cropRect))
                }
            }
        }

        // 2. フィルタ(identity ならそのまま返る)
        image = FilterEngine.apply(overlay.filter, to: image)

        // 3. 枠(キーフレームがあれば中心・大きさ・回転・不透明度を置き換える)
        var frameRect = pixelFrame(overlay.frame, canvasSize: canvasSize)
        var rotation = 0.0
        var opacity = overlay.opacity
        if !overlay.keyframes.isEmpty {
            let fallback = KeyframeInterpolator.Value(center: NormalizedPoint(x: overlay.frame.midX, y: overlay.frame.midY),
                                                      scale: 1, rotation: 0, opacity: overlay.opacity)
            let value = KeyframeInterpolator.value(at: time - overlay.start, keyframes: overlay.keyframes, fallback: fallback)
            let center = GeometryMath.point(topLeft: value.center, in: canvasSize)
            let scale = CGFloat(max(0.01, value.scale))
            let w = max(1, (frameRect.width * scale).rounded())
            let h = max(1, (frameRect.height * scale).rounded())
            frameRect = CGRect(x: (center.x - w / 2).rounded(), y: (center.y - h / 2).rounded(), width: w, height: h)
            rotation = value.rotation
            opacity = min(max(value.opacity, 0), 1)
        }
        guard frameRect.width >= 1, frameRect.height >= 1 else { return nil }
        let e = image.extent
        guard e.width > 0, e.height > 0, !e.isInfinite else { return nil }
        let scale: CGFloat
        switch overlay.fit {
        case .fill:
            scale = max(frameRect.width / e.width, frameRect.height / e.height)
        case .fit:
            scale = min(frameRect.width / e.width, frameRect.height / e.height)
        }
        guard scale.isFinite, scale > 0 else { return nil }
        var placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let pe = placed.extent
        let dx = frameRect.midX - pe.midX
        let dy = frameRect.midY - pe.midY
        placed = placed
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: frameRect)

        // 4. 角丸
        let radius = cornerRadiusPixels(overlay.cornerRadius, frameRect: frameRect, canvasSize: canvasSize)
        if radius >= 1, let mask = roundedMask(size: frameRect.size, radius: radius) {
            let positionedMask = mask.transformed(by: CGAffineTransform(translationX: frameRect.minX, y: frameRect.minY))
            placed = placed.applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: positionedMask
            ]).cropped(to: frameRect)
        }

        // 4'. マスク(枠を基準にした形で切り抜く。回転の前なので枠と一緒に回る)
        if overlay.mask.isActive {
            placed = MaskRenderer.apply(overlay.mask, to: placed, frameRect: frameRect)
        }

        // 5. 回転(枠の中心まわり)
        if abs(rotation) > 0.01 {
            placed = GeometryMath.transformed(GeometryMath.normalizedToOrigin(placed),
                                              scale: 1,
                                              rotationDegrees: rotation,
                                              center: CGPoint(x: frameRect.midX, y: frameRect.midY))
        }

        // 6. 不透明度(フェード × 不透明度)
        return GeometryMath.withAlpha(placed, fade * opacity)
    }

    /// NormalizedRect(左上原点)→ キャンバス上のピクセル矩形(CoreImage の左下原点、整数に丸め)
    static func pixelFrame(_ frame: NormalizedRect, canvasSize: CGSize) -> CGRect {
        let tl = frame.rect(in: canvasSize)
        let x = tl.minX.rounded()
        let maxX = tl.maxX.rounded()
        let topY = tl.minY.rounded()
        let bottomY = tl.maxY.rounded()
        let width = max(0, maxX - x)
        let height = max(0, bottomY - topY)
        return CGRect(x: x, y: canvasSize.height - bottomY, width: width, height: height)
    }

    // MARK: - ブレンド

    /// 対応するブレンドフィルタ名(これ以外は通常の重ね合わせ)
    static let blendModeNames: Set<String> = [
        "CIMultiplyBlendMode", "CIScreenBlendMode", "CIOverlayBlendMode", "CISoftLightBlendMode",
        "CIHardLightBlendMode", "CILightenBlendMode", "CIDarkenBlendMode", "CIColorDodgeBlendMode",
        "CIColorBurnBlendMode", "CIDifferenceBlendMode", "CIExclusionBlendMode", "CILuminosityBlendMode",
        "CIHueBlendMode", "CIColorBlendMode", "CISaturationBlendMode", "CIAdditionCompositing"
    ]

    /// top を bottom の上に合成する(blendMode が対応名なら CoreImage のブレンド、そうでなければ source-over)
    static func composite(_ top: CIImage, over bottom: CIImage, blendMode: String?, canvas: CGRect) -> CIImage {
        if let mode = blendMode, blendModeNames.contains(mode) {
            return top.applyingFilter(mode, parameters: [
                kCIInputBackgroundImageKey: bottom
            ]).cropped(to: canvas)
        }
        return top.composited(over: bottom).cropped(to: canvas)
    }

    // MARK: - キャッシュ

    /// 写真オーバーレイ・静止画クリップの CIImage(url + 読み込みサイズごと)
    private static let imageCache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 24
        return c
    }()

    /// 角丸マスク(サイズ + 半径ごと)
    private static let maskCache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 24
        return c
    }()

    /// 写真を読み込みサイズ(キャンバス長辺の 1.5 倍、最大 4096)で一度だけ読み込む
    static func cachedImage(url: URL, canvasSize: CGSize) -> CIImage? {
        cachedImage(url: url, maxPixel: loadPixelSize(canvasSize: canvasSize))
    }

    /// 写真を長辺 maxPixel 以下(向き反映済み)で一度だけ読み込む(url + maxPixel ごとにキャッシュ)
    static func cachedImage(url: URL, maxPixel: Int) -> CIImage? {
        let pixel = max(16, min(8192, maxPixel))
        let key = "\(url.path)|\(pixel)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let cg = MediaStore.loadImage(url: url, maxPixel: CGFloat(pixel)) else { return nil }
        let image = CIImage(cgImage: cg)
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Ken Burns で 80% まで寄っても粗くならないよう、キャンバス長辺より大きめに読む
    static func loadPixelSize(canvasSize: CGSize) -> Int {
        let longSide = max(canvasSize.width, canvasSize.height)
        let target = min(4096, max(256, (longSide * 1.5).rounded()))
        // キーが散らばらないよう 64 単位に丸める
        return Int((target / 64).rounded(.up)) * 64
    }

    /// 白い角丸矩形(原点 (0,0))。アルファをマスクとして使う
    static func roundedMask(size: CGSize, radius: CGFloat) -> CIImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let r = max(0, min(radius, CGFloat(min(w, h)) / 2))
        let key = "\(w)x\(h)|\(Int((r * 10).rounded()))" as NSString
        if let cached = maskCache.object(forKey: key) { return cached }

        let pixelSize = CGSize(width: w, height: h)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let uiImage = renderer.image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: pixelSize), cornerRadius: r)
            UIColor.white.setFill()
            path.fill()
        }
        guard let cg = uiImage.cgImage else { return nil }
        let mask = CIImage(cgImage: cg)
        maskCache.setObject(mask, forKey: key)
        return mask
    }

    // MARK: - ヘルパー

    /// 角丸半径(min(キャンバス幅, 高さ) に対する比率)→ ピクセル。枠の半分を超えない
    private static func cornerRadiusPixels(_ ratio: Double, frameRect: CGRect, canvasSize: CGSize) -> CGFloat {
        guard ratio > 0 else { return 0 }
        let base = min(canvasSize.width, canvasSize.height)
        let radius = CGFloat(ratio) * base
        return min(radius, min(frameRect.width, frameRect.height) / 2)
    }
}

// MARK: - 透かし

enum WatermarkRenderer {

    /// 透かし(画像または文字)を隅に描く。最後に呼ぶので黒帯の上にも出る
    static func draw(_ settings: WatermarkSettings, over frame: CIImage, canvasSize: CGSize) -> CIImage {
        guard settings.isActive, canvasSize.width >= 2, canvasSize.height >= 2 else { return frame }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let shortSide = min(canvasSize.width, canvasSize.height)
        let sizeRatio = GeometryMath.clamp(settings.sizeRatio, 0.03, 1.0)
        let targetWidth = max(8, (CGFloat(sizeRatio) * canvasSize.width).rounded())

        var mark: CIImage? = nil
        if let url = settings.imageURL,
           let base = OverlayRenderer.cachedImage(url: url, canvasSize: canvasSize) {
            let e = base.extent
            if e.width >= 1, e.height >= 1, !e.isInfinite {
                let scale = targetWidth / e.width
                mark = GeometryMath.normalizedToOrigin(base).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        if mark == nil, !settings.text.trimmingCharacters(in: .whitespaces).isEmpty {
            var style = TextStyle()
            style.bold = true
            style.colorHex = "#FFFFFF"
            // sizeRatio は画面幅に対する比率なので、短辺基準の文字サイズに換算する
            let widthToShort = Double(canvasSize.width / shortSide)
            style.sizeRatio = GeometryMath.clamp(sizeRatio * 0.22 * widthToShort, 0.015, 0.6)
            style.shadow.enabled = true
            style.shadow.opacity = 0.7
            style.strokeColorHex = nil
            style.backgroundColorHex = nil
            mark = TextRenderer.image(text: settings.text, style: style, canvasSize: canvasSize, widthRatio: 1)
        }
        guard let image = mark else { return frame }
        let e = image.extent
        guard e.width >= 1, e.height >= 1, !e.isInfinite else { return frame }

        // 大きいとき(最大で画面幅 100%)ははみ出さないよう、余白を空いている分まで縮める
        let margin = (canvasSize.width * 0.03).rounded()
        let marginX: CGFloat = min(margin, max(0, (canvasSize.width - e.width) / 2))
        let marginY: CGFloat = min(margin, max(0, (canvasSize.height - e.height) / 2))
        let x: CGFloat
        let y: CGFloat
        switch settings.corner {
        case .topLeft:
            x = marginX
            y = canvasSize.height - marginY - e.height
        case .topRight:
            x = canvasSize.width - marginX - e.width
            y = canvasSize.height - marginY - e.height
        case .bottomLeft:
            x = marginX
            y = marginY
        case .bottomRight:
            x = canvasSize.width - marginX - e.width
            y = marginY
        }
        let placed = GeometryMath.normalizedToOrigin(image)
            .transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        return GeometryMath.withAlpha(placed, settings.opacity).composited(over: frame).cropped(to: canvas)
    }
}
