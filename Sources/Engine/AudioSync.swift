import Foundation
import AVFoundation
import Accelerate

// =====================================================================
// マルチカムの音声による自動同期
// 1) 8 kHz モノラル float PCM を読み込み(先頭 ~5 分)
// 2) 100 Hz の RMS エンベロープを正規化して相互相関 → 粗いずれ(10 ms 単位)
// 3) 8 kHz の生波形で ±0.05 s を精査 → ~1 ms 精度
// 符号: angleTime = mainTime + offset
// =====================================================================

enum AudioSyncError: LocalizedError {
    case noAudioTrack(String)
    case readFailed(String)
    case tooShort
    case weakCorrelation

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let name):
            return "「\(name)」に音声トラックがないため、自動同期できません。"
        case .readFailed(let detail):
            return "音声の読み込みに失敗しました: \(detail)"
        case .tooShort:
            return "音声が短すぎるため、自動同期できません。"
        case .weakCorrelation:
            return "2つの音声の一致箇所が見つかりませんでした。同じ場面を録音した素材か確認し、手動で調整してください。"
        }
    }
}

enum AudioSync {
    /// 読み込みサンプルレート
    private static let sampleRate: Double = 8000
    /// エンベロープ 1 フレームのサンプル数(8000 / 80 = 100 Hz)
    private static let envelopeWindow = 80
    private static let envelopeRate: Double = 100
    /// 読み込む最大長(秒)
    private static let maxReadDuration: Double = 300
    /// 相関計算に必要な最小重なり(秒)
    private static let minOverlapSeconds: Double = 3
    /// 精査の探索範囲(秒)
    private static let refineRange: Double = 0.05
    /// 精査に使う最大長(秒)
    private static let refineWindowSeconds: Double = 60

    /// Offset such that angleTime = mainTime + offset. Throws if either file has no audio.
    static func estimateOffset(mainURL: URL, angleURL: URL, maxOffset: Double = 60) async throws -> Double {
        let mainSamples = try await readMonoPCM(url: mainURL)
        try Task.checkCancellation()
        let angleSamples = try await readMonoPCM(url: angleURL)
        try Task.checkCancellation()

        let limit = max(1, maxOffset)
        return try await Task.detached(priority: .userInitiated) {
            try AudioSync.computeOffset(main: mainSamples, angle: angleSamples, maxOffset: limit)
        }.value
    }

    // MARK: - 読み込み

    private static func readMonoPCM(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioSyncError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioSyncError.readFailed(error.localizedDescription)
        }
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: maxReadDuration, preferredTimescale: 600))

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
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
            throw AudioSyncError.readFailed("音声出力を追加できません")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioSyncError.readFailed(reader.error?.localizedDescription ?? "読み込みを開始できません")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * min(maxReadDuration, 120)))
        let maxSamples = Int(sampleRate * maxReadDuration)

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
            samples.append(contentsOf: chunk)
            if samples.count >= maxSamples {
                reader.cancelReading()
                break
            }
        }

        if reader.status == .failed {
            throw AudioSyncError.readFailed(reader.error?.localizedDescription ?? "不明なエラー")
        }
        if samples.count > maxSamples {
            samples.removeLast(samples.count - maxSamples)
        }
        return samples
    }

    // MARK: - 計算

    private static func computeOffset(main: [Float], angle: [Float], maxOffset: Double) throws -> Double {
        let mainEnv = normalized(envelope(main))
        let angleEnv = normalized(envelope(angle))
        let minOverlap = Int(minOverlapSeconds * envelopeRate)
        guard mainEnv.count >= minOverlap, angleEnv.count >= minOverlap else {
            throw AudioSyncError.tooShort
        }

        // ---- 粗い探索(100 Hz エンベロープ)----
        let maxLagFrames = Int(maxOffset * envelopeRate)
        guard let coarse = bestLag(a: mainEnv, b: angleEnv,
                                   lagRange: -maxLagFrames...maxLagFrames,
                                   minOverlap: minOverlap,
                                   collectStatistics: true) else {
            throw AudioSyncError.weakCorrelation
        }
        // ピークの強さ(正規化相関)と、他のラグに対する突出度(z スコア)で信頼性を判定
        if coarse.score < 0.1 || coarse.zScore < 3 {
            throw AudioSyncError.weakCorrelation
        }

        let coarseOffset = Double(coarse.lag) / envelopeRate

        // ---- 精査(8 kHz 生波形、±0.05 s)----
        let centerLag = coarse.lag * envelopeWindow
        let range = Int(refineRange * sampleRate)
        let mainCentered = removingMean(main)
        let angleCentered = removingMean(angle)

        // 重なり区間の中央から最大 refineWindowSeconds を使う(計算量を抑える)
        let overlapStart = max(0, -centerLag)
        let overlapEnd = min(mainCentered.count, angleCentered.count - centerLag)
        let overlap = overlapEnd - overlapStart
        guard overlap > Int(sampleRate) else { return coarseOffset }
        let windowLength = min(overlap, Int(refineWindowSeconds * sampleRate))
        let windowStart = overlapStart + (overlap - windowLength) / 2
        let mainWindow = Array(mainCentered[windowStart..<(windowStart + windowLength)])

        // angle 側は main の窓に lag を足した位置。範囲外になる部分を避けるため window 単位で直接計算
        guard let fine = refine(mainWindow: mainWindow, mainWindowStart: windowStart,
                                angle: angleCentered, lagRange: (centerLag - range)...(centerLag + range)) else {
            return coarseOffset
        }
        if fine.score < 0.05 {
            // 生波形での一致が弱い(マイク特性差など)場合は粗い結果を使う
            return coarseOffset
        }
        return Double(fine.lag) / sampleRate
    }

    /// RMS エンベロープ(envelopeWindow サンプルごと)
    private static func envelope(_ samples: [Float]) -> [Float] {
        let frames = samples.count / envelopeWindow
        guard frames > 0 else { return [] }
        var result = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<frames {
                var rms: Float = 0
                vDSP_rmsqv(base + i * envelopeWindow, 1, &rms, vDSP_Length(envelopeWindow))
                result[i] = rms
            }
        }
        // 音量差に強くするため対数圧縮
        for i in 0..<frames {
            result[i] = log10f(1 + 1000 * result[i])
        }
        return result
    }

    /// 平均を引いて標準偏差で割る
    private static func normalized(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let centered = removingMean(values)
        var rms: Float = 0
        vDSP_rmsqv(centered, 1, &rms, vDSP_Length(centered.count))
        guard rms > 1e-9 else { return [Float](repeating: 0, count: values.count) }
        var divisor = rms
        var result = [Float](repeating: 0, count: centered.count)
        vDSP_vsdiv(centered, 1, &divisor, &result, 1, vDSP_Length(centered.count))
        return result
    }

    private static func removingMean(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        var negativeMean = -mean
        var result = [Float](repeating: 0, count: values.count)
        vDSP_vsadd(values, 1, &negativeMean, &result, 1, vDSP_Length(values.count))
        return result
    }

    /// 二乗の累積和(区間エネルギーを O(1) で求める)
    private static func prefixEnergy(_ values: [Float]) -> [Double] {
        var result = [Double](repeating: 0, count: values.count + 1)
        var acc = 0.0
        for i in 0..<values.count {
            acc += Double(values[i]) * Double(values[i])
            result[i + 1] = acc
        }
        return result
    }

    private struct LagResult {
        let lag: Int
        let score: Double
        let zScore: Double
    }

    /// score(L) = Σ a[i]·b[i+L] / sqrt(Σa² Σb²)(重なり区間で正規化)
    private static func bestLag(a: [Float], b: [Float], lagRange: ClosedRange<Int>,
                                minOverlap: Int, collectStatistics: Bool) -> LagResult? {
        let energyA = prefixEnergy(a)
        let energyB = prefixEnergy(b)
        var bestLag = 0
        var bestScore = -Double.infinity
        var sum = 0.0
        var sumSquares = 0.0
        var n = 0

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let baseA = pa.baseAddress, let baseB = pb.baseAddress else { return }
                for lag in lagRange {
                    let start = max(0, -lag)
                    let end = min(a.count, b.count - lag)
                    let count = end - start
                    guard count >= minOverlap else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(baseA + start, 1, baseB + start + lag, 1, &dot, vDSP_Length(count))
                    let ea = energyA[end] - energyA[start]
                    let eb = energyB[end + lag] - energyB[start + lag]
                    let denominator = (ea * eb).squareRoot()
                    guard denominator > 1e-9 else { continue }
                    let score = Double(dot) / denominator
                    if collectStatistics {
                        sum += score
                        sumSquares += score * score
                        n += 1
                    }
                    if score > bestScore {
                        bestScore = score
                        bestLag = lag
                    }
                }
            }
        }

        guard bestScore.isFinite else { return nil }
        var z = 0.0
        if collectStatistics && n > 1 {
            let mean = sum / Double(n)
            let variance = max(0, sumSquares / Double(n) - mean * mean)
            let std = variance.squareRoot()
            z = std > 1e-12 ? (bestScore - mean) / std : 0
        }
        return LagResult(lag: bestLag, score: bestScore, zScore: z)
    }

    /// main の窓(main 上の開始位置 mainWindowStart)と angle を lag ごとに比較
    private static func refine(mainWindow: [Float], mainWindowStart: Int, angle: [Float],
                               lagRange: ClosedRange<Int>) -> LagResult? {
        let energyAngle = prefixEnergy(angle)
        var energyMain = 0.0
        for v in mainWindow { energyMain += Double(v) * Double(v) }
        guard energyMain > 1e-12 else { return nil }

        var bestLag = 0
        var bestScore = -Double.infinity

        mainWindow.withUnsafeBufferPointer { pm in
            angle.withUnsafeBufferPointer { pa in
                guard let baseM = pm.baseAddress, let baseA = pa.baseAddress else { return }
                for lag in lagRange {
                    // main[mainWindowStart + k] ↔ angle[mainWindowStart + k + lag]
                    let angleStart = mainWindowStart + lag
                    var kStart = 0
                    var kEnd = mainWindow.count
                    if angleStart < 0 { kStart = -angleStart }
                    if angleStart + kEnd > angle.count { kEnd = angle.count - angleStart }
                    let count = kEnd - kStart
                    guard count > Int(sampleRate) / 2 else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(baseM + kStart, 1, baseA + angleStart + kStart, 1, &dot, vDSP_Length(count))
                    var em: Float = 0
                    vDSP_svesq(baseM + kStart, 1, &em, vDSP_Length(count))
                    let ea = energyAngle[angleStart + kEnd] - energyAngle[angleStart + kStart]
                    let denominator = (Double(em) * ea).squareRoot()
                    guard denominator > 1e-12 else { continue }
                    let score = Double(dot) / denominator
                    if score > bestScore {
                        bestScore = score
                        bestLag = lag
                    }
                }
            }
        }

        guard bestScore.isFinite else { return nil }
        return LagResult(lag: bestLag, score: bestScore, zScore: 0)
    }
}
