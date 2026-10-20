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

/// ポリゴン(多面体)のボタン背景: 外形は不ぞろいな多角形、中は明るさの違う三角形の面で埋める。
/// 色は左のオレンジから右のピンクへ。面ごとに明るさを変えて、光が当たった立体のように見せる
enum PolygonButtonMesh {
    /// 外形の頂点(正規化座標、時計回り)
    static let outline: [CGPoint] = [
        CGPoint(x: 0.10, y: 0.00), CGPoint(x: 0.45, y: 0.00), CGPoint(x: 0.80, y: 0.00),
        CGPoint(x: 0.95, y: 0.14), CGPoint(x: 1.00, y: 0.46), CGPoint(x: 0.97, y: 0.84),
        CGPoint(x: 0.86, y: 1.00), CGPoint(x: 0.50, y: 1.00), CGPoint(x: 0.13, y: 1.00),
        CGPoint(x: 0.02, y: 0.80), CGPoint(x: 0.00, y: 0.38), CGPoint(x: 0.04, y: 0.10)
    ]
    /// 内側の頂点
    static let inner: [CGPoint] = [
        CGPoint(x: 0.27, y: 0.48), CGPoint(x: 0.55, y: 0.56), CGPoint(x: 0.79, y: 0.40)
    ]
    /// 三角形(outline の番号 0...11、inner は 100 + 番号)と明るさ
    static let faces: [(Int, Int, Int, Double)] = [
        (11, 0, 100, 1.18), (0, 1, 100, 1.08), (1, 101, 100, 0.92), (1, 2, 101, 1.02),
        (2, 102, 101, 0.88), (2, 3, 102, 1.12), (3, 4, 102, 0.96), (4, 5, 102, 0.82),
        (5, 101, 102, 0.78), (5, 6, 101, 0.88), (6, 7, 101, 0.84), (7, 100, 101, 0.97),
        (7, 8, 100, 0.9), (8, 9, 100, 0.95), (9, 10, 100, 1.05), (10, 11, 100, 1.14)
    ]

    static func point(_ index: Int, in size: CGSize) -> CGPoint {
        let p = index >= 100 ? inner[index - 100] : outline[index]
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    /// 左のオレンジ → 右のピンクを x で混ぜ、明るさを掛ける
    static func color(atX x: Double, brightness: Double) -> Color {
        let a: (Double, Double, Double) = (0.86, 0.47, 0.13)
        let b: (Double, Double, Double) = (0.76, 0.19, 0.33)
        let t = min(max(x, 0), 1)
        let r = min(1, (a.0 + (b.0 - a.0) * t) * brightness)
        let g = min(1, (a.1 + (b.1 - a.1) * t) * brightness)
        let bl = min(1, (a.2 + (b.2 - a.2) * t) * brightness)
        return Color(red: r, green: g, blue: bl)
    }
}

/// 外形の多角形
struct PolygonOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (i, v) in PolygonButtonMesh.outline.enumerated() {
            let pt = CGPoint(x: rect.minX + v.x * rect.width, y: rect.minY + v.y * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// ポリゴンのボタン背景(書き出し・新しいプロジェクトなど)
struct FacetedBrandBackground: View {
    var body: some View {
        Canvas { context, size in
            for face in PolygonButtonMesh.faces {
                let a = PolygonButtonMesh.point(face.0, in: size)
                let b = PolygonButtonMesh.point(face.1, in: size)
                let c = PolygonButtonMesh.point(face.2, in: size)
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                path.addLine(to: c)
                path.closeSubpath()
                let centroidX = Double((a.x + b.x + c.x) / 3 / max(size.width, 1))
                let fill = PolygonButtonMesh.color(atX: centroidX, brightness: face.3)
                context.fill(path, with: .color(fill))
                // 面の境目をうっすら光らせる
                context.stroke(path, with: .color(Color.white.opacity(0.10)), lineWidth: 0.6)
            }
        }
        .clipShape(PolygonOutlineShape())
    }
}
