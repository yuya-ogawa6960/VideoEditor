import Foundation
import os

// =====================================================================
// アプリの保存先を 1 か所で決める。
//
//   Library/Application Support/           … アプリ内部のデータ(「ファイル」アプリには出ない。iCloud バックアップに入る)
//     Projects/<uuid>/project.json         … 編集内容(ProjectStore)。素材はファイル名だけで持つ
//     Projects/library.json                … プロジェクト一覧(ProjectLibrary)
//     Media/<UUID>_<元の名前>              … 取り込んだ素材(MediaStore)。Media/LUTs、Media/Fonts もここ
//     Caches/                              … 作り直せるもの(バックアップから除外)
//     presets.json / formats.json / text_styles.json … 書き出しプリセット・書式・文字スタイル
//     WhisperKit/                          … 文字起こしのモデル(数百 MB。ダウンロードし直せるのでバックアップから除外)
//   Documents/                             … UIFileSharingEnabled のため「ファイル」アプリに見える。ユーザーの作品だけ置く
//     Exports/                             … 書き出した動画(ExportManager)。ここに残すのは意図的
//     Inbox/                               … AirDrop・「Video Mania で開く」で iOS がコピーしてくる(アプリは作らない・移さない)
//   Library/Caches/                        … サムネイル・LUT・効果音などの一時キャッシュ(OS が容量不足のとき消してよいもの)。
//                                             各自 FileManager の .cachesDirectory を使う
//   tmp/                                   … 書き出し中の作業ファイルなど
//   App Group(Shared/AppGroup.swift)      … 「共有」の拡張機能が受け取った動画・写真を置く Inbox。
//                                             拡張機能はこのファイルを含まない(Shared だけ)ので、ここでは触らない
//
// 1.12.68 まではプロジェクト・素材・プリセットも Documents にあった。1.12.69 で Application Support へ移すようにし、
// このファイル(prepare)が起動の最初に、まだ Documents に残っているものを移す。
// 保存データは素材をファイル名だけで参照している(ProjectStore.resolveMedia / MediaStore.uniqueDestination)ので、
// フォルダごと移せばそのまま開ける。絶対パスを保存している場所はない(1.12.80 時点で確認)。
// =====================================================================

enum AppDirectories {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VideoMania", category: "Storage")

    // MARK: - 置き場所(無ければ作る)

    /// Library/Application Support
    static var applicationSupport: URL {
        ensureDirectory(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Application Support/Projects(ProjectStore)
    static var projects: URL {
        ensureDirectory(applicationSupport.appendingPathComponent("Projects", isDirectory: true))
    }

    /// Application Support/Media(MediaStore)
    static var media: URL {
        ensureDirectory(applicationSupport.appendingPathComponent("Media", isDirectory: true))
    }

    /// Application Support/Caches。作り直せるが OS に勝手に消されては困るもの(iCloud バックアップには入れない)。
    /// 容量不足のとき OS が消してよいものは FileManager の .cachesDirectory を使う
    static var caches: URL {
        let url = applicationSupport.appendingPathComponent("Caches", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            ensureDirectory(url)
            excludeFromBackup(url)
        }
        return url
    }

    /// Documents。「ファイル」アプリに見えるので、ユーザーの作品(Exports)以外は置かない
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Documents/Inbox(AirDrop などで iOS がコピーしてくる受け取り場所。作らない)
    static var documentsInbox: URL {
        documents.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Application Support/WhisperKit(文字起こしのモデル。バックアップから除外)
    static var whisperModels: URL {
        applicationSupport.appendingPathComponent("WhisperKit", isDirectory: true)
    }

    /// フォルダが無ければ作る(作れなくてもログを出して URL は返す)
    @discardableResult
    static func ensureDirectory(_ url: URL) -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.error("フォルダを作れません: \(url.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    /// iCloud バックアップから除外する(ダウンロードし直せるもの用)
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            logger.error("バックアップ除外にできません: \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 起動時(ほかの保存先を使う前に 1 回だけ呼ぶ)

    /// 起動の最初に呼ぶ。Documents に残っている内部データを Application Support へ移し、
    /// バックアップから除外するフォルダに印を付ける。プロジェクトを開く前・保存先を使う前に終わる
    static func prepare() {
        migrateFromDocumentsIfNeeded()
        excludeFromBackup(caches)
        excludeFromBackup(ensureDirectory(whisperModels))
    }

    // MARK: - Documents → Application Support の移行

    /// Documents 直下から移すもの。Exports(作品)と Inbox(iOS の受け取り場所)は移さない
    static let migratedItemNames = ["Projects", "Media", "presets.json", "formats.json"]

    /// 移し終わった印(これが立っていれば Documents を見に行かない。
    /// 「ファイル」アプリでユーザーが後から Documents に置いた同名のフォルダを勝手に取り込まないため)
    private static let completedKey = "storage.migration.documentsToApplicationSupport.v2"
    /// 1.12.69〜1.12.77 の移行(StorageLocations)が立てた印。立っていれば移し終えている
    private static let legacyCompletedKey = "storage.movedToApplicationSupport.v1"

    /// 移行の結果(ログと確認用)
    struct MigrationReport: Equatable {
        /// 移したファイルの数(フォルダごと移したときは中のファイルも数える)
        var movedFiles = 0
        /// ひとまとまりで移したフォルダの数
        var movedDirectories = 0
        /// 移し先にもうあったので中身を 1 つずつ合わせたフォルダの数(前回の途中で止まったとき)
        var mergedDirectories = 0
        /// 同じ名前のファイルが両方にあり、Documents 側を消さずに残した数
        var keptInPlace = 0
        /// 移せなかった数(次の起動でやり直す)
        var failed = 0

        /// 失敗がなければ終わり(同名で残したものがあっても、それ以上は触らない)
        var isComplete: Bool { failed == 0 }
        var didMoveAnything: Bool { movedFiles + movedDirectories + mergedDirectories > 0 }
    }

    /// 最後に行った移行の結果(なければ nil。まだ 1 度も動いていない・印だけで済んだとき)
    private(set) static var lastMigrationReport: MigrationReport?

    /// Documents に残っている内部データを Application Support へ移す。
    /// - 同じボリューム内の rename なので 1 つずつが原子的。途中で落ちても、次の起動で続きから移す
    /// - 何度呼んでも安全。終わったら UserDefaults に印を付けて、以降は Documents を見ない
    /// - 失敗しても何も消さない(移し先にあるものを上書きもしない)
    @discardableResult
    static func migrateFromDocumentsIfNeeded() -> MigrationReport? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: completedKey) {
            return nil
        }
        if defaults.bool(forKey: legacyCompletedKey) {
            defaults.set(true, forKey: completedKey)
            logger.info("Documents → Application Support: 1.12.69 以降の版で移し終えている")
            return nil
        }

        let started = Date()
        let fm = FileManager.default
        let destinationRoot = applicationSupport
        var report = MigrationReport()
        for name in migratedItemNames {
            let from = documents.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { continue }
            move(from, to: destinationRoot.appendingPathComponent(name), report: &report)
        }

        let elapsed = Date().timeIntervalSince(started)
        if report.didMoveAnything || report.failed > 0 || report.keptInPlace > 0 {
            logger.notice("""
                Documents → Application Support: ファイル \(report.movedFiles) ・フォルダ \(report.movedDirectories) を移動、\
                続きを合わせたフォルダ \(report.mergedDirectories)、同名で残した \(report.keptInPlace)、失敗 \(report.failed)\
                (\(String(format: "%.2f", elapsed), privacy: .public) 秒)
                """)
        } else {
            logger.info("Documents → Application Support: 移すものなし")
        }
        if report.isComplete {
            defaults.set(true, forKey: completedKey)
        } else {
            logger.error("Documents → Application Support: 移せなかったものがあるので次の起動でやり直す")
        }
        lastMigrationReport = report
        return report
    }

    /// from を to へ移す。
    /// - to が無ければ rename(フォルダなら中身ごと 1 回で)
    /// - 両方フォルダなら中身を 1 つずつ移す(前回の途中で止まったとき)。空になった from だけ消す
    /// - 同じ名前のファイルが両方にあれば、移し先(移行後にアプリが書いた新しい方)を残し、from は消さずに置く
    private static func move(_ from: URL, to: URL, report: inout MigrationReport) {
        let fm = FileManager.default
        var fromIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &fromIsDirectory) else { return }
        var toIsDirectory: ObjCBool = false
        let toExists = fm.fileExists(atPath: to.path, isDirectory: &toIsDirectory)

        if !toExists {
            let fileCount = fromIsDirectory.boolValue ? regularFileCount(in: from) : 1
            do {
                try fm.moveItem(at: from, to: to)
                report.movedFiles += fileCount
                if fromIsDirectory.boolValue { report.movedDirectories += 1 }
            } catch {
                report.failed += 1
                logger.error("移せません: \(from.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        guard fromIsDirectory.boolValue, toIsDirectory.boolValue else {
            report.keptInPlace += 1
            logger.notice("同じ名前が両方にあるので Documents 側を残す: \(from.lastPathComponent, privacy: .public)")
            return
        }

        report.mergedDirectories += 1
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil, options: [])
        } catch {
            report.failed += 1
            logger.error("中身を読めません: \(from.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return
        }
        for child in children {
            move(child, to: to.appendingPathComponent(child.lastPathComponent), report: &report)
        }
        if let rest = try? fm.contentsOfDirectory(atPath: from.path), rest.isEmpty {
            try? fm.removeItem(at: from)
        }
    }

    /// フォルダの中の(入れ子も含む)ファイルの数。ログ用
    private static func regularFileCount(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: []) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}
