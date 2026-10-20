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

/// ポリゴン(多面体)のボタン背景: 外形はぼこぼこした多角形、中は明るさの違う三角形の面で埋める。
/// 色は左のオレンジから右のピンクへ。左上から光が当たったように、上ほど明るく、面ごとに明るさをずらす
enum PolygonButtonMesh {
    /// 外形の頂点(正規化座標、時計回り。辺が出たり引っ込んだりする)
    static let outline: [CGPoint] = [
        CGPoint(x: 0.06, y: 0.10), CGPoint(x: 0.22, y: 0.00), CGPoint(x: 0.36, y: 0.06), CGPoint(x: 0.52, y: 0.00),
        CGPoint(x: 0.68, y: 0.05), CGPoint(x: 0.84, y: 0.00), CGPoint(x: 0.96, y: 0.12), CGPoint(x: 1.00, y: 0.40),
        CGPoint(x: 0.97, y: 0.66), CGPoint(x: 1.00, y: 0.86), CGPoint(x: 0.88, y: 1.00), CGPoint(x: 0.72, y: 0.94),
        CGPoint(x: 0.56, y: 1.00), CGPoint(x: 0.40, y: 0.95), CGPoint(x: 0.24, y: 1.00), CGPoint(x: 0.08, y: 0.92),
        CGPoint(x: 0.00, y: 0.70), CGPoint(x: 0.03, y: 0.46), CGPoint(x: 0.00, y: 0.26)
    ]
    /// 内側の頂点(左から右へ)
    static let inner: [CGPoint] = [
        CGPoint(x: 0.16, y: 0.52), CGPoint(x: 0.34, y: 0.40), CGPoint(x: 0.50, y: 0.58),
        CGPoint(x: 0.66, y: 0.42), CGPoint(x: 0.84, y: 0.56)
    ]
    /// 面ごとの明るさのずれ
    private static let jitter: [Double] = [
        0.10, -0.06, 0.14, -0.12, 0.04, -0.15, 0.12, -0.02, 0.08, -0.10, 0.15, -0.08, 0.02, -0.14, 0.09, -0.04,
        0.13, -0.11, 0.06, -0.09, 0.11, -0.05, 0.07, -0.13, 0.03, -0.07, 0.12, -0.01, 0.05, -0.12, 0.10, -0.06
    ]

    /// 三角形の 3 頂点(正規化座標)
    static let faces: [[CGPoint]] = {
        func nearest(_ p: CGPoint) -> Int {
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (k, q) in inner.enumerated() {
                let d = abs(Double(q.x - p.x)) + 0.3 * abs(Double(q.y - p.y))
                if d < bestDistance {
                    bestDistance = d
                    best = k
                }
            }
            return best
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        var result: [[CGPoint]] = []
        let n = outline.count
        for i in 0..<n {
            let a = outline[i]
            let b = outline[(i + 1) % n]
            let c = outline[(i + 2) % n]
            let k = nearest(mid(a, b))
            result.append([a, b, inner[k]])
            let next = nearest(mid(b, c))
            if next != k {
                let lo = min(k, next)
                let hi = max(k, next)
                for j in lo..<hi {
                    result.append([b, inner[j], inner[j + 1]])
                }
            }
        }
        return result
    }()

    /// 面の色(x, y は面の中心の正規化座標)
    static func color(x: Double, y: Double, face: Int) -> Color {
        let a: (Double, Double, Double) = (0.86, 0.47, 0.13)
        let b: (Double, Double, Double) = (0.76, 0.19, 0.33)
        let t = min(max(x, 0), 1)
        let light = 1.0 + 0.28 * (0.5 - y) + 0.10 * (0.5 - x) + jitter[face % jitter.count] * 1.1
        func channel(_ from: Double, _ to: Double) -> Double {
            min(max((from + (to - from) * t) * light, 0), 1)
        }
        return Color(red: channel(a.0, b.0), green: channel(a.1, b.1), blue: channel(a.2, b.2))
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
            for (index, face) in PolygonButtonMesh.faces.enumerated() {
                let pts: [CGPoint] = face.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                var path = Path()
                path.move(to: pts[0])
                path.addLine(to: pts[1])
                path.addLine(to: pts[2])
                path.closeSubpath()
                let cx = Double((face[0].x + face[1].x + face[2].x) / 3)
                let cy = Double((face[0].y + face[1].y + face[2].y) / 3)
                context.fill(path, with: .color(PolygonButtonMesh.color(x: cx, y: cy, face: index)))
                // 面の境目をうっすら光らせる
                context.stroke(path, with: .color(Color(red: 1, green: 0.75, blue: 0.6).opacity(0.35)), lineWidth: 0.6)
            }
        }
        .clipShape(PolygonOutlineShape())
    }
}
