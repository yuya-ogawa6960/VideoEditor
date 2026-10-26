import Foundation
import UIKit
import Observation

// =====================================================================
// 使い方の統計(匿名)。どの機能がどれだけ使われているかを自分のサーバー(server/)に送る。
//   - 端末ごとのランダムな ID だけ(Apple のサインインや名前とは結びつけない)
//   - 動画・文章・ファイル名は送らない。送るのは機能名・スタイル名・秒数の区分など
//   - 設定(「使い方の統計を送信」)でいつでも止められる
//   - まとめて送る: 20 件たまる / 60 秒ごと / 裏に回るとき
// =====================================================================

@Observable
final class Analytics {
    static let shared = Analytics()

    static let enabledKey = "analytics.enabled"
    private static let installKey = "analytics.installID"
    private static let queueFile = "analytics-queue.json"
    private static let flushCount = 20
    private static let flushInterval: TimeInterval = 60
    private static let maxQueued = 500

    struct Event: Codable {
        var name: String
        var params: [String: String]
        /// 端末の時刻(ISO 8601)
        var t: String
    }

    /// 送信するか(既定はオン。設定で切れる)
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var queue: [Event] = []
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 端末ごとのランダムな ID(アプリを消すと変わる)
    private(set) var installID: String = ""

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.installKey), !saved.isEmpty {
            installID = saved
        } else {
            installID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(installID, forKey: Self.installKey)
        }
        loadQueue()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionEnded()
            self?.flush()
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionStarted()
        })
    }

    /// 起動時に 1 回
    func start() {
        sessionStarted()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
    }

    // MARK: 記録

    /// 出来事を 1 つ記録する(params の値は短い文字列だけ。個人情報や本文は入れない)
    func track(_ name: String, _ params: [String: String] = [:]) {
        guard isEnabled else { return }
        let event = Event(name: name, params: params, t: formatter.string(from: Date()))
        lock.lock()
        queue.append(event)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        let count = queue.count
        lock.unlock()
        saveQueue()
        if count >= Self.flushCount { flush() }
    }

    /// 秒数を区分にする("<10s" / "10-30s" / "30s-1m" / "1-3m" / "3-10m" / ">10m")
    static func durationBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<10: return "<10s"
        case ..<30: return "10-30s"
        case ..<60: return "30s-1m"
        case ..<180: return "1-3m"
        case ..<600: return "3-10m"
        default: return ">10m"
        }
    }

    /// 長めの時間の区分(編集にかかった時間など)
    static func longDurationBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: return "<1m"
        case ..<300: return "1-5m"
        case ..<900: return "5-15m"
        case ..<1800: return "15-30m"
        case ..<3600: return "30-60m"
        default: return ">60m"
        }
    }

    /// 数の区分("1" / "2-5" / "6-20" / ">20")
    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<2: return "1"
        case ..<6: return "2-5"
        case ..<21: return "6-20"
        default: return ">20"
        }
    }

    // MARK: 使い勝手の計測(迷っている印・かかった時間)

    @ObservationIgnored private var projectOpenedAt: Date?
    @ObservationIgnored private var captionsDoneAt: Date?
    @ObservationIgnored private var lastAction: (name: String, at: Date)?

    /// プロジェクトを開いた(書き出しまでの時間を測る)
    func projectOpened() {
        projectOpenedAt = Date()
        captionsDoneAt = nil
        lastAction = nil
    }

    /// 直前の操作(元に戻したとき、何を戻したかを知るため)
    func noteAction(_ name: String) {
        lastAction = (name, Date())
    }

    /// 字幕を作り終えた(書き出しまでに字幕を直す時間を測る)
    func captionsDone() {
        captionsDoneAt = Date()
        noteAction("captions")
    }

    /// 元に戻した。直前 60 秒以内の操作があれば、それを戻したとみなす(意図と違う結果になった印)
    func trackUndo(source: String) {
        var params = ["source": source, "after": "none"]
        if let lastAction {
            let elapsed = Date().timeIntervalSince(lastAction.at)
            if elapsed < 60 {
                params["after"] = lastAction.name
                params["within"] = Self.durationBucket(elapsed)
            }
        }
        track("undo", params)
    }

    /// 書き出しの出来事に足す時間(プロジェクトを開いてから・字幕を作ってから)
    func exportTiming() -> [String: String] {
        var params: [String: String] = [:]
        if let projectOpenedAt {
            params["since_open"] = Self.longDurationBucket(Date().timeIntervalSince(projectOpenedAt))
        }
        if let captionsDoneAt {
            params["since_captions"] = Self.longDurationBucket(Date().timeIntervalSince(captionsDoneAt))
        }
        return params
    }

    private func sessionStarted() {
        guard sessionStart == nil else { return }
        sessionStart = Date()
        track("app_open")
    }

    private func sessionEnded() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        track("app_close", ["length": Self.durationBucket(Date().timeIntervalSince(start))])
    }

    // MARK: 送信

    private var endpoint: URL? {
        AccountService.serverURL?.appendingPathComponent("v1/events")
    }

    func flush() {
        guard isEnabled, let endpoint else { return }
        lock.lock()
        guard !isSending, !queue.isEmpty else {
            lock.unlock()
            return
        }
        isSending = true
        let batch = Array(queue.prefix(100))
        lock.unlock()

        let body: [String: Any] = [
            "install": installID,
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "os": UIDevice.current.systemVersion,
            "device": Self.deviceModel,
            "locale": Locale.current.identifier,
            "events": batch.map { ["name": $0.name, "params": $0.params, "t": $0.t] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            lock.lock(); isSending = false; lock.unlock()
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = data
        let sent = batch.count
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let ok = error == nil && (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            self.lock.lock()
            if ok { self.queue.removeFirst(min(sent, self.queue.count)) }
            self.isSending = false
            self.lock.unlock()
            if ok { self.saveQueue() }
        }
        task.resume()
    }

    // MARK: 保存(送れなかった分は次回の起動で送る)

    private var queueURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(Self.queueFile)
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL),
              let saved = try? JSONDecoder().decode([Event].self, from: data) else { return }
        lock.lock()
        queue = saved
        lock.unlock()
    }

    private func saveQueue() {
        lock.lock()
        let snapshot = queue
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}
