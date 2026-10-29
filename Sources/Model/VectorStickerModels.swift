import Foundation

// =====================================================================
// 動くステッカー(コードで描くベクターのステッカー)
//   - TextClip.vectorSticker に種類を入れると、文字の代わりにこの絵を描く(VectorStickerRenderer.swift)
//   - 色は TextClip.style.colorHex、吹き出しなどの文字は TextClip.text を使う
//   - 置き方・大きさ・回転・キーフレーム・トラッキング・保存は普通のステッカーと同じ
// =====================================================================

enum VectorStickerCategory: String, CaseIterable, Identifiable {
    case arrow, bubble, sparkle, heart, frame, reaction, handwritten, number, scene
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arrow: return String(localized: "矢印")
        case .bubble: return String(localized: "吹き出し")
        case .sparkle: return String(localized: "キラキラ")
        case .heart: return String(localized: "ハート")
        case .frame: return String(localized: "枠・線")
        case .reaction: return String(localized: "リアクション")
        case .handwritten: return String(localized: "手書き風")
        case .number: return String(localized: "数字")
        case .scene: return String(localized: "シーン")
        }
    }

    /// タイムラインなどに出す小さなアイコン
    var systemImage: String {
        switch self {
        case .arrow: return "arrow.right"
        case .bubble: return "bubble.left"
        case .sparkle: return "sparkles"
        case .heart: return "heart"
        case .frame: return "circle.dashed"
        case .reaction: return "exclamationmark.bubble"
        case .handwritten: return "scribble"
        case .number: return "1.circle"
        case .scene: return "hand.thumbsup"
        }
    }

    var kinds: [VectorStickerKind] {
        VectorStickerKind.allCases.filter { $0.category == self }
    }
}

enum VectorStickerKind: String, CaseIterable, Identifiable {
    // 矢印
    case arrowBounce, arrowCurved, pointingHand, chevrons
    // 吹き出し
    case speechBubble, thoughtBubble, shoutBubble
    // キラキラ
    case sparkles, starBurst, glitter
    // ハート
    case heartBeat, heartsFloat
    // 枠・線
    case circleDraw, underlineScribble, rectFrame
    // リアクション
    case exclaimQuestion, question, bulb, sweat, anger, laugh, emphasisLines
    // 手書き風
    case scribbleCircle, checkDraw, crossDraw, doodleStar
    // 数字
    case badge1, badge2, badge3
    // シーン
    case likeButton, saveButton, subscribeButton, newBadge

    var id: String { rawValue }

    var category: VectorStickerCategory {
        switch self {
        case .arrowBounce, .arrowCurved, .pointingHand, .chevrons: return .arrow
        case .speechBubble, .thoughtBubble, .shoutBubble: return .bubble
        case .sparkles, .starBurst, .glitter: return .sparkle
        case .heartBeat, .heartsFloat: return .heart
        case .circleDraw, .underlineScribble, .rectFrame: return .frame
        case .exclaimQuestion, .question, .bulb, .sweat, .anger, .laugh, .emphasisLines: return .reaction
        case .scribbleCircle, .checkDraw, .crossDraw, .doodleStar: return .handwritten
        case .badge1, .badge2, .badge3: return .number
        case .likeButton, .saveButton, .subscribeButton, .newBadge: return .scene
        }
    }

    var displayName: String {
        switch self {
        case .arrowBounce: return String(localized: "はねる矢印")
        case .arrowCurved: return String(localized: "曲がる矢印")
        case .pointingHand: return String(localized: "指さし")
        case .chevrons: return String(localized: "流れる矢印")
        case .speechBubble: return String(localized: "吹き出し")
        case .thoughtBubble: return String(localized: "考え中")
        case .shoutBubble: return String(localized: "叫び")
        case .sparkles: return String(localized: "キラキラ")
        case .starBurst: return String(localized: "星がはじける")
        case .glitter: return String(localized: "ラメ")
        case .heartBeat: return String(localized: "ドキドキ")
        case .heartsFloat: return String(localized: "ふわふわハート")
        case .circleDraw: return String(localized: "丸で囲む")
        case .underlineScribble: return String(localized: "下線")
        case .rectFrame: return String(localized: "四角で囲む")
        case .exclaimQuestion: return "!?"
        case .question: return "?"
        case .bulb: return String(localized: "ひらめき")
        case .sweat: return String(localized: "汗")
        case .anger: return String(localized: "怒り")
        case .laugh: return String(localized: "笑い")
        case .emphasisLines: return String(localized: "集中線")
        case .scribbleCircle: return String(localized: "ぐるぐる")
        case .checkDraw: return String(localized: "チェック")
        case .crossDraw: return String(localized: "バツ")
        case .doodleStar: return String(localized: "手描きの星")
        case .badge1: return "1"
        case .badge2: return "2"
        case .badge3: return "3"
        case .likeButton: return String(localized: "いいね")
        case .saveButton: return String(localized: "保存してね")
        case .subscribeButton: return String(localized: "チャンネル登録")
        case .newBadge: return "NEW"
        }
    }

    /// 文字を入れられる種類(吹き出し・数字・ボタン)
    var hasText: Bool {
        switch category {
        case .bubble, .number, .scene: return true
        default: return false
        }
    }

    /// 追加したときの文字(文字を入れられない種類は名前。描画には使わない)
    var defaultText: String {
        switch self {
        case .speechBubble: return String(localized: "なるほど")
        case .thoughtBubble: return String(localized: "うーん…")
        case .shoutBubble: return String(localized: "えっ!")
        default: return displayName
        }
    }

    var defaultColorHex: String {
        switch self {
        case .arrowBounce, .arrowCurved, .chevrons: return "#FFE44D"
        case .pointingHand: return "#FFD2A6"
        case .speechBubble, .thoughtBubble: return "#FFFFFF"
        case .shoutBubble: return "#FFE600"
        case .sparkles, .starBurst, .glitter: return "#FFE45C"
        case .heartBeat, .heartsFloat: return "#FF3B5C"
        case .circleDraw, .rectFrame, .underlineScribble: return "#FF3B30"
        case .exclaimQuestion, .anger: return "#FF2D2D"
        case .question: return "#4DB8FF"
        case .bulb: return "#FFD60A"
        case .sweat: return "#5AC8FA"
        case .laugh, .emphasisLines: return "#FFFFFF"
        case .scribbleCircle, .crossDraw: return "#FF3B30"
        case .checkDraw: return "#34C759"
        case .doodleStar: return "#FFE44D"
        case .badge1: return "#FF3B30"
        case .badge2: return "#007AFF"
        case .badge3: return "#34C759"
        case .likeButton, .subscribeButton: return "#FF3B30"
        case .saveButton: return "#007AFF"
        case .newBadge: return "#FF3B30"
        }
    }

    /// 絵の横幅 / 高さ
    var aspect: Double {
        switch self {
        case .chevrons: return 1.6
        case .speechBubble, .thoughtBubble, .shoutBubble: return 1.6
        case .circleDraw, .rectFrame: return 1.4
        case .underlineScribble: return 3
        case .likeButton, .saveButton, .subscribeButton: return 3
        default: return 1
        }
    }

    /// 1 回の動きの長さ(秒)。この長さで繰り返す
    var period: Double {
        switch self {
        case .arrowBounce, .pointingHand: return 0.9
        case .chevrons: return 1.2
        case .arrowCurved, .circleDraw, .underlineScribble, .rectFrame,
             .scribbleCircle, .checkDraw, .crossDraw, .doodleStar: return 2.4
        case .speechBubble, .thoughtBubble: return 2
        case .shoutBubble: return 1
        case .sparkles, .glitter: return 1.6
        case .starBurst: return 1.4
        case .heartBeat: return 1
        case .heartsFloat: return 2.4
        case .exclaimQuestion, .question: return 1.2
        case .bulb: return 1.4
        case .sweat: return 1.6
        case .anger: return 0.9
        case .laugh: return 1.5
        case .emphasisLines: return 0.4
        case .badge1, .badge2, .badge3: return 1.6
        case .likeButton, .saveButton, .subscribeButton: return 1.6
        case .newBadge: return 2
        }
    }

    /// 止まった見本を出すときの位置(0...1。線が描き終わったところなど)
    var posterPhase: Double {
        switch self {
        case .arrowCurved, .circleDraw, .underlineScribble, .rectFrame,
             .scribbleCircle, .checkDraw, .crossDraw, .doodleStar: return 0.7
        case .starBurst: return 0.35
        default: return 0.25
        }
    }
}
