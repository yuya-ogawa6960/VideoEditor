import SwiftUI

// =====================================================================
// アプリの色(アイコンの網点と同じ、オレンジ → ピンク。画面では少し深めの色にしている)。
// 大事なボタン(新しいプロジェクト・書き出し・動画を追加)に使う。
// アプリ全体の差し色(AccentColor)は、その中間のコーラル。
// =====================================================================

enum BrandStyle {
    static let orange = Color(red: 0.86, green: 0.47, blue: 0.13)
    static let pink = Color(red: 0.76, green: 0.19, blue: 0.33)
    static let coral = Color(red: 0.85, green: 0.33, blue: 0.27)
    /// 紺(アイコンの背景)
    static let navy = Color(red: 0.063, green: 0.102, blue: 0.2)

    static var gradient: LinearGradient {
        LinearGradient(colors: [orange, pink], startPoint: .leading, endPoint: .trailing)
    }
}

/// オレンジ → ピンクの塗りのボタン(書き出しなど)
struct BrandProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .padding(.vertical, 6)
            .background(BrandStyle.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
