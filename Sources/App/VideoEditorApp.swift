import SwiftUI
import UIKit

@main
struct VideoEditorApp: App {
    /// 背景 URLSession(クラウド文字起こしの送信)の完了でアプリが起こされたときのイベントを受け取る
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 保存先の用意。Documents に残っている内部データを Application Support へ移す
        // (1 回だけ。プロジェクトを開く前・ほかの保存先を使う前に終わる。Sources/Engine/AppDirectories.swift)
        AppDirectories.prepare()
        AppLifecycle.shared.start()
        // マナーモードでも動画の音が鳴るように(.playback)
        AudioSessionSetup.ensurePlayback()
        // 使い方の統計(匿名。設定で止められる)
        Analytics.shared.start()
        // 動作の重さ・落ちた回数(Apple が 1 日に 1 回ほどまとめて届ける)も統計に送る
        MetricsReporter.shared.start()
        // クラウド文字起こしの背景セッションをつなぎ直す(前回の起動中に送ったピースの結果を受け取れるように)
        CloudBackgroundUploader.shared.activate()
        // 「Apple でサインイン」がやめられていないか(設定 → Apple アカウント)を確かめる。
        // 前面に戻るたびの確認と、やめられたときの通知は AccountService が受け取る
        Task { @MainActor in
            await AccountService.shared.verifyAppleCredential()
        }
        // フィルタの LUT をバックグラウンドで先に作っておく(初回表示のもたつき防止)
        Task.detached(priority: .utility) { FilterLUT.prewarm() }
        // 読み込んだフォント(.ttf / .otf)を起動時に登録する
        Task.detached(priority: .utility) { MediaTools.registerStoredFonts() }
        // 前回までのドラッグ&ドロップの一時フォルダを消す
        Task.detached(priority: .utility) { MediaDrop.cleanUpTemporaryFolders() }
        // 「書き出した動画を自動で消す」(設定)。選んだ日数より古い Documents/Exports の動画を消す
        Task { @MainActor in ExportFileStore.runAutomaticCleanup() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .modifier(OrientationRefresher())
        }
    }
}

/// UIKit のアプリデリゲート(SwiftUI の App から @UIApplicationDelegateAdaptor で使う)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 画面の向き(ふだんはたて固定。全画面プレビューのときだけ横。iPhone Duo を開いたときは固定しない)
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.supportedMask
    }

    /// 背景 URLSession の転送が終わり、アプリが(終了していても)バックグラウンドで起こされたとき。
    /// 同じ識別子のセッションを作り直して(CloudBackgroundUploader.shared)完了ハンドラを預ける。
    /// ハンドラはすべてのイベントを受け取り終えたとき(urlSessionDidFinishEvents)にメインスレッドで呼ばれる
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        CloudBackgroundUploader.shared.handleEventsForBackgroundURLSession(identifier: identifier,
                                                                         completionHandler: completionHandler)
    }
}
