import Foundation
import CoreGraphics
import CoreImage

// =====================================================================
// BackgroundRemovalRenderer: 背景を消す(自動の切り抜き)とクロマキー。
// VideoCompositor.renderLayer(メインのクリップ)と OverlayRenderer.image(オーバーレイ)から、
// 向きを反映した素材の画像(原点 (0,0))に対して、フィルタより前に呼ばれる。
//   - 自動: SegmentationMasks(人物 / 被写体)の切り抜き → 境界をくっきり / やわらかく → 外を透明に
//   - クロマキー: HSV の色の近さで作った CIColorCubeWithColorSpace(sRGB)で、近い色を透明にし、
//     ふちの色かぶりは消す色の方向の色みを引いて抑える
// メインのクリップでは消した部分を ぼかし / 単色 で埋められる(透明のままなら下は黒)。
// 切り抜きは同じコマ・同じ設定ならキャッシュを使う(止めてスライダーを動かしても作り直さない)。
// =====================================================================

enum BackgroundRemovalRenderer {

    /// image(原点 (0,0)・不透明な素材)の背景を消す。
    /// cacheKey: コマを区別する文字列(クリップ / オーバーレイの ID と時刻)。accurate: 書き出し用のきれいな切り抜き。
    /// fillsBackground: メインのクリップ(消した部分を settings.fill で埋める)。オーバーレイは false(透明のまま)
    /// stream・time: 動画のコマの続き(クリップ / オーバーレイごと)。続けて再生・書き出ししているときは、
    /// 前のコマの切り抜きと混ぜて境界のちらつきを抑える(写真は nil)
    static func apply(_ settings: BackgroundRemoval,
                      to image: CIImage,
                      cacheKey: String,
                      accurate: Bool,
                      fillsBackground: Bool,
                      stream: String? = nil,
                      time: Double? = nil) -> CIImage {
        let rect = image.extent
        guard settings.isActive, !rect.isInfinite, rect.width >= 2, rect.height >= 2 else { return image }

        let cutout: CIImage
        switch settings.mode {
        case .off:
            return image
        case .auto:
            guard let mask = autoMask(settings, image: image, rect: rect, cacheKey: cacheKey, accurate: accurate,
                                      stream: stream, time: time) else {
                return image
            }
            let clear = CIImage(color: CIColor.clear).cropped(to: rect)
            cutout = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ]).cropped(to: rect)
        case .chroma:
            guard let keyed = chromaKeyed(image, settings: settings) else { return image }
            cutout = keyed.cropped(to: rect)
        }

        guard fillsBackground else { return cutout }
        switch settings.fill {
        case .clear:
            return cutout
        case .blur:
            let sigma = Double(min(rect.width, rect.height)) * 0.03
            let background = image.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: rect)
            return cutout.composited(over: background).cropped(to: rect)
        case .color:
            let c = settings.fillColor.clamped()
            let color = CIColor(cgColor: CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                                                 blue: CGFloat(c.blue), alpha: 1))
            let background = CIImage(color: color).cropped(to: rect)
            return cutout.composited(over: background).cropped(to: rect)
        }
    }

    // MARK: - 自動(人物 / 被写体)

    private static let maskCache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 8
        return c
    }()

    /// ちらつきを抑えるための、流れ(クリップ / オーバーレイ)ごとの前のコマの切り抜き
    private struct PreviousMask {
        let time: Double
        let size: CGSize
        let settingsKey: String
        let mask: CIImage
    }
    private static let previousLock = NSLock()
    private static var previousMasks: [String: PreviousMask] = [:]

    /// 前のコマと混ぜる割合(前のコマの分)。続くコマ(0.1 秒以内)のときだけ混ぜる
    private static let temporalCarry: CGFloat = 0.35

    private static func autoMask(_ settings: BackgroundRemoval,
                                 image: CIImage,
                                 rect: CGRect,
                                 cacheKey: String,
                                 accurate: Bool,
                                 stream: String?,
                                 time: Double?) -> CIImage? {
        let settingsKey = "\(settings.target.rawValue)|\(accurate ? 1 : 0)"
        let key = "\(cacheKey)|\(settingsKey)|\(Int(rect.width))x\(Int(rect.height))" as NSString
        let raw: CIImage
        if let cached = maskCache.object(forKey: key) {
            raw = cached
        } else {
            let kind: SegmentationMasks.Kind
            switch settings.target {
            case .person: kind = .person(accurate: accurate)
            case .subject: kind = .foreground(point: nil)
            }
            // プレビューは縮めてから渡す(速さ優先)。書き出しは大きめ。
            // どちらも元の映像の輪郭に沿って広げる(ただ引き伸ばすと境界がぼやけ、背景がにじむ)
            guard let made = SegmentationMasks.mask(for: image, in: rect, kind: kind,
                                                    maxInputSide: accurate ? 1920 : 1024,
                                                    edgeAware: true) else { return nil }
            // プレビューと書き出しが同時に走っても前のコマを取り合わないよう、流れを分ける
            let smoothed = temporallySmoothed(made, rect: rect, settingsKey: settingsKey,
                                              stream: stream.map { "\($0)|\(accurate ? 1 : 0)" }, time: time)
            maskCache.setObject(smoothed, forKey: key)
            raw = smoothed
        }
        return refinedMask(raw, softness: settings.edgeSoftness, rect: rect)
    }

    /// 続けて再生・書き出ししているときは前のコマの切り抜きと混ぜる(人物の境界が毎コマ揺れるのを抑える)。
    /// 飛んだとき(シーク・逆戻り)・大きさや設定が変わったときは混ぜない
    private static func temporallySmoothed(_ mask: CIImage, rect: CGRect, settingsKey: String,
                                           stream: String?, time: Double?) -> CIImage {
        guard let stream, let time, time.isFinite else { return mask }
        previousLock.lock()
        let previous = previousMasks[stream]
        previousLock.unlock()
        var result = mask
        if let previous, previous.size == rect.size, previous.settingsKey == settingsKey {
            let dt = time - previous.time
            if dt > 0.0001, dt <= 0.1 {
                // result = mask × (1 - carry) + previous × carry(不透明のまま混ぜる)
                result = mask.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: previous.mask,
                    kCIInputTimeKey: NSNumber(value: Double(temporalCarry))
                ]).cropped(to: rect)
            }
        }
        previousLock.lock()
        if previousMasks.count > 16, previousMasks[stream] == nil {
            previousMasks.removeAll()
        }
        // 混ぜる前の切り抜きを残す(混ぜた結果を残すと、前のコマの前のコマ…と描く手順がつながって重くなる)
        previousMasks[stream] = PreviousMask(time: time, size: rect.size, settingsKey: settingsKey, mask: mask)
        previousLock.unlock()
        return result
    }

    /// 境界のぼかし: 小さいほどくっきり(コントラストを上げる)、大きいほどやわらかく(ぼかす)
    private static func refinedMask(_ mask: CIImage, softness: Double, rect: CGRect) -> CIImage {
        let s = softness.isFinite ? min(max(softness, 0), 1) : 0.3
        var m = mask
        if s < 0.3 {
            let gain = CGFloat(1 + (0.3 - s) / 0.3 * 3)
            let bias = 0.5 * (1 - gain)
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
        }
        let sigma = s * Double(min(rect.width, rect.height)) * 0.012
        if sigma > 0.3 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: sigma)
        }
        return m.cropped(to: rect)
    }

    // MARK: - クロマキー

    private static let cubeDimension = 48
    private static let cubeCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 4
        return c
    }()
    private static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func chromaKeyed(_ image: CIImage, settings: BackgroundRemoval) -> CIImage? {
        let data = cubeData(settings)
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": NSNumber(value: cubeDimension),
            "inputCubeData": data,
            "inputColorSpace": sRGB
        ])
    }

    private static func cubeData(_ settings: BackgroundRemoval) -> Data {
        let key = settings.keyColor.clamped()
        func q(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 1000).rounded()) }
        let cacheKey = "\(key.hex)|\(q(settings.strength))|\(q(settings.edgeSoftness))|\(q(settings.spill))" as NSString
        if let cached = cubeCache.object(forKey: cacheKey) {
            return cached as Data
        }
        let data = makeCube(key: key,
                            strength: min(max(settings.strength, 0), 1),
                            softness: min(max(settings.edgeSoftness, 0), 1),
                            spill: min(max(settings.spill, 0), 1))
        cubeCache.setObject(data as NSData, forKey: cacheKey)
        return data
    }

    /// RGB(0...1)→ HSV(h は 0..<1 の回転、s・v は 0...1)
    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 1e-6 {
            if maxC == r {
                h = (g - b) / delta
            } else if maxC == g {
                h = 2 + (b - r) / delta
            } else {
                h = 4 + (r - g) / delta
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC > 1e-6 ? delta / maxC : 0
        return (h, s, maxC)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        if edge1 <= edge0 { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 消す色にどれだけ近いか(1 = 消す、0 = 残す)と、色かぶりを抑えた色を並べた立方体(sRGB、乗算済みアルファ)
    private static func makeCube(key: BackgroundRemovalColor, strength: Double, softness: Double, spill: Double) -> Data {
        let n = cubeDimension
        let k = hsv(key.red, key.green, key.blue)
        let keyIsGray = k.s < 0.12

        // 色の幅(強さで広がる)と、残す / 消すの境目の幅(境界のぼかしで広がる)
        let hueTol = 0.05 + strength * 0.13
        let hueSoft = 0.015 + softness * 0.10
        let satMin = max(0.06, k.s * (0.6 - 0.45 * strength))
        let satSoft = 0.04 + softness * 0.12
        let rgbTol = 0.05 + strength * 0.25
        let rgbSoft = 0.02 + softness * 0.15

        // 色かぶりを抑える方向(消す色の、明るさを除いた色み)
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.299 * r + 0.587 * g + 0.114 * b }
        let ky = luma(key.red, key.green, key.blue)
        var dir = (key.red - ky, key.green - ky, key.blue - ky)
        let len = sqrt(dir.0 * dir.0 + dir.1 * dir.1 + dir.2 * dir.2)
        let canDespill = len > 0.05 && spill > 0.001
        if len > 1e-6 { dir = (dir.0 / len, dir.1 / len, dir.2 / len) }

        var values = [Float](repeating: 0, count: n * n * n * 4)
        let scale = 1 / Double(n - 1)
        var index = 0
        for bi in 0..<n {
            let b = Double(bi) * scale
            for gi in 0..<n {
                let g = Double(gi) * scale
                for ri in 0..<n {
                    let r = Double(ri) * scale
                    let keyness: Double
                    if keyIsGray {
                        let dr = r - key.red, dg = g - key.green, db = b - key.blue
                        let d = sqrt(dr * dr + dg * dg + db * db) / sqrt(3.0)
                        keyness = 1 - smoothstep(rgbTol, rgbTol + rgbSoft, d)
                    } else {
                        let p = hsv(r, g, b)
                        var dh = abs(p.h - k.h)
                        if dh > 0.5 { dh = 1 - dh }
                        let hueMatch = 1 - smoothstep(hueTol, hueTol + hueSoft, dh)
                        let satMatch = smoothstep(satMin - satSoft, satMin, p.s)
                        // とても暗いところは色が分からないので残す
                        let valMatch = smoothstep(0.04, 0.14, p.v)
                        keyness = hueMatch * satMatch * valMatch
                    }
                    let alpha = 1 - keyness

                    var outR = r, outG = g, outB = b
                    if canDespill, alpha > 0.001 {
                        let y = luma(r, g, b)
                        let c = (r - y, g - y, b - y)
                        let proj = c.0 * dir.0 + c.1 * dir.1 + c.2 * dir.2
                        if proj > 0 {
                            let amount = proj * spill
                            outR = min(max(r - amount * dir.0, 0), 1)
                            outG = min(max(g - amount * dir.1, 0), 1)
                            outB = min(max(b - amount * dir.2, 0), 1)
                        }
                    }
                    values[index] = Float(outR * alpha)
                    values[index + 1] = Float(outG * alpha)
                    values[index + 2] = Float(outB * alpha)
                    values[index + 3] = Float(alpha)
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
