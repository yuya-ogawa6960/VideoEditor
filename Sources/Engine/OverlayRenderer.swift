import Foundation
import AVFoundation
import CoreImage
import UIKit

// =====================================================================
// OverlayRenderer: Bロール / ワイプ(PiP) / 写真クリップを 1 フレームに重ねる
// VideoCompositor から毎フレーム呼ばれる。
// 手順(オーバーレイごと): ソース画像 → Ken Burns クロップ → フィルタ → 枠に収める(fill / fit)
//   → 角丸マスク → 不透明度(フェード込み) → source-over 合成
// CoreImage は左下原点、NormalizedRect は左上原点なので y を変換する。
// 写真の CIImage と角丸マスクはサイズごとにキャッシュして、毎フレームの確保を避ける。
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
            let alpha = overlay.effectiveOpacity(at: time)
            if alpha <= 0.001 { continue }

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

            if let rendered = Self.image(for: overlay, source: source, time: time, alpha: alpha, canvasSize: canvasSize) {
                out = rendered.composited(over: out)
            }
        }
        return out.cropped(to: canvas)
    }

    /// 1 つのオーバーレイを、キャンバス上の位置に配置した CIImage にする(合成前)。
    /// source は原点 (0,0)・向き反映済みの画像。
    static func image(for overlay: VideoCompositorOverlay,
                      source: CIImage,
                      time: Double,
                      alpha: Double,
                      canvasSize: CGSize) -> CIImage? {
        var image = normalizedToOrigin(source)
        let sourceExtent = image.extent
        guard sourceExtent.width >= 1, sourceExtent.height >= 1, !sourceExtent.isInfinite else { return nil }

        // 1. Ken Burns(ソース画像上の表示範囲。左上原点 → 左下原点)
        if overlay.kenBurns.enabled {
            let crop = overlay.kenBurns.crop(at: overlay.progress(at: time)).clamped()
            if !crop.isFull {
                let w = sourceExtent.width
                let h = sourceExtent.height
                let cropRect = CGRect(x: CGFloat(crop.x) * w,
                                      y: (1 - CGFloat(crop.maxY)) * h,
                                      width: CGFloat(crop.width) * w,
                                      height: CGFloat(crop.height) * h)
                if cropRect.width >= 1, cropRect.height >= 1 {
                    image = normalizedToOrigin(image.cropped(to: cropRect))
                }
            }
        }

        // 2. フィルタ(identity ならそのまま返る)
        image = FilterEngine.apply(overlay.filter, to: image)

        // 3. 枠に収める
        let frameRect = pixelFrame(overlay.frame, canvasSize: canvasSize)
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

        // 5. 不透明度(premultiplied なので RGBA すべてに掛ける)
        if alpha < 0.999 {
            let a = CGFloat(max(0, alpha))
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)
            ])
        }
        return placed
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

    // MARK: - キャッシュ

    /// 写真オーバーレイの CIImage(url + 読み込みサイズごと)
    private static let imageCache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 16
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
        let maxPixel = loadPixelSize(canvasSize: canvasSize)
        let key = "\(url.path)|\(maxPixel)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let cg = MediaStore.loadImage(url: url, maxPixel: CGFloat(maxPixel)) else { return nil }
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

    /// 原点を (0,0) に揃える
    private static func normalizedToOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isInfinite else { return image }
        if e.origin.x == 0 && e.origin.y == 0 { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }
}
