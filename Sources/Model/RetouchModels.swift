import Foundation

// =====================================================================
// レタッチ: 顔の形(小顔・目・鼻・口角)、メイク(リップ・チーク・歯)、体型(スリム・脚長)。
// 顔の位置は描画のたびに Vision で探し、クリップごとになめらかに追う(RetouchRenderer.swift)。
// かんたんな「美肌」は画質補正(ClipEnhancements)のまま。
// 値はすべて 0 ... 1(0 = 何もしない)。
// =====================================================================

/// パネルで切り替えるまとまり
enum RetouchGroup: String, CaseIterable, Identifiable {
    case face
    case makeup
    case body

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .face: return String(localized: "顔")
        case .makeup: return String(localized: "メイク")
        case .body: return String(localized: "体型")
        }
    }
}

struct ClipRetouch: Equatable {
    // 顔
    /// 小顔(あごまわりを細く)
    var slimFace: Double = 0
    /// 目を大きく
    var bigEyes: Double = 0
    /// 鼻を細く
    var slimNose: Double = 0
    /// 口角アップ
    var smile: Double = 0

    // メイク
    /// リップの濃さ
    var lip: Double = 0
    /// リップの色("#RRGGBB")
    var lipColorHex: String = ClipRetouch.defaultLipColorHex
    /// チーク
    var blush: Double = 0
    /// 歯を白く
    var whitenTeeth: Double = 0

    // 体型
    /// スリム(人物のまわりを横に少し縮める)
    var slimBody: Double = 0
    /// 脚長(下半身を縦に少し伸ばす)
    var longLegs: Double = 0

    static let defaultLipColorHex = "#C8324B"
    /// リップの色の候補
    static let lipPresets = ["#C8324B", "#E0566E", "#B5303A", "#D9776B", "#9E2A4F", "#E88A8A"]

    /// 顔を探す必要がある
    var usesFace: Bool {
        slimFace > 0.001 || bigEyes > 0.001 || slimNose > 0.001 || smile > 0.001
            || lip > 0.001 || blush > 0.001 || whitenTeeth > 0.001
    }

    /// 人物を探す必要がある
    var usesBody: Bool { slimBody > 0.001 || longLegs > 0.001 }

    var isIdentity: Bool { !usesFace && !usesBody }

    /// まとまりごとに 0 に戻す(リップの色は残す)
    mutating func reset(_ group: RetouchGroup) {
        switch group {
        case .face:
            slimFace = 0
            bigEyes = 0
            slimNose = 0
            smile = 0
        case .makeup:
            lip = 0
            blush = 0
            whitenTeeth = 0
        case .body:
            slimBody = 0
            longLegs = 0
        }
    }

    func isZero(_ group: RetouchGroup) -> Bool {
        switch group {
        case .face: return slimFace <= 0.001 && bigEyes <= 0.001 && slimNose <= 0.001 && smile <= 0.001
        case .makeup: return lip <= 0.001 && blush <= 0.001 && whitenTeeth <= 0.001
        case .body: return !usesBody
        }
    }
}
