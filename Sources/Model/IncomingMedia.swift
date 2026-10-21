import Foundation
import Observation

// =====================================================================
// 「共有」(ShareExtension)から送られてきた動画・写真の受け取り箱。
// 拡張機能は App Group の Inbox/<yyyyMMdd-HHmmss>-<UUID>/<NNN>-<元の名前> に書き込む(Shared/AppGroup.swift)。
// 書き込み中のフォルダは先頭に "." が付いた隠しフォルダで、全部書き終えると名前が変わって見えるようになる。
//
// アプリは起動時・前面に戻ったときに refresh() で読み直し、pendingURLs があれば取り込み方
// (新しいプロジェクトで編集 / 開いているプロジェクトに追加)を聞く。
// takeAll() で受け取ったファイルは、取り込む側が 1 件ずつ Media フォルダへ移し(移せなければコピー)、
// 1 件済むごとに discard(_:) で消す(途中でアプリが終了しても、取り込み済みのものをまた聞かないように)。
// キャンセルなどで取り込まなかったものは giveBack(_:) で返す(pendingURLs に戻り、あとでまた聞ける)。
// 7 日より古いフォルダ(取り込まれなかった共有・書き込みの途中で止まったもの)は refresh() が消す。
// =====================================================================

@MainActor
@Observable
final class IncomingMediaCenter {
    static let shared = IncomingMediaCenter()

    /// 届いたがまだ取り込んでいないファイル(古い順: フォルダ名の順 → ファイル名の順)
    private(set) var pendingURLs: [URL] = []

    /// 「新しいプロジェクトで編集」を選んだときに作ったプロジェクト。
    /// そのプロジェクトの編集画面は、聞かずに受け取ったファイルを取り込む
    var autoImportProjectID: UUID? = nil

    /// takeAll() で渡したが、まだ discard / giveBack されていないファイル(refresh で pendingURLs に戻さない)
    @ObservationIgnored private var handedOutPaths: Set<String> = []

    /// これより古い受け取りフォルダは消す(7 日)
    private static let staleInterval: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        refresh()
    }

    // MARK: - 読み込み

    /// Inbox を読み直す(軽い処理。起動時とアプリが前面に戻ったときに呼ぶ)
    func refresh() {
        guard let inbox = AppGroup.inboxURL else {
            setPending([])
            return
        }
        let fileManager = FileManager.default
        let folderKeys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: inbox,
                                                                 includingPropertiesForKeys: Array(folderKeys),
                                                                 options: []) else {
            setPending([])
            return
        }
        // 渡したファイルのうち、もうないもの(取り込み側で消した・Media フォルダへ移したもの)は忘れる
        handedOutPaths = handedOutPaths.filter { fileManager.fileExists(atPath: $0) }

        let now = Date()
        let fileKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var found: [URL] = []
        for folder in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? folder.resourceValues(forKeys: folderKeys)
            let folderPath = folder.path
            let inUse = handedOutPaths.contains { $0.hasPrefix(folderPath + "/") }

            // 7 日より古いもの(取り込まれなかった共有・書き込みの途中で止まったもの)は消す
            if !inUse, let date = values?.creationDate ?? values?.contentModificationDate,
               now.timeIntervalSince(date) > Self.staleInterval {
                try? fileManager.removeItem(at: folder)
                continue
            }
            // 隠しフォルダは拡張機能が書き込み中。フォルダでないものは扱わない
            guard values?.isDirectory == true, !folder.lastPathComponent.hasPrefix(".") else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(at: folder,
                                                                      includingPropertiesForKeys: fileKeys,
                                                                      options: [.skipsHiddenFiles]) else { continue }
            let visible = contents.filter { !$0.lastPathComponent.hasPrefix(".") }
            if visible.isEmpty {
                // 取り込みが終わって空になったフォルダは片づける
                if !inUse { try? fileManager.removeItem(at: folder) }
                continue
            }
            // 大きさ 0 のファイルはまだ書き込み中として無視する
            let ready = visible.filter { url in
                guard let fileValues = try? url.resourceValues(forKeys: Set(fileKeys)) else { return false }
                return fileValues.isRegularFile == true && (fileValues.fileSize ?? 0) > 0
            }
            for url in ready.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where !handedOutPaths.contains(url.path) {
                found.append(url)
            }
        }
        setPending(found)
    }

    // MARK: - 取り込み

    /// pendingURLs を返して空にする(ファイルは discard(_:) するまでディスクに残る)
    func takeAll() -> [URL] {
        let urls = pendingURLs
        for url in urls {
            handedOutPaths.insert(url.path)
        }
        setPending([])
        return urls
    }

    /// 取り込み終えた(または要らない)ファイルを消し、空になった受け取りフォルダも消す。
    /// Inbox の外のファイルは消さない
    func discard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fileManager = FileManager.default
        let inbox = AppGroup.inboxURL
        var removedPaths = Set<String>()
        var folders: [URL] = []
        for url in urls {
            removedPaths.insert(url.path)
            handedOutPaths.remove(url.path)
            guard let inbox, Self.isInInbox(url, inbox: inbox) else { continue }
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            let folder = url.deletingLastPathComponent()
            if !folders.contains(where: { $0.path == folder.path }) {
                folders.append(folder)
            }
        }
        for folder in folders {
            removeFolderIfEmpty(folder)
        }
        let remaining = pendingURLs.filter { !removedPaths.contains($0.path) }
        setPending(remaining)
    }

    /// takeAll() で渡したが取り込まなかったファイル(取り込みをキャンセルしたときなど)を返す。
    /// Inbox に残っているものは読み直して pendingURLs に戻る(あとでまた取り込み方を聞ける)
    func giveBack(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            handedOutPaths.remove(url.path)
        }
        refresh()
    }

    // MARK: - 内部

    private func setPending(_ urls: [URL]) {
        // 同じ内容なら書き換えない(画面の更新を減らす)
        if urls != pendingURLs {
            pendingURLs = urls
        }
    }

    /// 受け取りフォルダが空(隠しファイルしかない)なら消す
    private func removeFolderIfEmpty(_ folder: URL) {
        guard !folder.lastPathComponent.hasPrefix(".") else { return }
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        if names.allSatisfy({ $0.hasPrefix(".") }) {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// url が Inbox/<受け取りフォルダ>/<ファイル> の形かどうか
    private static func isInInbox(_ url: URL, inbox: URL) -> Bool {
        guard url.isFileURL, url.lastPathComponent != "..", url.lastPathComponent != "." else { return false }
        let batch = url.deletingLastPathComponent()
        guard batch.lastPathComponent != "..", !batch.lastPathComponent.hasPrefix(".") else { return false }
        let parent = batch.deletingLastPathComponent()
        if parent.path == inbox.path { return true }
        // /private/var と /var のような書き方の違いをそろえて比べる
        return parent.resolvingSymlinksInPath().path == inbox.resolvingSymlinksInPath().path
    }
}
