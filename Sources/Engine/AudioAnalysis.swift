import Foundation
import AVFoundation
import Accelerate

// =====================================================================
// 音声解析(波形ピーク・無音検出)
// - AVAssetReader でモノラル float PCM をストリーミング読み込み(全体をメモリに
//   載せないので長尺でも安全)
// - 波形は URL + 解像度ごとに NSCache へキャッシュ
// - 読み込みは Task.detached 上で行い、呼び出し側 Task のキャンセルで停止する
// =====================================================================

// MARK: - エラー

enum AudioAnalysisError: LocalizedError {
    case noAudioTrack(String)
    case readFailed(String)
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let name):
            return String(localized: "「\(name)」に音声トラックがありません。")
        case .readFailed(let detail):
            return String(localized: "音声の読み込みに失敗しました: \(detail)")
        case .invalidRange:
            return String(localized: "解析する範囲が短すぎます。")
        }
    }
}

// MARK: - 波形

struct AudioWaveform {
    /// 1 秒あたりのバケット数
    let samplesPerSecond: Double
    /// バケットごとのピーク(0...1 に正規化。ファイル全体の最大値を 1 とする)
    let peaks: [Float]
    /// 素材全体の長さ(秒)
    let duration: Double

    /// 元素材上の時刻に対応するピーク(範囲外は 0)
    func peak(at seconds: Double) -> Float {
        guard !peaks.isEmpty, seconds.isFinite else { return 0 }
        let index = Int(seconds * samplesPerSecond)
        guard index >= 0, index < peaks.count else { return 0 }
        return peaks[index]
    }

    /// 元素材上の範囲 [start, end) を `count` 本にリサンプリングしたピーク列(表示用)
    func peaks(from start: Double, to end: Double, count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty, end > start else { return [] }
        var result = [Float](repeating: 0, count: count)
        let span = (end - start) / Double(count)
        for i in 0..<count {
            let s = start + Double(i) * span
            let e = s + span
            var lo = Int(s * samplesPerSecond)
            var hi = Int(e * samplesPerSecond)
            lo = max(0, min(lo, peaks.count - 1))
            hi = max(lo, min(hi, peaks.count - 1))
            var m: Float = 0
            for j in lo...hi where peaks[j] > m { m = peaks[j] }
            result[i] = m
        }
        return result
    }
}

// MARK: - 共通 PCM リーダー

/// モノラル float32 PCM をチャンクごとにコールバックするリーダー(LoudnessAnalyzer と共用)
enum AudioAnalysisPCMReader {
    /// 元素材の [start, end) をモノラル `sampleRate` Hz の float PCM として順にコールバックする。
    /// `handler` は読み込みスレッド上で順番に呼ばれる。戻り値は素材全体の長さ(秒)。
    /// start / end が nil なら先頭 / 末尾まで。呼び出し側 Task のキャンセルで読み込みを中断する。
    @discardableResult
    static func stream(url: URL, sampleRate: Double, start: Double? = nil, end: Double? = nil,
                       handler: @escaping ([Float]) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioAnalysisError.noAudioTrack(url.lastPathComponent)
        }
        let durationTime = try await asset.load(.duration)
        let rawDuration = CMTimeGetSeconds(durationTime)
        let assetDuration: Double = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 0

        let rangeStart = max(0, start ?? 0)
        var rangeEnd: Double? = end
        if rangeEnd == nil, assetDuration > 0 { rangeEnd = assetDuration }
        if let e = rangeEnd, assetDuration > 0 { rangeEnd = min(e, assetDuration) }

        let timeRange: CMTimeRange
        let startTime = CMTime(seconds: rangeStart, preferredTimescale: 48_000)
        if let e = rangeEnd {
            guard e > rangeStart + 0.01 else { throw AudioAnalysisError.invalidRange }
            timeRange = CMTimeRange(start: startTime, end: CMTime(seconds: e, preferredTimescale: 48_000))
        } else {
            timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
        }

        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try AudioAnalysisPCMReader.readBlocking(asset: asset, track: track, sampleRate: sampleRate,
                                                    timeRange: timeRange, handler: handler)
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        return assetDuration
    }

    /// 全サンプルを配列で返す簡易版(短い範囲向け)
    static func readMono(url: URL, sampleRate: Double, start: Double? = nil, end: Double? = nil) async throws -> [Float] {
        final class Box { var samples: [Float] = [] }
        let box = Box()
        try await stream(url: url, sampleRate: sampleRate, start: start, end: end) { chunk in
            box.samples.append(contentsOf: chunk)
        }
        return box.samples
    }

    private static func readBlocking(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double,
                                     timeRange: CMTimeRange, handler: ([Float]) -> Void) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioAnalysisError.readFailed(error.localizedDescription)
        }
        reader.timeRange = timeRange

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioAnalysisError.readFailed(String(localized: "音声出力を追加できません"))
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioAnalysisError.readFailed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                                  dataLength: count * MemoryLayout<Float>.size,
                                                  destination: base)
            }
            guard status == noErr else { continue }
            handler(chunk)
        }

        if Task.isCancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        if reader.status == .failed {
            throw AudioAnalysisError.readFailed(reader.error?.localizedDescription ?? String(localized: "不明なエラー"))
        }
    }
}

/// ストリーミングされたチャンクを固定長フレームに切り分ける(境界をまたぐ分は持ち越す)
final class AudioAnalysisFrameSplitter {
    let frameLength: Int
    private var carry: [Float] = []

    init(frameLength: Int) {
        self.frameLength = max(1, frameLength)
    }

    /// `body` はフレーム先頭ポインタ(frameLength 個有効)ごとに呼ばれる
    func push(_ chunk: [Float], _ body: (UnsafePointer<Float>) -> Void) {
        var data: [Float]
        if carry.isEmpty {
            data = chunk
        } else {
            data = carry
            data.append(contentsOf: chunk)
            carry = []
        }
        let frames = data.count / frameLength
        if frames > 0 {
            data.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for i in 0..<frames {
                    body(base + i * frameLength)
                }
            }
        }
        let used = frames * frameLength
        if used < data.count {
            carry = Array(data[used...])
        }
    }

    /// まだフレームになっていない末尾のサンプル(frameLength 未満)
    var remainder: [Float] { carry }
}

// MARK: - 解析

enum AudioAnalysis {

    // MARK: 波形

    private final class WaveformBox {
        let waveform: AudioWaveform
        init(_ waveform: AudioWaveform) { self.waveform = waveform }
    }

    private static let waveformCache: NSCache<NSString, WaveformBox> = {
        let cache = NSCache<NSString, WaveformBox>()
        cache.countLimit = 64
        return cache
    }()

    private static func cacheKey(url: URL, samplesPerSecond: Double) -> NSString {
        "\(url.path)|\(samplesPerSecond)" as NSString
    }

    /// キャッシュ済みの波形があれば同期的に返す(UI の初回描画用)
    static func cachedWaveform(for url: URL, samplesPerSecond: Double = 50) -> AudioWaveform? {
        waveformCache.object(forKey: cacheKey(url: url, samplesPerSecond: samplesPerSecond))?.waveform
    }

    /// 素材全体のピーク波形(1 秒あたり `samplesPerSecond` バケット)。URL ごとにキャッシュ。
    /// モノラルミックスダウン。呼び出し側 Task のキャンセルで中断する。
    static func waveform(for url: URL, samplesPerSecond: Double = 50) async throws -> AudioWaveform {
        let rate = max(1, samplesPerSecond)
        let key = cacheKey(url: url, samplesPerSecond: rate)
        if let cached = waveformCache.object(forKey: key) {
            return cached.waveform
        }

        // 1 バケットあたりのサンプル数(読み込みレートは 48 kHz を上限に調整)
        var bucketSamples = 160
        if rate * Double(bucketSamples) > 48_000 {
            bucketSamples = max(8, Int(48_000 / rate))
        }
        let readRate = rate * Double(bucketSamples)

        final class Collector {
            var peaks: [Float] = []
        }
        let collector = Collector()
        let splitter = AudioAnalysisFrameSplitter(frameLength: bucketSamples)
        let frameLength = vDSP_Length(bucketSamples)

        let duration = try await AudioAnalysisPCMReader.stream(url: url, sampleRate: readRate) { chunk in
            splitter.push(chunk) { frame in
                var peak: Float = 0
                vDSP_maxmgv(frame, 1, &peak, frameLength)
                collector.peaks.append(peak)
            }
        }
        let rest = splitter.remainder
        if !rest.isEmpty {
            var peak: Float = 0
            vDSP_maxmgv(rest, 1, &peak, vDSP_Length(rest.count))
            collector.peaks.append(peak)
        }

        var peaks = collector.peaks
        if !peaks.isEmpty {
            var maxValue: Float = 0
            vDSP_maxv(peaks, 1, &maxValue, vDSP_Length(peaks.count))
            if maxValue > 1e-6 {
                var divisor = maxValue
                var normalized = [Float](repeating: 0, count: peaks.count)
                vDSP_vsdiv(peaks, 1, &divisor, &normalized, 1, vDSP_Length(peaks.count))
                peaks = normalized
            }
        }

        let totalDuration = duration > 0 ? duration : Double(peaks.count) / rate
        let waveform = AudioWaveform(samplesPerSecond: rate, peaks: peaks, duration: totalDuration)
        waveformCache.setObject(WaveformBox(waveform), forKey: key)
        return waveform
    }

    // MARK: 無音検出

    /// 無音区間(元素材上の秒)
    struct SilenceRange: Equatable {
        let start: Double
        let end: Double
        var duration: Double { max(0, end - start) }
    }

    /// 無音判定の RMS 窓(秒)
    private static let silenceWindow: Double = 0.02
    /// 無音検出の読み込みレート
    private static let silenceSampleRate: Double = 16_000
    /// この長さ未満の「音あり」の切れ目(クリックノイズなど)は無音どうしをつなげる(秒)
    private static let silenceBridgeGap: Double = 0.05

    /// 元素材 [start, end] の無音区間を返す。
    /// 20 ms 窓の RMS が `thresholdDB`(dBFS)未満の区間を無音とし、`minimumDuration` 以上のものだけを採用、
    /// 前後 `padding` 秒は音声側に残す(無音区間を内側に縮める)。結果は時刻順・重なりなし。
    static func detectSilence(in url: URL, start: Double, end: Double,
                              thresholdDB: Float = -40, minimumDuration: Double = 0.6,
                              padding: Double = 0.15) async throws -> [SilenceRange] {
        guard end > start + 0.05 else { return [] }

        let windowSamples = Int(silenceSampleRate * silenceWindow)
        final class Collector {
            var levels: [Float] = []   // 窓ごとの dBFS
        }
        let collector = Collector()
        let splitter = AudioAnalysisFrameSplitter(frameLength: windowSamples)
        let frameLength = vDSP_Length(windowSamples)

        try await AudioAnalysisPCMReader.stream(url: url, sampleRate: silenceSampleRate,
                                                start: start, end: end) { chunk in
            splitter.push(chunk) { frame in
                var rms: Float = 0
                vDSP_rmsqv(frame, 1, &rms, frameLength)
                collector.levels.append(20 * log10f(max(rms, 1e-9)))
            }
        }
        let rest = splitter.remainder
        if rest.count >= windowSamples / 2 {
            var rms: Float = 0
            vDSP_rmsqv(rest, 1, &rms, vDSP_Length(rest.count))
            collector.levels.append(20 * log10f(max(rms, 1e-9)))
        }

        try Task.checkCancellation()
        return silenceRanges(levels: collector.levels, window: silenceWindow, origin: start, limit: end,
                             thresholdDB: thresholdDB, minimumDuration: minimumDuration, padding: padding)
    }

    /// 窓ごとの dB 列から無音区間を組み立てる(純粋関数。テストしやすいよう分離)
    static func silenceRanges(levels: [Float], window: Double, origin: Double, limit: Double,
                              thresholdDB: Float, minimumDuration: Double, padding: Double) -> [SilenceRange] {
        guard !levels.isEmpty else { return [] }

        // 1) 連続する無音窓を区間にまとめる(窓番号 [from, to])
        var runs: [(from: Int, to: Int)] = []
        var runStart: Int? = nil
        for (i, level) in levels.enumerated() {
            if level < thresholdDB {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                runs.append((s, i - 1))
                runStart = nil
            }
        }
        if let s = runStart { runs.append((s, levels.count - 1)) }
        guard !runs.isEmpty else { return [] }

        // 2) ごく短い音ありの切れ目は橋渡しして結合
        let bridgeWindows = Int((silenceBridgeGap / window).rounded())
        var merged: [(from: Int, to: Int)] = []
        for run in runs {
            if let last = merged.last, run.from - last.to - 1 <= bridgeWindows {
                merged[merged.count - 1] = (last.from, run.to)
            } else {
                merged.append(run)
            }
        }

        // 3) 最小長で絞り、パディング分だけ内側に縮める
        let pad = max(0, padding)
        var result: [SilenceRange] = []
        for run in merged {
            let rawStart = origin + Double(run.from) * window
            let rawEnd = origin + Double(run.to + 1) * window
            guard rawEnd - rawStart >= minimumDuration else { continue }
            // 範囲の端に接する無音は、その端側のパディングを不要とする(先頭・末尾の無音を丸ごと削れる)
            let touchesStart = run.from == 0
            let touchesEnd = run.to == levels.count - 1
            var s = touchesStart ? rawStart : rawStart + pad
            var e = touchesEnd ? rawEnd : rawEnd - pad
            s = max(origin, s)
            e = min(limit, e)
            guard e - s >= 0.05 else { continue }
            if let last = result.last, s < last.end {
                // 念のため重なりを解消
                result[result.count - 1] = SilenceRange(start: last.start, end: max(last.end, e))
            } else {
                result.append(SilenceRange(start: s, end: e))
            }
        }
        return result
    }

    // MARK: 無音カット後に残す範囲

    /// クリップのトリミング範囲から無音を取り除いた「残す」元素材範囲(時刻順、各 0.3 秒以上)。
    /// 音声のないクリップや無音が見つからない場合はトリミング範囲そのものを 1 件返す。
    static func keptRanges(for clip: Clip, thresholdDB: Float = -40, minimumDuration: Double = 0.6,
                           padding: Double = 0.15) async throws -> [(start: Double, end: Double)] {
        let rangeStart = clip.startTime
        let rangeEnd = clip.endTime
        guard rangeEnd > rangeStart else { return [] }
        guard clip.hasAudio else { return [(start: rangeStart, end: rangeEnd)] }

        let silences = try await detectSilence(in: clip.url, start: rangeStart, end: rangeEnd,
                                               thresholdDB: thresholdDB, minimumDuration: minimumDuration,
                                               padding: padding)
        return keptRanges(from: rangeStart, to: rangeEnd, removing: silences)
    }

    /// [from, to] から無音区間を除いた残り(純粋関数)。
    /// 無音と無音に挟まれた 0.3 秒未満の断片(ノイズなど)は無音とみなして捨てる。
    static func keptRanges(from rangeStart: Double, to rangeEnd: Double,
                           removing silences: [SilenceRange]) -> [(start: Double, end: Double)] {
        let minimumKeep = 0.3
        guard !silences.isEmpty else {
            return rangeEnd - rangeStart > 0 ? [(start: rangeStart, end: rangeEnd)] : []
        }
        var kept: [(start: Double, end: Double)] = []
        var cursor = rangeStart
        for silence in silences.sorted(by: { $0.start < $1.start }) {
            let s = max(rangeStart, silence.start)
            let e = min(rangeEnd, silence.end)
            guard e > s else { continue }
            if s - cursor >= minimumKeep {
                kept.append((start: cursor, end: s))
            }
            cursor = max(cursor, e)
        }
        if rangeEnd - cursor >= minimumKeep {
            kept.append((start: cursor, end: rangeEnd))
        }
        if kept.isEmpty, rangeEnd - rangeStart > 0 {
            // 全体が無音でも空にはしない(呼び出し側で削除判断ができるよう元の範囲を返す)
            return [(start: rangeStart, end: rangeEnd)]
        }
        return kept
    }
}
