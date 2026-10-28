import SwiftUI
import UIKit
import AVFoundation
import Observation

// =====================================================================
// 第4弾: AI 台本
//   テーマ・長さ・口調から ScriptWriter.write で台本(時刻つきの行)を作り、
//   行を直してから「ナレーションとして挿入」(TextToSpeech → ナレーション)/「キャプションとして挿入」(SubtitleCue)。
//   「キャプションから構成案」は ScriptWriter.outline でチャプターのマーカーを追加する。
//   作った台本はシートを閉じても ScriptWriterDraft に残す(次に開いたときに戻る)。
// =====================================================================

/// 閉じても台本が消えないように、シートの外に残しておく下書き(TextToSpeechDraft と同じ仕組み)
enum ScriptWriterDraft {
    static var topic = ""
    /// nil なら、次に開いたときに動画の長さから決める
    static var durationSeconds: Double?
    static var tone: ScriptTone = .friendly
    static var lines: [ScriptLine] = []
}

struct ScriptWriterSheetView: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// ナレーションを追加したときに呼ぶ(最後に追加した ID)
    let onNarrationAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 確認してから始める AI の操作
    private enum PendingAction {
        /// 台本を作る(作り直す)
        case write
        /// キャプションから構成案を作る
        case outline
    }

    @State private var topic = ScriptWriterDraft.topic
    @State private var durationSeconds: Double = ScriptWriterDraft.durationSeconds ?? 60
    @State private var tone: ScriptTone = ScriptWriterDraft.tone
    @State private var lines: [ScriptLine] = ScriptWriterDraft.lines
    @State private var analysis = EditorAnalysisRunner()
    @State private var errorText: String?
    /// エラーの原因に合わせてアラートに付けるボタン(AccountService.swift の CloudAIGateway.recovery)
    @State private var errorRecovery: CloudAIRecovery = .none
    /// 台本・構成案の結果(作成ボタンの下)
    @State private var infoText: String?
    /// 挿入の結果(それぞれのボタンの下)
    @State private var narrationInfoText: String?
    @State private var subtitleInfoText: String?
    /// 挿入したときの行(行が変わるまで、同じ内容を二重に入れないようボタンを止める)
    @State private var narrationInsertedLines: [ScriptLine]?
    @State private var subtitleInsertedLines: [ScriptLine]?
    /// 作り直す・構成案の前の確認(台本の上書き・ポイントの目安)
    @State private var pendingAction: PendingAction?
    /// 台本があるときの「閉じる」の確認
    @State private var isCloseConfirmationPresented = false
    /// アラートから開く画面
    @State private var showsAISettings = false
    @State private var showsAccountSheet = false

    // 読み上げ
    @State private var language = "ja-JP"
    @State private var voices: [(id: String, name: String)] = []
    @State private var voiceID: String?
    /// クラウドの声(nil なら端末の声)
    @State private var cloudVoice: CloudVoice?
    @State private var rate: Float = 0.5
    @State private var pitch: Float = 1.0
    @State private var replaceSubtitles = false

    private let durationOptions: [Double] = [30, 60, 90, 120, 180]

    private var currentVoiceName: String {
        if let cloudVoice { return cloudVoice.displayName }
        guard let voiceID, let voice = voices.first(where: { $0.id == voiceID }) else { return String(localized: "標準の声") }
        return voice.name
    }

    /// ScriptWriter と同じ判定(「AI 仕上げ: 使わない」でも使えるエンジンがあれば使う)
    private var engineName: String {
        ScriptWriter.engineDisplayName(settings: AppSettings.shared)
    }

    private var hasEngine: Bool {
        ScriptWriter.isAvailable(settings: AppSettings.shared)
    }

    /// ポイントで AI を使うか(Apple Intelligence で作るときはポイントを使わないので、目安は出さない。SubtitleEditorView の AI翻訳と同じ判定)
    private var usesPointsForAI: Bool {
        CloudAIGateway.usesPoints && usesCloudAI
    }

    /// 文章を OpenAI に送るか(ポイント・自分のキーのどちらでも)
    private var usesCloudAI: Bool {
        ScriptWriter.resolveExplicitEngine(settings: AppSettings.shared) == .cloud
    }

    /// Google の声が使えるか(サーバーの設定。AccountService.googleVoicesAvailable)
    private var googleVoicesAvailable: Bool {
        AccountService.shared.googleVoicesAvailable
    }

    private var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nonEmptyLines: [ScriptLine] {
        lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time < $1.time }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    inputSection
                    actionSection
                    linesSection
                    if !lines.isEmpty {
                        narrationSection
                        subtitleSection
                    }
                }
                if let progress = analysis.progress {
                    ClipFXProgressOverlay(progress: progress) {
                        analysis.cancel()
                    }
                }
            }
            .navigationTitle("AI台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { requestClose() }
                }
            }
            // 台本があるとき・作成中はスワイプで閉じられないようにする(台本が消える / 途中の結果がプロジェクトに入るため)
            .interactiveDismissDisabled(!lines.isEmpty || analysis.isRunning)
            .confirmationDialog("台本を閉じますか?",
                                isPresented: $isCloseConfirmationPresented,
                                titleVisibility: .visible) {
                Button("台本を残して閉じる") {
                    analysis.cancel()
                    dismiss()
                }
                Button("台本を破棄して閉じる", role: .destructive) {
                    analysis.cancel()
                    lines = []
                    dismiss()
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("残した台本は、次に「AI台本」を開いたときに戻ります。")
            }
            // 作り直す(いまの台本が消える)・ポイントで使うときの目安を見せてから始める
            .confirmationDialog(pendingActionTitle,
                                isPresented: Binding(get: { pendingAction != nil },
                                                     set: { if !$0 { pendingAction = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingAction) { action in
                switch action {
                case .write:
                    if lines.isEmpty {
                        Button("台本を作る") { write() }
                    } else {
                        Button("台本を作り直す", role: .destructive) { write() }
                    }
                case .outline:
                    Button("構成案を作る") { outline() }
                }
                Button("キャンセル", role: .cancel) { }
            } message: { action in
                Text(pendingActionMessage(action))
            }
            .alert("作成できませんでした", isPresented: errorIsPresented) {
                switch errorRecovery {
                case .signIn, .points:
                    Button("アカウントとポイント") { showsAccountSheet = true }
                case .apiKey:
                    Button("文字起こしとAI仕上げ") { showsAISettings = true }
                case .none:
                    EmptyView()
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .navigationDestination(isPresented: $showsAISettings) {
                TranscriptionSettingsView()
            }
            // AccountPointsView.swift
            .sheet(isPresented: $showsAccountSheet) {
                AccountPointsSheet()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // 下書きに長さが無ければ、動画の長さから決める
            if ScriptWriterDraft.durationSeconds == nil {
                let total = project.totalDuration
                if total > 5 {
                    durationSeconds = min(600, max(10, (total / 5).rounded() * 5))
                }
            }
            reloadVoices()
        }
        // 閉じるとき(スワイプで閉じられたときも)途中の作成を止めて、台本を下書きに残す
        .onDisappear {
            analysis.cancel()
            saveDraft()
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { errorText != nil },
            set: { newValue in
                if !newValue { errorText = nil }
            }
        )
    }

    private var pendingActionTitle: String {
        switch pendingAction {
        case .some(.write):
            return lines.isEmpty ? String(localized: "台本を作りますか?") : String(localized: "台本を作り直しますか?")
        case .some(.outline):
            return String(localized: "構成案を作りますか?")
        case .none:
            return ""
        }
    }

    /// 確認の文: 上書きの注意と、ポイントで使うときの目安(台本・構成案は 1 リクエスト。SubtitlePolisher.estimatedPoints)
    private func pendingActionMessage(_ action: PendingAction) -> String {
        var parts: [String] = []
        if action == .write, !lines.isEmpty {
            parts.append(String(localized: "いまの台本は消えます。"))
        }
        if usesPointsForAI {
            parts.append(String(localized: "約 \(SubtitlePolisher.estimatedPoints(lineCount: 1)) pt を使います。"))
        }
        if usesCloudAI {
            parts.append(String(localized: "文章を OpenAI に送ります。"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: 入力

    private var inputSection: some View {
        Section {
            TextField("例: 京都の紅葉を巡る 1 日", text: $topic, axis: .vertical)
                .lineLimit(1...4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("長さ")
                    Spacer()
                    Text(MediaTimeText.precise(durationSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if project.totalDuration > 1 {
                            EditorChip(title: String(localized: "動画の長さ"),
                                       isSelected: abs(durationSeconds - project.totalDuration) < 0.5) {
                                durationSeconds = project.totalDuration
                            }
                        }
                        ForEach(durationOptions, id: \.self) { option in
                            EditorChip(title: String(localized: "\(Int(option)) 秒"),
                                       isSelected: abs(durationSeconds - option) < 0.5) {
                                durationSeconds = option
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Slider(value: $durationSeconds, in: 10...600, step: 5)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("口調")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScriptTone.allCases) { option in
                            EditorChip(title: option.displayName, isSelected: tone == option) {
                                tone = option
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            NavigationLink {
                TranscriptionSettingsView()
            } label: {
                HStack {
                    Label("文字起こしとAI仕上げ", systemImage: "gearshape")
                    Spacer()
                    Text(engineName)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("テーマ")
        } footer: {
            if hasEngine {
                Text("いまの AI: \(engineName)。キャプションやマーカーも参考にします。")
            } else {
                Text("「文字起こしとAI仕上げ」で AI を設定してください。")
            }
        }
    }

    // MARK: 作成

    private var actionSection: some View {
        Section {
            Button {
                requestWrite()
            } label: {
                Label(lines.isEmpty ? String(localized: "台本を作る") : String(localized: "台本を作り直す"), systemImage: "text.badge.star")
            }
            .disabled(trimmedTopic.isEmpty || analysis.isRunning)

            Button {
                requestOutline()
            } label: {
                Label("キャプションから構成案を作る", systemImage: "list.bullet.indent")
            }
            .disabled(project.subtitles.isEmpty || analysis.isRunning)

            if let infoText {
                Text(infoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // AI の結果(台本・構成案)に問題があったときの報告先(CloudAIGateway.supportURL)
            if !lines.isEmpty || infoText != nil {
                Button {
                    UIApplication.shared.open(CloudAIGateway.supportURL)
                } label: {
                    Label("問題を報告", systemImage: "exclamationmark.bubble")
                        .font(.caption)
                }
            }
        } footer: {
            Text("構成案はチャプターのマーカーとして追加します。")
        }
    }

    /// OpenAI に送るときは、初回だけ送り先の確認(CloudAIGateway.ensureConsent)。Apple Intelligence なら聞かない
    @MainActor
    private func confirmCloudConsent() async -> Bool {
        guard usesCloudAI else { return true }
        return await CloudAIGateway.ensureConsent()
    }

    /// 台本があるときは上書きの確認、ポイントで使うときは目安を見せてから作る
    private func requestWrite() {
        guard !trimmedTopic.isEmpty else { return }
        Task { @MainActor in
            guard await confirmCloudConsent() else { return }
            if !lines.isEmpty || usesPointsForAI {
                pendingAction = .write
            } else {
                write()
            }
        }
    }

    private func requestOutline() {
        guard !project.subtitles.isEmpty else { return }
        Task { @MainActor in
            guard await confirmCloudConsent() else { return }
            if usesPointsForAI {
                pendingAction = .outline
            } else {
                outline()
            }
        }
    }

    /// 台本があるときは、残すか破棄するかを確かめてから閉じる
    private func requestClose() {
        if lines.isEmpty {
            analysis.cancel()
            dismiss()
        } else {
            isCloseConfirmationPresented = true
        }
    }

    private func saveDraft() {
        ScriptWriterDraft.topic = topic
        // 台本が無ければ長さは覚えない(次に開いたときに動画の長さから決める)
        ScriptWriterDraft.durationSeconds = lines.isEmpty ? nil : durationSeconds
        ScriptWriterDraft.tone = tone
        ScriptWriterDraft.lines = lines
    }

    // MARK: 台本の行

    private var linesSection: some View {
        Section {
            if lines.isEmpty {
                Text("台本はまだありません。テーマを入れて「台本を作る」を押してください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($lines) { $line in
                    lineRow($line)
                }
                .onDelete { offsets in
                    lines.remove(atOffsets: offsets)
                }
                Button {
                    addLine()
                } label: {
                    Label("行を追加", systemImage: "plus")
                }
            }
        } header: {
            HStack {
                Text("台本(\(lines.count) 行)")
                Spacer()
                if !lines.isEmpty {
                    Button("並べ替え") {
                        lines.sort { $0.time < $1.time }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        } footer: {
            if !lines.isEmpty {
                Text("時刻は完成した動画での目安です。")
            }
        }
    }

    private func lineRow(_ line: Binding<ScriptLine>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(MediaTimeText.precise(line.wrappedValue.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: line.time, in: 0...3600, step: 1)
                    .labelsHidden()
                Spacer()
                Button {
                    player.seek(to: line.wrappedValue.time)
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("この時刻へ移動")
            }
            TextField("セリフ", text: line.text, axis: .vertical)
                .lineLimit(1...5)
        }
        .padding(.vertical, 2)
    }

    private func addLine() {
        let last = lines.map { $0.time }.max() ?? 0
        let time = lines.isEmpty ? 0 : last + 5
        lines.append(ScriptLine(time: time, text: ""))
    }

    // MARK: 挿入(ナレーション)

    private var narrationSection: some View {
        Section {
            HStack(spacing: 8) {
                EditorChip(title: String(localized: "日本語"), isSelected: language == "ja-JP") {
                    language = "ja-JP"
                    reloadVoices()
                }
                EditorChip(title: "English", isSelected: language == "en-US") {
                    language = "en-US"
                    reloadVoices()
                }
                Spacer()
            }

            HStack {
                Text("声")
                Spacer()
                Menu {
                    Section(String(localized: "端末の声")) {
                        Button(String(localized: "標準の声")) { voiceID = nil; cloudVoice = nil }
                        ForEach(voices, id: \.id) { voice in
                            Button(voice.name) { voiceID = voice.id; cloudVoice = nil }
                        }
                    }
                    Section(String(localized: "クラウドの声(OpenAI)")) {
                        ForEach(CloudVoice.openAIVoices) { voice in
                            Button(voice.displayName) { cloudVoice = voice }
                        }
                    }
                    // Google の声はサーバーで使える設定のときだけ(TextPanels の読み上げと同じ)
                    if googleVoicesAvailable {
                        Section(String(localized: "クラウドの声(Google・日本語)")) {
                            ForEach(CloudVoice.googleVoices) { voice in
                                Button(voice.displayName) { cloudVoice = voice }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentVoiceName)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("速さ")
                    Spacer()
                    Text(String(format: "%.2f", rate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rate, in: 0.3...0.7)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("高さ")
                    Spacer()
                    Text(String(format: "%.2f", pitch))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pitch, in: 0.6...1.6)
            }

            // 入れたあとは、行を直すまで同じ内容を二重に入れないよう止める
            Button {
                insertNarration()
            } label: {
                Label("ナレーションとして挿入", systemImage: "waveform.badge.plus")
            }
            .disabled(nonEmptyLines.isEmpty || analysis.isRunning || narrationInsertedLines == nonEmptyLines)

            if let narrationInfoText {
                Text(narrationInfoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("読み上げ")
        } footer: {
            Text("各行をその時刻のナレーションにします。前の行と重なるときは後ろへずらします。")
        }
    }

    private func reloadVoices() {
        voices = TextToSpeech.availableVoices(language: language)
        if let voiceID, !voices.contains(where: { $0.id == voiceID }) {
            self.voiceID = nil
        }
    }

    /// クラウドの声(OpenAI / Google)に送る前の、初回だけの確認(CloudAIGateway.ensureConsent)を済ませてから作る
    private func insertNarration() {
        let items = nonEmptyLines
        guard !items.isEmpty else { return }
        let chosenChoice: TTSVoiceChoice = cloudVoice.map { .cloud($0) } ?? .device(voiceID)
        Task { @MainActor in
            if chosenChoice.isCloud {
                guard await CloudAIGateway.ensureConsent() else { return }
            }
            startNarrationInsert(items: items, choice: chosenChoice)
        }
    }

    private func startNarrationInsert(items: [ScriptLine], choice chosenChoice: TTSVoiceChoice) {
        guard !items.isEmpty, !analysis.isRunning else { return }
        let chosenRate = rate
        let chosenPitch = pitch
        errorText = nil
        narrationInfoText = nil
        player.pause()
        analysis.run(title: String(localized: "読み上げを作成中")) { report in
            var created: [NarrationClip] = []
            let total = Double(items.count)
            for (i, line) in items.enumerated() {
                if Task.isCancelled { break }
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = try await TextToSpeech.render(choice: chosenChoice, text: text,
                                                        rate: chosenRate, pitch: chosenPitch, instructions: nil)
                let asset = AVURLAsset(url: url)
                let loaded = try? await asset.load(.duration)
                let seconds: Double = loaded?.seconds ?? 1
                let duration: Double = (seconds.isFinite && seconds > 0) ? seconds : 1
                let name = String(localized: "台本: ") + String(text.prefix(12))
                created.append(NarrationClip(url: url, name: name, start: max(0, line.time), duration: duration))
                report(Double(i + 1) / total)
            }
            if Task.isCancelled {
                for clip in created {
                    try? FileManager.default.removeItem(at: clip.url)
                }
                return
            }
            guard !created.isEmpty else { return }

            // 前の行と重なるときは後ろへずらす
            var adjusted = created
            var cursor: Double = 0
            for i in adjusted.indices {
                if adjusted[i].start < cursor {
                    adjusted[i].start = cursor
                }
                cursor = adjusted[i].end + 0.2
            }

            history.record(project)
            project.narration.append(contentsOf: adjusted)
            project.sortNarration()
            narrationInfoText = String(localized: "\(adjusted.count) 件のナレーションを追加しました。")
            narrationInsertedLines = items
            if let last = adjusted.last {
                onNarrationAdded(last.id)
            }
        } onError: { error in
            presentError(error,
                         retryHint: String(localized: "もう一度「ナレーションとして挿入」を押してください。続くときは「声」を「標準の声」にしてください。"))
        }
    }

    // MARK: 挿入(キャプション)

    private var subtitleSection: some View {
        Section {
            Toggle("今あるキャプションを置き換える", isOn: $replaceSubtitles)
                .disabled(project.subtitles.isEmpty)
            // 入れたあとは、行を直すまで同じ内容を二重に入れないよう止める
            Button {
                insertSubtitles()
            } label: {
                Label("キャプションとして挿入", systemImage: "captions.bubble")
            }
            .disabled(nonEmptyLines.isEmpty || analysis.isRunning || subtitleInsertedLines == nonEmptyLines)

            if let subtitleInfoText {
                Text(subtitleInfoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("キャプション")
        } footer: {
            Text("各行をその時刻からのキャプションにします。次の行と重ならない長さにします。")
        }
    }

    private func insertSubtitles() {
        let items = nonEmptyLines
        guard !items.isEmpty else { return }
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(items.count)
        for (i, line) in items.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start: Double = max(0, line.time)
            let characters = Double(text.count)
            let estimated: Double = max(1.5, min(8, characters * 0.22))
            var end: Double = start + estimated
            if i + 1 < items.count {
                let nextStart: Double = max(start + 0.6, items[i + 1].time)
                end = min(end, nextStart - 0.1)
            }
            cues.append(SubtitleCue(start: start, end: max(start + 0.5, end), text: text))
        }
        let withWords = SubtitleWordTiming.fillingMissing(cues)
        history.record(project)
        if replaceSubtitles {
            project.subtitles = withWords
        } else {
            project.subtitles.append(contentsOf: withWords)
        }
        project.sortSubtitles()
        subtitleInfoText = String(localized: "\(withWords.count) 件のキャプションを追加しました。")
        subtitleInsertedLines = items
    }

    // MARK: AI 呼び出し

    private func write() {
        let theme = trimmedTopic
        guard !theme.isEmpty else { return }
        let seconds = durationSeconds
        let chosenTone = tone
        let subtitles = project.subtitles
        let markers = project.markers
        errorText = nil
        infoText = nil
        analysis.run(title: String(localized: "台本を作成中"), indeterminate: true) { _ in
            let result = try await ScriptWriter.write(topic: theme,
                                                      durationSeconds: seconds,
                                                      tone: chosenTone,
                                                      subtitles: subtitles,
                                                      markers: markers,
                                                      settings: AppSettings.shared)
            if Task.isCancelled { return }
            lines = result.sorted { $0.time < $1.time }
            narrationInfoText = nil
            subtitleInfoText = nil
            narrationInsertedLines = nil
            subtitleInsertedLines = nil
            if lines.isEmpty {
                infoText = String(localized: "台本を作れませんでした。テーマをもう少し具体的にしてお試しください。")
            } else {
                infoText = String(localized: "\(lines.count) 行の台本ができました。内容と時刻を直してから挿入できます。")
            }
        } onError: { error in
            presentError(error,
                         retryHint: String(localized: "もう一度「台本を作る」を押してください。続くときは「文字起こしとAI仕上げ」を確かめてください。"))
        }
    }

    private func outline() {
        let subtitles = project.subtitles
        guard !subtitles.isEmpty else { return }
        errorText = nil
        infoText = nil
        analysis.run(title: String(localized: "構成案を作成中"), indeterminate: true) { _ in
            let suggested = try await ScriptWriter.outline(from: subtitles, settings: AppSettings.shared)
            if Task.isCancelled { return }
            guard !suggested.isEmpty else {
                infoText = String(localized: "構成案を作れませんでした。キャプションがもう少し長いとうまくいきます。")
                return
            }
            history.record(project)
            var markers = project.markers
            var added = 0
            for item in suggested {
                var marker = item
                marker.kind = .chapter
                if markers.contains(where: { $0.kind == .chapter && abs($0.time - marker.time) < 0.5 }) {
                    continue
                }
                markers.append(marker)
                added += 1
            }
            project.markers = markers
            project.sortMarkers()
            infoText = String(localized: "\(added) 個のチャプターを追加しました。マーカーを選ぶと名前を直せます。")
        } onError: { error in
            presentError(error,
                         retryHint: String(localized: "もう一度「キャプションから構成案を作る」を押してください。続くときは「文字起こしとAI仕上げ」を確かめてください。"))
        }
    }

    /// エラーを原因に合ったボタン付きで出す
    /// (ログインの期限切れ・ポイント不足 → アカウントとポイント、API キー → 文字起こしとAI仕上げ。AccountService.swift の CloudAIGateway.recovery)
    private func presentError(_ error: Error, retryHint: String) {
        // moderation が止めた内容(ScriptWriter.swift)は、やり直しの案内を付けずそのまま
        if error is CloudAIModerationError {
            errorRecovery = .none
            errorText = error.localizedDescription
            return
        }
        let recovery = CloudAIGateway.recovery(for: error)
        errorRecovery = recovery
        switch recovery {
        case .signIn, .points:
            // 原因(サーバーの文)をそのまま。通信の案内は出さない
            errorText = error.localizedDescription
        case .apiKey:
            errorText = String(localized: "「文字起こしとAI仕上げ」で Apple Intelligence か OpenAI の API キーを設定してください。\n\n詳細: ") + error.localizedDescription
        case .none:
            errorText = retryHint + String(localized: "\n\n詳細: ") + error.localizedDescription
        }
    }
}
