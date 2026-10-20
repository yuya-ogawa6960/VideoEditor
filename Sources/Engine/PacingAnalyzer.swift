import Foundation
import AVFoundation
import CoreImage
import Vision
import SoundAnalysis

// =====================================================================
// 中だるみチェック(端末内の AI だけで判定。ネットには送らない)。
//
// 出力タイムラインの 1 秒ごとに「見ている人が飽きそうな度合い」を 0...1 で出し、
// 緑(テンポよい)/ 黄(少しゆるい)/ 赤(中だるみ)の区間にまとめる。
//
// 飽きやすさを上げるもの:
//   - 同じカットが長く続く(カットが変わってからの秒数)
//   - 画面の動きが少ない(2 コマ/秒の縮小画像の差)
//   - 話し声も音楽も笑い声もなく、音が小さい
//   - 画面が変わらないまま長く話し続けている
// 下げるもの(「間」として見ていられるもの):
//   - 景色・画のきれいさ(Vision の美しさスコア VNCalculateImageAestheticsScoresRequest)
//   - 人の顔・笑顔(CIDetector の笑顔判定)
//   - 笑い声・拍手・歓声、音楽、自然の音(波・風・鳥・雨など)= 雰囲気(SoundAnalysis)
//   - 話し声、テキスト・ステッカー・オーバーレイが出ている
// 何が映っているか(夕焼け・海など)は VNClassifyImageRequest で読み、理由の文に使う。
// =====================================================================

enum PacingLevel: Int, Comparable {
    case good = 0
    case loose = 1
    case dull = 2

    static func < (lhs: PacingLevel, rhs: PacingLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .good: return "テンポよい"
        case .loose: return "少しゆるい"
        case .dull: return "中だるみ"
        }
    }
}

struct PacingSegment: Identifiable, Equatable {
    let id = UUID()
    /// 出力タイムライン上の秒
    let start: Double
    let end: Double
    let level: PacingLevel
    /// 判断の理由(よい点・気になる点)
    let reasons: [String]
    /// 直し方の提案
    let suggestions: [String]
}

/// 1 秒ごとの特徴(0...1)
private struct PacingSecond {
    var shotAge: Double = 0
    var motion: Double = 0
    var loud: Double = 0
    var speech: Double = 0
    var laughter: Double = 0
    var music: Double = 0
    var nature: Double = 0
    var faces: Double = 0
    var smile: Double = 0
    /// -1...1(高いほどきれい)。未計測は nil
    var aesthetic: Double? = nil
    var scene: String? = nil
    var decorated: Bool = false
    var hasVideo: Bool = false
}

enum PacingAnalyzer {

    static func analyze(snapshot: ProjectSnapshot, progress: ((Double) -> Void)?) async throws -> [PacingSegment] {
        let placements = CompositionBuilder.timelineLayout(for: snapshot)
        let total = placements.last?.end ?? 0
        guard total > 1 else { return [] }
        let seconds = Int(total.rounded(.up))
        var timeline = [PacingSecond](repeating: PacingSecond(), count: seconds)

        let clipCount = Double(max(1, snapshot.clips.count))
        for (index, clip) in snapshot.clips.enumerated() {
            try Task.checkCancellation()
            guard index < placements.count else { break }
            let placement = placements[index]
            let base = Double(index) / clipCount
            let share = 1 / clipCount
            let speed = max(clip.speed, 0.01)

            // カットが変わってからの秒数
            let first = max(0, Int(placement.start.rounded(.down)))
            let last = min(seconds - 1, Int(placement.end.rounded(.up)) - 1)
            if last >= first {
                for s in first...last {
                    timeline[s].shotAge = Double(s) - placement.start
                    timeline[s].hasVideo = !clip.isStill
                }
            }

            // 映像(静止画は動きなし・美しさだけ)
            let video = try await analyzeVideo(clip: clip) { progress?(base + share * 0.6 * $0) }
            for (sourceSecond, value) in video.enumerated() {
                let out = placement.start + Double(sourceSecond) / speed
                let s = Int(out)
                guard s >= 0, s < seconds, out < placement.end else { continue }
                timeline[s].motion = max(timeline[s].motion, value.motion)
                timeline[s].faces = max(timeline[s].faces, value.faces)
                timeline[s].smile = max(timeline[s].smile, value.smile)
                if let a = value.aesthetic { timeline[s].aesthetic = a }
                if let scene = value.scene { timeline[s].scene = scene }
            }
            // 1 秒より遅い速度のとき、間を埋める
            fillGaps(&timeline, from: first, to: last)

            // 音(動画の音声 + 雰囲気の聞き分け)
            if clip.hasAudio, !clip.isMuted, !clip.isStill {
                if let audio = try? await analyzeAudio(clip: clip) {
                    for (sourceSecond, value) in audio.enumerated() {
                        let out = placement.start + Double(sourceSecond) / speed
                        let s = Int(out)
                        guard s >= 0, s < seconds, out < placement.end else { continue }
                        timeline[s].loud = max(timeline[s].loud, value.loud)
                        timeline[s].speech = max(timeline[s].speech, value.speech)
                        timeline[s].laughter = max(timeline[s].laughter, value.laughter)
                        timeline[s].music = max(timeline[s].music, value.music)
                        timeline[s].nature = max(timeline[s].nature, value.nature)
                    }
                }
            }
            progress?(base + share)
        }

        // BGM・ナレーション・字幕・テキスト・オーバーレイ
        if snapshot.audio.bgmURL != nil {
            for s in 0..<seconds { timeline[s].music = max(timeline[s].music, 0.6) }
        }
        for item in snapshot.narration {
            mark(&timeline, start: item.start, end: item.start + item.duration) { $0.speech = max($0.speech, 0.8) }
        }
        for cue in snapshot.subtitles {
            mark(&timeline, start: cue.start, end: cue.end) { $0.speech = max($0.speech, 0.7) }
        }
        for text in snapshot.textClips where !text.isMosaic {
            mark(&timeline, start: text.start, end: text.end) { $0.decorated = true }
        }
        for overlay in snapshot.overlays {
            mark(&timeline, start: overlay.start, end: overlay.end) { $0.decorated = true }
            // オーバーレイが出ると画が変わるので、カットの経過もそこで戻す
            let s0 = max(0, Int(overlay.start))
            let s1 = min(seconds - 1, Int(overlay.end))
            if s1 >= s0 {
                for s in s0...s1 { timeline[s].shotAge = min(timeline[s].shotAge, Double(s) - overlay.start) }
            }
        }

        progress?(1)
        return segments(from: timeline)
    }

    // MARK: - 採点

    private static func dullness(_ f: PacingSecond) -> Double {
        var score = 0.25
        // 同じカットが長い(5 秒を超えたら上がり始め、15 秒でいっぱい)
        score += min(1, max(0, (f.shotAge - 5) / 10)) * 0.35
        // 動きが少ない
        if f.hasVideo { score += (1 - min(1, f.motion)) * 0.2 }
        // 何も聞こえない
        let sound = max(f.speech, f.music, f.laughter, f.nature)
        if sound < 0.3 && f.loud < 0.15 { score += 0.2 }
        // 画面が変わらないまま話し続けている
        if f.speech > 0.5 && f.shotAge > 12 && f.motion < 0.3 { score += 0.1 }

        // 見ていられるもの
        if let a = f.aesthetic, a > 0 { score -= min(1, a / 0.6) * 0.25 }
        score -= f.smile * 0.25
        score -= min(1, f.faces) * 0.08
        score -= f.laughter * 0.3
        if f.speech > 0.4 { score -= 0.12 }
        // 雰囲気: 音楽や自然の音があり、画がきれいなら「間」として成り立つ
        let mood = max(f.music, f.nature)
        if mood > 0.4 {
            let pretty = max(0, f.aesthetic ?? 0)
            score -= 0.08 + 0.15 * min(1, pretty / 0.5)
        }
        if f.decorated { score -= 0.15 }
        return min(max(score, 0), 1)
    }

    private static func segments(from timeline: [PacingSecond]) -> [PacingSegment] {
        let raw = timeline.map { dullness($0) }
        // 前後 1 秒の平均でならす
        var smooth = raw
        for i in raw.indices {
            let lo = max(0, i - 1)
            let hi = min(raw.count - 1, i + 1)
            smooth[i] = raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let levels: [PacingLevel] = smooth.map { $0 >= 0.6 ? .dull : ($0 >= 0.38 ? .loose : .good) }

        // 同じ色をまとめる(2 秒未満の島は前の色に吸収)
        var runs: [(level: PacingLevel, start: Int, end: Int)] = []
        for (i, level) in levels.enumerated() {
            if let lastRun = runs.last, lastRun.level == level {
                runs[runs.count - 1].end = i + 1
            } else {
                runs.append((level, i, i + 1))
            }
        }
        var merged: [(level: PacingLevel, start: Int, end: Int)] = []
        for run in runs {
            if run.end - run.start < 2, let lastRun = merged.last {
                merged[merged.count - 1].end = run.end
                _ = lastRun
            } else if let lastRun = merged.last, lastRun.level == run.level {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }

        return merged.map { run in
            let slice = Array(timeline[run.start..<run.end])
            let notes = explain(slice, level: run.level)
            return PacingSegment(start: Double(run.start), end: Double(run.end), level: run.level,
                                 reasons: notes.reasons, suggestions: notes.suggestions)
        }
    }

    private static func explain(_ slice: [PacingSecond], level: PacingLevel) -> (reasons: [String], suggestions: [String]) {
        guard !slice.isEmpty else { return ([], []) }
        let n = Double(slice.count)
        func avg(_ key: (PacingSecond) -> Double) -> Double { slice.map(key).reduce(0, +) / n }
        let maxAge = slice.map { $0.shotAge }.max() ?? 0
        let motion = avg { $0.motion }
        let speech = avg { $0.speech }
        let laughter = avg { $0.laughter }
        let music = avg { $0.music }
        let nature = avg { $0.nature }
        let smile = avg { $0.smile }
        let faces = avg { $0.faces }
        let loud = avg { $0.loud }
        let aesthetics = slice.compactMap { $0.aesthetic }
        let pretty = aesthetics.isEmpty ? 0 : aesthetics.reduce(0, +) / Double(aesthetics.count)
        let scene = mostCommon(slice.compactMap { $0.scene })

        var good: [String] = []
        var bad: [String] = []
        var suggestions: [String] = []

        if pretty > 0.25 {
            good.append(scene.map { "\($0)がきれいに撮れていて、見ていられる画です" } ?? "画がきれいで、見ていられます")
        }
        if smile > 0.3 { good.append("笑顔が映っています") } else if faces > 0.5 { good.append("人の表情が見えています") }
        if laughter > 0.3 { good.append("笑い声が入っていて盛り上がっています") }
        if max(music, nature) > 0.4 && pretty > 0.1 {
            good.append(nature > music ? "自然の音と景色で、雰囲気のある「間」になっています" : "音楽と画で雰囲気が出ています")
        }
        if speech > 0.5 && level == .good { good.append("話が続いていてテンポがあります") }

        if maxAge > 10 { bad.append("同じカットが \(Int(maxAge)) 秒続いています") }
        if motion < 0.2 && slice.contains(where: { $0.hasVideo }) { bad.append("画面の動きが少なめです") }
        if speech < 0.3 && laughter < 0.2 && music < 0.3 && nature < 0.3 && loud < 0.15 {
            bad.append("声や音がほとんどありません")
        }
        if speech > 0.5 && maxAge > 12 && motion < 0.3 { bad.append("画面が変わらないまま話が続いています") }

        if level != .good {
            if maxAge > 10 { suggestions.append("スプリットして間を詰めるか、途中で別のカットを挟む") }
            if speech > 0.5 && motion < 0.3 { suggestions.append("話の内容に合う写真や動画をオーバーレイで重ねる") }
            if motion < 0.2 { suggestions.append("ゆっくりズーム(Ken Burns / キーフレーム)で画に動きをつける") }
            if speech < 0.3 && loud < 0.15 { suggestions.append("無音部分を削除する、または BGM を足す") }
            suggestions.append("テキストや字幕で情報を足す")
        }
        let reasons = (level == .good ? good + bad : bad + good)
        return (Array(reasons.prefix(3)), Array(suggestions.prefix(3)))
    }

    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func mark(_ timeline: inout [PacingSecond], start: Double, end: Double,
                             _ update: (inout PacingSecond) -> Void) {
        guard !timeline.isEmpty, end > start else { return }
        let s0 = max(0, Int(start.rounded(.down)))
        let s1 = min(timeline.count - 1, Int(end.rounded(.up)) - 1)
        guard s1 >= s0 else { return }
        for s in s0...s1 { update(&timeline[s]) }
    }

    private static func fillGaps(_ timeline: inout [PacingSecond], from first: Int, to last: Int) {
        guard last > first else { return }
        for s in (first + 1)...last where timeline[s].motion == 0 && timeline[s].aesthetic == nil {
            let previous = timeline[s - 1]
            timeline[s].motion = previous.motion
            timeline[s].faces = previous.faces
            timeline[s].smile = previous.smile
            timeline[s].aesthetic = previous.aesthetic
            timeline[s].scene = previous.scene
        }
    }

    // MARK: - 映像

    private struct VideoSecond {
        var motion: Double = 0
        var faces: Double = 0
        var smile: Double = 0
        var aesthetic: Double? = nil
        var scene: String? = nil
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil,
                                                 options: [CIDetectorAccuracy: CIDetectorAccuracyLow])

    private static func analyzeVideo(clip: Clip, progress: @escaping (Double) -> Void) async throws -> [VideoSecond] {
        if clip.isStill, let url = clip.stillImageURL, let image = CIImage(contentsOf: url) {
            var second = VideoSecond()
            judgeFrame(image, into: &second, aesthetics: true, classify: true)
            let count = max(1, Int(clip.trimmedDuration.rounded(.up)))
            return [VideoSecond](repeating: second, count: count)
        }
        let duration = clip.trimmedDuration
        guard duration > 0.3 else { return [] }
        let count = max(1, Int(duration.rounded(.up)))

        final class State {
            var result: [VideoSecond]
            var previous: [UInt8] = []
            var lastAestheticSecond = -10
            var lastClassifySecond = -10
            var lastFaceSecond = -1
            init(count: Int) { result = [VideoSecond](repeating: VideoSecond(), count: count) }
        }
        let state = State(count: count)
        let start = clip.startTime
        try await AnalysisFrameReader.readFrames(url: clip.url, start: clip.startTime, end: clip.endTime,
                                                 fps: 2, maxDimension: 480) { buffer, time in
            let relative = max(0, time - start)
            let s = min(count - 1, Int(relative))
            progress(min(1, relative / duration))
            let image = CIImage(cvPixelBuffer: buffer)
            // 動き: 32×18 の白黒画像の差
            let thumb = tinyLuma(image)
            if !state.previous.isEmpty, thumb.count == state.previous.count {
                var diff = 0
                for i in thumb.indices { diff += abs(Int(thumb[i]) - Int(state.previous[i])) }
                let value = min(1, Double(diff) / Double(thumb.count) / 25)
                state.result[s].motion = max(state.result[s].motion, value)
            }
            state.previous = thumb
            // 顔と笑顔(1 秒に 1 回)、美しさ(2 秒に 1 回)、写っているもの(4 秒に 1 回)
            if s != state.lastFaceSecond {
                state.lastFaceSecond = s
                let aesthetics = s - state.lastAestheticSecond >= 2
                let classify = s - state.lastClassifySecond >= 4
                if aesthetics { state.lastAestheticSecond = s }
                if classify { state.lastClassifySecond = s }
                judgeFrame(image, into: &state.result[s], aesthetics: aesthetics, classify: classify)
            }
            return true
        }
        return state.result
    }

    private static func tinyLuma(_ image: CIImage) -> [UInt8] {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return [] }
        let small = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .transformed(by: CGAffineTransform(scaleX: 32 / e.width, y: 18 / e.height))
        var bytes = [UInt8](repeating: 0, count: 32 * 18 * 4)
        ciContext.render(small, toBitmap: &bytes, rowBytes: 32 * 4,
                         bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: 32, height: 18),
                         format: .RGBA8, colorSpace: nil)
        var luma = [UInt8](repeating: 0, count: 32 * 18)
        for i in 0..<(32 * 18) { luma[i] = bytes[i * 4] }
        return luma
    }

    private static func judgeFrame(_ image: CIImage, into second: inout VideoSecond, aesthetics: Bool, classify: Bool) {
        if let features = faceDetector?.features(in: image, options: [CIDetectorSmile: true]) as? [CIFaceFeature] {
            second.faces = max(second.faces, min(1, Double(features.count) / 2))
            if features.contains(where: { $0.hasSmile }) { second.smile = 1 }
        }
        guard aesthetics || classify else { return }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        var requests: [VNRequest] = []
        let aestheticRequest = VNCalculateImageAestheticsScoresRequest()
        let classifyRequest = VNClassifyImageRequest()
        if aesthetics { requests.append(aestheticRequest) }
        if classify { requests.append(classifyRequest) }
        try? handler.perform(requests)
        if aesthetics, let observation = aestheticRequest.results?.first {
            // 書類・画面写真のような「記録用」の画は美しさに数えない
            second.aesthetic = observation.isUtility ? -0.2 : Double(observation.overallScore)
        }
        if classify, let labels = classifyRequest.results {
            for label in labels.prefix(8) where label.confidence > 0.3 {
                if let name = sceneName(label.identifier) {
                    second.scene = name
                    break
                }
            }
        }
    }

    /// Vision の分類名 → 理由の文に使う日本語(景色に関係するものだけ)
    private static func sceneName(_ identifier: String) -> String? {
        let table: [(String, String)] = [
            ("sunset", "夕焼け"), ("sunrise", "朝焼け"), ("sky", "空"), ("cloud", "空"),
            ("beach", "海辺"), ("ocean", "海"), ("sea", "海"), ("lake", "湖"), ("river", "川"),
            ("waterfall", "滝"), ("mountain", "山"), ("forest", "森"), ("tree", "木々"),
            ("flower", "花"), ("snow", "雪景色"), ("night", "夜景"), ("city", "街並み"),
            ("cityscape", "街並み"), ("skyline", "街並み"), ("food", "料理"), ("garden", "庭"),
            ("park", "公園"), ("field", "野原"), ("desert", "砂漠"), ("bridge", "橋"),
            ("temple", "寺社"), ("shrine", "寺社"), ("animal", "動物"), ("dog", "犬"), ("cat", "猫")
        ]
        let lower = identifier.lowercased()
        for (key, name) in table where lower.contains(key) {
            return name
        }
        return nil
    }

    // MARK: - 音

    private struct AudioSecond {
        var loud: Double = 0
        var speech: Double = 0
        var laughter: Double = 0
        var music: Double = 0
        var nature: Double = 0
    }

    private final class SoundObserver: NSObject, SNResultsObserving {
        var seconds: [AudioSecond]
        init(count: Int) { seconds = [AudioSecond](repeating: AudioSecond(), count: count) }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let center = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
            let s = Int(center)
            guard s >= 0, s < seconds.count else { return }
            for c in result.classifications where c.confidence > 0.15 {
                let id = c.identifier.lowercased()
                let v = c.confidence
                if id.contains("speech") || id.contains("conversation") || id.contains("narration") {
                    seconds[s].speech = max(seconds[s].speech, v)
                } else if id.contains("laugh") || id.contains("giggle") || id.contains("applause")
                            || id.contains("cheer") || id.contains("chuckle") {
                    seconds[s].laughter = max(seconds[s].laughter, v)
                } else if id.contains("music") || id.contains("singing") || id.contains("guitar")
                            || id.contains("piano") || id.contains("drum") {
                    seconds[s].music = max(seconds[s].music, v)
                } else if id.contains("wind") || id.contains("water") || id.contains("ocean")
                            || id.contains("wave") || id.contains("rain") || id.contains("bird")
                            || id.contains("stream") || id.contains("insect") || id.contains("thunder") {
                    seconds[s].nature = max(seconds[s].nature, v)
                }
            }
        }
    }

    private static func analyzeAudio(clip: Clip) async throws -> [AudioSecond] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("pacing_\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: temp) }
        try await MediaTools.exportAudio(from: clip.url, start: clip.startTime, end: clip.endTime, to: temp)
        let count = max(1, Int(clip.trimmedDuration.rounded(.up)))

        // 音量(1 秒ごとの RMS を、クリップ内の 95 パーセンタイルで正規化)
        var loud = [Double](repeating: 0, count: count)
        if let file = try? AVAudioFile(forReading: temp) {
            let format = file.processingFormat
            let frames = AVAudioFrameCount(format.sampleRate)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                var index = 0
                while index < count {
                    buffer.frameLength = 0
                    do { try file.read(into: buffer, frameCount: frames) } catch { break }
                    if buffer.frameLength == 0 { break }
                    if let data = buffer.floatChannelData?[0] {
                        var sum: Float = 0
                        let n = Int(buffer.frameLength)
                        for i in 0..<n { sum += data[i] * data[i] }
                        loud[index] = Double(sqrt(sum / Float(max(1, n))))
                    }
                    index += 1
                }
            }
        }
        let sorted = loud.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        if p95 > 0.0001 {
            loud = loud.map { min(1, $0 / p95) }
        }

        // 雰囲気(話し声・笑い声・音楽・自然の音)
        let observer = SoundObserver(count: count)
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1),
           let analyzer = try? SNAudioFileAnalyzer(url: temp) {
            request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
            request.overlapFactor = 0.5
            try? analyzer.add(request, withObserver: observer)
            analyzer.analyze()
        }
        var result = observer.seconds
        for i in result.indices { result[i].loud = loud[i] }
        return result
    }
}
