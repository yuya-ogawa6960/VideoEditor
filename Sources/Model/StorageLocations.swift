import Foundation

// =====================================================================
// アプリの作業ファイルの置き場所。
// 取り込んだ素材(Media)・プロジェクト(Projects)・書き出しの設定・書式は Application Support に置く
// (「ファイル」アプリには出さない)。書き出した動画(Exports)だけはユーザーの作品なので Documents に残す。
// 1.12.68 までは全部 Documents にあったので、起動したときに 1 回だけ移す。
// 保存データは素材をファイル名だけで持っている(ProjectStore.resolveMedia)ので、フォルダごと移せばそのまま開ける。
// =====================================================================

enum StorageLocations {
    /// Application Support(無ければ作る)
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Documents から移すもの
    private static let movedItems = ["Media", "Projects", "presets.json", "formats.json"]
    private static let movedKey = "storage.movedToApplicationSupport.v1"

    /// 起動の最初に呼ぶ(ほかの保存先を使う前)。移し終わるまで、起動のたびにやり直す
    static func prepare() {
        if !UserDefaults.standard.bool(forKey: movedKey) {
            var allMoved = true
            for name in movedItems {
                let from = documents.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                if !move(from, to: applicationSupport.appendingPathComponent(name)) {
                    allMoved = false
                }
            }
            if allMoved {
                UserDefaults.standard.set(true, forKey: movedKey)
            }
        }
        // 文字起こしのモデル(数百 MB。いつでもダウンロードし直せる)は iCloud バックアップに入れない
        let models = applicationSupport.appendingPathComponent("WhisperKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        excludeFromBackup(models)
    }

    /// from を to へ移す。to がもうあれば(前回の途中で止まったなど)、中身を 1 つずつ足す。
    /// 同じ名前がどちらにもあるときは、移した先(新しい方)を残し、元は消さずに置いておく
    private static func move(_ from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: to.path) {
            do {
                try fm.moveItem(at: from, to: to)
                return true
            } catch {
                return false
            }
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return true
        }
        guard let children = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else {
            return false
        }
        var allMoved = true
        for child in children {
            if !move(child, to: to.appendingPathComponent(child.lastPathComponent)) {
                allMoved = false
            }
        }
        // 空になった元のフォルダは消す(同じ名前が残ったときは残す)
        if let rest = try? fm.contentsOfDirectory(atPath: from.path), rest.isEmpty {
            try? fm.removeItem(at: from)
        }
        return allMoved
    }

    private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
