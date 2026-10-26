import SwiftUI
import CoreText

/// Google Fonts を探して入れる画面(各フォントの見本をそのフォントで表示)
struct GoogleFontsBrowser: View {
    /// 入れたフォントの PostScript 名(先頭が通常)を返す
    let onInstalled: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var families: [GoogleFontFamily] = []
    @State private var loading = true
    /// 一覧を読み込めなかったとき(一覧の代わりに出す。「再試行」で読み直す)
    @State private var errorText: String?
    /// 「再試行」のたびに増やして .task(id:) を再実行する
    @State private var loadAttempt = 0
    /// フォントを入れられなかったとき(一覧はそのまま、アラートで知らせる)
    @State private var installErrorText: String?
    @State private var query = ""
    @State private var japaneseOnly = true
    @State private var category = String(localized: "すべて")
    @State private var installing: String?
    @State private var installed: Set<String> = GoogleFontsService.installedFamilies()

    private var categories: [String] {
        [String(localized: "すべて")] + Array(Set(scope.map { $0.categoryName })).sorted()
    }

    private var scope: [GoogleFontFamily] {
        families.filter { $0.japanese == japaneseOnly }
    }

    private var shown: [GoogleFontFamily] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return scope.filter { item in
            (category == String(localized: "すべて") || item.categoryName == category)
                && (q.isEmpty || item.family.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("言語", selection: $japaneseOnly) {
                    Text("日本語").tag(true)
                    Text("英語").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { name in
                            EditorChip(title: name, isSelected: category == name) { category = name }
                        }
                    }
                    .padding(.horizontal)
                }
                if loading {
                    ProgressView("フォントの一覧を読み込んでいます…").frame(maxHeight: .infinity)
                } else if let errorText {
                    VStack(spacing: 12) {
                        Text(errorText)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("再試行") {
                            loadAttempt += 1
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxHeight: .infinity)
                } else {
                    List(shown) { family in
                        GoogleFontRow(family: family,
                                      isInstalled: installed.contains(family.family),
                                      isInstalling: installing == family.family) {
                            install(family)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: String(localized: "フォント名で探す"))
            .navigationTitle("フォントを探す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            // 開いたときと「再試行」のたびに一覧を読み直す
            .task(id: loadAttempt) {
                loading = true
                errorText = nil
                do {
                    families = try await GoogleFontsService.loadCatalog()
                } catch {
                    errorText = error.localizedDescription
                }
                loading = false
            }
            .onChange(of: japaneseOnly) { _, _ in category = String(localized: "すべて") }
            .alert("フォントを追加できませんでした", isPresented: Binding(
                get: { installErrorText != nil },
                set: { if !$0 { installErrorText = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(installErrorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func install(_ family: GoogleFontFamily) {
        installing = family.family
        Task { @MainActor in
            defer { installing = nil }
            do {
                let names = try await GoogleFontsService.install(family)
                installed.insert(family.family)
                if let first = names.first {
                    onInstalled(first)
                }
            } catch {
                installErrorText = String(localized: "もう一度「追加」を押してください。\n\n詳細: ") + error.localizedDescription
            }
        }
    }
}

/// 1 行: そのフォントで書いた見本 + 名前 + 追加ボタン
private struct GoogleFontRow: View {
    let family: GoogleFontFamily
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void

    @State private var preview: CTFont?

    private var sampleText: String {
        family.japanese ? String(localized: "あいう 動画編集 Aa") : "The quick fox 123"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let preview {
                        Text(sampleText).font(Font(preview))
                    } else {
                        Text(sampleText).font(.system(size: 22)).foregroundStyle(.secondary).redacted(reason: .placeholder)
                    }
                }
                .lineLimit(1)
                Text(family.family + " ・ " + family.categoryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalled {
                Label("追加済み", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .font(.title3)
            } else if isInstalling {
                ProgressView()
            } else {
                Button("追加", action: onInstall)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .task(id: family.family) {
            preview = await GoogleFontsService.previewFont(for: family, text: sampleText, size: 22)
        }
    }
}
