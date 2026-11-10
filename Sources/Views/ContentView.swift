import SwiftUI
import UIKit
import PhotosUI
import Photos
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// 写真ライブラリで、動画と写真のどちらを選ぶか(混ぜずに片方だけを見せる)
enum MediaPickKind {
    case videos, photos
    var filter: PHPickerFilter { self == .videos ? .videos : .images }
}

/// 動画か写真かを先に聞くとき、どこに足すかを覚えておく
struct MediaKindQuestion {
    let overlay: Bool
    let appendAtEnd: Bool
}

/// メイン画面(CapCut 風:上部バー/プレビュー/再生操作/タイムライン/下部ツールバー)
struct ContentView: View {
    /// 編集するプロジェクト(ProjectLibrary の ID)。保存先はこの ID のフォルダ
    let projectID: UUID
    /// 一覧へ戻るときに呼ぶ(保存を終えてから呼ばれる)。wasImporting: 動画・写真の取り込み中に閉じた(空に見えても消さない)
    let onClose: (_ wasImporting: Bool) -> Void

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
    /// 「設定」→「動画の置き場所」
    @State private var isChoosingMediaMode = false
    /// 🔍 機能を探す
    @State private var isSearchingTools = false
    /// 中だるみチェックをしたときのクリップの並び
    @State private var pacingClipsKey = ""
    /// 写真ライブラリの動画を読み直している途中(この間は保存しない。空の内容で上書きしないため)
    @State private var isLoadingPhotoMedia = false
    /// 写真ライブラリの動画の読み込みの進み具合(済んだ本数・全体の本数・いまの 1 本の iCloud からのダウンロード 0...1)
    @State private var photoLoadDone = 0
    @State private var photoLoadTotal = 0
    @State private var photoLoadFraction: Double = 0
    /// 写真ライブラリの動画を読み込む処理(読み込み中に「一覧へ戻る」で止める)
    @State private var photoLoadTask: Task<Void, Never>?
    /// 写真ライブラリに見つからない動画のお知らせ(クリップは残している。「見つからない動画を外す」も選べる)
    @State private var missingPhotoNotice: String?
    /// missingPhotoNotice の対象("photos:<id>")
    @State private var missingPhotoReferences: [String] = []
    /// missingPhotoNotice で設定アプリへの入り口を出すか
    @State private var missingPhotoNoticeOffersSettings = false
    /// 保存に失敗したまま(空き容量が無いなど)。画面の上に出し続ける
    @State private var saveFailed = false
    /// 閉じるときの保存に失敗した(閉じずに、どうするか聞く)
    @State private var showCloseSaveFailed = false
    /// 保存ファイル(project.json)が読めなかった。編集画面は出さず、保存もしない(空の内容で上書きしないため)
    @State private var isProjectUnreadable = false
    /// 読めなかったときに、前回きちんと保存できた控えがある(「前回の状態に戻す」を出す)
    @State private var unreadableBackupAvailable = false
    /// 「前回の状態に戻す」で戻せなかった
    @State private var unreadableRestoreFailed = false
    /// 読めなかったことを伝えるお知らせ
    @State private var showUnreadableAlert = false
    /// カメラで撮ったのにプロジェクトに入らなかった動画(取り込みの失敗・キャンセル)。消さずに残し、どうするか聞く
    @State private var keptCameraTakes: [URL] = []
    /// keptCameraTakes をどうするか聞くお知らせ
    @State private var showKeptCameraTakes = false
    /// keptCameraTakes を取り込めなかった理由(お知らせに添える。キャンセルのときは nil)
    @State private var keptCameraTakesReason: String?
    /// 残した撮影を写真に保存している間(一覧からは外さず、閉じる・また聞くのを止める)
    @State private var isSavingKeptTakes = false

    @State private var activePanel: EditorPanel?
    @State private var activeSheet: EditorSheet?
    /// 字幕のシートを開いたときに開いて見せる場所(「キャプションを翻訳」から)。シートを閉じたら忘れる
    @State private var subtitleSheetSection: SubtitleEditorSection?
    /// 「文字起こしで編集」のシート(TranscriptEditView)
    @State private var showTranscriptEdit = false

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone Duo を開いたときなど、縦横とも regular の大きな画面
    private var isLargeWindow: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }
    /// iPhone Duo を開いたとき、下のツールを右の列(時刻などが出る列)に縦に並べる(アプリの設定・ツールバーの「設定」から切り替え)
    @AppStorage("editor.toolbarOnSide") private var toolbarOnSide = false
    /// SNS の表示ガイド(TikTok などのボタンが重なる範囲をプレビューに出す。SafeZoneModels.swift)
    @AppStorage("safeZoneGuide") private var safeZoneGuide: SafeZoneGuide = SafeZoneGuide.none
    @State private var showClearProjectConfirm = false
    /// 消すとクリップが 0 本になる削除の確認と、確かめたあとに行う削除(キャプション・テキストなども一緒に消えるため)
    @State private var showDeleteAllClipsConfirm = false
    @State private var pendingClipDelete: (() -> Void)? = nil
    /// 無音カットのテンポを選ぶ
    @State private var showSilenceCutConfirm = false
    @State private var showPunchInDialog = false
    /// 「調整を全クリップに適用」の確認(元になるクリップ。LookClipboard.swift)
    @State private var showLookApplyAllConfirm = false
    @State private var lookApplyAllClipID: UUID?
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
    /// 手書き中の拡大率と、拡大した絵のずれ(2 本指でつまむ・動かす。DrawingCanvasView)
    @State private var drawingZoom: CGFloat = 1
    @State private var drawingPan: CGSize = .zero

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
    /// 「元に戻す」つきのトーストを出したときに、↶ で戻る先(あとから別の編集をしたら、トーストからは戻さない)
    @State private var toastUndoTarget: ProjectSnapshot?
    /// 1.5: ツールバーで開いているグループ(選択が変わると閉じる)
    @State private var toolbarGroupPath: [String] = []
    /// 1.5: パネルを開いたときの状態(✕「キャンセル」で戻す)
    @State private var panelSnapshot: ProjectSnapshot?
    /// 開いているパネルの高さ(トーストをパネルの上に出すため)
    @State private var openPanelHeight: CGFloat = 0
    /// お知らせを閉じたあとに出すトースト(一部だけ読み込めたときの「元に戻す」つきのお知らせ)
    @State private var toastAfterAlert: EditorToast?
    /// 字幕を直したあとの「ほかの〇か所も変えますか?」
    @State private var termReplacement: CaptionTermReplacement?
    /// 1.5: タイムラインの「+」から開く PhotosPicker
    @State private var showMediaPicker = false
    /// 「追加」の写真ライブラリで見せるもの(動画だけ / 写真だけ)
    @State private var mediaPickerFilter: PHPickerFilter = .videos
    /// 動画か写真かを聞いている途中(タイムラインの「+」などから)
    @State private var mediaKindQuestion: MediaKindQuestion? = nil
    /// 「カメラで撮る」(CameraRecorderView。撮った動画は「ファイル」からの追加と同じ道で取り込む)
    @State private var showCameraRecorder = false
    #if OSMO_LIVE
    /// 「Osmo Pocket で撮る(実験)」(開発者モードのとき。録った動画はカメラで撮るときと同じ道で取り込む)
    @State private var showOsmoRecorder = false
    #endif
    /// タイムライン末尾の「+」から追加したときは末尾に足す(それ以外は再生位置のクリップの後ろに差し込む)
    @State private var importAppendsAtEnd = false
    /// ドロップで差し込む位置(タイムラインに落としたとき。importLocalFiles が一度だけ使う)
    @State private var importInsertIndex: Int? = nil
    /// 使い勝手の計測: 取り込んだ場所(ドロップのときだけ上書き)
    @State private var importSourceOverride: String? = nil
    /// ドラッグ中の項目がタイムライン・プレビューの上にあるか
    @State private var timelineDropTargeted = false
    @State private var previewDropTargeted = false
    /// 空の画面の上にドラッグ中の項目があるか
    @State private var emptyDropTargeted = false
    @State private var timelineWidth: CGFloat = 0
    /// クリップを動かしている間(移動・トリム・並べ替え)に固定しておくタイムラインの高さ。終わったら nil に戻す
    /// (ドラッグ中に行が増えて、指の下でタイムラインがずれないように)
    @State private var frozenTimelineHeight: CGFloat?
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
    /// タイムラインの「+」から開くオーバーレイの PhotosPicker
    @State private var showOverlayPicker = false
    /// オーバーレイの写真ライブラリで見せるもの(動画だけ / 写真だけ)
    @State private var overlayPickerFilter: PHPickerFilter = .videos
    /// マルチカメラを V1 のカットに書き出している最中
    @State private var isFlatteningMulticam = false
    /// 「V1 に書き出す」を押せない理由(押したときにシートの中で出す)
    @State private var multicamFlattenBlockMessage: String?
    /// 長い動画の逆再生を作る前に確かめているクリップと、その説明
    @State private var reverseConfirmClipID: UUID?
    @State private var reverseConfirmMessage = ""
    /// ステッカーパネルの「GIF を読み込む」(写真ライブラリ / 「ファイル」。どちらもオーバーレイとして入る)
    @State private var showGIFPhotoPicker = false
    @State private var showGIFFileImporter = false

    init(projectID: UUID, onClose: @escaping (_ wasImporting: Bool) -> Void) {
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

            // なめらかスローの作成中(FlowSlowControls.swift)
            if let progress = FlowSlowJobs.shared.progress {
                ClipFXProgressOverlay(progress: progress) {
                    FlowSlowJobs.shared.cancel()
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
                      matching: mediaPickerFilter,
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        // 動画と写真を混ぜずに選べるよう、先にどちらかを聞く
        .confirmationDialog("何を追加しますか?", isPresented: mediaKindDialogShown,
                            titleVisibility: .visible, presenting: mediaKindQuestion,
                            actions: mediaKindActions)
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
            // 手書きを閉じたら拡大を戻す(次に開いたときは等倍から)
            if newValue != .drawingCanvas, drawingZoom != 1 || drawingPan != .zero {
                drawingZoom = 1
                drawingPan = .zero
            }
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
        // キーボードが画面の下を実際に覆っているときだけタイムラインを隠す。
        // シート(文字起こし編集など)の中で出したキーボードは編集画面には関係ないので数えない。
        // 隠れた通知を取りこぼすと、タイムラインが出てこないままになっていた
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            isKeyboardVisible = activeSheet == nil && !showTranscriptEdit && !isSearchingTools
                && Self.keyboardCoversScreen(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: activeSheet == nil && !showTranscriptEdit && !isSearchingTools) { _, closed in
            if closed { isKeyboardVisible = false }
        }
        .onAppear {
            handleAppear()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .fullScreenCover(isPresented: $showCameraRecorder) {
            // 「カメラで撮る」。撮った動画は「ファイル」から追加したときと同じ道で Media フォルダへ移して取り込む
            // (撮影はここにしか無いので、プロジェクトに入らなかったときは消さずに残し、どうするか聞く。importLocalFiles)
            CameraRecorderView(aspect: project.canvas.aspect) { url in
                importSourceOverride = "camera"
                startLocalImport([url], securityScoped: false, deleteSourcesAfter: true)
            }
        }
        #if OSMO_LIVE
        .fullScreenCover(isPresented: $showOsmoRecorder) {
            // 「Osmo Pocket で撮る(実験)」。録った .mp4 はカメラで撮ったときと同じ道で取り込む
            NavigationStack {
                OsmoLiveMonitorView { url in
                    importSourceOverride = "osmo"
                    startLocalImport([url], securityScoped: false, deleteSourcesAfter: true)
                }
            }
        }
        #endif
        // 文字起こしで編集(開くときに履歴を記録し、何も消さずに閉じたらその記録を捨てる)
        .sheet(isPresented: $showTranscriptEdit, onDismiss: { history.discardLastIfUnchanged(project) }) {
            TranscriptEditView(project: project, player: player,
                               onOpenCaptions: { history.record(project); activeSheet = .subtitles },
                               onFinished: { count, seconds in
                                   showToast(String(localized: "文字起こしで \(count) か所・\(String(format: "%.1f", seconds)) 秒を削除しました"), undo: true)
                               })
        }
        .onChange(of: activeSheet) { previous, sheet in
            if let sheet {
                Analytics.shared.track("sheet", ["name": Self.analyticsName(of: sheet)])
            } else if case .multicam? = previous {
                // マルチカメラはアングルの読み込みがシートを閉じたあとに終わって書き込むことがあるので、開くときの履歴は残す
            } else {
                // 何も変えずにシートを閉じたときは、開くときに記録した履歴を捨てる(↶ が空振りしないように)
                history.discardLastIfUnchanged(project)
            }
            // 「キャプションを翻訳」で指定した開く場所は、字幕のシートを閉じたら忘れる
            if sheet != .subtitles { subtitleSheetSection = nil }
        }
        .confirmationDialog("このプロジェクトを空にしますか?",
                            isPresented: $showClearProjectConfirm,
                            titleVisibility: .visible) {
            Button("編集中の内容をすべて削除", role: .destructive) {
                clearProject()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このプロジェクトのクリップ・キャプション・BGM・オーバーレイ・ナレーション・テキスト・手書き・マーカーはすべて消え、元に戻せません。プロジェクト自体は一覧に残ります。")
        }
        .confirmationDialog("すべてのクリップを削除しますか?",
                            isPresented: $showDeleteAllClipsConfirm,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                let action = pendingClipDelete
                pendingClipDelete = nil
                action?()
            }
            Button("キャンセル", role: .cancel) {
                pendingClipDelete = nil
            }
        } message: {
            Text("キャプション・テキスト・オーバーレイ・ナレーション・手書き・マーカーも一緒に消えます。消したあとは「元に戻す」で戻せます。")
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
    /// 「ファイル」から選ぶ画面と、共有で受け取った素材の確認もここに付ける
    /// (body の型チェックを軽くするため、またほかのシート・お知らせと別の View に付けるため分けている)
    private var mainColumn: some View {
        VStack(spacing: 0) {
            topBarWithDialogs
            // 本体をタップすると書き出し画面に戻る
            ExportProgressBanner(onOpen: { openExport() })
            if saveFailed && !isProjectUnreadable {
                saveFailureBanner
            }
            if isProjectUnreadable {
                // 保存ファイルが読めなかった: 空の画面の代わりに説明を出す(空のまま編集しても保存されず、作業が消えるため)
                unreadableProjectView
            } else if isLoadingPhotoMedia {
                // 写真ライブラリの動画を読み込み中: 空の画面は出さない
                // (前は空の画面で素材を足せてしまい、足したクリップやカメラの撮影が読み込みの完了で黙って消えていた)
                photoLoadingView
            } else if project.isEmpty {
                emptyState
            } else {
                editor
            }
        }
        // 大きな画面では左端を少し空ける(ケースなどで端に指が届きにくいため)
        .padding(.leading, isLargeWindow ? 14 : 0)
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
        // ステッカーパネルの「GIF を読み込む」→「ファイルから選ぶ」(オーバーレイとして入る)
        .background {
            Color.clear
                .fileImporter(isPresented: $showGIFFileImporter,
                              allowedContentTypes: [.gif],
                              allowsMultipleSelection: true) { result in
                    handleGIFFileImport(result)
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
        // 保存ファイルが読めなかったとき・カメラの撮影を残したときのお知らせ(型チェックを軽くするため、別の枝に付ける)
        .background {
            dataSafetyAlerts
        }
        // アプリに戻ってきたら、共有で受け取った動画・写真がないか見る
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            IncomingMediaCenter.shared.refresh()
            scheduleIncomingCheck()
        }
        // 保存に失敗した・また保存できるようになった(空き容量が無いなど。ProjectStore が知らせる)
        .onReceive(NotificationCenter.default.publisher(for: ProjectStore.saveStatusDidChange)) { note in
            guard let id = note.userInfo?["projectID"] as? UUID, id == projectID else { return }
            saveFailed = (note.userInfo?["failed"] as? Bool) ?? false
        }
        // 取り込めずに残したカメラの撮影の置き場所を覚えておく(アプリが終了しても、次に開いたときにまた聞けるように)
        .onChange(of: keptCameraTakes) { _, takes in
            let saved: [URL] = KeptCameraTakesStore.save(takes)
            if saved != takes { keptCameraTakes = saved }
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
            if message == nil {
                scheduleIncomingCheck()
                if let pending = toastAfterAlert {
                    toastAfterAlert = nil
                    showToast(pending.message, style: pending.style, undo: pending.canUndo)
                }
            }
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
            DroppedMediaHandoff.discard(for: projectID)
        }
    }

    // MARK: - トースト

    private func toastLayer(_ current: EditorToast) -> some View {
        VStack {
            Spacer(minLength: 0)
            EditorToastView(toast: current) {
                undoFromToast()
            }
            // パネルを開いている間はパネルの上に出す(パネルに重ならず、「元に戻す」が指の下に来ないように)
            .padding(.bottom, activePanel == nil ? 84 : openPanelHeight + 8)
            // 雲のようにふわっと現れ、消えるときは真ん中にスッと吸い込まれる(動きを減らす設定では薄く出入りするだけ)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.toastCloud)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: activePanel == nil)
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
        toastUndoTarget = undo ? history.undoTarget(project) : nil
        withAnimation(EditorToastView.showAnimation) {
            toast = EditorToast(message, style: style, canUndo: undo)
        }
    }

    private func undoFromToast() {
        withAnimation(EditorToastView.hideAnimation) {
            toast = nil
        }
        // トーストを出したあとに別の編集(トリム・移動など)をしていたら戻さない。前はその別の編集のほうを戻していた
        if let expected = toastUndoTarget, history.undoTarget(project) != expected {
            toastUndoTarget = nil
            showToast(String(localized: "あとから別の編集をしたため、戻していません。↶ で 1 つずつ戻せます"), style: .info)
            return
        }
        toastUndoTarget = nil
        activePanel = nil
        Analytics.shared.trackUndo(source: "toast")
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
                Button("写真ライブラリから参照") {
                    ProjectLibrary.shared.setMediaMode(id: projectID, to: .photoLibrary)
                    // 次に作るプロジェクトも同じ置き場所にする
                    NewProjectMediaMode.last = .photoLibrary
                    showToast(String(localized: "これから追加する動画は写真ライブラリから参照します(次に作るプロジェクトも同じです)"))
                }
                Button("アプリに取り込む") {
                    ProjectLibrary.shared.setMediaMode(id: projectID, to: .appCopy)
                    NewProjectMediaMode.last = .appCopy
                    showToast(String(localized: "これから追加する動画はアプリに取り込みます"))
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("これから追加する動画に使われます。追加済みの動画はそのままです。次に作るプロジェクトも同じ置き場所になります(「新しいプロジェクト」の画面で変えられます)。\n「写真ライブラリから参照」では、写真アプリで動画を消すとこのプロジェクトでも使えなくなります。スローモーションの動画はアプリに取り込みます。")
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
                .frame(maxWidth: 170, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("プロジェクト名「\(projectName)」を変更")

            Spacer()

            // ↶ ↷ は親指の届く再生の行(パネルを開いている間はシークバー)にある
            Button {
                EditorHaptics.tap()
                player.pause()
                isSearchingTools = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(project.isEmpty ? 0.3 : 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 空のプロジェクトでは使えない(見えないパネルが開き、あとで取り込んだクリップまで ✕ で消えるため)
            .disabled(project.isEmpty)
            .accessibilityLabel("機能を探す")

            Spacer()

            Button {
                EditorHaptics.tap()
                openExport()
            } label: {
                Text("書き出し")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    // 幅の狭い画面(iPhone Duo を開いたたて持ちなど)でも 2 行に折り返さない
                    .lineLimit(1)
                    .fixedSize()
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

    /// 書き出し画面を開く(上部バーの「書き出し」と、書き出し中のバナーのタップから)
    private func openExport() {
        player.pause()
        // 手書きの途中なら、描いた線を追加してから閉じる
        if isDrawingNew {
            finishDrawing()
        } else {
            activePanel = nil
        }
        activeSheet = .export
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
                requestMediaAdd(appendAtEnd: false, kind: .videos)
            } label: {
                Label("動画を追加", systemImage: "plus.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(FacetedBrandBackground())
            }
            .buttonStyle(.plain)
            .disabled(isImporting || isLoadingPhotoMedia)

            // 写真ライブラリ以外の取り込み元は小さく並べる。1 行に入らないときは 2 段に、それでも入らないときは縦に並べる
            // (文字の途中で折り返さない)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    emptyStateDeviceSources
                    emptyStateMadeSources
                }
                VStack(spacing: 0) {
                    HStack(spacing: 20) { emptyStateDeviceSources }
                    HStack(spacing: 20) { emptyStateMadeSources }
                }
                VStack(alignment: .leading, spacing: 0) {
                    emptyStateDeviceSources
                    emptyStateMadeSources
                }
            }
            .disabled(isImporting || isLoadingPhotoMedia)

            // 最後のクリップを消した直後なども戻せるよう、空の画面にも「元に戻す」を出す(編集画面の ↶ は空の画面には無い)
            if history.canUndo {
                Button {
                    EditorHaptics.tap()
                    undoFromButton()
                } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        // ほかのアプリから落とした動画・写真は、クリップとして取り込む(前は空のプロジェクトには落とせなかった)
        .contentShape(Rectangle())
        .onDrop(of: MediaDrop.types, isTargeted: $emptyDropTargeted) { providers in
            handleEmptyDrop(providers)
        }
        .overlay {
            if emptyDropTargeted, canAcceptDrop {
                MediaDropHighlight(title: String(localized: "クリップとして追加"))
                    .padding(8)
            }
        }
    }

    /// 空の画面の取り込み元(端末にあるもの)
    @ViewBuilder
    private var emptyStateDeviceSources: some View {
        emptyStateSourceButton(String(localized: "写真"), systemImage: "photo") {
            requestMediaAdd(appendAtEnd: false, kind: .photos)
        }
        emptyStateSourceButton(String(localized: "ファイル"), systemImage: "folder") {
            requestFileAdd(appendAtEnd: false)
        }
        emptyStateSourceButton(String(localized: "カメラ"), systemImage: "camera") {
            requestCameraAdd(appendAtEnd: false)
        }
    }

    /// 空の画面の取り込み元(その場で作る背景と Google フォト)
    @ViewBuilder
    private var emptyStateMadeSources: some View {
        // 空の画面には下のパネルが無いので、黒 3 秒をそのまま入れる(入ってから編集画面で色や長さを変えられる)
        emptyStateSourceButton(String(localized: "カラー"), systemImage: "rectangle.fill") {
            guard !isImporting, !isLoadingPhotoMedia else { return }
            history.record(project)
            importAppendsAtEnd = true
            insertColorScreen(hex: "#000000", seconds: 3)
        }
        emptyStateSourceButton(String(localized: "方眼紙"), systemImage: "squareshape.split.3x3") {
            addGridPaperBackground()
        }
        if GoogleOAuth.isConfigured {
            emptyStateSourceButton(String(localized: "Google フォト"), systemImage: "photo.on.rectangle.angled") {
                requestGooglePhotosAdd(appendAtEnd: false)
            }
        }
    }

    private func emptyStateSourceButton(_ title: String, systemImage: String,
                                        action: @escaping () -> Void) -> some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 保存ファイルが読めないとき・撮影を残したときのお知らせ

    /// mainColumn の背景に付けるお知らせ(お知らせごとに別の View に付ける)
    private var dataSafetyAlerts: some View {
        ZStack {
            // 保存ファイルが読めなかった(開いたときに 1 回。後ろの画面にも同じ説明とボタンを出している)
            Color.clear
                .alert(String(localized: "このプロジェクトを読み込めませんでした"), isPresented: $showUnreadableAlert) {
                    if unreadableBackupAvailable && !unreadableRestoreFailed {
                        Button(String(localized: "前回の状態に戻す")) {
                            restoreProjectBackup()
                        }
                    }
                    Button(String(localized: "プロジェクト一覧へ戻る"), role: .cancel) {
                        closeProject()
                    }
                } message: {
                    Text(unreadableProjectMessage)
                }
            // カメラで撮ったのにプロジェクトに入らなかった動画: 消さずに残し、もう一度取り込むか写真に保存するかを選んでもらう
            Color.clear
                .alert(String(localized: "撮った動画をまだ取り込んでいません"), isPresented: $showKeptCameraTakes) {
                    Button(String(localized: "もう一度取り込む")) {
                        retryKeptCameraTakes()
                    }
                    Button(String(localized: "写真に保存")) {
                        saveKeptCameraTakesToPhotos()
                    }
                    Button(String(localized: "動画を削除"), role: .destructive) {
                        discardKeptCameraTakes()
                    }
                } message: {
                    Text(keptCameraTakesMessage)
                }
            // 写真ライブラリに見つからない動画: クリップは消さずに残し、外すのは自分で選んだときだけ
            Color.clear
                .alert(String(localized: "見つからない動画があります"), isPresented: Binding(
                    get: { missingPhotoNotice != nil },
                    set: { if !$0 { missingPhotoNotice = nil } }
                )) {
                    if missingPhotoNoticeOffersSettings {
                        Button(String(localized: "設定を開く")) {
                            openSystemSettings()
                        }
                    }
                    Button(String(localized: "見つからない動画を外す"), role: .destructive) {
                        removeMissingPhotoClips()
                    }
                    Button(String(localized: "残しておく"), role: .cancel) {}
                } message: {
                    Text(missingPhotoNotice ?? "")
                }
            // 長い動画の逆再生を作る前の確認(元の動画全体から作るため、時間と容量がかかる)
            Color.clear
                .alert(String(localized: "逆再生の動画を作成しますか?"), isPresented: Binding(
                    get: { reverseConfirmClipID != nil },
                    set: { if !$0 { reverseConfirmClipID = nil } }
                )) {
                    Button(String(localized: "作成する")) {
                        if let id = reverseConfirmClipID {
                            reverseConfirmClipID = nil
                            toggleReverse(id, confirmedLongSource: true)
                        }
                    }
                    Button(String(localized: "キャンセル"), role: .cancel) {}
                } message: {
                    Text(reverseConfirmMessage)
                }
            // 閉じるときの保存に失敗した: 閉じると編集が消えるので、閉じずにどうするか聞く
            Color.clear
                .alert(String(localized: "保存できませんでした"), isPresented: $showCloseSaveFailed) {
                    Button(String(localized: "もう一度保存して閉じる")) {
                        // お知らせが閉じ終わってから(また失敗したときに、もう一度聞けるように)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            closeProject()
                        }
                    }
                    Button(String(localized: "保存せずに一覧へ戻る"), role: .destructive) {
                        closeWithoutSaving()
                    }
                    Button(String(localized: "編集に戻る"), role: .cancel) {}
                } message: {
                    Text(String(localized: "iPhone の空き容量が足りない可能性があります。設定アプリの「一般」→「iPhone ストレージ」で空きを作ってから、もう一度保存してください。このまま一覧へ戻ると、最後に保存できたあとの編集は消えます。"))
                }
        }
    }

    /// 写真ライブラリの動画を読み込んでいる間に、空の画面の代わりに出す(何本目か・iCloud からのダウンロード・一覧へ戻る)
    private var photoLoadingView: some View {
        VStack(spacing: 18) {
            ProgressView(value: photoLoadProgressValue)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(maxWidth: 260)
            Text(String(localized: "写真ライブラリから動画を読み込んでいます…"))
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if photoLoadTotal > 0 {
                Text(String(localized: "\(min(photoLoadDone + 1, photoLoadTotal)) / \(photoLoadTotal) 本"))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(String(localized: "iCloud にある動画はダウンロードするため、時間がかかることがあります。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                EditorHaptics.tap()
                closeProject()
            } label: {
                Text(String(localized: "プロジェクト一覧へ戻る"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 写真ライブラリの動画の読み込みの進み具合(0...1)
    private var photoLoadProgressValue: Double {
        guard photoLoadTotal > 0 else { return 0 }
        let done: Double = Double(photoLoadDone) + min(max(photoLoadFraction, 0), 1)
        return min(1, max(0, done / Double(photoLoadTotal)))
    }

    /// 保存に失敗したままのときに上に出し続ける帯(前は何も出ず、閉じると最後に保存できたあとの編集が消えていた)
    private var saveFailureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(String(localized: "保存できませんでした。iPhone の空き容量を確保してください"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                EditorHaptics.tap()
                retrySave()
            } label: {
                Text(String(localized: "もう一度保存"))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .background(Color.red.opacity(0.35))
    }

    /// 帯の「もう一度保存」
    private func retrySave() {
        guard !isLoadingPhotoMedia, !isProjectUnreadable else { return }
        if ProjectStore.saveNow(project.snapshot(), projectID: projectID) {
            showToast(String(localized: "保存しました"))
        } else {
            showToast(String(localized: "まだ保存できません。空き容量を確保してください"), style: .warning)
        }
    }

    /// 「保存せずに一覧へ戻る」(閉じるときの保存に失敗し、自分で選んだとき)
    private func closeWithoutSaving() {
        ProjectLibrary.shared.flush()
        onClose(isImporting || isLoadingPhotoMedia)
    }

    /// 「見つからない動画を外す」: 写真ライブラリに見つからないまま残していたクリップ・オーバーレイを、保存ファイルからも外す
    /// (自分で選んだときだけ。iCloud から取れなかっただけの動画は外さない)
    private func removeMissingPhotoClips() {
        let references = Set(missingPhotoReferences)
        missingPhotoReferences = []
        guard !references.isEmpty,
              ProjectStore.discardHeldPhotoReferences(projectID: projectID, references: references) else { return }
        ProjectStore.scheduleSave(project.snapshot(), projectID: projectID)
        showToast(String(localized: "見つからない動画をプロジェクトから外しました"))
    }

    /// 保存ファイル(project.json)が読めなかったときに、空の画面・編集画面の代わりに出す。
    /// 開いたときのお知らせと同じ説明・ボタン(お知らせを閉じたあとや、出せなかったときもここから選べる)
    private var unreadableProjectView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text(String(localized: "このプロジェクトを読み込めませんでした"))
                .font(.title3.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(unreadableProjectMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if unreadableBackupAvailable && !unreadableRestoreFailed {
                Button {
                    EditorHaptics.tap()
                    restoreProjectBackup()
                } label: {
                    Text(String(localized: "前回の状態に戻す"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(FacetedBrandBackground())
                }
                .buttonStyle(.plain)
            }
            Button {
                EditorHaptics.tap()
                closeProject()
            } label: {
                Text(String(localized: "プロジェクト一覧へ戻る"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 読めなかったときの説明(何が起きたか・何ができるか)
    private var unreadableProjectMessage: String {
        if unreadableRestoreFailed {
            return String(localized: "前回の状態に戻せませんでした。保存ファイルは消さずにそのまま残しています。")
        }
        if unreadableBackupAvailable {
            return String(localized: "保存ファイルが壊れているか、このバージョンのアプリでは読めない形式です。前回きちんと保存できた状態に戻せます(読めなかったファイルも消さずに残します)。")
        }
        return String(localized: "保存ファイルが壊れているか、このバージョンのアプリでは読めない形式です。ファイルは消さずにそのまま残しています。アプリを最新版にすると開ける場合があります。")
    }

    /// 「前回の状態に戻す」: 控え(project.json.bak)を project.json に戻してから開き直す(読めなかったファイルも残す)
    @MainActor
    private func restoreProjectBackup() {
        guard ProjectStore.restoreBackup(projectID: projectID) else {
            // 戻せなかった: 何も変えていないので、説明だけ変えて一覧へ戻るボタンを残す
            unreadableRestoreFailed = true
            return
        }
        isProjectUnreadable = false
        openSavedProject()
        if !isProjectUnreadable {
            showToast(String(localized: "前回の状態に戻しました"))
        }
    }

    // MARK: - 編集画面

    private var isDrawingNew: Bool { activePanel == .drawingCanvas }

    /// 手書きの途中で描いた線があるときは、↶ が最後の線を消す(プロジェクトの履歴は戻さない)
    private var undoRemovesStroke: Bool { isDrawingNew && !draftStrokes.isEmpty }

    /// 再生の行・シークバーの ↶
    private func undoFromButton() {
        if undoRemovesStroke {
            draftStrokes.removeLast()
            return
        }
        guard history.canUndo else { return }
        activePanel = nil
        Analytics.shared.trackUndo(source: "button")
        history.undo(project)
    }

    /// 再生の行の ↷(パネルを開いている間は出さない)
    private func redoFromButton() {
        guard history.canRedo else { return }
        activePanel = nil
        history.redo(project)
    }

    /// パネルで編集している部品の、タイムライン上の範囲(シークバーの色の帯)
    private var scrubHighlight: ClosedRange<Double>? {
        guard let target = activePanel?.targetSelection else { return nil }
        return timelineRange(of: target)
    }

    /// 部品のタイムライン上の範囲(クリップはトランジションの重なりを含む)
    private func timelineRange(of target: EditorSelection) -> ClosedRange<Double>? {
        let range: (start: Double, end: Double)?
        switch target {
        case .clip(let clipID):
            let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
            range = layout.first(where: { $0.clipID == clipID }).map { (start: $0.start, end: $0.end) }
        case .subtitle(let cueID):
            range = project.subtitles.first(where: { $0.id == cueID }).map { (start: $0.start, end: $0.end) }
        case .overlay(let overlayID):
            range = project.overlays.first(where: { $0.id == overlayID }).map { (start: $0.start, end: $0.start + $0.duration) }
        case .narration(let narrationID):
            range = project.narration.first(where: { $0.id == narrationID }).map { (start: $0.start, end: $0.end) }
        case .text(let textID):
            range = project.textClips.first(where: { $0.id == textID }).map { (start: $0.start, end: $0.start + $0.duration) }
        case .drawing(let drawingID):
            range = project.drawings.first(where: { $0.id == drawingID }).map { (start: $0.start, end: $0.start + $0.duration) }
        case .videoEffect(let effectID):
            range = project.videoEffects.first(where: { $0.id == effectID }).map { (start: $0.start, end: $0.end) }
        case .bgm, .marker:
            range = nil
        }
        guard let range, range.end > range.start else { return nil }
        return range.start...range.end
    }

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
            // 手書き中は線と同じに拡大する(中心を基準に拡大してからずらす。枠の外は切る)
            .scaleEffect(isDrawingNew ? drawingZoom : 1)
            .offset(isDrawingNew ? drawingPan : .zero)
            .clipped()
            .overlay {
                // 映像の表示領域(アスペクトフィット後)にぴったり重なる
                if isDrawingNew {
                    DrawingCanvasView(strokes: $draftStrokes,
                                      colorHex: drawingColorHex,
                                      width: drawingWidth,
                                      zoom: $drawingZoom,
                                      pan: $drawingPan)
                } else {
                    PreviewGestureOverlay(project: project,
                                          history: history,
                                          selection: selection,
                                          maskTarget: previewMaskTarget,
                                          rectSelection: previewRectSelection,
                                          player: player,
                                          onSelect: { newSelection in
                                              // パネルを開いている間はプレビューのタップで選択を変えない(パネルが閉じて ✕「キャンセル」で戻せなくなるため)
                                              if activePanel == nil { selection = newSelection }
                                          },
                                          onEditSelected: { tapped in
                                              // 選択中のテキスト・ステッカー・モザイクの枠のタップで編集を開く(パネルを開いている間は何もしない)
                                              guard activePanel == nil, case .text(let textID) = tapped,
                                                    let item = project.textClips.first(where: { $0.id == textID }) else { return }
                                              openPanel(item.isMosaic ? .mosaic(textID) : .textStyle(textID))
                                          })
                }
            }
            // 色・ルック系のパネルを開いている間だけ、長押しで元の色を見る(LookComparePreview.swift)
            .lookCompareHold(scope: isDrawingNew ? nil : activePanel?.lookCompareScope, player: player)
            // SNS の表示ガイド(TikTok などのボタンが重なる範囲)。プレビューだけで、書き出しには影響しない
            .overlay {
                SafeZonePreviewLayer(guide: $safeZoneGuide, project: project,
                                     renderSize: player.renderSize, showsButton: !isDrawingNew,
                                     player: player)
            }
    }

    /// キーボードの通知の終わりの枠が、画面の下を 80pt 以上覆っているか(外付けキーボード・小さな浮きキーボードは数えない)
    private static func keyboardCoversScreen(_ note: Notification) -> Bool {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
        let screen = UIScreen.main.bounds
        let covered = screen.intersection(end)
        guard !covered.isNull else { return false }
        return covered.height >= 80 && covered.width >= screen.width * 0.5 && end.maxY >= screen.maxY - 1
    }

    private var editor: some View {
        GeometryReader { geo in
            let panelOpen: Bool = activePanel != nil
            let fullHeight: CGFloat = geo.size.height
            // プレビューは残りの高さをすべて使う(タイムラインとツールバーの間に隙間を作らない。
            // iPhone Duo を開いた横持ちなど、高さに余裕がある画面ではそのぶん大きく映る)
            let previewMax: CGFloat = fullHeight
            // 横持ちかどうかは、キーボードで縮まない高さ(この画面の上端から画面の下端まで)で決める。
            // geo の高さで決めると、iPhone Duo のたて持ちでキーボードが出ただけで列の分け方が変わり、
            // パネルが作り直されて入力欄のフォーカスが切れ、キーボードが閉じてしまう
            let keyboardFreeHeight: CGFloat = max(geo.size.height, UIScreen.main.bounds.height - geo.frame(in: .global).minY)
            let isWideLayout: Bool = isLargeWindow && geo.size.width > keyboardFreeHeight
            // パネルの高さ: ふだんは画面の 38%。iPhone Duo を開いた横持ち(広い画面の横長)は高さに余裕がないので、
            // 上部バーとタイムラインの分だけ残してあとはパネルに使う(38% では中身が切れる)
            let panelMax: CGFloat = isWideLayout
                ? max(160, fullHeight - 44 - 100)
                : max(160, fullHeight * 0.38)
            // 縦長(9:16・4:5)の作品を広い画面の横持ちで開いたときは、左にプレビューを縦いっぱい、右にタイムラインとツールを置く
            let splitPortrait: Bool = isWideLayout && portraitPreviewRatio != nil
            // ツールを右の列へ: iPhone Duo を開いたとき、または閉じていても右端に時刻・電池が縦に並ぶ列(広いセーフエリア)がある画面
            // (パネルを開いている間は下にパネルが出るので、列は出さない)
            let sideColumn: Bool = geo.safeAreaInsets.trailing >= Self.sideColumnMinInset
            let sideToolbar: Bool = (isLargeWindow || sideColumn) && toolbarOnSide && !panelOpen && !splitPortrait
            // 右の列の幅: 時刻・電池などが出る右端のセーフエリアと同じ幅(狭いときは 72pt)
            let sideWidth: CGFloat = max(72, geo.safeAreaInsets.trailing)
            // 右の列はプレビューの横から画面の下まで縦いっぱいに出す。右上に縦に並ぶ時刻・電池・電波と重ならないよう、その下から始める。
            // iPhone Duo ではステータスバーの枠が取れない(0 になる)ことがあるので、少なくとも sideColumnStatusAllowance は空ける
            let sideTop: CGFloat = max(0, max(Self.statusBarBottom() + 8, Self.sideColumnStatusAllowance) - geo.frame(in: .global).minY)
            let timelineHeight: CGFloat = frozenTimelineHeight ?? TimelineView.preferredHeight(for: project)
            // 左のプレビューの幅: 高さいっぱいに映る幅(+ 余白)。画面の 45% まで
            let previewWidth: CGFloat = min(geo.size.width * 0.45, fullHeight * (portraitPreviewRatio ?? 1) + 24)
            // 右の列にパネルを開いても、タイムラインを残せるだけの高さがあるか
            let keepsTimeline: Bool = splitPortrait && fullHeight - 44 - timelineHeight >= 240
            let splitPanelMax: CGFloat = keepsTimeline ? max(160, fullHeight - 44 - timelineHeight - 8) : panelMax

            HStack(spacing: 0) {
                if splitPortrait {
                    previewBlock
                        .frame(width: previewWidth, height: fullHeight)
                    VStack(spacing: 0) {
                        if !isKeyboardVisible {
                            if panelOpen, !keepsTimeline {
                                scrubBar
                            } else {
                                transportAndTimeline
                            }
                        }
                        Spacer(minLength: 0)
                        bottomArea(maxPanelHeight: splitPanelMax)
                    }
                    .frame(width: geo.size.width - previewWidth, height: fullHeight)
                } else {
                    VStack(spacing: 0) {
                        previewBlock
                            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: previewMax)
                            // プレビューのタップは PreviewGestureOverlay が選択に使う(何もない所のタップは選択を外す。選択していなければ再生・一時停止)
                            .layoutPriority(1)

                        if !isKeyboardVisible {
                            if panelOpen {
                                // パネルを開いている間はタイムラインの代わりに細いシークバーを出す(プレビューを広く保つ)。
                                // タイムラインと同じく右の列(時刻などが出る列)の下まで伸ばす
                                scrubBar
                                    .ignoresSafeArea(.container, edges: .trailing)
                            } else {
                                transportAndTimeline
                            }
                        }

                        if !sideToolbar {
                            // パネルの上端(いちばん高いとき)が右の列の時刻などより下なら、パネルも右の列の下まで使う
                            bottomArea(maxPanelHeight: panelMax,
                                       panelUsesSideColumn: geo.size.height - panelMax > sideTop + 12)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)

                    if sideToolbar {
                        // 右の列にツール: プレビューの横から画面の下まで、右端のセーフエリア(時刻などが出る列)に縦の列を重ねる
                        sideToolbarColumn
                            .padding(.top, sideTop)
                            .frame(width: sideWidth, height: geo.size.height, alignment: .top)
                            .background {
                                ZStack {
                                    Color.black
                                    BrandStyle.surface
                                }
                            }
                    }
                }
            }
            .frame(width: geo.size.width + (sideToolbar ? sideWidth : 0), height: geo.size.height, alignment: .leading)
            .ignoresSafeArea(.container, edges: sideToolbar ? .trailing : [])
            // クリップを動かし始めたら、そのときの高さでタイムラインを固定する。終わったら新しい高さへなめらかに戻す
            .onChange(of: timeline.isEditing) { _, editing in
                if editing {
                    frozenTimelineHeight = TimelineView.preferredHeight(for: project)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        frozenTimelineHeight = nil
                    }
                }
            }
        }
        .photosPicker(isPresented: $showOverlayPicker,
                      selection: $overlayPickerItems,
                      maxSelectionCount: nil,
                      selectionBehavior: .ordered,
                      matching: overlayPickerFilter,
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        // ステッカーパネルの「GIF を読み込む」→「写真から選ぶ」(画像だけ。GIF 以外の写真も写真オーバーレイになる)
        .photosPicker(isPresented: $showGIFPhotoPicker,
                      selection: $overlayPickerItems,
                      maxSelectionCount: nil,
                      selectionBehavior: .ordered,
                      matching: .images,
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        // 字幕を 1 件直したら、ほかの字幕の同じ言葉もまとめて直すか聞く(「カフェ小川」→「CAFE OGAWA」など)
        .alert(termReplacement?.question ?? "",
               isPresented: Binding(get: { termReplacement != nil },
                                    set: { if !$0 { termReplacement = nil } }),
               presenting: termReplacement) { replacement in
            Button(replacement.confirmTitle) { applyTermReplacement(replacement, remember: false) }
            Button(replacement.rememberTitle) { applyTermReplacement(replacement, remember: true) }
            Button("このままにする", role: .cancel) {}
        }
    }

    /// カメラのトラックの区間から、その位置でスイッチャーを開く。パネルを開いている間は nil(メニューに出さない)
    private var openMulticamFromTimeline: ((UUID, Double) -> Void)? {
        guard activePanel == nil else { return nil }
        return { clipID, time in
            guard activePanel == nil else { return }
            // マルチカメラは Pro の機能(クリップの「マルチカメラ」ボタンと同じく、ここでもプランを確かめる)
            guard PlanStore.shared.allows(.multicam) else {
                PlanPaywall.present(for: .multicam)
                return
            }
            player.pause()
            player.seek(to: time)
            history.record(project)
            activeSheet = .multicam(clipID)
        }
    }

    /// 再生ボタンの行とタイムライン(パネルを開いていないとき)
    @ViewBuilder
    private var transportAndTimeline: some View {
        EditorTransportRow(player: player,
                           canUndo: history.canUndo,
                           canRedo: history.canRedo,
                           onUndo: { undoFromButton() },
                           onRedo: { redoFromButton() })
            .padding(.horizontal, 16)
            .frame(height: 44)

        TimelineView(project: project, player: player, history: history,
                     timeline: timeline, selection: $selection,
                     onAdd: { kind in handleTimelineAdd(kind) },
                     onTransition: { clipID in
                         // 切れ目のボタンからトランジションの設定を直接開く
                         guard activePanel == nil else { return }
                         openPanel(.transition(clipID))
                     },
                     onOpenMulticam: openMulticamFromTimeline)
            // クリップを動かしている間は高さを変えない(終わったら新しい高さへ)
            .frame(height: frozenTimelineHeight ?? TimelineView.preferredHeight(for: project))
            // 右側(iPhone Duo のたて持ちで時刻などが出る列)の下までタイムラインを伸ばす
            .ignoresSafeArea(.container, edges: .trailing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timelineWidth = $0 }
            // ほかのアプリから落とした動画・写真は、落とした位置のクリップの切れ目に差し込む
            .onDrop(of: MediaDrop.types, isTargeted: $timelineDropTargeted) { providers, location in
                handleTimelineDrop(providers, at: location)
            }
            .overlay {
                if timelineDropTargeted, canAcceptDrop {
                    MediaDropHighlight(title: String(localized: "クリップとして追加"))
                }
            }
    }

    /// 縦長の作品の幅 ÷ 高さ(9:16 なら 0.5625)。縦長でなければ nil。「元のまま」は映像の大きさで決める
    private var portraitPreviewRatio: CGFloat? {
        if let ratio = project.canvas.aspect.ratio { return ratio < 1 ? ratio : nil }
        let size = player.renderSize
        guard size.width > 0, size.height > size.width else { return nil }
        return size.width / size.height
    }

    /// プレビューのドラッグ・ピンチで映す範囲を変えるクリップ(PreviewClipFraming.swift)。
    /// クリップを 1 つ選んでいて、パネルを開いていない(または「位置・クロップ」を開いている)とき。
    /// 手書き・マスク・範囲選択の最中と、自動リフレーム(人物追尾)を使っているクリップは除く
    private var framingClipID: UUID? {
        guard !isDrawingNew, previewMaskTarget == nil, previewRectSelection == nil, !timeline.isMultiSelecting,
              case .clip(let id) = selection,
              let clip = project.clips.first(where: { $0.id == id }), !clip.reframe.isActive else { return nil }
        if let panel = activePanel, panel != .geometry(id) { return nil }
        return id
    }

    /// プレビュー(ほかのアプリから落とした動画・写真を、再生位置からオーバーレイとして重ねる受け口つき)。
    /// 置き場所いっぱいに広げ、クリップを選んでいれば上下・左右の黒帯でもドラッグ・ピンチで映す範囲を変えられる
    private var previewBlock: some View {
        previewArea
            .background(Color.black)
            .clipFraming(project: project, history: history, player: player,
                         clipID: framingClipID,
                         showsSourceAlways: framingClipID.map { activePanel == .geometry($0) } ?? false)
            .onDrop(of: MediaDrop.types, isTargeted: $previewDropTargeted) { providers in
                handleOverlayDrop(providers)
            }
            .overlay {
                if previewDropTargeted, canAcceptDrop {
                    MediaDropHighlight(title: String(localized: "オーバーレイとして追加"))
                }
            }
    }

    /// パネルを開いている間にタイムラインの代わりに出す細いシークバー。編集している部品の範囲は色の帯で出す
    private var scrubBar: some View {
        EditorScrubBar(player: player,
                       highlight: scrubHighlight,
                       canUndo: history.canUndo || undoRemovesStroke,
                       undoLabel: undoRemovesStroke ? String(localized: "最後の線を消す") : String(localized: "元に戻す"),
                       onUndo: { undoFromButton() })
            .padding(.horizontal, 12)
            .frame(height: 44)
    }

    /// 右上の時刻・電池(ステータスバー)の下端(ウインドウ座標)。枠が取れなければ 0
    private static func statusBarBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let manager = scene.statusBarManager else { return 0 }
        let frame = manager.statusBarFrame
        return frame.height > 0 ? frame.maxY : 0
    }

    /// 右端のセーフエリア(時刻・電池が縦に並ぶ列)がこの幅以上なら、閉じた iPhone Duo でもそこにツールを縦に並べられる
    /// (ふつうの iPhone の横持ちは 59pt なので対象にならない)
    static let sideColumnMinInset: CGFloat = 70
    /// 右の列で、画面の上からここまでは時刻・電池・電波が縦に並ぶ場所として空けておく
    /// (iPhone Duo を開いた横持ちでは約 115pt、閉じたときは約 160pt まで出る)
    static let sideColumnStatusAllowance: CGFloat = 176

    /// 右端のセーフエリアが広い(時刻・電池が縦に並ぶ列がある)か。「ツールを右に置く」を出す条件に使う
    private static func trailingColumnAvailable() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.keyWindow ?? scene.windows.first else { return false }
        return window.safeAreaInsets.right >= sideColumnMinInset
    }

    /// iPhone Duo を開いたときの右の列のツール(下のツールバーと同じ項目を縦に並べる)
    private var sideToolbarColumn: some View {
        toolConfirmationDialogs(
            EditorToolbar(items: toolbarItems,
                          onBack: backAction,
                          onDisabledTap: { reason in showToast(reason, style: .warning) },
                          groupPath: $toolbarGroupPath,
                          pickerItems: $pickerItems,
                          overlayPickerItems: $overlayPickerItems,
                          replacePickerItem: $replacePickerItem,
                          extractAudioPickerItem: $extractAudioPickerItem,
                          slideshowPickerItems: $slideshowPickerItems,
                          axis: .vertical)
        )
    }

    /// remember: 用語として登録し、次の文字起こしからも自動で直す
    private func applyTermReplacement(_ replacement: CaptionTermReplacement, remember: Bool) {
        history.record(project)
        let changed = CaptionTermReplace.apply(replacement, to: project)
        termReplacement = nil
        if remember {
            CaptionTermDictionary.add(from: replacement.from, to: replacement.to)
        }
        if changed > 0 {
            showToast(String(localized: "\(changed) 件のキャプションを直しました"), undo: true)
        }
    }

    /// キャプションの一覧(生成した文と注意書き)を、その場で直すモードで開く。再生位置の行まで送られる
    private func openCaptionList() {
        history.record(project)
        player.pause()
        subtitleSheetSection = .list
        activeSheet = .subtitles
    }

    /// オーバーレイを写真ライブラリから足す。kind が nil なら、動画か写真かを先に聞く
    private func requestOverlayAdd(_ kind: MediaPickKind? = nil) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        guard let kind else {
            mediaKindQuestion = MediaKindQuestion(overlay: true, appendAtEnd: false)
            return
        }
        overlayPickerFilter = kind.filter
        showOverlayPicker = true
    }

    /// 動画・写真を写真ライブラリから足す(下のツールバー・空の画面・タイムラインの「+」)。
    /// kind が nil なら、動画か写真かを先に聞く(選んだほうだけを写真ライブラリに出す)。
    /// appendAtEnd: タイムライン末尾の「+」からのときは末尾に足す(それ以外は再生位置のクリップの後ろ)
    private func requestMediaAdd(appendAtEnd: Bool, kind: MediaPickKind? = nil) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        guard let kind else {
            mediaKindQuestion = MediaKindQuestion(overlay: false, appendAtEnd: appendAtEnd)
            return
        }
        importAppendsAtEnd = appendAtEnd
        mediaPickerFilter = kind.filter
        showMediaPicker = true
    }

    private var mediaKindDialogShown: Binding<Bool> {
        Binding(get: { mediaKindQuestion != nil },
                set: { if !$0 { mediaKindQuestion = nil } })
    }

    @ViewBuilder
    private func mediaKindActions(_ question: MediaKindQuestion) -> some View {
        Button("動画を選ぶ") { answerMediaKind(question, .videos) }
        Button(choosePhotosTitle) { answerMediaKind(question, .photos) }
        Button("キャンセル", role: .cancel) {}
    }

    /// 写真ライブラリを複数選択で開く項目の名前(確認・「追加」「オーバーレイ」のメニュー)。日本語は「写真を選ぶ」のまま。
    /// 1 枚だけ選ぶ表紙の「写真を選ぶ」とはキーを分ける(en などはこちらだけ複数形)
    private var choosePhotosTitle: String {
        String(localized: "写真を選ぶ(複数)", defaultValue: "写真を選ぶ")
    }

    /// 解説スライド用の方眼紙を、写真と同じように再生位置の後ろへ足す。
    /// 足せたら名前を付けて、カラーの画面と同じように差し込んだ所を見せる(続けて置く文字が方眼紙に載るように)
    private func addGridPaperBackground() {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        player.pause()
        importAppendsAtEnd = false
        let canvasSize = player.renderSize
        // 画像を作っている間にもう一度押されないよう、先に読み込み中にする
        isImporting = true
        importTotal = 1
        importDone = 0
        importFraction = nil
        importIsDownloading = false
        importTask = Task { @MainActor in
            // 短辺 1080 の PNG を作るので、メインスレッドを止めない
            let file = await Task.detached(priority: .userInitiated) {
                GridPaperBackground.makeFile(canvasSize: canvasSize)
            }.value
            guard let file else {
                isImporting = false
                importTask = nil
                alertMessage = String(localized: "方眼紙を作れませんでした。")
                return
            }
            let existingIDs = Set(project.clips.map(\.id))
            importSourceOverride = "grid_paper"
            await importLocalFiles([file], securityScoped: false, deleteSourcesAfter: true)
            // キャンセルや読み込みの失敗でクリップが増えなかったときは何もしない
            guard let index = project.clips.firstIndex(where: { !existingIDs.contains($0.id) }) else { return }
            project.clips[index].name = String(localized: "方眼紙")
            if let range = project.outputRange(ofClip: project.clips[index].id) {
                player.seek(to: range.start + 0.02)
            }
        }
    }

    /// 「動画を選ぶ / 写真を選ぶ」の答え。確認が閉じきってから写真ライブラリを開く
    private func answerMediaKind(_ question: MediaKindQuestion, _ kind: MediaPickKind) {
        mediaKindQuestion = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // 待っている間に別の確認や写真ライブラリが開いていたら、重ねて出さない
            guard mediaKindQuestion == nil, !showMediaPicker, !showOverlayPicker else { return }
            if question.overlay {
                requestOverlayAdd(kind)
            } else {
                requestMediaAdd(appendAtEnd: question.appendAtEnd, kind: kind)
            }
        }
    }

    /// 「ファイル」アプリ(Google ドライブ・iCloud Drive など)から追加する
    private func requestFileAdd(appendAtEnd: Bool) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        importAppendsAtEnd = appendAtEnd
        showFileImporter = true
    }

    /// 「カメラで撮る」(CameraRecorderView)。撮った動画は「ファイル」から追加したときと同じように Media フォルダへコピーして足す
    private func requestCameraAdd(appendAtEnd: Bool) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        importAppendsAtEnd = appendAtEnd
        player.pause()
        showCameraRecorder = true
    }

    #if OSMO_LIVE
    /// 「Osmo Pocket で撮る(実験)」(OsmoLiveMonitorView)。録った動画はカメラで撮るときと同じように取り込む
    private func requestOsmoAdd(appendAtEnd: Bool) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        importAppendsAtEnd = appendAtEnd
        player.pause()
        showOsmoRecorder = true
    }
    #endif

    /// 「カラーの画面」(EditorColorScreenPanel)。色と長さを選んだら insertColorScreen で差し込む
    private func requestColorScreenAdd(appendAtEnd: Bool) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        importAppendsAtEnd = appendAtEnd
        player.pause()
        selection = nil
        openPanel(.colorScreen)
    }

    /// 単色の PNG(作品の大きさ)を Media フォルダに作り、写真と同じ静止画クリップとして
    /// 再生位置のクリップの後ろ(末尾の「+」からのときと、クリップが無いときは末尾)に差し込む
    private func insertColorScreen(hex: String, seconds: Double) {
        let appendAtEnd = importAppendsAtEnd
        importAppendsAtEnd = false
        let snapshot = project.snapshot()
        var size = CompositionBuilder.renderSize(for: snapshot, purpose: .export)
        if !(size.width >= 16 && size.height >= 16) { size = CGSize(width: 1920, height: 1080) }
        let color = UIColor(EditorColorHex.color(hex))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let clean = hex.uppercased().replacingOccurrences(of: "#", with: "")
        let destination = MediaStore.uniqueDestination(forFileName: "カラー \(clean).png")
        do {
            guard let data = image.pngData() else { throw MediaStoreError.unreadableImage("PNG") }
            try data.write(to: destination, options: .atomic)
            var clip = try makeStillClip(from: destination)
            clip.name = String(localized: "カラー") + " #" + clean
            clip.endTime = max(0.2, seconds)
            // 差し込む位置: 再生位置のクリップの後ろ(それ以外は末尾)。後ろの部品(字幕・BGM など)も差し込んだ長さだけずらす
            var insertAt: Int? = nil
            if !appendAtEnd, !project.clips.isEmpty,
               let location = project.locate(timelineTime: player.currentTime), location.index < project.clips.count {
                insertAt = location.index + 1
            }
            let rippleTime: Double? = insertAt.flatMap { i in
                i < project.clips.count ? project.outputRange(ofClip: project.clips[i].id)?.start : nil
            }
            let durationBefore = project.layoutDuration
            // 履歴はパネルを開いたときに記録済み(openPanel)
            if let i = insertAt, i <= project.clips.count {
                project.clips.insert(clip, at: i)
            } else {
                project.clips.append(clip)
            }
            if let rippleTime {
                project.insertTimelineGap(at: rippleTime, length: project.layoutDuration - durationBefore)
            } else {
                project.extendChapterLabelsAfterAppend(previousDuration: durationBefore)
            }
            trackMediaAdd(target: "clip", source: "color", count: 1)
            activePanel = nil
            selection = .clip(clip.id)
            if let range = project.outputRange(ofClip: clip.id) {
                player.seek(to: range.start + 0.02)
            }
            showToast(String(localized: "カラーの画面を差し込みました"), undo: true)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            alertMessage = String(localized: "カラーの画面を作れませんでした。\n\(error.localizedDescription)")
        }
    }

    /// Google フォトから追加する
    private func requestGooglePhotosAdd(appendAtEnd: Bool) {
        guard !isImporting, !isLoadingPhotoMedia else { return }
        importAppendsAtEnd = appendAtEnd
        player.pause()
        activeSheet = .googlePhotos
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
        case .coldOpen:
            // メニューの項目は無効にできないので、使えないときは理由をトーストで出す
            if project.clips.isEmpty {
                showToast(String(localized: "先に動画を追加してください"), style: .warning)
            } else if analysis.isRunning {
                showToast(Self.analysisBusyReason, style: .warning)
            } else {
                insertColdOpen()
            }
        }
    }

    // MARK: - 下部(ツールバー or パネル)

    /// panelUsesSideColumn: パネルをいちばん高くしても右の列の時刻などに届かないので、パネルも右の列の下まで伸ばす
    private func bottomArea(maxPanelHeight: CGFloat, panelUsesSideColumn: Bool = false) -> some View {
        toolConfirmationDialogs(bottomAreaContent(maxPanelHeight: maxPanelHeight))
            // 右側(時刻などが縦に並ぶ列)の下までツールバーを伸ばす。時刻などは列の上のほうにしか出ないので、下は空けない
            // (パネルは、高くすると列の上の時刻などに届くときだけ伸ばさない)
            .ignoresSafeArea(.container, edges: activePanel == nil || panelUsesSideColumn ? .trailing : [])
    }

    private func bottomAreaContent(maxPanelHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let panel = activePanel {
                let cancelAction: (() -> Void)? = panel.supportsCancel ? { cancelPanel(panel) } : nil
                let panelHeight: CGFloat = min(panel.height, maxPanelHeight)
                EditorPanelContainer(title: panelTitle(panel),
                                     height: panelHeight,
                                     onCancel: cancelAction,
                                     onClose: { closePanel(panel) },
                                     onCompare: LookCompare.action(for: panel, player: player)) {
                    panelContent(panel)
                }
                // トーストをパネルの上に出すため、高さを控えておく
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { openPanelHeight = $0 }
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
                    // 隙間をなくしたので、タイムラインの「+ 追加」に重ならないよう中央に出す
                    .overlay(alignment: .top) {
                        EditorModeBadge(title: toolbarModeTitle)
                            .offset(y: -22)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: activePanel)
    }

    /// ツールバーから開く確認(オートパンチイン・無音カット)。下のツールバーと、Duo のときの右の列の両方に付ける
    private func toolConfirmationDialogs<Content: View>(_ content: Content) -> some View {
        content
        // 選んでいるクリップがあればそのクリップだけ、なければ全クリップに入れる
        .confirmationDialog("オートパンチイン",
                            isPresented: $showPunchInDialog,
                            titleVisibility: .visible) {
            Button("1.15 倍・話の区切りごと") { applyPunchIn(zoom: 1.15, interval: nil) }
            Button("1.25 倍・話の区切りごと") { applyPunchIn(zoom: 1.25, interval: nil) }
            Button("1.15 倍・4 秒ごと") { applyPunchIn(zoom: 1.15, interval: 4) }
            Button("キャンセル", role: .cancel) {}
        }
        // 全クリップの無音を詰める。テンポだけ選んでもらい、結果はトーストの「元に戻す」で戻せる
        .confirmationDialog("無音カット",
                            isPresented: $showSilenceCutConfirm,
                            titleVisibility: .visible) {
            ForEach(SilenceCutPace.allCases) { pace in
                Button(pace.title) {
                    startSilenceCut(pace: pace)
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        // このクリップの調整をほかの全クリップに写す(各クリップの HSL・LUT も置き換わる。トーストの「元に戻す」で戻せる)
        .confirmationDialog("すべてのクリップに調整を適用しますか?",
                            isPresented: $showLookApplyAllConfirm,
                            titleVisibility: .visible) {
            Button("全クリップに適用") {
                if let clipID = lookApplyAllClipID { applyLookToAllClips(from: clipID) }
                lookApplyAllClipID = nil
            }
            Button("キャンセル", role: .cancel) { lookApplyAllClipID = nil }
        } message: {
            Text("カラープリセット・カラー補正・HSL・LUT がほかのクリップの設定と置き換わります。")
        }
    }

    /// 全クリップとナレーションの音量をそろえる(確認なし。トーストの「元に戻す」で戻せる)
    private func normalizeAll() {
        startNormalize(clipIDs: project.clips.map { $0.id },
                       narrationIDs: project.narration.map { $0.id })
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
            return String(localized: "キャプション\(i + 1)")
        case .bgm:
            return project.audio.bgmName.map { BGMTrack.displayName(forStoredName: $0) } ?? "BGM"
        case .overlay(let overlayID):
            guard let i = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return nil }
            return String(localized: "オーバーレイ\(i + 1)")
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
        case .videoEffect(let effectID):
            return project.videoEffects.first(where: { $0.id == effectID })?.type.displayName
        }
    }

    /// パネルの ✓(完了)。手書き中なら描いた線を追加してから閉じる
    private func closePanel(_ panel: EditorPanel) {
        Analytics.shared.noteAction(Self.analyticsName(of: panel))
        if panel == .drawingCanvas {
            finishDrawing()
        } else {
            // 無料プランの試用(画質補正・背景を消す)は、何か変えて閉じたときだけ確定する(何も変えなければポイントを返す)
            PlanTrial.settle(panel: panel, applied: panelSnapshot.map { project.snapshot() != $0 } ?? true)
            activePanel = nil
            discardOpenHistoryEntryIfUnchanged(after: panel)
            rewindToText(of: panel)
            if case .textEdit(let cueID) = panel {
                offerTermReplacement(cueID: cueID)
            }
            if panel == .textToSpeech,
               !TextToSpeechDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showToast(String(localized: "読み上げる文章は残してあります"), style: .info)
            }
        }
    }

    /// 字幕を直して ✓ で閉じたとき、変えた言葉がほかの字幕にもあれば、まとめて直すか聞く
    private func offerTermReplacement(cueID: UUID) {
        guard let before = panelSnapshot?.subtitles.first(where: { $0.id == cueID })?.text,
              let after = project.subtitles.first(where: { $0.id == cueID })?.text else { return }
        termReplacement = CaptionTermReplace.suggestion(oldText: before, newText: after,
                                                        editedCueID: cueID, in: project.subtitles)
    }

    /// パネルの ✕「キャンセル」。開いたときの状態に戻して閉じる
    private func cancelPanel(_ panel: EditorPanel) {
        Analytics.shared.track("panel_cancel", ["name": Self.analyticsName(of: panel)])
        if panel == .drawingCanvas {
            cancelDrawing()
            return
        }
        let snapshot = panelSnapshot
        activePanel = nil
        panelSnapshot = nil
        // 無料プランの試用(画質補正・背景を消す)を使わずに閉じた → ポイントを返す
        PlanTrial.settle(panel: panel, applied: false)
        // 解析が終わる前に ✕ で閉じたら解析も止める(戻したクリップに、あとから結果が書き込まれないように)
        switch panel {
        case .autoReframe, .stabilize:
            if analysis.isRunning { analysis.cancel() }
        default:
            break
        }
        if let snapshot, project.snapshot() != snapshot {
            // 取り消しも 1 回の操作として履歴に残し、トーストの「元に戻す」で取り消す前に戻せるようにする
            history.record(project)
            project.restore(snapshot)
            showToast(String(localized: "変更を取り消しました"), style: .info, undo: true)
        }
        discardOpenHistoryEntryIfUnchanged(after: panel)
        rewindToText(of: panel)
    }

    /// 何も変えずにパネルを閉じたときは、開くときに記録した履歴を捨てる(↶ が空振りしないように)。
    /// 閉じたあとに書き込みが残るパネルでは捨てない(捨てると、その書き込みを「元に戻す」で戻せなくなる):
    /// オーディオエフェクトは閉じたあとに未反映の変更を書き込み、
    /// オートリフレーム・スタビライザー・カラーマッチは解析が閉じたあとに終わって結果を書き込むことがあり、
    /// ロゴ・透かしは選んだ写真の読み込みが閉じたあとに終わって書き込むことがある
    private func discardOpenHistoryEntryIfUnchanged(after panel: EditorPanel) {
        switch panel {
        case .audioEffects, .narrationEffects, .autoReframe, .stabilize, .colorMatch, .watermark:
            return
        default:
            history.discardLastIfUnchanged(project)
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .speed(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorSpeedPanel(project: project, clip: clip)
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
                EditorFilterPanel(project: project, clip: clip, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .textEdit(let cueID):
            if let cue = project.subtitleBinding(id: cueID) {
                EditorTextEditPanel(cue: cue)
            } else {
                EditorMissingPanelContent()
            }
        case .subtitleStyle, .captionTemplate:
            // キャプションのデザインは 1 つのパネル(テンプレート → 色 → サイズ → 位置 → フォント)
            EditorSubtitleStylePanel(project: project)
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
                    // 合成の作り直しを待たずに、いまの映像へ色を入れる(カラープリセットのパネルと同じ。前は指を止めるまで変わらなかった)
                    .onChange(of: clip.wrappedValue.filter) { _, newValue in
                        player.setLiveFilter(newValue, for: clipID)
                    }
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
                EditorClipAnimationPanel(clip: clip, project: project, player: player)
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
                EditorSpeedCurvePanel(project: project, clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .audioEffects(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorAudioEffectsPanel(url: clip.wrappedValue.url,
                                        name: clip.wrappedValue.name,
                                        effects: clip.audio.effects,
                                        project: project)
            } else {
                EditorMissingPanelContent()
            }
        case .beatDetect(let clipID):
            EditorBeatDetectPanel(project: project, history: history, clipID: clipID)
        case .hsl(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorHSLPanel(clip: clip)
                    .onChange(of: clip.wrappedValue.filter) { _, newValue in
                        player.setLiveFilter(newValue, for: clipID)
                    }
            } else {
                EditorMissingPanelContent()
            }
        case .lut(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorLUTPanel(clip: clip)
                    .onChange(of: clip.wrappedValue.filter) { _, newValue in
                        player.setLiveFilter(newValue, for: clipID)
                    }
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
                EditorTextStylePanel(text: text, canvasSize: player.renderSize, project: project, history: history)
                    .id(textID)
            } else {
                EditorMissingPanelContent()
            }
        case .textAnimation(let textID):
            if let text = project.textClipBinding(id: textID) {
                EditorTextAnimationPanel(text: text, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .textPlacement(let textID):
            if let text = project.textClipBinding(id: textID) {
                EditorTextPlacementPanel(text: text, player: player, project: project)
            } else {
                EditorMissingPanelContent()
            }
        case .textKeyframes(let textID):
            if let text = project.textClipBinding(id: textID) {
                let current = text.wrappedValue
                EditorKeyedKeyframePanel(player: player,
                                         start: current.start,
                                         duration: current.duration,
                                         base: KeyframeInterpolator.Value(center: TextRenderer.placedCenter(for: current, canvasSize: player.renderSize, documentary: project.documentary),
                                                                          scale: current.scale,
                                                                          rotation: current.rotation,
                                                                          opacity: current.opacity),
                                         keyframes: text.keyframes)
            } else {
                EditorMissingPanelContent()
            }
        case .colorScreen:
            EditorColorScreenPanel { hex, seconds in
                insertColorScreen(hex: hex, seconds: seconds)
            }
        case .sticker:
            EditorStickerPanel(onPick: { emoji in
                addSticker(emoji)
            }, onPickVector: { kind in
                addVectorSticker(kind)
            }, onPickGIFFromPhotos: { showGIFPhotoPicker = true }, onPickGIFFromFiles: { showGIFFileImporter = true })

        // ---- 第3弾: オーバーレイ ----
        case .overlayPlacement(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayPlacementPanel(project: project, overlay: overlay, history: history)
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
                EditorOverlayFilterPanel(project: project, overlay: overlay, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayKeyframes(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                let current = overlay.wrappedValue
                EditorKeyedKeyframePanel(player: player,
                                         start: current.start,
                                         duration: current.duration,
                                         base: KeyframeInterpolator.Value(center: NormalizedPoint(x: current.frame.midX,
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
        case .overlayTransition(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayTransitionPanel(overlay: overlay, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayOpacity(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayOpacityPanel(overlay: overlay)
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
                                        effects: narration.effects,
                                        project: project)
            } else {
                EditorMissingPanelContent()
            }
        case .narrationRecord:
            // 追加しても選択は変えない(選択が変わるとパネルが閉じ、結果の表示が見えなくなるため)
            EditorNarrationRecordPanel(project: project,
                                       player: player,
                                       history: history,
                                       onRecorded: { _ in })

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
            // 追加しても選択は変えない(選択が変わるとパネルが閉じ、結果の表示が見えなくなるため)
            EditorTextToSpeechPanel(project: project,
                                    player: player,
                                    history: history,
                                    onAdded: { _ in })

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
        case .subjectFlash(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorSubjectFlashPanel(clip: clip, project: project, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .retouch(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorRetouchPanel(clip: clip, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .clipKeyframes(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorClipKeyframePanel(project: project, player: player, clip: clip)
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
        // 背景を消す / クロマキー
        case .backgroundRemoval(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorClipBackgroundRemovalPanel(clip: clip, project: project, player: player)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayBackgroundRemoval(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayBackgroundRemovalPanel(overlay: overlay, player: player)
            } else {
                EditorMissingPanelContent()
            }

        case .pacing:
            EditorPacingPanel(timeline: timeline, player: player,
                              onRerun: { runPacingCheck() },
                              onFix: { fix in applyEditingFix(fix) })
        case .mosaic(let textID):
            if let clip = project.textClipBinding(id: textID) {
                EditorMosaicPanel(clip: clip, player: player)
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
        case .soundEffects:
            // 追加しても選択は変えない(続けていくつも入れられるように)
            EditorSoundEffectsPanel(project: project,
                                    player: player,
                                    history: history)
        case .dubbing:
            EditorDubbingPanel(project: project,
                               player: player,
                               history: history,
                               analysis: analysis)
        case .videoEffectAdd:
            EditorVideoEffectAddPanel { type in
                addVideoEffect(type)
            }
        case .videoEffect(let effectID):
            if let effect = project.videoEffectBinding(id: effectID) {
                EditorVideoEffectPanel(effect: effect, totalDuration: project.layoutDuration, player: player)
            } else {
                EditorMissingPanelContent()
            }
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

    /// 🔍 機能を探す(いまのツールバー + 何かを選んでいるときは全体の編集も。
    /// 何も選んでいないときは、再生位置のクリップの機能(速度・スプリットなど)も探せる)
    private var toolSearchSheet: some View {
        let isWholeEdit: Bool = selection == nil && !timeline.isMultiSelecting
        let wholeTitle = String(localized: "全体の編集")
        if isWholeEdit, let clipID = clipIDAtPlayhead {
            // 選ぶとそのクリップを選択してから実行する(runSearchedTool)
            let clipTitle = String(localized: "再生位置のクリップ")
            return EditorToolSearchSheet(contextEntries: EditorToolSearchIndex.flatten(EditorToolItem.gatedByPlan(rootItems), isRoot: true,
                                                                                       contextTitle: wholeTitle),
                                         contextTitle: wholeTitle,
                                         rootEntries: EditorToolSearchIndex.flatten(EditorToolItem.gatedByPlan(clipItems(clipID)), isRoot: false,
                                                                                    contextTitle: clipTitle, selectsClipID: clipID),
                                         rootTitle: clipTitle,
                                         onPick: { entry in runSearchedTool(entry) })
        }
        let contextTitle: String = toolbarModeTitle
        let context: [EditorToolSearchEntry] = EditorToolSearchIndex.flatten(toolbarItems, isRoot: isWholeEdit,
                                                                             contextTitle: contextTitle)
        let root: [EditorToolSearchEntry] = isWholeEdit
            ? []
            : EditorToolSearchIndex.flatten(EditorToolItem.gatedByPlan(rootItems), isRoot: true, contextTitle: wholeTitle)
        return EditorToolSearchSheet(contextEntries: context,
                                     contextTitle: contextTitle,
                                     rootEntries: root,
                                     onPick: { entry in runSearchedTool(entry) })
    }

    /// 検索で選んだ機能を実行する。写真を選ぶ機能など、ここから実行できないものはツールバーをその場所まで開く
    private func runSearchedTool(_ entry: EditorToolSearchEntry) {
        let item = entry.item
        // シートが閉じてから実行する(パネルやシートを開く機能があるため)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // 手書きの途中なら、描いた線を追加してから(パネルが閉じると線が消えるため)
            if isDrawingNew { finishDrawing() }
            let needsDeselect: Bool = entry.isRoot && (selection != nil || timeline.isMultiSelecting)
            if needsDeselect {
                timeline.endMultiSelect()
                selection = nil
            } else if let clipID = entry.selectsClipID {
                // 何も選んでいないときに出した再生位置のクリップの機能: そのクリップを選んでから実行する
                selection = .clip(clipID)
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
                } else if case .addOverlay = item.kind {
                    requestOverlayAdd()
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
        case .subtitle: return String(localized: "字幕の編集")
        case .bgm: return String(localized: "BGMの編集")
        case .overlay: return String(localized: "オーバーレイの編集")
        case .narration(let id):
            return project.narration.first(where: { $0.id == id })?.track != nil
                ? String(localized: "音声の編集") : String(localized: "ナレーションの編集")
        case .text(let id):
            return project.textClips.first(where: { $0.id == id })?.isMosaic == true ? String(localized: "モザイクの編集") : String(localized: "テキストの編集")
        case .drawing: return String(localized: "手書きの編集")
        case .marker: return String(localized: "マーカーの編集")
        case .videoEffect: return String(localized: "エフェクトの編集")
        }
    }

    /// ツールバーの項目(有料の機能は、いまのプランで使えなければ王冠付き・タップでプランの画面。EditorToolItem.gatedByPlan)
    private var toolbarItems: [EditorToolItem] {
        EditorToolItem.gatedByPlan(planlessToolbarItems)
    }

    private var planlessToolbarItems: [EditorToolItem] {
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
        case .videoEffect(let effectID):
            return videoEffectItems(effectID)
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
        // タップで写真ライブラリを開く。ファイル・Google フォトは長押しのメニュー
        var sourceMenu: [EditorToolMenuEntry] = []
        // 動画と写真は分けて選ぶ(写真ライブラリには選んだほうだけが出る)
        sourceMenu.append(EditorToolMenuEntry(String(localized: "動画を選ぶ"), systemImage: "video") {
            requestMediaAdd(appendAtEnd: false, kind: .videos)
        })
        sourceMenu.append(EditorToolMenuEntry(choosePhotosTitle, systemImage: "photo") {
            requestMediaAdd(appendAtEnd: false, kind: .photos)
        })
        sourceMenu.append(EditorToolMenuEntry(String(localized: "方眼紙の背景"), systemImage: "squareshape.split.3x3") {
            addGridPaperBackground()
        })
        sourceMenu.append(EditorToolMenuEntry(String(localized: "ファイル"), systemImage: "folder") {
            requestFileAdd(appendAtEnd: false)
        })
        sourceMenu.append(EditorToolMenuEntry(String(localized: "カメラで撮る"), systemImage: "camera") {
            requestCameraAdd(appendAtEnd: false)
        })
        #if OSMO_LIVE
        if AppSettings.shared.developerMode {
            sourceMenu.append(EditorToolMenuEntry(String(localized: "Osmo Pocket で撮る(実験)"), systemImage: "camera.aperture") {
                requestOsmoAdd(appendAtEnd: false)
            })
        }
        #endif
        sourceMenu.append(EditorToolMenuEntry(String(localized: "カラーの画面"), systemImage: "rectangle.fill") {
            requestColorScreenAdd(appendAtEnd: false)
        })
        if GoogleOAuth.isConfigured {
            sourceMenu.append(EditorToolMenuEntry(String(localized: "Google フォト"), systemImage: "photo.on.rectangle.angled") {
                requestGooglePhotosAdd(appendAtEnd: false)
            })
        }
        // 並び(その他/設定 の前に 8 つまで): 追加 / 分割 / テキスト / オーディオ / エフェクト / オーバーレイ / AI / 全体
        // タップでメニュー(動画を選ぶ / 写真を選ぶ / ファイル / カメラで撮る / カラーの画面 / Google フォト)。長押しは分かりにくいため
        items.append(EditorToolItem(String(localized: "追加"), systemImage: "plus.rectangle.on.rectangle",
                                    enabled: !isImporting,
                                    disabledReason: Self.importingReason) {
            requestMediaAdd(appendAtEnd: false)
        }.withTapMenu(sourceMenu))
        // 何も選んでいなければ再生位置のクリップを切る(切ったあとは左側を選んだまま)
        items.append(EditorToolItem(String(localized: "分割"), systemImage: "scissors", id: "root-split",
                                    enabled: !project.clips.isEmpty,
                                    disabledReason: String(localized: "先に動画を追加してください")) {
            withClipAtPlayhead { clipID in
                splitClip(clipID)
            }
        })
        items.append(EditorToolItem.group(String(localized: "テキスト"), systemImage: "textformat", id: "group-text",
                                          items: textGroupItems))
        items.append(EditorToolItem.group(String(localized: "オーディオ"), systemImage: "music.note", id: "group-audio",
                                          items: audioGroupItems))
        // 映像エフェクトはエフェクト群の先頭に入れた(root 直置きはやめた)
        items.append(EditorToolItem.group(String(localized: "エフェクト"), systemImage: "sparkles", id: "group-effects",
                                          items: effectGroupItems))
        // タップで「動画を選ぶ / 写真を選ぶ」(写真ライブラリには選んだほうだけが出る)
        let overlayMenu = [
            EditorToolMenuEntry(String(localized: "動画を選ぶ"), systemImage: "video") {
                requestOverlayAdd(.videos)
            },
            EditorToolMenuEntry(choosePhotosTitle, systemImage: "photo") {
                requestOverlayAdd(.photos)
            },
        ]
        items.append(EditorToolItem(String(localized: "オーバーレイ"), systemImage: "photo.on.rectangle",
                                    enabled: !isImporting,
                                    disabledReason: Self.importingReason) {
            requestOverlayAdd()
        }.withTapMenu(overlayMenu))
        items.append(EditorToolItem.group("AI", systemImage: "wand.and.stars", id: "group-ai",
                                          items: autoGroupItems))
        items.append(EditorToolItem.group(String(localized: "全体"), systemImage: "rectangle.3.group", id: "group-whole",
                                          items: wholeGroupItems))
        items.append(EditorToolItem.more(rootMoreItems))
        // 「その他」の右隣に固定(ツールバーが分けて出す)
        items.append(EditorToolItem.settings(rootSettingsItems))
        return items
    }

    /// テキスト: テキスト / 字幕(手で 1 件) / 自動字幕 / 字幕一覧 / 名前テロップ / 章タイトル / ステッカー
    /// (文字起こし編集は AI 群だけに置く)
    private var textGroupItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "テキスト"), systemImage: "textformat") {
            addTextAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "字幕"), systemImage: "captions.bubble") {
            addSubtitleAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "自動字幕"), systemImage: "text.bubble") {
            history.record(project)
            activeSheet = .subtitles
        })
        items.append(EditorToolItem(String(localized: "字幕一覧"), systemImage: "list.bullet.rectangle", id: "text-caption-list",
                                    enabled: !project.subtitles.isEmpty,
                                    disabledReason: String(localized: "先に「自動字幕」で字幕を作ってください")) {
            openCaptionList()
        })
        items.append(EditorToolItem(String(localized: "名前テロップ"), systemImage: "person.text.rectangle") {
            addLowerThirdAtPlayhead()
        })
        // 章タイトルはテロップ(テキスト)として入れる(テキストのレーンに乗り、動かす・伸ばす・見た目を変えるが普通のテロップと同じ)。
        // 以前の黒い画面の章タイトルが残っているプロジェクトでは、長押しからそちらの編集も開ける
        var chapter = EditorToolItem(String(localized: "章タイトル"), systemImage: "text.below.photo") {
            addChapterTitleTelop()
        }
        if !project.titleCards.isEmpty {
            chapter = chapter.withTapMenu([
                EditorToolMenuEntry(String(localized: "テロップで章タイトルを入れる"), systemImage: "textformat") {
                    addChapterTitleTelop()
                },
                EditorToolMenuEntry(String(localized: "以前の章タイトル(黒い画面)を編集"), systemImage: "rectangle.on.rectangle") {
                    addTitleCardAtPlayhead()
                },
            ])
        }
        items.append(chapter)
        items.append(EditorToolItem(String(localized: "ステッカー"), systemImage: "face.smiling") {
            openPanel(.sticker)
        })
        return items
    }

    /// オーディオ: BGM / ナレーション / 効果音 / AI読み上げ / 音声抽出
    private var audioGroupItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem("BGM", systemImage: "music.note") {
            history.record(project)
            activeSheet = .audio
        })
        // タイムラインの「+ 追加」の「ナレーション」と同じ名前・同じアイコン
        items.append(EditorToolItem(String(localized: "ナレーション"), systemImage: "mic") {
            openPanel(.narrationRecord)
        })
        items.append(EditorToolItem(String(localized: "効果音"), systemImage: "speaker.wave.3") {
            openPanel(.soundEffects)
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

    /// エフェクト: 映像エフェクト / モザイク / 顔モザイク / 手書き
    private var effectGroupItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        // 画面全体にかける映像エフェクト(揺れ・VHS・キラキラなど)。タイムラインに部品として置く
        items.append(EditorToolItem(String(localized: "映像エフェクト"), systemImage: "camera.filters", id: "root-video-effects",
                                    enabled: !project.clips.isEmpty,
                                    disabledReason: String(localized: "先に動画を追加してください")) {
            openPanel(.videoEffectAdd)
        })
        items.append(EditorToolItem(String(localized: "モザイク"), systemImage: "square.grid.3x3", id: "addMosaic") {
            addMosaicAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "顔モザイク"), systemImage: "face.dashed", id: "face-mosaic",
                                    enabled: !analysis.isRunning && !project.clips.isEmpty,
                                    disabledReason: project.clips.isEmpty ? String(localized: "先に動画を追加してください") : Self.analysisBusyReason) {
            autoMosaicFaces()
        })
        items.append(EditorToolItem(String(localized: "手書き"), systemImage: "pencil.tip.crop.circle") {
            startDrawing()
        })
        return items
    }

    /// 全体: 全体の仕上げ / ロゴ・透かし / 音量そろえ(比率は「設定」、無音カットは AI 群へ移した)
    private var wholeGroupItems: [EditorToolItem] {
        let hasNarration = !project.narration.isEmpty
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "全体の仕上げ"), systemImage: "film.stack") {
            openPanel(.documentary)
        })
        items.append(EditorToolItem(String(localized: "ロゴ・透かし"), systemImage: "seal") {
            openPanel(.watermark)
        })
        items.append(EditorToolItem(String(localized: "音量そろえ"), systemImage: "waveform", id: "root-loudness",
                                    enabled: hasAudioClips || hasNarration,
                                    disabledReason: String(localized: "音声のあるクリップやナレーションがありません")) {
            normalizeAll()
        })
        return items
    }

    /// AI: AI を使う機能をここに集める。小見出しは付けず、ショートでテンポを作る機能を先頭に並べる。
    /// ほかのグループにも入口がある AI読み上げ(オーディオ)・顔モザイク(エフェクト)・自動字幕と字幕一覧(テキスト)・
    /// 自動補正(クリップのカラー)は外した。終了画面(横長の動画向け)とスライドショーは最後
    private var autoGroupItems: [EditorToolItem] {
        let running = analysis.isRunning
        let noClips = project.clips.isEmpty
        let needClips = String(localized: "先に動画を追加してください")
        let needCaptions = String(localized: "先に「自動字幕」で字幕を作ってください")
        var items: [EditorToolItem] = []

        items.append(EditorToolItem(String(localized: "おまかせ編集"), systemImage: "sparkles.rectangle.stack.fill",
                                    enabled: !running, disabledReason: Self.analysisBusyReason) {
            player.pause()
            activePanel = nil
            activeSheet = .autoEdit
        })
        items.append(EditorToolItem(String(localized: "無音カット"), systemImage: "waveform.slash", id: "ai-silence",
                                    enabled: hasAudioClips,
                                    disabledReason: String(localized: "音声のあるクリップがありません")) {
            showSilenceCutConfirm = true
        })
        items.append(EditorToolItem(String(localized: "言いよどみカット"), systemImage: "scissors.badge.ellipsis", id: "ai-fillers",
                                    enabled: !project.subtitles.isEmpty,
                                    disabledReason: needCaptions) {
            cutFillers()
        })
        items.append(EditorToolItem(String(localized: "文字起こし編集"), systemImage: "text.quote", id: "ai-transcript-edit",
                                    enabled: !noClips, disabledReason: needClips) {
            openTranscriptEdit()
        })
        items.append(EditorToolItem(String(localized: "冒頭フック"), systemImage: "bolt.fill", id: "ai-coldopen",
                                    enabled: !running && !noClips, disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            insertColdOpen()
        })
        items.append(EditorToolItem(String(localized: "オートパンチイン"), systemImage: "plus.magnifyingglass", id: "ai-punchin",
                                    enabled: !running && !noClips, disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            showPunchInDialog = true
        })
        items.append(EditorToolItem(String(localized: "編集チェック"), systemImage: "gauge.with.dots.needle.33percent", id: "ai-editcheck",
                                    enabled: !running && !noClips,
                                    disabledReason: noClips ? needClips : Self.analysisBusyReason) {
            runPacingCheck()
        })
        items.append(EditorToolItem(String(localized: "スピーチを強調"), systemImage: "person.wave.2", id: "ai-speech",
                                    enabled: !noClips, disabledReason: needClips) {
            withClipAtPlayhead { clipID in
                openPanel(.audioEffects(clipID))
            }
        })
        items.append(EditorToolItem(String(localized: "オートリフレーム"), systemImage: "person.crop.rectangle", id: "ai-reframe",
                                    enabled: !noClips, disabledReason: needClips) {
            withClipAtPlayhead { clipID in
                openPanel(.autoReframe(clipID))
            }
        })
        items.append(EditorToolItem(String(localized: "字幕を翻訳"), systemImage: "character.book.closed", id: "ai-translate",
                                    enabled: !project.subtitles.isEmpty,
                                    disabledReason: needCaptions) {
            history.record(project)
            // 字幕のシートを「翻訳」を開いた状態で出す
            subtitleSheetSection = .translate
            activeSheet = .subtitles
        })
        items.append(EditorToolItem(String(localized: "吹き替え"), systemImage: "person.wave.2.fill", id: "ai-dubbing",
                                    enabled: !project.subtitles.isEmpty && !running,
                                    disabledReason: project.subtitles.isEmpty ? needCaptions : Self.analysisBusyReason) {
            openPanel(.dubbing)
        })
        items.append(EditorToolItem(String(localized: "おまかせテンプレ"), systemImage: "square.grid.2x2",
                                    enabled: !running, disabledReason: Self.analysisBusyReason) {
            openPanel(.autoEditTemplates)
        })
        items.append(EditorToolItem(String(localized: "AI台本"), systemImage: "text.badge.star", id: "ai-script") {
            player.pause()
            activePanel = nil
            activeSheet = .scriptWriter
        })
        // 縦の動画では出さない(末尾に止まった 10 秒ができ、ループ再生の邪魔になるため)
        if !isVerticalProject {
            items.append(EditorToolItem(String(localized: "終了画面"), systemImage: "rectangle.bottomthird.inset.filled", id: "ai-endscreen",
                                        enabled: !noClips, disabledReason: needClips) {
                appendEndScreen()
            })
        }
        let slideshowBlocked = isImporting || running
        items.append(EditorToolItem.addSlideshow(String(localized: "スライドショー"), systemImage: "photo.stack",
                                                 enabled: !slideshowBlocked,
                                                 disabledReason: Self.busyReason))
        return items
    }

    /// 縦長(9:16・4:5、または元のままで縦の素材)のプロジェクトか
    private var isVerticalProject: Bool {
        if let ratio = project.canvas.aspect.ratio { return ratio < 1 }
        guard let first = project.clips.first else { return false }
        // 90° / 270° 回したクリップは縦横が入れ替わる(CompositionBuilder.renderSize と同じ)
        let size = ClipFramingMath.sourceSize(of: first)
        return size.height > size.width
    }

    /// 再生位置のクリップを選んでから処理する(何も選んでいないときのスプリットや、クリップ用の AI 機能のため)
    private func withClipAtPlayhead(_ body: (UUID) -> Void) {
        guard let clipID = clipIDAtPlayhead else {
            showToast(String(localized: "再生位置をクリップの上に合わせてください"), style: .warning)
            return
        }
        selection = .clip(clipID)
        body(clipID)
    }

    /// ルートの「その他」: マーカー / パーツ / サムネ / 前回と比較(設定の類いは「設定」グループ)。
    /// ファイル・カメラで撮る・カラーの画面は「追加」の長押しにあるので、ここには置かない
    private var rootMoreItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "マーカー"), systemImage: "flag") {
            addMarkerAtPlayhead()
        })
        items.append(EditorToolItem(String(localized: "パーツ"), systemImage: "rectangle.stack.badge.plus") {
            openPanel(.formatKit)
        })
        items.append(EditorToolItem(String(localized: "サムネ"), systemImage: "photo.badge.plus") {
            player.pause()
            activePanel = nil
            activeSheet = .coverMaker
        })
        items.append(EditorToolItem(String(localized: "前回と比較"), systemImage: "arrow.left.arrow.right") {
            player.pause()
            activePanel = nil
            activeSheet = .compare
        })
        return items
    }

    /// ルートの「設定」(「その他」の右隣に固定): 比率 / 動画の置き場所 / (Duo のとき)ツールの置き場所 / このプロジェクトを空にする
    private var rootSettingsItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "比率"), systemImage: "aspectratio") {
            openPanel(.aspect)
        })
        items.append(EditorToolItem(String(localized: "動画の置き場所"), systemImage: "rectangle.center.inset.filled") {
            isChoosingMediaMode = true
        })
        // SNS の表示ガイド: タップで なし → TikTok → Reels → Shorts → すべて の順に切り替え、長押しで直接選ぶ(プレビュー左上のボタンと同じ)
        items.append(EditorToolItem(String(localized: "表示ガイド"), systemImage: "rectangle.dashed", id: "safe-zone-guide") {
            safeZoneGuide = safeZoneGuide.next
            showToast(safeZoneGuide.isOn ? String(localized: "\(safeZoneGuide.title)の表示ガイドを出しました")
                                         : String(localized: "表示ガイドを消しました"), style: .info)
        }.withTapMenu(SafeZoneGuide.allCases.map { guide in
            EditorToolMenuEntry(guide.title, systemImage: guide == safeZoneGuide ? "checkmark" : "rectangle.dashed") {
                safeZoneGuide = guide
            }
        }))
        // iPhone Duo(開いたとき、または閉じていても右に時刻・電池の列がある画面): 下のツールを右の列に置く / 下に戻す
        // (設定の「Duo を開いたときはツールを右に」と同じ)
        if isLargeWindow || Self.trailingColumnAvailable() {
            items.append(EditorToolItem(toolbarOnSide ? String(localized: "ツールを下に戻す") : String(localized: "ツールを右に置く"),
                                        systemImage: toolbarOnSide ? "rectangle.bottomthird.inset.filled" : "sidebar.trailing",
                                        id: "toolbar-side") {
                toolbarOnSide.toggle()
            })
        }
        items.append(EditorToolItem(String(localized: "このプロジェクトを空にする"), systemImage: "trash", destructive: true) {
            showClearProjectConfirm = true
        })
        return items
    }

    // MARK: クリップ

    // クリップを選んだとき(監査で決めた順): 分割 → 音量 → 速度 → カラー → モーション → トランジション → AI → 削除(赤・末尾)。
    // 分割を戻す・置き換え・オーディオ・複製などは「その他」の中。
    // 同じ種類の機能はどの部品でも同じグループ名(カラー / モーション / オーディオ)
    private func clipItems(_ clipID: UUID) -> [EditorToolItem] {
        let clip = project.clips.first(where: { $0.id == clipID })
        let isStill = clip?.isStill ?? false
        let isReversed = clip?.isReversed ?? false
        let hasAudio = (clip?.hasAudio ?? false) && !isStill
        let busy = mediaToolProgress != nil

        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "分割"), systemImage: "scissors") {
            splitClip(clipID)
        })
        if !isStill {
            items.append(EditorToolItem(String(localized: "音量"), systemImage: "speaker.wave.2",
                                        enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
                openPanel(.volume(clipID))
            })
            // 映像と音声のリンクを解除して、音声を A1 で別に動かせるようにする(映像はミュート)
            let detachReason: String? = clip.flatMap { EditorProject.audioDetachBlockReason($0) }
            items.append(EditorToolItem(String(localized: "リンク解除"), systemImage: "rectangle.split.1x2",
                                        enabled: detachReason == nil, disabledReason: detachReason) {
                detachAudio(clipID: clipID)
            })
            var speedItems: [EditorToolItem] = []
            speedItems.append(EditorToolItem(String(localized: "速度"), systemImage: "speedometer") {
                openPanel(.speed(clipID))
            })
            speedItems.append(EditorToolItem(String(localized: "タイムリマップ"), systemImage: "timeline.selection") {
                openPanel(.speedCurve(clipID))
            })
            // マルチカメラのクリップは逆再生にできない(合成がアングルを使わなくなり、切替が黙って消えて見えるため)。解除はいつでもできる
            let hasAngles = !(clip?.multicam.angles.isEmpty ?? true)
            let reverseBlocked = !isReversed && hasAngles
            speedItems.append(EditorToolItem(isReversed ? String(localized: "逆再生を解除") : String(localized: "逆再生"),
                                             systemImage: isReversed ? "arrow.uturn.backward.circle.fill" : "arrow.uturn.backward",
                                             id: "reverse",
                                             enabled: !busy && !reverseBlocked,
                                             disabledReason: reverseBlocked
                                                ? String(localized: "マルチカメラのクリップは逆再生にできません")
                                                : Self.busyReason) {
                toggleReverse(clipID)
            })
            speedItems.append(EditorToolItem(String(localized: "フレーム保持"), systemImage: "pause.rectangle",
                                             enabled: !busy, disabledReason: Self.busyReason) {
                freezeFrame(clipID)
            })
            items.append(EditorToolItem.group(String(localized: "速度"), systemImage: "speedometer", id: "group-speed",
                                              items: speedItems))
        }
        items.append(EditorToolItem.group(String(localized: "カラー"), systemImage: "circle.lefthalf.filled", id: "group-color",
                                          items: colorGroupItems(clipID)))
        items.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion",
                                          items: clipMotionItems(clipID, isStill: isStill)))
        items.append(EditorToolItem(String(localized: "トランジション"), systemImage: "arrow.left.arrow.right.square") {
            openPanel(.transition(clipID))
        })
        items.append(EditorToolItem.group("AI", systemImage: "wand.and.stars", id: "group-clip-ai",
                                          items: clipAIItems(clipID, isStill: isStill, hasAudio: hasAudio)))
        // 削除(詰める挙動はそのまま)。赤で末尾
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            deleteClip(clipID)
        })

        // ここから下は「その他」の中: 分割を戻す / 置き換え / オーディオ / 複製 ほか
        var more: [EditorToolItem] = []
        // 分割を戻す: 次のクリップが同じ素材の続きのときだけ(ClipRejoin.swift)
        let canRejoin = project.index(of: clipID).map { ClipRejoin.canRejoin(project.clips, at: $0) } ?? false
        more.append(EditorToolItem(String(localized: "分割を戻す"), systemImage: "arrow.right.and.line.vertical.and.arrow.left",
                                   enabled: canRejoin,
                                   disabledReason: String(localized: "次のクリップが同じ素材の続きではありません")) {
            rejoinClip(clipID)
        })
        more.append(EditorToolItem.replaceMedia(String(localized: "置き換え"), systemImage: "arrow.triangle.2.circlepath",
                                                enabled: !(isImporting || busy),
                                                disabledReason: Self.busyReason))
        if !isStill {
            more.append(EditorToolItem.group(String(localized: "オーディオ"), systemImage: "waveform", id: "group-clip-audio",
                                             items: clipAudioItems(clipID, hasAudio: hasAudio)))
        }
        more.append(contentsOf: clipMoreItems(clipID, clip: clip, isStill: isStill,
                                              hasAudio: hasAudio, busy: busy))
        items.append(EditorToolItem.more(more))
        return items
    }

    /// クリップの「AI」: 画質補正 だけ(レタッチ(小顔・メイク・体型)は外した。美肌は画質補正にある)。
    /// スピーチを強調はオーディオの音声効果、自動補正はカラー、オートリフレーム・自動字幕・顔モザイクは root(AI / テキスト / エフェクト)にある
    private func clipAIItems(_ clipID: UUID, isStill: Bool, hasAudio: Bool) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "画質補正"), systemImage: "sparkles.tv", id: "clip-ai-quality") {
            openPanel(.enhance(clipID))
        }.freeToAdjust(!(project.clips.first(where: { $0.id == clipID })?.enhance.isIdentity ?? true)))
        return items
    }

    /// クリップの「モーション」: 位置・クロップ / アニメーション / キーフレーム / スタビライザー / マスク / 背景を消す / クロマキー / 被写体フラッシュ / 3Dズーム
    /// (オートリフレームは root の AI 群だけ)
    private func clipMotionItems(_ clipID: UUID, isStill: Bool) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "位置・クロップ"), systemImage: "crop.rotate") {
            openPanel(.geometry(clipID))
        })
        items.append(EditorToolItem(String(localized: "アニメーション"), systemImage: "sparkles.rectangle.stack") {
            openPanel(.clipAnimation(clipID))
        })
        items.append(EditorToolItem(String(localized: "キーフレーム"), systemImage: "diamond", id: "clip-keyframes") {
            openPanel(.clipKeyframes(clipID))
        })
        if !isStill {
            items.append(EditorToolItem(String(localized: "スタビライザー"), systemImage: "gyroscope") {
                openPanel(.stabilize(clipID))
            })
        }
        items.append(EditorToolItem(String(localized: "マスク"), systemImage: "circle.dashed") {
            openPanel(.mask(clipID))
        })
        // 背景を消す / クロマキー(同じパネル。オフなら押した方の方法で始める。キャンセルで戻る)
        items.append(EditorToolItem(String(localized: "背景を消す"), systemImage: "person.and.background.dotted", id: "clip-bg-removal") {
            openPanel(.backgroundRemoval(clipID))
            if let i = project.index(of: clipID), !project.clips[i].backgroundRemoval.isActive {
                project.clips[i].backgroundRemoval.mode = .auto
            }
        }.freeToAdjust(project.clips.first(where: { $0.id == clipID })?.backgroundRemoval.isActive ?? false))
        items.append(EditorToolItem(String(localized: "クロマキー"), systemImage: "eyedropper", id: "clip-chroma-key") {
            openPanel(.backgroundRemoval(clipID))
            if let i = project.index(of: clipID), !project.clips[i].backgroundRemoval.isActive {
                project.clips[i].backgroundRemoval.mode = .chroma
            }
        })
        items.append(EditorToolItem(String(localized: "被写体フラッシュ"), systemImage: "sparkle", id: "clip-subject-flash") {
            openPanel(.subjectFlash(clipID))
        })
        if isStill {
            items.append(EditorToolItem(String(localized: "3Dズーム"), systemImage: "cube.transparent") {
                openPanel(.parallax(clipID))
            })
        }
        return items
    }

    /// クリップの「オーディオ」(その他の中): 音声効果(スピーチを強調もここ) / J/Lカット / ビート合わせ
    private func clipAudioItems(_ clipID: UUID, hasAudio: Bool) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "音声効果"), systemImage: "waveform.and.magnifyingglass", id: "clip-audio-effects",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.audioEffects(clipID))
        })
        items.append(EditorToolItem(String(localized: "J/Lカット"), systemImage: "waveform.path",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.jlCut(clipID))
        })
        items.append(EditorToolItem(String(localized: "ビート合わせ"), systemImage: "metronome",
                                    enabled: hasAudio, disabledReason: Self.noAudioClipReason) {
            openPanel(.beatDetect(clipID))
        })
        return items
    }

    /// 色調整: カラープリセット / 自動補正(ここだけ) / カラー補正 / カラーをコピー・貼り付け / 全体に適用 / HSL / 色合わせ / LUT / スコープ
    private func colorGroupItems(_ clipID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "カラープリセット"), systemImage: "paintpalette") {
            openPanel(.filter(clipID))
        })
        items.append(EditorToolItem(String(localized: "自動補正"), systemImage: "wand.and.rays") {
            autoEnhance(clipID)
        })
        items.append(EditorToolItem(String(localized: "カラー補正"), systemImage: "slider.horizontal.3") {
            openPanel(.colorAdjust(clipID))
        })
        // 調整(プリセット・補正・HSL・LUT すべて)をほかのクリップに写す(LookClipboard.swift)
        items.append(EditorToolItem(String(localized: "カラーをコピー"), systemImage: "doc.on.doc", id: "look-copy") {
            copyLook(ofClip: clipID)
        })
        items.append(EditorToolItem(String(localized: "カラーを貼り付け"), systemImage: "doc.on.clipboard", id: "look-paste",
                                    enabled: LookClipboard.shared.hasLook, disabledReason: Self.emptyLookReason) {
            pasteLook(toClips: [clipID])
        })
        items.append(EditorToolItem(String(localized: "全体に適用"), systemImage: "square.stack.3d.down.right", id: "look-apply-all",
                                    enabled: project.clips.count > 1,
                                    disabledReason: String(localized: "クリップが 2 つ以上あるときに使えます")) {
            lookApplyAllClipID = clipID
            showLookApplyAllConfirm = true
        })
        // ここから下は慣れた人向け(区切り線だけ)
        items.append(EditorToolItem.section(""))
        items.append(EditorToolItem(String(localized: "HSL セカンダリ"), systemImage: "paintpalette") {
            openPanel(.hsl(clipID))
        })
        items.append(EditorToolItem(String(localized: "カラーマッチ"), systemImage: "eyedropper.halffull",
                                    enabled: project.clips.count > 1,
                                    disabledReason: String(localized: "クリップが 2 つ以上あるときに使えます")) {
            openPanel(.colorMatch(clipID))
        })
        items.append(EditorToolItem("LUT", systemImage: "cube", id: "clip-lut") {
            openPanel(.lut(clipID))
        })
        items.append(EditorToolItem(String(localized: "カラースコープ"), systemImage: "chart.bar.xaxis") {
            player.pause()
            activePanel = nil
            activeSheet = .scopes(clipID)
        })
        return items
    }

    /// クリップの「その他」(分割を戻す・置き換え・オーディオの後ろ): 複製 / 複数選択 / 前へ・後ろへ移動 / スリップ / トリミングを解除 / マルチカメラ / パーツとして保存
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
            if moveClipsRippling([clipID], by: -1) { showToast(String(localized: "前へ移動しました"), undo: true) }
        })
        items.append(EditorToolItem(String(localized: "後ろへ移動"), systemImage: "arrow.right.to.line",
                                    enabled: index < project.clips.count - 1, disabledReason: String(localized: "これ以上後ろには動かせません")) {
            if moveClipsRippling([clipID], by: 1) { showToast(String(localized: "後ろへ移動しました"), undo: true) }
        })
        let canSlip = !isStill && (clip.map { $0.duration - ($0.endTime - $0.startTime) > 0.05 } ?? false)
        items.append(EditorToolItem(String(localized: "スリップ"), systemImage: "arrow.left.and.right.square",
                                    enabled: canSlip,
                                    disabledReason: String(localized: "元の動画をすべて使っているので、ずらせません")) {
            openPanel(.slip(clipID))
        })
        // 「詳細設定」はやめた(ほかの操作はツールバーとパネルにある)。トリミングを解除だけここに移した
        if !isStill {
            items.append(EditorToolItem(String(localized: "トリミングを解除"), systemImage: "arrow.left.and.right",
                                        enabled: clip?.isTrimmed ?? false,
                                        disabledReason: String(localized: "トリミングしていません")) {
                resetTrim(clipID)
            })
            // 逆再生中のクリップは合成でマルチカメラを使わないので開かせない(切り替えても映らない)
            let isReversedClip = clip.map { $0.isReversed && $0.reversedURL != nil } ?? false
            items.append(EditorToolItem(String(localized: "マルチカメラ"), systemImage: "camera.on.rectangle", id: "clip-multicam",
                                        enabled: !isReversedClip,
                                        disabledReason: String(localized: "逆再生中のクリップでは使えません。逆再生を解除してください")) {
                history.record(project)
                activeSheet = .multicam(clipID)
            })
        }
        items.append(EditorToolItem(String(localized: "パーツとして保存"), systemImage: "rectangle.stack.badge.plus") {
            openPanel(.formatKit)
        })
        return items
    }

    /// クリップを元の長さに戻す。キャプションやテキストなどは同じ素材の位置に付けたまま動かす(TimelineRipple.swift)
    private func resetTrim(_ clipID: UUID) {
        guard let index = project.index(of: clipID) else { return }
        history.record(project)
        let layout = project.captureClipLayout()
        project.clips[index].startTime = 0
        project.clips[index].endTime = project.clips[index].duration
        project.rippleTimelineItems(from: layout)
        showToast(String(localized: "元の長さに戻しました"), undo: true)
    }

    // MARK: 重ねた素材(オーバーレイ)

    // オーバーレイ・テキスト・モザイクは同じ並び: 主操作 → 見た目(モーション・カラー) → 音 → 複製 → 削除(赤・末尾)
    private func overlayItems(_ overlayID: UUID) -> [EditorToolItem] {
        let isImage = project.overlays.first(where: { $0.id == overlayID })?.isImage ?? false
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "位置・サイズ"), systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
            openPanel(.overlayPlacement(overlayID))
        })
        items.append(EditorToolItem(String(localized: "トランジション"), systemImage: "arrow.left.arrow.right.square") {
            openPanel(.overlayTransition(overlayID))
        })
        items.append(EditorToolItem(String(localized: "不透明度"), systemImage: "circle.dotted") {
            openPanel(.overlayOpacity(overlayID))
        })
        var motion: [EditorToolItem] = []
        motion.append(EditorToolItem(String(localized: "キーフレーム"), systemImage: "diamond") {
            openPanel(.overlayKeyframes(overlayID))
        })
        motion.append(EditorToolItem(String(localized: "トラッキング"), systemImage: "scope") {
            openPanel(.overlayTracking(overlayID))
        })
        motion.append(EditorToolItem(String(localized: "ズーム・パン"), systemImage: "arrow.up.left.and.arrow.down.right",
                                     id: "Ken Burns") {
            openPanel(.overlayKenBurns(overlayID))
        })
        motion.append(EditorToolItem(String(localized: "マスク"), systemImage: "circle.dashed") {
            openPanel(.overlayMask(overlayID))
        })
        // 背景を消す / クロマキー(消した部分は透明 → 下の映像の上に人物だけを重ねる)
        motion.append(EditorToolItem(String(localized: "背景を消す"), systemImage: "person.and.background.dotted", id: "overlay-bg-removal") {
            openPanel(.overlayBackgroundRemoval(overlayID))
            if let i = project.overlays.firstIndex(where: { $0.id == overlayID }),
               !project.overlays[i].backgroundRemoval.isActive {
                project.overlays[i].backgroundRemoval.mode = .auto
            }
        }.freeToAdjust(project.overlays.first(where: { $0.id == overlayID })?.backgroundRemoval.isActive ?? false))
        motion.append(EditorToolItem(String(localized: "クロマキー"), systemImage: "eyedropper", id: "overlay-chroma-key") {
            openPanel(.overlayBackgroundRemoval(overlayID))
            if let i = project.overlays.firstIndex(where: { $0.id == overlayID }),
               !project.overlays[i].backgroundRemoval.isActive {
                project.overlays[i].backgroundRemoval.mode = .chroma
            }
        })
        if isImage {
            motion.append(EditorToolItem(String(localized: "3Dズーム"), systemImage: "cube.transparent") {
                openPanel(.overlayParallax(overlayID))
            })
        }
        items.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion", items: motion))
        var color: [EditorToolItem] = []
        color.append(EditorToolItem(String(localized: "カラープリセット"), systemImage: "paintpalette") {
            openPanel(.overlayFilter(overlayID))
        })
        color.append(EditorToolItem(String(localized: "描画モード"), systemImage: "square.on.square.intersection.dashed") {
            openPanel(.overlayBlend(overlayID))
        })
        // クリップと同じ調整のコピー・貼り付け(クリップ ↔ オーバーレイ間でも写せる)
        color.append(EditorToolItem(String(localized: "カラーをコピー"), systemImage: "doc.on.doc", id: "overlay-look-copy") {
            copyLook(ofOverlay: overlayID)
        })
        color.append(EditorToolItem(String(localized: "カラーを貼り付け"), systemImage: "doc.on.clipboard", id: "overlay-look-paste",
                                    enabled: LookClipboard.shared.hasLook, disabledReason: Self.emptyLookReason) {
            pasteLook(toOverlay: overlayID)
        })
        items.append(EditorToolItem.group(String(localized: "カラー"), systemImage: "circle.lefthalf.filled", id: "group-color", items: color))
        // 「その他」は中身が少ないのでやめて、直接並べる
        if !isImage {
            items.append(EditorToolItem(String(localized: "音量"), systemImage: "speaker.wave.2") {
                openPanel(.overlayVolume(overlayID))
            })
            let detachReason: String? = project.overlays.first(where: { $0.id == overlayID })
                .flatMap { EditorProject.audioDetachBlockReason($0) }
            items.append(EditorToolItem(String(localized: "リンク解除"), systemImage: "rectangle.split.1x2",
                                        enabled: detachReason == nil, disabledReason: detachReason) {
                detachAudio(overlayID: overlayID)
            })
            items.append(EditorToolItem(String(localized: "速度"), systemImage: "speedometer") {
                openPanel(.overlaySpeed(overlayID))
            })
        }
        // 再生位置で切る(リンク中の音声もいっしょに切れる)
        items.append(EditorToolItem(String(localized: "分割"), systemImage: "scissors") {
            splitOverlay(overlayID)
        })
        items.append(EditorToolItem(String(localized: "複製"), systemImage: "plus.square.on.square") {
            duplicateOverlay(overlayID)
            showToast(String(localized: "複製しました"), undo: true)
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeOverlay(id: overlayID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        return items
    }

    // MARK: ナレーション

    // 音量 → 音声効果 → 音量そろえ → 削除(赤・末尾)
    private func narrationItems(_ narrationID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "音量"), systemImage: "speaker.wave.2") {
            openPanel(.narrationVolume(narrationID))
        })
        items.append(EditorToolItem(String(localized: "音声効果"), systemImage: "waveform.and.magnifyingglass", id: "narration-audio-effects") {
            openPanel(.narrationEffects(narrationID))
        })
        items.append(EditorToolItem(String(localized: "分割"), systemImage: "scissors") {
            splitNarration(narrationID)
        })
        items.append(EditorToolItem(String(localized: "音量そろえ"), systemImage: "waveform", id: "narration-loudness",
                                    enabled: audioToolProgress == nil,
                                    disabledReason: Self.busyReason) {
            startNormalize(clipIDs: [], narrationIDs: [narrationID])
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeNarration(id: narrationID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        return items
    }

    // MARK: 字幕

    // 文字を直す → 字幕一覧 → 字幕デザイン → 削除(赤・末尾)。自動字幕はテキスト群だけ
    private func subtitleItems(_ cueID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "文字を直す"), systemImage: "pencil") {
            openPanel(.textEdit(cueID))
        })
        items.append(EditorToolItem(String(localized: "字幕一覧"), systemImage: "list.bullet.rectangle", id: "subtitle-list") {
            openCaptionList()
        })
        // 「スタイル」と「デザイン」は 1 つの入口にまとめた
        items.append(EditorToolItem(String(localized: "字幕デザイン"), systemImage: "textformat.size") {
            openPanel(.captionTemplate)
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeSubtitle(id: cueID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        return items
    }

    // MARK: BGM

    // 音量 → BGMを置き換え → 削除(赤・末尾)
    private var bgmItems: [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "音量"), systemImage: "speaker.wave.2") {
            openPanel(.bgmVolume)
        })
        items.append(EditorToolItem(String(localized: "BGMを置き換え"), systemImage: "arrow.triangle.2.circlepath") {
            history.record(project)
            activeSheet = .audio
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.audio.bgmURL = nil
            project.audio.bgmName = nil
            project.audio.bgmSourceStart = 0
            showToast(String(localized: "削除しました"), undo: true)
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
        items.append(EditorToolItem(String(localized: "アニメーション"), systemImage: "sparkles.rectangle.stack") {
            openPanel(.textAnimation(textID))
        })
        // 「その他」は中身が複製だけなので、オーバーレイと同じく直接並べる。削除は末尾
        items.append(textDuplicateItem(textID))
        items.append(textDeleteItem(textID))
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
        var motion: [EditorToolItem] = []
        motion.append(EditorToolItem(String(localized: "トラッキング"), systemImage: "scope") {
            openPanel(.textTracking(textID))
        })
        motion.append(EditorToolItem(String(localized: "キーフレーム"), systemImage: "diamond") {
            openPanel(.textKeyframes(textID))
        })
        items.append(EditorToolItem.group(String(localized: "モーション"), systemImage: "move.3d", id: "group-motion", items: motion))
        items.append(textDuplicateItem(textID))
        items.append(textDeleteItem(textID))
        return items
    }

    /// 中だるみチェック(端末内の AI で 1 秒ごとに判定し、目盛りの下に緑・黄・赤の帯を出す)
    private func runPacingCheck() {
        player.pause()
        let snapshot = project.snapshot()
        analysis.run(title: String(localized: "動画をチェックしています"), robot: .consensus) { report in
            // 無料プランの試用(ポイント)は、結果が出たときだけ確定する(失敗・中止したときは返す)
            var finished = false
            defer {
                if finished { PlanTrial.commit(.editCheck) } else { PlanTrial.refund(.editCheck) }
            }
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
            finished = true
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
            let before = project.snapshot()
            project.canvas.aspect = .portrait9x16
            // モザイクは映像に合わせて置き直す(画面に対する位置のままだと顔から外れる)
            project.remapMosaics(from: before)
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
            // 音量そろえは Standard の機能(編集チェックの「直す」からも、ツールバーと同じくプランを確かめる)
            if PlanStore.shared.allows(.loudness) {
                normalizeAll()
            } else {
                PlanPaywall.present(for: .loudness)
            }
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
            let before = project.snapshot()
            project.canvas.aspect = aspect
            project.remapMosaics(from: before)
            showToast(String(localized: "\(aspect.displayName)にしました"), undo: true)
        case .addEndScreen:
            // 終了画面は有料の機能(無料プランは試用のポイント)。ツールバーと同じく確かめる
            if PlanStore.shared.allows(.endScreen) {
                appendEndScreen()
            } else {
                PlanTrial.offer(.endScreen) { appendEndScreen() }
            }
        }
    }

    // MARK: インフルエンサー向けの自動編集(パンチイン・言いよどみカット・冒頭フック・エンドスクリーン)

    /// 話の区切りごとにズームを 1.0 と zoom 倍で交互に切り替える(選択中のクリップがあればそれだけ、なければ全クリップ)
    private func applyPunchIn(zoom: Double, interval: Double?) {
        player.pause()
        let snapshot = project.snapshot()
        let selected = selection?.clipID
        // 逆再生のクリップは分割できない(EditorProject.splitClip が断る)。何も変えずに「分けました」と出さないように止める
        if let selected, let picked = project.clips.first(where: { $0.id == selected }),
           picked.isReversed, picked.reversedURL != nil {
            showToast(String(localized: "逆再生中のクリップでは使えません"), style: .warning)
            return
        }
        analysis.run(title: String(localized: "話の区切りを探しています")) { report in
            try await HighlightAnalyzer.ensureVoiceRuns(snapshot: snapshot, progress: report)
            let guardSpeech = SpeechGuard(snapshot: snapshot, pad: 0)
            var plan: [(id: UUID, cuts: [Double], base: Double)] = []
            for (index, clip) in snapshot.clips.enumerated() where !clip.isStill && !(clip.isReversed && clip.reversedURL != nil) {
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

    /// 「文字起こしで編集」(TranscriptEditView)。キャプションが無ければ先に作ってもらう(字幕のシートを開く)
    private func openTranscriptEdit() {
        guard !project.subtitles.isEmpty else {
            history.record(project)
            activeSheet = .subtitles
            return
        }
        player.pause()
        activePanel = nil
        history.record(project)
        showTranscriptEdit = true
    }

    /// 字幕の言葉から「えー」「あのー」などを見つけて、その部分だけ詰める
    private func cutFillers() {
        let cues = project.subtitles
        guard !cues.isEmpty else {
            PlanTrial.refund(.fillerCut)
            showToast(String(localized: "先に「自動字幕」で字幕を作ってください"), style: .warning)
            return
        }
        let spans = FillerDetector.spans(in: cues)
        guard !spans.isEmpty else {
            // 無料プランの試用で払ったポイントは返す(何も切っていないので)
            if PlanTrial.refund(.fillerCut) {
                showToast(String(localized: "言いよどみは見つかりませんでした。ポイントは戻しました"), style: .info)
            } else {
                showToast(String(localized: "言いよどみは見つかりませんでした"), style: .info)
            }
            return
        }
        PlanTrial.commit(.fillerCut)
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
            // 後ろの部品は、実際に伸びた長さ(フェード(黒)の重なりを引いた長さ)だけずらす(前は 0.4 秒遅れていた)
            let durationBefore = project.layoutDuration
            project.clips.insert(piece, at: 0)
            project.shiftTimelineItems(from: 0, by: project.layoutDuration - durationBefore)
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
            player.seek(to: 0)
            showToast(String(localized: "見どころ(\(clipFXSeconds(best.end - best.start)))を先頭に差し込みました"), undo: true)
        } onError: { error in
            showToast(String(localized: "見どころを探せませんでした(\(error.localizedDescription))"), style: .warning)
        }
    }

    /// 最後に終了画面用の余白(最後のコマを少し暗くした静止画 10 秒)を足す
    private func appendEndScreen(seconds: Double = 10) {
        guard let last = project.clips.last else {
            PlanTrial.refund(.endScreen)
            return
        }
        player.pause()
        mediaToolTask?.cancel()
        mediaToolTask = Task { @MainActor in
            mediaToolProgress = ClipFXProgress(title: String(localized: "終了画面を作成中"), fraction: nil)
            do {
                let imageURL: URL
                if last.isStill, let still = last.stillImageURL {
                    imageURL = still
                } else {
                    // マルチカメラで別のカメラに切り替えたまま終わっていれば、そのカメラのコマを使う
                    let lastTime = max(last.startTime, last.endTime - 0.1)
                    if let angle = last.angleFrame(atSourceTime: lastTime),
                       let angleImage = try? await MediaTools.freezeFrameImage(from: angle.url, at: angle.time) {
                        imageURL = angleImage
                    } else {
                        imageURL = try await MediaTools.freezeFrameImage(from: last.url, at: lastTime)
                    }
                }
                mediaToolProgress = nil
                if Task.isCancelled {
                    PlanTrial.refund(.endScreen)
                    return
                }
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
                // 最後のクリップの切り抜き・ズーム・回転・反転・色を写す(前は外れたコマになっていた)
                still.geometry = last.geometry
                still.mask = last.mask
                still.enhance = last.enhance
                still.filter = last.filter
                // 終了画面の部品(次の動画・登録ボタン)が目立つよう少し暗くする
                still.filter.adjustments.brightness = max(-0.5, last.filter.adjustments.brightness - 0.25)
                history.record(project)
                if project.clips.indices.last.map({ project.clips[$0].transition.type == .none }) ?? false {
                    project.clips[project.clips.count - 1].transition = ClipTransition(type: .dissolve, duration: 0.5)
                }
                project.clips.append(still)
                // 無料プランの試用(ポイント)は、作れたときだけ確定する
                PlanTrial.commit(.endScreen)
                showToast(String(localized: "最後に \(Int(seconds)) 秒の余白を足しました"), undo: true)
            } catch {
                mediaToolProgress = nil
                PlanTrial.refund(.endScreen)
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

    /// 再生位置のコマ(見えているとおりの映像)で顔を探し、顔ごとにモザイクを置いて、映っている間追いかけさせる
    /// (FaceMosaicPlanner。拡大・切り抜き・反転・リフレーム・マルチカメラ・重ねた素材の顔も、見えている位置で隠す)。
    /// 顔を見失った所があれば、モザイクを大きくして残したうえで、その位置へ動かして知らせる
    private func autoMosaicFaces() {
        let t = player.currentTime
        player.pause()
        let snapshot = project.snapshot()
        let project = self.project
        let history = self.history

        analysis.run(title: String(localized: "顔を探しています")) { report in
            let plan = try await FaceMosaicPlanner.plan(snapshot: snapshot, time: t, progress: report)
            if Task.isCancelled { return }
            guard !plan.mosaics.isEmpty else {
                showToast(String(localized: "この位置のコマに顔が見つかりませんでした"), style: .warning)
                return
            }
            history.record(project)
            project.textClips.append(contentsOf: plan.mosaics)
            project.sortTextClips()
            if let first = plan.mosaics.first {
                selection = .text(first.id)
            }
            if let lost = plan.firstLostTime {
                // 見失った所へ動かして、そこから先を確かめてもらう
                player.seek(to: lost)
                showToast(plan.message, style: .warning, undo: true)
            } else {
                showToast(plan.message, undo: true)
            }
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
        items.append(EditorToolItem(String(localized: "表示する時間"), systemImage: "clock") {
            openPanel(.drawingTiming(drawingID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeDrawing(id: drawingID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        return items
    }

    // MARK: マーカー

    private func markerItems(_ markerID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "名前"), systemImage: "character.cursor.ibeam") {
            openPanel(.markerName(markerID))
        })
        items.append(EditorToolItem(String(localized: "色・種類"), systemImage: "flag") {
            openPanel(.markerKind(markerID))
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeMarker(id: markerID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        return items
    }

    // MARK: 映像エフェクト

    private func videoEffectItems(_ effectID: UUID) -> [EditorToolItem] {
        var items: [EditorToolItem] = []
        items.append(EditorToolItem(String(localized: "種類・強さ"), systemImage: "camera.filters", id: "effect-edit") {
            openPanel(.videoEffect(effectID))
        })
        items.append(EditorToolItem(String(localized: "複製"), systemImage: "plus.square.on.square", id: "effect-duplicate") {
            duplicateVideoEffect(effectID)
        })
        items.append(EditorToolItem(String(localized: "削除"), systemImage: "trash", id: "effect-delete", destructive: true) {
            history.record(project)
            selection = nil
            project.removeVideoEffect(id: effectID)
            showToast(String(localized: "削除しました"), undo: true)
        })
        return items
    }

    /// 映像エフェクトを再生位置に追加して選び、種類・強さのパネルを開く
    private func addVideoEffect(_ type: VideoEffectType) {
        guard !project.clips.isEmpty else { return }
        let before = panelSnapshot ?? project.snapshot()
        history.record(project)
        let total = project.layoutDuration
        var start = frameAligned(player.currentTime)
        // 最後まで来ていたら、終わりの 3 秒にかける
        if total > 0.5 && start > total - 0.5 { start = max(0, total - 3) }
        let length = total > start + 0.3 ? min(3, total - start) : 3
        let effect = VideoEffectClip(type: type, start: start, duration: length, intensity: type.defaultIntensity)
        project.videoEffects.append(effect)
        project.sortVideoEffects()
        selection = .videoEffect(effect.id)
        // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻る
        panelSnapshot = before
        activePanel = .videoEffect(effect.id)
    }

    /// 選択中の映像エフェクトを複製して直後に置き、複製を選ぶ
    private func duplicateVideoEffect(_ effectID: UUID) {
        guard let original = project.videoEffects.first(where: { $0.id == effectID }) else { return }
        history.record(project)
        var copy = original
        copy.id = UUID()
        copy.start = original.end
        project.videoEffects.append(copy)
        project.sortVideoEffects()
        selection = .videoEffect(copy.id)
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
                                    systemImage: allSelected ? "circle" : "checkmark.circle",
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
        // コピーした調整を選んだクリップ全部に貼り付ける(LookClipboard.swift)
        items.append(EditorToolItem(String(localized: "カラーを貼り付け"), systemImage: "doc.on.clipboard", id: "multi-look-paste",
                                    enabled: hasSelection && LookClipboard.shared.hasLook,
                                    disabledReason: hasSelection ? Self.emptyLookReason : Self.noMultiSelectionReason) {
            pasteLook(toClips: Set(ids))
        })
        items.append(EditorToolItem(hasSelection ? String(localized: "削除(\(ids.count))") : String(localized: "削除"), systemImage: "trash",
                                    id: "multi-delete", destructive: true,
                                    enabled: hasSelection, disabledReason: Self.noMultiSelectionReason) {
            deleteMultiSelected()
        })
        return items
    }

    // MARK: 調整のコピー・貼り付け(LookClipboard.swift)

    private static let emptyLookReason = String(localized: "先に「カラーをコピー」をしてください")

    private func copyLook(ofClip clipID: UUID) {
        guard let clip = project.clips.first(where: { $0.id == clipID }) else { return }
        LookClipboard.shared.copy(ClipLook(from: clip))
        showToast(String(localized: "カラーをコピーしました"))
    }

    private func copyLook(ofOverlay overlayID: UUID) {
        guard let overlay = project.overlays.first(where: { $0.id == overlayID }) else { return }
        LookClipboard.shared.copy(ClipLook(from: overlay))
        showToast(String(localized: "カラーをコピーしました"))
    }

    /// コピーした調整をクリップに貼り付ける(複数選択中はその全部)。トーストの「元に戻す」で戻せる
    private func pasteLook(toClips ids: Set<UUID>) {
        guard let look = LookClipboard.shared.look else { return }
        let targets = project.clips.indices.filter { ids.contains(project.clips[$0].id) }
        guard !targets.isEmpty else { return }
        history.record(project)
        for i in targets {
            look.apply(to: &project.clips[i])
        }
        if targets.count > 1 {
            showToast(String(localized: "\(targets.count) 本のクリップにカラーを貼り付けました"), undo: true)
        } else {
            showToast(String(localized: "カラーを貼り付けました"), undo: true)
        }
    }

    private func pasteLook(toOverlay overlayID: UUID) {
        guard let look = LookClipboard.shared.look,
              let i = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return }
        history.record(project)
        look.apply(to: &project.overlays[i])
        showToast(String(localized: "カラーを貼り付けました"), undo: true)
    }

    /// このクリップの調整(プリセット・補正・HSL・LUT すべて)をほかの全クリップに写す(確認のあと)
    private func applyLookToAllClips(from clipID: UUID) {
        guard let clip = project.clips.first(where: { $0.id == clipID }) else { return }
        let look = ClipLook(from: clip)
        history.record(project)
        for i in project.clips.indices where project.clips[i].id != clipID {
            look.apply(to: &project.clips[i])
        }
        showToast(String(localized: "全クリップに調整を適用しました"), undo: true)
    }

    private func endMultiSelect() {
        timeline.endMultiSelect()
        selection = nil
    }

    /// クリップを前後に動かす(動かせたら true)。字幕・テキスト・オーバーレイなどは同じ素材の位置に付いたまま動く
    private func moveClipsRippling(_ ids: Set<UUID>, by step: Int) -> Bool {
        let recorded = history.record(project)
        let layout = project.captureClipLayout()
        let originalClips: [Clip] = project.clips
        guard project.moveClips(ids: ids, by: step) else {
            // 動かせないときは並びも変えない(離れたクリップを寄せただけで並びが変わり、字幕・テキストなどが付いてこなかった)
            if project.clips.map(\.id) != originalClips.map(\.id) {
                project.clips = originalClips
            }
            // 端で動かせなかった: ここで積んだ記録を捨てる(「やり直す」も消さない)
            if recorded { history.discardLastIfUnchanged(project) }
            return false
        }
        project.rippleTimelineItems(from: layout)
        return true
    }

    private func moveMultiSelected(by step: Int) {
        let ids = timeline.multiSelectedClipIDs
        guard !ids.isEmpty else { return }
        let moved: Bool = moveClipsRippling(ids, by: step)
        if moved {
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            showToast(step < 0 ? String(localized: "これ以上前には動かせません") : String(localized: "これ以上後ろには動かせません"), style: .warning)
        }
    }

    private func deleteMultiSelected(confirmed: Bool = false) {
        let ids = timeline.multiSelectedClipIDs
        guard !ids.isEmpty else { return }
        // すべてのクリップを選んでいたら、「このプロジェクトを空にする」と同じく先に確かめる
        if !confirmed, project.clips.allSatisfy({ ids.contains($0.id) }) {
            pendingClipDelete = { deleteMultiSelected(confirmed: true) }
            showDeleteAllClipsConfirm = true
            return
        }
        let count = ids.count
        history.record(project)
        timeline.endMultiSelect()
        selection = nil
        // 後ろから 1 本ずつ消して詰める。再生位置も詰めた分だけ動かす
        var playhead = player.currentTime
        let ordered: [UUID] = project.clips.map { $0.id }.filter { ids.contains($0) }
        // リンク解除した音声もいっしょに消える(切られる)ので、お知らせに書く
        let detachedAudio = ordered.reduce(0) { $0 + project.detachedAudioCount(overlappingClip: $1) }
        for id in ordered.reversed() {
            if let gap = project.removeClip(id: id) {
                playhead = Self.rippledTime(playhead, gap)
            }
        }
        movePlayheadAfterDelete(to: playhead)
        showToast(detachedAudio > 0 ? String(localized: "\(count) 本のクリップを削除しました(分けた音声もいっしょに消しました)")
                                    : String(localized: "\(count) 本のクリップを削除しました"), undo: true)
    }

    /// クリップを削除(「元に戻す」つきのトースト)
    private func deleteClip(_ clipID: UUID, confirmed: Bool = false) {
        // 最後の 1 本を消すとキャプション・テキストなども全部消えるので、「このプロジェクトを空にする」と同じく先に確かめる
        if !confirmed, project.clips.count == 1, project.clips.first?.id == clipID {
            pendingClipDelete = { deleteClip(clipID, confirmed: true) }
            showDeleteAllClipsConfirm = true
            return
        }
        history.record(project)
        selection = nil
        // リンク解除した音声もいっしょに消える(切られる)ので、お知らせに書く
        let detachedAudio = project.detachedAudioCount(overlappingClip: clipID)
        var playhead = player.currentTime
        if let gap = project.removeClip(id: clipID) {
            playhead = Self.rippledTime(playhead, gap)
        }
        movePlayheadAfterDelete(to: playhead)
        showToast(detachedAudio > 0 ? String(localized: "削除しました(分けた音声もいっしょに消しました)")
                                    : String(localized: "削除しました"), undo: true)
    }

    /// 詰めた区間に合わせた再生位置(消した区間の中なら区間の頭 = 後ろのクリップの頭、後ろなら詰めた分だけ前へ)
    private static func rippledTime(_ t: Double, _ gap: (from: Double, to: Double)) -> Double {
        if t < gap.from { return t }
        if t >= gap.to { return t - (gap.to - gap.from) }
        return gap.from
    }

    /// 削除のあと、再生位置(白い線)を詰めた先へ動かす。前は元の時刻に残り、後ろのクリップの途中に線が出ていた
    private func movePlayheadAfterDelete(to t: Double) {
        guard !project.clips.isEmpty else { return }
        let total = project.layoutDuration
        player.seek(to: min(max(0, t), max(0, total - 0.05)))
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
                        // 切り替えたとおりに V1 のカットへ分け、メインの音声は A の段へ(MulticamFlatten.swift)
                        ToolbarItem(placement: .bottomBar) {
                            let reason: String? = project.clips.first(where: { $0.id == clipID })
                                .flatMap { EditorProject.multicamFlattenBlockReason($0) }
                            Button {
                                if let reason {
                                    // 押せない理由と直し方を出す(前は灰色のまま押せず、理由も出なかった)
                                    multicamFlattenBlockMessage = reason + "\n" + String(localized: "速度を 1x に戻し、タイムリマップを外すと書き出せます。")
                                } else {
                                    flattenMulticam(clipID)
                                }
                            } label: {
                                Label("V1 に書き出す", systemImage: "square.and.arrow.down.on.square")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(reason != nil ? Color.gray : nil)
                            .disabled(isFlatteningMulticam)
                        }
                    }
                    // 「V1 に書き出す」を押せないときの理由(シートの中に出す)
                    .alert(String(localized: "V1 に書き出せません"), isPresented: Binding(
                        get: { multicamFlattenBlockMessage != nil },
                        set: { if !$0 { multicamFlattenBlockMessage = nil } }
                    )) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(multicamFlattenBlockMessage ?? "")
                    }
            }
        case .subtitles:
            // クリップを選んで開いたときは、そのクリップだけ字幕を作れる
            SubtitleEditorView(project: project, player: player, focusClipID: selection?.clipID,
                               initialSection: subtitleSheetSection)
        case .audio:
            AudioSettingsView(project: project)
        case .export:
            // 編集画面のプレーヤーを渡す(「比較」から「この位置で編集画面に戻る」で同じ位置に戻れるように)
            ExportView(project: project, player: player, projectID: projectID)
        case .scopes(let clipID):
            ScopeSheetView(player: player, clip: project.clips.first(where: { $0.id == clipID }))
        case .coverMaker:
            CoverMakerView(project: project)
        case .compare:
            CompareView(project: project, player: player, projectID: projectID)
        case .autoEdit:
            AutoEditSheetView(project: project,
                              player: player,
                              history: history,
                              onApplied: { note in afterProjectReplaced(note: note) })
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
                                  projectID: projectID,
                                  onNarrationAdded: { id in selection = .narration(id) })
        case .googlePhotos:
            // 選んだ写真・動画は一時ファイルで届く(取り込んだら消す)。シートは自分で閉じる
            GooglePhotosImportView(onPicked: { urls in
                startLocalImport(urls, securityScoped: false, deleteSourcesAfter: true)
            })
        }
    }

    /// おまかせ編集・テンプレート・スライドショーでプロジェクトを置き換えた後の後始末。
    /// note: 話の整理の結果など、「適用しました」の代わりに出す一言
    private func afterProjectReplaced(note: String? = nil) {
        selection = nil
        if activePanel != .autoEditTemplates {
            activePanel = nil
        }
        Task { await reloadThumbnails() }
        showToast(note ?? String(localized: "適用しました"), undo: true)
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
        case .videoEffect(let effectID):
            return project.videoEffects.contains(where: { $0.id == effectID })
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
        seekToPanelTarget(panel)
        Analytics.shared.track("panel", ["name": Self.analyticsName(of: panel)])
    }

    /// 編集する部品が再生位置に無いと、色などを変えてもプレビューに映らない(別のクリップのコマが出たまま)。
    /// 止めているときは、部品が映る位置へ合わせる。トランジションは切れ目を見るので動かさない
    private func seekToPanelTarget(_ panel: EditorPanel) {
        if case .transition = panel { return }
        guard !player.isPlaying, let target = panel.targetSelection else { return }
        let range: ClosedRange<Double>
        // クリップの本当の終わり(出口のトランジションの重なりを含む)
        var clipEnd: Double? = nil
        switch target {
        case .clip(let clipID):
            let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
            guard let i = layout.firstIndex(where: { $0.clipID == clipID }), layout[i].end > layout[i].start else { return }
            // トランジションで前後のクリップと重なる所を除いた、このクリップだけが映る範囲(無ければ全体)
            let start = i > 0 ? max(layout[i].start, layout[i - 1].end) : layout[i].start
            let end = i + 1 < layout.count ? min(layout[i].end, layout[i + 1].start) : layout[i].end
            range = end > start + 0.05 ? start...end : layout[i].start...layout[i].end
            clipEnd = layout[i].end
        case .overlay, .subtitle, .text, .drawing, .videoEffect:
            guard let band = timelineRange(of: target) else { return }
            range = band
        default:
            return
        }
        let now = player.currentTime
        // 入りのアニメーション(フェードなど)があるテキストは、範囲の中でも入りの途中だと薄く・一部しか映らず、
        // 文字や色を変えても見えないので、入りきった所へ動かす
        if case .text(let textID) = target, Self.panelShowsTextAppearance(panel),
           let text = project.textClips.first(where: { $0.id == textID }), text.animIn != .none {
            let visibleFrom: Double = text.start + Self.textEntranceLead(text)
            if now >= text.start, now < visibleFrom - 0.01, visibleFrom < text.end {
                player.seek(to: visibleFrom)
                return
            }
        }
        guard now < range.lowerBound || now >= range.upperBound else { return }
        let length = range.upperBound - range.lowerBound
        if let clipEnd, now >= range.upperBound, now < clipEnd {
            // このクリップの出口のトランジションの中(まだこのクリップが映っている): 頭まで戻さず、重なりの手前へ
            player.seek(to: range.upperBound - min(0.05, length / 2))
            return
        }
        // 登場アニメーション・フェードイン・入りのトランジションの途中だと薄く映り、色などを変えても見えにくいので、出きった所へ
        var lead = 0.05
        switch target {
        case .clip(let clipID):
            if let clip = project.clips.first(where: { $0.id == clipID }), clip.animation.inType != .none {
                lead = clip.animation.inDuration + 0.05
            }
        case .overlay(let overlayID):
            if let overlay = project.overlays.first(where: { $0.id == overlayID }) {
                lead = (overlay.transitionIn.isActive ? overlay.transitionIn.duration : overlay.fadeIn) + 0.05
            }
        case .text(let textID):
            if Self.panelShowsTextAppearance(panel),
               let text = project.textClips.first(where: { $0.id == textID }), text.animIn != .none {
                lead = Self.textEntranceLead(text)
            }
        default:
            break
        }
        player.seek(to: range.lowerBound + min(lead, length / 2))
    }

    /// 文字の見た目・置き場所を編集するパネルか(入りのアニメーションの途中ではなく、文字が出きった所を見せる。
    /// アニメーション・キーフレームのパネルは再生位置そのものを使うので動かさない)
    private static func panelShowsTextAppearance(_ panel: EditorPanel) -> Bool {
        switch panel {
        case .textStyle, .textPlacement: return true
        default: return false
        }
    }

    /// テキストの入りのアニメーションが終わって、文字が出きるまでの秒(少し余裕を足す)
    private static func textEntranceLead(_ text: TextClip) -> Double {
        min(max(0, text.animInDuration), text.duration / 2) + 0.05
    }

    /// テキスト・ステッカーを足す開始時刻(合成のコマに合わせる)。動画の最後(残り 0.5 秒未満)にいるときは、
    /// 長さ length が動画の中に収まる所へ戻す(そのままだと動画の外に置かれ、打っても映らず、書き出しにも入らなかった)
    private func placementStart(length: Double) -> Double {
        let total = project.layoutDuration
        let start = frameAligned(player.currentTime)
        guard total > 0.5, start > total - 0.5 else { return start }
        return frameAligned(max(0, total - length))
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
        // わずかに前になり、プレビューにテキストが出ないことがある(動画の最後にいるときは中へ戻す)
        let start = placementStart(length: 3)
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
        // コマに合わせ、動画の最後にいるときは中へ戻す(前はそのままの時刻で、止めた画面や動画の最後では映らなかった)
        let start = placementStart(length: 3)
        var clip = TextClip(text: emoji, start: start)
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
        // 止めている画面にすぐ映す(前は再生するまで出ず、出ていないと思って二重に足してしまうことがあった)
        if !player.isPlaying { player.seek(to: start) }
    }

    /// 動くステッカーを再生位置に追加して選択する(色は style.colorHex、吹き出しなどの文字は text)
    private func addVectorSticker(_ kind: VectorStickerKind) {
        history.record(project)
        let start = placementStart(length: 3)
        var clip = TextClip(text: kind.defaultText, start: start)
        clip.isSticker = true
        clip.vectorSticker = kind
        clip.widthRatio = 0.3
        clip.style.sizeRatio = kind.aspect >= 2 ? 0.1 : 0.16
        clip.style.colorHex = kind.defaultColorHex
        clip.style.bold = false
        clip.style.shadow.enabled = false
        clip.style.backgroundColorHex = nil
        clip.style.strokeColorHex = nil
        project.textClips.append(clip)
        project.sortTextClips()
        selection = .text(clip.id)
        // 止めている画面にすぐ映す。線が描かれていく種類は開始のコマでは何も描かれないので、少し進んだ所を出す
        if !player.isPlaying { player.seek(to: frameAligned(start + min(0.6, clip.duration / 2))) }
    }

    /// 選択中のテキストを複製して直後に置き、複製を選択する
    private func duplicateText(_ textID: UUID) {
        guard let original = project.textClips.first(where: { $0.id == textID }) else { return }
        history.record(project)
        var copy = original
        copy.id = UUID()
        copy.start = original.end
        // 動画の終わりを越えるときは、直後ではなく動画の中に収まる所へ置く(前は丸ごと動画の外に置かれ、映らなかった)
        let total = project.layoutDuration
        if total > 0.5, copy.start > total - 0.5 {
            copy.start = frameAligned(max(0, total - copy.duration))
        }
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

    /// 再生位置に章タイトルのテロップ(2 行: 第n章 / タイトル)を入れて、テキストの編集パネルを開く。
    /// 黒い画面に出したいときは「カラーの画面」で黒を差し込んで、その上に乗せる
    private func addChapterTitleTelop() {
        let before = project.snapshot()
        history.record(project)
        let start = placementStart(length: 3)
        // 何番目の章か(言語に依らないよう、章タイトルとして入れた「見出し」テンプレのテロップを数える)
        let n = project.textClips.filter { $0.template == .headline && !$0.isSticker && $0.mosaic == nil }.count + 1
        var clip = TextClip(text: String(localized: "第\(n)章") + "\n" + String(localized: "タイトル"), start: start)
        clip.duration = 3
        clip.template = .headline
        clip.style = TextStyle.preset(.headline)
        clip.style.sizeRatio = max(clip.style.sizeRatio, 0.085)
        clip.style.alignment = .center
        clip.widthRatio = 0.9
        clip.center = .center
        clip.animIn = .fade
        clip.animOut = .fade
        project.textClips.append(clip)
        project.sortTextClips()
        selection = .text(clip.id)
        // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻る
        panelSnapshot = before
        activePanel = .textStyle(clip.id)
        // 入りがフェードなので、先頭のコマでは何も映らない。編集している間は入りきった所を出す
        player.seek(to: start + Self.textEntranceLead(clip))
    }

    /// 再生位置に(以前の黒い画面の)章タイトルを追加して編集パネルを開く
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

    /// 選んだ音声の部品を再生位置で切る(リンクを解除した音声・ナレーション・効果音)
    private func splitNarration(_ narrationID: UUID) {
        guard let item = project.narration.first(where: { $0.id == narrationID }) else { return }
        let t = player.currentTime
        guard t > item.start + 0.1, t < item.end - 0.1 else {
            showToast(String(localized: "再生位置を音声の上に合わせてください"), style: .warning)
            return
        }
        player.pause()
        history.record(project)
        guard project.splitNarration(id: narrationID, at: t) != nil else {
            history.discardLastIfUnchanged(project)
            return
        }
        showToast(String(localized: "分割しました"), undo: true)
    }

    /// 選んだオーバーレイを再生位置で切る(リンク中の音声もいっしょに切れる)
    private func splitOverlay(_ overlayID: UUID) {
        guard let overlay = project.overlays.first(where: { $0.id == overlayID }) else { return }
        let t = player.currentTime
        guard t > overlay.start + 0.1, t < overlay.end - 0.1 else {
            showToast(String(localized: "再生位置をオーバーレイの上に合わせてください"), style: .warning)
            return
        }
        player.pause()
        history.record(project)
        guard project.splitOverlay(id: overlayID, at: t) != nil else {
            history.discardLastIfUnchanged(project)
            return
        }
        showToast(String(localized: "分割しました"), undo: true)
    }

    /// クリップの映像と音声のリンクを解除する(音声を A1 に置き、映像はミュート)。分けた音声を選ぶ
    private func detachAudio(clipID: UUID) {
        player.pause()
        history.record(project)
        guard let audioID = project.detachAudio(clipID: clipID) else {
            history.discardLastIfUnchanged(project)
            return
        }
        selection = .narration(audioID)
        showToast(String(localized: "リンクを解除しました"), undo: true)
    }

    /// オーバーレイの映像と音声のリンクを解除する(音声は A2 …)。動画に音声トラックが無いときは分けない
    private func detachAudio(overlayID: UUID) {
        guard let overlay = project.overlays.first(where: { $0.id == overlayID }) else { return }
        player.pause()
        Task { @MainActor in
            let tracks = (try? await AVURLAsset(url: overlay.url).loadTracks(withMediaType: .audio)) ?? []
            guard !tracks.isEmpty else {
                showToast(String(localized: "この動画には音声がありません"), style: .warning)
                return
            }
            history.record(project)
            guard let audioID = project.detachAudio(overlayID: overlayID) else {
                history.discardLastIfUnchanged(project)
                return
            }
            selection = .narration(audioID)
            showToast(String(localized: "リンクを解除しました"), undo: true)
        }
    }

    /// マルチカメラを V1 のカットに書き出す(切り替えたとおりに分ける。メインの音声は映像から分けて A の段へ)
    private func flattenMulticam(_ clipID: UUID) {
        guard !isFlatteningMulticam else { return }
        isFlatteningMulticam = true
        player.pause()
        history.record(project)
        Task { @MainActor in
            let ids = await project.flattenMulticam(clipID: clipID)
            isFlatteningMulticam = false
            guard let ids, let first = ids.first else {
                history.discardLastIfUnchanged(project)
                showToast(String(localized: "書き出せませんでした。もう一度試してください"), style: .warning)
                return
            }
            activeSheet = nil
            selection = .clip(first)
            showToast(String(localized: "\(ids.count) 本のカットにしました"), undo: true)
        }
    }

    /// 追加したオーバーレイを置く: 再生位置から。タイムラインで段(V2・V3 …)を選んでいればその段へ
    private func placeAddedOverlay(_ id: UUID) {
        // 枠は画像・動画の大きさに合わせる(枠の余白で端まで寄せられない、を無くす)
        project.fitOverlayToSource(id: id)
        if let lane = timeline.targetOverlayLane {
            // 選んだ段が今は無い(消した後など)ときは、いちばん上の次の段まで
            let others = TimelineMetrics.overlayLaneCount(project.overlays.filter { $0.id != id })
            project.placeOverlay(id: id, inLane: min(lane, others))
        }
        project.sortOverlays()
    }

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
                    // V1 と同じく音声も入れる(要らなければ音量・リンク解除で)
                    video.volume = 1
                    overlay = video
                } else if item.isGIF, let gif = try? await item.loadTransferable(type: PickedGIF.self) {
                    // GIF は .gif のまま受け取り、動く写真オーバーレイにする(AnimatedImageCache)
                    var image = try MediaStore.makeImageOverlay(from: gif.url)
                    image.duration = AnimatedImageCache.suggestedOverlayDuration(for: gif.url)
                    overlay = image
                } else if let photo = try? await item.loadTransferable(type: PickedPhoto.self) {
                    var image = try MediaStore.makeImageOverlay(from: photo.url)
                    image.duration = 4
                    overlay = image
                } else if Self.hasImageType(item) {
                    // 写真なのに受け取れなかった(iCloud にだけある写真を圏外で選んだなど): 写真のエラーとして出す
                    throw PickedPhotoLoadError.unavailable
                } else {
                    // 種類が判定できなかった場合の保険
                    let movieURL = try await importMovieURL(item, onProgress: progress)
                    var video = try await MediaStore.makeOverlay(fromVideo: movieURL)
                    OverlayPreset.bRollFull.apply(to: &video)
                    video.volume = 1
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
                placeAddedOverlay(added.id)
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
        trackMediaAdd(target: "overlay", source: "photos", count: lastAdded == nil ? 0 : importDone - failures.count)
        if let lastAdded {
            selection = .overlay(lastAdded)
            // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻せる
            panelSnapshot = before
            activePanel = .overlayPlacement(lastAdded)
        }
        if !failures.isEmpty, !cancelled {
            alertOffersSettings = needsPhotoSettings
            alertMessage = Self.importResultMessage(added: lastAdded == nil ? 0 : importDone - failures.count, failures: failures)
        } else if lastAdded != nil, importCopiedPhotoMedia {
            showToast(Self.photoCopiedNote(), style: .info)
        }
    }

    /// 選んだ項目が動画らしいか
    /// 選んだ項目が写真(画像の形式を持つ)か。写真を受け取れなかったときに、動画の取り込みに回さないために見る
    private static func hasImageType(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains(where: { $0.conforms(to: .image) })
    }

    /// GIF をクリップとして入れたときのお知らせ(V1 では最初のコマの写真になる)
    private static func stillGIFNote() -> String {
        String(localized: "GIF は止まった写真として入りました。動かすには「ステッカー」の「GIF を読み込む」から重ねてください")
    }

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
    private func toggleReverse(_ clipID: UUID, confirmedLongSource: Bool = false) {
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
        // 逆再生のファイルは元の動画全体から作る(あとでトリミングを変えても使えるように)。長い動画では時間と容量がかかるので、
        // 作る前に空き容量を確かめ、使っているのが一部だけなら確かめてから作る(前は数十分・数 GB かかっても何も言わずに始めていた)
        let estimate: Int64 = Self.estimatedReverseBytes(for: clip)
        let available: Int64 = StorageEstimator.availableBytes()
        if available > 0, estimate + StorageEstimator.safetyMarginBytes > available {
            alertMessage = String(localized: "空き容量が足りないため、逆再生の動画を作れません(約 \(StorageEstimator.formatBytes(estimate)) 必要・空き \(StorageEstimator.formatBytes(available)))。")
            return
        }
        if !confirmedLongSource, clip.duration > 120, clip.endTime - clip.startTime < clip.duration * 0.5 {
            reverseConfirmMessage = String(localized: "逆再生は、トリミングした部分ではなく元の動画全体(\(MediaTimeText.mmss(clip.duration)))から作るため、時間がかかり、約 \(StorageEstimator.formatBytes(estimate)) の容量を使います。")
            reverseConfirmClipID = clipID
            return
        }
        player.pause()
        mediaToolTask?.cancel()
        mediaToolTask = Task { @MainActor in
            mediaToolProgress = ClipFXProgress(title: String(localized: "逆再生の動画を作成中"), fraction: 0)
            // 作成中は画面の自動ロックを止め、アプリを離れてもしばらく続ける(FlowSlowControls.swift の LongTaskKeepAlive)
            let keepAlive = LongTaskKeepAlive.begin(title: String(localized: "逆再生の動画を作成中")) { mediaToolTask?.cancel() }
            defer { keepAlive.finish(success: project.clips.first(where: { $0.id == clipID })?.reversedURL != nil) }
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
                    alertMessage = keepAlive.leftApp
                        ? String(localized: "アプリを離れたため止まりました。もう一度お試しください")
                        : String(localized: "逆再生の動画を作成できませんでした。\n\(error.localizedDescription)")
                }
            }
            mediaToolTask = nil
        }
    }

    /// 逆再生のファイルの大きさの見積もり(元の動画ファイルの約 3 倍。高いビットレートで書き直すため)
    private static func estimatedReverseBytes(for clip: Clip) -> Int64 {
        let size: Int64 = (try? clip.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        if size > 0 { return size * 3 }
        // 大きさが分からないときは 1 秒あたり約 8 MB で見積もる
        return Int64(max(0, clip.duration) * 8_000_000)
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
        // 逆再生のクリップは分割できない(EditorProject.splitClip が断る)ので、静止画がクリップの後ろに入ってしまう。分割と同じく止める
        if clip.isReversed && clip.reversedURL != nil {
            showToast(String(localized: "逆再生中のクリップでは使えません"), style: .warning)
            return
        }
        let sourceTime = min(max(location.sourceTime, clip.startTime), clip.endTime)
        let freezeTime = player.currentTime
        player.pause()
        mediaToolTask?.cancel()
        mediaToolTask = Task { @MainActor in
            mediaToolProgress = ClipFXProgress(title: String(localized: "フレーム保持を作成中"), fraction: nil)
            do {
                // マルチカメラで別のカメラに切り替えている所は、そのカメラのコマを使う(読めなければメインのカメラ)
                let imageURL: URL
                if let angle = clip.angleFrame(atSourceTime: sourceTime),
                   let angleImage = try? await MediaTools.freezeFrameImage(from: angle.url, at: angle.time) {
                    imageURL = angleImage
                } else {
                    imageURL = try await MediaTools.freezeFrameImage(from: clip.url, at: sourceTime)
                }
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
                // 切り抜き・ズーム・回転・反転・画面分割の位置、マスク、画質補正、背景を消すも写す
                // (前は色だけで、止まっている間だけ構図が飛んでいた。キーフレーム・手ぶれ補正・自動リフレームは静止画には写らない)
                still.geometry = clip.geometry
                still.mask = clip.mask
                still.enhance = clip.enhance
                still.backgroundRemoval = clip.backgroundRemoval

                guard let i = project.index(of: clipID) else { return }
                history.record(project)
                let minimum = 0.2
                // 静止画を入れた位置より後ろの部品も、静止画の長さだけ後ろへずらす
                let range = project.outputRange(ofClip: clipID)
                var durationBefore = project.layoutDuration
                let rippleTime: Double?
                if sourceTime > clip.startTime + minimum, sourceTime < clip.endTime - minimum,
                   project.splitClip(id: clipID, atSourceTime: sourceTime) {
                    // 分割で変わった配置は splitClip の中で部品に反映済み。ここからは静止画の長さだけずらす
                    durationBefore = project.layoutDuration
                    // 切れ目は分割で動くことがある(前のトランジションの重なりが短くなる・速度カーブを半分ずつにかけ直す)。
                    // 静止画は前半(clipID のまま・トランジションなし)の終わりに入るので、新しい配置で測る
                    rippleTime = project.outputRange(ofClip: clipID)?.end ?? freezeTime
                    project.clips.insert(still, at: i + 1)
                } else if sourceTime <= clip.startTime + minimum {
                    project.clips.insert(still, at: i)
                    rippleTime = range?.start
                } else {
                    project.clips.insert(still, at: i + 1)
                    rippleTime = range?.end
                }
                if let rippleTime {
                    project.insertTimelineGap(at: rippleTime, length: project.layoutDuration - durationBefore)
                }
                selection = .clip(still.id)
                showToast(String(localized: "フレーム保持を追加しました"), undo: true)
            } catch is CancellationError {
                mediaToolProgress = nil
            } catch {
                mediaToolProgress = nil
                if !Task.isCancelled {
                    alertMessage = String(localized: "フレーム保持を作成できませんでした。\n\(error.localizedDescription)")
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
            // 今のトリミング範囲の中ほどのコマを、プリセット・LUT・HSL を掛けた色で測る(色調整は全部書き換えるので外す。
            // ClipFXPanels.swift の ClipColorSample)。前は読み込んだときの元素材の先頭のコマ(clip.thumbnail)で決めていた
            var look = clip.filter
            look.adjustments = ColorAdjustments()
            let image = await ClipColorSample.image(for: clip, settings: look)
            guard let image else {
                alertMessage = String(localized: "サムネイルを取得できなかったため、自動補正できませんでした。")
                return
            }
            let auto = FilterEngine.autoEnhanceAdjustments(for: image)
            guard let j = project.index(of: clipID) else { return }
            let before = project.snapshot()
            history.record(project)
            // 自動補正が決める項目だけを書き換え、自分で付けた色温度・シャープネスは残す(前は全部を置き換えて 0 に戻していた)。
            // 彩度・シャドウ・ハイライトは自動補正が値を決めたときだけ書き換える
            var adjustments = project.clips[j].filter.adjustments
            adjustments.brightness = auto.brightness
            adjustments.contrast = auto.contrast
            if auto.saturation != 1 { adjustments.saturation = auto.saturation }
            if auto.shadows != 0 { adjustments.shadows = auto.shadows }
            if auto.highlights != 0 { adjustments.highlights = auto.highlights }
            // 露出は補正前の映像で明るさを測っているので、重ねると明るくなりすぎる。0 に戻し、そのことを伝える
            let resetExposure: Bool = adjustments.exposure != 0
            adjustments.exposure = 0
            project.clips[j].filter.adjustments = adjustments
            // 結果を確認・微調整できるよう色調整パネルを開く(履歴は記録済み。✕「キャンセル」で補正前に戻る)
            panelSnapshot = before
            activePanel = .colorAdjust(clipID)
            showToast(resetExposure ? String(localized: "自動補正しました(露出は 0 に戻しました)")
                                    : String(localized: "自動補正しました"), undo: true)
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
            } else if Self.hasImageType(item) {
                // 写真なのに受け取れなかった: 写真のエラーとして出す(動画の取り込みに回すと、要らないフルアクセスを求めていた)
                throw PickedPhotoLoadError.unavailable
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
            // メインの素材が変わったので、アングルの音声同期は合わせ直しが必要
            for i in replaced.multicam.angles.indices {
                replaced.multicam.angles[i].syncState = .stale
            }
            replaced.isMuted = old.isMuted && fresh.hasAudio
            replaced.audio = old.audio
            replaced.transition = old.transition
            replaced.animation = old.animation
            replaced.geometry = old.geometry
            replaced.speedCurve = old.speedCurve
            // 素材に依存しない設定は引き継ぐ(リフレーム・手ぶれ補正の解析結果は素材ごとなので引き継がない)
            replaced.mask = old.mask
            replaced.enhance = old.enhance
            replaced.retouch = old.retouch
            // キーフレーム(元素材上の秒)は、クリップの先頭からの位置が同じになるようずらして引き継ぐ
            let keyShift = replaced.startTime - old.startTime
            replaced.keyframes = old.keyframes.map { key in
                var k = key
                k.time += keyShift
                return k
            }
            let before = project.snapshot()
            history.record(project)
            // キャプション・テキスト・モザイク・Bロール・ナレーション・効果音・マーカーも、クリップの先頭からの位置を保って動かす。
            // 新しい動画が短くてクリップが縮んだときは、右端をトリミングしたときと同じく後ろを前へ詰める
            // (前は V1 だけが縮み、後ろの字幕などが元の時刻に残ってずれていた。TimelineRipple.swift)
            let layout = project.captureClipLayout(replacing: clipID, with: replaced)
            project.clips[i] = replaced
            project.rippleTimelineItems(from: layout)
            importDone = 1
            if shortened {
                showToast(String(localized: "置き換えました(新しい動画が短いため、クリップも短くなりました)"), undo: true)
            } else if !fresh.isStill, fresh.duration - length > 0.05 {
                // 長さはそのままで、どこを使うかを細かく合わせられるようスリップのパネルを開く
                // (履歴は記録済みなので openPanel は使わない。トーストの「元に戻す」と ✕「キャンセル」で置き換え前に戻る)
                panelSnapshot = before
                activePanel = .slip(clipID)
                showToast(String(localized: "置き換えました。使う部分を調整できます"), undo: true)
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

    private func startSilenceCut(pace: SilenceCutPace) {
        audioToolTask?.cancel()
        audioToolTask = Task { @MainActor in
            await runSilenceCut(pace: pace)
            audioToolTask = nil
        }
    }

    /// 音声のある(ミュートでない)全クリップから無音部分を取り除き、残す範囲ごとにクリップを分割する
    @MainActor
    private func runSilenceCut(pace: SilenceCutPace) async {
        // 逆再生・速度カーブ(タイムリマップ)のクリップは外す。切れ端の並び・速さが元と変わり、
        // 字幕などを正しく詰められないため(ReelFinisher の無音カットと同じ)
        let targets = project.clips.filter {
            $0.hasAudio && !$0.isMuted && !$0.isStill && !$0.isReversed && !$0.speedCurve.enabled
        }
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
                kept[clip.id] = try await AudioAnalysis.keptRanges(for: clip,
                                                                   minimumDuration: pace.minimumDuration,
                                                                   padding: pace.padding,
                                                                   minimumKeep: pace.minimumKeep)
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

        // 残す範囲ごとにクリップを組み立て直す(最初の範囲は元の ID を保つ)。
        // 取り除く無音は、組み立て直す前の出力タイムラインの区間(秒)としても控えておき、あとで字幕・テキストなどを
        // クリップを削除したときと同じように詰める(前は V1 だけが詰まり、ほかの部品は元の時刻に残って話とずれていた)
        let tolerance = 0.01
        let oldLayout = CompositionBuilder.timelineLayout(for: project.snapshot())
        var newClips: [Clip] = []
        var removedRanges: [(from: Double, to: Double)] = []
        var removedCount = 0
        var removedOutputSeconds = 0.0
        for (index, clip) in project.clips.enumerated() {
            guard var ranges = kept[clip.id], !ranges.isEmpty, index < oldLayout.count else {
                newClips.append(clip)
                continue
            }
            // ナレーション・効果音・分けた音声が鳴っている所は詰めない(詰めるとナレーションの終わりが切れ、話の間の効果音が消えていた)
            ranges += project.narrationSourceRanges(in: clip, placementStart: oldLayout[index].start)
            // トランジションで前後と重なる所(重なりの 2 倍)は切らない。切ると前後のクリップの区間が重なりの中でかぶって
            // 字幕などを二重に詰めて消したり、重なりが短くなって後ろの部品が早まったりする
            let inOverlap = index > 0 ? max(0, oldLayout[index - 1].end - oldLayout[index].start) : 0
            let outOverlap = index + 1 < oldLayout.count ? max(0, oldLayout[index].end - oldLayout[index + 1].start) : 0
            if inOverlap > 0 {
                ranges.append((start: clip.startTime, end: clip.sourceTime(atOutputOffset: 2 * inOverlap)))
            }
            if outOverlap > 0 {
                ranges.append((start: clip.sourceTime(atOutputOffset: clip.outputDuration - 2 * outOverlap), end: clip.endTime))
            }
            var merged: [(start: Double, end: Double)] = []
            for r in ranges.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, r.start <= last.end + tolerance {
                    merged[merged.count - 1].end = max(last.end, r.end)
                } else {
                    merged.append(r)
                }
            }
            ranges = merged
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
            // 取り除く元素材の区間(先頭・残す範囲のあいだ・末尾)を、組み立て直す前の出力タイムラインの秒にする
            let clipStart = oldLayout[index].start
            var cutStart = clip.startTime
            for range in ranges {
                if range.start > cutStart + tolerance {
                    removedRanges.append((from: clipStart + clip.outputOffset(atSourceTime: cutStart),
                                          to: clipStart + clip.outputOffset(atSourceTime: range.start)))
                }
                cutStart = range.end
            }
            if clip.endTime > cutStart + tolerance {
                removedRanges.append((from: clipStart + clip.outputOffset(atSourceTime: cutStart),
                                      to: clipStart + clip.outputOffset(atSourceTime: clip.endTime)))
            }
            for (j, range) in ranges.enumerated() {
                var piece = (j == 0) ? clip : clip.duplicated()
                // 被写体フラッシュなども切れ端に合わせる(Clip.restrictToSource)
                piece.restrictToSource(range.start, range.end, of: clip,
                                       flashFrom: j == 0 ? clip.startTime : ranges[j - 1].end)
                // 同じクリップの中の切れ目はふつうのカットにする(最後の切れ端だけ元のトランジションを残す。分割と同じ)。
                // 残すと切れ目ごとに重なって余分に短くなり、部品がずれる
                piece.clearCutEdges(head: j > 0, tail: j < ranges.count - 1)
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
        // 字幕・テキスト(モザイク)・章タイトル・テロップ・手書き・映像エフェクト・重ね合わせ(Bロール)・ナレーション(効果音)も、
        // クリップを削除したときと同じ removeTimelineRange で消したり詰めたりする(TimelineRipple.swift)。
        // 後ろの区間から詰めるので、前の区間の秒は変わらない。再生位置も削除のときと同じように動かす
        let gapsFromBack = removedRanges.sorted { $0.from > $1.from }
        let markersBefore = project.markers
        var playhead = player.currentTime
        for gap in gapsFromBack {
            project.removeTimelineRange(from: gap.from, to: gap.to)
            playhead = Self.rippledTime(playhead, gap)
        }
        // マーカー(章の区切りなど)は無音の中にあっても消さず、詰めた先(無音の始まり)へ寄せる
        let remainingMarkers = Set(project.markers.map(\.id))
        for marker in markersBefore where !remainingMarkers.contains(marker.id) {
            var moved = marker
            moved.time = gapsFromBack.reduce(marker.time) { Self.rippledTime($0, $1) }
            project.markers.append(moved)
        }
        project.sortMarkers()
        movePlayheadAfterDelete(to: playhead)
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
            showToast(String(localized: "ラウドネスの自動一致をキャンセルしました"), style: .info)
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
        // 逆再生のクリップは分割すると前後の中身が入れ替わるので止める(EditorProject.splitClip でも断る)。文言は追跡と同じもの
        if clip.isReversed && clip.reversedURL != nil {
            showToast(String(localized: "逆再生中のクリップでは使えません"), style: .warning)
            return
        }
        history.record(project)
        project.splitClip(id: clipID, atSourceTime: sourceTime)
        showToast(String(localized: "分割しました"), undo: true)
    }

    /// 分割したクリップを次のクリップとつなぎ直す(ClipRejoin.swift)。
    /// 字幕・テキストなどは同じ素材の位置に付けたまま動かす(TimelineRipple.swift)
    private func rejoinClip(_ clipID: UUID) {
        guard let index = project.index(of: clipID), ClipRejoin.canRejoin(project.clips, at: index),
              let merged = ClipRejoin.merge(project.clips[index], project.clips[index + 1]) else {
            showToast(String(localized: "次のクリップが同じ素材の続きではありません"), style: .warning)
            return
        }
        history.record(project)
        // 先に 2 つの間のトランジションの重なりを外して部品を動かしてから 1 つにまとめる
        // (まとめた後は配置が変わらないので、消えるクリップの上の部品もそのままの位置でよい)
        var layout = project.captureClipLayout()
        project.clips[index].transition = ClipTransition()
        project.rippleTimelineItems(from: layout)
        layout = project.captureClipLayout()
        project.clips[index] = merged
        project.clips.remove(at: index + 1)
        project.rippleTimelineItems(from: layout)
        showToast(String(localized: "分割を戻しました"), undo: true)
    }

    // MARK: 保存 / プロジェクトの切り替え

    /// 変更内容を保存し、一覧のメタデータとサムネイルを更新する(書き込みはまとめて行われる)
    private func persist(_ snapshot: ProjectSnapshot) {
        // 読み込み中・保存ファイルが読めなかったときは保存しない(空の内容で上書きしないため)
        if isLoadingPhotoMedia || isProjectUnreadable { return }
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
        // カメラで撮ったのにプロジェクトに入らなかった動画が残っていれば、閉じる前にどうするか聞く
        // (閉じると残した撮影の行き先がわからなくなる)。写真に保存している間は閉じない
        if isSavingKeptTakes { return }
        if !keptCameraTakes.isEmpty {
            showKeptCameraTakes = true
            return
        }
        // 読み上げを作成中なら閉じない(閉じたあとにできたナレーションは保存されず、ポイントだけ減っていた)
        if EditorPendingAudioWork.isRendering {
            showToast(String(localized: "読み上げを作成中です。できあがってから「一覧」に戻ってください"), style: .warning)
            return
        }
        // 録音中なら、止めてナレーションを足してから保存する(パネルが閉じたあとに足すと保存されない)
        EditorPendingAudioWork.finishRecording?()
        // 取り込み中に閉じたかは、片付けの前に控えておく
        let wasImporting: Bool = isImporting || isLoadingPhotoMedia
        player.pause()
        mediaToolTask?.cancel()
        analysis.cancel()
        // 手書きの途中なら、描いた線を追加してから閉じる
        if isDrawingNew { finishDrawing() }
        activePanel = nil
        activeSheet = nil
        selection = nil
        if isLoadingPhotoMedia {
            // まだ読み込み終わっていない(保存すると空の内容で上書きしてしまう)。読み込みも止める
            photoLoadTask?.cancel()
            photoLoadTask = nil
            onClose(wasImporting)
            return
        }
        if isProjectUnreadable {
            // 保存ファイルが読めなかった: 何も書かない(前は空の内容で上書きしていた)。サムネイルと一覧の情報もそのまま
            onClose(wasImporting)
            return
        }
        let snapshot = project.snapshot()
        guard ProjectStore.saveNow(snapshot, projectID: projectID) else {
            // 保存できなかった(空き容量が無いなど): 閉じると最後に保存できたあとの編集が消えるので、閉じずにどうするか聞く
            saveFailed = true
            showCloseSaveFailed = true
            return
        }
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
        onClose(wasImporting)
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
        // 写真ライブラリから読み出せない・素材ファイルが見つからずに保留していた項目も消す(残すと保存のときに書き戻される)
        ProjectStore.discardHeldUnresolvedItems(projectID: projectID)
        project.restore(ProjectSnapshot(clips: [],
                                        subtitles: [],
                                        subtitleStyle: SubtitleStyle.starter,
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
            Analytics.shared.projectOpened()
            saveFailed = ProjectStore.hasSaveFailure(projectID: projectID)
            // 前に取り込めずに残したカメラの撮影があれば、また聞く(アプリが終了しても行き先を失わないよう覚えている)
            restoreKeptCameraTakes()
            openSavedProject()
        }
        player.update(with: project.snapshot())
        // 共有で受け取った動画・写真がないか見る(一覧の「新しいプロジェクトで編集」から開いたときは、ここで取り込む)
        IncomingMediaCenter.shared.refresh()
        checkIncomingMedia()
    }

    /// 保存済みの内容を開く(開いたときと「前回の状態に戻す」のあと)。
    /// 写真ライブラリを参照している動画は、読み出せるようにしてから開く
    @MainActor
    private func openSavedProject() {
        let photoReferences: [String] = ProjectStore.photoReferences(projectID: projectID)
        if photoReferences.isEmpty {
            restoreSavedProject()
        } else {
            // 読み込み中は空の画面の代わりに読み込み中の画面(進み具合と「一覧へ戻る」)を出し、取り込み・元に戻すも止める
            isLoadingPhotoMedia = true
            photoLoadDone = 0
            photoLoadTotal = photoReferences.count
            photoLoadFraction = 0
            // 写真アプリで編集されて長さが変わった動画を、取り込んだときの版で開くための長さ
            let expected: [String: Double] = ProjectStore.photoReferenceDurations(projectID: projectID)
            photoLoadTask?.cancel()
            photoLoadTask = Task { @MainActor in
                let result = await PhotoMediaResolver.prepareDetailed(references: photoReferences,
                                                                      expectedDurations: expected,
                                                                      onProgress: { done, total, fraction in
                    photoLoadDone = done
                    photoLoadTotal = total
                    photoLoadFraction = fraction
                })
                // 「一覧へ戻る」で止めたときは開かない(画面はもう閉じている)
                if Task.isCancelled { return }
                photoLoadTask = nil
                restoreSavedProject()
                isLoadingPhotoMedia = false
                if !isProjectUnreadable {
                    notePhotoLibraryResult(result)
                }
            }
        }
    }

    /// 写真ライブラリの動画を読み込んだ結果を伝える。
    /// 見つからない・アクセスがない(外すかを選べるお知らせ)/ iCloud から取れない(通信の案内。前は「削除したか、アクセスが
    /// 許可されていない」と誤って出ていた)/ 写真アプリで編集されて長さが変わった、を分けて出す
    @MainActor
    private func notePhotoLibraryResult(_ result: PhotoMediaResolver.PrepareResult) {
        var lines: [String] = []
        if !result.offline.isEmpty {
            lines.append(String(localized: "iCloud から動画を \(result.offline.count) 本ダウンロードできませんでした。インターネットに接続してから、プロジェクトを開き直してください(クリップはプロジェクトに残っています)。"))
        }
        if !result.changed.isEmpty {
            lines.append(String(localized: "写真アプリで編集されて長さが変わった動画が \(result.changed.count) 本あります。カットやキャプションの位置がずれていないか確かめてください。"))
        }
        if !result.missing.isEmpty {
            // 写真へのアクセスを許可していない・選んだ写真だけのときは、設定アプリへの入り口を出す
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            missingPhotoNoticeOffersSettings = status == .denied || status == .limited
            missingPhotoReferences = result.missing
            let head = String(localized: "写真ライブラリに見つからない動画が \(result.missing.count) 本あります。写真アプリで削除したか、写真へのアクセスが許可されていない可能性があります(設定アプリの「Video Mania」→「写真」で「フルアクセス」を選んでください)。クリップはプロジェクトに残しているので、写真アプリの「最近削除した項目」から戻すと、次に開いたときに使えます。")
            // 素材ファイルが見つからない項目のお知らせ(restoreSavedProject)なども、このお知らせにまとめる(2 つ重ねて出せないため)
            missingPhotoNotice = ([head] + lines + [alertMessage].compactMap { $0 }).joined(separator: "\n\n")
            alertMessage = nil
        } else if !lines.isEmpty {
            alertOffersSettings = false
            alertMessage = ([alertMessage].compactMap { $0 } + lines).joined(separator: "\n\n")
        }
    }

    /// 前に取り込めずに残したカメラの撮影(KeptCameraTakesStore)を、お知らせで聞き直すために戻す。
    /// どこかのプロジェクトで使っているもの(念のため)は除く
    @MainActor
    private func restoreKeptCameraTakes() {
        let stored: [URL] = KeptCameraTakesStore.load()
        guard !stored.isEmpty else { return }
        var used = Set<String>()
        for id in ProjectStore.storedProjectIDs() {
            used.formUnion(ProjectStore.mediaFileNames(projectID: id))
        }
        for url in stored where !used.contains(url.lastPathComponent) && !keptCameraTakes.contains(url) {
            keptCameraTakes.append(url)
        }
    }

    /// 保存済みの内容を読み込んで表示する
    @MainActor
    private func restoreSavedProject() {
        switch ProjectStore.open(projectID: projectID) {
        case .loaded(let saved, let missingMediaItems):
            isProjectUnreadable = false
            project.restore(saved)
            restoredSnapshot = project.snapshot()
            if !saved.isEmpty {
                Task { await reloadThumbnails() }
            }
            noteMissingMedia(missingMediaItems)
        case .notFound:
            isProjectUnreadable = false
        case .unreadable(let backupAvailable):
            // 読めない保存ファイルは空のプロジェクトとして開かない(前は閉じるときの保存で中身がすべて消えていた)。
            // 保存も止め(persist・closeProject。ProjectStore も書き込まない)、前回の状態に戻すか一覧へ戻るかを選んでもらう
            isProjectUnreadable = true
            unreadableBackupAvailable = backupAvailable
            unreadableRestoreFailed = false
            showUnreadableAlert = true
        }
        // 開く前(読み込み中など)の履歴は残さない(↶ で開く前の空の状態に戻り、それが保存されることがあった)
        history.clear()
        player.update(with: project.snapshot())
    }

    /// 素材ファイルが見つからずに編集画面に出さなかった項目があれば、何件あったかを伝える。
    /// 項目はプロジェクトに残っているので、同じ項目については 1 回だけ伝える(開くたびには出さない)
    private func noteMissingMedia(_ items: [String]) {
        let key = "project.missingMediaNotice." + projectID.uuidString
        guard !items.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let signature: String = items.sorted().joined(separator: ",")
        guard UserDefaults.standard.string(forKey: key) != signature else { return }
        UserDefaults.standard.set(signature, forKey: key)
        alertMessage = String(localized: "素材のファイルが見つからない項目が \(items.count) 件ありました。プレビューと書き出しには入りませんが、プロジェクトからは消さずに残しています。")
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

    /// 読み込めなかったときのお知らせ。一部だけ読み込めたときは件数を先に出し、同じ理由はまとめる
    private static func importResultMessage(added: Int, failures: [String]) -> String {
        var seen = Set<String>()
        let reasons: [String] = failures.filter { seen.insert($0).inserted }
        let head: String = added > 0
            ? String(localized: "\(added)件追加・\(failures.count)件失敗")
            : String(localized: "\(failures.count)件の動画・写真を読み込めませんでした。")
        return ([head] + reasons).joined(separator: "\n")
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
        // GIF をクリップとして入れた(最初のコマの写真になるので、最後に知らせる)
        var addedStillGIF = false
        // 差し込む位置: 再生位置のクリップの後ろ(末尾の「+」からのときと、クリップが無いときは末尾)
        var insertAt: Int? = nil
        if !importAppendsAtEnd, !project.clips.isEmpty,
           let location = project.locate(timelineTime: player.currentTime), location.index < project.clips.count {
            insertAt = location.index + 1
        }
        importAppendsAtEnd = false
        // 差し込む位置より後ろの部品(オーバーレイ・字幕・オーディオなど)も、差し込んだ長さだけ後ろへずらす
        let rippleTime: Double? = insertAt.flatMap { i in
            i < project.clips.count ? project.outputRange(ofClip: project.clips[i].id)?.start : nil
        }
        let durationBefore = project.layoutDuration
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
                    if item.isGIF { addedStillGIF = true }
                } else if Self.hasImageType(item) {
                    // 写真なのに受け取れなかった(iCloud にだけある写真を圏外で選んだなど): 写真のエラーとして出す
                    // (前は動画の取り込みに回り、要らない写真へのフルアクセスを求めて、動画の説明を出していた)
                    throw PickedPhotoLoadError.unavailable
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
        trackMediaAdd(target: "clip", source: "photos", count: added)
        if added > 0, let rippleTime {
            project.insertTimelineGap(at: rippleTime, length: project.layoutDuration - durationBefore)
        } else if added > 0 {
            project.extendChapterLabelsAfterAppend(previousDuration: durationBefore)
        }
        let cancelled = Task.isCancelled
        isImporting = false
        importFraction = nil
        importTask = nil
        // 一部だけ読み込めなかったときも、読み込めたクリップは選び、お知らせを閉じたら「元に戻す」つきのトーストを出す
        if let id = firstAddedID { selection = .clip(id) }
        if !failures.isEmpty, !cancelled {
            alertOffersSettings = needsPhotoSettings
            alertMessage = Self.importResultMessage(added: added, failures: failures)
            if added > 0 {
                toastAfterAlert = EditorToast(String(localized: "\(added)件を追加しました"), canUndo: true)
            }
        } else if added > 0 {
            if addedStillGIF {
                // GIF が止まった写真として入ったことを伝える(元に戻すも出す)
                showToast(Self.stillGIFNote(), style: .info, undo: true)
            } else if importCopiedPhotoMedia {
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

    /// ステッカーパネルの「GIF を読み込む」→「ファイルから選ぶ」。一時フォルダにコピーしてから
    /// ドラッグ&ドロップと同じ取り込み(importOverlayFiles)でオーバーレイにする
    private func handleGIFFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty, !isImporting else { return }
            importSourceOverride = "files"
            isImporting = true
            importTotal = urls.count
            importDone = 0
            importFraction = nil
            importIsDownloading = true
            importTask = Task { @MainActor in
                let copied = await AnimatedImageImport.copyToTemporary(urls)
                importIsDownloading = false
                guard !copied.isEmpty, !Task.isCancelled else {
                    MediaDrop.remove(copied)
                    importSourceOverride = nil
                    isImporting = false
                    importTask = nil
                    if !Task.isCancelled {
                        alertMessage = String(localized: "GIF を読み込めませんでした。")
                    }
                    return
                }
                await importOverlayFiles(copied)
            }
        case .failure(let error):
            alertMessage = String(localized: "ファイルを開けませんでした。\n\(error.localizedDescription)")
        }
    }

    /// importLocalFiles を「キャンセル」で止められるように importTask で始める
    private func startLocalImport(_ urls: [URL], securityScoped: Bool, deleteSourcesAfter: Bool) {
        guard !urls.isEmpty else { return }
        // 写真ライブラリの動画を読み込み中も取り込まない(読み込みの完了で上書きされて消えるため。撮影は残してあとで聞く)
        guard !isImporting, !isLoadingPhotoMedia else {
            // 取り込めないので、Google フォトの一時ファイルは残さない
            // (共有で受け取ったファイルは残して IncomingMediaCenter に返す。あとでまた聞く。
            //  カメラで撮った動画はほかに無いので消さずに残し、いまの取り込みが終わってからどうするか聞く)
            if deleteSourcesAfter {
                let incoming: [URL] = urls.filter { LocalMediaImport.isInIncomingInbox($0) }
                let takes: [URL] = urls.filter { LocalMediaImport.isCameraTake($0) }
                IncomingMediaCenter.shared.giveBack(incoming)
                keptCameraTakes.append(contentsOf: takes)
                removeImportSources(urls.filter { !LocalMediaImport.isInIncomingInbox($0) && !LocalMediaImport.isCameraTake($0) })
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
    ///   キャンセルで取り込まなかったものは IncomingMediaCenter に返す。
    ///   カメラで撮った動画は Media フォルダへ移し(4K の長い撮影でも空き容量が要らない)、プロジェクトに入ったときだけ元が無くなる。
    ///   失敗・キャンセルで入らなかった撮影は消さずに残し、もう一度取り込むか写真に保存するかを聞く(前は失敗しても消していた)
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
        // カメラで撮った動画か(同じく先に決めておく)
        let cameraFlags: [Bool] = urls.map { deleteSourcesAfter && LocalMediaImport.isCameraTake($0) }
        // プロジェクトに入った撮影(コピーで取り込んだときは、残った元のファイルを最後に消す)
        var addedTakes: [URL] = []
        // Media フォルダへ移したあと入らなかった撮影(消さずにそこに残す)
        var movedKeptTakes: [URL] = []
        var failures: [String] = []
        var recorded = false
        var added = 0
        // GIF などの動く画像をクリップとして入れた(最初のコマの写真になるので、最後に知らせる)
        var addedStillGIF = false
        // 差し込む位置: 再生位置のクリップの後ろ(末尾の「+」からのときと、クリップが無いときは末尾)。
        // タイムラインに落としたときは、落とした位置の切れ目
        let droppedIndex: Int? = importInsertIndex
        importInsertIndex = nil
        var insertAt: Int? = nil
        if let droppedIndex {
            insertAt = min(max(0, droppedIndex), project.clips.count)
        } else if !importAppendsAtEnd, !project.clips.isEmpty,
           let location = project.locate(timelineTime: player.currentTime), location.index < project.clips.count {
            insertAt = location.index + 1
        }
        importAppendsAtEnd = false
        // 差し込む位置より後ろの部品(オーバーレイ・字幕・オーディオなど)も、差し込んだ長さだけ後ろへずらす
        let rippleTime: Double? = insertAt.flatMap { i in
            i < project.clips.count ? project.outputRange(ofClip: project.clips[i].id)?.start : nil
        }
        let durationBefore = project.layoutDuration
        var firstAddedID: UUID? = nil
        // 取り込みを終えた(または読み込めなかった)ファイルの数。先頭からこの数だけが済んでいる
        var processed = 0
        for (index, url) in urls.enumerated() {
            // キャンセルされたら、追加済みの分は残してやめる
            if Task.isCancelled { break }
            importFraction = nil
            let isIncoming: Bool = incomingFlags[index]
            let isCameraTake: Bool = cameraFlags[index]
            // 共有で受け取ったファイル・Google フォトの一時ファイルは "<NNN>-<元の名前>"(先頭の番号は外す)
            let fileName: String = LocalMediaImport.storedFileName(for: url, stripsNumberPrefix: deleteSourcesAfter)
            // Media フォルダに置いたファイル(クリップにできなかったときは消すか、元の場所に戻す)
            var copied: URL? = nil
            // 共有で受け取ったファイル・カメラの撮影を Media フォルダへ移した
            // (取り込まなかったときは、受け取ったファイルは元の場所に戻し、撮影は Media フォルダに置いたまま残す)
            var movedFromInbox = false
            do {
                let destination: URL
                if isIncoming || isCameraTake {
                    // 共有で受け取ったファイルとカメラの撮影は移す(コピーより速く、空き容量も要らない。移せなければコピーする)
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
                    if AnimatedImageCache.isAnimated(url: destination) { addedStillGIF = true }
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
                if isCameraTake { addedTakes.append(url) }
            } catch {
                if let copied {
                    if movedFromInbox && isCameraTake {
                        // 撮った動画はここにしか無いので、移した Media フォルダに置いたまま残す(どうするかは最後に聞く)
                        movedKeptTakes.append(copied)
                    } else if movedFromInbox {
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
        trackMediaAdd(target: "clip",
                      source: securityScoped ? "files" : (incomingFlags.contains(true) ? "share" : "google"),
                      count: added)
        if added > 0, let rippleTime {
            project.insertTimelineGap(at: rippleTime, length: project.layoutDuration - durationBefore)
        } else if added > 0 {
            project.extendChapterLabelsAfterAppend(previousDuration: durationBefore)
        }
        let cancelled = Task.isCancelled
        // キャンセルで取り込まなかった共有のファイルは IncomingMediaCenter に返す。
        // すぐにまた聞かないよう「あとで」と同じ扱いにする(一覧に戻ったときや、次にプロジェクトを開いたときにまた聞く)
        let unprocessedIncoming: [URL] = zip(urls, incomingFlags).dropFirst(processed).filter { $0.1 }.map { $0.0 }
        if !unprocessedIncoming.isEmpty {
            IncomingMediaCenter.shared.giveBack(unprocessedIncoming)
            postponedIncomingURLs = IncomingMediaCenter.shared.pendingURLs
        }
        // プロジェクトに入らなかった撮影(失敗・キャンセル・手を付けなかったもの)。元の場所に残っているものと、
        // Media フォルダへ移したまま残したもの。どちらも消さずに、もう一度取り込むか写真に保存するかを聞く
        var keptTakes: [URL] = zip(urls, cameraFlags).filter { $0.1 }.map { $0.0 }
            .filter { !addedTakes.contains($0) && FileManager.default.fileExists(atPath: $0.path) }
        keptTakes.append(contentsOf: movedKeptTakes)
        if deleteSourcesAfter {
            // Google フォトの一時ファイルは、キャンセルで取り込まなかったものも含めて消す(残した撮影は消さない)
            let temporary: [URL] = zip(urls, incomingFlags).filter { !$0.1 }.map { $0.0 }
                .filter { !keptTakes.contains($0) }
            removeImportSources(temporary)
        }
        if !keptTakes.isEmpty {
            keptCameraTakes.append(contentsOf: keptTakes)
            var reasons = Set<String>()
            let reasonLines: [String] = failures.filter { reasons.insert($0).inserted }
            keptCameraTakesReason = cancelled || reasonLines.isEmpty ? nil : reasonLines.joined(separator: "\n")
        }
        isImporting = false
        importFraction = nil
        importIsDownloading = false
        importTask = nil
        // 一部だけ読み込めなかったときも、読み込めたクリップは選び、お知らせを閉じたら「元に戻す」つきのトーストを出す
        if let id = firstAddedID { selection = .clip(id) }
        if !keptTakes.isEmpty {
            // 撮影のお知らせ(取り込めなかった理由も入れる)は、取り込みが終わってから checkIncomingMedia が出す
            if added > 0 {
                showToast(String(localized: "\(added)件を追加しました"), undo: true)
            }
        } else if !failures.isEmpty, !cancelled {
            alertMessage = Self.importResultMessage(added: added, failures: failures)
            if added > 0 {
                toastAfterAlert = EditorToast(String(localized: "\(added)件を追加しました"), canUndo: true)
            }
        } else if added > 0, addedStillGIF {
            showToast(Self.stillGIFNote(), style: .info, undo: true)
        } else if added > 0 {
            showToast(insertAt != nil && droppedIndex == nil
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

    /// 取り込んだ(使い勝手の計測。どこから・何本。名前や中身は送らない)
    private func trackMediaAdd(target: String, source: String, count: Int) {
        defer { importSourceOverride = nil }
        guard count > 0 else { return }
        Analytics.shared.track("media_add", ["target": target, "source": importSourceOverride ?? source,
                                             "count": Analytics.countBucket(count)])
        Analytics.shared.noteAction("media_add")
    }

    // MARK: ドラッグ&ドロップ

    /// ほかのアプリから落とした動画・写真を受け取れるか(読み込み中・パネルや画面内の処理の間は受け取らない。
    /// 保存ファイルが読めなかったプロジェクトは保存できないので受け取らない)
    private var canAcceptDrop: Bool {
        didRestore && !isImporting && !isLoadingPhotoMedia && !isPanelOrToolBusy && !isProjectUnreadable
    }

    /// タイムラインに落とした: 落とした位置に近いクリップの切れ目に差し込む
    private func handleTimelineDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        guard canAcceptDrop, !providers.isEmpty else { return false }
        // タイムラインは再生位置が中央。落とした x を時刻に直し、その時刻より後ろに中心があるクリップの前に入れる
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let time = player.currentTime + Double(location.x - timelineWidth / 2) / pps
        let ranges = TimelineView.clipRanges(for: project.snapshot())
        let index = ranges.firstIndex { ($0.start + $0.end) / 2 > time } ?? ranges.count
        beginDropImport(providers) { urls in
            importInsertIndex = index
            await importLocalFiles(urls, securityScoped: false, deleteSourcesAfter: true)
        }
        return true
    }

    /// 空の画面に落とした: クリップとして末尾に取り込む
    private func handleEmptyDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptDrop, !providers.isEmpty else { return false }
        beginDropImport(providers) { urls in
            importAppendsAtEnd = true
            await importLocalFiles(urls, securityScoped: false, deleteSourcesAfter: true)
        }
        return true
    }

    /// プレビューに落とした: 再生位置からオーバーレイとして重ねる
    private func handleOverlayDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptDrop, !providers.isEmpty else { return false }
        beginDropImport(providers) { urls in
            await importOverlayFiles(urls)
        }
        return true
    }

    /// 落とした項目を一時フォルダにコピーしてから取り込む(コピーの間も「読み込み中」を出す)
    private func beginDropImport(_ providers: [NSItemProvider], then importFiles: @escaping @MainActor ([URL]) async -> Void) {
        EditorHaptics.tap()
        importSourceOverride = "drop"
        isImporting = true
        importTotal = providers.count
        importDone = 0
        importFraction = nil
        importIsDownloading = true
        importTask = Task { @MainActor in
            let urls = await MediaDrop.loadFiles(from: providers)
            importIsDownloading = false
            guard !urls.isEmpty, !Task.isCancelled else {
                MediaDrop.remove(urls)
                importSourceOverride = nil
                isImporting = false
                importTask = nil
                if !Task.isCancelled {
                    alertMessage = String(localized: "動画・写真のデータを取得できませんでした。")
                }
                return
            }
            await importFiles(urls)
        }
    }

    /// 落とした動画・写真をオーバーレイにする(importOverlayItems のファイル版)
    @MainActor
    private func importOverlayFiles(_ urls: [URL]) async {
        isImporting = true
        importTotal = urls.count
        importDone = 0
        importFraction = nil
        var failures: [String] = []
        var recorded = false
        var lastAdded: UUID?
        var before: ProjectSnapshot?
        for (index, url) in urls.enumerated() {
            if Task.isCancelled {
                MediaDrop.remove(Array(urls[index...]))
                break
            }
            let fileName = LocalMediaImport.storedFileName(for: url, stripsNumberPrefix: true)
            var stored: URL? = nil
            do {
                let result = try await LocalMediaImport.moveIntoMediaDirectory(url, fileName: fileName)
                let destination = result.url
                stored = destination
                // 移せずにコピーしたときは、一時ファイルを消す
                if !result.moved { try? FileManager.default.removeItem(at: url) }
                var overlay: OverlayClip
                switch LocalMediaImport.kind(of: destination) {
                case .movie:
                    overlay = try await MediaStore.makeOverlay(fromVideo: destination)
                    OverlayPreset.bRollFull.apply(to: &overlay)
                    overlay.volume = 1
                case .image:
                    overlay = try MediaStore.makeImageOverlay(from: destination)
                    overlay.duration = overlay.isAnimatedImage ? AnimatedImageCache.suggestedOverlayDuration(for: destination) : 4
                }
                overlay.start = max(0, player.currentTime)
                if !recorded {
                    before = project.snapshot()
                    history.record(project)
                    recorded = true
                }
                project.overlays.append(overlay)
                placeAddedOverlay(overlay.id)
                lastAdded = overlay.id
            } catch {
                if let stored { try? FileManager.default.removeItem(at: stored) }
                try? FileManager.default.removeItem(at: url)
                if error is CancellationError || Task.isCancelled {
                    MediaDrop.remove(Array(urls[(index + 1)...]))
                    break
                }
                failures.append(error.localizedDescription)
            }
            importDone += 1
        }
        let cancelled = Task.isCancelled
        isImporting = false
        importFraction = nil
        importTask = nil
        trackMediaAdd(target: "overlay", source: "photos", count: lastAdded == nil ? 0 : importDone - failures.count)
        if let lastAdded {
            selection = .overlay(lastAdded)
            // 履歴は追加前に記録済みなので openPanel は使わない。✕「キャンセル」で追加前に戻せる
            panelSnapshot = before
            activePanel = .overlayPlacement(lastAdded)
        }
        if !failures.isEmpty, !cancelled {
            alertMessage = Self.importResultMessage(added: lastAdded == nil ? 0 : importDone - failures.count, failures: failures)
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
        // 保存ファイルが読めなかったプロジェクトには何も取り込まない(保存できないので、取り込んだものがなくなる)
        guard !isProjectUnreadable else { return }
        // カメラで撮ったのにプロジェクトに入らなかった動画があれば、先にどうするか聞く
        // (取り込み・パネル・シート・ほかのお知らせが終わってから。消さずに残している)
        if !keptCameraTakes.isEmpty {
            guard didRestore, !isLoadingPhotoMedia, !isImporting, !isPanelOrToolBusy, !showKeptCameraTakes, !isSavingKeptTakes else { return }
            if activeSheet != nil || alertMessage != nil || ScreenPresentation.isPresentingSomething {
                scheduleIncomingCheck(retry: true)
            } else {
                showKeptCameraTakes = true
            }
            return
        }
        // 一覧に落とした動画・写真(このプロジェクトはそのために作った)は、聞かずに取り込む
        if didRestore, !isLoadingPhotoMedia, !isImporting, !isPanelOrToolBusy,
           let dropped = DroppedMediaHandoff.take(for: projectID) {
            importAppendsAtEnd = true
            startLocalImport(dropped, securityScoped: false, deleteSourcesAfter: true)
            return
        }
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

    // MARK: 取り込めなかったカメラの撮影

    /// 撮影を残したお知らせの説明(取り込めなかった理由があれば続ける)
    private var keptCameraTakesMessage: String {
        let head = String(localized: "動画は消さずに残しています。もう一度取り込むか、写真に保存してください。")
        guard let reason = keptCameraTakesReason else { return head }
        return head + "\n\n" + reason
    }

    /// 「もう一度取り込む」: 残しておいた撮影を、再生位置のクリップの後ろに取り込む(また入らなければ、また聞く)
    private func retryKeptCameraTakes() {
        let takes: [URL] = keptCameraTakes
        keptCameraTakes = []
        keptCameraTakesReason = nil
        importSourceOverride = "camera"
        startLocalImport(takes, securityScoped: false, deleteSourcesAfter: true)
    }

    /// 「写真に保存」: 残しておいた撮影を写真ライブラリに保存し(追加だけの許可。ExportManager と同じ)、保存できたものはアプリから消す。
    /// 許可が無い・保存できなかったものは残して、お知らせを閉じたらまた聞く
    private func saveKeptCameraTakesToPhotos() {
        guard !isSavingKeptTakes else { return }
        let takes: [URL] = keptCameraTakes
        // 保存が終わるまで一覧からは外さない(途中で閉じても、残した撮影の行き先がわかるように)
        isSavingKeptTakes = true
        keptCameraTakesReason = nil
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                isSavingKeptTakes = false
                alertOffersSettings = true
                alertMessage = String(localized: "写真ライブラリへの保存が許可されていません。設定アプリから許可してください")
                return
            }
            var failed = false
            for url in takes {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                    try? FileManager.default.removeItem(at: url)
                    keptCameraTakes.removeAll { $0 == url }
                } catch {
                    failed = true
                }
            }
            isSavingKeptTakes = false
            if !failed {
                showToast(String(localized: "写真に保存しました"))
                scheduleIncomingCheck()
            } else {
                alertMessage = String(localized: "写真に保存できませんでした")
            }
        }
    }

    /// 「動画を削除」: 残しておいた撮影を消す(自分で選んだときだけ)
    private func discardKeptCameraTakes() {
        for url in keptCameraTakes {
            try? FileManager.default.removeItem(at: url)
        }
        keptCameraTakes = []
        keptCameraTakesReason = nil
        scheduleIncomingCheck()
    }
}

/// 写真ピッカーで選んだ写真を受け取れなかった(iCloud にだけある写真を圏外で選んだなど)
private enum PickedPhotoLoadError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "写真を読み込めませんでした。iCloud にだけある写真は、インターネットに接続してからもう一度選んでください。")
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

    /// 取り込みに渡されたファイルが、カメラで撮った動画か(消さずに扱う。取り込めなければ残して、どうするか聞く)。
    /// 撮影の一時フォルダの中のものと、前に取り込めずに Media フォルダへ移したまま残したもの
    /// (deleteSourcesAfter で Media フォルダのファイルが渡されるのは、残した撮影の「もう一度取り込む」だけ)
    static func isCameraTake(_ url: URL) -> Bool {
        if CameraRecorder.isTemporaryRecording(url) { return true }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path
            == MediaStore.mediaDirectory.resolvingSymlinksInPath().path
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
    /// ↶ ↷(片手で持ったときに親指が届くよう、上部バーではなくこの行に置く)
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    /// 横向きの全画面プレビュー
    @State private var isFullScreen = false
    /// 全画面を開いた回数(開けたかを少しあとで確かめるときに、前の確認と取り違えないため)
    @State private var fullScreenRequest = 0
    /// 行の幅(狭い画面では全画面ボタンを出さず、↶ ↷ が再生ボタンに重ならないようにする。全画面は横に倒しても開く)
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        let current: Double = player.currentTime
        let showsFullScreenButton: Bool = rowWidth == 0 || rowWidth >= 330
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

            HStack(spacing: 0) {
                Spacer()
                EditorHistoryButton(systemImage: "arrow.uturn.backward",
                                    label: String(localized: "元に戻す"),
                                    isEnabled: canUndo,
                                    action: onUndo)
                EditorHistoryButton(systemImage: "arrow.uturn.forward",
                                    label: String(localized: "やり直す"),
                                    isEnabled: canRedo,
                                    action: onRedo)
                if showsFullScreenButton {
                    Button {
                        EditorHaptics.tap()
                        // 縦長・正方形の作品は回さずに縦のまま全画面にする(前は横に回され、映像は編集画面と同じくらいの大きさだった)
                        openFullScreen(isPortraitCanvas ? nil : .landscapeRight)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.duration <= 0)
                    .accessibilityLabel(isPortraitCanvas ? String(localized: "全画面で見る") : String(localized: "横向きの全画面で見る"))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // iPhone を横にしたら全画面で見る。
            // シート・アラート・写真の選択などを出している間は開かない(全画面を重ねて出せず、横向きのまま戻れなくなるため)
            let device = UIDevice.current.orientation
            // 縦長・正方形の作品では開かない(横にしても大きくならず、寝転んで傾けただけで開いて編集が止まっていた)
            if device.isLandscape, !isFullScreen, !OrientationController.isLargeWindow, player.duration > 0, !Self.isPresentingSomething,
               !isPortraitCanvas {
                openFullScreen(OrientationController.landscapeMask(for: device))
            } else if device == .portrait, isFullScreen, !OrientationController.isLargeWindow,
                      !OrientationController.isLandscapePreviewVisible {
                // 開こうとしている途中でたてに戻した・出せなかった: すぐ元に戻す
                closeFullScreen()
            }
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            LandscapePreviewView(player: player) {
                closeFullScreen()
            }
        }
    }

    /// 縦長・正方形の作品か(全画面にするとき回さない)
    private var isPortraitCanvas: Bool {
        let size = player.renderSize
        return size.width > 0 && size.height >= size.width
    }

    /// 全画面を開く。orientation が nil なら回さずに今の向きのまま出す(縦長・正方形の作品)
    private func openFullScreen(_ orientation: UIInterfaceOrientationMask?) {
        isFullScreen = true
        guard let orientation else { return }
        OrientationController.previewRequestedAt = Date()
        OrientationController.rotate(to: orientation)
        // 何かを出している最中などで全画面を出せなかったときは、横向きのままにせず元に戻す
        fullScreenRequest += 1
        let request = fullScreenRequest
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard request == fullScreenRequest, isFullScreen,
                  !OrientationController.isLandscapePreviewVisible else { return }
            closeFullScreen()
        }
    }

    private func closeFullScreen() {
        OrientationController.previewRequestedAt = nil
        OrientationController.rotate(to: .portrait)
        isFullScreen = false
    }

    /// 画面の上に何か(シート・アラート・写真の選択・広告など)を出しているか。
    /// キーウインドウだけでなく、前面のシーンのすべてのウインドウを見る(メニューなどで別のウインドウがキーのときも取りこぼさない)
    private static var isPresentingSomething: Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
        return windows.contains { window in
            guard let root = window.rootViewController else { return false }
            return root.presentedViewController != nil || root.transitionCoordinator != nil
        }
    }
}

/// 再生の行・シークバーの ↶ ↷(44pt)
private struct EditorHistoryButton: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(isEnabled ? 1 : 0.3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
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

// MARK: - キーフレームのパネル(再生位置の補間値を渡す)

/// EditorKeyframePanel に、再生位置でのキーフレームの補間値を currentValue として渡す。
/// キーフレームがあると描画は基本の値(center / scale / rotation / opacity)を見ないため、
/// 基本の値を渡すと「キーフレームを追加」が今見えている配置と違う値で入ってしまう。
/// 再生時刻の変化で ContentView 全体が描き直されないよう別の View にしている
private struct EditorKeyedKeyframePanel: View {
    let player: PlayerController
    /// 部品の出力タイムライン上の開始・長さ
    let start: Double
    let duration: Double
    /// キーフレームが無いときの配置(基本の値)
    let base: KeyframeInterpolator.Value
    @Binding var keyframes: [Keyframe]

    var body: some View {
        // EditorKeyframePanel の playheadRelative と同じ丸め方(部品の範囲内に収める)
        let local: Double = min(max(player.currentTime - start, 0), max(duration, 0))
        let current: KeyframeInterpolator.Value = KeyframeInterpolator.value(at: local, keyframes: keyframes, fallback: base)
        EditorKeyframePanel(player: player,
                            start: start,
                            duration: duration,
                            currentValue: current,
                            keyframes: $keyframes)
    }
}

// MARK: - パネルを開いている間の細いシークバー(44pt)

struct EditorScrubBar: View {
    let player: PlayerController
    /// パネルで編集している部品のタイムライン上の範囲(シークバーに色の帯で出す)
    let highlight: ClosedRange<Double>?
    /// ↶(パネルを開いている間も親指で届くように)
    let canUndo: Bool
    let undoLabel: String
    let onUndo: () -> Void
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
                .background {
                    if let highlight {
                        EditorScrubHighlight(range: highlight, total: total)
                    }
                }

            EditorTimeReadout(text: timeText)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize()
                .frame(minWidth: 58, alignment: .trailing)

            EditorHistoryButton(systemImage: "arrow.uturn.backward",
                                label: undoLabel,
                                isEnabled: canUndo,
                                action: onUndo)
        }
    }
}

/// シークバーの下に敷く、編集中の部品の範囲の帯。
/// つまみの中心が動く範囲(両端からつまみの半径ぶん内側)に合わせて置く
private struct EditorScrubHighlight: View {
    let range: ClosedRange<Double>
    let total: Double
    /// 標準の Slider のつまみの半径(おおよそ)
    private let thumbInset: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let usable: CGFloat = max(geo.size.width - thumbInset * 2, 1)
            let lower: CGFloat = CGFloat(min(max(range.lowerBound / total, 0), 1))
            let upper: CGFloat = CGFloat(min(max(range.upperBound / total, 0), 1))
            let x: CGFloat = thumbInset + usable * lower
            let width: CGFloat = max(usable * (upper - lower), 4)
            Capsule()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: width, height: 6)
                .position(x: x + width / 2, y: geo.size.height / 2 + 9)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
