import SwiftUI

// =====================================================================
// キャプションを 2 つに分ける(字幕の一覧の「分ける」から開く)。
// 文を言葉(単語の時刻があればその区切り、無ければ 1 文字ずつ)に分けて並べ、分けたい所をタップして「ここで分ける」。
// 前は「時刻や分割を直す」の画面で文字カーソルを置いてから「ここで分割」を押す必要があり、見つけにくかった。
// 分けた時刻は、単語の時刻があればその単語の始まり、無ければ文字数の割合で決める。
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

    /// 文の区切り。単語の時刻があり、文の中に順番どおりに見つかれば単語ごと(時刻つき)、そうでなければ 1 文字ずつ
    static func segments(for cue: SubtitleCue) -> [Segment] {
        let chars = Array(cue.text)
        guard !chars.isEmpty else { return [] }
        if let byWords = wordSegments(cue: cue, chars: chars) { return byWords }
        return chars.enumerated().map { index, c in
            Segment(id: index, text: String(c), offset: index, time: nil)
        }
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
            result.append(Segment(id: k, text: String(chars[from..<to]), offset: from, time: k == 0 ? nil : start.time))
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

/// 分けたい所をタップして選ぶ画面
struct CaptionSplitSheet: View {
    let cue: SubtitleCue
    let playheadTime: Double
    let onSplit: (_ offset: Int, _ time: Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// この区切りの前で分ける(1 以上)
    @State private var selected: Int?

    private var segments: [CaptionSplit.Segment] { CaptionSplit.segments(for: cue) }
    private var canSplit: Bool { cue.duration >= CaptionSplit.minimumLength * 2 && segments.count >= 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if canSplit {
                        Text("分けたい所の、後ろの言葉をタップしてください。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        EditorChipFlowLayout(spacing: 3, lineSpacing: 8) {
                            ForEach(segments) { segment in
                                segmentButton(segment)
                            }
                        }
                        if let k = selected {
                            preview(k)
                        }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("ここで分ける") {
                        guard let k = selected, k < segments.count else { return }
                        onSplit(segments[k].offset, segments[k].time)
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
            .onAppear {
                // 再生位置がこのキャプションの中なら、その近くの区切りを最初から選んでおく
                if selected == nil {
                    selected = CaptionSplit.segmentIndex(near: playheadTime, in: cue, segments: segments)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func segmentButton(_ segment: CaptionSplit.Segment) -> some View {
        let isAfter = selected.map { segment.id >= $0 } ?? false
        let isCut = selected == segment.id
        return Button {
            guard segment.id > 0 else { return }
            EditorHaptics.tap()
            selected = segment.id
        } label: {
            HStack(spacing: 3) {
                if isCut {
                    Image(systemName: "scissors")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(segment.text)
                    .font(.title3)
                    .foregroundStyle(isAfter ? Color.accentColor : Color.primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isAfter ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .disabled(segment.id == 0)
    }

    private func preview(_ k: Int) -> some View {
        let offset = segments[k].offset
        let chars = Array(cue.text)
        let first = String(chars[..<offset]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(chars[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(first)
            } icon: {
                Text("1")
                    .font(.caption.weight(.bold))
            }
            Label {
                Text(second)
                    .foregroundStyle(Color.accentColor)
            } icon: {
                Text("2")
                    .font(.caption.weight(.bold))
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground)))
    }
}
