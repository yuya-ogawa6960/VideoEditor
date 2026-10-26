import Foundation

// =====================================================================
// 要確認の字幕(字幕の一覧・タイムラインで赤い背景と「!」を出す)。
//
// - 聞き取りの自信が低い言葉: 音声認識(Apple・Whisper)が返す単語ごとの自信度が低かった言葉。
//   文字起こしのときに字幕へ記録し(doubtfulWords)、直してその言葉が文から消えれば出なくなる
// - よくある誤認識: 音声のない所で Whisper などが作りがちな定型文(「ご視聴ありがとうございました」など)
// - 前の字幕と同じ文 / 同じ文字の連続 / 表示が速すぎる・短すぎる
// 「問題なし」(issueDismissed)にした字幕は出さない。
// =====================================================================

enum CaptionIssue: Equatable {
    case doubtful([String])
    case commonMistake
    case repeated
    case repeatedCharacters
    case tooFast
    case tooShort

    /// 一覧に出す短い理由
    var message: String {
        switch self {
        case .doubtful(let words):
            let shown = words.prefix(2).joined(separator: "」「")
            return String(localized: "「\(shown)」の聞き取りに自信がありません")
        case .commonMistake: return String(localized: "よくある誤認識かもしれません")
        case .repeated: return String(localized: "前の字幕と同じです")
        case .repeatedCharacters: return String(localized: "同じ文字が続いています")
        case .tooFast: return String(localized: "表示が速すぎます")
        case .tooShort: return String(localized: "表示が短すぎます")
        }
    }
}

enum CaptionIssueCheck {
    /// これより自信度が低い言葉を要確認にする(0〜1)
    static let lowConfidence: Double = 0.4

    /// 音声のない所で出やすい定型文(認識結果と比べる文なので訳さない。1 行で書くと翻訳の抽出から外れる)
    private static let commonMistakes: [String] = "ご視聴ありがとうございました|チャンネル登録|高評価|字幕作成|字幕制作|thanks for watching|thank you for watching|subtitles by|amara.org".components(separatedBy: "|")

    /// 字幕ごとの要確認の理由(時刻順に並んだ字幕を渡す)
    static func issues(in cues: [SubtitleCue]) -> [UUID: CaptionIssue] {
        var result: [UUID: CaptionIssue] = [:]
        var previous: SubtitleCue?
        for cue in cues {
            if let issue = issue(for: cue, previous: previous) {
                result[cue.id] = issue
            }
            previous = cue
        }
        return result
    }

    static func issue(for cue: SubtitleCue, previous: SubtitleCue?) -> CaptionIssue? {
        guard !cue.issueDismissed else { return nil }
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let visible = visibleCharacters(text)

        let lowered = visible.lowercased()
        if commonMistakes.contains(where: { phrase in
            let target = visibleCharacters(phrase).lowercased()
            return lowered.contains(target) && visible.count <= target.count + 6
        }) {
            return .commonMistake
        }
        if let previous, visible.count >= 2, visibleCharacters(previous.text) == visible {
            return .repeated
        }
        let doubtful = cue.doubtfulWords.filter { containsWord($0, in: cue.text) }
        if !doubtful.isEmpty {
            return .doubtful(doubtful)
        }
        if hasLongRun(visible) {
            return .repeatedCharacters
        }
        let duration = cue.duration
        if duration < 0.3 {
            return .tooShort
        }
        // 1 秒あたりの文字数(英語などは文字が多いので基準を変える)
        let isMostlyLatin = visible.unicodeScalars.filter { $0.isASCII }.count * 2 > visible.unicodeScalars.count
        let limit: Double = isMostlyLatin ? 25 : 12
        if visible.count >= 6, Double(visible.count) / max(duration, 0.01) > limit {
            return .tooFast
        }
        return nil
    }

    /// 自信度の低いトークンを、時刻が重なり文に含まれる字幕へ「要確認の言葉」として記録する
    static func attachDoubtfulWords(_ cues: [SubtitleCue], tokens: [TimedToken]) -> [SubtitleCue] {
        let doubtful = tokens.compactMap { token -> (word: String, middle: Double)? in
            guard let confidence = token.confidence, confidence < lowConfidence else { return nil }
            // 前後の句読点は字幕にするときに変わるので外す
            let word = token.text.trimmingCharacters(in: ignored)
            guard isMeaningfulWord(word) else { return nil }
            return (word, (token.start + token.end) / 2)
        }
        guard !doubtful.isEmpty else { return cues }
        var result = cues
        for (word, middle) in doubtful {
            guard let index = result.firstIndex(where: {
                middle >= $0.start - 0.05 && middle <= $0.end + 0.05 && containsWord(word, in: $0.text)
            }) else { continue }
            if !result[index].doubtfulWords.contains(word) {
                result[index].doubtfulWords.append(word)
            }
        }
        return result
    }

    /// AI 仕上げで字幕が分かれたり作り直されたりしても、時刻の重なる元の字幕から要確認の言葉を引き継ぐ
    static func carryDoubtfulWords(from original: [SubtitleCue], to updated: [SubtitleCue]) -> [SubtitleCue] {
        let sources = original.filter { !$0.doubtfulWords.isEmpty }
        guard !sources.isEmpty else { return updated }
        return updated.map { cue in
            var result = cue
            for source in sources where source.start < cue.end && source.end > cue.start {
                for word in source.doubtfulWords where containsWord(word, in: cue.text) && !result.doubtfulWords.contains(word) {
                    result.doubtfulWords.append(word)
                }
            }
            return result
        }
    }

    /// 空白・句読点・記号(毎回作ると重いので 1 回だけ)
    private static let ignored = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    /// 空白・句読点・記号を除いた文字
    private static func visibleCharacters(_ text: String) -> String {
        String(text.unicodeScalars.filter { !ignored.contains($0) }.map(Character.init))
    }

    /// 要確認にしても意味のない短い言葉(助詞・助動詞・英語の機能語)
    private static let minorWords: Set<String> = SubtitleSegmenter.japaneseBreakParticles.union("です|でした|ます|ました|ません|ない|なく|だっ|だ|た|の|ね|よ|な|という|って|ちゃう|ちゃっ|けど|あの|その|この|えー|あー|まあ|the|and|you|for|are|was|but|not|that|this|with|have|it's|i'm".components(separatedBy: "|"))

    private static func isMeaningfulWord(_ word: String) -> Bool {
        let visible = visibleCharacters(word)
        guard visible.count >= 2, !minorWords.contains(word.lowercased()) else { return false }
        // 英語などは 3 文字以上だけ(in・to・it などを出さない)
        if visible.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return visible.count >= 3
        }
        return true
    }

    /// 文に言葉が含まれるか。英語などは単語の区切りで比べる(「in」が「thing」に当たらないように)
    static func containsWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        guard word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text.contains(word) }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: [.caseInsensitive], range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == text.endIndex || !text[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// 同じ文字が 6 つ以上続く(「ああああああ」など)
    private static func hasLongRun(_ text: String) -> Bool {
        var last: Character?
        var run = 0
        for character in text {
            if character == last {
                run += 1
                if run >= 6 { return true }
            } else {
                last = character
                run = 1
            }
        }
        return false
    }
}
