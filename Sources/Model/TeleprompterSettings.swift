import Foundation

// =====================================================================
// 「カメラで撮る」(CameraRecorderView)とテレプロンプター(TeleprompterOverlay)の設定。
// どれも @AppStorage で UserDefaults に残す(キーは TeleprompterSettingsKey)。
// 台本の文章も最後に使ったものを 1 つだけ残す(プロジェクトには保存しない)。
// =====================================================================

/// テレプロンプターの流れる速さ
enum TeleprompterSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slow: return String(localized: "ゆっくり")
        case .normal: return String(localized: "ふつう")
        case .fast: return String(localized: "速い")
        }
    }

    /// 1 秒に流れる行数(文字サイズ × 行間の高さに掛ける)
    var linesPerSecond: Double {
        switch self {
        case .slow: return 0.45
        case .normal: return 0.7
        case .fast: return 1.05
        }
    }
}

/// テレプロンプターの文字サイズ
enum TeleprompterFontSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return String(localized: "小")
        case .medium: return String(localized: "中")
        case .large: return String(localized: "大")
        }
    }

    var pointSize: Double {
        switch self {
        case .small: return 20
        case .medium: return 26
        case .large: return 34
        }
    }

    /// 1 行の高さ(行間を含む)
    var lineHeight: Double { pointSize * 1.4 }

    /// 小 → 中 → 大 → 小 と順に切り替える
    var next: TeleprompterFontSize {
        switch self {
        case .small: return .medium
        case .medium: return .large
        case .large: return .small
        }
    }
}

/// 録画ボタンを押してから撮り始めるまでの秒数
enum CameraCountdown: Int, CaseIterable, Identifiable {
    case none = 0
    case three = 3
    case five = 5
    case ten = 10
    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "なし")
        case .three: return String(localized: "3 秒")
        case .five: return String(localized: "5 秒")
        case .ten: return String(localized: "10 秒")
        }
    }
}

/// 録画のフレームレート(どちらも 1080p)
enum CameraFrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .fps30: return "1080p / 30fps"
        case .fps60: return "1080p / 60fps"
        }
    }

    var shortName: String {
        switch self {
        case .fps30: return "30fps"
        case .fps60: return "60fps"
        }
    }
}

/// @AppStorage のキー
enum TeleprompterSettingsKey {
    static let speed = "teleprompter.speed"
    static let fontSize = "teleprompter.fontSize"
    static let mirror = "teleprompter.mirror"
    /// 最後に使った台本の文章
    static let script = "teleprompter.lastScript"
    static let countdown = "camera.countdown"
    static let frameRate = "camera.frameRate"
    /// 最後に使ったカメラが前(true)か後ろ(false)か
    static let usesFrontCamera = "camera.usesFront"
}
