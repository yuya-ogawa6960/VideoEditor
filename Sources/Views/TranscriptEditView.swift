import SwiftUI
import Observation

// =====================================================================
// 文字起こしで編集(Descript 風の文字ベース編集)。
// キャプションの文を読みながら単語や行をタップして選び、「削除」でその時間の映像を詰める。
// 字幕の文・単語も合わせて消す。消した所は取り消し線で残す(この画面を閉じるまで)。
// 計算は Engine/TranscriptEditor.swift。ContentView からシートで開く
// =====================================================================

/// 秒 → "m:ss"
fileprivate func transcriptTimeString(_ seconds: Double) -> String {
    let s = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

struct TranscriptEditView: View {
    let project: EditorProject
    let player: PlayerController
    /// キャプションが無いとき「キャプションを作成」を押した(閉じたあとに呼ぶ。字幕のシートを開く)
    let onOpenCaptions: () -> Void
    /// 閉じたときに、この画面で消した数と合計秒を知らせる(何も消していなければ呼ばない)
    let onFinished: (_ count: Int, _ seconds: Double) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var lines: [TranscriptEditor.Line]

    init(project: EditorProject, player: PlayerController,
         onOpenCaptions: @escaping () -> Void = {},
         onFinished: @escaping (_ count: Int, _ seconds: Double) -> Void = { _, _ in }) {
        self.project = project
        self.player = player
        self.onOpenCaptions = onOpenCaptions
        self.onFinished = onFinished
        // 開いた瞬間から一覧を出す(onAppear で作ると「キャプションがありません」が一瞬見える)
        _lines = State(initialValue: TranscriptEditor.lines(from: project.subtitles))
    }
    /// 選んでいる単位(単語か行)の id
    @State private var selected: Set<UUID> = []
    /// 最後にタップした単位(次のタップでそこから範囲を広げる)
    @State private var anchor: UUID?
    /// 削除ごとの取り消し用(削除する直前のプロジェクトと一覧)
    @State private var undoStack: [UndoEntry] = []
    @State private var deletedCount = 0
    @State private var deletedSeconds = 0.0
    /// 直前の削除のお知らせ(「元に戻す」付き。しばらくすると消える)
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private struct UndoEntry {
        let snapshot: ProjectSnapshot
        let lines: [TranscriptEditor.Line]
        let count: Int
        let seconds: Double
    }

    /// 一覧の中の位置(行番号・行の中の番号)。範囲で選ぶときの比較用
    private struct Position: Equatable, Comparable {
        let line: Int
        let item: Int
        static func < (a: Position, b: Position) -> Bool {
            a.line != b.line ? a.line < b.line : a.item < b.item
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    emptyState
                } else {
                    transcript
                }
            }
            .navigationTitle("文字起こし編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !lines.isEmpty {
                    bottomBar
                }
            }
        }
        .onAppear {
            Analytics.shared.track("sheet", ["name": "transcriptEdit"])
        }
        .onDisappear {
            noticeTask?.cancel()
            if deletedCount > 0 {
                onFinished(deletedCount, deletedSeconds)
            }
        }
    }

    // MARK: 本文

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("単語をタップして選び、別の単語をタップすると範囲になります。左の○で行ごと選べます。長押しでその場所から再生します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(lines) { line in
                    TranscriptLineRow(line: line,
                                      selected: selected.intersection(line.items.map { $0.id }),
                                      onTapItem: { tap($0) },
                                      onTapLine: { tapLine(line) },
                                      onPlay: { play(from: $0) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("字幕がありません")
                .font(.headline)
            Text("先に「自動字幕」で字幕を作ると、文字を読みながら不要な部分を消せます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("自動字幕") {
                dismiss()
                // シートが閉じてから字幕のシートを開く(重ねて出すと開けない)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onOpenCaptions()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 下の操作列

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let notice {
                HStack {
                    Text(notice)
                        .font(.footnote)
                    Spacer()
                    Button("元に戻す") { undoLast() }
                        .font(.footnote.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button {
                    selectAllFillers()
                } label: {
                    Label(fillerCount > 0 ? String(localized: "言いよどみをすべて選ぶ(\(fillerCount))") : String(localized: "言いよどみをすべて選ぶ"),
                          systemImage: "scissors.badge.ellipsis")
                }
                .disabled(fillerCount == 0)
                Spacer()
                if player.isPlaying {
                    Button {
                        player.pause()
                    } label: {
                        Label("一時停止", systemImage: "pause.fill")
                    }
                }
            }
            .font(.subheadline)
            HStack(spacing: 12) {
                Text(selectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("選択を解除") { clearSelection() }
                    .disabled(selected.isEmpty)
                Button(role: .destructive) {
                    deleteSelection()
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionSummary: String {
        guard !selected.isEmpty else { return String(localized: "単語や行をタップして選びます") }
        let seconds = TranscriptEditor.totalDuration(TranscriptEditor.ranges(for: selected, in: lines))
        return String(localized: "\(String(format: "%.1f", seconds)) 秒を選択中")
    }

    /// まだ消していない言いよどみの数
    private var fillerCount: Int {
        lines.reduce(0) { $0 + $1.items.filter { $0.isFiller && !$0.isDeleted }.count }
    }

    // MARK: 選ぶ

    private func position(of id: UUID) -> Position? {
        for (l, line) in lines.enumerated() {
            if let i = line.items.firstIndex(where: { $0.id == id }) {
                return Position(line: l, item: i)
            }
        }
        return nil
    }

    /// a から b まで(両端を含む)の、消していない単位の id
    private func itemIDs(from a: Position, to b: Position) -> [UUID] {
        var ids: [UUID] = []
        for l in a.line...b.line {
            let items = lines[l].items
            let lo = l == a.line ? a.item : 0
            let hi = l == b.line ? b.item : items.count - 1
            guard lo <= hi else { continue }
            for i in lo...hi where !items[i].isDeleted {
                ids.append(items[i].id)
            }
        }
        return ids
    }

    /// 単位をタップ: 選んでいなければ選ぶ(前にタップした所があれば、そこからの範囲)。選んでいれば外す
    private func tap(_ item: TranscriptEditor.Item) {
        guard !item.isDeleted else { return }
        if selected.contains(item.id) {
            selected.remove(item.id)
            if anchor == item.id || selected.isEmpty { anchor = nil }
            return
        }
        if let anchor, let a = position(of: anchor), let b = position(of: item.id) {
            for id in itemIDs(from: min(a, b), to: max(a, b)) {
                selected.insert(id)
            }
        } else {
            selected.insert(item.id)
        }
        anchor = item.id
    }

    /// 行の○をタップ: 行をまるごと選ぶ。すでに全部選んでいれば外す
    private func tapLine(_ line: TranscriptEditor.Line) {
        let ids = line.items.filter { !$0.isDeleted }.map { $0.id }
        guard !ids.isEmpty else { return }
        if ids.allSatisfy({ selected.contains($0) }) {
            for id in ids { selected.remove(id) }
            if selected.isEmpty { anchor = nil }
        } else {
            for id in ids { selected.insert(id) }
            anchor = ids.last
        }
    }

    private func selectAllFillers() {
        for line in lines {
            for item in line.items where item.isFiller && !item.isDeleted {
                selected.insert(item.id)
            }
        }
        anchor = nil
    }

    private func clearSelection() {
        selected = []
        anchor = nil
    }

    private func play(from item: TranscriptEditor.Item) {
        guard !item.isDeleted else { return }
        player.seek(to: item.start)
        player.play()
    }

    // MARK: 削除する・元に戻す

    private func deleteSelection() {
        let items = lines.flatMap { $0.items }.filter { selected.contains($0.id) && !$0.isDeleted }
        guard !items.isEmpty else { return }
        let ranges = TranscriptEditor.ranges(for: selected, in: lines)
        guard !ranges.isEmpty else { return }
        player.pause()
        undoStack.append(UndoEntry(snapshot: project.snapshot(), lines: lines,
                                   count: deletedCount, seconds: deletedSeconds))
        // 先に字幕の文・単語を消してから、時間を詰める(removeOutputRanges が時刻をずらす)
        project.subtitles = TranscriptEditor.applyDeletion(to: project.subtitles, deleting: items)
        let removed = project.removeOutputRanges(ranges)
        lines = TranscriptEditor.linesAfterDeletion(lines, deleted: selected, ranges: ranges)
        deletedCount += ranges.count
        deletedSeconds += removed
        selected = []
        anchor = nil
        EditorHaptics.success()
        showNotice(String(localized: "\(ranges.count) か所・\(String(format: "%.1f", removed)) 秒を削除しました"))
    }

    private func undoLast() {
        guard let entry = undoStack.popLast() else { return }
        player.pause()
        project.restore(entry.snapshot)
        lines = entry.lines
        deletedCount = entry.count
        deletedSeconds = entry.seconds
        selected = []
        anchor = nil
        noticeTask?.cancel()
        notice = nil
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            notice = message
        }
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                notice = nil
            }
        }
    }
}

// MARK: - 1 行(1 キャプション)

private struct TranscriptLineRow: View {
    let line: TranscriptEditor.Line
    /// この行の中で選んでいる単位の id
    let selected: Set<UUID>
    let onTapItem: (TranscriptEditor.Item) -> Void
    let onTapLine: () -> Void
    let onPlay: (TranscriptEditor.Item) -> Void

    private var isAllSelected: Bool {
        let alive = line.items.filter { !$0.isDeleted }
        return !alive.isEmpty && alive.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onTapLine) {
                VStack(spacing: 4) {
                    Image(systemName: line.isAllDeleted ? "xmark.circle" : (isAllSelected ? "checkmark.circle.fill" : "circle"))
                        .font(.body)
                        .foregroundStyle(isAllSelected ? Color.accentColor : Color.secondary)
                    Text(transcriptTimeString(line.start))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(line.isAllDeleted)
            .accessibilityLabel("行を選ぶ")

            if line.hasWordTimings {
                TranscriptFlowLayout(spacingX: 2, spacingY: 6) {
                    ForEach(line.items) { item in
                        TranscriptWordChip(item: item, isSelected: selected.contains(item.id))
                            .onTapGesture { onTapItem(item) }
                            .onLongPressGesture(minimumDuration: 0.4) { onPlay(item) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let item = line.items.first {
                Text(item.text)
                    .font(.body)
                    .strikethrough(item.isDeleted, color: .secondary)
                    .underline(item.isSuspicious && !item.isDeleted, pattern: .dot, color: .orange)
                    .foregroundStyle(item.isDeleted ? Color.secondary.opacity(0.6)
                                     : (selected.contains(item.id) ? Color.white : Color.primary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected.contains(item.id) ? Color.accentColor.opacity(0.85) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { onTapItem(item) }
                    .onLongPressGesture(minimumDuration: 0.4) { onPlay(item) }
            }
        }
    }
}

// MARK: - 単語のチップ

private struct TranscriptWordChip: View {
    let item: TranscriptEditor.Item
    let isSelected: Bool

    var body: some View {
        Text(item.text)
            .font(.body)
            .strikethrough(item.isDeleted, color: .secondary)
            .underline(item.isSuspicious && !item.isDeleted, pattern: .dot, color: .orange)
            .foregroundStyle(item.isDeleted ? Color.secondary.opacity(0.6) : (isSelected ? Color.white : Color.primary))
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(isSelected ? Color.accentColor.opacity(0.85) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}

// MARK: - 折り返しの並び

/// 単語のチップを左から右に並べ、幅に入らなければ次の行に折り返す
struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 2
    var spacingY: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = limit(proposal.width)
        let frames = frames(for: subviews, maxWidth: maxWidth)
        let height = frames.map { $0.maxY }.max() ?? 0
        let usedWidth = frames.map { $0.maxX }.max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(for: subviews, maxWidth: bounds.width)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func limit(_ width: CGFloat?) -> CGFloat {
        if let width, width.isFinite, width > 0 { return width }
        return .infinity
    }

    private func frames(for subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            result.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return result
    }
}
