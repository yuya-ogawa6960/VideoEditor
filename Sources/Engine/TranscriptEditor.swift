import Foundation

// =====================================================================
// 文字起こしで編集(Descript 風の文字ベース編集)の計算。画面は Views/TranscriptEditView.swift
//   - lines(from:)          : キャプション → 行(1 キャプション = 1 段落)と、タップで選べる単位(単語か行)
//   - ranges(for:in:)       : 選んだ単位 → 取り除く出力タイムラインの区間(前後に少し余白、隣どうしはつなぐ)
//   - applyDeletion(to:deleting:) : 選んだ単語を字幕の文と words から消す
//                             (EditorProject.removeOutputRanges は時刻をずらすだけで、文は変えない)
//   - linesAfterDeletion    : 消した単位に印を付け、残りの時刻を前にずらす(画面の一覧用)
//   - resynced              : 削除のあと、一覧の単語を今の字幕の words に付け直す(番号と時刻)
// =====================================================================

enum TranscriptEditor {
    /// タップで選べる単位。単語タイミングがあれば単語、無ければ行全体
    struct Item: Identifiable, Equatable {
        let id: UUID
        let cueID: UUID
        let text: String
        /// 出力タイムライン上の秒
        var start: Double
        var end: Double
        /// 字幕の words の中の番号。行全体を 1 つで扱うとき(単語タイミングが無い)は nil。
        /// 削除のたびに resynced で今の words の番号に付け直す
        var wordIndex: Int?
        /// 言いよどみ(「えー」「あのー」など。単語タイミングがあるときだけ)
        let isFiller: Bool
        /// 言いよどみ、または聞き取りに自信のない言葉(点線の下線で知らせる)
        let isSuspicious: Bool
        /// この画面で消した(取り消し線で残す)
        var isDeleted = false

        var duration: Double { max(0, end - start) }
    }

    /// 1 キャプション = 1 行
    struct Line: Identifiable, Equatable {
        /// 字幕の id
        let id: UUID
        var items: [Item]
        var start: Double
        var end: Double
        /// 単語ごとにタップできるか
        let hasWordTimings: Bool
        /// 単語の時刻が文字数で割った推定なので、行ごとにだけ選ばせている
        var wordsEstimated: Bool = false

        var isAllDeleted: Bool { items.allSatisfy { $0.isDeleted } }
    }

    /// 取り除く区間の前後の余白(秒。言いよどみカットと同じ)
    static let padding: Double = 0.03
    /// 列の上で隣どうしの単語を選んだとき、間がこれ以内なら間も一緒に取り除く(秒)
    static let bridgeGap: Double = 0.6

    // MARK: 一覧を作る

    static func lines(from cues: [SubtitleCue]) -> [Line] {
        cues.sorted { $0.start < $1.start }.map { cue -> Line in
            // 単語の時刻が文字数で割った推定(字幕の文を直した・AI 仕上げ・用語の置き換え・SRT など)の行は、行ごとにだけ選ばせる。
            // 単語ごとに切ると実際に話した位置とずれ、前後の言葉が欠けたり、消した言葉の端が残ったりする
            let estimated = hasEstimatedWordTimings(cue.words)
            if !cue.words.isEmpty, !estimated {
                var items: [Item] = []
                for (index, word) in cue.words.enumerated() {
                    let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let filler = FillerDetector.isFiller(text)
                    let doubtful = cue.doubtfulWords.contains {
                        CaptionIssueCheck.containsWord($0, in: text) || CaptionIssueCheck.containsWord(text, in: $0)
                    }
                    items.append(Item(id: UUID(), cueID: cue.id, text: text,
                                      start: word.start, end: max(word.start, word.end),
                                      wordIndex: index, isFiller: filler, isSuspicious: filler || doubtful))
                }
                if !items.isEmpty {
                    return Line(id: cue.id, items: items, start: cue.start, end: cue.end, hasWordTimings: true)
                }
            }
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let suspicious = !cue.doubtfulWords.isEmpty || !FillerDetector.spans(in: [cue]).isEmpty
            let item = Item(id: UUID(), cueID: cue.id, text: text, start: cue.start, end: cue.end,
                            wordIndex: nil, isFiller: false, isSuspicious: suspicious)
            return Line(id: cue.id, items: [item], start: cue.start, end: cue.end, hasWordTimings: false,
                        wordsEstimated: estimated)
        }
    }

    /// 単語の時刻が、文字数に比例して割り振った推定値か(SubtitleWordTiming.distribute・SubtitlePolisher.rescaleWords・
    /// distributeEvenly の形: すき間なくつながり、1 文字あたりの長さがどの単語も同じ)。本物の認識結果でこうなることはまずない
    static func hasEstimatedWordTimings(_ words: [SubtitleWord]) -> Bool {
        guard words.count >= 3 else { return false }
        var rates: [Double] = []
        rates.reserveCapacity(words.count)
        for (i, word) in words.enumerated() {
            let length = word.end - word.start
            guard length > 0 else { return false }
            if i + 1 < words.count, abs(words[i + 1].start - word.end) > 0.0005 { return false }
            rates.append(length / Double(max(1, word.text.count)))
        }
        let mean = rates.reduce(0, +) / Double(rates.count)
        guard mean > 0 else { return false }
        // 推定の値は計算の誤差しか違わない(認識結果の時刻はコマ単位に丸められていて、ここまでそろうことはまずない)
        return rates.allSatisfy { abs($0 - mean) <= mean * 0.002 + 0.00002 }
    }

    // MARK: 区間

    /// 選んだ単位から取り除く区間を作る。列の上で隣どうしに選んだ単語は(間が bridgeGap 秒以内なら)間も含めてひとつにつなぎ、
    /// 前後に padding 秒の余白を付けてから重なりをまとめる
    static func ranges(for selected: Set<UUID>, in lines: [Line]) -> [(start: Double, end: Double)] {
        var raw: [(start: Double, end: Double)] = []
        var previousSelected = false
        for line in lines {
            for item in line.items where !item.isDeleted {
                let isSelected = selected.contains(item.id)
                if isSelected, item.end > item.start {
                    if previousSelected, let last = raw.last, item.start >= last.start, item.start - last.end <= bridgeGap {
                        raw[raw.count - 1].end = max(last.end, item.end)
                    } else {
                        raw.append((item.start, item.end))
                    }
                }
                previousSelected = isSelected
            }
        }
        return merge(raw.map { (start: max(0, $0.start - padding), end: $0.end + padding) })
    }

    /// 重なる区間をまとめる
    static func merge(_ input: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        let sorted = input.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for r in sorted {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    static func totalDuration(_ ranges: [(start: Double, end: Double)]) -> Double {
        ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// 区間を取り除いたあとの時刻(EditorProject.removeOutputRanges と同じ計算)
    static func shifted(_ t: Double, removing ranges: [(start: Double, end: Double)]) -> Double {
        var removedBefore = 0.0
        for r in ranges {
            if t >= r.end { removedBefore += r.end - r.start }
            else if t > r.start { removedBefore += t - r.start }
        }
        return max(0, t - removedBefore)
    }

    // MARK: 字幕に反映する

    /// 選んだ単位を字幕から消す。単語は文と words から外し、行全体を選んだ字幕や単語が無くなった字幕は取り除く。
    /// 時刻は変えない(このあと removeOutputRanges がずらす)
    static func applyDeletion(to cues: [SubtitleCue], deleting items: [Item]) -> [SubtitleCue] {
        var wholeLines = Set<UUID>()
        var wordIndices: [UUID: Set<Int>] = [:]
        for item in items {
            if let index = item.wordIndex {
                wordIndices[item.cueID, default: []].insert(index)
            } else {
                wholeLines.insert(item.cueID)
            }
        }
        guard !wholeLines.isEmpty || !wordIndices.isEmpty else { return cues }
        return cues.compactMap { cue -> SubtitleCue? in
            if wholeLines.contains(cue.id) { return nil }
            guard let removed = wordIndices[cue.id], !removed.isEmpty else { return cue }
            var result = cue
            result.text = textRemovingWords(cue.text, words: cue.words, removed: removed)
            result.words = cue.words.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
            if result.words.isEmpty || result.text.isEmpty { return nil }
            // 要確認の言葉は、文から消えたものを外す
            result.doubtfulWords = cue.doubtfulWords.filter { CaptionIssueCheck.containsWord($0, in: result.text) }
            return result
        }
    }

    /// 文から、消す単語の文字を取り除く。単語を前から順に文の中で探す(句読点はそのまま残る)。
    /// 見つからない単語があるときは、残った単語をつなぎ直す
    static func textRemovingWords(_ text: String, words: [SubtitleWord], removed: Set<Int>) -> String {
        var cursor = text.startIndex
        var cuts: [Range<String.Index>] = []
        for (index, word) in words.enumerated() {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard let found = text.range(of: token, range: cursor..<text.endIndex) else {
                return joined(words.enumerated().filter { !removed.contains($0.offset) }.map { $0.element })
            }
            if removed.contains(index) {
                var lower = found.lowerBound
                var upper = found.upperBound
                // 後ろの空白(英語など)も一緒に消す。文末なら前の空白を消す
                if upper < text.endIndex, text[upper] == " " {
                    upper = text.index(after: upper)
                } else if lower > text.startIndex, text[text.index(before: lower)] == " " {
                    lower = text.index(before: lower)
                }
                // 直前に消す範囲と重ならないようにする
                if let last = cuts.last, lower < last.upperBound { lower = last.upperBound }
                if lower < upper { cuts.append(lower..<upper) }
            }
            cursor = found.upperBound
        }
        var result = text
        for range in cuts.reversed() {
            result.removeSubrange(range)
        }
        return trimmedEdges(result)
    }

    /// 単語をつなぎ直す(かな・漢字どうし以外の間には空白を入れる。needsSpace)
    static func joined(_ words: [SubtitleWord]) -> String {
        var result = ""
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let last = result.last, let first = token.first, needsSpace(between: last, and: first) {
                result.append(" ")
            }
            result.append(token)
        }
        return trimmedEdges(result)
    }

    // MARK: 単語の間の空白

    /// last で終わる単語と first で始まる単語の間に空白を入れるか。
    /// 詰めるのは、かな・漢字などの日本語(と中国語)のときだけ。英語・スペイン語・ポルトガル語などは、
    /// 句読点やアクセント付きの文字のあとでも空白を入れる(前は英数字どうしのときだけで、"Hello,world" "issoébom" と詰まっていた)
    static func needsSpace(between last: Character, and first: Character) -> Bool {
        if last.isWhitespace || first.isWhitespace { return false }
        if isCJK(last) || isCJK(first) { return false }
        // 閉じる記号・句読点の前と、開く記号のあとは詰める
        if ",.!?;:)]}%…”".contains(first) { return false }
        if "([{“¿¡".contains(last) { return false }
        return true
    }

    /// かな・漢字・全角の記号か(空白を入れずに続けて書く文字)
    static func isCJK(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                continue
            }
        }
        return false
    }

    /// 先頭に残った読点・空白と、両端の空白を除く
    private static func trimmedEdges(_ text: String) -> String {
        var result = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = result.first, leadingTrash.contains(first) {
            result = result.dropFirst()
        }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let leadingTrash: Set<Character> = ["、", "，", ",", "。", ".", "；", ";", "：", ":", " "]

    // MARK: 画面の一覧を更新する

    /// 消した単位に印を付け、残りの単位の時刻を前にずらす(消した単位はそのまま残して取り消し線で見せる)
    static func linesAfterDeletion(_ lines: [Line], deleted: Set<UUID>,
                                   ranges: [(start: Double, end: Double)]) -> [Line] {
        lines.map { line in
            var result = line
            result.items = line.items.map { item in
                var updated = item
                if deleted.contains(item.id) {
                    updated.isDeleted = true
                } else if !item.isDeleted {
                    updated.start = shifted(item.start, removing: ranges)
                    updated.end = shifted(item.end, removing: ranges)
                }
                return updated
            }
            result.start = shifted(line.start, removing: ranges)
            result.end = shifted(line.end, removing: ranges)
            return result
        }
    }

    /// 削除のあと、一覧の単語を今の字幕に付け直す(words の番号と時刻)。
    /// 番号を開いたときのままにしていたので、同じ行の単語を 2 回に分けて消すと、字幕から別の単語が消え、
    /// 消したはずの単語が字幕に残っていた。時刻も実際に詰めた結果(トランジションの重なりは切らない)に合わせる。
    /// 字幕から無くなった単語・行(短くなりすぎて外れたものなど)は、消したものとして取り消し線で見せる
    static func resynced(_ lines: [Line], with cues: [SubtitleCue]) -> [Line] {
        var byID: [UUID: SubtitleCue] = [:]
        for cue in cues { byID[cue.id] = cue }
        return lines.map { line in
            var result = line
            guard let cue = byID[line.id] else {
                result.items = line.items.map { item in
                    var updated = item
                    updated.isDeleted = true
                    return updated
                }
                return result
            }
            result.start = cue.start
            result.end = cue.end
            if line.hasWordTimings {
                var cursor = 0
                result.items = line.items.map { item in
                    var updated = item
                    guard !item.isDeleted else { return updated }
                    var found: Int? = nil
                    var k = cursor
                    while k < cue.words.count {
                        if cue.words[k].text.trimmingCharacters(in: .whitespacesAndNewlines) == item.text {
                            found = k
                            break
                        }
                        k += 1
                    }
                    if let found {
                        updated.wordIndex = found
                        updated.start = cue.words[found].start
                        updated.end = max(cue.words[found].start, cue.words[found].end)
                        cursor = found + 1
                    } else {
                        updated.isDeleted = true
                    }
                    return updated
                }
            } else {
                result.items = line.items.map { item in
                    var updated = item
                    if !item.isDeleted {
                        updated.start = cue.start
                        updated.end = cue.end
                    }
                    return updated
                }
            }
            return result
        }
    }
}
