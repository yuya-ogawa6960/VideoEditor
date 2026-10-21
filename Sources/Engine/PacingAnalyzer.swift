import Foundation
import AVFoundation
import CoreImage
import Vision
import SoundAnalysis

// =====================================================================
// 中だるみチェックと編集チェック(端末内の AI で判定。AI に話の中身を採点させるときだけ
// 字幕の文章を Apple Intelligence またはクラウド AI に渡す)。
//
// 出力タイムラインの 1 秒ごとに「見ている人が飽きそうな度合い」を 0...1 で出し、
// 緑(テンポよい)/ 黄(少しゆるい)/ 赤(中だるみ)の区間にまとめる。
//
// 飽きやすさを上げるもの:
//   - 同じカットが長く続く(クリップの境目・クリップ内の場面転換・オーバーレイの登場で 0 に戻る)
//   - 画面の動きが少ない(2 コマ/秒の縮小画像の差)
//   - 話し声も音楽も笑い声もなく、音が小さい
//   - 画面が変わらないまま長く話し続けている
//   - 話がゆっくり(字幕の 1 秒あたりの文字数)、話の途中の長い沈黙
//   - (選んだとき)AI が「退屈・繰り返し・前置きが長い」と採点した区間
// 下げるもの(「間」として見ていられるもの):
//   - 景色・画のきれいさ(Vision の美しさスコア VNCalculateImageAestheticsScoresRequest)
//   - 人の顔・笑顔(CIDetector の笑顔判定)
//   - 笑い声・拍手・歓声、音楽、自然の音(波・風・鳥・雨など)= 雰囲気(SoundAnalysis)
//   - 話し声、テキスト・ステッカー・オーバーレイが出ている、AI が高く採点した区間
// 何が映っているか(夕焼け・海など)は VNClassifyImageRequest で読み、理由の文に使う。
// 動画ごとの真ん中の値で基準をならし、厳しさ(厳しめ / ふつう / ゆるめ)を選べる。
//
// あわせて、YouTuber・インフルエンサーが気をつける点(冒頭のつかみ・字幕・BGM と声・
// テキストの表示時間・縦動画の安全な範囲・長さと比率・カットの頻度・終わり方・サムネ)を点検する。
// =====================================================================

enum PacingLevel: Int, Comparable {
    case good = 0
    case loose = 1
    case dull = 2

    static func < (lhs: PacingLevel, rhs: PacingLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .good: return String(localized: "テンポよい")
        case .loose: return String(localized: "少しゆるい")
        case .dull: return String(localized: "中だるみ")
        }
    }
}

/// 判定の厳しさ
enum PacingSensitivity: String, CaseIterable, Identifiable {
    case strict, normal, relaxed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .strict: return String(localized: "厳しめ")
        case .normal: return String(localized: "ふつう")
        case .relaxed: return String(localized: "ゆるめ")
        }
    }
    /// 点数に足す値(厳しいほど赤くなりやすい)
    var bias: Double {
        switch self {
        case .strict: return 0.07
        case .normal: return 0
        case .relaxed: return -0.07
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

/// 編集チェック(YouTuber・インフルエンサーが気をつける点)の 1 項目
struct EditingCheck: Identifiable, Equatable {
    enum Fix: Equatable {
        case openCaptions
        case enableDucking
        case makeVertical
        case openCover
        case seek(Double)
        /// BGM の音量をこの値にする(声より十分小さく)
        case setBGMVolume(Float)
        /// 「ラウドネスを自動一致」を実行する
        case normalizeLoudness
        /// このクリップの「カラーマッチ」を開く
        case openColorMatch(UUID)
        /// 「字幕から構成案(チャプター)」のある AI 台本の画面を開く
        case openScriptWriter
        /// このクリップの「オートリフレーム」を開く
        case openAutoReframe(UUID)
    }
    let id = UUID()
    let level: PacingLevel
    let title: String
    let detail: String
    var fix: Fix? = nil
    var fixTitle: String? = nil
}

/// クリップごとの見た目の平均(色・明るさのばらつき、人物の位置のチェックに使う)
private struct ClipVisualStats {
    var meanLuma: Double? = nil
    var warmth: Double? = nil
    /// 顔が写っていた秒の、顔の中心の横位置(0 = 左端, 1 = 右端)の平均
    var faceCenterX: Double? = nil
    var faceSeconds: Int = 0
}

struct PacingReport: Equatable {
    var segments: [PacingSegment] = []
    var checks: [EditingCheck] = []
    var usedAI = false
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
    /// ここで画が切り替わった(クリップの境目・クリップ内の場面転換・オーバーレイの登場)
    var cut: Bool = false
    /// 字幕から読んだ話す速さ(1 秒あたりの文字数)。字幕がなければ nil
    var talkRate: Double? = nil
    /// 話の途中の長い沈黙
    var pause: Bool = false
    /// AI が付けた話の面白さ(1...5)と一言
    var aiScore: Int? = nil
    var aiNote: String? = nil
}

enum PacingAnalyzer {

    static func analyze(snapshot: ProjectSnapshot, sensitivity: PacingSensitivity, useAI: Bool,
                        progress: ((Double) -> Void)?) async throws -> PacingReport {
        let placements = CompositionBuilder.timelineLayout(for: snapshot)
        let total = placements.last?.end ?? 0
        guard total > 1 else { return PacingReport() }
        let seconds = Int(total.rounded(.up))
        var timeline = [PacingSecond](repeating: PacingSecond(), count: seconds)
        let mediaShare: Double = (useAI && !snapshot.subtitles.isEmpty) ? 0.85 : 1.0

        let clipCount = Double(max(1, snapshot.clips.count))
        var visuals: [ClipVisualStats] = []
        var clipLoudness: [Int: Double] = [:]
        for (index, clip) in snapshot.clips.enumerated() {
            try Task.checkCancellation()
            guard index < placements.count else { break }
            let placement = placements[index]
            let base: Double = mediaShare * Double(index) / clipCount
            let share: Double = mediaShare / clipCount
            let speed = max(clip.speed, 0.01)

            let first = max(0, Int(placement.start.rounded(.down)))
            let last = min(seconds - 1, Int(placement.end.rounded(.up)) - 1)
            if last >= first {
                timeline[first].cut = true
                for s in first...last {
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
                if value.cut { timeline[s].cut = true }
            }
            // 1 秒より遅い速度のとき、間を埋める
            fillGaps(&timeline, from: first, to: last)
            visuals.append(Self.summarize(video))

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
                // クリップごとの音量(LUFS)。ばらつきと BGM との比較に使う
                if snapshot.clips.count <= 40,
                   let measured = try? await LoudnessAnalyzer.measure(url: clip.url, start: clip.startTime, end: clip.endTime),
                   measured.isValid {
                    clipLoudness[index] = measured.integratedLUFS
                }
            }
            progress?(base + share)
        }
        var bgmLUFS: Double? = nil
        if let bgmURL = snapshot.audio.bgmURL,
           let measured = try? await LoudnessAnalyzer.measure(url: bgmURL, start: 0, end: 90), measured.isValid {
            bgmLUFS = measured.integratedLUFS
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
            // オーバーレイが出ると画が変わる
            let s0 = Int(overlay.start)
            if s0 >= 0, s0 < seconds { timeline[s0].cut = true }
        }
        applyTalkSignals(snapshot.subtitles, to: &timeline)
        recomputeShotAge(&timeline)

        // AI に話の面白さを採点してもらう(字幕があるときだけ)
        var usedAI = false
        if useAI, !snapshot.subtitles.isEmpty {
            let start: Double = mediaShare
            usedAI = await applyAIReview(snapshot.subtitles, to: &timeline) { fraction in
                progress?(start + (1 - start) * fraction)
            }
        }

        progress?(1)
        let segments = makeSegments(from: timeline, sensitivity: sensitivity)
        let checks = makeChecks(snapshot: snapshot, timeline: timeline, total: total,
                                visuals: visuals, loudness: clipLoudness, bgmLUFS: bgmLUFS)
        return PacingReport(segments: segments, checks: checks, usedAI: usedAI)
    }

    // MARK: - 手がかりの追加

    /// カットが変わってからの秒数(クリップの境目・クリップ内の場面転換・オーバーレイの登場で 0 に戻る)
    private static func recomputeShotAge(_ timeline: inout [PacingSecond]) {
        var age = 0.0
        for s in timeline.indices {
            if timeline[s].cut || s == 0 {
                age = 0
            } else {
                age += 1
            }
            timeline[s].shotAge = age
        }
    }

    /// 字幕から話す速さと、話の途中の長い沈黙を読む
    private static func applyTalkSignals(_ subtitles: [SubtitleCue], to timeline: inout [PacingSecond]) {
        let cues = subtitles.sorted { $0.start < $1.start }
        for cue in cues where cue.duration > 0.3 {
            let chars = cue.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            let rate: Double = Double(chars) / cue.duration
            mark(&timeline, start: cue.start, end: cue.end) { second in
                second.talkRate = max(second.talkRate ?? 0, rate)
            }
        }
        // 話と話の間が 2.5 秒以上(20 秒以内)あいている所 = 話の途中の沈黙
        guard cues.count >= 2 else { return }
        for i in 0..<(cues.count - 1) {
            let gapStart = cues[i].end
            let gapEnd = cues[i + 1].start
            let gap = gapEnd - gapStart
            if gap >= 2.5 && gap <= 20 {
                mark(&timeline, start: gapStart + 1, end: gapEnd) { $0.pause = true }
            }
        }
    }

    /// 字幕を約 30 秒ごとに区切って AI に読ませ、話の面白さ・情報量を 1...5 で付けてもらう。
    /// 1 区間でも採点できたら true
    private static func applyAIReview(_ subtitles: [SubtitleCue], to timeline: inout [PacingSecond],
                                      progress: (Double) -> Void) async -> Bool {
        let settings = AppSettings.shared
        let engine = ScriptWriter.resolveEngine(settings: settings)
        guard engine != .none else { return false }
        let cues = subtitles.sorted { $0.start < $1.start }
        var chunks: [(start: Double, end: Double, text: String)] = []
        var current: (start: Double, end: Double, text: String)? = nil
        for cue in cues {
            if var c = current, cue.end - c.start <= 30 {
                c.end = cue.end
                c.text += " " + cue.text
                current = c
            } else {
                if let c = current { chunks.append(c) }
                current = (cue.start, cue.end, cue.text)
            }
        }
        if let c = current { chunks.append(c) }
        guard !chunks.isEmpty else { return false }

        let instructions = """
        あなたは YouTube 動画の編集者です。動画の字幕を区間ごとに読み、見ている人が飽きずに見続けられるかを判定します。
        各区間について、話の面白さ・情報量・テンポを 1〜5 で採点します(5 = 引きつけられる、1 = 退屈・同じ話の繰り返し・前置きが長い)。
        出力は 1 区間 1 行、「番号: 点数 / 理由(15 文字以内)」の形だけにしてください。
        """
        var applied = false
        let batchSize = 12
        var index = 0
        while index < chunks.count {
            if Task.isCancelled { break }
            let upper = min(index + batchSize, chunks.count)
            var prompt = String(localized: "次の区間を採点してください。\n")
            for k in index..<upper {
                prompt += "\(k + 1): \(chunks[k].text.prefix(400))\n"
            }
            if let reply = try? await ScriptWriter.generate(engine: engine, instructions: instructions, prompt: prompt,
                                                           apiKey: settings.cloudCredential, temperature: 0.2) {
                for line in reply.components(separatedBy: .newlines) {
                    guard let parsed = parseReviewLine(line), parsed.number >= 1, parsed.number <= chunks.count else { continue }
                    let chunk = chunks[parsed.number - 1]
                    mark(&timeline, start: chunk.start, end: chunk.end) { second in
                        second.aiScore = parsed.score
                        second.aiNote = parsed.note
                    }
                    applied = true
                }
            }
            index = upper
            progress(min(1, Double(index) / Double(chunks.count)))
        }
        return applied
    }

    /// 「3: 4 / 理由」→ (3, 4, "理由")
    private static func parseReviewLine(_ line: String) -> (number: Int, score: Int, note: String)? {
        let normalized = line
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "／", with: "/")
        let parts = normalized.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let digits = parts[0].filter { $0.isNumber }
        guard let number = Int(digits) else { return nil }
        let rest = parts[1].split(separator: "/", maxSplits: 1)
        guard let first = rest.first else { return nil }
        let scoreText = first.trimmingCharacters(in: .whitespaces).prefix(1)
        guard let score = Int(scoreText), (1...5).contains(score) else { return nil }
        let note: String = rest.count > 1 ? rest[1].trimmingCharacters(in: .whitespaces) : ""
        return (number, score, note)
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
        // 話す速さ: ゆっくりすぎると間延び、テンポよく話していれば見ていられる
        if let rate = f.talkRate {
            if rate < 3 {
                score += 0.1
            } else if rate > 7 {
                score -= 0.05
            }
        }
        // 話の途中の長い沈黙
        if f.pause { score += 0.15 }

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
        // AI の採点(話の中身)。3 を基準に 1 点で 0.1
        if let ai = f.aiScore {
            score += Double(3 - ai) * 0.1
        }
        return score
    }

    private static func makeSegments(from timeline: [PacingSecond], sensitivity: PacingSensitivity) -> [PacingSegment] {
        var raw: [Double] = timeline.map { dullness($0) }
        // 動画ごとにならす: 全体がゆったりした動画で全部が赤にならないよう、真ん中の値が高すぎるときは下げる
        let sorted = raw.sorted()
        let median: Double = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let shift: Double = max(0, median - 0.45) * 0.7
        raw = raw.map { min(max($0 - shift + sensitivity.bias, 0), 1) }

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
            if run.end - run.start < 2, !merged.isEmpty {
                merged[merged.count - 1].end = run.end
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
        let pauses = slice.filter { $0.pause }.count
        let rates = slice.compactMap { $0.talkRate }
        let rate: Double? = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        let aesthetics = slice.compactMap { $0.aesthetic }
        let pretty: Double = aesthetics.isEmpty ? 0 : aesthetics.reduce(0, +) / Double(aesthetics.count)
        let scene = mostCommon(slice.compactMap { $0.scene })
        let aiScores = slice.compactMap { $0.aiScore }
        let aiAverage: Double? = aiScores.isEmpty ? nil : Double(aiScores.reduce(0, +)) / Double(aiScores.count)
        let aiNote = mostCommon(slice.compactMap { $0.aiNote }.filter { !$0.isEmpty })

        var good: [String] = []
        var bad: [String] = []
        var suggestions: [String] = []

        if let aiAverage, let aiNote {
            if aiAverage >= 3.5 {
                good.append("AI: " + aiNote)
            } else if aiAverage <= 2.5 {
                bad.append("AI: " + aiNote)
            }
        }
        if pretty > 0.25 {
            good.append(scene.map { String(localized: "\($0)がきれいに撮れていて、見ていられる画です") } ?? String(localized: "画がきれいで、見ていられます"))
        }
        if smile > 0.3 {
            good.append(String(localized: "笑顔が映っています"))
        } else if faces > 0.5 {
            good.append(String(localized: "人の表情が見えています"))
        }
        if laughter > 0.3 { good.append(String(localized: "笑い声が入っていて盛り上がっています")) }
        if max(music, nature) > 0.4 && pretty > 0.1 {
            good.append(nature > music ? String(localized: "自然の音と景色で、雰囲気のある「間」になっています") : String(localized: "音楽と画で雰囲気が出ています"))
        }
        if let rate, rate > 6 { good.append(String(localized: "話のテンポがよいです")) }

        if maxAge > 10 { bad.append(String(localized: "同じカットが \(Int(maxAge)) 秒続いています")) }
        if motion < 0.2 && slice.contains(where: { $0.hasVideo }) { bad.append(String(localized: "画面の動きが少なめです")) }
        if pauses >= 2 { bad.append(String(localized: "話の途中で \(pauses) 秒ほど間があいています")) }
        if let rate, rate < 3 { bad.append(String(localized: "話がゆっくりで、間延びしやすいです")) }
        if speech < 0.3 && laughter < 0.2 && music < 0.3 && nature < 0.3 && loud < 0.15 {
            bad.append(String(localized: "声や音がほとんどありません"))
        }
        if speech > 0.5 && maxAge > 12 && motion < 0.3 { bad.append(String(localized: "画面が変わらないまま話が続いています")) }

        if level != .good {
            if pauses >= 2 { suggestions.append(String(localized: "話の間をスプリットで詰める(ジャンプカット)")) }
            if maxAge > 10 { suggestions.append(String(localized: "途中で別のカットやズームを挟む(5〜10 秒ごとに画を変える)")) }
            if speech > 0.5 && motion < 0.3 { suggestions.append(String(localized: "話の内容に合う写真や動画をオーバーレイで重ねる")) }
            if let aiAverage, aiAverage <= 2.5 { suggestions.append(String(localized: "話が長い所は要点だけ残してカットする")) }
            if speech < 0.3 && loud < 0.15 { suggestions.append(String(localized: "無音部分を削除する、または BGM を足す")) }
            suggestions.append(String(localized: "テキストで要点を見せる"))
        }
        let reasons = (level == .good ? good + bad : bad + good)
        return (Array(reasons.prefix(3)), Array(suggestions.prefix(3)))
    }

    // MARK: - 編集チェック(YouTuber・インフルエンサーが気をつける点)

    private static func makeChecks(snapshot: ProjectSnapshot, timeline: [PacingSecond], total: Double,
                                   visuals: [ClipVisualStats] = [], loudness: [Int: Double] = [:],
                                   bgmLUFS: Double? = nil) -> [EditingCheck] {
        var checks: [EditingCheck] = []
        let size = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)
        let vertical: Bool = size.height > size.width * 1.2

        // 1. 冒頭 3 秒のつかみ
        let opening = Array(timeline.prefix(3))
        let hook = opening.contains { $0.speech > 0.5 || $0.motion > 0.35 || $0.decorated || $0.smile > 0.5 || $0.laughter > 0.3 }
        if hook {
            checks.append(EditingCheck(level: .good, title: String(localized: "冒頭 3 秒のつかみ"),
                                       detail: String(localized: "最初の 3 秒に話・動き・テキストのどれかがあり、引きつけられます。")))
        } else {
            checks.append(EditingCheck(level: .dull, title: String(localized: "冒頭 3 秒のつかみ"),
                                       detail: String(localized: "最初の 3 秒が静かです。結論や一番いい場面を先に見せる、テキストで「何の動画か」を出すと離脱が減ります。"),
                                       fix: .seek(0), fixTitle: String(localized: "冒頭を見る")))
        }

        // 2. 最初が静かすぎないか
        if let first = timeline.first, first.loud < 0.08, first.motion < 0.05, first.speech < 0.3, !first.decorated {
            checks.append(EditingCheck(level: .loose, title: String(localized: "始まりの無音・止まった画面"),
                                       detail: String(localized: "最初の 1 秒が無音で動きもありません。頭を少し切ると、テンポよく始まります。"),
                                       fix: .seek(0), fixTitle: String(localized: "冒頭を見る")))
        }

        // 3. 字幕(音を出さずに見る人向け)
        let speechSeconds = timeline.filter { $0.speech > 0.5 }.count
        if speechSeconds >= 15 {
            let covered = timeline.filter { $0.speech > 0.5 && $0.talkRate != nil }.count
            let ratio: Double = Double(covered) / Double(speechSeconds)
            if ratio < 0.5 {
                let missing = Int(((1 - ratio) * 100).rounded())
                checks.append(EditingCheck(level: .dull, title: String(localized: "字幕"),
                                           detail: "話している所の \(missing)% に字幕がありません。SNS では音を出さずに見る人が多いので、字幕があると最後まで見てもらいやすくなります。",
                                           fix: .openCaptions, fixTitle: String(localized: "字幕を作る")))
            } else {
                checks.append(EditingCheck(level: .good, title: String(localized: "字幕"), detail: String(localized: "話している所にほぼ字幕が付いています。")))
            }
        }

        // 4. BGM と声
        if snapshot.audio.bgmURL != nil && speechSeconds >= 5 {
            if snapshot.documentary.autoDucking {
                checks.append(EditingCheck(level: .good, title: String(localized: "BGM と声"), detail: String(localized: "話している間は BGM が自動で下がります。")))
            } else {
                checks.append(EditingCheck(level: .loose, title: String(localized: "BGM と声"),
                                           detail: String(localized: "BGM と声が重なっています。話している間だけ BGM を下げる(ダッキング)と聞き取りやすくなります。"),
                                           fix: .enableDucking, fixTitle: String(localized: "ダッキングをオン")))
            }
        }

        // 5. テキストの表示時間
        let shortTexts = snapshot.textClips.filter { clip in
            guard !clip.isMosaic, !clip.isSticker else { return false }
            let chars = clip.text.filter { !$0.isWhitespace }.count
            return clip.duration < 0.8 + Double(chars) * 0.12
        }
        if let firstShort = shortTexts.min(by: { $0.start < $1.start }) {
            checks.append(EditingCheck(level: .loose, title: String(localized: "テキストの表示時間"),
                                       detail: String(localized: "\(shortTexts.count) 個のテキストが、文字数に対して表示が短く読み切れない可能性があります(目安: 0.8 秒 + 1 文字 0.12 秒)。"),
                                       fix: .seek(firstShort.start), fixTitle: String(localized: "最初の 1 つを見る")))
        }

        // 6. 縦動画の安全な範囲(下や右のボタン・説明文に隠れる)
        if vertical {
            let unsafe = snapshot.textClips.filter { !$0.isMosaic && ($0.center.y > 0.8 || $0.center.x > 0.85 || $0.center.y < 0.08) }
            if let firstUnsafe = unsafe.min(by: { $0.start < $1.start }) {
                checks.append(EditingCheck(level: .loose, title: String(localized: "縦動画の安全な範囲"),
                                           detail: String(localized: "\(unsafe.count) 個のテキストが画面の端にあり、TikTok・リール・ショートのボタンや説明文に隠れる可能性があります。少し内側に寄せましょう。"),
                                           fix: .seek(firstUnsafe.start), fixTitle: String(localized: "見る")))
            }
            if snapshot.subtitleStyle.position == .bottom, !snapshot.subtitles.isEmpty {
                checks.append(EditingCheck(level: .loose, title: String(localized: "縦動画の字幕の位置"),
                                           detail: String(localized: "縦動画で字幕がいちばん下にあると、説明文に隠れることがあります。「中央」寄りがおすすめです。")))
            }
        }

        // 7. 長さと比率
        if !vertical && total <= 60 {
            checks.append(EditingCheck(level: .loose, title: String(localized: "長さと比率"),
                                       detail: String(localized: "1 分以内の動画です。ショート・リール・TikTok に出すなら 9:16 の縦にすると画面いっぱいに見てもらえます。"),
                                       fix: .makeVertical, fixTitle: String(localized: "9:16 にする")))
        } else if vertical && total > 180 {
            checks.append(EditingCheck(level: .loose, title: String(localized: "長さと比率"),
                                       detail: String(localized: "縦動画で 3 分を超えています。ショート向けなら要点にしぼるか、長い動画なら 16:9 の横も検討しましょう。")))
        }

        // 8. カットの頻度
        if total >= 60 {
            let cuts = timeline.filter { $0.cut }.count
            let perMinute: Double = Double(cuts) / (total / 60)
            let text = String(format: "%.1f", perMinute)
            if perMinute < 3 {
                checks.append(EditingCheck(level: .loose, title: String(localized: "カットの頻度"),
                                           detail: String(localized: "1 分あたり \(text) 回しか画が変わっていません。5〜10 秒ごとにカット・ズーム・テキストなどで変化をつけると、見続けてもらいやすくなります。")))
            } else {
                checks.append(EditingCheck(level: .good, title: String(localized: "カットの頻度"),
                                           detail: String(localized: "1 分あたり \(text) 回、画が変わっていてテンポがあります。")))
            }
        }

        // 9. 終わり方
        let ending = Array(timeline.suffix(5))
        if ending.count == 5 {
            let quiet = ending.filter { $0.speech < 0.3 && $0.motion < 0.15 && !$0.decorated }.count
            if quiet >= 4 {
                checks.append(EditingCheck(level: .loose, title: String(localized: "終わり方"),
                                           detail: String(localized: "最後の 5 秒が静かです。余韻が長いと最後まで見られにくいので、短くするか、次の動画やチャンネル登録への一言を入れましょう。"),
                                           fix: .seek(max(0, total - 5)), fixTitle: String(localized: "最後を見る")))
            }
        }

        // 10. サムネ
        let cover = snapshot.cover
        let hasCover: Bool = cover.imageURL != nil || !cover.title.isEmpty || !cover.memoText.isEmpty
        if hasCover {
            checks.append(EditingCheck(level: .good, title: String(localized: "サムネ"), detail: String(localized: "サムネが作られています。")))
        } else {
            checks.append(EditingCheck(level: .loose, title: String(localized: "サムネ"),
                                       detail: String(localized: "サムネがまだありません。一覧で選ばれるかはサムネで決まるので、顔や一番いい場面と短い言葉で作りましょう。"),
                                       fix: .openCover, fixTitle: String(localized: "サムネを作る")))
        }

        // 11. BGM が声より大きくないか(測った音量で比べる)
        if let bgm = bgmLUFS, snapshot.audio.bgmURL != nil, speechSeconds >= 5 {
            let voices: [Double] = snapshot.clips.indices.compactMap { i -> Double? in
                guard let v = loudness[i], !snapshot.clips[i].isMuted else { return nil }
                return v
            }
            if !voices.isEmpty {
                let voice = voices.sorted()[voices.count / 2] + 20 * log10(Double(max(snapshot.audio.originalVolume, 0.01)))
                var bgmLevel = bgm + 20 * log10(Double(max(snapshot.audio.bgmVolume, 0.01)))
                if snapshot.documentary.autoDucking {
                    bgmLevel += 20 * log10(Double(max(snapshot.documentary.duckingLevel, 0.05)))
                }
                let gap = voice - bgmLevel   // 声のほうがどれだけ大きいか(dB)
                if gap < 8 {
                    // 声より 14 dB 下がる音量にする
                    let wanted = Double(snapshot.audio.bgmVolume) * pow(10, (gap - 14) / 20)
                    let volume = Float(min(1, max(0.05, wanted)))
                    let percent = Int((volume * 100).rounded())
                    checks.append(EditingCheck(level: gap < 3 ? .dull : .loose, title: String(localized: "BGM の大きさ"),
                                               detail: String(localized: "BGM が声と同じくらいの大きさです(差 \(Int(gap.rounded())) dB)。声がいちばん聞こえるよう、BGM は声より 12〜15 dB 下げるのが目安です。"),
                                               fix: .setBGMVolume(volume), fixTitle: String(localized: "BGM を \(percent)% にする")))
                } else {
                    checks.append(EditingCheck(level: .good, title: String(localized: "BGM の大きさ"),
                                               detail: String(localized: "BGM は声より \(Int(gap.rounded())) dB 小さく、声がはっきり聞こえます。")))
                }
            }
        }

        // 12. 字幕が長すぎないか(1 枚の文字数・行数)
        if !subtitleCues(snapshot).isEmpty {
            let longCues = subtitleCues(snapshot).filter { cue in
                let lines = cue.text.split(separator: "\n", omittingEmptySubsequences: true)
                let longest = lines.map { $0.count }.max() ?? cue.text.count
                let japanese = cue.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
                return lines.count > 2 || longest > (japanese ? 26 : 42)
            }
            if let first = longCues.min(by: { $0.start < $1.start }) {
                checks.append(EditingCheck(level: .loose, title: String(localized: "字幕の長さ"),
                                           detail: String(localized: "\(longCues.count) 枚の字幕が長すぎます(目安: 1 行 26 文字・2 行まで)。読み切れないので、文を分けるか短くしましょう。"),
                                           fix: .seek(first.start), fixTitle: String(localized: "最初の 1 つを見る")))
            } else if subtitleCues(snapshot).count >= 5 {
                checks.append(EditingCheck(level: .good, title: String(localized: "字幕の長さ"),
                                           detail: String(localized: "字幕は読み切れる長さに収まっています。")))
            }
        }

        // 13. クリップごとの音量のばらつき
        let levels = loudness.values.sorted()
        if levels.count >= 2 {
            let spread = levels[levels.count - 1] - levels[0]
            if spread >= 6 {
                checks.append(EditingCheck(level: spread >= 10 ? .dull : .loose, title: String(localized: "クリップごとの音量"),
                                           detail: String(localized: "クリップの間で音量が最大 \(Int(spread.rounded())) dB 違います。急に大きくなったり小さくなったりすると聞きづらいので、そろえましょう。"),
                                           fix: .normalizeLoudness, fixTitle: String(localized: "音量をそろえる")))
            } else {
                checks.append(EditingCheck(level: .good, title: String(localized: "クリップごとの音量"),
                                           detail: String(localized: "クリップの間の音量の差は \(Int(spread.rounded())) dB で、そろっています。")))
            }
        }

        // 14. クリップごとの色・明るさのばらつき
        let videoIndices = snapshot.clips.indices.filter { i in
            i < visuals.count && !snapshot.clips[i].isStill && visuals[i].meanLuma != nil
        }
        if videoIndices.count >= 2 {
            let lumas = videoIndices.map { visuals[$0].meanLuma ?? 0 }
            let warmths = videoIndices.map { visuals[$0].warmth ?? 0 }
            let lumaSpread = (lumas.max() ?? 0) - (lumas.min() ?? 0)
            let warmSpread = (warmths.max() ?? 0) - (warmths.min() ?? 0)
            if lumaSpread >= 0.22 || warmSpread >= 0.12 {
                // 真ん中からいちばん離れたクリップを直す対象にする
                let medianLuma = lumas.sorted()[lumas.count / 2]
                let medianWarm = warmths.sorted()[warmths.count / 2]
                let worst = videoIndices.max { a, b in
                    let da = abs((visuals[a].meanLuma ?? 0) - medianLuma) + abs((visuals[a].warmth ?? 0) - medianWarm) * 2
                    let db = abs((visuals[b].meanLuma ?? 0) - medianLuma) + abs((visuals[b].warmth ?? 0) - medianWarm) * 2
                    return da < db
                } ?? videoIndices[0]
                let what = lumaSpread >= 0.22 ? String(localized: "明るさ") : String(localized: "色味")
                checks.append(EditingCheck(level: .loose, title: String(localized: "クリップごとの色"),
                                           detail: String(localized: "クリップの間で\(what)が大きく違います。別の日・別のカメラの素材が混ざっているときは、「カラーマッチ」でお手本のクリップに合わせると統一感が出ます。"),
                                           fix: .openColorMatch(snapshot.clips[worst].id), fixTitle: String(localized: "カラーマッチを開く")))
            } else {
                checks.append(EditingCheck(level: .good, title: String(localized: "クリップごとの色"),
                                           detail: String(localized: "クリップの明るさ・色味はそろっています。")))
            }
        }

        // 15. 長い動画のチャプター(YouTube は 3 つ以上・最初は 0:00・各 10 秒以上)
        if total >= 480 {
            let chapters = snapshot.markers.filter { $0.kind == .chapter }
            if chapters.count < 3 {
                checks.append(EditingCheck(level: .loose, title: String(localized: "チャプター"),
                                           detail: String(localized: "8 分を超える動画にチャプターが \(chapters.count) 個しかありません。YouTube では 3 つ以上(最初は 0:00、各 10 秒以上)あると目次が出て、見たい所へ飛べます。字幕があれば AI が構成案を作ります。"),
                                           fix: .openScriptWriter, fixTitle: String(localized: "構成案を作る")))
            } else {
                checks.append(EditingCheck(level: .good, title: String(localized: "チャプター"),
                                           detail: String(localized: "チャプターが \(chapters.count) 個あります。")))
            }
        }

        // 16. 冒頭のタイトル・静止画が長い
        if let card = snapshot.titleCards.first(where: { $0.start < 1.0 }), card.duration >= 4 {
            checks.append(EditingCheck(level: .loose, title: String(localized: "冒頭のタイトル"),
                                       detail: String(localized: "最初のタイトルが \(Int(card.duration.rounded())) 秒あります。イントロは 2〜3 秒以内にして、すぐ本題に入るほうが離脱されにくいです。"),
                                       fix: .seek(0), fixTitle: String(localized: "冒頭を見る")))
        } else if let firstClip = snapshot.clips.first, firstClip.isStill, firstClip.trimmedDuration >= 4,
                  timeline.prefix(4).allSatisfy({ $0.speech < 0.3 }) {
            checks.append(EditingCheck(level: .loose, title: String(localized: "冒頭のタイトル"),
                                       detail: String(localized: "最初の写真が \(Int(firstClip.trimmedDuration.rounded())) 秒、話もなく続きます。冒頭は 3 秒以内で動きのある場面に入るのがおすすめです。"),
                                       fix: .seek(0), fixTitle: String(localized: "冒頭を見る")))
        }

        // 17. 縦動画で人物が中央にいない(横の素材を縦に切り出しているとき)
        if vertical, snapshot.canvas.scaling == .fill {
            var offCenter: [Int] = []
            for i in snapshot.clips.indices where i < visuals.count {
                let clip = snapshot.clips[i]
                guard !clip.isStill, !clip.reframe.isActive, clip.naturalSize.width > clip.naturalSize.height * 1.2,
                      visuals[i].faceSeconds >= 3, let x = visuals[i].faceCenterX else { continue }
                if x < 0.36 || x > 0.64 { offCenter.append(i) }
            }
            if let first = offCenter.first {
                checks.append(EditingCheck(level: .loose, title: String(localized: "縦動画の人物の位置"),
                                           detail: String(localized: "\(offCenter.count) 本のクリップで、人物が画面の端に寄っていて縦に切り出すと見切れます。「オートリフレーム」で人物を追いかけて中央に映せます。"),
                                           fix: .openAutoReframe(snapshot.clips[first].id), fixTitle: String(localized: "オートリフレームを開く")))
            }
        }

        // 気になる順(赤 → 黄 → 緑)
        return checks.sorted { $0.level > $1.level }
    }

    private static func subtitleCues(_ snapshot: ProjectSnapshot) -> [SubtitleCue] { snapshot.subtitles }

    // MARK: - 補助

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
        /// 画面の平均の明るさ 0...1
        var luma: Double? = nil
        /// 暖かさ(赤 − 青)-1...1
        var warmth: Double? = nil
        /// いちばん大きい顔の中心の横位置 0...1
        var faceCenterX: Double? = nil
        var aesthetic: Double? = nil
        var scene: String? = nil
        /// この秒の中で場面が大きく変わった(撮りっぱなしの動画の中の場面転換)
        var cut: Bool = false
    }

    /// 顔・笑顔の検出(GPU 用と、裏で GPU を使えないとき用の CPU 版)
    private static let gpuFaceDetector = CIDetector(ofType: CIDetectorTypeFace, context: FilterEngineContexts.gpu,
                                                    options: [CIDetectorAccuracy: CIDetectorAccuracyLow])
    private static let cpuFaceDetector = CIDetector(ofType: CIDetectorTypeFace, context: FilterEngineContexts.cpu,
                                                    options: [CIDetectorAccuracy: CIDetectorAccuracyLow])
    private static var faceDetector: CIDetector? {
        let lifecycle = AppLifecycle.shared
        return (lifecycle.isInBackground && !lifecycle.backgroundGPUAllowed) ? cpuFaceDetector : gpuFaceDetector
    }

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
            var averageMotion: Double = 0.2
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
            // 動き: 32×18 の白黒画像の差(ついでに平均の明るさと暖かさ)
            let tiny = tinyStats(image)
            let thumb = tiny.luma
            state.result[s].luma = tiny.meanLuma
            state.result[s].warmth = tiny.warmth
            if !state.previous.isEmpty, thumb.count == state.previous.count {
                var diff = 0
                for i in thumb.indices { diff += abs(Int(thumb[i]) - Int(state.previous[i])) }
                let value = min(1, Double(diff) / Double(thumb.count) / 25)
                state.result[s].motion = max(state.result[s].motion, value)
                // 急に大きく変わったら場面の切り替わり(ふだんの動きの 3 倍以上、かつ大きな差)
                if value > 0.6, value > state.averageMotion * 3, relative > 0.6 {
                    state.result[s].cut = true
                }
                state.averageMotion = state.averageMotion * 0.85 + value * 0.15
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

    private struct TinyStats {
        var luma: [UInt8] = []
        var meanLuma: Double? = nil
        var warmth: Double? = nil
    }

    /// 32×18 に縮めて、白黒の画(動きの比較用)と、平均の明るさ・暖かさを求める
    private static func tinyStats(_ image: CIImage) -> TinyStats {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return TinyStats() }
        let small = image.transformed(by: CGAffineTransform(scaleX: 32 / e.width, y: 18 / e.height))
        var bytes = [UInt8](repeating: 0, count: 32 * 18 * 4)
        FilterEngineContexts.current.render(small, toBitmap: &bytes, rowBytes: 32 * 4,
                         bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: 32, height: 18),
                         format: .RGBA8, colorSpace: nil)
        var luma = [UInt8](repeating: 0, count: 32 * 18)
        var sumLuma = 0.0
        var sumR = 0.0
        var sumB = 0.0
        for i in 0..<(32 * 18) {
            let r = Double(bytes[i * 4]), g = Double(bytes[i * 4 + 1]), b = Double(bytes[i * 4 + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            luma[i] = UInt8(min(255, max(0, y)))
            sumLuma += y
            sumR += r
            sumB += b
        }
        let n = Double(32 * 18)
        return TinyStats(luma: luma, meanLuma: sumLuma / n / 255, warmth: (sumR - sumB) / n / 255)
    }

    /// クリップ全体の平均(色・明るさ・顔の位置)
    private static func summarize(_ seconds: [VideoSecond]) -> ClipVisualStats {
        var stats = ClipVisualStats()
        let lumas = seconds.compactMap { $0.luma }
        if !lumas.isEmpty { stats.meanLuma = lumas.reduce(0, +) / Double(lumas.count) }
        let warmths = seconds.compactMap { $0.warmth }
        if !warmths.isEmpty { stats.warmth = warmths.reduce(0, +) / Double(warmths.count) }
        let faces = seconds.compactMap { $0.faceCenterX }
        stats.faceSeconds = faces.count
        if !faces.isEmpty { stats.faceCenterX = faces.reduce(0, +) / Double(faces.count) }
        return stats
    }

    private static func judgeFrame(_ image: CIImage, into second: inout VideoSecond, aesthetics: Bool, classify: Bool) {
        if let features = faceDetector?.features(in: image, options: [CIDetectorSmile: true]) as? [CIFaceFeature] {
            second.faces = max(second.faces, min(1, Double(features.count) / 2))
            if features.contains(where: { $0.hasSmile }) { second.smile = 1 }
            // いちばん大きい顔の横位置(人物が中央にいるかのチェック用)
            if let biggest = features.max(by: { $0.bounds.width < $1.bounds.width }), image.extent.width > 0 {
                second.faceCenterX = Double((biggest.bounds.midX - image.extent.minX) / image.extent.width)
            }
        }
        guard aesthetics || classify else { return }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        var requests: [VNRequest] = []
        let aestheticRequest = VNCalculateImageAestheticsScoresRequest()
        let classifyRequest = VNClassifyImageRequest()
        if aesthetics { requests.append(aestheticRequest) }
        if classify { requests.append(classifyRequest) }
        VisionCompute.prepare(requests)
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
            ("sunset", String(localized: "夕焼け")), ("sunrise", String(localized: "朝焼け")), ("sky", String(localized: "空")), ("cloud", String(localized: "空")),
            ("beach", String(localized: "海辺")), ("ocean", String(localized: "海")), ("sea", String(localized: "海")), ("lake", String(localized: "湖")), ("river", String(localized: "川")),
            ("waterfall", String(localized: "滝")), ("mountain", String(localized: "山")), ("forest", String(localized: "森")), ("tree", String(localized: "木々")),
            ("flower", String(localized: "花")), ("snow", String(localized: "雪景色")), ("night", String(localized: "夜景")), ("city", String(localized: "街並み")),
            ("cityscape", String(localized: "街並み")), ("skyline", String(localized: "街並み")), ("food", String(localized: "料理")), ("garden", String(localized: "庭")),
            ("park", String(localized: "公園")), ("field", String(localized: "野原")), ("desert", String(localized: "砂漠")), ("bridge", String(localized: "橋")),
            ("temple", String(localized: "寺社")), ("shrine", String(localized: "寺社")), ("animal", String(localized: "動物")), ("dog", String(localized: "犬")), ("cat", String(localized: "猫"))
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
            _ = await analyzer.analyze()
        }
        var result = observer.seconds
        for i in result.indices { result[i].loud = loud[i] }
        return result
    }
}
