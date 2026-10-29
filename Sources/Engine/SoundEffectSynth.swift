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

        /// のこぎり波(-1 → 1)。折り返しの歪みを polyBLEP で抑える
        mutating func saw(_ freq: Double) -> Float {
            let dt = freq / SoundEffectSynth.sampleRate
            var v = 2 * phase - 1
            if phase < dt {
                let x = phase / dt
                v -= x + x - x * x - 1
            } else if phase > 1 - dt {
                let x = (phase - 1) / dt
                v -= x * x + x + x + 1
            }
            advance(freq)
            return Float(v)
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
    /// level: 仕上がりの大きさ(1 で targetPeak。静かな音は小さめに)
    static func finish(_ samples: [Float], level: Float = 1) -> [Float] {
        var out = samples
        var peak: Float = 0
        for v in out where v.isFinite { peak = max(peak, abs(v)) }
        guard peak > 0 else { return out }
        let scale = targetPeak * level / peak
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
        case .sadTrombone: raw = sadTrombone()
        case .vineBoom: raw = vineBoom()
        case .dramatic: raw = dramatic()
        case .recordScratch: raw = recordScratch()
        case .jajaan: raw = jajaan()
        case .correct: raw = correct()
        case .wrong: raw = wrong()
        case .drumRoll: raw = drumRoll()
        case .crickets: raw = crickets()
        case .applause: raw = applause()
        case .tada: raw = tada()
        case .rimshot: raw = rimshot()
        }
        // 「シーン」は静かな音なので控えめにそろえる
        return finish(raw, level: kind == .crickets ? 0.45 : 1)
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

    // ---- ネタ・リアクション ----

    /// 金管っぽい 1 音(のこぎり波 + 共鳴するローパス、軽いビブラート)
    /// wah: フィルターをゆっくり開いてから閉じる(ワウ)、slide: 終わりで音程を下げる
    private static func brassNote(_ freq: Double, length: Double, wah: Bool, slide: Bool) -> [Float] {
        let n = frameCount(length)
        var osc = Oscillator()
        var filter = Filter()
        var vib = Oscillator()
        var s = [Float](repeating: 0, count: n)
        let release = wah ? 0.25 : 0.05
        for i in 0..<n {
            let t = time(i)
            let p = t / length
            // 終わりの 3 割で 3 半音ほど下がる
            let drop = slide ? pow(2.0, -3.0 / 12 * max(0, (p - 0.7) / 0.3)) : 1
            let vibrato = 1 + 0.012 * Double(vib.sine(5.5)) * min(t / 0.15, 1)
            let f = freq * drop * vibrato
            // フィルターの開き具合(短い音は素早く、長い音はゆっくり開いてから閉じる)
            let open: Double = wah ? Double(hump(p, peak: 0.35)) : (1 - exp(-t * 60)) * (1 - 0.5 * p)
            let cutoff = freq * (2 + 6 * open)
            let attack = min(t / 0.025, 1)
            let tail = t > length - release ? (length - t) / release : 1
            let env = attack * tail * (wah ? 0.7 + 0.3 * open : 1)
            s[i] = filter.process(osc.saw(f), cutoff: cutoff, q: 2.5).low * Float(env)
        }
        return s
    }

    /// 和音(のこぎり波 + ローパス)。bright: フィルターをどれだけ開けるか(0...1)
    private static func chord(_ freqs: [Double], length: Double, decay: Double, bright: Double) -> [Float] {
        let n = frameCount(length)
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var filter = Filter()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var sum: Float = 0
            for j in freqs.indices {
                // 1 つおきにわずかにずらして厚みを出す
                sum += oscs[j].saw(freqs[j] * (1 + 0.002 * Double(j % 2)))
            }
            sum /= Float(freqs.count)
            let cutoff = 600 + bright * 3000 * exp(-t * 2.5)
            let release = Float(min(1, (length - t) / 0.02))
            s[i] = filter.process(sum, cutoff: cutoff, q: 1.1).low * attackDecay(t, attack: 0.008, decay: decay) * release
        }
        return s
    }

    /// シンバル(cymbal() の短い版。decay で余韻の長さを変える)
    private static func crash(seed: UInt64, length: Double, decay: Double) -> [Float] {
        let n = frameCount(length)
        var rng = Random(seed: seed)
        let freqs: [Double] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map { $0 * 2.1 }
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var metal = Filter()
        var hiss = Filter()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var sum: Float = 0
            for j in freqs.indices { sum += oscs[j].square(freqs[j]) }
            sum /= Float(freqs.count)
            let m = metal.process(sum, cutoff: 6500, q: 0.7).high
            let h = hiss.process(rng.noise(), cutoff: 6000, q: 0.7).high * 0.8
            s[i] = (m + h) * attackDecay(t, attack: 0.002, decay: decay)
        }
        return s
    }

    /// ファーファーファーファー: 下がっていく金管の 4 音。最後はワウをかけて音程が落ちる
    private static func sadTrombone() -> [Float] {
        let duration = 2.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        // Bb3 → A3 → Ab3 → G3
        let notes: [Double] = [233.08, 220.0, 207.65, 196.0]
        let starts: [Double] = [0, 0.3, 0.6, 0.9]
        for (index, freq) in notes.enumerated() {
            let isLast = index == notes.count - 1
            let length = isLast ? duration - starts[index] : 0.28
            mix(brassNote(freq, length: length, wah: isLast, slide: isLast),
                into: &out, at: starts[index], gain: isLast ? 1 : 0.9)
        }
        return out
    }

    /// ドゥーン(ブーム): 深い低音が素早く沈み、長く残る
    private static func vineBoom() -> [Float] {
        let duration = 1.2
        let n = frameCount(duration)
        var rng = Random(seed: 602)
        var sub = Oscillator()
        var body = Oscillator()
        var thud = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let f = 50 + 70 * exp(-t * 18)
            let low = sub.sine(f) * attackDecay(t, attack: 0.004, decay: 2.8)
            // スマホのスピーカーでも聞こえるよう 1 オクターブ上を少し足す
            let mid = body.sine(f * 2) * attackDecay(t, attack: 0.004, decay: 6) * 0.35
            let hit = thud.process(rng.noise(), cutoff: 700, q: 0.8).low * Float(exp(-t * 90)) * 0.5
            let v = low + mid + hit
            out[i] = Float(tanh(Double(v) * 1.8) / tanh(1.8))
        }
        // 短く遅らせた音を戻して残響のような尾を付ける
        let echoes: [(delay: Double, gain: Float)] = [(0.041, 0.35), (0.067, 0.28)]
        for (delay, gain) in echoes {
            let d = frameCount(delay)
            guard d < n else { continue }
            for i in d..<n { out[i] += out[i - d] * gain }
        }
        return out
    }

    /// ドゥーン(緊迫): 低い半音のぶつかりがゆっくり膨らんで、ぶつっと切れる
    private static func dramatic() -> [Float] {
        let duration = 2.0
        let cut = 1.55
        let n = frameCount(duration)
        // C2, C#2, G2, C3, C#3
        let freqs: [Double] = [65.41, 69.30, 98.0, 130.81, 138.59]
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var sub = Oscillator()
        var filter = Filter()
        var tremolo = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = min(t / cut, 1)
            var sum: Float = 0
            for j in freqs.indices { sum += oscs[j].saw(freqs[j]) }
            sum /= Float(freqs.count)
            let cutoff = 250 * pow(8.0, p * p)
            let tone = filter.process(sum, cutoff: cutoff, q: 1.2).low
            let low = sub.sine(freqs[0]) * 0.5
            let trem = 0.8 + 0.2 * tremolo.sine(5 + 3 * p)
            // 膨らみきったところで切り、わずかな余韻だけ残す
            let env = t < cut ? Float(pow(p, 2.2)) : Float(exp(-(t - cut) * 18))
            out[i] = (tone + low) * trem * env
        }
        return out
    }

    /// キュッ(レコード): 帯域ノイズの中心を素早く下げて戻す(針をこする音)
    private static func recordScratch() -> [Float] {
        let duration = 0.5
        let n = frameCount(duration)
        var rng = Random(seed: 604)
        var filter = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / duration
            // 針の動き: 速く下がって、ゆっくり戻る
            let motion = p < 0.4 ? 1 - pow(p / 0.4, 0.6) : pow((p - 0.4) / 0.6, 1.5)
            let center = 500 * pow(5.0, motion)
            let noise = filter.process(rng.noise(), cutoff: center, q: 5).band
            let squeal = osc.tone(center / 3, h2: 0.3, h3: 0.2) * 0.35
            let env = hump(p, peak: 0.15) * (p < 0.4 ? 1 : 0.7)
            out[i] = (noise + squeal) * env
        }
        return out
    }

    /// ジャジャーン: 短い和音を 2 回、そのあと明るい和音を伸ばす
    private static func jajaan() -> [Float] {
        let duration = 1.5
        var out = [Float](repeating: 0, count: frameCount(duration))
        // C メジャー
        let stab: [Double] = [261.63, 329.63, 392.0, 523.25]
        let hold: [Double] = [261.63, 329.63, 392.0, 523.25, 659.25, 783.99, 1046.5]
        mix(chord(stab, length: 0.16, decay: 12, bright: 0.6), into: &out, at: 0, gain: 0.9)
        mix(chord(stab, length: 0.16, decay: 12, bright: 0.6), into: &out, at: 0.19, gain: 0.9)
        mix(chord(hold, length: duration - 0.38, decay: 2.2, bright: 1.0), into: &out, at: 0.38)
        return out
    }

    /// ピンポーン(正解): 柔らかい 2 音(E5 → A5)
    private static func correct() -> [Float] {
        let duration = 0.7
        var out = [Float](repeating: 0, count: frameCount(duration))
        func note(_ freq: Double, length: Double, decay: Double) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                // 三角波に近い柔らかい音
                let release = Float(min(1, (length - t) / 0.02))
                s[i] = osc.tone(freq, h3: 0.11) * attackDecay(t, attack: 0.004, decay: decay) * release
            }
            return s
        }
        mix(note(659.25, length: 0.24, decay: 9), into: &out, at: 0, gain: 0.85)
        mix(note(880.0, length: 0.48, decay: 5), into: &out, at: 0.22)
        return out
    }

    /// ブッブー(不正解): 低いブザーを 2 回(2 回目は長め)
    private static func wrong() -> [Float] {
        let duration = 0.8
        var out = [Float](repeating: 0, count: frameCount(duration))
        func buzz(length: Double) -> [Float] {
            let n = frameCount(length)
            var a = Oscillator()
            var b = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                // 少しずらした矩形波でうなりをつける
                let raw = 0.6 * a.square(196) + 0.4 * b.square(199)
                let env = Float(min(t / 0.006, 1)) * Float(min(1, (length - t) / 0.03))
                s[i] = filter.process(raw, cutoff: 1500, q: 0.8).low * env
            }
            return s
        }
        mix(buzz(length: 0.22), into: &out, at: 0)
        mix(buzz(length: 0.42), into: &out, at: 0.32)
        return out
    }

    /// ドロロロ: スネアの連打がだんだん速く大きくなり、最後にシンバル
    private static func drumRoll() -> [Float] {
        let duration = 2.0
        let crashAt = 1.72
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 608)
        func hit(pitch: Double) -> [Float] {
            let n = frameCount(0.12)
            var osc = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let body = osc.sine(pitch + 80 * exp(-t * 60)) * Float(exp(-t * 28))
                let snap = filter.process(rng.noise(), cutoff: 1800, q: 1).band * Float(exp(-t * 70)) * 0.7
                s[i] = body + snap
            }
            return s
        }
        var at = 0.0
        var k = 0
        while at < crashAt - 0.02 {
            let p = at / crashAt
            // 左右の手で少し音が違う
            let pitch = k % 2 == 0 ? 165.0 : 150.0
            let gain = Float(0.45 + 0.55 * p) * Float(rng.uniform(0.85...1.0))
            mix(hit(pitch: pitch), into: &out, at: at, gain: gain)
            // だんだん速く
            at += 0.082 - 0.035 * p
            k += 1
        }
        mix(crash(seed: 609, length: duration - crashAt, decay: 5), into: &out, at: crashAt, gain: 1.3)
        return out
    }

    /// シーン(コオロギ): 高い鳴き声を 1 秒に 3 回くり返す
    private static func crickets() -> [Float] {
        let duration = 2.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 610)
        func chirp() -> [Float] {
            // 短い音を 30Hz で刻む(本物の鳴き方に近い)
            let length = 0.12
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let pulse = max(0, sin(2 * Double.pi * 30 * t))
                let env = hump(t / length, peak: 0.5) * Float(pulse * pulse)
                s[i] = osc.sine(4200 + 60 * sin(2 * Double.pi * 30 * t)) * env
            }
            return s
        }
        var at = 0.06
        while at < duration - 0.15 {
            mix(chirp(), into: &out, at: at, gain: Float(rng.uniform(0.7...1.0)))
            at += 0.333 + rng.uniform(-0.01...0.01)
        }
        return out
    }

    /// パチパチ(拍手): 短いノイズの粒をたくさん重ね、途中で盛り上がる
    private static func applause() -> [Float] {
        let duration = 2.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 611)
        func clap(center: Double) -> [Float] {
            let n = frameCount(0.04)
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                s[i] = filter.process(rng.noise(), cutoff: center, q: 1.4).band * Float(exp(-t * 160))
            }
            return s
        }
        var at = 0.0
        while at < duration - 0.05 {
            let p = at / duration
            let swell = hump(p, peak: 0.4)
            let gain = Float(rng.uniform(0.3...1.0)) * swell
            mix(clap(center: rng.uniform(900...2600)), into: &out, at: at, gain: gain)
            // 盛り上がりの付近ほど密に
            at += rng.uniform(0.012...0.05) / (0.6 + 0.8 * Double(swell))
        }
        // 会場のざわめき(低めのノイズ)
        var bed = Filter()
        for i in out.indices {
            let p = time(i) / duration
            out[i] += bed.process(rng.noise(), cutoff: 1200, q: 0.7).low * 0.08 * hump(p, peak: 0.4)
        }
        return out
    }

    /// ジャーン(タダー): 駆け上がるファンファーレのあと、明るい和音
    private static func tada() -> [Float] {
        let duration = 1.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        // G4 → C5 → E5 → G5(1 オクターブ下を添える)
        let run: [Double] = [392.0, 523.25, 659.25, 783.99]
        let starts: [Double] = [0, 0.09, 0.18, 0.27]
        for (index, freq) in run.enumerated() {
            mix(chord([freq, freq * 0.5], length: 0.14, decay: 10, bright: 0.7),
                into: &out, at: starts[index], gain: 0.8)
        }
        let finale: [Double] = [261.63, 392.0, 523.25, 659.25, 783.99, 1046.5]
        mix(chord(finale, length: duration - 0.36, decay: 2.5, bright: 1.0), into: &out, at: 0.36)
        // 和音の頭にシンバルを添えて華やかに
        mix(crash(seed: 612, length: 0.7, decay: 6), into: &out, at: 0.36, gain: 0.35)
        return out
    }

    /// バダム・ツ: タム 2 発のあとにシンバル
    private static func rimshot() -> [Float] {
        let duration = 0.8
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 613)
        func tom(_ pitch: Double) -> [Float] {
            let n = frameCount(0.25)
            var osc = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let body = osc.sine(pitch + pitch * 0.8 * exp(-t * 40)) * Float(exp(-t * 14))
                let stick = filter.process(rng.noise(), cutoff: 2500, q: 0.8).band * Float(exp(-t * 90)) * 0.5
                s[i] = Float(tanh(Double(body + stick) * 1.3))
            }
            return s
        }
        mix(tom(170), into: &out, at: 0, gain: 0.9)
        mix(tom(120), into: &out, at: 0.15)
        mix(crash(seed: 614, length: 0.45, decay: 7), into: &out, at: 0.32, gain: 0.9)
        return out
    }
}
