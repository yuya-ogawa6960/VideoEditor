import Foundation
import UIKit
import BackgroundTasks

/// アプリのフォアグラウンド / バックグラウンド状態を管理する。
/// `isInBackground` はどのスレッドからでも読める(NSLock で保護)。
/// 合成エンジン(Team A)はこれを見て GPU / CPU の CIContext を切り替える。
final class AppLifecycle {
    static let shared = AppLifecycle()

    /// BGContinuedProcessingTask(iOS 26+)の識別子。Info.plist の BGTaskSchedulerPermittedIdentifiers に必要。
    static let exportTaskIdentifier = "com.personal.videoeditor.export"

    private let lock = NSLock()
    private var backgroundFlag = false
    private var started = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 現在バックグラウンドにいるか(スレッドセーフ)
    var isInBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgroundFlag
    }

    private func setInBackground(_ value: Bool) {
        lock.lock()
        backgroundFlag = value
        lock.unlock()
    }

    /// App.init から一度だけ呼ぶ。
    /// BGTaskScheduler への登録はアプリの起動完了前に行う必要があるため、ここで同期的に行う。
    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        registerBackgroundTasks()

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.installObservers()
            }
        } else {
            Task { @MainActor in
                self.installObservers()
            }
        }
    }

    @MainActor
    private func installObservers() {
        let center = NotificationCenter.default
        let enterBackground = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            self?.setInBackground(true)
        }
        let willEnterForeground = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.setInBackground(false)
        }
        let didBecomeActive = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            self?.setInBackground(false)
        }
        observers.append(contentsOf: [enterBackground, willEnterForeground, didBecomeActive])

        // 起動直後の状態(バックグラウンド起動の場合に備える)
        setInBackground(UIApplication.shared.applicationState == .background)
    }

    private func registerBackgroundTasks() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // iOS 26 以降: 書き出しをバックグラウンドで継続するための BGContinuedProcessingTask。
            // ExportManager が書き出し開始時に BGContinuedProcessingTaskRequest を submit し、
            // システムがこのハンドラを呼ぶ。進捗報告と完了通知は ExportManager が行う。
            _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: AppLifecycle.exportTaskIdentifier,
                                                using: nil) { task in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                ExportManager.shared.attachContinuedProcessingTask(continued)
            }
        }
        #endif
    }
}
