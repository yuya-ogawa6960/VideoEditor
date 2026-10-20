import Foundation
import UIKit

// =====================================================================
// クラウド文字起こしの背景 URLSession(ロック中・アプリが止められた後も送信を続ける)
//
// - セッション: URLSessionConfiguration.background(withIdentifier: "<実行時のバンドル ID>.cloud-upload")。
//   sessionSendsLaunchEvents = true なので、転送が終わるとアプリが(終了していても)バックグラウンドで起こされ、
//   AppDelegate の handleEventsForBackgroundURLSession から同じ識別子のセッションを作り直して結果を受け取る。
// - 1 回の文字起こし = 1 ジョブ(複数クリップ・複数ピース)。Application Support/CloudJobs/<jobID>/ に
//   job.json(CloudJobManifest。API キーは保存しない)・audio-*.m4a(切り出した音声)・
//   body-<i>.bin(multipart の送信内容。背景セッションはファイルからしか送れない)・result-<i>.json(応答)を置く。
// - タスクの taskDescription は "<jobID>|<ピース番号>"。応答は didReceive data でタスクごとに溜め、完了時に判定する:
//   2xx → 結果を保存 / 429・5xx・一時的な通信エラー(POSIX 53/54/57 など)→ 同じ送信内容で新しいタスクを作って送り直す
//   (1 ピース 6 回まで。間隔は earliestBeginDate)/ 401・403 などは失敗 / 精度優先モデルの非対応 4xx → whisper-1 で作り直す。
//   送り直しは元のタスクの originalRequest(Authorization ヘッダ付き)を使うので、キーを読み直さなくてよい。
// - デリゲートはこのクラス専用の直列キューで呼ばれる。共有状態は lock で守り、待っている処理(continuation)は
//   lock の外で、ちょうど 1 回だけ再開する。
// - バックグラウンド中に作ったタスクは iOS が「任意のタイミング」扱いにすることがあるので、
//   アプリが前面に戻ったとき・前面で待ち始めたときにまだ送り始めていなければ作り直す
//   (前回のプロセスから引き継いだ、まだ送り始めていないタスクも同じ扱い。作っただけで resume されていないものは再開する)。
// - 継続処理でプロセスが動いている間(enqueue の inProcessRetriesWhile が true)にバックグラウンドで必要になった
//   送り直し・フォールバックは、背景セッションではなくこのプロセスから直接送る(結果の扱いは同じ)。
// - 精度優先モデルが使えないと分かったら(前面にいるとき)、まだ送り始めていないピースもまとめてフォールバックへ切り替える。
// - 利用者の強制終了でシステムが取り消したタスクは送り直さない(タスクの無いピースとして残し、「取り込む」で送り直す)。
// - 前回のプロセスが終了して取り込まれなかったジョブは pendingJobs() で返す(字幕画面のバナー)。
//   失敗・キャンセル・7 日より古いジョブは起動時に消す。API キーが無くて送り直せないときはジョブを失敗にしない
//   (保存済みの結果を残し、キーを設定し直してから取り込めるようにする)。
// =====================================================================

/// 背景セッションで送るクラウド文字起こし 1 回分の記録(複数クリップ・複数ピース)。
/// あとから(アプリの再起動後でも)トークン → 字幕を作り直せるだけの情報を持つ。API キーは持たない
struct CloudJobManifest: Codable, Identifiable, Equatable {
    enum JobStatus: String, Codable {
        case running
        case completed
        case failed
        case cancelled
    }

    enum PieceStatus: String, Codable {
        /// 送信内容を用意しただけ(まだタスクが無い)
        case pending
        /// タスクで送信中(再送信待ちを含む)
        case uploading
        /// 応答(2xx)を result-<i>.json に保存済み
        case done
        case failed
    }

    /// 1 クリップ分の対応づけ(元素材上の秒 → 出力タイムライン上の秒の計算に使う)
    struct ClipInfo: Codable, Equatable {
        var clipID: UUID
        /// この実行の中での順番(0 から)
        var order: Int
        var name: String
        /// トリミング範囲(元素材上の秒)= clip.startTime / clip.endTime
        var sourceStart: Double
        var sourceEnd: Double
        var speed: Double
        /// 出力タイムライン上の開始・終了(秒)。終了は字幕の hardEnd
        var timelineStart: Double
        var timelineEnd: Double
    }

    struct Piece: Codable, Equatable {
        /// 0 から。pieces の並び順と同じ
        let index: Int
        var clipID: UUID
        /// ClipInfo.order
        var clipOrder: Int
        /// 元素材上の範囲(秒)。トークンはこの範囲に収める
        var sourceStart: Double
        var sourceEnd: Double
        /// 切り出したファイルの先頭に対応する元素材上の秒と、ファイルの長さ(秒)
        var extractStartOffset: Double
        var extractDuration: Double
        /// 切り出した音声(ジョブのフォルダ内のファイル名)
        var audioFileName: String
        /// このピースを送っているモデル(フォールバックすると変わる)
        var model: String
        /// body-<i>.bin の Content-Type(boundary 付き)
        var bodyContentType: String?
        var status: PieceStatus
        /// 送信を始めた回数
        var attempts: Int
        var lastHTTPStatus: Int?
        var lastError: String?

        init(index: Int, clipID: UUID, clipOrder: Int, sourceStart: Double, sourceEnd: Double,
             extractStartOffset: Double, extractDuration: Double, audioFileName: String, model: String) {
            self.index = index
            self.clipID = clipID
            self.clipOrder = clipOrder
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.extractStartOffset = extractStartOffset
            self.extractDuration = extractDuration
            self.audioFileName = audioFileName
            self.model = model
            self.bodyContentType = nil
            self.status = .pending
            self.attempts = 0
            self.lastHTTPStatus = nil
            self.lastError = nil
        }
    }

    /// 失敗の内容(CloudTranscriptionError に戻せる形)
    struct Failure: Codable, Equatable {
        var code: String
        var status: Int?
        var message: String
    }

    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    /// プロジェクト ID(分かるときだけ。字幕画面ではクリップ ID で突き合わせる)
    var projectID: UUID?
    /// API に渡す言語コード("ja" / "en")
    var language: String
    /// TranscriptionLanguage.rawValue("ja-JP" など。字幕の区切り方に使う)
    var localeIdentifier: String?
    /// CloudTranscriptionQuality.rawValue
    var quality: String
    /// 最初に使ったモデル
    var model: String
    var fallbackModel: String
    /// どこかのピースでフォールバックしたら true(以降に送り直すピースもフォールバックモデルを使う)
    var usesFallback: Bool
    var clips: [ClipInfo]
    var pieces: [Piece]
    var status: JobStatus
    var failure: Failure?

    init(id: UUID, createdAt: Date = Date(), projectID: UUID?, language: String, localeIdentifier: String?,
         quality: String, model: String, fallbackModel: String, clips: [ClipInfo], pieces: [Piece]) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.projectID = projectID
        self.language = language
        self.localeIdentifier = localeIdentifier
        self.quality = quality
        self.model = model
        self.fallbackModel = fallbackModel
        self.usesFallback = false
        self.clips = clips
        self.pieces = pieces
        self.status = .running
        self.failure = nil
    }

    var totalPieceCount: Int { pieces.count }

    var completedPieceCount: Int {
        pieces.reduce(0) { $0 + ($1.status == .done ? 1 : 0) }
    }

    /// すべてのピースの応答がそろったか
    var isComplete: Bool {
        !pieces.isEmpty && pieces.allSatisfy { $0.status == .done }
    }

    var clipIDs: Set<UUID> { Set(clips.map { $0.clipID }) }

    /// このジョブのクリップのどれかが clipIDs に含まれるか(今のプロジェクトのジョブかの判定)
    func matches(clipIDs ids: Set<UUID>) -> Bool {
        clips.contains { ids.contains($0.clipID) }
    }
}

extension CloudJobManifest.Failure {
    static func from(_ error: CloudTranscriptionError) -> CloudJobManifest.Failure {
        switch error {
        case .missingAPIKey:
            return CloudJobManifest.Failure(code: "missingAPIKey", status: nil, message: "")
        case .invalidAPIKey:
            return CloudJobManifest.Failure(code: "invalidAPIKey", status: nil, message: "")
        case .rateLimited(let detail):
            return CloudJobManifest.Failure(code: "rateLimited", status: 429, message: detail)
        case .offline:
            return CloudJobManifest.Failure(code: "offline", status: nil, message: "")
        case .timedOut:
            return CloudJobManifest.Failure(code: "timedOut", status: nil, message: "")
        case .network(let detail):
            return CloudJobManifest.Failure(code: "network", status: nil, message: detail)
        case .fileTooLarge:
            return CloudJobManifest.Failure(code: "fileTooLarge", status: 413, message: "")
        case .server(let status, let message):
            return CloudJobManifest.Failure(code: "server", status: status, message: message)
        case .badResponse:
            return CloudJobManifest.Failure(code: "badResponse", status: nil, message: "")
        case .noAudio:
            return CloudJobManifest.Failure(code: "noAudio", status: nil, message: "")
        }
    }

    /// 利用者に見せるエラー(CloudTranscriptionError)に戻す
    var error: Error {
        switch code {
        case "missingAPIKey": return CloudTranscriptionError.missingAPIKey
        case "invalidAPIKey": return CloudTranscriptionError.invalidAPIKey
        case "rateLimited": return CloudTranscriptionError.rateLimited(message)
        case "offline": return CloudTranscriptionError.offline
        case "timedOut": return CloudTranscriptionError.timedOut
        case "fileTooLarge": return CloudTranscriptionError.fileTooLarge
        case "server": return CloudTranscriptionError.server(status: status ?? 0, message: message)
        case "badResponse": return CloudTranscriptionError.badResponse
        case "noAudio": return CloudTranscriptionError.noAudio
        default: return CloudTranscriptionError.network(message.isEmpty ? "不明なエラー" : message)
        }
    }
}

enum CloudBackgroundUploaderError: LocalizedError {
    /// 背景セッションが使えない(呼び出し側はこのプロセスから直接送る従来の経路へ)
    case unavailable(String)
    /// ジョブが見つからない(破棄済みなど)
    case jobNotFound

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "バックグラウンド送信を使えません: \(reason)"
        case .jobNotFound:
            return "前回の文字起こしのデータが見つかりません。"
        }
    }
}

/// タスクとピースの対応("<jobID>|<ピース番号>")
private struct PieceKey: Hashable {
    let jobID: UUID
    let index: Int

    init(jobID: UUID, index: Int) {
        self.jobID = jobID
        self.index = index
    }

    init?(taskDescription: String?) {
        guard let text = taskDescription else { return nil }
        let parts = text.split(separator: "|")
        guard parts.count == 2,
              let id = UUID(uuidString: String(parts[0])),
              let index = Int(String(parts[1])) else { return nil }
        self.init(jobID: id, index: index)
    }

    var taskDescription: String { "\(jobID.uuidString)|\(index)" }
}

/// waitForCompletion で待っている 1 件
private struct CloudJobWaiter {
    let id: UUID
    let progress: (Int, Int) -> Void
    let continuation: CheckedContinuation<[Int: Data], Error>
}

/// このプロセスから直接送っている 1 ピース分(継続処理中のバックグラウンドでの送り直し)
private struct InProcessUpload {
    /// 完了時に「今のものか」を確かめる印
    let token: UUID
    let task: Task<Void, Never>
}

/// lock を外してから行う後始末(タスクの取り消し・開始、進捗の通知、continuation の再開)
private struct CloudUploadDelivery {
    var tasksToCancel: [URLSessionTask] = []
    var inProcessToCancel: [Task<Void, Never>] = []
    var tasksToResume: [URLSessionTask] = []
    var progress: [(callback: (Int, Int) -> Void, done: Int, total: Int)] = []
    var completions: [(continuation: CheckedContinuation<[Int: Data], Error>, result: Result<[Int: Data], Error>)] = []

    func run() {
        for task in tasksToCancel { task.cancel() }
        for task in inProcessToCancel { task.cancel() }
        for task in tasksToResume { task.resume() }
        for item in progress { item.callback(item.done, item.total) }
        for item in completions { item.continuation.resume(with: item.result) }
    }
}

final class CloudBackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = CloudBackgroundUploader()

    /// 1 ピースあたりの送信回数の上限(最初の 1 回を含む)
    static let maxAttempts = 6
    /// これより古いジョブは起動時に消す
    static let jobRetention: TimeInterval = 7 * 24 * 60 * 60
    /// 待ち始めたときにタスクの無いピース(前のプロセスが送り直しの途中で終了したなど)を送り直すまでの猶予(秒)。
    /// 再起動直後は、終わっていたタスクの完了通知が少し遅れて届くことがあるため
    private static let orphanGraceSeconds: Double = 3
    /// 完了ハンドラが預けられる前に urlSessionDidFinishEvents が来たとき、後から来たハンドラをすぐ呼ぶ期限(秒)
    private static let finishEventsWindow: TimeInterval = 30
    /// NSURLErrorCancelledReasonUserForceQuitApplication(利用者がアプリを強制終了したため取り消された)
    private static let forceQuitCancelReason = 0

    /// 背景セッションの識別子("<実行時のバンドル ID>.cloud-upload")
    let sessionIdentifier: String

    private let delegateQueue: OperationQueue
    private var session: URLSession?
    /// 継続処理中にバックグラウンドで必要になった送り直しを、このプロセスから直接送るためのセッション
    private let inProcessSession: URLSession
    private let rootDirectory: URL?

    // 以下は lock で保護する(ロックの順序: CloudBackgroundUploader → AppLifecycle / BackgroundPauseReporter)
    private let lock = NSLock()
    private var jobs: [UUID: CloudJobManifest] = [:]
    /// タスク ID → 受け取り中の応答
    private var buffers: [Int: Data] = [:]
    /// タスク ID → ピース(このプロセスで把握している、動いているタスク)
    private var taskKeys: [Int: PieceKey] = [:]
    /// ピース → 今そのピースを送っているタスク
    private var pieceTasks: [PieceKey: URLSessionTask] = [:]
    /// ピース → このプロセスから直接送っている送り直し(pieceTasks と同じピースに同時には持たない)
    private var inProcessUploads: [PieceKey: InProcessUpload] = [:]
    /// ジョブ → true を返す間は、バックグラウンドで必要になった送り直しをこのプロセスから直接送る(enqueue で受け取る)
    private var inProcessRetryGates: [UUID: () -> Bool] = [:]
    /// バックグラウンド中に作ったタスク(前面に戻ったとき、まだ送り始めていなければ作り直す)
    private var backgroundCreatedTaskIDs: Set<Int> = []
    /// 作り直しなどで置き換えたタスク(完了通知は無視する)
    private var supersededTaskIDs: Set<Int> = []
    private var waiters: [UUID: [CloudJobWaiter]] = [:]
    /// 登録より先に取り消された waiter(waitForCompletion の開始直後にキャンセルされた場合)
    private var cancelledWaiterIDs: Set<UUID> = []
    /// このプロセスで送り始めたジョブ(呼び出し側が結果を受け取るので pendingJobs には出さない)
    private var ownedJobIDs: Set<UUID> = []
    /// 起動時に getAllTasks で前回のタスクを確認し終えたか
    private var reconciled = false
    private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
    private var storedCompletionHandler: (() -> Void)?
    private var eventsFinishedAt: Date?
    private var lastEvent: String = "まだありません"
    private var activationObserver: NSObjectProtocol?

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm:ss"
        return formatter
    }()

    private override init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.personal.videoeditor"
        sessionIdentifier = bundleID + ".cloud-upload"
        let queue = OperationQueue()
        queue.name = "CloudBackgroundUploader.delegate"
        queue.maxConcurrentOperationCount = 1
        delegateQueue = queue
        rootDirectory = CloudBackgroundUploader.makeRootDirectory()
        let direct = URLSessionConfiguration.default
        direct.timeoutIntervalForRequest = CloudTranscriber.accurateRequestTimeout
        direct.timeoutIntervalForResource = 600
        direct.waitsForConnectivity = false
        inProcessSession = URLSession(configuration: direct)
        super.init()

        loadJobs()

        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = CloudTranscriber.accurateRequestTimeout
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        let backgroundSession = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session = backgroundSession

        // 前回のプロセスが作ったタスク(まだ動いているもの)を把握する
        backgroundSession.getAllTasks { [weak self] tasks in
            self?.reconcile(with: tasks)
        }
        // 念のため: getAllTasks が返ってこなくても待ち続けない
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.reconcileTimedOut()
        }

        // 前面に戻ったら、バックグラウンド中に作ってまだ送り始めていないタスクを作り直す
        Task { @MainActor [weak self] in
            self?.installActivationObserver()
        }
    }

    @MainActor
    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.restartDeferredTasks()
        }
    }

    // MARK: - 公開 API

    /// 起動時に呼ぶ(セッションを作り直し、前回送ったピースの結果を受け取れるようにする)。何度呼んでもよい
    func activate() {
        _ = sessionIdentifier
    }

    /// 背景セッションでジョブを送れるか(保存先のフォルダを作れたか)
    var isAvailable: Bool {
        rootDirectory != nil && session != nil
    }

    /// AppDelegate が預ける完了ハンドラ。urlSessionDidFinishEvents のあとメインスレッドで呼ぶ
    var backgroundCompletionHandler: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCompletionHandler
        }
        set {
            lock.lock()
            storedCompletionHandler = newValue
            lock.unlock()
        }
    }

    /// AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:) から呼ぶ
    func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == sessionIdentifier else {
            // 以前のバンドル ID のセッションなど(作り直せない)→ すぐに完了を伝える
            DispatchQueue.main.async { completionHandler() }
            return
        }
        lock.lock()
        var finishedEarlier = false
        if let finishedAt = eventsFinishedAt, Date().timeIntervalSince(finishedAt) < Self.finishEventsWindow {
            finishedEarlier = true
        }
        eventsFinishedAt = nil
        if !finishedEarlier {
            storedCompletionHandler = completionHandler
        }
        noteLocked("送信の完了でアプリが起こされました")
        lock.unlock()
        if finishedEarlier {
            DispatchQueue.main.async { completionHandler() }
        }
    }

    /// ジョブの作業フォルダを作って返す(切り出した音声などを置く)。保存先が無ければ投げる
    func makeJobDirectory(for jobID: UUID) throws -> URL {
        guard let directory = jobDirectoryURL(for: jobID) else {
            throw CloudBackgroundUploaderError.unavailable("保存先(Application Support)を使えません")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// ジョブの記録を書き、すべてのピースの送信を始める。
    /// 音声(audioFileName)はあらかじめ makeJobDirectory のフォルダに置いておくこと。
    /// 背景セッションを使えないときは CloudBackgroundUploaderError.unavailable を投げる(ジョブは登録しない)。
    /// - inProcessRetriesWhile: true を返す間(継続処理でプロセスが動いている間)、バックグラウンドで必要になった
    ///   送り直し・フォールバックを背景セッションではなくこのプロセスから直接送る
    ///   (バックグラウンドで作った背景セッションのタスクは iOS が後回しにするため)。lock の中から呼ぶので軽くすること
    func enqueue(job: CloudJobManifest, apiKey: String, inProcessRetriesWhile gate: (() -> Bool)? = nil) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }
        guard !job.pieces.isEmpty else { throw CloudTranscriptionError.noAudio }
        guard let session, let directory = jobDirectoryURL(for: job.id) else {
            throw CloudBackgroundUploaderError.unavailable("背景セッションを作れません")
        }
        for (position, piece) in job.pieces.enumerated() where piece.index != position {
            throw CloudBackgroundUploaderError.unavailable("ピースの番号が不正です")
        }

        var manifest = job
        manifest.status = .running
        manifest.failure = nil
        manifest.updatedAt = Date()
        var requests: [(index: Int, request: URLRequest, bodyURL: URL)] = []
        do {
            // 送信内容(multipart)をファイルに書く(背景セッションはファイルからしか送れない)
            for i in manifest.pieces.indices {
                let piece = manifest.pieces[i]
                let contentType = try writeBody(for: piece, model: piece.model, language: manifest.language,
                                                directory: directory)
                manifest.pieces[i].bodyContentType = contentType
                manifest.pieces[i].status = .uploading
                manifest.pieces[i].attempts = 1
                let request = CloudTranscriber.makeUploadRequest(apiKey: key, contentType: contentType, model: piece.model)
                requests.append((index: i, request: request,
                                 bodyURL: directory.appendingPathComponent(Self.bodyFileName(i))))
            }
            try writeManifest(manifest)
        } catch {
            throw CloudBackgroundUploaderError.unavailable("送信の準備に失敗しました(\(error.localizedDescription))")
        }

        let inBackground = AppLifecycle.shared.isInBackground
        var tasks: [URLSessionTask] = []
        lock.lock()
        jobs[manifest.id] = manifest
        ownedJobIDs.insert(manifest.id)
        if let gate {
            inProcessRetryGates[manifest.id] = gate
        }
        for item in requests {
            let task = session.uploadTask(with: item.request, fromFile: item.bodyURL)
            let pieceKey = PieceKey(jobID: manifest.id, index: item.index)
            task.taskDescription = pieceKey.taskDescription
            registerTaskLocked(task, key: pieceKey, createdInBackground: inBackground)
            tasks.append(task)
        }
        noteLocked("送信開始(ピース \(requests.count) 本)")
        lock.unlock()
        for task in tasks {
            task.resume()
        }
    }

    /// すべてのピースの応答がそろうまで待ち、ピース番号 → 応答(JSON)を返す。
    /// - すでにそろっていればすぐに返す(再起動後に前回のジョブを取り込むときなど)。
    ///   タスクの無いピース(前のプロセスが途中で終了した)は少し待ってから送り直す(API キーは設定から読む)。
    /// - ジョブが失敗したら CloudTranscriptionError を投げる。
    /// - progress(完了ピース数, 全ピース数)は登録時と各ピースの完了時に呼ばれる(スレッドは決まっていない)。
    /// - Task がキャンセルされたら CancellationError。cancelsTasksOnCancellation が true ならジョブの送信もやめる
    func waitForCompletion(jobID: UUID, cancelsTasksOnCancellation: Bool = true,
                           progress: @escaping (Int, Int) -> Void) async throws -> [Int: Data] {
        await waitUntilReconciled()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int: Data], Error>) in
                self.register(waiterID: waiterID, jobID: jobID, progress: progress, continuation: continuation)
            }
        } onCancel: {
            self.cancelWait(waiterID: waiterID, jobID: jobID, cancelTasks: cancelsTasksOnCancellation)
        }
    }

    /// 前回のプロセスで送ったまま取り込まれていないジョブ(送信中・完了)。新しい順。
    /// このプロセスで送り始めたジョブや、いま待っている処理のあるジョブは含めない
    func pendingJobs() -> [CloudJobManifest] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values
            .filter { isPendingLocked($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// ジョブの今の記録
    func job(withID jobID: UUID) -> CloudJobManifest? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[jobID]
    }

    /// 保存済みの応答(完了したピースだけ)。ジョブが無ければ nil
    func results(for jobID: UUID) -> [Int: Data]? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[jobID], let directory = jobDirectoryURL(for: jobID) else { return nil }
        var results: [Int: Data] = [:]
        for piece in job.pieces where piece.status == .done {
            let url = directory.appendingPathComponent(Self.resultFileName(piece.index))
            if let data = try? Data(contentsOf: url) {
                results[piece.index] = data
            }
        }
        return results
    }

    /// ジョブを捨てる(送信中のタスクを取り消し、フォルダを消す)。待っている処理には CancellationError。
    /// 登録していないジョブのフォルダ(このプロセスから直接送った場合)も消す
    func discard(jobID: UUID) {
        var delivery = CloudUploadDelivery()
        lock.lock()
        let existed = jobs.removeValue(forKey: jobID) != nil
        ownedJobIDs.remove(jobID)
        inProcessRetryGates.removeValue(forKey: jobID)
        for (key, task) in pieceTasks where key.jobID == jobID {
            pieceTasks.removeValue(forKey: key)
            taskKeys.removeValue(forKey: task.taskIdentifier)
            backgroundCreatedTaskIDs.remove(task.taskIdentifier)
            supersededTaskIDs.insert(task.taskIdentifier)
            delivery.tasksToCancel.append(task)
        }
        cancelInProcessUploadsLocked(jobID: jobID, delivery: &delivery)
        if let list = waiters.removeValue(forKey: jobID) {
            for waiter in list {
                delivery.completions.append((continuation: waiter.continuation, result: .failure(CancellationError())))
            }
        }
        if existed {
            noteLocked("ジョブを片付けました")
        }
        lock.unlock()
        delivery.run()
        if let directory = jobDirectoryURL(for: jobID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// このプロセスで送っているジョブ(または待っている処理のあるジョブ)が送信中か
    var hasActiveUploads: Bool {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.contains { job in
            job.status == .running && (ownedJobIDs.contains(job.id) || waiters[job.id] != nil)
        }
    }

    /// 診断表示用の要約(日本語・複数行)
    func diagnosticSummary() -> String {
        lock.lock()
        let runningCount = jobs.values.filter { $0.status == .running }.count
        let livePieces = pieceTasks.count + inProcessUploads.count
        let pendingCount = jobs.values.filter { isPendingLocked($0) }.count
        let event = lastEvent
        let checked = reconciled
        lock.unlock()

        var lines: [String] = []
        lines.append("セッション: \(sessionIdentifier)")
        if rootDirectory == nil {
            lines.append("状態: 使えません(保存先を作れません)")
        } else if checked {
            lines.append("状態: 使えます")
        } else {
            lines.append("状態: 使えます(前回の送信を確認中)")
        }
        lines.append("送信中のジョブ: \(runningCount) 件(送信中のピース \(livePieces) 本)")
        lines.append("未取り込みの結果: \(pendingCount) 件")
        lines.append("最後のイベント: \(event)")
        return lines.joined(separator: "\n")
    }

    // MARK: - URLSession デリゲート(delegateQueue で直列に呼ばれる)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handleCompletion(of: task, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // AppDelegate がハンドラを預けるのはメインスレッドなので、メインスレッドで読む
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.storedCompletionHandler
            self.storedCompletionHandler = nil
            if handler == nil {
                self.eventsFinishedAt = Date()
            }
            self.lock.unlock()
            handler?()
        }
    }

    // MARK: - 完了の処理

    private func handleCompletion(of task: URLSessionTask, error: Error?) {
        let taskID = task.taskIdentifier
        var delivery = CloudUploadDelivery()
        lock.lock()
        let data = buffers.removeValue(forKey: taskID) ?? Data()
        backgroundCreatedTaskIDs.remove(taskID)
        let mappedKey = taskKeys.removeValue(forKey: taskID)
        if supersededTaskIDs.remove(taskID) != nil {
            // 作り直し・破棄で置き換えたタスク
            lock.unlock()
            return
        }
        guard let key = mappedKey ?? PieceKey(taskDescription: task.taskDescription) else {
            lock.unlock()
            return
        }
        let current = pieceTasks[key]
        if current?.taskIdentifier == taskID {
            pieceTasks.removeValue(forKey: key)
        }
        // このプロセスから直接送っている送り直しがあれば、そちらが今のもの
        let isCurrent = current?.taskIdentifier == taskID || (current == nil && inProcessUploads[key] == nil)
        guard var job = jobs[key.jobID], job.status == .running,
              job.pieces.indices.contains(key.index),
              job.pieces[key.index].status != .done else {
            // 破棄・失敗・キャンセル済みのジョブ、または応答がそろっているピース
            lock.unlock()
            return
        }

        if Self.wasCancelledByForceQuit(error) {
            // 利用者がアプリを強制終了したため、システムが送信を取り消した(次の起動で届く)。
            // ここで送り直すと、止めたつもりの実行に料金がかかり続ける → タスクの無いピースとして残し、
            // 「取り込む」で送り直す(resumeOrphans)。「破棄」なら費用はかからない
            var resumeLater = false
            if isCurrent {
                job.pieces[key.index].lastError = "アプリの強制終了で送信が取り消されました"
                job.updatedAt = Date()
                jobs[key.jobID] = job
                persistLocked(job)
                noteLocked("アプリの強制終了で止まったピースがあります(「取り込む」で送り直します)")
                // すでに「取り込む」で待っているなら、利用者の操作なので送り直す
                resumeLater = waiters[key.jobID] != nil
            }
            lock.unlock()
            if resumeLater {
                scheduleOrphanCheck(jobID: key.jobID)
            }
            return
        }

        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        let disposition = Self.disposition(for: job.pieces[key.index], status: httpStatus, data: data, error: error)

        if !isCurrent {
            // 同じピースを新しいタスク(またはこのプロセスからの直接送信)が送っている
            // (前のタスクの完了が遅れて届いた)→ 成功のときだけ採用する
            guard case .success = disposition else {
                lock.unlock()
                return
            }
            if let newer = current {
                pieceTasks.removeValue(forKey: key)
                taskKeys.removeValue(forKey: newer.taskIdentifier)
                backgroundCreatedTaskIDs.remove(newer.taskIdentifier)
                supersededTaskIDs.insert(newer.taskIdentifier)
                delivery.tasksToCancel.append(newer)
            }
            if let direct = inProcessUploads.removeValue(forKey: key) {
                delivery.inProcessToCancel.append(direct.task)
            }
        }

        applyDispositionLocked(disposition, job: &job, key: key, status: httpStatus, data: data, error: error,
                               template: task.originalRequest, delivery: &delivery)
        lock.unlock()
        delivery.run()
    }

    /// このプロセスから直接送った 1 回分の結果(背景セッションの完了と同じように扱う)
    private func handleInProcessCompletion(key: PieceKey, token: UUID, template: URLRequest, status httpStatus: Int?,
                                           data: Data, error: Error?) {
        var delivery = CloudUploadDelivery()
        lock.lock()
        guard let entry = inProcessUploads[key], entry.token == token else {
            // 取り消し・置き換え済み
            lock.unlock()
            return
        }
        inProcessUploads.removeValue(forKey: key)
        guard var job = jobs[key.jobID], job.status == .running,
              job.pieces.indices.contains(key.index),
              job.pieces[key.index].status != .done else {
            lock.unlock()
            return
        }
        let disposition = Self.disposition(for: job.pieces[key.index], status: httpStatus, data: data, error: error)
        applyDispositionLocked(disposition, job: &job, key: key, status: httpStatus, data: data, error: error,
                               template: template, delivery: &delivery)
        lock.unlock()
        delivery.run()
    }

    /// 1 回の送信結果の扱い(HTTP 応答、または通信エラー)
    private static func disposition(for piece: CloudJobManifest.Piece, status: Int?, data: Data,
                                    error: Error?) -> CloudTranscriber.UploadDisposition {
        if let error {
            return CloudTranscriber.disposition(forTransportError: error, attempt: piece.attempts,
                                                maxAttempts: maxAttempts)
        }
        return CloudTranscriber.disposition(forStatus: status ?? 0, data: data, model: piece.model,
                                            attempt: piece.attempts, maxAttempts: maxAttempts)
    }

    /// 利用者がアプリを強制終了したため、システムが背景セッションのタスクを取り消したか
    private static func wasCancelledByForceQuit(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled else { return false }
        let reason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
        return reason == forceQuitCancelReason
    }

    /// 1 回の送信結果をピースとジョブに反映し、記録して、待っている処理への通知を用意する。lock を持って呼ぶ。
    /// job は送信中で、key のピースはまだ完了していないこと。template は送り直しに使う元のリクエスト(Authorization ヘッダ付き)
    private func applyDispositionLocked(_ disposition: CloudTranscriber.UploadDisposition, job: inout CloudJobManifest,
                                        key: PieceKey, status httpStatus: Int?, data: Data, error: Error?,
                                        template: URLRequest?, delivery: inout CloudUploadDelivery) {
        let pieceNumber = key.index + 1
        let pieceTotal = job.pieces.count
        job.pieces[key.index].lastHTTPStatus = httpStatus
        switch disposition {
        case .success:
            if writeResult(data, jobID: key.jobID, index: key.index) {
                job.pieces[key.index].status = .done
                job.pieces[key.index].lastError = nil
                noteLocked("ピース \(pieceNumber)/\(pieceTotal) 完了")
            } else {
                failLocked(&job, error: .network("結果を保存できませんでした(空き容量を確認してください)"),
                           delivery: &delivery)
            }
        case .retry(let delay):
            let reason = Self.describe(error: error, status: httpStatus)
            job.pieces[key.index].lastError = reason
            if let failure = startUploadLocked(&job, index: key.index, template: template, apiKey: nil,
                                               rebuildBody: false, delay: delay, createdInBackground: nil,
                                               delivery: &delivery) {
                failLocked(&job, error: failure, delivery: &delivery)
            } else {
                noteLocked("ピース \(pieceNumber)/\(pieceTotal) を送り直します(\(reason))")
            }
        case .useFallbackModel:
            job.usesFallback = true
            job.pieces[key.index].model = job.fallbackModel
            job.pieces[key.index].attempts = 0
            if let failure = startUploadLocked(&job, index: key.index, template: template, apiKey: nil,
                                               rebuildBody: true, delay: 0, createdInBackground: nil,
                                               delivery: &delivery) {
                failLocked(&job, error: failure, delivery: &delivery)
            } else {
                noteLocked("ピース \(pieceNumber)/\(pieceTotal) を \(job.fallbackModel) で送り直します")
                // まだ送り始めていないピースも、前面にいる今のうちにフォールバックモデルで作り直す
                if !AppLifecycle.shared.isInBackground {
                    let switched = switchUnsentPiecesToFallbackLocked(&job, delivery: &delivery)
                    if switched > 0, job.status == .running {
                        noteLocked("まだ送っていないピース \(switched) 本も \(job.fallbackModel) に切り替えました")
                    }
                }
            }
        case .fail(let failure):
            job.pieces[key.index].status = .failed
            job.pieces[key.index].lastError = failure.localizedDescription
            failLocked(&job, error: failure, delivery: &delivery)
        }

        if job.status == .running, job.isComplete {
            job.status = .completed
            noteLocked("すべてのピース(\(pieceTotal) 本)の結果がそろいました")
        }
        job.updatedAt = Date()
        jobs[key.jobID] = job
        persistLocked(job)
        collectWaiterUpdatesLocked(for: job, into: &delivery)
    }

    /// 精度優先モデルが使えないと分かったとき、まだ送り始めていないピース(同時接続 4 本の順番待ちなど)を
    /// フォールバックモデルで作り直す。非対応の 4xx を待つだけの無駄な送信と、ロック中に作る作り直し
    /// (iOS が後回しにしやすい)を減らす。lock を持って呼ぶ。作り直した本数を返す
    private func switchUnsentPiecesToFallbackLocked(_ job: inout CloudJobManifest,
                                                    delivery: inout CloudUploadDelivery) -> Int {
        var switched = 0
        for i in job.pieces.indices {
            guard job.status == .running else { break }
            guard job.pieces[i].status != .done, job.pieces[i].model != job.fallbackModel else { continue }
            let pieceKey = PieceKey(jobID: job.id, index: i)
            guard let task = pieceTasks[pieceKey], let template = task.originalRequest,
                  task.countOfBytesSent == 0,
                  task.state == .running || task.state == .suspended else { continue }
            pieceTasks.removeValue(forKey: pieceKey)
            taskKeys.removeValue(forKey: task.taskIdentifier)
            backgroundCreatedTaskIDs.remove(task.taskIdentifier)
            supersededTaskIDs.insert(task.taskIdentifier)
            delivery.tasksToCancel.append(task)
            job.pieces[i].model = job.fallbackModel
            job.pieces[i].attempts = 0
            if let failure = startUploadLocked(&job, index: i, template: template, apiKey: nil, rebuildBody: true,
                                               delay: 0, createdInBackground: nil, delivery: &delivery) {
                failLocked(&job, error: failure, delivery: &delivery)
            } else {
                switched += 1
            }
        }
        return switched
    }

    /// job の index 番目のピースの送信を(再)開始する。lock を持って呼ぶ。
    /// - template: 元のタスクの originalRequest(Authorization ヘッダ付き)。nil なら apiKey(nil なら設定)から作る
    /// - rebuildBody: モデルを変えたときなど、送信内容を作り直す
    /// - createdInBackground: nil なら今の状態(AppLifecycle)で判断する
    /// 始められなければ失敗の理由を返す
    private func startUploadLocked(_ job: inout CloudJobManifest, index: Int, template: URLRequest?, apiKey: String?,
                                   rebuildBody: Bool, delay: Double, createdInBackground: Bool?,
                                   delivery: inout CloudUploadDelivery) -> CloudTranscriptionError? {
        guard let session, let directory = jobDirectoryURL(for: job.id) else {
            return .network("バックグラウンド送信を使えません")
        }
        let piece = job.pieces[index]
        let model = piece.model
        let bodyURL = directory.appendingPathComponent(Self.bodyFileName(index))
        var resolvedContentType = piece.bodyContentType
        if rebuildBody || resolvedContentType == nil || !FileManager.default.fileExists(atPath: bodyURL.path) {
            do {
                let built = try writeBody(for: piece, model: model, language: job.language, directory: directory)
                resolvedContentType = built
                job.pieces[index].bodyContentType = built
            } catch {
                return .network("送信内容を作れませんでした(\(error.localizedDescription))")
            }
        }
        guard let contentType = resolvedContentType else {
            return .network("送信内容を作れませんでした")
        }

        let request: URLRequest
        if var copy = template {
            copy.setValue(contentType, forHTTPHeaderField: "Content-Type")
            copy.timeoutInterval = CloudTranscriber.requestTimeout(for: model)
            request = copy
        } else {
            let key = (apiKey ?? AppSettings.shared.openAIKey).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return .missingAPIKey }
            request = CloudTranscriber.makeUploadRequest(apiKey: key, contentType: contentType, model: model)
        }

        let pieceKey = PieceKey(jobID: job.id, index: index)
        let inBackground = createdInBackground ?? AppLifecycle.shared.isInBackground
        if inBackground, let gate = inProcessRetryGates[job.id], gate() {
            // 継続処理でプロセスが動いている間にバックグラウンドで背景セッションのタスクを作ると、iOS が「任意のタイミング」
            // 扱いにしてロック解除・充電まで後回しにすることがある → このプロセスから直接送る
            startInProcessUploadLocked(request: request, bodyURL: bodyURL, key: pieceKey, delay: delay)
        } else {
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = pieceKey.taskDescription
            if delay > 0 {
                task.earliestBeginDate = Date().addingTimeInterval(delay)
            }
            registerTaskLocked(task, key: pieceKey, createdInBackground: inBackground)
            delivery.tasksToResume.append(task)
        }
        job.pieces[index].status = .uploading
        job.pieces[index].attempts += 1
        return nil
    }

    /// 1 ピースをこのプロセスから送る(継続処理中のバックグラウンドでの送り直し)。lock を持って呼ぶ。
    /// 結果は handleInProcessCompletion で背景セッションの完了と同じように扱う
    private func startInProcessUploadLocked(request: URLRequest, bodyURL: URL, key: PieceKey, delay: Double) {
        if let previous = inProcessUploads.removeValue(forKey: key) {
            previous.task.cancel()
        }
        let token = UUID()
        let uploadSession = inProcessSession
        let delayNanoseconds: UInt64 = delay > 0 ? UInt64(delay * 1_000_000_000) : 0
        let task = Task.detached(priority: .utility) { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            if Task.isCancelled { return }
            var receivedStatus: Int? = nil
            var receivedData = Data()
            var failure: Error? = nil
            do {
                let (data, response) = try await uploadSession.upload(for: request, fromFile: bodyURL)
                receivedData = data
                receivedStatus = (response as? HTTPURLResponse)?.statusCode
            } catch {
                failure = error
            }
            // こちらから取り消した(破棄・失敗・置き換え)
            if Task.isCancelled { return }
            self?.handleInProcessCompletion(key: key, token: token, template: request, status: receivedStatus,
                                            data: receivedData, error: failure)
        }
        inProcessUploads[key] = InProcessUpload(token: token, task: task)
    }

    /// このプロセスから直接送っている job のピースをすべて取り消す。lock を持って呼ぶ
    private func cancelInProcessUploadsLocked(jobID: UUID, delivery: inout CloudUploadDelivery) {
        let keys = inProcessUploads.keys.filter { $0.jobID == jobID }
        for key in keys {
            if let direct = inProcessUploads.removeValue(forKey: key) {
                delivery.inProcessToCancel.append(direct.task)
            }
        }
    }

    /// ジョブを失敗にして、残りのピースの送信をやめる。lock を持って呼ぶ
    private func failLocked(_ job: inout CloudJobManifest, error: CloudTranscriptionError,
                            delivery: inout CloudUploadDelivery) {
        guard job.status == .running else { return }
        job.status = .failed
        job.failure = CloudJobManifest.Failure.from(error)
        let keys = pieceTasks.keys.filter { $0.jobID == job.id }
        for key in keys {
            guard let task = pieceTasks.removeValue(forKey: key) else { continue }
            taskKeys.removeValue(forKey: task.taskIdentifier)
            backgroundCreatedTaskIDs.remove(task.taskIdentifier)
            supersededTaskIDs.insert(task.taskIdentifier)
            delivery.tasksToCancel.append(task)
        }
        cancelInProcessUploadsLocked(jobID: job.id, delivery: &delivery)
        noteLocked("失敗: \(error.localizedDescription)")
    }

    private func registerTaskLocked(_ task: URLSessionTask, key: PieceKey, createdInBackground: Bool) {
        taskKeys[task.taskIdentifier] = key
        pieceTasks[key] = task
        if createdInBackground {
            backgroundCreatedTaskIDs.insert(task.taskIdentifier)
        }
    }

    /// 待っている処理への進捗・結果の通知を用意する。lock を持って呼ぶ
    private func collectWaiterUpdatesLocked(for job: CloudJobManifest, into delivery: inout CloudUploadDelivery) {
        let list = waiters[job.id] ?? []
        guard !list.isEmpty else { return }
        let done = job.completedPieceCount
        let total = job.totalPieceCount
        for waiter in list {
            delivery.progress.append((callback: waiter.progress, done: done, total: total))
        }
        let outcome: Result<[Int: Data], Error>?
        switch job.status {
        case .running:
            outcome = nil
        case .completed:
            outcome = readResultsLocked(job)
        case .failed:
            outcome = .failure(job.failure?.error ?? CloudTranscriptionError.badResponse)
        case .cancelled:
            outcome = .failure(CancellationError())
        }
        guard let outcome else { return }
        waiters.removeValue(forKey: job.id)
        for waiter in list {
            delivery.completions.append((continuation: waiter.continuation, result: outcome))
        }
    }

    // MARK: - 待ち合わせ

    private func register(waiterID: UUID, jobID: UUID, progress: @escaping (Int, Int) -> Void,
                          continuation: CheckedContinuation<[Int: Data], Error>) {
        lock.lock()
        if cancelledWaiterIDs.remove(waiterID) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        guard let job = jobs[jobID] else {
            lock.unlock()
            continuation.resume(throwing: CloudBackgroundUploaderError.jobNotFound)
            return
        }
        let done = job.completedPieceCount
        let total = job.totalPieceCount
        let immediate: Result<[Int: Data], Error>?
        switch job.status {
        case .failed:
            immediate = .failure(job.failure?.error ?? CloudTranscriptionError.badResponse)
        case .cancelled:
            immediate = .failure(CancellationError())
        case .completed, .running:
            immediate = job.isComplete ? readResultsLocked(job) : nil
        }
        if let immediate {
            lock.unlock()
            progress(done, total)
            continuation.resume(with: immediate)
            return
        }
        waiters[jobID, default: []].append(CloudJobWaiter(id: waiterID, progress: progress, continuation: continuation))
        let hasOrphans = hasOrphanPiecesLocked(job)
        lock.unlock()
        progress(done, total)
        if hasOrphans {
            scheduleOrphanCheck(jobID: jobID)
        }
        // 前面で待ち始めたなら、バックグラウンドで作られた(前回のプロセスから引き継いだものを含む)まだ送り始めていない
        // タスクを今作り直す(didBecomeActive より後に前回のタスクを確認し終えた場合もここで拾う)
        if !AppLifecycle.shared.isInBackground {
            restartDeferredTasks(jobID: jobID)
        }
    }

    /// 完了しておらず、送っているタスク(このプロセスからの直接送信を含む)も無いピースがあるか。lock を持って呼ぶ
    private func hasOrphanPiecesLocked(_ job: CloudJobManifest) -> Bool {
        job.pieces.contains { piece in
            let pieceKey = PieceKey(jobID: job.id, index: piece.index)
            return piece.status != .done && pieceTasks[pieceKey] == nil && inProcessUploads[pieceKey] == nil
        }
    }

    /// 少し待ってから(再起動直後に遅れて届く完了通知を待つ)、タスクの無いピースを送り直す
    private func scheduleOrphanCheck(jobID: UUID) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.orphanGraceSeconds) { [weak self] in
            self?.resumeOrphans(jobID: jobID)
        }
    }

    private func cancelWait(waiterID: UUID, jobID: UUID, cancelTasks: Bool) {
        var delivery = CloudUploadDelivery()
        lock.lock()
        if var list = waiters[jobID], let position = list.firstIndex(where: { $0.id == waiterID }) {
            let waiter = list.remove(at: position)
            waiters[jobID] = list.isEmpty ? nil : list
            delivery.completions.append((continuation: waiter.continuation, result: .failure(CancellationError())))
        } else {
            // まだ登録されていない(register がこの印を見てすぐに CancellationError で戻す)
            cancelledWaiterIDs.insert(waiterID)
        }
        if cancelTasks, var job = jobs[jobID], job.status == .running {
            job.status = .cancelled
            job.updatedAt = Date()
            let keys = pieceTasks.keys.filter { $0.jobID == jobID }
            for key in keys {
                guard let task = pieceTasks.removeValue(forKey: key) else { continue }
                taskKeys.removeValue(forKey: task.taskIdentifier)
                backgroundCreatedTaskIDs.remove(task.taskIdentifier)
                supersededTaskIDs.insert(task.taskIdentifier)
                delivery.tasksToCancel.append(task)
            }
            cancelInProcessUploadsLocked(jobID: jobID, delivery: &delivery)
            jobs[jobID] = job
            persistLocked(job)
            collectWaiterUpdatesLocked(for: job, into: &delivery)
            noteLocked("キャンセルしました")
        }
        lock.unlock()
        delivery.run()
    }

    /// タスクの無いピース(前のプロセスが途中で終了したなど)を送り直す。待っている処理があるときだけ。
    /// API キーが無ければジョブは失敗にせず(保存済みの結果を残す)、待っている処理にだけ missingAPIKey を返す
    private func resumeOrphans(jobID: UUID) {
        let apiKey = AppSettings.shared.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var delivery = CloudUploadDelivery()
        lock.lock()
        guard var job = jobs[jobID], job.status == .running, let list = waiters[jobID] else {
            lock.unlock()
            return
        }
        if apiKey.isEmpty {
            if hasOrphanPiecesLocked(job) {
                // ジョブは送信中のまま残す(バナーの「取り込む」でキーを設定し直してから続けられる)
                waiters.removeValue(forKey: jobID)
                for waiter in list {
                    delivery.completions.append((continuation: waiter.continuation,
                                                 result: .failure(CloudTranscriptionError.missingAPIKey)))
                }
                noteLocked("API キーが無いため、中断していたピースを送り直せません")
            }
            lock.unlock()
            delivery.run()
            return
        }
        var restarted = 0
        for i in job.pieces.indices {
            guard job.status == .running else { break }
            let pieceKey = PieceKey(jobID: jobID, index: i)
            guard job.pieces[i].status != .done, pieceTasks[pieceKey] == nil,
                  inProcessUploads[pieceKey] == nil else { continue }
            var rebuild = false
            if job.usesFallback, job.pieces[i].model != job.fallbackModel {
                job.pieces[i].model = job.fallbackModel
                rebuild = true
            }
            if let failure = startUploadLocked(&job, index: i, template: nil, apiKey: apiKey, rebuildBody: rebuild,
                                               delay: 0, createdInBackground: nil, delivery: &delivery) {
                failLocked(&job, error: failure, delivery: &delivery)
            } else {
                restarted += 1
            }
        }
        if restarted > 0 {
            noteLocked("中断していたピース \(restarted) 本を送り直しました")
        }
        job.updatedAt = Date()
        jobs[jobID] = job
        persistLocked(job)
        collectWaiterUpdatesLocked(for: job, into: &delivery)
        lock.unlock()
        delivery.run()
    }

    /// バックグラウンド中に作ってまだ送り始めていないタスクを、前面にいる今のうちに作り直す
    /// (バックグラウンドで作ったタスクは iOS が後回しにすることがあるため)。jobID を渡すとそのジョブのタスクだけ
    private func restartDeferredTasks(jobID onlyJobID: UUID? = nil) {
        var delivery = CloudUploadDelivery()
        var restarted = 0
        lock.lock()
        for taskID in Array(backgroundCreatedTaskIDs) {
            guard let key = taskKeys[taskID], let task = pieceTasks[key], task.taskIdentifier == taskID else {
                backgroundCreatedTaskIDs.remove(taskID)
                continue
            }
            if let onlyJobID, key.jobID != onlyJobID { continue }
            guard task.countOfBytesSent == 0, task.state == .running || task.state == .suspended else { continue }
            // 元のリクエスト(Authorization ヘッダ付き)が無ければ作り直さない(そのまま送らせる)
            guard let template = task.originalRequest else { continue }
            guard var job = jobs[key.jobID], job.status == .running, job.pieces.indices.contains(key.index) else {
                continue
            }
            pieceTasks.removeValue(forKey: key)
            taskKeys.removeValue(forKey: taskID)
            backgroundCreatedTaskIDs.remove(taskID)
            supersededTaskIDs.insert(taskID)
            delivery.tasksToCancel.append(task)
            // 作り直しは回数に数えない
            job.pieces[key.index].attempts = max(0, job.pieces[key.index].attempts - 1)
            if let failure = startUploadLocked(&job, index: key.index, template: template, apiKey: nil,
                                               rebuildBody: false, delay: 0, createdInBackground: false,
                                               delivery: &delivery) {
                failLocked(&job, error: failure, delivery: &delivery)
            } else {
                restarted += 1
            }
            job.updatedAt = Date()
            jobs[key.jobID] = job
            persistLocked(job)
            collectWaiterUpdatesLocked(for: job, into: &delivery)
        }
        if restarted > 0 {
            noteLocked("後回しになっていたピース \(restarted) 本を送り直しました")
        }
        lock.unlock()
        delivery.run()
    }

    // MARK: - 起動時の確認

    private func reconcile(with tasks: [URLSessionTask]) {
        var stale: [URLSessionTask] = []
        var suspended: [URLSessionTask] = []
        lock.lock()
        for task in tasks {
            guard let key = PieceKey(taskDescription: task.taskDescription) else {
                stale.append(task)
                continue
            }
            if let job = jobs[key.jobID] {
                guard job.status == .running, job.pieces.indices.contains(key.index),
                      job.pieces[key.index].status != .done else {
                    stale.append(task)
                    continue
                }
                if pieceTasks[key] == nil {
                    pieceTasks[key] = task
                    taskKeys[task.taskIdentifier] = key
                    // 前回のプロセスがバックグラウンド(ロック中・完了で起こされたとき)に作った送り直しかもしれない
                    // (iOS が後回しにする)。まだ送り始めていなければ、前面で待ち始めたとき・前面に戻ったときに作り直す
                    if task.countOfBytesSent == 0, task.state == .running || task.state == .suspended {
                        backgroundCreatedTaskIDs.insert(task.taskIdentifier)
                    }
                    // 作ってから resume する前に前回のプロセスが終了した
                    if task.state == .suspended {
                        suspended.append(task)
                    }
                }
            } else if let directory = jobDirectoryURL(for: key.jobID),
                      FileManager.default.fileExists(atPath: directory.path) {
                // 記録はあるが読めなかった(端末の初回ロック解除前など)→ そのまま送らせておく
                continue
            } else {
                stale.append(task)
            }
        }
        if !tasks.isEmpty {
            noteLocked("前回の送信 \(tasks.count) 件を確認しました")
        }
        let waiting = finishReconcileLocked()
        lock.unlock()
        for task in stale {
            task.cancel()
        }
        for task in suspended {
            task.resume()
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    private func reconcileTimedOut() {
        lock.lock()
        let waiting = reconciled ? [] : finishReconcileLocked()
        lock.unlock()
        for continuation in waiting {
            continuation.resume()
        }
    }

    private func finishReconcileLocked() -> [CheckedContinuation<Void, Never>] {
        reconciled = true
        let waiting = reconcileWaiters
        reconcileWaiters = []
        return waiting
    }

    private func waitUntilReconciled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if reconciled {
                lock.unlock()
                continuation.resume()
                return
            }
            reconcileWaiters.append(continuation)
            lock.unlock()
        }
    }

    // MARK: - ファイル

    private static func makeRootDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        var url = base.appendingPathComponent("CloudJobs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    private func jobDirectoryURL(for jobID: UUID) -> URL? {
        rootDirectory?.appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    private static let manifestFileName = "job.json"

    private static func bodyFileName(_ index: Int) -> String { "body-\(index).bin" }

    private static func resultFileName(_ index: Int) -> String { "result-\(index).json" }

    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    /// 保存済みのジョブを読み込む(init から 1 回だけ)。失敗・キャンセル・古いジョブと、記録の無いフォルダは消す
    private func loadJobs() {
        guard let root = rootDirectory else { return }
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let now = Date()
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            let manifestURL = entry.appendingPathComponent(Self.manifestFileName)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                // 記録の無いフォルダ(このプロセスから直接送った実行の残りなど)
                try? fileManager.removeItem(at: entry)
                continue
            }
            guard let data = try? Data(contentsOf: manifestURL) else {
                // 読めない(端末の初回ロック解除前など)→ 消さずに残す
                continue
            }
            guard let job = try? decoder.decode(CloudJobManifest.self, from: data), job.id == id else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let expired = now.timeIntervalSince(job.createdAt) > Self.jobRetention
            if expired || job.status == .failed || job.status == .cancelled {
                try? fileManager.removeItem(at: entry)
                continue
            }
            jobs[id] = job
        }
    }

    private func writeManifest(_ job: CloudJobManifest) throws {
        guard let directory = jobDirectoryURL(for: job.id) else {
            throw CloudBackgroundUploaderError.unavailable("保存先を使えません")
        }
        let data = try JSONEncoder().encode(job)
        try data.write(to: directory.appendingPathComponent(Self.manifestFileName), options: Self.writeOptions)
    }

    /// ジョブの記録を書く。lock を持って呼ぶ(失敗しても処理は続ける)
    private func persistLocked(_ job: CloudJobManifest) {
        try? writeManifest(job)
    }

    /// 送信内容(multipart)を body-<i>.bin に書き、Content-Type を返す
    private func writeBody(for piece: CloudJobManifest.Piece, model: String, language: String,
                           directory: URL) throws -> String {
        let audio = try Data(contentsOf: directory.appendingPathComponent(piece.audioFileName))
        let body = CloudTranscriber.multipartBody(audioData: audio, model: model, language: language)
        try body.data.write(to: directory.appendingPathComponent(Self.bodyFileName(piece.index)),
                            options: Self.writeOptions)
        return body.contentType
    }

    private func writeResult(_ data: Data, jobID: UUID, index: Int) -> Bool {
        guard let directory = jobDirectoryURL(for: jobID) else { return false }
        do {
            try data.write(to: directory.appendingPathComponent(Self.resultFileName(index)), options: Self.writeOptions)
            return true
        } catch {
            return false
        }
    }

    /// すべてのピースの応答を読む。lock を持って呼ぶ
    private func readResultsLocked(_ job: CloudJobManifest) -> Result<[Int: Data], Error> {
        guard let directory = jobDirectoryURL(for: job.id) else {
            return .failure(CloudBackgroundUploaderError.jobNotFound)
        }
        var results: [Int: Data] = [:]
        for piece in job.pieces {
            let url = directory.appendingPathComponent(Self.resultFileName(piece.index))
            guard let data = try? Data(contentsOf: url) else {
                return .failure(CloudTranscriptionError.badResponse)
            }
            results[piece.index] = data
        }
        return .success(results)
    }

    /// pendingJobs に出すジョブか。lock を持って呼ぶ
    private func isPendingLocked(_ job: CloudJobManifest) -> Bool {
        guard job.status == .running || job.status == .completed else { return false }
        return !ownedJobIDs.contains(job.id) && waiters[job.id] == nil
    }

    // MARK: - 診断

    private func noteLocked(_ text: String) {
        lastEvent = Self.stampFormatter.string(from: Date()) + " " + text
    }

    private static func describe(error: Error?, status: Int?) -> String {
        if let error {
            let nsError = error as NSError
            return "通信エラー \(nsError.domain) \(nsError.code)"
        }
        if let status {
            return "HTTP \(status)"
        }
        return "不明"
    }
}
