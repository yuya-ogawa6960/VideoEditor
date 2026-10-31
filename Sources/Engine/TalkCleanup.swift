import Foundation

// =====================================================================
// おまかせ編集の「話の整理」(AutoEditor.build のあとにかける)
//   - 話していない所 : 声の無い区間(HighlightAnalyzer の声の区間と字幕のどちらにも入らない所)を、
//                      前後 0.15 秒を残して詰める。0.6 秒未満の息つぎは切らない。
//                      雑音だけの所も「声が無い」とみなす(音量ではなく声の特徴で見るため)。
//   - 言いよどみ     : 「えー」「あのー」だけの所(FillerDetector)も詰める
//   - 言い直し       : 同じ出だしをすぐ(2.5 秒以内)にもう一度話していたら、前の回を捨てて最後の回だけ残す。
//                      字幕があれば言葉で比べる。無いときは「短い一言 → 間 → 長い話」の形だけで推測(自信は低い)
//   - 調べ物の場面   : 声の無い 2 秒以上の所。字幕で「調べ」「検索」などに触れていれば残し、
//                      カットの直後(場面の変わり目から 2 秒以内)も残す。切った所にはマーカー「調べ物をカット」を置く
// 時刻はすべて出力タイムラインの秒。実際に取り除くのは EditorProject.removeOutputRanges(CreatorTools.swift)。
// 切れ目は SpeechGuard の発話の中には置かない。
// =====================================================================

/// どれを詰めるか(AutoEditSettings から作る)
struct TalkCleanupOptions: Equatable {
    var cutNonSpeech = true
    var cutRetakes = true
    var cutLookups = false

    init(cutNonSpeech: Bool = true, cutRetakes: Bool = true, cutLookups: Bool = false) {
        self.cutNonSpeech = cutNonSpeech
        self.cutRetakes = cutRetakes
        self.cutLookups = cutLookups
    }

    init(settings: AutoEditSettings) {
        cutNonSpeech = settings.cutNonSpeech
        cutRetakes = settings.cutRetakes
        cutLookups = settings.cutLookups
    }

    var isEnabled: Bool { cutNonSpeech || cutRetakes || cutLookups }
}

/// 取り除く区間の一覧(出力タイムラインの秒)
struct TalkCleanupPlan {
    enum Reason: Equatable {
        /// 声の無い所
        case nonSpeech
        /// 言い直しの前の回
        case retake
        /// 言いよどみ(考えている間)
        case thinking
        /// 調べ物の場面
        case lookup
    }

    struct Cut: Equatable {
        var start: Double
        var end: Double
        var reason: Reason
        /// 字幕なしで形だけから推測した言い直し(当たりはずれがある)
        var lowConfidence = false
    }

    var cuts: [Cut] = []
    /// 調べ物らしいが、字幕で触れていたので残した数
    var keptLookupCount = 0

    var isEmpty: Bool { cuts.isEmpty }
    var nonSpeechCount: Int { cuts.filter { $0.reason == .nonSpeech }.count }
    var retakeCount: Int { cuts.filter { $0.reason == .retake }.count }
    var thinkingCount: Int { cuts.filter { $0.reason == .thinking }.count }
    var lookupCount: Int { cuts.filter { $0.reason == .lookup }.count }
    /// 取り除く合計秒(重なりはまとめる)
    var totalSeconds: Double {
        TalkCleanup.merged(cuts.map { (start: $0.start, end: $0.end) }).reduce(0.0) { $0 + ($1.end - $1.start) }
    }

    /// 画面に出す一言(例: 「話していない 12 か所・言い直し 2 か所を詰めました」)。何も無ければ nil
    var summaryText: String? {
        var parts: [String] = []
        if nonSpeechCount > 0 { parts.append(String(localized: "話していない \(nonSpeechCount) か所")) }
        if thinkingCount > 0 { parts.append(String(localized: "言いよどみ \(thinkingCount) か所")) }
        if retakeCount > 0 { parts.append(String(localized: "言い直し \(retakeCount) か所")) }
        if lookupCount > 0 { parts.append(String(localized: "調べ物 \(lookupCount) か所")) }
        guard !parts.isEmpty else { return nil }
        return String(localized: "\(parts.joined(separator: String(localized: "・")))を詰めました")
    }
}

enum TalkCleanup {
    /// 話の前後に残す余白(秒)
    static let speechPad = 0.15
    /// この間(秒)より短い声の切れ目は息つぎとみなして切らない
    static let joinGap = SpeechGuard.joinGap
    /// 余白を引いたあと、これ(秒)より短い所は詰めない
    static let minimumGap = 0.3
    /// 言い直しとみなす、前の回と後の回の間(秒)
    static let retakeGap = 2.5
    /// 出だしを比べる文字数
    static let retakeHeadLength = 12
    /// 出だしの似ている度合い(0...1)がこれ以上なら言い直し
    static let retakeSimilarity = 0.7
    /// 調べ物の場面とみなす、声の無い長さ(秒)
    static let lookupMinimum = 2.0
    /// カット(場面の変わり目)からこの秒数以内の調べ物は残す
    static let lookupSceneGrace = 2.0
    /// 前後この秒数の字幕に出てきたら、調べ物の場面を残す
    static let lookupTextReach = 3.0
    static let lookupKeywords = ["調べ", "検索", "見て", "ググ", "google", "地図", "マップ"]
    /// 出だしを比べる前に外す言いよどみ
    private static let leadingFillers = ["えーっと", "えーと", "えっと", "ええと", "あのー", "あのう", "うーん", "んーと", "えー", "んー", "umm", "um", "uh", "er"]
    private static let sentenceEnds = ["。", "！", "？", "!", "?", "."]

    /// ひとまとまりの話(出力タイムラインの秒)
    private struct Utterance {
        var start: Double
        var end: Double
        /// 字幕の言葉(無ければ空)
        var text: String
        var hasCueText: Bool { !text.isEmpty }
        var duration: Double { max(0, end - start) }
    }

    // MARK: - 計画

    /// 取り除く区間を決める(まだ何も変えない)。声の区間が無いクリップは先に音声を解析する
    static func plan(snapshot: ProjectSnapshot, subtitles: [SubtitleCue], options: TalkCleanupOptions,
                     progress: ((Double) -> Void)? = nil) async throws -> TalkCleanupPlan {
        var result = TalkCleanupPlan()
        guard options.isEnabled, !snapshot.clips.isEmpty else {
            progress?(1)
            return result
        }
        try await HighlightAnalyzer.ensureVoiceRuns(snapshot: snapshot) { fraction in
            progress?(0.9 * fraction)
        }
        try Task.checkCancellation()

        let layout = CompositionBuilder.timelineLayout(for: snapshot)
        let guardSpeech = SpeechGuard(snapshot: snapshot, pad: speechPad)
        let cues = subtitles.sorted { $0.start < $1.start }

        for (index, clip) in snapshot.clips.enumerated() where index < layout.count {
            try Task.checkCancellation()
            // 音の無いクリップ・写真・逆再生はそのまま(時間の対応が取りにくい)
            guard clip.hasAudio, !clip.isStill, !clip.isMuted, !clip.isReversed else { continue }
            let placement = layout[index]
            guard placement.end - placement.start > 1.0 else { continue }
            let talks = utterances(for: clip, placement: placement, cues: cues)
            // 声がまったく無いクリップは風景などの B ロールとみなして触らない
            guard !talks.isEmpty else { continue }

            // 1. 声の無い区間(前後 speechPad を残す)
            var gaps: [(start: Double, end: Double)] = []
            var cursor = placement.start
            for (i, talk) in talks.enumerated() {
                let a = (i == 0) ? placement.start : cursor + speechPad
                let b = talk.start - speechPad
                if b - a >= minimumGap { gaps.append((a, b)) }
                cursor = talk.end
            }
            if placement.end - (cursor + speechPad) >= minimumGap {
                gaps.append((cursor + speechPad, placement.end))
            }

            for gap in gaps {
                guard let tight = tightened(gap, clip: clip, index: index, placement: placement,
                                            guardSpeech: guardSpeech) else { continue }
                let length = tight.end - tight.start
                // 4. 調べ物の場面(声の無い 2 秒以上)
                if options.cutLookups, length >= lookupMinimum {
                    if mentionsLookup(cues, around: tight) {
                        // 字幕で触れている → 入れる価値があるので残す(「話していない所」としても切らない)
                        result.keptLookupCount += 1
                        continue
                    }
                    if tight.start - placement.start > lookupSceneGrace {
                        result.cuts.append(.init(start: tight.start, end: tight.end, reason: .lookup))
                        continue
                    }
                    // カットの直後は調べ物とは見ない(下の「話していない所」の扱いに任せる)
                }
                if options.cutNonSpeech {
                    result.cuts.append(.init(start: tight.start, end: tight.end, reason: .nonSpeech))
                }
            }

            // 2. 言い直し(前の回を捨てて最後の回だけ残す)
            if options.cutRetakes, talks.count >= 2 {
                for i in 0..<(talks.count - 1) {
                    let first = talks[i]
                    let second = talks[i + 1]
                    let gap = second.start - first.end
                    guard gap <= retakeGap else { continue }
                    var isRetake = false
                    var low = false
                    if first.hasCueText, second.hasCueText {
                        isRetake = looksLikeRetake(first: first.text, second: second.text)
                    } else if cues.isEmpty {
                        // 字幕なし: 「短い一言 → 間 → 長い話」の形だけで推測(当たりはずれがあるので短いときだけ)
                        isRetake = first.duration <= 1.5 && gap >= 0.4 && second.duration > first.duration + 0.5
                        low = true
                    }
                    guard isRetake else { continue }
                    // 字幕なしの推測は当たりはずれが大きいので、いまは切らない(後で「切る」を選べる設定にするかもしれない)
                    if low { continue }
                    let start = max(placement.start, first.start - speechPad)
                    let end = min(placement.end, second.start - speechPad)
                    guard end - start >= 0.1 else { continue }
                    result.cuts.append(.init(start: start, end: end, reason: .retake, lowConfidence: low))
                }
            }
        }

        // 3. 言いよどみ(字幕があるときだけ。cutFillers と同じ 0.03 秒の余白)
        if options.cutNonSpeech, !cues.isEmpty {
            for span in FillerDetector.spans(in: cues) {
                result.cuts.append(.init(start: max(0, span.start - 0.03), end: span.end + 0.03, reason: .thinking))
            }
        }

        result.cuts.sort { $0.start < $1.start }
        progress?(1)
        return result
    }

    // MARK: - 適用

    /// 区間を取り除き、調べ物を切った所にマーカーを置く。取り除けた合計秒を返す
    @MainActor
    @discardableResult
    static func apply(_ plan: TalkCleanupPlan, to project: EditorProject) -> Double {
        guard !plan.isEmpty else { return 0 }
        let ranges = plan.cuts.map { (start: max(0, $0.start), end: $0.end) }
        // マーカーの位置は取り除いたあとの時刻で先に出しておく(removeOutputRanges と同じ計算)
        let joined = merged(ranges)
        func shifted(_ t: Double) -> Double {
            var removedBefore = 0.0
            for r in joined {
                if t >= r.end { removedBefore += r.end - r.start }
                else if t > r.start { removedBefore += t - r.start }
            }
            return max(0, t - removedBefore)
        }
        let markerTimes = plan.cuts.filter { $0.reason == .lookup }.map { shifted($0.start) }
        let removed = project.removeOutputRanges(ranges)
        for time in markerTimes {
            project.markers.append(TimelineMarker(time: time, name: String(localized: "調べ物をカット"), kind: .note))
        }
        return removed
    }

    // MARK: - 部品

    /// 重なりをまとめた区間(開始順)
    static func merged(_ input: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        let sorted = input.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [(start: Double, end: Double)] = []
        for r in sorted {
            if var last = result.last, r.start <= last.end {
                last.end = max(last.end, r.end)
                result[result.count - 1] = last
            } else {
                result.append(r)
            }
        }
        return result
    }

    /// クリップの中の発話(声の区間と字幕をつなぎ、joinGap 未満の間は同じ話とみなす)。出力タイムラインの秒
    private static func utterances(for clip: Clip, placement: ClipPlacement, cues: [SubtitleCue]) -> [Utterance] {
        var spans: [(start: Double, end: Double)] = []
        let runs = HighlightAnalyzer.voiceRuns(for: clip.id)
        for run in runs {
            let lo = max(run.lowerBound, clip.startTime)
            let hi = min(run.upperBound, clip.endTime)
            guard hi > lo else { continue }
            let a = placement.start + ClipFXTimeline.outputOffset(sourceTime: lo, clip: clip)
            let b = min(placement.end, placement.start + ClipFXTimeline.outputOffset(sourceTime: hi, clip: clip))
            if b > a { spans.append((a, b)) }
        }
        // 字幕は真ん中がクリップの中にあるものだけ数える(ディゾルブの重なりや、クリップの端をまたぐだけの字幕は数えない)
        let inClip = cues.filter { cue in
            let mid = (cue.start + cue.end) / 2
            return mid >= placement.start && mid < placement.end
        }
        // 声の区間も、クリップの中に収まる字幕も無ければ、風景などの B ロールとみなして触らない
        if runs.isEmpty, inClip.isEmpty { return [] }
        for cue in inClip {
            let a = max(placement.start, cue.start)
            let b = min(placement.end, cue.end)
            if b > a { spans.append((a, b)) }
        }
        var joined: [(start: Double, end: Double)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if var last = joined.last, span.start <= last.end + joinGap {
                last.end = max(last.end, span.end)
                joined[joined.count - 1] = last
            } else {
                joined.append(span)
            }
        }
        return joined.map { span in
            Utterance(start: span.start, end: span.end, text: text(of: inClip, between: span.start, and: span.end))
        }
    }

    /// 発話に入る字幕の言葉。単語の時刻があれば単語ごとに、無ければ字幕の真ん中で振り分ける
    private static func text(of cues: [SubtitleCue], between start: Double, and end: Double) -> String {
        var pieces: [String] = []
        for cue in cues {
            if !cue.words.isEmpty {
                let words = cue.words.filter { word in
                    let mid = (word.start + word.end) / 2
                    return mid >= start - 0.1 && mid <= end + 0.1
                }
                if !words.isEmpty {
                    pieces.append(words.map { $0.text }.joined())
                }
            } else {
                let mid = (cue.start + cue.end) / 2
                if mid >= start - 0.1 && mid <= end + 0.1 {
                    pieces.append(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return pieces.filter { !$0.isEmpty }.joined()
    }

    /// 区間の両端が話の途中なら、話の外まで寄せる。短くなりすぎたら nil
    private static func tightened(_ gap: (start: Double, end: Double), clip: Clip, index: Int,
                                  placement: ClipPlacement, guardSpeech: SpeechGuard) -> (start: Double, end: Double)? {
        var a = gap.start
        var b = gap.end
        let sourceA = clip.sourceTime(atOutputOffset: a - placement.start)
        if guardSpeech.isInsideSpeech(sourceA, clip: index) {
            let safe = guardSpeech.safeEnd(sourceA, clip: index, upper: clip.endTime)
            a = placement.start + ClipFXTimeline.outputOffset(sourceTime: safe, clip: clip)
        }
        let sourceB = clip.sourceTime(atOutputOffset: b - placement.start)
        if guardSpeech.isInsideSpeech(sourceB, clip: index) {
            let safe = guardSpeech.retreatToSafe(sourceB, clip: index)
            b = placement.start + ClipFXTimeline.outputOffset(sourceTime: safe, clip: clip)
        }
        a = max(a, placement.start)
        b = min(b, placement.end)
        return b - a >= minimumGap ? (a, b) : nil
    }

    /// 前後 lookupTextReach 秒の字幕に「調べ」「検索」などが出てくるか
    private static func mentionsLookup(_ cues: [SubtitleCue], around gap: (start: Double, end: Double)) -> Bool {
        for cue in cues where cue.end >= gap.start - lookupTextReach && cue.start <= gap.end + lookupTextReach {
            let text = cue.text.lowercased()
            if lookupKeywords.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - 言い直しの判定

    /// 前の回(first)のあとに、同じ出だしの後の回(second)が来ているか
    static func looksLikeRetake(first: String, second: String) -> Bool {
        let fullA = stripLeadingFillers(FillerDetector.normalize(first))
        let fullB = stripLeadingFillers(FillerDetector.normalize(second))
        guard fullA.count >= 2, fullB.count >= 2 else { return false }
        // 前の回が文として終わっていて、後の回より長いなら、ただ似た話を続けただけ
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsSentence = sentenceEnds.contains { trimmed.hasSuffix($0) }
        guard !endsSentence || fullA.count < fullB.count else { return false }
        if fullB.hasPrefix(fullA) { return true }
        let headA = String(fullA.prefix(retakeHeadLength))
        let headB = String(fullB.prefix(retakeHeadLength))
        return similarity(headA, headB) >= retakeSimilarity
    }

    private static func stripLeadingFillers(_ text: String) -> String {
        var s = text
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where s.hasPrefix(filler) && s.count > filler.count {
                s = String(s.dropFirst(filler.count))
                changed = true
            }
        }
        return s
    }

    /// 似ている度合い(1 − 編集距離 ÷ 長い方の文字数)。0...1
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a)
        let y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }
}
