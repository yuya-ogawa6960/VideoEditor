import Foundation
import AVFoundation
import Accelerate

// =====================================================================
// マルチカムの音声による自動同期(計算は AudioSyncCore.swift)
// 1) 参照(ふつうはメイン)のクリップ前後と、アングルの全体(4 時間まで)を 8 kHz で読み、100 Hz の特徴量にする
//    (先頭のタイムスタンプで時刻をそろえる。参照の特徴量はキャッシュして、続けて同期するアングルで使い回す)
// 2) ずれの範囲を制限せずに照合し、候補と信頼度を出す
// 3) クリップの範囲で 8 kHz の波形を複数の窓で照合して精度を上げ、時計のずれ(ドリフト)を推定する
// 符号: アングルの時刻 = offset + rate × 参照の時刻
// =====================================================================

enum AudioSyncError: LocalizedError {
    /// 参照(メイン、または経由するアングル)に音声トラックがない
    case referenceHasNoAudio(String)
    /// 合わせるアングルに音声トラックがない
    case angleHasNoAudio(String)
    case readFailed(String)
    case tooShort
    /// 一致が弱い。候補のずれ(参照の時刻での見かけのずれ。強い順)
    case weakCorrelation(candidates: [Double])
    /// 2 つの音声が時間的に重ならない
    case noOverlap

    var errorDescription: String? {
        switch self {
        case .referenceHasNoAudio(let name), .angleHasNoAudio(let name):
            return String(localized: "「\(name)」に音声トラックがないため、自動同期できません。")
        case .readFailed(let detail):
            return String(localized: "音声の読み込みに失敗しました: \(detail)")
        case .tooShort:
            return String(localized: "音声が短すぎるため、自動同期できません。")
        case .weakCorrelation:
            return String(localized: "2つの音声の一致箇所が見つかりませんでした。同じ場面を録音した素材か確認し、手動で調整してください。")
        case .noOverlap:
            return String(localized: "2つの音声に重なる部分がありません。")
        }
    }
}

enum AudioSyncConfidence: String {
    case high
    case medium
}

struct AudioSyncResult {
    /// アングルの時刻 = offset + rate × 参照の時刻
    var offset: Double
    /// 時計のずれの補正(1 = 補正なし)
    var rate: Double
    var confidence: AudioSyncConfidence
    /// 最良の一致の突出度(候補から精査したときは 0)
    var robustZ: Double
    /// 1 位と 2 位の強さの比
    var peakRatio: Double
    /// 波形の照合で採用した窓の数 / 試した窓の数
    var windowsUsed: Int
    var windowsTried: Int
    /// 直線からの残差(ミリ秒。窓が 3 つ以上のとき)
    var residualMs: Double?
    var driftApplied: Bool
    /// ほかの候補(参照の時刻での見かけのずれ。要確認のときだけ)
    var candidates: [Double]
    /// 耳で確かめるのによい位置(参照の元素材上の秒)
    var checkTime: Double?
}

enum AudioSync {
    /// 時計のずれの補正を使うか(問題が出たらここで止める)
    static let appliesClockDrift = true
    /// 読み込む長さの上限(秒)
    private static let maxReadSeconds: Double = 4 * 3600

    /// アングルの時刻 = offset + rate × 参照の時刻 となる対応を求める。
    /// focus は参照の元素材上で使う範囲(クリップのトリミング範囲)。startingOffset を渡すと、粗い照合を飛ばしてその値から精査する。
    /// progress は読み込みスレッドから呼ばれる(0...1)
    static func analyze(referenceURL: URL,
                        angleURL: URL,
                        focus: ClosedRange<Double>,
                        startingOffset: Double? = nil,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> AudioSyncResult {
        let referenceAsset = AVURLAsset(url: referenceURL)
        let angleAsset = AVURLAsset(url: angleURL)
        guard let referenceTrack = try await audioTrack(of: referenceAsset) else {
            throw AudioSyncError.referenceHasNoAudio(referenceURL.lastPathComponent)
        }
        guard let angleTrack = try await audioTrack(of: angleAsset) else {
            throw AudioSyncError.angleHasNoAudio(angleURL.lastPathComponent)
        }
        let referenceSpan = try await trackSpan(referenceTrack, asset: referenceAsset)
        let angleSpan = try await trackSpan(angleTrack, asset: angleAsset)
        try Task.checkCancellation()

        // 参照はクリップの前後 60 秒(最低 120 秒、最大 4 時間)、アングルは全体(最大 4 時間)
        let referenceRange = readRange(span: referenceSpan, focus: focus)
        let angleRange = angleSpan.lowerBound...min(angleSpan.upperBound, angleSpan.lowerBound + maxReadSeconds)

        var d0: Double
        var robustZ = 0.0
        var peakRatio = 10.0
        var topR = 1.0
        var ambiguous = false
        var alternatives: [Double] = []

        if let startingOffset {
            d0 = startingOffset
            progress(0.8)
        } else {
            let referenceFeatures = try await features(asset: referenceAsset, track: referenceTrack, url: referenceURL,
                                                       range: referenceRange) { p in progress(0.35 * p) }
            let angleFeatures = try await features(asset: angleAsset, track: angleTrack, url: angleURL,
                                                   range: angleRange) { p in progress(0.35 + 0.45 * p) }
            try Task.checkCancellation()
            let coarse: AudioSyncCore.CoarseResult
            do {
                coarse = try AudioSyncCore.coarseSearch(mainRaw: referenceFeatures.values,
                                                        angleRaw: angleFeatures.values,
                                                        originDelta: angleFeatures.origin - referenceFeatures.origin)
            } catch let error as AudioSyncCore.CoreError {
                switch error {
                case .tooShort: throw AudioSyncError.tooShort
                case .weak(let candidates): throw AudioSyncError.weakCorrelation(candidates: candidates)
                }
            }
            progress(0.85)
            guard let best = coarse.candidates.first else { throw AudioSyncError.weakCorrelation(candidates: []) }
            d0 = best.offset
            robustZ = coarse.robustZ
            peakRatio = coarse.peakRatio
            topR = best.r

            // 1 位と 2 位が近いときは、上位 3 つを波形で比べて決める
            if coarse.peakRatio < 1.25 && coarse.candidates.count >= 2 {
                var scored: [(offset: Double, score: Double)] = []
                for candidate in coarse.candidates.prefix(3) {
                    try Task.checkCancellation()
                    let score = try await tieBreakScore(offset: candidate.offset,
                                                        referenceAsset: referenceAsset, referenceTrack: referenceTrack,
                                                        referenceSpan: referenceSpan,
                                                        angleAsset: angleAsset, angleTrack: angleTrack, angleSpan: angleSpan,
                                                        focus: focus)
                    scored.append((candidate.offset, score))
                }
                scored.sort { $0.score > $1.score }
                if let first = scored.first {
                    d0 = first.offset
                    let second = scored.count >= 2 ? scored[1].score : 0
                    if first.score <= 0 || first.score < second * 1.2 {
                        ambiguous = true
                        alternatives = scored.dropFirst().map { $0.offset }
                    } else {
                        peakRatio = max(peakRatio, 1.25)
                    }
                }
            }
        }

        // --- 8 kHz の窓で精査する(クリップの範囲を中心に)
        let overlapLow = max(referenceSpan.lowerBound, angleSpan.lowerBound - d0)
        let overlapHigh = min(referenceSpan.upperBound, angleSpan.upperBound - d0)
        guard overlapHigh - overlapLow > 1 else { throw AudioSyncError.noOverlap }
        var rangeLow = max(overlapLow, focus.lowerBound - 30)
        var rangeHigh = min(overlapHigh, focus.upperBound + 30)
        if rangeHigh - rangeLow < 60 {
            // 開いている側だけ 60 秒まで広げる(窓をクリップの近く、d0 が正しい範囲に置く。
            // 重なり全体に広げると、時計のずれがある長い収録ではクリップから遠い位置で測ってしまう)
            rangeHigh = min(overlapHigh, rangeLow + 60)
            rangeLow = max(overlapLow, rangeHigh - 60)
        }
        let rangeLength = rangeHigh - rangeLow
        var windowSeconds = 6.0
        var windowCount = min(max(Int(rangeLength / 30), 3), 12)
        if rangeLength < 18 {
            windowCount = 1
            windowSeconds = min(rangeLength, 20)
        }
        let rangeCenter = (rangeLow + rangeHigh) / 2
        var centers: [Double] = []
        for k in 0..<windowCount {
            centers.append(rangeLow + (Double(k) + 0.5) * rangeLength / Double(windowCount))
        }
        centers.sort { abs($0 - rangeCenter) < abs($1 - rangeCenter) }

        var points: [AudioSyncCore.WeightedPoint] = []
        var pointScores: [Double] = []
        var fit: AudioSyncCore.LineFit? = nil
        var tried = 0
        for (index, center) in centers.enumerated() {
            try Task.checkCancellation()
            let predicted: Double
            let radius: Double
            if points.count >= 3, let fit {
                predicted = fit.value(at: center)
                radius = max(0.012, 4 * fit.residualRMS + 0.004)
            } else {
                predicted = d0
                radius = min(0.25, 0.03 + 3e-4 * abs(center - rangeCenter))
            }
            defer { progress(0.85 + 0.15 * Double(index + 1) / Double(centers.count)) }
            let half = windowSeconds / 2
            // 窓は飛ばさずに両方の素材の範囲へ縮める(短いアングル・アングルの端で決まる重なりでも精査できるように)
            let mainStart = max(center - half, referenceSpan.lowerBound, angleSpan.lowerBound - predicted + radius)
            let mainEnd = min(center + half, referenceSpan.upperBound, angleSpan.upperBound - predicted - radius)
            guard mainEnd - mainStart >= 0.5 else { continue }
            let angleStart = max(angleSpan.lowerBound, mainStart + predicted - radius)
            let angleEnd = min(angleSpan.upperBound, mainEnd + predicted + radius)
            tried += 1
            let main = try await readWindow(asset: referenceAsset, track: referenceTrack, start: mainStart, end: mainEnd)
            guard main.samples.count >= Int(AudioSyncCore.sampleRate * 0.5) else { continue }
            var rms: Float = 0
            vDSP_rmsqv(main.samples, 1, &rms, vDSP_Length(main.samples.count))
            guard rms >= 1e-4 else { continue }   // 無音
            let angle = try await readWindow(asset: angleAsset, track: angleTrack, start: angleStart, end: angleEnd)
            guard let match = AudioSyncCore.matchWindow(main: main.samples, angle: angle.samples),
                  match.r >= 0.12, match.psr >= 1.4 else { continue }
            let measured = angle.origin + match.lagSamples / AudioSyncCore.sampleRate - main.origin
            let time = main.origin + Double(main.samples.count) / 2 / AudioSyncCore.sampleRate
            points.append(AudioSyncCore.WeightedPoint(t: time, d: measured, w: match.r))
            pointScores.append(match.r * match.psr)
            if points.count >= 3 {
                fit = AudioSyncCore.fitLine(points)
            }
        }
        let finalFit = points.count >= 2 ? AudioSyncCore.fitLine(points) : nil

        // --- 時計のずれを補正するか(厳しい条件をすべて満たしたときだけ)
        let focusLength = max(focus.upperBound - focus.lowerBound, 0)
        var offset = d0
        var rate = 1.0
        var driftApplied = false
        if appliesClockDrift, let line = finalFit,
           line.used >= 4, line.span >= 120,
           abs(line.slope) >= 2e-6, abs(line.slope) <= 3e-4,
           abs(line.slope) * focusLength >= 0.008,
           abs(line.slope) >= 4 * line.slopeSE,
           line.residualRMS <= 0.005 {
            rate = 1 + line.slope
            offset = line.intercept - line.slope * line.tMean
            driftApplied = true
        } else {
            var inFocus: [(value: Double, weight: Double)] = []
            var all: [(value: Double, weight: Double)] = []
            for p in points {
                all.append((p.d, p.w))
                if p.t >= focus.lowerBound && p.t <= focus.upperBound {
                    inFocus.append((p.d, p.w))
                }
            }
            // クリップの中の窓 → 直線のクリップ中央での値 → すべての窓 → 粗い結果 の順に使う。
            // 直線は、外れた点を除かずに当てられ、クリップの中央が窓のあいだにあるときだけ使う(延長すると 1 つの外れた窓を大きくしてしまう)
            let focusCenter = (focus.lowerBound + focus.upperBound) / 2
            var tLow = Double.infinity
            var tHigh = -Double.infinity
            for p in points {
                tLow = min(tLow, p.t)
                tHigh = max(tHigh, p.t)
            }
            var lineValue: Double? = nil
            if let line = finalFit, line.used >= 3, line.used == points.count,
               focusCenter >= tLow, focusCenter <= tHigh {
                lineValue = line.value(at: focusCenter)
            }
            offset = AudioSyncCore.weightedMedian(inFocus)
                ?? lineValue
                ?? AudioSyncCore.weightedMedian(all)
                ?? d0
        }

        // --- 信頼度
        let residual = finalFit.map { $0.residualRMS }
        var confidence = AudioSyncConfidence.medium
        if startingOffset != nil {
            if points.count >= 3, let residual, residual <= 0.004 { confidence = .high }
        } else {
            var consistent = true
            if !points.isEmpty {
                var measured: [Double] = []
                for p in points { measured.append(p.d) }
                let allowance = 0.02 + abs(finalFit?.slope ?? 0) * (finalFit?.span ?? 0) / 2
                consistent = abs(AudioSyncCore.median(measured) - d0) <= allowance
            }
            let residualOK = points.count < 3 || (residual ?? 1) <= 0.004
            if !ambiguous && robustZ >= 8 && peakRatio >= 1.25 && topR >= 0.15 && consistent && residualOK {
                confidence = .high
            }
        }

        // 耳で確かめる位置: クリップの範囲でいちばんよく一致した窓
        var checkTime: Double? = nil
        var bestCheck = -1.0
        for (i, p) in points.enumerated() where p.t >= focus.lowerBound && p.t <= focus.upperBound {
            if pointScores[i] > bestCheck {
                bestCheck = pointScores[i]
                checkTime = p.t
            }
        }
        progress(1)
        return AudioSyncResult(offset: offset,
                               rate: rate,
                               confidence: confidence,
                               robustZ: robustZ,
                               peakRatio: peakRatio,
                               windowsUsed: points.count,
                               windowsTried: tried,
                               residualMs: residual.map { $0 * 1000 },
                               driftApplied: driftApplied,
                               candidates: ambiguous ? alternatives : [],
                               checkTime: checkTime ?? (focus.lowerBound + focus.upperBound) / 2)
    }

    // MARK: - 候補の比べ方

    /// 候補のずれで、クリップの中央付近の 3 つの窓を ±30 ms で照合した点数(Σ|r|·PSR)
    private static func tieBreakScore(offset: Double,
                                      referenceAsset: AVURLAsset, referenceTrack: AVAssetTrack,
                                      referenceSpan: ClosedRange<Double>,
                                      angleAsset: AVURLAsset, angleTrack: AVAssetTrack,
                                      angleSpan: ClosedRange<Double>,
                                      focus: ClosedRange<Double>) async throws -> Double {
        let low = max(referenceSpan.lowerBound, angleSpan.lowerBound - offset, focus.lowerBound - 30)
        let high = min(referenceSpan.upperBound, angleSpan.upperBound - offset, focus.upperBound + 30)
        guard high - low > 1 else { return 0 }
        let windowSeconds = min(6, high - low)
        let radius = 0.03
        var total = 0.0
        for k in 0..<3 {
            try Task.checkCancellation()
            let center = low + (Double(k) + 0.5) * (high - low) / 3
            let mainStart = max(low, center - windowSeconds / 2)
            let mainEnd = min(high, mainStart + windowSeconds)
            let angleStart = mainStart + offset - radius
            let angleEnd = mainEnd + offset + radius
            guard mainEnd - mainStart >= 0.5,
                  angleStart >= angleSpan.lowerBound, angleEnd <= angleSpan.upperBound else { continue }
            let main = try await readWindow(asset: referenceAsset, track: referenceTrack, start: mainStart, end: mainEnd)
            let angle = try await readWindow(asset: angleAsset, track: angleTrack, start: angleStart, end: angleEnd)
            if let match = AudioSyncCore.matchWindow(main: main.samples, angle: angle.samples),
               match.r >= 0.12, match.psr >= 1.4 {
                total += match.r * match.psr
            }
        }
        return total
    }

    // MARK: - 範囲

    /// 参照を読む範囲: 使う範囲の前後 60 秒(短ければ 120 秒まで広げる。最大 4 時間で、使う範囲の中央を中心にする)
    private static func readRange(span: ClosedRange<Double>, focus: ClosedRange<Double>) -> ClosedRange<Double> {
        var low = max(span.lowerBound, focus.lowerBound - 60)
        var high = min(span.upperBound, focus.upperBound + 60)
        if high < low { high = low }
        if high - low < 120 {
            let missing = 120 - (high - low)
            low = max(span.lowerBound, low - missing / 2)
            high = min(span.upperBound, high + missing / 2)
            // 片側が端に当たったら、もう片側へ伸ばす
            if high - low < 120 {
                low = max(span.lowerBound, high - 120)
                high = min(span.upperBound, low + 120)
            }
        }
        if high - low > maxReadSeconds {
            let center = (focus.lowerBound + focus.upperBound) / 2
            low = max(span.lowerBound, center - maxReadSeconds / 2)
            high = min(span.upperBound, low + maxReadSeconds)
        }
        return low...max(low, high)
    }

    // MARK: - 読み込み

    /// 有効な最初の音声トラック(なければ先頭。音声がなければ nil)
    private static func audioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack? {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioSyncError.readFailed(error.localizedDescription)
        }
        for track in tracks {
            if (try? await track.load(.isEnabled)) ?? true {
                return track
            }
        }
        return tracks.first
    }

    /// 音声トラックが素材上でカバーする範囲(秒)
    private static func trackSpan(_ track: AVAssetTrack, asset: AVURLAsset) async throws -> ClosedRange<Double> {
        if let range = try? await track.load(.timeRange) {
            let start = range.start.seconds
            let end = range.end.seconds
            if start.isFinite, end.isFinite, end > start {
                return max(0, start)...end
            }
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration.isFinite, duration > 0 else {
            throw AudioSyncError.readFailed(String(localized: "長さを読み取れません"))
        }
        return 0...duration
    }

    private final class FeatureBox {
        let values: [Float]
        /// values[0] の素材上の時刻(秒)
        let origin: Double
        init(values: [Float], origin: Double) {
            self.values = values
            self.origin = origin
        }
    }

    private static let featureCache: NSCache<NSString, FeatureBox> = {
        let cache = NSCache<NSString, FeatureBox>()
        cache.countLimit = 8
        return cache
    }()

    /// 範囲の 100 Hz の特徴量(キャッシュがあれば読み込まない)
    private static func features(asset: AVURLAsset, track: AVAssetTrack, url: URL, range: ClosedRange<Double>,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> FeatureBox {
        let key = "\(url.standardizedFileURL.path)|\(Int((range.lowerBound * 10).rounded()))|\(Int((range.upperBound * 10).rounded()))|v2" as NSString
        if let cached = featureCache.object(forKey: key) {
            progress(1)
            return cached
        }
        final class Accumulator {
            var core = AudioSyncCore.FeatureAccumulator()
        }
        let accumulator = Accumulator()
        let origin = try await streamPCM(asset: asset, track: track, start: range.lowerBound, end: range.upperBound,
                                         progress: progress) { chunk in
            accumulator.core.append(chunk)
        }
        let box = FeatureBox(values: accumulator.core.features, origin: origin)
        featureCache.setObject(box, forKey: key)
        return box
    }

    /// 短い範囲を 8 kHz でそのまま読む
    private static func readWindow(asset: AVURLAsset, track: AVAssetTrack,
                                   start: Double, end: Double) async throws -> (samples: [Float], origin: Double) {
        final class Collector {
            var samples: [Float] = []
        }
        let collector = Collector()
        let origin = try await streamPCM(asset: asset, track: track, start: start, end: end, progress: nil) { chunk in
            collector.samples.append(contentsOf: chunk)
        }
        // 頼んだ範囲より長く届いたら切る(窓の長さをそろえる)
        let expected = Int(((end - start) * AudioSyncCore.sampleRate).rounded()) + 1
        if collector.samples.count > expected {
            collector.samples.removeLast(collector.samples.count - expected)
        }
        return (collector.samples, origin)
    }

    /// 素材の [start, end) を 8 kHz モノラルで読み、チャンクごとに handler に渡す(読み込みスレッドで順に呼ぶ)。
    /// 戻り値は最初のサンプルの素材上の時刻(先頭のタイムスタンプ。音声が映像より遅れて始まる素材でも時刻がずれない)
    private static func streamPCM(asset: AVURLAsset, track: AVAssetTrack, start: Double, end: Double,
                                  progress: (@Sendable (Double) -> Void)?,
                                  handler: @escaping ([Float]) -> Void) async throws -> Double {
        guard end > start + 0.01 else { throw AudioSyncError.tooShort }
        let timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                    end: CMTime(seconds: end, preferredTimescale: 48_000))
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) { () throws -> Double in
            try AudioSync.readBlocking(asset: asset, track: track, timeRange: timeRange,
                                       progress: progress, handler: handler)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func readBlocking(asset: AVURLAsset, track: AVAssetTrack, timeRange: CMTimeRange,
                                     progress: (@Sendable (Double) -> Void)?,
                                     handler: ([Float]) -> Void) throws -> Double {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioSyncError.readFailed(error.localizedDescription)
        }
        reader.timeRange = timeRange
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: AudioSyncCore.sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioSyncError.readFailed(String(localized: "音声出力を追加できません"))
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioSyncError.readFailed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
        }

        let rangeStart = timeRange.start.seconds
        let rangeLength = timeRange.duration.seconds
        var origin: Double? = nil
        var lastReported = -1.0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
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
            if origin == nil {
                origin = pts.isFinite ? pts : rangeStart
            }
            handler(chunk)
            if let progress, rangeLength > 0, pts.isFinite {
                let p = min(max((pts - rangeStart) / rangeLength, 0), 1)
                if p - lastReported >= 0.01 {
                    lastReported = p
                    progress(p)
                }
            }
        }

        if Task.isCancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        if reader.status == .failed {
            throw AudioSyncError.readFailed(reader.error?.localizedDescription ?? String(localized: "不明なエラー"))
        }
        return origin ?? rangeStart
    }
}
