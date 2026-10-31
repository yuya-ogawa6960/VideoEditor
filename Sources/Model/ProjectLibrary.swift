import Foundation
import Observation
import UIKit

// =====================================================================
// プロジェクト一覧(CapCut のホーム画面に相当)のメタデータ。
// 編集内容そのものは ProjectStore が Application Support/Projects/<uuid>/ に保存し、
// ここでは名前・日時・長さ・クリップ数だけを Application Support/Projects/library.json に持つ。
// `projects` は常に updatedAt の新しい順。
// 書き込みは touch() のような頻繁な更新は 1 秒にまとめ、作成/削除などはすぐに行う。
// =====================================================================

struct ProjectMeta: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// 出力タイムラインの長さ(秒)
    var duration: Double
    var clipCount: Int
    /// 動画の置き場所(後から追加したので、古いデータでは nil = アプリに取り込む)
    var mediaMode: ProjectMediaMode? = nil

    var effectiveMediaMode: ProjectMediaMode { mediaMode ?? .appCopy }
}

private struct LibraryFile: Codable {
    var version = 1
    var projects: [ProjectMeta]
}

@Observable
final class ProjectLibrary {
    static let shared = ProjectLibrary()

    /// updatedAt の新しい順
    private(set) var projects: [ProjectMeta] = []

    /// サムネイルが書き換わったことを一覧に知らせるためのカウンタ(表示の再読み込み用)
    private(set) var thumbnailRevision: Int = 0

    @ObservationIgnored private var writeQueue = DispatchQueue(label: "ProjectLibrary.write", qos: .utility)
    @ObservationIgnored private var lock = NSLock()
    @ObservationIgnored private var pendingWrite: DispatchWorkItem?

    static var libraryURL: URL {
        ProjectStore.projectsDirectory.appendingPathComponent("library.json")
    }

    private init() {
        reload()
    }

    // MARK: - 読み込み

    /// library.json を読み直す。一覧にないプロジェクトフォルダの拾い上げと、
    /// 旧バージョン(current.json)からの移行もここで行う
    func reload() {
        flush()
        var list: [ProjectMeta] = []
        if let data = try? Data(contentsOf: Self.libraryURL),
           let file = try? JSONDecoder().decode(LibraryFile.self, from: data) {
            list = file.projects
        }
        var changed = false

        // フォルダはあるが一覧に載っていないプロジェクト(一覧の保存失敗など)を拾う
        let known = Set(list.map { $0.id })
        for id in ProjectStore.storedProjectIDs() where !known.contains(id) {
            let dates = ProjectStore.fileDates(projectID: id)
            let snapshot = ProjectStore.load(projectID: id)
            let now = Date()
            list.append(ProjectMeta(id: id,
                                    name: String(localized: "復元されたプロジェクト"),
                                    createdAt: dates.created ?? now,
                                    updatedAt: dates.modified ?? now,
                                    duration: snapshot?.totalDuration ?? 0,
                                    clipCount: snapshot?.clips.count ?? 0))
            changed = true
        }

        // 旧バージョン(単一プロジェクト)からの移行:一覧が空のときだけ取り込む
        if list.isEmpty, ProjectStore.hasLegacyProject {
            let id = UUID()
            if let imported = ProjectStore.importLegacyProject(into: id) {
                let now = Date()
                list.append(ProjectMeta(id: id,
                                        name: String(localized: "以前の編集"),
                                        createdAt: imported.createdAt ?? now,
                                        updatedAt: imported.modifiedAt ?? now,
                                        duration: imported.snapshot.totalDuration,
                                        clipCount: imported.snapshot.clips.count))
                changed = true
                generateThumbnailIfMissing(projectID: id, snapshot: imported.snapshot)
            }
        }

        projects = Self.sorted(list)
        if changed {
            writeNow()
        }
    }

    func project(id: UUID) -> ProjectMeta? {
        projects.first(where: { $0.id == id })
    }

    // MARK: - 作成 / 変更 / 削除

    /// 新しい空のプロジェクトを作る。名前を省略すると「プロジェクト N」
    @discardableResult
    func create(name: String? = nil, mediaMode: ProjectMediaMode? = nil) -> ProjectMeta {
        let now = Date()
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = ProjectMeta(id: UUID(),
                               name: trimmed.isEmpty ? defaultName() : trimmed,
                               createdAt: now,
                               updatedAt: now,
                               duration: 0,
                               clipCount: 0,
                               mediaMode: mediaMode)
        ProjectStore.ensureProjectDirectory(projectID: meta.id)
        projects.insert(meta, at: 0)
        writeNow()
        return meta
    }

    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = projects.firstIndex(where: { $0.id == id }),
              projects[i].name != trimmed else { return }
        projects[i].name = trimmed
        writeNow()
    }

    /// 編集内容とサムネイルをコピーした新しいプロジェクトを作る(素材ファイルは共有)
    @discardableResult
    func duplicate(id: UUID) -> ProjectMeta? {
        guard let source = projects.first(where: { $0.id == id }) else { return nil }
        let now = Date()
        let copy = ProjectMeta(id: UUID(),
                               name: duplicateName(for: source.name),
                               createdAt: now,
                               updatedAt: now,
                               duration: source.duration,
                               clipCount: source.clipCount,
                               mediaMode: source.mediaMode)
        guard ProjectStore.copyProjectFiles(from: source.id, to: copy.id) else {
            ProjectStore.delete(projectID: copy.id)
            return nil
        }
        projects.insert(copy, at: 0)
        writeNow()
        return copy
    }

    /// 動画の置き場所を変える(これから取り込む動画に使う。取り込み済みの動画はそのまま)
    func setMediaMode(id: UUID, to mode: ProjectMediaMode) {
        guard let i = projects.firstIndex(where: { $0.id == id }),
              projects[i].mediaMode != mode else { return }
        projects[i].mediaMode = mode
        writeNow()
    }

    /// 一覧から外し、保存フォルダも削除する(素材ファイルは消さない)
    func delete(id: UUID) {
        projects.removeAll { $0.id == id }
        ProjectStore.delete(projectID: id)
        writeNow()
    }

    /// 編集のたびに呼ぶ。更新日時・長さ・クリップ数を更新し、先頭に移動する(書き込みはまとめて行う)
    func touch(id: UUID, duration: Double, clipCount: Int) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        var meta = projects[i]
        meta.updatedAt = Date()
        meta.duration = duration.isFinite ? max(0, duration) : 0
        meta.clipCount = clipCount
        if i == 0 {
            projects[0] = meta
        } else {
            projects.remove(at: i)
            projects.insert(meta, at: 0)
        }
        scheduleWrite()
    }

    /// サムネイルを書き換えたあとに呼ぶと、表示中の一覧が読み直す
    func noteThumbnailChanged() {
        thumbnailRevision &+= 1
    }

    // MARK: - 名前

    private func defaultName() -> String {
        let existing = Set(projects.map { $0.name })
        var n = projects.count + 1
        var candidate = String(localized: "プロジェクト \(n)")
        while existing.contains(candidate) {
            n += 1
            candidate = String(localized: "プロジェクト \(n)")
        }
        return candidate
    }

    private func duplicateName(for name: String) -> String {
        let existing = Set(projects.map { $0.name })
        let base = String(localized: "\(name) のコピー")
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private static func sorted(_ list: [ProjectMeta]) -> [ProjectMeta] {
        list.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - サムネイル(移行したプロジェクト用)

    private func generateThumbnailIfMissing(projectID: UUID, snapshot: ProjectSnapshot) {
        guard let clip = snapshot.clips.first,
              !ProjectStore.hasThumbnail(projectID: projectID) else { return }
        let url = clip.url
        let time = clip.startTime
        Task {
            guard let image = await MediaStore.thumbnail(for: url, at: time, maxPixel: 400) else { return }
            ProjectStore.saveThumbnail(image, projectID: projectID)
            await MainActor.run {
                self.noteThumbnailChanged()
            }
        }
    }

    // MARK: - 書き込み

    private func scheduleWrite() {
        let copy = projects
        let item = DispatchWorkItem { Self.write(copy) }
        lock.lock()
        pendingWrite?.cancel()
        pendingWrite = item
        lock.unlock()
        writeQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func writeNow() {
        lock.lock()
        pendingWrite?.cancel()
        pendingWrite = nil
        lock.unlock()
        let copy = projects
        writeQueue.sync { Self.write(copy) }
    }

    /// まとめ書き待ちの変更があればいま書き込む(バックグラウンド移行時など)
    func flush() {
        lock.lock()
        let pending = pendingWrite
        pendingWrite = nil
        lock.unlock()
        guard let pending else { return }
        pending.cancel()
        let copy = projects
        writeQueue.sync { Self.write(copy) }
    }

    private static func write(_ list: [ProjectMeta]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LibraryFile(projects: list))
            try data.write(to: libraryURL, options: .atomic)
        } catch {
            print("ProjectLibrary: write failed: \(error)")
        }
    }
}
