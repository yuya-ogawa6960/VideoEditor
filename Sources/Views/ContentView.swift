import SwiftUI
import UIKit
import PhotosUI
import Photos
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// メイン画面(CapCut 風:上部バー/プレビュー/再生操作/タイムライン/下部ツールバー)
struct ContentView: View {
    /// 編集するプロジェクト(ProjectLibrary の ID)。保存先はこの ID のフォルダ
    let projectID: UUID
    /// 一覧へ戻るときに呼ぶ(保存を終えてから呼ばれる)
    let onClose: () -> Void

    @State private var project = EditorProject()
    @State private var didRestore = false
    /// 開いた直後に復元した内容。復元による最初の変化は保存しない(保存済みの内容と同じ)
    @State private var restoredSnapshot: ProjectSnapshot?
    /// 開いてから 1 回でも編集したか(一覧の更新日時を動かすかどうか)
    @State private var isDirty = false
    @State private var player = PlayerController()
    @State private var history = EditorHistory()
    @State private var timeline = TimelineState()
    @State private var selection: EditorSelection?
    /// 上部バーからプロジェクト名を変更する
    @State private var isRenamingProject = false
    @State private var projectNameDraft = ""
    /// 「その他」→「動画の置き場所」
    @State private var isChoosingMediaMode = false
    /// 🔍 機能を探す
    @State private var isSearchingTools = false
    /// 中だるみチェックをしたときのクリップの並び
    @State private var pacingClipsKey = ""
    /// 写真ライブラリの動画を読み直している途中(この間は保存しない。空の内容で上書きしないため)
    @State private var isLoadingPhotoMedia = false

    @State private var activePanel: EditorPanel?
    @State private var activeSheet: EditorSheet?

    @State private var pickerItems: [PhotosPickerItem] = []
    /// 「オーバーレイ」で選んだ動画・写真
    @State private var overlayPickerItems: [PhotosPickerItem] = []
    /// 「置き換え」で選んだ動画
    @State private var replacePickerItem: PhotosPickerItem?
    /// 「音声抽出」で選んだ動画
    @State private var extractAudioPickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importDone = 0
    @State private var importTotal = 0
    /// 読み込み中の 1 件の進み具合(iCloud からのダウンロードなど。nil ならわからない)
    @State private var importFraction: Double?
    /// 「ファイル」アプリの項目(Google ドライブなど)をダウンロード・コピーしている途中(進み具合はわからない)
    @State private var importIsDownloading = false
    /// 読み込みの処理(「キャンセル」で止める)
    @State private var importTask: Task<Void, Never>?
    /// 「写真ライブラリから参照」なのに参照できず、アプリに取り込んだ動画があった(読み込みのたびに戻す)
    @State private var importCopiedPhotoMedia = false

    @State private var alertMessage: String?
    /// お知らせに「設定を開く」を出す(写真へのアクセスが許可されていないときなど)
    @State private var alertOffersSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showClearProjectConfirm = false
    @State private var showSilenceCutConfirm = false
    @State private var showPunchInDialog = false
    @State private var showNormalizeConfirm = false
    /// 無音カット・音量そろえの進捗(nil なら実行中でない)
    @State private var audioToolProgress: AudioToolProgress?
    @State private var audioToolTask: Task<Void, Never>?
    /// 逆再生の作成・フリーズフレーム・音声抽出の進捗(nil なら実行中でない)
    @State private var mediaToolProgress: ClipFXProgress?
    @State private var mediaToolTask: Task<Void, Never>?
    @State private var isKeyboardVisible = false

    /// 手書き(新規作成中)の下書き
    @State private var draftStrokes: [DrawingStroke] = []
    @State private var drawingColorHex = "#FF4D4D"
    @State private var drawingWidth: Double = 0.012

    /// 第4弾: 長い解析(リフレーム・手ぶれ・トラッキング・テンプレート)の進捗とキャンセル
    @State private var analysis = EditorAnalysisRunner()
    /// 第4弾: トラッキング(プレビューで囲んだ四角 → キーフレーム)の状態
    @State private var tracking = EditorTrackingController()
    /// 「スライドショー」で選んだ写真
    @State private var slideshowPickerItems: [PhotosPickerItem] = []
    /// スライドショー用に読み込んだ写真(アプリ内コピー)
    @State private var slideshowImages: [URL] = []

    /// 1.5: 画面を止めない短いお知らせ(2 秒で消える)
    @State private var toast: EditorToast?
    /// 1.5: ツールバーで開いているグループ(選択が変わると閉じる)
    @State private var toolbarGroupPath: [String] = []
    /// 1.5: パネルを開いたときの状態(✕「キャンセル」で戻す)
    @State private var panelSnapshot: ProjectSnapshot?
    /// 1.5: タイムラインの「+」から開く PhotosPicker
    @State private var showMediaPicker = false
    /// タイムライン末尾の「+」から追加したときは末尾に足す(それ以外は再生位置のクリップの後ろに差し込む)
    @State private var importAppendsAtEnd = false
    /// 「動画・写真を追加」で、どこから追加するか(写真ライブラリ / ファイル / Google フォト)を選ぶ
    @State private var showMediaSourceDialog = false
    /// 「ファイル」アプリ(Google ドライブ・iCloud Drive など)から選ぶ
    @State private var showFileImporter = false
    /// 共有で受け取った動画・写真を「このプロジェクトに追加」するか聞く
    @State private var showIncomingPrompt = false
    @State private var incomingPromptCount = 0
    /// 「あとで」を選んだときに受け取っていた素材(同じ内容のままならもう聞かない)
    @State private var postponedIncomingURLs: [URL] = []
    /// 共有で受け取った素材の確認を少し待ってから行う処理(シートなどが閉じてから聞く)
    @State private var incomingCheckTask: Task<Void, Never>?
    @State private var incomingCheckAttempts = 0
    @State private var showOverlayPicker = false
    /// 「オーバーレイ」を押したときの「動画だけ / 写真だけ / 両方」の選択
    @State private var showOverlayKindDialog = false
    @State private var overlayPickerFilter: PHPickerFilter = .any(of: [.videos, .images])
    /// 1.5: 「聞きやすくする」(ナレーション 1 件の音量そろえ)の確認対象
    @State private var normalizeNarrationTarget: UUID?

    init(projectID: UUID, onClose: @escaping () -> Void) {
        self.projectID = projectID
        self.onClose = onClose
    }

    enum EditorSheet: Identifiable, Hashable {
        case clipDetail(UUID)
        case multicam(UUID)
        case subtitles
        case audio
        case export
        /// スコープ(ヒストグラム・波形)
        case scopes(UUID)
        /// サムネ(カバー画像)作成
        case coverMaker
        /// 前回の書き出しと比較
        case compare
        /// おまかせ編集(第4弾)
        case autoEdit
        /// 写真からスライドショー(第4弾。写真は slideshowImages)
        case slideshow
        /// AI 台本(第4弾)
        case scriptWriter
        /// Google フォトから選んで取り込む(GooglePhotosImportView)
        case googlePhotos

        var id: String {
            switch self {
            case .clipDetail(let clipID): return "detail-\(clipID.uuidString)"
            case .multicam(let clipID): return "multicam-\(clipID.uuidString)"
            case .subtitles: return "subtitles"
            case .audio: return "audio"
            case .export: return "export"
            case .scopes(let clipID): return "scopes-\(clipID.uuidString)"
            case .coverMaker: return "cover"
            case .compare: return "compare"
            case .autoEdit: return "autoEdit"
            case .slideshow: return "slideshow"
            case .scriptWriter: return "scriptWriter"
            case .googlePhotos: return "googlePhotos"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            mainColumn

            if isImporting {
                importOverlay
            }

            if let progress = audioToolProgress {
                AudioToolProgressOverlay(progress: progress) {
                    audioToolTask?.cancel()
                }
            }

            if let progress = mediaToolProgress {
                ClipFXProgressOverlay(progress: progress) {
                    mediaToolTask?.cancel()
                }
            }

            if let progress = analysis.progress {
                ClipFXProgressOverlay(progress: progress) {
                    analysis.cancel()
                }
            }

            if let current = toast {
                toastLayer(current)
            }
        }
        .preferredColorScheme(.dark)
        .photosPicker(isPresented: $showMediaPicker,
                      selection: $pickerItems,
                      maxSelectionCount: nil,
                      selectionBehavior: .ordered,
                      matching: .any(of: [.videos, .images]),
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            pickerItems = []
            importTask = Task { await importItems(items) }
        }
        .onChange(of: slideshowPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            slideshowPickerItems = []
            importTask = Task { await importSlideshowItems(items) }
        }
        .onChange(of: overlayPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            overlayPickerItems = []
            importTask = Task { await importOverlayItems(items) }
        }
        .onChange(of: replacePickerItem) { _, newItem in
            guard let item = newItem else { return }
            replacePickerItem = nil
            guard let clipID = selection?.clipID else { return }
            importTask = Task { await replaceClip(clipID, with: item) }
        }
        .onChange(of: extractAudioPickerItem) { _, newItem in
            guard let item = newItem else { return }
            extractAudioPickerItem = nil
            // 進捗表示の「キャンセル」で止められるように mediaToolTask に入れる
            mediaToolTask?.cancel()
            mediaToolTask = Task { @MainActor in
                await extractAudio(from: item)
                mediaToolTask = nil
            }
        }
        .onChange(of: project.snapshot()) { _, newSnapshot in
            player.update(with: newSnapshot)
            if let restored = restoredSnapshot {
                // 開いた直後の復元による変化は保存しない(内容は保存済みのものと同じ)
                restoredSnapshot = nil
                if restored == newSnapshot { return }
            }
            persist(newSnapshot)
        }
        .onChange(of: selectionExists) { _, exists in
            if !exists {
                selection = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            toolbarGroupPath = []
            if let panel = activePanel, !panel.isCompatible(with: newValue) {
                activePanel = nil
            }
        }
        .onChange(of: activePanel) { oldValue, newValue in
            if newValue == nil {
                panelSnapshot = nil
            } else if oldValue == nil && panelSnapshot == nil {
                // 開く直前の状態を明示しなかった場合は、開いた時点の状態に戻す
                panelSnapshot = project.snapshot()
            }
        }
        .onChange(of: project.isEmpty) { _, isEmpty in
            if isEmpty {
                activePanel = nil
                selection = nil
                toolbarGroupPath = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onAppear {
            handleAppear()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .onChange(of: activeSheet) { _, sheet in
            if let sheet { Analytics.shared.track("sheet", ["name": Self.analyticsName(of: sheet)]) }
        }
        .confirmationDialog("このプロジェクトを空にしますか?",
                            isPresented: $showClearProjectConfirm,
                            titleVisibility: .visible) {
            Button("編集中の内容をすべて削除", role: .destructive) {
                clearProject()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このプロジェクトのクリップ・字幕・BGM・オーバーレイ・ナレーション・テキスト・手書き・マーカーはすべて消え、元に戻せません。プロジェクト自体は一覧に残ります。")
        }
        .alert("お知らせ", isPresented: alertIsPresented) {
            if alertOffersSettings {
                Button("設定を開く") {
                    openSystemSettings()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - 上部バー + 空の画面 / 編集画面

    /// 上部バーと、空の画面 / 編集画面。
    /// 「動画・写真を追加」の取り込み元の選択と、共有で受け取った素材の確認もここに付ける
    /// (body の型チェックを軽くするため、またほかのシート・お知らせと別の View に付けるため分けている)
    private var mainColumn: some View {
        VStack(spacing: 0) {
            topBarWithDialogs
            ExportProgressBanner()
            if project.isEmpty {
                emptyState
            } else {
                editor
            }
        }
        .confirmationDialog("どこから追加しますか?",
                            isPresented: $showMediaSourceDialog,
                            titleVisibility: .visible) {
            Button("写真ライブラリ") {
                showMediaPicker = true
            }
            Button("ファイル(Google ドライブなど)") {
                showFileImporter = true
            }
            if GoogleOAuth.isConfigured {
                Button("Google フォト") {
                    player.pause()
                    activeSheet = .googlePhotos
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if AppGroup.isAvailable {
                Text("ほかのアプリの「共有」から Video Mania を選んで送ることもできます。")
            }
        }
        // 「ファイル」から選ぶ画面は、下のパネル(LUT・フォントの読み込み)の .fileImporter と入れ子にならないよう、
        // 本体とは別の枝(背景)に付ける
        .background {
            Color.clear
                .fileImporter(isPresented: $showFileImporter,
                              allowedContentTypes: [.movie, .image],
                              allowsMultipleSelection: true) { result in
                    handleFileImport(result)
                }
        }
        .alert("共有で受け取った動画・写真が \(incomingPromptCount)件あります", isPresented: $showIncomingPrompt) {
            Button("このプロジェクトに追加") {
                importIncomingMedia()
            }
            Button("あとで", role: .cancel) {
                postponedIncomingURLs = IncomingMediaCenter.shared.pendingURLs
            }
        } message: {
            Text("再生位置のクリップの後ろに追加します。")
        }
        // アプリに戻ってきたら、共有で受け取った動画・写真がないか見る
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            IncomingMediaCenter.shared.refresh()
            scheduleIncomingCheck()
        }
        .onChange(of: IncomingMediaCenter.shared.pendingURLs) { _, _ in
            checkIncomingMedia()
        }
        // 読み込み・復元・シート・お知らせが終わったら、待たせていた確認を出す
        .onChange(of: isImporting) { _, busy in
            if !busy { scheduleIncomingCheck() }
        }
        .onChange(of: isLoadingPhotoMedia) { _, loading in
            if !loading { scheduleIncomingCheck() }
        }
        .onChange(of: activeSheet) { _, sheet in
            if sheet == nil { scheduleIncomingCheck() }
        }
        .onChange(of: alertMessage) { _, message in
            if message == nil { scheduleIncomingCheck() }
        }
        // 下のパネルを閉じた・画面内の処理(無音カット・逆再生・解析など)が終わったときも、待たせていた確認を出す
        // (どれかが残っている間は確認しないので、全部なくなったときに呼び直す)
        .onChange(of: isPanelOrToolBusy) { _, busy in
            if !busy { scheduleIncomingCheck() }
        }
        .onDisappear {
            incomingCheckTask?.cancel()
            incomingCheckTask = nil
            // 取り込まずに閉じたときは、次に開いたときに聞かずに取り込まないよう忘れる
            if IncomingMediaCenter.shared.autoImportProjectID == projectID {
                IncomingMediaCenter.shared.autoImportProjectID = nil
            }
        }
    }

    // MARK: - トースト

    private func toastLayer(_ current: EditorToast) -> some View {
        VStack {
            Spacer(minLength: 0)
            EditorToastView(toast: current) {
                undoFromToast()
            }
            .padding(.bottom, 84)
            // 雲のようにふわっと現れ、消えるときは真ん中にスッと吸い込まれる(動きを減らす設定では薄く出入りするだけ)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.toastCloud)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: current.id) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            if toast?.id == current.id {
                withAnimation(EditorToastView.hideAnimation) {
                    toast = nil
                }
            }
        }
    }

    /// 短いお知らせを出す(成功・注意は触覚つき)。undo が true なら「元に戻す」ボタンを出す
    private func showToast(_ message: String, style: EditorToast.Style = .success, undo: Bool = false) {
        switch style {
        case .success: EditorHaptics.success()
        case .warning: EditorHaptics.warning()
        case .info: break
        }
        withAnimation(EditorToastView.showAnimation) {
            toast = EditorToast(message, style: style, canUndo: undo)
        }
    }

    private func undoFromToast() {
        withAnimation(EditorToastView.hideAnimation) {
            toast = nil
        }
        activePanel = nil
        history.undo(project)
    }

    // MARK: - 上部バー

    /// 一覧に表示されているこのプロジェクトの名前
    private var projectName: String {
        let name: String = ProjectLibrary.shared.projects.first(where: { $0.id == projectID })?.name ?? ""
        return name.isEmpty ? String(localized: "無題") : name
    }

    /// 上部バーと、そこから開くダイアログ(body の型チェックを軽くするため分けている)
    private var topBarWithDialogs: some View {
        topBar
            .alert("名前を変更", isPresented: $isRenamingProject) {
                TextField("プロジェクト名", text: $projectNameDraft)
                Button("キャンセル", role: .cancel) {}
                Button("保存") {
                    ProjectLibrary.shared.rename(id: projectID, to: projectNameDraft)
                }
            } message: {
                Text("新しいプロジェクト名を入力してください。")
            }
            .sheet(isPresented: $isSearchingTools) {
                toolSearchSheet
            }
            .confirmationDialog("動画の置き場所(いま: \(mediaMode.displayName))",
                                isPresented: $isChoosingMediaMode, titleVisibility: .visible) {
                Button("写真ライブラリから参照(容量を使わない)") {
                    ProjectLibrary.shared.setMediaMode(id: projectID, to: .photoLibrary)
                    showToast(String(localized: "これから追加する動画は写真ライブラリから参照します"))
                }
                Button("アプリに取り込む(写真を消しても安心)") {
                    ProjectLibrary.shared.setMediaMode(id: projectID, to: .appCopy)
                    showToast(String(localized: "これから追加する動画はアプリに取り込みます"))
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("これから追加する動画に使われます。追加済みの動画はそのままです。\n「写真ライブラリから参照」では、写真アプリで動画を消すとこのプロジェクトでも使えなくなります。スローモーションの動画はアプリに取り込みます。")
            }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                EditorHaptics.tap()
                closeProject()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("一覧")
                        .font(.system(size: 15))
                }
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("プロジェクト一覧へ戻る")
            // 上部バーは高さが決まっているので、大きな文字の設定では長押しで拡大して見せる
            .accessibilityShowsLargeContentViewer {
                Label("一覧", systemImage: "chevron.left")
            }

            Button {
                EditorHaptics.tap()
                projectNameDraft = projectName
                isRenamingProject = true
            } label: {
                HStack(spacing: 4) {
                    Text(projectName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 130, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("プロジェクト名「\(projectName)」を変更")

            Spacer()

            Button {
                EditorHaptics.tap()
                activePanel = nil
                history.undo(project)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(history.canUndo ? 1 : 0.3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!history.canUndo)
            .accessibilityLabel("元に戻す")

            Button {
                EditorHaptics.tap()
                activePanel = nil
                history.redo(project)
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(history.canRedo ? 1 : 0.3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!history.canRedo)
            .accessibilityLabel("やり直す")

            Button {
                EditorHaptics.tap()
                player.pause()
                isSearchingTools = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("機能を探す")

            Spacer()

            Button {
                EditorHaptics.tap()
                player.pause()
                activePanel = nil
                activeSheet = .export
            } label: {
                Text("書き出し")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(FacetedBrandBackground())
                    .opacity(project.isEmpty ? 0.4 : 1)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(project.isEmpty)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    // MARK: - 空の状態

    private var emptyState: some View {
        VStack(spacing: 24) {
            // フィルムを抱えて運ぶ係のロボット(AIWorkingOverlay.swift)
            FloatingRobot(name: "robot_hero_film", height: 160)
            Text("動画や写真を追加して編集を始めましょう")
                .foregroundStyle(.secondary)
            Button {
                EditorHaptics.tap()
                requestMediaAdd(appendAtEnd: false)
            } label: {
                Label("動画・写真を追加", systemImage: "plus.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(FacetedBrandBackground())
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 編集画面

    private var isDrawingNew: Bool { activePanel == .drawingCanvas }

    /// マスクのパネルを開いている間は、プレビュー上でマスクの中心・大きさ・角度を操作できる
    private var previewMaskTarget: PreviewMaskTarget? {
        switch activePanel {
        case .mask(let clipID): return .clip(clipID)
        case .overlayMask(let overlayID): return .overlay(overlayID)
        default: return nil
        }
    }

    /// トラッキングのパネルを開いている間は、プレビュー上で対象を囲む四角を描ける
    private var previewRectSelection: PreviewRectSelection? {
        let target: EditorTrackingTarget
        switch activePanel {
        case .textTracking(let textID): target = .text(textID)
        case .overlayTracking(let overlayID): target = .overlay(overlayID)
        default: return nil
        }
        let project = self.project
        let player = self.player
        let history = self.history
        let analysis = self.analysis
        let tracking = self.tracking
        return PreviewRectSelection { rect in
            tracking.track(rect: rect, target: target, project: project, player: player,
                           history: history, analysis: analysis)
        }
    }

    private var previewArea: some View {
        PreviewView(player: player)
            .overlay {
                // 映像の表示領域(アスペクトフィット後)にぴったり重なる
                if isDrawingNew {
                    DrawingCanvasView(strokes: $draftStrokes,
                                      colorHex: drawingColorHex,
                                      width: drawingWidth)
                } else {
                    PreviewGestureOverlay(project: project,
                                          history: history,
                                          selection: selection,
                                          maskTarget: previewMaskTarget,
                                          rectSelection: previewRectSelection,
                                          player: player,
                                          onSelect: { newSelection in selection = newSelection })
                }
            }
    }

    private var editor: some View {
        GeometryReader { geo in
            let panelOpen: Bool = activePanel != nil
            let fullHeight: CGFloat = geo.size.height
            let previewMax: CGFloat = panelOpen ? fullHeight : max(100, fullHeight * 0.45)
            let panelMax: CGFloat = max(160, fullHeight * 0.38)

            VStack(spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: previewMax)
                    .background(Color.black)
                    // プレビューのタップは PreviewGestureOverlay が選択に使う(再生・一時停止は下の再生ボタン)
                    .layoutPriority(1)

                if !isKeyboardVisible {
                    if panelOpen {
                        // パネルを開いている間はタイムラインの代わりに細いシークバーを出す(プレビューを広く保つ)
                        EditorScrubBar(player: player)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                    } else {
                        EditorTransportRow(player: player)
                            .padding(.horizontal, 16)
                            .frame(height: 44)

                        TimelineView(project: project, player: player, history: history,
                                     timeline: timeline, selection: $selection,
                                     onAdd: { kind in handleTimelineAdd(kind) })
                            .frame(height: TimelineView.preferredHeight(for: project))
                    }
                }

                if !panelOpen {
                    Spacer(minLength: 0)
                }

                bottomArea(maxPanelHeight: panelMax)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .photosPicker(isPresented: $showOverlayPicker,
                      selection: $overlayPickerItems,
                      maxSelectionCount: nil,
                      selectionBehavior: .ordered,
                      matching: overlayPickerFilter,
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .confirmationDialog("オーバーレイに追加するもの",
                            isPresented: $showOverlayKindDialog,
                            titleVisibility: .visible) {
            Button("動画だけ") { openOverlayPicker(.videos) }
            Button("写真だけ") { openOverlayPicker(.images) }
            Button("動画と写真") { openOverlayPicker(.any(of: [.videos, .images])) }
            Button("キャンセル", role: .cancel) {}
        }
    }

    /// 「オーバーレイ」ボタン・タイムラインの「+」から。種類を選んでから写真ライブラリを開く
    private func requestOverlayAdd() {
        guard !isImporting else { return }
        showOverlayKindDialog = true
    }

    private func openOverlayPicker(_ filter: PHPickerFilter) {
        overlayPickerFilter = filter
        showOverlayPicker = true
    }

    /// 「動画・写真を追加」(下のツールバー・空の画面・タイムラインの「+」)。
    /// どこから追加するか(写真ライブラリ / ファイル / Google フォト)を選んでもらう。
    /// appendAtEnd: タイムライン末尾の「+」からのときは末尾に足す(それ以外は再生位置のクリップの後ろ)
    private func requestMediaAdd(appendAtEnd: Bool) {
        guard !isImporting else { return }
        importAppendsAtEnd = appendAtEnd
        showMediaSourceDialog = true
    }

    /// タイムラインの「+」(空のトラックをまとめた行・最後のクリップの後ろ)から追加する
    private func handleTimelineAdd(_ kind: TimelineAddKind) {
        EditorHaptics.tap()
        switch kind {
        case .media:
            requestMediaAdd(appendAtEnd: true)
        case .text:
            addTextAtPlayhead()
        case .subtitle:
            player.pause()
            activePanel = nil
            history.record(project)
            activeSheet = .subtitles
        case .overlay:
            requestOverlayAdd()
        case .bgm:
            player.pause()
            activePanel = nil
            history.record(project)
            activeSheet = .audio
        case .narration:
            selection = nil
            openPanel(.narrationRecord)
        }
    }

    // MARK: - 下部(ツールバー or パネル)

    private func bottomArea(maxPanelHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let panel = activePanel {
                let cancelAction: (() -> Void)? = panel.supportsCancel ? { cancelPanel(panel) } : nil
                let panelHeight: CGFloat = min(panel.height, maxPanelHeight)
                EditorPanelContainer(title: panelTitle(panel),
                                     height: panelHeight,
                                     onCancel: cancelAction,
                                     onClose: { closePanel(panel) }) {
                    panelContent(panel)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                EditorToolbar(items: toolbarItems,
                              onBack: backAction,
                              onDisabledTap: { reason in showToast(reason, style: .warning) },
                              groupPath: $toolbarGroupPath,
                              pickerItems: $pickerItems,
                              overlayPickerItems: $overlayPickerItems,
                              replacePickerItem: $replacePickerItem,
                              extractAudioPickerItem: $extractAudioPickerItem,
                              slideshowPickerItems: $slideshowPickerItems)
                    .overlay(alignment: .topLeading) {
                        EditorModeBadge(title: toolbarModeTitle)
                            .padding(.leading, 12)
                            .offset(y: -22)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: activePanel)
        .confirmationDialog("オートパンチイン(話の区切りでズームを切り替えます)",
                            isPresented: $showPunchInDialog,
                            titleVisibility: .visible) {
            Button("1.15 倍・話の区切りごと(おすすめ)") { applyPunchIn(zoom: 1.15, interval: nil) }
            Button("1.25 倍・話の区切りごと") { applyPunchIn(zoom: 1.25, interval: nil) }
            Button("1.15 倍・4 秒ごと") { applyPunchIn(zoom: 1.15, interval: 4) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択中のクリップがあればそのクリップだけ、なければ全クリップに入れます。「元に戻す」で戻せます。")
        }
        .confirmationDialog("無音部分を自動で詰めます(全クリップ)",
                            isPresented: $showSilenceCutConfirm,
                            titleVisibility: .visible) {
            Button("無音カットを実行") {
                startSilenceCut()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("音声のあるクリップごとに 0.6 秒以上の無音を検出し、その部分を取り除いてクリップを分割します。「元に戻す」で戻せます。")
        }
        .confirmationDialog("全クリップとナレーションの音量をそろえます",
                            isPresented: $showNormalizeConfirm,
                            titleVisibility: .visible) {
            Button("音量そろえを実行") {
                startNormalize(clipIDs: project.clips.map { $0.id },
                               narrationIDs: project.narration.map { $0.id })
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("各クリップとナレーションの音の大きさを測り、聞きやすい大きさにそろえます。「元に戻す」で戻せます。")
        }
        .confirmationDialog("このナレーションを聞きやすくします",
                            isPresented: normalizeNarrationConfirmIsPresented,
                            titleVisibility: .visible) {
            Button("聞きやすくする") {
                if let narrationID = normalizeNarrationTarget {
                    startNormalize(clipIDs: [], narrationIDs: [narrationID])
                }
                normalizeNarrationTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                normalizeNarrationTarget = nil
            }
        } message: {
            Text("ナレーションの音の大きさを測り、聞きやすい大きさにそろえます。「元に戻す」で戻せます。")
        }
    }

    private var normalizeNarrationConfirmIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { normalizeNarrationTarget != nil },
            set: { newValue in
                if !newValue { normalizeNarrationTarget = nil }
            }
        )
    }

    /// 選択中なら「‹」で選択解除
    private var backAction: (() -> Void)? {
        guard selection != nil else { return nil }
        return { selection = nil }
    }

    /// パネルのタイトル。対象があれば「速度 – クリップ2」のように付ける
    private func panelTitle(_ panel: EditorPanel) -> String {
        guard let target = panel.targetSelection, let name = targetName(for: target) else {
            return panel.title
        }
        return panel.title + " – " + name
    }

    /// 選択対象の短い名前(パネルのタイトル用)
    private func targetName(for target: EditorSelection) -> String? {
        switch target {
        case .clip(let clipID):
            guard let i = project.index(of: clipID) else { return nil }
            return String(localized: "クリップ\(i + 1)")
        case .subtitle(let cueID):
            guard let i = project.subtitles.firstIndex(where: { $0.id == cueID }) else { return nil }
            return String(localized: "字幕\(i + 1)")
        case .bgm:
            return project.audio.bgmName ?? "BGM"
        case .overlay(let overlayID):
            guard let i = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return nil }
            return String(localized: "重ねた素材\(i + 1)")
        case .narration(let narrationID):
            guard let item = project.narration.first(where: { $0.id == narrationID }) else { return nil }
            return item.name.isEmpty ? String(localized: "ナレーション") : item.name
        case .text(let textID):
            guard let item = project.textClips.first(where: { $0.id == textID }) else { return nil }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isMosaic { return String(localized: "モザイク") }
            if trimmed.isEmpty { return item.isSticker ? String(localized: "ステッカー") : String(localized: "テキスト") }
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            return firstLine.count > 10 ? String(firstLine.prefix(10)) + "…" : firstLine
        case .drawing(let drawingID):
            guard let i = project.drawings.firstIndex(where: { $0.id == drawingID }) else { return nil }
            return String(localized: "手書き\(i + 1)")
        case .marker(let markerID):
            guard let i = project.markers.firstIndex(where: { $0.id == markerID }) else { return nil }
            let name = project.markers[i].name
            return name.isEmpty ? String(localized: "マーカー\(i + 1)") : name
        }
    }

    /// パネルの ✓(完了)。手書き中なら描いた線を追加してから閉じる
    private func closePanel(_ panel: EditorPanel) {
        if panel == .drawingCanvas {
            finishDrawing()
        } else {
            activePanel = nil
            rewindToText(of: panel)
        }
    }

    /// パネルの ✕「キャンセル」。開いたときの状態に戻して閉じる
    private func cancelPanel(_ panel: EditorPanel) {
        if panel == .drawingCanvas {
            cancelDrawing()
            return
        }
        let snapshot = panelSnapshot
        activePanel = nil
        panelSnapshot = nil
        if let snapshot, project.snapshot() != snapshot {
            project.restore(snapshot)
            showToast(String(localized: "変更を取り消しました"), style: .info)
        }
        rewindToText(of: panel)
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .speed(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorSpeedPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .volume(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorVolumePanel(project: project, clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .filter(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorFilterPanel(project: project, clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .textEdit(let cueID):
            if let cue = project.subtitleBinding(id: cueID) {
                EditorTextEditPanel(cue: cue)
            } else {
                EditorMissingPanelContent()
            }
        case .subtitleStyle:
            EditorSubtitleStylePanel(project: project)
        case .captionTemplate:
            EditorCaptionTemplatePanel(project: project)
        case .aspect:
            EditorAspectPanel(project: project)
        case .bgmVolume:
            EditorBGMVolumePanel(project: project)
        case .documentary:
            EditorDocumentaryPanel(project: project, player: player)
        case .titleCard(let cardID):
            EditorTitleCardPanel(project: project,
                                 player: player,
                                 card: titleCardBinding(id: cardID),
                                 onSelect: { id in activePanel = .titleCard(id) },
                                 onDelete: { id in deleteTitleCard(id) })
        case .lowerThird(let itemID):
            EditorLowerThirdPanel(project: project,
                                  player: player,
                                  item: lowerThirdBinding(id: itemID),
                                  onSelect: { id in activePanel = .lowerThird(id) },
                                  onDelete: { id in deleteLowerThird(id) })
        case .jlCut(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorJLCutPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .colorAdjust(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorColorAdjustPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }

        // ---- 第3弾: クリップ ----
        case .transition(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorTransitionPanel(project: project, clip: clip, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .slip(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorSlipPanel(project: project, clip: clip, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .clipAnimation(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorClipAnimationPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .geometry(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorGeometryPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .speedCurve(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorSpeedCurvePanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .audioEffects(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorAudioEffectsPanel(url: clip.wrappedValue.url,
                                        name: clip.wrappedValue.name,
                                        effects: clip.audio.effects)
            } else {
                EditorMissingPanelContent()
            }
        case .beatDetect(let clipID):
            EditorBeatDetectPanel(project: project, history: history, clipID: clipID)
        case .hsl(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorHSLPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .lut(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorLUTPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .colorMatch(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorColorMatchPanel(project: project, clip: clip)
            } else {
                EditorMissingPanelContent()
            }

        // ---- 第3弾: テキスト ----
        case .textStyle(let textID):
            if let text = project.textClipBinding(id: textID) {
                EditorTextStylePanel(text: text)
            } else {
                EditorMissingPanelContent()
            }
        case .textAnimation(let textID):
            if let text = project.textClipBinding(id: textID) {
                EditorTextAnimationPanel(text: text)
            } else {
                EditorMissingPanelContent()
            }
        case .textPlacement(let textID):
            if let text = project.textClipBinding(id: textID) {
                EditorTextPlacementPanel(text: text)
            } else {
                EditorMissingPanelContent()
            }
        case .textKeyframes(let textID):
            if let text = project.textClipBinding(id: textID) {
                let current = text.wrappedValue
                EditorKeyframePanel(player: player,
                                    start: current.start,
                                    duration: current.duration,
                                    currentValue: KeyframeInterpolator.Value(center: current.center,
                                                                             scale: current.scale,
                                                                             rotation: current.rotation,
                                                                             opacity: current.opacity),
                                    keyframes: text.keyframes)
            } else {
                EditorMissingPanelContent()
            }
        case .sticker:
            EditorStickerPanel { emoji in
                addSticker(emoji)
            }

        // ---- 第3弾: オーバーレイ ----
        case .overlayPlacement(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayPlacementPanel(project: project, overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayKenBurns(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayKenBurnsPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayVolume(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayVolumePanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlaySpeed(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlaySpeedPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayFilter(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayFilterPanel(project: project, overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayKeyframes(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                let current = overlay.wrappedValue
                EditorKeyframePanel(player: player,
                                    start: current.start,
                                    duration: current.duration,
                                    currentValue: KeyframeInterpolator.Value(center: NormalizedPoint(x: current.frame.midX,
                                                                                                     y: current.frame.midY),
                                                                             scale: 1,
                                                                             rotation: current.rotation,
                                                                             opacity: current.opacity),
                                    keyframes: overlay.keyframes)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayBlend(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayBlendPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }

        // ---- ナレーション ----
        case .narrationVolume(let narrationID):
            if let narration = project.narrationBinding(id: narrationID) {
                EditorNarrationVolumePanel(narration: narration)
            } else {
                EditorMissingPanelContent()
            }
        case .narrationEffects(let narrationID):
            if let narration = project.narrationBinding(id: narrationID) {
                EditorAudioEffectsPanel(url: narration.wrappedValue.url,
                                        name: narration.wrappedValue.name,
                                        effects: narration.effects)
            } else {
                EditorMissingPanelContent()
            }
        case .narrationRecord:
            EditorNarrationRecordPanel(project: project,
                                       player: player,
                                       history: history,
                                       onRecorded: { id in selection = .narration(id) })

        // ---- 第3弾: 手書き ----
        case .drawingCanvas:
            EditorDrawingToolsPanel(strokes: $draftStrokes,
                                    colorHex: $drawingColorHex,
                                    width: $drawingWidth,
                                    onFinish: { finishDrawing() },
                                    onCancel: { cancelDrawing() })
        case .drawingStyle(let drawingID):
            if let drawing = project.drawingBinding(id: drawingID) {
                EditorDrawingStylePanel(drawing: drawing)
            } else {
                EditorMissingPanelContent()
            }
        case .drawingTiming(let drawingID):
            if let drawing = project.drawingBinding(id: drawingID) {
                EditorDrawingTimingPanel(drawing: drawing, player: player)
            } else {
                EditorMissingPanelContent()
            }

        // ---- 第3弾: マーカー ----
        case .markerName(let markerID):
            if let marker = project.markerBinding(id: markerID) {
                EditorMarkerNamePanel(project: project, player: player, marker: marker)
            } else {
                EditorMissingPanelContent()
            }
        case .markerKind(let markerID):
            if let marker = project.markerBinding(id: markerID) {
                EditorMarkerKindPanel(marker: marker)
            } else {
                EditorMissingPanelContent()
            }

        // ---- 第3弾: ルート ----
        case .watermark:
            EditorWatermarkPanel(project: project)
        case .formatKit:
            EditorFormatKitPanel(project: project,
                                 player: player,
                                 history: history,
                                 selectedClipID: selection?.clipID)
        case .textToSpeech:
            EditorTextToSpeechPanel(project: project,
                                    player: player,
                                    history: history,
                                    onAdded: { id in selection = .narration(id) })

        // ---- 第4弾: クリップ ----
        case .mask(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorClipMaskPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .autoReframe(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorAutoReframePanel(project: project, clip: clip, analysis: analysis)
            } else {
                EditorMissingPanelContent()
            }
        case .stabilize(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorStabilizePanel(clip: clip, analysis: analysis)
            } else {
                EditorMissingPanelContent()
            }
        case .enhance(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorEnhancePanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .parallax(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorClipParallaxPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }

        // ---- 第4弾: オーバーレイ ----
        case .overlayMask(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayMaskPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayParallax(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayParallaxPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }

        case .pacing:
            EditorPacingPanel(timeline: timeline, player: player,
                              onRerun: { runPacingCheck() },
                              onFix: { fix in applyEditingFix(fix) })
        case .mosaic(let textID):
            if let clip = project.textClipBinding(id: textID) {
                EditorMosaicPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }

        // ---- 第4弾: トラッキング ----
        case .textTracking(let textID):
            EditorTrackingPanel(project: project,
                                player: player,
                                history: history,
                                analysis: analysis,
                                controller: tracking,
                                target: .text(textID))
        case .overlayTracking(let overlayID):
            EditorTrackingPanel(project: project,
                                player: player,
                                history: history,
                                analysis: analysis,
                                controller: tracking,
                                target: .overlay(overlayID))

        // ---- 第4弾: ルート ----
        case .autoEditTemplates:
            EditorAutoEditTemplatePanel(project: project,
                                        player: player,
                                        history: history,
                                        analysis: analysis,
                                        onApplied: { afterProjectReplaced() })
        }
    }

    // MARK: - 章タイトル / テロップ の Binding

    /// 指定 ID の章タイトルへの Binding(見つからなければ nil)。
    /// 途中で消えても落ちないよう、見つからない場合は最後に見た値を返す
    private func titleCardBinding(id: UUID) -> Binding<TitleCard>? {
        guard let initial = project.titleCards.first(where: { $0.id == id }) else { return nil }
        let project = self.project
        return Binding<TitleCard>(
            get: { project.titleCards.first(where: { $0.id == id }) ?? initial },
            set: { newValue in
                guard let i = project.titleCards.firstIndex(where: { $0.id == id }) else { return }
                project.titleCards[i] = newValue
            }
        )
    }

    /// 指定 ID のテロップへの Binding(見つからなければ nil)
    private func lowerThirdBinding(id: UUID) -> Binding<LowerThird>? {
        guard let initial = project.lowerThirds.first(where: { $0.id == id }) else { return nil }
        let project = self.project
        return Binding<LowerThird>(
            get: { project.lowerThirds.first(where: { $0.id == id }) ?? initial },
            set: { newValue in
                guard let i = project.lowerThirds.firstIndex(where: { $0.id == id }) else { return }
                project.lowerThirds[i] = newValue
            }
        )
    }

    // MARK: - ツールバー項目
    //
    // 1.5: よく使う項目(9 個まで)+ グループ(2 段目の列)+「その他」。削除は最後。
    // 対象に当てはまらない項目(静止画 / 動画)は出さず、条件しだいで使えない項目はタップで理由を出す。

    /// 🔍 機能を探す(いまのツールバー + 何かを選んでいるときは全体の編集も)
    private var toolSearchSheet: some View {
        let contextTitle: String = toolbarModeTitle
        let context: [EditorToolSearchEntry] = EditorToolSearchIndex.flatten(toolbarItems, isRoot: selection == nil && !timeline.isMultiSelecting,
                                                                             contextTitle: contextTitle)
        let root: [EditorToolSearchEntry] = (selection == nil && !timeline.isMultiSelecting)
            ? []
            : EditorToolSearchIndex.flatten(rootItems, isRoot: true, contextTitle: String(localized: "全体の編集"))
        return EditorToolSearchSheet(contextEntries: context,
                                     contextTitle: contextTitle,
                                     rootEntries: root,
                                     onPick: { entry in runSearchedTool(entry) })
    }

    /// 検索で選んだ機能を実行する。写真を選ぶ機能など、ここから実行できないものはツールバーをその場所まで開く
    private func runSearchedTool(_ entry: EditorToolSearchEntry) {
        let item = entry.item
        let needsDeselect: Bool = entry.isRoot && (selection != nil || timeline.isMultiSelecting)
        // シートが閉じてから実行する(パネルやシートを開く機能があるため)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if needsDeselect {
                timeline.endMultiSelect()
                selection = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard item.isEnabled else {
                    if let reason = item.disabledReason {
                        showToast(reason, style: .warning)
                    }
                    toolbarGroupPath = entry.groupPath
                    return
                }
                if case .action(let action) = item.kind {
                    action()
                } else {
                    // 写真の選択などはボタンから開く必要があるので、その列を開いて知らせる
                    toolbarGroupPath = entry.groupPath
                    showToast(String(localized: "下の「\(item.title)」を押してください"))
                }
            }
        }
    }

    /// 下のボタンが何の編集か(切り替わったときに 1 秒だけ小さく表示する)
    private var toolbarModeTitle: String {
        if timeline.isMultiSelecting { return String(localized: "複数選択") }
        guard let current = selection else { return String(localized: "全体の編集") }
        switch current {
        case .clip: return String(localized: "クリップの編集")
        case .subtitle: return String(localized: "キャプションの編集")
        case .bgm: return String(localized: "BGMの編集")
        case .overlay: return String(localized: "オーバーレイの編集")
        case .narration: return String(localized: "ナレーションの編集")
        case .text(let id):
            return project.textClips.first(where: { $0.id == id })?.isMosaic == true ? String(localized: "モザイクの編集") : String(localized: "テキストの編集")
        case .drawing: return String(localized: "手書きの編集")
        case .marker: return String(localized: "マーカーの編集")
        }
    }

    private var toolbarItems: [EditorToolItem] {
        if timeline.isMultiSelecting { return multiSelectItems }
        guard let current = selection else { return rootItems }
        switch current {
        case .clip(let clipID):
            return clipItems(clipID)
        case .subtitle(let cueID):
            return subtitleItems(cueID)
        case .bgm:
            return bgmItems
        case .overlay(let overlayID):
            return overlayItems(overlayID)
        case .narration(let narrationID):
            return narrationItems(narrationID)
        case .text(let textID):
            return textItems(textID)
        case .drawing(let drawingID):
            return drawingItems(drawingID)
        case .marker(let markerID):
            return markerItems(markerID)
        }
    }

    /// 音声トラックを持つクリップがあるか(無音カット・音量そろえの有効条件)
    private var hasAudioClips: Bool {
        project.clips.contains(where: { $0.hasAudio })
    }

    private static let busyReason = String(localized: "処理中です。終わるまでお待ちください")
    private static let analysisBusyReason = String(localized: "解析中です。終わるまでお待ちください")
    private static let importingReason = String(localized: "読み込み中です。終わるまでお待ちください")
    private static let noAudioClipReason = String(localized: "このクリップには音声がありません")

    // MARK: ルート

    // 何も選んでいないとき: 足すもの と 全体にかけるもの だけを並べる
    private var rootItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        // どこから追加するか(写真ライブラリ / ファイル / Google フォト)を選んでから開く
        items.append(EditorToolItem(String(localized: "動画・写真を追加"), systemImage: "plus.rectangle.on.rectangle",
                                    enabled: !isImporting,
                                    disabledReason: Self.importingReason) {
            requestMediaAdd(appendAtEnd: false)
        })
        items.append(EditorToolItem.group(String(localized: "テキスト"), systemImage: "textformat", id: "group-text",
                                          items: textGroupItems))
        items.append(EditorToolItem.group(String(localized: "オーディオ"), systemImage: "music.note", id: "group-audio",
                                          items: audioGroupItems))
        items.append(EditorToolItem.group(String(localized: "全体"), systemImage: "rectangle.3.group", id: "group-whole",
                                          items: wholeGroupItems))
        items.append(EditorToolItem.group("AI", systemImage: "wand.and.stars", id: "group-ai",
                                          items: autoGroupItems))
        items.append(EditorToolItem(String(localized: "オーバーレイ"), systemImage: "photo.on.rectangle",
                                    enabled: !isImporting,
                                    disabledReason: Self.importingReason) {
            requestOverlayAdd()
        })
        items.append(EditorToolItem.group(String(localized: "エフェクト"), systemImage: "sparkles", id: "group-effects",
                                          items: effectGroupItems))
        items.append(EditorToolItem.more(rootMoreItems))
        return items
    }

    /// テキスト: テキスト / キャプション / キャプションを作成 / 名前テロップ / 章タイトル / ステッカー
    private var textGroupItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "テキスト"), systemImage: "textformat") {
            addTextAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "キャプション"), systemImage: "captions.bubble") {
            addSubtitleAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "キャプションを作成"), systemImage: "text.bubble") {
            history.record(project)
            activeSheet = .subtitles
        })
        items.append(EditorToolItem(String(localized: "名前テロップ"), systemImage: "person.text.rectangle") {
            addLowerThirdAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "章タイトル"), systemImage: "text.below.photo") {
            addTitleCardAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "ステッカー"), systemImage: "face.smiling") {
            openPanel(.sticker)
        })
        return items
    }

    /// オーディオ: BGM / ボイスオーバー録音 / AI読み上げ / 音声抽出
    private var audioGroupItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem("BGM", systemImage: "music.note") {
            history.record(project)
            activeSheet = .audio
        })
        items.append(EditorToolItem(String(localized: "ボイスオーバー録音"), systemImage: "mic") {
            openPanel(.narrationRecord)
        })
        items.append(EditorToolItem(String(localized: "AI読み上げ"), systemImage: "waveform.badge.mic") {
            openPanel(.textToSpeech)
        })
        let extractBusy = isImporting || mediaToolProgress != nil
        items.append(EditorToolItem.extractAudio(String(localized: "音声抽出"), systemImage: "waveform.badge.plus",
                                                 enabled: !extractBusy,
                                                 disabledReason: Self.busyReason))
        return items
    }

    /// エフェクト: モザイク / 顔に自動でかける / 手書き
    private var effectGroupItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "モザイク"), systemImage: "square.grid.3x3", id: "addMosaic") {
            addMosaicAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "顔に自動モザイク"), systemImage: "face.dashed",
                                    enabled: !analysis.isRunning && !project.clips.isEmpty,
                                    disabledReason: project.clips.isEmpty ? String(localized: "先に動画を追加してください") : Self.analysisBusyReason) {
            autoMosaicFaces()
        })
        items.append(EditorToolItem(String(localized: "手書き"), systemImage: "pencil.tip.crop.circle") {
            startDrawing()
        })
        return items
    }

    /// 全体: 比率 / 全体の仕上げ / ロゴ・透かし / ラウドネスを自動一致 / 無音部分を削除
    private var wholeGroupItems: [EditorToolItem] {
        let hasNarration = !project.narration.isEmpty
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "比率"), systemImage: "aspectratio") {
            openPanel(.aspect)
        })
        items.append(EditorToolItem(String(localized: "全体の仕上げ"), systemImage: "film.stack") {
            openPanel(.documentary)
        })
        items.append(EditorToolItem(String(localized: "ロゴ・透かし"), systemImage: "seal") {
            openPanel(.watermark)
        })
        items.append(EditorToolItem(String(localized: "ラウドネスを自動一致"), systemImage: "speaker.wave.2",
                                    enabled: hasAudioClips || hasNarration,
                                    disabledReason: String(localized: "音声のあるクリップやナレーションがありません")) {
            showNormalizeConfirm = true
        })
        items.append(EditorToolItem(String(localized: "無音部分を削除"), systemImage: "waveform.slash",
                                    enabled: hasAudioClips,
                                    disabledReason: String(localized: "音声のあるクリップがありません")) {
            showSilenceCutConfirm = true
        })
        return items
    }

    /// AI: AI を使う機能をすべてここに集める(ほかのメニューと重なってもよい)。
    /// 小見出しは付けず、よく使う順に 1 列で並べる。
    private var autoGroupItems: [EditorToolItem] {
        let running = analysis.isRunning
        let noClips = project.clips.isEmpty
        let needClips = String(localized: "先に動画を追加してください")
        var items: [EditorToolItem] = []

        items.append(EditorToolItem(String(localized: "おまかせ編集"), systemImage: "wand.and.stars",
                                    enabled: !running, disabledReason: Self.analysisBusyReason) {
            player.pause()
            activePanel = nil
            activeSheet = .autoEdit
        })
        items.append(EditorToolItem(String(localized: "キャプションを作成"), systemImage: "text.bubble", id: "ai-captions") {
            history.record(project)
            activeSheet = .subtitles
        })
        items.append(EditorToolItem(String(localized: "中だるみ・編集チェック"), systemImage: "gauge.with.dots.needle.33percent",
                                    enabled: !running && !noClips,
                                    disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            runPacingCheck()
        })
        items.append(EditorToolItem(String(localized: "無音部分を削除"), systemImage: "waveform.slash", id: "ai-silence",
                                    enabled: hasAudioClips,
                                    disabledReason: String(localized: "音声のあるクリップがありません")) {
            showSilenceCutConfirm = true
        })
        items.append(EditorToolItem(String(localized: "オートパンチイン"), systemImage: "plus.magnifyingglass", id: "ai-punchin",
                                    enabled: !running && !noClips, disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            showPunchInDialog = true
        })
        items.append(EditorToolItem(String(localized: "言いよどみカット"), systemImage: "scissors.badge.ellipsis", id: "ai-fillers",
                                    enabled: !project.subtitles.isEmpty,
                                    disabledReason: String(localized: "先に字幕を作ってください")) {
            cutFillers()
        })
        items.append(EditorToolItem(String(localized: "冒頭フック"), systemImage: "bolt.fill", id: "ai-coldopen",
                                    enabled: !running && !noClips, disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            insertColdOpen()
        })
        items.append(EditorToolItem(String(localized: "エンドスクリーンの余白"), systemImage: "rectangle.bottomthird.inset.filled", id: "ai-endscreen",
                                    enabled: !noClips, disabledReason: needClips) {
            appendEndScreen()
        })
        items.append(EditorToolItem(String(localized: "顔に自動モザイク"), systemImage: "face.dashed", id: "ai-faces",
                                    enabled: !running && !noClips,
                                    disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            autoMosaicFaces()
        })
        items.append(EditorToolItem(String(localized: "スピーチを強調"), systemImage: "person.wave.2", id: "ai-speech",
                                    enabled: !noClips, disabledReason: needClips) {
            withClipAtPlayhead { clipID in
                openPanel(.audioEffects(clipID))
                showToast(String(localized: "「スピーチを強調(AI)」を右に動かすと、声以外の雑音が消えます"))
            }
        })
        items.append(EditorToolItem(String(localized: "字幕を翻訳"), systemImage: "character.book.closed", id: "ai-translate") {
            history.record(project)
            activeSheet = .subtitles
            showToast(String(localized: "字幕の画面の「翻訳」から英語などに訳せます"))
        })
        items.append(EditorToolItem(String(localized: "AI読み上げ"), systemImage: "waveform.badge.mic", id: "ai-tts") {
            openPanel(.textToSpeech)
        })
        items.append(EditorToolItem(String(localized: "オートリフレーム"), systemImage: "person.crop.rectangle", id: "ai-reframe",
                                    enabled: !noClips, disabledReason: needClips) {
            withClipAtPlayhead { clipID in
                openPanel(.autoReframe(clipID))
            }
        })
        items.append(EditorToolItem(String(localized: "自動補正"), systemImage: "wand.and.rays", id: "ai-enhance",
                                    enabled: !noClips, disabledReason: needClips) {
            withClipAtPlayhead { clipID in
                autoEnhance(clipID)
            }
        })
        items.append(EditorToolItem(String(localized: "おまかせテンプレ"), systemImage: "square.grid.2x2",
                                    enabled: !running, disabledReason: Self.analysisBusyReason) {
            openPanel(.autoEditTemplates)
        })
        items.append(EditorToolItem(String(localized: "AI台本"), systemImage: "text.badge.star") {
            player.pause()
            activePanel = nil
            activeSheet = .scriptWriter
        })
        let slideshowBlocked = isImporting || running
        items.append(EditorToolItem.addSlideshow(String(localized: "スライドショー"), systemImage: "photo.stack",
                                                 enabled: !slideshowBlocked,
                                                 disabledReason: Self.busyReason))
        return items
    }

    /// 再生位置のクリップを選んでから処理する(クリップ用の AI 機能を「AI」メニューから使うため)
    private func withClipAtPlayhead(_ body: (UUID) -> Void) {
        guard let clipID = clipIDAtPlayhead else {
            showToast(String(localized: "再生位置をクリップの上に合わせてください"), style: .warning)
            return
        }
        selection = .clip(clipID)
        body(clipID)
    }

    /// ルートの「その他」
    private var rootMoreItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "マーカー"), systemImage: "flag") {
            addMarkerAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "フォーマット"), systemImage: "rectangle.stack.badge.plus") {
            openPanel(.formatKit)
        })
        items.append(EditorToolItem(String(localized: "サムネ"), systemImage: "photo.badge.plus") {
            player.pause()
            activePanel = nil
            activeSheet = .coverMaker
        })
        items.append(EditorToolItem(String(localized: "前回と比較"), systemImage: "rectangle.split.2x1") {
            player.pause()
            activePanel = nil
            activeSheet = .compare
        })
        items.append(EditorToolItem.section(String(localized: "設定")))
        items.append(EditorToolItem(String(localized: "動画の置き場所"), systemImage: mediaMode == .photoLibrary ? "photo.on.rectangle" : "internaldrive") {
            isChoosingMediaMode = true
        })
        items.append(EditorToolItem(String(localized: "このプロジェクトを空にする"), systemImage: "trash", destructive: true) {
            showClearProjectConfirm = true
        })
        return items
    }

    // MARK: クリップ

    // クリップを選んだとき(ユーザー指定の順): スプリット → リップル削除 → ビデオトランジション → AI → オーディオ
    // → ボリューム → 置き換え。速度・カラー・モーションなど、ほかはすべて「その他」の中。
    // 同じ種類の機能はどの部品でも同じグループ名(カラー / モーション / オーディオ)
    private func clipItems(_ clipID: UUID) -> [EditorToolItem] {
        let clip = project.clips.first(where: { $0.id == clipID })
        let isStill = clip?.isStill ?? false
        let isReversed = clip?.isReversed ?? false
        let hasAudio = (clip?.hasAudio ?? false) && !isStill
        let busy = mediaToolProgress != nil

        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "スプリット"), systemImage: "square.split.2x1") {
            splitClip(clipID)
        })
        items.append(EditorToolItem(String(localized: "リップル削除"), systemImage: "trash", destructive: true) {
            deleteClip(clipID)
        })
        items.append(EditorToolItem(String(localized: "ビデオトランジション"), systemImage: "arrow.left.arrow.right.square") {
            openPanel(.transition(clipID))
        })
        items.append(EditorToolItem.group("AI", systemImage: "wand.and.stars", id: "group-clip-ai",
                                          items: clipAIItems(clipID, isStill: isStill, hasAudio: hasAudio)))
        if !isStill {
            items.append(EditorToolItem.group(String(localized: "オーディオ"), systemImage: "waveform", id: "group-clip-audio",
                                              items: clipAudioItems(clipID, hasAudio: hasAudio)))
            items.append(EditorToolItem(String(localized: "ボリューム"), systemImage: "speaker.wave.2",
                                        enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
                openPanel(.volume(clipID))
            })
        }
        items.append(EditorToolItem.replaceMedia(String(localized: "フッテージを置き換え"), systemImage: "arrow.triangle.2.circlepath",
                                                 enabled: !(isImporting || busy),
                                                 disabledReason: Self.busyReason))

        // ここから下は「その他」の中
        var more: [EditorToolItem] = []
        if !isStill {
            var speedItems: [EditorToolItem] = []
            speedItems.append(EditorToolItem(String(localized: "速度・デュレーション"), systemImage: "speedometer") {
                openPanel(.speed(clipID))
            })
            speedItems.append(EditorToolItem(String(localized: "タイムリマップ"), systemImage: "waveform.path.ecg") {
                openPanel(.speedCurve(clipID))
            })
            speedItems.append(EditorToolItem(isReversed ? String(localized: "逆再生を解除") : String(localized: "逆再生"),
                                             systemImage: isReversed ? "arrow.uturn.backward.circle.fill" : "arrow.uturn.backward.circle",
                                             id: "reverse",
                                             enabled: !busy,
                                             disabledReason: Self.busyReason) {
                toggleReverse(clipID)
            })
            speedItems.append(EditorToolItem(String(localized: "フレーム保持"), systemImage: "pause.rectangle",
                                             enabled: !busy, disabledReason: Self.busyReason) {
                freezeFrame(clipID)
            })
            more.append(EditorToolItem.group(String(localized: "速度"), systemImage: "speedometer", id: "group-speed",
                                             items: speedItems))
        }
        more.append(EditorToolItem.group(String(localized: "カラー"), systemImage: "circle.lefthalf.filled", id: "group-color",
                                         items: colorGroupItems(clipID)))
        more.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion",
                                         items: clipMotionItems(clipID, isStill: isStill)))
        more.append(contentsOf: clipMoreItems(clipID, clip: clip, isStill: isStill,
                                              hasAudio: hasAudio, busy: busy))
        items.append(EditorToolItem.more(more))
        return items
    }

    /// クリップの「AI」: このクリップに使う AI 機能(全体の AI メニューと重なってもよい)
    private func clipAIItems(_ clipID: UUID, isStill: Bool, hasAudio: Bool) -> [EditorToolItem] {
        let running = analysis.isRunning
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "スピーチを強調"), systemImage: "person.wave.2", id: "clip-ai-speech",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.audioEffects(clipID))
            showToast(String(localized: "「スピーチを強調(AI)」を右に動かすと、声以外の雑音が消えます"))
        })
        items.append(EditorToolItem(String(localized: "自動補正"), systemImage: "wand.and.rays", id: "clip-ai-enhance") {
            autoEnhance(clipID)
        })
        if !isStill {
            items.append(EditorToolItem(String(localized: "オートリフレーム"), systemImage: "person.crop.rectangle", id: "clip-ai-reframe") {
                openPanel(.autoReframe(clipID))
            })
        }
        items.append(EditorToolItem(String(localized: "顔に自動モザイク"), systemImage: "face.dashed", id: "clip-ai-faces",
                                    enabled: !running, disabledReason: Self.analysisBusyReason) {
            autoMosaicFaces()
        })
        items.append(EditorToolItem(String(localized: "キャプションを作成"), systemImage: "text.bubble", id: "clip-ai-captions") {
            history.record(project)
            activeSheet = .subtitles
        })
        return items
    }

    /// クリップの「モーション」: モーション・クロップ / アニメーション / オートリフレーム / スタビライザー / マスク / 3Dズーム
    private func clipMotionItems(_ clipID: UUID, isStill: Bool) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "モーション・クロップ"), systemImage: "crop.rotate") {
            openPanel(.geometry(clipID))
        })
        items.append(EditorToolItem(String(localized: "アニメーション"), systemImage: "sparkles.rectangle.stack") {
            openPanel(.clipAnimation(clipID))
        })
        if !isStill {
            items.append(EditorToolItem(String(localized: "オートリフレーム"), systemImage: "person.crop.rectangle") {
                openPanel(.autoReframe(clipID))
            })
            items.append(EditorToolItem(String(localized: "スタビライザー"), systemImage: "camera.metering.center.weighted") {
                openPanel(.stabilize(clipID))
            })
        }
        items.append(EditorToolItem(String(localized: "マスク"), systemImage: "circle.dashed") {
            openPanel(.mask(clipID))
        })
        if isStill {
            items.append(EditorToolItem(String(localized: "3Dズーム"), systemImage: "cube.transparent") {
                openPanel(.parallax(clipID))
            })
        }
        return items
    }

    /// クリップの「オーディオ」: スピーチを強調 / オーディオエフェクト / J/Lカット / ビートに合わせる
    private func clipAudioItems(_ clipID: UUID, hasAudio: Bool) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "スピーチを強調"), systemImage: "person.wave.2",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.audioEffects(clipID))
            showToast(String(localized: "「スピーチを強調(AI)」を右に動かすと、声以外の雑音が消えます"))
        })
        items.append(EditorToolItem(String(localized: "オーディオエフェクト"), systemImage: "waveform.and.magnifyingglass",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.audioEffects(clipID))
        })
        items.append(EditorToolItem(String(localized: "J/Lカット"), systemImage: "waveform.path",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.jlCut(clipID))
        })
        items.append(EditorToolItem(String(localized: "ビートに合わせる"), systemImage: "metronome",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.beatDetect(clipID))
        })
        return items
    }

    /// 色調整: 自動補正 / 色調整 / HSL / 色合わせ / LUT読み込み / スコープ
    private func colorGroupItems(_ clipID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "カラープリセット"), systemImage: "camera.filters") {
            openPanel(.filter(clipID))
        })
        items.append(EditorToolItem(String(localized: "自動補正"), systemImage: "wand.and.stars") {
            autoEnhance(clipID)
        })
        items.append(EditorToolItem(String(localized: "カラー補正"), systemImage: "circle.lefthalf.filled") {
            openPanel(.colorAdjust(clipID))
        })
        items.append(EditorToolItem(String(localized: "HSL セカンダリ"), systemImage: "paintpalette") {
            openPanel(.hsl(clipID))
        })
        items.append(EditorToolItem(String(localized: "カラーマッチ"), systemImage: "eyedropper.halffull",
                                    enabled: project.clips.count > 1,
                                    disabledReason: String(localized: "クリップが 2 つ以上あるときに使えます")) {
            openPanel(.colorMatch(clipID))
        })
        items.append(EditorToolItem(String(localized: "LUT を参照"), systemImage: "cube") {
            openPanel(.lut(clipID))
        })
        items.append(EditorToolItem(String(localized: "カラースコープ"), systemImage: "chart.bar.xaxis") {
            player.pause()
            activePanel = nil
            activeSheet = .scopes(clipID)
        })
        return items
    }

    /// クリップの「その他」: 複製 / 複数選択 / フッテージを置き換え / 画質補正 / マルチカメラ / パーツとして保存 / 詳細設定
    private func clipMoreItems(_ clipID: UUID, clip: Clip?, isStill: Bool,
                               hasAudio: Bool, busy: Bool) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "複製"), systemImage: "plus.square.on.square") {
            history.record(project)
            project.duplicateClip(id: clipID)
            showToast(String(localized: "複製しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "複数選択"), systemImage: "checkmark.circle") {
            timeline.beginMultiSelect(with: clipID)
            showToast(String(localized: "クリップをタップして選択を追加・解除できます"))
        })
        // 並べ替え(長押しドラッグのほかに、ボタンでも 1 つずつ動かせる)
        let index = project.index(of: clipID) ?? 0
        items.append(EditorToolItem(String(localized: "前へ移動"), systemImage: "arrow.left.to.line",
                                    enabled: index > 0, disabledReason: String(localized: "これ以上前には動かせません")) {
            history.record(project)
            if project.moveClips(ids: [clipID], by: -1) { showToast(String(localized: "前へ移動しました"), undo: true) }
        })
        items.append(EditorToolItem(String(localized: "後ろへ移動"), systemImage: "arrow.right.to.line",
                                    enabled: index < project.clips.count - 1, disabledReason: String(localized: "これ以上後ろには動かせません")) {
            history.record(project)
            if project.moveClips(ids: [clipID], by: 1) { showToast(String(localized: "後ろへ移動しました"), undo: true) }
        })
        let canSlip = !isStill && (clip.map { $0.duration - ($0.endTime - $0.startTime) > 0.05 } ?? false)
        items.append(EditorToolItem(String(localized: "使う部分を調整(スリップ)"), systemImage: "arrow.left.and.right.square",
                                    enabled: canSlip,
                                    disabledReason: String(localized: "元の動画をすべて使っているので、ずらせません")) {
            openPanel(.slip(clipID))
        })
        items.append(EditorToolItem(String(localized: "画質補正"), systemImage: "sparkles.tv") {
            openPanel(.enhance(clipID))
        })
        if !isStill {
            items.append(EditorToolItem(String(localized: "マルチカメラ"), systemImage: "camera.on.rectangle") {
                history.record(project)
                activeSheet = .multicam(clipID)
            })
        }
        items.append(EditorToolItem(String(localized: "パーツとして保存"), systemImage: "rectangle.stack.badge.plus") {
            openPanel(.formatKit)
        })
        items.append(EditorToolItem(String(localized: "詳細設定"), systemImage: "slider.horizontal.3") {
            history.record(project)
            activeSheet = .clipDetail(clipID)
        })
        return items
    }

    // MARK: 重ねた素材(オーバーレイ)

    // オーバーレイ・テキスト・モザイクは同じ並び: 編集 → 削除 → モーション → (アニメーション) → カラー → その他
    private func overlayItems(_ overlayID: UUID) -> [EditorToolItem] {
        let isImage = project.overlays.first(where: { $0.id == overlayID })?.isImage ?? false
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "位置・サイズ"), systemImage: "rectangle.on.rectangle") {
            openPanel(.overlayPlacement(overlayID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeOverlay(id: overlayID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        var motion: [EditorToolItem] = []
        motion.append(EditorToolItem(String(localized: "キーフレーム"), systemImage: "diamond") {
            openPanel(.overlayKeyframes(overlayID))
        })
        motion.append(EditorToolItem(String(localized: "トラッキング"), systemImage: "scope") {
            openPanel(.overlayTracking(overlayID))
        })
        motion.append(EditorToolItem("Ken Burns", systemImage: "arrow.up.left.and.arrow.down.right") {
            openPanel(.overlayKenBurns(overlayID))
        })
        motion.append(EditorToolItem(String(localized: "マスク"), systemImage: "circle.dashed") {
            openPanel(.overlayMask(overlayID))
        })
        if isImage {
            motion.append(EditorToolItem(String(localized: "3Dズーム"), systemImage: "cube.transparent") {
                openPanel(.overlayParallax(overlayID))
            })
        }
        items.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion", items: motion))
        var color: [EditorToolItem] = []
        color.append(EditorToolItem(String(localized: "カラープリセット"), systemImage: "camera.filters") {
            openPanel(.overlayFilter(overlayID))
        })
        color.append(EditorToolItem(String(localized: "描画モード"), systemImage: "circle.lefthalf.striped.horizontal") {
            openPanel(.overlayBlend(overlayID))
        })
        items.append(EditorToolItem.group(String(localized: "カラー"), systemImage: "circle.lefthalf.filled", id: "group-color", items: color))
        var more: [EditorToolItem] = []
        more.append(EditorToolItem(String(localized: "複製"), systemImage: "plus.square.on.square") {
            duplicateOverlay(overlayID)
            showToast(String(localized: "複製しました"), undo: true)
        })
        if !isImage {
            more.append(EditorToolItem(String(localized: "ボリューム"), systemImage: "speaker.wave.2") {
                openPanel(.overlayVolume(overlayID))
            })
            more.append(EditorToolItem(String(localized: "速度・デュレーション"), systemImage: "speedometer") {
                openPanel(.overlaySpeed(overlayID))
            })
        }
        items.append(EditorToolItem.more(more))
        return items
    }

    // MARK: ナレーション

    private func narrationItems(_ narrationID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "ボリューム"), systemImage: "speaker.wave.2") {
            openPanel(.narrationVolume(narrationID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeNarration(id: narrationID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "オーディオエフェクト"), systemImage: "waveform.and.magnifyingglass") {
            openPanel(.narrationEffects(narrationID))
        })
        items.append(EditorToolItem(String(localized: "聞きやすくする"), systemImage: "waveform",
                                    enabled: audioToolProgress == nil,
                                    disabledReason: Self.busyReason) {
            normalizeNarrationTarget = narrationID
        })
        return items
    }

    // MARK: 字幕

    private func subtitleItems(_ cueID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "文字を直す"), systemImage: "pencil") {
            openPanel(.textEdit(cueID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeSubtitle(id: cueID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "キャプションのスタイル"), systemImage: "textformat.size") {
            openPanel(.subtitleStyle)
        })
        items.append(EditorToolItem(String(localized: "キャプションのデザイン"), systemImage: "rectangle.3.group") {
            openPanel(.captionTemplate)
        })
        items.append(EditorToolItem(String(localized: "キャプションを作成"), systemImage: "text.bubble") {
            history.record(project)
            activeSheet = .subtitles
        })
        return items
    }

    // MARK: BGM

    private var bgmItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "ボリューム"), systemImage: "speaker.wave.2") {
            openPanel(.bgmVolume)
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.audio.bgmURL = nil
            project.audio.bgmName = nil
            showToast(String(localized: "削除しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "曲を変更"), systemImage: "arrow.triangle.2.circlepath") {
            history.record(project)
            activeSheet = .audio
        })
        return items
    }

    // MARK: テキスト・ステッカー

    private func textItems(_ textID: UUID) -> [EditorToolItem] {
        if project.textClips.first(where: { $0.id == textID })?.isMosaic == true {
            return mosaicItems(textID)
        }
        let isSticker = project.textClips.first(where: { $0.id == textID })?.isSticker ?? false
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(isSticker ? String(localized: "ステッカー") : String(localized: "文字・スタイル"), systemImage: "pencil",
                                    id: "textStyle") {
            openPanel(.textStyle(textID))
        })
        items.append(textDeleteItem(textID))
        var motion: [EditorToolItem] = []
        motion.append(EditorToolItem(String(localized: "位置・サイズ"), systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
            openPanel(.textPlacement(textID))
        })
        motion.append(EditorToolItem(String(localized: "キーフレーム"), systemImage: "diamond") {
            openPanel(.textKeyframes(textID))
        })
        motion.append(EditorToolItem(String(localized: "トラッキング"), systemImage: "scope") {
            openPanel(.textTracking(textID))
        })
        items.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion", items: motion))
        items.append(EditorToolItem(String(localized: "アニメーション"), systemImage: "sparkles") {
            openPanel(.textAnimation(textID))
        })
        items.append(EditorToolItem.more([textDuplicateItem(textID)]))
        return items
    }

    private func textDeleteItem(_ textID: UUID) -> EditorToolItem {
        EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeTextClip(id: textID)
            showToast(String(localized: "削除しました"), undo: true)
        }
    }

    private func textDuplicateItem(_ textID: UUID) -> EditorToolItem {
        EditorToolItem(String(localized: "複製"), systemImage: "plus.square.on.square") {
            duplicateText(textID)
            showToast(String(localized: "複製しました"), undo: true)
        }
    }

    // MARK: モザイク

    private func mosaicItems(_ textID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "モザイク"), systemImage: "square.grid.3x3", id: "mosaicStyle") {
            openPanel(.mosaic(textID))
        })
        items.append(textDeleteItem(textID))
        var motion: [EditorToolItem] = []
        motion.append(EditorToolItem(String(localized: "トラッキング"), systemImage: "scope") {
            openPanel(.textTracking(textID))
        })
        motion.append(EditorToolItem(String(localized: "キーフレーム"), systemImage: "diamond") {
            openPanel(.textKeyframes(textID))
        })
        items.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion", items: motion))
        items.append(EditorToolItem.more([textDuplicateItem(textID)]))
        return items
    }

    /// 中だるみチェック(端末内の AI で 1 秒ごとに判定し、目盛りの下に緑・黄・赤の帯を出す)
    private func runPacingCheck() {
        player.pause()
        let snapshot = project.snapshot()
        analysis.run(title: String(localized: "動画をチェックしています"), robot: .consensus) { report in
            let sensitivity = PacingSensitivity(rawValue: UserDefaults.standard.string(forKey: "pacing.sensitivity") ?? "") ?? .normal
            let useAI: Bool = UserDefaults.standard.bool(forKey: "pacing.useAI")
            let platform = TargetPlatform(rawValue: UserDefaults.standard.string(forKey: "pacing.platform") ?? "") ?? .youtube
            let result = try await PacingAnalyzer.analyze(snapshot: snapshot, sensitivity: sensitivity,
                                                          useAI: useAI, platform: platform, progress: report)
            if Task.isCancelled { return }
            timeline.pacing = result.segments
            timeline.pacingChecks = result.checks
            if useAI && !result.usedAI && !snapshot.subtitles.isEmpty {
                showToast(String(localized: "AI を使えなかったため、映像と音だけで判定しました"), style: .warning)
            }
            pacingClipsKey = Self.clipsKey(snapshot)
            selection = nil
            activePanel = .pacing
        } onError: { error in
            showToast(String(localized: "チェックできませんでした(\(error.localizedDescription))"), style: .warning)
        }
    }

    /// 編集チェックの「直す」ボタン
    private func applyEditingFix(_ fix: EditingCheck.Fix) {
        switch fix {
        case .openCaptions:
            activePanel = nil
            history.record(project)
            activeSheet = .subtitles
        case .enableDucking:
            history.record(project)
            project.documentary.autoDucking = true
            showToast(String(localized: "話している間は BGM を下げるようにしました"), undo: true)
        case .makeVertical:
            history.record(project)
            project.canvas.aspect = .portrait9x16
            showToast(String(localized: "9:16 の縦にしました"), undo: true)
        case .openCover:
            player.pause()
            activePanel = nil
            activeSheet = .coverMaker
        case .seek(let time):
            player.seek(to: time)
        case .setBGMVolume(let volume):
            history.record(project)
            project.audio.bgmVolume = volume
            showToast(String(localized: "BGM を \(Int((volume * 100).rounded()))% にしました"), undo: true)
        case .normalizeLoudness:
            showNormalizeConfirm = true
        case .openColorMatch(let clipID):
            selection = .clip(clipID)
            openPanel(.colorMatch(clipID))
        case .openScriptWriter:
            player.pause()
            activePanel = nil
            activeSheet = .scriptWriter
        case .openAutoReframe(let clipID):
            selection = .clip(clipID)
            openPanel(.autoReframe(clipID))
        case .setAspect(let aspect):
            history.record(project)
            project.canvas.aspect = aspect
            showToast(String(localized: "\(aspect.displayName)にしました"), undo: true)
        case .addEndScreen:
            appendEndScreen()
        }
    }

    // MARK: インフルエンサー向けの自動編集(パンチイン・言いよどみカット・冒頭フック・エンドスクリーン)

    /// 話の区切りごとにズームを 1.0 と zoom 倍で交互に切り替える(選択中のクリップがあればそれだけ、なければ全クリップ)
    private func applyPunchIn(zoom: Double, interval: Double?) {
        player.pause()
        let snapshot = project.snapshot()
        let selected = selection?.clipID
        analysis.run(title: String(localized: "話の区切りを探しています")) { report in
            try await HighlightAnalyzer.ensureVoiceRuns(snapshot: snapshot, progress: report)
            let guardSpeech = SpeechGuard(snapshot: snapshot, pad: 0)
            var plan: [(id: UUID, cuts: [Double], base: Double)] = []
            for (index, clip) in snapshot.clips.enumerated() where !clip.isStill {
                if let selected, clip.id != selected { continue }
                let cuts = PunchInPlanner.cutPoints(for: clip, index: index, guardSpeech: guardSpeech,
                                                    fallbackInterval: interval ?? 4)
                if !cuts.isEmpty { plan.append((clip.id, cuts, clip.geometry.zoom)) }
            }
            guard !plan.isEmpty else {
                showToast(String(localized: "区切りが見つかりませんでした(クリップが短いか、話し声がありません)"), style: .warning)
                return
            }
            history.record(project)
            var pieces = 0
            for item in plan {
                guard let index = project.index(of: item.id) else { continue }
                let original = project.clips[index]
                for t in item.cuts.sorted(by: >) {
                    _ = project.splitClip(id: item.id, atSourceTime: t)
                }
                var i = index
                var punched = false
                while i < project.clips.count,
                      project.clips[i].url == original.url,
                      project.clips[i].startTime >= original.startTime - 0.001,
                      project.clips[i].endTime <= original.endTime + 0.001 {
                    project.clips[i].geometry.zoom = punched ? min(4, item.base * zoom) : item.base
                    let hasNextPiece = i + 1 < project.clips.count && project.clips[i + 1].url == original.url
                        && project.clips[i + 1].endTime <= original.endTime + 0.001
                    if hasNextPiece { project.clips[i].transition = ClipTransition() }
                    punched.toggle()
                    i += 1
                    pieces += 1
                }
            }
            showToast(String(localized: "\(Int(pieces)) 個に分けてパンチインを入れました"), undo: true)
        } onError: { error in
            showToast(String(localized: "チェックできませんでした(\(error.localizedDescription))"), style: .warning)
        }
    }

    /// 字幕の言葉から「えー」「あのー」などを見つけて、その部分だけ詰める
    private func cutFillers() {
        let cues = project.subtitles
        guard !cues.isEmpty else {
            showToast(String(localized: "先に字幕を作ってください(字幕の言葉から探します)"), style: .warning)
            return
        }
        let spans = FillerDetector.spans(in: cues)
        guard !spans.isEmpty else {
            showToast(String(localized: "言いよどみは見つかりませんでした"), style: .info)
            return
        }
        player.pause()
        history.record(project)
        let removed = project.removeOutputRanges(spans.map { (start: max(0, $0.start - 0.03), end: $0.end + 0.03) })
        showToast(String(localized: "\(spans.count) か所・\(String(format: "%.1f", removed)) 秒の言いよどみを詰めました"), undo: true)
    }

    /// いちばんの見どころ(3〜5 秒)を先頭にコピーして差し込む(結論から見せる構成)
    private func insertColdOpen() {
        player.pause()
        let snapshot = project.snapshot()
        guard snapshot.totalDuration >= 20 else {
            showToast(String(localized: "20 秒以上の動画で使えます"), style: .warning)
            return
        }
        analysis.run(title: String(localized: "見どころを探しています")) { report in
            var settings = AutoEditSettings()
            settings.style = .short
            settings.targetDuration = 15
            let segments = try await HighlightAnalyzer.analyze(snapshot: snapshot, settings: settings, progress: report)
            let layout = CompositionBuilder.timelineLayout(for: snapshot)
            let guardSpeech = SpeechGuard(snapshot: snapshot, pad: 0.15)
            var best: (clipIndex: Int, start: Double, end: Double, score: Double)? = nil
            for segment in segments {
                guard let index = snapshot.clips.firstIndex(where: { $0.id == segment.clipID }), index < layout.count else { continue }
                let clip = snapshot.clips[index]
                let speed = max(clip.speed, 0.01)
                let timelineStart = layout[index].start + (segment.start - clip.startTime) / speed
                guard timelineStart >= 8 else { continue }
                let s = guardSpeech.safeStart(segment.start, clip: index, lower: clip.startTime)
                var e = guardSpeech.safeEnd(min(segment.end, s + 5), clip: index, upper: clip.endTime)
                if e - s > 7 { e = guardSpeech.safeEnd(s + 5, clip: index, upper: clip.endTime) }
                guard e - s >= 2 else { continue }
                if best == nil || segment.score > (best?.score ?? 0) { best = (index, s, e, segment.score) }
            }
            guard let best else {
                showToast(String(localized: "先頭に出せる見どころが見つかりませんでした"), style: .warning)
                return
            }
            let source = snapshot.clips[best.clipIndex]
            var piece = source.duplicated()
            piece.startTime = best.start
            piece.endTime = best.end
            piece.transition = ClipTransition(type: .fadeBlack, duration: 0.4)
            let length = piece.outputDuration
            let speed = max(source.speed, 0.01)
            let segStart = layout[best.clipIndex].start + (best.start - source.startTime) / speed
            let segEnd = segStart + (best.end - best.start) / speed
            history.record(project)
            project.shiftTimelineItems(from: 0, by: length)
            // 見どころの字幕も先頭にコピーする
            var copies: [SubtitleCue] = []
            for cue in snapshot.subtitles where cue.end > segStart && cue.start < segEnd {
                var copy = cue
                copy.id = UUID()
                copy.start = max(0, cue.start - segStart)
                copy.end = min(length, cue.end - segStart)
                copy.words = cue.words.compactMap { word in
                    var w = word
                    w.start -= segStart
                    w.end -= segStart
                    return w.start >= 0 && w.end <= length ? w : nil
                }
                if copy.end - copy.start >= 0.2 { copies.append(copy) }
            }
            project.subtitles.append(contentsOf: copies)
            project.sortSubtitles()
            project.clips.insert(piece, at: 0)
            player.seek(to: 0)
            showToast(String(localized: "見どころ(\(clipFXSeconds(best.end - best.start)))を先頭に差し込みました"), undo: true)
        } onError: { error in
            showToast(String(localized: "見どころを探せませんでした(\(error.localizedDescription))"), style: .warning)
        }
    }

    /// 最後に終了画面用の余白(最後のコマを少し暗くした静止画 10 秒)を足す
    private func appendEndScreen(seconds: Double = 10) {
        guard let last = project.clips.last else { return }
        player.pause()
        mediaToolTask?.cancel()
        mediaToolTask = Task { @MainActor in
            mediaToolProgress = ClipFXProgress(title: String(localized: "エンドスクリーンの余白を作成中"), fraction: nil)
            do {
                let imageURL: URL
                if last.isStill, let still = last.stillImageURL {
                    imageURL = still
                } else {
                    imageURL = try await MediaTools.freezeFrameImage(from: last.url, at: max(last.startTime, last.endTime - 0.1))
                }
                mediaToolProgress = nil
                if Task.isCancelled { return }
                let size = MediaStore.imagePixelSize(of: imageURL) ?? last.displaySize
                let thumb = MediaStore.makeImageClipThumbnail(url: imageURL, maxPixel: 320)
                var still = Clip(url: imageURL,
                                 duration: 3600,
                                 naturalSize: size,
                                 preferredTransform: .identity,
                                 hasAudio: false,
                                 thumbnail: thumb,
                                 name: String(localized: "エンドスクリーン"))
                still.stillImageURL = imageURL
                still.startTime = 0
                still.endTime = seconds
                // 終了画面の部品(次の動画・登録ボタン)が目立つよう少し暗くする
                still.filter.adjustments.brightness = -0.25
                history.record(project)
                if project.clips.indices.last.map({ project.clips[$0].transition.type == .none }) ?? false {
                    project.clips[project.clips.count - 1].transition = ClipTransition(type: .dissolve, duration: 0.5)
                }
                project.clips.append(still)
                showToast(String(localized: "最後に \(Int(seconds)) 秒の余白を足しました(終了画面用)"), undo: true)
            } catch {
                mediaToolProgress = nil
                showToast(String(localized: "余白を作れませんでした: \(error.localizedDescription)"), style: .warning)
            }
        }
    }

    /// クリップの並びと長さ(変わったら中だるみチェックの帯を消す)
    private static func clipsKey(_ snapshot: ProjectSnapshot) -> String {
        snapshot.clips.map { "\($0.id.uuidString):\(Int($0.outputDuration * 10))" }.joined(separator: "|")
    }

    /// 再生位置にモザイクを追加して選択し、設定パネルを開く
    private func addMosaicAtPlayhead() {
        let before = project.snapshot()
        history.record(project)
        let clip = TextClip.newMosaic(start: max(0, player.currentTime))
        project.textClips.append(clip)
        project.sortTextClips()
        selection = .text(clip.id)
        panelSnapshot = before
        activePanel = .mosaic(clip.id)
    }

    /// 再生位置のコマで顔を探し、顔ごとにモザイクを置いて、クリップの終わりまで追いかけさせる
    private func autoMosaicFaces() {
        let t = player.currentTime
        guard let location = project.locate(timelineTime: t), location.index < project.clips.count else {
            showToast(String(localized: "再生位置にクリップがありません"), style: .warning)
            return
        }
        let clip = project.clips[location.index]
        if clip.isStill || clip.isReversed {
            showToast(clip.isStill ? String(localized: "静止画では顔を追いかけられません") : String(localized: "逆再生中のクリップでは使えません"), style: .warning)
            return
        }
        player.pause()
        let snapshot = project.snapshot()
        let canvasSize = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)
        let scaling: ScalingMode = (snapshot.canvas.aspect == .original) ? .fit : snapshot.canvas.scaling
        let sourceStart = min(max(location.sourceTime, clip.startTime), clip.endTime)
        let sourceEnd = clip.endTime
        let outputStartInClip: Double = ClipFXTimeline.outputOffset(sourceTime: sourceStart, clip: clip)
        let outputEndInClip: Double = ClipFXTimeline.outputOffset(sourceTime: sourceEnd, clip: clip)
        let duration: Double = max(0.5, outputEndInClip - outputStartInClip)
        let clipRect = PreviewTrackingMath.clipRect(clipSize: clip.displaySize, canvasSize: canvasSize, scaling: scaling)
        let url = clip.url
        let project = self.project
        let history = self.history

        analysis.run(title: String(localized: "顔を探しています")) { report in
            let faces = try await MosaicFaceFinder.findFaces(in: clip, sourceTime: sourceStart,
                                                            canvasSize: canvasSize, scaling: scaling)
            guard !faces.isEmpty else {
                showToast(String(localized: "この位置のコマに顔が見つかりませんでした"), style: .warning)
                return
            }
            var mosaics: [TextClip] = []
            for (n, face) in faces.enumerated() {
                var mosaic = TextClip.newMosaic(start: t, duration: duration)
                // 顔より少し大きめに
                mosaic.center = NormalizedPoint(x: face.canvasRect.midX, y: face.canvasRect.midY)
                mosaic.widthRatio = min(1, face.canvasRect.width * 1.35)
                mosaic.mosaic?.heightRatio = min(1, face.canvasRect.height * 1.5)
                // 顔を追いかける(見失ったらそこで止まり、以降は最後の位置)
                if sourceEnd - sourceStart >= 0.2 {
                    let base = Double(n) / Double(faces.count)
                    let share = 1 / Double(faces.count)
                    if let tracked = try? await MotionTracker.track(url: url, start: sourceStart, end: sourceEnd,
                                                                    initialRect: face.sourceRect, fps: 15,
                                                                    progress: { report(base + $0 * share) }) {
                        var keyframes: [Keyframe] = []
                        for tracker in tracked {
                            let out = ClipFXTimeline.outputOffset(sourceTime: sourceStart + tracker.time, clip: clip)
                                - outputStartInClip
                            let p = PreviewTrackingMath.canvasPoint(fromSource: tracker.center,
                                                                    clipRect: clipRect, canvasSize: canvasSize)
                            keyframes.append(Keyframe(time: max(0, out),
                                                      center: NormalizedPoint(x: min(max(p.x, -0.25), 1.25),
                                                                              y: min(max(p.y, -0.25), 1.25)),
                                                      scale: 1, rotation: 0, opacity: 1, easing: .linear))
                        }
                        mosaic.keyframes = keyframes.sorted { $0.time < $1.time }
                    }
                }
                mosaics.append(mosaic)
            }
            if Task.isCancelled { return }
            history.record(project)
            project.textClips.append(contentsOf: mosaics)
            project.sortTextClips()
            if let first = mosaics.first {
                selection = .text(first.id)
            }
            showToast(String(localized: "\(mosaics.count) 人の顔にモザイクをかけました"), undo: true)
        } onError: { error in
            showToast(String(localized: "顔を探せませんでした(\(error.localizedDescription))"), style: .warning)
        }
    }

    // MARK: 手書き

    private func drawingItems(_ drawingID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "色・太さ"), systemImage: "paintbrush.pointed") {
            openPanel(.drawingStyle(drawingID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeDrawing(id: drawingID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "表示する時間"), systemImage: "clock") {
            openPanel(.drawingTiming(drawingID))
        })
        return items
    }

    // MARK: マーカー

    private func markerItems(_ markerID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "名前"), systemImage: "character.cursor.ibeam") {
            openPanel(.markerName(markerID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeMarker(id: markerID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "色・種類"), systemImage: "flag") {
            openPanel(.markerKind(markerID))
        })
        return items
    }

    // MARK: 複数選択

    private static let noMultiSelectionReason = String(localized: "クリップをタップして選んでください")

    private var multiSelectItems: [EditorToolItem] {
        let ids = timeline.multiSelectedClipIDs.filter { id in project.clips.contains(where: { $0.id == id }) }
        let hasSelection = !ids.isEmpty
        let allSelected = ids.count == project.clips.count && !project.clips.isEmpty
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "完了"), systemImage: "checkmark", id: "multi-done") {
            endMultiSelect()
        })
        items.append(EditorToolItem(allSelected ? String(localized: "選択を解除") : String(localized: "すべて選択"),
                                    systemImage: allSelected ? "circle" : "checkmark.circle.fill",
                                    id: "multi-all") {
            if allSelected {
                timeline.multiSelectedClipIDs = []
            } else {
                timeline.multiSelectedClipIDs = Set(project.clips.map { $0.id })
            }
        })
        items.append(EditorToolItem(String(localized: "前へ"), systemImage: "arrow.left", id: "multi-left",
                                    enabled: hasSelection, disabledReason: Self.noMultiSelectionReason) {
            moveMultiSelected(by: -1)
        })
        items.append(EditorToolItem(String(localized: "後ろへ"), systemImage: "arrow.right", id: "multi-right",
                                    enabled: hasSelection, disabledReason: Self.noMultiSelectionReason) {
            moveMultiSelected(by: 1)
        })
        items.append(EditorToolItem(hasSelection ? String(localized: "リップル削除(\(ids.count))") : String(localized: "リップル削除"), systemImage: "trash",
                                    id: "multi-delete", destructive: true,
                                    enabled: hasSelection, disabledReason: Self.noMultiSelectionReason) {
            deleteMultiSelected()
        })
        return items
    }

    private func endMultiSelect() {
        timeline.endMultiSelect()
        selection = nil
    }

    private func moveMultiSelected(by step: Int) {
        let ids = timeline.multiSelectedClipIDs
        guard !ids.isEmpty else { return }
        history.record(project)
        let moved: Bool = project.moveClips(ids: ids, by: step)
        if moved {
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            showToast(step < 0 ? String(localized: "これ以上前には動かせません") : String(localized: "これ以上後ろには動かせません"), style: .warning)
        }
    }

    private func deleteMultiSelected() {
        let ids = timeline.multiSelectedClipIDs
        guard !ids.isEmpty else { return }
        let count = ids.count
        history.record(project)
        timeline.endMultiSelect()
        selection = nil
        project.removeClips(ids: ids)
        showToast(String(localized: "\(count) 本のクリップを削除しました"), undo: true)
    }

    /// クリップを削除(「元に戻す」つきのトースト)
    private func deleteClip(_ clipID: UUID) {
        history.record(project)
        selection = nil
        project.removeClip(id: clipID)
        showToast(String(localized: "削除しました"), undo: true)
    }

    // MARK: - シート

    @ViewBuilder
    private func sheetContent(for sheet: EditorSheet) -> some View {
        switch sheet {
        case .clipDetail(let clipID):
            NavigationStack {
                ClipEditorView(project: project, player: player, clipID: clipID)
            }
        case .multicam(let clipID):
            NavigationStack {
                MulticamEditorView(project: project, player: player, clipID: clipID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了") { activeSheet = nil }
                        }
                    }
            }
        case .subtitles:
            SubtitleEditorView(project: project, player: player)
        case .audio:
            AudioSettingsView(project: project)
        case .export:
            ExportView(project: project)
        case .scopes(let clipID):
            ScopeSheetView(player: player, clip: project.clips.first(where: { $0.id == clipID }))
        case .coverMaker:
            CoverMakerView(project: project)
        case .compare:
            CompareView(project: project, player: player)
        case .autoEdit:
            AutoEditSheetView(project: project,
                              player: player,
                              history: history,
                              onApplied: { afterProjectReplaced() })
        case .slideshow:
            SlideshowSheetView(images: slideshowImages,
                               project: project,
                               player: player,
                               history: history,
                               onApplied: { afterProjectReplaced() })
        case .scriptWriter:
            ScriptWriterSheetView(project: project,
                                  player: player,
                                  history: history,
                                  onNarrationAdded: { id in selection = .narration(id) })
        case .googlePhotos:
            // 選んだ写真・動画は一時ファイルで届く(取り込んだら消す)。シートは自分で閉じる
            GooglePhotosImportView(onPicked: { urls in
                startLocalImport(urls, securityScoped: false, deleteSourcesAfter: true)
            })
        }
    }

    /// おまかせ編集・テンプレート・スライドショーでプロジェクトを置き換えた後の後始末
    private func afterProjectReplaced() {
        selection = nil
        if activePanel != .autoEditTemplates {
            activePanel = nil
        }
        Task { await reloadThumbnails() }
        showToast(String(localized: "適用しました"), undo: true)
    }

    /// PhotosPicker で選んだ写真をアプリ内にコピーして、スライドショーの設定シートを開く
    @MainActor
    private func importSlideshowItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importTotal = items.count
        importDone = 0
        importFraction = nil
        var urls: [URL] = []
        var failures = 0
        for item in items {
            if Task.isCancelled { break }
            do {
                if let photo = try await item.loadTransferable(type: PickedPhoto.self) {
                    urls.append(photo.url)
                } else {
                    failures += 1
                }
            } catch {
                failures += 1
            }
            importDone += 1
        }
        isImporting = false
        importTask = nil
        if Task.isCancelled {
            // キャンセルされたらシートは開かず、コピーした写真も片付ける
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        if urls.isEmpty {
            alertMessage = failures > 0 ? String(localized: "写真を読み込めませんでした(\(failures) 枚)。") : String(localized: "写真を読み込めませんでした。")
            return
        }
        // 一部だけ失敗したときはシートと同時にアラートを出さず、読み込めた写真で進める
        player.pause()
        activePanel = nil
        slideshowImages = urls
        activeSheet = .slideshow
    }

    private var importOverlay: some View {
        let total: Double = Double(max(importTotal, 1))
        // 読み込み中の 1 件の進み具合も足す(iCloud にしかない大きな動画でも止まって見えないように)
        let done: Double = min(Double(importDone) + (importFraction ?? 0), total)
        // 進み具合がわからない間は、0% や 100% で止まった棒ではなく動き続ける表示にする
        // (「ファイル」アプリの項目のダウンロード・コピー中と、写真ライブラリからのダウンロードを終えて動画を準備している間)
        let downloading: Bool = importIsDownloading
        let preparing: Bool = !downloading && (importFraction ?? 0) >= 1
        return ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                // 雲から落ちてくるフィルムを受け止めるロボット(AIWorkingOverlay.swift)
                RobotWorkshop(clip: .importing)
                if downloading || preparing {
                    Group {
                        if downloading {
                            Text("クラウドからダウンロードしています…(大きな動画は数分かかります)")
                        } else {
                            Text("動画を準備しています…")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView(value: done, total: total)
                }
                Text("読み込み中… \(importDone)/\(importTotal)")
                    .font(.callout)
                    .monospacedDigit()
                Button {
                    EditorHaptics.tap()
                    importTask?.cancel()
                } label: {
                    Text("キャンセル")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(width: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// index 件目(importDone と同じ数え方)の読み込みの進み具合を受け取る。
    /// 終わった件から遅れて届いた値は、次の件の進み具合にしない
    private func importProgress(for index: Int) -> MovieImporter.ProgressHandler {
        { fraction in
            guard isImporting, importDone == index else { return }
            importFraction = fraction.isFinite ? min(max(fraction, 0), 1) : nil
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { alertMessage != nil },
            set: { newValue in
                if !newValue {
                    alertMessage = nil
                    alertOffersSettings = false
                }
            }
        )
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 状態

    /// 選択中の対象がまだ存在するか(削除・元に戻すで消えたら選択解除する)
    private var selectionExists: Bool {
        guard let current = selection else { return true }
        switch current {
        case .clip(let clipID):
            return project.index(of: clipID) != nil
        case .subtitle(let cueID):
            return project.subtitles.contains(where: { $0.id == cueID })
        case .bgm:
            return project.audio.bgmURL != nil
        case .overlay(let overlayID):
            return project.overlays.contains(where: { $0.id == overlayID })
        case .narration(let narrationID):
            return project.narration.contains(where: { $0.id == narrationID })
        case .text(let textID):
            return project.textClips.contains(where: { $0.id == textID })
        case .drawing(let drawingID):
            return project.drawings.contains(where: { $0.id == drawingID })
        case .marker(let markerID):
            return project.markers.contains(where: { $0.id == markerID })
        }
    }

    /// 再生位置にあるクリップ
    private var clipIDAtPlayhead: UUID? {
        guard let location = project.locate(timelineTime: player.currentTime),
              location.index < project.clips.count else { return nil }
        return project.clips[location.index].id
    }

    // MARK: - 操作

    /// パネルを開く。開く直前の状態を 1 回だけ記録し、パネル内の変更を 1 回の「元に戻す」で戻せるようにする
    private func openPanel(_ panel: EditorPanel) {
        history.record(project)
        // ✕「キャンセル」で戻す状態
        panelSnapshot = project.snapshot()
        activePanel = panel
        Analytics.shared.track("panel", ["name": Self.analyticsName(of: panel)])
    }

    /// 統計用の名前(言語に依らない enum の名前だけ。中の ID などは落とす)
    static func analyticsName(of value: Any) -> String {
        let text = String(describing: value)
        if let paren = text.firstIndex(of: "(") { return String(text[..<paren]) }
        return text
    }

    private func addSubtitleAtPlayhead() {
        history.record(project)
        let cue = project.addSubtitle(at: player.currentTime)
        selection = .subtitle(cue.id)
    }

    // MARK: テキスト / ステッカー

    /// 再生位置にテキストレイヤーを追加して選択し、テキスト編集パネルを開く
    private func addTextAtPlayhead() {
        let before = project.snapshot()
        history.record(project)
        // 合成のコマに合わせる。合わせないと、いま見えているコマの時刻がテキストの開始より
        // わずかに前になり、プレビューにテキストが出ないことがある
        let start = frameAligned(player.currentTime)
        let clip = TextClip(text: String(localized: "テキスト"), start: start)
        project.textClips.append(clip)
        project.sortTextClips()
        selection = .text(clip.id)
        // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻る
        panelSnapshot = before
        activePanel = .textStyle(clip.id)
        player.seek(to: start)
    }

    /// 合成のコマ(プロジェクトのフレームレート)の境目に切り下げた時刻
    private func frameAligned(_ time: Double) -> Double {
        guard time.isFinite, time > 0 else { return 0 }
        let fps = Double(min(max(project.canvas.frameRate, 1), 120))
        return (time * fps).rounded(.down) / fps
    }

    /// テキストの編集が終わったら、そのテキストの先頭にバーを戻す
    private func rewindToText(of panel: EditorPanel) {
        guard case .textStyle(let textID) = panel,
              let text = project.textClips.first(where: { $0.id == textID }) else { return }
        player.pause()
        player.seek(to: text.start)
    }

    /// 絵文字ステッカーを再生位置に追加して選択する(ステッカーパネルは選択の変化で閉じる)
    private func addSticker(_ emoji: String) {
        history.record(project)
        var clip = TextClip(text: emoji, start: max(0, player.currentTime))
        clip.isSticker = true
        clip.widthRatio = 0.3
        clip.style.sizeRatio = 0.18
        clip.style.bold = false
        clip.style.shadow.enabled = false
        clip.style.backgroundColorHex = nil
        clip.style.strokeColorHex = nil
        project.textClips.append(clip)
        project.sortTextClips()
        selection = .text(clip.id)
    }

    /// 選択中のテキストを複製して直後に置き、複製を選択する
    private func duplicateText(_ textID: UUID) {
        guard let original = project.textClips.first(where: { $0.id == textID }) else { return }
        history.record(project)
        var copy = original
        copy.id = UUID()
        copy.start = original.end
        copy.keyframes = original.keyframes.map { keyframe in
            var k = keyframe
            k.id = UUID()
            return k
        }
        project.textClips.append(copy)
        project.sortTextClips()
        selection = .text(copy.id)
    }

    // MARK: 手書き

    /// 新しい手書きを始める(プレビューにキャンバスを重ね、下部に道具を出す)
    private func startDrawing() {
        player.pause()
        draftStrokes = []
        selection = nil
        // 履歴は「完了」で追加するときに記録する
        activePanel = .drawingCanvas
    }

    /// 描いた線を再生位置の手書きとして追加する
    private func finishDrawing() {
        let strokes = draftStrokes
        draftStrokes = []
        activePanel = nil
        guard !strokes.isEmpty else { return }
        history.record(project)
        let drawing = DrawingClip(start: max(0, player.currentTime), strokes: strokes)
        project.drawings.append(drawing)
        project.drawings.sort { $0.start < $1.start }
        selection = .drawing(drawing.id)
    }

    private func cancelDrawing() {
        draftStrokes = []
        activePanel = nil
    }

    // MARK: マーカー

    /// 再生位置にマーカーを追加して選択し、名前のパネルを開く
    private func addMarkerAtPlayhead() {
        let before = project.snapshot()
        history.record(project)
        let marker = TimelineMarker(time: max(0, player.currentTime), name: "", kind: .note)
        project.markers.append(marker)
        project.sortMarkers()
        selection = .marker(marker.id)
        // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻る
        panelSnapshot = before
        activePanel = .markerName(marker.id)
    }

    // MARK: 章タイトル / テロップ

    /// 再生位置に章タイトルを追加して編集パネルを開く
    private func addTitleCardAtPlayhead() {
        let before = project.snapshot()
        history.record(project)
        let n = project.titleCards.count + 1
        let card = TitleCard(start: max(0, player.currentTime),
                             heading: String(localized: "第\(n)章"),
                             title: String(localized: "タイトル"))
        project.titleCards.append(card)
        selection = nil
        panelSnapshot = before
        activePanel = .titleCard(card.id)
    }

    /// 再生位置にテロップ(ネームプレート)を追加して編集パネルを開く
    private func addLowerThirdAtPlayhead() {
        let before = project.snapshot()
        history.record(project)
        let item = LowerThird(kind: .nameplate,
                              start: max(0, player.currentTime),
                              primary: String(localized: "名前"),
                              secondary: String(localized: "肩書き"))
        project.lowerThirds.append(item)
        selection = nil
        panelSnapshot = before
        activePanel = .lowerThird(item.id)
    }

    /// 章タイトルを削除。残りがあれば次のカードの編集に切り替え、なければパネルを閉じる
    private func deleteTitleCard(_ cardID: UUID) {
        history.record(project)
        project.titleCards.removeAll { $0.id == cardID }
        if let next = project.titleCards.sorted(by: { $0.start < $1.start }).first {
            activePanel = .titleCard(next.id)
        } else {
            activePanel = nil
        }
    }

    /// テロップを削除。残りがあれば次のテロップの編集に切り替え、なければパネルを閉じる
    private func deleteLowerThird(_ itemID: UUID) {
        history.record(project)
        project.lowerThirds.removeAll { $0.id == itemID }
        if let next = project.lowerThirds.sorted(by: { $0.start < $1.start }).first {
            activePanel = .lowerThird(next.id)
        } else {
            activePanel = nil
        }
    }

    // MARK: オーバーレイ

    /// 選択中のオーバーレイを複製して直後に置き、複製を選択する
    private func duplicateOverlay(_ overlayID: UUID) {
        guard let i = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return }
        history.record(project)
        let original = project.overlays[i]
        var copy = original.duplicated()
        copy.start = original.end
        project.overlays.insert(copy, at: i + 1)
        project.sortOverlays()
        selection = .overlay(copy.id)
    }

    /// PhotosPicker で選んだ動画・写真をオーバーレイとして再生位置に追加する
    @MainActor
    private func importOverlayItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importTotal = items.count
        importDone = 0
        importFraction = nil
        importCopiedPhotoMedia = false
        var failures: [String] = []
        var needsPhotoSettings = false
        var recorded = false
        var lastAdded: UUID?
        var before: ProjectSnapshot?
        for item in items {
            // キャンセルされたら、追加済みの分は残してやめる
            if Task.isCancelled { break }
            importFraction = nil
            let progress = importProgress(for: importDone)
            do {
                var overlay: OverlayClip?
                if Self.looksLikeMovie(item) {
                    let movieURL = try await importMovieURL(item, onProgress: progress)
                    var video = try await MediaStore.makeOverlay(fromVideo: movieURL)
                    OverlayPreset.bRollFull.apply(to: &video)
                    overlay = video
                } else if let photo = try? await item.loadTransferable(type: PickedPhoto.self) {
                    var image = try MediaStore.makeImageOverlay(from: photo.url)
                    image.duration = 4
                    overlay = image
                } else {
                    // 種類が判定できなかった場合の保険
                    let movieURL = try await importMovieURL(item, onProgress: progress)
                    var video = try await MediaStore.makeOverlay(fromVideo: movieURL)
                    OverlayPreset.bRollFull.apply(to: &video)
                    overlay = video
                }
                guard var added = overlay else {
                    failures.append(String(localized: "動画・写真のデータを取得できませんでした。"))
                    importDone += 1
                    continue
                }
                added.start = max(0, player.currentTime)
                if !recorded {
                    before = project.snapshot()
                    history.record(project)
                    recorded = true
                }
                project.overlays.append(added)
                project.sortOverlays()
                lastAdded = added.id
            } catch {
                // キャンセルは失敗として数えない
                if error is CancellationError || Task.isCancelled { break }
                if MovieImporterError.isPhotoAccessError(error) { needsPhotoSettings = true }
                failures.append(error.localizedDescription)
            }
            importDone += 1
        }
        let cancelled = Task.isCancelled
        isImporting = false
        importFraction = nil
        importTask = nil
        if let lastAdded {
            selection = .overlay(lastAdded)
            // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻せる
            panelSnapshot = before
            activePanel = .overlayPlacement(lastAdded)
        }
        if !failures.isEmpty, !cancelled {
            alertOffersSettings = needsPhotoSettings
            alertMessage = String(localized: "\(failures.count)件の素材を読み込めませんでした。\n") + failures.joined(separator: "\n")
        } else if lastAdded != nil, importCopiedPhotoMedia {
            showToast(Self.photoCopiedNote(), style: .info)
        }
    }

    /// 選んだ項目が動画らしいか
    private static func looksLikeMovie(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) })
    }

    /// 写真から静止画クリップを作る(標準 4 秒)
    private func makeStillClip(from url: URL) throws -> Clip {
        let name = MediaStore.displayName(for: url, fallback: String(localized: "写真"))
        guard let size = MediaStore.imagePixelSize(of: url) else {
            throw MediaStoreError.unreadableImage(name)
        }
        let thumb = MediaStore.makeImageClipThumbnail(url: url, maxPixel: 320)
        var clip = Clip(url: url,
                        duration: MediaStore.imageSourceDuration,
                        naturalSize: size,
                        preferredTransform: .identity,
                        hasAudio: false,
                        thumbnail: thumb,
                        name: name)
        clip.stillImageURL = url
        clip.startTime = 0
        clip.endTime = 4
        return clip
    }

    // MARK: 逆再生 / フリーズ / 自動補正

    /// 逆再生の切り替え。逆再生ファイルがまだなければ作ってから有効にする(解除してもファイルは残す)
    private func toggleReverse(_ clipID: UUID) {
        guard let i = project.index(of: clipID) else { return }
        let clip = project.clips[i]
        if clip.isReversed {
            history.record(project)
            project.clips[i].isReversed = false
            return
        }
        if clip.reversedURL != nil {
            history.record(project)
            project.clips[i].isReversed = true
            return
        }
        player.pause()
        mediaToolTask?.cancel()
        mediaToolTask = Task { @MainActor in
            mediaToolProgress = ClipFXProgress(title: String(localized: "逆再生の動画を作成中"), fraction: 0)
            do {
                // 元素材全体を逆再生にする(トリミング範囲を後で変えても使えるように)
                let url = try await MediaTools.reversedCopy(of: clip.url, start: 0, end: clip.duration, progress: { value in
                    DispatchQueue.main.async {
                        if mediaToolProgress != nil {
                            mediaToolProgress?.fraction = value
                        }
                    }
                })
                mediaToolProgress = nil
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard let j = project.index(of: clipID) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                history.record(project)
                project.clips[j].reversedURL = url
                project.clips[j].isReversed = true
            } catch is CancellationError {
                mediaToolProgress = nil
            } catch {
                mediaToolProgress = nil
                if !Task.isCancelled {
                    alertMessage = String(localized: "逆再生の動画を作成できませんでした。\n\(error.localizedDescription)")
                }
            }
            mediaToolTask = nil
        }
    }

    /// 再生位置のコマを静止画クリップにして、クリップを分割した間に差し込む
    private func freezeFrame(_ clipID: UUID) {
        guard let location = project.locate(timelineTime: player.currentTime),
              location.index < project.clips.count,
              project.clips[location.index].id == clipID else {
            showToast(String(localized: "再生位置をクリップの上に合わせてください"), style: .warning)
            return
        }
        let clip = project.clips[location.index]
        let sourceTime = min(max(location.sourceTime, clip.startTime), clip.endTime)
        player.pause()
        mediaToolTask?.cancel()
        mediaToolTask = Task { @MainActor in
            mediaToolProgress = ClipFXProgress(title: String(localized: "フリーズフレームを作成中"), fraction: nil)
            do {
                let imageURL = try await MediaTools.freezeFrameImage(from: clip.url, at: sourceTime)
                mediaToolProgress = nil
                if Task.isCancelled { return }
                let size = MediaStore.imagePixelSize(of: imageURL) ?? clip.displaySize
                let thumb = MediaStore.makeImageClipThumbnail(url: imageURL, maxPixel: 320)
                var still = Clip(url: imageURL,
                                 duration: 3600,
                                 naturalSize: size,
                                 preferredTransform: .identity,
                                 hasAudio: false,
                                 thumbnail: thumb,
                                 name: String(localized: "フレーム保持"))
                still.stillImageURL = imageURL
                still.startTime = 0
                still.endTime = 2
                still.filter = clip.filter

                guard let i = project.index(of: clipID) else { return }
                history.record(project)
                let minimum = 0.2
                if sourceTime > clip.startTime + minimum, sourceTime < clip.endTime - minimum,
                   project.splitClip(id: clipID, atSourceTime: sourceTime) {
                    project.clips.insert(still, at: i + 1)
                } else if sourceTime <= clip.startTime + minimum {
                    project.clips.insert(still, at: i)
                } else {
                    project.clips.insert(still, at: i + 1)
                }
                selection = .clip(still.id)
                showToast(String(localized: "静止画にしました"), undo: true)
            } catch is CancellationError {
                mediaToolProgress = nil
            } catch {
                mediaToolProgress = nil
                if !Task.isCancelled {
                    alertMessage = String(localized: "静止画を作成できませんでした。\n\(error.localizedDescription)")
                }
            }
            mediaToolTask = nil
        }
    }

    /// サムネイルから明るさ・コントラストなどを推定して色調整に反映する
    private func autoEnhance(_ clipID: UUID) {
        Task { @MainActor in
            guard let i = project.index(of: clipID) else { return }
            let clip = project.clips[i]
            var image = clip.thumbnail
            if image == nil {
                if let still = clip.stillImageURL {
                    image = MediaStore.makeImageClipThumbnail(url: still, maxPixel: 320)
                } else {
                    image = await MediaStore.thumbnail(for: clip.url, at: clip.startTime, maxPixel: 320)
                }
            }
            guard let image else {
                alertMessage = String(localized: "サムネイルを取得できなかったため、自動補正できませんでした。")
                return
            }
            let adjustments = FilterEngine.autoEnhanceAdjustments(for: image)
            guard let j = project.index(of: clipID) else { return }
            let before = project.snapshot()
            history.record(project)
            project.clips[j].filter.adjustments = adjustments
            // 結果を確認・微調整できるよう色調整パネルを開く(履歴は記録済み。✕「キャンセル」で補正前に戻る)
            panelSnapshot = before
            activePanel = .colorAdjust(clipID)
            showToast(String(localized: "自動補正しました"), undo: true)
        }
    }

    // MARK: 置き換え / 音声抽出

    /// 選択中のクリップの素材を別の動画に置き換える(トリミング位置・速度・フィルタなどは保つ)
    @MainActor
    private func replaceClip(_ clipID: UUID, with item: PhotosPickerItem) async {
        isImporting = true
        importTotal = 1
        importDone = 0
        importFraction = nil
        defer {
            isImporting = false
            importFraction = nil
            importTask = nil
        }
        let progress = importProgress(for: 0)
        // 取り込んだファイル(キャンセルしたときに消す。置き換えはいつもアプリ内へのコピーなので消してよい)
        var importedURL: URL?
        do {
            // 動画でも写真でも置き換えられる(写真は静止画クリップになり、長さは元のクリップと同じ)
            let fresh: Clip
            if Self.looksLikeMovie(item) {
                let url = try await MovieImporter.importMovie(item, onProgress: progress)
                importedURL = url
                fresh = try await MediaStore.makeClip(from: url)
            } else if let photo = try? await item.loadTransferable(type: PickedPhoto.self) {
                importedURL = photo.url
                fresh = try makeStillClip(from: photo.url)
            } else {
                let url = try await MovieImporter.importMovie(item, onProgress: progress)
                importedURL = url
                fresh = try await MediaStore.makeClip(from: url)
            }
            // キャンセルされたら置き換えず、取り込んだファイルも消す
            if Task.isCancelled {
                Self.removeUnusedFiles([importedURL, fresh.url, fresh.stillImageURL])
                return
            }
            guard let i = project.index(of: clipID) else { return }
            let old = project.clips[i]
            var replaced = Clip(id: old.id,
                                url: fresh.url,
                                duration: fresh.duration,
                                naturalSize: fresh.naturalSize,
                                preferredTransform: fresh.preferredTransform,
                                hasAudio: fresh.hasAudio,
                                thumbnail: fresh.thumbnail,
                                name: fresh.name)
            replaced.stillImageURL = fresh.stillImageURL
            // クリップの長さはそのまま。新しい動画が長ければ同じ位置から同じ長さだけ使い、
            // 短ければ全部使う(そのぶん短くなる)
            let length = max(0.2, old.endTime - old.startTime)
            var shortened = false
            if fresh.isStill {
                replaced.startTime = 0
                replaced.endTime = max(0.2, min(fresh.duration, length))
            } else if fresh.duration >= length {
                replaced.startTime = min(max(0, old.startTime), fresh.duration - length)
                replaced.endTime = replaced.startTime + length
            } else {
                replaced.startTime = 0
                replaced.endTime = fresh.duration
                shortened = true
            }
            replaced.speed = old.speed
            replaced.filter = old.filter
            replaced.multicam = old.multicam
            replaced.isMuted = old.isMuted && fresh.hasAudio
            replaced.audio = old.audio
            replaced.transition = old.transition
            replaced.animation = old.animation
            replaced.geometry = old.geometry
            replaced.speedCurve = old.speedCurve
            // 素材に依存しない設定は引き継ぐ(リフレーム・手ぶれ補正の解析結果は素材ごとなので引き継がない)
            replaced.mask = old.mask
            replaced.enhance = old.enhance
            history.record(project)
            project.clips[i] = replaced
            importDone = 1
            if shortened {
                showToast(String(localized: "置き換えました(新しい動画が短いため、クリップも短くなりました)"), undo: true)
            } else if !fresh.isStill, fresh.duration - length > 0.05 {
                // 長さはそのままで、どこを使うかを細かく合わせられるように
                showToast(String(localized: "置き換えました。使う部分を調整できます"), undo: true)
                openPanel(.slip(clipID))
            } else {
                showToast(String(localized: "置き換えました"), undo: true)
            }
        } catch {
            // キャンセルはお知らせを出さない(取り込み済みのファイルは使わないので消す)
            if error is CancellationError || Task.isCancelled {
                Self.removeUnusedFiles([importedURL])
                return
            }
            alertOffersSettings = MovieImporterError.isPhotoAccessError(error)
            alertMessage = String(localized: "動画を置き換えられませんでした。\n\(error.localizedDescription)")
        }
    }

    /// 使わなくなった取り込みファイルを消す(nil と重複は飛ばす)
    private static func removeUnusedFiles(_ urls: [URL?]) {
        var seen = Set<String>()
        for url in urls.compactMap({ $0 }) where seen.insert(url.path).inserted {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 動画から音声だけを取り出してナレーションとして再生位置に追加する
    @MainActor
    private func extractAudio(from item: PhotosPickerItem) async {
        mediaToolProgress = ClipFXProgress(title: String(localized: "音声を取り出しています"), fraction: nil)
        defer { mediaToolProgress = nil }
        // 取り込んだ動画のコピーと、取り出した音声(キャンセル・失敗したときに消す)
        var movieURL: URL?
        var audioURL: URL?
        do {
            // iCloud からのダウンロード中は進み具合を出す
            let movie = try await MovieImporter.importMovie(item, onProgress: { fraction in
                if mediaToolProgress != nil {
                    mediaToolProgress?.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : nil
                }
            })
            movieURL = movie
            mediaToolProgress?.fraction = nil
            if Task.isCancelled {
                // 取り出し元の動画コピーは使わない
                Self.removeUnusedFiles([movieURL])
                return
            }
            let extracted = try await MediaTools.extractAudio(from: movie, start: nil, end: nil)
            audioURL = extracted
            var url = extracted
            if !url.path.hasPrefix(MediaStore.mediaDirectory.path) {
                url = try MediaStore.copyIntoMediaDirectory(extracted)
                audioURL = url
                if url != extracted {
                    try? FileManager.default.removeItem(at: extracted)
                }
            }
            // 取り出し元の動画コピーは不要になる
            if movie != url {
                try? FileManager.default.removeItem(at: movie)
            }
            movieURL = nil
            let asset = AVURLAsset(url: url)
            let seconds = try await asset.load(.duration).seconds
            let duration = (seconds.isFinite && seconds > 0) ? seconds : 1
            // 取り出しの最後にキャンセルされたときも、ナレーションは追加しない
            if Task.isCancelled {
                Self.removeUnusedFiles([audioURL])
                return
            }
            history.record(project)
            let clip = NarrationClip(url: url,
                                     name: MediaStore.displayName(for: url, fallback: String(localized: "抽出した音声")),
                                     start: max(0, player.currentTime),
                                     duration: duration)
            project.narration.append(clip)
            project.sortNarration()
            selection = .narration(clip.id)
        } catch {
            // 途中までに作ったファイルは使わないので消す
            Self.removeUnusedFiles([movieURL, audioURL])
            // キャンセルはお知らせを出さない
            if error is CancellationError || Task.isCancelled { return }
            alertOffersSettings = MovieImporterError.isPhotoAccessError(error)
            alertMessage = String(localized: "音声を取り出せませんでした。\n\(error.localizedDescription)")
        }
    }

    // MARK: 無音カット

    private func startSilenceCut() {
        audioToolTask?.cancel()
        audioToolTask = Task { @MainActor in
            await runSilenceCut()
            audioToolTask = nil
        }
    }

    /// 音声のある(ミュートでない)全クリップから無音部分を取り除き、残す範囲ごとにクリップを分割する
    @MainActor
    private func runSilenceCut() async {
        let targets = project.clips.filter { $0.hasAudio && !$0.isMuted && !$0.isStill }
        guard !targets.isEmpty else {
            alertMessage = String(localized: "音声のあるクリップがありません。")
            return
        }
        player.pause()
        audioToolProgress = AudioToolProgress(title: String(localized: "無音を検出中"), done: 0, total: targets.count)

        var kept: [UUID: [(start: Double, end: Double)]] = [:]
        var failures: [String] = []
        var cancelled = false
        for (i, clip) in targets.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                kept[clip.id] = try await AudioAnalysis.keptRanges(for: clip)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failures.append("\(clip.name): \(error.localizedDescription)")
            }
            audioToolProgress?.done = i + 1
        }
        audioToolProgress = nil
        if cancelled {
            showToast(String(localized: "無音カットをキャンセルしました"), style: .info)
            return
        }

        // 残す範囲ごとにクリップを組み立て直す(最初の範囲は元の ID を保つ)
        let tolerance = 0.01
        var newClips: [Clip] = []
        var removedCount = 0
        var removedOutputSeconds = 0.0
        for clip in project.clips {
            guard let ranges = kept[clip.id], !ranges.isEmpty else {
                newClips.append(clip)
                continue
            }
            var gaps = max(0, ranges.count - 1)
            if let first = ranges.first, first.start > clip.startTime + tolerance { gaps += 1 }
            if let last = ranges.last, last.end < clip.endTime - tolerance { gaps += 1 }
            guard gaps > 0 else {
                newClips.append(clip)
                continue
            }
            let keptSource = ranges.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            removedOutputSeconds += max(0, clip.trimmedDuration - keptSource) / max(clip.speed, 0.01)
            removedCount += gaps
            for (j, range) in ranges.enumerated() {
                var piece = (j == 0) ? clip : clip.duplicated()
                piece.startTime = range.start
                piece.endTime = range.end
                newClips.append(piece)
            }
        }

        guard removedCount > 0 else {
            if failures.isEmpty {
                showToast(String(localized: "無音部分は見つかりませんでした"), style: .info)
            } else {
                alertMessage = String(localized: "無音部分は見つかりませんでした。\n解析できなかったクリップ:\n") + failures.joined(separator: "\n")
            }
            return
        }

        history.record(project)
        project.clips = newClips
        let secondsText = String(format: "%.1f", removedOutputSeconds)
        showToast(String(localized: "\(removedCount) か所・\(secondsText) 秒の無音を詰めました"), undo: true)
        if !failures.isEmpty {
            alertMessage = String(localized: "解析できなかったクリップ:\n") + failures.joined(separator: "\n")
        }
    }

    // MARK: 音量そろえ

    private func startNormalize(clipIDs: [UUID], narrationIDs: [UUID]) {
        audioToolTask?.cancel()
        audioToolTask = Task { @MainActor in
            await runNormalize(clipIDs: clipIDs, narrationIDs: narrationIDs)
            audioToolTask = nil
        }
    }

    /// 指定したクリップ・ナレーションの音の大きさを測り、聞きやすい大きさになるようゲインを設定する
    @MainActor
    private func runNormalize(clipIDs: [UUID], narrationIDs: [UUID]) async {
        let clipTargets = project.clips.filter { clipIDs.contains($0.id) && $0.hasAudio && !$0.isStill }
        let narrationTargets = project.narration.filter { narrationIDs.contains($0.id) }
        let total = clipTargets.count + narrationTargets.count
        guard total > 0 else {
            alertMessage = String(localized: "音声のあるクリップやナレーションがありません。")
            return
        }
        player.pause()
        audioToolProgress = AudioToolProgress(title: String(localized: "音量を測定中"), done: 0, total: total)

        var clipGains: [UUID: Float] = [:]
        var narrationGains: [UUID: Float] = [:]
        var failures: [String] = []
        var cancelled = false
        var done = 0

        for clip in clipTargets {
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                let measurement = try await LoudnessAnalyzer.measure(url: clip.url,
                                                                     start: clip.startTime,
                                                                     end: clip.endTime)
                clipGains[clip.id] = LoudnessAnalyzer.normalizationGain(for: measurement)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failures.append("\(clip.name): \(error.localizedDescription)")
            }
            done += 1
            audioToolProgress?.done = done
        }

        if !cancelled {
            for item in narrationTargets {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                do {
                    let measurement = try await LoudnessAnalyzer.measure(url: item.url,
                                                                         start: item.sourceStart,
                                                                         end: item.sourceEnd)
                    narrationGains[item.id] = LoudnessAnalyzer.normalizationGain(for: measurement)
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
                done += 1
                audioToolProgress?.done = done
            }
        }

        audioToolProgress = nil
        if cancelled {
            showToast(String(localized: "音量そろえをキャンセルしました"), style: .info)
            return
        }
        guard !clipGains.isEmpty || !narrationGains.isEmpty else {
            alertMessage = String(localized: "音量を測定できませんでした。\n") + failures.joined(separator: "\n")
            return
        }

        history.record(project)
        var clips = project.clips
        for i in clips.indices {
            if let gain = clipGains[clips[i].id] {
                clips[i].audio.gain = gain
            }
        }
        project.clips = clips
        var narration = project.narration
        for i in narration.indices {
            if let gain = narrationGains[narration[i].id] {
                narration[i].gain = gain
            }
        }
        project.narration = narration

        let count = clipGains.count + narrationGains.count
        showToast(String(localized: "\(count) 件の音量をそろえました"), undo: true)
        if !failures.isEmpty {
            alertMessage = String(localized: "測定できなかった素材:\n") + failures.joined(separator: "\n")
        }
    }

    private func splitClip(_ clipID: UUID) {
        // 選んでいるクリップの中で、再生位置(トランジションの重なり・速度カーブを反映)を元素材の時刻にする
        guard let clip = project.clips.first(where: { $0.id == clipID }),
              let sourceTime = project.sourceTime(timelineTime: player.currentTime, inClip: clipID) else {
            showToast(String(localized: "再生位置をクリップの上に合わせてください"), style: .warning)
            return
        }
        let minimum = 0.2
        guard sourceTime > clip.startTime + minimum,
              sourceTime < clip.endTime - minimum else {
            showToast(String(localized: "クリップの端に近すぎます。端から0.2秒以上離してください"), style: .warning)
            return
        }
        history.record(project)
        project.splitClip(id: clipID, atSourceTime: sourceTime)
        showToast(String(localized: "スプリットしました"), undo: true)
    }

    // MARK: 保存 / プロジェクトの切り替え

    /// 変更内容を保存し、一覧のメタデータとサムネイルを更新する(書き込みはまとめて行われる)
    private func persist(_ snapshot: ProjectSnapshot) {
        if isLoadingPhotoMedia { return }
        if !timeline.pacing.isEmpty, Self.clipsKey(snapshot) != pacingClipsKey {
            // クリップを編集したら結果は古くなるので帯を消す
            timeline.pacing = []
            timeline.pacingChecks = []
        }
        isDirty = true
        ProjectStore.scheduleSave(snapshot, projectID: projectID)
        ProjectLibrary.shared.touch(id: projectID,
                                    duration: snapshot.totalDuration,
                                    clipCount: snapshot.clips.count)
        if let image = snapshot.clips.first?.thumbnail {
            ProjectStore.scheduleThumbnail(image, projectID: projectID)
        } else if snapshot.clips.isEmpty {
            ProjectStore.deleteThumbnail(projectID: projectID)
        }
    }

    /// いま保存してからプロジェクト一覧へ戻る
    private func closeProject() {
        player.pause()
        mediaToolTask?.cancel()
        analysis.cancel()
        activePanel = nil
        activeSheet = nil
        selection = nil
        if isLoadingPhotoMedia {
            // まだ読み込み終わっていない(保存すると空の内容で上書きしてしまう)
            onClose()
            return
        }
        let snapshot = project.snapshot()
        ProjectStore.saveNow(snapshot, projectID: projectID)
        if snapshot.clips.isEmpty {
            ProjectStore.deleteThumbnail(projectID: projectID)
        } else if let image = snapshot.clips.first?.thumbnail {
            ProjectStore.saveThumbnail(image, projectID: projectID)
        }
        if isDirty {
            ProjectLibrary.shared.touch(id: projectID,
                                        duration: snapshot.totalDuration,
                                        clipCount: snapshot.clips.count)
        }
        ProjectLibrary.shared.flush()
        onClose()
    }

    /// このプロジェクトの内容をすべて消す(一覧からは消さない)。空になった内容は onChange 経由で保存される
    private func clearProject() {
        player.pause()
        mediaToolTask?.cancel()
        analysis.cancel()
        activePanel = nil
        activeSheet = nil
        selection = nil
        draftStrokes = []
        // 写真ライブラリから読み出せずに保留していたクリップも消す(残すと保存のときに書き戻される)
        ProjectStore.discardHeldUnresolvedItems(projectID: projectID)
        project.restore(ProjectSnapshot(clips: [],
                                        subtitles: [],
                                        subtitleStyle: SubtitleStyle(),
                                        audio: AudioSettings(),
                                        canvas: CanvasSettings()))
        history.clear()
        player.seek(to: 0)
    }

    /// 画面を開いたとき(初回だけ保存済みの内容を復元する)
    @MainActor
    private func handleAppear() {
        // 読み込んだフォントをテキスト描画の前に登録しておく(起動時にも呼ばれるが、念のため)
        MediaTools.registerStoredFonts()
        if !didRestore {
            didRestore = true
            let photoReferences: [String] = ProjectStore.photoReferences(projectID: projectID)
            if photoReferences.isEmpty {
                restoreSavedProject()
            } else {
                // 写真ライブラリを参照している動画は、読み出せるようにしてから開く
                isLoadingPhotoMedia = true
                showToast(String(localized: "写真ライブラリから動画を読み込んでいます…"))
                Task { @MainActor in
                    let missing: [String] = await PhotoMediaResolver.prepare(references: photoReferences)
                    restoreSavedProject()
                    isLoadingPhotoMedia = false
                    if !missing.isEmpty {
                        // 写真へのアクセスを許可していない・選んだ写真だけのときは、設定アプリへの入り口を出す
                        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        alertOffersSettings = status == .denied || status == .limited
                        alertMessage = String(localized: "写真ライブラリに見つからない動画が \(missing.count) 本ありました。写真アプリで削除したか、写真へのアクセスが許可されていない可能性があります(設定アプリの「Video Mania」→「写真」で「フルアクセス」を選んでください)。")
                    }
                }
            }
        }
        player.update(with: project.snapshot())
        // 共有で受け取った動画・写真がないか見る(一覧の「新しいプロジェクトで編集」から開いたときは、ここで取り込む)
        IncomingMediaCenter.shared.refresh()
        checkIncomingMedia()
    }

    /// 保存済みの内容を読み込んで表示する
    @MainActor
    private func restoreSavedProject() {
        if let saved = ProjectStore.load(projectID: projectID) {
            project.restore(saved)
            restoredSnapshot = project.snapshot()
            if !saved.isEmpty {
                Task { await reloadThumbnails() }
            }
        }
        player.update(with: project.snapshot())
    }

    /// このプロジェクトの動画の置き場所
    private var mediaMode: ProjectMediaMode {
        ProjectLibrary.shared.project(id: projectID)?.effectiveMediaMode ?? .appCopy
    }

    /// 動画を取り込む。「写真ライブラリから参照」なら写真ライブラリの動画をそのまま使い、
    /// 参照できない動画(スローモーションなど)や「アプリに取り込む」ではアプリにコピーする
    @MainActor
    private func importMovieURL(_ item: PhotosPickerItem, onProgress: MovieImporter.ProgressHandler? = nil) async throws -> URL {
        // キャンセル後に写真へのアクセスの許可を求めたりしない
        try Task.checkCancellation()
        guard mediaMode == .photoLibrary, let id = item.itemIdentifier else {
            return try await MovieImporter.importMovie(item, onProgress: onProgress)
        }
        if let url = await PhotoMediaResolver.resolve(assetID: id, onProgress: onProgress) {
            return url
        }
        try Task.checkCancellation()
        let url = try await MovieImporter.importMovie(item, onProgress: onProgress)
        // 参照できずにアプリへ取り込んだ(読み込みが終わったらトーストで伝える)
        importCopiedPhotoMedia = true
        return url
    }

    /// 「写真ライブラリから参照」なのにアプリへ取り込んだときのお知らせ
    private static func photoCopiedNote() -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .limited || status == .denied || status == .restricted {
            return String(localized: "写真へのアクセスが制限されているため、動画をアプリに取り込みました")
        }
        return String(localized: "スローモーションなど参照できない動画は、アプリに取り込みました")
    }

    /// 復元したクリップのサムネイルを読み直す(保存ファイルには画像を含めないため)
    @MainActor
    private func reloadThumbnails() async {
        for clip in project.clips where clip.thumbnail == nil {
            let image: UIImage?
            if let still = clip.stillImageURL {
                image = MediaStore.makeImageClipThumbnail(url: still, maxPixel: 240)
            } else {
                image = await MediaStore.thumbnail(for: clip.url, at: clip.startTime, maxPixel: 240)
            }
            if let i = project.index(of: clip.id) {
                project.clips[i].thumbnail = image
            }
        }
    }

    @MainActor
    private func importItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importTotal = items.count
        importDone = 0
        importFraction = nil
        importCopiedPhotoMedia = false
        var failures: [String] = []
        var needsPhotoSettings = false
        var recorded = false
        var added = 0
        // 差し込む位置: 再生位置のクリップの後ろ(末尾の「+」からのときと、クリップが無いときは末尾)
        var insertAt: Int? = nil
        if !importAppendsAtEnd, !project.clips.isEmpty,
           let location = project.locate(timelineTime: player.currentTime), location.index < project.clips.count {
            insertAt = location.index + 1
        }
        importAppendsAtEnd = false
        var firstAddedID: UUID? = nil
        for item in items {
            // キャンセルされたら、追加済みの分は残してやめる
            if Task.isCancelled { break }
            importFraction = nil
            let progress = importProgress(for: importDone)
            do {
                let clip: Clip
                if Self.looksLikeMovie(item) {
                    let movieURL = try await importMovieURL(item, onProgress: progress)
                    clip = try await MediaStore.makeClip(from: movieURL)
                } else if let photo = try? await item.loadTransferable(type: PickedPhoto.self) {
                    // 写真は静止画クリップになる
                    clip = try makeStillClip(from: photo.url)
                } else {
                    // 種類が判定できなかった場合の保険
                    let movieURL = try await importMovieURL(item, onProgress: progress)
                    clip = try await MediaStore.makeClip(from: movieURL)
                }
                if !recorded {
                    history.record(project)
                    recorded = true
                }
                if let i = insertAt, i <= project.clips.count {
                    project.clips.insert(clip, at: i)
                    insertAt = i + 1
                } else {
                    project.clips.append(clip)
                }
                if firstAddedID == nil { firstAddedID = clip.id }
                added += 1
            } catch {
                // キャンセルは失敗として数えない
                if error is CancellationError || Task.isCancelled { break }
                if MovieImporterError.isPhotoAccessError(error) { needsPhotoSettings = true }
                // MovieImporter / MediaStore のエラーは日本語の説明(LocalizedError)を持つ
                failures.append(error.localizedDescription)
            }
            importDone += 1
        }
        let cancelled = Task.isCancelled
        isImporting = false
        importFraction = nil
        importTask = nil
        if !failures.isEmpty, !cancelled {
            alertOffersSettings = needsPhotoSettings
            alertMessage = String(localized: "\(failures.count)件の動画・写真を読み込めませんでした。\n") + failures.joined(separator: "\n")
        } else if added > 0 {
            if let id = firstAddedID { selection = .clip(id) }
            if importCopiedPhotoMedia {
                // 写真ライブラリから参照できずにアプリへ取り込んだことを伝える(元に戻すも出す)
                showToast(Self.photoCopiedNote(), style: .info, undo: true)
            } else {
                showToast(insertAt != nil
                          ? String(localized: "再生位置の後ろに \(added)件を差し込みました")
                          : String(localized: "\(added)件を追加しました"), undo: true)
            }
        }
    }

    // MARK: 端末にあるファイルの取り込み(「ファイル」アプリ・Google フォト・共有で受け取ったもの)

    /// 「ファイル」アプリで選んだ動画・写真を取り込む
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            startLocalImport(urls, securityScoped: true, deleteSourcesAfter: false)
        case .failure(let error):
            alertMessage = String(localized: "ファイルを開けませんでした。\n\(error.localizedDescription)")
        }
    }

    /// importLocalFiles を「キャンセル」で止められるように importTask で始める
    private func startLocalImport(_ urls: [URL], securityScoped: Bool, deleteSourcesAfter: Bool) {
        guard !urls.isEmpty else { return }
        guard !isImporting else {
            // 取り込めないので、Google フォトの一時ファイルは残さない
            // (共有で受け取ったファイルは残して IncomingMediaCenter に返す。あとでまた聞く)
            if deleteSourcesAfter {
                let incoming: [URL] = urls.filter { LocalMediaImport.isInIncomingInbox($0) }
                IncomingMediaCenter.shared.giveBack(incoming)
                removeImportSources(urls.filter { !LocalMediaImport.isInIncomingInbox($0) })
            }
            return
        }
        importTask = Task {
            await importLocalFiles(urls, securityScoped: securityScoped, deleteSourcesAfter: deleteSourcesAfter)
        }
    }

    /// すでに端末にあるファイル(「ファイル」アプリ・Google フォト・共有で受け取ったもの)を取り込む。
    /// アプリの Media フォルダにコピーし(共有で受け取ったファイルは移し)、動画はクリップ、写真は静止画クリップにして
    /// importItems と同じ位置に差し込む。
    /// - securityScoped: 「ファイル」アプリで選んだファイル(読むあいだだけアクセスを許可してもらう。
    ///   Google ドライブなどの端末にまだないファイルは、ダウンロードが終わるのを待ってからコピーする)
    /// - deleteSourcesAfter: 元のファイルを消す(Google フォトの一時ファイル・共有で受け取ったファイル)。
    ///   共有で受け取ったファイルは 1 件済むごとに消し(途中でアプリが終了しても、取り込み済みのものをまた聞かないように)、
    ///   キャンセルで取り込まなかったものは IncomingMediaCenter に返す
    @MainActor
    private func importLocalFiles(_ urls: [URL], securityScoped: Bool, deleteSourcesAfter: Bool) async {
        isImporting = true
        importTotal = urls.count
        importDone = 0
        importFraction = nil
        importIsDownloading = false
        importCopiedPhotoMedia = false
        // 共有で受け取ったファイルか(Media フォルダへ移したあとはパスで判定できないことがあるので、先に決めておく)
        let incomingFlags: [Bool] = urls.map { deleteSourcesAfter && LocalMediaImport.isInIncomingInbox($0) }
        var failures: [String] = []
        var recorded = false
        var added = 0
        // 差し込む位置: 再生位置のクリップの後ろ(末尾の「+」からのときと、クリップが無いときは末尾)
        var insertAt: Int? = nil
        if !importAppendsAtEnd, !project.clips.isEmpty,
           let location = project.locate(timelineTime: player.currentTime), location.index < project.clips.count {
            insertAt = location.index + 1
        }
        importAppendsAtEnd = false
        var firstAddedID: UUID? = nil
        // 取り込みを終えた(または読み込めなかった)ファイルの数。先頭からこの数だけが済んでいる
        var processed = 0
        for (index, url) in urls.enumerated() {
            // キャンセルされたら、追加済みの分は残してやめる
            if Task.isCancelled { break }
            importFraction = nil
            let isIncoming: Bool = incomingFlags[index]
            // 共有で受け取ったファイル・Google フォトの一時ファイルは "<NNN>-<元の名前>"(先頭の番号は外す)
            let fileName: String = LocalMediaImport.storedFileName(for: url, stripsNumberPrefix: deleteSourcesAfter)
            // Media フォルダに置いたファイル(クリップにできなかったときは消すか、元の場所に戻す)
            var copied: URL? = nil
            // 共有で受け取ったファイルを Media フォルダへ移した(取り込まなかったときは元の場所に戻す)
            var movedFromInbox = false
            do {
                let destination: URL
                if isIncoming {
                    // 共有で受け取ったファイルは移す(コピーより速く、空き容量も要らない。移せなければコピーする)
                    let stored = try await LocalMediaImport.moveIntoMediaDirectory(url, fileName: fileName)
                    destination = stored.url
                    movedFromInbox = stored.moved
                } else {
                    // 「ファイル」アプリの項目は、端末にないとダウンロードを待つ(進み具合はわからないので、動き続ける表示にする)
                    importIsDownloading = securityScoped
                    defer { importIsDownloading = false }
                    destination = try await LocalMediaImport.copyIntoMediaDirectory(url,
                                                                                 fileName: fileName,
                                                                                 securityScoped: securityScoped)
                }
                copied = destination
                // コピーの途中でキャンセルされたら、コピーしたファイルは消して(移したファイルは戻して)やめる
                try Task.checkCancellation()
                let clip: Clip
                switch LocalMediaImport.kind(of: destination) {
                case .movie:
                    clip = try await MediaStore.makeClip(from: destination)
                case .image:
                    // 写真は静止画クリップになる
                    clip = try makeStillClip(from: destination)
                }
                if !recorded {
                    history.record(project)
                    recorded = true
                }
                if let i = insertAt, i <= project.clips.count {
                    project.clips.insert(clip, at: i)
                    insertAt = i + 1
                } else {
                    project.clips.append(clip)
                }
                if firstAddedID == nil { firstAddedID = clip.id }
                added += 1
            } catch {
                if let copied {
                    if movedFromInbox {
                        // 受け取ったファイルをなくさないよう、元の場所に戻す
                        await LocalMediaImport.moveBack(copied, to: url)
                    } else {
                        try? FileManager.default.removeItem(at: copied)
                    }
                }
                // キャンセルは失敗として数えない(このファイルはまだ済んでいないので、あとで IncomingMediaCenter に返す)
                if error is CancellationError || Task.isCancelled { break }
                if copied == nil {
                    // コピーできなかった(どのファイルかわかるように名前をつける)
                    failures.append(fileName + ": " + error.localizedDescription)
                } else {
                    // MediaStore のエラーは日本語の説明(LocalizedError)を持つ
                    failures.append(error.localizedDescription)
                }
            }
            // 済んだ(追加した・読み込めなかった)共有のファイルはすぐに消す。
            // 途中でアプリが終了しても、取り込み済みのものをまた聞かないように
            if isIncoming {
                IncomingMediaCenter.shared.discard([url])
            }
            importDone += 1
            processed += 1
        }
        let cancelled = Task.isCancelled
        // キャンセルで取り込まなかった共有のファイルは IncomingMediaCenter に返す。
        // すぐにまた聞かないよう「あとで」と同じ扱いにする(一覧に戻ったときや、次にプロジェクトを開いたときにまた聞く)
        let unprocessedIncoming: [URL] = zip(urls, incomingFlags).dropFirst(processed).filter { $0.1 }.map { $0.0 }
        if !unprocessedIncoming.isEmpty {
            IncomingMediaCenter.shared.giveBack(unprocessedIncoming)
            postponedIncomingURLs = IncomingMediaCenter.shared.pendingURLs
        }
        if deleteSourcesAfter {
            // Google フォトの一時ファイルは、キャンセルで取り込まなかったものも含めて消す
            let temporary: [URL] = zip(urls, incomingFlags).filter { !$0.1 }.map { $0.0 }
            removeImportSources(temporary)
        }
        isImporting = false
        importFraction = nil
        importIsDownloading = false
        importTask = nil
        if !failures.isEmpty, !cancelled {
            alertMessage = String(localized: "\(failures.count)件の動画・写真を読み込めませんでした。\n") + failures.joined(separator: "\n")
        } else if added > 0 {
            if let id = firstAddedID { selection = .clip(id) }
            showToast(insertAt != nil
                      ? String(localized: "再生位置の後ろに \(added)件を差し込みました")
                      : String(localized: "\(added)件を追加しました"), undo: true)
        }
    }

    /// 取り込みが終わった元のファイルを消す。共有で受け取ったものは IncomingMediaCenter に任せる(空になったフォルダも消える)
    private func removeImportSources(_ urls: [URL]) {
        var incoming: [URL] = []
        for url in urls {
            if LocalMediaImport.isInIncomingInbox(url) {
                incoming.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if !incoming.isEmpty {
            IncomingMediaCenter.shared.discard(incoming)
        }
    }

    // MARK: 共有で受け取った動画・写真

    /// 下のパネルを開いている、または画面内の処理(無音カット・音量そろえ・逆再生・解析など)が動いている
    /// (この間は共有で受け取った素材を聞かない・取り込まない)
    private var isPanelOrToolBusy: Bool {
        activePanel != nil || audioToolProgress != nil || mediaToolProgress != nil || analysis.progress != nil
    }

    /// 共有で受け取った動画・写真があれば、取り込む(一覧の「新しいプロジェクトで編集」から開いたとき)か、
    /// このプロジェクトに追加するかを聞く。
    /// 読み込み中・復元中・下のパネルを開いている間・画面内の処理(無音カット・逆再生・解析など)の間は終わってから
    /// (onChange で呼び直す)。シートや写真の選択などを出している間は、少し待って確かめ直す
    private func checkIncomingMedia() {
        let center = IncomingMediaCenter.shared
        let urls: [URL] = center.pendingURLs
        guard !urls.isEmpty, didRestore, !isLoadingPhotoMedia, !isImporting else { return }
        // パネルの ✕「キャンセル」で取り込んだクリップまで消えないよう、パネルを閉じてから。
        // 画面内の処理の進み具合と読み込み中の表示も重ねない
        guard !isPanelOrToolBusy else { return }
        if center.autoImportProjectID == projectID {
            // このプロジェクトは受け取った素材を編集するために作った: 聞かずに取り込む
            center.autoImportProjectID = nil
            importIncomingMedia()
            return
        }
        guard !showIncomingPrompt, urls != postponedIncomingURLs else { return }
        if activeSheet != nil || alertMessage != nil || ScreenPresentation.isPresentingSomething {
            // 重ねて出せない(出せなかった確認が残ってしまう)ので、閉じてから聞く
            scheduleIncomingCheck(retry: true)
            return
        }
        incomingPromptCount = urls.count
        showIncomingPrompt = true
    }

    /// 少し待ってから checkIncomingMedia を呼ぶ(閉じかけのシートなどが消えてから)。
    /// retry は何かを出していて聞けなかったときの確かめ直し(40 回、約 1 分までは 1.5 秒ごと。
    /// そのあとも、まだ聞いていない素材が残っている間は 5 秒ごとに確かめる。checkIncomingMedia が続けるかを決める)
    private func scheduleIncomingCheck(retry: Bool = false) {
        let delay: UInt64
        if retry {
            incomingCheckAttempts += 1
            delay = incomingCheckAttempts <= 40 ? 1_500_000_000 : 5_000_000_000
        } else {
            incomingCheckAttempts = 0
            delay = 800_000_000
        }
        incomingCheckTask?.cancel()
        incomingCheckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            checkIncomingMedia()
        }
    }

    /// 共有で受け取った動画・写真を、再生位置のクリップの後ろに取り込む(取り込んだら受け取ったファイルは消す)
    private func importIncomingMedia() {
        guard !isImporting else { return }
        let urls: [URL] = IncomingMediaCenter.shared.takeAll()
        guard !urls.isEmpty else { return }
        postponedIncomingURLs = []
        importAppendsAtEnd = false
        startLocalImport(urls, securityScoped: false, deleteSourcesAfter: true)
    }
}

// MARK: - 端末にあるファイルを Media フォルダにコピーする

/// 「ファイル」アプリ・Google フォト・共有で受け取った動画・写真を Media フォルダにコピーする(共有で受け取ったものは移す)。
/// メインスレッドを止めないよう、コピー・移動はバックグラウンドで行う
enum LocalMediaImport {
    /// 動画か写真か
    enum Kind {
        case movie
        case image
    }

    /// 拡張子から動画か写真かを決める。拡張子でわからないときは、画像として読めるかで決める
    static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .movie }
            if type.conforms(to: .image) { return .image }
        }
        return MediaStore.imagePixelSize(of: url) != nil ? .image : .movie
    }

    /// 共有で受け取ったファイル(App Group の Inbox の中)か
    static func isInIncomingInbox(_ url: URL) -> Bool {
        guard let inbox = AppGroup.inboxURL else { return false }
        let inboxPath = inbox.standardizedFileURL.resolvingSymlinksInPath().path
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(inboxPath + "/")
    }

    /// 保存するファイル名。共有で受け取ったファイル(Inbox/<日時>-<UUID>/<NNN>-<元の名前>)と、
    /// stripsNumberPrefix のとき(Google フォトの一時ファイルも "<NNN>-<元の名前>")は先頭の番号を外す
    static func storedFileName(for url: URL, stripsNumberPrefix: Bool = false) -> String {
        let name = url.lastPathComponent
        guard stripsNumberPrefix || isInIncomingInbox(url) else { return name }
        let characters = Array(name)
        guard characters.count > 4,
              characters[0...2].allSatisfy({ $0.isASCII && $0.isNumber }),
              characters[3] == "-" else { return name }
        return String(characters[4...])
    }

    /// url を Media フォルダに fileName でコピーし、コピー先を返す。
    /// NSFileCoordinator で読むので、「ファイル」アプリの項目(Google ドライブなど)がまだ端末にないときはダウンロードを待つ。
    /// キャンセルされたら読み込みを止める
    static func copyIntoMediaDirectory(_ url: URL, fileName: String, securityScoped: Bool) async throws -> URL {
        try Task.checkCancellation()
        let box = CoordinatorBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try LocalMediaImport.coordinatedCopy(url, fileName: fileName,
                                                     securityScoped: securityScoped,
                                                     coordinator: box.coordinator)
            }.value
        } onCancel: {
            box.coordinator.cancel()
        }
    }

    /// 共有で受け取ったファイル(Inbox の中)を Media フォルダに fileName で移し、置いた先を返す
    /// (コピーより速く、空き容量も要らない)。移せなかったときはコピーする(moved が false。元のファイルは残る)
    static func moveIntoMediaDirectory(_ url: URL, fileName: String) async throws -> (url: URL, moved: Bool) {
        try Task.checkCancellation()
        let destination = MediaStore.uniqueDestination(forFileName: fileName)
        let moved: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                return true
            } catch {
                // 途中まで書いたファイルが残らないように
                try? FileManager.default.removeItem(at: destination)
                return false
            }
        }.value
        if moved {
            return (destination, true)
        }
        let copied = try await copyIntoMediaDirectory(url, fileName: fileName, securityScoped: false)
        return (copied, false)
    }

    /// moveIntoMediaDirectory で移したファイルを元の場所に戻す(取り込まなかったとき。受け取ったファイルをなくさないように)。
    /// 受け取りフォルダが片づけられていたら作り直す。戻せなかったときは Media フォルダのファイルを消す
    static func moveBack(_ moved: URL, to original: URL) async {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.moveItem(at: moved, to: original)
            } catch {
                try? fileManager.removeItem(at: moved)
            }
        }.value
    }

    /// キャンセルのときに別のスレッドから NSFileCoordinator.cancel() を呼ぶための入れ物
    /// (cancel() はどのスレッドから呼んでもよい)
    private final class CoordinatorBox: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)
    }

    private static func coordinatedCopy(_ url: URL, fileName: String, securityScoped: Bool,
                                        coordinator: NSFileCoordinator) throws -> URL {
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let destination = MediaStore.uniqueDestination(forFileName: fileName)
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }
        var failure: Error? = copyError
        if let coordinationError {
            failure = coordinationError
        }
        if let failure {
            // 途中まで書いたファイルが残らないように
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        return destination
    }
}

// MARK: - 再生操作の行(再生時刻の変化で ContentView 全体が描き直されないよう分けている)

struct EditorTransportRow: View {
    let player: PlayerController
    /// 横向きの全画面プレビュー
    @State private var isFullScreen = false

    var body: some View {
        let current: Double = player.currentTime
        let playing: Bool = player.isPlaying
        let currentText: String = playing ? EditorTimeFormat.short(current) : EditorTimeFormat.tenths(current)
        let totalText: String = EditorTimeFormat.short(player.duration)

        ZStack {
            HStack {
                // 真ん中の再生ボタンに重ならない大きさまで
                EditorTimeReadout(text: currentText + " / " + totalText)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                Spacer()
            }

            Button {
                EditorHaptics.tap()
                player.togglePlay()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.duration <= 0)
            .accessibilityLabel(playing ? String(localized: "一時停止") : String(localized: "再生"))

            HStack {
                Spacer()
                Button {
                    EditorHaptics.tap()
                    openFullScreen(.landscapeRight)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.duration <= 0)
                .accessibilityLabel("横向きの全画面で見る")
            }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // iPhone を横にしたら全画面で見る。
            // シート・アラート・写真の選択などを出している間は開かない(全画面を重ねて出せず、横向きのまま戻れなくなるため)
            let device = UIDevice.current.orientation
            if device.isLandscape, !isFullScreen, player.duration > 0, !Self.isPresentingSomething {
                openFullScreen(OrientationController.landscapeMask(for: device))
            }
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            LandscapePreviewView(player: player) {
                closeFullScreen()
            }
        }
    }

    private func openFullScreen(_ orientation: UIInterfaceOrientationMask) {
        isFullScreen = true
        OrientationController.rotate(to: orientation)
    }

    private func closeFullScreen() {
        OrientationController.rotate(to: .portrait)
        isFullScreen = false
    }

    /// 画面の上に何か(シート・アラート・写真の選択・広告など)を出しているか
    private static var isPresentingSomething: Bool {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return root?.presentedViewController != nil
    }
}

/// 再生時刻の表示。文字の大きさの設定に合わせて大きくする。
/// 高さ 44pt の行に収まるよう、使う側で .dynamicTypeSize(...) をつけて上限を決める
/// (@ScaledMetric はこの View に届く文字の大きさで決まるので、中でつけても効かない)
private struct EditorTimeReadout: View {
    let text: String
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 15

    var body: some View {
        Text(text)
            .font(.system(size: size).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.85))
    }
}

// MARK: - パネルを開いている間の細いシークバー(44pt)

struct EditorScrubBar: View {
    let player: PlayerController
    /// ドラッグ中の位置(nil なら再生位置を表示)
    @State private var dragValue: Double?

    var body: some View {
        let total: Double = max(player.duration, 0.01)
        let playing: Bool = player.isPlaying
        let shown: Double = dragValue ?? min(max(player.currentTime, 0), total)
        let timeText: String = playing ? EditorTimeFormat.short(shown) : EditorTimeFormat.tenths(shown)

        HStack(spacing: 8) {
            Button {
                EditorHaptics.tap()
                player.togglePlay()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.duration <= 0)
            .accessibilityLabel(playing ? String(localized: "一時停止") : String(localized: "再生"))

            Slider(value: Binding<Double>(
                        get: { shown },
                        set: { newValue in
                            dragValue = newValue
                            player.scrub(to: newValue)
                        }),
                   in: 0...total,
                   onEditingChanged: { editing in
                       if editing {
                           if player.isPlaying { player.pause() }
                       } else {
                           let finalValue: Double = dragValue ?? shown
                           dragValue = nil
                           player.endScrub(at: finalValue)
                       }
                   })
                .tint(.white)
                .disabled(player.duration <= 0)

            EditorTimeReadout(text: timeText)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize()
                .frame(minWidth: 58, alignment: .trailing)
        }
    }
}
