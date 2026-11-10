import Foundation
import AVFoundation
import Vision

// =====================================================================
// おまかせ編集の「話の整理」(AutoEditor.build のあとにかける)
//   - 話していない所 : 声の無い区間(HighlightAnalyzer の声の区間と字幕のどちらにも入らない所)を、
//                      前後 0.15 秒を残して詰める。0.6 秒未満の息つぎは切らない。
//                      雑音だけの所も「声が無い」とみなす(音量ではなく声の特徴で見るため)。
//   - 言いよどみ     : 「えー」「あのー」だけの所(FillerDetector)も詰める
//   - 言い直し       : 同じ出だしをすぐ(2.5 秒以内)にもう一度話していたら、前の回を捨てて最後の回だけ残す。
//                      字幕があれば言葉で比べる。無いときは「短い一言 → 間 → 長い話」の形だけで推測(自信は低い)
//   - 景色の場面     : 声が無くても、顔が映っていない(景色を撮っている)所は切らずに残す
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
    /// 声は無いが景色を撮っていたので残した数
    var keptSceneryCount = 0

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
    /// これより長く話した前の回は言い直しとして切らない(秒)
    static let retakeMaxFirst = 4.0
    /// これ以上の声の無い所は、顔が映っていなければ景色として残す(秒)
    static let sceneryMinimum = 1.0
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
        // ナレーション・効果音が鳴っている所(「話していない所」として詰めない。無音カットと同じ)
        let busy = EditorProject.narrationBusyRanges(snapshot.narration)

        for (index, clip) in snapshot.clips.enumerated() where index < layout.count {
            try Task.checkCancellation()
            // 音の無いクリップ・写真・逆再生はそのまま(時間の対応が取りにくい)
            guard clip.hasAudio, !clip.isStill, !clip.isMuted, !clip.isReversed else { continue }
            let placement = layout[index]
            guard placement.end - placement.start > 1.0 else { continue }
            let talks = utterances(for: clip, placement: placement, cues: cues)
            // 声がまったく無いクリップは風景などの B ロールとみなして触らない
            guard !talks.isEmpty else { continue }
            // トランジションで前後のクリップと重なる所(removeOutputRanges の扱い): 前のクリップの終わりと後ろのクリップの頭が
            // どちらも話していないときだけ、重なりごと詰める。そのときも話の前後には重なりの長さぶんの余白を残す
            // (重なりの中に声が入ると、前の文末と次の文頭がディゾルブの中で重なってフェードし、字幕もつなぎ目ごとに遅れていた)。
            // 片方だけが話していないときは、重なりの 2 倍は切られずに残る
            let inOverlap = index > 0 ? max(0, layout[index - 1].end - placement.start) : 0
            let outOverlap = index + 1 < layout.count ? max(0, placement.end - layout[index + 1].start) : 0

            // 1. 声の無い区間(前後 speechPad を残す)
            var gaps: [(start: Double, end: Double)] = []
            var cursor = placement.start
            for (i, talk) in talks.enumerated() {
                let a = (i == 0) ? placement.start : cursor + speechPad
                let b = talk.start - speechPad - (i == 0 ? inOverlap : 0)
                if b - a >= minimumGap { gaps.append((a, b)) }
                cursor = talk.end
            }
            let tailStart = cursor + speechPad + outOverlap
            if placement.end - tailStart >= minimumGap {
                gaps.append((tailStart, placement.end))
            }
            gaps = EditorProject.subtracting(busy, from: gaps, minimumLength: minimumGap)

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
                    // 景色の場面(1 秒以上、顔が映っていない)は話していなくても残す
                    // (調べ物は手元だけ映っていることが多いので、上の調べ物の判定を先にする)
                    if length >= sceneryMinimum {
                        try Task.checkCancellation()
                        let a = clip.sourceTime(atOutputOffset: tight.start - placement.start)
                        let b = clip.sourceTime(atOutputOffset: tight.end - placement.start)
                        let hasFace = await showsFace(url: clip.url, from: min(a, b), to: max(a, b))
                        if !hasFace {
                            result.keptSceneryCount += 1
                            continue
                        }
                    }
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
                    // 長く話した前の回は、言い直しでも中身があるので残す(大事な言い直し)
                    guard first.duration <= retakeMaxFirst else { continue }
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
                    // 前の回の頭がトランジションの重なりの近く(重なりの 2 倍)なら切らない
                    // (そこは切られずに残るので、言いかけの頭だけが残ってしまう)
                    guard first.start - speechPad >= placement.start + 2 * inOverlap - 0.001 else { continue }
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

    /// 区間を取り除き、調べ物・言い直しを切った所にマーカーを置く。実際に短くなった秒を返す
    @MainActor
    @discardableResult
    static func apply(_ plan: TalkCleanupPlan, to project: EditorProject) -> Double {
        guard !plan.isEmpty else { return 0 }
        let ranges = plan.cuts.map { (start: max(0, $0.start), end: $0.end) }
        // マーカーは切る所の頭に先に置いておく(removeOutputRanges が消さずに詰めた先へ寄せる)。
        // 言い直しは当たりはずれがあるので、どこを切ったか分かるように印を残す(対談で相手の受け答えを切っていないか確かめられる)
        for cut in plan.cuts where cut.reason == .lookup || cut.reason == .retake {
            let name = cut.reason == .lookup ? String(localized: "調べ物をカット") : String(localized: "言い直しをカット")
            project.markers.append(TimelineMarker(time: max(0, cut.start), name: name, kind: .note))
        }
        let removed = project.removeOutputRanges(ranges)
        project.sortMarkers()
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
        // 前の回がそれだけで文として終わっている(「そうなんですよ」「よろしくお願いします。」)なら、言い直しではなく
        // 対談で相手が同じ言葉で受けたか、同じ話を続けただけ(前の人の発言を丸ごと切っていた)
        guard !endsAsSentence(trimmed) else { return false }
        if fullB.hasPrefix(fullA) { return true }
        // 前の回が、後の回の出だしをほぼそのまま言いかけただけのときだけ(出だしが同じでも、違う中身を話していたら残す)
        guard fullA.count <= fullB.count else { return false }
        let headA = String(fullA.prefix(retakeHeadLength))
        let headB = String(fullB.prefix(retakeHeadLength))
        guard similarity(headA, headB) >= retakeSimilarity else { return false }
        return similarity(fullA, String(fullB.prefix(fullA.count))) >= retakeSimilarity
    }

    /// 文末の形(句点が無い認識結果でも文が終わっていると分かる形)。後ろに「ね」「よ」「か」が付いた形も文末
    private static let sentenceEndings = ["ございます", "ます", "ました", "ません", "ましょう", "です", "でした", "でしょう", "ください"]
    private static let sentenceEndingParticles = ["ね", "よ", "よね", "か", "かね", "よな", "な"]

    /// それだけで文として終わっている一言か。句点の有無ではなく文末の形で見る(認識結果に句点が無いことも、
    /// 言いかけに句点が付くこともある)。「！」「？」で終わる言葉も終わっているとみなす。読点で終わる言いかけは終わっていない
    static func endsAsSentence(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "」』）)\"”’'】〕".contains(last) { t.removeLast() }
        guard let last = t.last else { return false }
        if "！？!?‼⁉".contains(last) { return true }
        if "、，,；;：:".contains(last) { return false }
        let hasJapanese = t.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        // 英語など: 句点で終わっていれば文として終わっている
        if !hasJapanese { return ".…".contains(last) }
        var core = t
        while let c = core.last, "。．.…ー〜～ 　".contains(c) { core.removeLast() }
        for ending in sentenceEndings {
            if core.hasSuffix(ending) { return true }
            for particle in sentenceEndingParticles where core.hasSuffix(ending + particle) { return true }
        }
        return false
    }

    // MARK: - 景色の場面

    /// 区間(元素材上の秒)のはじめ・なか・おわりのどれかに顔が映っているか。読めなければ true(切ってよい扱い)
    private static func showsFace(url: URL, from start: Double, to end: Double) async -> Bool {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let span = max(0, end - start)
        let times = [start + span * 0.2, start + span * 0.5, start + span * 0.8]
        var readAny = false
        for t in times {
            guard let image = try? await generator.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image else {
                continue
            }
            readAny = true
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            // 小さすぎる顔(遠くの通行人など)は数えない
            if let faces = request.results, faces.contains(where: { $0.boundingBox.height >= 0.08 }) {
                return true
            }
        }
        return !readAny
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
