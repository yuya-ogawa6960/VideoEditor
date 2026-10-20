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
            .background(FacetedBrandBackground())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// 角を階段状に欠いた四角(アイコンの網点のドットのような、カクカクした形)
struct PixelCornerShape: Shape {
    /// 1 段の大きさ(pt)
    var step: CGFloat = 3
    /// 段の数
    var steps: Int = 2

    func path(in rect: CGRect) -> Path {
        let s = min(step, rect.width / CGFloat(steps * 2 + 1), rect.height / CGFloat(steps * 2 + 1))
        let n = max(1, steps)
        var p = Path()
        // 上の辺(左上の階段の終わりから右上の階段の始まりまで)
        p.move(to: CGPoint(x: rect.minX + s * CGFloat(n), y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - s * CGFloat(n), y: rect.minY))
        // 右上: 下へ → 右へ を繰り返す
        for i in 0..<n {
            let x = rect.maxX - s * CGFloat(n - i)
            let y = rect.minY + s * CGFloat(i)
            p.addLine(to: CGPoint(x: x, y: y + s))
            p.addLine(to: CGPoint(x: x + s, y: y + s))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - s * CGFloat(n)))
        // 右下: 左へ → 下へ
        for i in 0..<n {
            let x = rect.maxX - s * CGFloat(i)
            let y = rect.maxY - s * CGFloat(n - i)
            p.addLine(to: CGPoint(x: x - s, y: y))
            p.addLine(to: CGPoint(x: x - s, y: y + s))
        }
        p.addLine(to: CGPoint(x: rect.minX + s * CGFloat(n), y: rect.maxY))
        // 左下: 上へ → 左へ
        for i in 0..<n {
            let x = rect.minX + s * CGFloat(n - i)
            let y = rect.maxY - s * CGFloat(i)
            p.addLine(to: CGPoint(x: x, y: y - s))
            p.addLine(to: CGPoint(x: x - s, y: y - s))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + s * CGFloat(n)))
        // 左上: 右へ → 上へ
        for i in 0..<n {
            let x = rect.minX + s * CGFloat(i)
            let y = rect.minY + s * CGFloat(n - i)
            p.addLine(to: CGPoint(x: x + s, y: y))
            p.addLine(to: CGPoint(x: x + s, y: y - s))
        }
        p.closeSubpath()
        return p
    }
}

/// 角を斜めに切り落とした多角形(四隅の切り方を少しずつ変えて、カット面のある石のような形にする)
struct ChamferedShape: Shape {
    /// 切り落とす大きさ(高さに対する比率)。左上・右上・右下・左下
    var cuts: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.42, 0.26, 0.36, 0.22)

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let limit = min(rect.width, rect.height) / 2
        let tl = min(h * cuts.0, limit)
        let tr = min(h * cuts.1, limit)
        let br = min(h * cuts.2, limit)
        let bl = min(h * cuts.3, limit)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bl))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.closeSubpath()
        return p
    }
}

/// オレンジ → ピンクの面に、明るさの違う三角の面を重ねた背景(ローポリのカット面のような見た目)
struct FacetedBrandBackground: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                BrandStyle.gradient
                // 左上の明るい面
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.38, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.62))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color.white.opacity(0.14))
                // 中央の暗い面
                Path { p in
                    p.move(to: CGPoint(x: w * 0.38, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.7, y: h))
                    p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.62))
                    p.closeSubpath()
                }
                .fill(Color.black.opacity(0.10))
                // 右下の暗い面
                Path { p in
                    p.move(to: CGPoint(x: w * 0.7, y: h))
                    p.addLine(to: CGPoint(x: w, y: h * 0.35))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(Color.black.opacity(0.16))
                // 右上の少し明るい面
                Path { p in
                    p.move(to: CGPoint(x: w * 0.62, y: 0))
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w, y: h * 0.35))
                    p.closeSubpath()
                }
                .fill(Color.white.opacity(0.08))
            }
        }
        .clipShape(ChamferedShape())
    }
}
