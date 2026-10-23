import Foundation
import AVFoundation

// =====================================================================
// 声がありそうな区間を見つける(クラウドに送る前に、はっきり無音の区間を除いて利用料を減らすため)。
//
// 8kHz モノラルに読み、50 ミリ秒ごとの音の大きさ(RMS)が「静かな部分 × 2」(下限 0.003・上限 0.008)を
// 超えたところを声の候補にする。前後 0.4 秒を足し、2 秒より短いすき間はつなぐ。
// 小さな声を落とさないよう控えめにし、ほとんど削れないときや読めなかったときは範囲全体を返す。
// =====================================================================

enum SpeechRegionDetector {
    private static let sampleRate: Double = 8_000
    private static let windowSeconds: Double = 0.05
    private static let paddingSeconds: Double = 0.4
    private static let mergeGapSeconds: Double = 2.0

    /// start〜end(元素材上の秒)のうち、送る区間(声がありそうな区間)。削る意味がなければ範囲全体
    static func speechRanges(url: URL, start: Double, end: Double) async -> [(start: Double, end: Double)] {
        let whole = [(start: start, end: end)]
        // 短い範囲は削っても節約にならない
        guard end - start > 8 else { return whole }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return whole }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return whole }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        guard reader.startReading() else { return whole }

        let window = max(1, Int(sampleRate * windowSeconds))
        var energies: [Float] = []
        var sum: Float = 0
        var count = 0
        var firstTime: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return whole
            }
            if firstTime == nil {
                let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                firstTime = t.isFinite ? t : start
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            var samples = [Float](repeating: 0, count: floatCount)
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size,
                                                  destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for value in samples {
                sum += value * value
                count += 1
                if count == window {
                    energies.append((sum / Float(window)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        guard reader.status == .completed, energies.count > 20, let origin = firstTime else { return whole }

        // 静かな部分(下から 10%)の 2 倍を目安に。小さな声を落とさないよう上限を低めにする
        let sorted = energies.sorted()
        let quiet = sorted[sorted.count / 10]
        let threshold = min(max(quiet * 2, 0.003), 0.008)

        // 声の候補の窓 → 区間(前後に余白を足し、短いすき間はつなぐ)
        let pad = Int((paddingSeconds / windowSeconds).rounded())
        let gap = Int((mergeGapSeconds / windowSeconds).rounded())
        var regions: [(Int, Int)] = []
        var index = 0
        while index < energies.count {
            guard energies[index] > threshold else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < energies.count, energies[last + 1] > threshold { last += 1 }
            let lo = max(0, index - pad)
            let hi = min(energies.count - 1, last + pad)
            if let previous = regions.last, lo - previous.1 <= gap {
                regions[regions.count - 1].1 = hi
            } else {
                regions.append((lo, hi))
            }
            index = last + 1
        }
        guard !regions.isEmpty else { return [] }

        let ranges = regions.map { region -> (start: Double, end: Double) in
            let s = max(start, origin + Double(region.0) * windowSeconds)
            let e = min(end, origin + Double(region.1 + 1) * windowSeconds)
            return (start: s, end: e)
        }.filter { $0.end - $0.start > 0.2 }
        // ほとんど削れないなら、分けずにそのまま送る(1 回で送るほうがよい)
        let kept = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        if kept >= (end - start) * 0.9 { return whole }
        return ranges
    }
}
