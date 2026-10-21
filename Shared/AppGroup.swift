import Foundation

// =====================================================================
// アプリ本体と「共有」の拡張機能(ShareExtension)が共有するフォルダ(App Group)。
// このファイルはアプリと拡張機能の両方のターゲットに入るので、Foundation だけを使う。
//
// 拡張機能は受け取った動画・写真を
//   Inbox/<yyyyMMdd-HHmmss>-<UUID>/<NNN>-<元の名前>
// に置く(書き込み中は先頭に "." を付けた隠しフォルダにしておき、書き終えてから名前を変える)。
// アプリは IncomingMediaCenter(Sources/Model/IncomingMedia.swift)で読み込み、取り込んだら消す。
// =====================================================================

enum AppGroup {
    static let identifier = "group.com.yuyaogawa6960.videomania"

    /// App Group の共有フォルダ(エンタイトルメントがないときは nil)
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 共有から受け取ったファイルの置き場所(containerURL/Inbox。なければ作る)
    static var inboxURL: URL? {
        guard let container = containerURL else { return nil }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: inbox.path) {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
    }
}
