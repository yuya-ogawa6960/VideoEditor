import Foundation
import CoreGraphics
import UIKit

// =====================================================================
// 自動保存と復元。
// CapCut の口コミで多い「編集中に落ちて作業が消える」への対策として、
// 変更のたびに Documents/Projects/current.json へ保存し、起動時に読み込む。
// 素材ファイルは MediaStore.mediaDirectory にあるので、ファイル名だけを保存する
// (アプリ更新でコンテナのパスが変わっても復元できるように)。
// =====================================================================

enum ProjectStore {
    static var projectsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var currentURL: URL { projectsDirectory.appendingPathComponent("current.json") }

    private static let queue = DispatchQueue(label: "ProjectStore.save", qos: .utility)
    private static var pendingWork: DispatchWorkItem?
    private static let lock = NSLock()

    /// 0.5 秒間隔にまとめて保存する(スライダー操作中に書き込みすぎないように)
    static func scheduleSave(_ snapshot: ProjectSnapshot) {
        let work = DispatchWorkItem { saveNow(snapshot) }
        lock.lock()
        pendingWork?.cancel()
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    static func saveNow(_ snapshot: ProjectSnapshot) {
        let file = ProjectFile(snapshot: snapshot)
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: currentURL, options: .atomic)
        } catch {
            print("ProjectStore: save failed: \(error)")
        }
    }

    /// 保存済みのプロジェクトを読み込む。素材ファイルが消えているクリップは除外する
    static func load() -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: currentURL),
              let file = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return nil }
        return file.makeSnapshot()
    }

    static func deleteSaved() {
        lock.lock()
        pendingWork?.cancel()
        pendingWork = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: currentURL)
    }

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

private struct ProjectFile: Codable {
    var version = 1
    var documentary: StoredDocumentary?
    var titleCards: [StoredTitleCard]?
    var lowerThirds: [StoredLowerThird]?
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
            lowerThirds: (lowerThirds ?? []).map { LowerThird(id: $0.id, kind: CaptionKind(rawValue: $0.kind) ?? .nameplate, start: $0.start, duration: $0.duration, primary: $0.primary, secondary: $0.secondary) })
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
