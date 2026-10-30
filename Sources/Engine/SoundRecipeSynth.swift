import Foundation
import AVFoundation

// =====================================================================
// レシピ(SoundRecipe)から音を作る汎用の合成器。SoundEffectSynth の部品(発振器・フィルター・乱数)を使う。
// 層ごとに: 波形/ノイズ → ADSR → フィルター(ローパス/ハイパス/バンドパス、動かせる) → 歪み → 定位。
// くり返しは 2 回目以降の音程と間隔をわずかに揺らして、機械的に聞こえないようにする。
// 仕上げ: ディレイ(echoes)→ 残響(Schroeder 型、左右で少し違う長さ)→ 直流除去 → 聞こえる大きさをそろえ -1dBFS に収める。
// 結果はステレオ 44.1kHz。乱数は recipe.randomSeed で固定なので、作り直しても同じ音になる。
// =====================================================================

extension SoundEffectSynth {
    /// レシピの仕上がりピーク(-1dBFS。今は SoundLoudness.swift の ceilingPeak を使う)
    static let recipePeak: Float = 0.891

    /// 残響の尾(この分だけ duration より長く書き出す)
    private static func tailLength(_ recipe: SoundRecipe) -> Double {
        let echoTail = recipe.echoes.map { $0.delay }.max().map { $0 * 3 } ?? 0
        let reverbTail = recipe.reverb > 0 ? min(recipe.reverbTime, 2.0) : 0
        return max(echoTail, reverbTail)
    }

    // MARK: - 入口

    /// レシピを左右 2 チャンネルの PCM(Float)に合成する
    static func renderSamples(recipe: SoundRecipe) -> (left: [Float], right: [Float]) {
        let total = frameCount(recipe.duration + tailLength(recipe))
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        var rng = Random(seed: recipe.randomSeed &+ 0x5EED)

        for layer in recipe.layers {
            let count = max(1, layer.repeats)
            let interval = layer.length + layer.repeatGap
            for r in 0..<count {
                // 2 回目以降は ±3% の揺れ(足音・ノックが機械的に並ばないように)
                let pitchScale = r == 0 ? 1.0 : rng.uniform(0.97...1.03)
                let timeShift = r == 0 ? 0.0 : rng.uniform(-0.03...0.03) * interval
                let gainScale = r == 0 ? 1.0 : rng.uniform(0.9...1.0)
                let start = max(0, layer.start + Double(r) * interval + timeShift)
                guard start < recipe.duration + 0.5 else { continue }
                let samples = renderLayer(layer, pitchScale: pitchScale, rng: &rng)
                mixStereo(samples, into: &left, &right, at: start, pan: layer.pan, gain: Float(gainScale))
            }
        }

        // ディレイ
        for (delay, gain) in recipe.echoes {
            let d = frameCount(delay)
            guard d > 0, d < total else { continue }
            for i in d..<total {
                left[i] += left[i - d] * gain
                right[i] += right[i - d] * gain
            }
        }

        // 残響
        if recipe.reverb > 0 {
            addReverb(&left, &right, send: recipe.reverb, time: recipe.reverbTime)
        }

        removeDC(&left)
        removeDC(&right)
        limit(&left, &right, ambience: isAmbience(recipe))
        return (left, right)
    }

    /// レシピをステレオの AVAudioPCMBuffer にする(フォーマットを作れなければ nil)
    static func render(recipe: SoundRecipe) -> AVAudioPCMBuffer? {
        let (left, right) = renderSamples(recipe: recipe)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else { return nil }
        for i in 0..<left.count {
            channels[0][i] = left[i]
            channels[1][i] = right[i]
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        return buffer
    }

    /// ステレオ 16bit PCM の .caf に書き出す
    static func writeStereo(left: [Float], right: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = AVAudioFrameCount(left.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let channels = buffer.floatChannelData, file.processingFormat.channelCount == 2 else {
            throw SynthError.bufferUnavailable
        }
        for i in 0..<left.count {
            channels[0][i] = left[i]
            channels[1][i] = right[i]
        }
        buffer.frameLength = count
        try file.write(from: buffer)
    }

    // MARK: - 層

    /// 1 層分をモノラルで作る
    private static func renderLayer(_ layer: SoundLayer, pitchScale: Double, rng: inout Random) -> [Float] {
        let length = max(layer.length, 0.005)
        let n = frameCount(length)
        var s = [Float](repeating: 0, count: n)

        var osc = Oscillator()
        var modulator = Oscillator()
        var lowpass = Filter()
        var highpassFilter = Filter()
        var bandpassFilter = Filter()
        // ピンク・ブラウンノイズの状態
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, brown: Float = 0

        let q = max(layer.resonance, 0.5)
        let driveAmount = Double(max(0, min(layer.drive, 1)))
        let driveGain = 1 + 4 * driveAmount
        let driveNorm = Float(tanh(driveGain))
        let pitchStart = max(layer.pitchStart, 1)
        let pitchEnd = layer.pitchEnd.map { max($0, 1) }
        let attack = max(layer.attack, 0.0005)
        let release = max(layer.release, 0.002)

        for i in 0..<n {
            let t = time(i)
            let p = t / length

            // エンベロープ(ADSR。終わりは必ず release で 0 にする)
            var env: Float
            if t < attack {
                env = Float(t / attack)
            } else if t < attack + layer.decay {
                env = 1 - (1 - layer.sustain) * Float((t - attack) / layer.decay)
            } else {
                env = layer.sustain
            }
            let remain = length - t
            if remain < release { env *= Float(remain / release) }

            // 音程(指数で滑らかに動かす + ビブラート)
            var freq = pitchStart * pitchScale
            if let pitchEnd { freq = pitchStart * pow(pitchEnd / pitchStart, p) * pitchScale }
            if layer.vibratoRate > 0, layer.vibratoDepth > 0 {
                let semis = layer.vibratoDepth * sin(2 * Double.pi * layer.vibratoRate * t)
                freq *= pow(2.0, semis / 12)
            }

            // 波形
            var v: Float
            switch layer.source {
            case .sine:
                v = osc.sine(freq)
            case .triangle:
                v = osc.triangle(freq)
            case .saw:
                v = osc.saw(freq)
            case .square:
                v = osc.square(freq)
            case .fm(let ratio, let index):
                // 変調波で位相を揺らす(ベル・金属音)。index は減衰に合わせて弱まる
                let m = Double(modulator.sine(freq * ratio)) * index * Double(0.3 + 0.7 * env)
                v = Float(sin(osc.phase * 2 * Double.pi + m))
                _ = osc.sine(freq)
            case .noise:
                v = rng.noise()
            case .pinkNoise:
                let w = rng.noise()
                b0 = 0.99765 * b0 + w * 0.0990460
                b1 = 0.96300 * b1 + w * 0.2965164
                b2 = 0.57000 * b2 + w * 1.0526913
                v = (b0 + b1 + b2 + w * 0.1848) * 0.25
            case .brownNoise:
                brown = (brown + 0.02 * rng.noise()) / 1.02
                v = brown * 3.5
            }

            // フィルター
            if let center = layer.bandpass {
                var c = center
                if let fs = layer.filterStart, let fe = layer.filterEnd, fs > 0 {
                    // ローパスの動きと同じ割合で中心を動かす
                    c = center * pow(fe / fs, p)
                }
                v = bandpassFilter.process(v, cutoff: c, q: q).band
            } else if let fs = layer.filterStart {
                let cutoff = layer.filterEnd.map { fs * pow($0 / fs, p) } ?? fs
                v = lowpass.process(v, cutoff: cutoff, q: q).low
            }
            if let hp = layer.highpass {
                v = highpassFilter.process(v, cutoff: hp, q: 0.7).high
            }

            // 歪み(柔らかい飽和)
            if driveAmount > 0 {
                v = Float(tanh(Double(v) * driveGain)) / driveNorm
            }

            s[i] = v * env * layer.gain
        }
        return s
    }

    /// モノラルの音を定位(pan)をつけて左右に足す
    private static func mixStereo(_ src: [Float], into left: inout [Float], _ right: inout [Float],
                                  at seconds: Double, pan: Float, gain: Float) {
        let offset = Int(seconds * sampleRate)
        guard offset < left.count else { return }
        let n = min(src.count, left.count - offset)
        guard n > 0 else { return }
        // 等パワーの定位
        let angle = Double(max(-1, min(pan, 1)) + 1) * Double.pi / 4
        let gl = Float(cos(angle)) * gain
        let gr = Float(sin(angle)) * gain
        for i in 0..<n {
            left[offset + i] += src[i] * gl
            right[offset + i] += src[i] * gr
        }
    }

    // MARK: - 残響

    /// Schroeder 型の残響(コム 4 本 + オールパス 2 本、プリディレイと高域の減衰つき)。左右で長さを少し変える
    private static func addReverb(_ left: inout [Float], _ right: inout [Float], send: Float, time rt60: Double) {
        let n = left.count
        guard n > 0 else { return }
        let preDelay = frameCount(0.012)
        let combsMs: [Double] = [29.7, 37.1, 41.1, 43.7]
        let allpassMs: [Double] = [5.0, 1.7]
        let damping: Float = 0.35
        let rt = max(rt60, 0.2)

        func process(offsetMs: Double) -> [Float] {
            // 入力は左右を足したもの
            let combLens = combsMs.map { frameCount(($0 + offsetMs) / 1000) }
            let combGains = combLens.map { Float(pow(10.0, -3 * Double($0) / sampleRate / rt)) }
            var combBufs = combLens.map { [Float](repeating: 0, count: $0) }
            var combLow = [Float](repeating: 0, count: combLens.count)
            let apLens = allpassMs.map { frameCount(($0 + offsetMs * 0.3) / 1000) }
            var apBufs = apLens.map { [Float](repeating: 0, count: $0) }
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let srcIndex = i - preDelay
                let x: Float = srcIndex >= 0 ? (left[srcIndex] + right[srcIndex]) * 0.5 : 0
                var sum: Float = 0
                for c in combLens.indices {
                    let idx = i % combLens[c]
                    let y = combBufs[c][idx]
                    // 戻す前に高域を少し削る(壁で吸われる感じ)
                    combLow[c] = y * (1 - damping) + combLow[c] * damping
                    combBufs[c][idx] = x + combLow[c] * combGains[c]
                    sum += y
                }
                var v = sum * 0.25
                for a in apLens.indices {
                    let idx = i % apLens[a]
                    let buffered = apBufs[a][idx]
                    let input = v + buffered * 0.5
                    apBufs[a][idx] = input
                    v = buffered - input * 0.5
                }
                out[i] = v
            }
            return out
        }

        let wetL = process(offsetMs: 0)
        let wetR = process(offsetMs: 0.9)
        for i in 0..<n {
            left[i] += wetL[i] * send
            right[i] += wetR[i] * send
        }
    }

    // MARK: - 仕上げ

    /// 環境音・長い音か(3 秒以上、または自然・季節の 1.5 秒以上の音)
    static func isAmbience(_ recipe: SoundRecipe) -> Bool {
        if isLongBed(seconds: recipe.duration) { return true }
        return (recipe.scene == .nature || recipe.scene == .season) && recipe.duration >= 1.5
    }

    /// 聞こえる大きさをそろえて -1dBFS に収め(SoundLoudness.swift)、頭と終わりに短いフェードをかける
    private static func limit(_ left: inout [Float], _ right: inout [Float], ambience: Bool) {
        var channels = [left, right]
        normalizeLoudness(&channels, ambience: ambience)
        left = channels[0]
        right = channels[1]
        let n = min(left.count, right.count)
        let fadeIn = min(n, frameCount(0.001))
        for i in 0..<fadeIn {
            let g = Float(i) / Float(fadeIn)
            left[i] *= g
            right[i] *= g
        }
        let fadeOut = min(n, frameCount(0.008))
        for i in 0..<fadeOut {
            let g = Float(i) / Float(fadeOut)
            left[n - 1 - i] *= g
            right[n - 1 - i] *= g
        }
    }
}
