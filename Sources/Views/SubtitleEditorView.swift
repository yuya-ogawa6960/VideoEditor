import SwiftUI
import Observation
import UniformTypeIdentifiers
import NaturalLanguage
import UIKit

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

/// SwiftUI の Color → "#RRGGBB"(0...1 に丸めてから変換)
fileprivate func subtitleHexString(from color: Color) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    func component(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", component(r), component(g), component(b))
}

// MARK: - スタイルプリセット

/// 「スタイル」セクションのチップで選ぶプリセット。SubtitleStyle に存在する項目だけを設定する
fileprivate enum SubtitleStylePreset: String, CaseIterable, Identifiable {
    case standard, netflix, youtube, cinema, pop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "標準")
        case .netflix: return String(localized: "Netflix風")
        case .youtube: return String(localized: "YouTube風")
        case .cinema: return String(localized: "シネマ")
        case .pop: return String(localized: "ポップ")
        }
    }

    var position: SubtitlePosition { .bottom }

    var color: SubtitleColor {
        switch self {
        case .pop: return .yellow
        default: return .white
        }
    }

    var sizeRatio: CGFloat {
        switch self {
        case .standard: return 0.045
        case .netflix: return 0.042
        case .youtube: return 0.05
        case .cinema: return 0.038
        case .pop: return 0.055
        }
    }

    var hasBackground: Bool {
        switch self {
        case .standard, .youtube, .pop: return true
        case .netflix, .cinema: return false
        }
    }

    /// displayMode は触らず、見た目の項目だけ上書きする
    func apply(to style: inout SubtitleStyle) {
        style.position = position
        style.color = color
        style.sizeRatio = sizeRatio
        style.hasBackground = hasBackground
    }

    /// 現在のスタイルがこのプリセットと一致しているか(チップの選択表示用)
    func matches(_ style: SubtitleStyle) -> Bool {
        style.position == position
            && style.color == color
            && style.hasBackground == hasBackground
            && abs(style.sizeRatio - sizeRatio) < 0.0005
    }
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
    /// 前回(アプリが終了するなどして)取り込めなかったクラウド文字起こし(CloudBackgroundUploader.pendingJobs)
    @State private var pendingCloudJobs: [CloudJobManifest] = []

    @State private var translationRequest: TranslationRequest?
    /// AI 翻訳(SubtitlePolisher.translate)の実行中タスク
    @State private var aiTranslationTask: Task<Void, Never>?

    @State private var editingCueID: UUID?

    @State private var alertTitle: String = ""
    @State private var alertMessage: String?
    /// エラーの案内に「設定を開く」ボタンを出すか
    @State private var alertOffersSettings: Bool = false

    /// 文字起こし中に「閉じる」を押したときの確認
    @State private var isCloseConfirmationPresented: Bool = false
    /// 「詳細設定」(テンプレート・フォント・字幕ファイルなど)を開いているか
    @State private var showsAdvanced: Bool = false

    // 字幕ファイル(SRT)の書き出し・読み込み
    @State private var exportUseTranslation: Bool = false
    @State private var exportBilingual: Bool = false
    @State private var exportURL: URL?
    @State private var isImporterPresented: Bool = false
    @State private var pendingImportedCues: [SubtitleCue] = []
    @State private var isImportChoicePresented: Bool = false

    // 字幕一覧の一括操作
    @State private var isDeleteAllPresented: Bool = false
    @State private var showsShiftTool: Bool = false
    @State private var appliedShift: Double = 0

    private var isTranscribing: Bool {
        transcriptionTask != nil || transcriber.isRunning
    }

    /// キャンセルを押してから、実際に止まるまでの間
    @State private var isCancellingTranscription = false

    private var isTranslating: Bool {
        translationRequest != nil || aiTranslationTask != nil
    }

    private var isAITranslating: Bool {
        aiTranslationTask != nil
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
                    pendingCloudJobSection
                    if project.subtitles.isEmpty {
                        // 字幕が無いときは「自動で字幕を作る」を最初に大きく出す
                        transcriptionSection
                        cueListSection
                        styleSection
                    } else {
                        // 字幕があるときは一覧を最初に出す
                        cueListSection
                        styleSection
                        transcriptionSection
                        translationSection
                    }
                    advancedToggleSection
                    if showsAdvanced {
                        advancedStyleSection
                        subtitleFileSection
                    }
                }
            }
            .navigationTitle("キャプション")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { requestClose() }
                }
            }
            // 文字起こし中はスワイプで閉じられないようにする(閉じると文字起こしが止まるため)
            .interactiveDismissDisabled(isTranscribing)
            .confirmationDialog("文字起こしを止めて閉じますか?",
                                isPresented: $isCloseConfirmationPresented,
                                titleVisibility: .visible) {
                Button("止めて閉じる", role: .destructive) {
                    cancelTranscription()
                    dismiss()
                }
                Button("文字起こしを続ける", role: .cancel) { }
            } message: {
                Text("閉じると、いま作っている字幕は途中で破棄されます。")
            }
            // 文字起こし中は画面の自動ロックを止める(ロックで通信が切れて止まるため)
            .onChange(of: transcriber.isRunning) { _, running in
                IdleTimerGuard.set(running, for: "transcription")
                // 前回の文字起こし結果のバナーを、文字起こし・取り込みが終わったら読み直す
                if !running {
                    refreshPendingCloudJobs()
                }
            }
            .onDisappear {
                IdleTimerGuard.set(false, for: "transcription")
            }
            // 前回の文字起こし結果のバナー: 開いたとき・前面に戻ったときに読み直す
            .onAppear {
                refreshPendingCloudJobs()
                // Whisper を使う設定なら、押してから待たないようにモデルを先に読み込んでおく(字幕がまだ無いとき)
                let settings = AppSettings.shared
                if settings.transcriptionEngine == .whisper, project.subtitles.isEmpty {
                    WhisperTranscriber.shared.preload(model: settings.whisperModel)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshPendingCloudJobs()
            }
            .navigationDestination(item: $editingCueID) { cueID in
                SubtitleCueEditView(project: project, player: player, cueID: cueID)
            }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: SubtitleEditorView.subtitleFileTypes,
                          allowsMultipleSelection: false) { result in
                handleSubtitleFileImport(result)
            }
            .confirmationDialog("読み込んだ字幕(\(pendingImportedCues.count) 件)をどうしますか?",
                                isPresented: $isImportChoicePresented,
                                titleVisibility: .visible) {
                Button("既存の字幕を置き換え") {
                    applyImportedCues(replace: true)
                }
                Button("既存の字幕に追加") {
                    applyImportedCues(replace: false)
                }
                Button("キャンセル", role: .cancel) {
                    pendingImportedCues = []
                }
            }
            .confirmationDialog("すべての字幕(\(project.subtitles.count) 件)を削除しますか?",
                                isPresented: $isDeleteAllPresented,
                                titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) {
                    project.subtitles.removeAll()
                    exportURL = nil
                    appliedShift = 0
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("この操作は取り消せません。")
            }
        }
        // 字幕の自動作成中は、見どころ探しなどと同じ作業カードを画面全体に重ねる
        .overlay {
            if isTranscribing {
                TranscriptionWorkingOverlay(project: project,
                                            fraction: transcriber.progress,
                                            status: isCancellingTranscription
                                                ? String(localized: "キャンセルしています…")
                                                : (transcriber.statusText.isEmpty ? String(localized: "準備中…") : transcriber.statusText),
                                            onCancel: isCancellingTranscription ? nil : { cancelTranscription() })
            }
        }
        .onChange(of: isTranscribing) { _, running in
            if !running { isCancellingTranscription = false }
        }
        .subtitleTranslation(project: project, request: $translationRequest, onFinish: { result in
            switch result {
            case .success(let count):
                showAlert(title: String(localized: "翻訳しました"),
                          message: String(localized: "\(count) 件の字幕を翻訳しました。「スタイル」の「表示」を「訳文」か「両方」にすると映像に出ます。"))
            case .failure(let error):
                showAlert(title: String(localized: "翻訳できませんでした"),
                          message: String(localized: "通信できる場所で、もう一度「翻訳」を押してください。うまくいかないときは「AIで翻訳」をお試しください。\n\n詳細: ") + error.localizedDescription)
            }
        })
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            if alertOffersSettings {
                Button("設定を開く") {
                    openSystemSettings()
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        .onDisappear {
            cancelTranscription()
            cancelAITranslation()
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

    /// 字幕が無いときは大きなカード、あるときは「自動で作り直す」として一覧の下に出す
    private var transcriptionSection: some View {
        let isFirstTime = project.subtitles.isEmpty
        return Section {
            if isFirstTime {
                autoCaptionIntro
            }

            Picker("話している言語", selection: $selectedLanguage) {
                ForEach(TranscriptionLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .disabled(isTranscribing)

            if !isFirstTime {
                Picker("今ある字幕", selection: $replaceExisting) {
                    Text("置き換える").tag(true)
                    Text("後ろに追加").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(isTranscribing)
            }

            // 文字起こし中は、画面全体に作業カードを重ねる(body の overlay)
            autoCaptionButton(isFirstTime: isFirstTime)

            NavigationLink {
                TranscriptionSettingsView()
            } label: {
                HStack {
                    Label("文字起こしの方式とAI仕上げ", systemImage: "gearshape")
                    Spacer()
                    Text(AppSettings.shared.transcriptionEngine.shortName)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isTranscribing)
        } header: {
            Text(isFirstTime ? String(localized: "自動で字幕を作る") : String(localized: "自動で作り直す"))
        } footer: {
            Text(transcriptionFooterText)
        }
    }

    private var autoCaptionIntro: some View {
        HStack(alignment: .top, spacing: 12) {
            // ヘッドホンで声を聞くロボット(粘土の 1 枚絵)
            Image("robot_hero_listening")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("自動で字幕を作る")
                    .font(.headline)
                Text("動画の声を聞き取って、字幕を自動で作ります。できた字幕はあとから1つずつ直せます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func autoCaptionButton(isFirstTime: Bool) -> some View {
        Button {
            startTranscription()
        } label: {
            Label(isFirstTime ? String(localized: "自動で字幕を作る") : String(localized: "自動で字幕を作り直す"), systemImage: "waveform")
                .font(isFirstTime ? Font.headline : Font.body)
                .frame(maxWidth: .infinity, minHeight: isFirstTime ? 44 : 32)
        }
        .buttonStyle(.borderedProminent)
        .disabled(project.isEmpty || isTranslating || isTranscribing)
    }

    private var transcriptionFooterText: String {
        let settings = AppSettings.shared
        let polish = settings.polishSubtitles
            ? SubtitlePolisher.displayName(of: SubtitlePolisher.resolveEngine(settings: settings))
            : String(localized: "オフ")
        var text = String(localized: "今の方式: ") + settings.transcriptionEngine.displayName + String(localized: "。AI仕上げ: ") + polish + "。"
        if project.isEmpty {
            text = String(localized: "先に編集画面で動画を追加してください。") + text
        }
        return text
    }

    /// 文字起こし中は確認してから閉じる(閉じると止まるため)
    private func requestClose() {
        if isTranscribing {
            isCloseConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
                showAlert(title: String(localized: "音声認識を許可してください"),
                          message: String(localized: "「設定を開く」→「音声認識」をオンにしてから、もう一度「自動で字幕を作る」を押してください。"),
                          offersSettings: true)
                return
            }
            if Task.isCancelled {
                transcriptionTask = nil
                return
            }
            do {
                let transcribed = try await transcriber.transcribe(snapshot: snapshot, language: language)
                // カラオケ風テンプレート用に、単語タイミングが無い字幕へ文字数比例のタイミングを付ける
                let cues = SubtitleWordTiming.fillingMissing(transcribed)
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
                    showAlert(title: String(localized: "声が見つかりませんでした"),
                              message: String(localized: "話している言語が合っているか確かめて、もう一度お試しください。BGMだけの動画では字幕は作られません。"))
                }
            } catch is CancellationError {
                transcriptionTask = nil
            } catch {
                let cancelled = Task.isCancelled
                transcriptionTask = nil
                if !cancelled {
                    showAlert(title: String(localized: "字幕を作れませんでした"),
                              message: String(localized: "通信できる場所で、もう一度「自動で字幕を作る」を押してください。続くときは「文字起こしの方式とAI仕上げ」で方式を変えてみてください。\n\n詳細: ") + error.localizedDescription)
                }
            }
        }
    }

    private func cancelTranscription() {
        if transcriber.isRunning {
            transcriber.cancel()
            // 止まるまでの間も、押したことがすぐ分かるように(ボタンを消して「キャンセルしています…」)
            isCancellingTranscription = true
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    // MARK: 前回の文字起こし結果(クラウド・背景送信)

    /// このプロジェクトのクリップを使った、未取り込みのクラウド文字起こし(新しいもの)
    private var pendingCloudJob: CloudJobManifest? {
        let clipIDs = Set(project.clips.map { $0.id })
        guard !clipIDs.isEmpty else { return nil }
        return pendingCloudJobs.first { $0.matches(clipIDs: clipIDs) }
    }

    @ViewBuilder
    private var pendingCloudJobSection: some View {
        if let job = pendingCloudJob, !isTranscribing {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(job.isComplete ? String(localized: "前回の文字起こし結果があります") : String(localized: "前回の文字起こしが途中です"),
                          systemImage: "tray.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                    Text(pendingCloudJobDetail(job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        importPendingCloudJob(job)
                    } label: {
                        Label("取り込む", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isTranslating)
                    Spacer()
                    Button("破棄", role: .destructive) {
                        discardPendingCloudJob(job)
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text(project.subtitles.isEmpty
                     ? String(localized: "「取り込む」を押すと、前回の結果から字幕を作ります。")
                     : String(localized: "「取り込む」と、「自動で作り直す」の「今ある字幕」の選択(置き換える / 後ろに追加)に従って字幕に入ります。"))
            }
        }
    }

    private func pendingCloudJobDetail(_ job: CloudJobManifest) -> String {
        let date = job.createdAt.formatted(date: .abbreviated, time: .shortened)
        let quality = CloudTranscriptionQuality(rawValue: job.quality)?.shortName ?? job.model
        var text = date + String(localized: "・クリップ \(job.clips.count) 本・") + quality
        if !job.isComplete {
            text += String(localized: "\n\(job.totalPieceCount) 件中 \(job.completedPieceCount) 件が完了。「取り込む」で残りを待ってから取り込みます。")
        }
        return text
    }

    private func refreshPendingCloudJobs() {
        pendingCloudJobs = CloudBackgroundUploader.shared.pendingJobs()
    }

    /// 前回の結果から字幕を作り直し(区切り・AI 仕上げ)、「既存の字幕」の選択に従って置き換え / 追加する
    private func importPendingCloudJob(_ job: CloudJobManifest) {
        guard transcriptionTask == nil else { return }
        let snapshot = project.snapshot()
        let language = selectedLanguage
        let replace = replaceExisting
        transcriptionTask = Task { @MainActor in
            do {
                let rebuilt = try await transcriber.cues(fromPendingJob: job, snapshot: snapshot, language: language)
                let cues = SubtitleWordTiming.fillingMissing(rebuilt)
                if Task.isCancelled {
                    transcriptionTask = nil
                    refreshPendingCloudJobs()
                    return
                }
                if replace {
                    project.subtitles = cues
                } else {
                    project.subtitles.append(contentsOf: cues)
                }
                project.sortSubtitles()
                CloudBackgroundUploader.shared.discard(jobID: job.id)
                transcriptionTask = nil
                refreshPendingCloudJobs()
                if cues.isEmpty {
                    showAlert(title: String(localized: "声が見つかりませんでした"),
                              message: String(localized: "前回の結果に字幕にできる声がありませんでした。「自動で字幕を作る」でもう一度お試しください。"))
                }
            } catch is CancellationError {
                transcriptionTask = nil
                refreshPendingCloudJobs()
            } catch {
                let cancelled = Task.isCancelled
                transcriptionTask = nil
                refreshPendingCloudJobs()
                if !cancelled {
                    showAlert(title: String(localized: "前回の結果を取り込めませんでした"),
                              message: String(localized: "通信できる場所で、もう一度「取り込む」を押してください。続くときは「破棄」して、自動で字幕を作り直してください。\n\n詳細: ") + error.localizedDescription)
                }
            }
        }
    }

    private func discardPendingCloudJob(_ job: CloudJobManifest) {
        CloudBackgroundUploader.shared.discard(jobID: job.id)
        refreshPendingCloudJobs()
    }

    // MARK: 翻訳

    private var translationSection: some View {
        Section {
            if isAITranslating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("AI で翻訳中…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("キャンセル", role: .destructive) {
                        cancelAITranslation()
                    }
                    .buttonStyle(.borderless)
                }
            } else if isTranslating {
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

            if !isTranslating {
                Button {
                    startAITranslation()
                } label: {
                    Label(selectedLanguage == .english ? String(localized: "AIで日本語に翻訳(文脈を見て自然に)") : String(localized: "AIで翻訳(文脈を見て自然に)"),
                          systemImage: "sparkles")
                }
                .disabled(project.subtitles.isEmpty || isTranscribing)
            }
        } header: {
            Text("翻訳")
        } footer: {
            Text(translationFooterText)
        }
    }

    private var translationFooterText: String {
        let engine = SubtitlePolisher.displayName(of: SubtitlePolisher.resolveEngine(settings: AppSettings.shared))
        let first = String(localized: "元の言語は「話している言語」の設定を使います。初回は翻訳用データのダウンロードを求められることがあります。")
        return first + String(localized: "「AIで翻訳」は前後の字幕も読んで自然な訳にします(いまの AI: ") + engine + ")。"
    }

    // MARK: AI 翻訳(SubtitlePolisher)

    private func startAITranslation() {
        guard aiTranslationTask == nil, !project.subtitles.isEmpty else { return }
        let cues = project.subtitles
        let language = selectedLanguage
        let toEnglish = (language != .english)
        // 始めたときにポイントで使っていたか(ログインの期限切れで途中でサインアウトしても、案内はこちらで決める)
        let viaPoints = CloudAIGateway.usesPoints
        aiTranslationTask = Task { @MainActor in
            let result = await SubtitlePolisher.translate(cues, from: language, toEnglish: toEnglish,
                                                          settings: AppSettings.shared)
            if Task.isCancelled {
                aiTranslationTask = nil
                return
            }
            aiTranslationTask = nil
            guard let result else {
                let detail = SubtitlePolisher.lastErrorMessage ?? ""
                var message: String
                if viaPoints, !detail.isEmpty {
                    // ポイントで使っているとき(ポイント不足・ログインの期限切れなど)は、API キーの案内を出さずに理由だけ
                    message = detail
                } else {
                    message = String(localized: "「文字起こしの方式とAI仕上げ」で Apple Intelligence か OpenAI の API キーを設定してから、もう一度お試しください。")
                    if !detail.isEmpty {
                        message += String(localized: "\n\n詳細: ") + detail
                    }
                }
                showAlert(title: String(localized: "AIで翻訳できませんでした"), message: message)
                return
            }
            // 翻訳中に字幕が変わっていても ID で突き合わせる
            var updated = project.subtitles
            var count = 0
            for translated in result {
                guard let text = translated.translatedText, !text.isEmpty,
                      let i = updated.firstIndex(where: { $0.id == translated.id }) else { continue }
                if updated[i].translatedText != text {
                    updated[i].translatedText = text
                    count += 1
                }
            }
            project.subtitles = updated
            exportURL = nil
            showAlert(title: String(localized: "AIで翻訳しました"),
                      message: String(localized: "\(count) 件の字幕を翻訳しました。「スタイル」の「表示」を「訳文」か「両方」にすると映像に出ます。"))
        }
    }

    private func cancelAITranslation() {
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
    }

    // MARK: 字幕ファイル(SRT)

    private static let subtitleFileTypes: [UTType] = {
        var types: [UTType] = []
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
        types.append(.plainText)
        types.append(.text)
        return types
    }()

    private var hasAnyTranslation: Bool {
        project.subtitles.contains { cue in
            guard let t = cue.translatedText else { return false }
            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var subtitleFileSection: some View {
        Section {
            Toggle("訳文を使う", isOn: $exportUseTranslation)
                .disabled(!hasAnyTranslation || exportBilingual)
                .onChange(of: exportUseTranslation) { _, _ in exportURL = nil }
            Toggle("2言語", isOn: $exportBilingual)
                .disabled(!hasAnyTranslation)
                .onChange(of: exportBilingual) { _, _ in exportURL = nil }

            if let url = exportURL {
                ShareLink(item: url) {
                    Label("字幕ファイルを共有・保存", systemImage: "square.and.arrow.up")
                }
                Button {
                    exportURL = nil
                } label: {
                    Label("作り直す", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.secondary)
            } else {
                Button {
                    exportSRT()
                } label: {
                    Label("字幕ファイル(SRT)を作る", systemImage: "doc.text")
                }
                .disabled(project.subtitles.isEmpty)
            }

            Button {
                isImporterPresented = true
            } label: {
                Label("字幕ファイルを読み込む", systemImage: "square.and.arrow.down")
            }
            .disabled(isTranscribing || isTranslating)
        } header: {
            Text("字幕ファイル")
        } footer: {
            Text("YouTube などにアップするときの字幕ファイル(SRT)を作れます。「訳文を使う」は翻訳した字幕だけ、「2言語」は元の字幕と訳文を両方入れます(翻訳したあとに選べます)。SRT / WebVTT ファイルの読み込みにも対応しています。")
        }
    }

    private func exportSRT() {
        guard !project.subtitles.isEmpty else { return }
        let text = SRTCodec.encode(project.subtitles,
                                   useTranslation: exportUseTranslation,
                                   bilingual: exportBilingual)
        let baseName = project.clips.first.map { $0.name } ?? "subtitles"
        let suffix: String
        if exportBilingual {
            suffix = "_ja_en"
        } else if exportUseTranslation {
            suffix = "_en"
        } else {
            suffix = ""
        }
        let fileName = sanitizedFileName(baseName) + suffix + ".srt"
        do {
            exportURL = try SRTCodec.writeTemporaryFile(text, fileName: fileName)
        } catch {
            showAlert(title: String(localized: "字幕ファイルを作れませんでした"),
                      message: String(localized: "端末の空き容量を確かめて、もう一度お試しください。\n\n詳細: ") + error.localizedDescription)
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = ""
        for scalar in name.unicodeScalars {
            if forbidden.contains(scalar) {
                cleaned.append("_")
            } else {
                cleaned.append(Character(scalar))
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "subtitles" : cleaned
    }

    private func handleSubtitleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showAlert(title: String(localized: "ファイルを開けませんでした"),
                      message: String(localized: "もう一度ファイルを選び直してください。\n\n詳細: ") + error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let decoded = try SRTCodec.decode(data: data)
                let cues = SubtitleWordTiming.fillingMissing(decoded)
                if project.subtitles.isEmpty {
                    pendingImportedCues = cues
                    applyImportedCues(replace: true)
                } else {
                    pendingImportedCues = cues
                    isImportChoicePresented = true
                }
            } catch {
                showAlert(title: String(localized: "字幕ファイルを読み込めませんでした"),
                          message: String(localized: "SRT か WebVTT(.vtt)形式のファイルを選んでください。\n\n詳細: ") + error.localizedDescription)
            }
        }
    }

    private func applyImportedCues(replace: Bool) {
        let cues = pendingImportedCues
        pendingImportedCues = []
        guard !cues.isEmpty else { return }
        if replace {
            project.subtitles = cues
        } else {
            project.subtitles.append(contentsOf: cues)
        }
        project.sortSubtitles()
        exportURL = nil
        appliedShift = 0
        let verb = replace ? String(localized: "読み込みました") : String(localized: "追加しました")
        showAlert(title: String(localized: "読み込み完了"), message: String(localized: "\(cues.count) 件の字幕を") + verb + "。")
    }

    // MARK: スタイル

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SubtitleStylePreset.allCases) { preset in
                    EditorVisualTile(title: preset.displayName, isSelected: preset.matches(project.subtitleStyle)) {
                        var style = project.subtitleStyle
                        preset.apply(to: &style)
                        project.subtitleStyle = style
                    } preview: {
                        CaptionLookPreview(color: Color(uiColor: preset.color.uiColor),
                                           sizeRatio: preset.sizeRatio,
                                           background: preset.hasBackground,
                                           position: preset.position)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var templateChips: some View {
        CaptionTemplatePicker(selection: $project.subtitleStyle.template)
    }

    private var highlightColorBinding: Binding<Color> {
        Binding<Color>(
            get: { Color(hex: project.subtitleStyle.highlightColorHex) ?? Color.yellow },
            set: { project.subtitleStyle.highlightColorHex = subtitleHexString(from: $0) }
        )
    }

    private var subtitleFontBinding: Binding<String> {
        Binding<String>(
            get: { project.subtitleStyle.fontName ?? "" },
            set: { project.subtitleStyle.fontName = $0.isEmpty ? nil : $0 }
        )
    }

    private var hasAnyWordTiming: Bool {
        project.subtitles.contains { !$0.words.isEmpty }
    }

    /// 「詳細設定」を開く・閉じる行
    private var advancedToggleSection: some View {
        Section {
            Button {
                withAnimation {
                    showsAdvanced.toggle()
                }
            } label: {
                HStack {
                    Label("詳細設定", systemImage: "slider.horizontal.3")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            if !showsAdvanced {
                Text("動く字幕(カラオケ風など)・フォント・字幕ファイル(SRT)の書き出し / 読み込み")
            }
        }
    }

    /// 詳細設定: テンプレート・ハイライト色・フォント
    private var advancedStyleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("動く字幕(テンプレート)")
                templateChips
                if project.subtitleStyle.template != .plain, !project.subtitles.isEmpty, !hasAnyWordTiming {
                    Text("このテンプレートは言葉ごとのタイミングを使います。字幕一覧の「…」から「単語タイミングを作り直す」を押してください。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ColorPicker(String(localized: "目立たせる色"), selection: highlightColorBinding, supportsOpacity: false)

            Picker("フォント", selection: subtitleFontBinding) {
                ForEach(SubtitleFontCatalog.options(including: project.subtitleStyle.fontName)) { option in
                    SubtitleFontCatalog.label(for: option)
                        .tag(option.id)
                }
            }
            // 一覧画面で、各フォントの名前をそのフォントで表示する(メニュー形式だとフォントが反映されない)
            .pickerStyle(.navigationLink)
        } header: {
            Text("字幕の見た目(詳細)")
        } footer: {
            Text("「目立たせる色」は、カラオケ風などで今しゃべっている言葉に付く色です。")
        }
    }

    private var styleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("おすすめの見た目")
                presetChips
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("位置")
                CaptionPositionPicker(selection: $project.subtitleStyle.position)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("文字色")
                CaptionColorPicker(selection: $project.subtitleStyle.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("文字サイズ")
                    Spacer()
                    Text("\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.subtitleStyle.sizeRatio, in: 0.02...0.08)
            }

            Toggle("背景を付ける", isOn: $project.subtitleStyle.hasBackground)

            VStack(alignment: .leading, spacing: 6) {
                Text("表示する字幕")
                CaptionDisplayModePicker(selection: $project.subtitleStyle.displayMode)
            }
        } header: {
            Text("スタイル")
        } footer: {
            Text("「表示」は、原文 = 元の字幕、訳文 = 翻訳した字幕、両方 = 2段で表示、です。")
        }
    }

    // MARK: 字幕一覧

    private var cueListSection: some View {
        Section {
            Button {
                let cue = project.addSubtitle(at: player.currentTime)
                editingCueID = cue.id
            } label: {
                Label(project.subtitles.isEmpty ? String(localized: "自分で1つずつ入力する") : String(localized: "再生位置に字幕を追加"), systemImage: "plus.bubble")
            }

            if showsShiftTool && !project.subtitles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper("タイミングを一括ずらす",
                            onIncrement: { shiftAllCues(by: 0.1) },
                            onDecrement: { shiftAllCues(by: -0.1) })
                    HStack {
                        Text(appliedShiftText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("閉じる") {
                            showsShiftTool = false
                            appliedShift = 0
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }

            if project.subtitles.isEmpty {
                Text("字幕はまだありません。上の「自動で字幕を作る」がかんたんです。")
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
            HStack {
                Text("字幕一覧(\(project.subtitles.count))")
                Spacer()
                if !project.subtitles.isEmpty {
                    Menu {
                        Button {
                            appliedShift = 0
                            showsShiftTool = true
                        } label: {
                            Label("タイミングを一括ずらす", systemImage: "arrow.left.and.right")
                        }
                        Button {
                            regenerateWordTimings()
                        } label: {
                            Label("単語タイミングを作り直す", systemImage: "textformat.abc.dottedunderline")
                        }
                        Button(role: .destructive) {
                            isDeleteAllPresented = true
                        } label: {
                            Label("すべて削除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .frame(width: 44, height: 32)
                            .contentShape(Rectangle())
                    }
                    .textCase(nil)
                    .accessibilityLabel("字幕一覧のその他の操作")
                }
            }
        }
    }

    private var appliedShiftText: String {
        let rounded = (appliedShift * 10).rounded() / 10
        if abs(rounded) < 0.05 {
            return String(localized: "±0.1 秒ずつ全字幕を前後に動かします")
        }
        let sign = rounded > 0 ? "+" : ""
        let amount = String(format: "%.1f", rounded)
        return String(localized: "合計 ") + sign + amount + String(localized: " 秒ずらしました")
    }

    /// 全字幕を delta 秒ずらす。先頭の字幕が 0 秒より前にならないよう delta を丸める
    private func shiftAllCues(by delta: Double) {
        guard !project.subtitles.isEmpty else { return }
        var effective = delta
        if delta < 0 {
            let minStart = project.subtitles.map { $0.start }.min() ?? 0
            effective = max(delta, -minStart)
        }
        guard abs(effective) > 0.0001 else { return }
        var cues = project.subtitles
        for i in cues.indices {
            let oldStart = cues[i].start
            let oldEnd = cues[i].end
            let newStart = max(0, oldStart + effective)
            let newEnd = max(newStart + 0.2, oldEnd + effective)
            cues[i].start = newStart
            cues[i].end = newEnd
            cues[i].words = SubtitleWordTiming.rescaled(cues[i].words,
                                                        oldStart: oldStart, oldEnd: oldEnd,
                                                        newStart: newStart, newEnd: newEnd)
        }
        project.subtitles = cues
        project.sortSubtitles()
        appliedShift += effective
        exportURL = nil
    }

    /// 全字幕に、文字数に比例した単語タイミングを付け直す(カラオケ風テンプレート用)
    private func regenerateWordTimings() {
        guard !project.subtitles.isEmpty else { return }
        var cues = project.subtitles
        for i in cues.indices {
            cues[i].words = SubtitleWordTiming.distribute(cue: cues[i])
        }
        project.subtitles = cues
        showAlert(title: String(localized: "単語タイミングを更新しました"),
                  message: String(localized: "\(cues.count) 件の字幕に、文字数に応じた単語タイミングを付けました。カラオケ風などのテンプレートで単語ごとに色が変わります。"))
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
                    Text(cue.text.isEmpty ? String(localized: "(空)") : cue.text)
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

    private func showAlert(title: String, message: String, offersSettings: Bool = false) {
        alertTitle = title
        alertOffersSettings = offersSettings
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
        .onChange(of: cue.wrappedValue.text) { _, _ in
            // 文字を変えたら単語タイミングを付け直す(単語を使うテンプレートのとき、または元々付いていたとき)
            var c = cue.wrappedValue
            guard !c.words.isEmpty || project.subtitleStyle.template != .plain else { return }
            c.words = SubtitleWordTiming.distribute(cue: c)
            cue.wrappedValue = c
        }
    }

    private func setStart(_ cue: Binding<SubtitleCue>, _ value: Double) {
        var c = cue.wrappedValue
        let oldStart = c.start
        let oldEnd = c.end
        c.start = max(0, value)
        if c.end < c.start + minimumLength {
            c.end = c.start + minimumLength
        }
        c.words = SubtitleWordTiming.rescaled(c.words, oldStart: oldStart, oldEnd: oldEnd,
                                              newStart: c.start, newEnd: c.end)
        cue.wrappedValue = c
        project.sortSubtitles()
    }

    private func setEnd(_ cue: Binding<SubtitleCue>, _ value: Double) {
        var c = cue.wrappedValue
        let oldStart = c.start
        let oldEnd = c.end
        c.end = max(value, c.start + minimumLength)
        c.words = SubtitleWordTiming.rescaled(c.words, oldStart: oldStart, oldEnd: oldEnd,
                                              newStart: c.start, newEnd: c.end)
        cue.wrappedValue = c
        project.sortSubtitles()
    }
}

// MARK: - 単語タイミング

/// 字幕の単語タイミング(カラオケ風・単語ごとのテンプレート用)。
/// 音声認識から単語の時刻が取れないため、文字数に比例して cue の区間を分配する。
enum SubtitleWordTiming {
    /// cue の区間を、単語の文字数に比例して分配したタイミングを返す
    static func distribute(cue: SubtitleCue) -> [SubtitleWord] {
        distribute(text: cue.text, start: cue.start, end: cue.end)
    }

    static func distribute(text: String, start: Double, end: Double) -> [SubtitleWord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, end > start else { return [] }
        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        let span = end - start
        var result: [SubtitleWord] = []
        result.reserveCapacity(tokens.count)
        var cursor = start
        for (i, token) in tokens.enumerated() {
            let wordEnd = (i == tokens.count - 1) ? end : min(end, cursor + span * weights[i] / total)
            result.append(SubtitleWord(text: token, start: cursor, end: wordEnd))
            cursor = wordEnd
        }
        return result
    }

    /// words が空の cue にだけタイミングを付ける
    static func fillingMissing(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { cue in
            guard cue.words.isEmpty else { return cue }
            var c = cue
            c.words = distribute(cue: c)
            return c
        }
    }

    /// cue の開始・終了を変えたとき、単語の時刻を古い区間から新しい区間へ線形に写す
    static func rescaled(_ words: [SubtitleWord],
                         oldStart: Double, oldEnd: Double,
                         newStart: Double, newEnd: Double) -> [SubtitleWord] {
        guard !words.isEmpty else { return words }
        let oldSpan = oldEnd - oldStart
        let newSpan = newEnd - newStart
        guard oldSpan > 0.0001, newSpan > 0 else { return words }
        let scale = newSpan / oldSpan
        return words.map { word in
            SubtitleWord(text: word.text,
                         start: newStart + (word.start - oldStart) * scale,
                         end: newStart + (word.end - oldStart) * scale)
        }
    }

    /// NLTokenizer で単語に分ける。単語の後ろの句読点・記号は前の単語に付ける(日本語・英語とも)
    private static func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }

        var tokens: [String] = []
        for (i, range) in ranges.enumerated() {
            var token = ""
            if i == 0, range.lowerBound > text.startIndex {
                // 先頭の記号(「 など)は最初の単語に付ける
                let lead = text[text.startIndex..<range.lowerBound].filter { !$0.isWhitespace && !$0.isNewline }
                token += String(lead)
            }
            token += String(text[range])
            let gapEnd = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : text.endIndex
            if range.upperBound < gapEnd {
                let trail = text[range.upperBound..<gapEnd].filter { !$0.isWhitespace && !$0.isNewline }
                token += String(trail)
            }
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                tokens.append(cleaned)
            }
        }

        if tokens.isEmpty {
            // 分割できないときは空白区切り、それも無ければ全体を 1 語にする
            let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return parts.isEmpty ? [text] : parts
        }
        return tokens
    }
}

// MARK: - フォントの選択肢

/// 字幕・サムネで共通のフォント選択肢。id が空文字ならシステムフォント
enum SubtitleFontCatalog {
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let builtIn: [Option] = [
        Option(id: "", label: String(localized: "ヒラギノ角ゴ W3(標準・映画字幕風)")),
        Option(id: "HiraginoSans-W6", label: String(localized: "ヒラギノ角ゴ W6(太め)")),
        Option(id: "HiraMinProN-W3", label: String(localized: "ヒラギノ明朝 W3(上品)")),
        Option(id: "HiraMinProN-W6", label: String(localized: "ヒラギノ明朝 W6")),
        Option(id: "HiraMaruProN-W4", label: String(localized: "ヒラギノ丸ゴ W4")),
        Option(id: "Noteworthy-Bold", label: String(localized: "Noteworthy(ノート風)")),
        Option(id: "BradleyHandITCTT-Bold", label: String(localized: "Bradley Hand(手書き風)")),
        Option(id: "Chalkduster", label: String(localized: "Chalkduster(チョーク)")),
        Option(id: "MarkerFelt-Wide", label: String(localized: "Marker Felt(マーカー)")),
        Option(id: "AvenirNext-Bold", label: "Avenir Next Bold"),
        Option(id: "Futura-Bold", label: "Futura Bold")
    ]

    /// 組み込み + 「ファイル」から読み込んだフォント(MediaTools)+ 現在選ばれている名前(一覧に無ければ追加)
    static func options(including current: String?) -> [Option] {
        BundledFonts.registerAll()
        var result = builtIn + BundledFonts.all.map { Option(id: $0.name, label: $0.label) }
        var known = Set(result.map { $0.id })
        for name in MediaTools.storedFontNames() where !known.contains(name) {
            result.append(Option(id: name, label: GoogleFontsService.displayName(forPostScript: name) ?? String(localized: "\(name)(読み込み)")))
            known.insert(name)
        }
        if let current, !current.isEmpty, !known.contains(current) {
            result.append(Option(id: current, label: current))
        }
        return result
    }

    /// Picker 用のラベル(そのフォントで表示)
    static func label(for option: Option) -> some View {
        Group {
            if option.id.isEmpty {
                // 標準は字幕と同じヒラギノ角ゴ W3
                Text(option.label)
                    .font(.custom("HiraginoSans-W3", size: 17))
            } else {
                Text(option.label)
                    .font(.custom(option.id, size: 17))
            }
        }
    }
}
