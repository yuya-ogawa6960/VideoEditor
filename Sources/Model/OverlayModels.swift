import Foundation
import CoreGraphics

// =====================================================================
// オーバーレイ(Bロール / ワイプ(PiP) / 写真クリップ / Ken Burns)のモデル。
// メイントラックの上に重ねて表示する素材を表す。描画(コンポジタ)と
// タイムライン UI は別ファイルで実装する。
// =====================================================================

// MARK: - 正規化矩形

/// 正規化矩形(0...1、原点左上)。キャンバスやソース画像に対する相対位置・サイズ
struct NormalizedRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 全面(0,0,1,1)
    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var isFull: Bool { self == .full }

    /// 線形補間(t = 0 で self、t = 1 で other)。t は 0...1 に丸める
    func interpolated(to other: NormalizedRect, t: Double) -> NormalizedRect {
        let k = t.isFinite ? min(max(t, 0), 1) : 0
        return NormalizedRect(x: x + (other.x - x) * k,
                              y: y + (other.y - y) * k,
                              width: width + (other.width - width) * k,
                              height: height + (other.height - height) * k)
    }

    /// 0...1 の範囲に収めた矩形(幅・高さは最小 0.01)
    func clamped() -> NormalizedRect {
        let w = min(max(width, 0.01), 1)
        let h = min(max(height, 0.01), 1)
        let px = min(max(x, 0), 1 - w)
        let py = min(max(y, 0), 1 - h)
        return NormalizedRect(x: px, y: py, width: w, height: h)
    }

    /// 実ピクセルサイズに展開した CGRect(原点左上)
    func rect(in size: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * size.width,
               y: CGFloat(y) * size.height,
               width: CGFloat(width) * size.width,
               height: CGFloat(height) * size.height)
    }
}

// MARK: - 収め方

enum OverlayFit: String, CaseIterable, Identifiable {
    /// 枠いっぱいに埋める(はみ出しはクロップ)
    case fill
    /// 枠内に収める(余白あり)
    case fit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill: return String(localized: "枠いっぱい")
        case .fit: return String(localized: "全体が見える")
        }
    }
}

// MARK: - Ken Burns(静止画のゆっくりしたズーム・パン)

struct KenBurns: Equatable {
    var enabled: Bool = false
    /// 開始時に表示するソース画像上の範囲(正規化)
    var startCrop: NormalizedRect = .full
    /// 終了時に表示するソース画像上の範囲(正規化)
    var endCrop: NormalizedRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    init(enabled: Bool = false,
         startCrop: NormalizedRect = .full,
         endCrop: NormalizedRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)) {
        self.enabled = enabled
        self.startCrop = startCrop
        self.endCrop = endCrop
    }

    /// 進行度 progress(0...1)での表示範囲。無効なら全面
    func crop(at progress: Double) -> NormalizedRect {
        guard enabled else { return .full }
        return startCrop.interpolated(to: endCrop, t: progress)
    }

    /// ズームイン(全面 → 中央 80%)
    static let zoomIn = KenBurns(enabled: true,
                                 startCrop: .full,
                                 endCrop: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    /// ズームアウト(中央 80% → 全面)
    static let zoomOut = KenBurns(enabled: true,
                                  startCrop: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                  endCrop: .full)
    /// 左から右へパン(高さ 85%)
    static let panLeftToRight = KenBurns(enabled: true,
                                         startCrop: NormalizedRect(x: 0, y: 0.075, width: 0.85, height: 0.85),
                                         endCrop: NormalizedRect(x: 0.15, y: 0.075, width: 0.85, height: 0.85))
}

// MARK: - オーバーレイクリップ

/// メイントラックの上に重ねる動画または写真
struct OverlayClip: Identifiable, Equatable {
    var id = UUID()
    /// アプリ内(mediaDirectory)にコピー済みのファイル
    var url: URL
    var isImage: Bool
    var name: String
    /// 元素材のピクセルサイズ(写真は EXIF 向きを反映済み)
    var naturalSize: CGSize
    /// 動画の回転。写真は identity
    var preferredTransform: CGAffineTransform
    /// 動画: 素材の長さ(秒)。写真: 3600 のような十分大きい値
    var sourceDuration: Double
    /// タイムライン上の開始(秒)
    var start: Double
    /// タイムライン上の長さ(秒)。写真: 自由。動画: (sourceDuration - sourceStart) / speed 以下
    var duration: Double
    /// 動画の素材上の開始位置(秒)
    var sourceStart: Double = 0
    /// 0.25 ... 4(1 = 等速)。写真では未使用
    var speed: Double = 1
    /// キャンバス上の配置(full = 全面を覆う Bロール、小さければワイプ)
    var frame: NormalizedRect = .full
    /// 枠の中心まわりの回転(度、時計回りが正)。キーフレームがあればそちらが優先
    var rotation: Double = 0
    var fit: OverlayFit = .fit
    /// 0 ... 1
    var opacity: Double = 1
    /// 角丸半径。min(キャンバス幅, 高さ) に対する比率 0 ... 0.5
    var cornerRadius: Double = 0
    /// 0 ... 1。Bロールは通常ミュート(0)、ワイプ動画は音声ありでもよい
    var volume: Float = 0
    var kenBurns = KenBurns()
    var filter = FilterSettings()
    /// フェードイン/アウト(秒)
    var fadeIn: Double = 0.3
    var fadeOut: Double = 0.3
    /// 位置・大きさ・回転・不透明度のキーフレーム(start からの相対秒)
    var keyframes: [Keyframe] = []
    /// 乗算・スクリーンなどのブレンド(CoreImage のフィルター名。nil = 通常)
    var blendMode: String? = nil
    /// マスク(Phase4Models.swift)
    var mask: MaskSettings = MaskSettings()
    /// 写真の 3D ズーム(奥行き情報がある場合)
    var parallax: DepthParallax = DepthParallax()

    init(id: UUID = UUID(),
         url: URL,
         isImage: Bool,
         name: String,
         naturalSize: CGSize,
         preferredTransform: CGAffineTransform = .identity,
         sourceDuration: Double,
         start: Double,
         duration: Double) {
        self.id = id
        self.url = url
        self.isImage = isImage
        self.name = name
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.sourceDuration = sourceDuration
        self.start = start
        self.duration = duration
    }

    /// タイムライン上の終了(秒)
    var end: Double { start + duration }

    /// 回転を反映した表示サイズ
    var displaySize: CGSize { orientedSize(naturalSize: naturalSize, transform: preferredTransform) }

    /// 動画の場合に許される最大のタイムライン長(秒)。写真は無制限(.infinity)
    var maxDuration: Double {
        if isImage { return .infinity }
        let remaining = max(0, sourceDuration - sourceStart)
        return remaining / max(speed, 0.01)
    }

    /// 動画の素材上の終了位置(秒)
    var sourceEnd: Double {
        if isImage { return sourceStart + duration }
        return min(sourceDuration, sourceStart + duration * speed)
    }

    /// 全面を覆う Bロールかどうか(ワイプではない)
    var coversCanvas: Bool { frame.isFull && fit == .fill && opacity >= 0.999 }

    /// タイムライン時刻 time がこのクリップの範囲内か
    func contains(timelineTime time: Double) -> Bool {
        time >= start && time < end
    }

    /// タイムライン時刻 time におけるフェードを含む不透明度(0 ... opacity)
    func effectiveOpacity(at time: Double) -> Double {
        guard duration > 0 else { return 0 }
        let local = time - start
        guard local >= 0, local <= duration else { return 0 }
        var factor = 1.0
        if fadeIn > 0, local < fadeIn {
            factor = min(factor, local / fadeIn)
        }
        if fadeOut > 0, duration - local < fadeOut {
            factor = min(factor, (duration - local) / fadeOut)
        }
        return max(0, min(1, factor)) * max(0, min(1, opacity))
    }

    /// 動画の場合、duration を素材の残り長さに収める
    mutating func clampDurationToSource() {
        guard !isImage else { return }
        duration = min(duration, maxDuration)
        if duration < 0 { duration = 0 }
    }

    /// 新しい ID を持つ複製
    func duplicated() -> OverlayClip {
        var copy = self
        copy.id = UUID()
        return copy
    }

    static func == (lhs: OverlayClip, rhs: OverlayClip) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.isImage == rhs.isImage
            && lhs.name == rhs.name
            && lhs.naturalSize == rhs.naturalSize
            && lhs.preferredTransform == rhs.preferredTransform
            && lhs.sourceDuration == rhs.sourceDuration
            && lhs.start == rhs.start
            && lhs.duration == rhs.duration
            && lhs.sourceStart == rhs.sourceStart
            && lhs.speed == rhs.speed
            && lhs.frame == rhs.frame
            && lhs.rotation == rhs.rotation
            && lhs.fit == rhs.fit
            && lhs.opacity == rhs.opacity
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.volume == rhs.volume
            && lhs.kenBurns == rhs.kenBurns
            && lhs.filter == rhs.filter
            && lhs.fadeIn == rhs.fadeIn
            && lhs.keyframes == rhs.keyframes
            && lhs.blendMode == rhs.blendMode
            && lhs.mask == rhs.mask
            && lhs.parallax == rhs.parallax
            && lhs.fadeOut == rhs.fadeOut
    }
}

// MARK: - プリセット

enum OverlayPreset: String, CaseIterable, Identifiable {
    /// 全面を覆う Bロール(音声なし、インタビュー音声は続く)
    case bRollFull
    /// 右上の小さなワイプ
    case pipSmallCorner
    /// 左半分
    case splitLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bRollFull: return String(localized: "全面に差し替え")
        case .pipSmallCorner: return String(localized: "右上に小窓")
        case .splitLeft: return String(localized: "左半分")
        }
    }

    /// このプリセットの配置
    var frame: NormalizedRect {
        switch self {
        case .bRollFull: return .full
        case .pipSmallCorner: return NormalizedRect(x: 0.62, y: 0.06, width: 0.33, height: 0.25)
        case .splitLeft: return NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        }
    }

    /// 配置・収め方・フェード・音量をオーバーレイに適用する(時間や素材情報は変更しない)
    func apply(to overlay: inout OverlayClip) {
        overlay.frame = frame
        switch self {
        case .bRollFull:
            overlay.fit = .fit
            overlay.fadeIn = 0.5
            overlay.fadeOut = 0.5
            overlay.volume = 0
            overlay.cornerRadius = 0
        case .pipSmallCorner:
            overlay.fit = .fit
            overlay.fadeIn = 0.3
            overlay.fadeOut = 0.3
            overlay.cornerRadius = 0.03
        case .splitLeft:
            overlay.fit = .fit
            overlay.fadeIn = 0.3
            overlay.fadeOut = 0.3
            overlay.cornerRadius = 0
        }
    }
}
