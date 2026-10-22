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
        case .none: return String(localized: "なし")
        case .mono: return String(localized: "モノクロ")
        case .noir: return String(localized: "ノワール")
        case .sepia: return String(localized: "セピア")
        case .chrome: return String(localized: "クローム")
        case .fade: return String(localized: "フェード")
        case .instant: return String(localized: "インスタント")
        case .process: return String(localized: "プロセス")
        case .transfer: return String(localized: "トランスファー")
        case .tonal: return String(localized: "トーナル")
        case .vivid: return String(localized: "ビビッド")
        case .cool: return String(localized: "クール")
        case .warm: return String(localized: "ウォーム")
        case .vignette: return String(localized: "ビネット")
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
    /// -2 ... 2 EV (0 = 変更なし)
    var exposure: Double = 0
    /// -1 ... 1 (0 = 変更なし、負で青く、正で暖かく)
    var temperature: Double = 0
    /// -1 ... 1 (0 = 変更なし、負で明部を抑える)
    var highlights: Double = 0
    /// -1 ... 1 (0 = 変更なし、正で暗部を持ち上げる)
    var shadows: Double = 0
    /// 0 ... 1 (0 = 変更なし)
    var sharpness: Double = 0

    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && exposure == 0 && temperature == 0
            && highlights == 0 && shadows == 0 && sharpness == 0
    }
}

struct FilterSettings: Equatable {
    var preset: FilterPreset = .none
    /// 0 ... 1
    var intensity: Double = 1
    var adjustments = ColorAdjustments()
    var hsl = HSLAdjustment()
    /// 読み込んだ LUT(.cube)のファイル名(MediaStore.mediaDirectory/LUTs 内)。設定時は preset より優先
    var lutFileName: String? = nil
    /// LUT の強さ 0...1
    var lutIntensity: Double = 1

    var isIdentity: Bool { (preset == .none || intensity <= 0) && adjustments.isIdentity && hsl.isIdentity && lutFileName == nil }
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
    /// 音量そろえのゲイン、Jカット・Lカット(AudioTrackModels.swift)
    var audio: ClipAudioSettings
    /// このクリップの終わりから次のクリップへのトランジション
    var transition: ClipTransition
    /// イン・アウトのアニメーション
    var animation: ClipAnimation
    /// 切り抜き・回転・反転・ズーム
    var geometry: ClipGeometry
    /// 速度カーブ(enabled のとき speed より優先)
    var speedCurve: SpeedCurve
    /// 逆再生(reversedURL に逆再生済みファイルがあるときだけ有効)
    var isReversed: Bool
    var reversedURL: URL?
    /// 静止画クリップ(写真・フリーズフレーム)。設定時は url は無視され、この画像を表示する。hasAudio は false
    var stillImageURL: URL?
    /// マスク(Phase4Models.swift)
    var mask: MaskSettings
    /// 自動リフレーム(人物追尾)の解析結果
    var reframe: ReframeTrack
    /// 手ぶれ補正の解析結果
    var stabilization: StabilizationTrack
    /// ノイズ除去・美肌・簡易高画質化
    var enhance: ClipEnhancements
    /// 静止画クリップの 3D ズーム(奥行き情報がある写真のみ)
    var parallax: DepthParallax

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
        self.audio = ClipAudioSettings()
        self.transition = ClipTransition()
        self.animation = ClipAnimation()
        self.geometry = ClipGeometry()
        self.speedCurve = SpeedCurve()
        self.isReversed = false
        self.reversedURL = nil
        self.stillImageURL = nil
        self.mask = MaskSettings()
        self.reframe = ReframeTrack()
        self.stabilization = StabilizationTrack()
        self.enhance = ClipEnhancements()
        self.parallax = DepthParallax()
    }

    /// トリミング後の長さ(元素材の秒)
    var trimmedDuration: Double { max(0, endTime - startTime) }
    /// 速度を反映した出力上の長さ(秒)
    var outputDuration: Double {
        if speedCurve.enabled { return speedCurve.outputDuration(trimmed: trimmedDuration) }
        return trimmedDuration / max(speed, 0.01)
    }
    var isStill: Bool { stillImageURL != nil }
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
        copy.audio = audio
        copy.transition = transition
        copy.animation = animation
        copy.geometry = geometry
        copy.speedCurve = speedCurve
        copy.isReversed = isReversed
        copy.reversedURL = reversedURL
        copy.stillImageURL = stillImageURL
        copy.mask = mask
        copy.reframe = reframe
        copy.stabilization = stabilization
        copy.enhance = enhance
        copy.parallax = parallax
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
            && lhs.audio == rhs.audio
            && lhs.transition == rhs.transition
            && lhs.animation == rhs.animation
            && lhs.geometry == rhs.geometry
            && lhs.speedCurve == rhs.speedCurve
            && lhs.isReversed == rhs.isReversed
            && lhs.reversedURL == rhs.reversedURL
            && lhs.stillImageURL == rhs.stillImageURL
            && lhs.mask == rhs.mask
            && lhs.reframe == rhs.reframe
            && lhs.stabilization == rhs.stabilization
            && lhs.enhance == rhs.enhance
            && lhs.parallax == rhs.parallax
            && lhs.name == rhs.name
    }
}

// MARK: - 字幕

enum SubtitlePosition: String, CaseIterable, Identifiable {
    case top, center, bottom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .top: return String(localized: "上")
        case .center: return String(localized: "中央")
        case .bottom: return String(localized: "下")
        }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable {
    case white, yellow, cyan, black
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .white: return String(localized: "白")
        case .yellow: return String(localized: "黄")
        case .cyan: return String(localized: "水色")
        case .black: return String(localized: "黒")
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
        case .original: return String(localized: "原文")
        case .translated: return String(localized: "訳文")
        case .both: return String(localized: "両方")
        }
    }
}

struct SubtitleStyle: Equatable {
    var position: SubtitlePosition = .bottom
    var color: SubtitleColor = .white
    /// 出力映像の短い辺に対する文字サイズ比(0.02 ... 0.08)。既定はシネマ風
    var sizeRatio: CGFloat = 0.034
    var hasBackground: Bool = false
    var displayMode: SubtitleDisplayMode = .original
    /// 字幕テンプレート(カラオケ風など)。words が無い cue では plain と同じ描画
    var template: CaptionTemplate = .plain
    var highlightColorHex: String = "#FFD54A"
    /// nil = システムフォント
    var fontName: String? = nil
}

/// 字幕1件(出力タイムライン上の秒)
struct SubtitleCue: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var translatedText: String? = nil
    /// 単語ごとの時刻(カラオケ風字幕用)。空なら不明
    var words: [SubtitleWord] = []

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
        case .original: return String(localized: "元のまま")
        case .portrait9x16: return String(localized: "9:16 縦(ショート/リール)")
        case .landscape16x9: return String(localized: "16:9 横(YouTube)")
        case .square: return String(localized: "1:1 正方形")
        case .portrait4x5: return String(localized: "4:5 縦(投稿)")
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
        case .fit: return String(localized: "収める(黒帯)")
        case .fitBlur: return String(localized: "収める(ぼかし背景)")
        case .fill: return String(localized: "埋める(クロップ)")
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
        case .high: return String(localized: "高画質")
        case .standard: return String(localized: "標準")
        case .small: return String(localized: "軽量(SNS向け)")
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
    var resolution: ResolutionCap = .uhd4k
    var quality: ExportQuality = .standard
    var frameRate: Int = 30
    /// 書き出しの詳細設定
    var codec: ExportCodec = .auto
    /// nil = quality から自動。手動指定は Mbps
    var bitrateMbps: Double? = nil
    var audioBitrateKbps: Int = 192
    var fileFormat: ExportFileFormat = .mp4
    /// HDR(HLG 10bit)のまま書き出す(素材が HDR のときのみ有効)
    var preserveHDR: Bool = false
    /// 字幕を映像に焼き込む(false なら字幕は映像に入れず SRT 用)
    var burnInSubtitles: Bool = true
}

enum ExportCodec: String, CaseIterable, Identifiable {
    case auto, h264, hevc
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return String(localized: "自動")
        case .h264: return String(localized: "H.264(互換性重視)")
        case .hevc: return String(localized: "HEVC(高画質・小容量)")
        }
    }
}

enum ExportFileFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
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
    /// Bロール・ワイプ・写真などの重ね合わせ(メイン映像の上に描く)
    var overlays: [OverlayClip] = []
    /// ナレーション(録音した音声)のトラック
    var narration: [NarrationClip] = []
    /// 自由配置テキスト・ステッカー
    var textClips: [TextClip] = []
    /// 手書き
    var drawings: [DrawingClip] = []
    /// マーカー(メモ・チャプター・ビート)
    var markers: [TimelineMarker] = []
    var watermark = WatermarkSettings()
    var cover = CoverSettings()

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
    /// Bロール・ワイプ・写真などの重ね合わせ(メイン映像の上に描く)
    var overlays: [OverlayClip] = []
    /// ナレーション(録音した音声)のトラック
    var narration: [NarrationClip] = []
    /// 自由配置テキスト・ステッカー
    var textClips: [TextClip] = []
    /// 手書き
    var drawings: [DrawingClip] = []
    /// マーカー(メモ・チャプター・ビート)
    var markers: [TimelineMarker] = []
    var watermark = WatermarkSettings()
    var cover = CoverSettings()

    var totalDuration: Double { clips.reduce(0) { $0 + $1.outputDuration } }
    var isEmpty: Bool { clips.isEmpty }

    func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(clips: clips, subtitles: subtitles, subtitleStyle: subtitleStyle,
                        audio: audio, canvas: canvas, documentary: documentary,
                        titleCards: titleCards, lowerThirds: lowerThirds, overlays: overlays, narration: narration,
                        textClips: textClips, drawings: drawings, markers: markers, watermark: watermark, cover: cover)
    }

    // MARK: タイムライン計算

    /// 各クリップの出力タイムライン上の開始時刻(トランジションの重なりを反映。CompositionBuilder.timelineLayout と同じ)。
    /// 以前は長さを足すだけで重なりを引いていなかったので、トランジションのたびに後ろのクリップの位置が遅れていた
    func clipStartTimes() -> [Double] {
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        var result: [Double] = []
        result.reserveCapacity(clips.count)
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            result.append(i < layout.count ? layout[i].start : t)
            t += clip.outputDuration
        }
        return result
    }

    /// 出力タイムライン上の時刻 → (クリップ番号, 元素材上の時刻)
    /// 出力タイムライン上の時刻 → (クリップの番号, 元素材上の時刻)。
    /// トランジションの重なり(CompositionBuilder.timelineLayout)と速度カーブを反映する。
    /// 重なりの中では前のクリップを返す
    func locate(timelineTime: Double) -> (index: Int, sourceTime: Double)? {
        guard !clips.isEmpty else { return nil }
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        for (i, clip) in clips.enumerated() where i < layout.count {
            let placement = layout[i]
            if timelineTime < placement.end || i == clips.count - 1 {
                let local = max(0, min(timelineTime - placement.start, clip.outputDuration))
                return (i, clip.sourceTime(atOutputOffset: local))
            }
        }
        return nil
    }

    /// 指定したクリップの中での、出力タイムライン上の時刻 → 元素材上の時刻(クリップの外なら nil)
    func sourceTime(timelineTime: Double, inClip clipID: UUID) -> Double? {
        guard let i = index(of: clipID) else { return nil }
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        guard i < layout.count else { return nil }
        let placement = layout[i]
        guard timelineTime >= placement.start - 0.001, timelineTime <= placement.end + 0.001 else { return nil }
        let clip = clips[i]
        return clip.sourceTime(atOutputOffset: min(max(timelineTime - placement.start, 0), clip.outputDuration))
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

    /// クリップを削除し、その区間にあった字幕などの部品も一緒に消して後ろを詰める
    /// (TimelineRipple.swift)。最後のクリップを消したときは部品をすべて消す。
    func removeClip(id: UUID) {
        guard index(of: id) != nil else { return }
        let range = outputRange(ofClip: id)
        let oldTotal = CompositionBuilder.totalDuration(for: snapshot())
        clips.removeAll { $0.id == id }
        if clips.isEmpty {
            clearTimelineItems()
            return
        }
        guard let range else { return }
        let newTotal = CompositionBuilder.totalDuration(for: snapshot())
        // トランジションの重なりがあるので、実際に短くなった長さを使う
        let removed = max(0, min(oldTotal - newTotal, range.end - range.start))
        removeTimelineRange(from: range.start, to: range.start + removed)
    }

    /// 複数のクリップをまとめて削除する(後ろから 1 本ずつ removeClip して詰める)
    func removeClips(ids: Set<UUID>) {
        let ordered: [UUID] = clips.map { $0.id }.filter { ids.contains($0) }
        for id in ordered.reversed() {
            removeClip(id: id)
        }
    }

    /// 選んだクリップを(元の並び順のまま)ひとかたまりに寄せる。かたまりの先頭の位置を返す
    @discardableResult
    func gatherClips(ids: Set<UUID>) -> Range<Int>? {
        guard let first = clips.firstIndex(where: { ids.contains($0.id) }) else { return nil }
        let selected: [Clip] = clips.filter { ids.contains($0.id) }
        let before: [Clip] = clips[..<first].filter { !ids.contains($0.id) }
        let after: [Clip] = clips[first...].filter { !ids.contains($0.id) }
        clips = before + selected + after
        return before.count..<(before.count + selected.count)
    }

    /// 選んだクリップをひとかたまりにして、1 本ぶん前(-1)または後ろ(+1)へ動かす
    @discardableResult
    func moveClips(ids: Set<UUID>, by step: Int) -> Bool {
        guard let block = gatherClips(ids: ids), !block.isEmpty else { return false }
        if step < 0 {
            guard block.lowerBound > 0 else { return false }
            let moved = clips.remove(at: block.lowerBound - 1)
            clips.insert(moved, at: block.upperBound - 1)
        } else {
            guard block.upperBound < clips.count else { return false }
            let moved = clips.remove(at: block.upperBound)
            clips.insert(moved, at: block.lowerBound)
        }
        return true
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
    func addSubtitle(at time: Double, duration: Double = 3, text: String = String(localized: "新しい字幕")) -> SubtitleCue {
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

// MARK: - 重ね合わせの操作

extension EditorProject {
    func overlayBinding(id: UUID) -> Binding<OverlayClip>? {
        guard let initial = overlays.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.overlays.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.overlays.firstIndex(where: { $0.id == id }) else { return }
                self.overlays[i] = newValue
            }
        )
    }

    func removeOverlay(id: UUID) {
        overlays.removeAll { $0.id == id }
    }

    func sortOverlays() {
        overlays.sort { $0.start < $1.start }
    }
}

// MARK: - ナレーションの操作

extension EditorProject {
    func narrationBinding(id: UUID) -> Binding<NarrationClip>? {
        guard let initial = narration.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.narration.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.narration.firstIndex(where: { $0.id == id }) else { return }
                self.narration[i] = newValue
            }
        )
    }

    func removeNarration(id: UUID) {
        narration.removeAll { $0.id == id }
    }

    func sortNarration() {
        narration.sort { $0.start < $1.start }
    }
}

// MARK: - テキスト・手書き・マーカーの操作

extension EditorProject {
    func textClipBinding(id: UUID) -> Binding<TextClip>? {
        guard let initial = textClips.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.textClips.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.textClips.firstIndex(where: { $0.id == id }) else { return }
                self.textClips[i] = newValue
            }
        )
    }
    func removeTextClip(id: UUID) { textClips.removeAll { $0.id == id } }
    func sortTextClips() { textClips.sort { $0.start < $1.start } }

    func drawingBinding(id: UUID) -> Binding<DrawingClip>? {
        guard let initial = drawings.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.drawings.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.drawings.firstIndex(where: { $0.id == id }) else { return }
                self.drawings[i] = newValue
            }
        )
    }
    func removeDrawing(id: UUID) { drawings.removeAll { $0.id == id } }

    func markerBinding(id: UUID) -> Binding<TimelineMarker>? {
        guard let initial = markers.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.markers.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.markers.firstIndex(where: { $0.id == id }) else { return }
                self.markers[i] = newValue
            }
        )
    }
    func removeMarker(id: UUID) { markers.removeAll { $0.id == id } }
    func sortMarkers() { markers.sort { $0.time < $1.time } }

    /// チャプター一覧のテキスト(YouTube の概要欄用)。先頭に 0:00 が無ければ補う
    func chapterListText() -> String {
        let chapters = markers.filter { $0.kind == .chapter }.sorted { $0.time < $1.time }
        var lines: [String] = []
        if chapters.first.map({ $0.time > 0.5 }) ?? true { lines.append(String(localized: "0:00 はじめに")) }
        for c in chapters {
            let t = Int(c.time.rounded(.down))
            let h = t / 3600, m = (t % 3600) / 60, s = t % 60
            let stamp = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            lines.append(String(localized: "\(stamp) \(c.name.isEmpty ? "チャプター" : c.name)"))
        }
        return lines.joined(separator: "\n")
    }

    /// 出力タイムライン上の時刻 → そのクリップの出力上の開始時刻(トランジション重なりは考慮しない)
    func clipTimelineStart(id: UUID) -> Double? {
        guard let i = index(of: id) else { return nil }
        return clipStartTimes()[i]
    }
}

extension Clip {
    /// クリップ先頭からの出力秒 → 元素材上の時刻(速度・速度カーブを考慮。ClipFXTimeline.outputOffset の逆)
    func sourceTime(atOutputOffset offset: Double) -> Double {
        let trimmed = trimmedDuration
        guard trimmed > 0 else { return startTime }
        if speedCurve.enabled {
            let n = 256
            let step = trimmed / Double(n)
            var total = 0.0
            for i in 0..<n {
                let p = (Double(i) + 0.5) / Double(n)
                let d = step / max(speedCurve.speed(at: p), 0.01)
                if total + d >= offset {
                    let fraction = d > 0 ? (offset - total) / d : 0
                    return startTime + (Double(i) + min(max(fraction, 0), 1)) * step
                }
                total += d
            }
            return endTime
        }
        return startTime + min(max(offset, 0), outputDuration) * speed
    }

    /// 元素材上の時刻 → クリップ先頭からの出力秒(sourceTime(atOutputOffset:) の逆。速度・速度カーブを考慮)
    func outputOffset(atSourceTime source: Double) -> Double {
        let trimmed = trimmedDuration
        guard trimmed > 0 else { return 0 }
        let local = min(max(source - startTime, 0), trimmed)
        if speedCurve.enabled {
            let n = 256
            let step = trimmed / Double(n)
            var total = 0.0
            for i in 0..<n {
                let segmentStart = Double(i) * step
                let p = (Double(i) + 0.5) / Double(n)
                let d = step / max(speedCurve.speed(at: p), 0.01)
                if local <= segmentStart + step {
                    let fraction = step > 0 ? (local - segmentStart) / step : 0
                    return total + min(max(fraction, 0), 1) * d
                }
                total += d
            }
            return total
        }
        return local / max(speed, 0.01)
    }
}
