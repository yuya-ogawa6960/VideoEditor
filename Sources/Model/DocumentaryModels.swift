import Foundation
import CoreGraphics

// =====================================================================
// ドキュメンタリー風の演出(共通の契約)。
// 時刻はすべて出力タイムライン上の秒。
// =====================================================================

/// 全体の色味
enum LookPreset: String, CaseIterable, Identifiable {
    case none
    /// 彩度控えめ、やや青緑の影と暖かい肌色(ドキュメンタリーの定番)
    case documentary
    /// 暖かく柔らかい映画調
    case cinematicWarm
    /// 高コントラストのモノクロ
    case noir
    /// 色あせたフィルム調
    case vintage

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .documentary: return "ドキュメンタリー"
        case .cinematicWarm: return "シネマ(暖色)"
        case .noir: return "モノクロ"
        case .vintage: return "フィルム"
        }
    }
}

/// 作品全体にかかる演出
struct DocumentaryStyle: Equatable {
    var look: LookPreset = .none
    /// 色味の強さ 0...1
    var lookIntensity: Double = 1
    /// 2.39:1 の上下黒帯
    var letterbox: Bool = false
    /// フィルム粒子 0...1
    var filmGrain: Double = 0
    /// 周辺減光 0...1
    var vignette: Double = 0
    /// 冒頭を黒からフェードイン、最後を黒へフェードアウト(各 1.5 秒)
    var fadeFromToBlack: Bool = false
    /// クリップのつなぎ目を一瞬黒に落とす(0.5 秒)
    var dipToBlackBetweenClips: Bool = false
    /// 字幕(=話している区間)の間だけ BGM を下げる
    var autoDucking: Bool = false
    /// ダッキング時の BGM 音量の倍率 0...1
    var duckingLevel: Float = 0.3

    var isActive: Bool {
        look != .none || letterbox || filmGrain > 0 || vignette > 0 || fadeFromToBlack || dipToBlackBetweenClips
    }
}

/// 章タイトル(黒い画面に白い文字)
struct TitleCard: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var duration: Double = 3
    /// 例: 「第1章」
    var heading: String
    /// 例: 「はじまり」
    var title: String
    /// true なら黒背景で映像を隠す。false なら映像の上に文字だけ重ねる
    var opaqueBackground: Bool = true

    var end: Double { start + duration }
}

/// 画面下部などに出すテロップ
enum CaptionKind: String, CaseIterable, Identifiable {
    /// 人物の名前と肩書き(左下)
    case nameplate
    /// 場所と日付(左上)
    case location
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .nameplate: return "ネームプレート"
        case .location: return "場所・日付"
        }
    }
}

struct LowerThird: Identifiable, Equatable {
    var id = UUID()
    var kind: CaptionKind = .nameplate
    var start: Double
    var duration: Double = 4
    /// ネームプレート: 名前 / 場所: 地名
    var primary: String
    /// ネームプレート: 肩書き / 場所: 日付など
    var secondary: String = ""

    var end: Double { start + duration }
}
