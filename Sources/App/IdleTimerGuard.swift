import UIKit

/// 長い処理(文字起こし・書き出し・モデルのダウンロード)の間だけ、画面の自動ロックを止める。
/// 自動ロックでアプリが一時停止すると通信が切れて処理が止まるため。
/// 複数の処理が同時に動いても、全部終わるまで解除しない。
@MainActor
enum IdleTimerGuard {
    private static var holders: Set<String> = []

    static func set(_ active: Bool, for key: String) {
        if active {
            holders.insert(key)
        } else {
            holders.remove(key)
        }
        UIApplication.shared.isIdleTimerDisabled = !holders.isEmpty
    }
}
