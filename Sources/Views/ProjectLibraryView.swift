import SwiftUI
import UIKit
import UniformTypeIdentifiers

// =====================================================================
// プロジェクト一覧(CapCut のホーム画面に相当)と、一覧 ⇄ 編集画面を切り替えるルート。
// プロジェクトを別の端末に送る(.videomania パッケージ)/ 受け取るのもここから行う(ProjectPackage)。
// =====================================================================

// MARK: - ルート

/// アプリのルート。プロジェクトを開いていなければ一覧、開いていれば編集画面(ContentView)
struct RootView: View {
    @State private var openProjectID: UUID?
    /// 開いたときの動画の置き場所(閉じるときに変わっていれば、次の「新しいプロジェクト」に使う)
    @State private var openedMediaMode: ProjectMediaMode = .appCopy
    /// 「ファイル」アプリや AirDrop から開かれた .videomania(一覧が表示されたら読み込む)
    @State private var openedPackageURL: URL?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let projectID = openProjectID {
                ContentView(projectID: projectID, onClose: {
                    // 編集画面の「その他」で動画の置き場所を変えていたら、次に作るプロジェクトもそれにする
                    if let mode = ProjectLibrary.shared.project(id: projectID)?.effectiveMediaMode, mode != openedMediaMode {
                        NewProjectMediaMode.last = mode
                    }
                    openProjectID = nil
                    AdsManager.shared.showInterstitial(.projectClosed)
                })
                .id(projectID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ProjectLibraryView(openedPackageURL: $openedPackageURL, onOpen: { meta in
                    openedMediaMode = meta.effectiveMediaMode
                    openProjectID = meta.id
                    Analytics.shared.track("project_open")
                })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: openProjectID)
        // .videomania をタップして開かれたとき。編集中なら、一覧に戻ったときに受け取る
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == ProjectPackage.packageExtension else { return }
            openedPackageURL = url
        }
        // 広告(トラッキングの確認 → AdMob の開始 → 広告の読み込み)
        .task { await AdsManager.shared.start() }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンドに回ったら、まとめ書き待ちの保存をすぐに書き出す
            if phase == .background {
                ProjectStore.flushAll()
                ProjectLibrary.shared.flush()
            }
            // アプリに戻ってきたら、共有で受け取った動画・写真がないか見る(一覧・編集画面がそれぞれ確認を出す)
            if phase == .active {
                IncomingMediaCenter.shared.refresh()
            }
        }
    }
}

// MARK: - 新しいプロジェクトの動画の置き場所

/// 「新しいプロジェクト」に使う動画の置き場所。最後に使ったものを覚えておく(初期値はアプリに取り込む)。
/// 編集画面の「その他」→「動画の置き場所」で変えると、次に作るプロジェクトから使われる
enum NewProjectMediaMode {
    private static let key = "project.newMediaMode"

    static var last: ProjectMediaMode {
        get { ProjectMediaMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .appCopy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - 一覧

struct ProjectLibraryView: View {
    /// 「ファイル」アプリなどから開かれた .videomania。受け取りを始めたら nil に戻す
    @Binding var openedPackageURL: URL?
    let onOpen: (ProjectMeta) -> Void

    /// 送るプロジェクトのパッケージ(<名前>.videomania)の種類(project.yml の UTExportedTypeDeclarations)
    private static let packageType = UTType(exportedAs: "com.yuyaogawa6960.videomania.project", conformingTo: .package)

    private let library = ProjectLibrary.shared

    @State private var renameTarget: ProjectMeta?
    @State private var renameText = ""
    @State private var isRenaming = false

    @State private var deleteTarget: ProjectMeta?
    @State private var isDeleting = false

    // パッケージを送る / 受け取る
    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var exportingMeta: ProjectMeta?
    @State private var exportProgress: Double = 0
    /// 送る準備ができて共有シートを出している間(閉じるまで、ほかの送る・受け取るを止める)
    @State private var isSharingPackage = false
    @State private var alertTitle = ""
    @State private var alertMessage: String?

    /// ドラッグ中の項目が一覧の上にあるか(落とすと新しいプロジェクト)
    @State private var dropTargeted = false
    /// 落とした動画・写真を受け取っている間(ほかの操作を止めて、読み込み中を出す)
    @State private var isLoadingDrop = false
    /// 共有で受け取った動画・写真を「新しいプロジェクトで編集」するか聞く
    @State private var showIncomingPrompt = false
    @State private var incomingPromptCount = 0
    /// 「あとで」を選んだときに受け取っていた素材(同じ内容のままならもう聞かない)。
    /// 編集画面を開くと一覧は作り直されるので、@State ではなくアプリが動いている間だけ覚えておく
    @MainActor private static var postponedIncomingURLs: [URL] = []
    /// 共有で受け取った素材の確認を少し待ってから行う処理(広告やシートなどが閉じてから聞く)
    @State private var incomingCheckTask: Task<Void, Never>?
    @State private var incomingCheckAttempts = 0

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(openedPackageURL: Binding<URL?>, onOpen: @escaping (ProjectMeta) -> Void) {
        self._openedPackageURL = openedPackageURL
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    newProjectButton

                    if library.projects.isEmpty {
                        emptyHint
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text("最近のプロジェクト")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(library.projects.count) 件")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        grid
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                // ほかのお知らせ(ScrollView・NavigationStack に付けたもの)と別の View に付ける
                .alert("共有で受け取った動画・写真が \(incomingPromptCount)件あります", isPresented: $showIncomingPrompt) {
                    Button("新しいプロジェクトで編集") {
                        createProject(mediaMode: .appCopy, importingIncomingMedia: true)
                    }
                    Button("あとで", role: .cancel) {
                        Self.postponedIncomingURLs = IncomingMediaCenter.shared.pendingURLs
                    }
                } message: {
                    Text("今あるプロジェクトに追加するときは「あとで」を選んでから、そのプロジェクトを開いてください。")
                }
            }
            .background(Color.black.ignoresSafeArea())
            // ほかのアプリから動画・写真を落とすと、新しいプロジェクトを作って取り込む
            .onDrop(of: MediaDrop.types, isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if dropTargeted, !isPackageBusy {
                    MediaDropHighlight(title: String(localized: "新しいプロジェクトで編集"))
                        .padding(8)
                }
            }
            // 受け取っている間は一覧を触れないようにする(途中でほかのプロジェクトを開かないように)
            .overlay {
                if isLoadingDrop {
                    ZStack {
                        Color.black.opacity(0.5).ignoresSafeArea()
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
            }
            .navigationTitle("プロジェクト")
            // 画面の下にバナー広告(広告が届く前から同じ高さで場所を取り、届かなければ閉じる。BannerAdView.swift)
            .safeAreaInset(edge: .bottom) {
                BannerAdSlot()
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // ポイントのサーバーが無いビルド(準備中)では出さない
                    if AccountService.shared.isAvailable {
                        NavigationLink {
                            AccountPointsView()
                        } label: {
                            AccountPointsSummaryLabel()
                                .loadingPointsIfNeeded()
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline)
                        }
                        .accessibilityLabel("アカウントとポイント")
                        .accessibilityValue(AccountService.shared.points.map { "\($0)pt" } ?? "")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .accessibilityLabel("設定")
                    Menu {
                        Button {
                            isImporterPresented = true
                        } label: {
                            Label("別の端末から受け取る", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isPackageBusy)
                    } label: {
                        Label("その他", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("その他")
                }
            }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: [Self.packageType, .folder, .package, .item],
                          allowsMultipleSelection: false) { result in
                handlePackageImport(result)
            }
            .onChange(of: openedPackageURL, initial: true) { _, _ in
                importOpenedPackageIfReady()
            }
            .onChange(of: isPackageBusy) { _, busy in
                importOpenedPackageIfReady()
                if !busy { scheduleIncomingCheck() }
            }
            // 共有で受け取った動画・写真がないか見る(編集画面から戻ったときの広告などが閉じるのを少し待つ)
            .onAppear {
                IncomingMediaCenter.shared.refresh()
                scheduleIncomingCheck()
            }
            .onDisappear {
                incomingCheckTask?.cancel()
                incomingCheckTask = nil
            }
            .onChange(of: IncomingMediaCenter.shared.pendingURLs) { _, _ in
                scheduleIncomingCheck()
            }
            .onChange(of: alertMessage) { _, message in
                if message == nil { scheduleIncomingCheck() }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
            .overlay {
                if isImporting || exportingMeta != nil {
                    packageProgressOverlay
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("名前を変更", isPresented: $isRenaming) {
            TextField("プロジェクト名", text: $renameText)
            Button("キャンセル", role: .cancel) {
                renameTarget = nil
            }
            Button("保存") {
                if let target = renameTarget {
                    library.rename(id: target.id, to: renameText)
                }
                renameTarget = nil
            }
        } message: {
            Text("新しいプロジェクト名を入力してください。")
        }
        .confirmationDialog(deleteTitle, isPresented: $isDeleting, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let target = deleteTarget {
                    library.delete(id: target.id)
                }
                deleteTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("編集内容とサムネイルを削除します。元に戻せません。写真アプリの元の動画・写真は消えません。")
        }
    }

    private var deleteTitle: String {
        String(localized: "「\(deleteTarget?.name ?? "")」を削除しますか?")
    }

    // MARK: 部品

    private var newProjectButton: some View {
        Button {
            // 動画の置き場所は最後に使ったもの(編集画面の「その他」で変えられる)
            createProject(mediaMode: NewProjectMediaMode.last)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                Text("新しいプロジェクト")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(FacetedBrandBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新しいプロジェクト")
        .task {
            // 前に送ったプロジェクトのパッケージ(素材のコピー入り)と GIF は、もう共有に使わないので消す
            // (この画面で新しく送る前に済むよう、先に行う)
            await Task.detached(priority: .utility) {
                ProjectPackage.cleanUpExportedPackages()
                try? FileManager.default.removeItem(at: GIFExporter.outputDirectory)
            }.value
            // どのプロジェクトからも使われなくなった動画を消して容量を空ける(1 日以上前に取り込んだものだけ)
            _ = await Task.detached(priority: .utility) {
                ProjectStore.cleanUpUnusedMedia()
            }.value
        }
    }

    /// importingIncomingMedia: 共有で受け取った動画・写真を編集するために作る(開いた編集画面が聞かずに取り込む)
    private func createProject(mediaMode: ProjectMediaMode, importingIncomingMedia: Bool = false,
                               droppedMedia: [URL]? = nil) {
        Analytics.shared.track("project_create", ["media": String(describing: mediaMode)])
        let meta = library.create(mediaMode: mediaMode)
        if importingIncomingMedia {
            IncomingMediaCenter.shared.autoImportProjectID = meta.id
        }
        if let droppedMedia {
            DroppedMediaHandoff.set(droppedMedia, for: meta.id)
        }
        onOpen(meta)
    }

    /// ほかのアプリから落とした動画・写真で新しいプロジェクトを作る(素材はアプリ内にコピーする)
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !isPackageBusy else { return false }
        isLoadingDrop = true
        Task { @MainActor in
            let urls = await MediaDrop.loadFiles(from: providers)
            isLoadingDrop = false
            guard !urls.isEmpty else {
                showAlert(String(localized: "追加できませんでした"), String(localized: "動画・写真のデータを取得できませんでした。"))
                return
            }
            createProject(mediaMode: .appCopy, droppedMedia: urls)
        }
        return true
    }

    // MARK: 共有で受け取った動画・写真

    /// 共有で受け取った動画・写真があれば「新しいプロジェクトで編集」するか聞く。
    /// プロジェクトを送る・受け取る途中やお知らせを出している間は終わってから(onChange で呼び直す)。
    /// 広告・シート・ダイアログなどを出している間は、少し待って確かめ直す
    private func checkIncomingMedia() {
        let urls: [URL] = IncomingMediaCenter.shared.pendingURLs
        guard !urls.isEmpty, !showIncomingPrompt, urls != Self.postponedIncomingURLs else { return }
        guard !isPackageBusy, alertMessage == nil else { return }
        if ScreenPresentation.isPresentingSomething {
            // 重ねて出せない(出せなかった確認が残ってしまう)ので、閉じてから聞く
            scheduleIncomingCheck(retry: true)
            return
        }
        incomingPromptCount = urls.count
        showIncomingPrompt = true
    }

    /// 少し待ってから checkIncomingMedia を呼ぶ。
    /// retry は何かを出していて聞けなかったときの確かめ直し(40 回、約 1 分まで。あとはアプリに戻ったときなどに呼び直す)
    private func scheduleIncomingCheck(retry: Bool = false) {
        if retry {
            incomingCheckAttempts += 1
            guard incomingCheckAttempts <= 40 else { return }
        } else {
            incomingCheckAttempts = 0
        }
        let delay: UInt64 = retry ? 1_500_000_000 : 800_000_000
        incomingCheckTask?.cancel()
        incomingCheckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            checkIncomingMedia()
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            // カメラの横で手を振って誘うロボット(AIWorkingOverlay.swift)
            RobotWorkshop(clip: .emptyProjects)
            Text("まだプロジェクトがありません")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 上の「新しいプロジェクト」を押す")
                Text("2. 「動画・写真を追加」で素材を選ぶ")
                Text("3. 編集して「書き出し」で写真アプリに保存")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text("編集内容は自動で保存されるので、途中でやめても大丈夫です。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            // 別の端末で作ったプロジェクト(.videomania)を持っている人のため。右上の「その他」からも開ける
            Button {
                isImporterPresented = true
            } label: {
                Text("別の端末からプロジェクトを受け取る")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .disabled(isPackageBusy)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(library.projects) { meta in
                ProjectCardView(meta: meta,
                                thumbnailRevision: library.thumbnailRevision,
                                onOpen: { onOpen(meta) },
                                onRename: { beginRename(meta) },
                                onDuplicate: { _ = library.duplicate(id: meta.id) },
                                onExport: { exportPackage(meta) },
                                onDelete: { beginDelete(meta) })
            }
        }
    }

    private var packageProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                if let meta = exportingMeta {
                    ProgressView(value: min(max(exportProgress, 0), 1))
                    Text("「\(meta.name)」を送る準備中… \(Int((min(max(exportProgress, 0), 1) * 100).rounded()))%")
                        .font(.callout)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                    Text("プロジェクトを受け取り中…")
                        .font(.callout)
                }
            }
            .padding(20)
            .frame(width: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: 操作

    private func beginRename(_ meta: ProjectMeta) {
        renameTarget = meta
        renameText = meta.name
        isRenaming = true
    }

    private func beginDelete(_ meta: ProjectMeta) {
        deleteTarget = meta
        isDeleting = true
    }

    private func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }

    // MARK: パッケージを送る / 受け取る

    /// プロジェクトを <名前>.videomania(フォルダ形式)にまとめて、そのまま共有シートへ
    private func exportPackage(_ meta: ProjectMeta) {
        guard !isPackageBusy else { return }
        // まとめ書き待ちの保存があれば先に書く
        ProjectStore.flush(projectID: meta.id)
        exportingMeta = meta
        exportProgress = 0
        Task { @MainActor in
            do {
                let url = try await ProjectPackage.export(projectID: meta.id, progress: { value in
                    Task { @MainActor in
                        exportProgress = value
                    }
                })
                exportingMeta = nil
                // 共有シート(AirDrop・「ファイル」に保存など)を閉じるまでは、ほかの送る・受け取るを止めておく
                isSharingPackage = true
                let presented = PackageShare.present(url) {
                    isSharingPackage = false
                }
                if !presented {
                    isSharingPackage = false
                    showAlert(String(localized: "送れませんでした"),
                              String(localized: "もう一度「別の端末に送る」を押してください。"))
                }
            } catch {
                exportingMeta = nil
                showAlert(String(localized: "送る準備ができませんでした"),
                          String(localized: "端末の空き容量を確かめて、もう一度「別の端末に送る」を押してください。\n\n詳細: ") + error.localizedDescription)
            }
        }
    }

    private func handlePackageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showAlert(String(localized: "ファイルを開けませんでした"),
                      String(localized: "もう一度「別の端末から受け取る」から選び直してください。\n\n詳細: ") + error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            importPackage(from: url, removeAfterImport: false)
        }
    }

    private func importPackage(from url: URL, removeAfterImport: Bool) {
        isImporting = true
        Task { @MainActor in
            do {
                let meta = try await ProjectPackage.importPackage(from: url)
                isImporting = false
                if removeAfterImport {
                    // 読み込んだので、受け取り用にコピーされたパッケージ(Documents/Inbox)は要らない
                    try? FileManager.default.removeItem(at: url)
                }
                showAlert(String(localized: "受け取りました"), String(localized: "「\(meta.name)」を一覧に追加しました。タップすると開けます。"))
            } catch {
                isImporting = false
                showAlert(String(localized: "受け取れませんでした"), String(localized: "「別の端末に送る」で作った .videomania のファイルを選んでください。途中で壊れたときは送り直してもらってください。\n\n詳細: ") + error.localizedDescription)
            }
        }
    }

    /// 受け取り・送る準備・共有シート・落とした素材の受け取りのどれかが進行中
    private var isPackageBusy: Bool {
        isImporting || exportingMeta != nil || isSharingPackage || isLoadingDrop
    }

    /// 「ファイル」アプリなどから開かれた .videomania を、ほかの送る・受け取るが終わっていれば受け取る
    private func importOpenedPackageIfReady() {
        guard let url = openedPackageURL, !isPackageBusy else { return }
        openedPackageURL = nil
        importPackage(from: url, removeAfterImport: Self.isInInbox(url))
    }

    /// AirDrop などで、このアプリの Documents/Inbox にコピーされて渡されたファイルか
    private static func isInInbox(_ url: URL) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(inbox + "/")
    }
}

// MARK: - 画面の上に何かを出しているか

/// 画面の上に何か(シート・アラート・ダイアログ・写真やファイルの選択・広告など)を出しているか。
/// 出している間は、共有で受け取った素材の確認を出さない(重ねて出せず、出せなかった確認が残ってしまうため)
@MainActor
enum ScreenPresentation {
    /// キーウインドウのルートの画面
    static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    static var isPresentingSomething: Bool {
        rootViewController?.presentedViewController != nil
    }
}

// MARK: - パッケージ共有

/// まとめた .videomania を共有シート(AirDrop・「ファイル」に保存など)で別の端末に送る
@MainActor
private enum PackageShare {
    /// いちばん上の画面から共有シートを出す。閉じたら(送っても、やめても)onFinish を 1 回呼ぶ。出せなければ false
    static func present(_ url: URL, onFinish: @escaping () -> Void) -> Bool {
        guard var top = ScreenPresentation.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onFinish()
        }
        // iPad ではポップオーバーになるので、出す位置が要る
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
        return true
    }
}

// MARK: - カード

private struct ProjectCardView: View {
    let meta: ProjectMeta
    let thumbnailRevision: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                ProjectThumbnailView(projectID: meta.id, reloadKey: reloadKey)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        durationBadge
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(meta.name) を開く")

            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, -8)
                .padding(.trailing, -8)
                .accessibilityLabel("その他の操作")
            }
        }
        .contextMenu {
            menuItems
        }
    }

    private var reloadKey: String {
        "\(thumbnailRevision)-\(meta.updatedAt.timeIntervalSinceReferenceDate)"
    }

    private var subtitle: String {
        let date = ProjectDateText.relative(meta.updatedAt)
        return date + String(localized: " ・ \(meta.clipCount) クリップ")
    }

    private var durationBadge: some View {
        Text(ProjectDurationText.mss(meta.duration))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
            .padding(6)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRename) {
            Label("名前を変更", systemImage: "pencil")
        }
        Button(action: onDuplicate) {
            Label("複製", systemImage: "plus.square.on.square")
        }
        Button(action: onExport) {
            Label("別の端末に送る", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive, action: onDelete) {
            Label("削除", systemImage: "trash")
        }
    }
}

// MARK: - サムネイル

private struct ProjectThumbnailView: View {
    let projectID: UUID
    /// 変わるとファイルを読み直す
    let reloadKey: String

    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .clipped()
            .task(id: reloadKey) {
                image = ProjectStore.loadThumbnail(projectID: projectID)
            }
    }
}

// MARK: - 時間表示

private enum ProjectDurationText {
    /// m:ss
    static func mss(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

// MARK: - 日付表示

private enum ProjectDateText {
    /// 「今日 14:05」「昨日 9:30」「3日前」「2025/10/01」のような、わかりやすい日付
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return String(localized: "今日 ") + time
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨日 ") + time
        }
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let days: Int = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if days >= 2 && days < 7 {
            return String(localized: "\(days)日前")
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
