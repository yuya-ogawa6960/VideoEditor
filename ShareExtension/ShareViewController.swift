import UIKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import ImageIO

// =====================================================================
// 「共有」から Video Mania に動画・写真を送る拡張機能。
// 写真アプリ・Google フォト・ファイルなどの共有シートから呼ばれ、受け取ったファイルを
// App Group の Inbox/<yyyyMMdd-HHmmss>-<UUID>/<NNN>-<元の名前> にコピーする(Shared/AppGroup.swift)。
// 書き込み中は先頭に "." を付けた隠しフォルダに置き、全部書き終えてから名前を変えてアプリから見えるようにする。
// 取り込みはアプリを開いたときに行う(Sources/Model/IncomingMedia.swift の IncomingMediaCenter)。
// 拡張機能が使えるメモリは約 120 MB しかないので、動画は必ずファイルのままコピーし、メモリに読み込まない。
// 拡張機能では UIApplication.shared などアプリ専用の API は使えない。
// =====================================================================

/// 共有シートから作られる画面(Info.plist の NSExtensionPrincipalClass)
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(ShareBrand.navy)
        // 送っている途中に下へのスワイプで閉じてしまわないように(キャンセルはボタンで)
        isModalInPresentation = true

        let model = ShareModel()
        model.onComplete = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        model.onCancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        self.model = model

        let host = UIHostingController(rootView: ShareStatusView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        startIfPossible(force: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidLoad の時点で extensionContext がまだないときは、表示されてから始める
        startIfPossible(force: true)
    }

    /// 共有されたもの(NSExtensionItem の attachments)を集めて送り始める(1 回だけ)
    private func startIfPossible(force: Bool) {
        guard let model, !model.hasStarted else { return }
        guard let context = extensionContext else {
            if force { model.start(providers: []) }
            return
        }
        var providers: [NSItemProvider] = []
        for case let item as NSExtensionItem in context.inputItems {
            providers.append(contentsOf: item.attachments ?? [])
        }
        model.start(providers: providers)
    }
}

// MARK: - 送る処理の状態

@MainActor
@Observable
final class ShareModel {
    enum Phase {
        /// 送るものを確かめている
        case preparing
        /// コピー中(current 件目 / 全 total 件)
        case sending(current: Int, total: Int)
        /// 送り終えた(sent 件を送り、failed 件は送れなかった)
        case done(sent: Int, failed: Int)
        /// 1 件も送れなかった
        case failed(message: String, detail: String?)
    }

    /// 1 件分(共有されたもの 1 つと、その種類)
    private struct Item {
        let provider: NSItemProvider
        let kind: ShareInboxWriter.Kind
    }

    private(set) var phase: Phase = .preparing

    /// 「OK」(送り終えた)を押したとき
    @ObservationIgnored var onComplete: (() -> Void)? = nil
    /// 「キャンセル」(送っている途中)・「閉じる」(送れなかった)を押したとき
    @ObservationIgnored var onCancel: (() -> Void)? = nil

    @ObservationIgnored private var task: Task<Void, Never>? = nil
    /// 書き込み中の隠しフォルダ(キャンセル・失敗のときに消す)
    @ObservationIgnored private var workingFolder: URL? = nil
    @ObservationIgnored private var isCancelled = false
    /// いま読み込み中の NSItemProvider の Progress(キャンセルで止める)
    private let progressBox = ShareProgressBox()

    var hasStarted: Bool { task != nil }

    func start(providers: [NSItemProvider]) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(providers)
        }
    }

    /// 送り終えた画面の「OK」
    func finish() {
        onComplete?()
    }

    /// 送っている途中の「キャンセル」
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        task?.cancel()
        progressBox.cancel()
        removeWorkingFolder()
        onCancel?()
    }

    /// 送れなかった画面の「閉じる」
    func close() {
        removeWorkingFolder()
        onCancel?()
    }

    private func run(_ providers: [NSItemProvider]) async {
        guard !isCancelled else { return }
        guard let inbox = AppGroup.inboxURL else {
            fail(String(localized: "受け取り用のフォルダを開けませんでした。Video Mania を最新版に更新してから、もう一度お試しください。"))
            return
        }
        var items: [Item] = []
        for provider in providers {
            if let kind = ShareInboxWriter.kind(of: provider) {
                items.append(Item(provider: provider, kind: kind))
            }
        }
        guard !items.isEmpty else {
            fail(String(localized: "送れる動画・写真が見つかりませんでした。"))
            return
        }

        let batchName = ShareInboxWriter.makeBatchName()
        let working = inbox.appendingPathComponent("." + batchName, isDirectory: true)
        let published = inbox.appendingPathComponent(batchName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        } catch {
            fail(String(localized: "受け取り用のフォルダを作れませんでした。"), detail: error.localizedDescription)
            return
        }
        workingFolder = working

        var sent = 0
        var failedCount = 0
        var lastError: Error?
        for (index, item) in items.enumerated() {
            guard !isCancelled else {
                removeWorkingFolder()
                return
            }
            phase = .sending(current: index + 1, total: items.count)
            do {
                // 1 件ずつ順番に(写真をメモリに読み込むときも 1 枚分で済むように)
                try await ShareInboxWriter.save(item.provider, kind: item.kind, number: index + 1,
                                                into: working, box: progressBox)
                sent += 1
            } catch {
                failedCount += 1
                lastError = error
            }
        }
        guard !isCancelled else {
            removeWorkingFolder()
            return
        }

        guard sent > 0 else {
            removeWorkingFolder()
            fail(String(localized: "動画・写真を読み込めませんでした。"), detail: lastError?.localizedDescription)
            return
        }
        do {
            // 全部書き終えてから名前を変えて、アプリから見えるようにする
            try FileManager.default.moveItem(at: working, to: published)
            workingFolder = nil
        } catch {
            removeWorkingFolder()
            fail(String(localized: "受け取り用のフォルダに保存できませんでした。"), detail: error.localizedDescription)
            return
        }
        phase = .done(sent: sent, failed: failedCount)
        ShareHaptics.success()
    }

    private func fail(_ message: String, detail: String? = nil) {
        phase = .failed(message: message, detail: detail)
        ShareHaptics.warning()
    }

    private func removeWorkingFolder() {
        guard let folder = workingFolder else { return }
        try? FileManager.default.removeItem(at: folder)
        workingFolder = nil
    }
}

// MARK: - 受け取り箱への書き込み

/// NSItemProvider から受け取り箱(Inbox の中のフォルダ)にファイルを書き込む。
/// NSItemProvider の完了ハンドラは別のスレッドで呼ばれ、渡された一時ファイルはハンドラから戻ると消されるので、
/// コピーはハンドラの中で済ませる
enum ShareInboxWriter {
    enum Kind {
        case movie
        case image
    }

    /// 書き込み先を決めるための情報
    struct Target: Sendable {
        let folder: URL
        let number: Int
        /// 共有元が付けた名前(拡張子なしのことが多い)
        let suggestedName: String?
        /// 名前がわからないときの名前
        let fallbackBaseName: String
        /// 中身の拡張子がわからないときの拡張子
        let fallbackExtension: String

        func destination(sourceURL: URL?, fileExtension: String) -> URL {
            let name = ShareInboxWriter.fileName(number: number, suggestedName: suggestedName, sourceURL: sourceURL,
                                                 fallbackBaseName: fallbackBaseName, fileExtension: fileExtension)
            return folder.appendingPathComponent(name, isDirectory: false)
        }
    }

    /// 動画か写真か(どちらでもなければ nil = 送らない)
    static func kind(of provider: NSItemProvider) -> Kind? {
        // Live Photos は写真として送る(com.apple.live-photo-bundle・com.apple.private.live-photo-bundle など)
        let isLivePhoto = provider.registeredTypeIdentifiers.contains { $0.contains("live-photo") }
        if isLivePhoto, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return .image }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { return .movie }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return .image }
        return nil
    }

    /// 受け取り箱のフォルダ名 "<yyyyMMdd-HHmmss>-<UUID>"(時刻は UTC。名前の順 = 届いた順)
    static func makeBatchName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + UUID().uuidString
    }

    /// 1 件を書き込み、書き込んだファイルの URL を返す
    @discardableResult
    static func save(_ provider: NSItemProvider, kind: Kind, number: Int, into folder: URL,
                     box: ShareProgressBox) async throws -> URL {
        switch kind {
        case .movie:
            return try await saveMovie(provider, number: number, into: folder, box: box)
        case .image:
            return try await saveImage(provider, number: number, into: folder, box: box)
        }
    }

    private static func saveMovie(_ provider: NSItemProvider, number: Int, into folder: URL,
                                  box: ShareProgressBox) async throws -> URL {
        let type = concreteType(of: provider, conformingTo: .movie)
        let identifier = type?.identifier ?? UTType.movie.identifier
        let target = Target(folder: folder, number: number, suggestedName: provider.suggestedName,
                            fallbackBaseName: "video", fallbackExtension: type?.preferredFilenameExtension ?? "mov")
        do {
            return try await copyFileRepresentation(of: provider, typeIdentifier: identifier, to: target, box: box)
        } catch {
            // ファイルの場所(URL)だけを渡すアプリ向け。動画はメモリに読み込まない(Data では受け取らない)
            guard !box.isCancelled,
                  provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { throw error }
        }
        return try await copyLoadedItem(of: provider, typeIdentifier: UTType.fileURL.identifier, to: target,
                                        allowsInMemoryData: false, box: box)
    }

    private static func saveImage(_ provider: NSItemProvider, number: Int, into folder: URL,
                                  box: ShareProgressBox) async throws -> URL {
        let type = concreteType(of: provider, conformingTo: .image)
        let identifier = type?.identifier ?? UTType.image.identifier
        let target = Target(folder: folder, number: number, suggestedName: provider.suggestedName,
                            fallbackBaseName: "photo", fallbackExtension: type?.preferredFilenameExtension ?? "jpg")
        do {
            return try await copyFileRepresentation(of: provider, typeIdentifier: identifier, to: target, box: box)
        } catch {
            if box.isCancelled { throw error }
        }
        do {
            // ファイルとして渡せないときは Data で受け取る(写真 1 枚ならメモリに読み込んでも大きくない)
            return try await writeDataRepresentation(of: provider, typeIdentifier: identifier, to: target, box: box)
        } catch {
            if box.isCancelled { throw error }
        }
        // 古い形の受け渡し(URL・Data・UIImage のどれか)
        return try await copyLoadedItem(of: provider, typeIdentifier: identifier, to: target,
                                        allowsInMemoryData: true, box: box)
    }

    /// provider に登録されている型のうち、base に当てはまる具体的な型(拡張子があり、パッケージではないもの)
    private static func concreteType(of provider: NSItemProvider, conformingTo base: UTType) -> UTType? {
        for identifier in provider.registeredTypeIdentifiers {
            // Live Photos の入れ物(写真と動画のセット)はファイル 1 つにならないので使わない
            if identifier.contains("live-photo") { continue }
            guard let type = UTType(identifier), type.conforms(to: base) else { continue }
            if type.conforms(to: .package) || type.conforms(to: .directory) { continue }
            if type.preferredFilenameExtension == nil { continue }
            return type
        }
        return nil
    }

    // MARK: 読み込み方ごと

    /// ファイルとして受け取ってコピーする(動画もメモリに読み込まない)
    private static func copyFileRepresentation(of provider: NSItemProvider, typeIdentifier: String,
                                               to target: Target, box: ShareProgressBox) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let loading = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { @Sendable url, error in
                // url の一時ファイルはこのハンドラから戻ると消されるので、ここでコピーする
                do {
                    guard let url else { throw error ?? ShareSendError.unreadable }
                    let destination = try Self.copyFile(at: url, to: target, box: box)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.track(loading)
        }
    }

    /// Data として受け取って書き込む(写真だけ)
    private static func writeDataRepresentation(of provider: NSItemProvider, typeIdentifier: String,
                                                to target: Target, box: ShareProgressBox) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let loading = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { @Sendable data, error in
                do {
                    guard let data else { throw error ?? ShareSendError.unreadable }
                    let fileExtension = Self.imageExtension(of: data, fallback: target.fallbackExtension)
                    let destination = try Self.writeData(data, to: target, fileExtension: fileExtension, box: box)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.track(loading)
        }
    }

    /// 古い形の受け渡し(loadItem)。ファイルの URL ならコピー、allowsInMemoryData のときは Data・UIImage も書き込む
    private static func copyLoadedItem(of provider: NSItemProvider, typeIdentifier: String, to target: Target,
                                       allowsInMemoryData: Bool, box: ShareProgressBox) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { @Sendable item, error in
                do {
                    let destination = try Self.saveLoadedItem(item, error: error, to: target,
                                                              allowsInMemoryData: allowsInMemoryData, box: box)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func saveLoadedItem(_ item: Any?, error: Error?, to target: Target,
                                       allowsInMemoryData: Bool, box: ShareProgressBox) throws -> URL {
        if let url = item as? URL {
            guard url.isFileURL else { throw error ?? ShareSendError.unreadable }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            return try copyFile(at: url, to: target, box: box)
        }
        if allowsInMemoryData, let data = item as? Data {
            let fileExtension = imageExtension(of: data, fallback: target.fallbackExtension)
            return try writeData(data, to: target, fileExtension: fileExtension, box: box)
        }
        if allowsInMemoryData, let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
            return try writeData(data, to: target, fileExtension: "jpg", box: box)
        }
        throw error ?? ShareSendError.unreadable
    }

    // MARK: 書き込み

    /// ファイルを受け取り箱にコピーする(中身はメモリに読み込まない)
    private static func copyFile(at source: URL, to target: Target, box: ShareProgressBox) throws -> URL {
        if box.isCancelled { throw CocoaError(.userCancelled) }
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
        // フォルダ(パッケージ)は送らない
        if values?.isDirectory == true { throw ShareSendError.unreadable }
        // 一時ファイルの拡張子が動画・写真のものならそのまま、違えば型から決めた拡張子にする
        let sourceExtension = source.pathExtension
        var fileExtension = target.fallbackExtension
        if !sourceExtension.isEmpty, let type = UTType(filenameExtension: sourceExtension),
           type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
            fileExtension = sourceExtension
        }
        let destination = target.destination(sourceURL: source, fileExtension: fileExtension)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        try ensureNotEmpty(destination)
        return destination
    }

    /// Data を受け取り箱に書き込む
    private static func writeData(_ data: Data, to target: Target, fileExtension: String,
                                  box: ShareProgressBox) throws -> URL {
        if box.isCancelled { throw CocoaError(.userCancelled) }
        guard !data.isEmpty else { throw ShareSendError.empty }
        let destination = target.destination(sourceURL: nil, fileExtension: fileExtension)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try data.write(to: destination)
        try ensureNotEmpty(destination)
        return destination
    }

    /// 大きさ 0 のファイルは送らない(アプリは大きさ 0 のファイルを書き込み中として無視する)
    private static func ensureNotEmpty(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            try? FileManager.default.removeItem(at: url)
            throw ShareSendError.empty
        }
    }

    /// 画像の Data の中身から拡張子を決める(heic / jpeg / png など)
    private static func imageExtension(of data: Data, fallback: String) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source),
              let fileExtension = UTType(typeIdentifier as String)?.preferredFilenameExtension else { return fallback }
        return fileExtension
    }

    // MARK: 名前

    /// "<NNN>-<元の名前>.<拡張子>"。名前は共有元が付けた名前(suggestedName)、なければ一時ファイルの名前
    static func fileName(number: Int, suggestedName: String?, sourceURL: URL?,
                         fallbackBaseName: String, fileExtension: String) -> String {
        var base = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty, let sourceURL {
            base = sourceURL.deletingPathExtension().lastPathComponent
        }
        // 名前に付いている動画・写真の拡張子は外して、中身の拡張子を付け直す(IMG_0001.HEIC.jpeg にしない)
        let nameExtension = (base as NSString).pathExtension
        if !nameExtension.isEmpty, let type = UTType(filenameExtension: nameExtension),
           type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
            base = (base as NSString).deletingPathExtension
        }
        base = sanitized(base)
        if base.count > 80 { base = String(base.prefix(80)) }
        // ファイル名は 255 バイトまで。番号と拡張子の分を残して短くする(日本語・絵文字は 1 文字が数バイト)
        while base.utf8.count > 200 {
            base.removeLast()
        }
        if base.isEmpty { base = fallbackBaseName }
        let cleanExtension = sanitized(fileExtension)
        let name = paddedNumber(number) + "-" + base
        return cleanExtension.isEmpty ? name : name + "." + cleanExtension
    }

    /// ファイル名に使えない文字を "_" にし、先頭の "."(隠しファイルになる)を外す
    private static func sanitized(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "/" || character == ":" || character == "\\" || character.isNewline {
                result.append("_")
            } else {
                result.append(character)
            }
        }
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 3 桁にそろえた番号(001, 002, …)
    private static func paddedNumber(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }
}

/// 読み込み中の Progress(キャンセルのときに止める)。完了ハンドラは別のスレッドで呼ばれるのでロックで守る
final class ShareProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Progress?
    private var cancelled = false

    /// 新しく始めた読み込みを覚える(キャンセル済みならすぐ止める)
    func track(_ progress: Progress) {
        lock.lock()
        current = progress
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let progress = current
        current = nil
        lock.unlock()
        progress?.cancel()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum ShareSendError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "このファイルは読み込めませんでした。")
        case .empty:
            return String(localized: "ファイルの中身が空でした。")
        }
    }
}

// MARK: - 見た目

/// アプリの BrandStyle(Sources/Views/BrandStyle.swift)と同じ色。拡張機能のターゲットには BrandStyle が入らないので写しを持つ
enum ShareBrand {
    static let green = Color(red: 0.13, green: 0.58, blue: 0.40)
    static let blue = Color(red: 0.12, green: 0.42, blue: 0.78)
    static let orange = Color(red: 0.86, green: 0.47, blue: 0.13)
    /// 紺(アイコンの背景)
    static let navy = Color(red: 0.063, green: 0.102, blue: 0.2)

    static var gradient: LinearGradient {
        LinearGradient(colors: [green, blue], startPoint: .leading, endPoint: .trailing)
    }
}

/// 触覚フィードバック(アプリの EditorHaptics と同じもの)
@MainActor
enum ShareHaptics {
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
}

/// 共有シートの中に出す画面
struct ShareStatusView: View {
    let model: ShareModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            status
                .frame(maxWidth: .infinity)
            Spacer(minLength: 24)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShareBrand.navy, ignoresSafeAreaEdges: .all)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ShareBrand.gradient)
            Text(verbatim: "Video Mania")
                .font(.headline)
                .foregroundStyle(Color.white)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .preparing:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("準備しています…")
                    .font(.headline)
                    .foregroundStyle(Color.white)
            }
        case .sending(let current, let total):
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Video Mania に送っています… \(current)/\(total)")
                    .monospacedDigit()
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                ProgressView(value: Double(max(current - 1, 0)), total: Double(max(total, 1)))
                    .tint(ShareBrand.blue)
                    .frame(maxWidth: 260)
            }
        case .done(_, let failed):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(ShareBrand.green)
                Text("送りました")
                    .font(.title2.bold())
                    .foregroundStyle(Color.white)
                Text("Video Mania を開くと、新しいプロジェクトで編集するか、開いているプロジェクトに追加するかを選べます。")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if failed > 0 {
                    Text("\(failed) 件は送れませんでした。")
                        .font(.footnote)
                        .foregroundStyle(ShareBrand.orange)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let message, let detail):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(ShareBrand.orange)
                Text("送れませんでした")
                    .font(.title2.bold())
                    .foregroundStyle(Color.white)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .preparing, .sending:
            Button {
                model.cancel()
            } label: {
                Text("キャンセル")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        case .done:
            Button {
                model.finish()
            } label: {
                Text("OK")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ShareBrand.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        case .failed:
            Button {
                model.close()
            } label: {
                Text("閉じる")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }
}
