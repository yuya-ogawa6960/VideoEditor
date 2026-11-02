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
// ここでは、重なる同じ単語(removeDuplicateTokens)・続く同じ文(mergeDuplicates)・短い定型文(removeHallucinations)を
// 取り除き、重なりは次の字幕を後ろへずらして解消する(resolveOverlaps)。
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
    /// これより短い定型文は誤認識として捨てる(秒)
    static let hallucinationMaxDuration: Double = 0.5
    /// 字幕どうしの最小の間(秒)
    static let minimumGap: Double = 0.05
    /// 字幕の最短表示(秒)
    static let minimumDuration: Double = 0.2
    /// 同じ単語が時間でこれ以上重なっていたら、同じ音声をもう一度認識したものとみなす(短い方の長さに対する比)
    static let tokenOverlapRatio: Double = 0.5

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
    /// ごく短いもの、またはほかの字幕と時間が重なるものを捨てる。
    /// 長くて重ならないもの(本当に言ったかもしれない)は残し、これまでどおり要確認として見せる
    static func removeHallucinations(_ cues: [SubtitleCue]) -> (cues: [SubtitleCue], removed: Int) {
        let sorted = sortedByStart(cues)
        var result: [SubtitleCue] = []
        result.reserveCapacity(sorted.count)
        var removed = 0
        for (index, cue) in sorted.enumerated() {
            guard CaptionIssueCheck.isCommonMistake(cue.text) else {
                result.append(cue)
                continue
            }
            let overlapsPrevious = index > 0 && sorted[index - 1].end > cue.start + minimumGap
            let overlapsNext = index + 1 < sorted.count && sorted[index + 1].start < cue.end - minimumGap
            if cue.duration < hallucinationMaxDuration || overlapsPrevious || overlapsNext {
                removed += 1
            } else {
                result.append(cue)
            }
        }
        return (result, removed)
    }

    /// 前の字幕と同じ文(空白・句読点を除いて比べる)が、重なるか duplicateGap 秒以内に続いていたらひとつにする。
    /// 時刻は前の始まり〜遅い方の終わり。単語の時刻・要確認の言葉は前の字幕のものを使う
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
                if end > limit {
                    let newStart = end + minimumGap
                    sorted[i + 1].end = max(sorted[i + 1].end, newStart + minimumDuration)
                    sorted[i + 1].start = newStart
                    sorted[i + 1].words = SubtitleSegmenter.clampWords(sorted[i + 1].words,
                                                                        start: newStart, end: sorted[i + 1].end)
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

    // MARK: - トークン

    /// 同じ単語が時間で大きく重なって 2 回出ていたら、あとの方を捨てる(Whisper が同じ音声を 2 度書き出したもの)。
    /// 時刻順に並べて返す
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
            let isDuplicate = !text.isEmpty && result.suffix(12).contains { kept in
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
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        if shorter <= 0.001 {
            // 長さのない単語は、始まりがほぼ同じなら同じもの
            return abs(a.start - b.start) <= 0.05
        }
        return overlap >= shorter * tokenOverlapRatio
    }

    // MARK: - 文の比べ方

    /// 同じ文か(空白・句読点・記号を除き、大文字小文字を区別しない。1 文字の文は比べない)
    static func isSameText(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedText(lhs)
        guard a.count >= 2 else { return false }
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
