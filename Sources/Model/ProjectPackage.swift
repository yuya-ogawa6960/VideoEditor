import Foundation
import UIKit
import CoreText

// =====================================================================
// プロジェクトの持ち出し・持ち込み(.videomania パッケージ)。
//   <名前>.videomania/
//     package.json    … 名前・書き出し日時・長さなど(無くても読める)
//     project.json    … ProjectStore と同じ形式(素材はファイル名で参照)
//     thumbnail.jpg   … 一覧用サムネイル(あれば)
//     media/<素材ファイル>        … 参照している素材(名前はそのまま)
//     media/LUTs/<名前>.cube     … 参照している LUT
//     media/Fonts/<名前>.ttf     … テキスト・キャプション・サムネで使っている、読み込んだフォント(Google Fonts など)
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
            return String(localized: "プロジェクトの保存ファイルが見つかりません。")
        case .notAPackage:
            return String(localized: "「.videomania」フォルダ(中に project.json があるもの)を選んでください。")
        case .invalidProjectFile:
            return String(localized: "project.json を読み取れませんでした。新しいバージョンの Video Mania で作られた可能性があります。")
        case .cannotAccess:
            return String(localized: "ファイルにアクセスできませんでした。")
        }
    }
}

enum ProjectPackage {
    static let packageExtension = "videomania"
    static let mediaFolderName = "media"
    static let lutFolderName = "LUTs"
    static let fontFolderName = "Fonts"
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

    /// 書き出したパッケージ
    struct ExportedPackage {
        let url: URL
        /// 入れられなかった素材の数(写真ライブラリから読み出せなかった動画・見つからない素材や LUT)。
        /// 1 つでもあれば、共有シートを出す前に知らせる(前は黙って抜けたまま送れていた)
        let missingCount: Int
    }

    /// 受け取ったパッケージ
    struct ImportedPackage {
        let meta: ProjectMeta
        /// この端末に無く、パッケージにも入っていなかったフォント(標準のフォントで表示される。受け取ったときに知らせる)
        let missingFontNames: [String]
    }

    // MARK: - 書き出し

    /// プロジェクトを <名前>.videomania フォルダにまとめて返す。
    /// progress は 0...1 でメインスレッドに呼ばれる(写真ライブラリの動画があれば前半はその取り出し、後半は素材のコピー量ベース)
    static func export(projectID: UUID, progress: ((Double) -> Void)?) async throws -> ExportedPackage {
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
        // 写真ライブラリを参照している動画は、読み出せるようにしてからパッケージに入れる
        // (iCloud からのダウンロードの進み具合を前半に出す。前は 0% のまま止まって見えた)
        let photoNames: [String] = references.mediaFileNames.filter { PhotoMediaResolver.isReference($0) }
        var copyProgress: ((Double) -> Void)? = progress
        if !photoNames.isEmpty {
            let reportPrepare: ((Double) -> Void)? = progress
            _ = await PhotoMediaResolver.prepareDetailed(references: photoNames, onProgress: { done, total, fraction in
                guard total > 0 else { return }
                let value = (Double(done) + min(max(fraction, 0), 1)) / Double(total)
                reportPrepare?(0.5 * min(max(value, 0), 1))
            })
            if let progress {
                copyProgress = { value in progress(0.5 + 0.5 * value) }
            }
        }
        // テキスト・キャプション・サムネで使っている、読み込んだフォントのファイル
        let fontFiles: [URL] = fontFileURLs(for: ProjectStore.fontNames(inProjectFileData: projectData))
        let snapshot = ProjectStore.snapshot(fromProjectFileData: projectData)
        let info = PackageInfo(formatVersion: formatVersion,
                               app: "Video Mania",
                               name: meta?.name ?? String(localized: "プロジェクト"),
                               exportedAt: Date(),
                               duration: meta?.duration ?? snapshot?.totalDuration ?? 0,
                               clipCount: meta?.clipCount ?? snapshot?.clips.count ?? 0)
        let thumbnailURL = ProjectStore.thumbnailURL(projectID: projectID)
        return try await offMain {
            // 前に書き出したパッケージ(素材のコピーで大きい)は消してから作る。
            // 共有シートは 1 つずつしか開かないので、新しく書き出すときに使い中のものは無い
            cleanUpExportedPackages()
            return try buildPackage(projectData: projectData, info: info, references: references,
                                    fontFiles: fontFiles, thumbnailURL: thumbnailURL, progress: copyProgress)
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
                                     fontFiles: [URL], thumbnailURL: URL,
                                     progress: ((Double) -> Void)?) throws -> ExportedPackage {
        let fm = FileManager.default
        let container = exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let package = container.appendingPathComponent("\(safeFileName(info.name)).\(packageExtension)", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let mediaDir = package.appendingPathComponent(mediaFolderName, isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // 写真ライブラリを参照している動画("photos:<id>")は、ふつうのファイル名にして中身を入れる
        var photoMapping: [String: String] = [:]
        for name in references.mediaFileNames where PhotoMediaResolver.isReference(name) {
            if let url = ProjectStore.resolveMedia(name) {
                photoMapping[name] = PhotoMediaResolver.packageFileName(forReference: name, url: url)
            }
        }
        var projectData = projectData
        if !photoMapping.isEmpty {
            projectData = try ProjectStore.rewritingMediaFileNames(inProjectFileData: projectData,
                                                                    mediaMapping: photoMapping, lutMapping: [:])
        }

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
        // 入れられなかった素材(写真ライブラリから読み出せなかった動画・見つからない素材や LUT)の数
        var missingCount = 0
        for name in references.mediaFileNames {
            if let url = ProjectStore.resolveMedia(name) {
                jobs.append((url, mediaDir.appendingPathComponent(photoMapping[name] ?? name)))
            } else if !FormatKitStore.isGeneratedStill(MediaStore.mediaDirectory.appendingPathComponent(name)) {
                missingCount += 1
            }
        }
        if !fontFiles.isEmpty {
            let fontDir = mediaDir.appendingPathComponent(fontFolderName, isDirectory: true)
            try fm.createDirectory(at: fontDir, withIntermediateDirectories: true)
            for url in fontFiles {
                jobs.append((url, fontDir.appendingPathComponent(url.lastPathComponent)))
            }
        }
        if !references.lutFileNames.isEmpty {
            let lutDir = mediaDir.appendingPathComponent(lutFolderName, isDirectory: true)
            var created = false
            for name in references.lutFileNames {
                guard let url = ProjectStore.resolveLUT(name) else {
                    missingCount += 1
                    continue
                }
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
        return ExportedPackage(url: package, missingCount: missingCount)
    }

    /// フォント名(PostScript 名)→ 読み込んだフォントのファイル(Media/Fonts にあるものだけ。内蔵・iOS のフォントは入れない)
    private static func fontFileURLs(for names: [String]) -> [URL] {
        guard !names.isEmpty else { return [] }
        let wanted = Set(names)
        guard let items = try? FileManager.default.contentsOfDirectory(at: MediaTools.fontsDirectory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        let extensions: Set<String> = ["ttf", "otf", "ttc"]
        var result: [URL] = []
        for url in items where extensions.contains(url.pathExtension.lowercased()) {
            if !wanted.isDisjoint(with: fontPostScriptNames(at: url)) {
                result.append(url)
            }
        }
        return result
    }

    /// フォントファイルに入っているフォントの PostScript 名(.ttc は複数)
    private static func fontPostScriptNames(at url: URL) -> [String] {
        guard let array = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) else { return [] }
        let count = CFArrayGetCount(array)
        var names: [String] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let descriptor = unsafeBitCast(raw, to: CTFontDescriptor.self)
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, !name.isEmpty {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - 読み込み

    private struct PreparedImport {
        let name: String
        let projectData: Data
        let thumbnailData: Data?
        let duration: Double
        let clipCount: Int
        /// この端末で使えないフォント
        let missingFontNames: [String]
    }

    /// .videomania フォルダ(または中の project.json)を読み込み、新しいプロジェクトとして一覧に登録して返す
    static func importPackage(from url: URL) async throws -> ImportedPackage {
        let prepared = try await offMain { try prepare(url) }
        let meta = try await MainActor.run { try register(prepared) }
        return ImportedPackage(meta: meta, missingFontNames: prepared.missingFontNames)
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
        // パッケージに入っているフォント(media/Fonts)を読み込んで登録する
        // (前は入っておらず、受け取った端末ではテロップ・キャプションが標準のフォントに黙って変わっていた)
        let fontSourceDir = mediaDir.appendingPathComponent(fontFolderName, isDirectory: true)
        if let fontItems = try? fm.contentsOfDirectory(at: fontSourceDir, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
            for fontURL in fontItems {
                _ = try? MediaTools.importFont(from: fontURL)
            }
        }
        // それでもこの端末で使えないフォント(受け取ったときに知らせる)
        let missingFontNames: [String] = ProjectStore.fontNames(inProjectFileData: rewritten)
            .filter { UIFont(name: $0, size: 12) == nil }
        let thumbnailData = try? Data(contentsOf: root.appendingPathComponent(ProjectStore.thumbnailFileName))
        let snapshot = ProjectStore.snapshot(fromProjectFileData: rewritten)

        var name = (info?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = root.deletingPathExtension().lastPathComponent }
        if name.isEmpty { name = String(localized: "読み込んだプロジェクト") }

        return PreparedImport(name: name,
                              projectData: rewritten,
                              thumbnailData: thumbnailData,
                              duration: snapshot?.totalDuration ?? info?.duration ?? 0,
                              clipCount: snapshot?.clips.count ?? info?.clipCount ?? 0,
                              missingFontNames: missingFontNames)
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
        return cleaned.isEmpty ? String(localized: "プロジェクト") : cleaned
    }
}
