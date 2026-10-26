import SwiftUI
import UIKit

// =====================================================================
// 「文字起こしとAI仕上げ」の設定画面
//
// - エンジン(Apple / Whisper / クラウドAI)の選択と説明
// - Whisper モデルの選択・ダウンロード(進捗)・削除
// - OpenAI API キー(Keychain 保存、保存後は末尾 4 文字のみ表示。ポイントで使っている間は折りたたむ)
// - AI 仕上げの ON/OFF とエンジン
// プライバシー・サポート用の情報は「設定」(AppSettingsView)にある。
//
// 使い方: NavigationStack の中に `TranscriptionSettingsView()` を置く(push)。
// シートで出すときは `TranscriptionSettingsSheet()`(NavigationStack + 完了ボタン付き)。
// =====================================================================

struct TranscriptionSettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var account = AccountService.shared

    // API キー入力
    @State private var keyDraft: String = ""
    @State private var isEditingKey: Bool = false
    /// ポイントで使っている間、自分のキーの欄を開いているか
    @State private var showsOwnKey: Bool = false
    @State private var showsKeyDeleteConfirmation: Bool = false

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

    // 前回の文字起こし結果
    @State private var cachedTranscriptCount: Int = 0
    // 用語の登録
    @State private var termCount: Int = 0

    init() {}

    var body: some View {
        Form {
            engineSection
            if settings.transcriptionEngine == .whisper {
                whisperSection
            }
            // ポイントのサーバーが無いビルド(準備中)では出さない(「設定」・一覧と同じ)
            if account.isAvailable {
                AccountPointsSection()
            }
            cloudSection
            polishSection
            termSection
            transcriptCacheSection
        }
        .navigationTitle("文字起こしとAI仕上げ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshModelState()
            cachedTranscriptCount = TranscriptCache.shared.storedCount
            termCount = CaptionTermDictionary.load().count
        }
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
        .confirmationDialog("OpenAI の API キーを削除しますか?",
                            isPresented: $showsKeyDeleteConfirmation, titleVisibility: .visible) {
            Button("削除", role: .destructive) { deleteKey() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("もう一度使うときは入力し直してください。")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } })
    }

    /// クラウド AI をポイントで使っている(isSignedIn も読んで、サインイン・サインアウトで描き直す)
    private var usesPoints: Bool {
        account.isSignedIn && account.usesPoints
    }

    // MARK: - 用語の登録

    private var termSection: some View {
        Section {
            NavigationLink {
                CaptionTermListView()
            } label: {
                LabeledContent("用語の登録") {
                    Text(verbatim: "\(termCount)")
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - 前回の文字起こし結果

    private var transcriptCacheSection: some View {
        Section {
            Button(role: .destructive) {
                TranscriptCache.shared.removeAll()
                cachedTranscriptCount = 0
            } label: {
                HStack {
                    Text("前回の文字起こし結果を消す")
                    Spacer()
                    Text(verbatim: "\(cachedTranscriptCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(cachedTranscriptCount == 0)
        } footer: {
            Text("同じクリップは前回の結果を使い、音声を送り直しません。")
        }
    }

    // MARK: - エンジン

    private var engineSection: some View {
        Section {
            Picker("方式", selection: $settings.transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            EngineDescriptionView(engine: settings.transcriptionEngine)
                .padding(.vertical, 4)

            if settings.transcriptionEngine == .whisper, !WhisperTranscriber.isAvailable {
                Label("このビルドには Whisper(WhisperKit)が含まれていません。別の方式を選んでください。",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if settings.transcriptionEngine == .cloud, !settings.isCloudConfigured {
                Label(cloudNotConfiguredHint, systemImage: "key")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("文字起こしの方式")
        } footer: {
            Text("迷ったら Apple で十分です。")
        }
    }

    /// クラウドAI を選んだのに使えないときの案内(サインイン・ポイントの設定・キーのどれで使えるようになるか)
    private var cloudNotConfiguredHint: String {
        if !account.isAvailable {
            return String(localized: "クラウドAI を使うには下の API キーを設定してください。")
        }
        if account.isSignedIn {
            return String(localized: "クラウドAI を使うには「アカウントとポイント」でポイントを使う設定にするか、下に API キーを入れてください。")
        }
        return String(localized: "クラウドAI を使うには、サインインするか下に API キーを入れてください。")
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
                    Text(downloadStatus.isEmpty ? String(localized: "ダウンロード中…") : downloadStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("キャンセル", role: .destructive) { cancelDownload() }
            } else {
                Button {
                    startDownload()
                } label: {
                    Label(downloadedModels.contains(settings.whisperModel) ? String(localized: "ダウンロード済み") : String(localized: "モデルをダウンロード"),
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
            Text("初回は文字起こしの開始時に自動でダウンロードします。Wi-Fi 推奨。")
        }
    }

    // MARK: - クラウドAI

    private var cloudSection: some View {
        Section {
            if settings.transcriptionEngine == .cloud {
                Picker("クラウドの精度", selection: $settings.cloudQuality) {
                    ForEach(CloudTranscriptionQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text(settings.cloudQuality.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if usesPoints {
                // ポイントで使っている間、自分のキーの欄は折りたたんでおく(サインイン前・ポイントが使えないビルドではそのまま出す)
                DisclosureGroup("自分の OpenAI キーを使う", isExpanded: $showsOwnKey) {
                    ownKeyRows
                }
            } else {
                ownKeyRows
            }
        } header: {
            if usesPoints {
                Text("クラウドAI")
            } else {
                Text("クラウドAI(OpenAI)")
            }
        } footer: {
            if usesPoints {
                Text("音声と字幕テキストはサーバーを通して OpenAI に送られます。")
            } else {
                Text("音声と字幕テキストは OpenAI に送られ、使った分だけ OpenAI から請求されます。")
            }
        }
    }

    /// 自分の OpenAI キー(説明・入力・変更・削除・取得のリンク)
    @ViewBuilder
    private var ownKeyRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API キーとは")
                .font(.subheadline.weight(.semibold))
            Text("OpenAI のサイトの「API keys」で作る、「sk-」で始まる文字列です。使った分だけ OpenAI から請求されます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)

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
                showsKeyDeleteConfirmation = true
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
    }

    // MARK: - AI 仕上げ

    private var polishSection: some View {
        Section {
            Toggle("AI で字幕を仕上げる", isOn: $settings.polishSubtitles)

            Picker("仕上げに使うAI", selection: $settings.polishEngine) {
                ForEach(PolishEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .disabled(!settings.polishSubtitles)

            Text(settings.polishEngine.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("実際に使われるAI")
                Spacer()
                Text(settings.polishSubtitles
                     ? SubtitlePolisher.displayName(of: SubtitlePolisher.resolveEngine(settings: settings))
                     : String(localized: "なし"))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 仕上げ")
        } footer: {
            Text("句読点の補正・言いよどみの削除・長い字幕の分割を AI が行います。")
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
        downloadStatus = String(localized: "準備中…")
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
                    showAlert(title: String(localized: "ダウンロードに失敗しました"), message: message)
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
        downloadStatus = String(localized: "キャンセル中…")
    }

    private func deleteModels() {
        WhisperTranscriber.shared.deleteDownloadedModels()
        refreshModelState()
    }

    /// 「キーを削除」の確認のあと
    private func deleteKey() {
        settings.openAIKey = ""
        keyDraft = ""
        isEditingKey = false
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.openAIKey = trimmed
        keyDraft = ""
        isEditingKey = false
        if trimmed.hasPrefix("sk-") {
            showAlert(title: String(localized: "保存しました"), message: String(localized: "API キーをこの端末の Keychain に保存しました。"))
        } else {
            showAlert(title: String(localized: "保存しました"),
                      message: String(localized: "OpenAI の API キーは通常「sk-」で始まります。キーが正しいか確認してください。"))
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
            Label(isDownloaded ? String(localized: "ダウンロード済み") : String(localized: "未ダウンロード"),
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
