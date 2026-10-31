import Foundation
import AVFoundation

// =====================================================================
// 効果音の合成。正弦波・ノイズ・フィルターの組み合わせで、短い SE を PCM(モノラル 44.1kHz)で作る。
// 乱数は種を固定しているので、作り直しても同じ音になる(トリム位置がずれない)。
// =====================================================================

enum SoundEffectSynth {
    static let sampleRate: Double = 44100
    /// 以前の仕上がりのピーク(今は SoundLoudness.swift の音量そろえを使う。参照が残っていても困らないよう置いておく)
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

        /// 段差のまわりだけを滑らかにする補正(polyBLEP)。段差の位置 t(0...1)と 1 サンプルの進み dt
        private static func blep(_ t: Double, _ dt: Double) -> Double {
            if t < dt {
                let x = t / dt
                return x + x - x * x - 1
            } else if t > 1 - dt {
                let x = (t - 1) / dt
                return x * x + x + x + 1
            }
            return 0
        }

        /// 矩形波(-1 / 1)。2 つの段差を polyBLEP で滑らかにして折り返しの歪みを抑える
        mutating func square(_ freq: Double) -> Float {
            let dt = freq / SoundEffectSynth.sampleRate
            var v: Double = phase < 0.5 ? 1 : -1
            v += Oscillator.blep(phase, dt)
            var half = phase + 0.5
            if half >= 1 { half -= 1 }
            v -= Oscillator.blep(half, dt)
            advance(freq)
            return Float(v)
        }

        /// 三角波(-1 → 1 → -1)。角だけなので歪みは小さい
        mutating func triangle(_ freq: Double) -> Float {
            let v = 2 * abs(2 * phase - 1) - 1
            advance(freq)
            return Float(v)
        }

        /// のこぎり波(-1 → 1)。折り返しの歪みを polyBLEP で抑える
        mutating func saw(_ freq: Double) -> Float {
            let dt = freq / SoundEffectSynth.sampleRate
            var v = 2 * phase - 1
            v -= Oscillator.blep(phase, dt)
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

    /// 聞こえる大きさをそろえ(SoundLoudness.swift)、頭と終わりにごく短いフェードをかける(プチッという音を防ぐ)
    /// ambience: 環境音・長い音(-20 に)。それ以外は単発の SE(-16 に)
    static func finish(_ samples: [Float], ambience: Bool = false) -> [Float] {
        var out = samples
        removeDC(&out)
        guard out.contains(where: { $0.isFinite && $0 != 0 }) else { return out }
        var channels = [out]
        normalizeLoudness(&channels, ambience: ambience)
        out = channels[0]
        let fadeIn = min(out.count, frameCount(0.001))
        for i in 0..<fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        let fadeOut = min(out.count, frameCount(0.006))
        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }

    /// 直流のずれを取る(20Hz のハイパス。低音を膨らませたあとの片寄りを防ぐ)
    static func removeDC(_ out: inout [Float]) {
        let r = Float(1 - 2 * Double.pi * 20 / sampleRate)
        var prevIn: Float = 0
        var prevOut: Float = 0
        for i in out.indices {
            let x = out[i].isFinite ? out[i] : 0
            let y = x - prevIn + r * prevOut
            prevIn = x
            prevOut = y
            out[i] = y
        }
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
        // 動き・ポップ
        case .zip: raw = zip()
        case .slideIn: raw = slideIn()
        case .rewind: raw = tapeScrub(forward: false)
        case .fastForward: raw = tapeScrub(forward: true)
        case .teleport: raw = teleport()
        case .airWhoosh: raw = airWhoosh()
        case .pop2: raw = pop2()
        case .blip: raw = blip()
        case .tick: raw = tick()
        case .bounce: raw = bounce()
        // ネタ・リアクション
        case .yay: raw = crowd(seed: 701, cheer: true, length: 1.4)
        case .boo: raw = crowd(seed: 702, cheer: false, length: 1.4)
        case .wahWah: raw = wahWah()
        case .dundun: raw = dundun()
        case .honk: raw = honk()
        case .quack: raw = quack()
        case .kazoo: raw = kazoo()
        case .slideWhistle: raw = slideWhistle()
        // 日常
        case .doorKnock: raw = doorKnock()
        case .sizzle: raw = sizzle()
        case .pourWater: raw = pourWater()
        case .footsteps: raw = footsteps()
        case .keyboardEnter: raw = keyboardEnter()
        case .phoneRing: raw = phoneRing()
        case .cashRegister: raw = cashRegister()
        case .cameraFocus: raw = cameraFocus()
        // 自然
        case .birds: raw = birds()
        case .rain: raw = rain()
        case .wind: raw = wind()
        case .waveWash: raw = waveWash()
        case .fireCrackle: raw = fireCrackle()
        case .insects: raw = insects()
        case .night: raw = night()
        case .thunder: raw = thunder()
        // 雰囲気
        case .pianoHit: raw = pianoHit()
        case .warmChord: raw = warmChord()
        case .sadNote: raw = sadNote()
        case .tensionDrone: raw = tensionDrone()
        case .heartbeatSlow: raw = heartbeatSlow()
        case .surpriseSting: raw = surpriseSting()
        // ゲーム
        case .coinGet: raw = coinGet()
        case .levelUp: raw = levelUp()
        case .fail: raw = fail()
        case .jump8bit: raw = jump8bit()
        case .powerUp: raw = powerUp()
        // スポーツ・アクション
        case .whistle: raw = whistle()
        case .crowdCheer: raw = crowd(seed: 703, cheer: true, length: 2.2)
        case .buzzer: raw = buzzer()
        case .punch: raw = punch()
        case .countdown: raw = countdown()
        // シーン別
        case .crunch: raw = crunch()
        case .corkPop: raw = corkPop()
        case .clink: raw = clink()
        case .kettle: raw = kettle()
        case .cupSet: raw = cupSet()
        case .pageFlip: raw = pageFlip()
        case .clockTick: raw = clockTick()
        case .schoolBell: raw = schoolBell()
        case .creak: raw = creak()
        case .mealChime: raw = mealChime()
        case .windChime: raw = windChime()
        case .magicShimmer: raw = magicShimmer()
        case .musicBox: raw = musicBox()
        case .churchBells: raw = churchBells()
        case .sleighBells: raw = sleighBells()
        case .partyPopper: raw = partyPopper()
        case .starterPistol: raw = starterPistol()
        case .tsuzumi: raw = tsuzumi()
        case .cicadas: raw = cicadas()
        case .leavesRustle: raw = leavesRustle()
        case .snowCrunch: raw = snowCrunch()
        case .shishiOdoshi: raw = shishiOdoshi()
        case .breath: raw = breath()
        case .eerieSting: raw = eerieSting()
        case .questionSting: raw = questionSting()
        case .orin: raw = orin()
        case .softLowChord: raw = softLowChord()
        case .risingSwell: raw = risingSwell()
        case .rattle: raw = rattle()
        }
        // 環境音・長い音は控えめ(-20)に、それ以外は単発の SE(-16)としてそろえる
        let ambience: Bool
        switch kind {
        case .crickets, .rain, .wind, .waveWash, .fireCrackle, .insects, .night, .cicadas, .leavesRustle, .breath,
             .tensionDrone:
            ambience = true
        default:
            ambience = isLongBed(seconds: Double(raw.count) / sampleRate)
        }
        return finish(raw, ambience: ambience)
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

    // =================================================================
    // 追加分(50 種)。まず共通の部品、そのあと分類ごとの合成
    // =================================================================

    // ---- 追加分の共通部品 ----

    /// 短く遅らせた音を戻して残響のような尾を付ける(vineBoom と同じ仕組み)
    private static func echoes(_ out: inout [Float], _ taps: [(delay: Double, gain: Float)]) {
        let n = out.count
        for (delay, gain) in taps {
            let d = frameCount(delay)
            guard d > 0, d < n else { continue }
            for i in d..<n { out[i] += out[i - d] * gain }
        }
    }

    /// 倍音つき正弦波の 1 音(立ち上がり → 指数減衰、終わりは短く切る)
    private static func simpleNote(_ freq: Double, length: Double, decay: Double,
                                   h2: Float = 0.2, h3: Float = 0, attack: Double = 0.004) -> [Float] {
        let n = frameCount(length)
        var osc = Oscillator()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let release = Float(min(1, (length - t) / 0.02))
            s[i] = osc.tone(freq, h2: h2, h3: h3) * attackDecay(t, attack: attack, decay: decay) * release
        }
        return s
    }

    /// ゲーム機っぽい 1 音(矩形波 + ローパス)。slideTo: 終わりまでに音程をここへ寄せる
    private static func chipNote(_ freq: Double, length: Double, decay: Double, slideTo: Double? = nil) -> [Float] {
        let n = frameCount(length)
        var osc = Oscillator()
        var filter = Filter()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / length
            let f: Double
            if let slideTo { f = freq * pow(slideTo / freq, p) } else { f = freq }
            let release = Float(min(1, (length - t) / 0.01))
            s[i] = filter.process(osc.square(f) * 0.5, cutoff: 3500, q: 0.7).low
                * attackDecay(t, attack: 0.003, decay: decay) * release
        }
        return s
    }

    /// 帯域ノイズの中心を start → end へ動かす(動き系の土台)。curve: 1 で等速、大きいほど後半で動く
    private static func noiseSweep(seed: UInt64, length: Double, from start: Double, to end: Double,
                                   q: Double, peak: Double, curve: Double = 1) -> [Float] {
        let n = frameCount(length)
        var rng = Random(seed: seed)
        var filter = Filter()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / length
            let cutoff = start * pow(end / start, pow(p, curve))
            s[i] = filter.process(rng.noise(), cutoff: cutoff, q: q).band * hump(p, peak: peak)
        }
        return s
    }

    /// ピアノ風の 1 音(倍音を別々に減衰させ、頭にハンマーのノイズ)
    private static func pianoNote(_ freq: Double, length: Double, decay: Double, rng: inout Random) -> [Float] {
        let n = frameCount(length)
        var oscs = [Oscillator](repeating: Oscillator(), count: 4)
        let ratios: [Double] = [1, 2.0, 3.01, 4.02]
        let amps: [Float] = [1, 0.45, 0.2, 0.08]
        var hammer = Filter()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var v: Float = 0
            for j in ratios.indices {
                v += amps[j] * oscs[j].sine(freq * ratios[j]) * attackDecay(t, attack: 0.003, decay: decay * (1 + 0.8 * Double(j)))
            }
            v += hammer.process(rng.noise(), cutoff: 2500, q: 0.8).band * Float(exp(-t * 150)) * 0.15
            let release = Float(min(1, (length - t) / 0.04))
            s[i] = v * release
        }
        return s
    }

    /// ゆっくり変わる値(いくつかの正弦波の和。環境音のうねりに使う)
    private static func slowDrift(_ t: Double, seed: Double) -> Double {
        0.5 + 0.25 * sin(2 * Double.pi * 0.17 * t + seed) + 0.15 * sin(2 * Double.pi * 0.41 * t + seed * 2.3)
            + 0.1 * sin(2 * Double.pi * 0.93 * t + seed * 0.7)
    }

    // ---- 動き・ポップ(追加) ----

    /// ジッ: 高めのノイズを素早く上へこすり、のこぎり波も一緒に上がる(ファスナー風)
    private static func zip() -> [Float] {
        let duration = 0.3
        let n = frameCount(duration)
        var osc = Oscillator()
        var filter = Filter()
        var out = noiseSweep(seed: 801, length: duration, from: 900, to: 7000, q: 2.2, peak: 0.55)
        for i in 0..<n {
            let p = time(i) / duration
            let f = 180 * pow(9.0, p)
            let tone = filter.process(osc.saw(f), cutoff: f * 6, q: 1.2).low
            out[i] += tone * hump(p, peak: 0.55) * 0.3
        }
        return out
    }

    /// スッ: 高いノイズが下がって、最後に軽く止まる(スライドして入る)
    private static func slideIn() -> [Float] {
        let duration = 0.45
        var out = noiseSweep(seed: 802, length: 0.38, from: 5000, to: 600, q: 1.2, peak: 0.25, curve: 0.8)
        out += [Float](repeating: 0, count: frameCount(duration) - out.count)
        // 止まる音
        let n = frameCount(0.1)
        var osc = Oscillator()
        var filter = Filter()
        var rng = Random(seed: 803)
        var stop = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            stop[i] = osc.sine(140 + 80 * exp(-t * 80)) * Float(exp(-t * 45)) * 0.6
                + filter.process(rng.noise(), cutoff: 1500, q: 0.8).low * Float(exp(-t * 200)) * 0.4
        }
        mix(stop, into: &out, at: 0.34)
        return out
    }

    /// 巻き戻し / 早送り: テープの音。細かく刻んだ音程が下がる(巻き戻し)か上がる(早送り)
    private static func tapeScrub(forward: Bool) -> [Float] {
        let duration = 0.9
        let n = frameCount(duration)
        var rng = Random(seed: forward ? 805 : 804)
        var osc = Oscillator()
        var osc2 = Oscillator()
        var filter = Filter()
        var noiseFilter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            // 巻き戻しは高い音から下がり、早送りは上がる
            let sweep = forward ? pow(p, 0.7) : 1 - pow(p, 0.7)
            let f = 250 * pow(5.0, sweep)
            // 1 秒に 16 回のコマ送りのような刻み
            let gate: Double = sin(2 * Double.pi * 16 * t) >= 0 ? 1 : 0.45
            let tone = filter.process(osc.saw(f) + 0.4 * osc2.sine(f * 1.5), cutoff: f * 4, q: 1.5).low
            let hiss = noiseFilter.process(rng.noise(), cutoff: 2500 + 3000 * sweep, q: 1).band * 0.35
            out[i] = (tone * 0.6 + hiss) * Float(gate) * hump(p, peak: 0.5)
        }
        return out
    }

    /// ヒュン: 音が一気に駆け上がって消える(瞬間移動)。短い残響つき
    private static func teleport() -> [Float] {
        let duration = 0.8
        let n = frameCount(duration)
        var a = Oscillator()
        var b = Oscillator()
        var vib = Oscillator()
        var out = noiseSweep(seed: 806, length: duration, from: 400, to: 9000, q: 1.8, peak: 0.65, curve: 1.6)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let f = 180 * pow(22.0, pow(p, 1.5)) * (1 + 0.01 * Double(vib.sine(9)))
            let tone = a.sine(f) + 0.3 * b.sine(f * 2.003)
            out[i] = out[i] * 0.6 + tone * hump(p, peak: 0.6) * 0.6
        }
        echoes(&out, [(0.05, 0.3), (0.11, 0.2), (0.19, 0.12)])
        return out
    }

    /// フォッ: 柔らかい空気の流れ(低めのノイズがふくらんで消える)
    private static func airWhoosh() -> [Float] {
        let duration = 0.9
        let n = frameCount(duration)
        var rng = Random(seed: 807)
        var low = Filter()
        var mid = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = time(i) / duration
            let x = rng.noise()
            let center = 250 * pow(6.0, sin(Double.pi * pow(p, 0.9)))
            let body = low.process(x, cutoff: center, q: 0.8).band
            let breath = mid.process(x, cutoff: center * 3, q: 0.6).band * 0.3
            out[i] = (body + breath) * hump(p, peak: 0.4)
        }
        return out
    }

    /// プチッ: 「ポン」より小さく軽い破裂音(テロップの出現に)
    private static func pop2() -> [Float] {
        let duration = 0.1
        let n = frameCount(duration)
        var rng = Random(seed: 808)
        var osc = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let freq = 600 + 1800 * exp(-t * 110)
            let body = osc.sine(freq) * attackDecay(t, attack: 0.001, decay: 55)
            let burst = filter.process(rng.noise(), cutoff: 4500, q: 1).band * Float(exp(-t * 500)) * 0.6
            out[i] = body + burst
        }
        return out
    }

    /// ピッ: 電子的な短い音(ボタン・決定)
    private static func blip() -> [Float] {
        let duration = 0.09
        let n = frameCount(duration)
        var osc = Oscillator()
        var osc2 = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let release = Float(min(1, (duration - t) / 0.01))
            out[i] = filter.process(osc.square(1760) * 0.5 + osc2.sine(3520) * 0.2, cutoff: 5000, q: 0.7).low
                * Float(min(t / 0.002, 1)) * Float(exp(-t * 25)) * release
        }
        return out
    }

    /// チッ: ごく短く乾いたクリック(カーソル・切り替え)
    private static func tick() -> [Float] {
        let duration = 0.035
        let n = frameCount(duration)
        var rng = Random(seed: 809)
        var filter = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            out[i] = filter.process(rng.noise(), cutoff: 5500, q: 1.5).band * Float(exp(-t * 700))
                + osc.sine(2400) * Float(exp(-t * 450)) * 0.35
        }
        return out
    }

    /// ポヨン: 弾む音が 3 回、だんだん小さく短く
    private static func bounce() -> [Float] {
        let duration = 0.7
        var out = [Float](repeating: 0, count: frameCount(duration))
        func hop(length: Double, pitch: Double) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let p = t / length
                // 当たった瞬間に下がって、はね返りで少し上がる
                let f = pitch * (1 + 0.6 * exp(-t * 50)) * (1 + 0.15 * p)
                s[i] = osc.tone(f, h2: 0.3) * attackDecay(t, attack: 0.003, decay: 3 / length) * hump(p, peak: 0.1)
            }
            return s
        }
        mix(hop(length: 0.3, pitch: 220), into: &out, at: 0)
        mix(hop(length: 0.2, pitch: 260), into: &out, at: 0.3, gain: 0.7)
        mix(hop(length: 0.13, pitch: 300), into: &out, at: 0.5, gain: 0.45)
        return out
    }

    // ---- ネタ・リアクション(追加) ----

    /// 群衆の声。cheer: 「ワー」(高く上がる)/ false: 「ブー」(低く下がる)
    /// 母音っぽい帯域(フォルマント)に通した複数ののこぎり波 + 息のノイズ
    private static func crowd(seed: UInt64, cheer: Bool, length: Double) -> [Float] {
        let n = frameCount(length)
        var rng = Random(seed: seed)
        let voices = 10
        var oscs = [Oscillator](repeating: Oscillator(), count: voices)
        var bases: [Double] = []
        var drifts: [Double] = []
        let pitchRange: ClosedRange<Double> = cheer ? 220...420 : 130...220
        for _ in 0..<voices {
            bases.append(rng.uniform(pitchRange))
            drifts.append(rng.uniform(0.6...1.4))
        }
        var f1 = Filter()
        var f2 = Filter()
        var breath = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / length
            var sum: Float = 0
            for j in 0..<voices {
                // ワーは上がり、ブーは下がる。各人少しずつ違う速さ
                let glide = cheer ? pow(1.5, min(p * drifts[j] * 2, 1)) : pow(0.8, min(p * drifts[j], 1))
                let wobble = 1 + 0.01 * sin(2 * Double.pi * (4 + Double(j)) * t)
                sum += oscs[j].saw(bases[j] * glide * wobble)
            }
            sum /= Float(voices)
            // 「あ」(ワー)と「う」(ブー)のフォルマント
            let a = f1.process(sum, cutoff: cheer ? 800 : 350, q: 2.5).band
            let b = f2.process(sum, cutoff: cheer ? 1300 : 750, q: 2.5).band
            let h = breath.process(rng.noise(), cutoff: cheer ? 2500 : 1200, q: 0.8).band * 0.15
            let env = cheer ? hump(p, peak: 0.3) : hump(p, peak: 0.4)
            out[i] = (a + 0.7 * b + h) * env
        }
        echoes(&out, [(0.031, 0.3), (0.057, 0.22), (0.089, 0.15)])
        return out
    }

    /// ワウワウ: 金管のワウを 2 回(2 回目は音程が下がる)
    private static func wahWah() -> [Float] {
        let duration = 1.3
        var out = [Float](repeating: 0, count: frameCount(duration))
        mix(brassNote(246.94, length: 0.5, wah: true, slide: false), into: &out, at: 0, gain: 0.9)
        mix(brassNote(233.08, length: duration - 0.55, wah: true, slide: true), into: &out, at: 0.55)
        return out
    }

    /// デデン: 低い 2 発のスタブ(2 発目は長く低く、残響つき)
    private static func dundun() -> [Float] {
        let duration = 1.5
        var out = [Float](repeating: 0, count: frameCount(duration))
        func hit(_ freqs: [Double], length: Double, decay: Double) -> [Float] {
            var s = chord(freqs, length: length, decay: decay, bright: 0.5)
            var sub = Oscillator()
            for i in s.indices {
                let t = time(i)
                s[i] = Float(tanh(Double(s[i] + 0.6 * sub.sine(freqs[0] * 0.5) * attackDecay(t, attack: 0.005, decay: decay)) * 1.6))
            }
            return s
        }
        mix(hit([110, 164.81, 220], length: 0.22, decay: 8), into: &out, at: 0, gain: 0.9)
        mix(hit([98, 146.83, 196], length: duration - 0.26, decay: 2.2), into: &out, at: 0.26)
        echoes(&out, [(0.043, 0.3), (0.071, 0.22)])
        return out
    }

    /// プップー: 車のクラクション(2 音の和音を短く、長く)
    private static func honk() -> [Float] {
        let duration = 0.75
        var out = [Float](repeating: 0, count: frameCount(duration))
        func toot(length: Double) -> [Float] {
            let n = frameCount(length)
            var a = Oscillator()
            var b = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let raw = 0.5 * a.saw(392) + 0.5 * b.saw(493.88)
                let env = Float(min(t / 0.01, 1)) * Float(min(1, (length - t) / 0.03))
                s[i] = filter.process(raw, cutoff: 1800, q: 1.3).low * env
            }
            return s
        }
        mix(toot(length: 0.16), into: &out, at: 0, gain: 0.9)
        mix(toot(length: 0.45), into: &out, at: 0.22)
        return out
    }

    /// ガーガー: アヒルの声(のこぎり波を鼻にかかった帯域に通し、速く震わせる)を 2 回
    private static func quack() -> [Float] {
        let duration = 0.6
        var out = [Float](repeating: 0, count: frameCount(duration))
        func one(length: Double) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var nasal = Filter()
            var body = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let p = t / length
                let f = 330 * pow(0.75, p)
                let raw = osc.saw(f)
                let trem = 0.6 + 0.4 * max(0, sin(2 * Double.pi * 28 * t))
                let v = nasal.process(raw, cutoff: 1100, q: 4).band * 0.8 + body.process(raw, cutoff: 600, q: 1).low * 0.5
                s[i] = v * Float(trem) * hump(p, peak: 0.2)
            }
            return s
        }
        mix(one(length: 0.24), into: &out, at: 0)
        mix(one(length: 0.26), into: &out, at: 0.3, gain: 0.85)
        return out
    }

    /// カズー: ビリビリした鼻声のような音。音程が上がってから下がる
    private static func kazoo() -> [Float] {
        let duration = 0.7
        let n = frameCount(duration)
        var rng = Random(seed: 810)
        var osc = Oscillator()
        var osc2 = Oscillator()
        var vib = Oscillator()
        var buzz = Filter()
        var body = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let f = 294 * pow(1.5, Double(hump(p, peak: 0.35))) * (1 + 0.02 * Double(vib.sine(6)))
            let raw = osc.saw(f) + 0.35 * osc2.square(f * 2.01) + 0.2 * rng.noise()
            let v = buzz.process(raw, cutoff: 1800, q: 3).band + body.process(raw, cutoff: 900, q: 1).low * 0.5
            out[i] = v * hump(p, peak: 0.3)
        }
        return out
    }

    /// スライド笛: 音程がなめらかに上がってから落ちる(落ちる方を長く)
    private static func slideWhistle() -> [Float] {
        let duration = 1.1
        let n = frameCount(duration)
        var osc = Oscillator()
        var vib = Oscillator()
        var rng = Random(seed: 811)
        var breath = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            // 0.3 秒で 1 オクターブ上がり、残りで 2 オクターブ下がる
            let curve = p < 0.27 ? p / 0.27 : 1 - 2 * pow((p - 0.27) / 0.73, 0.9)
            let f = 880 * pow(2.0, curve) * (1 + 0.006 * Double(vib.sine(5.5)))
            let tone = osc.tone(f, h2: 0.08, h3: 0.03)
            let air = breath.process(rng.noise(), cutoff: f * 2, q: 2).band * 0.12
            out[i] = (tone + air) * hump(p, peak: 0.35)
        }
        return out
    }

    // ---- 日常(追加) ----

    /// コンコン: ドアを 3 回ノック(木の板の低い共鳴 + 当たるノイズ)
    private static func doorKnock() -> [Float] {
        let duration = 0.85
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 812)
        func knock() -> [Float] {
            let n = frameCount(0.18)
            var a = Oscillator()
            var b = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let body = (a.sine(190 + 120 * exp(-t * 90)) + 0.5 * b.sine(410)) * Float(exp(-t * 30))
                let tap = filter.process(rng.noise(), cutoff: 1200, q: 0.9).low * Float(exp(-t * 220)) * 0.7
                s[i] = Float(tanh(Double(body + tap) * 1.3))
            }
            return s
        }
        mix(knock(), into: &out, at: 0)
        mix(knock(), into: &out, at: 0.21, gain: 0.95)
        mix(knock(), into: &out, at: 0.42, gain: 0.9)
        return out
    }

    /// ジュー: 油で焼く音(高いノイズのうねり + 細かいはじける粒)
    private static func sizzle() -> [Float] {
        let duration = 2.2
        let n = frameCount(duration)
        var rng = Random(seed: 813)
        var hiss = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let drift = slowDrift(t * 3, seed: 1.1)
            let x = rng.noise()
            var v = hiss.process(x, cutoff: 4500 + 2500 * drift, q: 0.9).band * Float(0.5 + 0.5 * drift)
            // ときどき油がはねる
            if rng.unit() < 0.004 { v += x * 1.5 }
            out[i] = v * hump(p, peak: 0.3)
        }
        return out
    }

    /// 水を注ぐ: 低めの流れるノイズに、上がっていく泡の音を散らす(容器が満ちて音程が上がる)
    private static func pourWater() -> [Float] {
        let duration = 2.0
        let n = frameCount(duration)
        var rng = Random(seed: 814)
        var flow = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let drift = slowDrift(t * 4, seed: 2.2)
            out[i] = flow.process(rng.noise(), cutoff: 900 + 1200 * drift + 800 * p, q: 1.2).band * hump(p, peak: 0.5) * 0.6
        }
        // 泡: 短く上がる音。注ぐにつれ音程が上がる
        var at = 0.1
        while at < duration - 0.1 {
            let base = 500 + 900 * (at / duration) * rng.uniform(0.8...1.2)
            let m = frameCount(0.06)
            var osc = Oscillator()
            var bub = [Float](repeating: 0, count: m)
            for i in 0..<m {
                let t = time(i)
                bub[i] = osc.sine(base * pow(2.0, min(t / 0.05, 1))) * attackDecay(t, attack: 0.002, decay: 60)
            }
            mix(bub, into: &out, at: at, gain: Float(rng.uniform(0.15...0.4)) * hump(at / duration, peak: 0.5))
            at += rng.uniform(0.02...0.07)
        }
        return out
    }

    /// 足音: 4 歩(かかと → つま先の 2 段の低い打撃)
    private static func footsteps() -> [Float] {
        let duration = 2.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 815)
        func step() -> [Float] {
            let n = frameCount(0.2)
            var osc = Oscillator()
            var low = Filter()
            var grit = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let x = rng.noise()
                // かかと
                let heel = osc.sine(90 + 60 * exp(-t * 70)) * Float(exp(-t * 35)) + low.process(x, cutoff: 500, q: 0.8).low * Float(exp(-t * 90)) * 0.8
                // つま先(少し遅れて、軽く高い)
                let dt = t - 0.07
                let toe: Float = dt > 0 ? grit.process(x, cutoff: 1500, q: 1).band * Float(exp(-dt * 120)) * 0.5 : 0
                s[i] = Float(tanh(Double(heel + toe) * 1.4))
            }
            return s
        }
        var at = 0.05
        while at < duration - 0.25 {
            mix(step(), into: &out, at: at, gain: Float(rng.uniform(0.8...1.0)))
            at += 0.48 + rng.uniform(-0.03...0.03)
        }
        return out
    }

    /// エンター: 大きめのキーを 1 回しっかり押す音(タイピングの 1 打を重く)
    private static func keyboardEnter() -> [Float] {
        let duration = 0.14
        let n = frameCount(duration)
        var rng = Random(seed: 816)
        var band = Filter()
        var body = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let x = rng.noise()
            let click = band.process(x, cutoff: 3000, q: 2).band * Float(exp(-t * 150))
            let thock = body.process(x, cutoff: 350, q: 0.8).low * Float(exp(-t * 60)) * 0.9
            let ping = osc.sine(1500) * Float(exp(-t * 250)) * 0.25
            // 離したときの小さなカチッ
            let dt = t - 0.08
            let up: Float = dt > 0 ? Float(exp(-dt * 300)) * x * 0.3 : 0
            out[i] = click + thock + ping + up
        }
        return out
    }

    /// 着信音: 電話のベル(2 つの高い音を 20Hz で震わせる)を 2 回
    private static func phoneRing() -> [Float] {
        let duration = 1.9
        var out = [Float](repeating: 0, count: frameCount(duration))
        func ring(length: Double) -> [Float] {
            let n = frameCount(length)
            var a = Oscillator()
            var b = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let trem = Float(0.55 + 0.45 * sin(2 * Double.pi * 20 * t))
                let env = Float(min(t / 0.01, 1)) * Float(min(1, (length - t) / 0.03))
                s[i] = (a.tone(1000, h2: 0.3) + b.tone(1250, h2: 0.3)) * 0.5 * trem * env
            }
            return s
        }
        mix(ring(length: 0.5), into: &out, at: 0)
        mix(ring(length: 0.5), into: &out, at: 1.0)
        return out
    }

    /// レジ: 引き出しが開くガチャッという機械音のあとに、高いベルのチーン
    private static func cashRegister() -> [Float] {
        let duration = 1.3
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 817)
        // ガチャッ(金属のノイズを 2 回)
        func clank(cutoff: Double) -> [Float] {
            let n = frameCount(0.08)
            var filter = Filter()
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                s[i] = filter.process(rng.noise(), cutoff: cutoff, q: 2).band * Float(exp(-t * 90))
                    + osc.sine(260) * Float(exp(-t * 80)) * 0.4
            }
            return s
        }
        mix(clank(cutoff: 1800), into: &out, at: 0, gain: 0.8)
        mix(clank(cutoff: 2600), into: &out, at: 0.07, gain: 0.7)
        // チーン(bell() と同じ倍音の構成を高く短く)
        let n = frameCount(duration - 0.18)
        let f0 = 2200.0
        let ratios: [Double] = [1, 2.0, 2.76, 5.4]
        let amps: [Float] = [1, 0.3, 0.45, 0.15]
        var oscs = [Oscillator](repeating: Oscillator(), count: ratios.count)
        var ding = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var v: Float = 0
            for j in ratios.indices {
                v += amps[j] * oscs[j].sine(f0 * ratios[j]) * attackDecay(t, attack: 0.002, decay: 3 + 2 * Double(j))
            }
            ding[i] = v
        }
        mix(ding, into: &out, at: 0.18, gain: 0.9)
        return out
    }

    /// ピント: カメラが合焦したときの短い電子音 2 回
    private static func cameraFocus() -> [Float] {
        let duration = 0.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        func beep() -> [Float] {
            let n = frameCount(0.05)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let env = Float(min(t / 0.002, 1)) * Float(min(1, (0.05 - t) / 0.006))
                s[i] = osc.tone(2640, h2: 0.15) * env
            }
            return s
        }
        mix(beep(), into: &out, at: 0)
        mix(beep(), into: &out, at: 0.08)
        return out
    }

    // ---- 自然(追加) ----

    /// 小鳥: 短いさえずりをいくつか(音程が素早く揺れる高い正弦波)
    private static func birds() -> [Float] {
        let duration = 2.6
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 818)
        func chirp(base: Double, length: Double, rate: Double, down: Bool) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let p = t / length
                let slide = down ? 1 - 0.3 * p : 1 + 0.25 * p
                let f = base * slide * (1 + 0.08 * sin(2 * Double.pi * rate * t))
                s[i] = osc.sine(f) * hump(p, peak: 0.4)
            }
            return s
        }
        var at = 0.05
        while at < duration - 0.3 {
            // 2〜4 音をひとまとまりで鳴く
            let count = Int(rng.uniform(2...4.99))
            let base = rng.uniform(2600...4200)
            var inner = at
            for _ in 0..<count {
                let length = rng.uniform(0.06...0.14)
                mix(chirp(base: base * rng.uniform(0.9...1.1), length: length, rate: rng.uniform(25...60), down: rng.unit() < 0.5),
                    into: &out, at: inner, gain: Float(rng.uniform(0.5...1.0)))
                inner += length + rng.uniform(0.02...0.06)
            }
            at = inner + rng.uniform(0.25...0.6)
        }
        return out
    }

    /// 雨: 高めのノイズの地面に、雨粒の小さな粒をたくさん散らす
    private static func rain() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        var rng = Random(seed: 819)
        var bed = Filter()
        var drop = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let drift = slowDrift(t, seed: 3.3)
            let x = rng.noise()
            var v = bed.process(x, cutoff: 3000 + 1500 * drift, q: 0.7).band * Float(0.7 + 0.3 * drift)
            // 雨粒(短い高い粒)
            if rng.unit() < 0.012 { v += drop.process(x, cutoff: 6000, q: 2).band * 4 }
            else { v += drop.process(0, cutoff: 6000, q: 2).band * 4 }
            out[i] = v * hump(p, peak: 0.5)
        }
        return out
    }

    /// 風: 低いノイズのうなりがゆっくり強まったり弱まったりする
    private static func wind() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        var rng = Random(seed: 820)
        var body = Filter()
        var whistleFilter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let drift = slowDrift(t, seed: 4.4)
            let x = rng.noise()
            let low = body.process(x, cutoff: 250 + 900 * drift * drift, q: 1.2).band
            // 強いときだけ高いヒューという音がまざる
            let whistle = whistleFilter.process(x, cutoff: 1200 + 1500 * drift, q: 6).band * Float(max(0, drift - 0.5)) * 0.5
            out[i] = (low + whistle) * Float(0.3 + 0.7 * drift) * hump(p, peak: 0.5)
        }
        return out
    }

    /// 波: 寄せる(ノイズがゆっくり明るく大きく)→ 引く(しゅわしゅわと静まる)
    private static func waveWash() -> [Float] {
        let duration = 3.2
        let n = frameCount(duration)
        var rng = Random(seed: 821)
        var body = Filter()
        var foam = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let swell = Double(hump(p, peak: 0.4))
            let x = rng.noise()
            let roll = body.process(x, cutoff: 300 + 1500 * swell, q: 0.8).band * Float(swell)
            // 引き波の泡は山を過ぎてから目立つ
            let after = max(0, (p - 0.4) / 0.6)
            let hiss = foam.process(x, cutoff: 3500, q: 0.7).band * Float(after * (1 - after) * 2.5) * 0.5
            out[i] = roll + hiss
        }
        return out
    }

    /// 焚き火: 低くこもった燃える音の上に、パチッとはぜる音を不規則に
    private static func fireCrackle() -> [Float] {
        let duration = 2.8
        let n = frameCount(duration)
        var rng = Random(seed: 822)
        var bed = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let drift = slowDrift(t * 2, seed: 5.5)
            out[i] = bed.process(rng.noise(), cutoff: 150 + 300 * drift, q: 0.9).low * Float(0.5 + 0.5 * drift) * 0.5
        }
        // パチッ
        var at = 0.1
        while at < duration - 0.05 {
            let m = frameCount(rng.uniform(0.01...0.03))
            var filter = Filter()
            var crackle = [Float](repeating: 0, count: m)
            let cutoff = rng.uniform(1500...5000)
            for i in 0..<m {
                let t = time(i)
                crackle[i] = filter.process(rng.noise(), cutoff: cutoff, q: 1.2).band * Float(exp(-t * 400))
            }
            mix(crackle, into: &out, at: at, gain: Float(rng.uniform(0.6...2.0)))
            at += rng.uniform(0.04...0.35)
        }
        // 全体の出入り
        for i in 0..<n { out[i] *= hump(time(i) / duration, peak: 0.5) }
        return out
    }

    /// 虫の声: 鈴虫のようなリーンリーンという高い音(2 つの近い音のうなり)を繰り返す
    private static func insects() -> [Float] {
        let duration = 3.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 823)
        func ring(length: Double, freq: Double) -> [Float] {
            let n = frameCount(length)
            var a = Oscillator()
            var b = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let p = t / length
                s[i] = (a.sine(freq) + b.sine(freq * 1.004)) * 0.5 * hump(p, peak: 0.3)
            }
            return s
        }
        var at = 0.05
        while at < duration - 0.3 {
            let length = rng.uniform(0.35...0.6)
            mix(ring(length: length, freq: rng.uniform(4300...4700)), into: &out, at: at, gain: Float(rng.uniform(0.6...1.0)))
            at += length + rng.uniform(0.15...0.4)
        }
        // 遠くでもう 1 匹(低めで小さく)
        var far = 0.3
        while far < duration - 0.3 {
            let length = rng.uniform(0.3...0.5)
            mix(ring(length: length, freq: rng.uniform(3300...3600)), into: &out, at: far, gain: 0.3)
            far += length + rng.uniform(0.3...0.6)
        }
        return out
    }

    /// 夜: ごく低いうなり + コオロギの遠い鳴き声 + ときどき小さな風
    private static func night() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        var rng = Random(seed: 824)
        var bed = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let drift = slowDrift(t, seed: 6.6)
            out[i] = bed.process(rng.noise(), cutoff: 120 + 250 * drift, q: 1).low * Float(0.4 + 0.6 * drift) * 0.6
        }
        // 遠くのコオロギ(crickets() と同じ刻み、小さく高めに)
        func chirp() -> [Float] {
            let length = 0.1
            let m = frameCount(length)
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: m)
            for i in 0..<m {
                let t = time(i)
                let pulse = max(0, sin(2 * Double.pi * 32 * t))
                s[i] = osc.sine(4600) * hump(t / length, peak: 0.5) * Float(pulse * pulse)
            }
            return s
        }
        var at = 0.2
        while at < duration - 0.15 {
            mix(chirp(), into: &out, at: at, gain: Float(rng.uniform(0.25...0.45)))
            at += 0.4 + rng.uniform(-0.02...0.02)
        }
        for i in 0..<n { out[i] *= hump(time(i) / duration, peak: 0.5) }
        return out
    }

    /// 雷: 稲妻のバリッという鋭い音のあと、ゴロゴロと転がる低い轟き
    private static func thunder() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        var rng = Random(seed: 825)
        var crack = Filter()
        var rumble = Filter()
        var sub = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let x = rng.noise()
            // バリッ(最初の 0.15 秒)
            let snap = crack.process(x, cutoff: 1800 + 3000 * exp(-t * 20), q: 1).band * Float(exp(-t * 22)) * 0.8
            // ゴロゴロ(大きさがうねりながらゆっくり消える)
            let roll = slowDrift(t * 2.5, seed: 7.7)
            let body = rumble.process(x, cutoff: 60 + 180 * roll, q: 1.1).low * Float(0.5 + 0.5 * roll) * Float(exp(-t * 1.1)) * 1.6
            let low = sub.sine(38 + 20 * roll) * Float(exp(-t * 1.5)) * 0.3
            out[i] = Float(tanh(Double(snap + body + low) * 1.8) / tanh(1.8))
        }
        echoes(&out, [(0.09, 0.35), (0.17, 0.25), (0.31, 0.15)])
        return out
    }

    // ---- 雰囲気(追加) ----

    /// ピアノ一打: 低めのオクターブを 1 回、長く響かせる
    private static func pianoHit() -> [Float] {
        let duration = 2.2
        var rng = Random(seed: 826)
        var out = pianoNote(130.81, length: duration, decay: 1.6, rng: &rng)
        let upper = pianoNote(261.63, length: duration, decay: 2.0, rng: &rng)
        mix(upper, into: &out, at: 0.004, gain: 0.6)
        echoes(&out, [(0.037, 0.25), (0.061, 0.18)])
        return out
    }

    /// あたたかい和音: 柔らかい電気ピアノ風の和音(Fmaj7)がゆっくり立ち上がって消える
    private static func warmChord() -> [Float] {
        let duration = 2.4
        let n = frameCount(duration)
        // F3, A3, C4, E4, A4
        let freqs: [Double] = [174.61, 220.0, 261.63, 329.63, 440.0]
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var filter = Filter()
        var trem = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            var sum: Float = 0
            for j in freqs.indices {
                sum += oscs[j].tone(freqs[j] * (1 + 0.0015 * Double(j % 2)), h2: 0.25, h3: 0.06)
            }
            sum /= Float(freqs.count)
            let soft = filter.process(sum, cutoff: 900 + 1200 * Double(hump(p, peak: 0.25)), q: 0.8).low
            let shimmer = 0.9 + 0.1 * trem.sine(4.5)
            out[i] = soft * shimmer * hump(p, peak: 0.22)
        }
        echoes(&out, [(0.047, 0.2), (0.083, 0.14)])
        return out
    }

    /// 悲しい音: 短調の 2 音(E4 → C4)がゆっくり下がって、少し震える
    private static func sadNote() -> [Float] {
        let duration = 2.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        func note(_ freq: Double, length: Double, decay: Double) -> [Float] {
            let n = frameCount(length)
            var osc = Oscillator()
            var sub = Oscillator()
            var vib = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let vibrato = 1 + 0.008 * Double(vib.sine(5)) * min(t / 0.3, 1)
                let v = filter.process(osc.saw(freq * vibrato) * 0.5 + sub.sine(freq * 0.5) * 0.3, cutoff: 700, q: 1).low
                let release = Float(min(1, (length - t) / 0.08))
                s[i] = v * attackDecay(t, attack: 0.05, decay: decay) * release
            }
            return s
        }
        mix(note(329.63, length: 0.8, decay: 1.2), into: &out, at: 0, gain: 0.85)
        mix(note(261.63, length: duration - 0.7, decay: 1.0), into: &out, at: 0.7)
        echoes(&out, [(0.053, 0.2), (0.091, 0.14)])
        return out
    }

    /// 緊張: 低い音の長いうなりに半音のぶつかりを重ね、ゆっくりふくらむ(dramatic より静かで長い)
    private static func tensionDrone() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        // A1, A#1, E2
        let freqs: [Double] = [55.0, 58.27, 82.41]
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var filter = Filter()
        var pulse = Oscillator()
        var rng = Random(seed: 827)
        var air = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            var sum: Float = 0
            for j in freqs.indices { sum += oscs[j].saw(freqs[j]) }
            sum /= Float(freqs.count)
            let tone = filter.process(sum, cutoff: 150 + 500 * p, q: 1.3).low
            let throb = 0.75 + 0.25 * pulse.sine(1.5 + 2 * p)
            let hiss = air.process(rng.noise(), cutoff: 2500, q: 0.7).band * Float(p * p) * 0.08
            out[i] = (tone * throb + hiss) * hump(p, peak: 0.75)
        }
        return out
    }

    /// 遅い心音: ドッ・クンをゆっくり 2 回(不安な間)
    private static func heartbeatSlow() -> [Float] {
        let duration = 2.4
        var out = [Float](repeating: 0, count: frameCount(duration))
        func thump() -> [Float] {
            let n = frameCount(0.35)
            var osc = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let v = osc.sine(42 + 30 * exp(-t * 20)) * attackDecay(t, attack: 0.012, decay: 14)
                s[i] = filter.process(v, cutoff: 250, q: 0.7).low
            }
            return s
        }
        let beat = thump()
        mix(beat, into: &out, at: 0)
        mix(beat, into: &out, at: 0.3, gain: 0.7)
        mix(beat, into: &out, at: 1.3)
        mix(beat, into: &out, at: 1.6, gain: 0.7)
        return out
    }

    /// ビクッ: 高い不協和の短いスタブ + 低い打撃(驚きのスティンガー)
    private static func surpriseSting() -> [Float] {
        let duration = 0.9
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 828)
        // C5, F#5, B5, C6(不協和)
        mix(chord([523.25, 739.99, 987.77, 1046.5], length: 0.6, decay: 7, bright: 1.0), into: &out, at: 0)
        // 低い打撃
        let n = frameCount(0.5)
        var osc = Oscillator()
        var filter = Filter()
        var hit = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            hit[i] = osc.sine(55 + 90 * exp(-t * 25)) * attackDecay(t, attack: 0.003, decay: 7)
                + filter.process(rng.noise(), cutoff: 900, q: 0.8).low * Float(exp(-t * 60)) * 0.5
        }
        mix(hit, into: &out, at: 0, gain: 1.1)
        echoes(&out, [(0.041, 0.3), (0.073, 0.2)])
        return out
    }

    // ---- ゲーム(追加) ----

    /// チャリン: コインを取ったときの 2 音(B5 → E6)
    private static func coinGet() -> [Float] {
        let duration = 0.5
        var out = [Float](repeating: 0, count: frameCount(duration))
        mix(chipNote(987.77, length: 0.09, decay: 8), into: &out, at: 0, gain: 0.9)
        mix(chipNote(1318.5, length: 0.42, decay: 7), into: &out, at: 0.08)
        return out
    }

    /// レベルアップ: 駆け上がるアルペジオ(C5 E5 G5 C6 E6)のあと、最後の音を伸ばす
    private static func levelUp() -> [Float] {
        let duration = 1.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        let notes: [Double] = [523.25, 659.25, 783.99, 1046.5, 1318.5]
        for (index, freq) in notes.enumerated() {
            let at = Double(index) * 0.075
            let isLast = index == notes.count - 1
            mix(chipNote(freq, length: isLast ? duration - at : 0.09, decay: isLast ? 4 : 10),
                into: &out, at: at, gain: isLast ? 1 : 0.8)
        }
        // 最後の音に 1 オクターブ下を添える
        mix(chipNote(659.25, length: duration - 0.3, decay: 4), into: &out, at: 0.3, gain: 0.5)
        echoes(&out, [(0.06, 0.25), (0.12, 0.15)])
        return out
    }

    /// 失敗ジングル: 下がる 3 音のあと、最後の音がずり下がる(ゲーム風)
    private static func fail() -> [Float] {
        let duration = 1.3
        var out = [Float](repeating: 0, count: frameCount(duration))
        // G4 → F#4 → F4 → E4(ずり下がる)
        mix(chipNote(392.0, length: 0.2, decay: 6), into: &out, at: 0)
        mix(chipNote(369.99, length: 0.2, decay: 6), into: &out, at: 0.22)
        mix(chipNote(349.23, length: 0.2, decay: 6), into: &out, at: 0.44)
        mix(chipNote(329.63, length: duration - 0.68, decay: 3, slideTo: 246.94), into: &out, at: 0.68)
        // 1 オクターブ下を薄く添えて重くする
        mix(chipNote(164.81, length: duration - 0.68, decay: 3, slideTo: 123.47), into: &out, at: 0.68, gain: 0.5)
        return out
    }

    /// ジャンプ: 8bit の跳ぶ音(矩形波が素早く上がる)
    private static func jump8bit() -> [Float] {
        let duration = 0.28
        let n = frameCount(duration)
        var osc = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let f = 180 * pow(5.0, pow(p, 0.6))
            let release = Float(min(1, (duration - t) / 0.02))
            out[i] = filter.process(osc.square(f) * 0.5, cutoff: 4000, q: 0.7).low * Float(min(t / 0.003, 1)) * release
        }
        return out
    }

    /// パワーアップ: 短い音が階段のように上がっていく(8bit 風)
    private static func powerUp() -> [Float] {
        let duration = 0.9
        var out = [Float](repeating: 0, count: frameCount(duration))
        let steps = 10
        for k in 0..<steps {
            let p = Double(k) / Double(steps)
            let freq = 440 * pow(4.0, p)
            mix(chipNote(freq, length: 0.1, decay: 10, slideTo: freq * 1.3), into: &out, at: p * 0.75, gain: Float(0.7 + 0.3 * p))
        }
        mix(chipNote(1760, length: duration - 0.75, decay: 6), into: &out, at: 0.75)
        return out
    }

    // ---- スポーツ・アクション(追加) ----

    /// ホイッスル: 審判の笛(高い音にピーッという速い震えとかすれた息)
    private static func whistle() -> [Float] {
        let duration = 0.7
        let n = frameCount(duration)
        var rng = Random(seed: 829)
        var osc = Oscillator()
        var breath = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            // 笛の中の玉が転がる速い震え
            let roll = 1 + 0.04 * sin(2 * Double.pi * 38 * t)
            let f = 2900 * roll
            let tone = osc.tone(f, h2: 0.12, h3: 0.05)
            let air = breath.process(rng.noise(), cutoff: f, q: 4).band * 0.3
            let env = Float(min(t / 0.015, 1)) * Float(min(1, (duration - t) / 0.06))
            out[i] = (tone + air) * env * Float(0.85 + 0.15 * hump(p, peak: 0.3))
        }
        return out
    }

    /// ブザー: 試合終了の低いブザー(矩形波の和音を 1 回長く)
    private static func buzzer() -> [Float] {
        let duration = 1.0
        let n = frameCount(duration)
        var a = Oscillator()
        var b = Oscillator()
        var c = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let raw = 0.5 * a.square(174.61) + 0.35 * b.square(176.5) + 0.3 * c.saw(349.23)
            let env = Float(min(t / 0.008, 1)) * Float(min(1, (duration - t) / 0.05))
            out[i] = filter.process(raw, cutoff: 1300, q: 1.2).low * env
        }
        return out
    }

    /// バシッ: パンチの当たる音(ノイズの鋭い破裂 + 低い打撃、少し歪ませる)
    private static func punch() -> [Float] {
        let duration = 0.35
        let n = frameCount(duration)
        var rng = Random(seed: 830)
        var osc = Oscillator()
        var smack = Filter()
        var body = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let x = rng.noise()
            let hit = smack.process(x, cutoff: 700 + 2500 * exp(-t * 120), q: 1).band * Float(exp(-t * 55))
            let low = osc.sine(110 + 90 * exp(-t * 60)) * attackDecay(t, attack: 0.002, decay: 18)
            let thump = body.process(x, cutoff: 250, q: 0.8).low * Float(exp(-t * 40)) * 0.7
            out[i] = Float(tanh(Double(hit + low + thump) * 2) / tanh(2))
        }
        echoes(&out, [(0.023, 0.2)])
        return out
    }

    /// カウントダウン: 3 回の短い電子音のあと、高く長いスタートの音
    private static func countdown() -> [Float] {
        let duration = 2.4
        var out = [Float](repeating: 0, count: frameCount(duration))
        mix(simpleNote(880, length: 0.15, decay: 10, h2: 0.3), into: &out, at: 0, gain: 0.8)
        mix(simpleNote(880, length: 0.15, decay: 10, h2: 0.3), into: &out, at: 0.5, gain: 0.8)
        mix(simpleNote(880, length: 0.15, decay: 10, h2: 0.3), into: &out, at: 1.0, gain: 0.8)
        mix(simpleNote(1760, length: duration - 1.5, decay: 3, h2: 0.3), into: &out, at: 1.5)
        return out
    }

    // =================================================================
    // シーン別の追加分(食事・パーティー・季節・行事など)
    // =================================================================

    /// 金属のベル 1 音(倍音が整数倍でない)。bell() を好きな高さ・長さで使えるようにしたもの
    private static func metalBell(_ f0: Double, length: Double, decay: Double, beat: Bool = true) -> [Float] {
        let n = frameCount(length)
        let ratios: [Double] = [1, 2.0, 2.76, 5.4, 8.93]
        let amps: [Float] = [1, 0.3, 0.5, 0.25, 0.12]
        var oscs = [Oscillator](repeating: Oscillator(), count: ratios.count)
        var beatOsc = Oscillator()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var v: Float = 0
            for j in ratios.indices {
                v += amps[j] * oscs[j].sine(f0 * ratios[j]) * attackDecay(t, attack: 0.002, decay: decay * (1 + 0.6 * Double(j)))
            }
            if beat { v += 0.5 * beatOsc.sine(f0 * 1.003) * attackDecay(t, attack: 0.002, decay: decay) }
            let release = Float(min(1, (length - t) / 0.05))
            s[i] = v * release
        }
        return s
    }

    // ---- 食事・パーティー ----

    /// ポリポリ: かじる音を 4 回(乾いたノイズの短い粒を少しずつ違う高さで)
    private static func crunch() -> [Float] {
        let duration = 0.9
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 901)
        func bite() -> [Float] {
            let n = frameCount(0.12)
            var filter = Filter()
            var low = Filter()
            var s = [Float](repeating: 0, count: n)
            let center = rng.uniform(1800...3200)
            for i in 0..<n {
                let t = time(i)
                let x = rng.noise()
                // 砕ける粒(荒いノイズ)+ あごの低い音
                let grain: Float = rng.unit() < 0.35 ? x : 0
                s[i] = filter.process(grain, cutoff: center, q: 1.2).band * Float(exp(-t * 45))
                    + low.process(x, cutoff: 300, q: 0.8).low * Float(exp(-t * 80)) * 0.5
            }
            return s
        }
        var at = 0.0
        while at < duration - 0.15 {
            mix(bite(), into: &out, at: at, gain: Float(rng.uniform(0.7...1.0)))
            at += rng.uniform(0.17...0.24)
        }
        return out
    }

    /// ポン(栓): コルクが抜ける音(短い低い破裂 + 瓶の口の共鳴がすっと上がる)
    private static func corkPop() -> [Float] {
        let duration = 0.3
        let n = frameCount(duration)
        var rng = Random(seed: 902)
        var osc = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let f = 350 * pow(2.2, min(t / 0.05, 1))
            let body = osc.sine(f) * attackDecay(t, attack: 0.002, decay: 28)
            let burst = filter.process(rng.noise(), cutoff: 1200, q: 0.9).low * Float(exp(-t * 250)) * 0.8
            out[i] = body + burst
        }
        return out
    }

    /// 乾杯: グラスが当たる高い金属音を 2 つ(わずかに違う高さ)
    private static func clink() -> [Float] {
        let duration = 1.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 903)
        var tap = [Float](repeating: 0, count: frameCount(0.03))
        var filter = Filter()
        for i in tap.indices {
            tap[i] = filter.process(rng.noise(), cutoff: 5000, q: 1.5).band * Float(exp(-time(i) * 400))
        }
        mix(tap, into: &out, at: 0, gain: 0.6)
        mix(metalBell(3100, length: duration, decay: 3.5, beat: false), into: &out, at: 0.002, gain: 0.9)
        mix(metalBell(3650, length: duration - 0.012, decay: 4, beat: false), into: &out, at: 0.012, gain: 0.7)
        return out
    }

    /// やかん: お湯が沸いてピーッと鳴る(ノイズがふくらみ、笛の音が入ってくる)
    private static func kettle() -> [Float] {
        let duration = 2.6
        let n = frameCount(duration)
        var rng = Random(seed: 904)
        var steam = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let hiss = steam.process(rng.noise(), cutoff: 2500 + 2500 * p, q: 0.9).band * Float(0.3 + 0.7 * p)
            // 笛は 4 割を過ぎてから上がりながら入る
            let w = max(0, (p - 0.4) / 0.6)
            let f = 2300 * pow(1.25, w) * (1 + 0.01 * sin(2 * Double.pi * 7 * t))
            let whistle = osc.tone(f, h2: 0.2) * Float(w * w)
            out[i] = (hiss * 0.5 + whistle) * Float(min(1, (duration - t) / 0.1))
        }
        return out
    }

    /// コトッ: カップを静かに置く(陶器の短い鳴り + 机の低い音)
    private static func cupSet() -> [Float] {
        let duration = 0.25
        let n = frameCount(duration)
        var rng = Random(seed: 905)
        var a = Oscillator()
        var b = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let ring = (a.sine(1850) + 0.5 * b.sine(2740)) * Float(exp(-t * 60)) * 0.5
            let table = filter.process(rng.noise(), cutoff: 400, q: 0.8).low * Float(exp(-t * 120))
            out[i] = ring + table
        }
        return out
    }

    /// ページめくり: 紙がこすれて、ぱさっと落ち着く
    private static func pageFlip() -> [Float] {
        let duration = 0.45
        var out = noiseSweep(seed: 906, length: 0.3, from: 1500, to: 4500, q: 1.1, peak: 0.6, curve: 1.3)
        out += [Float](repeating: 0, count: frameCount(duration) - out.count)
        var rng = Random(seed: 907)
        var filter = Filter()
        var settle = [Float](repeating: 0, count: frameCount(0.1))
        for i in settle.indices {
            let t = time(i)
            settle[i] = filter.process(rng.noise(), cutoff: 900, q: 0.8).band * Float(exp(-t * 80))
        }
        mix(settle, into: &out, at: 0.3, gain: 0.7)
        return out
    }

    /// チクタク: 時計の針の音を 1 秒おきに(チッ・タッで少し音が違う)
    private static func clockTick() -> [Float] {
        let duration = 3.0
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 908)
        func tock(_ pitch: Double, cutoff: Double) -> [Float] {
            let n = frameCount(0.05)
            var filter = Filter()
            var osc = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                s[i] = filter.process(rng.noise(), cutoff: cutoff, q: 2).band * Float(exp(-t * 300))
                    + osc.sine(pitch) * Float(exp(-t * 200)) * 0.5
            }
            return s
        }
        var k = 0
        var at = 0.1
        while at < duration - 0.1 {
            let even = k % 2 == 0
            mix(tock(even ? 2100 : 1700, cutoff: even ? 3200 : 2400), into: &out, at: at, gain: even ? 1 : 0.85)
            at += 0.5
            k += 1
        }
        return out
    }

    /// 学校チャイム: キーンコーンカーンコーン(ウェストミンスターの 4 音)
    private static func schoolBell() -> [Float] {
        let duration = 2.6
        var out = [Float](repeating: 0, count: frameCount(duration))
        // E5, C5, D5, G4
        let notes: [Double] = [659.25, 523.25, 587.33, 392.0]
        for (index, f) in notes.enumerated() {
            let at = Double(index) * 0.55
            let isLast = index == notes.count - 1
            mix(metalBell(f, length: duration - at, decay: isLast ? 1.2 : 1.8), into: &out, at: at, gain: 0.8)
        }
        echoes(&out, [(0.07, 0.25), (0.13, 0.15)])
        return out
    }

    /// ギィ: 古いドアのきしみ(低くざらついた音がゆっくり上がる)
    private static func creak() -> [Float] {
        let duration = 1.4
        let n = frameCount(duration)
        var rng = Random(seed: 909)
        var osc = Oscillator()
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        var held: Float = 0
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            // 引っかかりながら動くので、音程が細かく揺れる
            if i % 40 == 0 { held = rng.noise() }
            let f = 95 * pow(2.2, pow(p, 1.4)) * (1 + 0.04 * Double(held)) * (1 + 0.02 * sin(2 * Double.pi * 13 * t))
            let raw = osc.saw(f) + 0.3 * rng.noise()
            out[i] = filter.process(raw, cutoff: 500 + 1500 * p, q: 3).band * hump(p, peak: 0.6)
        }
        return out
    }

    /// いただきます: 食事の合図の明るい 3 音(G5 → E5 → C5 の順で柔らかく)
    private static func mealChime() -> [Float] {
        let duration = 1.3
        var out = [Float](repeating: 0, count: frameCount(duration))
        mix(simpleNote(783.99, length: 0.5, decay: 6, h2: 0.15, h3: 0.05), into: &out, at: 0, gain: 0.8)
        mix(simpleNote(659.25, length: 0.5, decay: 6, h2: 0.15, h3: 0.05), into: &out, at: 0.2, gain: 0.8)
        mix(simpleNote(523.25, length: duration - 0.4, decay: 3.5, h2: 0.15, h3: 0.05), into: &out, at: 0.4)
        mix(simpleNote(1046.5, length: duration - 0.4, decay: 4, h2: 0.1), into: &out, at: 0.4, gain: 0.4)
        return out
    }

    /// 風鈴: 高いガラスの鈴がいくつか、不規則に鳴る
    private static func windChime() -> [Float] {
        let duration = 2.8
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 910)
        let notes: [Double] = [2637, 2960, 3520, 3951, 4699]
        var at = 0.05
        while at < duration - 0.6 {
            let f = notes[Int(rng.uniform(0...4.99))]
            mix(metalBell(f, length: min(1.6, duration - at), decay: 2.5, beat: false), into: &out, at: at, gain: Float(rng.uniform(0.4...1.0)))
            at += rng.uniform(0.12...0.55)
        }
        return out
    }

    /// 魔法: 上がる高い粒(キラキラ)に、ゆっくり上がる光の帯を重ねる
    private static func magicShimmer() -> [Float] {
        let duration = 1.6
        let n = frameCount(duration)
        var out = [Float](repeating: 0, count: n)
        var rng = Random(seed: 911)
        for k in 0..<18 {
            let p = Double(k) / 18
            let f = 1800 * pow(3.5, p) * rng.uniform(0.97...1.03)
            mix(simpleNote(f, length: 0.4, decay: 9, h2: 0.3), into: &out, at: p * 1.0 + rng.uniform(0...0.02), gain: Float(rng.uniform(0.4...0.9)))
        }
        var a = Oscillator()
        var b = Oscillator()
        var shimmerFilter = Filter()
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let f = 600 * pow(4.0, p)
            let band = (a.sine(f) + 0.5 * b.sine(f * 1.5)) * hump(p, peak: 0.6) * 0.25
            let air = shimmerFilter.process(rng.noise(), cutoff: 6000 + 4000 * p, q: 1.5).band * hump(p, peak: 0.7) * 0.2
            out[i] += band + air
        }
        echoes(&out, [(0.06, 0.3), (0.13, 0.2), (0.21, 0.12)])
        return out
    }

    /// オルゴール: 小さな金属の歯が鳴る短いメロディ(きらきら星の出だし)
    private static func musicBox() -> [Float] {
        let duration = 2.6
        var out = [Float](repeating: 0, count: frameCount(duration))
        // C6 C6 G6 G6 A6 A6 G6
        let notes: [Double] = [1046.5, 1046.5, 1568, 1568, 1760, 1760, 1568]
        let starts: [Double] = [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8]
        for (index, f) in notes.enumerated() {
            let n = frameCount(1.0)
            var a = Oscillator()
            var b = Oscillator()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                s[i] = (a.sine(f) + 0.35 * b.sine(f * 3.0)) * attackDecay(t, attack: 0.001, decay: 4.5)
            }
            mix(s, into: &out, at: starts[index], gain: index == notes.count - 1 ? 1 : 0.85)
        }
        return out
    }

    /// 教会の鐘: 大きな鐘を 3 回、ゆっくり(低く長い余韻)
    private static func churchBells() -> [Float] {
        let duration = 3.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        let notes: [Double] = [523.25, 392.0, 523.25]
        let starts: [Double] = [0, 0.9, 1.8]
        for (index, f) in notes.enumerated() {
            mix(metalBell(f, length: duration - starts[index], decay: 1.0), into: &out, at: starts[index], gain: 0.9)
            mix(metalBell(f * 0.5, length: duration - starts[index], decay: 0.8, beat: false), into: &out, at: starts[index], gain: 0.5)
        }
        echoes(&out, [(0.083, 0.3), (0.151, 0.2), (0.29, 0.12)])
        return out
    }

    /// 鈴: そりの鈴をシャンシャンと振る(高い小さな鈴の束を 4 回)
    private static func sleighBells() -> [Float] {
        let duration = 1.6
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 912)
        func shake() -> [Float] {
            let n = frameCount(0.25)
            var s = [Float](repeating: 0, count: n)
            for _ in 0..<8 {
                let f = rng.uniform(5000...9000)
                let at = rng.uniform(0...0.03)
                var osc = Oscillator()
                var one = [Float](repeating: 0, count: n - frameCount(at))
                for i in one.indices {
                    one[i] = osc.tone(f, h2: 0.3) * attackDecay(time(i), attack: 0.001, decay: 18)
                }
                mix(one, into: &s, at: at, gain: Float(rng.uniform(0.3...0.8)))
            }
            var filter = Filter()
            for i in 0..<n {
                s[i] += filter.process(rng.noise(), cutoff: 8000, q: 0.7).high * Float(exp(-time(i) * 40)) * 0.3
            }
            return s
        }
        for k in 0..<4 {
            mix(shake(), into: &out, at: Double(k) * 0.36, gain: Float(rng.uniform(0.8...1.0)))
        }
        return out
    }

    /// クラッカー: パンッという破裂と、紙テープのしゅるしゅる
    private static func partyPopper() -> [Float] {
        let duration = 0.7
        let n = frameCount(duration)
        var rng = Random(seed: 913)
        var bang = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let x = rng.noise()
            let crack = bang.process(x, cutoff: 1500 + 4000 * exp(-t * 100), q: 0.8).band * Float(exp(-t * 35))
            let low = osc.sine(140 + 200 * exp(-t * 80)) * Float(exp(-t * 30)) * 0.6
            out[i] = Float(tanh(Double(crack + low) * 1.8) / tanh(1.8))
        }
        // 紙テープが飛ぶ音
        mix(noiseSweep(seed: 914, length: 0.5, from: 5000, to: 2500, q: 0.8, peak: 0.2), into: &out, at: 0.05, gain: 0.3)
        echoes(&out, [(0.029, 0.25), (0.053, 0.15)])
        return out
    }

    /// パン(合図): 運動会の合図のパンという乾いた破裂音(余韻短め)
    private static func starterPistol() -> [Float] {
        let duration = 0.6
        let n = frameCount(duration)
        var rng = Random(seed: 915)
        var crack = Filter()
        var body = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let x = rng.noise()
            let snap = crack.process(x, cutoff: 2500, q: 0.7).high * Float(exp(-t * 90))
            let boom = body.process(x, cutoff: 350, q: 0.8).low * Float(exp(-t * 25)) * 0.9
            out[i] = Float(tanh(Double(snap + boom) * 2) / tanh(2))
        }
        // 校庭に響く
        echoes(&out, [(0.11, 0.3), (0.23, 0.18), (0.37, 0.1)])
        return out
    }

    /// 鼓: ポンという張りのある高めの打音を 2 回(間を置いて)
    private static func tsuzumi() -> [Float] {
        let duration = 1.4
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 916)
        func pon() -> [Float] {
            let n = frameCount(0.5)
            var osc = Oscillator()
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                // 打ったあと皮が締まって音程が少し上がる
                let f = 330 * (1 - 0.25 * exp(-t * 40)) * (1 + 0.06 * min(t / 0.15, 1))
                let body = osc.tone(f, h2: 0.2) * attackDecay(t, attack: 0.002, decay: 9)
                let slap = filter.process(rng.noise(), cutoff: 2000, q: 1).band * Float(exp(-t * 120)) * 0.5
                s[i] = body + slap
            }
            return s
        }
        mix(pon(), into: &out, at: 0, gain: 0.9)
        mix(pon(), into: &out, at: 0.75)
        echoes(&out, [(0.09, 0.2)])
        return out
    }

    // ---- 季節 ----

    /// セミ: ジージーという連続した鳴き声(速く刻んだ帯域ノイズ + うなる音)
    private static func cicadas() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        var rng = Random(seed: 917)
        var filter = Filter()
        var osc = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            // 1 秒に 55 回の刻み(ジジジジ)+ ゆっくりしたうねり
            let pulse = 0.4 + 0.6 * max(0, sin(2 * Double.pi * 55 * t))
            let swell = 0.6 + 0.4 * sin(2 * Double.pi * 0.7 * t)
            let buzz = filter.process(rng.noise(), cutoff: 4200 + 600 * swell, q: 4).band
            let tone = osc.tone(4300 + 100 * swell, h2: 0.3) * 0.25
            out[i] = (buzz + tone) * Float(pulse * swell) * hump(p, peak: 0.5)
        }
        return out
    }

    /// 落ち葉: 枯れ葉を踏む・かき分けるかさかさ(高い粒の多いノイズ)
    private static func leavesRustle() -> [Float] {
        let duration = 2.0
        let n = frameCount(duration)
        var rng = Random(seed: 918)
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            let drift = slowDrift(t * 3, seed: 8.8)
            let grain: Float = rng.unit() < 0.3 + 0.4 * drift ? rng.noise() : 0
            out[i] = filter.process(grain, cutoff: 3500 + 2500 * drift, q: 0.9).band * Float(0.4 + 0.6 * drift) * hump(p, peak: 0.45)
        }
        return out
    }

    /// 雪を踏む: キュッ、ギュッと雪が締まる足音を 3 歩
    private static func snowCrunch() -> [Float] {
        let duration = 1.8
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 919)
        func step() -> [Float] {
            let n = frameCount(0.3)
            var filter = Filter()
            var low = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = time(i)
                let p = t / 0.3
                let x = rng.noise()
                // 粒が密に詰まっていく(後半ほど高くきしむ)
                let grain: Float = rng.unit() < 0.5 ? x : 0
                let squeak = filter.process(grain, cutoff: 2000 + 3000 * p, q: 1.6).band * hump(p, peak: 0.35)
                let press = low.process(x, cutoff: 250, q: 0.8).low * Float(exp(-t * 30)) * 0.5
                s[i] = squeak + press
            }
            return s
        }
        var at = 0.05
        while at < duration - 0.35 {
            mix(step(), into: &out, at: at, gain: Float(rng.uniform(0.8...1.0)))
            at += 0.55 + rng.uniform(-0.03...0.03)
        }
        return out
    }

    /// ししおどし: 竹が石を打つカコンという音と、水の流れる音
    private static func shishiOdoshi() -> [Float] {
        let duration = 2.4
        let n = frameCount(duration)
        var rng = Random(seed: 920)
        var stream = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let drift = slowDrift(t * 5, seed: 9.9)
            out[i] = stream.process(rng.noise(), cutoff: 1500 + 1000 * drift, q: 1).band * 0.12 * hump(t / duration, peak: 0.5)
        }
        // カコン(竹の筒の共鳴 2 つ + 当たるノイズ)
        let m = frameCount(0.6)
        var a = Oscillator()
        var b = Oscillator()
        var knock = Filter()
        var hit = [Float](repeating: 0, count: m)
        for i in 0..<m {
            let t = time(i)
            let body = (a.tone(520, h2: 0.3, h3: 0.15) + 0.6 * b.sine(1180)) * attackDecay(t, attack: 0.002, decay: 9)
            let tap = knock.process(rng.noise(), cutoff: 1500, q: 1).band * Float(exp(-t * 150)) * 0.6
            hit[i] = body + tap
        }
        mix(hit, into: &out, at: 1.0)
        echoes(&out, [(0.07, 0.25), (0.15, 0.15)])
        return out
    }

    // ---- 雰囲気(シーン別) ----

    /// 息づかい: ささやくような、吸って吐く息のノイズを 2 回
    private static func breath() -> [Float] {
        let duration = 2.4
        let n = frameCount(duration)
        var rng = Random(seed: 921)
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            // 1.2 秒で 1 呼吸。前半が吸う(高め)、後半が吐く(低め)
            let cycle = (t / 1.2).truncatingRemainder(dividingBy: 1)
            let inhale = cycle < 0.4
            let phase = inhale ? cycle / 0.4 : (cycle - 0.4) / 0.6
            let cutoff = inhale ? 1200 + 1800 * phase : 1800 - 1200 * phase
            let env = hump(phase, peak: inhale ? 0.6 : 0.3) * (inhale ? 0.8 : 1)
            out[i] = filter.process(rng.noise(), cutoff: cutoff, q: 1.5).band * env * hump(t / duration, peak: 0.5)
        }
        return out
    }

    /// 不気味: 逆再生のように膨らむ金属音のあと、不協和の低い打撃
    private static func eerieSting() -> [Float] {
        let duration = 2.2
        let hitAt = 1.1
        let n = frameCount(duration)
        var rng = Random(seed: 922)
        var metal = Filter()
        var oscs = [Oscillator](repeating: Oscillator(), count: 3)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            if t < hitAt {
                let p = t / hitAt
                // 膨らむ金属のうなり(不協和な 3 音)
                let freqs: [Double] = [311.13, 440.0, 466.16]
                var sum: Float = 0
                for j in freqs.indices { sum += oscs[j].saw(freqs[j] * (1 + 0.004 * sin(2 * Double.pi * 3 * t))) }
                let v = metal.process(sum / 3 + 0.2 * rng.noise(), cutoff: 800 + 3000 * p * p, q: 2).band
                out[i] = v * Float(pow(p, 2.5))
            }
        }
        // 打撃(低い音 + 高いひずんだ衝撃)
        mix(chord([65.41, 69.30, 98.0], length: duration - hitAt, decay: 2, bright: 0.4), into: &out, at: hitAt, gain: 1.2)
        var crack = Filter()
        var hit = [Float](repeating: 0, count: frameCount(0.4))
        for i in hit.indices {
            let t = time(i)
            hit[i] = crack.process(rng.noise(), cutoff: 900, q: 1).band * Float(exp(-t * 30))
        }
        mix(hit, into: &out, at: hitAt, gain: 0.8)
        echoes(&out, [(0.061, 0.3), (0.113, 0.2), (0.2, 0.12)])
        return out
    }

    /// はてな: 上がって首をかしげるような 2 音(G5 → C#6、最後が少し揺れる)
    private static func questionSting() -> [Float] {
        let duration = 1.1
        var out = [Float](repeating: 0, count: frameCount(duration))
        mix(simpleNote(783.99, length: 0.25, decay: 7, h2: 0.3, h3: 0.1), into: &out, at: 0, gain: 0.8)
        // 上がりきった音は少し震えて止まる
        let n = frameCount(duration - 0.22)
        var osc = Oscillator()
        var vib = Oscillator()
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let f = 1108.73 * (1 + 0.015 * Double(vib.sine(6)) * min(t / 0.2, 1))
            let release = Float(min(1, (duration - 0.22 - t) / 0.05))
            s[i] = osc.tone(f, h2: 0.3, h3: 0.1) * attackDecay(t, attack: 0.01, decay: 3.5) * release
        }
        mix(s, into: &out, at: 0.22)
        echoes(&out, [(0.05, 0.2)])
        return out
    }

    /// おりん: 仏具の鈴。低めの澄んだ音がとても長く残る
    private static func orin() -> [Float] {
        let duration = 3.5
        let n = frameCount(duration)
        let f0 = 1046.5
        let ratios: [Double] = [1, 2.71, 4.95, 7.6]
        let amps: [Float] = [1, 0.35, 0.15, 0.06]
        var oscs = [Oscillator](repeating: Oscillator(), count: ratios.count)
        var beat = Oscillator()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            var v: Float = 0
            for j in ratios.indices {
                v += amps[j] * oscs[j].sine(f0 * ratios[j]) * attackDecay(t, attack: 0.003, decay: 0.9 + 1.2 * Double(j))
            }
            // ゆっくりしたうなり
            v += 0.4 * beat.sine(f0 * 1.0015) * attackDecay(t, attack: 0.003, decay: 0.9)
            out[i] = v * Float(min(1, (duration - t) / 0.2))
        }
        return out
    }

    /// 静かな和音: 低く柔らかい和音(Am9)がゆっくり現れて消える
    private static func softLowChord() -> [Float] {
        let duration = 3.0
        let n = frameCount(duration)
        // A2, E3, G3, B3, C4
        let freqs: [Double] = [110.0, 164.81, 196.0, 246.94, 261.63]
        var oscs = [Oscillator](repeating: Oscillator(), count: freqs.count)
        var filter = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = t / duration
            var sum: Float = 0
            for j in freqs.indices { sum += oscs[j].tone(freqs[j], h2: 0.15) }
            sum /= Float(freqs.count)
            out[i] = filter.process(sum, cutoff: 500 + 300 * Double(hump(p, peak: 0.4)), q: 0.7).low * hump(p, peak: 0.35)
        }
        echoes(&out, [(0.067, 0.2), (0.12, 0.14)])
        return out
    }

    /// 幕開け: 柔らかい音がゆっくり上がって明るく開き、最後に軽くきらめく
    private static func risingSwell() -> [Float] {
        let duration = 2.6
        let n = frameCount(duration)
        var rng = Random(seed: 923)
        var oscs = [Oscillator](repeating: Oscillator(), count: 3)
        var filter = Filter()
        var air = Filter()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = time(i)
            let p = min(t / 1.8, 1)
            // C4 の和音が 1 オクターブ上がっていく
            let base = 261.63 * pow(2.0, pow(p, 1.3))
            let sum = (oscs[0].tone(base, h2: 0.2) + 0.7 * oscs[1].tone(base * 1.5, h2: 0.2) + 0.5 * oscs[2].tone(base * 1.26, h2: 0.2)) / 2.2
            let tone = filter.process(sum, cutoff: 500 + 3500 * p * p, q: 0.9).low
            let hiss = air.process(rng.noise(), cutoff: 3000 + 5000 * p, q: 0.8).band * Float(p * p) * 0.12
            let env = t < 1.8 ? Float(pow(p, 1.4)) : Float(exp(-(t - 1.8) * 2.5))
            out[i] = (tone + hiss) * env
        }
        // 開ききったところできらめく
        for k in 0..<6 {
            mix(simpleNote(2093 * pow(1.5, Double(k) * 0.4), length: 0.5, decay: 8, h2: 0.3), into: &out, at: 1.75 + Double(k) * 0.05, gain: 0.3)
        }
        echoes(&out, [(0.071, 0.25), (0.133, 0.15)])
        return out
    }

    /// ガラガラ: 赤ちゃんのがらがら(小さな粒がたくさん転がる)を 3 回振る
    private static func rattle() -> [Float] {
        let duration = 1.2
        var out = [Float](repeating: 0, count: frameCount(duration))
        var rng = Random(seed: 924)
        func shake() -> [Float] {
            let n = frameCount(0.22)
            var filter = Filter()
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let p = time(i) / 0.22
                let grain: Float = rng.unit() < 0.25 ? rng.noise() : 0
                s[i] = filter.process(grain, cutoff: 2500, q: 1.5).band * hump(p, peak: 0.3)
            }
            return s
        }
        for k in 0..<3 {
            mix(shake(), into: &out, at: Double(k) * 0.38, gain: Float(rng.uniform(0.8...1.0)))
        }
        return out
    }
}
