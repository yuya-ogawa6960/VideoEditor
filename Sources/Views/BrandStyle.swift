import SwiftUI

// =====================================================================
// 大事なボタン(新しいプロジェクト・書き出し・動画を追加)の色: 緑 → 青のステンドグラス。
// オレンジ / ピンクはアイコンの網点の色(ロボットの飾りなどに残している)。
// アプリ全体の差し色(AccentColor)はコーラルのまま。
// =====================================================================

enum BrandStyle {
    static let green = Color(red: 0.13, green: 0.58, blue: 0.40)
    static let blue = Color(red: 0.12, green: 0.42, blue: 0.78)
    static let orange = Color(red: 0.86, green: 0.47, blue: 0.13)
    static let pink = Color(red: 0.76, green: 0.19, blue: 0.33)
    static let coral = Color(red: 0.85, green: 0.33, blue: 0.27)
    /// 紺(アイコンの背景)
    static let navy = Color(red: 0.063, green: 0.102, blue: 0.2)

    static var gradient: LinearGradient {
        LinearGradient(colors: [green, blue], startPoint: .leading, endPoint: .trailing)
    }
}

/// 緑 → 青のステンドグラス塗りのボタン(書き出しなど)
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

/// 八角形のボタン背景: 四隅を同じだけ斜めに切り落とした八角形を、中心から各辺への 8 枚の面に分け、
/// 面ごとに明るさを変えて立体に見せる(左上から光)。色は左のオレンジから右のピンクへ
struct PolygonOutlineShape: Shape {
    /// 切り落とす大きさ(高さに対する比率)
    var cut: CGFloat = 0.3

    static func vertices(in rect: CGRect, cut: CGFloat) -> [CGPoint] {
        let c = min(rect.height * cut, rect.width / 2)
        return [
            CGPoint(x: rect.minX + c, y: rect.minY), CGPoint(x: rect.maxX - c, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + c), CGPoint(x: rect.maxX, y: rect.maxY - c),
            CGPoint(x: rect.maxX - c, y: rect.maxY), CGPoint(x: rect.minX + c, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY - c), CGPoint(x: rect.minX, y: rect.minY + c)
        ]
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let v = Self.vertices(in: rect, cut: cut)
        p.move(to: v[0])
        for point in v.dropFirst() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }
}

/// ステンドグラス風の八角形のボタン背景(書き出し・新しいプロジェクトなど)。
/// 八角形の中を、3 つの中心から放射状に伸びる白い線で三角形のガラスに分け、ガラスごとに明るさを変える
/// (メルボルンのトラムの側面のような模様)。色は左のオレンジから右のピンクへ
struct FacetedBrandBackground: View {
    /// 放射の中心(正規化座標、左から右)
    private static let hubs: [CGPoint] = [CGPoint(x: 0.22, y: 0.76), CGPoint(x: 0.5, y: 0.22), CGPoint(x: 0.78, y: 0.8)]
    /// ガラスごとの明るさ(明暗を交互に)
    private static let shades: [Double] = [1.18, 0.82, 1.06, 0.9, 1.22, 0.78, 1.0, 0.88, 1.14, 0.8, 1.1, 0.86, 1.2, 0.84, 1.04, 0.92]

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let corners = PolygonOutlineShape.vertices(in: rect, cut: 0.3)
            // 外周の点(上と下の長い辺は 4 つに分けて、放射の線を増やす)
            var perimeter: [CGPoint] = []
            for i in 0..<corners.count {
                let a = corners[i]
                let b = corners[(i + 1) % corners.count]
                perimeter.append(a)
                if abs(a.y - b.y) < 0.5 {
                    for j in 1..<4 {
                        let t = CGFloat(j) / 4
                        perimeter.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    }
                }
            }
            let hubs: [CGPoint] = Self.hubs.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            func nearest(_ p: CGPoint) -> Int {
                var best = 0
                var distance = CGFloat.greatestFiniteMagnitude
                for (k, h) in hubs.enumerated() where abs(h.x - p.x) < distance {
                    distance = abs(h.x - p.x)
                    best = k
                }
                return best
            }
            var faces: [[CGPoint]] = []
            let n = perimeter.count
            for i in 0..<n {
                let a = perimeter[i]
                let b = perimeter[(i + 1) % n]
                let c = perimeter[(i + 2) % n]
                let k = nearest(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                faces.append([a, b, hubs[k]])
                let next = nearest(CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2))
                if next != k {
                    for j in min(k, next)..<max(k, next) {
                        faces.append([b, hubs[j], hubs[j + 1]])
                    }
                }
            }
            // ガラス
            for (index, face) in faces.enumerated() {
                let path = Self.triangle(face)
                let cx = Double((face[0].x + face[1].x + face[2].x) / 3 / max(size.width, 1))
                context.fill(path, with: .color(Self.color(x: cx, light: Self.shades[index % Self.shades.count])))
            }
        }
        .clipShape(PolygonOutlineShape())
    }

    private static func triangle(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.closeSubpath()
        return path
    }

    private static func color(x: Double, light: Double) -> Color {
        // 左の緑 → 右の青(ガラスごとの明暗は shades で付ける)
        let a: (Double, Double, Double) = (0.13, 0.58, 0.40)
        let b: (Double, Double, Double) = (0.12, 0.42, 0.78)
        let t = min(max(x, 0), 1)
        func channel(_ from: Double, _ to: Double) -> Double {
            min(max((from + (to - from) * t) * light, 0), 1)
        }
        return Color(red: channel(a.0, b.0), green: channel(a.1, b.1), blue: channel(a.2, b.2))
    }
}
