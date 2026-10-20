import Foundation
import CoreGraphics
import SwiftUI

// =====================================================================
// 第3弾の共通データ定義(契約)。
// トランジション、クリップのアニメーション、切り抜き/回転、速度カーブ、
// 静止画クリップ、マーカー、テキストレイヤー、ステッカー、手書き、キーフレーム、
// 字幕の単語タイミングとテンプレート、透かし、音声エフェクト、HSL、LUT、
// フォーマット(オープニング等)、サムネ作成、書き出しプリセット。
// 時刻はすべて秒。「出力タイムライン上」か「クリップの開始からの相対」かは各所に明記。
// =====================================================================

// MARK: - 正規化座標

struct NormalizedPoint: Equatable {
    var x: Double
    var y: Double
    static let center = NormalizedPoint(x: 0.5, y: 0.5)
    func point(in size: CGSize) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
}

// MARK: - トランジション(クリップの終わりから次のクリップへ)

enum TransitionType: String, CaseIterable, Identifiable {
    case none, dissolve, fadeBlack, fadeWhite, slideLeft, slideRight, slideUp, slideDown, zoomIn, zoomOut, wipeLeft, wipeRight, blur
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .dissolve: return "じわっと切り替え"
        case .fadeBlack: return "黒を挟む"
        case .fadeWhite: return "白を挟む"
        case .slideLeft: return "左へスライド"
        case .slideRight: return "右へスライド"
        case .slideUp: return "上へスライド"
        case .slideDown: return "下へスライド"
        case .zoomIn: return "ズームイン"
        case .zoomOut: return "ズームアウト"
        case .wipeLeft: return "左へ拭き取り"
        case .wipeRight: return "右へ拭き取り"
        case .blur: return "ぼかし"
        }
    }
}

struct ClipTransition: Equatable {
    var type: TransitionType = .none
    /// 0.2 ... 2.0 秒。前後のクリップがこの長さだけ重なる(出力の合計は短くなる)
    var duration: Double = 0.5
    var isActive: Bool { type != .none && duration > 0.05 }
}

// MARK: - クリップのイン・アウト アニメーション

enum ClipAnimationType: String, CaseIterable, Identifiable {
    case none, fade, slideFromLeft, slideFromRight, slideFromBottom, slideFromTop, zoomIn, zoomOut, blur, spin
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .fade: return "ふわっと"
        case .slideFromLeft: return "左から"
        case .slideFromRight: return "右から"
        case .slideFromBottom: return "下から"
        case .slideFromTop: return "上から"
        case .zoomIn: return "ズームイン"
        case .zoomOut: return "ズームアウト"
        case .blur: return "ぼかし"
        case .spin: return "回転"
        }
    }
}

struct ClipAnimation: Equatable {
    var inType: ClipAnimationType = .none
    var inDuration: Double = 0.5
    var outType: ClipAnimationType = .none
    var outDuration: Double = 0.5
    var isIdentity: Bool { inType == .none && outType == .none }
}

// MARK: - 切り抜き・回転・反転・ズーム

struct ClipGeometry: Equatable {
    /// 90度単位の回転(0...3)
    var rotationQuarterTurns: Int = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    /// 元映像のどこを使うか(回転・反転後の座標、左上原点)
    var crop: NormalizedRect = .full
    /// 1 ... 4。中心を offsetX/offsetY(-0.5...0.5)だけずらす
    var zoom: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var isIdentity: Bool {
        rotationQuarterTurns % 4 == 0 && !flipHorizontal && !flipVertical && crop.isFull && zoom == 1 && offsetX == 0 && offsetY == 0
    }
}

// MARK: - 速度カーブ

struct SpeedPoint: Equatable {
    /// トリミング後の元素材範囲の中での位置 0...1
    var position: Double
    /// 0.1 ... 10
    var speed: Double
}

struct SpeedCurve: Equatable {
    var enabled: Bool = false
    /// position 昇順。最初は 0、最後は 1 であること
    var points: [SpeedPoint] = [SpeedPoint(position: 0, speed: 1), SpeedPoint(position: 1, speed: 1)]
    /// スロー部分で前後のコマを混ぜてなめらかに見せる
    var smoothSlow: Bool = false

    static let montage = SpeedCurve(enabled: true, points: [.init(position: 0, speed: 1), .init(position: 0.3, speed: 3), .init(position: 0.5, speed: 0.5), .init(position: 0.7, speed: 3), .init(position: 1, speed: 1)])
    static let hero = SpeedCurve(enabled: true, points: [.init(position: 0, speed: 1), .init(position: 0.4, speed: 0.3), .init(position: 0.6, speed: 0.3), .init(position: 1, speed: 1)])
    static let bullet = SpeedCurve(enabled: true, points: [.init(position: 0, speed: 1), .init(position: 0.45, speed: 4), .init(position: 0.5, speed: 0.2), .init(position: 0.55, speed: 4), .init(position: 1, speed: 1)])
    static let flashIn = SpeedCurve(enabled: true, points: [.init(position: 0, speed: 4), .init(position: 0.3, speed: 1), .init(position: 1, speed: 1)])
    static let flashOut = SpeedCurve(enabled: true, points: [.init(position: 0, speed: 1), .init(position: 0.7, speed: 1), .init(position: 1, speed: 4)])

    /// 位置 p (0...1) での速度(区分線形補間)
    func speed(at p: Double) -> Double {
        guard enabled, points.count >= 2 else { return 1 }
        let x = min(max(p, 0), 1)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if x <= b.position {
                let span = max(b.position - a.position, 1e-6)
                let t = (x - a.position) / span
                return max(0.05, a.speed + (b.speed - a.speed) * t)
            }
        }
        return max(0.05, points.last!.speed)
    }

    /// トリミング後の長さ trimmed(秒)を再生したときの出力の長さ(秒)。256 区間で数値積分
    func outputDuration(trimmed: Double) -> Double {
        guard enabled, trimmed > 0 else { return trimmed }
        let n = 256
        var total = 0.0
        for i in 0..<n {
            let p = (Double(i) + 0.5) / Double(n)
            total += (trimmed / Double(n)) / speed(at: p)
        }
        return total
    }

    /// 等速区間に分割する(CompositionBuilder が scaleTimeRange に使う)。各要素は元素材上の相対範囲と速度
    func segments(count: Int = 24) -> [(fromPosition: Double, toPosition: Double, speed: Double)] {
        guard enabled else { return [(fromPosition: 0, toPosition: 1, speed: 1)] }
        var result: [(fromPosition: Double, toPosition: Double, speed: Double)] = []
        for i in 0..<count {
            let a = Double(i) / Double(count), b = Double(i + 1) / Double(count)
            result.append((fromPosition: a, toPosition: b, speed: speed(at: (a + b) / 2)))
        }
        return result
    }
}

// MARK: - マーカー

enum MarkerKind: String, CaseIterable, Identifiable {
    case note, chapter, beat
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .note: return "メモ"
        case .chapter: return "章の区切り"
        case .beat: return "音楽の拍"
        }
    }
}

struct TimelineMarker: Identifiable, Equatable {
    var id = UUID()
    /// 出力タイムライン上の秒
    var time: Double
    var name: String = ""
    var kind: MarkerKind = .note
}

// MARK: - キーフレーム(オーバーレイ・テキスト用)

enum KeyframeEasing: String, CaseIterable, Identifiable {
    case linear, easeInOut, easeIn, easeOut
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .linear: return "一定"
        case .easeInOut: return "ゆっくり始まりゆっくり終わる"
        case .easeIn: return "ゆっくり始まる"
        case .easeOut: return "ゆっくり終わる"
        }
    }
}

struct Keyframe: Identifiable, Equatable {
    var id = UUID()
    /// 部品の開始からの相対秒
    var time: Double
    var center: NormalizedPoint = .center
    var scale: Double = 1
    /// 度
    var rotation: Double = 0
    var opacity: Double = 1
    var easing: KeyframeEasing = .easeInOut
}

/// キーフレーム列の補間
enum KeyframeInterpolator {
    struct Value { var center: NormalizedPoint; var scale: Double; var rotation: Double; var opacity: Double }
    static func value(at t: Double, keyframes: [Keyframe], fallback: Value) -> Value {
        let ks = keyframes.sorted { $0.time < $1.time }
        guard let first = ks.first else { return fallback }
        if t <= first.time { return Value(center: first.center, scale: first.scale, rotation: first.rotation, opacity: first.opacity) }
        for i in 1..<ks.count {
            let a = ks[i - 1], b = ks[i]
            if t <= b.time {
                let span = max(b.time - a.time, 1e-6)
                var u = (t - a.time) / span
                switch a.easing {
                case .linear: break
                case .easeInOut: u = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                case .easeIn: u = u * u
                case .easeOut: u = 1 - (1 - u) * (1 - u)
                }
                return Value(center: NormalizedPoint(x: a.center.x + (b.center.x - a.center.x) * u, y: a.center.y + (b.center.y - a.center.y) * u),
                             scale: a.scale + (b.scale - a.scale) * u,
                             rotation: a.rotation + (b.rotation - a.rotation) * u,
                             opacity: a.opacity + (b.opacity - a.opacity) * u)
            }
        }
        let l = ks.last!
        return Value(center: l.center, scale: l.scale, rotation: l.rotation, opacity: l.opacity)
    }
}

// MARK: - テキストレイヤー(字幕とは別の自由配置テキスト。ステッカーも兼ねる)

enum TextAnimationType: String, CaseIterable, Identifiable {
    case none, fade, typewriter, pop, slideUp, slideLeft, blurIn, scaleDown, wordByWord
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .fade: return "ふわっと"
        case .typewriter: return "タイプライター"
        case .pop: return "ポップ"
        case .slideUp: return "下から"
        case .slideLeft: return "右から"
        case .blurIn: return "ぼかしから"
        case .scaleDown: return "大きく→小さく"
        case .wordByWord: return "単語ごと"
        }
    }
}

enum TextAlignment2: String, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var displayName: String { self == .left ? "左" : self == .center ? "中央" : "右" }
}

struct TextShadow: Equatable {
    var enabled: Bool = true
    var colorHex: String = "#000000"
    var opacity: Double = 0.6
    var radius: Double = 0.006     // 画面の短辺に対する比率
    var offsetX: Double = 0
    var offsetY: Double = 0.004
}

struct TextStyle: Equatable {
    /// nil = システムフォント。PostScript 名または登録したフォント名
    var fontName: String? = nil
    var bold: Bool = true
    var italic: Bool = false
    /// 画面の短辺に対する文字サイズの比率(0.02 ... 0.25)
    var sizeRatio: Double = 0.07
    var colorHex: String = "#FFFFFF"
    var strokeColorHex: String? = nil
    /// 文字サイズに対する縁取りの太さ比率(0 ... 0.3)
    var strokeWidth: Double = 0
    var shadow = TextShadow()
    var backgroundColorHex: String? = nil
    var backgroundOpacity: Double = 0.6
    /// 文字サイズに対する余白比率
    var backgroundPadding: Double = 0.35
    var backgroundCornerRadius: Double = 0.25
    var alignment: TextAlignment2 = .center
    /// 文字サイズに対する字間比率
    var letterSpacing: Double = 0
    var lineSpacing: Double = 1.1
    var vertical: Bool = false
    /// 0 = 直線。正で弧(画面の短辺に対する半径比率)
    var curveRadius: Double = 0
}

enum TextTemplate: String, CaseIterable, Identifiable {
    case plain, headline, newsBar, caption, quote, handwritten, neon, minimalSerif, subtitleBox, bigImpact
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .plain: return "シンプル"
        case .headline: return "見出し"
        case .newsBar: return "ニュース帯"
        case .caption: return "説明文"
        case .quote: return "引用"
        case .handwritten: return "手書き風"
        case .neon: return "ネオン"
        case .minimalSerif: return "明朝・上品"
        case .subtitleBox: return "黒帯テロップ"
        case .bigImpact: return "インパクト"
        }
    }
}

struct TextClip: Identifiable, Equatable {
    var id = UUID()
    var text: String
    /// 出力タイムライン上の秒
    var start: Double
    var duration: Double = 3
    var center: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5)
    /// 折り返し幅(画面幅に対する比率 0.2 ... 1)
    var widthRatio: Double = 0.8
    /// 度
    var rotation: Double = 0
    var scale: Double = 1
    var opacity: Double = 1
    var style = TextStyle()
    var template: TextTemplate = .plain
    var animIn: TextAnimationType = .none
    var animInDuration: Double = 0.5
    var animOut: TextAnimationType = .none
    var animOutDuration: Double = 0.5
    var keyframes: [Keyframe] = []
    /// 絵文字ステッカーとして扱う(大きな絵文字1つ、背景なし)
    var isSticker: Bool = false

    var end: Double { start + duration }
    func contains(timelineTime t: Double) -> Bool { t >= start && t < end }
}

// MARK: - 手書き

struct DrawingStroke: Equatable {
    var points: [NormalizedPoint]
    var colorHex: String = "#FF4D4D"
    /// 画面の短辺に対する線幅比率
    var width: Double = 0.012
}

struct DrawingClip: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var duration: Double = 3
    var strokes: [DrawingStroke] = []
    /// 線が描かれていくアニメーション(秒。0 で即表示)
    var revealDuration: Double = 0.8
    var end: Double { start + duration }
}

// MARK: - 字幕の単語タイミングとテンプレート

struct SubtitleWord: Equatable {
    var text: String
    /// 出力タイムライン上の秒
    var start: Double
    var end: Double
}

enum CaptionTemplate: String, CaseIterable, Identifiable {
    case plain, karaoke, boxPop, outlineBig, pillHighlight, typewriter
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .plain: return "標準"
        case .karaoke: return "カラオケ(単語が光る)"
        case .boxPop: return "単語ごとに箱がポップ"
        case .outlineBig: return "太い縁取り(大)"
        case .pillHighlight: return "丸い帯でハイライト"
        case .typewriter: return "タイプライター"
        }
    }
}

// MARK: - 透かし

enum WatermarkCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        }
    }
}

struct WatermarkSettings: Equatable {
    var enabled: Bool = false
    /// 画像(アプリ内にコピー済み)。nil のときは text を使う
    var imageURL: URL? = nil
    var text: String = ""
    var corner: WatermarkCorner = .bottomRight
    var opacity: Double = 0.6
    /// 画面幅に対する大きさ比率
    var sizeRatio: Double = 0.18
    var isActive: Bool { enabled && (imageURL != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty) }
}

// MARK: - 音声エフェクト(クリップ・ナレーション共通)

enum VoicePreset: String, CaseIterable, Identifiable {
    case none, robot, chipmunk, deep, radio, telephone, cathedral
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .robot: return "ロボット"
        case .chipmunk: return "高い声"
        case .deep: return "低い声"
        case .radio: return "ラジオ"
        case .telephone: return "電話"
        case .cathedral: return "大聖堂(残響)"
        }
    }
}

struct AudioEffects: Equatable {
    /// dB -12 ... 12
    var eqLow: Double = 0
    var eqMid: Double = 0
    var eqHigh: Double = 0
    /// 半音 -12 ... 12
    var pitchSemitones: Double = 0
    var voicePreset: VoicePreset = .none
    /// 0...1 簡易ノイズ低減(ハイパスとゲート)
    var noiseReduction: Double = 0
    var isIdentity: Bool { eqLow == 0 && eqMid == 0 && eqHigh == 0 && pitchSemitones == 0 && voicePreset == .none && noiseReduction == 0 }
}

// MARK: - HSL(8つの色相帯)

struct HSLBand: Equatable {
    /// -1 ... 1 (色相を回す)
    var hue: Double = 0
    /// -1 ... 1
    var saturation: Double = 0
    /// -1 ... 1
    var luminance: Double = 0
    var isIdentity: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

struct HSLAdjustment: Equatable {
    static let bandNames = ["赤", "オレンジ", "黄", "緑", "水色", "青", "紫", "マゼンタ"]
    /// 8 帯: 0°,45°,...,315° を中心
    var bands: [HSLBand] = Array(repeating: HSLBand(), count: 8)
    var isIdentity: Bool { bands.allSatisfy { $0.isIdentity } }
}

// MARK: - フォーマット(オープニング・クロージング・ディバイダー)

enum FormatKind: String, CaseIterable, Identifiable {
    case opening, closing, divider
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .opening: return "オープニング"
        case .closing: return "クロージング"
        case .divider: return "ディバイダー(区切り)"
        }
    }
}

/// 使い回す決まりごと。時刻はブロックの先頭からの相対秒
struct FormatBlock: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: FormatKind
    var duration: Double = 4
    /// 背景色(黒など)。nil なら映像の上に重ねる
    var backgroundColorHex: String? = "#000000"
    var titleCards: [TitleCard] = []
    var textClips: [TextClip] = []
    /// 使う素材(アプリ内の動画/画像)。nil なら背景色のみ
    var mediaURL: URL? = nil
    var transitionOut: ClipTransition = ClipTransition(type: .fadeBlack, duration: 0.6)
}

// MARK: - サムネ(カバー画像)作成

enum MemoPaper: String, CaseIterable, Identifiable {
    case yellow, white, kraft, dark, pink
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .yellow: return "黄色の付箋"
        case .white: return "白いメモ"
        case .kraft: return "クラフト紙"
        case .dark: return "黒板"
        case .pink: return "ピンクの付箋"
        }
    }
}

struct CoverSettings: Equatable {
    /// 出力タイムライン上の秒(この時刻のコマを背景にする)。imageURL があればそちらを使う
    var frameTime: Double = 0
    var imageURL: URL? = nil
    var title: String = ""
    /// メモ風カードに書く本文(改行で箇条書き)
    var memoText: String = ""
    var paper: MemoPaper = .yellow
    /// カードの位置と幅(画面比率)
    var memoCenter: NormalizedPoint = NormalizedPoint(x: 0.72, y: 0.5)
    var memoWidthRatio: Double = 0.42
    /// 度
    var memoRotation: Double = -4
    var fontName: String? = nil
    var applyLook: Bool = true
}

// MARK: - 書き出しプリセット(ユーザー保存)

struct ExportPreset: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var canvas: CanvasSettings
    var subtitleStyle: SubtitleStyle?
    var documentary: DocumentaryStyle?
}

// MARK: - 色ユーティリティ

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255; b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            self.init(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255, blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        } else {
            self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
