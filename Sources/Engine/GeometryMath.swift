import Foundation
import CoreGraphics
import CoreImage

// =====================================================================
// GeometryMath: 座標変換・イージング・クリップのジオメトリ(回転/反転/切り抜き/ズーム)
//
// 座標系の約束:
//   - NormalizedRect / NormalizedPoint は「左上原点」(UIKit と同じ、0...1)
//   - CIImage は「左下原点」。この変換はすべてここで行う
//   - 回転の向き: モデルの「度」は UIKit と同じ時計回りが正。CoreImage(y 上向き)では
//     正の角度が反時計回りになるので、符号を反転して適用する
// =====================================================================

enum GeometryMath {

    // MARK: - 数値ユーティリティ

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }

    /// 0...1 → 0...1 のなめらかな補間
    static func smoothstep(_ x: Double) -> Double {
        let t = clamp(x, 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func easeOutCubic(_ x: Double) -> Double {
        let t = clamp(x, 0, 1)
        return 1 - pow(1 - t, 3)
    }

    static func easeInOutCubic(_ x: Double) -> Double {
        let t = clamp(x, 0, 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// 少し行き過ぎてから戻る(ポップ用)。x = 1 で 1
    static func easeOutBack(_ x: Double) -> Double {
        let t = clamp(x, 0, 1)
        let c1 = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    // MARK: - 座標変換

    /// 左上原点の正規化点 → CoreImage 座標(左下原点)のピクセル位置
    static func point(topLeft p: NormalizedPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
    }

    /// 左上原点の正規化矩形 → CoreImage 座標(左下原点)のピクセル矩形
    static func rect(topLeft r: NormalizedRect, in size: CGSize) -> CGRect {
        let w = CGFloat(r.width) * size.width
        let h = CGFloat(r.height) * size.height
        let x = CGFloat(r.x) * size.width
        let y = (1 - CGFloat(r.maxY)) * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - CIImage ユーティリティ

    /// 原点を (0,0) に揃える
    static func normalizedToOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, e.width.isFinite, e.height.isFinite else { return image }
        if e.origin.x == 0 && e.origin.y == 0 { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    /// 不透明度を掛ける(premultiplied なので RGBA すべてに掛ける)
    static func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        let a = CGFloat(clamp(alpha, 0, 1))
        if a >= 0.999 { return image }
        if a <= 0.0005 { return CIImage.empty() }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)
        ])
    }

    /// 端を伸ばしてからぼかし、元の範囲に戻す(縁が暗くならない)
    static func blurred(_ image: CIImage, sigma: Double) -> CIImage {
        guard sigma > 0.05, sigma.isFinite else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        return image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
    }

    /// 原点 (0,0) の画像を、中心を center(CoreImage 座標)に置いて scale 倍・rotationDegrees 度(時計回り正)回す
    static func transformed(_ image: CIImage, scale: CGFloat, rotationDegrees: Double, center: CGPoint) -> CIImage {
        let e = image.extent
        guard !e.isInfinite else { return image }
        let s = (scale.isFinite && scale > 0) ? scale : 1
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
        t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
        if rotationDegrees.isFinite, abs(rotationDegrees) > 0.001 {
            let radians = CGFloat(-rotationDegrees * Double.pi / 180)
            t = t.concatenating(CGAffineTransform(rotationAngle: radians))
        }
        t = t.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return image.transformed(by: t)
    }

    /// 画像をその中心のまわりで scale 倍する(位置は変わらない)
    static func scaledAboutCenter(_ image: CIImage, scale: CGFloat) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, scale.isFinite, scale > 0, abs(scale - 1) > 0.0001 else { return image }
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
        return image.transformed(by: t)
    }

    // MARK: - クリップのジオメトリ

    /// 向き反映済み(原点 (0,0))の画像に、回転(90 度単位)→ 反転 → 切り抜き → ズーム/オフセットを適用する。
    /// 戻り値の原点も (0,0)。
    static func applyClipGeometry(_ image: CIImage, geometry: ClipGeometry) -> CIImage {
        if geometry.isIdentity { return image }
        var out = normalizedToOrigin(image)
        guard !out.extent.isInfinite, out.extent.width >= 1, out.extent.height >= 1 else { return image }

        // 1. 90 度単位の回転(時計回り)
        let turns = ((geometry.rotationQuarterTurns % 4) + 4) % 4
        if turns != 0 {
            let angle = CGFloat(-Double(turns) * Double.pi / 2)
            out = normalizedToOrigin(out.transformed(by: CGAffineTransform(rotationAngle: angle)))
        }

        // 2. 反転
        if geometry.flipHorizontal {
            out = normalizedToOrigin(out.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        if geometry.flipVertical {
            out = normalizedToOrigin(out.transformed(by: CGAffineTransform(scaleX: 1, y: -1)))
        }

        // 3. 切り抜き(回転・反転後の座標、左上原点)
        let crop = geometry.crop.clamped()
        if !crop.isFull {
            let r = rect(topLeft: crop, in: out.extent.size).integral
            if r.width >= 1, r.height >= 1 {
                out = normalizedToOrigin(out.cropped(to: r.intersection(out.extent)))
            }
        }

        // 4. ズーム / オフセット(見える範囲を 1/zoom に狭めて中心をずらす)
        let zoom = clamp(geometry.zoom, 1, 8)
        let ox = clamp(geometry.offsetX, -0.5, 0.5)
        let oy = clamp(geometry.offsetY, -0.5, 0.5)
        if zoom > 1.0001 || ox != 0 || oy != 0 {
            let w = out.extent.width
            let h = out.extent.height
            let visibleW = w / CGFloat(zoom)
            let visibleH = h / CGFloat(zoom)
            // 中心(左上原点の比率)→ CoreImage 座標
            let cx = (0.5 + CGFloat(ox)) * w
            let cyTop = (0.5 + CGFloat(oy)) * h
            let cy = h - cyTop
            var x = cx - visibleW / 2
            var y = cy - visibleH / 2
            x = min(max(x, 0), max(0, w - visibleW))
            y = min(max(y, 0), max(0, h - visibleH))
            let region = CGRect(x: x, y: y, width: visibleW, height: visibleH).integral.intersection(out.extent)
            if region.width >= 1, region.height >= 1 {
                out = normalizedToOrigin(out.cropped(to: region))
            }
        }
        return out
    }

    // MARK: - 曲線

    /// Catmull-Rom スプラインで点列をなめらかにする(各区間を subdivisions 分割)
    static func catmullRom(points: [CGPoint], subdivisions: Int = 8) -> [CGPoint] {
        let n = points.count
        guard n >= 3, subdivisions >= 1 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity((n - 1) * subdivisions + 1)
        for i in 0..<(n - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, n - 1)]
            // 係数を先に求めておく(1 つの式が長すぎると型推論に時間がかかるため分割)
            let ax: CGFloat = 2 * p1.x
            let bx: CGFloat = p2.x - p0.x
            let cx: CGFloat = 2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x
            let dx: CGFloat = 3 * p1.x - 3 * p2.x + p3.x - p0.x
            let ay: CGFloat = 2 * p1.y
            let by: CGFloat = p2.y - p0.y
            let cy: CGFloat = 2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y
            let dy: CGFloat = 3 * p1.y - 3 * p2.y + p3.y - p0.y
            for s in 0..<subdivisions {
                let t = CGFloat(s) / CGFloat(subdivisions)
                let t2 = t * t
                let t3 = t2 * t
                let xSum: CGFloat = ax + bx * t + cx * t2 + dx * t3
                let ySum: CGFloat = ay + by * t + cy * t2 + dy * t3
                result.append(CGPoint(x: 0.5 * xSum, y: 0.5 * ySum))
            }
        }
        result.append(points[n - 1])
        return result
    }

    /// 折れ線の長さ
    static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        return total
    }
}
