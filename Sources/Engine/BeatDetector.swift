import Foundation

// =====================================================================
// ビート検出(エネルギーの立ち上がりによるオンセット検出)。
// 元素材の [start, end] をモノラル PCM で読み、短い窓ごとのエネルギーと
// 高域エネルギーの増分からオンセット強度を作り、局所しきい値を超えた
// ピークをビートとする。戻り値は元素材上の秒。
// =====================================================================

enum BeatDetector {
    private static let sampleRate: Double = 22_050
    private static let hop = 512

    /// ビート(元素材上の秒)。sensitivity 0.1...1(高いほど多く検出)
    static func detectBeats(url: URL, start: Double, end: Double, sensitivity: Double = 0.5) async throws -> [Double] {
        let rangeStart = max(0, min(start, end))
        let rangeEnd = max(start, end)
        guard rangeEnd - rangeStart > 0.2 else { return [] }

        let samples = try await AudioAnalysisPCMReader.readMono(url: url, sampleRate: sampleRate,
                                                                start: rangeStart, end: rangeEnd)
        try Task.checkCancellation()
        return beats(in: samples, origin: rangeStart, sensitivity: sensitivity)
    }

    /// PCM(モノラル、sampleRate Hz)からビートを求める(テストしやすいよう分離)
    static func beats(in samples: [Float], origin: Double, sensitivity: Double) -> [Double] {
        let frames = samples.count / hop
        guard frames > 8 else { return [] }

        // 窓ごとのエネルギーと高域(差分)エネルギー
        var energy = [Float](repeating: 0, count: frames)
        var highEnergy = [Float](repeating: 0, count: frames)
        var previous: Float = 0
        for f in 0..<frames {
            var e: Float = 0
            var h: Float = 0
            let base = f * hop
            for i in 0..<hop {
                let s = samples[base + i]
                e += s * s
                let d = s - previous
                h += d * d
                previous = s
            }
            energy[f] = e / Float(hop)
            highEnergy[f] = h / Float(hop)
        }

        // オンセット強度: 対数エネルギーの正の増分
        var onset = [Float](repeating: 0, count: frames)
        for f in 1..<frames {
            let a = log10f(energy[f] + 1e-7) - log10f(energy[f - 1] + 1e-7)
            let b = log10f(highEnergy[f] + 1e-7) - log10f(highEnergy[f - 1] + 1e-7)
            onset[f] = max(0, a) + 0.5 * max(0, b)
        }

        var mean: Float = 0
        for v in onset { mean += v }
        mean /= Float(frames)
        var variance: Float = 0
        for v in onset {
            let d = v - mean
            variance += d * d
        }
        variance /= Float(frames)
        let std = sqrtf(variance)

        let sens = min(max(sensitivity, 0), 1)
        let k = Float(2.6 - 2.1 * sens)            // 0.5 ... 2.6
        let minimumGap = 0.6 - 0.4 * sens          // 0.2 ... 0.6 秒
        let window = max(2, Int(0.5 * sampleRate / Double(hop)))
        let frameSeconds = Double(hop) / sampleRate

        var result: [Double] = []
        var lastBeat = -Double.greatestFiniteMagnitude
        for f in 1..<(frames - 1) {
            let lo = max(0, f - window)
            let hi = min(frames - 1, f + window)
            var local: Float = 0
            for j in lo...hi { local += onset[j] }
            local /= Float(hi - lo + 1)
            let threshold = local + k * std + 0.02
            if onset[f] > threshold, onset[f] >= onset[f - 1], onset[f] >= onset[f + 1] {
                let t = origin + Double(f) * frameSeconds
                if t - lastBeat >= minimumGap {
                    result.append(t)
                    lastBeat = t
                }
            }
        }
        return result
    }

    /// オンセット列から BPM を推定する(70...180 に折りたたむ)。情報が足りなければ nil
    static func estimateBPM(onsets: [Double]) -> Double? {
        let sorted = onsets.sorted()
        guard sorted.count >= 4 else { return nil }
        var intervals: [Double] = []
        for i in 1..<sorted.count {
            let d = sorted[i] - sorted[i - 1]
            if d > 0.2 && d < 2.0 { intervals.append(d) }
        }
        guard intervals.count >= 3 else { return nil }

        var bins: [Int: Int] = [:]
        for d in intervals {
            var bpm = 60 / d
            while bpm < 70 { bpm *= 2 }
            while bpm > 180 { bpm /= 2 }
            let key = Int(bpm.rounded())
            bins[key, default: 0] += 1
        }

        var bestKey = 0
        var bestMass = 0
        for key in bins.keys {
            var mass = 0
            for dk in -2...2 { mass += bins[key + dk] ?? 0 }
            if mass > bestMass {
                bestMass = mass
                bestKey = key
            }
        }
        guard bestMass > 0 else { return nil }

        var sum = 0.0
        var weight = 0.0
        for dk in -2...2 {
            let count = Double(bins[bestKey + dk] ?? 0)
            sum += Double(bestKey + dk) * count
            weight += count
        }
        return weight > 0 ? sum / weight : nil
    }
}
