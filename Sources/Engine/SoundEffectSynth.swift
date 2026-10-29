import Foundation
import AVFoundation

// =====================================================================
// 効果音の合成。正弦波・ノイズ・フィルターの組み合わせで、短い SE を PCM(モノラル 44.1kHz)で作る。
// 乱数は種を固定しているので、作り直しても同じ音になる(トリム位置がずれない)。
// =====================================================================

enum SoundEffectSynth {
    static let sampleRate: Double = 44100
    /// 仕上がりのピーク(-3dB 程度。重ねても割れにくい大きさ)
    static let targetPeak: Float = 0.7

    // MARK: - 部品

    /// 種を固定した乱数(splitmix64)
    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0..<1
        mutating func unit() -> Double {
            Double(next() >> 11) / 9_007_199_254_740_992.0
        }

        /// -1...1 のホワイトノイズ
        mutating func noise() -> Float {
            Float(unit() * 2 - 1)
        }

        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }
    }

    /// 状態変数フィルター(TPT 型。周波数を毎サンプル変えても安定)
    struct Filter {
        private var ic1: Float = 0
        private var ic2: Float = 0

        mutating func process(_ x: Float, cutoff: Double, q: Double) -> (low: Float, band: Float, high: Float) {
            let f = min(max(cutoff, 20), SoundEffectSynth.sampleRate * 0.45)
            let g = Float(tan(Double.pi * f / SoundEffectSynth.sampleRate))
            let k = Float(1 / max(q, 0.1))
            let a1 = 1 / (1 + g * (g + k))
            let a2 = g * a1
            let a3 = g * a2
            let v3 = x - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return (v2, v1, x - k * v1 - v2)
        }
    }

    /// 位相を積み上げる発振器(周波数を変えても途切れない)
    struct Oscillator {
        private(set) var phase: Double = 0

        /// 今の位相の正弦波を返して、freq だけ進める
        mutating func sine(_ freq: Double) -> Float {
            let v = Float(sin(phase * 2 * Double.pi))
            advance(freq)
            return v
        }

        /// 矩形波(-1 / 1)
        mutating func square(_ freq: Double) -> Float {
            let v: Float = phase < 0.5 ? 1 : -1
            advance(freq)
            return v
        }

        /// 基音 + 倍音(h2: 2 倍音の量、h3: 3 倍音の量)
        mutating func tone(_ freq: Double, h2: Float = 0, h3: Float = 0) -> Float {
            let p = phase * 2 * Double.pi
            let v = Float(sin(p)) + h2 * Float(sin(2 * p)) + h3 * Float(sin(3 * p))
            advance(freq)
            return v
        }

        private mutating func advance(_ freq: Double) {
            phase += freq / SoundEffectSynth.sampleRate
            if phase >= 1 { phase -= floor(phase) }
        }
    }

    static func frameCount(_ seconds: Double) -> Int {
        max(1, Int(seconds * sampleRate))
    }

    static func time(_ i: Int) -> Double {
        Double(i) / sampleRate
    }

    /// 立ち上がり attack 秒で 1 まで上げ、そのあと指数で減衰
    static func attackDecay(_ t: Double, attack: Double, decay: Double) -> Float {
        if t < attack { return Float(t / attack) }
        return Float(exp(-(t - attack) * decay))
    }

    /// 0...1 の進み具合 p で、peak の位置がいちばん大きい山型(なめらか)
    static func hump(_ p: Double, peak: Double) -> Float {
        let x = p < peak ? p / peak : 1 - (p - peak) / max(1 - peak, 0.0001)
        let s = sin(Double.pi / 2 * min(max(x, 0), 1))
        return Float(s * s)
    }

    /// src を dst の at 秒の位置に gain 倍で足す
    static func mix(_ src: [Float], into dst: inout [Float], at seconds: Double, gain: Float = 1) {
        let offset = Int(seconds * sampleRate)
        guard offset < dst.count else { return }
        let n = min(src.count, dst.count - offset)
        guard n > 0 else { return }
        for i in 0..<n {
            dst[offset + i] += src[i] * gain
        }
    }

    /// ピークをそろえ、頭と終わりにごく短いフェードをかける(プチッという音を防ぐ)
    static func finish(_ samples: [Float]) -> [Float] {
        var out = samples
        var peak: Float = 0
        for v in out where v.isFinite { peak = max(peak, abs(v)) }
        guard peak > 0 else { return out }
        let scale = targetPeak / peak
        for i in out.indices {
            out[i] = out[i].isFinite ? out[i] * scale : 0
        }
        let fadeIn = min(out.count, frameCount(0.001))
        for i in 0..<fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        let fadeOut = min(out.count, frameCount(0.006))
        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }

    // MARK: - 書き出し

    enum SynthError: Error {
        case bufferUnavailable
    }

    /// 16bit PCM の .caf に書き出す
    static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // file はこの関数を抜けると閉じられる
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let channel = buffer.floatChannelData?[0] else {
            throw SynthError.bufferUnavailable
        }
        for i in 0..<samples.count {
            channel[i] = samples[i]
        }
        buffer.frameLength = count
        try file.write(from: buffer)
    }

    // MARK: - 種類ごとの合成

    static func render(_ kind: SoundEffectKind) -> [Float] {
        let raw: [Float]
        switch kind {
        case .whoosh: raw = whoosh()
        case .swooshUp: raw = swoosh(up: true)
        case .swooshDown: raw = swoosh(up: false)
        case .swipe: raw = swipe()
        case .riser: raw = riser()
        case .pop: raw = pop()
        case .click: raw = click()
        case .bubble: raw = bubble()
        case .boing: raw = boing()
        case .kira: raw = kira()
        case .sparkle: raw = sparkle()
        case .bell: raw = bell()
        case .success: raw = success()
        case .impact: raw = impact()
        case .drum: raw = drum()
        case .cymbal: raw = cymbal()
        case .heartbeat: raw = heartbeat()
        case .glitch: raw = glitch()
        case .shutter: raw = shutter()
        case .typing: raw = typing()
        case .notification: raw = notification()
        }
        return finish(raw)
    }

    // ---- 動き ----

    /// シュッ: 帯域ノイズの中心を上げて下げる
    private static func whoosh() -> [Float] {
        let duration = 0.5
        let n = frameCount(duration)
        var rng = Random(seed: 101)
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / duration
            let cutoff = 350 * pow(9.0, sin(Double.pi * pow(p, 0.8)))
            let y = filter.process(rng.noise(), cutoff: cutoff, q: 1.3).band
            out[i] = y * hump(p, peak: 0.45)
        }
        return out
    }

    /// シュワッ: 上へ(音が上がる)/ 下へ(音が下がる)
    private static func swoosh(up: Bool) -> [Float] {
        let duration = 0.65
        let n = frameCount(duration)
        var rng = Random(seed: up ? 102 : 103)
        var filter = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / duration
            let rise = up ? pow(p, 1.4) : 1 - pow(p, 0.7)
            let cutoff = 300 * pow(20.0, rise)
            let toneFreq = 220 * pow(4.5, rise)
            let env = hump(p, peak: up ? 0.8 : 0.2)
            let y = filter.process(rng.noise(), cutoff: cutoff, q: 1.6).band
            out[i] = (y + 0.12 * osc.sine(toneFreq)) * env
        }
        return out
    }

    /// スワイプ: 高めのノイズを短くこする
    private static func swipe() -> [Float] {
        let duration = 0.24
        let n = frameCount(duration)
        var rng = Random(seed: 104)
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / duration
            let cutoff = 2000 * pow(2.5, p)
            let y = filter.process(rng.noise(), cutoff: cutoff, q: 0.9).band
            out[i] = y * hump(p, peak: 0.3)
        }
        return out
    }

    /// ライザー: ノイズとうなりのある音がだんだん上がって大きくなる
    private static func riser() -> [Float] {
        let duration = 2.2
        let n = frameCount(duration)
        var rng = Random(seed: 105)
        var filter = Filter()
        var a = Oscillator()
        var b = Oscillator()
        var tremolo = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / duration
            let cutoff = 200 * pow(40.0, p * p)
            let freq = 180 * pow(8.0, pow(p, 1.5))
            let trem = 0.65 + 0.35 * tremolo.sine(4 + 20 * p)
            let noise = filter.process(rng.noise(), cutoff: cutoff, q: 2.2).band
            let tone = 0.5 * (a.sine(freq) + b.sine(freq * 1.012))
            let env = Float(pow(p, 1.6))
            out[i] = (0.6 * noise + 0.4 * tone * trem) * env
        }
        return out
    }

    // ---- ポップ ----

    /// ポン: 高い音から素早く下がる短い音
    private static func pop() -> [Float] {
        let duration = 0.16
        let n = frameCount(duration)
        var rng = Random(seed: 201)
        var osc = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let freq = 300 + 700 * exp(-t * 60)
            let body = osc.sine(freq) * attackDecay(t, attack: 0.002, decay: 32)
            let tick = filter.process(rng.noise(), cutoff: 3000, q: 0.7).low * Float(exp(-t * 600)) * 0.4
            out[i] = body + tick
        }
        return out
    }

    /// カチッ: ごく短い高い音
    private static func click() -> [Float] {
        let duration = 0.06
        let n = frameCount(duration)
        var rng = Random(seed: 202)
        var osc = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let noise = filter.process(rng.noise(), cutoff: 2200, q: 0.7).high * Float(exp(-t * 400))
            let tone = osc.sine(3200) * Float(exp(-t * 220)) * 0.5
            out[i] = noise + tone
        }
        return out
    }

    /// ポコッ: 上がる短い音を 2 つ(泡)
    private static func bubble() -> [Float] {
        let duration = 0.36
        var out = [Float](repeating: 0, count: frameCount(duration))
        func one(low: Double, high: Double, length: Double) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let freq = low * pow(high / low, min(t / 0.06, 1))
                s[i] = osc.sine(freq) * attackDecay(t, attack: 0.004, decay: 40)
            }
            return s
        }
        mix(one(low: 400, high: 1400, length: 0.2), into: &out, at: 0)
        mix(one(low: 520, high: 1800, length: 0.2), into: &out, at: 0.13, gain: 0.7)
        return out
    }

    /// ビヨーン: ばねのように揺れる音
    private static func boing() -> [Float] {
        let duration = 0.85
        let n = frameCount(duration)
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let wobble: Double = 90 * sin(2 * Double.pi * 8 * t) * exp(-t * 3)
            let freq: Double = 210 + wobble + 40 * t
            out[i] = osc.tone(freq, h2: 0.35) * attackDecay(t, attack: 0.005, decay: 4)
        }
        return out
    }

    // ---- キラキラ ----

    /// キラーン: 高い音が少し上がって長く響く
    private static func kira() -> [Float] {
        let duration = 1.4
        let n = frameCount(duration)
        var rng = Random(seed: 301)
        var filter = Filter()
        var o1 = Oscillator()
        var o2 = Oscillator()
        var o3 = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let glide = 1760 * pow(1.5, min(t / 0.08, 1))
            let vibrato = t > 0.1 ? 1 + 0.004 * sin(2 * Double.pi * 6 * t) : 1
            let f = glide * vibrato
            var v = o1.sine(f) * attackDecay(t, attack: 0.003, decay: 3)
            v += 0.4 * o2.sine(f * 2.01) * attackDecay(t, attack: 0.003, decay: 5)
            v += 0.15 * o3.sine(f * 3.98) * attackDecay(t, attack: 0.003, decay: 8)
            let shimmer = filter.process(rng.noise(), cutoff: 7000, q: 0.7).high * Float(exp(-t * 6)) * 0.12
            out[i] = v + shimmer
        }
        return out
    }

    /// キラキラ: 高い短い音がちりばめられる
    private static func sparkle() -> [Float] {
        let duration = 1.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 302)
        func ping(freq: Double) -> [Float] {
            let n = frameCount(0.3)
            var a = Oscillator()
            var b = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                s[i] = (a.sine(freq) + 0.3 * b.sine(freq * 2.76)) * attackDecay(t, attack: 0.002, decay: 16)
            }
            return s
        }
        for k in 0..<16 {
            // 前半ほど密に
            let at = pow(Double(k) / 16, 1.3) * 0.85 + rng.uniform(0...0.03)
            let freq = rng.uniform(2500...6500)
            let gain = Float(rng.uniform(0.4...1.0)) * Float(1 - Double(k) / 24)
            mix(ping(freq: freq), into: &out, at: at, gain: gain)
        }
        return out
    }

    /// チーン: 金属のベル(倍音が整数倍でない)
    private static func bell() -> [Float] {
        let duration = 2.2
        let n = frameCount(duration)
        let f0 = 1320.0
        let ratios: [Double] = [1, 2.0, 2.76, 5.4, 8.93]
        let amps: [Float] = [1, 0.3, 0.5, 0.25, 0.12]
        let decays: [Double] = [1.8, 2.5, 3.5, 6, 9]
        var oscs = [Oscillator](repeating: Oscillator(), count: ratios.count)
        var beat = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var v: Float = 0
            for j in ratios.indices {
                v += amps[j] * oscs[j].sine(f0 * ratios[j]) * attackDecay(t, attack: 0.002, decay: decays[j])
            }
            // わずかにずらした音でうなりをつける
            v += 0.5 * beat.sine(f0 * 1.003) * attackDecay(t, attack: 0.002, decay: decays[0])
            out[i] = v
        }
        return out
    }

    /// 成功チャイム: ド・ミ・ソ・ドを素早く
    private static func success() -> [Float] {
        let duration = 1.1
        var out = [Float](repeating: 0, count: frameCount(duration))
        let notes: [Double] = [523.25, 659.25, 783.99, 1046.5]
        let starts: [Double] = [0, 0.08, 0.16, 0.26]
        for (index, freq) in notes.enumerated() {
            let isLast = index == notes.count - 1
            let length = duration - starts[index]
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                s[i] = osc.tone(freq, h2: 0.25, h3: 0.1) * attackDecay(t, attack: 0.005, decay: isLast ? 4.5 : 9)
            }
            mix(s, into: &out, at: starts[index], gain: isLast ? 1 : 0.8)
        }
        return out
    }

    // ---- 衝撃 ----

    /// ドン: 低い音と土煙のようなノイズ(少し歪ませて迫力を出す)
    private static func impact() -> [Float] {
        let duration = 1.8
        let n = frameCount(duration)
        var rng = Random(seed: 401)
        var low = Filter()
        var crack = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let sub = osc.sine(35 + 60 * exp(-t * 8)) * attackDecay(t, attack: 0.003, decay: 2.5)
            let x = rng.noise()
            let rumble = low.process(x, cutoff: 100 + 2000 * exp(-t * 6), q: 0.7).low * Float(exp(-t * 10)) * 0.6
            let snap = crack.process(x, cutoff: 1200, q: 1).band * Float(exp(-t * 40)) * 0.3
            let v = sub + rumble + snap
            out[i] = Float(tanh(Double(v) * 2) / tanh(2))
        }
        return out
    }

    /// ドラム: バスドラム
    private static func drum() -> [Float] {
        let duration = 0.5
        let n = frameCount(duration)
        var rng = Random(seed: 402)
        var filter = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let body = osc.sine(50 + 110 * exp(-t * 30)) * Float(exp(-t * 7))
            let beater = filter.process(rng.noise(), cutoff: 3000, q: 0.7).low * Float(exp(-t * 300)) * 0.3
            out[i] = Float(tanh(Double(body + beater) * 1.5))
        }
        return out
    }

    /// シャーン: 金属的な矩形波の重なり + 高いノイズ(シンバル風)
    private static func cymbal() -> [Float] {
        let duration = 1.8
        let n = frameCount(duration)
        var rng = Random(seed: 403)
        let freqs: [Double] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map { $0 * 1.7 }
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var metal = Filter()
        var hiss = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var sum: Float = 0
            for j in freqs.indices { sum += oscs[j].square(freqs[j]) }
            sum /= Float(freqs.count)
            let m = metal.process(sum, cutoff: 6000, q: 0.7).high
            let h = hiss.process(rng.noise(), cutoff: 7000, q: 0.7).high * 0.6
            out[i] = (m + h) * attackDecay(t, attack: 0.002, decay: 2.2)
        }
        return out
    }

    /// ドクン: 心臓の音(ドッ・クン)
    private static func heartbeat() -> [Float] {
        let duration = 1.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        func thump() -> [Float] {
            let n = frameCount(0.3)
            var osc = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let v = osc.sine(45 + 35 * exp(-t * 25)) * attackDecay(t, attack: 0.008, decay: 18)
                s[i] = filter.process(v, cutoff: 300, q: 0.7).low
            }
            return s
        }
        let beat = thump()
        mix(beat, into: &out, at: 0)
        mix(beat, into: &out, at: 0.26, gain: 0.75)
        return out
    }

    /// ザザッ: 途切れ途切れのノイズと電子音(グリッチ)
    private static func glitch() -> [Float] {
        let duration = 0.6
        let n = frameCount(duration)
        var rng = Random(seed: 404)
        var out = [Float](repeating: 0, count: n)
        var index = 0
        while index < n {
            let length = min(frameCount(rng.uniform(0.025...0.06)), n - index)
            let type = Int(rng.uniform(0...2.999))
            let gain = Float(rng.uniform(0.5...1.0))
            let hold = Int(rng.uniform(4...16))
            let freq = rng.uniform(200...2000)
            var osc = Oscillator()
            var held: Float = 0
            let fade = max(1, min(length / 2, frameCount(0.001)))
            for i in 0..<length {
                var v: Float
                switch type {
                case 0:
                    v = 0
                case 1:
                    // 荒いノイズ(同じ値を何サンプルか続ける)
                    if i % hold == 0 { held = rng.noise() }
                    v = held
                default:
                    v = osc.square(freq) * 0.6
                }
                let edge = min(i, length - 1 - i)
                if edge < fade { v *= Float(edge) / Float(fade) }
                out[index + i] = v * gain
            }
            index += length
        }
        return out
    }

    // ---- 日常 ----

    /// カシャ: シャッターの 2 回のクリック
    private static func shutter() -> [Float] {
        let duration = 0.3
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 501)
        func snap(cutoff: Double, thump: Double) -> [Float] {
            let n = frameCount(0.06)
            var filter = Filter()
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let noise = filter.process(rng.noise(), cutoff: cutoff, q: 0.8).band * Float(exp(-t * 120))
                let low = osc.sine(thump) * Float(exp(-t * 60)) * 0.5
                s[i] = noise + low
            }
            return s
        }
        // 幕が走る音
        let slideStart = 0.01
        let slideLength = 0.07
        var slideFilter = Filter()
        var slide = [Float](repeating: 0, count: frameCount(slideLength))
        for i in slide.indices {
            let p = time(i) / slideLength
            slide[i] = slideFilter.process(rng.noise(), cutoff: 2500, q: 1).band * hump(p, peak: 0.5)
        }
        mix(snap(cutoff: 1800, thump: 180), into: &out, at: 0, gain: 0.8)
        mix(slide, into: &out, at: slideStart, gain: 0.15)
        mix(snap(cutoff: 3000, thump: 150), into: &out, at: 0.085)
        return out
    }

    /// カタカタ: キーボードを打つ音
    private static func typing() -> [Float] {
        let duration = 1.3
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 502)
        var at = 0.02
        while at < 1.15 {
            let n = frameCount(0.05)
            let center = rng.uniform(2000...4000)
            let tone = rng.uniform(1200...2200)
            var band = Filter()
            var body = Filter()
            var osc = Oscillator()
            var key = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let x = rng.noise()
                let tick = band.process(x, cutoff: center, q: 2).band * Float(exp(-t * 180))
                let ping = osc.sine(tone) * Float(exp(-t * 300)) * 0.3
                let thock = body.process(x, cutoff: 400, q: 0.7).low * Float(exp(-t * 90)) * 0.4
                key[i] = tick + ping + thock
            }
            mix(key, into: &out, at: at, gain: Float(rng.uniform(0.6...1.0)))
            at += rng.uniform(0.07...0.16)
        }
        return out
    }

    /// ピコン: 2 音の通知音
    private static func notification() -> [Float] {
        let duration = 0.42
        var out = [Float](repeating: 0, count: frameCount(duration))
        func note(_ freq: Double, length: Double, decay: Double) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                s[i] = osc.tone(freq, h2: 0.2) * attackDecay(time(i), attack: 0.003, decay: decay)
            }
            return s
        }
        mix(note(1318.5, length: 0.14, decay: 25), into: &out, at: 0, gain: 0.8)
        mix(note(1760, length: 0.32, decay: 12), into: &out, at: 0.1)
        return out
    }
}
