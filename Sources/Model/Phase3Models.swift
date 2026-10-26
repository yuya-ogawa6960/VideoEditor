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
    case wipeUp, wipeDown, coverLeft, coverRight, irisOpen, irisClose, doorOpen, spin, swirl, zoomBlur, whipLeft, whipRight, flash, lightLeak, glitch, pixelate, bars, pageCurl
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return String(localized: "なし")
        case .dissolve: return String(localized: "クロスディゾルブ")
        case .fadeBlack: return String(localized: "暗転")
        case .fadeWhite: return String(localized: "ホワイトアウト")
        case .slideLeft: return String(localized: "スライド(左)")
        case .slideRight: return String(localized: "スライド(右)")
        case .slideUp: return String(localized: "スライド(上)")
        case .slideDown: return String(localized: "スライド(下)")
        case .zoomIn: return String(localized: "クロスズーム(イン)")
        case .zoomOut: return String(localized: "クロスズーム(アウト)")
        case .wipeLeft: return String(localized: "ワイプ(左)")
        case .wipeRight: return String(localized: "ワイプ(右)")
        case .blur: return String(localized: "ブラー")
        case .wipeUp: return String(localized: "ワイプ(上)")
        case .wipeDown: return String(localized: "ワイプ(下)")
        case .coverLeft: return String(localized: "カバー(左)")
        case .coverRight: return String(localized: "カバー(右)")
        case .irisOpen: return String(localized: "アイリス(開く)")
        case .irisClose: return String(localized: "アイリス(閉じる)")
        case .doorOpen: return String(localized: "ドア(開く)")
        case .spin: return String(localized: "スピン")
        case .swirl: return String(localized: "うず巻き")
        case .zoomBlur: return String(localized: "ズームブラー")
        case .whipLeft: return String(localized: "ホイップパン(左)")
        case .whipRight: return String(localized: "ホイップパン(右)")
        case .flash: return String(localized: "フラッシュ")
        case .lightLeak: return String(localized: "光漏れ")
        case .glitch: return String(localized: "グリッチ")
        case .pixelate: return String(localized: "モザイク")
        case .bars: return String(localized: "バー")
        case .pageCurl: return String(localized: "ページめくり")
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
        case .none: return String(localized: "なし")
        case .fade: return String(localized: "ふわっと")
        case .slideFromLeft: return String(localized: "左から")
        case .slideFromRight: return String(localized: "右から")
        case .slideFromBottom: return String(localized: "下から")
        case .slideFromTop: return String(localized: "上から")
        case .zoomIn: return String(localized: "ズームイン")
        case .zoomOut: return String(localized: "ズームアウト")
        case .blur: return String(localized: "ぼかし")
        case .spin: return String(localized: "回転")
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
        case .note: return String(localized: "メモ")
        case .chapter: return String(localized: "章の区切り")
        case .beat: return String(localized: "音楽の拍")
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
        case .linear: return String(localized: "一定")
        case .easeInOut: return String(localized: "ゆっくり始まりゆっくり終わる")
        case .easeIn: return String(localized: "ゆっくり始まる")
        case .easeOut: return String(localized: "ゆっくり終わる")
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

    /// 部品の先頭を removedHead 秒ぶん切ったあとのキーフレーム列(先頭を伸ばしたときは負)。
    /// 切った区間の中のキーは消し、新しい先頭(0 秒)にそのときの補間値のキーを入れる
    /// (追尾のモザイクなどが、切った位置の値から始まる)
    static func shifted(_ keyframes: [Keyframe], removingHead removedHead: Double) -> [Keyframe] {
        guard !keyframes.isEmpty, abs(removedHead) > 0.0001 else { return keyframes }
        var result: [Keyframe] = []
        var dropped = false
        for key in keyframes {
            var k = key
            k.time = key.time - removedHead
            if k.time >= -0.001 {
                result.append(k)
            } else {
                dropped = true
            }
        }
        guard dropped, !result.contains(where: { abs($0.time) < 0.001 }) else { return result }
        let v = value(at: removedHead, keyframes: keyframes,
                      fallback: Value(center: .center, scale: 1, rotation: 0, opacity: 1))
        var head = Keyframe(time: 0, center: v.center, scale: v.scale, rotation: v.rotation, opacity: v.opacity)
        if let before = keyframes.filter({ $0.time < removedHead }).max(by: { $0.time < $1.time }) {
            head.easing = before.easing
        }
        result.insert(head, at: 0)
        return result
    }
}

// MARK: - テキストレイヤー(字幕とは別の自由配置テキスト。ステッカーも兼ねる)

enum TextAnimationType: String, CaseIterable, Identifiable {
    case none, fade, typewriter, pop, slideUp, slideLeft, blurIn, scaleDown, wordByWord
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return String(localized: "なし")
        case .fade: return String(localized: "ふわっと")
        case .typewriter: return String(localized: "タイプライター")
        case .pop: return String(localized: "ポップ")
        case .slideUp: return String(localized: "下から")
        case .slideLeft: return String(localized: "右から")
        case .blurIn: return String(localized: "ぼかしから")
        case .scaleDown: return String(localized: "大きく→小さく")
        case .wordByWord: return String(localized: "単語ごと")
        }
    }
}

enum TextAlignment2: String, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var displayName: String { self == .left ? String(localized: "左") : self == .center ? String(localized: "中央") : String(localized: "右") }
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
        case .plain: return String(localized: "シンプル")
        case .headline: return String(localized: "見出し")
        case .newsBar: return String(localized: "ニュース帯")
        case .caption: return String(localized: "説明文")
        case .quote: return String(localized: "引用")
        case .handwritten: return String(localized: "手書き風")
        case .neon: return String(localized: "ネオン")
        case .minimalSerif: return String(localized: "明朝・上品")
        case .subtitleBox: return String(localized: "黒帯テロップ")
        case .bigImpact: return String(localized: "インパクト")
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
    /// モザイク / ぼかし(nil 以外ならテキストは描かず、この範囲の映像にモザイクをかける。MosaicModels.swift)
    var mosaic: MosaicStyle? = nil

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
        case .plain: return String(localized: "標準")
        case .karaoke: return String(localized: "カラオケ(単語が光る)")
        case .boxPop: return String(localized: "単語ごとに箱がポップ")
        case .outlineBig: return String(localized: "太い縁取り(大)")
        case .pillHighlight: return String(localized: "丸い帯でハイライト")
        case .typewriter: return String(localized: "タイプライター")
        }
    }
}

// MARK: - 透かし

enum WatermarkCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .topLeft: return String(localized: "左上")
        case .topRight: return String(localized: "右上")
        case .bottomLeft: return String(localized: "左下")
        case .bottomRight: return String(localized: "右下")
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
        case .none: return String(localized: "なし")
        case .robot: return String(localized: "ロボット")
        case .chipmunk: return String(localized: "高い声")
        case .deep: return String(localized: "低い声")
        case .radio: return String(localized: "ラジオ")
        case .telephone: return String(localized: "電話")
        case .cathedral: return String(localized: "大聖堂(残響)")
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
    static let bandNames = [String(localized: "赤"), String(localized: "オレンジ"), String(localized: "黄"), String(localized: "緑"), String(localized: "水色"), String(localized: "青"), String(localized: "紫"), String(localized: "マゼンタ")]
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
        case .opening: return String(localized: "オープニング")
        case .closing: return String(localized: "クロージング")
        case .divider: return String(localized: "ディバイダー(区切り)")
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
        case .yellow: return String(localized: "黄色の付箋")
        case .white: return String(localized: "白いメモ")
        case .kraft: return String(localized: "クラフト紙")
        case .dark: return String(localized: "黒板")
        case .pink: return String(localized: "ピンクの付箋")
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
