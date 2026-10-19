import Foundation
import UIKit

// =====================================================================
// プロジェクトの持ち出し・持ち込み(.videomania パッケージ)。
//   <名前>.videomania/
//     package.json    … 名前・書き出し日時・長さなど(無くても読める)
//     project.json    … ProjectStore と同じ形式(素材はファイル名で参照)
//     thumbnail.jpg   … 一覧用サムネイル(あれば)
//     media/<素材ファイル>        … 参照している素材(名前はそのまま)
//     media/LUTs/<名前>.cube     … 参照している LUT
// 書き出しは temporaryDirectory/VideoManiaPackages/<uuid>/ にフォルダとして作る
// (ShareLink(item: URL) でそのまま共有できる)。
// 読み込みは素材を MediaStore.mediaDirectory にコピーし(同名で同じ大きさなら使い回し、
// 違えば MediaStore.uniqueDestination で別名にして project.json を書き換え)、
// 新しいプロジェクト ID で ProjectLibrary.shared に登録する。
// =====================================================================

enum ProjectPackageError: LocalizedError {
    case projectNotFound
    case notAPackage
    case invalidProjectFile
    case cannotAccess

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "プロジェクトの保存ファイルが見つかりません。"
        case .notAPackage:
            return "「.videomania」フォルダ(中に project.json があるもの)を選んでください。"
        case .invalidProjectFile:
            return "project.json を読み取れませんでした。新しいバージョンの Video Mania で作られた可能性があります。"
        case .cannotAccess:
            return "ファイルにアクセスできませんでした。"
        }
    }
}

enum ProjectPackage {
    static let packageExtension = "videomania"
    static let mediaFolderName = "media"
    static let lutFolderName = "LUTs"
    static let infoFileName = "package.json"
    static let formatVersion = 1

    /// 書き出したパッケージを置くフォルダ(temporaryDirectory 内)
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VideoManiaPackages", isDirectory: true)
    }

    private struct PackageInfo: Codable {
        var formatVersion: Int
        var app: String
        var name: String
        var exportedAt: Date
        var duration: Double
        var clipCount: Int
    }

    // MARK: - 書き出し

    /// プロジェクトを <名前>.videomania フォルダにまとめて、その URL を返す。
    /// progress は 0...1 でメインスレッドに呼ばれる(素材のコピー量ベース)
    static func export(projectID: UUID, progress: ((Double) -> Void)?) async throws -> URL {
        let meta: ProjectMeta? = await MainActor.run { ProjectLibrary.shared.project(id: projectID) }
        guard let projectData = ProjectStore.projectFileData(projectID: projectID) else {
            throw ProjectPackageError.projectNotFound
        }
        let references: ProjectStore.MediaReferences
        do {
            references = try ProjectStore.mediaReferences(inProjectFileData: projectData)
        } catch {
            throw ProjectPackageError.invalidProjectFile
        }
        let snapshot = ProjectStore.snapshot(fromProjectFileData: projectData)
        let info = PackageInfo(formatVersion: formatVersion,
                               app: "Video Mania",
                               name: meta?.name ?? "プロジェクト",
                               exportedAt: Date(),
                               duration: meta?.duration ?? snapshot?.totalDuration ?? 0,
                               clipCount: meta?.clipCount ?? snapshot?.clips.count ?? 0)
        let thumbnailURL = ProjectStore.thumbnailURL(projectID: projectID)
        return try await offMain {
            try buildPackage(projectData: projectData, info: info, references: references,
                             thumbnailURL: thumbnailURL, progress: progress)
        }
    }

    /// 書き出したパッケージ(temporaryDirectory 内)をすべて消す(共有が終わったあとなど)
    static func cleanUpExportedPackages() {
        let dir = exportDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func buildPackage(projectData: Data, info: PackageInfo, references: ProjectStore.MediaReferences,
                                     thumbnailURL: URL, progress: ((Double) -> Void)?) throws -> URL {
        let fm = FileManager.default
        let container = exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let package = container.appendingPathComponent("\(safeFileName(info.name)).\(packageExtension)", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let mediaDir = package.appendingPathComponent(mediaFolderName, isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        try projectData.write(to: package.appendingPathComponent(ProjectStore.projectFileName), options: .atomic)
        if fm.fileExists(atPath: thumbnailURL.path) {
            try? fm.copyItem(at: thumbnailURL, to: package.appendingPathComponent(ProjectStore.thumbnailFileName))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: package.appendingPathComponent(infoFileName), options: .atomic)

        // コピーする素材(生成した単色 PNG は読み込み側で作り直すので、mediaDirectory に無いものは入れない)
        var jobs: [(source: URL, destination: URL)] = []
        for name in references.mediaFileNames {
            if let url = ProjectStore.resolveMedia(name) {
                jobs.append((url, mediaDir.appendingPathComponent(name)))
            }
        }
        if !references.lutFileNames.isEmpty {
            let lutDir = mediaDir.appendingPathComponent(lutFolderName, isDirectory: true)
            var created = false
            for name in references.lutFileNames {
                guard let url = ProjectStore.resolveLUT(name) else { continue }
                if !created {
                    try fm.createDirectory(at: lutDir, withIntermediateDirectories: true)
                    created = true
                }
                jobs.append((url, lutDir.appendingPathComponent(name)))
            }
        }

        let totalBytes = max(Int64(1), jobs.reduce(Int64(0)) { $0 + fileSize($1.source) })
        var copiedBytes: Int64 = 0
        report(progress, 0)
        for job in jobs {
            // 同じ名前は一度だけ
            if fm.fileExists(atPath: job.destination.path) { continue }
            try fm.copyItem(at: job.source, to: job.destination)
            copiedBytes += fileSize(job.source)
            report(progress, Double(copiedBytes) / Double(totalBytes))
        }
        report(progress, 1)
        return package
    }

    // MARK: - 読み込み

    private struct PreparedImport {
        let name: String
        let projectData: Data
        let thumbnailData: Data?
        let duration: Double
        let clipCount: Int
    }

    /// .videomania フォルダ(または中の project.json)を読み込み、新しいプロジェクトとして一覧に登録して返す
    static func importPackage(from url: URL) async throws -> ProjectMeta {
        let prepared = try await offMain { try prepare(url) }
        return try await MainActor.run { try register(prepared) }
    }

    private static func prepare(_ url: URL) throws -> PreparedImport {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        var result: PreparedImport?
        var innerError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            do {
                result = try prepareUnsafe(readURL)
            } catch {
                innerError = error
            }
        }
        if let innerError { throw innerError }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw ProjectPackageError.cannotAccess }
        return result
    }

    private static func packageRoot(for url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ProjectPackageError.cannotAccess
        }
        if isDirectory.boolValue { return url }
        if url.lastPathComponent == ProjectStore.projectFileName { return url.deletingLastPathComponent() }
        throw ProjectPackageError.notAPackage
    }

    private static func prepareUnsafe(_ pickedURL: URL) throws -> PreparedImport {
        let fm = FileManager.default
        let root = try packageRoot(for: pickedURL)
        let projectURL = root.appendingPathComponent(ProjectStore.projectFileName)
        guard fm.fileExists(atPath: projectURL.path) else { throw ProjectPackageError.notAPackage }
        let projectData = try Data(contentsOf: projectURL)
        let references: ProjectStore.MediaReferences
        do {
            references = try ProjectStore.mediaReferences(inProjectFileData: projectData)
        } catch {
            throw ProjectPackageError.invalidProjectFile
        }

        var info: PackageInfo? = nil
        if let infoData = try? Data(contentsOf: root.appendingPathComponent(infoFileName)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            info = try? decoder.decode(PackageInfo.self, from: infoData)
        }

        // 素材を mediaDirectory へ(名前はそのまま。衝突したら別名にして書き換え表を作る)
        let mediaDir = root.appendingPathComponent(mediaFolderName, isDirectory: true)
        var mediaMapping: [String: String] = [:]
        for name in references.mediaFileNames {
            let source = mediaDir.appendingPathComponent(name)
            // パッケージに無い素材(生成した単色 PNG など)はそのままの名前で残す
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = try copyMedia(from: source, preferredName: name)
            if destination.lastPathComponent != name {
                mediaMapping[name] = destination.lastPathComponent
            }
        }
        var lutMapping: [String: String] = [:]
        let lutSourceDir = mediaDir.appendingPathComponent(lutFolderName, isDirectory: true)
        for name in references.lutFileNames {
            let source = lutSourceDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = try copyLUT(from: source, preferredName: name)
            if destination.lastPathComponent != name {
                lutMapping[name] = destination.lastPathComponent
            }
        }

        let rewritten: Data
        if mediaMapping.isEmpty && lutMapping.isEmpty {
            rewritten = projectData
        } else {
            rewritten = try ProjectStore.rewritingMediaFileNames(inProjectFileData: projectData,
                                                                 mediaMapping: mediaMapping,
                                                                 lutMapping: lutMapping)
        }
        let thumbnailData = try? Data(contentsOf: root.appendingPathComponent(ProjectStore.thumbnailFileName))
        let snapshot = ProjectStore.snapshot(fromProjectFileData: rewritten)

        var name = (info?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = root.deletingPathExtension().lastPathComponent }
        if name.isEmpty { name = "読み込んだプロジェクト" }

        return PreparedImport(name: name,
                              projectData: rewritten,
                              thumbnailData: thumbnailData,
                              duration: snapshot?.totalDuration ?? info?.duration ?? 0,
                              clipCount: snapshot?.clips.count ?? info?.clipCount ?? 0)
    }

    /// 素材を mediaDirectory にコピーする。同名で同じ大きさのファイルがあれば使い回し、違えば別名にする
    private static func copyMedia(from source: URL, preferredName name: String) throws -> URL {
        let fm = FileManager.default
        let direct = MediaStore.mediaDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) {
            if fileSize(direct) == fileSize(source) { return direct }
            let ext = source.pathExtension
            let base = MediaStore.displayName(for: source, fallback: "media")
            let destination = MediaStore.uniqueDestination(forFileName: ext.isEmpty ? base : "\(base).\(ext)")
            try fm.copyItem(at: source, to: destination)
            return destination
        }
        try fm.copyItem(at: source, to: direct)
        return direct
    }

    /// LUT を mediaDirectory/LUTs にコピーする(同名で同じ大きさなら使い回し)
    private static func copyLUT(from source: URL, preferredName name: String) throws -> URL {
        let fm = FileManager.default
        let dir = ProjectStore.lutDirectory
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let direct = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) {
            if fileSize(direct) == fileSize(source) { return direct }
            let destination = dir.appendingPathComponent("\(UUID().uuidString)_\(name)")
            try fm.copyItem(at: source, to: destination)
            return destination
        }
        try fm.copyItem(at: source, to: direct)
        return direct
    }

    @MainActor
    private static func register(_ prepared: PreparedImport) throws -> ProjectMeta {
        let library = ProjectLibrary.shared
        let existing = Set(library.projects.map { $0.name })
        var name = prepared.name
        if existing.contains(name) {
            var n = 2
            while existing.contains("\(prepared.name) \(n)") { n += 1 }
            name = "\(prepared.name) \(n)"
        }
        let meta = library.create(name: name)
        do {
            try ProjectStore.writeImportedProject(fileData: prepared.projectData,
                                                  thumbnailData: prepared.thumbnailData,
                                                  projectID: meta.id)
        } catch {
            library.delete(id: meta.id)
            throw error
        }
        library.touch(id: meta.id, duration: prepared.duration, clipCount: prepared.clipCount)
        library.flush()
        library.noteThumbnailChanged()
        return library.project(id: meta.id) ?? meta
    }

    // MARK: - 補助

    /// 同期処理を裏のキューで実行して待つ
    private static func offMain<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func report(_ progress: ((Double) -> Void)?, _ value: Double) {
        guard let progress else { return }
        let clamped = min(max(value, 0), 1)
        DispatchQueue.main.async { progress(clamped) }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    /// フォルダ名に使えない文字を取り除く
    private static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        var cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)) }
        return cleaned.isEmpty ? "プロジェクト" : cleaned
    }
}
