import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UIKit

// =====================================================================
// DepthParallaxRenderer: 写真の奥行き情報を使った 3D ズーム(視差)
//
// - 奥行き: 写真に埋め込まれた視差(kCGImageAuxiliaryDataTypeDisparity)/ 深度(Depth)を
//   AVDepthData で読み、写真と同じ向きに揃えて「手前ほど白い」8bit グレーの CGImage にする。
//   どちらも無いポートレート写真では人物マット(PortraitEffectsMatte: 人物 = 手前)で代用する。
//   ファイルごとに 1 回だけ読み、CIImage としてキャッシュする(毎フレームの確保なし)。
// - 描画: 手前(奥行きマスク)と奥の 2 層に分け、手前を大きく動かす(ズーム / パン)。
//   手前の層のふちはマスクをぼかしてなじませる。奥の層は端を伸ばしてから動かすので黒が出ない。
//   奥行きが無い写真は Ken Burns 風のゆっくりしたズーム / パンで代用する。
// - 静止画クリップ(clip.parallax)と写真オーバーレイ(overlay.parallax)の両方から使う。
// =====================================================================

enum DepthParallaxRenderer {

    // MARK: - 公開 API

    /// 写真(向き反映済み、長辺 maxPixel 以下)と奥行きマップ(手前 = 白。低解像度、写真と同じ向き)。
    /// 写真が読めなければ nil。奥行きが無い写真では depth が nil
    static func image(for url: URL, maxPixel: CGFloat) -> (image: CIImage, depth: CIImage?)? {
        let pixel = Int(max(64, min(8192, maxPixel.isFinite ? maxPixel.rounded() : 1024)))
        guard let image = OverlayRenderer.cachedImage(url: url, maxPixel: pixel) else { return nil }
        return (image: image, depth: depth(for: url))
    }

    /// この写真に奥行き情報(視差 / 深度 / 人物マット)があるか。結果はキャッシュされる(UI から何度呼んでもよい)
    static func hasDepth(url: URL) -> Bool {
        depth(for: url) != nil
    }

    /// 奥行きマップ(手前 = 白のグレースケール、原点 (0,0)、写真と同じ向き)。無ければ nil
    static func depth(for url: URL) -> CIImage? {
        let path = url.path
        let key = path as NSString
        if let cached = depthCache.object(forKey: key) { return cached }

        lock.lock()
        let known = availability[path]
        lock.unlock()
        if known == false { return nil }

        let loaded = loadDepth(url: url)
        lock.lock()
        availability[path] = (loaded != nil)
        lock.unlock()
        if let loaded {
            let e = loaded.extent
            let cost = Int(max(1, e.width * e.height)) * 4
            depthCache.setObject(loaded, forKey: key, cost: cost)
        }
        return loaded
    }

    /// 写真 image(原点は任意)に 3D ズームを掛けた画像(原点 (0,0)、大きさは元と同じ)。
    /// progress は 0...1(クリップ / オーバーレイの進行度)。depth が nil なら Ken Burns 風の代用
    static func render(image: CIImage, depth: CIImage?, parallax: DepthParallax, progress: Double) -> CIImage {
        guard parallax.enabled else { return image }
        let base = GeometryMath.normalizedToOrigin(image)
        let extent = base.extent
        guard !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return image }
        let strength = GeometryMath.clamp(parallax.strength, 0, 1)
        guard strength > 0.001 else { return base }
        let eased = GeometryMath.smoothstep(GeometryMath.clamp(progress, 0, 1))

        guard let depth, !depth.extent.isInfinite, depth.extent.width >= 2, depth.extent.height >= 2 else {
            return kenBurns(base, direction: parallax.direction, strength: strength, eased: eased)
        }

        let motion = layerMotion(direction: parallax.direction, strength: strength, eased: eased, width: extent.width)
        let backgroundTransform = aboutCenter(extent, scale: motion.backgroundScale, dx: motion.backgroundDx)
        let foregroundTransform = aboutCenter(extent, scale: motion.foregroundScale, dx: motion.foregroundDx)

        let background = base
            .clampedToExtent()
            .transformed(by: backgroundTransform)
            .cropped(to: extent)
        let foreground = base
            .transformed(by: foregroundTransform)
            .cropped(to: extent)
        let mask = nearMask(depth, extent: extent)
            .transformed(by: foregroundTransform)
            .cropped(to: extent)
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
    }

    /// キャッシュを捨てる(メモリ警告時など)
    static func clearCache() {
        depthCache.removeAllObjects()
        lock.lock()
        availability.removeAll()
        lock.unlock()
    }

    // MARK: - キャッシュ

    private static let depthCache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 24
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private static let lock = NSLock()
    /// ファイルパス → 奥行きがあるか(無い写真を毎回読み直さないため)
    private static var availability: [String: Bool] = [:]

    // MARK: - 奥行きの読み込み

    private static func loadDepth(url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        var exif = CGImagePropertyOrientation.up
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
           let o = CGImagePropertyOrientation(rawValue: raw) {
            exif = o
        }

        // 1. 視差 / 深度(AVDepthData)。写真と同じ向きに揃え、視差 Float32 に統一する
        let types: [CFString] = [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth]
        for type in types {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  let raw = try? AVDepthData(fromDictionaryRepresentation: info) else {
                continue
            }
            var depthData = raw.applyingExifOrientation(exif)
            if depthData.depthDataType != kCVPixelFormatType_DisparityFloat32 {
                depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            }
            if let cg = grayImage(fromDisparity: depthData.depthDataMap) {
                return CIImage(cgImage: cg)
            }
        }

        // 2. 人物マット(人物 = 手前)
        if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte) as? [AnyHashable: Any],
           let matte = try? AVPortraitEffectsMatte(fromDictionaryRepresentation: info) {
            let oriented = matte.applyingExifOrientation(exif)
            if let cg = grayImage(fromMatte: oriented.mattingImage) {
                return CIImage(cgImage: cg)
            }
        }
        return nil
    }

    /// 視差(Float32、大きいほど手前)→ 2%〜98% の範囲で 0...255 に正規化したグレー画像
    private static func grayImage(fromDisparity buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DisparityFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 2, height >= 2, width * height <= 4_000_000,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        // 範囲(無効値を除く)
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let v = row[x]
                guard v.isFinite else { continue }
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        guard hi > lo, (hi - lo) > 1e-6 else { return nil }

        // ヒストグラムで 2% / 98% の値を求める(外れ値で全体が潰れないように)
        let bins = 256
        var histogram = [Int](repeating: 0, count: bins)
        var counted = 0
        let binScale = Float(bins - 1) / (hi - lo)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let v = row[x]
                guard v.isFinite else { continue }
                var bin = Int((v - lo) * binScale)
                if bin < 0 { bin = 0 }
                if bin > bins - 1 { bin = bins - 1 }
                histogram[bin] += 1
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        let lowTarget = Int(Double(counted) * 0.02)
        let highTarget = Int(Double(counted) * 0.98)
        var lowBin = 0
        var highBin = bins - 1
        var running = 0
        var lowFound = false
        for i in 0..<bins {
            running += histogram[i]
            if !lowFound && running >= lowTarget {
                lowBin = i
                lowFound = true
            }
            if running >= highTarget {
                highBin = i
                break
            }
        }
        if highBin <= lowBin { highBin = min(bins - 1, lowBin + 1) }
        let binWidth = (hi - lo) / Float(bins - 1)
        let lo2 = lo + Float(lowBin) * binWidth
        let hi2 = lo + Float(highBin) * binWidth
        guard hi2 > lo2 else { return nil }
        let scale = 255 / (hi2 - lo2)

        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            let rowOffset = y * width
            for x in 0..<width {
                let v = row[x]
                guard v.isFinite else { continue }
                var n = (v - lo2) * scale
                if n < 0 { n = 0 }
                if n > 255 { n = 255 }
                bytes[rowOffset + x] = UInt8(n)
            }
        }
        return grayCGImage(bytes: bytes, width: width, height: height)
    }

    /// 人物マット(OneComponent8、人物 = 255)をそのままグレー画像にする
    private static func grayImage(fromMatte buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 2, height >= 2, width * height <= 16_000_000,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let rowOffset = y * width
            for x in 0..<width {
                bytes[rowOffset + x] = row[x]
            }
        }
        return grayCGImage(bytes: bytes, width: width, height: height)
    }

    private static func grayCGImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: - 描画

    private struct LayerMotion {
        var backgroundScale: CGFloat
        var foregroundScale: CGFloat
        var backgroundDx: CGFloat
        var foregroundDx: CGFloat
    }

    /// 手前 / 奥それぞれの拡大率と横ずれ(ピクセル)
    private static func layerMotion(direction: ParallaxDirection,
                                    strength: Double,
                                    eased: Double,
                                    width: CGFloat) -> LayerMotion {
        let s = CGFloat(strength)
        switch direction {
        case .zoomIn, .zoomOut:
            let k: CGFloat = direction == .zoomIn ? CGFloat(eased) : CGFloat(1 - eased)
            let bg: CGFloat = 1 + 0.04 * s * k
            let fg: CGFloat = 1 + 0.14 * s * k
            return LayerMotion(backgroundScale: bg, foregroundScale: fg, backgroundDx: 0, foregroundDx: 0)
        case .panLeft, .panRight:
            // +1 → -1(時間とともに左へ)。panRight は逆向き
            let t: CGFloat = CGFloat(1 - 2 * eased)
            let sign: CGFloat = direction == .panLeft ? 1 : -1
            let baseScale: CGFloat = 1 + 0.10 * s
            let fgScale: CGFloat = baseScale * (1 + 0.02 * s)
            let bgDx: CGFloat = sign * 0.012 * s * width * t
            let fgDx: CGFloat = sign * 0.045 * s * width * t
            return LayerMotion(backgroundScale: baseScale, foregroundScale: fgScale, backgroundDx: bgDx, foregroundDx: fgDx)
        }
    }

    /// extent の中心まわりで scale 倍し、横に dx ずらす変換
    private static func aboutCenter(_ extent: CGRect, scale: CGFloat, dx: CGFloat) -> CGAffineTransform {
        let s = (scale.isFinite && scale > 0) ? scale : 1
        var t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
        t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
        t = t.concatenating(CGAffineTransform(translationX: extent.midX + dx, y: extent.midY))
        return t
    }

    /// 奥行きマップ → 写真の大きさに広げ、手前(0.45〜0.75 をなだらかに 0 → 1)だけを白くしたマスク
    private static func nearMask(_ depth: CIImage, extent: CGRect) -> CIImage {
        let d = GeometryMath.normalizedToOrigin(depth)
        let de = d.extent
        let sx = extent.width / max(1, de.width)
        let sy = extent.height / max(1, de.height)
        var mask = d.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let lower: CGFloat = 0.45
        let upper: CGFloat = 0.75
        let gain: CGFloat = 1 / (upper - lower)
        let bias: CGFloat = -lower * gain
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ])
        mask = mask.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        mask = mask.cropped(to: extent)
        let sigma = Double(min(extent.width, extent.height)) * 0.012
        return GeometryMath.blurred(mask, sigma: sigma)
    }

    /// 奥行きが無いときの代用(ゆっくりしたズーム / パン)
    private static func kenBurns(_ base: CIImage, direction: ParallaxDirection, strength: Double, eased: Double) -> CIImage {
        let extent = base.extent
        let s = CGFloat(strength)
        let scale: CGFloat
        var dx: CGFloat = 0
        switch direction {
        case .zoomIn:
            scale = 1 + 0.12 * s * CGFloat(eased)
        case .zoomOut:
            scale = 1 + 0.12 * s * CGFloat(1 - eased)
        case .panLeft, .panRight:
            scale = 1 + 0.10 * s
            let sign: CGFloat = direction == .panLeft ? 1 : -1
            let phase: CGFloat = CGFloat(1 - 2 * eased)
            dx = sign * 0.05 * s * extent.width * phase
        }
        let transform = aboutCenter(extent, scale: scale, dx: dx)
        return base.clampedToExtent().transformed(by: transform).cropped(to: extent)
    }
}
