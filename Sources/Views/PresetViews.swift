import SwiftUI
import Observation

// =====================================================================
// 書き出しプリセット(PresetStore)の UI。
// - ExportPresetBar: 横スクロールのチップ(ユーザーが保存したものだけ)と、最後に「設定を保存」
// - PresetSaveSheet: 名前と含める項目を選んで PresetStore.shared.save(...) を呼ぶ
// ExportView から使う。PresetStore 本体は Sources/Model/PresetStore.swift(別担当)。
// =====================================================================

// MARK: - 表示用ヘルパー

/// プリセットの中身を 1 行で表す(例: 4K・30fps・高画質)。比率はプリセットで変えないので出さない
func exportPresetDetailText(_ canvas: CanvasSettings) -> String {
    "\(canvas.resolution.displayName)・\(canvas.frameRate)fps・\(canvas.quality.displayName)"
}

// MARK: - プリセットバー

/// 書き出し画面の上部に置く横スクロールのプリセット一覧
struct ExportPresetBar: View {
    let project: EditorProject
    var isDisabled: Bool = false

    private let store = PresetStore.shared

    @State private var isSavePresented = false
    @State private var renameTarget: ExportPreset?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var deleteTarget: ExportPreset?
    @State private var isDeleting = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 組み込みのプリセットは出さない(画質は上のタイルで選ぶ)。自分で保存したものだけ
                ForEach(store.presets) { preset in
                    PresetChipView(preset: preset, isSelected: matches(preset), isUserPreset: true) {
                        store.apply(preset, to: project)
                    }
                    .contextMenu {
                        Text(exportPresetDetailText(preset.canvas))
                        Button {
                            beginRename(preset)
                        } label: {
                            Label("名前を変更", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleteTarget = preset
                            isDeleting = true
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }

                saveChip
            }
            .padding(.vertical, 2)
        }
        .disabled(isDisabled)
        .sheet(isPresented: $isSavePresented) {
            PresetSaveSheet(project: project)
        }
        .alert("プリセット名を変更", isPresented: $isRenaming) {
            TextField("プリセット名", text: $renameText)
            Button("キャンセル", role: .cancel) {
                renameTarget = nil
            }
            Button("保存") {
                if let target = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        store.rename(id: target.id, to: trimmed)
                    }
                }
                renameTarget = nil
            }
        }
        .confirmationDialog("「\(deleteTarget?.name ?? "")」を削除しますか?",
                            isPresented: $isDeleting,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let target = deleteTarget {
                    store.delete(id: target.id)
                }
                deleteTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                deleteTarget = nil
            }
        }
    }

    private var saveChip: some View {
        Button {
            isSavePresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text("設定を保存")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func matches(_ preset: ExportPreset) -> Bool {
        store.matches(preset, canvas: project.canvas)
    }

    private func beginRename(_ preset: ExportPreset) {
        renameTarget = preset
        renameText = preset.name
        isRenaming = true
    }
}

// MARK: - チップ

struct PresetChipView: View {
    let preset: ExportPreset
    let isSelected: Bool
    let isUserPreset: Bool
    let action: () -> Void

    var body: some View {
        // 名前だけ。中身は長押しのメニューで見せる
        Button(action: action) {
            Text(preset.name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous)
                        .fill(BrandStyle.surface)
                )
                .brandSelected(isSelected, cornerRadius: BrandStyle.Radius.chip)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - 保存シート

/// 現在のキャンバス設定(と任意で字幕スタイル・ドキュメンタリー風設定)をプリセットとして保存する
struct PresetSaveSheet: View {
    let project: EditorProject

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var includeSubtitleStyle: Bool = true
    @State private var includeDocumentary: Bool = true

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("プリセット名", text: $name)
                        .submitLabel(.done)
                } header: {
                    Text("名前")
                }
                .listRowBackground(Color(white: 0.11))

                Section {
                    LabeledContent("解像度", value: project.canvas.resolution.displayName)
                    LabeledContent("画質", value: project.canvas.quality.displayName)
                    LabeledContent("フレームレート", value: "\(project.canvas.frameRate) fps")
                    LabeledContent("コーデック", value: project.canvas.codec.displayName)
                    LabeledContent("ファイル形式", value: project.canvas.fileFormat.displayName)
                } header: {
                    Text("保存する設定")
                }
                .listRowBackground(Color(white: 0.11))

                Section {
                    Toggle("キャプションのスタイルも含める", isOn: $includeSubtitleStyle)
                    Toggle("ドキュメンタリー風の設定も含める", isOn: $includeDocumentary)
                }
                .listRowBackground(Color(white: 0.11))
            }
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.07))
            .navigationTitle("設定を保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear {
                if name.isEmpty {
                    name = defaultName()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func defaultName() -> String {
        let existing = Set(PresetStore.shared.presets.map { $0.name })
        var n = PresetStore.shared.presets.count + 1
        var candidate = String(localized: "マイプリセット \(n)")
        while existing.contains(candidate) {
            n += 1
            candidate = String(localized: "マイプリセット \(n)")
        }
        return candidate
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        _ = PresetStore.shared.save(name: trimmedName,
                                    canvas: project.canvas,
                                    subtitleStyle: includeSubtitleStyle ? project.subtitleStyle : nil,
                                    documentary: includeDocumentary ? project.documentary : nil)
        dismiss()
    }
}
