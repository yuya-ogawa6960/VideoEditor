import Foundation

// =====================================================================
// CaptionCleanup の検査(XCTest を使わない小さな本体。run.sh でコンパイルして実行する)。
// 1.12.76 までの不具合(31 分の動画で同じ文が 2 回続く・0.2 秒の「ご視聴ありがとうございました」が次の字幕と重なる)
// を再現する入力で、取り除かれること・重なりが残らないことを確かめる
// =====================================================================

@main
struct CaptionCleanupTests {
    static var failures = 0
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL \(URL(fileURLWithPath: file).lastPathComponent):\(line): \(message)")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                                          file: String = #file, line: Int = #line) {
        expect(actual == expected, "\(message) — got \(actual), expected \(expected)", file: file, line: line)
    }

    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.0001) -> Bool { abs(a - b) <= tolerance }

    static func cue(_ start: Double, _ end: Double, _ text: String, words: Bool = false) -> SubtitleCue {
        var result = SubtitleCue(start: start, end: end, text: text)
        if words {
            let middle = (start + end) / 2
            result.words = [SubtitleWord(text: String(text.prefix(2)), start: start, end: middle),
                            SubtitleWord(text: String(text.dropFirst(2)), start: middle, end: end)]
        }
        return result
    }

    /// 重なりが無く、時刻順で、どれも minimumDuration 以上か
    static func hasNoOverlap(_ cues: [SubtitleCue]) -> Bool {
        for i in cues.indices {
            if cues[i].end - cues[i].start < CaptionCleanup.minimumDuration - 0.0001 { return false }
            if i + 1 < cues.count, cues[i].end > cues[i + 1].start - CaptionCleanup.minimumGap + 0.0001 { return false }
        }
        return true
    }

    static func main() {
        testCommonMistakeMatching()
        testHallucinationsRemoved()
        testDuplicatesMerged()
        testOverlapsResolved()
        testDuplicateTokens()
        testReportedScenario()
        testSortIsStable()
        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            exit(1)
        }
    }

    // MARK: 定型文

    static func testCommonMistakeMatching() {
        expect(CaptionIssueCheck.isCommonMistake("ご視聴ありがとうございました"), "定型文そのもの")
        expect(CaptionIssueCheck.isCommonMistake("ご視聴ありがとうございました。"), "句点付き")
        expect(CaptionIssueCheck.isCommonMistake("Thanks for watching!"), "英語・大文字小文字と記号")
        expect(CaptionIssueCheck.isCommonMistake("チャンネル登録お願いします"), "少し付いていても定型文")
        expect(!CaptionIssueCheck.isCommonMistake("今日は皆さんにご視聴ありがとうございましたと伝えたくて動画を撮りました"),
               "長い文の中に含まれるだけなら定型文ではない")
        expect(!CaptionIssueCheck.isCommonMistake("おはようございます"), "ふつうの文")
        expect(!CaptionIssueCheck.isCommonMistake("   "), "空")
    }

    static func testHallucinationsRemoved() {
        let input = [
            cue(0.0, 2.0, "おはようございます"),
            cue(306.2, 306.4, "ご視聴ありがとうございました"),      // 0.2 秒 → 捨てる
            cue(306.45, 310.0, "今日は天気がいいですね"),
            cue(320.0, 330.0, "ご視聴ありがとうございました"),      // 長くて重ならない → 残す(要確認のまま)
            cue(340.0, 346.0, "ご視聴ありがとうございました"),      // 長いが次と重なる → 捨てる
            cue(340.5, 343.0, "次の話題です"),
        ]
        let (result, removed) = CaptionCleanup.removeHallucinations(input)
        expectEqual(removed, 2, "0.2 秒のものと重なるものを捨てる")
        expectEqual(result.map { $0.text },
                    ["おはようございます", "今日は天気がいいですね", "ご視聴ありがとうございました", "次の話題です"],
                    "残る字幕")
        expect(near(result[2].start, 320.0), "長くて重ならない定型文は残す")

        // 定型文でない短い字幕は捨てない(短すぎるのは要確認で知らせるだけ)
        let short = [cue(1.0, 1.2, "はい")]
        expectEqual(CaptionCleanup.removeHallucinations(short).removed, 0, "定型文でなければ短くても捨てない")
    }

    // MARK: 続く同じ文

    static func testDuplicatesMerged() {
        let input = [
            cue(0.0, 1.5, "おはようございます"),
            cue(1.5, 3.0, "おはようございます"),       // 直後 → ひとつに
            cue(10.0, 11.0, "12時39分です"),
            cue(11.3, 12.0, "12時39分です。"),        // 0.3 秒後・句点だけ違う → ひとつに
            cue(20.0, 21.0, "はい"),
            cue(22.0, 23.0, "はい"),                  // 1 秒空く → 別の字幕
            cue(30.0, 30.5, "あ"),
            cue(30.5, 31.0, "あ"),                    // 1 文字は比べない
        ]
        let (result, removed) = CaptionCleanup.mergeDuplicates(input)
        expectEqual(removed, 2, "続く同じ文の数")
        expectEqual(result.count, 6, "残る字幕の数")
        expect(near(result[0].start, 0.0) && near(result[0].end, 3.0), "ひとつにした字幕は前の始まり〜遅い方の終わり")
        expectEqual(result[0].text, "おはようございます", "前の文を使う")
        expect(near(result[1].start, 10.0) && near(result[1].end, 12.0), "句点だけ違う文もひとつにする")
        expectEqual(result[1].text, "12時39分です", "前の文を使う(句点なし)")
        expectEqual(result[2].text, "はい", "間が空いた同じ文は残る")
        expectEqual(result[3].text, "はい", "間が空いた同じ文は残る")

        // 単語の時刻・要確認の言葉は前のものを引き継ぐ
        var first = cue(0.0, 1.0, "田中さんです", words: true)
        first.doubtfulWords = ["田中"]
        var second = cue(1.1, 2.0, "田中さんです")
        second.doubtfulWords = ["田中", "さん"]
        let merged = CaptionCleanup.mergeDuplicates([first, second]).cues
        expectEqual(merged.count, 1, "ひとつになる")
        expectEqual(merged[0].id, first.id, "前の字幕の id を保つ")
        expectEqual(merged[0].words.count, 2, "前の単語時刻を保つ")
        expectEqual(merged[0].doubtfulWords, ["田中", "さん"], "要確認の言葉は合わせる")
    }

    // MARK: 重なり

    static func testOverlapsResolved() {
        // 同時に始まる 2 つの字幕(以前は前を 0.2 秒に縮めるだけで、重なったまま残っていた)
        let sameStart = [cue(312.0, 312.2, "ご視聴ありがとうございました"), cue(312.0, 313.5, "それでは始めます", words: true)]
        let resolved = CaptionCleanup.resolveOverlaps(sameStart)
        expect(hasNoOverlap(resolved), "重なりが残らない: \(resolved.map { ($0.start, $0.end) })")
        expectEqual(resolved.map { $0.text }, ["ご視聴ありがとうございました", "それでは始めます"], "順番を保つ")
        expect(near(resolved[0].end, 312.2), "前は最短表示まで")
        expect(near(resolved[1].start, 312.25), "次は前の終わり + 間から始まる")
        expect(near(resolved[1].end, 313.5), "次の終わりはそのまま")
        expect(resolved[1].words.allSatisfy { $0.start >= 312.25 - 0.0001 }, "ずらした字幕の単語も範囲に収める")

        // ふつうの重なり: 前を縮めるだけ
        let simple = [cue(0.0, 2.0, "最初の文"), cue(1.5, 3.0, "次の文")]
        let trimmed = CaptionCleanup.resolveOverlaps(simple)
        expect(near(trimmed[0].end, 1.45) && near(trimmed[1].start, 1.5), "前の終わりを次の始まりの手前まで縮める")

        // 重なっていなければ何も変えない
        let apart = [cue(0.0, 1.0, "一"), cue(2.0, 3.0, "二"), cue(4.0, 5.0, "三")]
        expectEqual(CaptionCleanup.resolveOverlaps(apart), apart, "重なりが無ければそのまま")

        // 3 つが同時に始まる・順番が入れ替わる場合も重なりが残らない
        let triple = [cue(10.0, 10.3, "一"), cue(10.0, 10.1, "二"), cue(10.1, 12.0, "三"), cue(10.0, 11.0, "四")]
        let tripleResolved = CaptionCleanup.resolveOverlaps(triple)
        expect(hasNoOverlap(tripleResolved), "3 つ以上の同時開始でも重なりが残らない: \(tripleResolved.map { ($0.start, $0.end) })")
        expectEqual(tripleResolved.count, 4, "字幕は減らない")
        expectEqual(Set(tripleResolved.map { $0.text }), Set(["一", "二", "三", "四"]), "文は失わない")

        // 時刻順に並べ直す
        let unsorted = [cue(5.0, 6.0, "後"), cue(1.0, 2.0, "先")]
        expectEqual(CaptionCleanup.resolveOverlaps(unsorted).map { $0.text }, ["先", "後"], "時刻順に並ぶ")
    }

    // MARK: 単語

    static func testDuplicateTokens() {
        let tokens = [
            TimedToken(text: "おはよう", start: 0.0, end: 0.5),
            TimedToken(text: "ございます", start: 0.5, end: 1.0),
            TimedToken(text: "おはよう", start: 0.05, end: 0.55),     // 窓の継ぎ目で同じ音声をもう一度 → 捨てる
            TimedToken(text: "ございます", start: 0.55, end: 1.0),
            TimedToken(text: "おはよう", start: 5.0, end: 5.5),       // 本当にもう一度言った → 残す
            TimedToken(text: "はい", start: 8.0, end: 8.0),
            TimedToken(text: "はい", start: 8.02, end: 8.02),         // 長さの無い単語は始まりで比べる → 捨てる
            TimedToken(text: "はい", start: 9.0, end: 9.0),
        ]
        let result = CaptionCleanup.removeDuplicateTokens(tokens)
        expectEqual(result.map { $0.text }, ["おはよう", "ございます", "おはよう", "はい", "はい"], "重なる同じ単語だけを捨てる")
        expect(zip(result, result.dropFirst()).allSatisfy { $0.start <= $1.start }, "時刻順")

        // 違う単語は重なっていても残す(Whisper の単語時刻はしばしば重なる)
        let different = [TimedToken(text: "今日", start: 0.0, end: 0.4), TimedToken(text: "は", start: 0.3, end: 0.5)]
        expectEqual(CaptionCleanup.removeDuplicateTokens(different).count, 2, "違う単語は残す")
    }

    // MARK: 報告された事例

    static func testReportedScenario() {
        // 31 分の動画(1.12.72〜1.12.76)で出た字幕を再現。時刻は 5:06.2 = 306.2 秒
        let input = [
            cue(0.0, 1.8, "おはようございます"),
            cue(1.8, 3.4, "おはようございます"),
            cue(3.5, 5.0, "12時39分です"),
            cue(5.0, 6.2, "12時39分です"),
            cue(6.3, 9.0, "今日の予定を話します"),
            cue(306.2, 306.4, "ご視聴ありがとうございました"),
            cue(306.45, 309.0, "ここからが本題です"),
            cue(312.0, 312.2, "ご視聴ありがとうございました"),
            cue(312.0, 313.5, "まず一つ目"),
        ]
        let (cues, report) = CaptionCleanup.clean(input)
        expectEqual(report.duplicates, 2, "同じ文 2 組")
        expectEqual(report.hallucinations, 2, "定型文 2 つ")
        expectEqual(report.total, 4, "合計")
        expectEqual(cues.map { $0.text },
                    ["おはようございます", "12時39分です", "今日の予定を話します", "ここからが本題です", "まず一つ目"],
                    "残る字幕")
        expect(hasNoOverlap(cues), "重なりが残らない: \(cues.map { ($0.start, $0.end) })")
        expect(near(cues[0].end, 3.4), "ひとつにした字幕は後ろの終わりまで")
        expect(near(cues[4].start, 312.0) && near(cues[4].end, 313.5), "本当の字幕の時刻は変わらない")

        // 問題のない字幕はまったく変えない
        let fine = [cue(0.0, 1.0, "一つ"), cue(1.2, 2.0, "二つ"), cue(2.5, 4.0, "三つ")]
        let (unchanged, none) = CaptionCleanup.clean(fine)
        expectEqual(unchanged, fine, "問題が無ければそのまま")
        expectEqual(none, CaptionCleanup.Report(), "取り除いた数は 0")
    }

    static func testSortIsStable() {
        let a = cue(1.0, 2.0, "A")
        let b = cue(1.0, 2.0, "B")
        let c = cue(0.5, 0.8, "C")
        expectEqual(CaptionCleanup.sortedByStart([a, b, c]).map { $0.text }, ["C", "A", "B"], "同じ始まりは元の順を保つ")
    }
}
