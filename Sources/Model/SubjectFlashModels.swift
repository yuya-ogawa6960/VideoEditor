import Foundation

// =====================================================================
// 被写体フラッシュ: クリップの中の 1 点で、人物や選んだ被写体だけをパッと明るく光らせる。
// 被写体の切り抜きは描画のたびに Vision で作る(SubjectFlashRenderer.swift)。
// 画面全体を光らせるのはトランジションの「白飛びフラッシュ」(TransitionType.exposureFlash)。
// =====================================================================

/// 何を光らせるか
enum SubjectFlashTarget: String, CaseIterable, Identifiable {
    /// 人物(人を全員)
    case person
    /// いちばん目立つ被写体(人・物・動物。自動)
    case subject
    /// 画面をタップして選んだ被写体
    case tapped

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .person: return String(localized: "人物")
        case .subject: return String(localized: "被写体(自動)")
        case .tapped: return String(localized: "タップで選ぶ")
        }
    }
}

struct SubjectFlash: Equatable {
    var enabled: Bool = false
    var target: SubjectFlashTarget = .person
    /// .tapped のときに選んだ位置(キャンバス正規化・左上原点)
    var point: NormalizedPoint = .center
    /// 光るタイミング(クリップの出力上の先頭からの秒)
    var time: Double = 0
    /// 光っている長さ(秒、0.15 ... 1.0)
    var duration: Double = 0.35
    /// 強さ(0.2 ... 1)
    var strength: Double = 0.8
    /// まわりに光のふちを付ける
    var glow: Bool = true

    var isActive: Bool { enabled && duration > 0.01 && strength > 0.01 }

    /// クリップ先頭からの秒 localTime での光り方(0 = 光っていない、1 = いちばん強い)。
    /// すばやく明るくなって、ゆっくり戻る
    func intensity(atLocalTime localTime: Double) -> Double {
        guard isActive else { return 0 }
        let u = (localTime - time) / duration
        guard u >= 0, u <= 1 else { return 0 }
        let rise = 0.2
        let shape = u < rise ? u / rise : pow(1 - (u - rise) / (1 - rise), 1.6)
        return min(max(shape, 0), 1) * strength
    }
}
