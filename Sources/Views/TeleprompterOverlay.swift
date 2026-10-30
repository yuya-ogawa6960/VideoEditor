import SwiftUI

// =====================================================================
// テレプロンプター(CameraRecorderView のプレビューの上に重ねる半透明の台本)
// - 録画が始まると自動で流れ、止めると止まる(isScrolling)。指で上下にずらせる
// - 速さ(ゆっくり / ふつう / 速い)・文字サイズ(小 / 中 / 大)・鏡(ミラーリグ用)は @AppStorage に残す
// - 台本の文章は TeleprompterScriptSheet で入れる(最後の台本を @AppStorage に残す。AI 台本があればそこから取れる)
// =====================================================================

struct TeleprompterOverlay: View {
    let script: String
    /// 流す(録画中)
    let isScrolling: Bool
    /// 「台本」ボタン(文章の入力シートを開く)
    let onEdit: () -> Void

    @AppStorage(TeleprompterSettingsKey.speed) private var speed: TeleprompterSpeed = .normal
    @AppStorage(TeleprompterSettingsKey.fontSize) private var fontSize: TeleprompterFontSize = .medium
    @AppStorage(TeleprompterSettingsKey.mirror) private var isMirrored = false

    /// 流し始めてからの分と指の分を除いた、いままでに流れた高さ
    @State private var baseOffset: CGFloat = 0
    /// 流し始めた時刻(流していないときは nil)
    @State private var scrollStart: Date?
    /// 指でずらしている途中の量
    @State private var dragOffset: CGFloat = 0
    /// 文章全体の高さ(上下の余白を含む)
    @State private var textHeight: CGFloat = 0
    /// 文章を見せている部分の高さ
    @State private var areaHeight: CGFloat = 0

    /// 1 秒に流れる高さ
    private var pointsPerSecond: CGFloat {
        CGFloat(fontSize.lineHeight * speed.linesPerSecond)
    }

    /// 読む位置(上から 30%)
    private var guideY: CGFloat { areaHeight * 0.3 }

    var body: some View {
        VStack(spacing: 0) {
            if script.isEmpty {
                emptyRow
            } else {
                textArea
                controls
            }
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: isScrolling) { _, scrolling in
            // 止めるときは、ここまで流れた分を baseOffset に残す(onChange の中では isScrolling がもう新しい値なので、自分で畳む)
            if let start = scrollStart {
                baseOffset = clamp(baseOffset + CGFloat(Date().timeIntervalSince(start)) * pointsPerSecond)
            }
            scrollStart = scrolling ? Date() : nil
        }
        // 速さ・文字サイズを変えても飛ばないように、ここまでの分は前の速さで畳む
        .onChange(of: speed) { old, _ in
            fold(pointsPerSecond: CGFloat(fontSize.lineHeight * old.linesPerSecond))
        }
        .onChange(of: fontSize) { old, _ in
            fold(pointsPerSecond: CGFloat(old.lineHeight * speed.linesPerSecond))
        }
        .onChange(of: script) { _, _ in
            baseOffset = 0
            dragOffset = 0
            scrollStart = isScrolling ? Date() : nil
        }
    }

    // MARK: - 文章

    private var textArea: some View {
        // 文章は Color.clear の上に重ねる(overlay)。文章の高さが枠の高さに影響しないようにするため。
        // 以前は 文章の高さ → 上下の余白 → 枠の高さ → 余白… と伸び続けて画面が固まった(台本が入っているとカメラ画面が開けなかった)
        Color.clear
            .overlay(alignment: .top) {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isScrolling)) { context in
                    let offset = currentOffset(at: context.date)
                    Text(script)
                        .font(.system(size: fontSize.pointSize, weight: .semibold))
                        .lineSpacing(fontSize.pointSize * 0.4)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        // 最初の行が読む位置から始まり、最後の行まで読む位置に来られるように上下を空ける
                        .padding(.top, guideY)
                        .padding(.bottom, max(0, areaHeight - guideY))
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            textHeight = height
                        }
                        .offset(y: -offset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .top) {
                // 読む位置の目印
                Rectangle()
                    .fill(BrandStyle.coral.opacity(0.8))
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .padding(.top, guideY)
                    .allowsHitTesting(false)
            }
            .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        dragOffset = -value.translation.height
                    }
                    .onEnded { value in
                        fold(pointsPerSecond: pointsPerSecond)
                        dragOffset = 0
                        baseOffset = clamp(baseOffset - value.translation.height)
                    }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                areaHeight = height
            }
            .accessibilityLabel("台本")
    }

    /// いま表示する位置(流している分と指の分を足して、文章の範囲に収める)
    private func currentOffset(at date: Date) -> CGFloat {
        var offset = baseOffset + dragOffset
        if isScrolling, let start = scrollStart {
            offset += CGFloat(date.timeIntervalSince(start)) * pointsPerSecond
        }
        return clamp(offset)
    }

    /// 流している分を pointsPerSecond の速さで baseOffset に足し込み、いまから流し直す(流していなければ何もしない)
    private func fold(pointsPerSecond: CGFloat) {
        guard let start = scrollStart else { return }
        baseOffset = clamp(baseOffset + CGFloat(Date().timeIntervalSince(start)) * pointsPerSecond)
        scrollStart = Date()
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        let maxOffset = max(0, textHeight - areaHeight)
        return min(max(0, value), maxOffset)
    }

    // MARK: - 操作

    private var controls: some View {
        HStack(spacing: 6) {
            ForEach(TeleprompterSpeed.allCases) { item in
                TeleprompterChip(title: item.displayName, systemImage: nil, isSelected: speed == item) {
                    speed = item
                }
            }
            Spacer(minLength: 4)
            TeleprompterChip(title: fontSize.displayName, systemImage: "textformat.size", isSelected: false) {
                fontSize = fontSize.next
            }
            .accessibilityLabel("文字の大きさ")
            TeleprompterChip(title: nil, systemImage: "flip.horizontal", isSelected: isMirrored) {
                isMirrored.toggle()
            }
            .accessibilityLabel("鏡")
            TeleprompterChip(title: String(localized: "台本"), systemImage: "square.and.pencil", isSelected: false) {
                onEdit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyRow: some View {
        Button {
            onEdit()
        } label: {
            Label("台本を入れる", systemImage: "text.alignleft")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// テレプロンプターの小さなボタン(速さ・文字サイズ・鏡・台本)
private struct TeleprompterChip: View {
    let title: String?
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                if let title {
                    Text(title)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? AnyShapeStyle(BrandStyle.gradient) : AnyShapeStyle(Color.white.opacity(0.16)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 台本の入力

/// 台本の文章を入れるシート(最後の台本は @AppStorage に残す。AI 台本(ScriptWriterDraft)があればそこから取れる)
struct TeleprompterScriptSheet: View {
    @AppStorage(TeleprompterSettingsKey.script) private var script = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditing: Bool

    /// AI 台本(ScriptWriterView で作ったもの)。無ければ nil
    private var aiScript: String? {
        let lines = ScriptWriterDraft.lines
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $script)
                    .focused($isEditing)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text("話す内容を入れるか、貼り付けてください")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 12) {
                    if let aiScript {
                        Button {
                            script = aiScript
                        } label: {
                            Label("AI 台本を使う", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        script = ""
                    } label: {
                        Text("消す")
                    }
                    .buttonStyle(.bordered)
                    .disabled(script.isEmpty)
                }
            }
            .padding(16)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .onAppear {
                if script.isEmpty { isEditing = true }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
