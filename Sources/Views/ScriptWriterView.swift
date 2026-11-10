import SwiftUI
import UIKit
import AVFoundation
import Observation

// =====================================================================
// 第4弾: AI 台本
//   テーマ・長さ・口調から ScriptWriter.write で台本(時刻つきの行)を作り、
//   行を直してから「ナレーションとして挿入」(TextToSpeech → ナレーション)/「キャプションとして挿入」(SubtitleCue)。
//   「キャプションから構成案」は ScriptWriter.outline でチャプターのマーカーを追加する。
//   作った台本は ScriptWriterDraft でプロジェクトごとのファイルに残す(次にそのプロジェクトで開いたときに戻る)。
// =====================================================================

/// 閉じても台本が消えないように残しておく下書き。プロジェクトのフォルダの script_draft.json に保存する
/// (前はメモリ上にアプリ全体で 1 つだけだったので、アプリが終了すると消え、別のプロジェクトを開くと前の台本が出ていた)。
/// テレプロンプターの「AI 台本を使う」のために、最後に残した台本の文章は UserDefaults にも残す
/// (プロジェクト一覧から開くカメラでも使えるように)
enum ScriptWriterDraft {
    struct Draft {
        var topic = ""
        /// nil なら、開いたときに動画の長さから決める
        var durationSeconds: Double?
        var tone: ScriptTone = .friendly
        var lines: [ScriptLine] = []
    }

    private struct StoredLine: Codable {
        var time: Double
        var text: String
    }

    private struct Stored: Codable {
        var topic: String
        var durationSeconds: Double?
        var tone: String
        var lines: [StoredLine]
    }

    private static let fileName = "script_draft.json"
    /// テレプロンプター用: 最後に残した AI 台本の文章(行を空行でつないだもの)
    private static let lastScriptKey = "scriptWriter.lastScript"

    private static func fileURL(projectID: UUID) -> URL {
        ProjectStore.projectDirectory(projectID: projectID).appendingPathComponent(fileName)
    }

    static func load(projectID: UUID) -> Draft {
        guard let data = try? Data(contentsOf: fileURL(projectID: projectID)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Draft() }
        var draft = Draft()
        draft.topic = stored.topic
        draft.durationSeconds = stored.durationSeconds
        draft.tone = ScriptTone(rawValue: stored.tone) ?? .friendly
        draft.lines = stored.lines.map { ScriptLine(time: $0.time, text: $0.text) }
        return draft
    }

    /// テーマも台本も空ならファイルを消す。プロジェクトのフォルダが無い(削除済み)ときは作らない
    static func save(_ draft: Draft, projectID: UUID) {
        let url = fileURL(projectID: projectID)
        let manager = FileManager.default
        if draft.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.lines.isEmpty {
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
            return
        }
        guard manager.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
        let stored = Stored(topic: draft.topic,
                            durationSeconds: draft.durationSeconds,
                            tone: draft.tone.rawValue,
                            lines: draft.lines.map { StoredLine(time: $0.time, text: $0.text) })
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 行を空行でつないだ文章(テレプロンプター用)
    static func scriptText(_ lines: [ScriptLine]) -> String {
        lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// テレプロンプター用に台本の文章を残す(空の台本では消さない。破棄したときは clearLastScript)
    static func rememberLastScript(_ lines: [ScriptLine]) {
        let text = scriptText(lines)
        guard !text.isEmpty else { return }
        UserDefaults.standard.set(text, forKey: lastScriptKey)
    }

    static func clearLastScript() {
        UserDefaults.standard.removeObject(forKey: lastScriptKey)
    }

    /// 最後に残した AI 台本の文章。無ければ nil
    static var lastScript: String? {
        let text = UserDefaults.standard.string(forKey: lastScriptKey) ?? ""
        return text.isEmpty ? nil : text
    }
}

struct ScriptWriterSheetView: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// 下書きを残すプロジェクト(ScriptWriterDraft)
    let projectID: UUID
    /// ナレーションを追加したときに呼ぶ(最後に追加した ID)
    let onNarrationAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// 確認してから始める AI の操作
    private enum PendingAction {
        /// 台本を作る(作り直す)
        case write
        /// キャプションから構成案を作る
        case outline
    }

    // 下書き(ScriptWriterDraft)は onAppear でこのプロジェクトの分を読み込む
    @State private var topic = ""
    @State private var durationSeconds: Double = 60
    @State private var tone: ScriptTone = .friendly
    @State private var lines: [ScriptLine] = []
    /// 下書きを読み込んだか(読み込む前に空の内容で上書きしないように)
    @State private var didLoadDraft = false
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

    // 読み上げ(初めはアプリの表示言語に合わせる。台本もその言語で作るため)
    @State private var language: String = {
        switch ScriptWriter.outputLanguage {
        case .japanese: return "ja-JP"
        case .spanish: return "es-MX"
        case .portuguese: return "pt-BR"
        case .english: return "en-US"
        }
    }()
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
                    // テレプロンプター用に残した文章も、この台本のものなら消す
                    if ScriptWriterDraft.lastScript == ScriptWriterDraft.scriptText(lines) {
                        ScriptWriterDraft.clearLastScript()
                    }
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
            if !didLoadDraft {
                didLoadDraft = true
                // このプロジェクトの下書きを読み込む(別のプロジェクトの台本は出さない)
                let draft = ScriptWriterDraft.load(projectID: projectID)
                topic = draft.topic
                tone = draft.tone
                lines = draft.lines
                if let saved = draft.durationSeconds {
                    durationSeconds = saved
                } else {
                    // 下書きに長さが無ければ、動画の長さから決める
                    let total = project.totalDuration
                    if total > 5 {
                        durationSeconds = min(600, max(10, (total / 5).rounded() * 5))
                    }
                }
            }
            reloadVoices()
        }
        // 閉じるとき(スワイプで閉じられたときも)途中の作成を止めて、台本を下書きに残す
        .onDisappear {
            // 全画面広告がシートの上に出たときにも呼ばれるので、そのときは作成を止めない(広告のあと台本が届かないまま終わらないように)
            if !AdsManager.shared.isShowing {
                analysis.cancel()
            }
            saveDraft()
        }
        // 開いたまま裏に回ったときも残す(そのまま iOS にアプリを終了されても消えないように)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                saveDraft()
            }
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
        guard didLoadDraft else { return }
        var draft = ScriptWriterDraft.Draft()
        draft.topic = topic
        // 台本が無ければ長さは覚えない(次に開いたときに動画の長さから決める)
        draft.durationSeconds = lines.isEmpty ? nil : durationSeconds
        draft.tone = tone
        draft.lines = lines
        ScriptWriterDraft.save(draft, projectID: projectID)
        ScriptWriterDraft.rememberLastScript(lines)
    }

    /// 動画の長さより後ろの時刻の行の数(挿入してもプレビュー・書き出しに入らない)
    private var linesAfterVideoEnd: Int {
        let total = project.totalDuration
        guard total > 0 else { return 0 }
        return nonEmptyLines.filter { $0.time >= total }.count
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("時刻は完成した動画での目安です。")
                    // 長さの違う台本を入れたときなど、動画より後ろの行は入れても聞こえず見えないので知らせる
                    if linesAfterVideoEnd > 0 {
                        Text("動画の長さより後ろの行が \(linesAfterVideoEnd) 行あります。挿入しても、いまは聞こえず見えません。")
                            .foregroundStyle(.orange)
                    }
                }
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
            // 端末の声の言語(「標準の声」もこの言語の声で読む)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TTSLanguage.codes, id: \.self) { code in
                        EditorChip(title: TTSLanguage.displayName(code), isSelected: language == code) {
                            language = code
                            reloadVoices()
                        }
                    }
                }
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
                Label(narrationInsertTitle, systemImage: "waveform.badge.plus")
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
        // 端末の「標準の声」は日本語の声で読むので、日本語以外のときはその言語の標準の声を選んでおく
        if self.voiceID == nil, cloudVoice == nil, language != "ja-JP",
           let id = AVSpeechSynthesisVoice(language: language)?.identifier,
           voices.contains(where: { $0.id == id }) {
            self.voiceID = id
        }
    }

    /// ナレーションの 1 行を作った声を覚えておくキー(途中で止まったあと、作った行を使い回す。TTSResumeCache)
    private static func narrationCacheKey(choice: TTSVoiceChoice, text: String, rate: Float, pitch: Float, language: String) -> String {
        TTSResumeCache.key(choice: choice, text: text, rate: rate, pitch: pitch, extra: "script|" + language)
    }

    /// クラウドの声でポイントを使うときの目安(まだ作っていない行の分だけ)。ポイントを使わないなら nil
    private var narrationEstimatedPoints: Int? {
        guard let cloudVoice, cloudVoice.isGoogle || CloudAIGateway.prefersPoints else { return nil }
        let choice: TTSVoiceChoice = .cloud(cloudVoice)
        let chars = nonEmptyLines.reduce(0) { total, line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.narrationCacheKey(choice: choice, text: text, rate: rate, pitch: pitch, language: language)
            return TTSResumeCache.url(for: key) == nil ? total + text.count : total
        }
        return AccountService.shared.speechPoints(forCharacters: chars)
    }

    /// 「ナレーションとして挿入」のボタン(ポイントを使うときは、押す前に目安を出す)
    private var narrationInsertTitle: String {
        if let points = narrationEstimatedPoints, points > 0 {
            return String(localized: "ナレーションとして挿入 ・ 約 \(points)pt")
        }
        return String(localized: "ナレーションとして挿入")
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
        let chosenLanguage = language
        errorText = nil
        narrationInfoText = nil
        player.pause()
        analysis.run(title: String(localized: "読み上げを作成中")) { report in
            // 1 行ずつ受け止め、途中で止まっても作れた行は残す(クラウドの声はポイントを使っているため)。
            // 作った声は TTSResumeCache に覚えておき、もう一度押したときは作り直さずに使う
            var created: [NarrationClip] = []
            var failure: Error?
            var failedLine = 0
            // 前の行と重なるときは後ろへずらす(前に追加済みの行も数える)
            var cursor: Double = 0
            let total = Double(items.count)
            for (i, line) in items.enumerated() {
                if Task.isCancelled { break }
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let cacheKey = Self.narrationCacheKey(choice: chosenChoice, text: text, rate: chosenRate,
                                                      pitch: chosenPitch, language: chosenLanguage)
                let url: URL
                if let cached = TTSResumeCache.url(for: cacheKey) {
                    // 途中で止まったときに追加済みの行は、もう一度入れない
                    if let existing = project.narration.first(where: { $0.url == cached }) {
                        cursor = max(cursor, existing.end + 0.2)
                        report(Double(i + 1) / total)
                        continue
                    }
                    url = cached
                } else {
                    do {
                        url = try await TextToSpeech.render(choice: chosenChoice, text: text,
                                                            rate: chosenRate, pitch: chosenPitch, instructions: nil,
                                                            language: chosenLanguage)
                    } catch {
                        if Task.isCancelled { break }
                        failure = error
                        failedLine = i + 1
                        break
                    }
                    TTSResumeCache.store(url, for: cacheKey)
                }
                let asset = AVURLAsset(url: url)
                let loaded = try? await asset.load(.duration)
                let seconds: Double = loaded?.seconds ?? 1
                let duration: Double = (seconds.isFinite && seconds > 0) ? seconds : 1
                let name = String(localized: "台本: ") + String(text.prefix(12))
                let start = max(max(0, line.time), cursor)
                created.append(NarrationClip(url: url, name: name, start: start, duration: duration))
                cursor = start + duration + 0.2
                report(Double(i + 1) / total)
            }
            if Task.isCancelled {
                // 端末の声は消す。クラウドの声で作った分は残す(もう一度押すと続きから作り、作った分のポイントはかからない)
                if !chosenChoice.isCloud {
                    for clip in created {
                        try? FileManager.default.removeItem(at: clip.url)
                    }
                }
                return
            }
            guard !created.isEmpty else {
                if let failure { throw failure }
                return
            }

            history.record(project)
            project.narration.append(contentsOf: created)
            project.sortNarration()
            narrationInfoText = String(localized: "\(created.count) 件のナレーションを追加しました。")
            if let last = created.last {
                onNarrationAdded(last.id)
            }
            if let failure {
                // 途中で止まった: 作れた行は追加済み。もう一度押せば残りの行だけを作る
                narrationInsertedLines = nil
                presentError(failure,
                             retryHint: String(localized: "\(failedLine) 行目で止まりました。作れた \(created.count) 行は追加しました。もう一度「ナレーションとして挿入」を押すと、残りの行だけを作ります。"))
            } else {
                narrationInsertedLines = items
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
            // 作った台本はすぐ残す(シートを開いたままアプリが終了しても消えないように)
            saveDraft()
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
