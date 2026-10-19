import Foundation
import CoreGraphics
import UIKit

// =====================================================================
// プロジェクトの自動保存と復元(プロジェクトごとに別ファイル)。
//   Documents/Projects/<uuid>/project.json   … 編集内容
//   Documents/Projects/<uuid>/thumbnail.jpg  … 一覧用サムネイル
//   Documents/Projects/library.json          … 一覧のメタデータ(ProjectLibrary が管理)
// CapCut の口コミで多い「編集中に落ちて作業が消える」への対策として、
// 変更のたびに(0.5 秒にまとめて)保存し、プロジェクトを開いたときに読み込む。
// 素材ファイルは MediaStore.mediaDirectory にあるので、ファイル名だけを保存する
// (アプリ更新でコンテナのパスが変わっても復元できるように)。
// 旧バージョンの単一ファイル Documents/Projects/current.json は、一覧が空のときに
// ProjectLibrary が 1 回だけ取り込んで削除する(importLegacyProject)。
//
// 保存形式(project.json)は version 2。第3弾で増えた項目(トランジション、アニメーション、
// 切り抜き、速度カーブ、逆再生、静止画、HSL/LUT、字幕テンプレート、単語タイミング、
// 音声エフェクト、キーフレーム、テキスト、手書き、マーカー、透かし、サムネ設定)は
// すべて省略可能で、旧ファイル(version 1)はそのまま読み込める。
// 字幕スタイルと出力設定は StoredSubtitleStyle / StoredCanvas にまとめた
// (PresetStore も同じ Codable を使う)。旧ファイルの平らな項目からも復元する。
// =====================================================================

enum ProjectStore {
    static var projectsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Projects", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 旧バージョン(単一プロジェクト)の保存ファイル。移行後は削除される
    static var legacyCurrentURL: URL { projectsDirectory.appendingPathComponent("current.json") }

    static let projectFileName = "project.json"
    static let thumbnailFileName = "thumbnail.jpg"

    /// プロジェクトのフォルダ(ここでは作成しない)
    static func projectDirectory(projectID: UUID) -> URL {
        projectsDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    static func projectFileURL(projectID: UUID) -> URL {
        projectDirectory(projectID: projectID).appendingPathComponent(projectFileName)
    }

    static func thumbnailURL(projectID: UUID) -> URL {
        projectDirectory(projectID: projectID).appendingPathComponent(thumbnailFileName)
    }

    /// プロジェクトのフォルダを(なければ)作る
    @discardableResult
    static func ensureProjectDirectory(projectID: UUID) -> URL {
        let dir = projectDirectory(projectID: projectID)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func hasProjectFile(projectID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: projectFileURL(projectID: projectID).path)
    }

    static func hasThumbnail(projectID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(projectID: projectID).path)
    }

    // MARK: - 遅延書き込み(プロジェクト ID ごとにまとめる)

    private enum WorkKind: Hashable {
        case snapshot
        case thumbnail
    }

    private struct WorkKey: Hashable {
        let projectID: UUID
        let kind: WorkKind
    }

    private struct PendingWork {
        let generation: UInt64
        let item: DispatchWorkItem
        let action: () -> Void
    }

    /// 書き込みはすべてこの直列キューで行う(同じファイルへの同時書き込みを避ける)
    private static let queue = DispatchQueue(label: "ProjectStore.save", qos: .utility)
    private static let lock = NSLock()
    private static var pending: [WorkKey: PendingWork] = [:]
    private static var generation: UInt64 = 0

    private static func schedule(_ key: WorkKey, delay: TimeInterval, action: @escaping () -> Void) {
        lock.lock()
        generation &+= 1
        let myGeneration = generation
        let item = DispatchWorkItem {
            lock.lock()
            if let current = pending[key], current.generation == myGeneration {
                pending[key] = nil
            }
            lock.unlock()
            action()
        }
        if let previous = pending[key] {
            previous.item.cancel()
        }
        pending[key] = PendingWork(generation: myGeneration, item: item, action: action)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 予約済みの書き込みを取り消して返す(実行はしない)
    private static func takePending(_ key: WorkKey) -> PendingWork? {
        lock.lock()
        let work = pending[key]
        pending[key] = nil
        lock.unlock()
        work?.item.cancel()
        return work
    }

    /// 予約済みの書き込みをいま実行する
    private static func flush(_ key: WorkKey) {
        guard let work = takePending(key) else { return }
        queue.sync { work.action() }
    }

    /// このプロジェクトの予約済みの書き込みをすべていま実行する
    static func flush(projectID: UUID) {
        flush(WorkKey(projectID: projectID, kind: .snapshot))
        flush(WorkKey(projectID: projectID, kind: .thumbnail))
    }

    /// すべてのプロジェクトの予約済みの書き込みをいま実行する(バックグラウンド移行時など)
    static func flushAll() {
        lock.lock()
        let works = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for work in works {
            work.item.cancel()
            queue.sync { work.action() }
        }
    }

    // MARK: - 編集内容の保存 / 読み込み

    /// 0.5 秒間隔にまとめて保存する(スライダー操作中に書き込みすぎないように)
    static func scheduleSave(_ snapshot: ProjectSnapshot, projectID: UUID) {
        schedule(WorkKey(projectID: projectID, kind: .snapshot), delay: 0.5) {
            writeSnapshot(snapshot, projectID: projectID)
        }
    }

    /// 予約を取り消してすぐに保存する(プロジェクトを閉じるときなど)
    static func saveNow(_ snapshot: ProjectSnapshot, projectID: UUID) {
        _ = takePending(WorkKey(projectID: projectID, kind: .snapshot))
        queue.sync { writeSnapshot(snapshot, projectID: projectID) }
    }

    private static func writeSnapshot(_ snapshot: ProjectSnapshot, projectID: UUID) {
        let file = ProjectFile(snapshot: snapshot)
        do {
            let data = try JSONEncoder().encode(file)
            ensureProjectDirectory(projectID: projectID)
            try data.write(to: projectFileURL(projectID: projectID), options: .atomic)
        } catch {
            print("ProjectStore: save failed (\(projectID)): \(error)")
        }
    }

    /// 保存済みのプロジェクトを読み込む。素材ファイルが消えているクリップは除外する。
    /// 保存ファイルがなければ nil(まだ何も保存していない新しいプロジェクト)
    static func load(projectID: UUID) -> ProjectSnapshot? {
        flush(projectID: projectID)
        guard let data = try? Data(contentsOf: projectFileURL(projectID: projectID)),
              let file = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return nil }
        return file.makeSnapshot()
    }

    /// project.json の生データ(予約済みの書き込みを済ませてから読む)。なければ nil
    static func projectFileData(projectID: UUID) -> Data? {
        flush(projectID: projectID)
        return try? Data(contentsOf: projectFileURL(projectID: projectID))
    }

    /// project.json の生データからスナップショットを作る(素材は現在の mediaDirectory で解決)。
    /// 形式が読めなければ nil
    static func snapshot(fromProjectFileData data: Data) -> ProjectSnapshot? {
        guard let file = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return nil }
        return file.makeSnapshot()
    }

    /// スナップショットを project.json 形式のデータにする(パッケージ書き出しなど)
    static func projectFileData(from snapshot: ProjectSnapshot) throws -> Data {
        try JSONEncoder().encode(ProjectFile(snapshot: snapshot))
    }

    /// プロジェクトのフォルダごと削除する(素材ファイルは共有なので消さない)
    static func delete(projectID: UUID) {
        _ = takePending(WorkKey(projectID: projectID, kind: .snapshot))
        _ = takePending(WorkKey(projectID: projectID, kind: .thumbnail))
        lock.lock()
        lastThumbnails[projectID] = nil
        lock.unlock()
        let dir = projectDirectory(projectID: projectID)
        queue.sync {
            if FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// project.json とサムネイルを別のプロジェクト ID にコピーする(複製用)。
    /// 素材ファイルは共有のままコピーしない。コピーすべきファイルがなければ何もせず true
    static func copyProjectFiles(from sourceID: UUID, to destinationID: UUID) -> Bool {
        flush(projectID: sourceID)
        ensureProjectDirectory(projectID: destinationID)
        let fm = FileManager.default
        let pairs: [(URL, URL)] = [
            (projectFileURL(projectID: sourceID), projectFileURL(projectID: destinationID)),
            (thumbnailURL(projectID: sourceID), thumbnailURL(projectID: destinationID))
        ]
        var ok = true
        queue.sync {
            for (src, dst) in pairs where fm.fileExists(atPath: src.path) {
                do {
                    if fm.fileExists(atPath: dst.path) {
                        try fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: src, to: dst)
                } catch {
                    print("ProjectStore: copy failed: \(error)")
                    ok = false
                }
            }
        }
        return ok
    }

    /// 外部から持ち込んだ project.json(とサムネイル)を指定したプロジェクト ID に書き込む
    /// (ProjectPackage の読み込み用)。予約済みの書き込みは取り消す
    static func writeImportedProject(fileData: Data, thumbnailData: Data?, projectID: UUID) throws {
        _ = takePending(WorkKey(projectID: projectID, kind: .snapshot))
        _ = takePending(WorkKey(projectID: projectID, kind: .thumbnail))
        lock.lock()
        lastThumbnails[projectID] = nil
        lock.unlock()
        ensureProjectDirectory(projectID: projectID)
        var failure: Error?
        queue.sync {
            do {
                try fileData.write(to: projectFileURL(projectID: projectID), options: .atomic)
                if let thumbnailData {
                    try thumbnailData.write(to: thumbnailURL(projectID: projectID), options: .atomic)
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Projects フォルダ内で project.json を持つプロジェクト ID(一覧との突き合わせ用)
    static func storedProjectIDs() -> [UUID] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: projectsDirectory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var result: [UUID] = []
        for url in items {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            if fm.fileExists(atPath: url.appendingPathComponent(projectFileName).path) {
                result.append(id)
            }
        }
        return result
    }

    /// project.json の作成日時・更新日時(なければ nil)
    static func fileDates(projectID: UUID) -> (created: Date?, modified: Date?) {
        let url = projectFileURL(projectID: projectID)
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
            return (nil, nil)
        }
        return (values.creationDate, values.contentModificationDate)
    }

    // MARK: - サムネイル

    private final class WeakImage {
        weak var image: UIImage?
        init(_ image: UIImage) { self.image = image }
    }

    /// 最後に書き込んだ(または予約した)サムネイル。同じ画像なら書き直さない
    private static var lastThumbnails: [UUID: WeakImage] = [:]

    private static func isSameAsLastThumbnail(_ image: UIImage, projectID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastThumbnails[projectID]?.image, last === image {
            return true
        }
        lastThumbnails[projectID] = WeakImage(image)
        return false
    }

    /// 数秒にまとめてサムネイルを保存する(同じ画像なら何もしない)
    static func scheduleThumbnail(_ image: UIImage, projectID: UUID) {
        if isSameAsLastThumbnail(image, projectID: projectID) { return }
        schedule(WorkKey(projectID: projectID, kind: .thumbnail), delay: 2.0) {
            writeThumbnail(image, projectID: projectID)
        }
    }

    /// すぐにサムネイルを保存する(JPEG 0.7、長辺 400px 以下)
    static func saveThumbnail(_ image: UIImage, projectID: UUID) {
        _ = takePending(WorkKey(projectID: projectID, kind: .thumbnail))
        _ = isSameAsLastThumbnail(image, projectID: projectID)
        queue.sync { writeThumbnail(image, projectID: projectID) }
    }

    static func loadThumbnail(projectID: UUID) -> UIImage? {
        UIImage(contentsOfFile: thumbnailURL(projectID: projectID).path)
    }

    static func deleteThumbnail(projectID: UUID) {
        _ = takePending(WorkKey(projectID: projectID, kind: .thumbnail))
        lock.lock()
        lastThumbnails[projectID] = nil
        lock.unlock()
        let url = thumbnailURL(projectID: projectID)
        queue.sync {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func writeThumbnail(_ image: UIImage, projectID: UUID) {
        guard let data = thumbnailData(from: image, maxPixel: 400, quality: 0.7) else { return }
        do {
            ensureProjectDirectory(projectID: projectID)
            try data.write(to: thumbnailURL(projectID: projectID), options: .atomic)
        } catch {
            print("ProjectStore: thumbnail save failed (\(projectID)): \(error)")
        }
    }

    /// 長辺 maxPixel 以下に縮小して JPEG にする
    static func thumbnailData(from image: UIImage, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return nil }
        if longest <= maxPixel {
            return image.jpegData(compressionQuality: quality)
        }
        let ratio = maxPixel / longest
        let target = CGSize(width: max(1, floor(pixelWidth * ratio)),
                            height: max(1, floor(pixelHeight * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    // MARK: - 旧バージョンからの移行

    struct LegacyImportResult {
        let snapshot: ProjectSnapshot
        let createdAt: Date?
        let modifiedAt: Date?
    }

    /// 旧バージョンの単一ファイル(current.json)が残っているか
    static var hasLegacyProject: Bool {
        FileManager.default.fileExists(atPath: legacyCurrentURL.path)
    }

    /// current.json を指定したプロジェクト ID の project.json として取り込み、元のファイルを削除する。
    /// 読み込めない場合は何もせず nil
    static func importLegacyProject(into projectID: UUID) -> LegacyImportResult? {
        let legacy = legacyCurrentURL
        guard FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy),
              let file = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return nil }
        let values = try? legacy.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        ensureProjectDirectory(projectID: projectID)
        do {
            try data.write(to: projectFileURL(projectID: projectID), options: .atomic)
        } catch {
            print("ProjectStore: legacy import failed: \(error)")
            return nil
        }
        try? FileManager.default.removeItem(at: legacy)
        return LegacyImportResult(snapshot: file.makeSnapshot(),
                                  createdAt: values?.creationDate,
                                  modifiedAt: values?.contentModificationDate)
    }

    // MARK: - 素材の解決

    /// 素材のファイル名 → 現在の mediaDirectory 内の URL
    static func resolveMedia(_ fileName: String) -> URL? {
        let url = MediaStore.mediaDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 静止画クリップの画像の解決。mediaDirectory になければ、生成した単色 PNG(black.png など)を
    /// FormatKitStore が作り直す
    static func resolveStillImage(_ fileName: String) -> URL? {
        if let url = resolveMedia(fileName) { return url }
        return FormatKitStore.generatedStillURL(fileName: fileName)
    }

    /// LUT(.cube)のフォルダ(MediaStore.mediaDirectory/LUTs。ここでは作成しない)
    static var lutDirectory: URL {
        MediaStore.mediaDirectory.appendingPathComponent("LUTs", isDirectory: true)
    }

    /// LUT のファイル名 → 存在すれば URL
    static func resolveLUT(_ fileName: String) -> URL? {
        let url = lutDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - パッケージ(.videomania)用: 参照している素材の列挙と名前の書き換え

    /// project.json が参照している素材ファイル名(重複なし、出現順)
    struct MediaReferences {
        /// mediaDirectory 直下のファイル(動画・画像・音声・逆再生ファイル・静止画・透かし・サムネ背景)
        var mediaFileNames: [String]
        /// mediaDirectory/LUTs 内の .cube
        var lutFileNames: [String]
    }

    static func mediaReferences(inProjectFileData data: Data) throws -> MediaReferences {
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        let refs = file.referencedFileNames()
        return MediaReferences(mediaFileNames: refs.media, lutFileNames: refs.luts)
    }

    /// 素材ファイル名を書き換えた project.json データを返す(mapping に無い名前はそのまま)
    static func rewritingMediaFileNames(inProjectFileData data: Data,
                                        mediaMapping: [String: String],
                                        lutMapping: [String: String]) throws -> Data {
        var file = try JSONDecoder().decode(ProjectFile.self, from: data)
        file.rewriteFileNames(media: mediaMapping, luts: lutMapping)
        return try JSONEncoder().encode(file)
    }
}

// =====================================================================
// MARK: - 保存形式(共通の Codable ミラー)
// internal のものは PresetStore / FormatKitStore / ProjectPackage も使う。
// 列挙型は rawValue の文字列で保存し、読めない値は既定値に戻す。
// =====================================================================

/// 出力設定(CanvasSettings)の保存形式
struct StoredCanvas: Codable {
    var aspect: String
    var scaling: String
    var resolution: String
    var quality: String
    var frameRate: Int
    var codec: String?
    var bitrateMbps: Double?
    var audioBitrateKbps: Int?
    var fileFormat: String?
    var preserveHDR: Bool?
    var burnInSubtitles: Bool?

    init(_ c: CanvasSettings) {
        aspect = c.aspect.rawValue
        scaling = c.scaling.rawValue
        resolution = c.resolution.rawValue
        quality = c.quality.rawValue
        frameRate = c.frameRate
        codec = c.codec.rawValue
        bitrateMbps = c.bitrateMbps
        audioBitrateKbps = c.audioBitrateKbps
        fileFormat = c.fileFormat.rawValue
        preserveHDR = c.preserveHDR
        burnInSubtitles = c.burnInSubtitles
    }

    var value: CanvasSettings {
        let defaults = CanvasSettings()
        var c = CanvasSettings()
        c.aspect = CanvasAspect(rawValue: aspect) ?? defaults.aspect
        c.scaling = ScalingMode(rawValue: scaling) ?? defaults.scaling
        c.resolution = ResolutionCap(rawValue: resolution) ?? defaults.resolution
        c.quality = ExportQuality(rawValue: quality) ?? defaults.quality
        c.frameRate = frameRate > 0 ? frameRate : defaults.frameRate
        c.codec = codec.flatMap { ExportCodec(rawValue: $0) } ?? defaults.codec
        c.bitrateMbps = bitrateMbps
        c.audioBitrateKbps = audioBitrateKbps ?? defaults.audioBitrateKbps
        c.fileFormat = fileFormat.flatMap { ExportFileFormat(rawValue: $0) } ?? defaults.fileFormat
        c.preserveHDR = preserveHDR ?? defaults.preserveHDR
        c.burnInSubtitles = burnInSubtitles ?? defaults.burnInSubtitles
        return c
    }
}

/// 字幕スタイル(SubtitleStyle)の保存形式
struct StoredSubtitleStyle: Codable {
    var position: String
    var color: String
    var sizeRatio: Double
    var hasBackground: Bool
    var displayMode: String
    var template: String?
    var highlightColorHex: String?
    var fontName: String?

    init(_ s: SubtitleStyle) {
        position = s.position.rawValue
        color = s.color.rawValue
        sizeRatio = Double(s.sizeRatio)
        hasBackground = s.hasBackground
        displayMode = s.displayMode.rawValue
        template = s.template.rawValue
        highlightColorHex = s.highlightColorHex
        fontName = s.fontName
    }

    var value: SubtitleStyle {
        let defaults = SubtitleStyle()
        var s = SubtitleStyle()
        s.position = SubtitlePosition(rawValue: position) ?? defaults.position
        s.color = SubtitleColor(rawValue: color) ?? defaults.color
        s.sizeRatio = sizeRatio > 0 ? CGFloat(sizeRatio) : defaults.sizeRatio
        s.hasBackground = hasBackground
        s.displayMode = SubtitleDisplayMode(rawValue: displayMode) ?? defaults.displayMode
        s.template = template.flatMap { CaptionTemplate(rawValue: $0) } ?? defaults.template
        s.highlightColorHex = highlightColorHex ?? defaults.highlightColorHex
        s.fontName = fontName
        return s
    }
}

/// ドキュメンタリー演出(DocumentaryStyle)の保存形式
struct StoredDocumentary: Codable {
    var look: String
    var lookIntensity: Double
    var letterbox: Bool
    var filmGrain: Double
    var vignette: Double
    var fadeFromToBlack: Bool
    var dipToBlackBetweenClips: Bool
    var autoDucking: Bool
    var duckingLevel: Float

    init(_ d: DocumentaryStyle) {
        look = d.look.rawValue
        lookIntensity = d.lookIntensity
        letterbox = d.letterbox
        filmGrain = d.filmGrain
        vignette = d.vignette
        fadeFromToBlack = d.fadeFromToBlack
        dipToBlackBetweenClips = d.dipToBlackBetweenClips
        autoDucking = d.autoDucking
        duckingLevel = d.duckingLevel
    }

    var value: DocumentaryStyle {
        var d = DocumentaryStyle()
        d.look = LookPreset(rawValue: look) ?? .none
        d.lookIntensity = lookIntensity
        d.letterbox = letterbox
        d.filmGrain = filmGrain
        d.vignette = vignette
        d.fadeFromToBlack = fadeFromToBlack
        d.dipToBlackBetweenClips = dipToBlackBetweenClips
        d.autoDucking = autoDucking
        d.duckingLevel = duckingLevel
        return d
    }
}

/// 正規化座標
struct StoredPoint: Codable {
    var x: Double
    var y: Double

    init(_ p: NormalizedPoint) {
        x = p.x
        y = p.y
    }

    var value: NormalizedPoint { NormalizedPoint(x: x, y: y) }
}

/// トランジション
struct StoredTransition: Codable {
    var type: String
    var duration: Double

    init(_ t: ClipTransition) {
        type = t.type.rawValue
        duration = t.duration
    }

    var value: ClipTransition {
        ClipTransition(type: TransitionType(rawValue: type) ?? .none, duration: duration)
    }
}

/// キーフレーム(オーバーレイ・テキスト)
struct StoredKeyframe: Codable {
    var id: UUID
    var time: Double
    var center: StoredPoint
    var scale: Double
    var rotation: Double
    var opacity: Double
    var easing: String

    init(_ k: Keyframe) {
        id = k.id
        time = k.time
        center = StoredPoint(k.center)
        scale = k.scale
        rotation = k.rotation
        opacity = k.opacity
        easing = k.easing.rawValue
    }

    var value: Keyframe {
        var k = Keyframe(time: time)
        k.id = id
        k.center = center.value
        k.scale = scale
        k.rotation = rotation
        k.opacity = opacity
        k.easing = KeyframeEasing(rawValue: easing) ?? .easeInOut
        return k
    }
}

struct StoredTextShadow: Codable {
    var enabled: Bool
    var colorHex: String
    var opacity: Double
    var radius: Double
    var offsetX: Double
    var offsetY: Double

    init(_ s: TextShadow) {
        enabled = s.enabled
        colorHex = s.colorHex
        opacity = s.opacity
        radius = s.radius
        offsetX = s.offsetX
        offsetY = s.offsetY
    }

    var value: TextShadow {
        var s = TextShadow()
        s.enabled = enabled
        s.colorHex = colorHex
        s.opacity = opacity
        s.radius = radius
        s.offsetX = offsetX
        s.offsetY = offsetY
        return s
    }
}

struct StoredTextStyle: Codable {
    var fontName: String?
    var bold: Bool
    var italic: Bool
    var sizeRatio: Double
    var colorHex: String
    var strokeColorHex: String?
    var strokeWidth: Double
    var shadow: StoredTextShadow
    var backgroundColorHex: String?
    var backgroundOpacity: Double
    var backgroundPadding: Double
    var backgroundCornerRadius: Double
    var alignment: String
    var letterSpacing: Double
    var lineSpacing: Double
    var vertical: Bool
    var curveRadius: Double

    init(_ t: TextStyle) {
        fontName = t.fontName
        bold = t.bold
        italic = t.italic
        sizeRatio = t.sizeRatio
        colorHex = t.colorHex
        strokeColorHex = t.strokeColorHex
        strokeWidth = t.strokeWidth
        shadow = StoredTextShadow(t.shadow)
        backgroundColorHex = t.backgroundColorHex
        backgroundOpacity = t.backgroundOpacity
        backgroundPadding = t.backgroundPadding
        backgroundCornerRadius = t.backgroundCornerRadius
        alignment = t.alignment.rawValue
        letterSpacing = t.letterSpacing
        lineSpacing = t.lineSpacing
        vertical = t.vertical
        curveRadius = t.curveRadius
    }

    var value: TextStyle {
        var t = TextStyle()
        t.fontName = fontName
        t.bold = bold
        t.italic = italic
        t.sizeRatio = sizeRatio
        t.colorHex = colorHex
        t.strokeColorHex = strokeColorHex
        t.strokeWidth = strokeWidth
        t.shadow = shadow.value
        t.backgroundColorHex = backgroundColorHex
        t.backgroundOpacity = backgroundOpacity
        t.backgroundPadding = backgroundPadding
        t.backgroundCornerRadius = backgroundCornerRadius
        t.alignment = TextAlignment2(rawValue: alignment) ?? .center
        t.letterSpacing = letterSpacing
        t.lineSpacing = lineSpacing
        t.vertical = vertical
        t.curveRadius = curveRadius
        return t
    }
}

/// 自由配置テキスト・ステッカー
struct StoredTextClip: Codable {
    var id: UUID
    var text: String
    var start: Double
    var duration: Double
    var center: StoredPoint
    var widthRatio: Double
    var rotation: Double
    var scale: Double
    var opacity: Double
    var style: StoredTextStyle
    var template: String
    var animIn: String
    var animInDuration: Double
    var animOut: String
    var animOutDuration: Double
    var keyframes: [StoredKeyframe]
    var isSticker: Bool

    init(_ t: TextClip) {
        id = t.id
        text = t.text
        start = t.start
        duration = t.duration
        center = StoredPoint(t.center)
        widthRatio = t.widthRatio
        rotation = t.rotation
        scale = t.scale
        opacity = t.opacity
        style = StoredTextStyle(t.style)
        template = t.template.rawValue
        animIn = t.animIn.rawValue
        animInDuration = t.animInDuration
        animOut = t.animOut.rawValue
        animOutDuration = t.animOutDuration
        keyframes = t.keyframes.map { StoredKeyframe($0) }
        isSticker = t.isSticker
    }

    var value: TextClip {
        var t = TextClip(text: text, start: start)
        t.id = id
        t.duration = duration
        t.center = center.value
        t.widthRatio = widthRatio
        t.rotation = rotation
        t.scale = scale
        t.opacity = opacity
        t.style = style.value
        t.template = TextTemplate(rawValue: template) ?? .plain
        t.animIn = TextAnimationType(rawValue: animIn) ?? .none
        t.animInDuration = animInDuration
        t.animOut = TextAnimationType(rawValue: animOut) ?? .none
        t.animOutDuration = animOutDuration
        t.keyframes = keyframes.map { $0.value }
        t.isSticker = isSticker
        return t
    }
}

/// 章タイトル
struct StoredTitleCard: Codable {
    var id: UUID
    var start: Double
    var duration: Double
    var heading: String
    var title: String
    var opaqueBackground: Bool

    init(_ t: TitleCard) {
        id = t.id
        start = t.start
        duration = t.duration
        heading = t.heading
        title = t.title
        opaqueBackground = t.opaqueBackground
    }

    var value: TitleCard {
        TitleCard(id: id, start: start, duration: duration, heading: heading, title: title, opaqueBackground: opaqueBackground)
    }
}

// MARK: - project.json 専用の保存形式(private)

private struct StoredTransform: Codable {
    var a, b, c, d, tx, ty: Double
    init(_ t: CGAffineTransform) {
        a = Double(t.a); b = Double(t.b); c = Double(t.c); d = Double(t.d); tx = Double(t.tx); ty = Double(t.ty)
    }
    var value: CGAffineTransform {
        CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
    }
}

private struct StoredHSLBand: Codable {
    var hue: Double
    var saturation: Double
    var luminance: Double

    init(_ b: HSLBand) {
        hue = b.hue
        saturation = b.saturation
        luminance = b.luminance
    }

    var value: HSLBand {
        var b = HSLBand()
        b.hue = hue
        b.saturation = saturation
        b.luminance = luminance
        return b
    }
}

private struct StoredFilter: Codable {
    var preset: String
    var intensity: Double
    var brightness: Double
    var contrast: Double
    var saturation: Double
    // 以下は後から追加した項目(旧ファイルにはないので省略可能、既定値 0)
    var exposure: Double?
    var temperature: Double?
    var highlights: Double?
    var shadows: Double?
    var sharpness: Double?
    // 第3弾: HSL(8 帯)と LUT
    var hsl: [StoredHSLBand]?
    var lutFileName: String?
    var lutIntensity: Double?

    init(_ f: FilterSettings) {
        preset = f.preset.rawValue
        intensity = f.intensity
        brightness = f.adjustments.brightness
        contrast = f.adjustments.contrast
        saturation = f.adjustments.saturation
        exposure = f.adjustments.exposure
        temperature = f.adjustments.temperature
        highlights = f.adjustments.highlights
        shadows = f.adjustments.shadows
        sharpness = f.adjustments.sharpness
        hsl = f.hsl.bands.map { StoredHSLBand($0) }
        lutFileName = f.lutFileName
        lutIntensity = f.lutIntensity
    }

    var value: FilterSettings {
        var f = FilterSettings()
        f.preset = FilterPreset(rawValue: preset) ?? .none
        f.intensity = intensity
        var a = ColorAdjustments()
        a.brightness = brightness
        a.contrast = contrast
        a.saturation = saturation
        a.exposure = exposure ?? 0
        a.temperature = temperature ?? 0
        a.highlights = highlights ?? 0
        a.shadows = shadows ?? 0
        a.sharpness = sharpness ?? 0
        f.adjustments = a
        var adjustment = HSLAdjustment()
        if let hsl {
            let count = adjustment.bands.count
            for (i, band) in hsl.prefix(count).enumerated() {
                adjustment.bands[i] = band.value
            }
        }
        f.hsl = adjustment
        // LUT ファイルが消えていれば LUT なしに戻す
        if let name = lutFileName, ProjectStore.resolveLUT(name) != nil {
            f.lutFileName = name
        } else {
            f.lutFileName = nil
        }
        f.lutIntensity = lutIntensity ?? 1
        return f
    }
}

private struct StoredRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ r: NormalizedRect) {
        x = r.x; y = r.y; width = r.width; height = r.height
    }

    var value: NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

private struct StoredAngle: Codable {
    var id: UUID
    var file: String
    var duration: Double
    var width: Double
    var height: Double
    var transform: StoredTransform
    var name: String
    var offset: Double
}

private struct StoredSwitch: Codable {
    var id: UUID
    var time: Double
    var angle: Int
}

private struct StoredClipAnimation: Codable {
    var inType: String
    var inDuration: Double
    var outType: String
    var outDuration: Double

    init(_ a: ClipAnimation) {
        inType = a.inType.rawValue
        inDuration = a.inDuration
        outType = a.outType.rawValue
        outDuration = a.outDuration
    }

    var value: ClipAnimation {
        var a = ClipAnimation()
        a.inType = ClipAnimationType(rawValue: inType) ?? .none
        a.inDuration = inDuration
        a.outType = ClipAnimationType(rawValue: outType) ?? .none
        a.outDuration = outDuration
        return a
    }
}

private struct StoredGeometry: Codable {
    var rotationQuarterTurns: Int
    var flipHorizontal: Bool
    var flipVertical: Bool
    var crop: StoredRect
    var zoom: Double
    var offsetX: Double
    var offsetY: Double

    init(_ g: ClipGeometry) {
        rotationQuarterTurns = g.rotationQuarterTurns
        flipHorizontal = g.flipHorizontal
        flipVertical = g.flipVertical
        crop = StoredRect(g.crop)
        zoom = g.zoom
        offsetX = g.offsetX
        offsetY = g.offsetY
    }

    var value: ClipGeometry {
        var g = ClipGeometry()
        g.rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        g.flipHorizontal = flipHorizontal
        g.flipVertical = flipVertical
        g.crop = crop.value
        g.zoom = zoom > 0 ? zoom : 1
        g.offsetX = offsetX
        g.offsetY = offsetY
        return g
    }
}

private struct StoredSpeedPoint: Codable {
    var position: Double
    var speed: Double
}

private struct StoredSpeedCurve: Codable {
    var enabled: Bool
    var points: [StoredSpeedPoint]
    var smoothSlow: Bool

    init(_ c: SpeedCurve) {
        enabled = c.enabled
        points = c.points.map { StoredSpeedPoint(position: $0.position, speed: $0.speed) }
        smoothSlow = c.smoothSlow
    }

    var value: SpeedCurve {
        var c = SpeedCurve()
        c.enabled = enabled
        if points.count >= 2 {
            c.points = points.map { SpeedPoint(position: $0.position, speed: $0.speed) }
        }
        c.smoothSlow = smoothSlow
        return c
    }
}

private struct StoredAudioEffects: Codable {
    var eqLow: Double
    var eqMid: Double
    var eqHigh: Double
    var pitchSemitones: Double
    var voicePreset: String
    var noiseReduction: Double

    init(_ e: AudioEffects) {
        eqLow = e.eqLow
        eqMid = e.eqMid
        eqHigh = e.eqHigh
        pitchSemitones = e.pitchSemitones
        voicePreset = e.voicePreset.rawValue
        noiseReduction = e.noiseReduction
    }

    var value: AudioEffects {
        var e = AudioEffects()
        e.eqLow = eqLow
        e.eqMid = eqMid
        e.eqHigh = eqHigh
        e.pitchSemitones = pitchSemitones
        e.voicePreset = VoicePreset(rawValue: voicePreset) ?? .none
        e.noiseReduction = noiseReduction
        return e
    }
}

private struct StoredClip: Codable {
    var id: UUID
    var file: String
    var duration: Double
    var width: Double
    var height: Double
    var transform: StoredTransform
    var hasAudio: Bool
    var name: String
    var startTime: Double
    var endTime: Double
    var speed: Double
    var filter: StoredFilter
    var isMuted: Bool
    var angles: [StoredAngle]
    var switches: [StoredSwitch]
    // クリップ音声設定(ClipAudioSettings)。後から追加したので省略可能
    var audioGain: Float?
    var audioLeadIn: Double?
    var audioTailOut: Double?
    // 第3弾(すべて省略可能)
    var audioEffects: StoredAudioEffects?
    var transition: StoredTransition?
    var animation: StoredClipAnimation?
    var geometry: StoredGeometry?
    var speedCurve: StoredSpeedCurve?
    var isReversed: Bool?
    var reversedFile: String?
    var stillImageFile: String?

    init(_ c: Clip) {
        id = c.id
        file = c.url.lastPathComponent
        duration = c.duration
        width = Double(c.naturalSize.width)
        height = Double(c.naturalSize.height)
        transform = StoredTransform(c.preferredTransform)
        hasAudio = c.hasAudio
        name = c.name
        startTime = c.startTime
        endTime = c.endTime
        speed = c.speed
        filter = StoredFilter(c.filter)
        isMuted = c.isMuted
        angles = c.multicam.angles.map { a in
            StoredAngle(id: a.id, file: a.url.lastPathComponent, duration: a.duration,
                        width: Double(a.naturalSize.width), height: Double(a.naturalSize.height),
                        transform: StoredTransform(a.preferredTransform), name: a.name, offset: a.offset)
        }
        switches = c.multicam.switches.map { StoredSwitch(id: $0.id, time: $0.time, angle: $0.angle) }
        audioGain = c.audio.gain
        audioLeadIn = c.audio.audioLeadIn
        audioTailOut = c.audio.audioTailOut
        audioEffects = StoredAudioEffects(c.audio.effects)
        transition = StoredTransition(c.transition)
        animation = StoredClipAnimation(c.animation)
        geometry = StoredGeometry(c.geometry)
        speedCurve = StoredSpeedCurve(c.speedCurve)
        isReversed = c.isReversed
        reversedFile = c.reversedURL?.lastPathComponent
        stillImageFile = c.stillImageURL?.lastPathComponent
    }

    /// 素材ファイル(静止画クリップなら画像)が消えていれば nil
    func makeClip() -> Clip? {
        var stillURL: URL? = nil
        if let stillFile = stillImageFile {
            guard let resolved = ProjectStore.resolveStillImage(stillFile) else { return nil }
            stillURL = resolved
        }
        guard let url = ProjectStore.resolveMedia(file) ?? stillURL else { return nil }
        var thumbnail: UIImage? = nil
        if let stillURL {
            thumbnail = MediaStore.makeImageClipThumbnail(url: stillURL, maxPixel: 320)
        }
        var clip = Clip(id: id, url: url, duration: duration,
                        naturalSize: CGSize(width: width, height: height),
                        preferredTransform: transform.value, hasAudio: hasAudio,
                        thumbnail: thumbnail, name: name)
        clip.startTime = startTime
        clip.endTime = endTime
        clip.speed = speed
        clip.filter = filter.value
        clip.isMuted = isMuted
        var clipAudio = ClipAudioSettings()
        clipAudio.gain = audioGain ?? 1
        clipAudio.audioLeadIn = audioLeadIn ?? 0
        clipAudio.audioTailOut = audioTailOut ?? 0
        clipAudio.effects = audioEffects?.value ?? AudioEffects()
        clip.audio = clipAudio
        var info = MulticamInfo()
        info.angles = angles.compactMap { sa in
            guard let aurl = ProjectStore.resolveMedia(sa.file) else { return nil }
            return CameraAngle(id: sa.id, url: aurl, duration: sa.duration,
                               naturalSize: CGSize(width: sa.width, height: sa.height),
                               preferredTransform: sa.transform.value, thumbnail: nil,
                               name: sa.name, offset: sa.offset)
        }
        if info.angles.count == angles.count {
            info.switches = switches.map { AngleSwitch(id: $0.id, time: $0.time, angle: $0.angle) }
        }
        clip.multicam = info
        clip.transition = transition?.value ?? ClipTransition()
        clip.animation = animation?.value ?? ClipAnimation()
        clip.geometry = geometry?.value ?? ClipGeometry()
        clip.speedCurve = speedCurve?.value ?? SpeedCurve()
        if let reversedFile, let reversedURL = ProjectStore.resolveMedia(reversedFile) {
            clip.reversedURL = reversedURL
            clip.isReversed = isReversed ?? false
        } else {
            // 逆再生ファイルが消えていれば通常再生に戻す
            clip.reversedURL = nil
            clip.isReversed = false
        }
        clip.stillImageURL = stillURL
        return clip
    }
}

private struct StoredWord: Codable {
    var text: String
    var start: Double
    var end: Double
}

private struct StoredCue: Codable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    var translatedText: String?
    /// 単語ごとの時刻(第3弾。省略可能)
    var words: [StoredWord]?

    init(_ c: SubtitleCue) {
        id = c.id
        start = c.start
        end = c.end
        text = c.text
        translatedText = c.translatedText
        words = c.words.isEmpty ? nil : c.words.map { StoredWord(text: $0.text, start: $0.start, end: $0.end) }
    }

    var value: SubtitleCue {
        var cue = SubtitleCue(id: id, start: start, end: end, text: text, translatedText: translatedText)
        cue.words = (words ?? []).map { SubtitleWord(text: $0.text, start: $0.start, end: $0.end) }
        return cue
    }
}

/// オーバーレイ(Bロール / ワイプ / 写真)。素材はファイル名だけを保存する
private struct StoredOverlay: Codable {
    var id: UUID
    var file: String
    var isImage: Bool
    var name: String
    var width: Double
    var height: Double
    var transform: StoredTransform
    var sourceDuration: Double
    var start: Double
    var duration: Double
    var sourceStart: Double
    var speed: Double
    var frame: StoredRect
    var fit: String
    var opacity: Double
    var cornerRadius: Double
    var volume: Float
    var kenBurnsEnabled: Bool
    var kenBurnsStart: StoredRect
    var kenBurnsEnd: StoredRect
    var filter: StoredFilter
    var fadeIn: Double
    var fadeOut: Double
    // 第3弾(省略可能)
    var keyframes: [StoredKeyframe]?
    var blendMode: String?

    init(_ o: OverlayClip) {
        id = o.id
        file = o.url.lastPathComponent
        isImage = o.isImage
        name = o.name
        width = Double(o.naturalSize.width)
        height = Double(o.naturalSize.height)
        transform = StoredTransform(o.preferredTransform)
        sourceDuration = o.sourceDuration
        start = o.start
        duration = o.duration
        sourceStart = o.sourceStart
        speed = o.speed
        frame = StoredRect(o.frame)
        fit = o.fit.rawValue
        opacity = o.opacity
        cornerRadius = o.cornerRadius
        volume = o.volume
        kenBurnsEnabled = o.kenBurns.enabled
        kenBurnsStart = StoredRect(o.kenBurns.startCrop)
        kenBurnsEnd = StoredRect(o.kenBurns.endCrop)
        filter = StoredFilter(o.filter)
        fadeIn = o.fadeIn
        fadeOut = o.fadeOut
        keyframes = o.keyframes.map { StoredKeyframe($0) }
        blendMode = o.blendMode
    }

    /// 素材ファイルが消えていれば nil
    func makeOverlay() -> OverlayClip? {
        guard let url = ProjectStore.resolveMedia(file) else { return nil }
        var o = OverlayClip(id: id, url: url, isImage: isImage, name: name,
                            naturalSize: CGSize(width: width, height: height),
                            preferredTransform: transform.value,
                            sourceDuration: sourceDuration, start: start, duration: duration)
        o.sourceStart = sourceStart
        o.speed = speed
        o.frame = frame.value
        o.fit = OverlayFit(rawValue: fit) ?? .fill
        o.opacity = opacity
        o.cornerRadius = cornerRadius
        o.volume = volume
        o.kenBurns = KenBurns(enabled: kenBurnsEnabled, startCrop: kenBurnsStart.value, endCrop: kenBurnsEnd.value)
        o.filter = filter.value
        o.fadeIn = fadeIn
        o.fadeOut = fadeOut
        o.keyframes = (keyframes ?? []).map { $0.value }
        o.blendMode = blendMode
        return o
    }
}

/// ナレーション(録音した音声)。素材はファイル名だけを保存する
private struct StoredNarration: Codable {
    var id: UUID
    var file: String
    var name: String
    var start: Double
    var sourceStart: Double
    var duration: Double
    var volume: Float
    var gain: Float
    /// 第3弾(省略可能)
    var effects: StoredAudioEffects?

    init(_ n: NarrationClip) {
        id = n.id
        file = n.url.lastPathComponent
        name = n.name
        start = n.start
        sourceStart = n.sourceStart
        duration = n.duration
        volume = n.volume
        gain = n.gain
        effects = StoredAudioEffects(n.effects)
    }

    /// 音声ファイルが消えていれば nil
    func makeNarration() -> NarrationClip? {
        guard let url = ProjectStore.resolveMedia(file) else { return nil }
        var n = NarrationClip(id: id, url: url, name: name, start: start, duration: duration)
        n.sourceStart = sourceStart
        n.volume = volume
        n.gain = gain
        n.effects = effects?.value ?? AudioEffects()
        return n
    }
}

private struct StoredStroke: Codable {
    var points: [StoredPoint]
    var colorHex: String
    var width: Double

    init(_ s: DrawingStroke) {
        points = s.points.map { StoredPoint($0) }
        colorHex = s.colorHex
        width = s.width
    }

    var value: DrawingStroke {
        var s = DrawingStroke(points: points.map { $0.value })
        s.colorHex = colorHex
        s.width = width
        return s
    }
}

private struct StoredDrawing: Codable {
    var id: UUID
    var start: Double
    var duration: Double
    var strokes: [StoredStroke]
    var revealDuration: Double

    init(_ d: DrawingClip) {
        id = d.id
        start = d.start
        duration = d.duration
        strokes = d.strokes.map { StoredStroke($0) }
        revealDuration = d.revealDuration
    }

    var value: DrawingClip {
        var d = DrawingClip(start: start)
        d.id = id
        d.duration = duration
        d.strokes = strokes.map { $0.value }
        d.revealDuration = revealDuration
        return d
    }
}

private struct StoredMarker: Codable {
    var id: UUID
    var time: Double
    var name: String
    var kind: String

    init(_ m: TimelineMarker) {
        id = m.id
        time = m.time
        name = m.name
        kind = m.kind.rawValue
    }

    var value: TimelineMarker {
        var m = TimelineMarker(time: time)
        m.id = id
        m.name = name
        m.kind = MarkerKind(rawValue: kind) ?? .note
        return m
    }
}

private struct StoredWatermark: Codable {
    var enabled: Bool
    var imageFile: String?
    var text: String
    var corner: String
    var opacity: Double
    var sizeRatio: Double

    init(_ w: WatermarkSettings) {
        enabled = w.enabled
        imageFile = w.imageURL?.lastPathComponent
        text = w.text
        corner = w.corner.rawValue
        opacity = w.opacity
        sizeRatio = w.sizeRatio
    }

    var value: WatermarkSettings {
        var w = WatermarkSettings()
        w.enabled = enabled
        w.imageURL = imageFile.flatMap { ProjectStore.resolveMedia($0) }
        w.text = text
        w.corner = WatermarkCorner(rawValue: corner) ?? .bottomRight
        w.opacity = opacity
        w.sizeRatio = sizeRatio
        return w
    }
}

private struct StoredCover: Codable {
    var frameTime: Double
    var imageFile: String?
    var title: String
    var memoText: String
    var paper: String
    var memoCenter: StoredPoint
    var memoWidthRatio: Double
    var memoRotation: Double
    var fontName: String?
    var applyLook: Bool

    init(_ c: CoverSettings) {
        frameTime = c.frameTime
        imageFile = c.imageURL?.lastPathComponent
        title = c.title
        memoText = c.memoText
        paper = c.paper.rawValue
        memoCenter = StoredPoint(c.memoCenter)
        memoWidthRatio = c.memoWidthRatio
        memoRotation = c.memoRotation
        fontName = c.fontName
        applyLook = c.applyLook
    }

    var value: CoverSettings {
        var c = CoverSettings()
        c.frameTime = frameTime
        c.imageURL = imageFile.flatMap { ProjectStore.resolveMedia($0) }
        c.title = title
        c.memoText = memoText
        c.paper = MemoPaper(rawValue: paper) ?? .yellow
        c.memoCenter = memoCenter.value
        c.memoWidthRatio = memoWidthRatio
        c.memoRotation = memoRotation
        c.fontName = fontName
        c.applyLook = applyLook
        return c
    }
}

private struct StoredLowerThird: Codable {
    var id: UUID
    var kind: String
    var start: Double
    var duration: Double
    var primary: String
    var secondary: String
}

/// project.json 全体。version 1(旧形式)も読める
private struct ProjectFile: Codable {
    var version = 2
    var documentary: StoredDocumentary?
    var titleCards: [StoredTitleCard]?
    var lowerThirds: [StoredLowerThird]?
    var overlays: [StoredOverlay]?
    var narration: [StoredNarration]?
    // 第3弾(省略可能)
    var textClips: [StoredTextClip]?
    var drawings: [StoredDrawing]?
    var markers: [StoredMarker]?
    var watermark: StoredWatermark?
    var cover: StoredCover?
    var clips: [StoredClip]
    var subtitles: [StoredCue]
    /// version 2 以降の字幕スタイルと出力設定(nil なら下の旧形式の項目から復元する)
    var subtitleStyle: StoredSubtitleStyle?
    var canvas: StoredCanvas?
    // 旧形式(version 1)の字幕スタイル。新しいファイルには書かない
    var subtitlePosition: String?
    var subtitleColor: String?
    var subtitleSize: Double?
    var subtitleBackground: Bool?
    var subtitleMode: String?
    var bgmFile: String?
    var bgmName: String?
    var bgmVolume: Float
    var originalVolume: Float
    var bgmFadeOut: Bool
    // 旧形式(version 1)の出力設定。新しいファイルには書かない
    var aspect: String?
    var scaling: String?
    var resolution: String?
    var quality: String?
    var frameRate: Int?
    var codec: String?
    var bitrateMbps: Double?
    var audioBitrateKbps: Int?
    var fileFormat: String?
    var preserveHDR: Bool?
    var burnInSubtitles: Bool?

    init(snapshot s: ProjectSnapshot) {
        clips = s.clips.map { StoredClip($0) }
        subtitles = s.subtitles.map { StoredCue($0) }
        subtitleStyle = StoredSubtitleStyle(s.subtitleStyle)
        canvas = StoredCanvas(s.canvas)
        bgmFile = s.audio.bgmURL?.lastPathComponent
        bgmName = s.audio.bgmName
        bgmVolume = s.audio.bgmVolume
        originalVolume = s.audio.originalVolume
        bgmFadeOut = s.audio.bgmFadeOut
        documentary = StoredDocumentary(s.documentary)
        titleCards = s.titleCards.map { StoredTitleCard($0) }
        lowerThirds = s.lowerThirds.map { StoredLowerThird(id: $0.id, kind: $0.kind.rawValue, start: $0.start, duration: $0.duration, primary: $0.primary, secondary: $0.secondary) }
        overlays = s.overlays.map { StoredOverlay($0) }
        narration = s.narration.map { StoredNarration($0) }
        textClips = s.textClips.map { StoredTextClip($0) }
        drawings = s.drawings.map { StoredDrawing($0) }
        markers = s.markers.map { StoredMarker($0) }
        watermark = StoredWatermark(s.watermark)
        cover = StoredCover(s.cover)
    }

    /// 旧形式(平らな項目)から字幕スタイルを復元
    private func legacySubtitleStyle() -> SubtitleStyle {
        var style = SubtitleStyle()
        style.position = subtitlePosition.flatMap { SubtitlePosition(rawValue: $0) } ?? .bottom
        style.color = subtitleColor.flatMap { SubtitleColor(rawValue: $0) } ?? .white
        if let size = subtitleSize, size > 0 { style.sizeRatio = CGFloat(size) }
        style.hasBackground = subtitleBackground ?? style.hasBackground
        style.displayMode = subtitleMode.flatMap { SubtitleDisplayMode(rawValue: $0) } ?? .original
        return style
    }

    /// 旧形式(平らな項目)から出力設定を復元
    private func legacyCanvas() -> CanvasSettings {
        let defaults = CanvasSettings()
        var c = CanvasSettings()
        c.aspect = aspect.flatMap { CanvasAspect(rawValue: $0) } ?? .original
        c.scaling = scaling.flatMap { ScalingMode(rawValue: $0) } ?? .fit
        c.resolution = resolution.flatMap { ResolutionCap(rawValue: $0) } ?? .fhd1080
        c.quality = quality.flatMap { ExportQuality(rawValue: $0) } ?? .standard
        c.frameRate = frameRate ?? defaults.frameRate
        c.codec = codec.flatMap { ExportCodec(rawValue: $0) } ?? defaults.codec
        c.bitrateMbps = bitrateMbps
        c.audioBitrateKbps = audioBitrateKbps ?? defaults.audioBitrateKbps
        c.fileFormat = fileFormat.flatMap { ExportFileFormat(rawValue: $0) } ?? defaults.fileFormat
        c.preserveHDR = preserveHDR ?? defaults.preserveHDR
        c.burnInSubtitles = burnInSubtitles ?? defaults.burnInSubtitles
        return c
    }

    func makeSnapshot() -> ProjectSnapshot {
        let restoredClips: [Clip] = clips.compactMap { $0.makeClip() }

        let style = subtitleStyle?.value ?? legacySubtitleStyle()

        var audio = AudioSettings()
        if let f = bgmFile, let url = ProjectStore.resolveMedia(f) {
            audio.bgmURL = url
            audio.bgmName = bgmName
        }
        audio.bgmVolume = bgmVolume
        audio.originalVolume = originalVolume
        audio.bgmFadeOut = bgmFadeOut

        let canvasSettings = canvas?.value ?? legacyCanvas()

        return ProjectSnapshot(
            clips: restoredClips,
            subtitles: subtitles.map { $0.value },
            subtitleStyle: style, audio: audio, canvas: canvasSettings,
            documentary: documentary?.value ?? DocumentaryStyle(),
            titleCards: (titleCards ?? []).map { $0.value },
            lowerThirds: (lowerThirds ?? []).map { LowerThird(id: $0.id, kind: CaptionKind(rawValue: $0.kind) ?? .nameplate, start: $0.start, duration: $0.duration, primary: $0.primary, secondary: $0.secondary) },
            overlays: (overlays ?? []).compactMap { $0.makeOverlay() },
            narration: (narration ?? []).compactMap { $0.makeNarration() },
            textClips: (textClips ?? []).map { $0.value },
            drawings: (drawings ?? []).map { $0.value },
            markers: (markers ?? []).map { $0.value },
            watermark: watermark?.value ?? WatermarkSettings(),
            cover: cover?.value ?? CoverSettings())
    }

    // MARK: 素材ファイル名の列挙・書き換え(パッケージ用)

    /// 参照している素材ファイル名(重複なし、出現順)。media は mediaDirectory 直下、luts は LUTs 内
    func referencedFileNames() -> (media: [String], luts: [String]) {
        var media: [String] = []
        var luts: [String] = []
        func addMedia(_ name: String?) {
            guard let name, !name.isEmpty, !media.contains(name) else { return }
            media.append(name)
        }
        func addLUT(_ name: String?) {
            guard let name, !name.isEmpty, !luts.contains(name) else { return }
            luts.append(name)
        }
        for c in clips {
            addMedia(c.file)
            addMedia(c.reversedFile)
            addMedia(c.stillImageFile)
            for a in c.angles { addMedia(a.file) }
            addLUT(c.filter.lutFileName)
        }
        addMedia(bgmFile)
        for o in overlays ?? [] {
            addMedia(o.file)
            addLUT(o.filter.lutFileName)
        }
        for n in narration ?? [] { addMedia(n.file) }
        addMedia(watermark?.imageFile)
        addMedia(cover?.imageFile)
        return (media, luts)
    }

    /// 素材ファイル名を書き換える(mapping に無い名前はそのまま)
    mutating func rewriteFileNames(media: [String: String], luts: [String: String]) {
        func m(_ name: String) -> String { media[name] ?? name }
        func mo(_ name: String?) -> String? { name.map { media[$0] ?? $0 } }
        func lo(_ name: String?) -> String? { name.map { luts[$0] ?? $0 } }
        for i in clips.indices {
            clips[i].file = m(clips[i].file)
            clips[i].reversedFile = mo(clips[i].reversedFile)
            clips[i].stillImageFile = mo(clips[i].stillImageFile)
            for j in clips[i].angles.indices {
                clips[i].angles[j].file = m(clips[i].angles[j].file)
            }
            clips[i].filter.lutFileName = lo(clips[i].filter.lutFileName)
        }
        bgmFile = mo(bgmFile)
        if var list = overlays {
            for i in list.indices {
                list[i].file = m(list[i].file)
                list[i].filter.lutFileName = lo(list[i].filter.lutFileName)
            }
            overlays = list
        }
        if var list = narration {
            for i in list.indices {
                list[i].file = m(list[i].file)
            }
            narration = list
        }
        if var w = watermark {
            w.imageFile = mo(w.imageFile)
            watermark = w
        }
        if var c = cover {
            c.imageFile = mo(c.imageFile)
            cover = c
        }
    }
}
