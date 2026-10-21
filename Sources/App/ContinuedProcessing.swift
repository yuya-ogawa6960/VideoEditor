import Foundation
import UIKit
import BackgroundTasks
import MachO

// =====================================================================
// ロック中・バックグラウンドでの処理の継続(iOS 26+ の BGContinuedProcessingTask)。
//
// - 要求の識別子は実行時のバンドル ID から作る: "<bundleID>.export.<UUID>" / "<bundleID>.transcribe.<UUID>"。
//   AltStore はインストール時にバンドル ID を "com.personal.videoeditor.<TEAMID>" に書き換えるが、
//   Info.plist の BGTaskSchedulerPermittedIdentifiers は書き換えない。固定の識別子
//   ("com.personal.videoeditor.export")はバンドル ID で始まらないため iOS に拒否される。
//   Info.plist にはワイルドカード "com.personal.videoeditor.*" を入れてあり、書き換え後の ID にも一致する。
// - 起動ハンドラは submit の直前に、その識別子で登録する(継続処理の識別子は起動後に登録してよい)。
//   許可リストに無い識別子を register すると例外(クラッシュ)になるため、先に Info.plist と照合する。
//   同じ識別子を 2 回 register しても例外になるため、登録済みの識別子を覚えておく。
// - strategy = .fail: すぐに開始できないときは submit が失敗する → nil を返し、
//   呼び出し側は beginBackgroundTask(約 30 秒)にフォールバックする。
// - GPU: wantsGPU かつ BGTaskScheduler.supportedResources に .gpu があれば requiredResources = .gpu で要求する。
//   その要求が通らなければ GPU なしで submit し直す。GPU 付きのタスクが動いている間は
//   AppLifecycle.shared.backgroundGPUAllowed を true にする(合成がバックグラウンドでも GPU を使える)。
// - iOS 26 未満 / iOS 26 SDK 未満のビルドでは何もせず nil を返す。
// =====================================================================

/// 継続処理の種類(識別子の一部になる)
enum ContinuedProcessingKind: String {
    case export
    case transcribe
    /// 見どころ探し・おまかせ編集・中だるみチェックなどの長い解析(EditorAnalysisRunner)
    case analyze

    /// 診断表示用の日本語名
    var displayName: String {
        switch self {
        case .export: return String(localized: "書き出し")
        case .transcribe: return String(localized: "文字起こし")
        case .analyze: return String(localized: "解析")
        }
    }
}

/// 1 回分の継続処理。`ContinuedProcessing.begin` が返す。どのスレッドから呼んでもよい(内部で NSLock を使う)。
/// 処理が終わったら(成功・失敗・キャンセルとも)必ず `finish(success:)` を呼ぶこと。
final class ContinuedProcessingHandle: @unchecked Sendable {
    let kind: ContinuedProcessingKind
    /// submit した要求の識別子("<bundleID>.<kind>.<UUID>")
    let identifier: String
    /// システム UI に出すタイトル
    let title: String

    /// task.progress の totalUnitCount
    static let unitCount: Int64 = 1000
    /// システム UI のサブタイトルを書き換える最短間隔(秒)
    private static let subtitleInterval: CFAbsoluteTime = 1.0
    /// 期限切れのあと、呼び出し側が finish を呼ばなくても完了を報告するまでの猶予(秒)
    private static let expirationGrace: TimeInterval = 2.0

    private let lock = NSLock()
    /// BGContinuedProcessingTask(iOS 18 でも宣言できるよう AnyObject で持つ)
    private var task: AnyObject?
    private var launched = false
    private var finished = false
    private var finishedSuccess = false
    private var expired = false
    private var gpuRequested = false
    private var holdsGPU = false
    private var fraction: Double = 0
    private var subtitle: String
    private var shownSubtitle: String?
    private var lastSubtitleTime: CFAbsoluteTime = 0
    private var expireHandler: (@MainActor () -> Void)?

    fileprivate init(kind: ContinuedProcessingKind, identifier: String, title: String, subtitle: String) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
    }

    /// バックグラウンドで GPU を使う要求(requiredResources = .gpu)が受け付けられたか
    var gpuGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gpuRequested
    }

    /// システムまたはユーザー(ロック画面などの停止ボタン)が処理を止めたか
    var wasExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    /// システムがタスクを開始していて、まだ止められても終わってもいないか
    /// (true の間はバックグラウンドでも処理を続けられる)
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return launched && !expired && !finished
    }

    /// 期限切れ(停止)のときにメインスレッドで呼ばれる。
    /// 呼ばれたら処理を中断し、できるだけ早く `finish(success: false)` を呼ぶこと
    /// (呼ばなくても 2 秒後にこちらで完了を報告する)。
    var onExpire: (@MainActor () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return expireHandler
        }
        set {
            lock.lock()
            expireHandler = newValue
            lock.unlock()
        }
    }

    /// 進捗(0...1)とサブタイトルを更新する。サブタイトルが nil なら前の表示のまま。
    /// 何度呼んでもよい(サブタイトルの書き換えは 1 秒に 1 回までに間引く)。
    func update(completed: Double, subtitle newSubtitle: String?) {
        let value = completed.isFinite ? min(max(completed, 0), 1) : 0
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if finished || expired {
            lock.unlock()
            return
        }
        fraction = value
        if let newSubtitle, !newSubtitle.isEmpty {
            subtitle = newSubtitle
        }
        let currentTask = task
        var subtitleToShow: String?
        if currentTask != nil, subtitle != shownSubtitle, now - lastSubtitleTime >= Self.subtitleInterval {
            subtitleToShow = subtitle
            shownSubtitle = subtitle
            lastSubtitleTime = now
        }
        lock.unlock()
        guard let currentTask else { return }
        push(fraction: value, subtitle: subtitleToShow, to: currentTask)
    }

    /// 処理の終了を報告する(setTaskCompleted)。2 回目以降は何もしない。
    func finish(success: Bool) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        finishedSuccess = success
        let currentTask = task
        let wasLaunched = launched
        task = nil
        if holdsGPU {
            holdsGPU = false
            ContinuedProcessing.releaseBackgroundGPU()
        }
        lock.unlock()

        ContinuedProcessing.removeActive(identifier, success: success, launched: wasLaunched)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let continued = currentTask as? BGContinuedProcessingTask {
            if success {
                continued.progress.totalUnitCount = Self.unitCount
                continued.progress.completedUnitCount = Self.unitCount
            }
            continued.setTaskCompleted(success: success)
        }
        #else
        _ = currentTask
        #endif
    }

    // MARK: - Internal

    fileprivate func setGPURequested(_ value: Bool) {
        lock.lock()
        gpuRequested = value
        lock.unlock()
    }

    /// システムがタスクを開始したか、すでに終わっているか(開始待ちの監視用)
    fileprivate var hasLaunchedOrFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return launched || finished
    }

    private func push(fraction value: Double, subtitle text: String?, to task: AnyObject) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            continued.progress.totalUnitCount = Self.unitCount
            continued.progress.completedUnitCount = Int64((value * Double(Self.unitCount)).rounded())
            if let text {
                continued.updateTitle(title, subtitle: text)
            }
        }
        #endif
    }

    /// 期限切れ(システム / ユーザーの停止)。expirationHandler から任意スレッドで呼ばれる
    private func handleExpiration() {
        lock.lock()
        if finished || expired {
            lock.unlock()
            return
        }
        expired = true
        if holdsGPU {
            // GPU の許可はここで失われる。以降の合成は CPU に戻す
            holdsGPU = false
            ContinuedProcessing.releaseBackgroundGPU()
        }
        lock.unlock()

        DispatchQueue.main.async {
            // 呼び出し側が begin の直後に onExpire を設定するので、読むのはメインスレッドで実行するときにする
            if let handler = self.onExpire {
                MainActor.assumeIsolated {
                    handler()
                }
            }
        }
        // 呼び出し側が finish を呼ばなくても、少し待ってから完了を報告する(報告しないとアプリが終了させられる)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.expirationGrace) {
            self.finish(success: false)
        }
    }

    #if compiler(>=6.2)
    /// 起動ハンドラから呼ばれる(任意スレッド)
    @available(iOS 26.0, *)
    fileprivate func attach(_ continued: BGContinuedProcessingTask) {
        // 期限切れハンドラは最初に設定する(タスク → ハンドラ → タスク の循環参照を避けるため weak)
        continued.expirationHandler = { [weak self, weak continued] in
            if let self {
                self.handleExpiration()
            } else {
                continued?.setTaskCompleted(success: false)
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if finished {
            // 開始される前に処理が終わっていた
            let success = finishedSuccess
            lock.unlock()
            continued.setTaskCompleted(success: success)
            return
        }
        task = continued
        launched = true
        if expired {
            // ハンドラを設定してからロックを取るまでの間に期限切れになった。タスクは保持して
            // (2 秒後の finish が setTaskCompleted できるように)、GPU の許可も進捗の表示もしない
            lock.unlock()
            return
        }
        if gpuRequested && !holdsGPU {
            holdsGPU = true
            ContinuedProcessing.retainBackgroundGPU()
        }
        let value = fraction
        let text = subtitle
        shownSubtitle = text
        lastSubtitleTime = now
        lock.unlock()

        push(fraction: value, subtitle: text, to: continued)
    }
    #endif
}

/// BGContinuedProcessingTask の開始と診断。
enum ContinuedProcessing {
    /// 以前のバージョンが submit していた固定の識別子(Info.plist の許可リストにも残してある)
    static let legacyExportIdentifier = "com.personal.videoeditor.export"

    /// Info.plist に識別子が無いときの代わりのバンドル ID 表示
    private static let unknownBundleIdentifier = String(localized: "(取得できません)")
    /// submit が受け付けられてから、システムがタスクを開始するまで待つ時間(秒)。過ぎたら診断に記録する
    private static let launchTimeout: TimeInterval = 5

    // 以下は lock で保護する。ロックの順序: ハンドル → ContinuedProcessing → AppLifecycle
    private static let lock = NSLock()
    private static var diagnostic: String?
    private static var diagnosticGeneration = 0
    private static var activeHandles: [String: ContinuedProcessingHandle] = [:]
    /// 開始前に finish された要求の結果(遅れて起動ハンドラが呼ばれたときに使う)
    private static var finishedResults: [String: Bool] = [:]
    private static var registeredIdentifiers: Set<String> = []
    private static var gpuUsers = 0

    /// 実行時のバンドル ID(AltStore で書き換えられた後の値)
    static var runtimeBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? unknownBundleIdentifier
    }

    /// 直近の begin(submit / register)の結果(日本語)。
    /// 例: 「ロック中の継続: 有効(書き出し・GPU なし…)」「ロック中の継続: 使えません(理由)」
    static var lastDiagnostic: String {
        lock.lock()
        let value = diagnostic
        lock.unlock()
        return value ?? preflightDiagnostic()
    }

    /// Info.plist の BGTaskSchedulerPermittedIdentifiers
    static var permittedIdentifierPatterns: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []
    }

    /// 識別子が Info.plist の許可リストに一致するか(完全一致、または ".*" で終わる項目の前方一致)
    static func isPermitted(_ identifier: String) -> Bool {
        for entry in permittedIdentifierPatterns {
            if entry == identifier { return true }
            if entry.hasSuffix(".*") {
                let prefix = String(entry.dropLast()) // 末尾の "*" だけ外す("." は残す)
                if identifier.count > prefix.count && identifier.hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }

    /// 継続処理を始める。ユーザー操作から、アプリが前面にある間にメインスレッドで呼ぶこと。
    /// 使えないとき(iOS 26 未満・許可されていない・すぐに開始できない)は nil(理由は lastDiagnostic)。
    @MainActor
    static func begin(kind: ContinuedProcessingKind, title: String, subtitle: String, wantsGPU: Bool) -> ContinuedProcessingHandle? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return beginContinuedTask(kind: kind, title: title, subtitle: subtitle, wantsGPU: wantsGPU)
        }
        setDiagnostic(String(localized: "ロック中の継続: 使えません(iOS 26 以降が必要です)"))
        return nil
        #else
        setDiagnostic(String(localized: "ロック中の継続: 使えません(iOS 26 SDK でビルドされていません)"))
        return nil
        #endif
    }

    /// 起動時(AppLifecycle.start)に一度だけ呼ぶ。以前のバージョンが固定の識別子で submit した要求が
    /// 残っていても、ハンドラ未登録で落ちないよう、すぐ完了させるだけのハンドラを登録する。
    /// 許可リストに無ければ登録しない(クラッシュさせない)。
    static func registerLegacyLaunchHandler() {
        // TestFlight 版(バンドル ID が com.personal.* ではない)では以前の識別子は使わない
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.personal.") == true else { return }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            _ = registerLaunchHandler(for: legacyExportIdentifier, slot: .legacy)
        }
        #endif
    }

    // MARK: - register の安全装置
    // register が例外を投げるとアプリは落ちる(Swift では捕まえられない)。iOS のワイルドカードの解釈が
    // こちらの照合(isPermitted)より厳しかった場合に備え、register の直前に印のファイルを書き、戻ってきたら消す
    // (begin では submit が戻るまで印を残す)。印が残っていれば(= その途中で落ちた)、同じビルドでは
    // その種類の register をもう行わない(落ちるのは 1 回だけで、以降は beginBackgroundTask にフォールバックする)。
    // 「同じビルド」は実行ファイルの LC_UUID で判定する。AltStore の更新(再署名・再インストール)では変わらず、
    // 新しくビルドしたときだけ変わる(実行ファイルの更新日時は再署名のたびに変わるので使わない)。

    private enum RegisterSlot: String {
        /// 起動時に登録する固定の識別子
        case legacy
        /// begin のたびに登録する "<bundleID>.<kind>.<UUID>"
        case dynamic
    }

    private static func registerMarkerURL(_ slot: RegisterSlot) -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("ContinuedProcessing", isDirectory: true)
            .appendingPathComponent("register-\(slot.rawValue).marker")
    }

    /// このビルドを表す文字列(バンドル ID + このコードを含む実行ファイルの LC_UUID)。
    /// LC_UUID はリンク時に決まり、再署名では変わらない。読めないとき(通常は無い)だけ実行ファイルの更新日時で代用する
    private static let installStamp: String = {
        var stamp = Bundle.main.bundleIdentifier ?? "-"
        if let uuid = ContinuedProcessing.imageUUID() {
            stamp += "|uuid:\(uuid)"
        } else if let url = Bundle.main.executableURL,
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            stamp += "|\(Int(date.timeIntervalSince1970))"
        }
        return stamp
    }()

    /// このコードを含むイメージ(アプリの実行ファイル)の Mach-O ヘッダから LC_UUID を読む
    private static func imageUUID() -> String? {
        let header = UnsafeRawPointer(#dsohandle)
        let machHeader = header.load(as: mach_header_64.self)
        guard machHeader.magic == UInt32(MH_MAGIC_64) else { return nil }
        var offset = MemoryLayout<mach_header_64>.size
        for _ in 0..<machHeader.ncmds {
            let command = header.load(fromByteOffset: offset, as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                let uuidCommand = header.load(fromByteOffset: offset, as: uuid_command.self)
                return UUID(uuid: uuidCommand.uuid).uuidString
            }
            guard command.cmdsize > 0 else { return nil }
            offset += Int(command.cmdsize)
        }
        return nil
    }

    /// このビルドで、前回この種類の register(.dynamic は submit まで)の途中でアプリが終了していたら true
    private static func registerCrashedBefore(_ slot: RegisterSlot) -> Bool {
        guard let url = registerMarkerURL(slot), let data = try? Data(contentsOf: url) else { return false }
        if String(decoding: data, as: UTF8.self) == installStamp {
            return true
        }
        // 前のビルドの印は消す
        try? FileManager.default.removeItem(at: url)
        return false
    }

    private static func setRegisterMarker(_ slot: RegisterSlot, active: Bool) {
        guard let url = registerMarkerURL(slot) else { return }
        if active {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(installStamp.utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Internal (handle から呼ばれる)

    fileprivate static func retainBackgroundGPU() {
        lock.lock()
        gpuUsers += 1
        AppLifecycle.shared.backgroundGPUAllowed = gpuUsers > 0
        lock.unlock()
    }

    fileprivate static func releaseBackgroundGPU() {
        lock.lock()
        gpuUsers = max(0, gpuUsers - 1)
        AppLifecycle.shared.backgroundGPUAllowed = gpuUsers > 0
        lock.unlock()
    }

    /// 結果を覚えておく要求の上限(開始されずに終わった要求の結果が溜まり続けないように)
    private static let finishedResultsLimit = 16

    /// launched: システムがすでにタスクを開始していたか。開始済みなら結果を覚えておく必要はない
    /// (覚えておくのは、開始前に finish された要求に遅れて起動ハンドラが呼ばれたときのためだけ)
    fileprivate static func removeActive(_ identifier: String, success: Bool, launched: Bool) {
        lock.lock()
        if activeHandles.removeValue(forKey: identifier) != nil, !launched {
            if finishedResults.count >= finishedResultsLimit {
                // 数秒しか使わない情報なので、溜まったら捨てる(遅れて開始されたタスクは失敗として完了させる)
                finishedResults.removeAll()
            }
            finishedResults[identifier] = success
        }
        lock.unlock()
    }

    // MARK: - Diagnostics

    @discardableResult
    private static func setDiagnostic(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        diagnostic = text
        diagnosticGeneration += 1
        return diagnosticGeneration
    }

    /// その後に別の begin が無ければ診断を書き換える
    private static func replaceDiagnostic(generation: Int, with text: String) {
        lock.lock()
        if diagnosticGeneration == generation {
            diagnostic = text
        }
        lock.unlock()
    }

    /// まだ一度も begin していないときの表示(許可リストとバンドル ID の照合だけ行う)
    private static func preflightDiagnostic() -> String {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
                return String(localized: "ロック中の継続: 使えません(バンドル ID を取得できません)")
            }
            if registerCrashedBefore(.dynamic) {
                return String(localized: "ロック中の継続: 使えません(前回、起動ハンドラの登録または要求の送信中にアプリが終了したため、このビルドでは使いません)")
            }
            let sample = "\(bundleID).\(ContinuedProcessingKind.export.rawValue).\(UUID().uuidString)"
            if isPermitted(sample) {
                return String(localized: "ロック中の継続: 未確認(識別子は Info.plist で許可されています。書き出しか文字起こしを始めると確認します)")
            }
            return String(localized: "ロック中の継続: 使えません(バンドル ID \(bundleID) に一致する項目が Info.plist の BGTaskSchedulerPermittedIdentifiers にありません)")
        }
        return String(localized: "ロック中の継続: 使えません(iOS 26 以降が必要です)")
        #else
        return String(localized: "ロック中の継続: 使えません(iOS 26 SDK でビルドされていません)")
        #endif
    }

    /// submit / register のエラーを日本語の理由にする
    private static func describe(_ error: Error?) -> String {
        guard let error else { return String(localized: "原因不明") }
        let nsError = error as NSError
        if nsError.domain == "BGTaskSchedulerErrorDomain" {
            switch nsError.code {
            case 1:
                return String(localized: "この端末または現在の状態では使えません [BGTaskScheduler 1]")
            case 2:
                return String(localized: "実行待ちの要求が多すぎます [BGTaskScheduler 2]")
            case 3:
                return String(localized: "識別子が許可されていません。Info.plist の許可リストとバンドル ID が一致しません [BGTaskScheduler 3]")
            case 4:
                return String(localized: "今すぐには開始できませんでした(ほかの処理の実行中・システムの負荷など) [BGTaskScheduler 4]")
            default:
                break
            }
        }
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    // MARK: - iOS 26

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    @MainActor
    private static func beginContinuedTask(kind: ContinuedProcessingKind, title: String, subtitle: String,
                                           wantsGPU: Bool) -> ContinuedProcessingHandle? {
        let unavailable = String(localized: "ロック中の継続: 使えません")
        if UIApplication.shared.applicationState == .background {
            setDiagnostic(String(localized: "\(unavailable)(アプリが前面にないため開始できません)"))
            return nil
        }
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            setDiagnostic(String(localized: "\(unavailable)(バンドル ID を取得できません)"))
            return nil
        }
        let identifier = "\(bundleID).\(kind.rawValue).\(UUID().uuidString)"
        guard isPermitted(identifier) else {
            setDiagnostic(String(localized: "\(unavailable)(識別子 \(bundleID).\(kind.rawValue).… が Info.plist の BGTaskSchedulerPermittedIdentifiers で許可されていません)"))
            return nil
        }
        if registerCrashedBefore(.dynamic) {
            setDiagnostic(String(localized: "\(unavailable)(前回、起動ハンドラの登録または要求の送信中にアプリが終了したため、このビルドでは使いません)"))
            return nil
        }
        // register から submit が戻るまで印を残す(どちらかの途中で落ちたら、このビルドではもう試さない)
        setRegisterMarker(.dynamic, active: true)
        defer { setRegisterMarker(.dynamic, active: false) }
        guard registerLaunchHandler(for: identifier, slot: .dynamic, markerHeldByCaller: true) else {
            setDiagnostic(String(localized: "\(unavailable)(起動ハンドラを登録できませんでした)"))
            return nil
        }

        let handle = ContinuedProcessingHandle(kind: kind, identifier: identifier, title: title, subtitle: subtitle)
        lock.lock()
        activeHandles[identifier] = handle
        lock.unlock()

        let gpuSupported = BGTaskScheduler.supportedResources.contains(.gpu)
        var submitted = false
        var lastError: Error?
        if wantsGPU && gpuSupported {
            handle.setGPURequested(true)
            do {
                try submitRequest(identifier: identifier, title: title, subtitle: subtitle, gpu: true)
                submitted = true
            } catch {
                // GPU 付きで通らなければ GPU なしでやり直す
                handle.setGPURequested(false)
                lastError = error
            }
        }
        if !submitted {
            do {
                try submitRequest(identifier: identifier, title: title, subtitle: subtitle, gpu: false)
                submitted = true
            } catch {
                lastError = error
            }
        }
        guard submitted else {
            lock.lock()
            activeHandles.removeValue(forKey: identifier)
            lock.unlock()
            setDiagnostic("\(unavailable)(\(describe(lastError)))")
            return nil
        }

        let gpuText: String
        if !wantsGPU {
            gpuText = ""
        } else if handle.gpuGranted {
            gpuText = String(localized: "・GPU あり")
        } else if !gpuSupported {
            gpuText = String(localized: "・GPU なし(この端末・アプリでは非対応のため CPU で処理)")
        } else {
            gpuText = String(localized: "・GPU なし(許可されなかったため CPU で処理)")
        }
        let generation = setDiagnostic(String(localized: "ロック中の継続: 有効(\(kind.displayName)\(gpuText))"))

        // submit が通ってもシステムがタスクを開始しない場合に備えて、少し後に確認して記録する
        DispatchQueue.main.asyncAfter(deadline: .now() + launchTimeout) { [weak handle] in
            guard let handle, !handle.hasLaunchedOrFinished else { return }
            ContinuedProcessing.replaceDiagnostic(generation: generation,
                                                  with: String(localized: "\(unavailable)(要求は受け付けられましたが、システムが開始しませんでした)"))
        }
        return handle
    }

    @available(iOS 26.0, *)
    private static func submitRequest(identifier: String, title: String, subtitle: String, gpu: Bool) throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        if gpu {
            request.requiredResources = .gpu
        }
        try BGTaskScheduler.shared.submit(request)
    }

    /// 許可リストに一致する識別子だけ登録する(一致しない識別子の register は例外でクラッシュするため)。
    /// 同じ識別子の 2 回目の register も例外になるので、登録済みなら何もしない。
    /// markerHeldByCaller: 呼び出し側がすでに印を書いていて(確認も済み)、後で消す(begin は submit の後まで残す)
    @available(iOS 26.0, *)
    private static func registerLaunchHandler(for identifier: String, slot: RegisterSlot,
                                              markerHeldByCaller: Bool = false) -> Bool {
        guard isPermitted(identifier) else { return false }
        lock.lock()
        let alreadyRegistered = registeredIdentifiers.contains(identifier)
        lock.unlock()
        if alreadyRegistered { return true }
        if !markerHeldByCaller {
            if registerCrashedBefore(slot) { return false }
            setRegisterMarker(slot, active: true)
        }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            ContinuedProcessing.launch(task)
        }
        if !markerHeldByCaller {
            setRegisterMarker(slot, active: false)
        }
        if registered {
            lock.lock()
            registeredIdentifiers.insert(identifier)
            lock.unlock()
        }
        return registered
    }

    /// 起動ハンドラ(任意スレッド)
    @available(iOS 26.0, *)
    private static func launch(_ task: BGTask) {
        lock.lock()
        let handle = activeHandles[task.identifier]
        // ハンドルがあっても消しておく(開始と finish がほぼ同時のとき、結果だけが残らないように)
        let earlierResult = finishedResults.removeValue(forKey: task.identifier)
        lock.unlock()

        guard let handle, let continued = task as? BGContinuedProcessingTask else {
            // 処理がもう終わっている、または以前のバージョンの要求
            task.setTaskCompleted(success: earlierResult ?? false)
            return
        }
        handle.attach(continued)
    }
    #endif
}
