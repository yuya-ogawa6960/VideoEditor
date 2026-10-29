import SwiftUI

// =====================================================================
// テキスト編集パネルの「スタイル」行(TextStylePresetStore.swift)。
// コピー / 貼り付け / すべてのテキストに適用 / 保存… と、保存したスタイル(マイスタイル)の一覧。
// 字幕(キャプション)は別物なので、ここでは触らない。
// =====================================================================

struct TextStyleClipboardRow: View {
    let project: EditorProject
    /// 貼り付け・すべてに適用の前に記録する(↶ で 1 手ずつ戻せるように)。nil ならパネルを開いたときの記録だけ
    let history: EditorHistory?
    @Binding var text: TextClip

    @State private var isNaming = false
    @State private var saveName = ""
    /// 直前の操作の結果(2 秒ほどで消える)
    @State private var message: String?
    @State private var messageID = UUID()

    private var store: TextStylePresetStore { TextStylePresetStore.shared }

    /// スタイルを写せるほかのテキスト(ステッカー・モザイクは見た目が別物なので除く)
    private var otherTextIndices: [Int] {
        project.textClips.indices.filter { i in
            let t = project.textClips[i]
            return t.id != text.id && !t.isSticker && t.mosaic == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "スタイル"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    EditorChip(title: String(localized: "コピー"), isSelected: false) {
                        store.copy(TextLook(from: text))
                        flash(String(localized: "スタイルをコピーしました"))
                    }
                    EditorChip(title: String(localized: "貼り付け"), isSelected: false) {
                        paste()
                    }
                    .disabled(!store.hasClipboard)
                    .opacity(store.hasClipboard ? 1 : 0.5)
                    EditorChip(title: String(localized: "すべてのテキストに適用"), isSelected: false) {
                        applyToAll()
                    }
                    .disabled(otherTextIndices.isEmpty)
                    .opacity(otherTextIndices.isEmpty ? 0.5 : 1)
                    EditorChip(title: String(localized: "保存…"), isSelected: false) {
                        saveName = store.nextDefaultName
                        isNaming = true
                    }
                }
                .padding(.vertical, 2)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.saved) { saved in
                            EditorVisualTile(title: saved.name,
                                             isSelected: saved.look == TextLook(from: text)) {
                                apply(saved.look)
                                flash(String(localized: "「\(saved.name)」を適用しました"))
                            } preview: {
                                SavedTextStylePreview(look: saved.look)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.delete(id: saved.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .alert("スタイルの名前", isPresented: $isNaming) {
            TextField(String(localized: "マイスタイル"), text: $saveName)
            Button("キャンセル", role: .cancel) {}
            Button("保存") {
                let saved = store.save(name: saveName, look: TextLook(from: text))
                flash(String(localized: "「\(saved.name)」として保存しました"))
            }
        } message: {
            Text("今の見た目(フォント・色・縁・影・背景・アニメーション)を名前を付けて保存します。")
        }
    }

    // MARK: - 操作

    private func paste() {
        guard let look = store.clipboard else { return }
        history?.record(project)
        look.apply(to: &text)
        flash(String(localized: "スタイルを貼り付けました"))
    }

    private func apply(_ look: TextLook) {
        history?.record(project)
        look.apply(to: &text)
    }

    /// このテキストの見た目を、ほかのすべてのテキスト(ステッカー・モザイク以外)に写す
    private func applyToAll() {
        let targets = otherTextIndices
        guard !targets.isEmpty else { return }
        let look = TextLook(from: text)
        history?.record(project)
        for i in targets {
            look.apply(to: &project.textClips[i])
        }
        flash(String(localized: "\(targets.count) 個のテキストに適用しました"))
    }

    private func flash(_ text: String) {
        let id = UUID()
        messageID = id
        message = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if messageID == id { message = nil }
        }
    }
}

/// 保存したスタイルのタイル(「Aa」をそのスタイルの色・フォント・縁・背景で描く)
private struct SavedTextStylePreview: View {
    let look: TextLook

    var body: some View {
        let style = look.style
        let fill = EditorColorHex.color(style.colorHex)
        let stroke = style.strokeColorHex.map { EditorColorHex.color($0, fallback: .black) }
        ZStack {
            LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.55), Color(red: 0.16, green: 0.2, blue: 0.26)],
                           startPoint: .top, endPoint: .bottom)
            Text("Aa")
                .font(previewFont(style, size: style.sizeRatio >= 0.1 ? 20 : (style.sizeRatio >= 0.06 ? 17 : 14)))
                .foregroundStyle(fill)
                .shadow(color: stroke ?? .clear, radius: 0, x: 1, y: 1)
                .shadow(color: stroke ?? .clear, radius: 0, x: -1, y: -1)
                .shadow(color: stroke ?? .clear, radius: 0, x: 1, y: -1)
                .shadow(color: stroke ?? .clear, radius: 0, x: -1, y: 1)
                .shadow(color: style.shadow.enabled && stroke == nil && style.backgroundColorHex == nil ? .black.opacity(0.6) : .clear,
                        radius: 1)
                .padding(.horizontal, style.backgroundColorHex == nil ? 0 : 6)
                .padding(.vertical, style.backgroundColorHex == nil ? 0 : 2)
                .background {
                    if let bg = style.backgroundColorHex {
                        RoundedRectangle(cornerRadius: CGFloat(style.backgroundCornerRadius) * 10)
                            .fill(EditorColorHex.color(bg, fallback: .black).opacity(style.backgroundOpacity))
                    }
                }
        }
    }

    private func previewFont(_ style: TextStyle, size: CGFloat) -> Font {
        if let name = style.fontName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: style.bold ? .heavy : .regular)
    }
}
