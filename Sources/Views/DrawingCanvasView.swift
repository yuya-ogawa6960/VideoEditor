import SwiftUI
import UIKit

// =====================================================================
// 手書きキャンバス。プレビュー(映像の表示領域)の上に重ねて使う。
// 指やポインタでなぞった点を正規化座標(0...1、左上原点)で記録し、Binding に線として追加する。
// =====================================================================

/// 手書きの線を Path にする(Catmull-Rom 風に滑らかにつなぐ)
enum DrawingStrokePath {
    static func path(for stroke: DrawingStroke, in size: CGSize) -> Path {
        let points = stroke.points.map { CGPoint(x: CGFloat($0.x) * size.width, y: CGFloat($0.y) * size.height) }
        var path = Path()
        guard let first = points.first else { return path }
        if points.count == 1 {
            path.move(to: first)
            path.addLine(to: first)
            return path
        }
        if points.count == 2 {
            path.move(to: points[0])
            path.addLine(to: points[1])
            return path
        }
        path.move(to: first)
        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// 線幅(ポイント)。width は画面の短辺に対する比率
    static func lineWidth(for stroke: DrawingStroke, in size: CGSize) -> CGFloat {
        max(1, CGFloat(stroke.width) * min(size.width, size.height))
    }
}

struct DrawingCanvasView: View {
    /// 描き終えた線
    @Binding var strokes: [DrawingStroke]
    /// これから描く線の色(#RRGGBB)
    let colorHex: String
    /// これから描く線の太さ(短辺に対する比率)
    let width: Double

    /// 描いている途中の点
    @State private var currentPoints: [NormalizedPoint] = []

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, _ in
                for stroke in strokes {
                    draw(stroke, in: size, context: &context)
                }
                if !currentPoints.isEmpty {
                    let live = DrawingStroke(points: currentPoints, colorHex: colorHex, width: width)
                    draw(live, in: size, context: &context)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        let point = NormalizedPoint(x: clamp01(Double(value.location.x / size.width)),
                                                    y: clamp01(Double(value.location.y / size.height)))
                        if let last = currentPoints.last,
                           abs(last.x - point.x) < 0.002, abs(last.y - point.y) < 0.002 {
                            return
                        }
                        currentPoints.append(point)
                    }
                    .onEnded { _ in
                        var points = currentPoints
                        if points.count == 1, let only = points.first {
                            // タップだけのときは小さな点にする
                            points.append(NormalizedPoint(x: only.x + 0.001, y: only.y + 0.001))
                        }
                        if !points.isEmpty {
                            strokes.append(DrawingStroke(points: points, colorHex: colorHex, width: width))
                        }
                        currentPoints = []
                    }
            )
            .overlay(alignment: .topLeading) {
                Text("なぞって描く")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
                    .opacity(strokes.isEmpty && currentPoints.isEmpty ? 1 : 0)
            }
        }
    }

    private func clamp01(_ v: Double) -> Double {
        min(max(v, 0), 1)
    }

    private func draw(_ stroke: DrawingStroke, in size: CGSize, context: inout GraphicsContext) {
        let path = DrawingStrokePath.path(for: stroke, in: size)
        let lineWidth = DrawingStrokePath.lineWidth(for: stroke, in: size)
        let color = EditorColorHex.color(stroke.colorHex, fallback: .red)
        context.stroke(path,
                       with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}
