import Foundation
import CoreImage

// =====================================================================
// FilterLUT: 手続き的に生成する 3D LUT(CIColorCubeWithColorSpace / sRGB)
// フィルムライクなトーンカーブ・スプリットトーン・肌色保護つきの選択的彩度で
// 各 FilterPreset / LookPreset の色を作る。LUT は初回利用時に一度だけ生成してキャッシュする。
// =====================================================================

/// LUT を作るためのパラメータ(値はすべて sRGB ガンマ空間 0...1 で扱う)
struct LUTRecipe {
    /// -1 (寒色) ... 1 (暖色)
    var temperature: Double = 0
    /// -1 (グリーン) ... 1 (マゼンタ)
    var tint: Double = 0
    /// 全体の彩度倍率
    var saturation: Double = 1
    /// 肌色域(色相 ~10...50°)の彩度倍率。全体の彩度を下げても肌はこちらを使う
    var skinSaturation: Double = 1
    /// 肌色を skinTargetHue に寄せる割合 0...1
    var skinHuePull: Double = 0.2
    var skinTargetHue: Double = 24
    /// 緑の色相シフト(+ でティール寄り、- でオリーブ寄り)
    var greenHueShift: Double = 0
    var greenSaturation: Double = 1
    var blueHueShift: Double = 0
    var blueSaturation: Double = 1
    /// S 字カーブの強さ(-0.5 ... 0.9)。負で軟調
    var contrast: Double = 0
    /// ハイライトのロールオフ(0 ... 1.5)
    var shoulder: Double = 0.3
    /// 黒の持ち上げ(出力の最小値)
    var blackLift: Double = 0
    /// 白の上限(出力の最大値)
    var whitePoint: Double = 1
    /// トーンカーブ前のガンマ(> 1 で暗く)
    var gamma: Double = 1
    /// スプリットトーン: 影の色相(度)と量
    var shadowHue: Double = 0
    var shadowAmount: Double = 0
    /// スプリットトーン: ハイライトの色相(度)と量
    var highlightHue: Double = 0
    var highlightAmount: Double = 0
    /// モノクロ
    var monochrome: Bool = false
    /// モノクロ変換時のチャンネル配合(赤多めで肌がきれいになる)
    var monoRed: Double = 0.30
    var monoGreen: Double = 0.59
    var monoBlue: Double = 0.11
}

enum FilterLUT {

    /// 立方体の一辺(32^3 × RGBA float = 512KB / LUT)
    static let dimension: Int = 32

    private static let lock = NSLock()
    private static var cache: [String: NSData] = [:]

    // MARK: - 公開 API

    /// プリセットの LUT(none は nil)
    static func cube(for preset: FilterPreset) -> NSData? {
        guard let recipe = recipe(for: preset) else { return nil }
        return cube(key: "preset.\(preset.rawValue)", recipe: recipe)
    }

    /// ルックの LUT(none は nil)
    static func cube(for look: LookPreset) -> NSData? {
        guard let recipe = recipe(for: look) else { return nil }
        return cube(key: "look.\(look.rawValue)", recipe: recipe)
    }

    /// LUT を適用(extent は変わらない)
    static func apply(_ cube: NSData, to image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": NSNumber(value: dimension),
            "inputCubeData": cube,
            "inputColorSpace": FilterEngineContexts.colorSpace
        ])
    }

    /// 全 LUT をバックグラウンドで事前生成(任意。初回表示のもたつきを避けたいときに呼ぶ)
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            for preset in FilterPreset.allCases { _ = cube(for: preset) }
            for look in LookPreset.allCases { _ = cube(for: look) }
        }
    }

    // MARK: - レシピ

    static func recipe(for preset: FilterPreset) -> LUTRecipe? {
        var r = LUTRecipe()
        switch preset {
        case .none:
            return nil
        case .mono:
            // 階調の豊かなクラシック B&W
            r.monochrome = true
            r.monoRed = 0.36; r.monoGreen = 0.50; r.monoBlue = 0.14
            r.contrast = 0.28
            r.shoulder = 0.45
            r.blackLift = 0.025
            r.whitePoint = 0.98
            r.gamma = 1.04
        case .noir:
            // 締まった黒、硬めのコントラスト
            r.monochrome = true
            r.monoRed = 0.42; r.monoGreen = 0.46; r.monoBlue = 0.12
            r.contrast = 0.62
            r.shoulder = 0.25
            r.blackLift = 0.0
            r.whitePoint = 1.0
            r.gamma = 1.12
        case .sepia:
            // 暖かいセピア(ほんの少しだけ元の色を残す)
            r.saturation = 0.10
            r.skinSaturation = 0.18
            r.skinHuePull = 0
            r.contrast = 0.15
            r.shoulder = 0.5
            r.blackLift = 0.045
            r.whitePoint = 0.96
            r.gamma = 1.05
            r.shadowHue = 22; r.shadowAmount = 0.07
            r.highlightHue = 40; r.highlightAmount = 0.08
        case .chrome:
            // 艶のあるリッチな色、ハイライトはわずかに涼しく
            r.saturation = 1.08
            r.skinSaturation = 1.0
            r.skinHuePull = 0.3
            r.contrast = 0.3
            r.shoulder = 0.45
            r.blackLift = 0.01
            r.gamma = 1.05
            r.greenHueShift = -6
            r.blueSaturation = 1.12
            r.shadowHue = 205; r.shadowAmount = 0.025
            r.highlightHue = 45; r.highlightAmount = 0.015
        case .fade:
            // 黒を持ち上げた軟調のフィルム
            r.saturation = 0.82
            r.skinSaturation = 0.95
            r.skinHuePull = 0.25
            r.contrast = -0.12
            r.shoulder = 0.6
            r.blackLift = 0.085
            r.whitePoint = 0.93
            r.gamma = 1.06
            r.shadowHue = 185; r.shadowAmount = 0.025
            r.highlightHue = 40; r.highlightAmount = 0.02
        case .instant:
            // インスタントフィルム: 暖かいハイライトと緑がかった影
            r.temperature = 0.15
            r.saturation = 0.9
            r.skinSaturation = 1.0
            r.skinHuePull = 0.3
            r.contrast = 0.1
            r.shoulder = 0.7
            r.blackLift = 0.05
            r.whitePoint = 0.95
            r.gamma = 1.05
            r.greenHueShift = -8
            r.shadowHue = 165; r.shadowAmount = 0.035
            r.highlightHue = 45; r.highlightAmount = 0.05
        case .process:
            // クロスプロセス風: 青緑の影、黄みのハイライト、緑はティールへ
            r.saturation = 0.92
            r.skinSaturation = 1.0
            r.skinHuePull = 0.4
            r.contrast = 0.22
            r.shoulder = 0.5
            r.blackLift = 0.03
            r.whitePoint = 0.97
            r.gamma = 1.04
            r.greenHueShift = 15
            r.greenSaturation = 0.9
            r.shadowHue = 190; r.shadowAmount = 0.055
            r.highlightHue = 52; r.highlightAmount = 0.04
        case .transfer:
            // 古いテレシネ転写: 暖色・オリーブ・やや軟調
            r.temperature = 0.2
            r.saturation = 0.86
            r.skinSaturation = 0.97
            r.skinHuePull = 0.3
            r.contrast = 0.16
            r.shoulder = 0.6
            r.blackLift = 0.04
            r.whitePoint = 0.95
            r.gamma = 1.05
            r.greenHueShift = -12
            r.greenSaturation = 0.85
            r.shadowHue = 30; r.shadowAmount = 0.03
            r.highlightHue = 42; r.highlightAmount = 0.03
        case .tonal:
            // やわらかいモノクロ
            r.monochrome = true
            r.monoRed = 0.33; r.monoGreen = 0.54; r.monoBlue = 0.13
            r.contrast = 0.0
            r.shoulder = 0.7
            r.blackLift = 0.05
            r.whitePoint = 0.95
            r.gamma = 1.05
        case .vivid:
            // 鮮やかだが肌は自然に(飽和済みの色は伸ばしすぎない)
            r.saturation = 1.24
            r.skinSaturation = 1.04
            r.skinHuePull = 0.35
            r.contrast = 0.25
            r.shoulder = 0.5
            r.gamma = 1.05
            r.greenHueShift = 6
            r.greenSaturation = 1.15
            r.blueSaturation = 1.18
        case .cool:
            // 涼しい色温度。肌は色相を引き戻して血色を保つ
            r.temperature = -0.38
            r.saturation = 0.95
            r.skinSaturation = 1.0
            r.skinHuePull = 0.45
            r.contrast = 0.12
            r.shoulder = 0.45
            r.blackLift = 0.015
            r.gamma = 1.03
            r.shadowHue = 205; r.shadowAmount = 0.03
        case .warm:
            // 暖かい色温度、ハイライトをほんのり金色に
            r.temperature = 0.36
            r.saturation = 0.98
            r.skinSaturation = 1.0
            r.skinHuePull = 0.35
            r.contrast = 0.12
            r.shoulder = 0.5
            r.blackLift = 0.015
            r.gamma = 1.03
            r.highlightHue = 40; r.highlightAmount = 0.03
        case .vignette:
            // ニュートラルなフィルムトーン(周辺減光は FilterEngine 側で追加)
            r.saturation = 0.95
            r.skinSaturation = 1.0
            r.skinHuePull = 0.25
            r.contrast = 0.18
            r.shoulder = 0.55
            r.blackLift = 0.02
            r.whitePoint = 0.98
            r.gamma = 1.04
            r.shadowHue = 200; r.shadowAmount = 0.015
        }
        return r
    }

    static func recipe(for look: LookPreset) -> LUTRecipe? {
        var r = LUTRecipe()
        switch look {
        case .none:
            return nil
        case .documentary:
            // 彩度控えめ・ティールの影・暖かい肌・軟らかいコントラスト・ハイライトのロールオフ
            r.temperature = 0.03
            r.saturation = 0.80
            r.skinSaturation = 0.98
            r.skinHuePull = 0.35
            r.skinTargetHue = 24
            r.greenHueShift = 10
            r.greenSaturation = 0.82
            r.blueSaturation = 0.88
            r.contrast = 0.12
            r.shoulder = 0.55
            r.blackLift = 0.03
            r.whitePoint = 0.965
            r.gamma = 1.05
            r.shadowHue = 192; r.shadowAmount = 0.05
            r.highlightHue = 36; r.highlightAmount = 0.025
        case .cinematicWarm:
            // 黄金色の暖かい映画調
            r.temperature = 0.3
            r.saturation = 0.94
            r.skinSaturation = 1.0
            r.skinHuePull = 0.3
            r.skinTargetHue = 26
            r.greenHueShift = -12
            r.greenSaturation = 0.85
            r.contrast = 0.18
            r.shoulder = 0.6
            r.blackLift = 0.025
            r.whitePoint = 0.975
            r.gamma = 1.05
            r.shadowHue = 20; r.shadowAmount = 0.025
            r.highlightHue = 42; r.highlightAmount = 0.055
        case .noir:
            // 高コントラストのモノクロ
            r.monochrome = true
            r.monoRed = 0.42; r.monoGreen = 0.48; r.monoBlue = 0.10
            r.contrast = 0.7
            r.shoulder = 0.3
            r.blackLift = 0.01
            r.whitePoint = 0.99
            r.gamma = 1.12
        case .vintage:
            // 色あせたフィルム: 持ち上がった黒、緑がかった影、暖かいハイライト
            r.temperature = 0.1
            r.saturation = 0.76
            r.skinSaturation = 0.9
            r.skinHuePull = 0.3
            r.greenHueShift = -15
            r.greenSaturation = 0.8
            r.blueSaturation = 0.8
            r.contrast = 0.05
            r.shoulder = 0.7
            r.blackLift = 0.09
            r.whitePoint = 0.92
            r.gamma = 1.06
            r.shadowHue = 140; r.shadowAmount = 0.05
            r.highlightHue = 45; r.highlightAmount = 0.06
        }
        return r
    }

    // MARK: - 生成とキャッシュ

    private static func cube(key: String, recipe: LUTRecipe) -> NSData {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let data = makeCube(recipe, dimension: dimension)
        cache[key] = data
        return data
    }

    /// RGBA float32、赤が最も速く変化する順(CIColorCube の仕様)
    static func makeCube(_ recipe: LUTRecipe, dimension n: Int) -> NSData {
        let count = n * n * n * 4
        var values = [Float](repeating: 0, count: count)
        let step = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            let b = Double(bi) * step
            for gi in 0..<n {
                let g = Double(gi) * step
                for ri in 0..<n {
                    let r = Double(ri) * step
                    let out = grade(r, g, b, recipe)
                    values[i] = Float(out.r)
                    values[i + 1] = Float(out.g)
                    values[i + 2] = Float(out.b)
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return data as NSData
    }

    // MARK: - 色変換本体

    static func grade(_ inR: Double, _ inG: Double, _ inB: Double, _ p: LUTRecipe) -> (r: Double, g: Double, b: Double) {
        var r = inR
        var g = inG
        var b = inB

        // 1. ホワイトバランス(輝度は保つ)
        if p.temperature != 0 || p.tint != 0 {
            let t = p.temperature
            let m = p.tint
            r *= 1 + 0.10 * t + 0.02 * m
            g *= 1 + 0.01 * t - 0.05 * m
            b *= 1 - 0.12 * t + 0.02 * m
            let before = luma(inR, inG, inB)
            let after = luma(r, g, b)
            if after > 0.00001 {
                let k = before / after
                r *= k
                g *= k
                b *= k
            }
        }

        var skinW = 0.0

        if p.monochrome {
            // 2a. モノクロ: チャンネル配合 → トーンカーブ
            let wSum = max(p.monoRed + p.monoGreen + p.monoBlue, 0.0001)
            let y = (r * p.monoRed + g * p.monoGreen + b * p.monoBlue) / wSum
            let t = tone(y, p)
            r = t
            g = t
            b = t
        } else {
            // 2b. 色相ごとの調整
            let hsv = rgbToHsv(clamp01(r), clamp01(g), clamp01(b))
            let h = hsv.h
            let s = hsv.s
            let v = hsv.v
            skinW = skinWeight(h: h, s: s, v: v)
            let chromaGate = smoothstep(0.05, 0.15, s)
            let greenW = hueWindow(h, center: 110, inner: 35, outer: 65) * chromaGate
            let blueW = hueWindow(h, center: 215, inner: 25, outer: 50) * chromaGate

            var dh = greenW * p.greenHueShift + blueW * p.blueHueShift
            dh += skinW * p.skinHuePull * hueDelta(from: h, to: p.skinTargetHue)
            if abs(dh) > 0.0001 {
                let rgb = hsvToRgb(wrapHue(h + dh), s, v)
                r = rgb.r
                g = rgb.g
                b = rgb.b
            }

            // 3. 選択的彩度(輝度基準)。肌は skinSaturation を優先
            var sat = p.saturation
            sat *= mix(1, p.greenSaturation, greenW)
            sat *= mix(1, p.blueSaturation, blueW)
            sat = mix(sat, p.skinSaturation, skinW)
            if sat > 1 {
                // すでに鮮やかな色は伸ばしすぎない(バイブランス的)
                sat = 1 + (sat - 1) * (1 - 0.7 * s)
            }
            let y = luma(r, g, b)
            r = y + (r - y) * sat
            g = y + (g - y) * sat
            b = y + (b - y) * sat

            // 4. トーンカーブ: チャンネル別(フィルムらしい発色)と輝度基準(色を保つ)の中間
            let y2 = luma(r, g, b)
            let dy = tone(y2, p) - y2
            r = 0.5 * (r + dy) + 0.5 * tone(r, p)
            g = 0.5 * (g + dy) + 0.5 * tone(g, p)
            b = 0.5 * (b + dy) + 0.5 * tone(b, p)
        }

        // 5. スプリットトーン(肌への影響は半分に)
        if p.shadowAmount > 0 || p.highlightAmount > 0 {
            let yt = luma(r, g, b)
            let protect = 1 - 0.5 * skinW
            if p.shadowAmount > 0 {
                let w = (1 - smoothstep(0.0, 0.6, yt)) * p.shadowAmount * protect
                let tv = tintVector(p.shadowHue)
                r += tv.r * w
                g += tv.g * w
                b += tv.b * w
            }
            if p.highlightAmount > 0 {
                let w = smoothstep(0.4, 1.0, yt) * p.highlightAmount * protect
                let tv = tintVector(p.highlightHue)
                r += tv.r * w
                g += tv.g * w
                b += tv.b * w
            }
        }

        return (clamp01(r), clamp01(g), clamp01(b))
    }

    /// フィルム調トーンカーブ: ガンマ → S 字 → ハイライトのロールオフ → 出力レンジ
    static func tone(_ x0: Double, _ p: LUTRecipe) -> Double {
        var x = clamp01(x0)
        if p.gamma != 1 { x = pow(x, p.gamma) }
        let c = min(max(p.contrast, -0.9), 0.95)
        let s = x * x * (3 - 2 * x)
        x = x + c * (s - x)
        let a = max(p.shoulder, 0)
        if a > 0 {
            // g(0)=0, g(1)=1, 傾き 1 → 1/(1+a) で上側をなだらかに
            x = x * (1 + a * x) / (1 + a * x * x)
        }
        return p.blackLift + (p.whitePoint - p.blackLift) * x
    }

    // MARK: - ヘルパー

    private static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    private static func wrapHue(_ h: Double) -> Double {
        var v = h.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    /// 色相の距離 0...180
    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// h から target への符号付き最短差(-180...180)
    private static func hueDelta(from h: Double, to target: Double) -> Double {
        var d = (target - h).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func hueWindow(_ h: Double, center: Double, inner: Double, outer: Double) -> Double {
        1 - smoothstep(inner, outer, hueDistance(h, center))
    }

    /// 肌色らしさ 0...1(色相 ~10...50°、中程度の彩度、暗すぎない)
    private static func skinWeight(h: Double, s: Double, v: Double) -> Double {
        let hw = hueWindow(h, center: 27, inner: 14, outer: 32)
        let sw = smoothstep(0.08, 0.22, s) * (1 - smoothstep(0.7, 0.95, s))
        let vw = smoothstep(0.15, 0.35, v)
        return hw * sw * vw
    }

    /// 輝度ゼロの色ベクトル(明るさを変えずに色味だけ足す)
    private static func tintVector(_ hue: Double) -> (r: Double, g: Double, b: Double) {
        let c = hsvToRgb(wrapHue(hue), 1, 1)
        let y = luma(c.r, c.g, c.b)
        return (c.r - y, c.g - y, c.b - y)
    }

    private static func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        var h = 0.0
        if delta > 0.000001 {
            if maxV == r {
                h = 60 * ((g - b) / delta)
            } else if maxV == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        h = wrapHue(h)
        let s = maxV > 0.000001 ? delta / maxV : 0
        return (h, s, maxV)
    }

    private static func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var r1 = 0.0
        var g1 = 0.0
        var b1 = 0.0
        switch Int(hp) {
        case 0: r1 = c; g1 = x; b1 = 0
        case 1: r1 = x; g1 = c; b1 = 0
        case 2: r1 = 0; g1 = c; b1 = x
        case 3: r1 = 0; g1 = x; b1 = c
        case 4: r1 = x; g1 = 0; b1 = c
        default: r1 = c; g1 = 0; b1 = x
        }
        return (r1 + m, g1 + m, b1 + m)
    }
}
