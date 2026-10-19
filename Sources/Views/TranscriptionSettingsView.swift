import SwiftUI
import UIKit

// =====================================================================
// 文字起こし設定画面
//
// - エンジン(Apple / Whisper / クラウドAI)の選択と説明
// - Whisper モデルの選択・ダウンロード(進捗)・削除
// - OpenAI API キー(Keychain 保存、保存後は末尾 4 文字のみ表示)
// - AI 仕上げの ON/OFF とエンジン
//
// 使い方: NavigationStack の中に `TranscriptionSettingsView()` を置く(push)。
// シートで出すときは `TranscriptionSettingsSheet()`(NavigationStack + 完了ボタン付き)。
// =====================================================================

struct TranscriptionSettingsView: View {
    @State private var settings = AppSettings.shared

    // API キー入力
    @State private var keyDraft: String = ""
    @State private var isEditingKey: Bool = false

    // Whisper モデル
    @State private var downloadProgress: Double? = nil
    @State private var downloadStatus: String = ""
    @State private var downloadTask: Task<Void, Never>? = nil
    @State private var downloadedModels: Set<String> = []
    @State private var downloadedSize: Int64 = 0
    @State private var showsDeleteConfirmation: Bool = false

    // 通知
    @State private var alertTitle: String = ""
    @State private var alertMessage: String? = nil

    init() {}

    var body: some View {
        Form {
            engineSection
            if settings.transcriptionEngine == .whisper {
                whisperSection
            }
            cloudSection
            polishSection
        }
        .navigationTitle("文字起こし設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshModelState() }
        .alert(alertTitle, isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog("ダウンロード済みの Whisper モデルをすべて削除しますか?",
                            isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("削除", role: .destructive) { deleteModels() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("次に Whisper で文字起こしするときに再ダウンロードされます。")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } })
    }

    // MARK: - エンジン

    private var engineSection: some View {
        Section {
            Picker("エンジン", selection: $settings.transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            EngineDescriptionView(engine: settings.transcriptionEngine)
                .padding(.vertical, 4)

            if settings.transcriptionEngine == .whisper, !WhisperTranscriber.isAvailable {
                Label("このビルドには Whisper(WhisperKit)が含まれていません。別のエンジンを選んでください。",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if settings.transcriptionEngine == .cloud, !settings.isCloudConfigured {
                Label("クラウドAI を使うには下の API キーを設定してください。",
                      systemImage: "key")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("文字起こしエンジン")
        } footer: {
            Text("どのエンジンでも、認識結果は文・文節ごとに区切られ、フィラー(「あのー」など)は自動で除かれます。")
        }
    }

    // MARK: - Whisper

    private var whisperSection: some View {
        Section {
            Picker("モデル", selection: $settings.whisperModel) {
                ForEach(WhisperModelOption.all) { option in
                    Text("\(option.displayName)(\(option.sizeHint))").tag(option.id)
                }
            }

            WhisperModelDetailView(option: WhisperModelOption.option(for: settings.whisperModel),
                                   isDownloaded: downloadedModels.contains(settings.whisperModel))

            if let progress = downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(progress, 0), 1))
                    Text(downloadStatus.isEmpty ? "ダウンロード中…" : downloadStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("キャンセル", role: .destructive) { cancelDownload() }
            } else {
                Button {
                    startDownload()
                } label: {
                    Label(downloadedModels.contains(settings.whisperModel) ? "ダウンロード済み" : "モデルをダウンロード",
                          systemImage: downloadedModels.contains(settings.whisperModel) ? "checkmark.circle" : "arrow.down.circle")
                }
                .disabled(!WhisperTranscriber.isAvailable || downloadedModels.contains(settings.whisperModel))
            }

            if downloadedSize > 0 {
                HStack {
                    Text("保存領域")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: downloadedSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Button("ダウンロード済みモデルを削除", role: .destructive) {
                    showsDeleteConfirmation = true
                }
                .disabled(downloadProgress != nil)
            }
        } header: {
            Text("Whisper モデル")
        } footer: {
            Text("モデルは Wi-Fi 接続でのダウンロードをおすすめします。文字起こし開始時に未ダウンロードなら自動でダウンロードします。large-v3 turbo は最も高精度ですが約 1.6GB で、メモリの少ない端末では読み込めないことがあります。")
        }
    }

    // MARK: - クラウドAI

    private var cloudSection: some View {
        Section {
            Picker("プロバイダ", selection: $settings.cloudProvider) {
                ForEach(CloudProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            if settings.hasOpenAIKey, !isEditingKey {
                HStack {
                    Text("API キー")
                    Spacer()
                    Text(settings.openAIKeyHint)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button("キーを変更") {
                    keyDraft = ""
                    isEditingKey = true
                }
                Button("キーを削除", role: .destructive) {
                    settings.openAIKey = ""
                    keyDraft = ""
                    isEditingKey = false
                }
            } else {
                HStack {
                    SecureField("sk-… を入力", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("貼り付け") {
                        if let pasted = UIPasteboard.general.string {
                            keyDraft = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("保存") { saveKey() }
                        .buttonStyle(.borderless)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasOpenAIKey {
                        Spacer()
                        Button("キャンセル") {
                            keyDraft = ""
                            isEditingKey = false
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let url = URL(string: "https://platform.openai.com/api-keys") {
                Link(destination: url) {
                    Label("API キーを取得(OpenAI)", systemImage: "safari")
                }
            }
        } header: {
            Text("クラウドAI(OpenAI)")
        } footer: {
            Text("クラウドAI を使うと、動画の音声(文字起こし)や字幕テキスト(AI 仕上げ)が OpenAI のサーバーへ送信されます。料金は OpenAI の従量課金で、文字起こしは目安 約0.9円/分($0.006/分換算)です。API キーはこの端末の Keychain にのみ保存され、外部には送られません。")
        }
    }

    // MARK: - AI 仕上げ

    private var polishSection: some View {
        Section {
            Toggle("AI で字幕を仕上げる", isOn: $settings.polishSubtitles)

            Picker("仕上げエンジン", selection: $settings.polishEngine) {
                ForEach(PolishEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .disabled(!settings.polishSubtitles)

            Text(settings.polishEngine.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("実際に使われるエンジン")
                Spacer()
                Text(settings.polishSubtitles
                     ? SubtitlePolisher.displayName(of: SubtitlePolisher.resolveEngine(settings: settings))
                     : "なし")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 仕上げ")
        } footer: {
            Text("音声認識のあとに、句読点の補正・言いよどみの削除・長い字幕の分割を AI が行います。端末内(Apple Intelligence)は iOS 26 以降で Apple Intelligence が有効な端末のみ使えます。クラウドは OpenAI の API キーが必要で、字幕テキストが送信されます。")
        }
    }

    // MARK: - 操作

    private func refreshModelState() {
        let transcriber = WhisperTranscriber.shared
        downloadedModels = Set(transcriber.downloadedModels())
        downloadedSize = transcriber.downloadedSizeBytes()
    }

    private func startDownload() {
        guard downloadTask == nil, WhisperTranscriber.isAvailable else { return }
        let model = settings.whisperModel
        downloadProgress = 0
        downloadStatus = "準備中…"
        downloadTask = Task {
            do {
                try await WhisperTranscriber.shared.download(model: model) { fraction, status in
                    Task { @MainActor in
                        downloadProgress = fraction
                        downloadStatus = status
                    }
                }
                await MainActor.run {
                    finishDownload()
                }
            } catch is CancellationError {
                await MainActor.run {
                    finishDownload()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    finishDownload()
                    showAlert(title: "ダウンロードに失敗しました", message: message)
                }
            }
        }
    }

    private func finishDownload() {
        downloadProgress = nil
        downloadStatus = ""
        downloadTask = nil
        refreshModelState()
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadStatus = "キャンセル中…"
    }

    private func deleteModels() {
        WhisperTranscriber.shared.deleteDownloadedModels()
        refreshModelState()
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.openAIKey = trimmed
        keyDraft = ""
        isEditingKey = false
        if trimmed.hasPrefix("sk-") {
            showAlert(title: "保存しました", message: "API キーをこの端末の Keychain に保存しました。")
        } else {
            showAlert(title: "保存しました",
                      message: "OpenAI の API キーは通常「sk-」で始まります。キーが正しいか確認してください。")
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }
}

// MARK: - 部品

private struct EngineDescriptionView: View {
    let engine: TranscriptionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(engine.pros, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            ForEach(engine.cons, id: \.self) { item in
                Label(item, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct WhisperModelDetailView: View {
    let option: WhisperModelOption?
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let option {
                Text("\(option.displayName) ・ \(option.sizeHint)")
                    .font(.subheadline)
                Text(option.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Label(isDownloaded ? "ダウンロード済み" : "未ダウンロード",
                  systemImage: isDownloaded ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                .font(.footnote)
                .foregroundStyle(isDownloaded ? Color.green : Color.secondary)
        }
    }
}

/// シート表示用(NavigationStack と「完了」ボタン付き)
struct TranscriptionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    init() {}

    var body: some View {
        NavigationStack {
            TranscriptionSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
    }
}
