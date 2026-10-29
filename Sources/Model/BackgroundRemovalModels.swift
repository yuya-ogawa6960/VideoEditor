import Foundation

// =====================================================================
// 背景を消す(自動の切り抜き)とクロマキー(グリーンバック・ブルーバック)。
// メインのクリップとオーバーレイ(Bロール / ワイプ)の両方に付けられる。
// オーバーレイでは消した部分が透明になり、下の映像が見える(人物だけを別の映像の上に重ねる)。
// メインのクリップでは消した部分を 透明(黒) / ぼかし / 単色 で埋める。
// 描画は BackgroundRemovalRenderer.swift、保存は StoredBackgroundRemoval(ProjectStore から使う)。
// =====================================================================

/// どうやって背景を消すか
enum BackgroundRemovalMode: String, CaseIterable, Identifiable {
    case off
    /// 人物・被写体を自動で切り抜く(コマごとに Vision)
    case auto
    /// 決めた色(緑・青など)を消す
    case chroma

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return String(localized: "オフ")
        case .auto: return String(localized: "自動で消す")
        case .chroma: return String(localized: "クロマキー")
        }
    }
}

/// 自動で残すもの
enum BackgroundRemovalTarget: String, CaseIterable, Identifiable {
    /// 人物(人を全員)
    case person
    /// 人・物・動物など前にある被写体すべて
    case subject

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .person: return String(localized: "人物")
        case .subject: return String(localized: "被写体")
        }
    }
}

/// メインのクリップで、消した部分を何で埋めるか(オーバーレイは常に透明)
enum BackgroundRemovalFill: String, CaseIterable, Identifiable {
    /// 透明(下に何もなければ黒)
    case clear
    /// 元の映像をぼかしたもの
    case blur
    /// 単色
    case color

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .clear: return String(localized: "透明(黒)")
        case .blur: return String(localized: "ぼかし")
        case .color: return String(localized: "単色")
        }
    }
}

/// sRGB の色(0...1)
struct BackgroundRemovalColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    // 保存("#RRGGBB")で読み戻しても同じ値になるよう 1/255 単位にしておく
    static let greenScreen = BackgroundRemovalColor(red: 0, green: 217.0 / 255, blue: 64.0 / 255)
    static let blueScreen = BackgroundRemovalColor(red: 0, green: 77.0 / 255, blue: 242.0 / 255)
    static let white = BackgroundRemovalColor(red: 1, green: 1, blue: 1)

    /// 0...1 に丸めた色
    func clamped() -> BackgroundRemovalColor {
        func c(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        return BackgroundRemovalColor(red: c(red), green: c(green), blue: c(blue))
    }

    /// "#RRGGBB"
    var hex: String {
        let v = clamped()
        func component(_ x: Double) -> Int { Int((x * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(v.red), component(v.green), component(v.blue))
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#RRGGBB" から(読めなければ nil)
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        red = Double((v >> 16) & 0xFF) / 255
        green = Double((v >> 8) & 0xFF) / 255
        blue = Double(v & 0xFF) / 255
    }
}

struct BackgroundRemoval: Equatable {
    var mode: BackgroundRemovalMode = .off
    /// 自動: 残すもの
    var target: BackgroundRemovalTarget = .person
    /// 境界のぼかし(0 = くっきり ... 1 = やわらか)。自動・クロマキー共通
    var edgeSoftness: Double = 0.3
    /// メインのクリップ: 消した部分の埋め方
    var fill: BackgroundRemovalFill = .clear
    /// fill == .color のときの色
    var fillColor: BackgroundRemovalColor = .white
    /// クロマキー: 消す色
    var keyColor: BackgroundRemovalColor = .greenScreen
    /// クロマキー: 強さ(消す色の幅。0 ... 1)
    var strength: Double = 0.45
    /// クロマキー: 色かぶり(ふちに残る緑・青)を抑える強さ(0 ... 1)
    var spill: Double = 0.5

    var isActive: Bool { mode != .off }
}

/// 保存用(後から追加したので、StoredClip / StoredOverlay では省略可能なフィールドとして持つ)
struct StoredBackgroundRemoval: Codable {
    var mode: String
    var target: String?
    var edgeSoftness: Double?
    var fill: String?
    var fillColor: String?
    var keyColor: String?
    var strength: Double?
    var spill: Double?

    init(_ b: BackgroundRemoval) {
        mode = b.mode.rawValue
        target = b.target.rawValue
        edgeSoftness = b.edgeSoftness
        fill = b.fill.rawValue
        fillColor = b.fillColor.hex
        keyColor = b.keyColor.hex
        strength = b.strength
        spill = b.spill
    }

    /// 既定値のままなら保存しない
    static func make(_ b: BackgroundRemoval) -> StoredBackgroundRemoval? {
        b == BackgroundRemoval() ? nil : StoredBackgroundRemoval(b)
    }

    var value: BackgroundRemoval {
        let defaults = BackgroundRemoval()
        func clamp(_ v: Double?, _ fallback: Double) -> Double {
            guard let v, v.isFinite else { return fallback }
            return min(max(v, 0), 1)
        }
        var b = BackgroundRemoval()
        b.mode = BackgroundRemovalMode(rawValue: mode) ?? .off
        b.target = target.flatMap { BackgroundRemovalTarget(rawValue: $0) } ?? defaults.target
        b.edgeSoftness = clamp(edgeSoftness, defaults.edgeSoftness)
        b.fill = fill.flatMap { BackgroundRemovalFill(rawValue: $0) } ?? defaults.fill
        b.fillColor = fillColor.flatMap { BackgroundRemovalColor(hex: $0) } ?? defaults.fillColor
        b.keyColor = keyColor.flatMap { BackgroundRemovalColor(hex: $0) } ?? defaults.keyColor
        b.strength = clamp(strength, defaults.strength)
        b.spill = clamp(spill, defaults.spill)
        return b
    }
}
