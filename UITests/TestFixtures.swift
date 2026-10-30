import Foundation
import SwiftUI
@testable import VideoEditor

/// テストで使う決まった中身(毎回同じ絵になるように)
enum TestFixtures {
    /// 長い台本(枠に収まらない長さ。以前はこれで描き直しが止まらなくなった)
    static let longScript: String = (1...24).map { i in
        "\(i). 今日はスマホ 1 台で撮った動画を、テンポよく編集するコツを紹介します。字幕は短く、1 行 12 文字くらいが読みやすいです。"
    }.joined(separator: "\n\n")

    /// テレプロンプター・カメラの設定を既定に戻す(@AppStorage が読む値)
    static func resetTeleprompterDefaults(script: String) {
        let defaults = UserDefaults.standard
        defaults.set(TeleprompterSpeed.normal.rawValue, forKey: TeleprompterSettingsKey.speed)
        defaults.set(TeleprompterFontSize.medium.rawValue, forKey: TeleprompterSettingsKey.fontSize)
        defaults.set(false, forKey: TeleprompterSettingsKey.mirror)
        defaults.set(script, forKey: TeleprompterSettingsKey.script)
        defaults.set(CameraCountdown.three.rawValue, forKey: TeleprompterSettingsKey.countdown)
        defaults.set(CameraFrameRate.fps30.rawValue, forKey: TeleprompterSettingsKey.frameRate)
        defaults.set(false, forKey: TeleprompterSettingsKey.usesFrontCamera)
    }
}
