import Foundation
import CoreGraphics
import CoreImage
import UIKit

// =====================================================================
// MaskRenderer: クリップ / オーバーレイのマスク(形で切り抜く)
//
// - マスクは描画ピクセルサイズで 1 回だけビットマップに描き(UIKit、左上原点)、
//   ぼかし(feather)は CIGaussianBlur を掛けた結果を CGImage に焼いてキャッシュする。
//   毎フレームはキャッシュ済みの CIImage を CIBlendWithMask に渡すだけ(大きな確保なし)。
// - マスク画像は「見せる部分 = 白(不透明)」「隠す部分 = 透明」。白 × アルファなので
//   輝度で見るフィルタ(CIBlendWithMask)でもアルファで見るフィルタでも同じ結果になる。
// - 座標: MaskSettings.center は左上原点の正規化座標、rotation は時計回りが正(UIKit と同じ)。
//   width / height / feather / cornerRadius は「描画領域の短辺」に対する比率。
//   クリップでは描画領域 = キャンバス、オーバーレイでは描画領域 = そのオーバーレイの枠(frameRect)。
// - 形: circle(楕円) / rectangle / roundedRectangle / linear(中心を通る線の片側。回転 0 で下側)
//   / mirror(中心線をはさんだ帯。height を使う) / star(五芒星) / heart
// - inverted: 形の外側を見せる(形の内側を隠す)
// =====================================================================

enum MaskRenderer {

    // MARK: - 公開 API

    /// 描画サイズ size(ピクセル)のマスク画像(原点 (0,0)、CoreImage 座標、ぼかし反映済み)。
    /// 見せる部分が白(不透明)、隠す部分が透明。shape == .none なら nil
    static func mask(for settings: MaskSettings, size: CGSize) -> CIImage? {
        guard settings.isActive else { return nil }
        guard size.width.isFinite, size.height.isFinite else { return nil }
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w >= 2, h >= 2, w <= 8192, h <= 8192 else { return nil }
        let key = cacheKey(settings, width: w, height: h)
        if let cached = cache.object(forKey: key) { return cached }

        guard let hard = drawShape(settings, width: w, height: h) else { return nil }
        var result = CIImage(cgImage: hard)
        let shortSide = Double(min(w, h))
        let sigma = GeometryMath.clamp(settings.feather, 0, 0.5) * shortSide * 0.4
        if sigma >= 0.5 {
            let extent = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            let blurred = result
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
            if let cg = FilterEngineContexts.current.createCGImage(blurred, from: extent) {
                result = CIImage(cgImage: cg)
            } else {
                result = blurred
            }
        }
        cache.setObject(result, forKey: key, cost: w * h * 4)
        return result
    }

    /// キャンバス大(原点 (0,0))の画像にマスクを掛ける。マスクの外は透明になる(背景の黒が見える)
    static func apply(_ settings: MaskSettings, to image: CIImage, canvasSize: CGSize) -> CIImage {
        apply(settings, to: image, frameRect: CGRect(origin: .zero, size: canvasSize))
    }

    /// frameRect(CoreImage 座標)に置かれた画像(オーバーレイ)にマスクを掛ける。
    /// マスクの中心・大きさは frameRect を基準にする(中心 0...1、幅・高さは frameRect の短辺比率)
    static func apply(_ settings: MaskSettings, to image: CIImage, frameRect: CGRect) -> CIImage {
        guard settings.isActive, frameRect.width >= 2, frameRect.height >= 2, !frameRect.isInfinite else { return image }
        // キーフレームで枠の大きさが毎フレーム変わってもキャッシュが効くよう、長辺を 32 px 単位に切り上げた
        // 大きさで描き、同じ倍率で縮小して枠に合わせる(縦横同じ倍率なので形は変わらない)
        let drawSize = Self.drawSize(for: frameRect.size)
        guard let maskImage = Self.mask(for: settings, size: drawSize) else { return image }
        let sx: CGFloat = frameRect.width / drawSize.width
        let sy: CGFloat = frameRect.height / drawSize.height
        var transform = CGAffineTransform.identity
        if abs(sx - 1) > 0.0001 || abs(sy - 1) > 0.0001 {
            transform = CGAffineTransform(scaleX: sx, y: sy)
        }
        if abs(frameRect.minX) > 0.001 || abs(frameRect.minY) > 0.001 {
            transform = transform.concatenating(CGAffineTransform(translationX: frameRect.minX, y: frameRect.minY))
        }
        var positioned = maskImage
        if !transform.isIdentity {
            positioned = maskImage.transformed(by: transform)
        }
        let clear = CIImage(color: CIColor.clear).cropped(to: frameRect)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: positioned
        ]).cropped(to: frameRect)
    }

    /// UI のプレビュー用: マスクの輪郭(ぼかし無し)を UIImage で返す(size はポイントでもピクセルでもよい)
    static func previewImage(for settings: MaskSettings, size: CGSize) -> UIImage? {
        guard settings.isActive else { return nil }
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w >= 2, h >= 2, w <= 4096, h <= 4096 else { return nil }
        guard let cg = drawShape(settings, width: w, height: h) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// マスクを描くピクセルサイズ。長辺を 32 px 単位に切り上げ、短辺は同じ倍率で丸める(縦横比はほぼ保たれる)
    private static func drawSize(for size: CGSize) -> CGSize {
        let step: CGFloat = 32
        let longSide = max(size.width, size.height)
        guard longSide >= 1 else { return size }
        let quantized = (longSide / step).rounded(.up) * step
        let k: CGFloat = quantized / longSide
        if abs(k - 1) < 0.0001 { return size }
        let w = max(2, (size.width * k).rounded())
        let h = max(2, (size.height * k).rounded())
        return CGSize(width: w, height: h)
    }

    // MARK: - キャッシュ

    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 16
        c.totalCostLimit = 192 * 1024 * 1024
        return c
    }()

    private static func quantized(_ value: Double, _ scale: Double) -> String {
        let v = GeometryMath.clamp(value, -1000, 1000) * scale
        return String(Int(v.rounded()))
    }

    private static func cacheKey(_ s: MaskSettings, width: Int, height: Int) -> NSString {
        let parts: [String] = [
            s.shape.rawValue,
            quantized(s.center.x, 1000),
            quantized(s.center.y, 1000),
            quantized(s.width, 1000),
            quantized(s.height, 1000),
            quantized(s.rotation, 10),
            quantized(s.feather, 1000),
            s.inverted ? "i" : "n",
            quantized(s.cornerRadius, 1000),
            String(width),
            String(height)
        ]
        return parts.joined(separator: "|") as NSString
    }

    // MARK: - 形の描画(UIKit 座標 = 左上原点)

    /// ぼかし無しのマスク(白 = 見せる部分)。CGImage は左上原点だが CIImage(cgImage:) でそのまま正しく表示される
    private static func drawShape(_ s: MaskSettings, width w: Int, height h: Int) -> CGImage? {
        let size = CGSize(width: CGFloat(w), height: CGFloat(h))
        let shortSide = CGFloat(min(w, h))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let cx = CGFloat(GeometryMath.clamp(s.center.x, -2, 3)) * size.width
        let cy = CGFloat(GeometryMath.clamp(s.center.y, -2, 3)) * size.height
        let shapeW = max(1, CGFloat(GeometryMath.clamp(s.width, 0.01, 6)) * shortSide)
        let shapeH = max(1, CGFloat(GeometryMath.clamp(s.height, 0.01, 6)) * shortSide)
        let corner = CGFloat(GeometryMath.clamp(s.cornerRadius, 0, 0.5)) * shortSide
        let big = 4 * max(size.width, size.height)
        let path = shapePath(s.shape, width: shapeW, height: shapeH, cornerRadius: corner, big: big)
        let radians = CGFloat(GeometryMath.clamp(s.rotation, -3600, 3600) * Double.pi / 180)

        let image = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            if s.inverted {
                // 全面を白にしてから形を「消す」
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.setBlendMode(.clear)
            }
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            if abs(radians) > 0.0001 {
                ctx.rotate(by: radians)
            }
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
        return image.cgImage
    }

    /// 原点を中心にした形のパス(UIKit 座標、y は下向き)
    private static func shapePath(_ shape: MaskShape,
                                  width w: CGFloat,
                                  height h: CGFloat,
                                  cornerRadius: CGFloat,
                                  big: CGFloat) -> CGPath {
        let box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        switch shape {
        case .none, .rectangle:
            return CGPath(rect: box, transform: nil)
        case .circle:
            return CGPath(ellipseIn: box, transform: nil)
        case .roundedRectangle:
            let r = max(0, min(cornerRadius, min(w, h) / 2))
            if r < 0.5 { return CGPath(rect: box, transform: nil) }
            return CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
        case .linear:
            // 中心を通る線の片側(回転 0 では線より下)。十分大きな矩形で表す
            return CGPath(rect: CGRect(x: -big, y: 0, width: big * 2, height: big), transform: nil)
        case .mirror:
            // 中心線をはさんだ帯(高さ h)
            return CGPath(rect: CGRect(x: -big, y: -h / 2, width: big * 2, height: h), transform: nil)
        case .star:
            return starPath(width: w, height: h)
        case .heart:
            return heartPath(width: w, height: h)
        }
    }

    /// 五芒星(w × h に内接)
    private static func starPath(width w: CGFloat, height h: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let rx = w / 2
        let ry = h / 2
        let inner: CGFloat = 0.42
        for i in 0..<10 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            let k: CGFloat = (i % 2 == 0) ? 1 : inner
            let px = cos(angle) * rx * k
            let py = sin(angle) * ry * k
            let p = CGPoint(x: px, y: py)
            if i == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        path.closeSubpath()
        return path
    }

    /// ハート(w × h に収める)。32 × 29.6 の基準形を拡大縮小する
    private static func heartPath(width w: CGFloat, height h: CGFloat) -> CGPath {
        let sx = w / 32
        let sy = h / 29.6
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let px = (x - 16) * sx
            let py = (y - 14.8) * sy
            return CGPoint(x: px, y: py)
        }
        let path = CGMutablePath()
        path.move(to: pt(23.6, 0))
        path.addCurve(to: pt(16, 5.6), control1: pt(20.2, 0), control2: pt(17.3, 2.7))
        path.addCurve(to: pt(8.4, 0), control1: pt(14.7, 2.7), control2: pt(11.8, 0))
        path.addCurve(to: pt(0, 8.4), control1: pt(3.8, 0), control2: pt(0, 3.8))
        path.addCurve(to: pt(16, 29.6), control1: pt(0, 17.8), control2: pt(9.5, 20.3))
        path.addCurve(to: pt(32, 8.4), control1: pt(22.1, 20.3), control2: pt(32, 17.5))
        path.addCurve(to: pt(23.6, 0), control1: pt(32, 3.8), control2: pt(28.2, 0))
        path.closeSubpath()
        return path
    }
}
