import SwiftUI
import UIKit

@main
struct VideoEditorApp: App {
    /// 背景 URLSession(クラウド文字起こしの送信)の完了でアプリが起こされたときのイベントを受け取る
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppLifecycle.shared.start()
        // クラウド文字起こしの背景セッションをつなぎ直す(前回の起動中に送ったピースの結果を受け取れるように)
        CloudBackgroundUploader.shared.activate()
        // フィルタの LUT をバックグラウンドで先に作っておく(初回表示のもたつき防止)
        Task.detached(priority: .utility) { FilterLUT.prewarm() }
        // 読み込んだフォント(.ttf / .otf)を起動時に登録する
        Task.detached(priority: .utility) { MediaTools.registerStoredFonts() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// UIKit のアプリデリゲート(SwiftUI の App から @UIApplicationDelegateAdaptor で使う)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 画面の向き(ふだんはたて固定。全画面プレビューのときだけ横)
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.mask
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
