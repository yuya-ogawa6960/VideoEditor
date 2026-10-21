import SwiftUI
import UIKit
import Observation

// =====================================================================
// Google フォトから選んで取り込むシート(Google Photos Picker API)。
//
// - 準備中(クライアント ID がない)→ 共有・ファイルからの方法を案内
// - 未ログイン → 何を見るのか(選んだものだけ)を説明して「Google でログイン」
// - ログイン済み → 「Google フォトを開いて選ぶ」でセッションを作り、Google フォトのアプリ(なければ Safari)を開く。
//   戻ってくるまで sessions.get を問い合わせ(バックグラウンドの間は止め、前面に戻ったらすぐ問い合わせる)、
//   選び終わったら一時フォルダへダウンロード → onPicked(urls) を 1 回呼んで閉じる
//   (取り込みとファイルの削除は呼び出し側)
// - ダウンロードの間は画面の自動ロックを止め、バックグラウンドの猶予(beginBackgroundTask)をもらう
// - キャンセル以外の失敗ではダウンロード済みのファイルを残し、「もう一度試す」では残りだけダウンロードする
//   (消すのはキャンセル・シートを閉じた・新しく選び直すとき)
// =====================================================================

struct GooglePhotosImportView: View {
    private let onPicked: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: GooglePhotosImportModel
    @State private var handedOver = false

    init(onPicked: @escaping ([URL]) -> Void) {
        self.onPicked = onPicked
        _model = State(initialValue: GooglePhotosImportModel())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    content
                    if let message = model.errorMessage, model.phase != .failed {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Google フォトから追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        model.cancelAll()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        // ダウンロード中に下へのスワイプで閉じてしまわないように
        .interactiveDismissDisabled(model.phase == .downloading)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.appDidBecomeActive()
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .done, !handedOver else { return }
            handedOver = true
            onPicked(model.resultFiles)
            dismiss()
        }
        .onDisappear {
            model.cancelAll()
        }
    }

    // MARK: - 見出し

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(BrandStyle.gradient)
            Text("Google フォト")
                .font(.title3.weight(.bold))
        }
        .padding(.top, 4)
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        if !GoogleOAuth.isConfigured {
            notConfiguredView
        } else if !model.isSignedIn {
            signInView
        } else {
            switch model.phase {
            case .ready, .signingIn:
                readyView
            case .opening:
                busyView(String(localized: "Google フォトを開いています…"))
            case .waiting:
                waitingView
            case .listing:
                busyView(String(localized: "選んだ写真・動画を確かめています…"))
            case .downloading:
                downloadingView
            case .partial:
                partialView
            case .failed:
                failedView
            case .done:
                busyView(String(localized: "追加しています…"), cancellable: false)
            }
        }
    }

    /// (a) 準備中
    private var notConfiguredView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Google フォトから直接取り込む機能は準備中です")
                .font(.headline)
            Text("今は次の方法で、Google フォトの写真・動画を追加できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if AppGroup.isAvailable {
                stepRow(number: 1, text: String(localized: "Google フォトで写真・動画を選び、「共有」から「Video Mania」を選ぶ"))
                stepRow(number: 2, text: String(localized: "または「共有」→「ファイルに保存」してから、Video Mania の追加で「ファイル(Google ドライブなど)」を選ぶ"))
            } else {
                // 共有の拡張機能が入っていない版では、「ファイルに保存」を通す方法だけを案内する
                stepRow(number: 1, text: String(localized: "Google フォトで写真・動画を選び、「共有」→「ファイルに保存」してから、Video Mania の追加で「ファイル(Google ドライブなど)」を選ぶ"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// (b) 未ログイン
    private var signInView: some View {
        VStack(spacing: 18) {
            Text("Google フォトの写真・動画を、この iPhone にダウンロードして編集できます。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                infoRow(icon: "hand.tap", text: String(localized: "見られるのは、あなたが Google フォトで選んだ写真・動画だけです。ライブラリ全体は見ません。"))
                infoRow(icon: "iphone", text: String(localized: "取り込んだ写真・動画は iPhone の中で編集します。開発者のサーバーに保存することはありません。"))
                infoRow(icon: "key", text: String(localized: "ログインの情報はこの iPhone にだけ保存します。ログアウトすればいつでも接続をやめられます。"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                EditorHaptics.tap()
                model.signIn()
            } label: {
                Group {
                    if model.phase == .signingIn {
                        ProgressView()
                            .tint(Color.white)
                    } else {
                        Label("Google でログイン", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(BrandProminentButtonStyle())
            .disabled(model.phase == .signingIn)
        }
    }

    /// (c) ログイン済み・待機
    private var readyView: some View {
        VStack(spacing: 16) {
            Text("Google フォトで写真・動画を選ぶと、この iPhone にダウンロードしてタイムラインに追加します。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                EditorHaptics.tap()
                model.startPicking()
            } label: {
                Label("Google フォトを開いて選ぶ", systemImage: "arrow.up.forward.app")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(BrandProminentButtonStyle())
            .disabled(model.phase == .signingIn)
            Text("一度に \(GooglePhotosPicker.maxItemCount) 個まで選べます。動画は Google フォトでの処理が終わったものだけ取り込めます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            signOutButton
        }
    }

    /// (c) Google フォトで選んでもらっている間
    private var waitingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Google フォトで選んで「完了」を押したら、このアプリに戻ってください")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                EditorHaptics.tap()
                model.reopenPicker()
            } label: {
                Label("もう一度 Google フォトを開く", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            Button("キャンセル", role: .cancel) {
                model.cancel()
            }
            .font(.subheadline)
        }
    }

    /// (c) ダウンロード中
    private var downloadingView: some View {
        VStack(spacing: 14) {
            Text("ダウンロード中 \(model.displayIndex) / \(model.downloadTotal)")
                .font(.headline.monospacedDigit())
            ProgressView(value: model.overallFraction)
                .tint(BrandStyle.blue)
            if !model.currentFilename.isEmpty {
                Text(model.currentFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ProgressView(value: model.itemFraction)
                .tint(BrandStyle.green)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
            Text("終わるまでこの画面のままお待ちください")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("キャンセル", role: .cancel) {
                model.cancel()
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
        }
    }

    /// 一部を取り込めなかった(確認してから渡す)
    private var partialView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle")
                .font(.title)
                .foregroundStyle(BrandStyle.orange)
            Text(model.partialMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                EditorHaptics.tap()
                model.acceptPartial()
            } label: {
                Text("\(model.resultFiles.count) 個を追加する")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(BrandProminentButtonStyle())
            Button("キャンセル", role: .cancel) {
                model.cancel()
            }
            .font(.subheadline)
        }
    }

    /// 失敗(やり直せる)
    private var failedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(BrandStyle.coral)
            Text(model.errorMessage ?? String(localized: "うまくいきませんでした。"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                EditorHaptics.tap()
                model.retry()
            } label: {
                Label("もう一度試す", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(BrandProminentButtonStyle())
            signOutButton
        }
    }

    private func busyView(_ title: String, cancellable: Bool = true) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if cancellable {
                Button("キャンセル", role: .cancel) {
                    model.cancel()
                }
                .font(.subheadline)
            }
        }
    }

    private var signOutButton: some View {
        Button("ログアウト") {
            model.signOut()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    // MARK: - 部品

    private func infoRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(BrandStyle.green)
                .frame(width: 24)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number))
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(BrandStyle.blue))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 状態

/// Google フォトから取り込むシートの状態と手順
@MainActor
@Observable
final class GooglePhotosImportModel {
    enum Phase: Equatable {
        /// ログイン済みで待機中(未ログインのときもこの状態)
        case ready
        case signingIn
        /// セッションを作って Google フォトを開いている
        case opening
        /// Google フォトで選んでもらっている
        case waiting
        /// 選ばれたものを確かめている
        case listing
        case downloading
        /// 一部を取り込めなかった(確認してから渡す)
        case partial
        case failed
        /// 渡す準備ができた(シートが onPicked を呼んで閉じる)
        case done
    }

    private(set) var phase: Phase = .ready
    private(set) var isSignedIn = false
    private(set) var errorMessage: String?
    private(set) var partialMessage = ""
    private(set) var resultFiles: [URL] = []

    private(set) var downloadIndex = 0
    private(set) var downloadTotal = 0
    private(set) var itemFraction: Double = 0
    private(set) var currentFilename = ""

    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var pickerURL: URL?
    /// ダウンロード先のフォルダ(渡していなければ、やめたときに消す)
    @ObservationIgnored private var downloadFolder: URL?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// 前面に戻ったので、待たずにすぐ問い合わせる
    @ObservationIgnored private var wakeRequested = false
    /// 失敗したのが選び終わった後(同じセッションでダウンロードからやり直せる)
    @ObservationIgnored private var canRetryDownload = false
    /// ファイルを呼び出し側に渡した(もう消さない)
    @ObservationIgnored private var delivered = false
    /// ダウンロードの間の画面ロックの止め・バックグラウンドの猶予を持っているか
    @ObservationIgnored private var isKeepingAwake = false
    /// 今のダウンロードの番号(前の手順の終わりが、あとから始めた分を外さないように)
    @ObservationIgnored private var keepAwakeToken = 0
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private static let idleTimerKey = "googlePhotos"

    init() {
        isSignedIn = GoogleOAuth.isSignedIn
    }

    /// 「ダウンロード中 3 / 10」の 3
    var displayIndex: Int {
        min(max(downloadIndex + 1, 1), max(downloadTotal, 1))
    }

    var overallFraction: Double {
        guard downloadTotal > 0 else { return 0 }
        return min(1, (Double(downloadIndex) + itemFraction) / Double(downloadTotal))
    }

    // MARK: - ログイン

    func signIn() {
        guard phase != .signingIn else { return }
        errorMessage = nil
        phase = .signingIn
        work?.cancel()
        work = Task { [weak self] in
            do {
                try await GoogleOAuth.signIn()
                guard let self else { return }
                self.isSignedIn = true
                self.phase = .ready
                EditorHaptics.success()
            } catch {
                guard let self else { return }
                self.phase = .ready
                self.handle(error)
            }
        }
    }

    func signOut() {
        cancel()
        GoogleOAuth.signOut()
        isSignedIn = false
        errorMessage = nil
        phase = .ready
    }

    // MARK: - 選ぶ

    /// セッションを作って Google フォトを開き、選び終わるのを待ってダウンロードする
    func startPicking() {
        work?.cancel()
        removeDownloadedFiles()
        dropSession()
        errorMessage = nil
        canRetryDownload = false
        delivered = false
        phase = .opening
        work = Task { [weak self] in
            await self?.runPicking()
        }
    }

    func reopenPicker() {
        guard let url = pickerURL else { return }
        Task { @MainActor [weak self] in
            let opened: Bool = await UIApplication.shared.open(url, options: [:])
            if !opened {
                self?.errorMessage = String(localized: "Google フォトを開けませんでした。もう一度お試しください。")
            }
        }
    }

    /// 前面に戻った(待っている間なら、すぐ問い合わせる)
    func appDidBecomeActive() {
        if phase == .waiting {
            wakeRequested = true
        }
        // ダウンロード中にバックグラウンドの猶予が時間切れで終わっていたら取り直す(次にロックしたときのため)
        beginBackgroundTaskIfNeeded()
    }

    /// 失敗のあとの「もう一度試す」
    func retry() {
        errorMessage = nil
        if canRetryDownload, sessionID != nil {
            work?.cancel()
            // ダウンロード済みのファイルは消さない(保存し終えたものは飛ばし、残りだけダウンロードする)
            phase = .listing
            work = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.downloadPicked()
                } catch {
                    self.handle(error)
                }
            }
        } else {
            startPicking()
        }
    }

    /// 一部を取り込めなかったが、取り込めたものを渡す
    func acceptPartial() {
        guard phase == .partial, !resultFiles.isEmpty else { return }
        deliver(resultFiles)
    }

    /// 「キャンセル」: 今の手順をやめて待機に戻る
    func cancel() {
        work?.cancel()
        work = nil
        endKeepAwake()
        removeDownloadedFiles()
        dropSession()
        canRetryDownload = false
        if phase != .done {
            phase = .ready
        }
    }

    /// シートを閉じるとき(渡していないファイルは消す)
    func cancelAll() {
        work?.cancel()
        work = nil
        endKeepAwake()
        removeDownloadedFiles()
        dropSession()
    }

    // MARK: - 手順

    private func runPicking() async {
        do {
            let session = try await GooglePhotosPicker.createSession()
            if Task.isCancelled {
                // 作っている間にやめた。作ったセッションは消しておく
                let orphan = session.id
                Task { await GooglePhotosPicker.deleteSession(orphan) }
                return
            }
            sessionID = session.id
            guard let url = session.pickerURL else { throw GooglePhotosError.invalidResponse }
            pickerURL = url
            wakeRequested = false
            phase = .waiting
            let opened: Bool = await UIApplication.shared.open(url, options: [:])
            try Task.checkCancellation()
            if !opened {
                errorMessage = String(localized: "Google フォトを開けませんでした。「もう一度 Google フォトを開く」を押してください。")
            }
            try await waitUntilPicked(session)
            try Task.checkCancellation()
            errorMessage = nil
            try await downloadPicked()
        } catch {
            handle(error)
        }
    }

    /// 選び終わるまで sessions.get を問い合わせる(バックグラウンドの間は止める)。
    /// 受付の期限は、問い合わせてもまだ選び終わっていないときだけ確かめる
    /// (期限を過ぎてから戻ってきても、選び終わっていれば取り込めるように)
    private func waitUntilPicked(_ first: GooglePickingSession) async throws {
        var session = first
        var deadline = Date().addingTimeInterval(session.timeout ?? 30 * 60)
        while !session.mediaItemsSet {
            try await pause(seconds: session.pollInterval)
            // バックグラウンド(Google フォトを見ている間)は問い合わせない。前面に戻ったら続ける
            while UIApplication.shared.applicationState != .active {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            wakeRequested = false
            session = try await GooglePhotosPicker.getSession(session.id)
            try Task.checkCancellation()
            if session.mediaItemsSet { break }
            // 残りの時間(timeoutIn)は問い合わせのたびに取り直す
            if let timeout = session.timeout {
                deadline = Date().addingTimeInterval(timeout)
            }
            if Date() >= deadline { throw GooglePhotosError.pickerTimedOut }
        }
    }

    /// seconds だけ待つ。前面に戻ったら途中でも終わる
    private func pause(seconds: TimeInterval) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if wakeRequested {
                wakeRequested = false
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 選ばれたものを受け取ってダウンロードする
    private func downloadPicked() async throws {
        guard let id = sessionID else { throw GooglePhotosError.sessionExpired }
        // 終わるまで画面の自動ロックを止め、バックグラウンドの猶予をもらう(終わり・失敗・キャンセルで外す)
        let keepAwake = beginKeepAwake()
        defer { endKeepAwake(keepAwake) }
        canRetryDownload = true
        phase = .listing
        let items = try await GooglePhotosPicker.listItems(sessionID: id)
        try Task.checkCancellation()
        let listedAt = Date()
        guard !items.isEmpty else {
            canRetryDownload = false
            throw GooglePhotosError.nothingPicked
        }
        downloadIndex = 0
        downloadTotal = items.filter { $0.isDownloadable }.count
        itemFraction = 0
        currentFilename = ""
        downloadFolder = GooglePhotosPicker.sessionFolder(for: id)
        phase = .downloading
        let result = try await GooglePhotosPicker.download(items, sessionID: id, listedAt: listedAt) { progress in
            self.apply(progress)
        }
        try Task.checkCancellation()
        // もう要らないのでセッションを消す
        canRetryDownload = false
        dropSession()
        guard !result.files.isEmpty else {
            throw GooglePhotosError.nothingDownloadable(processing: result.processingCount, failed: result.failedCount)
        }
        resultFiles = result.files
        if result.processingCount > 0 || result.failedCount > 0 {
            var notes: [String] = []
            if result.processingCount > 0 {
                notes.append(String(localized: "\(result.processingCount) 本の動画は Google フォトでまだ処理中のため、取り込めませんでした。少し待ってからもう一度選んでください。"))
            }
            if result.failedCount > 0 {
                notes.append(String(localized: "\(result.failedCount) 個はダウンロードできませんでした。"))
            }
            partialMessage = notes.joined(separator: "\n")
            phase = .partial
            EditorHaptics.warning()
            return
        }
        deliver(result.files)
    }

    private func apply(_ progress: GooglePhotosDownloadProgress) {
        guard phase == .downloading else { return }
        // 前のファイルの知らせが遅れて届いても戻らない
        if progress.index < downloadIndex { return }
        if progress.index > downloadIndex {
            downloadIndex = progress.index
            itemFraction = min(max(progress.fraction, 0), 1)
            currentFilename = progress.filename
            return
        }
        if currentFilename.isEmpty, !progress.filename.isEmpty {
            currentFilename = progress.filename
        }
        let fraction = min(max(progress.fraction, 0), 1)
        // 細かすぎる更新は間引く
        if fraction >= 1 || abs(fraction - itemFraction) >= 0.01 {
            itemFraction = fraction
        }
    }

    private func deliver(_ files: [URL]) {
        delivered = true
        resultFiles = files
        EditorHaptics.success()
        phase = .done
    }

    private func handle(_ error: Error) {
        // キャンセル(「キャンセル」・シートを閉じた)は何も出さない
        if error is CancellationError || Task.isCancelled { return }
        if let oauthError = error as? GoogleOAuthError {
            switch oauthError {
            case .cancelled:
                if phase == .signingIn { phase = .ready }
                return
            case .signInRequired:
                dropSession()
                removeDownloadedFiles()
                canRetryDownload = false
                isSignedIn = false
                errorMessage = oauthError.localizedDescription
                phase = .ready
                EditorHaptics.warning()
                return
            default:
                break
            }
        }
        if let photosError = error as? GooglePhotosError {
            switch photosError {
            case .sessionExpired, .pickerTimedOut, .nothingPicked:
                // 同じセッションではやり直せない
                canRetryDownload = false
                dropSession()
            default:
                break
            }
        }
        if !canRetryDownload {
            dropSession()
        }
        errorMessage = error.localizedDescription
        if isSignedIn {
            phase = .failed
        } else {
            // ログイン前の失敗は、ログインの画面のまま赤い文で出す
            phase = .ready
        }
        EditorHaptics.warning()
    }

    // MARK: - ダウンロードの間の画面ロック・バックグラウンド

    /// 画面の自動ロックを止め、バックグラウンドの猶予をもらう。返した番号を endKeepAwake に渡す
    private func beginKeepAwake() -> Int {
        keepAwakeToken += 1
        isKeepingAwake = true
        IdleTimerGuard.set(true, for: Self.idleTimerKey)
        beginBackgroundTaskIfNeeded()
        return keepAwakeToken
    }

    /// 画面ロックの止めとバックグラウンドの猶予を外す。
    /// token を渡したときは、それが今のダウンロードの分のときだけ外す(nil ならいつでも外す: キャンセル・閉じたとき)
    private func endKeepAwake(_ token: Int? = nil) {
        if let token, token != keepAwakeToken { return }
        isKeepingAwake = false
        IdleTimerGuard.set(false, for: Self.idleTimerKey)
        endBackgroundTask()
    }

    /// ダウンロード中で、バックグラウンドの猶予を持っていなければもらう
    private func beginBackgroundTaskIfNeeded() {
        guard isKeepingAwake, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "GooglePhotosDownload") { [weak self] in
            // 時間切れ(メインスレッドで呼ばれる)。終了しないとアプリが強制終了される。ダウンロードそのものは止めない
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// セッションを消す(届かなくてもよい)
    private func dropSession() {
        guard let id = sessionID else { return }
        sessionID = nil
        pickerURL = nil
        Task {
            await GooglePhotosPicker.deleteSession(id)
        }
    }

    /// まだ渡していないダウンロード済みのファイルを消す(渡したものは呼び出し側が消すので触らない)
    private func removeDownloadedFiles() {
        guard !delivered else { return }
        let fm = FileManager.default
        for file in resultFiles {
            try? fm.removeItem(at: file)
        }
        resultFiles = []
        if let folder = downloadFolder {
            try? fm.removeItem(at: folder)
        }
        downloadFolder = nil
    }
}
