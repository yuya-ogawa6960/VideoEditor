import Foundation
import UniformTypeIdentifiers

// =====================================================================
// Google フォトの Picker API(公式。2025 年から Library API では利用者のライブラリを読めなくなった)。
//
// 1. sessions.create でセッションを作り、pickerUri を開く(Google フォトのアプリ、なければ Safari)
// 2. 利用者が選んで「完了」を押すと mediaItemsSet が true になる。sessions.get を pollInterval ごとに問い合わせて待つ
// 3. mediaItems.list で選ばれたものを受け取り、baseUrl からダウンロードする
//    (動画は "=dv"、写真は "=d"。Authorization: Bearer が要る。baseUrl は 60 分で使えなくなる)
// 4. 終わったら(やめたときも)sessions.delete
//
// ダウンロードはメモリに載せずファイルへ(URLSession のダウンロードタスク)。
// 置き場所は一時フォルダの GooglePhotos/<セッション>/<番号>-<元の名前>。取り込んだら呼び出し側が消す
// =====================================================================

/// 選択のセッション(sessions.create / sessions.get の応答)
struct GooglePickingSession: Sendable {
    let id: String
    /// 選ぶ画面の URL(Google フォトのアプリ、または Safari で開く)
    let pickerURL: URL?
    /// 次に問い合わせるまでの間隔(秒)
    let pollInterval: TimeInterval
    /// あと何秒で受付が終わるか(わからなければ nil)
    let timeout: TimeInterval?
    /// 利用者が選び終わったか
    let mediaItemsSet: Bool
}

/// 選ばれた写真・動画 1 つ(mediaItems.list の応答)
struct GooglePickedItem: Sendable, Identifiable {
    enum Kind: Sendable {
        case photo
        case video
    }

    let id: String
    let kind: Kind
    let baseURL: String
    let mimeType: String
    let filename: String
    /// 動画の処理の状況(READY / PROCESSING / FAILED。書かれていなければ nil)
    let processingStatus: String?

    /// まだ Google フォトで処理中の動画
    var isProcessing: Bool { kind == .video && processingStatus == "PROCESSING" }
    /// Google フォトで処理に失敗した動画
    var isFailed: Bool { kind == .video && processingStatus == "FAILED" }
    /// ダウンロードしてよいか(写真、または処理が終わった・状況が書かれていない動画)
    var isDownloadable: Bool { !isProcessing && !isFailed }
}

/// ダウンロードの進み具合
struct GooglePhotosDownloadProgress: Sendable {
    /// 今ダウンロードしているものの番号(0 から)
    let index: Int
    let total: Int
    /// 今のものの進み具合(0...1。大きさがわからなければ 0 のまま)
    let fraction: Double
    let filename: String

    var overall: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(index) + min(max(fraction, 0), 1)) / Double(total))
    }
}

/// ダウンロードの結果
struct GooglePhotosDownloadResult: Sendable {
    /// ダウンロードしたファイル(選んだ順)
    var files: [URL] = []
    /// Google フォトでまだ処理中で、取り込めなかった動画の数
    var processingCount = 0
    /// 処理に失敗していた・ダウンロードできなかったものの数
    var failedCount = 0
}

enum GooglePhotosError: LocalizedError {
    /// 403(権限がない・API が有効になっていない)
    case permissionDenied(String)
    /// 404(セッションの期限が切れた・消された)
    case sessionExpired
    /// まだ選び終わっていない(FAILED_PRECONDITION)
    case notFinished
    case tooManyRequests
    case serverBusy
    /// 選ぶのを待っている間に受付の時間が過ぎた
    case pickerTimedOut
    /// 何も選ばれていなかった
    case nothingPicked
    /// どれも取り込めなかった
    case nothingDownloadable(processing: Int, failed: Int)
    case storageFull
    case saveFailed
    /// 1 つのダウンロードが失敗した(HTTP の状態)
    case itemFailed(Int)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let detail):
            let base = String(localized: "Google フォトにアクセスできませんでした。ログアウトしてから、もう一度ログインしてお試しください。")
            return detail.isEmpty ? base : base + "\n(" + detail + ")"
        case .sessionExpired:
            return String(localized: "選ぶ時間が過ぎました。もう一度 Google フォトを開いて選んでください。")
        case .notFinished:
            return String(localized: "まだ選び終わっていないようです。Google フォトで選んで「完了」を押してください。")
        case .tooManyRequests:
            return String(localized: "Google フォトへの問い合わせが多すぎました。少し待ってからもう一度お試しください。")
        case .serverBusy:
            return String(localized: "Google フォトが混み合っています。少し待ってからもう一度お試しください。")
        case .pickerTimedOut:
            return String(localized: "選ぶ時間が過ぎました。もう一度 Google フォトを開いて選んでください。")
        case .nothingPicked:
            return String(localized: "写真・動画が選ばれていませんでした。")
        case .nothingDownloadable(let processing, let failed):
            if processing > 0 && failed == 0 {
                return String(localized: "選んだ動画は Google フォトでまだ処理中です。少し待ってからもう一度お試しください。")
            }
            return String(localized: "選んだ写真・動画をダウンロードできませんでした。もう一度お試しください。")
        case .storageFull:
            return String(localized: "iPhone の空き容量が足りません。空きを増やしてからもう一度お試しください。")
        case .saveFailed:
            return String(localized: "ダウンロードしたファイルを保存できませんでした。もう一度お試しください。")
        case .itemFailed(let status):
            return String(localized: "ダウンロードに失敗しました(\(status))。もう一度お試しください。")
        case .server(let detail):
            return String(localized: "Google フォトでエラーが起きました(\(detail))。時間をおいてもう一度お試しください。")
        case .invalidResponse:
            return String(localized: "Google フォトの応答を読めませんでした。もう一度お試しください。")
        }
    }

    /// Google の API のエラー応答({"error":{"code","message","status"}})から
    static func from(status: Int, json: [String: Any]) -> GooglePhotosError {
        let error = json["error"] as? [String: Any]
        let reason = error?["status"] as? String ?? ""
        let message = error?["message"] as? String ?? ""
        switch status {
        case 403:
            return .permissionDenied(message)
        case 404:
            return .sessionExpired
        case 400 where reason == "FAILED_PRECONDITION":
            return .notFinished
        case 429:
            return .tooManyRequests
        case 500...599:
            return .serverBusy
        default:
            return .server(message.isEmpty ? "HTTP " + String(status) : message)
        }
    }
}

enum GooglePhotosPicker {
    /// 一度に選べる数
    static let maxItemCount = 50
    private static let apiBase = "https://photospicker.googleapis.com/v1/"

    /// 進み具合を受け取る(メインスレッドで呼ばれる)
    typealias ProgressHandler = @MainActor @Sendable (GooglePhotosDownloadProgress) -> Void

    // MARK: - セッション

    /// 選択のセッションを作る(pickerUri を開くと選べる)
    @MainActor
    static func createSession() async throws -> GooglePickingSession {
        let body = try JSONSerialization.data(withJSONObject: [
            "pickingConfig": ["maxItemCount": String(maxItemCount)],
        ])
        let url = try endpoint("sessions")
        let json = try await authorizedJSON(method: "POST", url: url, body: body)
        return try parseSession(json)
    }

    /// セッションの今の状態(選び終わったか・次に問い合わせるまでの間隔)
    @MainActor
    static func getSession(_ id: String) async throws -> GooglePickingSession {
        let url = try endpoint("sessions/" + GoogleOAuth.percentEncode(id))
        let json = try await authorizedJSON(method: "GET", url: url)
        return try parseSession(json)
    }

    /// セッションを消す(終わったとき・やめたとき。失敗しても気にしない)
    @MainActor
    static func deleteSession(_ id: String) async {
        guard let url = try? endpoint("sessions/" + GoogleOAuth.percentEncode(id)) else { return }
        _ = try? await authorizedJSON(method: "DELETE", url: url)
    }

    /// 選ばれた写真・動画(すべてのページ)
    @MainActor
    static func listItems(sessionID: String) async throws -> [GooglePickedItem] {
        var items: [GooglePickedItem] = []
        var pageToken: String?
        repeat {
            var path = "mediaItems?sessionId=" + GoogleOAuth.percentEncode(sessionID) + "&pageSize=100"
            if let pageToken {
                path += "&pageToken=" + GoogleOAuth.percentEncode(pageToken)
            }
            let url = try endpoint(path)
            let json = try await authorizedJSON(method: "GET", url: url)
            let page = json["mediaItems"] as? [[String: Any]] ?? []
            for raw in page {
                if let item = parseItem(raw) {
                    items.append(item)
                }
            }
            let next = json["nextPageToken"] as? String ?? ""
            pageToken = next.isEmpty ? nil : next
            try Task.checkCancellation()
        } while pageToken != nil
        return items
    }

    // MARK: - ダウンロード

    /// 選ばれたものを一時フォルダにダウンロードする。処理中・処理に失敗した動画は飛ばして数える。
    /// 1 つのダウンロードの失敗は数えて先へ進むが、通信できない・ログインし直しが必要・空き容量がないときは全体を止める。
    /// Task がキャンセルされたらダウンロードを止め、ダウンロード済みのファイルも消して CancellationError を投げる。
    /// それ以外の失敗ではダウンロード済みのファイルを残す(同じセッションでやり直したとき、保存し終えたものは飛ばす)
    @MainActor
    static func download(_ items: [GooglePickedItem], sessionID: String, listedAt: Date,
                         onProgress: @escaping ProgressHandler) async throws -> GooglePhotosDownloadResult {
        let folder = sessionFolder(for: sessionID)
        removeStaleFolders(keeping: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw GooglePhotosError.saveFailed
        }
        // 前の試みで保存し終えたファイル(保存先には最後まで届いたものだけを移すので、あればそのまま使える)
        let finishedFiles = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                                          options: [.skipsHiddenFiles])) ?? []

        var result = GooglePhotosDownloadResult()
        result.processingCount = items.filter { $0.isProcessing }.count
        result.failedCount = items.filter { $0.isFailed }.count
        let targets = items.filter { $0.isDownloadable }
        let total = targets.count
        // ファイル名の番号は選ばれたもの全体での順番(処理中の動画が処理を終えても、やり直しで番号がずれないように)
        let positions = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        // baseUrl は 60 分で使えなくなるので、50 分を過ぎたら選ばれたものを取り直す
        var freshItems: [String: GooglePickedItem] = [:]
        var freshAt = listedAt

        do {
            for (index, original) in targets.enumerated() {
                try Task.checkCancellation()
                let displayName = original.filename
                let parts = fileParts(for: original, index: positions[original.id] ?? index)
                if let finished = finishedFile(in: finishedFiles, baseName: parts.base) {
                    // 前の試みで保存し終えている。ダウンロードし直さない
                    onProgress(GooglePhotosDownloadProgress(index: index, total: total, fraction: 1, filename: displayName))
                    result.files.append(finished)
                    continue
                }
                if Date().timeIntervalSince(freshAt) > 50 * 60 {
                    let fetched = try await listItems(sessionID: sessionID)
                    freshItems = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    freshAt = Date()
                }
                var item = freshItems[original.id] ?? original
                onProgress(GooglePhotosDownloadProgress(index: index, total: total, fraction: 0, filename: displayName))
                var attempt = 0
                while true {
                    do {
                        let file = try await downloadItem(item, folder: folder, baseName: parts.base, fallbackExtension: parts.ext) { fraction in
                            onProgress(GooglePhotosDownloadProgress(index: index, total: total, fraction: fraction, filename: displayName))
                        }
                        result.files.append(file)
                        break
                    } catch GooglePhotosError.itemFailed(let status) where attempt == 0 && (status == 403 || status == 404 || status == 410) {
                        // baseUrl の期限が切れたかもしれない。選ばれたものを取り直して 1 回だけやり直す
                        attempt += 1
                        let fetched = try await listItems(sessionID: sessionID)
                        freshItems = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        freshAt = Date()
                        item = freshItems[original.id] ?? original
                    } catch {
                        if isFatal(error) { throw error }
                        // この 1 つだけ飛ばす
                        result.failedCount += 1
                        break
                    }
                }
            }
        } catch {
            // キャンセルのときだけ消す。ほかの失敗では、やり直したときに使えるよう保存し終えたファイルを残す
            if error is CancellationError || Task.isCancelled {
                try? FileManager.default.removeItem(at: folder)
            }
            throw error
        }
        onProgress(GooglePhotosDownloadProgress(index: total, total: total, fraction: 0, filename: ""))
        return result
    }

    /// 前の試みで保存し終えたファイル("001-IMG_1234.<拡張子>")。空のファイルは使わない
    private static func finishedFile(in files: [URL], baseName: String) -> URL? {
        files.first { file in
            let name = file.lastPathComponent
            guard name == baseName || (name as NSString).deletingPathExtension == baseName else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
    }

    /// 全体を止めるべき失敗か(キャンセル・ログイン・通信・空き容量)
    private static func isFatal(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if error is GoogleOAuthError { return true }
        switch error as? GooglePhotosError {
        case .storageFull?, .saveFailed?, .sessionExpired?, .tooManyRequests?:
            return true
        default:
            return false
        }
    }

    /// 1 つをダウンロードする。401 ならトークンを取り直して 1 回だけやり直し、それでもだめならログインし直してもらう
    @MainActor
    private static func downloadItem(_ item: GooglePickedItem, folder: URL, baseName: String, fallbackExtension: String,
                                     onFraction: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        // 動画は "=dv"(動画のファイル)、写真は "=d"(元の写真。位置情報は除かれる)
        let suffix = item.kind == .video ? "=dv" : "=d"
        guard let url = URL(string: item.baseURL + suffix) else { throw GooglePhotosError.invalidResponse }
        var retriedAuth = false
        while true {
            let token = try await GoogleOAuth.validAccessToken(forceRefresh: retriedAuth)
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            // データが 60 秒届かなければ時間切れ(全体の時間は区切らない)
            request.timeoutInterval = 60
            let outcome = try await GoogleFileDownload.run(request, folder: folder, baseName: baseName,
                                                           fallbackExtension: fallbackExtension, onFraction: onFraction)
            if outcome.status == 401 {
                if !retriedAuth {
                    retriedAuth = true
                    continue
                }
                GoogleOAuth.forgetTokens()
                throw GoogleOAuthError.signInRequired
            }
            guard (200..<300).contains(outcome.status), let file = outcome.file else {
                if outcome.status == 429 { throw GooglePhotosError.tooManyRequests }
                throw GooglePhotosError.itemFailed(outcome.status)
            }
            return file
        }
    }

    // MARK: - ファイル

    /// ダウンロードの置き場所(一時フォルダ/GooglePhotos)
    static var rootFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GooglePhotos", isDirectory: true)
    }

    /// セッションごとのフォルダ
    static func sessionFolder(for sessionID: String) -> URL {
        let safe = String(sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(80))
        return rootFolder.appendingPathComponent(safe.isEmpty ? "session" : safe, isDirectory: true)
    }

    /// 前の取り込みの残り(空のフォルダ・1 日より古いフォルダ)を消す
    static func removeStaleFolders(keeping: URL?) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: rootFolder,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let kept = keeping?.standardizedFileURL.lastPathComponent
        for folder in folders where folder.standardizedFileURL.lastPathComponent != kept {
            let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if contents.isEmpty || Date().timeIntervalSince(modified) > 24 * 3600 {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// ファイル名("001-IMG_1234" と拡張子)。拡張子がなければ MIME タイプから決める
    static func fileParts(for item: GooglePickedItem, index: Int) -> (base: String, ext: String) {
        let cleaned = item.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned as NSString
        var ext = name.pathExtension
        var stem = String(name.deletingPathExtension.prefix(80))
        if stem.isEmpty || stem.hasPrefix(".") {
            stem = item.kind == .video ? "video" : "photo"
        }
        if ext.isEmpty || ext.count > 8 {
            ext = UTType(mimeType: item.mimeType)?.preferredFilenameExtension ?? (item.kind == .video ? "mp4" : "jpg")
        }
        let number = String(index + 1)
        let padded = String(repeating: "0", count: max(0, 3 - number.count)) + number
        return (padded + "-" + stem, ext)
    }

    /// 届いたファイルの種類(Content-Type)が元の拡張子と違えば、届いた種類の拡張子にする
    /// (取り込む側は拡張子で動画か写真かを決めるため)
    static func resolvedExtension(fallback: String, mimeType: String?) -> String {
        guard let mimeType, let served = UTType(mimeType: mimeType),
              served.conforms(to: .image) || served.conforms(to: .audiovisualContent) else { return fallback }
        if let current = UTType(filenameExtension: fallback), current.conforms(to: served) {
            return fallback
        }
        return served.preferredFilenameExtension ?? fallback
    }

    // MARK: - 通信

    private static func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: apiBase + path) else { throw GooglePhotosError.invalidResponse }
        return url
    }

    /// アクセストークンを付けて送り、JSON を返す。401 ならトークンを取り直して 1 回だけやり直す
    @MainActor
    private static func authorizedJSON(method: String, url: URL, body: Data? = nil) async throws -> [String: Any] {
        var retriedAuth = false
        while true {
            let token = try await GoogleOAuth.validAccessToken(forceRefresh: retriedAuth)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: request)
            } catch {
                throw GoogleOAuth.mappedNetworkError(error)
            }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                if !retriedAuth {
                    retriedAuth = true
                    continue
                }
                GoogleOAuth.forgetTokens()
                throw GoogleOAuthError.signInRequired
            }
            let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
            guard (200..<300).contains(status) else {
                throw GooglePhotosError.from(status: status, json: json)
            }
            return json
        }
    }

    private static func parseSession(_ json: [String: Any]) throws -> GooglePickingSession {
        guard let id = json["id"] as? String, !id.isEmpty else { throw GooglePhotosError.invalidResponse }
        let pickerURL = (json["pickerUri"] as? String).flatMap { URL(string: $0) }
        let polling = json["pollingConfig"] as? [String: Any]
        let interval = parseDuration(polling?["pollInterval"]) ?? 5
        let timeout = parseDuration(polling?["timeoutIn"])
        let itemsSet = (json["mediaItemsSet"] as? Bool) ?? false
        return GooglePickingSession(id: id,
                                    pickerURL: pickerURL,
                                    pollInterval: min(max(interval, 1), 30),
                                    timeout: timeout,
                                    mediaItemsSet: itemsSet)
    }

    /// "3.5s" のような Duration の文字列を秒にする
    private static func parseDuration(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("s") { text.removeLast() }
        return Double(text)
    }

    private static func parseItem(_ raw: [String: Any]) -> GooglePickedItem? {
        guard let id = raw["id"] as? String,
              let file = raw["mediaFile"] as? [String: Any],
              let baseURL = file["baseUrl"] as? String, !baseURL.isEmpty else { return nil }
        let mimeType = file["mimeType"] as? String ?? ""
        let filename = file["filename"] as? String ?? ""
        let kind: GooglePickedItem.Kind
        switch raw["type"] as? String ?? "" {
        case "VIDEO":
            kind = .video
        case "PHOTO":
            kind = .photo
        default:
            // TYPE_UNSPECIFIED は MIME タイプで決める
            kind = mimeType.lowercased().hasPrefix("video/") ? .video : .photo
        }
        let metadata = file["mediaFileMetadata"] as? [String: Any]
        let video = metadata?["videoMetadata"] as? [String: Any]
        let status = video?["processingStatus"] as? String
        return GooglePickedItem(id: id, kind: kind, baseURL: baseURL, mimeType: mimeType,
                                filename: filename, processingStatus: status)
    }
}

// MARK: - ファイルへのダウンロード

/// ダウンロード 1 回の結果(成功ならファイルの場所)
struct GoogleFileDownloadOutcome: Sendable {
    let status: Int
    let file: URL?
}

/// URLSession のダウンロードタスクでファイルへ直接ダウンロードする(メモリに載せない)。
/// 進み具合を onFraction に渡し、呼び出し側の Task がキャンセルされたらタスクも止める
/// (途中のファイルは URLSession が消す。保存先には成功したときだけ移す)
enum GoogleFileDownload {
    static func run(_ request: URLRequest, folder: URL, baseName: String, fallbackExtension: String,
                    onFraction: @escaping @MainActor @Sendable (Double) -> Void) async throws -> GoogleFileDownloadOutcome {
        let box = GoogleDownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GoogleFileDownloadOutcome, Error>) in
                let task = URLSession.shared.downloadTask(with: request) { location, response, error in
                    box.finish()
                    if let error {
                        if (error as? URLError)?.code == .cannotWriteToFile {
                            continuation.resume(throwing: GooglePhotosError.storageFull)
                        } else {
                            continuation.resume(throwing: GoogleOAuth.mappedNetworkError(error))
                        }
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status), let location else {
                        continuation.resume(returning: GoogleFileDownloadOutcome(status: status, file: nil))
                        return
                    }
                    let ext = GooglePhotosPicker.resolvedExtension(fallback: fallbackExtension, mimeType: response?.mimeType)
                    let destination = folder.appendingPathComponent(ext.isEmpty ? baseName : baseName + "." + ext)
                    do {
                        let fm = FileManager.default
                        try? fm.removeItem(at: destination)
                        try fm.moveItem(at: location, to: destination)
                        continuation.resume(returning: GoogleFileDownloadOutcome(status: status, file: destination))
                    } catch {
                        let full = (error as? CocoaError)?.code == .fileWriteOutOfSpace
                        continuation.resume(throwing: full ? GooglePhotosError.storageFull : GooglePhotosError.saveFailed)
                    }
                }
                let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    let fraction = progress.fractionCompleted
                    // 受け取るたびに知らせると大きな動画でメインスレッドが埋まるので、1% ごとにする
                    guard box.shouldReport(fraction) else { return }
                    Task { @MainActor in
                        onFraction(fraction)
                    }
                }
                if box.attach(task, observation: observation) {
                    task.resume()
                } else {
                    // 始める前にキャンセルされていた
                    observation.invalidate()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// ダウンロードタスクとキャンセルの受け渡し(どちらが先に来ても 1 回だけ止める)
private final class GoogleDownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false
    /// 最後に知らせた進み具合
    private var lastReported: Double = -1

    /// 進み具合を知らせるか(1% 未満の変化は間引く。終わり(1)は必ず知らせる)
    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fraction < 1, abs(fraction - lastReported) < 0.01 { return false }
        lastReported = fraction
        return true
    }

    /// キャンセル済みなら false(タスクは始めない)
    func attach(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { return false }
        self.task = task
        self.observation = observation
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    func finish() {
        lock.lock()
        let watching = observation
        observation = nil
        task = nil
        lock.unlock()
        watching?.invalidate()
    }
}
