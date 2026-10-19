import Foundation
import AVFoundation
import Accelerate

// =====================================================================
// ラウドネス測定(ITU-R BS.1770 の簡易実装)
// - 48 kHz モノラル float に K 特性フィルタ(ハイシェルフ +4 dB @1681 Hz → ハイパス 38 Hz)
// - 400 ms ブロック・75% オーバーラップ(100 ms ホップ)の平均二乗
// - 絶対ゲート -70 LUFS、相対ゲート -10 LU
// - LUFS = -0.691 + 10 log10(平均二乗)
// 注意(近似であること):
//   * ステレオ素材は AVAssetReader でモノラルにミックスダウンしてから測るため、
//     規格どおりのチャンネル別測定と比べ数 dB 低めに出ることがある。
//   * peakDBFS は 48 kHz 上のサンプルピーク(トゥルーピークではない)。
// =====================================================================

struct LoudnessMeasurement {
    /// 統合ラウドネス(LUFS、近似)。無音などで測定不能な場合は -Double.infinity
    let integratedLUFS: Double
    /// サンプルピーク(dBFS)。無音の場合は -Double.infinity
    let peakDBFS: Double

    var isValid: Bool { integratedLUFS.isFinite }
}

/// 2 次 IIR(転置直接形 II)
private struct LoudnessBiquad {
    let b0: Double, b1: Double, b2: Double
    let a1: Double, a2: Double
    var z1: Double = 0
    var z2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2
        self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

enum LoudnessAnalyzer {
    /// 測定サンプルレート(K 特性フィルタ係数はこのレート前提)
    private static let sampleRate: Double = 48_000
    /// ゲーティングブロックのホップ(100 ms)
    private static let hopSamples = 4_800
    /// 1 ブロック = 4 ホップ(400 ms)
    private static let hopsPerBlock = 4
    private static let absoluteGateLUFS: Double = -70
    private static let relativeGateLU: Double = -10

    /// BS.1770 の 48 kHz 用 K 特性係数
    private static func makePreFilter() -> LoudnessBiquad {
        LoudnessBiquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                       a1: -1.69065929318241, a2: 0.73248077421585)
    }

    private static func makeHighPass() -> LoudnessBiquad {
        LoudnessBiquad(b0: 1.0, b1: -2.0, b2: 1.0,
                       a1: -1.99004745483398, a2: 0.99007225036621)
    }

    private static func lufs(fromMeanSquare ms: Double) -> Double {
        guard ms > 0, ms.isFinite else { return -Double.infinity }
        return -0.691 + 10 * log10(ms)
    }

    // MARK: - 測定

    /// ファイルの [start, end](元素材上の秒、nil = 先頭 / 末尾)を測定する。
    /// 音声トラックがない場合は AudioAnalysisError.noAudioTrack を投げる。
    static func measure(url: URL, start: Double? = nil, end: Double? = nil) async throws -> LoudnessMeasurement {
        final class State {
            var pre = LoudnessAnalyzer.makePreFilter()
            var hp = LoudnessAnalyzer.makeHighPass()
            /// ホップ(100 ms)ごとの二乗和(K 特性フィルタ後)
            var hopEnergies: [Double] = []
            var peak: Float = 0
        }
        let state = State()
        let splitter = AudioAnalysisFrameSplitter(frameLength: hopSamples)
        let hop = hopSamples

        try await AudioAnalysisPCMReader.stream(url: url, sampleRate: sampleRate, start: start, end: end) { chunk in
            // ピーク(フィルタ前)
            if !chunk.isEmpty {
                var chunkPeak: Float = 0
                vDSP_maxmgv(chunk, 1, &chunkPeak, vDSP_Length(chunk.count))
                if chunkPeak > state.peak { state.peak = chunkPeak }
            }
            // K 特性フィルタ → ホップごとの二乗和
            splitter.push(chunk) { frame in
                var sum = 0.0
                var pre = state.pre
                var hp = state.hp
                for i in 0..<hop {
                    let x = Double(frame[i])
                    let y = hp.process(pre.process(x))
                    sum += y * y
                }
                state.pre = pre
                state.hp = hp
                state.hopEnergies.append(sum)
            }
        }

        // 末尾の端数(100 ms 未満)はブロックが 1 つも無いときだけ使う
        let rest = splitter.remainder
        var energies = state.hopEnergies
        var trailingSamples = 0
        if energies.isEmpty, !rest.isEmpty {
            var sum = 0.0
            var pre = state.pre
            var hp = state.hp
            for v in rest {
                let y = hp.process(pre.process(Double(v)))
                sum += y * y
            }
            energies = [sum]
            trailingSamples = rest.count
        }

        try Task.checkCancellation()

        let peakDB: Double = state.peak > 0 ? 20 * log10(Double(state.peak)) : -Double.infinity
        let integrated = integratedLoudness(hopEnergies: energies,
                                            samplesPerHop: trailingSamples > 0 ? trailingSamples : hop)
        return LoudnessMeasurement(integratedLUFS: integrated, peakDBFS: peakDB)
    }

    /// ホップごとの二乗和からゲート付き統合ラウドネスを求める(純粋関数)
    static func integratedLoudness(hopEnergies: [Double], samplesPerHop: Int) -> Double {
        guard !hopEnergies.isEmpty, samplesPerHop > 0 else { return -Double.infinity }

        // 400 ms ブロック(4 ホップ)の平均二乗。ホップが 4 未満ならあるだけで 1 ブロック
        var blockMeanSquares: [Double] = []
        if hopEnergies.count < hopsPerBlock {
            let total = hopEnergies.reduce(0, +)
            blockMeanSquares = [total / Double(hopEnergies.count * samplesPerHop)]
        } else {
            let blockSamples = Double(hopsPerBlock * samplesPerHop)
            blockMeanSquares.reserveCapacity(hopEnergies.count - hopsPerBlock + 1)
            var window = 0.0
            for i in 0..<hopsPerBlock { window += hopEnergies[i] }
            blockMeanSquares.append(window / blockSamples)
            if hopEnergies.count > hopsPerBlock {
                for i in hopsPerBlock..<hopEnergies.count {
                    window += hopEnergies[i] - hopEnergies[i - hopsPerBlock]
                    blockMeanSquares.append(max(0, window) / blockSamples)
                }
            }
        }

        // 絶対ゲート
        let absGated = blockMeanSquares.filter { lufs(fromMeanSquare: $0) > absoluteGateLUFS }
        guard !absGated.isEmpty else { return -Double.infinity }
        let absMean = absGated.reduce(0, +) / Double(absGated.count)

        // 相対ゲート
        let relativeThreshold = lufs(fromMeanSquare: absMean) + relativeGateLU
        let relGated = absGated.filter { lufs(fromMeanSquare: $0) > relativeThreshold }
        guard !relGated.isEmpty else { return lufs(fromMeanSquare: absMean) }
        let relMean = relGated.reduce(0, +) / Double(relGated.count)
        return lufs(fromMeanSquare: relMean)
    }

    // MARK: - 正規化ゲイン

    /// 測定値を `targetLUFS`(既定 -16 LUFS、オンライン動画向け)へ合わせる線形ゲイン。
    /// ピークが -1 dBFS を超えないよう制限し、0.1...8 にクランプする。測定不能(無音)なら 1。
    static func normalizationGain(for m: LoudnessMeasurement, targetLUFS: Double = -16) -> Float {
        guard m.integratedLUFS.isFinite else { return 1 }
        var gainDB = targetLUFS - m.integratedLUFS
        if m.peakDBFS.isFinite {
            let peakLimitedDB = -1.0 - m.peakDBFS
            gainDB = min(gainDB, peakLimitedDB)
        }
        let linear = pow(10.0, gainDB / 20.0)
        guard linear.isFinite else { return 1 }
        return Float(min(max(linear, 0.1), 8.0))
    }

    /// ゲインを dB 表示にする(UI 用)
    static func decibels(fromGain gain: Float) -> Double {
        guard gain > 0 else { return -Double.infinity }
        return 20 * log10(Double(gain))
    }
}
