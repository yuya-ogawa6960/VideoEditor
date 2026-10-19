import Foundation
import AVFoundation
import SwiftUI
import Observation

// =====================================================================
// アプリ全体の「契約」となる型定義。
// 他のファイルはここで定義された型・プロパティ名に合わせて実装する。
// =====================================================================

// MARK: - 共通ヘルパー

/// preferredTransform(回転)を反映した実際の表示サイズ
func orientedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
    let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
}

// MARK: - フィルタ

enum FilterPreset: String, CaseIterable, Identifiable {
    case none, mono, noir, sepia, chrome, fade, instant, process, transfer, tonal, vivid, cool, warm, vignette

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .mono: return "モノクロ"
        case .noir: return "ノワール"
        case .sepia: return "セピア"
        case .chrome: return "クローム"
        case .fade: return "フェード"
        case .instant: return "インスタント"
        case .process: return "プロセス"
        case .transfer: return "トランスファー"
        case .tonal: return "トーナル"
        case .vivid: return "ビビッド"
        case .cool: return "クール"
        case .warm: return "ウォーム"
        case .vignette: return "ビネット"
        }
    }
}

struct ColorAdjustments: Equatable {
    /// -0.5 ... 0.5 (0 = 変更なし)
    var brightness: Double = 0
    /// 0.5 ... 1.5 (1 = 変更なし)
    var contrast: Double = 1
    /// 0 ... 2 (1 = 変更なし)
    var saturation: Double = 1

    var isIdentity: Bool { brightness == 0 && contrast == 1 && saturation == 1 }
}

struct FilterSettings: Equatable {
    var preset: FilterPreset = .none
    /// 0 ... 1
    var intensity: Double = 1
    var adjustments = ColorAdjustments()

    var isIdentity: Bool { (preset == .none || intensity <= 0) && adjustments.isIdentity }
}

// MARK: - マルチカム(複数台カメラ切替)

/// メインクリップと同時に撮影した別アングル素材
struct CameraAngle: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let duration: Double
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    var thumbnail: UIImage?
    var name: String
    /// アングル素材上の時刻 = メインクリップ素材上の時刻 + offset(秒)
    var offset: Double

    init(id: UUID = UUID(), url: URL, duration: Double, naturalSize: CGSize,
         preferredTransform: CGAffineTransform, thumbnail: UIImage?, name: String, offset: Double = 0) {
        self.id = id
        self.url = url
        self.duration = duration
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.thumbnail = thumbnail
        self.name = name
        self.offset = offset
    }

    var displaySize: CGSize { orientedSize(naturalSize: naturalSize, transform: preferredTransform) }

    static func == (lhs: CameraAngle, rhs: CameraAngle) -> Bool {
        lhs.id == rhs.id && lhs.offset == rhs.offset && lhs.name == rhs.name
    }
}

/// アングル切替点
struct AngleSwitch: Identifiable, Equatable {
    var id = UUID()
    /// メインクリップの元素材上の時刻(秒)。この時刻以降 angle を使う
    var time: Double
    /// 0 = メインクリップ自身、1以上 = angles[angle - 1]
    var angle: Int
}

struct MulticamInfo: Equatable {
    var angles: [CameraAngle] = []
    /// time 昇順(sortSwitches() で整える)
    var switches: [AngleSwitch] = []

    var isActive: Bool { !angles.isEmpty }

    /// 元素材上の時刻 sourceTime で使うアングル番号(0 = メイン)
    func angleIndex(at sourceTime: Double) -> Int {
        var current = 0
        for s in switches where s.time <= sourceTime {
            current = s.angle
        }
        return min(max(current, 0), angles.count)
    }

    mutating func sortSwitches() {
        switches.sort { $0.time < $1.time }
    }
}

// MARK: - クリップ

struct Clip: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// 元素材全体の長さ(秒)
    let duration: Double
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let hasAudio: Bool
    var thumbnail: UIImage?
    var name: String
    /// トリミング範囲(元素材上の秒)
    var startTime: Double
    var endTime: Double
    /// 0.25 ... 4 (1 = 等速)
    var speed: Double
    var filter: FilterSettings
    var multicam: MulticamInfo
    var isMuted: Bool

    init(id: UUID = UUID(), url: URL, duration: Double, naturalSize: CGSize,
         preferredTransform: CGAffineTransform, hasAudio: Bool, thumbnail: UIImage?, name: String) {
        self.id = id
        self.url = url
        self.duration = duration
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.hasAudio = hasAudio
        self.thumbnail = thumbnail
        self.name = name
        self.startTime = 0
        self.endTime = duration
        self.speed = 1
        self.filter = FilterSettings()
        self.multicam = MulticamInfo()
        self.isMuted = false
    }

    /// トリミング後の長さ(元素材の秒)
    var trimmedDuration: Double { max(0, endTime - startTime) }
    /// 速度を反映した出力上の長さ(秒)
    var outputDuration: Double { trimmedDuration / max(speed, 0.01) }
    var isTrimmed: Bool { startTime > 0.001 || endTime < duration - 0.001 }
    var displaySize: CGSize { orientedSize(naturalSize: naturalSize, transform: preferredTransform) }

    /// 新しい ID を持つ複製
    func duplicated() -> Clip {
        var copy = Clip(url: url, duration: duration, naturalSize: naturalSize,
                        preferredTransform: preferredTransform, hasAudio: hasAudio,
                        thumbnail: thumbnail, name: name)
        copy.startTime = startTime
        copy.endTime = endTime
        copy.speed = speed
        copy.filter = filter
        copy.multicam = multicam
        copy.isMuted = isMuted
        return copy
    }

    static func == (lhs: Clip, rhs: Clip) -> Bool {
        lhs.id == rhs.id
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
            && lhs.speed == rhs.speed
            && lhs.filter == rhs.filter
            && lhs.multicam == rhs.multicam
            && lhs.isMuted == rhs.isMuted
            && lhs.name == rhs.name
    }
}

// MARK: - 字幕

enum SubtitlePosition: String, CaseIterable, Identifiable {
    case top, center, bottom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .top: return "上"
        case .center: return "中央"
        case .bottom: return "下"
        }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable {
    case white, yellow, cyan, black
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .white: return "白"
        case .yellow: return "黄"
        case .cyan: return "水色"
        case .black: return "黒"
        }
    }
    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .yellow: return UIColor(red: 1.0, green: 0.85, blue: 0.1, alpha: 1)
        case .cyan: return UIColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 1)
        case .black: return .black
        }
    }
    var color: Color { Color(uiColor: uiColor) }
}

enum SubtitleDisplayMode: String, CaseIterable, Identifiable {
    case original, translated, both
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .original: return "原文"
        case .translated: return "英訳"
        case .both: return "両方"
        }
    }
}

struct SubtitleStyle: Equatable {
    var position: SubtitlePosition = .bottom
    var color: SubtitleColor = .white
    /// 出力映像の幅に対する文字サイズ比(0.03 ... 0.10)
    var sizeRatio: CGFloat = 0.045
    var hasBackground: Bool = true
    var displayMode: SubtitleDisplayMode = .original
}

/// 字幕1件(出力タイムライン上の秒)
struct SubtitleCue: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var translatedText: String? = nil

    var duration: Double { max(0, end - start) }

    /// 表示モードに応じた行(上から順)。空なら表示しない
    func displayLines(mode: SubtitleDisplayMode) -> [String] {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = (translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .original:
            return original.isEmpty ? [] : [original]
        case .translated:
            return translated.isEmpty ? (original.isEmpty ? [] : [original]) : [translated]
        case .both:
            return [original, translated].filter { !$0.isEmpty }
        }
    }
}

// MARK: - 音声

struct AudioSettings: Equatable {
    /// アプリ内にコピー済みの BGM ファイル
    var bgmURL: URL? = nil
    var bgmName: String? = nil
    /// 0 ... 1
    var bgmVolume: Float = 0.5
    /// 0 ... 1
    var originalVolume: Float = 1.0
    /// 最後の 2 秒で BGM をフェードアウト
    var bgmFadeOut: Bool = true
}

// MARK: - 出力形式

enum CanvasAspect: String, CaseIterable, Identifiable {
    case original, portrait9x16, landscape16x9, square, portrait4x5
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .original: return "元のまま"
        case .portrait9x16: return "9:16 縦(ショート/リール)"
        case .landscape16x9: return "16:9 横(YouTube)"
        case .square: return "1:1 正方形"
        case .portrait4x5: return "4:5 縦(投稿)"
        }
    }
    /// 幅 / 高さ。original は nil
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .portrait9x16: return 9.0 / 16.0
        case .landscape16x9: return 16.0 / 9.0
        case .square: return 1
        case .portrait4x5: return 4.0 / 5.0
        }
    }
}

enum ScalingMode: String, CaseIterable, Identifiable {
    case fit, fitBlur, fill
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fit: return "収める(黒帯)"
        case .fitBlur: return "収める(ぼかし背景)"
        case .fill: return "埋める(クロップ)"
        }
    }
}

enum ResolutionCap: String, CaseIterable, Identifiable {
    case uhd4k, fhd1080, hd720
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .uhd4k: return "4K"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        }
    }
    /// 短辺の最大ピクセル数
    var maxShortSide: CGFloat {
        switch self {
        case .uhd4k: return 2160
        case .fhd1080: return 1080
        case .hd720: return 720
        }
    }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case high, standard, small
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .high: return "高画質"
        case .standard: return "標準"
        case .small: return "軽量(SNS向け)"
        }
    }
    /// 1080p 相当でのおおよその映像ビットレート(bps)。解像度に比例して換算する
    var videoBitrateAt1080p: Double {
        switch self {
        case .high: return 16_000_000
        case .standard: return 10_000_000
        case .small: return 6_000_000
        }
    }
}

struct CanvasSettings: Equatable {
    var aspect: CanvasAspect = .original
    var scaling: ScalingMode = .fit
    var resolution: ResolutionCap = .fhd1080
    var quality: ExportQuality = .standard
    var frameRate: Int = 30
}

// MARK: - プロジェクト

/// バックグラウンド処理に渡すための値コピー
struct ProjectSnapshot: Equatable {
    var clips: [Clip]
    var subtitles: [SubtitleCue]
    var subtitleStyle: SubtitleStyle
    var audio: AudioSettings
    var canvas: CanvasSettings
    var documentary = DocumentaryStyle()
    var titleCards: [TitleCard] = []
    var lowerThirds: [LowerThird] = []

    var totalDuration: Double { clips.reduce(0) { $0 + $1.outputDuration } }
    var isEmpty: Bool { clips.isEmpty }
}

@Observable
final class EditorProject {
    var clips: [Clip] = []
    var subtitles: [SubtitleCue] = []
    var subtitleStyle = SubtitleStyle()
    var audio = AudioSettings()
    var canvas = CanvasSettings()
    var documentary = DocumentaryStyle()
    var titleCards: [TitleCard] = []
    var lowerThirds: [LowerThird] = []

    var totalDuration: Double { clips.reduce(0) { $0 + $1.outputDuration } }
    var isEmpty: Bool { clips.isEmpty }

    func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(clips: clips, subtitles: subtitles, subtitleStyle: subtitleStyle,
                        audio: audio, canvas: canvas, documentary: documentary,
                        titleCards: titleCards, lowerThirds: lowerThirds)
    }

    // MARK: タイムライン計算

    /// 各クリップの出力タイムライン上の開始時刻
    func clipStartTimes() -> [Double] {
        var result: [Double] = []
        var t = 0.0
        for clip in clips {
            result.append(t)
            t += clip.outputDuration
        }
        return result
    }

    /// 出力タイムライン上の時刻 → (クリップ番号, 元素材上の時刻)
    func locate(timelineTime: Double) -> (index: Int, sourceTime: Double)? {
        guard !clips.isEmpty else { return nil }
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            let end = t + clip.outputDuration
            if timelineTime < end || i == clips.count - 1 {
                let local = max(0, min(timelineTime - t, clip.outputDuration))
                return (i, clip.startTime + local * clip.speed)
            }
            t = end
        }
        return nil
    }

    // MARK: クリップ操作

    func index(of clipID: UUID) -> Int? {
        clips.firstIndex(where: { $0.id == clipID })
    }

    func clipBinding(id: UUID) -> Binding<Clip>? {
        guard let initial = clips.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.clips.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.index(of: id) else { return }
                self.clips[i] = newValue
            }
        )
    }

    func removeClip(id: UUID) {
        clips.removeAll { $0.id == id }
    }

    func duplicateClip(id: UUID) {
        guard let i = index(of: id) else { return }
        clips.insert(clips[i].duplicated(), at: i + 1)
    }

    /// 元素材上の時刻 sourceTime で前後に分割
    @discardableResult
    func splitClip(id: UUID, atSourceTime sourceTime: Double) -> Bool {
        guard let i = index(of: id) else { return false }
        let original = clips[i]
        let minimum = 0.2
        guard sourceTime > original.startTime + minimum, sourceTime < original.endTime - minimum else { return false }
        var first = original
        first.endTime = sourceTime
        var second = original.duplicated()
        second.startTime = sourceTime
        clips[i] = first
        clips.insert(second, at: i + 1)
        return true
    }

    func applyFilterToAllClips(_ filter: FilterSettings) {
        for i in clips.indices { clips[i].filter = filter }
    }

    // MARK: 字幕操作

    @discardableResult
    func addSubtitle(at time: Double, duration: Double = 3, text: String = "新しい字幕") -> SubtitleCue {
        let start = max(0, time)
        let cue = SubtitleCue(start: start, end: start + duration, text: text)
        subtitles.append(cue)
        sortSubtitles()
        return cue
    }

    func sortSubtitles() {
        subtitles.sort { $0.start < $1.start }
    }

    func removeSubtitle(id: UUID) {
        subtitles.removeAll { $0.id == id }
    }

    func subtitleBinding(id: UUID) -> Binding<SubtitleCue>? {
        guard let initial = subtitles.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.subtitles.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.subtitles.firstIndex(where: { $0.id == id }) else { return }
                self.subtitles[i] = newValue
            }
        )
    }
}
