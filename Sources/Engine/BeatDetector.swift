import Foundation
import AVFoundation

// =====================================================================
// ビート検出(エネルギーの立ち上がりによるオンセット検出)。
// 元素材の [start, end] をモノラル PCM で少しずつ読み、短い窓ごとのエネルギーと
// 高域エネルギーの増分からオンセット強度を作り、局所しきい値を超えた
// ピークをビートとする。戻り値は元素材上の秒。
// 音声全体は配列に貯めず、窓ごとのエネルギーだけを貯める(長い配信録画・1 時間の BGM でもメモリを使いすぎない)。
// =====================================================================

enum BeatDetector {
    private static let sampleRate: Double = 22_050
    private static let hop = 512

    /// ビート(元素材上の秒)。sensitivity 0.1...1(高いほど多く検出)
    static func detectBeats(url: URL, start: Double, end: Double, sensitivity: Double = 0.5) async throws -> [Double] {
        let rangeStart = max(0, min(start, end))
        let rangeEnd = max(start, end)
        guard rangeEnd - rangeStart > 0.2 else { return [] }

        // 窓(hop サンプル)ごとのエネルギーと高域(差分)エネルギーだけを貯める
        final class Accumulator {
            var energy: [Float] = []
            var highEnergy: [Float] = []
            var previous: Float = 0
        }
        let accumulator = Accumulator()
        let frameLength = hop
        let splitter = AudioAnalysisFrameSplitter(frameLength: frameLength)
        try await AudioAnalysisPCMReader.stream(url: url, sampleRate: sampleRate,
                                                start: rangeStart, end: rangeEnd) { chunk in
            splitter.push(chunk) { frame in
                var e: Float = 0
                var h: Float = 0
                var previous = accumulator.previous
                for i in 0..<frameLength {
                    let s = frame[i]
                    e += s * s
                    let d = s - previous
                    h += d * d
                    previous = s
                }
                accumulator.previous = previous
                accumulator.energy.append(e / Float(frameLength))
                accumulator.highEnergy.append(h / Float(frameLength))
            }
        }
        try Task.checkCancellation()
        return beats(energy: accumulator.energy, highEnergy: accumulator.highEnergy,
                     origin: rangeStart, sensitivity: sensitivity)
    }

    /// BGM のビート(出力タイムライン上の秒)。BGM は sourceStart(曲の開始位置)から 0 秒に置かれ、
    /// 曲より長い動画ではくり返す(つなぎ目は CompositionBuilder と同じく最大 1.5 秒重ねる)。
    /// 使う長さ(covering 秒)の分だけを読み、くり返す分は曲のビートをずらして足す
    /// (前は 30 秒の動画でも曲の先頭 3600 秒を全部読み、くり返し後のビートも無かった)
    static func detectBGMBeats(url: URL, covering seconds: Double, sourceStart: Double = 0,
                               sensitivity: Double = 0.5) async throws -> [Double] {
        let need = max(1, min(seconds.isFinite ? seconds : 60, 3600))
        let loaded = try? await AVURLAsset(url: url).load(.duration)
        let raw = loaded.map { CMTimeGetSeconds($0) } ?? 0
        let songLength = (raw.isFinite && raw > 0) ? raw : 0
        guard songLength > 0.5 else {
            return try await detectBeats(url: url, start: 0, end: need, sensitivity: sensitivity)
        }
        let offset = min(max(0, sourceStart), max(0, songLength - 1))
        let loops = offset + need > songLength
        let songBeats = try await detectBeats(url: url,
                                              start: loops ? 0 : offset,
                                              end: loops ? songLength : min(songLength, offset + need + 1),
                                              sensitivity: sensitivity)
        var result = songBeats.filter { $0 >= offset }.map { $0 - offset }
        guard loops else { return result }
        let crossfade = min(1.5, songLength / 4)
        let firstLength = songLength - offset
        var segmentStart = firstLength > crossfade ? firstLength - crossfade : firstLength
        while segmentStart < need {
            result.append(contentsOf: songBeats.map { segmentStart + $0 }.filter { $0 <= need + 0.5 })
            segmentStart += songLength - crossfade
        }
        return result.sorted()
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
        return beats(energy: energy, highEnergy: highEnergy, origin: origin, sensitivity: sensitivity)
    }

    /// 窓(hop サンプル)ごとのエネルギーと高域エネルギーからビートを求める
    static func beats(energy: [Float], highEnergy: [Float], origin: Double, sensitivity: Double) -> [Double] {
        let frames = min(energy.count, highEnergy.count)
        guard frames > 8 else { return [] }

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

// MARK: - BGM の拍の格子

extension VideoEffectType {
    /// BGM の拍に合わせて動くエフェクトか(「ズームパルス」「ビート揺れ」)
    var followsBGMBeat: Bool {
        self == .zoomPulse || self == .beatShake
    }
}

/// BGM の拍の格子(1 拍の秒と、拍の頭になる曲の中の秒)。「ビート揺れ」「ズームパルス」を BGM の拍に合わせるのに使う
/// (前はいつも 120 BPM で、数秒で拍からずれていた)。曲ごとに起動中 1 回だけ解析する。
/// くり返し後のつなぎ目のずれは見ない(多くの動画は曲より短い)
enum BGMBeatGrid {
    struct Grid: Equatable {
        /// 1 拍の秒
        let period: Double
        /// 拍の頭になる曲の中の秒
        let origin: Double
    }

    private static let lock = NSLock()
    private static var grids: [String: Grid] = [:]
    private static var tasks: [String: Task<Grid?, Never>] = [:]
    /// 拍が見つからなかった曲(試し直さない)
    private static var failed: Set<String> = []

    /// url の拍の格子。まだ無ければ、waits のときは解析を待ち、そうでなければ裏で解析して nil を返す
    /// (できたら .compositionMaterialsDidChange でプレビューを作り直してもらう)
    static func grid(for url: URL?, needed: Bool, waits: Bool) async -> Grid? {
        guard needed, let url else { return nil }
        let (cached, task) = lookup(url)
        if let cached { return cached }
        guard let task, waits else { return nil }
        return await task.value
    }

    /// 覚えている格子か、解析中(なければ始めた)の処理
    private static func lookup(_ url: URL) -> (Grid?, Task<Grid?, Never>?) {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let grid = grids[key] { return (grid, nil) }
        if failed.contains(key) { return (nil, nil) }
        if let task = tasks[key] { return (nil, task) }
        let task = Task.detached(priority: .utility) { () -> Grid? in
            let grid = await BGMBeatGrid.analyze(url)
            BGMBeatGrid.store(grid, key: key)
            if grid != nil {
                NotificationCenter.default.post(name: .compositionMaterialsDidChange, object: nil)
            }
            return grid
        }
        tasks[key] = task
        return (nil, task)
    }

    private static func store(_ grid: Grid?, key: String) {
        lock.lock()
        tasks[key] = nil
        if let grid {
            grids[key] = grid
        } else {
            failed.insert(key)
        }
        lock.unlock()
    }

    /// 曲の頭から 90 秒までで拍を探し、テンポと拍の頭(見つけた拍の位相の平均)を求める
    private static func analyze(_ url: URL) async -> Grid? {
        guard let onsets = try? await BeatDetector.detectBeats(url: url, start: 0, end: 90, sensitivity: 0.5),
              let bpm = BeatDetector.estimateBPM(onsets: onsets), bpm.isFinite, bpm > 0 else { return nil }
        let period = 60 / bpm
        var sx = 0.0
        var sy = 0.0
        for t in onsets {
            let x = t / period
            let angle = 2 * Double.pi * (x - floor(x))
            sx += cos(angle)
            sy += sin(angle)
        }
        var phase = atan2(sy, sx) / (2 * Double.pi)
        if phase < 0 { phase += 1 }
        return Grid(period: period, origin: phase * period)
    }

    /// 合成に渡すエフェクトに拍を入れる(タイムライン t は曲の bgmOffset + t の位置)
    static func applying(_ grid: Grid?, bgmOffset: Double, to effect: VideoEffectClip) -> VideoEffectClip {
        guard let grid, effect.type.followsBGMBeat else { return effect }
        var result = effect
        result.beatPeriod = grid.period
        result.beatOrigin = grid.origin - max(0, bgmOffset)
        return result
    }
}
