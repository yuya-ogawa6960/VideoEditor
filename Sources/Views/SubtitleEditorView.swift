import SwiftUI
import Observation

// MARK: - ヘルパー

/// 秒 → "m:ss.s"
fileprivate func subtitleTimeString(_ seconds: Double) -> String {
    let s = max(0, seconds.isFinite ? seconds : 0)
    let tenths = Int((s * 10).rounded())
    let minutes = tenths / 600
    let secs = (tenths % 600) / 10
    let frac = tenths % 10
    return String(format: "%d:%02d.%d", minutes, secs, frac)
}

// MARK: - 字幕エディタ

struct SubtitleEditorView: View {
    @Bindable var project: EditorProject
    let player: PlayerController

    @Environment(\.dismiss) private var dismiss

    @State private var transcriber = TranscriptionService()
    @State private var selectedLanguage: TranscriptionLanguage = .japanese
    @State private var replaceExisting: Bool = true
    @State private var transcriptionTask: Task<Void, Never>?

    @State private var translationRequest: TranslationRequest?

    @State private var editingCueID: UUID?

    @State private var alertTitle: String = ""
    @State private var alertMessage: String?

    private var isTranscribing: Bool {
        transcriptionTask != nil || transcriber.isRunning
    }

    private var isTranslating: Bool {
        translationRequest != nil
    }

    private var currentCueID: UUID? {
        let t = player.currentTime
        return project.subtitles.first(where: { t >= $0.start && t < $0.end })?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewHeader
                Form {
                    transcriptionSection
                    translationSection
                    styleSection
                    cueListSection
                }
            }
            .navigationTitle("字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .navigationDestination(item: $editingCueID) { cueID in
                SubtitleCueEditView(project: project, player: player, cueID: cueID)
            }
        }
        .subtitleTranslation(project: project, request: $translationRequest, onFinish: { result in
            switch result {
            case .success(let count):
                showAlert(title: "翻訳完了",
                          message: "\(count) 件の字幕を翻訳しました。表示を「英訳」または「両方」にすると映像に表示されます。")
            case .failure(let error):
                showAlert(title: "翻訳エラー", message: error.localizedDescription)
            }
        })
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        .onDisappear {
            cancelTranscription()
        }
    }

    // MARK: プレビュー

    private var previewHeader: some View {
        VStack(spacing: 6) {
            PreviewView(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.black)
            HStack(spacing: 16) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 32)
                }
                Text("\(subtitleTimeString(player.currentTime)) / \(subtitleTimeString(player.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 4)
    }

    // MARK: 自動文字起こし

    private var transcriptionSection: some View {
        Section {
            Picker("言語", selection: $selectedLanguage) {
                ForEach(TranscriptionLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .disabled(isTranscribing)

            Picker("既存の字幕", selection: $replaceExisting) {
                Text("置き換え").tag(true)
                Text("追加").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(isTranscribing)

            if isTranscribing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(transcriber.progress, 0), 1))
                    Text(transcriber.statusText.isEmpty ? "準備中…" : transcriber.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("キャンセル", role: .destructive) {
                    cancelTranscription()
                }
            } else {
                Button {
                    startTranscription()
                } label: {
                    Label("文字起こしを開始", systemImage: "waveform")
                }
                .disabled(project.isEmpty || isTranslating)
            }
        } header: {
            Text("自動文字起こし")
        } footer: {
            Text("動画の音声から字幕を自動作成します。対応端末ではオンデバイスで処理します。")
        }
    }

    private func startTranscription() {
        guard transcriptionTask == nil else { return }
        let snapshot = project.snapshot()
        let language = selectedLanguage
        let replace = replaceExisting
        transcriptionTask = Task { @MainActor in
            let authorized = await transcriber.requestAuthorization()
            guard authorized else {
                transcriptionTask = nil
                showAlert(title: "音声認識を利用できません",
                          message: "音声認識が許可されていません。設定アプリでこのアプリの音声認識を許可してください。")
                return
            }
            if Task.isCancelled {
                transcriptionTask = nil
                return
            }
            do {
                let cues = try await transcriber.transcribe(snapshot: snapshot, language: language)
                if Task.isCancelled {
                    transcriptionTask = nil
                    return
                }
                if replace {
                    project.subtitles = cues
                } else {
                    project.subtitles.append(contentsOf: cues)
                }
                project.sortSubtitles()
                transcriptionTask = nil
                if cues.isEmpty {
                    showAlert(title: "文字起こし完了", message: "音声が検出されませんでした。")
                }
            } catch is CancellationError {
                transcriptionTask = nil
            } catch {
                let cancelled = Task.isCancelled
                transcriptionTask = nil
                if !cancelled {
                    showAlert(title: "文字起こしエラー", message: error.localizedDescription)
                }
            }
        }
    }

    private func cancelTranscription() {
        if transcriber.isRunning {
            transcriber.cancel()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    // MARK: 翻訳

    private var translationSection: some View {
        Section {
            if isTranslating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("翻訳中…")
                        .foregroundStyle(.secondary)
                }
            } else if selectedLanguage == .english {
                Button {
                    translationRequest = TranslationRequest(source: selectedLanguage, targetIsEnglish: false)
                } label: {
                    Label("日本語に翻訳", systemImage: "globe")
                }
                .disabled(project.subtitles.isEmpty || isTranscribing)
            } else {
                Button {
                    translationRequest = TranslationRequest(source: selectedLanguage, targetIsEnglish: true)
                } label: {
                    Label("英語に翻訳", systemImage: "globe")
                }
                .disabled(project.subtitles.isEmpty || isTranscribing)
            }
        } header: {
            Text("翻訳")
        } footer: {
            Text("原文の言語は「自動文字起こし」の言語設定を使います。初回は翻訳用の言語データのダウンロードを求められることがあります。")
        }
    }

    // MARK: スタイル

    private var styleSection: some View {
        Section {
            Picker("位置", selection: $project.subtitleStyle.position) {
                ForEach(SubtitlePosition.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Picker("文字色", selection: $project.subtitleStyle.color) {
                ForEach(SubtitleColor.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("文字サイズ")
                    Spacer()
                    Text("\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.subtitleStyle.sizeRatio, in: 0.03...0.10)
            }

            Toggle("背景を付ける", isOn: $project.subtitleStyle.hasBackground)

            Picker("表示", selection: $project.subtitleStyle.displayMode) {
                ForEach(SubtitleDisplayMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("スタイル")
        }
    }

    // MARK: 字幕一覧

    private var cueListSection: some View {
        Section {
            Button {
                let cue = project.addSubtitle(at: player.currentTime)
                editingCueID = cue.id
            } label: {
                Label("再生位置に追加", systemImage: "plus.bubble")
            }

            if project.subtitles.isEmpty {
                Text("字幕はまだありません。「再生位置に追加」または自動文字起こしで作成できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let highlightedID = currentCueID
                ForEach(project.subtitles) { cue in
                    cueRow(cue, isCurrent: cue.id == highlightedID)
                }
                .onDelete { offsets in
                    project.subtitles.remove(atOffsets: offsets)
                }
            }
        } header: {
            Text("字幕一覧(\(project.subtitles.count))")
        }
    }

    private func cueRow(_ cue: SubtitleCue, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                player.seek(to: cue.start)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(subtitleTimeString(cue.start)) – \(subtitleTimeString(cue.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    Text(cue.text.isEmpty ? "(空)" : cue.text)
                        .foregroundStyle(Color.primary)
                        .lineLimit(3)
                    if let translated = cue.translatedText, !translated.isEmpty {
                        Text(translated)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button {
                editingCueID = cue.id
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }
}

// MARK: - 字幕1件の編集画面

struct SubtitleCueEditView: View {
    let project: EditorProject
    let player: PlayerController
    let cueID: UUID

    @Environment(\.dismiss) private var dismiss

    private let minimumLength: Double = 0.2

    var body: some View {
        Group {
            if let binding = project.subtitleBinding(id: cueID) {
                editor(binding)
            } else {
                Text("この字幕は削除されました。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("字幕を編集")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editor(_ cue: Binding<SubtitleCue>) -> some View {
        Form {
            Section {
                TextField("字幕のテキスト", text: cue.text, axis: .vertical)
                    .lineLimit(1...6)
            } header: {
                Text("テキスト")
            }

            Section {
                TextField("翻訳(任意)", text: Binding(
                    get: { cue.wrappedValue.translatedText ?? "" },
                    set: { newValue in
                        var c = cue.wrappedValue
                        c.translatedText = newValue.isEmpty ? nil : newValue
                        cue.wrappedValue = c
                    }
                ), axis: .vertical)
                .lineLimit(1...6)
            } header: {
                Text("翻訳")
            }

            Section {
                Stepper("開始 " + subtitleTimeString(cue.wrappedValue.start),
                        onIncrement: { setStart(cue, cue.wrappedValue.start + 0.1) },
                        onDecrement: { setStart(cue, cue.wrappedValue.start - 0.1) })
                HStack {
                    Button("再生位置にする") {
                        setStart(cue, player.currentTime)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("ここへ移動") {
                        player.seek(to: cue.wrappedValue.start)
                    }
                    .buttonStyle(.borderless)
                }

                Stepper("終了 " + subtitleTimeString(cue.wrappedValue.end),
                        onIncrement: { setEnd(cue, cue.wrappedValue.end + 0.1) },
                        onDecrement: { setEnd(cue, cue.wrappedValue.end - 0.1) })
                HStack {
                    Button("再生位置にする") {
                        setEnd(cue, player.currentTime)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("ここへ移動") {
                        player.seek(to: max(cue.wrappedValue.start, cue.wrappedValue.end - 0.1))
                    }
                    .buttonStyle(.borderless)
                }

                Text("長さ \(String(format: "%.1f", cue.wrappedValue.duration)) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("タイミング")
            } footer: {
                Text("現在の再生位置: \(subtitleTimeString(player.currentTime))")
            }

            Section {
                Button(role: .destructive) {
                    project.removeSubtitle(id: cueID)
                    dismiss()
                } label: {
                    Label("この字幕を削除", systemImage: "trash")
                }
            }
        }
    }

    private func setStart(_ cue: Binding<SubtitleCue>, _ value: Double) {
        var c = cue.wrappedValue
        c.start = max(0, value)
        if c.end < c.start + minimumLength {
            c.end = c.start + minimumLength
        }
        cue.wrappedValue = c
        project.sortSubtitles()
    }

    private func setEnd(_ cue: Binding<SubtitleCue>, _ value: Double) {
        var c = cue.wrappedValue
        c.end = max(value, c.start + minimumLength)
        cue.wrappedValue = c
        project.sortSubtitles()
    }
}
