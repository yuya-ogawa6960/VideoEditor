import SwiftUI
import UIKit

// =====================================================================
// 手書きキャンバス。プレビュー(映像の表示領域)の上に重ねて使う。
// 指やポインタでなぞった点を正規化座標(0...1、左上原点)で記録し、Binding に線として追加する。
// 2 本指でつまむと拡大(最大 6 倍)、2 本指で動かすと移動する。映像は呼ぶ側が同じ zoom・pan で拡大する
// (中心を基準に scaleEffect → offset。この View の線も同じに描く)
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
    /// 拡大率(1 ... 6)と、拡大した絵の中心のずれ(pt)
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize

    /// 描いている途中の点
    @State private var currentPoints: [NormalizedPoint] = []

    static let maxZoom: CGFloat = 6

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
            .scaleEffect(zoom)
            .offset(pan)
            .clipped()
            .allowsHitTesting(false)
            .overlay {
                // 指の入力は拡大していない座標で受け、拡大を戻して線の点にする
                DrawingTouchInput(zoom: zoom, pan: pan,
                                  onStroke: { phase, location in
                                      handleStroke(phase, at: location, size: size)
                                  },
                                  onTransform: { newZoom, newPan in
                                      zoom = newZoom
                                      pan = Self.clampedPan(newPan, zoom: newZoom, size: size)
                                  })
            }
            .overlay(alignment: .topTrailing) {
                if zoom > 1.01 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            zoom = 1
                            pan = .zero
                        }
                    } label: {
                        Label("等倍に戻す", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                Text("なぞって描く・2本指で拡大")
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

    /// 画面上の点 → 拡大前のキャンバスの点(中心を基準に scaleEffect → offset の逆)
    static func unzoomed(_ p: CGPoint, zoom: CGFloat, pan: CGSize, size: CGSize) -> CGPoint {
        let z = max(zoom, 0.01)
        let cx = size.width / 2
        let cy = size.height / 2
        return CGPoint(x: cx + (p.x - cx - pan.width) / z, y: cy + (p.y - cy - pan.height) / z)
    }

    /// 拡大した絵が枠の外へずれて、端に何も無い所が出ないようにする
    static func clampedPan(_ pan: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let maxX = max(0, (zoom - 1) * size.width / 2)
        let maxY = max(0, (zoom - 1) * size.height / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    private func handleStroke(_ phase: DrawingTouchInput.Phase, at location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        switch phase {
        case .began, .moved:
            let p = Self.unzoomed(location, zoom: zoom, pan: pan, size: size)
            let point = NormalizedPoint(x: clamp01(Double(p.x / size.width)),
                                        y: clamp01(Double(p.y / size.height)))
            // 拡大しているときは細かく動かしても点を拾う
            let step = 0.002 / Double(max(zoom, 1))
            if phase == .moved, let last = currentPoints.last,
               abs(last.x - point.x) < step, abs(last.y - point.y) < step {
                return
            }
            if phase == .began { currentPoints = [] }
            currentPoints.append(point)
        case .ended:
            var points = currentPoints
            if points.count == 1, let only = points.first {
                // タップだけのときは小さな点にする
                points.append(NormalizedPoint(x: only.x + 0.001, y: only.y + 0.001))
            }
            if !points.isEmpty {
                strokes.append(DrawingStroke(points: points, colorHex: colorHex, width: width))
            }
            currentPoints = []
        case .cancelled:
            // 2 本目の指が触れた(拡大・移動を始めた)ときは、描きかけの線を捨てる
            currentPoints = []
        }
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

/// 手書きの指の入力。1 本指で描き、2 本指でつまむと拡大、2 本指で動かすと移動する。
/// 位置はこの View(拡大していない枠)の座標で渡す
struct DrawingTouchInput: UIViewRepresentable {
    enum Phase { case began, moved, ended, cancelled }

    let zoom: CGFloat
    let pan: CGSize
    let onStroke: (Phase, CGPoint) -> Void
    let onTransform: (CGFloat, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        let c = context.coordinator
        c.view = view
        view.coordinator = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handle(_:)))
        let twoFinger = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handle(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        pinch.delegate = c
        twoFinger.delegate = c
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(twoFinger)
        c.pinch = pinch
        c.twoFinger = twoFinger
        update(c)
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ c: Coordinator) {
        c.zoom = zoom
        c.pan = pan
        c.onStroke = onStroke
        c.onTransform = onTransform
    }

    final class TouchView: UIView {
        weak var coordinator: Coordinator?
        /// 描いている指(1 本だけ)
        private var drawingTouch: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let all = event?.allTouches?.filter { $0.view === self } ?? touches
            if all.count > 1 {
                cancelStroke()
                return
            }
            guard drawingTouch == nil, let touch = touches.first else { return }
            drawingTouch = touch
            coordinator?.onStroke?(.began, touch.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = drawingTouch, touches.contains(touch) else { return }
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for sample in samples {
                coordinator?.onStroke?(.moved, sample.location(in: self))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = drawingTouch, touches.contains(touch) else { return }
            drawingTouch = nil
            coordinator?.onStroke?(.ended, touch.location(in: self))
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            cancelStroke()
        }

        func cancelStroke() {
            guard drawingTouch != nil else { return }
            drawingTouch = nil
            coordinator?.onStroke?(.cancelled, .zero)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: TouchView?
        weak var pinch: UIPinchGestureRecognizer?
        weak var twoFinger: UIPanGestureRecognizer?
        var zoom: CGFloat = 1
        var pan: CGSize = .zero
        var onStroke: ((Phase, CGPoint) -> Void)?
        var onTransform: ((CGFloat, CGSize) -> Void)?

        /// 拡大・移動を始めたときの値
        private var transforming = false
        private var startZoom: CGFloat = 1
        private var startPinchScale: CGFloat = 1
        /// 始めたときに指の間にあった、拡大前のキャンバスの点(この点が指の間に付いてくる)
        private var anchor: CGPoint = .zero

        @objc func handle(_ g: UIGestureRecognizer) {
            guard let view else { return }
            // どちらかの指の操作が終わったら、残った操作は今の拡大から始め直す(拡大が戻ったり位置が飛んだりしない)
            if g.state == .ended || g.state == .cancelled || g.state == .failed {
                transforming = false
                return
            }
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let recognizers: [UIGestureRecognizer] = [pinch, twoFinger].compactMap { $0 }
            let active = recognizers.contains { $0.state == .began || $0.state == .changed }
            if !active {
                transforming = false
                return
            }
            view.cancelStroke()
            let location = g.location(in: view)
            let pinchActive = pinch.map { $0.state == .began || $0.state == .changed } ?? false
            let pinchScale: CGFloat = pinchActive ? (pinch?.scale ?? 1) : 1
            if !transforming {
                transforming = true
                startZoom = zoom
                startPinchScale = pinchScale
                anchor = DrawingCanvasView.unzoomed(location, zoom: zoom, pan: pan, size: size)
            }
            let ratio = startPinchScale > 0 ? pinchScale / startPinchScale : 1
            let newZoom = min(max(startZoom * ratio, 1), DrawingCanvasView.maxZoom)
            // anchor が今の指の位置に来るずれ
            let cx = size.width / 2
            let cy = size.height / 2
            let newPan = CGSize(width: location.x - cx - newZoom * (anchor.x - cx),
                                height: location.y - cy - newZoom * (anchor.y - cy))
            zoom = newZoom
            pan = newPan
            onTransform?(newZoom, newPan)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
