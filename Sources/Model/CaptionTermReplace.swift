import Foundation

// =====================================================================
// 字幕を 1 件直したとき、ほかの字幕の同じ言葉もまとめて直すかを聞く。
//
// 例:「カフェ小川に行く」→「CAFE OGAWAに行く」なら、前後の同じ部分を除いて
// 変わった部分「カフェ小川」→「CAFE OGAWA」を取り出し、ほかの字幕に「カフェ小川」が何か所あるかを数える。
// 1 文字だけの直し(助詞など)は、ほかの字幕まで変えると壊れやすいので聞かない。
// =====================================================================

struct CaptionTermReplacement: Identifiable, Equatable {
    let id = UUID()
    let from: String
    let to: String
    /// ほかの字幕で見つかった数
    let count: Int
    /// 直した字幕(置き換えの対象から外す)
    let editedCueID: UUID

    var question: String {
        to.isEmpty
            ? String(localized: "ほかの \(count) か所の「\(from)」も消しますか?")
            : String(localized: "ほかの \(count) か所の「\(from)」も「\(to)」にしますか?")
    }

    var confirmTitle: String {
        to.isEmpty ? String(localized: "すべて消す") : String(localized: "すべて変える")
    }

    /// まとめて直し、用語として登録して次の文字起こしからも自動で直す
    var rememberTitle: String {
        to.isEmpty ? String(localized: "すべて消して、次からも自動で消す")
                   : String(localized: "すべて変えて、次からも自動で直す")
    }
}

enum CaptionTermReplace {
    /// 直す前と後の文から変わった言葉を取り出し、ほかの字幕にもあれば提案を返す
    static func suggestion(oldText: String, newText: String, editedCueID: UUID,
                           in cues: [SubtitleCue]) -> CaptionTermReplacement? {
        guard oldText != newText else { return nil }
        let old = Array(oldText)
        let new = Array(newText)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let from = String(old[prefix..<(old.count - suffix)]).trimmingCharacters(in: .whitespacesAndNewlines)
        let to = String(new[prefix..<(new.count - suffix)]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard from.count >= 2, from != to else { return nil }
        let count = cues
            .filter { $0.id != editedCueID }
            .reduce(0) { $0 + occurrences(of: from, in: $1.text) }
        guard count > 0 else { return nil }
        return CaptionTermReplacement(from: from, to: to, count: count, editedCueID: editedCueID)
    }

    /// ほかの字幕の from を to に置き換える。直した字幕の数を返す
    @discardableResult
    static func apply(_ replacement: CaptionTermReplacement, to project: EditorProject) -> Int {
        var cues = project.subtitles
        var changed = 0
        for i in cues.indices where cues[i].id != replacement.editedCueID && cues[i].text.contains(replacement.from) {
            cues[i].text = cues[i].text.replacingOccurrences(of: replacement.from, with: replacement.to)
            // 単語ごとの時刻(カラオケ風)は文字が変わると合わなくなるので、文字数で付け直す
            if !cues[i].words.isEmpty {
                cues[i].words = SubtitleWordTiming.distribute(cue: cues[i])
            }
            changed += 1
        }
        project.subtitles = cues
        return changed
    }

    private static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        return text.components(separatedBy: term).count - 1
    }
}
