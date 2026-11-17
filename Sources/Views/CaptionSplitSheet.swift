import SwiftUI
import NaturalLanguage

// =====================================================================
// キャプションを 2 つに分ける(字幕の一覧の「分ける」から開く)。
// 文を言葉に分けて並べ、分けたい所の後ろの言葉をタップすると、そこで分かれる(確認の手順は無い。
// 間違えたら一覧の「次とつなげる」で戻せる)。再生位置がキャプションの中なら「再生位置で分ける」も出す。
// 言葉の区切りは、単語の時刻があればその区切り、無ければ NLTokenizer の単語(助詞は前の言葉に付ける)。
// どちらでも足りないときのために「1 文字ずつ選ぶ」に切り替えられる。
// 前は「時刻や分割を直す」の画面で文字カーソルを置いてから「ここで分割」を押す必要があり、見つけにくかった。
// 分けた時刻は、単語の時刻があればそこから(単語の途中は割合で)、無ければ文字数の割合で決める。
// =====================================================================

/// 一覧の「分ける」で開く対象
struct CaptionSplitRequest: Identifiable {
    let id: UUID
}

enum CaptionSplit {
    /// 分けたあとのそれぞれのいちばん短い長さ(秒)
    static let minimumLength: Double = 0.2

    /// 選べる区切りの 1 つ分(text は表示する文字、offset は文の先頭からの文字数、time はこの区切りの前で分けたときの時刻)
    struct Segment: Identifiable, Equatable {
        let id: Int
        let text: String
        let offset: Int
        let time: Double?
    }

    /// 文の区切り。単語の時刻があり、文の中に順番どおりに見つかれば単語ごと(時刻つき)、
    /// そうでなければ NLTokenizer の言葉ごと、それも無理なら 1 文字ずつ。fine なら必ず 1 文字ずつ
    static func segments(for cue: SubtitleCue, fine: Bool = false) -> [Segment] {
        let chars = Array(cue.text)
        guard !chars.isEmpty else { return [] }
        let byWords = wordSegments(cue: cue, chars: chars)
        if !fine {
            if let byWords { return byWords }
            if let byPhrases = phraseSegments(chars: chars) { return byPhrases }
        }
        // 1 文字ずつ。単語の時刻があれば、単語の中は割合でならして時刻を付ける
        return chars.enumerated().map { index, c in
            Segment(id: index, text: String(c), offset: index,
                    time: index == 0 ? nil : byWords.flatMap { interpolatedTime(offset: index, in: $0, cue: cue, count: chars.count) })
        }
    }

    /// 1 文字ずつ選べる意味があるか(言葉ごとの区切りと同じなら切り替えは出さない)
    static func hasFinerSegments(for cue: SubtitleCue) -> Bool {
        segments(for: cue).count < cue.text.count
    }

    /// offset 文字目の時刻(単語ごとの区切りの間を文字数の割合でならす)
    private static func interpolatedTime(offset: Int, in words: [Segment], cue: SubtitleCue, count: Int) -> Double? {
        guard let k = words.lastIndex(where: { $0.offset <= offset }) else { return nil }
        let fromOffset = words[k].offset
        let fromTime = words[k].time ?? cue.start
        let toOffset = k + 1 < words.count ? words[k + 1].offset : count
        let toTime = k + 1 < words.count ? (words[k + 1].time ?? cue.end) : cue.end
        guard toOffset > fromOffset, toTime >= fromTime else { return nil }
        return fromTime + (toTime - fromTime) * Double(offset - fromOffset) / Double(toOffset - fromOffset)
    }

    /// NLTokenizer の単語ごとの区切り(時刻なし)。ひらがな 1〜2 文字の言葉(助詞・語尾)は前の言葉に付けて、
    /// 「私は」「今が」のようなまとまりにする。句読点や空白は前の言葉に付く。2 つ以上に分けられなければ nil
    private static func phraseSegments(chars: [Character]) -> [Segment]? {
        let text = String(chars)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
            tokenizer.setLanguage(.japanese)
        }
        var starts: [Int] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range]
            let isParticle = token.count <= 2 && token.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) || $0.value == 0x30FC }
            if starts.isEmpty || !isParticle {
                starts.append(text.distance(from: text.startIndex, to: range.lowerBound))
            }
            return true
        }
        guard starts.count >= 2 else { return nil }
        var result: [Segment] = []
        for (k, start) in starts.enumerated() {
            let from = k == 0 ? 0 : start
            let to = k + 1 < starts.count ? starts[k + 1] : chars.count
            guard to > from else { continue }
            result.append(Segment(id: result.count, text: String(chars[from..<to]), offset: from, time: nil))
        }
        return result.count >= 2 ? result : nil
    }

    private static func wordSegments(cue: SubtitleCue, chars: [Character]) -> [Segment]? {
        let words = cue.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard words.count >= 2 else { return nil }
        let lowered = chars.map { Character($0.lowercased()) }
        var starts: [(offset: Int, time: Double)] = []
        var cursor = 0
        for word in words {
            let target = Array(word.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            guard !target.isEmpty else { continue }
            var found: Int? = nil
            var i = cursor
            while i + target.count <= lowered.count {
                if Array(lowered[i..<(i + target.count)]) == target {
                    found = i
                    break
                }
                i += 1
            }
            guard let start = found else { return nil }
            starts.append((offset: start, time: word.start))
            cursor = start + target.count
        }
        guard starts.count >= 2 else { return nil }
        var result: [Segment] = []
        for (k, start) in starts.enumerated() {
            // 最初の単語の前の文字(「「」など)は最初の区切りに含める
            let from = k == 0 ? 0 : start.offset
            let to = k + 1 < starts.count ? starts[k + 1].offset : chars.count
            guard to > from else { continue }
            result.append(Segment(id: result.count, text: String(chars[from..<to]), offset: from, time: result.isEmpty ? nil : start.time))
        }
        return result.count >= 2 ? result : nil
    }

    /// offset 文字目の前で分けた 2 件。time があればその時刻、無ければ文字数の割合で分ける。分けられなければ nil。
    /// 前半は同じ id のまま、訳文は前半に残す(訳文は 2 つに分けられない)
    static func split(_ c: SubtitleCue, at offset: Int, time: Double?) -> (head: SubtitleCue, tail: SubtitleCue)? {
        let chars = Array(c.text)
        guard c.duration >= minimumLength * 2, offset > 0, offset < chars.count else { return nil }
        let first = String(chars[..<offset]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(chars[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        let weight = Double(first.count) / Double(first.count + second.count)
        var boundary = time ?? (c.start + c.duration * weight)
        boundary = min(max(boundary, c.start + minimumLength), c.end - minimumLength)

        var head = c
        head.text = first
        head.end = boundary
        var tail = SubtitleCue(start: boundary, end: c.end, text: second)
        tail.bilingual = c.bilingual
        if !c.words.isEmpty {
            // 単語の時刻は境目で分ける(はみ出す分は境目にそろえる)
            head.words = c.words.filter { $0.start < boundary - 0.001 }.map { word in
                var w = word
                w.end = min(w.end, boundary)
                return w
            }
            tail.words = c.words.filter { $0.start >= boundary - 0.001 }.map { word in
                var w = word
                w.start = max(w.start, boundary)
                return w
            }
            if head.words.isEmpty { head.words = SubtitleWordTiming.distribute(text: first, start: head.start, end: head.end) }
            if tail.words.isEmpty { tail.words = SubtitleWordTiming.distribute(text: second, start: tail.start, end: tail.end) }
        }
        return (head, tail)
    }

    /// time(再生位置)に近い区切り。区間の外なら nil
    static func segmentIndex(near time: Double, in cue: SubtitleCue, segments: [Segment]) -> Int? {
        guard time > cue.start + minimumLength, time < cue.end - minimumLength, segments.count >= 2 else { return nil }
        let total = Double(cue.text.count)
        var best: Int? = nil
        var bestDistance = Double.greatestFiniteMagnitude
        for k in 1..<segments.count {
            let t = segments[k].time ?? (cue.start + cue.duration * Double(segments[k].offset) / max(1, total))
            let distance = abs(t - time)
            if distance < bestDistance {
                bestDistance = distance
                best = k
            }
        }
        return best
    }
}

/// 分けたい所をタップして選ぶ画面(タップしたら、そこで分かれて閉じる)
struct CaptionSplitSheet: View {
    let cue: SubtitleCue
    let playheadTime: Double
    let onSplit: (_ offset: Int, _ time: Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 1 文字ずつ選ぶ(言葉ごとの区切りでは足りないとき)
    @State private var fine = false

    private var segments: [CaptionSplit.Segment] { CaptionSplit.segments(for: cue, fine: fine) }
    private var canSplit: Bool { cue.duration >= CaptionSplit.minimumLength * 2 && segments.count >= 2 }
    /// 再生位置に近い区切り(再生位置がこのキャプションの中のときだけ)
    private var playheadSegment: Int? {
        CaptionSplit.segmentIndex(near: playheadTime, in: cue, segments: segments)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if canSplit {
                        Text("2 つ目の頭にしたい言葉をタップすると、そこで分かれます。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        EditorChipFlowLayout(spacing: fine ? 2 : 4, lineSpacing: 8) {
                            ForEach(segments) { segment in
                                segmentButton(segment)
                            }
                        }
                        if let k = playheadSegment, k < segments.count {
                            Button {
                                split(at: k)
                            } label: {
                                Label("再生位置で分ける", systemImage: "scissors")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if fine || CaptionSplit.hasFinerSegments(for: cue) {
                            Button {
                                fine.toggle()
                            } label: {
                                Label(fine ? LocalizedStringKey("言葉ごとに選ぶ") : LocalizedStringKey("1 文字ずつ選ぶ"),
                                      systemImage: fine ? "text.word.spacing" : "character.cursor.ibeam")
                            }
                            .font(.subheadline)
                        }
                        Text("間違えたら、一覧の右上の「元に戻す」で戻せます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("このキャプションは短すぎるため分けられません。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("キャプションを分ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func split(at k: Int) {
        guard k > 0, k < segments.count else { return }
        onSplit(segments[k].offset, segments[k].time)
        dismiss()
    }

    private func segmentButton(_ segment: CaptionSplit.Segment) -> some View {
        // 再生位置に近い区切りには、はさみの印を付けておく(「再生位置で分ける」で切れる所)
        let isPlayhead = playheadSegment == segment.id
        return Button {
            split(at: segment.id)
        } label: {
            HStack(spacing: 3) {
                if isPlayhead {
                    Image(systemName: "scissors")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(segment.text)
                    .font(.title3)
                    .foregroundStyle(segment.id == 0 ? Color.secondary : Color.primary)
            }
            .padding(.horizontal, fine ? 5 : 8)
            .padding(.vertical, 8)
            .frame(minWidth: fine ? 30 : 36, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isPlayhead ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .disabled(segment.id == 0)
    }
}
