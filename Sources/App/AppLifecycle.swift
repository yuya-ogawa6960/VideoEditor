import Foundation
import UIKit

/// アプリのフォアグラウンド / バックグラウンド状態を管理する。
/// `isInBackground` / `backgroundGPUAllowed` はどのスレッドからでも読める(NSLock で保護)。
/// 合成エンジン(Team A)はこれを見て GPU / CPU の CIContext を切り替える。
final class AppLifecycle {
    static let shared = AppLifecycle()

    private let lock = NSLock()
    private var backgroundFlag = false
    private var gpuAllowedFlag = false
    private var started = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 現在バックグラウンドにいるか(スレッドセーフ)
    var isInBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgroundFlag
    }

    /// バックグラウンドでも GPU を使ってよいか(スレッドセーフ)。
    /// iOS 26+ の継続処理(ContinuedProcessing)で GPU の使用が許可されたタスクが動いている間だけ true。
    /// ContinuedProcessing が設定する。
    var backgroundGPUAllowed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return gpuAllowedFlag
        }
        set {
            lock.lock()
            gpuAllowedFlag = newValue
            lock.unlock()
        }
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

        // 以前のバージョンが固定の識別子で submit した要求のためのハンドラ(すぐ完了させるだけ)。
        // 許可リストに無い識別子は登録しないので、AltStore でバンドル ID が書き換えられていても落ちない。
        // 書き出し・文字起こしの継続処理は、開始時に ContinuedProcessing.begin が識別子ごとに登録する。
        ContinuedProcessing.registerLegacyLaunchHandler()

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
            // バックグラウンドでは再生しない(audio のバックグラウンドモードは無い)ので、
            // 音声セッションを手放して他のアプリ(音楽など)の再生を再開させる
            AudioSessionSetup.release()
        }
        let willEnterForeground = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.setInBackground(false)
            // 他のアプリや広告の再生でカテゴリが変わっていても、戻ったら再生用に戻す
            AudioSessionSetup.ensurePlayback()
        }
        let didBecomeActive = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            self?.setInBackground(false)
        }
        observers.append(contentsOf: [enterBackground, willEnterForeground, didBecomeActive])

        // 起動直後の状態(バックグラウンド起動の場合に備える)
        setInBackground(UIApplication.shared.applicationState == .background)
    }
}
