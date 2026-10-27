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

// MARK: - デザインの見本

/// 「デザイン」の見本タイル。1 枚で描き方(テンプレート)と色・大きさ・背景・フォントをまとめて決める。
/// 位置と表示(原文 / 訳文)は触らない
fileprivate enum CaptionLook: String, CaseIterable, Identifiable {
    case bold, karaoke, pop, marker, typewriter, box, yellow, simple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: return String(localized: "太縁")
        case .karaoke: return String(localized: "カラオケ")
        case .pop: return String(localized: "ポップ")
        case .marker: return String(localized: "マーカー")
        case .typewriter: return String(localized: "タイプ")
        case .box: return String(localized: "ボックス")
        case .yellow: return String(localized: "イエロー")
        case .simple: return String(localized: "シンプル")
        }
    }

    var template: CaptionTemplate {
        switch self {
        case .bold: return .outlineBig
        case .karaoke: return .karaoke
        case .pop: return .boxPop
        case .marker: return .pillHighlight
        case .typewriter: return .typewriter
        case .box, .yellow, .simple: return .plain
        }
    }

    var color: SubtitleColor {
        self == .yellow ? .yellow : .white
    }

    var sizeRatio: CGFloat {
        switch self {
        case .bold: return SubtitleStyle.starter.sizeRatio
        case .karaoke, .pop, .marker, .yellow: return 0.06
        case .typewriter: return 0.055
        case .box: return 0.05
        case .simple: return 0.045
        }
    }

    var hasBackground: Bool { self == .box }

    /// シンプルだけ標準の細い書体。ほかは太字
    var fontName: String? {
        self == .simple ? nil : SubtitleStyle.starter.fontName
    }

    func apply(to style: inout SubtitleStyle) {
        style.template = template
        style.color = color
        style.sizeRatio = sizeRatio
        style.hasBackground = hasBackground
        style.fontName = fontName
    }

    /// 今のスタイルがこの見本と同じか(フォントを自分で変えていても同じとみなす)
    func matches(_ style: SubtitleStyle) -> Bool {
        style.template == template
            && style.color == color
            && style.hasBackground == hasBackground
            && abs(style.sizeRatio - sizeRatio) < 0.0005
    }
}

// MARK: - 字幕エディタ

/// 開いたときに開いて見せる場所(編集画面の「キャプションを翻訳」などから渡す)
enum SubtitleEditorSection {
    case translate
}

struct SubtitleEditorView: View {
    @Bindable var project: EditorProject
    let player: PlayerController
    /// 選択中のクリップ(クリップのメニューの「キャプションを作成」から開いたとき)。そのクリップだけ字幕を作れる
    var focusClipID: UUID? = nil
    /// 開いたときに開いて見せる場所(nil なら一覧)
    var initialSection: SubtitleEditorSection? = nil

    @Environment(\.dismiss) private var dismiss

    /// 一覧の上の操作列で開くツール
    private enum CaptionTool: Hashable {
        case autoCaption, translate, file
    }

    /// 今あるキャプションを置き換えるか追加するかを聞いてから始める操作
    private enum ReplaceTarget {
        case transcription
        case cloudJob(CloudJobManifest)
    }

    /// アラートに付ける追加のボタン
    private enum AlertAction {
        /// システム設定(音声認識の許可)
        case systemSettings
        /// 「文字起こしとAI仕上げ」(API キー・方式)
        case aiSettings
        /// 「アカウントとポイント」(ログイン・ポイント不足)
        case account
        /// 原文と訳文を 2 段で出す
        case showBoth

        var title: String {
            switch self {
            case .systemSettings: return String(localized: "設定を開く")
            case .aiSettings: return String(localized: "文字起こしとAI仕上げ")
            case .account: return String(localized: "アカウントとポイント")
            case .showBoth: return String(localized: "両方で表示")
            }
        }
    }

    /// 操作列の行の id(「翻訳」から開いたときにここへスクロールする)
    private static let toolRowID = "captionTools"

    @State private var transcriber = TranscriptionService()
    /// 話している言語(訳を付けるかも含む)
    @State private var captionChoice: CaptionLanguage = .japanese
    /// 字幕を作る範囲(全体 / 選んだクリップだけ)
    @State private var captionScope: CaptionScope = .all
    /// 「全体」のときに選んでいた言語(「選んだクリップだけ」から戻ったときに戻す)
    @State private var wholeCaptionChoice: CaptionLanguage = .japanese
    /// 前回選んだ 置き換える / 後ろに追加(作り直す・取り込む前の確認で選んだほうを覚える)
    @State private var replaceExisting: Bool = true
    /// 作り直す・取り込む前の「置き換えますか?」で待っている操作
    @State private var pendingReplaceTarget: ReplaceTarget?
    /// 「破棄」の確認で破棄しようとしている前回の結果
    @State private var pendingDiscardJob: CloudJobManifest?
    @State private var transcriptionTask: Task<Void, Never>?
    /// 前回(アプリが終了するなどして)取り込めなかったクラウド文字起こし(CloudBackgroundUploader.pendingJobs)
    @State private var pendingCloudJobs: [CloudJobManifest] = []

    @State private var translationRequest: TranslationRequest?
    /// AI 翻訳(SubtitlePolisher.translate)の実行中タスク
    @State private var aiTranslationTask: Task<Void, Never>?
    /// AI 翻訳の前に見せるポイントの目安(ポイントで使うときだけ。nil なら確認を出していない)
    @State private var aiTranslationEstimate: Int?

    @State private var editingCueID: UUID?
    /// 字幕 1 件の編集を開いたときの文(閉じたときに、ほかの字幕の同じ言葉も直すか聞くため)
    @State private var editStartText: String?
    @State private var termReplacement: CaptionTermReplacement?

    @State private var alertTitle: String = ""
    @State private var alertMessage: String?
    /// アラートの追加ボタン(設定・アカウント・両方で表示)
    @State private var alertAction: AlertAction?
    /// アラートから「文字起こしとAI仕上げ」を開く
    @State private var showsAISettings: Bool = false
    /// アラートから「アカウントとポイント」を開く
    @State private var showsAccountSheet: Bool = false

    /// 文字起こし・翻訳の途中に「閉じる」を押したときの確認
    @State private var isCloseConfirmationPresented: Bool = false
    /// 操作列で開いているツール(自動作成 / 翻訳 / ファイル)
    @State private var expandedTool: CaptionTool?
    /// 「デザイン」の「細かく調整」を開いているか
    @State private var showsStyle: Bool = false
    /// 翻訳を AI で行う(オンなら SubtitlePolisher.translate、オフなら端末の翻訳)
    @State private var useAITranslation: Bool = false
    /// Google Fonts を探す画面
    @State private var showsFontBrowser: Bool = false
    /// 開いたときの準備(選んだクリップの既定・翻訳へのスクロール)を 1 回だけ行う
    @State private var didPrepareOnAppear: Bool = false

    // 字幕ファイル(SRT)の書き出し・読み込み
    @State private var exportUseTranslation: Bool = false
    @State private var exportBilingual: Bool = false
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
    /// 字幕の自動作成が終わったときに少しのあいだ出す完了の表示(作った字幕の件数)
    @State private var captionDoneCount: Int?

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
                ScrollViewReader { proxy in
                    Form {
                        pendingCloudJobSection
                        if project.subtitles.isEmpty {
                            // キャプションが無いときは「自動で作る」を最初に大きく出す
                            transcriptionSection
                            designSection
                            cueListSection
                        } else {
                            // キャプションがあるときは デザイン → 操作列 → 開いたツール → 一覧
                            designSection
                            captionToolSection
                            if let tool = expandedTool {
                                switch tool {
                                case .autoCaption: transcriptionSection
                                case .translate: translationSection
                                case .file: subtitleFileSection
                                }
                            }
                            cueListSection
                        }
                    }
                    // カラオケなど単語を使う描き方にしたら、単語の時刻が無いキャプションにその場で付ける
                    .onChange(of: project.subtitleStyle.template) { _, template in
                        fillMissingWordTimings(for: template)
                    }
                    .onAppear {
                        guard !didPrepareOnAppear else { return }
                        didPrepareOnAppear = true
                        // クリップを選んで開いたときは「選んだクリップだけ」にし、自動作成を開いておく
                        applyFocusClipDefaults()
                        if focusClip != nil, !project.subtitles.isEmpty {
                            expandedTool = .autoCaption
                        }
                        // 「キャプションを翻訳」から開いたときは翻訳を開いて、そこへスクロールする
                        if initialSection == .translate, !project.subtitles.isEmpty {
                            expandedTool = .translate
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                withAnimation {
                                    proxy.scrollTo(SubtitleEditorView.toolRowID, anchor: .top)
                                }
                            }
                        }
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
            // 文字起こし・翻訳の途中はスワイプで閉じられないようにする(閉じると止まるため)
            .interactiveDismissDisabled(isTranscribing || isTranslating)
            .confirmationDialog(isTranscribing ? String(localized: "文字起こしを止めて閉じますか?") : String(localized: "翻訳を止めて閉じますか?"),
                                isPresented: $isCloseConfirmationPresented,
                                titleVisibility: .visible) {
                Button("止めて閉じる", role: .destructive) {
                    cancelTranscription()
                    cancelAITranslation()
                    translationRequest = nil
                    dismiss()
                }
                Button("続ける", role: .cancel) { }
            } message: {
                Text(isTranscribing
                     ? String(localized: "閉じると、いま作っているキャプションは破棄されます。")
                     : String(localized: "閉じると、翻訳は途中で止まります。"))
            }
            // 作り直す・取り込む前に、今あるキャプションをどうするか聞く(選んだほうを次回の既定にする)
            .confirmationDialog("\(project.subtitles.count) 件のキャプションを置き換えますか?",
                                isPresented: Binding(get: { pendingReplaceTarget != nil },
                                                     set: { if !$0 { pendingReplaceTarget = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingReplaceTarget) { target in
                Button("置き換える", role: .destructive) {
                    runReplaceTarget(target, replace: true)
                }
                Button("追加する") {
                    runReplaceTarget(target, replace: false)
                }
                Button("キャンセル", role: .cancel) { }
            }
            // 前回の結果(有料のこともある)は、確認してから破棄する
            .confirmationDialog("前回の結果を破棄しますか?",
                                isPresented: Binding(get: { pendingDiscardJob != nil },
                                                     set: { if !$0 { pendingDiscardJob = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDiscardJob) { job in
                Button("破棄", role: .destructive) {
                    discardPendingCloudJob(job)
                }
                Button("キャンセル", role: .cancel) { }
            } message: { _ in
                Text("破棄した結果は戻せません。")
            }
            // ポイントで使うときは、使うポイントの目安を見せてから AI 翻訳を始める
            .confirmationDialog("AI翻訳を始めますか?",
                                isPresented: Binding(get: { aiTranslationEstimate != nil },
                                                     set: { if !$0 { aiTranslationEstimate = nil } }),
                                titleVisibility: .visible,
                                presenting: aiTranslationEstimate) { _ in
                Button("翻訳する") {
                    startAITranslation()
                }
                Button("キャンセル", role: .cancel) { }
            } message: { points in
                Text(String(localized: "約 \(points) pt を使います。"))
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
                // Whisper が入っていないビルドでは選べないので、前に選んでいたら Apple に戻す
                if settings.transcriptionEngine == .whisper, !WhisperTranscriber.isAvailable {
                    settings.transcriptionEngine = .apple
                }
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
            // アラートの「文字起こしとAI仕上げ」(AccountService.swift の CloudAIGateway.recovery が .apiKey のとき)
            .navigationDestination(isPresented: $showsAISettings) {
                TranscriptionSettingsView()
            }
            // アラートの「アカウントとポイント」(ログイン・ポイント不足のとき。AccountPointsView.swift)
            .sheet(isPresented: $showsAccountSheet) {
                AccountPointsSheet()
            }
            // 「フォントを追加」(詳細設定)。入れたフォントをそのまま選ぶ
            .sheet(isPresented: $showsFontBrowser) {
                GoogleFontsBrowser { name in
                    project.subtitleStyle.fontName = name
                }
            }
            .onChange(of: editingCueID) { oldID, newID in
                if let newID {
                    editStartText = project.subtitles.first(where: { $0.id == newID })?.text
                    return
                }
                // 編集から戻った: 「再生位置に追加」で入れて何も書かなかったものは消す
                if let oldID, let cue = project.subtitles.first(where: { $0.id == oldID }),
                   cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   (cue.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    project.removeSubtitle(id: oldID)
                    editStartText = nil
                    return
                }
                // 変えた言葉がほかの字幕にもあれば、まとめて直すか聞く
                if let oldID, let before = editStartText,
                   let after = project.subtitles.first(where: { $0.id == oldID })?.text {
                    termReplacement = CaptionTermReplace.suggestion(oldText: before, newText: after,
                                                                    editedCueID: oldID, in: project.subtitles)
                }
                editStartText = nil
            }
            .alert(termReplacement?.question ?? "",
                   isPresented: Binding(get: { termReplacement != nil },
                                        set: { if !$0 { termReplacement = nil } }),
                   presenting: termReplacement) { replacement in
                Button(replacement.confirmTitle) {
                    CaptionTermReplace.apply(replacement, to: project)
                    termReplacement = nil
                }
                Button(replacement.rememberTitle) {
                    CaptionTermReplace.apply(replacement, to: project)
                    CaptionTermDictionary.add(from: replacement.from, to: replacement.to)
                    termReplacement = nil
                }
                Button("このままにする", role: .cancel) {}
            }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: SubtitleEditorView.subtitleFileTypes,
                          allowsMultipleSelection: false) { result in
                handleSubtitleFileImport(result)
            }
            .confirmationDialog("読み込んだ \(pendingImportedCues.count) 件で、今あるキャプションを置き換えますか?",
                                isPresented: $isImportChoicePresented,
                                titleVisibility: .visible) {
                Button("置き換える", role: .destructive) {
                    applyImportedCues(replace: true)
                }
                Button("追加する") {
                    applyImportedCues(replace: false)
                }
                Button("キャンセル", role: .cancel) {
                    pendingImportedCues = []
                }
            }
            .confirmationDialog("\(project.subtitles.count) 件のキャプションをすべて削除しますか?",
                                isPresented: $isDeleteAllPresented,
                                titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) {
                    project.subtitles.removeAll()
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
                                            fraction: transcriber.isPreparingModel ? nil : transcriber.progress,
                                            status: isCancellingTranscription
                                                ? String(localized: "キャンセルしています…")
                                                : (transcriber.statusText.isEmpty ? String(localized: "準備中…") : transcriber.statusText),
                                            onCancel: isCancellingTranscription ? nil : { cancelTranscription() },
                                            onSwitchToApple: transcriber.canSwitchToApple && !isCancellingTranscription
                                                ? { transcriber.switchToAppleSpeech() } : nil,
                                            robot: transcriber.isPreparingModel
                                                ? (transcriber.isDownloadingModel ? .modelDownload : .modelLoading)
                                                : .subtitles)
            }
        }
        // 字幕ができたときの完了の表示(ロボットがサムズアップ。タップか 3 秒で消える)
        .overlay {
            if let count = captionDoneCount {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        RobotWorkshop(clip: .subtitlesComplete)
                        Text("キャプションができました")
                            .font(.headline)
                        Text(String(localized: "\(count) 件のキャプションを作りました"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(width: 280)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .contentShape(Rectangle())
                .onTapGesture { captionDoneCount = nil }
                .transition(.opacity)
            }
        }
        .onChange(of: isTranscribing) { _, running in
            if !running { isCancellingTranscription = false }
        }
        .subtitleTranslation(project: project, request: $translationRequest, onFinish: { result in
            switch result {
            case .success(let count):
                // 表示モードは書き出しにも効くので勝手に切り替えず、ボタンで選べるようにする
                showAlert(title: String(localized: "翻訳しました"),
                          message: String(localized: "\(count) 件のキャプションを翻訳しました。"),
                          action: .showBoth)
            case .failure(let error):
                showAlert(title: String(localized: "翻訳できませんでした"),
                          message: String(localized: "もう一度お試しください。続くときは「AIで自然に」をオンにしてください。\n\n詳細: ") + error.localizedDescription)
            }
        })
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            if let action = alertAction {
                Button(action.title) {
                    perform(action)
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

    /// 縦の動画か(縦はプレビューを大きくして、キャプションの大きさ・縁取りを見比べられるようにする)
    private var isPortraitCanvas: Bool {
        let size = player.renderSize
        return size.height > size.width * 1.1
    }

    private var previewHeader: some View {
        // 値で渡す(高さを決めるクロージャの中で self を読まない)
        let portrait = isPortraitCanvas
        return VStack(spacing: 6) {
            PreviewView(player: player)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { length, _ in
                    portrait ? max(220, (length * 0.4).rounded()) : 220
                }
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

    /// キャプションが無いときは大きなカード、あるときは操作列の「自動作成」で開く
    private var transcriptionSection: some View {
        let isFirstTime = project.subtitles.isEmpty
        return Section {
            if isFirstTime {
                autoCaptionIntro
            }

            // クリップを選んで開いたときは、そのクリップだけ作ることもできる
            if focusClip != nil {
                Picker("作る範囲", selection: $captionScope) {
                    Text("全体").tag(CaptionScope.all)
                    Text("選んだクリップだけ").tag(CaptionScope.clip)
                }
                .pickerStyle(.segmented)
                .disabled(isTranscribing)
            }

            Picker("話している言語", selection: $captionChoice) {
                ForEach(CaptionLanguage.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .disabled(isTranscribing)

            if captionScope == .clip, focusClip != nil {
                Text("選んだクリップの範囲だけ作り直します。言語はこのクリップに記憶します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if clipsWithOwnLanguage > 0 {
                Text(String(localized: "\(clipsWithOwnLanguage) 本のクリップは、そのクリップで選んだ言語で作ります。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 文字起こし中は、画面全体に作業カードを重ねる(body の overlay)。
            // 今あるキャプションを置き換えるか追加するかは、押したあとの確認で選ぶ
            autoCaptionButton(isFirstTime: isFirstTime)

            NavigationLink {
                TranscriptionSettingsView()
            } label: {
                HStack {
                    Label("文字起こしとAI仕上げ", systemImage: "gearshape")
                    Spacer()
                    Text(AppSettings.shared.transcriptionEngine.shortName)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isTranscribing)
        } footer: {
            if project.isEmpty {
                Text("先に動画を追加")
            }
        }
        .onChange(of: captionScope) { oldScope, scope in
            if scope == .clip {
                // 「選んだクリップだけ」にしたら、そのクリップで前に選んだ言語にする
                if oldScope == .all { wholeCaptionChoice = captionChoice }
                if let saved = focusClip?.captionLanguage {
                    captionChoice = saved
                }
            } else {
                // 「全体」に戻したら、全体で選んでいた言語に戻す(クリップの言語がほかのクリップに広がらないように)
                captionChoice = wholeCaptionChoice
            }
        }
    }

    /// 話している言語(訳を付けるかは除く)
    private var selectedLanguage: TranscriptionLanguage { captionChoice.spoken }

    /// 選択中のクリップ(まだプロジェクトにあれば)
    private var focusClip: Clip? {
        guard let focusClipID else { return nil }
        return project.clips.first { $0.id == focusClipID }
    }

    /// 自分の言語を選んであるクリップの数
    private var clipsWithOwnLanguage: Int {
        project.clips.filter { $0.captionLanguage != nil }.count
    }

    /// クリップを選んで開いたときは「選んだクリップだけ」にし、そのクリップの言語にする
    private func applyFocusClipDefaults() {
        guard let clip = focusClip else { return }
        wholeCaptionChoice = captionChoice
        captionScope = .clip
        if let saved = clip.captionLanguage {
            captionChoice = saved
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
            Text("声からキャプションを作ります")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private func autoCaptionButton(isFirstTime: Bool) -> some View {
        Button {
            requestTranscription()
        } label: {
            Label(isFirstTime ? String(localized: "自動でキャプションを作る") : String(localized: "自動で作り直す"), systemImage: "waveform")
                .font(isFirstTime ? Font.headline : Font.body)
                .frame(maxWidth: .infinity, minHeight: isFirstTime ? 44 : 32)
        }
        .buttonStyle(.borderedProminent)
        .disabled(project.isEmpty || isTranslating || isTranscribing)
    }

    /// 文字起こし・翻訳の途中は確認してから閉じる(閉じると止まるため)
    private func requestClose() {
        if isTranscribing || isTranslating {
            isCloseConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// アラートの追加ボタンを押したとき
    private func perform(_ action: AlertAction) {
        switch action {
        case .systemSettings:
            openSystemSettings()
        case .aiSettings:
            showsAISettings = true
        case .account:
            showsAccountSheet = true
        case .showBoth:
            project.subtitleStyle.displayMode = .both
        }
    }

    /// クラウド AI のエラーを、原因に合ったボタン付きで出す
    /// (ログインの期限切れ・ポイント不足 → アカウントとポイント、API キー → 文字起こしとAI仕上げ。AccountService.swift の CloudAIGateway.recovery)
    private func presentCloudError(_ error: Error, title: String, retryHint: String, fallbackAction: AlertAction? = nil) {
        switch CloudAIGateway.recovery(for: error) {
        case .signIn, .points:
            // 原因(サーバーの文)をそのまま。通信の案内は出さない
            showAlert(title: title, message: error.localizedDescription, action: .account)
        case .apiKey:
            showAlert(title: title,
                      message: String(localized: "「文字起こしとAI仕上げ」で Apple Intelligence か OpenAI の API キーを設定してください。\n\n詳細: ") + error.localizedDescription,
                      action: .aiSettings)
        case .none:
            showAlert(title: title,
                      message: retryHint + String(localized: "\n\n詳細: ") + error.localizedDescription,
                      action: fallbackAction)
        }
    }

    /// 字幕の自動作成が終わったことを少しのあいだ見せる(3 秒で自動で消える)
    private func showCaptionDone(count: Int) {
        withAnimation(.easeOut(duration: 0.25)) { captionDoneCount = count }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if captionDoneCount == count {
                withAnimation(.easeIn(duration: 0.25)) { captionDoneCount = nil }
            }
        }
    }

    /// 今あるキャプションを消す前に、置き換えるか追加するかを聞く(選んだクリップだけのときはその範囲だけなので聞かない)
    private func requestTranscription() {
        if !project.subtitles.isEmpty, !(captionScope == .clip && focusClip != nil) {
            pendingReplaceTarget = .transcription
        } else {
            startTranscription(replace: replaceExisting)
        }
    }

    /// 「置き換える / 追加する」を選んだあとに、待っていた操作を始める(選んだほうを覚えておく)
    private func runReplaceTarget(_ target: ReplaceTarget, replace: Bool) {
        replaceExisting = replace
        switch target {
        case .transcription:
            startTranscription(replace: replace)
        case .cloudJob(let job):
            importPendingCloudJob(job, replace: replace)
        }
    }

    private func startTranscription(replace: Bool) {
        guard transcriptionTask == nil else { return }
        // 「選んだクリップだけ」のときは、そのクリップに言語を覚えておく(全体で作り直すときもその言語になる)
        let onlyClipID: UUID? = (captionScope == .clip) ? focusClip?.id : nil
        if let onlyClipID, let index = project.index(of: onlyClipID) {
            project.clips[index].captionLanguage = captionChoice
        }
        let snapshot = project.snapshot()
        let language = selectedLanguage
        let defaultCaption = captionChoice
        transcriptionTask = Task { @MainActor in
            let authorized = await transcriber.requestAuthorization()
            guard authorized else {
                transcriptionTask = nil
                showAlert(title: String(localized: "音声認識を許可してください"),
                          message: String(localized: "「設定を開く」→「音声認識」をオンにしてから、もう一度「自動で作る」を押してください。"),
                          action: .systemSettings)
                return
            }
            if Task.isCancelled {
                transcriptionTask = nil
                return
            }
            // 使い勝手の計測: 字幕を作り始めた・終わった・失敗した(方式と所要時間の区分だけ)
            let engine = AppSettings.shared.transcriptionEngine.rawValue
            let startedAt = Date()
            Analytics.shared.track("transcribe_start", ["engine": engine])
            do {
                let transcribed = try await transcriber.transcribe(snapshot: snapshot, language: language,
                                                                   defaultCaption: defaultCaption,
                                                                   clipIDs: onlyClipID.map { [$0] })
                // カラオケ風テンプレート用に、単語タイミングが無い字幕へ文字数比例のタイミングを付ける
                let cues = SubtitleWordTiming.fillingMissing(transcribed)
                if Task.isCancelled {
                    transcriptionTask = nil
                    Analytics.shared.track("transcribe_cancelled", ["engine": engine])
                    return
                }
                if let onlyClipID, let range = project.outputRange(ofClip: onlyClipID) {
                    // そのクリップの範囲にあった字幕だけを入れ替える(ほかのクリップの字幕はそのまま)
                    project.subtitles.removeAll { $0.start < range.end - 0.01 && $0.end > range.start + 0.01 }
                    project.subtitles.append(contentsOf: cues)
                } else if replace {
                    project.subtitles = cues
                } else {
                    project.subtitles.append(contentsOf: cues)
                }
                project.sortSubtitles()
                transcriptionTask = nil
                Analytics.shared.track("transcribe_done", ["engine": engine,
                                                           "took": Analytics.durationBucket(Date().timeIntervalSince(startedAt)),
                                                           "cues": cues.isEmpty ? "0" : Analytics.countBucket(cues.count)])
                if !cues.isEmpty { Analytics.shared.captionsDone() }
                if cues.isEmpty {
                    showAlert(title: String(localized: "声が見つかりませんでした"),
                              message: String(localized: "話している言語が合っているか確かめて、もう一度お試しください。BGMだけの動画ではキャプションは作られません。"))
                } else {
                    showCaptionDone(count: cues.count)
                }
            } catch is CancellationError {
                transcriptionTask = nil
                Analytics.shared.track("transcribe_cancelled", ["engine": engine])
            } catch TranscriptionError.notAuthorized {
                // Whisper の準備中に Apple 音声認識へ切り替えたあと、音声認識の許可が無かったとき
                transcriptionTask = nil
                Analytics.shared.track("transcribe_failed", ["engine": engine, "kind": "not_authorized"])
                showAlert(title: String(localized: "音声認識を許可してください"),
                          message: String(localized: "「設定を開く」→「音声認識」をオンにしてから、もう一度「自動で作る」を押してください。"),
                          action: .systemSettings)
            } catch {
                let cancelled = Task.isCancelled
                transcriptionTask = nil
                Analytics.shared.track(cancelled ? "transcribe_cancelled" : "transcribe_failed", ["engine": engine])
                if !cancelled {
                    presentCloudError(error,
                                      title: String(localized: "キャプションを作れませんでした"),
                                      retryHint: String(localized: "もう一度「自動で作る」を押してください。続くときは「文字起こしとAI仕上げ」で方式を変えてください。"),
                                      fallbackAction: .aiSettings)
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
                        requestImportPendingCloudJob(job)
                    } label: {
                        Label("取り込む", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isTranslating)
                    Spacer()
                    Button("破棄", role: .destructive) {
                        pendingDiscardJob = job
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text(project.subtitles.isEmpty
                     ? String(localized: "「取り込む」で前回の結果からキャプションを作ります。")
                     : String(localized: "「取り込む」のとき、今あるキャプションを置き換えるか追加するかを選べます。"))
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

    /// 今あるキャプションがあれば、置き換えるか追加するかを聞いてから取り込む
    private func requestImportPendingCloudJob(_ job: CloudJobManifest) {
        if project.subtitles.isEmpty {
            importPendingCloudJob(job, replace: true)
        } else {
            pendingReplaceTarget = .cloudJob(job)
        }
    }

    /// 前回の結果から字幕を作り直し(区切り・AI 仕上げ)、置き換え / 追加する
    private func importPendingCloudJob(_ job: CloudJobManifest, replace: Bool) {
        guard transcriptionTask == nil else { return }
        let snapshot = project.snapshot()
        let language = selectedLanguage
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
                              message: String(localized: "前回の結果に声がありませんでした。「自動で作る」でもう一度お試しください。"))
                }
            } catch is CancellationError {
                transcriptionTask = nil
                refreshPendingCloudJobs()
            } catch {
                let cancelled = Task.isCancelled
                transcriptionTask = nil
                refreshPendingCloudJobs()
                if !cancelled {
                    presentCloudError(error,
                                      title: String(localized: "前回の結果を取り込めませんでした"),
                                      retryHint: String(localized: "もう一度「取り込む」を押してください。続くときは「破棄」して、自動で作り直してください。"))
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
                    Text("AI翻訳中…")
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
            } else {
                Button {
                    startTranslation()
                } label: {
                    Label(selectedLanguage == .english ? String(localized: "日本語に翻訳") : String(localized: "英語に翻訳"),
                          systemImage: useAITranslation && canUseAITranslation ? "sparkles" : "globe")
                }
                .disabled(project.subtitles.isEmpty || isTranscribing)

                // AI が使えるときだけ。ポイントを使うときは目安を添える
                if canUseAITranslation {
                    Toggle(isOn: $useAITranslation) {
                        if let points = aiTranslationPoints {
                            Text("AIで自然に ・ \(points) pt")
                        } else {
                            Text("AIで自然に")
                        }
                    }
                    .disabled(isTranscribing)
                }
            }
        }
    }

    /// AI 翻訳が使えるか(Apple Intelligence か、ポイント / API キーのクラウド)
    private var canUseAITranslation: Bool {
        aiTranslationEngine != .none
    }

    /// AI 翻訳でポイントを使うときの目安(ポイントを使わないときは nil)
    private var aiTranslationPoints: Int? {
        guard CloudAIGateway.usesPoints, aiTranslationEngine == .cloud, !project.subtitles.isEmpty else { return nil }
        return SubtitlePolisher.estimatedPoints(lineCount: project.subtitles.count)
    }

    /// 「英語に翻訳」/「日本語に翻訳」。「AIで自然に」がオンなら AI、オフなら端末の翻訳
    private func startTranslation() {
        if useAITranslation, canUseAITranslation {
            requestAITranslation()
        } else {
            translationRequest = TranslationRequest(source: selectedLanguage,
                                                    targetIsEnglish: selectedLanguage != .english)
        }
    }

    // MARK: AI 翻訳(SubtitlePolisher)

    /// 「AI翻訳」が使うエンジン。利用者が押して始めるので、「仕上げに使うAI」が「使わない」でも
    /// Apple Intelligence か、ポイント / API キーのクラウドを使う(SubtitlePolisher.resolveExplicitEngine)
    private var aiTranslationEngine: SubtitlePolisher.ResolvedEngine {
        SubtitlePolisher.resolveExplicitEngine(settings: AppSettings.shared)
    }

    /// ポイントで使うときは、使うポイントの目安(SubtitlePolisher.estimatedPoints)を確かめてから始める
    /// (Apple Intelligence で翻訳するときはポイントを使わないので聞かない)
    private func requestAITranslation() {
        guard aiTranslationTask == nil, !project.subtitles.isEmpty else { return }
        if CloudAIGateway.usesPoints, aiTranslationEngine == .cloud {
            aiTranslationEstimate = SubtitlePolisher.estimatedPoints(lineCount: project.subtitles.count)
        } else {
            startAITranslation()
        }
    }

    private func startAITranslation() {
        guard aiTranslationTask == nil, !project.subtitles.isEmpty else { return }
        let cues = project.subtitles
        let language = selectedLanguage
        let toEnglish = (language != .english)
        aiTranslationTask = Task { @MainActor in
            // userInitiated: 利用者が押して始めた翻訳(aiTranslationEngine と同じ resolveExplicitEngine で決める)
            let result = await SubtitlePolisher.translate(cues, from: language, toEnglish: toEnglish,
                                                          settings: AppSettings.shared, userInitiated: true)
            if Task.isCancelled {
                aiTranslationTask = nil
                return
            }
            aiTranslationTask = nil
            guard let result else {
                // 理由(SubtitlePolisher.lastError。文は lastErrorMessage)から、原因に合ったボタンを付ける:
                // ログインの期限切れ・ポイント不足 → アカウントとポイント、API キー → 文字起こしとAI仕上げ、
                // 通信エラーなど → ボタン無し(CloudAIGateway.recovery)。理由が無いときはやり直しの案内だけ
                let title = String(localized: "AI翻訳できませんでした")
                let retryHint = String(localized: "もう一度お試しください。")
                if let error = SubtitlePolisher.lastError {
                    presentCloudError(error, title: title, retryHint: retryHint)
                } else {
                    showAlert(title: title, message: retryHint)
                }
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
            // 表示モードは書き出しにも効くので勝手に切り替えず、ボタンで選べるようにする
            showAlert(title: String(localized: "AI翻訳しました"),
                      message: String(localized: "\(count) 件のキャプションを翻訳しました。"),
                      action: .showBoth)
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
            // 訳文があるときだけ
            if hasAnyTranslation {
                Toggle("訳文を使う", isOn: $exportUseTranslation)
                    .disabled(exportBilingual)
                Toggle("2言語", isOn: $exportBilingual)
            }

            // 押したらファイルを作って、そのまま共有シートを開く
            Button {
                exportSRT()
            } label: {
                Label("キャプションファイルを書き出す", systemImage: "square.and.arrow.up")
            }
            .disabled(project.subtitles.isEmpty)

            Button {
                isImporterPresented = true
            } label: {
                Label("ファイルを読み込む", systemImage: "square.and.arrow.down")
            }
            .disabled(isTranscribing || isTranslating)
        }
    }

    /// SRT を作って共有シートを開く
    private func exportSRT() {
        guard !project.subtitles.isEmpty else { return }
        let useTranslation = hasAnyTranslation && exportUseTranslation
        let bilingual = hasAnyTranslation && exportBilingual
        let text = SRTCodec.encode(project.subtitles,
                                   useTranslation: useTranslation,
                                   bilingual: bilingual)
        let baseName = project.clips.first.map { $0.name } ?? "subtitles"
        let suffix: String
        if bilingual {
            suffix = "_ja_en"
        } else if useTranslation {
            suffix = "_en"
        } else {
            suffix = ""
        }
        let fileName = sanitizedFileName(baseName) + suffix + ".srt"
        do {
            let url = try SRTCodec.writeTemporaryFile(text, fileName: fileName)
            if !presentShareSheet(for: url) {
                showAlert(title: String(localized: "共有シートを開けませんでした"),
                          message: String(localized: "もう一度お試しください。"))
            }
        } catch {
            showAlert(title: String(localized: "ファイルを作れませんでした"),
                      message: String(localized: "空き容量を確かめて、もう一度お試しください。\n\n詳細: ") + error.localizedDescription)
        }
    }

    /// いちばん上に出ている画面(このシート)から共有シートを出す。出せなければ false
    private func presentShareSheet(for url: URL) -> Bool {
        guard var top = ScreenPresentation.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad ではポップオーバーになるので、出す位置が要る
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
        return true
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
                showAlert(title: String(localized: "ファイルを読み込めませんでした"),
                          message: String(localized: "SRT か WebVTT のファイルを選んでください。\n\n詳細: ") + error.localizedDescription)
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
        appliedShift = 0
        let verb = replace ? String(localized: "読み込みました") : String(localized: "追加しました")
        showAlert(title: String(localized: "読み込み完了"), message: String(localized: "\(cues.count) 件のキャプションを") + verb + "。")
    }

    // MARK: デザイン

    /// 見本タイル(流行りの見た目を 1 列で。押したらすぐプレビューに出る)
    private var lookTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CaptionLook.allCases) { look in
                    EditorVisualTile(title: look.title, isSelected: look.matches(project.subtitleStyle)) {
                        var style = project.subtitleStyle
                        look.apply(to: &style)
                        project.subtitleStyle = style
                    } preview: {
                        lookPreview(look)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func lookPreview(_ look: CaptionLook) -> some View {
        if look.template == .plain {
            CaptionLookPreview(color: Color(uiColor: look.color.uiColor),
                               sizeRatio: look.sizeRatio,
                               background: look.hasBackground,
                               position: .bottom)
        } else {
            CaptionTemplatePreview(template: look.template, highlight: highlightColorBinding.wrappedValue)
        }
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

    /// 強調色を使う描き方か
    private var usesHighlightColor: Bool {
        switch project.subtitleStyle.template {
        case .karaoke, .boxPop, .pillHighlight: return true
        case .plain, .outlineBig, .typewriter: return false
        }
    }

    /// 単語ごとに描くテンプレートにしたとき、単語の時刻が無いキャプションへ文字数に応じた時刻を付ける
    private func fillMissingWordTimings(for template: CaptionTemplate) {
        guard template != .plain, template != .outlineBig,
              project.subtitles.contains(where: { $0.words.isEmpty }) else { return }
        project.subtitles = SubtitleWordTiming.fillingMissing(project.subtitles)
    }

    /// 見た目の設定はここだけ: 見本タイル → 細かく調整(位置・文字色・サイズ・背景・フォント・強調色・表示)
    private var designSection: some View {
        Section {
            lookTiles

            DisclosureGroup(isExpanded: $showsStyle) {
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
                        Text("サイズ")
                        Spacer()
                        Text("\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // 編集画面のパネル(EditorPanels.swift)と同じ範囲
                    Slider(value: $project.subtitleStyle.sizeRatio, in: 0.03...0.10)
                }

                Toggle("背景", isOn: $project.subtitleStyle.hasBackground)

                if usesHighlightColor {
                    ColorPicker(String(localized: "強調色"), selection: highlightColorBinding, supportsOpacity: false)
                }

                Picker("フォント", selection: subtitleFontBinding) {
                    ForEach(SubtitleFontCatalog.options(including: project.subtitleStyle.fontName)) { option in
                        SubtitleFontCatalog.label(for: option)
                            .tag(option.id)
                    }
                }
                // 一覧画面で、各フォントの名前をそのフォントで表示する(メニュー形式だとフォントが反映されない)
                .pickerStyle(.navigationLink)

                // Google Fonts から入れる(入れたフォントはそのまま選ばれる)
                Button {
                    showsFontBrowser = true
                } label: {
                    Label("フォントを追加", systemImage: "plus")
                }

                // 原文 / 訳文 / 両方は、訳文があるときだけ
                if hasAnyTranslation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("表示")
                        CaptionDisplayModePicker(selection: $project.subtitleStyle.displayMode)
                    }
                }
            } label: {
                Label("細かく調整", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("デザイン")
        }
    }

    // MARK: 操作列(自動作成 / 翻訳 / ファイル)

    /// 一覧の上に出す操作列。押したツールの設定が、この行のすぐ下に開く
    private var captionToolSection: some View {
        Section {
            HStack(spacing: 8) {
                toolChip(.autoCaption, title: String(localized: "自動作成"), systemImage: "waveform")
                toolChip(.translate, title: String(localized: "翻訳"), systemImage: "globe")
                toolChip(.file, title: String(localized: "ファイル"), systemImage: "doc.text")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .id(SubtitleEditorView.toolRowID)
        }
    }

    private func toolChip(_ tool: CaptionTool, title: String, systemImage: String) -> some View {
        let isSelected = expandedTool == tool
        let isBusy = (tool == .translate && isTranslating) || (tool == .autoCaption && isTranscribing)
        return Button {
            withAnimation {
                expandedTool = isSelected ? nil : tool
            }
        } label: {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill)))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 字幕一覧

    private var cueListSection: some View {
        // 再生中は毎秒何度も描き直すので、要確認の判定はここで 1 回だけ
        let issues = CaptionIssueCheck.issues(in: project.subtitles)
        return Section {
            Button {
                // 空で入れて編集を開く(何も書かずに戻ったら消す)
                let cue = project.addSubtitle(at: player.currentTime, text: "")
                editingCueID = cue.id
            } label: {
                Label(project.subtitles.isEmpty ? String(localized: "自分で 1 件ずつ入力する") : String(localized: "再生位置に追加"), systemImage: "plus.bubble")
            }

            if project.subtitles.isEmpty {
                // キャプションがあるときは操作列の「ファイル」から読み込む
                Button {
                    isImporterPresented = true
                } label: {
                    Label("ファイルを読み込む", systemImage: "square.and.arrow.down")
                }
                .disabled(isTranscribing)
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
                Text("キャプションはまだありません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let highlightedID = currentCueID
                ForEach(project.subtitles) { cue in
                    cueRow(cue, isCurrent: cue.id == highlightedID, issue: issues[cue.id])
                }
                .onDelete { offsets in
                    project.subtitles.remove(atOffsets: offsets)
                }
            }
        } header: {
            HStack {
                Text("一覧 \(project.subtitles.count)")
                let issueCount = issues.count
                if issueCount > 0 {
                    Label {
                        Text(verbatim: "\(issueCount)")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.red)
                        .accessibilityLabel(String(localized: "要確認 \(issueCount) 件"))
                }
                Spacer()
                if !project.subtitles.isEmpty {
                    Menu {
                        Button {
                            appliedShift = 0
                            showsShiftTool = true
                        } label: {
                            Label("タイミングを一括ずらす", systemImage: "arrow.left.and.right")
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
                    .accessibilityLabel("一覧のその他の操作")
                }
            }
        }
    }

    private var appliedShiftText: String {
        let rounded = (appliedShift * 10).rounded() / 10
        if abs(rounded) < 0.05 {
            return String(localized: "±0.1 秒ずつ全キャプションを前後に動かします")
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
    }

    /// この行と次の行を 1 件にする(時刻は前の開始〜後の終了。単語タイミングは両方をつなぐ)
    private func mergeWithNext(cueID: UUID) {
        guard let i = project.subtitles.firstIndex(where: { $0.id == cueID }),
              i + 1 < project.subtitles.count else { return }
        let a = project.subtitles[i]
        let b = project.subtitles[i + 1]
        var merged = a
        merged.end = max(a.end, b.end)
        merged.text = SubtitleEditorView.joined(a.text, b.text)
        let translatedA = a.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let translatedB = b.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        merged.translatedText = (translatedA.isEmpty && translatedB.isEmpty) ? nil : SubtitleEditorView.joined(translatedA, translatedB)
        merged.bilingual = a.bilingual || b.bilingual
        merged.doubtfulWords = a.doubtfulWords + b.doubtfulWords
        merged.issueDismissed = a.issueDismissed && b.issueDismissed
        if a.words.isEmpty && b.words.isEmpty {
            merged.words = []
        } else if !a.words.isEmpty && !b.words.isEmpty {
            merged.words = a.words + b.words
        } else {
            merged.words = SubtitleWordTiming.distribute(cue: merged)
        }
        project.subtitles[i] = merged
        project.subtitles.remove(at: i + 1)
    }

    /// 2 つの文をつなぐ(英数字の境目だけ空白を入れる)
    private static func joined(_ lhs: String, _ rhs: String) -> String {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let needsSpace = (a.last?.isASCII ?? false) || (b.first?.isASCII ?? false)
        return needsSpace ? a + " " + b : a + b
    }

    /// issue: 要確認の理由(赤い背景と「!」。CaptionIssues.swift)
    private func cueRow(_ cue: SubtitleCue, isCurrent: Bool, issue: CaptionIssue?) -> some View {
        HStack(spacing: 8) {
            if issue != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .accessibilityLabel("要確認")
            }
            Button {
                player.seek(to: cue.start)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(subtitleTimeString(cue.start)) – \(subtitleTimeString(cue.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    if let issue {
                        Text(issue.message)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Text(cue.text.isEmpty ? String(localized: "テキストなし") : cue.text)
                        .foregroundStyle(cue.text.isEmpty ? Color.secondary : Color.primary)
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
        .listRowBackground(issue != nil
                           ? Color.red.opacity(isCurrent ? 0.32 : 0.22)
                           : (isCurrent ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground)))
        // 確認して問題なければ、左にスワイプして印を消す
        .swipeActions(edge: .leading) {
            if issue != nil {
                Button {
                    if let index = project.subtitles.firstIndex(where: { $0.id == cue.id }) {
                        project.subtitles[index].issueDismissed = true
                    }
                } label: {
                    Label("問題なし", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
        // 独自のスワイプを付けると onDelete の削除が出なくなることがあるので、削除も並べておく
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                project.subtitles.removeAll { $0.id == cue.id }
            } label: {
                Label("削除", systemImage: "trash")
            }
            if project.subtitles.last?.id != cue.id {
                Button {
                    mergeWithNext(cueID: cue.id)
                } label: {
                    Label("次と結合", systemImage: "arrow.triangle.merge")
                }
                .tint(.blue)
            }
        }
    }

    private func showAlert(title: String, message: String, action: AlertAction? = nil) {
        alertTitle = title
        alertAction = action
        alertMessage = message
    }
}

// MARK: - 字幕1件の編集画面

struct SubtitleCueEditView: View {
    let project: EditorProject
    let player: PlayerController
    let cueID: UUID

    @Environment(\.dismiss) private var dismiss

    /// テキストの文字カーソル(「ここで分割」の位置)
    @State private var textSelection: TextSelection?
    /// 直前の文字カーソル(ボタンを押すとフォーカスが外れて選択が消えることがあるため取っておく)
    @State private var lastSelection: TextSelection?

    private let minimumLength: Double = 0.2

    var body: some View {
        Group {
            if let binding = project.subtitleBinding(id: cueID) {
                editor(binding)
            } else {
                Text("このキャプションは削除されました。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("キャプションを編集")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editor(_ cue: Binding<SubtitleCue>) -> some View {
        Form {
            Section {
                TextField("テキストを入力", text: cue.text, selection: $textSelection, axis: .vertical)
                    .lineLimit(1...6)
                    .onChange(of: textSelection) { _, selection in
                        if let selection { lastSelection = selection }
                    }
                Button {
                    splitCue(cue)
                } label: {
                    Label("ここで分割", systemImage: "scissors")
                }
                .disabled(cue.wrappedValue.duration < minimumLength * 2 || cue.wrappedValue.text.count < 2)
            } header: {
                Text("テキスト")
            } footer: {
                Text("分割は文字カーソルの位置で切ります。カーソルが無ければ再生位置です。")
            }

            Section {
                TextField("訳文", text: Binding(
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
                    Button("ここを再生") {
                        player.seek(to: cue.wrappedValue.start)
                        player.play()
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
                    Button("ここを再生") {
                        // 終わりの少し前から流して、切れ目を耳で確かめる
                        player.seek(to: max(cue.wrappedValue.start, cue.wrappedValue.end - 1))
                        player.play()
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
                    Label("このキャプションを削除", systemImage: "trash")
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

    // MARK: 分割

    /// 文字カーソルの位置(無ければ再生位置、それも範囲外なら真ん中)で 2 件に分ける。
    /// 前半は同じ id のまま(この画面で続けて直せる)、後半は新しいキャプションとして直後に入れる。
    /// 時刻は、再生位置で切ったときはその時刻、文字カーソルのときは文字数の割合
    private func splitCue(_ cue: Binding<SubtitleCue>) {
        let c = cue.wrappedValue
        let chars = Array(c.text)
        guard c.duration >= minimumLength * 2, chars.count >= 2 else { return }

        let splitIndex: Int
        var splitTime: Double?
        if let cursor = cursorOffset(in: c.text), cursor > 0, cursor < chars.count {
            splitIndex = cursor
        } else {
            let t = player.currentTime
            let fraction: Double
            if t > c.start + minimumLength, t < c.end - minimumLength {
                fraction = (t - c.start) / c.duration
                splitTime = t
            } else {
                fraction = 0.5
            }
            splitIndex = nearestBreak(in: chars, around: Int((fraction * Double(chars.count)).rounded()))
        }

        let first = String(chars[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(chars[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return }

        let weight = Double(first.count) / Double(first.count + second.count)
        var boundary = splitTime ?? (c.start + c.duration * weight)
        boundary = min(max(boundary, c.start + minimumLength), c.end - minimumLength)

        var head = c
        head.text = first
        head.end = boundary
        // 訳文は 2 つに分けられないので前半に残す(後半は空)
        var tail = SubtitleCue(start: boundary, end: c.end, text: second)
        tail.bilingual = c.bilingual
        if !c.words.isEmpty {
            head.words = SubtitleWordTiming.distribute(text: first, start: head.start, end: head.end)
            tail.words = SubtitleWordTiming.distribute(text: second, start: tail.start, end: tail.end)
        }

        guard let i = project.subtitles.firstIndex(where: { $0.id == cueID }) else { return }
        project.subtitles[i] = head
        project.subtitles.insert(tail, at: i + 1)
        project.sortSubtitles()
        lastSelection = nil
    }

    /// 文字カーソルの位置(先頭からの文字数)。選択範囲があればその先頭。文の先頭・末尾や、文が変わって合わなくなっていれば nil
    private func cursorOffset(in text: String) -> Int? {
        guard let selection = lastSelection, case .selection(let range) = selection.indices else { return nil }
        let index = range.lowerBound
        guard index > text.startIndex, index < text.endIndex else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }

    /// k の近く(±4 文字)に空白や句読点の直後があればそこで切る。無ければ k
    private func nearestBreak(in chars: [Character], around k: Int) -> Int {
        let count = chars.count
        let center = min(max(k, 1), count - 1)
        var best = center
        var bestDistance = Int.max
        for j in max(1, center - 4)...min(count - 1, center + 4) {
            let before = chars[j - 1]
            if before.isWhitespace || before.isPunctuation, abs(j - center) < bestDistance {
                best = j
                bestDistance = abs(j - center)
            }
        }
        return best
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
        Option(id: "", label: String(localized: "ヒラギノ角ゴ W3")),
        Option(id: "HiraginoSans-W6", label: String(localized: "ヒラギノ角ゴ W6")),
        Option(id: "HiraMinProN-W3", label: String(localized: "ヒラギノ明朝 W3")),
        Option(id: "HiraMinProN-W6", label: String(localized: "ヒラギノ明朝 W6")),
        Option(id: "HiraMaruProN-W4", label: String(localized: "ヒラギノ丸ゴ W4")),
        Option(id: "Noteworthy-Bold", label: "Noteworthy"),
        Option(id: "BradleyHandITCTT-Bold", label: "Bradley Hand"),
        Option(id: "Chalkduster", label: "Chalkduster"),
        Option(id: "MarkerFelt-Wide", label: "Marker Felt"),
        Option(id: "AvenirNext-Bold", label: "Avenir Next Bold"),
        Option(id: "Futura-Bold", label: "Futura Bold")
    ]

    /// 組み込み + 「ファイル」から読み込んだフォント(MediaTools)+ 現在選ばれている名前(一覧に無ければ追加)
    static func options(including current: String?) -> [Option] {
        BundledFonts.registerAll()
        var result = builtIn + BundledFonts.all.map { Option(id: $0.name, label: $0.label) }
        var known = Set(result.map { $0.id })
        for name in MediaTools.storedFontNames() where !known.contains(name) {
            result.append(Option(id: name, label: GoogleFontsService.displayName(forPostScript: name) ?? name))
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

/// 自動字幕を作る範囲
enum CaptionScope: Hashable {
    /// プロジェクト全体
    case all
    /// 選んだクリップだけ
    case clip
}
