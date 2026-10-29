import Foundation
import CoreGraphics
import CoreImage

// =====================================================================
// VideoEffectRenderer: 映像エフェクト(VideoEffectClip)を画面全体にかける。
// VideoCompositor.render の「モザイク → オーバーレイ」の後、質感・手書き・テキスト・キャプションの前に呼ばれる。
// Core Image だけで作る。時間で動くものは、エフェクトの先頭からの秒(local)で決める
// (同じ時刻なら毎回同じ絵になるよう、乱数は時刻から作る)。
// =====================================================================

enum VideoEffectRenderer {

    /// ズームパルス・ビート揺れの 1 拍の長さ(秒。120 BPM)
    static let beatPeriod: Double = 0.5

    /// time に表示中のエフェクトを、開始が早い順に重ねてかける
    static func apply(_ effects: [VideoEffectClip], to frame: CIImage, time: Double, canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        guard canvas.width >= 2, canvas.height >= 2 else { return frame }
        var result = frame
        for effect in effects where effect.contains(timelineTime: time) {
            let local = max(0, time - effect.start)
            result = render(effect.type, image: result, local: local, duration: effect.duration,
                            intensity: effect.intensity, canvas: canvas).cropped(to: canvas)
        }
        return result
    }

    /// 1 つのエフェクトをかける。intensity は 0 ... 1
    static func render(_ type: VideoEffectType, image: CIImage, local t: Double, duration: Double,
                       intensity: Double, canvas: CGRect) -> CIImage {
        let k = min(max(intensity, 0), 1)
        let minSide = Double(min(canvas.width, canvas.height))
        switch type {
        case .shake:
            let amp = minSide * 0.035 * k
            let dx = amp * (sin(t * 41) * 0.6 + sin(t * 23.7) * 0.4)
            let dy = amp * (cos(t * 37) * 0.6 + sin(t * 19.3) * 0.4)
            return transformed(image, scale: 1 + 0.06 * k, rotation: 0.02 * k * sin(t * 29),
                               dx: dx, dy: dy, canvas: canvas)

        case .zoomPulse:
            let phase = beatPhase(t)
            let pulse = exp(-phase * 5)
            return transformed(image, scale: 1 + 0.18 * k * pulse, rotation: 0, dx: 0, dy: 0, canvas: canvas)

        case .beatShake:
            let phase = beatPhase(t)
            let decay = exp(-phase * 7)
            let amp = minSide * 0.04 * k * decay
            return transformed(image, scale: 1 + 0.1 * k * decay, rotation: 0.025 * k * decay * sin(t * 47),
                               dx: amp * sin(t * 60), dy: amp * cos(t * 53), canvas: canvas)

        case .vhs:
            var img = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: NSNumber(value: 1 - 0.35 * k),
                kCIInputContrastKey: NSNumber(value: 1 + 0.1 * k),
                kCIInputBrightnessKey: NSNumber(value: 0.02 * k)
            ])
            let shift = CGFloat(minSide * 0.006 * k * (1 + 0.5 * sin(t * 3)))
            img = channelSplit(img, red: CGPoint(x: shift, y: 0), blue: CGPoint(x: -shift, y: 0), canvas: canvas)
            let slot = floor(t * 6)
            if rand(slot, 1) < 0.4 + 0.4 * k {
                img = displacedBands(img, count: 1, slot: slot, maxShift: minSide * 0.08 * k, canvas: canvas)
            }
            img = scanLines(img, alpha: 0.28 * k, canvas: canvas)
            return grain(img, amount: 0.3 * k, time: t, canvas: canvas)

        case .rgbSplit:
            let slot = floor(t * 10)
            let burst = rand(slot, 1)
            let amp = CGFloat(minSide * 0.025 * k * (0.3 + 0.7 * burst))
            var img = channelSplit(image, red: CGPoint(x: amp, y: amp * 0.3),
                                   blue: CGPoint(x: -amp, y: -amp * 0.2), canvas: canvas)
            if burst > 0.55 {
                img = displacedBands(img, count: 3, slot: slot, maxShift: minSide * 0.1 * k, canvas: canvas)
            }
            return img

        case .noise:
            return grain(image, amount: 0.25 + 0.6 * k, time: t, canvas: canvas)

        case .filmScratch:
            return filmScratch(image, k: k, time: t, canvas: canvas)

        case .lightLeak:
            return lightLeak(image, k: k, time: t, canvas: canvas)

        case .lensFlare:
            return lensFlare(image, k: k, time: t, canvas: canvas)

        case .sparkles:
            return sparkles(image, k: k, time: t, canvas: canvas)

        case .blur:
            return image.clampedToExtent()
                .applyingGaussianBlur(sigma: max(0.1, minSide * 0.025 * k))
                .cropped(to: canvas)

        case .zoomBlur:
            return image.clampedToExtent()
                .applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    "inputAmount": NSNumber(value: minSide * 0.05 * k * (0.6 + 0.4 * sin(t * 3)))
                ])
                .cropped(to: canvas)

        case .motionBlur:
            return image.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: NSNumber(value: max(0.1, minSide * 0.035 * k)),
                    kCIInputAngleKey: NSNumber(value: 0.4 * sin(t * 1.5))
                ])
                .cropped(to: canvas)

        case .neonGlow:
            return neonGlow(image, k: k, time: t, minSide: minSide, canvas: canvas)

        case .monoToColor:
            // 前半は白黒、途中からじわっと色が戻る
            let p = duration > 0 ? t / duration : 1
            let s = smoothstep(0.35, 0.7, p)
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: NSNumber(value: (1 - k) + k * s),
                kCIInputBrightnessKey: NSNumber(value: 0),
                kCIInputContrastKey: NSNumber(value: 1 + 0.1 * k * (1 - s))
            ])

        case .strobe:
            let period = 0.3 - 0.15 * k
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let flash = phase < 0.4 ? 1 - phase / 0.4 : 0
            guard flash > 0.001 else { return image }
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
            return mix(image, white, amount: 0.85 * k * flash)

        case .vignette:
            let radius = Double(hypot(canvas.width, canvas.height)) / 2 * (0.95 - 0.35 * k)
            return image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                kCIInputRadiusKey: NSNumber(value: radius),
                kCIInputIntensityKey: NSNumber(value: 0.5 + 0.8 * k)
            ])

        case .fisheye:
            return image.clampedToExtent()
                .applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputRadiusKey: NSNumber(value: Double(max(canvas.width, canvas.height)) * 0.7),
                    kCIInputScaleKey: NSNumber(value: 0.5 * k * (0.85 + 0.15 * sin(t * 2)))
                ])
                .cropped(to: canvas)

        case .mirror:
            // 左半分を右へ折り返す
            let half = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width / 2, height: canvas.height)
            let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: canvas.minX * 2 + canvas.width, ty: 0)
            let mirrored = image.cropped(to: half).transformed(by: flip)
            return mirrored.composited(over: image)

        case .split2:
            let w = canvas.width, h = canvas.height
            let rects: [CGRect] = h >= w
                ? [CGRect(x: 0, y: 0, width: w, height: h / 2), CGRect(x: 0, y: h / 2, width: w, height: h / 2)]
                : [CGRect(x: 0, y: 0, width: w / 2, height: h), CGRect(x: w / 2, y: 0, width: w / 2, height: h)]
            return tiled(image, rects: rects, canvas: canvas)

        case .split4:
            let w = canvas.width / 2, h = canvas.height / 2
            let rects = [CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: w, y: 0, width: w, height: h),
                         CGRect(x: 0, y: h, width: w, height: h), CGRect(x: w, y: h, width: w, height: h)]
            return tiled(image, rects: rects, canvas: canvas)
        }
    }

    // MARK: - 部品

    /// 0 ... 1 の拍の中の位置
    private static func beatPhase(_ t: Double) -> Double {
        t.truncatingRemainder(dividingBy: beatPeriod) / beatPeriod
    }

    /// 時刻(や番号)から作る 0 ..< 1 の値(同じ入力なら同じ値)
    static func rand(_ a: Double, _ salt: Int) -> Double {
        let x = sin(a * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - floor(x)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let v = min(max((x - a) / (b - a), 0), 1)
        return v * v * (3 - 2 * v)
    }

    /// a から b へ amount(0 ... 1)だけ寄せる
    private static func mix(_ a: CIImage, _ b: CIImage, amount: Double) -> CIImage {
        let m = min(max(amount, 0), 1)
        if m <= 0.001 { return a }
        if m >= 0.999 { return b }
        return a.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: b,
            kCIInputTimeKey: NSNumber(value: m)
        ])
    }

    /// 明るさ・不透明度を k 倍にする(重ねる光の強さ)
    private static func scaled(_ image: CIImage, _ k: Double) -> CIImage {
        let v = CGFloat(min(max(k, 0), 1))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: v)
        ])
    }

    /// 画面の中心を軸に拡大・回転・移動する(端は引き伸ばして黒を出さない)
    private static func transformed(_ image: CIImage, scale: Double, rotation: Double,
                                    dx: Double, dy: Double, canvas: CGRect) -> CIImage {
        let c = CGPoint(x: canvas.midX, y: canvas.midY)
        let t = CGAffineTransform(translationX: c.x + CGFloat(dx), y: c.y + CGFloat(dy))
            .rotated(by: CGFloat(rotation))
            .scaledBy(x: CGFloat(scale), y: CGFloat(scale))
            .translatedBy(x: -c.x, y: -c.y)
        return image.clampedToExtent().transformed(by: t).cropped(to: canvas)
    }

    /// 赤と青をずらす(色ずれ)
    private static func channelSplit(_ image: CIImage, red: CGPoint, blue: CGPoint, canvas: CGRect) -> CIImage {
        let base = image.clampedToExtent()
        func only(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        let r = only(1, 0, 0).transformed(by: CGAffineTransform(translationX: red.x, y: red.y)).cropped(to: canvas)
        let g = only(0, 1, 0).cropped(to: canvas)
        let b = only(0, 0, 1).transformed(by: CGAffineTransform(translationX: blue.x, y: blue.y)).cropped(to: canvas)
        // 色ごとの最大を取ると (r, g, b) に戻る
        return r.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: g])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    /// 横の帯をいくつか左右にずらす(電波の乱れ)
    private static func displacedBands(_ image: CIImage, count: Int, slot: Double, maxShift: Double,
                                       canvas: CGRect) -> CIImage {
        var img = image
        let source = image.clampedToExtent()
        for i in 0..<max(1, count) {
            let y = canvas.minY + canvas.height * CGFloat(rand(slot, 2 + i * 5))
            let bh = canvas.height * CGFloat(0.03 + 0.08 * rand(slot, 3 + i * 5))
            let dx = CGFloat((rand(slot, 4 + i * 5) - 0.5) * 2 * maxShift)
            let band = CGRect(x: canvas.minX, y: y, width: canvas.width, height: bh).intersection(canvas)
            guard !band.isNull, band.height >= 1 else { continue }
            let moved = source.transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: band)
            img = moved.composited(over: img)
        }
        return img
    }

    /// 走査線(細い横じま)
    private static func scanLines(_ image: CIImage, alpha: Double, canvas: CGRect) -> CIImage {
        guard alpha > 0.001,
              let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(alpha)),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                kCIInputWidthKey: NSNumber(value: Double(max(1, canvas.height / 320))),
                kCIInputSharpnessKey: NSNumber(value: 1)
              ])?.outputImage else { return image }
        // 縦じまを 90° 回して横じまにする
        let lines = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: canvas)
        return lines.composited(over: image)
    }

    /// 砂嵐のような粒子(amount 0 ... 1)
    private static func grain(_ image: CIImage, amount: Double, time t: Double, canvas: CGRect) -> CIImage {
        guard amount > 0.001, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let slot = floor(t * 30)
        let grainScale = max(1, Double(min(canvas.width, canvas.height)) / 540)
        let shift = CGAffineTransform(translationX: CGFloat(rand(slot, 7) * 900), y: CGFloat(rand(slot, 8) * 900))
        let gray = noise.transformed(by: shift)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(grainScale), y: CGFloat(grainScale)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .cropped(to: canvas)
        let blended = gray.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        return mix(image, blended, amount: amount)
    }

    /// 丸いぼんやりした光(中心 color → 外側は透明)
    private static func glowSpot(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage? {
        guard radius > 0.5 else { return nil }
        let clear = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
        return CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: center.x, y: center.y),
            "inputRadius0": NSNumber(value: 0),
            "inputRadius1": NSNumber(value: Double(radius)),
            "inputColor0": color,
            "inputColor1": clear
        ])?.outputImage?.cropped(to: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
    }

    private static func filmScratch(_ image: CIImage, k: Double, time t: Double, canvas: CGRect) -> CIImage {
        var img = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: NSNumber(value: 0.35 * k)])
        // 明るさのちらつき
        let flicker = (rand(floor(t * 24), 1) - 0.5) * 0.25 * k
        img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: NSNumber(value: flicker)])
        let slot = floor(t * 12)
        let lineCount = 1 + Int(rand(slot, 2) * 3 * k)
        for i in 0..<lineCount {
            let x = canvas.minX + canvas.width * CGFloat(rand(slot, 10 + i))
            let lw = max(1, canvas.width / 540) * CGFloat(1 + rand(slot, 20 + i))
            let alpha = CGFloat((0.25 + 0.45 * rand(slot, 30 + i)) * k)
            let bright = rand(slot, 40 + i) > 0.4
            let color = bright ? CIColor(red: 1, green: 1, blue: 0.95, alpha: alpha)
                               : CIColor(red: 0.1, green: 0.08, blue: 0.05, alpha: alpha)
            let y0 = canvas.height * CGFloat(rand(slot, 50 + i) * 0.4)
            let y1 = canvas.height * CGFloat(0.6 + rand(slot, 60 + i) * 0.4)
            let line = CIImage(color: color).cropped(to: CGRect(x: x, y: canvas.minY + y0, width: lw, height: max(1, y1 - y0)))
            img = line.composited(over: img)
        }
        // ほこり
        let dustCount = Int(3 + 6 * k)
        let minSide = min(canvas.width, canvas.height)
        for i in 0..<dustCount {
            let p = CGPoint(x: canvas.minX + canvas.width * CGFloat(rand(slot, 70 + i)),
                            y: canvas.minY + canvas.height * CGFloat(rand(slot, 90 + i)))
            let r = minSide * CGFloat(0.002 + 0.006 * rand(slot, 110 + i))
            if let dust = glowSpot(center: p, radius: r, color: CIColor(red: 0.05, green: 0.04, blue: 0.03, alpha: CGFloat(0.7 * k))) {
                img = dust.composited(over: img)
            }
        }
        return img
    }

    private static func lightLeak(_ image: CIImage, k: Double, time t: Double, canvas: CGRect) -> CIImage {
        let w = canvas.width, h = canvas.height
        let big = max(w, h)
        let breath = 0.75 + 0.25 * sin(t * 2.1)
        let p1 = CGPoint(x: canvas.minX + w * CGFloat(0.5 + 0.6 * sin(t * 0.7)),
                         y: canvas.minY + h * CGFloat(0.8 + 0.25 * cos(t * 0.5)))
        let p2 = CGPoint(x: canvas.minX + w * CGFloat(0.2 + 0.4 * cos(t * 0.9)),
                         y: canvas.minY + h * CGFloat(0.2 + 0.3 * sin(t * 0.6)))
        var leak = CIImage(color: CIColor.clear).cropped(to: canvas)
        if let a = glowSpot(center: p1, radius: big * 0.65,
                            color: CIColor(red: 1, green: 0.45, blue: 0.15, alpha: CGFloat(0.85 * k * breath))) {
            leak = a.composited(over: leak)
        }
        if let b = glowSpot(center: p2, radius: big * 0.5,
                            color: CIColor(red: 1, green: 0.25, blue: 0.5, alpha: CGFloat(0.6 * k * breath))) {
            leak = b.composited(over: leak)
        }
        return leak.cropped(to: canvas).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func lensFlare(_ image: CIImage, k: Double, time t: Double, canvas: CGRect) -> CIImage {
        let w = canvas.width, h = canvas.height
        let minSide = min(w, h)
        let c = CGPoint(x: canvas.minX + w * CGFloat(0.25 + 0.5 * (0.5 + 0.5 * sin(t * 0.6))),
                        y: canvas.minY + h * 0.78)
        var flare = CIImage(color: CIColor.clear).cropped(to: canvas)
        if let sun = CIFilter(name: "CISunbeamsGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: c.x, y: c.y),
            kCIInputColorKey: CIColor(red: 1, green: 0.85, blue: 0.6),
            "inputSunRadius": NSNumber(value: Double(minSide) * 0.04),
            "inputMaxStriationRadius": NSNumber(value: 2.6),
            "inputStriationStrength": NSNumber(value: 0.5),
            "inputStriationContrast": NSNumber(value: 1.4),
            kCIInputTimeKey: NSNumber(value: (t * 0.3).truncatingRemainder(dividingBy: 1))
        ])?.outputImage {
            flare = sun.cropped(to: canvas).composited(over: flare)
        }
        // 中心をはさんで反対側に並ぶ光の玉
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let ghosts: [(f: CGFloat, r: CGFloat, color: CIColor)] = [
            (0.5, 0.05, CIColor(red: 0.6, green: 0.9, blue: 1, alpha: 0.35)),
            (1.1, 0.03, CIColor(red: 1, green: 0.6, blue: 0.9, alpha: 0.4)),
            (1.5, 0.09, CIColor(red: 0.7, green: 1, blue: 0.7, alpha: 0.22))
        ]
        for g in ghosts {
            let p = CGPoint(x: c.x + (center.x - c.x) * (1 + g.f), y: c.y + (center.y - c.y) * (1 + g.f))
            if let spot = glowSpot(center: p, radius: minSide * g.r, color: g.color) {
                flare = spot.composited(over: flare)
            }
        }
        return scaled(flare.cropped(to: canvas), k)
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func sparkles(_ image: CIImage, k: Double, time t: Double, canvas: CGRect) -> CIImage {
        let w = canvas.width, h = canvas.height
        let minSide = min(w, h)
        var layer = CIImage(color: CIColor.clear).cropped(to: canvas)
        let count = 14 + Int(22 * k)
        for i in 0..<count {
            let seed = Double(i)
            let speed = 1.5 + rand(seed, 3) * 3
            let phase = rand(seed, 4) * 2 * .pi
            let twinkle = sin(t * speed + phase)
            guard twinkle > 0.05 else { continue }
            // ゆっくり上へ流れる
            let drift = CGFloat((t * (0.02 + 0.03 * rand(seed, 6))).truncatingRemainder(dividingBy: 1))
            let px = canvas.minX + w * CGFloat(rand(seed, 1))
            let py = canvas.minY + (h * (CGFloat(rand(seed, 2)) + drift)).truncatingRemainder(dividingBy: h)
            let size = minSide * CGFloat(0.006 + 0.012 * rand(seed, 5)) * CGFloat(0.6 + 0.4 * twinkle)
            let alpha = CGFloat(twinkle)
            let color = CIColor(red: 1, green: 0.96, blue: 0.82, alpha: alpha)
            if let core = glowSpot(center: CGPoint(x: px, y: py), radius: size * 1.6, color: color) {
                layer = core.composited(over: layer)
            }
            // 十字の光の筋(丸い光を細く引き伸ばす)
            if let streak = glowSpot(center: .zero, radius: size * 4.5,
                                     color: CIColor(red: 1, green: 0.96, blue: 0.82, alpha: alpha * 0.8)) {
                let horizontal = streak.transformed(by: CGAffineTransform(scaleX: 1, y: 0.08))
                    .transformed(by: CGAffineTransform(translationX: px, y: py))
                let vertical = streak.transformed(by: CGAffineTransform(scaleX: 0.08, y: 1))
                    .transformed(by: CGAffineTransform(translationX: px, y: py))
                layer = horizontal.composited(over: layer)
                layer = vertical.composited(over: layer)
            }
        }
        return scaled(layer.cropped(to: canvas), 0.4 + 0.6 * k)
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func neonGlow(_ image: CIImage, k: Double, time t: Double, minSide: Double, canvas: CGRect) -> CIImage {
        let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: NSNumber(value: 6)])
            .cropped(to: canvas)
        let glow = edges.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.5, minSide * 0.01))
            .cropped(to: canvas)
        let neon = edges.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow])
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: NSNumber(value: t * 1.2)])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: NSNumber(value: 1.8),
                kCIInputBrightnessKey: NSNumber(value: 0),
                kCIInputContrastKey: NSNumber(value: 1)
            ])
        let dark = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: NSNumber(value: -1.6)])
        let combined = neon.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: dark])
            .cropped(to: canvas)
        return mix(image, combined, amount: k)
    }

    /// 同じ映像を rects のそれぞれに、はみ出す分を切って敷き詰める(画面の分割)
    private static func tiled(_ image: CIImage, rects: [CGRect], canvas: CGRect) -> CIImage {
        var result = CIImage(color: CIColor.black).cropped(to: canvas)
        for rect in rects {
            let s = max(rect.width / canvas.width, rect.height / canvas.height)
            let tx = rect.midX - canvas.midX * s
            let ty = rect.midY - canvas.midY * s
            let cell = image.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
                .cropped(to: rect)
            result = cell.composited(over: result)
        }
        return result
    }
}
