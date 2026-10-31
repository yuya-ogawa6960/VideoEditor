import Foundation

// =====================================================================
// 効果音の音量そろえ(enum の SE とレシピの両方の最後に通す)。
// ピークではなく「聞こえる大きさ」でそろえる: K 特性もどき(60Hz ハイパス + 1.5kHz 以上 +4dB)をかけて
// 400ms 窓の二乗平均を測り、LUFS 相当の値で目標に合わせる。
//   単発の SE: 一番大きい 400ms 窓を -16 に(400ms に満たない音は足りない分を無音として数える)
//   環境音・長い音: 窓の平均(-70 と相対 -10 のゲート付き)を -20 に
// そのあと先読みリミッターで -1dBFS(サンプル値は約 -1.5dBFS。サンプル間のピーク分の余裕)に収める。
// =====================================================================

extension SoundEffectSynth {
    /// 単発の SE の目標(LUFS 相当)
    static let oneShotLoudness: Double = -16
    /// 環境音・長い音の目標(LUFS 相当)
    static let ambienceLoudness: Double = -20
    /// 最終的な上限(-1dBFS)
    static let ceilingPeak: Float = 0.891
    /// サンプル値の上限(サンプル間のピーク分 0.5dB の余裕をみる)
    private static let samplePeakLimit: Float = 0.841
    /// 静かな音を持ち上げすぎない上限(+24dB)
    private static let maxGainDB: Double = 24

    /// 長さ 3 秒以上は環境音・長い音として扱う
    static func isLongBed(seconds: Double) -> Bool { seconds >= 3 }

    /// 聞こえる大きさをそろえて -1dBFS に収める。channels はモノラルなら 1 本、ステレオなら 2 本(同じ長さ)
    static func normalizeLoudness(_ channels: inout [[Float]], ambience: Bool) {
        guard let n = channels.first?.count, n > 0 else { return }
        for c in channels.indices {
            for i in channels[c].indices where !channels[c][i].isFinite { channels[c][i] = 0 }
        }
        let target = ambience ? ambienceLoudness : oneShotLoudness
        if let measured = measureLoudness(channels, ambience: ambience) {
            let gainDB = min(maxGainDB, target - measured)
            let gain = Float(pow(10, gainDB / 20))
            for c in channels.indices {
                for i in 0..<n { channels[c][i] *= gain }
            }
        }
        limitPeaks(&channels)
    }

    // MARK: - 測る

    /// LUFS 相当の大きさ(無音なら nil)
    private static func measureLoudness(_ channels: [[Float]], ambience: Bool) -> Double? {
        let n = channels[0].count
        let window = frameCount(0.4)
        let hop = frameCount(0.1)
        // K 特性をかけた二乗を、全チャンネル分たし合わせる
        var power = [Double](repeating: 0, count: n)
        for ch in channels {
            let weighted = kWeight(ch)
            for i in 0..<n { power[i] += Double(weighted[i]) * Double(weighted[i]) }
        }
        // 累積和で窓ごとの平均を出す
        var cumulative = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cumulative[i + 1] = cumulative[i] + power[i] }
        var means: [Double] = []
        if n <= window {
            means.append(cumulative[n] / Double(window))
        } else {
            var start = 0
            while start + window <= n {
                means.append((cumulative[start + window] - cumulative[start]) / Double(window))
                start += hop
            }
            // 最後の端数も見る
            means.append((cumulative[n] - cumulative[n - window]) / Double(window))
        }
        func lufs(_ ms: Double) -> Double { -0.691 + 10 * log10(ms) }
        let audible = means.filter { $0 > 0 && lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        if !ambience {
            return lufs(audible.max() ?? 0)
        }
        // 環境音: 全体の平均から 10 下までの窓だけで平均をとる
        let overall = lufs(audible.reduce(0, +) / Double(audible.count))
        let gated = audible.filter { lufs($0) > overall - 10 }
        let use = gated.isEmpty ? audible : gated
        return lufs(use.reduce(0, +) / Double(use.count))
    }

    /// K 特性の近似: 60Hz ハイパス(2 次)→ 1.5kHz 以上 +4dB のハイシェルフ(2 次)
    private static func kWeight(_ input: [Float]) -> [Float] {
        var hp = LoudnessBiquad.highPass(freq: 60, q: 0.5)
        var shelf = LoudnessBiquad.highShelf(freq: 1500, gainDB: 4)
        var out = input
        for i in out.indices { out[i] = shelf.process(hp.process(out[i])) }
        return out
    }

    /// RBJ のクックブック式の 2 次フィルター
    private struct LoudnessBiquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        static func highPass(freq: Double, q: Double) -> LoudnessBiquad {
            let w = 2 * Double.pi * freq / SoundEffectSynth.sampleRate
            let alpha = sin(w) / (2 * q)
            let c = cos(w)
            let a0 = 1 + alpha
            var f = LoudnessBiquad()
            f.b0 = (1 + c) / 2 / a0
            f.b1 = -(1 + c) / a0
            f.b2 = (1 + c) / 2 / a0
            f.a1 = -2 * c / a0
            f.a2 = (1 - alpha) / a0
            return f
        }

        static func highShelf(freq: Double, gainDB: Double) -> LoudnessBiquad {
            let a = pow(10, gainDB / 40)
            let w = 2 * Double.pi * freq / SoundEffectSynth.sampleRate
            let c = cos(w)
            let alpha = sin(w) / 2 * sqrt(2.0)   // 傾き S = 1
            let sq = 2 * sqrt(a) * alpha
            let a0 = (a + 1) - (a - 1) * c + sq
            var f = LoudnessBiquad()
            f.b0 = a * ((a + 1) + (a - 1) * c + sq) / a0
            f.b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0
            f.b2 = a * ((a + 1) + (a - 1) * c - sq) / a0
            f.a1 = 2 * ((a - 1) - (a + 1) * c) / a0
            f.a2 = ((a + 1) - (a - 1) * c - sq) / a0
            return f
        }

        mutating func process(_ x: Float) -> Float {
            let xd = Double(x)
            let y = b0 * xd + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xd
            y2 = y1; y1 = y
            return Float(y)
        }
    }

    // MARK: - 収める

    /// 先読みリミッター: 山の 1.5ms 手前から下げ、60ms かけて戻す。左右は同じ量だけ下げる(定位を崩さない)
    private static func limitPeaks(_ channels: inout [[Float]]) {
        let n = channels[0].count
        let limit = samplePeakLimit
        // 各サンプルで必要な倍率
        var need = [Float](repeating: 1, count: n)
        var anyOver = false
        for i in 0..<n {
            var a: Float = 0
            for ch in channels { a = max(a, abs(ch[i])) }
            if a > limit {
                need[i] = limit / a
                anyOver = true
            }
        }
        if anyOver {
            let look = max(1, frameCount(0.0015))
            // 先読み分の最小値(山より前から下げ始める)
            var gain = [Float](repeating: 1, count: n)
            let release = Float(exp(-1 / (0.06 * sampleRate)))
            var env: Float = 1
            for i in 0..<n {
                var m: Float = 1
                var j = i
                let end = min(n, i + look + 1)
                while j < end { m = min(m, need[j]); j += 1 }
                // 下げるのはすぐ、戻りはゆっくり
                env = m < env ? m : m + (env - m) * release
                gain[i] = env
            }
            // 角を丸める(移動平均)。山で足りなくならないよう元の値以下にとどめる
            var sum: Float = 0
            for i in 0..<n {
                sum += gain[i]
                if i >= look { sum -= gain[i - look] }
                let smooth = sum / Float(min(i + 1, look))
                let g = min(smooth, gain[i])
                for c in channels.indices { channels[c][i] *= g }
            }
        }
        // 念のため上限で止める
        let ceiling = ceilingPeak
        for c in channels.indices {
            for i in 0..<n { channels[c][i] = max(-ceiling, min(ceiling, channels[c][i])) }
        }
    }
}
