import Foundation
import CoreGraphics
import UIKit

// =====================================================================
// ScopeAnalyzer: スコープ(ヒストグラム / 波形)と色の統計
// 画像を小さなビットマップ(長辺 160px)に縮小してから CPU でサンプリングする。
// UI のスコープ表示、自動補正、色合わせ(FilterEngine)で使う。
// =====================================================================

enum ScopeAnalyzer {

    /// RGBA8(sRGB)の小さなビットマップ
    struct Bitmap {
        let width: Int
        let height: Int
        /// width * height * 4 バイト(R, G, B, A の順)
        let pixels: [UInt8]

        @inline(__always)
        func rgb(x: Int, y: Int) -> (r: Float, g: Float, b: Float) {
            let i = (y * width + x) * 4
            return (Float(pixels[i]) / 255, Float(pixels[i + 1]) / 255, Float(pixels[i + 2]) / 255)
        }
    }

    /// 色の統計(すべて 0...1 基準)
    struct ColorStatistics {
        /// 平均輝度
        var meanLuma: Float
        /// 輝度の標準偏差(コントラストの目安)
        var lumaStdDev: Float
        /// 平均彩度(HSV の S)
        var meanSaturation: Float
        /// 暖かさの目安: 平均 (R - B)。正で暖色
        var warmth: Float
        /// 輝度 0.12 未満の画素の割合
        var darkFraction: Float
        /// 輝度 0.9 以上の画素の割合
        var brightFraction: Float
    }

    // MARK: - 公開 API(契約)

    /// 輝度ヒストグラム(最大値で正規化、0...1)
    static func luminanceHistogram(_ image: CGImage, bins: Int = 64) -> [Float] {
        let n = max(2, bins)
        guard let bitmap = sample(image) else { return Array(repeating: 0, count: n) }
        var counts = [Float](repeating: 0, count: n)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let c = bitmap.rgb(x: x, y: y)
                let l = luma(c.r, c.g, c.b)
                let idx = min(n - 1, max(0, Int(l * Float(n))))
                counts[idx] += 1
            }
        }
        let peak = counts.max() ?? 0
        guard peak > 0 else { return counts }
        return counts.map { $0 / peak }
    }

    /// 波形(列ごとの輝度分布)。戻り値は [columns][rows]、rows[0] が暗い側。列ごとに最大値で正規化
    static func waveform(_ image: CGImage, columns: Int = 64, rows: Int = 32) -> [[Float]] {
        let cols = max(1, columns)
        let rws = max(2, rows)
        let empty = Array(repeating: Array(repeating: Float(0), count: rws), count: cols)
        guard let bitmap = sample(image, maxSide: max(160, cols)) else { return empty }
        var result = empty
        for x in 0..<bitmap.width {
            let col = min(cols - 1, x * cols / max(1, bitmap.width))
            for y in 0..<bitmap.height {
                let c = bitmap.rgb(x: x, y: y)
                let l = luma(c.r, c.g, c.b)
                let row = min(rws - 1, max(0, Int(l * Float(rws))))
                result[col][row] += 1
            }
        }
        for c in 0..<cols {
            let peak = result[c].max() ?? 0
            if peak > 0 {
                for r in 0..<rws { result[c][r] /= peak }
            }
        }
        return result
    }

    /// RGB の平均(0...1)
    static func rgbMeans(_ image: CGImage) -> (r: Float, g: Float, b: Float) {
        guard let bitmap = sample(image), bitmap.width > 0, bitmap.height > 0 else { return (0, 0, 0) }
        var r: Double = 0, g: Double = 0, b: Double = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let c = bitmap.rgb(x: x, y: y)
                r += Double(c.r); g += Double(c.g); b += Double(c.b)
            }
        }
        let n = Double(bitmap.width * bitmap.height)
        return (Float(r / n), Float(g / n), Float(b / n))
    }

    // MARK: - 統計(自動補正・色合わせ用)

    static func colorStatistics(_ image: CGImage) -> ColorStatistics? {
        guard let bitmap = sample(image), bitmap.width > 0, bitmap.height > 0 else { return nil }
        let n = Float(bitmap.width * bitmap.height)
        var sumL: Float = 0, sumL2: Float = 0, sumS: Float = 0, sumW: Float = 0
        var dark: Float = 0, bright: Float = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let c = bitmap.rgb(x: x, y: y)
                let l = luma(c.r, c.g, c.b)
                sumL += l
                sumL2 += l * l
                let maxV = max(c.r, max(c.g, c.b))
                let minV = min(c.r, min(c.g, c.b))
                sumS += maxV > 0.0001 ? (maxV - minV) / maxV : 0
                sumW += c.r - c.b
                if l < 0.12 { dark += 1 }
                if l >= 0.9 { bright += 1 }
            }
        }
        let mean = sumL / n
        let variance = max(0, sumL2 / n - mean * mean)
        return ColorStatistics(meanLuma: mean,
                               lumaStdDev: variance.squareRoot(),
                               meanSaturation: sumS / n,
                               warmth: sumW / n,
                               darkFraction: dark / n,
                               brightFraction: bright / n)
    }

    /// UIImage → CGImage(CIImage しか無い場合はレンダリング)
    static func cgImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        if let ci = image.ciImage, !ci.extent.isInfinite, !ci.extent.isEmpty {
            return FilterEngineContexts.current.createCGImage(ci, from: ci.extent)
        }
        return nil
    }

    // MARK: - サンプリング

    /// 長辺 maxSide 以下に縮小した RGBA8 ビットマップを作る
    static func sample(_ image: CGImage, maxSide: Int = 160) -> Bitmap? {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(srcW, srcH)))
        let w = max(1, Int((Double(srcW) * scale).rounded()))
        let h = max(1, Int((Double(srcH) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    @inline(__always)
    private static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        let y: Float = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return min(1, max(0, y))
    }
}
