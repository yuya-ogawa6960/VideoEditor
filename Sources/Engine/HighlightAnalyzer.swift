import Foundation
import AVFoundation
import Accelerate
import CoreVideo
import Vision

// =====================================================================
// 自動ハイライト解析(おまかせ編集の材料)。
//
// クリップごとに 1 秒刻みの特徴量を作り、重み付き合計をスコアにする:
//   - 音量   : 16 kHz モノラルの 50 ms 窓 RMS(クリップ内の 95 パーセンタイルで正規化)
//   - 会話   : RMS がノイズ床を超え、ゼロ交差率が声の範囲にある窓の割合 × 音量の揺らぎ。
//              字幕があればその区間は 1 とする
//   - 動き   : 320 px・4 コマ/秒のコマ間の輝度差(クリップ内の 90 パーセンタイルで正規化)
//   - 顔     : 1 コマ/秒の VNDetectFaceRectanglesRequest(人数と大きさ)
// スコアの高い 2〜6 秒の窓を重ならないように選び、会話の途中で切れないよう前後に少し伸ばす。
// 戻り値はクリップ順・開始時刻順。時刻は元素材上の秒。
// progress は 0...1 をバックグラウンドのスレッドから呼ぶことがある。
// =====================================================================

enum HighlightAnalyzer {
    static let analysisFPS: Double = 4
    static let frameDimension = 320
    private static let audioSampleRate: Double = 16_000
    /// 50 ms
    private static let audioWindow = 800

    private struct Weights {
        var loud: Double
        var speech: Double
        var motion: Double
        var face: Double
    }

    private struct ClipFeatures {
        var seconds: Int
        var loud: [Double]
        var speech: [Double]
        var motion: [Double]
        var face: [Double]

        init(seconds: Int) {
            let n = max(1, seconds)
            self.seconds = n
            loud = [Double](repeating: 0, count: n)
            speech = [Double](repeating: 0, count: n)
            motion = [Double](repeating: 0, count: n)
            face = [Double](repeating: 0, count: n)
        }
    }

    // MARK: - 公開 API

    static func analyze(snapshot: ProjectSnapshot, settings: AutoEditSettings,
                        progress: ((Double) -> Void)?) async throws -> [HighlightSegment] {
        let clips = snapshot.clips
        guard !clips.isEmpty else { return [] }

        var timelineStarts: [Double] = []
        var cursor = 0.0
        for clip in clips {
            timelineStarts.append(cursor)
            cursor += clip.outputDuration
        }

        var result: [HighlightSegment] = []
        let total = Double(clips.count)
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let base = Double(index) / total
            let share = 1.0 / total

            if clip.isStill {
                let length = min(clip.trimmedDuration, 5)
                if length > 0.2 {
                    result.append(HighlightSegment(clipID: clip.id, start: clip.startTime,
                                                   end: clip.startTime + length, score: 0.4, reason: "写真"))
                }
                progress?(base + share)
                continue
            }

            let duration = clip.trimmedDuration
            guard duration > 0.3 else { continue }
            let seconds = Int(duration.rounded(.up))
            var features = ClipFeatures(seconds: seconds)

            if clip.hasAudio {
                do {
                    let audio = try await analyzeAudio(clip: clip, seconds: features.seconds) { fraction in
                        progress?(base + share * 0.3 * fraction)
                    }
                    features.loud = audio.loud
                    features.speech = audio.speech
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 音声が読めないときは音の特徴量なしで続ける
                }
            }
            applySubtitles(snapshot.subtitles, clip: clip, timelineStart: timelineStarts[index], into: &features)

            do {
                let video = try await analyzeVideo(clip: clip, seconds: features.seconds) { fraction in
                    progress?(base + share * (0.3 + 0.7 * fraction))
                }
                features.motion = video.motion
                features.face = video.face
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 映像が読めないときは音声だけで評価する
            }
            try Task.checkCancellation()

            result.append(contentsOf: segments(for: clip, features: features, settings: settings))
            progress?(base + share)
        }
        progress?(1)
        return result
    }

    // MARK: - 音声

    private static func analyzeAudio(clip: Clip, seconds: Int,
                                     progress: @escaping (Double) -> Void) async throws -> (loud: [Double], speech: [Double]) {
        final class Collector {
            var rms: [Float] = []
            var zcr: [Float] = []
        }
        let collector = Collector()
        let splitter = AudioAnalysisFrameSplitter(frameLength: audioWindow)
        let windowLength = vDSP_Length(audioWindow)
        let count = audioWindow
        let start = clip.startTime
        let end = clip.endTime
        let span = max(0.01, end - start)
        let windowsPerSecond = audioSampleRate / Double(audioWindow)

        try await AudioAnalysisPCMReader.stream(url: clip.url, sampleRate: audioSampleRate,
                                                start: start, end: end) { chunk in
            splitter.push(chunk) { frame in
                var rms: Float = 0
                vDSP_rmsqv(frame, 1, &rms, windowLength)
                var crossings = 0
                var previous = frame[0]
                for i in 1..<count {
                    let value = frame[i]
                    if (value >= 0) != (previous >= 0) { crossings += 1 }
                    previous = value
                }
                collector.rms.append(rms)
                collector.zcr.append(Float(crossings) / Float(count))
            }
            let done = Double(collector.rms.count) / windowsPerSecond
            progress(min(1, done / span))
        }

        let n = max(1, seconds)
        var loud = [Double](repeating: 0, count: n)
        var speech = [Double](repeating: 0, count: n)
        let rmsValues = collector.rms
        let zcrValues = collector.zcr
        guard rmsValues.count > 1 else { return (loud, speech) }

        let sortedRMS = rmsValues.sorted()
        let lastIndex = sortedRMS.count - 1
        let floorValue = Double(sortedRMS[Int(Double(lastIndex) * 0.2)])
        let p95 = Double(sortedRMS[Int(Double(lastIndex) * 0.95)])
        let speechThreshold = max(floorValue * 2.5, 0.004)

        for s in 0..<n {
            let lo = Int(Double(s) * windowsPerSecond)
            let hi = min(rmsValues.count, Int(Double(s + 1) * windowsPerSecond))
            guard hi > lo else { continue }
            let windows = Double(hi - lo)
            var sum = 0.0
            var speechWindows = 0
            var dbValues: [Double] = []
            dbValues.reserveCapacity(hi - lo)
            for i in lo..<hi {
                let r = Double(rmsValues[i])
                sum += r
                let z = Double(zcrValues[i])
                if r > speechThreshold && z >= 0.02 && z <= 0.35 {
                    speechWindows += 1
                }
                dbValues.append(20 * log10(max(r, 1e-6)))
            }
            let meanRMS = sum / windows
            loud[s] = p95 > 0 ? min(1, meanRMS / p95) : 0

            var dbSum = 0.0
            for v in dbValues { dbSum += v }
            let meanDB = dbSum / windows
            var variance = 0.0
            for v in dbValues {
                let d = v - meanDB
                variance += d * d
            }
            let deviation = sqrt(variance / windows)
            // 音節のリズムで音量が揺れるほど会話らしい
            let modulation: Double = deviation > 3 ? 1.0 : 0.4
            speech[s] = Double(speechWindows) / windows * modulation
        }
        return (loud, speech)
    }

    /// 字幕(出力タイムライン上)がかかっている秒は会話 = 1
    private static func applySubtitles(_ subtitles: [SubtitleCue], clip: Clip, timelineStart: Double,
                                       into features: inout ClipFeatures) {
        guard !subtitles.isEmpty else { return }
        let speed = max(clip.speed, 0.01)
        let timelineEnd = timelineStart + clip.outputDuration
        for cue in subtitles {
            guard cue.end > timelineStart, cue.start < timelineEnd else { continue }
            let sourceStart = clip.startTime + (max(cue.start, timelineStart) - timelineStart) * speed
            let sourceEnd = clip.startTime + (min(cue.end, timelineEnd) - timelineStart) * speed
            let first = max(0, Int((sourceStart - clip.startTime).rounded(.down)))
            let last = min(features.seconds - 1, Int((sourceEnd - clip.startTime).rounded(.up)) - 1)
            guard last >= first else { continue }
            for s in first...last {
                features.speech[s] = 1
            }
        }
    }

    // MARK: - 映像

    private static func analyzeVideo(clip: Clip, seconds: Int,
                                     progress: @escaping (Double) -> Void) async throws -> (motion: [Double], face: [Double]) {
        final class VideoState {
            var previousLuma: [Float] = []
            var motionSum: [Double]
            var motionCount: [Int]
            var faceScore: [Double]
            var frameIndex = 0
            let faceRequest = VNDetectFaceRectanglesRequest()
            init(seconds: Int) {
                motionSum = [Double](repeating: 0, count: seconds)
                motionCount = [Int](repeating: 0, count: seconds)
                faceScore = [Double](repeating: 0, count: seconds)
            }
        }
        let n = max(1, seconds)
        let state = VideoState(seconds: n)
        let start = clip.startTime
        let end = clip.endTime
        let span = max(0.01, end - start)
        let faceEvery = max(1, Int(analysisFPS.rounded()))

        try await AnalysisFrameReader.readFrames(url: clip.url, start: start, end: end, fps: analysisFPS,
                                                 maxDimension: frameDimension) { buffer, time in
            let second = min(n - 1, max(0, Int(time - start)))
            let luma = AnalysisFrameReader.lumaSamples(of: buffer, stride: 4)
            if !state.previousLuma.isEmpty, state.previousLuma.count == luma.count, !luma.isEmpty {
                var difference = [Float](repeating: 0, count: luma.count)
                let length = vDSP_Length(luma.count)
                vDSP_vsub(state.previousLuma, 1, luma, 1, &difference, 1, length)
                var mean: Float = 0
                vDSP_meamgv(difference, 1, &mean, length)
                state.motionSum[second] += Double(mean)
                state.motionCount[second] += 1
            }
            state.previousLuma = luma

            if state.frameIndex % faceEvery == 0 {
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                if (try? handler.perform([state.faceRequest])) != nil {
                    let faces = state.faceRequest.results ?? []
                    if !faces.isEmpty {
                        var largest = 0.0
                        for face in faces {
                            largest = max(largest, Double(face.boundingBox.height))
                        }
                        let countScore = min(1.0, Double(faces.count) * 0.6)
                        let sizeScore = min(1.0, max(0.3, largest / 0.12))
                        let score = countScore * sizeScore
                        state.faceScore[second] = max(state.faceScore[second], score)
                    }
                }
            }
            state.frameIndex += 1
            progress(min(1, max(0, (time - start) / span)))
            return true
        }

        var motion = [Double](repeating: 0, count: n)
        var observed: [Double] = []
        for s in 0..<n {
            let c = state.motionCount[s]
            if c > 0 {
                motion[s] = state.motionSum[s] / Double(c)
                observed.append(motion[s])
            }
        }
        if !observed.isEmpty {
            let sorted = observed.sorted()
            let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
            let divisor = max(p90, 0.5)
            for s in 0..<n {
                motion[s] = min(1, motion[s] / divisor)
            }
        }
        return (motion, state.faceScore)
    }

    // MARK: - 区間の選択

    private static func weights(for settings: AutoEditSettings) -> Weights {
        var w: Weights
        switch settings.style {
        case .documentary: w = Weights(loud: 0.15, speech: 0.45, motion: 0.15, face: 0.25)
        case .vlog: w = Weights(loud: 0.2, speech: 0.25, motion: 0.3, face: 0.25)
        case .short: w = Weights(loud: 0.3, speech: 0.15, motion: 0.4, face: 0.15)
        case .family: w = Weights(loud: 0.15, speech: 0.3, motion: 0.2, face: 0.35)
        case .howto: w = Weights(loud: 0.15, speech: 0.5, motion: 0.15, face: 0.2)
        }
        if !settings.preferFaces { w.face *= 0.3 }
        if !settings.preferSpeech { w.speech *= 0.3 }
        let sum = w.loud + w.speech + w.motion + w.face
        if sum > 0 {
            w.loud /= sum
            w.speech /= sum
            w.motion /= sum
            w.face /= sum
        }
        return w
    }

    /// スタイルごとの区間の目安の長さ(秒)
    static func targetSegmentLength(for style: AutoEditStyle) -> Double {
        switch style {
        case .documentary: return 5
        case .vlog: return 3.5
        case .short: return 2.5
        case .family: return 4
        case .howto: return 5
        }
    }

    private static func segments(for clip: Clip, features: ClipFeatures, settings: AutoEditSettings) -> [HighlightSegment] {
        let n = features.seconds
        guard n > 0 else { return [] }
        let w = weights(for: settings)
        var score = [Double](repeating: 0, count: n)
        var dominant = [Int](repeating: 0, count: n)   // 0 音量 / 1 会話 / 2 動き / 3 顔
        for s in 0..<n {
            let parts: [Double] = [w.loud * features.loud[s], w.speech * features.speech[s],
                                   w.motion * features.motion[s], w.face * features.face[s]]
            var total = 0.0
            var bestIndex = 0
            var bestValue = -1.0
            for (i, p) in parts.enumerated() {
                total += p
                if p > bestValue {
                    bestValue = p
                    bestIndex = i
                }
            }
            score[s] = total
            dominant[s] = bestIndex
        }

        let duration = clip.trimmedDuration
        let target = targetSegmentLength(for: settings.style)
        let windowSeconds = max(2, min(6, Int(target.rounded())))

        if duration <= Double(windowSeconds) + 0.5 {
            var sum = 0.0
            for v in score { sum += v }
            let mean = sum / Double(n)
            return [HighlightSegment(clipID: clip.id, start: clip.startTime, end: clip.endTime,
                                     score: clamp01(mean), reason: reasonText(dominant: majority(dominant)))]
        }

        let windows = n - windowSeconds + 1
        guard windows > 0 else { return [] }
        var windowScores = [Double](repeating: 0, count: windows)
        for i in 0..<windows {
            var sum = 0.0
            for j in i..<(i + windowSeconds) { sum += score[j] }
            windowScores[i] = sum / Double(windowSeconds)
        }
        var bestOverall = 0.0
        for v in windowScores where v > bestOverall { bestOverall = v }

        var used = [Bool](repeating: false, count: n)
        var picked: [(start: Int, end: Int, score: Double)] = []
        let maxCount = min(12, max(2, Int(duration / (Double(windowSeconds) * 2.0))))

        while picked.count < maxCount {
            var bestIndex = -1
            var bestValue = -1.0
            for i in 0..<windows {
                var free = true
                for j in i..<(i + windowSeconds) where used[j] {
                    free = false
                    break
                }
                if free && windowScores[i] > bestValue {
                    bestValue = windowScores[i]
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }
            if !picked.isEmpty && bestValue < bestOverall * 0.35 { break }

            var s = bestIndex
            var e = bestIndex + windowSeconds   // [s, e)
            // 会話の途中で切らない: 終わりを最大 2 秒延ばし、始まりを最大 1 秒戻す(全体 6 秒まで)
            var extended = 0
            while e < n, !used[e], features.speech[e] > 0.5, extended < 2, e - s < 6 {
                e += 1
                extended += 1
            }
            var back = 0
            while s > 0, !used[s - 1], features.speech[s - 1] > 0.5, back < 1, e - s < 6 {
                s -= 1
                back += 1
            }
            for j in s..<e { used[j] = true }
            var sum = 0.0
            for j in s..<e { sum += score[j] }
            picked.append((start: s, end: e, score: sum / Double(e - s)))
        }

        var result: [HighlightSegment] = []
        for p in picked {
            let startTime = clip.startTime + Double(p.start)
            let endTime = min(clip.endTime, clip.startTime + Double(p.end))
            guard endTime - startTime >= 1 else { continue }
            let dom = majority(Array(dominant[p.start..<p.end]))
            result.append(HighlightSegment(clipID: clip.id, start: startTime, end: endTime,
                                           score: clamp01(p.score), reason: reasonText(dominant: dom)))
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func majority(_ values: [Int]) -> Int {
        var counts = [Int](repeating: 0, count: 4)
        for v in values where v >= 0 && v < 4 { counts[v] += 1 }
        var best = 0
        for i in 1..<4 where counts[i] > counts[best] { best = i }
        return best
    }

    private static func reasonText(dominant: Int) -> String {
        switch dominant {
        case 1: return "話している場面"
        case 2: return "動きのある場面"
        case 3: return "顔が映っている場面"
        default: return "音が盛り上がる場面"
        }
    }
}
