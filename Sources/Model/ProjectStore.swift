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
}

// MARK: - 保存形式

private struct StoredTransform: Codable {
    var a, b, c, d, tx, ty: Double
    init(_ t: CGAffineTransform) {
        a = Double(t.a); b = Double(t.b); c = Double(t.c); d = Double(t.d); tx = Double(t.tx); ty = Double(t.ty)
    }
    var value: CGAffineTransform {
        CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
    }
}

private struct StoredFilter: Codable {
    var preset: String
    var intensity: Double
    var brightness: Double
    var contrast: Double
    var saturation: Double

    init(_ f: FilterSettings) {
        preset = f.preset.rawValue
        intensity = f.intensity
        brightness = f.adjustments.brightness
        contrast = f.adjustments.contrast
        saturation = f.adjustments.saturation
    }

    var value: FilterSettings {
        var f = FilterSettings()
        f.preset = FilterPreset(rawValue: preset) ?? .none
        f.intensity = intensity
        f.adjustments = ColorAdjustments(brightness: brightness, contrast: contrast, saturation: saturation)
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
}

private struct StoredCue: Codable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    var translatedText: String?
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
        return o
    }
}

private struct ProjectFile: Codable {
    var version = 1
    var documentary: StoredDocumentary?
    var titleCards: [StoredTitleCard]?
    var lowerThirds: [StoredLowerThird]?
    var overlays: [StoredOverlay]?
    var clips: [StoredClip]
    var subtitles: [StoredCue]
    var subtitlePosition: String
    var subtitleColor: String
    var subtitleSize: Double
    var subtitleBackground: Bool
    var subtitleMode: String
    var bgmFile: String?
    var bgmName: String?
    var bgmVolume: Float
    var originalVolume: Float
    var bgmFadeOut: Bool
    var aspect: String
    var scaling: String
    var resolution: String
    var quality: String
    var frameRate: Int

    init(snapshot s: ProjectSnapshot) {
        clips = s.clips.map { c in
            StoredClip(
                id: c.id, file: c.url.lastPathComponent, duration: c.duration,
                width: Double(c.naturalSize.width), height: Double(c.naturalSize.height),
                transform: StoredTransform(c.preferredTransform), hasAudio: c.hasAudio, name: c.name,
                startTime: c.startTime, endTime: c.endTime, speed: c.speed,
                filter: StoredFilter(c.filter), isMuted: c.isMuted,
                angles: c.multicam.angles.map { a in
                    StoredAngle(id: a.id, file: a.url.lastPathComponent, duration: a.duration,
                                width: Double(a.naturalSize.width), height: Double(a.naturalSize.height),
                                transform: StoredTransform(a.preferredTransform), name: a.name, offset: a.offset)
                },
                switches: c.multicam.switches.map { StoredSwitch(id: $0.id, time: $0.time, angle: $0.angle) }
            )
        }
        subtitles = s.subtitles.map { StoredCue(id: $0.id, start: $0.start, end: $0.end, text: $0.text, translatedText: $0.translatedText) }
        subtitlePosition = s.subtitleStyle.position.rawValue
        subtitleColor = s.subtitleStyle.color.rawValue
        subtitleSize = Double(s.subtitleStyle.sizeRatio)
        subtitleBackground = s.subtitleStyle.hasBackground
        subtitleMode = s.subtitleStyle.displayMode.rawValue
        bgmFile = s.audio.bgmURL?.lastPathComponent
        bgmName = s.audio.bgmName
        bgmVolume = s.audio.bgmVolume
        originalVolume = s.audio.originalVolume
        bgmFadeOut = s.audio.bgmFadeOut
        aspect = s.canvas.aspect.rawValue
        scaling = s.canvas.scaling.rawValue
        resolution = s.canvas.resolution.rawValue
        quality = s.canvas.quality.rawValue
        frameRate = s.canvas.frameRate
        documentary = StoredDocumentary(s.documentary)
        titleCards = s.titleCards.map { StoredTitleCard(id: $0.id, start: $0.start, duration: $0.duration, heading: $0.heading, title: $0.title, opaqueBackground: $0.opaqueBackground) }
        lowerThirds = s.lowerThirds.map { StoredLowerThird(id: $0.id, kind: $0.kind.rawValue, start: $0.start, duration: $0.duration, primary: $0.primary, secondary: $0.secondary) }
        overlays = s.overlays.map { StoredOverlay($0) }
    }

    func makeSnapshot() -> ProjectSnapshot {
        let restoredClips: [Clip] = clips.compactMap { sc in
            guard let url = ProjectStore.resolveMedia(sc.file) else { return nil }
            var clip = Clip(id: sc.id, url: url, duration: sc.duration,
                            naturalSize: CGSize(width: sc.width, height: sc.height),
                            preferredTransform: sc.transform.value, hasAudio: sc.hasAudio,
                            thumbnail: nil, name: sc.name)
            clip.startTime = sc.startTime
            clip.endTime = sc.endTime
            clip.speed = sc.speed
            clip.filter = sc.filter.value
            clip.isMuted = sc.isMuted
            var info = MulticamInfo()
            info.angles = sc.angles.compactMap { sa in
                guard let aurl = ProjectStore.resolveMedia(sa.file) else { return nil }
                return CameraAngle(id: sa.id, url: aurl, duration: sa.duration,
                                   naturalSize: CGSize(width: sa.width, height: sa.height),
                                   preferredTransform: sa.transform.value, thumbnail: nil,
                                   name: sa.name, offset: sa.offset)
            }
            if info.angles.count == sc.angles.count {
                info.switches = sc.switches.map { AngleSwitch(id: $0.id, time: $0.time, angle: $0.angle) }
            }
            clip.multicam = info
            return clip
        }

        var style = SubtitleStyle()
        style.position = SubtitlePosition(rawValue: subtitlePosition) ?? .bottom
        style.color = SubtitleColor(rawValue: subtitleColor) ?? .white
        style.sizeRatio = CGFloat(subtitleSize)
        style.hasBackground = subtitleBackground
        style.displayMode = SubtitleDisplayMode(rawValue: subtitleMode) ?? .original

        var audio = AudioSettings()
        if let f = bgmFile, let url = ProjectStore.resolveMedia(f) {
            audio.bgmURL = url
            audio.bgmName = bgmName
        }
        audio.bgmVolume = bgmVolume
        audio.originalVolume = originalVolume
        audio.bgmFadeOut = bgmFadeOut

        var canvas = CanvasSettings()
        canvas.aspect = CanvasAspect(rawValue: aspect) ?? .original
        canvas.scaling = ScalingMode(rawValue: scaling) ?? .fit
        canvas.resolution = ResolutionCap(rawValue: resolution) ?? .fhd1080
        canvas.quality = ExportQuality(rawValue: quality) ?? .standard
        canvas.frameRate = frameRate

        return ProjectSnapshot(
            clips: restoredClips,
            subtitles: subtitles.map { SubtitleCue(id: $0.id, start: $0.start, end: $0.end, text: $0.text, translatedText: $0.translatedText) },
            subtitleStyle: style, audio: audio, canvas: canvas,
            documentary: documentary?.value ?? DocumentaryStyle(),
            titleCards: (titleCards ?? []).map { TitleCard(id: $0.id, start: $0.start, duration: $0.duration, heading: $0.heading, title: $0.title, opaqueBackground: $0.opaqueBackground) },
            lowerThirds: (lowerThirds ?? []).map { LowerThird(id: $0.id, kind: CaptionKind(rawValue: $0.kind) ?? .nameplate, start: $0.start, duration: $0.duration, primary: $0.primary, secondary: $0.secondary) },
            overlays: (overlays ?? []).compactMap { $0.makeOverlay() })
    }
}

private struct StoredDocumentary: Codable {
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

private struct StoredTitleCard: Codable {
    var id: UUID
    var start: Double
    var duration: Double
    var heading: String
    var title: String
    var opaqueBackground: Bool
}

private struct StoredLowerThird: Codable {
    var id: UUID
    var kind: String
    var start: Double
    var duration: Double
    var primary: String
    var secondary: String
}
