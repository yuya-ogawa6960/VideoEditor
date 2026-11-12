import Foundation

// =====================================================================
// 文字起こしの結果の掃除(純粋関数。Foundation だけに依存し、Tests/CaptionCleanup のスクリプトで Linux でも検査できる)。
//
// 31 分の動画で「おはようございます」「12時39分です」が 2 回続く、「ご視聴ありがとうございました」が 0.2 秒だけ出て
// 次の字幕と重なる、といった字幕ができていた(1.12.72〜1.12.76)。原因は 3 つ:
//   1. Whisper は 30 秒の窓で認識するので、窓の継ぎ目で同じ言葉をもう一度書き出すことがある(時刻は重なるか直後)
//   2. 音声のない所で「ご視聴ありがとうございました」などの定型文を作り出す(ごく短いか、本当の字幕と重なる)
//   3. 同時に始まる 2 つの字幕があると、前の字幕を 0.2 秒に縮めるだけだったので、重なったまま残っていた
//      (TranscriptionService.finalize と SubtitleSegmenter.adjustTiming)
// 1.12.106 までは、Whisper が書き出す音の注釈「(音楽)」「(笑)」「(一同)」の開き括弧が日本語では単語 1 つとして出て、
// SubtitleSegmenter が前の単語に付けていたので、「音楽)」「楽)」「一同)」のような字幕が残っていた(removeSoundAnnotations)。
// 動画の途中の 1〜2 秒の「ご視聴ありがとうございました」も残っていた(removeHallucinations の締めの定型文)
// ここでは、重なる同じ単語(removeDuplicateTokens)・続く同じ文(mergeDuplicates)・短い定型文(removeHallucinations)を
// 取り除き、重なりは次の字幕を後ろへずらして解消する(resolveOverlaps)。
// 本当の繰り返し(笑い声の「ハ」「ハ」「ハ」、長さ 0 で並ぶ「20」「20」、「すごい！」「すごい！」)は消さないよう、
// 1 文字の単語・長さの無い単語・4 文字未満の短い文は比べない。
// resolveOverlaps は SubtitleSegmenter.segment() の中では使わない。定型文を捨てる前にずらすと、同時に始まる本当の字幕が
// 後ろへずれてしまうため(clean() が定型文を捨ててから解消し、TranscriptionService.finalize が仕上げのあとにもう一度解消する)
// =====================================================================

enum CaptionCleanup {
    /// 取り除いた数(完了の表示に出す)
    struct Report: Equatable {
        /// 同じ文が続いていたのでひとつにした数
        var duplicates = 0
        /// 音声のない所の定型文として捨てた数
        var hallucinations = 0

        var total: Int { duplicates + hallucinations }
    }

    /// 続く同じ文を同じものとみなす、前の終わりから次の始まりまでの最大の間(秒)
    static let duplicateGap: Double = 0.5
    /// 続く同じ文をひとつにするのは、空白・句読点を除いてこの文字数以上の文だけ
    /// (「すごい！」「すごい！」「やばい！」「やばい！」のような短い本当の繰り返しは残す)
    static let duplicateMinimumLength = 4
    /// これより短い定型文は誤認識として捨てる(秒)
    static let hallucinationMaxDuration: Double = 0.5
    /// 締めの定型文(「ご視聴ありがとうございました」など)は、字幕の最後からこの秒数より前にあれば長くても捨てる
    static let outroWindow: Double = 30
    /// 音の注釈とみなす括弧の中身の最大の文字数(これを超えても閉じなければ注釈とみなさず、開き括弧だけを消す)
    static let annotationMaxLength = 12
    /// 字幕どうしの最小の間(秒)
    static let minimumGap: Double = 0.05
    /// 字幕の最短表示(秒)
    static let minimumDuration: Double = 0.2
    /// 同じ単語が時間でこれ以上重なっていたら、同じ音声をもう一度認識したものとみなす(短い方の長さに対する比)
    static let tokenOverlapRatio: Double = 0.5
    /// 同じ単語として比べるのは、空白・句読点を除いてこの文字数以上の単語だけ(「ハ」「ハ」「ハ」のような 1 文字の繰り返しは残す)
    static let tokenMinimumLength = 2

    // MARK: - 字幕

    /// 定型文を捨て、続く同じ文をひとつにし、重なりを解消する
    static func clean(_ cues: [SubtitleCue]) -> (cues: [SubtitleCue], report: Report) {
        var report = Report()
        let sorted = sortedByStart(cues)
        let (withoutHallucinations, hallucinations) = removeHallucinations(sorted)
        report.hallucinations = hallucinations
        let (merged, duplicates) = mergeDuplicates(withoutHallucinations)
        report.duplicates = duplicates
        return (resolveOverlaps(merged), report)
    }

    /// 音声のない所で Whisper などが作りがちな定型文(CaptionIssueCheck.commonMistakes)のうち、
    /// ごく短いもの、またはほかの字幕と時間が重なるもの、締めの定型文で最後の outroWindow 秒より前にあるものを捨てる。
    /// 長くて重ならないもの(本当に言ったかもしれない)は残し、これまでどおり要確認として見せる
    static func removeHallucinations(_ cues: [SubtitleCue]) -> (cues: [SubtitleCue], removed: Int) {
        let sorted = sortedByStart(cues)
        var result: [SubtitleCue] = []
        result.reserveCapacity(sorted.count)
        var removed = 0
        let lastEnd = sorted.map { $0.end }.max() ?? 0
        for (index, cue) in sorted.enumerated() {
            guard CaptionIssueCheck.isCommonMistake(cue.text) else {
                result.append(cue)
                continue
            }
            let overlapsPrevious = index > 0 && sorted[index - 1].end > cue.start + minimumGap
            let overlapsNext = index + 1 < sorted.count && sorted[index + 1].start < cue.end - minimumGap
            // 動画の途中で「ご視聴ありがとうございました」とは言わない(音楽や雑音の所で Whisper が作る)
            let outroInMiddle = CaptionIssueCheck.isOutroMistake(cue.text) && cue.end < lastEnd - outroWindow
            if cue.duration < hallucinationMaxDuration || overlapsPrevious || overlapsNext || outroInMiddle {
                removed += 1
            } else {
                result.append(cue)
            }
        }
        return (result, removed)
    }

    /// 前の字幕と同じ文(空白・句読点を除いて比べる。duplicateMinimumLength 文字以上の文だけ)が、
    /// 重なるか duplicateGap 秒以内に続いていたらひとつにする。
    /// 時刻は前の始まり〜遅い方の終わり。文と、単語ごとの時刻は前の字幕のものを使う。要確認の言葉は両方を合わせる
    static func mergeDuplicates(_ cues: [SubtitleCue]) -> (cues: [SubtitleCue], removed: Int) {
        var result: [SubtitleCue] = []
        result.reserveCapacity(cues.count)
        var removed = 0
        for cue in sortedByStart(cues) {
            if let last = result.last, isSameText(last.text, cue.text), cue.start - last.end <= duplicateGap {
                var merged = last
                merged.end = max(last.end, cue.end)
                for word in cue.doubtfulWords where !merged.doubtfulWords.contains(word) {
                    merged.doubtfulWords.append(word)
                }
                merged.issueDismissed = last.issueDismissed && cue.issueDismissed
                // 取り除いた言いよどみ(言いよどみカットの候補)は両方のものを残す
                if let fillers = cue.removedFillers {
                    var record = merged.removedFillers ?? RemovedSubtitleFillers(words: [], cueStart: merged.start, cueEnd: merged.end)
                    record.words.append(contentsOf: fillers.words)
                    merged.removedFillers = record
                }
                syncRemovedFillers(&merged)
                result[result.count - 1] = merged
                removed += 1
            } else {
                result.append(cue)
            }
        }
        return (result, removed)
    }

    /// 時刻順に並べ、重なりを解消する。前の字幕の終わりを次の始まりの minimumGap 秒前まで縮め、
    /// それでは minimumDuration 秒より短くなるとき(同時に始まる 2 つの字幕)は、次の字幕を後ろへずらす
    static func resolveOverlaps(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var sorted = sortedByStart(cues)
        guard sorted.count > 1 else { return sorted }
        // 次をずらすと、その次との順番が入れ替わることがあるので、並べ直して繰り返す(通常は 1 回で終わる)
        for _ in 0..<8 {
            var shifted = false
            for i in 0..<(sorted.count - 1) {
                let limit = sorted[i + 1].start - minimumGap
                guard sorted[i].end > limit else { continue }
                let end = max(sorted[i].start + minimumDuration, limit)
                sorted[i].end = end
                sorted[i].words = SubtitleSegmenter.clampWords(sorted[i].words, start: sorted[i].start, end: end)
                syncRemovedFillers(&sorted[i])
                if end > limit {
                    let newStart = end + minimumGap
                    sorted[i + 1].end = max(sorted[i + 1].end, newStart + minimumDuration)
                    sorted[i + 1].start = newStart
                    sorted[i + 1].words = SubtitleSegmenter.clampWords(sorted[i + 1].words,
                                                                        start: newStart, end: sorted[i + 1].end)
                    syncRemovedFillers(&sorted[i + 1])
                    shifted = true
                }
            }
            guard shifted else { break }
            let reordered = sortedByStart(sorted)
            if reordered == sorted { break }
            sorted = reordered
        }
        return sorted
    }

    /// 字幕の表示の時刻だけを直したとき、取り除いた言いよどみの記録(RemovedSubtitleFillers)の字幕の時刻も今の値にする。
    /// 音声は動いていないので、言いよどみの時刻はそのまま言いよどみカットの候補に使える
    /// (記録の時刻が字幕と違うと、FillerDetector はタイムラインを編集したものとみなして使わない)
    private static func syncRemovedFillers(_ cue: inout SubtitleCue) {
        guard var record = cue.removedFillers else { return }
        record.cueStart = cue.start
        record.cueEnd = cue.end
        cue.removedFillers = record
    }

    // MARK: - トークン

    /// 音の注釈の開き括弧 → 閉じ括弧
    private static let annotationBrackets: [Character: Set<Character>] = [
        "(": [")", "）"], "（": ["）", ")"], "[": ["]", "］"], "［": ["］", "]"], "【": ["】"], "〔": ["〕"],
    ]
    private static let annotationClosers: Set<Character> = [")", "）", "]", "］", "】", "〕"]

    /// Whisper が書き出す音の注釈「(音楽)」「(笑)」「(拍手)」「(一同)」「[音楽]」と「♪」を取り除く(時刻順のトークンを渡す)。
    /// 日本語では開き括弧が単語 1 つとして出てくることがあり、括弧の中身が離れた単語に分かれていても(「(」「音」…「楽)」)、
    /// 続くトークンの文字をつなげて閉じ括弧まで消す。
    /// 中身が annotationMaxLength 文字を超えても閉じないときは注釈とみなさず、開き括弧だけを消す。
    /// 開き括弧の無い閉じ括弧(前のピースで開いていたもの)は、そのトークンの頭から閉じ括弧までを消す。
    /// 文字が消えて空になったトークンは捨てる(もともと句読点だけのトークンはそのまま残す)
    static func removeSoundAnnotations(_ tokens: [TimedToken]) -> [TimedToken] {
        guard tokens.contains(where: { token in
            token.text.contains { annotationBrackets[$0] != nil || annotationClosers.contains($0) || $0 == "♪" }
        }) else { return tokens }
        var chars: [Character] = []
        var owner: [Int] = []
        for (index, token) in tokens.enumerated() {
            for c in token.text {
                chars.append(c)
                owner.append(index)
            }
        }
        var remove = [Bool](repeating: false, count: chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "♪" {
                remove[i] = true
                i += 1
                continue
            }
            if let closers = annotationBrackets[c] {
                var found: Int? = nil
                var j = i + 1
                while j < chars.count, j - i - 1 <= annotationMaxLength {
                    if closers.contains(chars[j]) {
                        found = j
                        break
                    }
                    // 中でまた開いたら、ここまでは注釈ではない
                    if annotationBrackets[chars[j]] != nil { break }
                    j += 1
                }
                if let found {
                    for k in i...found { remove[k] = true }
                    i = found + 1
                } else {
                    remove[i] = true
                    i += 1
                }
                continue
            }
            if annotationClosers.contains(c) {
                // 開き括弧の無い閉じ括弧: そのトークンの頭から消す(「楽)」「一同)」)
                var k = i
                while k >= 0, owner[k] == owner[i] {
                    remove[k] = true
                    k -= 1
                }
            }
            i += 1
        }
        var result: [TimedToken] = []
        result.reserveCapacity(tokens.count)
        var cursor = 0
        for token in tokens {
            let count = token.text.count
            var text = ""
            var changed = false
            for offset in 0..<count {
                if remove[cursor + offset] {
                    changed = true
                } else {
                    text.append(chars[cursor + offset])
                }
            }
            cursor += count
            guard changed else {
                result.append(token)
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var kept = token
            kept.text = trimmed
            result.append(kept)
        }
        return result
    }

    /// 同じ単語が時間で大きく重なって 2 回出ていたら、あとの方を捨てる(Whisper が同じ音声を 2 度書き出したもの)。
    /// 1 文字の単語・長さの無い単語は比べない(本当に続けて言ったものと見分けられない)。時刻順に並べて返す
    static func removeDuplicateTokens(_ tokens: [TimedToken]) -> [TimedToken] {
        let sorted = tokens.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            return lhs.offset < rhs.offset
        }.map { $0.element }
        var result: [TimedToken] = []
        result.reserveCapacity(sorted.count)
        for token in sorted {
            let text = normalizedText(token.text)
            // 直前の数個とだけ比べる(重なるのは近くの単語だけ)
            let isDuplicate = text.count >= tokenMinimumLength && result.suffix(12).contains { kept in
                normalizedText(kept.text) == text && overlapsMostly(kept, token)
            }
            if !isDuplicate {
                result.append(token)
            }
        }
        return result
    }

    private static func overlapsMostly(_ a: TimedToken, _ b: TimedToken) -> Bool {
        let shorter = min(a.end - a.start, b.end - b.start)
        if shorter <= 0.001 {
            // 長さのない単語は重なりで見分けられないので、同じものとはみなさない
            // (Whisper の単語時刻では、続けて言った「20」「20」が同じ時刻・長さ 0 で並ぶことがある)
            return false
        }
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        return overlap >= shorter * tokenOverlapRatio
    }

    // MARK: - 文の比べ方

    /// 同じ文か(空白・句読点・記号を除き、大文字小文字を区別しない。duplicateMinimumLength 文字より短い文は比べない)
    static func isSameText(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedText(lhs)
        guard a.count >= duplicateMinimumLength else { return false }
        return a == normalizedText(rhs)
    }

    /// 空白・句読点・記号を除いて小文字にした文
    static func normalizedText(_ text: String) -> String {
        String(text.unicodeScalars.filter { !ignored.contains($0) }.map(Character.init)).lowercased()
    }

    private static let ignored = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    /// 始まりの早い順(同じ始まりは元の順を保つ)
    static func sortedByStart(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }
}
