import Foundation
import UIKit
import CoreImage

// =====================================================================
// 動くステッカーの描画
//   VectorStickerDrawer  : 1 コマ分の絵を CGContext に描く(左上原点。プレビューの Canvas と書き出しで共通)
//   VectorStickerRenderer: TextClip 用の CIImage を作る。1 回の動きを 30 コマ/秒に区切ってキャッシュ
//   絵は高さ 100 の設計座標(横は 100 × aspect)で描き、描くときに拡大する
// =====================================================================

enum VectorStickerRenderer {

    /// 文字サイズに対する絵の高さの比率(絵文字ステッカーの枠と同じ 1.25 倍)
    static let boxScale: Double = 1.25

    /// NSCache 自体がスレッドセーフ
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 360
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// 絵のピクセルサイズ(配置の拡大前)
    static func pixelSize(sizeRatio: Double, kind: VectorStickerKind, canvasSize: CGSize) -> CGSize {
        let shortSide = Double(min(canvasSize.width, canvasSize.height))
        let height = max(8, (GeometryMath.clamp(sizeRatio, 0.01, 0.6) * shortSide * boxScale).rounded())
        let width = max(8, (height * kind.aspect).rounded())
        return CGSize(width: min(4096, width), height: min(4096, height))
    }

    /// クリップ内の時刻 localTime の絵(原点 (0,0)、配置・拡大・回転は未適用)
    static func image(for clip: TextClip, localTime: Double, canvasSize: CGSize) -> CIImage? {
        guard let kind = clip.vectorSticker, canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let size = pixelSize(sizeRatio: clip.style.sizeRatio, kind: kind, canvasSize: canvasSize)
        let period = max(0.1, kind.period)
        let steps = max(12, Int((period * 30).rounded()))
        var phase = localTime.isFinite ? localTime.truncatingRemainder(dividingBy: period) / period : 0
        if phase < 0 { phase += 1 }
        let step = min(steps - 1, max(0, Int(phase * Double(steps))))
        let time = Double(step) / Double(steps) * period
        let text = kind.hasText ? clip.text : ""
        let colorHex = clip.style.colorHex
        let key = "\(kind.rawValue)|\(colorHex)|\(text)|\(Int(size.width))x\(Int(size.height))|\(step)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { context in
            VectorStickerDrawer.drawFitted(kind, in: context.cgContext, size: size, time: time, colorHex: colorHex, text: text)
        }
        guard let cg = uiImage.cgImage else { return nil }
        let image = CIImage(cgImage: cg)
        cache.setObject(image, forKey: key, cost: Int(size.width * size.height * 4))
        return image
    }
}

// MARK: - 1 コマの絵

enum VectorStickerDrawer {

    /// 設計上の大きさ(高さ 100)
    static func designSize(_ kind: VectorStickerKind) -> CGSize {
        CGSize(width: 100 * kind.aspect, height: 100)
    }

    /// size(左上原点)の中に縦横比を保って収めて描く
    static func drawFitted(_ kind: VectorStickerKind, in cg: CGContext, size: CGSize, time: Double,
                           colorHex: String, text: String) {
        let design = designSize(kind)
        guard size.width > 1, size.height > 1 else { return }
        let s = min(size.width / design.width, size.height / design.height)
        cg.saveGState()
        cg.translateBy(x: (size.width - design.width * s) / 2, y: (size.height - design.height * s) / 2)
        cg.scaleBy(x: s, y: s)
        // 文字は UIKit で描くので、このコンテキストを現在のものにする
        UIGraphicsPushContext(cg)
        draw(kind, in: cg, time: time, color: UIColor(hex: colorHex) ?? .white, text: text)
        UIGraphicsPopContext()
        cg.restoreGState()
    }

    /// 設計座標(高さ 100)で 1 コマを描く
    static func draw(_ kind: VectorStickerKind, in cg: CGContext, time: Double, color: UIColor, text: String) {
        let period = max(0.1, kind.period)
        var p = time.isFinite ? time.truncatingRemainder(dividingBy: period) / period : 0
        if p < 0 { p += 1 }
        let tau = Double.pi * 2
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        switch kind {

        // MARK: 矢印
        case .arrowBounce:
            let bounce = CGFloat(abs(sin(Double.pi * p))) * 12
            let path = CGMutablePath()
            path.addLines(between: [pt(39, 16), pt(61, 16), pt(61, 54), pt(82, 54), pt(50, 92), pt(18, 54), pt(39, 54)])
            path.closeSubpath()
            transformed(cg, offset: CGPoint(x: 0, y: -bounce)) {
                fill(path, color, cg)
            }

        case .arrowCurved:
            let d = drawOn(p)
            let points = quadPoints(pt(16, 86), pt(18, 24), pt(76, 28), count: 40)
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) {
                    stroke(path, color, width: 9, cg)
                }
                let headScale = clamp01((d.progress - 0.85) / 0.15)
                if headScale > 0.01, let tip = points.last {
                    let prev = points[points.count - 2]
                    arrowHead(tip: tip, from: prev, size: 16 * headScale, color: color, cg)
                }
            }

        case .pointingHand:
            let dx = CGFloat(sin(tau * p)) * 7
            transformed(cg, offset: CGPoint(x: dx, y: 0)) {
                fill(roundedRect(9, 34, 11, 40, 3), UIColor.white, cg, outlineWidth: 5)
                fill(roundedRect(18, 30, 40, 48, 14), color, cg, outlineWidth: 5)
                fill(roundedRect(46, 46, 20, 10, 5), color, cg, outlineWidth: 5)
                fill(roundedRect(46, 56, 19, 10, 5), color, cg, outlineWidth: 5)
                fill(roundedRect(46, 66, 17, 10, 5), color, cg, outlineWidth: 5)
                fill(roundedRect(32, 20, 22, 14, 7), color, cg, outlineWidth: 5)
                fill(roundedRect(46, 30, 42, 16, 8), color, cg, outlineWidth: 5)
            }

        case .chevrons:
            for i in 0..<3 {
                let bump = CGFloat(max(0, sin(tau * (p - Double(i) / 3))))
                let x = 30 + CGFloat(i) * 38 + bump * 4
                let path = CGMutablePath()
                path.addLines(between: [pt(x, 26), pt(x + 22, 50), pt(x, 74)])
                alpha(cg, 0.3 + 0.7 * bump) {
                    stroke(path, color, width: 12, cg)
                }
            }

        // MARK: 吹き出し
        case .speechBubble:
            let scale = 1 + 0.03 * CGFloat(sin(tau * p))
            let rotation = 0.025 * CGFloat(sin(tau * p + 0.5))
            transformed(cg, around: pt(80, 50), scale: scale, rotation: rotation) {
                fill(speechPath(), color, cg)
                drawText(text, in: CGRect(x: 20, y: 14, width: 120, height: 50), color: contrast(color), maxSize: 40)
            }

        case .thoughtBubble:
            let dy = CGFloat(sin(tau * p)) * 2
            let blobs: [(CGFloat, CGFloat, CGFloat)] = [(40, 44, 22), (64, 28, 20), (94, 26, 20), (120, 40, 20),
                                                        (110, 58, 16), (76, 60, 16), (48, 60, 13)]
            let core = CGPath(ellipseIn: CGRect(x: 30, y: 20, width: 100, height: 44), transform: nil)
            transformed(cg, offset: CGPoint(x: 0, y: dy)) {
                // 輪郭をまとめて描いてから塗ると、雲の形の外側だけに線が残る
                let paths = blobs.map { circle($0.0, $0.1, $0.2) } + [core]
                for path in paths { outlineStroke(path, width: 6, cg) }
                for path in paths { solidFill(path, color, cg) }
                drawText(text, in: CGRect(x: 34, y: 20, width: 92, height: 44), color: contrast(color), maxSize: 34)
            }
            let a1 = 0.55 + 0.45 * CGFloat(0.5 + 0.5 * sin(tau * p))
            let a2 = 0.55 + 0.45 * CGFloat(0.5 + 0.5 * sin(tau * p - 1.2))
            alpha(cg, a1) { fill(circle(34, 82, 7), color, cg, outlineWidth: 4) }
            alpha(cg, a2) { fill(circle(22, 93, 4.5), color, cg, outlineWidth: 3) }

        case .shoutBubble:
            let scale = 1 + 0.04 * CGFloat(abs(sin(tau * p)))
            let dx = CGFloat(sin(tau * p * 3)) * 1.5
            transformed(cg, around: pt(80, 48), offset: CGPoint(x: dx, y: 0), scale: scale) {
                fill(spikyPath(center: pt(80, 48), rx: 68, ry: 40), color, cg)
                drawText(text, in: CGRect(x: 38, y: 30, width: 84, height: 36), color: contrast(color), maxSize: 36)
            }

        // MARK: キラキラ
        case .sparkles:
            let items: [(CGPoint, CGFloat, Double)] = [(pt(34, 34), 22, 0), (pt(68, 62), 28, 0.33), (pt(26, 76), 13, 0.66)]
            for (center, radius, phase) in items {
                let s = 0.45 + 0.55 * CGFloat(0.5 + 0.5 * sin(tau * (p + phase)))
                let r = radius * s
                fill(sparklePath(center, r), color, cg, outlineWidth: 4)
                alpha(cg, 0.8) { solidFill(circle(center.x, center.y, r * 0.16), .white, cg) }
            }

        case .starBurst:
            let e = CGFloat(easeOutCubic(p))
            let a = CGFloat(p < 0.1 ? p / 0.1 : 1 - (p - 0.1) / 0.9)
            for k in 0..<8 {
                let angle = Double(k) / 8 * tau + 0.2
                let dist = 12 + 28 * e
                let c = pt(50 + dist * CGFloat(cos(angle)), 50 + dist * CGFloat(sin(angle)))
                let size = 7 * (1 - CGFloat(p) * 0.6)
                alpha(cg, a) {
                    fill(starPath(c, outer: size, inner: size * 0.45, points: 5, rotation: CGFloat(angle)), color, cg, outlineWidth: 3)
                }
            }
            let pop = CGFloat(p < 0.2 ? sin(Double.pi * p / 0.2) : 0)
            let r = 20 * (0.85 + 0.25 * pop)
            fill(starPath(pt(50, 50), outer: r, inner: r * 0.45, points: 5, rotation: 0), color, cg)

        case .glitter:
            var random = StickerRandom(seed: 7)
            for i in 0..<24 {
                let x = 10 + 80 * random.next()
                let y = 10 + 80 * random.next()
                let phase = Double(random.next())
                let size = 2 + 3.5 * random.next()
                let twinkle = CGFloat(max(0, sin(tau * (p + phase))))
                guard twinkle > 0.03 else { continue }
                let tint: UIColor = i % 3 == 0 ? .white : color
                if i % 4 == 0 {
                    fill(sparklePath(pt(x, y), size * 2.4 * twinkle), tint, cg, outlineWidth: 2)
                } else {
                    alpha(cg, twinkle) { fill(circle(x, y, size * (0.6 + 0.4 * twinkle)), tint, cg, outlineWidth: 2) }
                }
            }

        // MARK: ハート
        case .heartBeat:
            let beat = exp(-pow((p - 0.12) / 0.06, 2)) + 0.7 * exp(-pow((p - 0.32) / 0.06, 2))
            let s = 34 * (1 + 0.14 * CGFloat(beat))
            let center = pt(50, 52)
            fill(heartPath(center, s), color, cg)
            alpha(cg, 0.55) {
                solidFill(CGPath(ellipseIn: CGRect(x: center.x - 0.62 * s, y: center.y - 0.55 * s, width: 0.36 * s, height: 0.22 * s),
                                 transform: nil), .white, cg)
            }

        case .heartsFloat:
            let baseX: [CGFloat] = [30, 62, 44, 74, 26]
            let sizes: [CGFloat] = [11, 9, 13, 8, 10]
            for i in 0..<5 {
                var q = (p + Double(i) / 5).truncatingRemainder(dividingBy: 1)
                if q < 0 { q += 1 }
                let y = 88 - 72 * CGFloat(q)
                let x = baseX[i] + CGFloat(sin(tau * (q * 1.2 + Double(i) * 0.37))) * 7
                let a = CGFloat(q < 0.15 ? q / 0.15 : (q > 0.7 ? (1 - q) / 0.3 : 1))
                let s = sizes[i] * (0.6 + 0.4 * CGFloat(min(1, q / 0.2)))
                alpha(cg, a) { fill(heartPath(pt(x, y), s), color, cg, outlineWidth: 4) }
            }

        // MARK: 枠・線
        case .circleDraw:
            let d = drawOn(p)
            var points: [CGPoint] = []
            let count = 90
            for i in 0...count {
                let t = Double(i) / Double(count)
                let angle = -1.9 + tau * 1.08 * t
                let f = 1 + 0.05 * t + 0.012 * sin(t * 12)
                points.append(pt(70 + 58 * CGFloat(f * cos(angle)), 50 + 38 * CGFloat(f * sin(angle))))
            }
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) { stroke(path, color, width: 6, cg) }
            }

        case .underlineScribble:
            let d = drawOn(p)
            var points: [CGPoint] = []
            for i in 0...40 {
                let x = 16 + 268 * CGFloat(i) / 40
                points.append(pt(x, 46 + CGFloat(sin(Double(x) * 0.05)) * 5))
            }
            for i in 1...24 {
                let t = CGFloat(i) / 24
                let x = 284 - 204 * t
                points.append(pt(x, 46 + 14 * min(1, t * 3) + CGFloat(sin(Double(x) * 0.06)) * 3))
            }
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) { stroke(path, color, width: 8, cg) }
            }

        case .rectFrame:
            let d = drawOn(p)
            let corners = [pt(12, 13), pt(128, 11), pt(129, 88), pt(11, 89), pt(12, 13), pt(34, 11)]
            var points: [CGPoint] = []
            for i in 1..<corners.count {
                let a = corners[i - 1]
                let b = corners[i]
                for j in 0..<12 {
                    let t = CGFloat(j) / 12
                    let wobble = CGFloat(sin(Double(i * 12 + j) * 0.9)) * 0.8
                    points.append(pt(a.x + (b.x - a.x) * t + wobble, a.y + (b.y - a.y) * t - wobble))
                }
            }
            points.append(corners[corners.count - 1])
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) { stroke(path, color, width: 6, cg) }
            }

        // MARK: リアクション
        case .exclaimQuestion:
            let scale = 1 + 0.08 * CGFloat(sin(tau * p))
            let rotation = -0.1 + 0.08 * CGFloat(sin(tau * p * 2))
            transformed(cg, around: pt(50, 50), scale: scale, rotation: rotation) {
                drawText("!?", in: CGRect(x: 10, y: 10, width: 80, height: 80), color: color, maxSize: 90, outline: true)
            }

        case .question:
            let rotation = 0.18 * CGFloat(sin(tau * p))
            transformed(cg, around: pt(50, 90), rotation: rotation) {
                drawText("?", in: CGRect(x: 20, y: 8, width: 60, height: 82), color: color, maxSize: 90, outline: true)
            }

        case .bulb:
            let pulse = CGFloat(0.5 + 0.5 * sin(tau * p))
            let center = pt(50, 48)
            alpha(cg, 0.25 * pulse) { solidFill(circle(center.x, center.y, 30 * (1 + 0.1 * pulse)), color, cg) }
            for k in 0..<7 {
                let angle = -Double.pi + Double(k) * Double.pi / 6
                let r0: CGFloat = 29
                let r1: CGFloat = 34 + 5 * pulse
                let ray = CGMutablePath()
                ray.move(to: pt(center.x + r0 * CGFloat(cos(angle)), center.y + r0 * CGFloat(sin(angle))))
                ray.addLine(to: pt(center.x + r1 * CGFloat(cos(angle)), center.y + r1 * CGFloat(sin(angle))))
                alpha(cg, 0.5 + 0.5 * pulse) { stroke(ray, color, width: 5, cg) }
            }
            fill(roundedRect(40, 64, 20, 16, 4), UIColor(white: 0.75, alpha: 1), cg, outlineWidth: 5)
            fill(roundedRect(43, 79, 14, 7, 3), UIColor(white: 0.4, alpha: 1), cg, outlineWidth: 5)
            fill(circle(center.x, center.y, 22), color, cg)
            let filament = CGMutablePath()
            filament.addLines(between: [pt(42, 56), pt(46, 50), pt(50, 56), pt(54, 50), pt(58, 56)])
            alpha(cg, 0.6) { stroke(filament, UIColor(red: 0.85, green: 0.45, blue: 0, alpha: 1), width: 2.5, cg, outlined: false) }
            alpha(cg, 0.6) { solidFill(CGPath(ellipseIn: CGRect(x: 36, y: 34, width: 10, height: 7), transform: nil), .white, cg) }

        case .sweat:
            let drops: [(CGPoint, CGFloat, Double)] = [(pt(30, 34), 12, 0), (pt(58, 22), 9, 0.4), (pt(72, 50), 14, 0.7)]
            for (center, s, phase) in drops {
                var q = (p + phase).truncatingRemainder(dividingBy: 1)
                if q < 0 { q += 1 }
                let c = pt(center.x, center.y + CGFloat(q) * 10)
                let a = CGFloat(q < 0.2 ? q / 0.2 : (1 - q) / 0.8)
                alpha(cg, a) {
                    fill(dropPath(c, s), color, cg, outlineWidth: 4)
                    solidFill(CGPath(ellipseIn: CGRect(x: c.x - s * 0.32, y: c.y + s * 0.05, width: s * 0.22, height: s * 0.3),
                                     transform: nil), UIColor.white.withAlphaComponent(0.8), cg)
                }
            }

        case .anger:
            let b = pow(max(0, 1 - abs(p - 0.2) / 0.2), 2)
            let scale = 1 + 0.18 * CGFloat(b)
            let center = pt(50, 50)
            transformed(cg, around: center, scale: scale) {
                for k in 0..<4 {
                    transformed(cg, around: center, rotation: CGFloat(Double(k) * Double.pi / 2)) {
                        let arc = CGMutablePath()
                        arc.move(to: pt(center.x + 8, center.y - 32))
                        arc.addQuadCurve(to: pt(center.x + 32, center.y - 8), control: pt(center.x + 8, center.y - 8))
                        stroke(arc, color, width: 11, cg)
                    }
                }
            }

        case .laugh:
            let items: [(CGPoint, CGFloat, CGFloat)] = [(pt(22, 62), -0.2, 32), (pt(52, 40), 0.1, 40), (pt(80, 62), 0.25, 30)]
            for (i, item) in items.enumerated() {
                let bump = CGFloat(max(0, sin(tau * (p - Double(i) / 6))))
                transformed(cg, around: item.0, offset: CGPoint(x: 0, y: -bump * 4), scale: 0.85 + 0.25 * bump, rotation: item.1) {
                    let s = item.2
                    drawText("w", in: CGRect(x: item.0.x - s / 2, y: item.0.y - s / 2, width: s, height: s),
                             color: color, maxSize: s * 1.4, outline: true)
                }
            }

        case .emphasisLines:
            let frame: UInt32 = p < 0.5 ? 1 : 2
            var random = StickerRandom(seed: frame)
            let center = pt(50, 50)
            for k in 0..<18 {
                let angle = Double(k) / 18 * tau + Double(random.next()) * 0.15
                let r0 = 28 + 10 * random.next()
                let r1: CGFloat = 46
                let line = CGMutablePath()
                line.move(to: pt(center.x + r0 * CGFloat(cos(angle)), center.y + r0 * CGFloat(sin(angle))))
                line.addLine(to: pt(center.x + r1 * CGFloat(cos(angle)), center.y + r1 * CGFloat(sin(angle))))
                stroke(line, color, width: 3.5, cg)
            }

        // MARK: 手書き風
        case .scribbleCircle:
            let d = drawOn(p)
            var points: [CGPoint] = []
            let count = 140
            for i in 0...count {
                let t = Double(i) / Double(count)
                let angle = -1.2 + tau * 2.6 * t
                let r = 34 + 5 * sin(t * 9.0) + 3 * t
                let wobble = 0.25 * sin(t * 5)
                points.append(pt(50 + CGFloat(r * 1.05 * cos(angle + wobble)), 50 + CGFloat(r * 0.85 * sin(angle))))
            }
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) { stroke(path, color, width: 5, cg) }
            }

        case .checkDraw:
            let d = drawOn(p)
            var points = linePoints(pt(18, 52), pt(42, 78), count: 8)
            points += quadPoints(pt(42, 78), pt(58, 46), pt(84, 20), count: 16).dropFirst()
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) { stroke(path, color, width: 12, cg) }
            }

        case .crossDraw:
            let d = drawOn(p)
            let first = quadPoints(pt(24, 24), pt(52, 46), pt(76, 76), count: 16)
            let second = quadPoints(pt(76, 24), pt(46, 48), pt(24, 76), count: 16)
            fade(cg, d.alpha) {
                if let path = partialPath(first, fraction: min(1, d.progress * 2)) { stroke(path, color, width: 11, cg) }
                if d.progress > 0.5, let path = partialPath(second, fraction: (d.progress - 0.5) * 2) {
                    stroke(path, color, width: 11, cg)
                }
            }

        case .doodleStar:
            let d = drawOn(p)
            var corners: [CGPoint] = []
            for k in 0...10 {
                let angle = -Double.pi / 2 + Double(k) * Double.pi / 5
                let r: CGFloat = (k % 2 == 0 ? 40 : 17) + CGFloat(sin(Double(k) * 2.3)) * 1.5
                corners.append(pt(50 + r * CGFloat(cos(angle)), 54 + r * CGFloat(sin(angle))))
            }
            var points: [CGPoint] = []
            for i in 1..<corners.count {
                points += linePoints(corners[i - 1], corners[i], count: 6).dropLast()
            }
            points.append(corners[corners.count - 1])
            fade(cg, d.alpha) {
                if let path = partialPath(points, fraction: d.progress) { stroke(path, color, width: 6, cg) }
            }

        // MARK: 数字
        case .badge1, .badge2, .badge3:
            let scale = 1 + 0.05 * CGFloat(sin(tau * p))
            let center = pt(50, 50)
            transformed(cg, around: center, scale: scale) {
                transformed(cg, around: center, rotation: CGFloat(p * tau / 6)) {
                    cg.saveGState()
                    cg.setLineDash(phase: 0, lengths: [8, 7])
                    stroke(circle(50, 50, 44), color, width: 4, cg)
                    cg.restoreGState()
                }
                fill(circle(50, 50, 36), color, cg)
                alpha(cg, 0.7) { stroke(circle(50, 50, 31), .white, width: 2.5, cg, outlined: false) }
                drawText(text, in: CGRect(x: 26, y: 24, width: 48, height: 52), color: contrast(color), maxSize: 56)
            }

        // MARK: シーン
        case .likeButton:
            pill(text: text, color: color, p: p, cg) { center in
                let pop = CGFloat(p > 0.5 && p < 0.75 ? sin(Double.pi * (p - 0.5) / 0.25) : 0)
                fill(heartPath(pt(center.x, center.y + 1), 13 * (1 + 0.3 * pop)), color, cg, outlineWidth: 0)
            }

        case .saveButton:
            pill(text: text, color: color, p: p, cg) { center in
                let dy = -CGFloat(abs(sin(tau * p))) * 3
                let mark = CGMutablePath()
                mark.addLines(between: [pt(center.x - 10, center.y - 13 + dy), pt(center.x + 10, center.y - 13 + dy),
                                        pt(center.x + 10, center.y + 13 + dy), pt(center.x, center.y + 5 + dy),
                                        pt(center.x - 10, center.y + 13 + dy)])
                mark.closeSubpath()
                solidFill(mark, color, cg)
            }

        case .subscribeButton:
            pill(text: text, color: color, p: p, cg) { center in
                let swing = CGFloat(p < 0.5 ? 0.35 * sin(tau * p * 4) * (1 - p * 2) : 0)
                transformed(cg, around: pt(center.x, center.y - 12), rotation: swing) {
                    solidFill(bellPath(center, 15), color, cg)
                    solidFill(circle(center.x, center.y + 11, 3.2), color, cg)
                }
            }

        case .newBadge:
            let center = pt(50, 50)
            transformed(cg, around: center, rotation: CGFloat(p * tau / 18)) {
                fill(starPath(center, outer: 46, inner: 40, points: 18, rotation: 0), color, cg)
            }
            let scale = 1 + 0.06 * CGFloat(sin(tau * p))
            transformed(cg, around: center, scale: scale) {
                drawText(text, in: CGRect(x: 20, y: 32, width: 60, height: 36), color: contrast(color), maxSize: 34)
            }
        }
    }

    // MARK: - 部品

    private static let outlineColor = UIColor(white: 0.08, alpha: 0.85)

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    private static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }

    private static func easeInOut(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v < 0.5 ? 2 * v * v : 1 - pow(-2 * v + 2, 2) / 2
    }

    /// 描いていく動き: 前半で描き、しばらく止まって、最後に消える
    private static func drawOn(_ p: Double) -> (progress: CGFloat, alpha: CGFloat) {
        let progress = CGFloat(easeInOut(p / 0.45))
        let a: CGFloat = p < 0.85 ? 1 : CGFloat(max(0, (1 - p) / 0.15))
        return (progress, a)
    }

    /// 暗い縁取り → 塗り
    private static func fill(_ path: CGPath, _ color: UIColor, _ cg: CGContext, outlineWidth: CGFloat = 6) {
        if outlineWidth > 0 { outlineStroke(path, width: outlineWidth, cg) }
        solidFill(path, color, cg)
    }

    private static func solidFill(_ path: CGPath, _ color: UIColor, _ cg: CGContext) {
        cg.addPath(path)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
    }

    private static func outlineStroke(_ path: CGPath, width: CGFloat, _ cg: CGContext) {
        cg.addPath(path)
        cg.setStrokeColor(outlineColor.cgColor)
        cg.setLineWidth(width)
        cg.setLineJoin(.round)
        cg.strokePath()
    }

    /// 線(外側に暗い縁を付ける)
    private static func stroke(_ path: CGPath, _ color: UIColor, width: CGFloat, _ cg: CGContext, outlined: Bool = true) {
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if outlined {
            cg.addPath(path)
            cg.setStrokeColor(outlineColor.cgColor)
            cg.setLineWidth(width + 5)
            cg.strokePath()
        }
        cg.addPath(path)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.strokePath()
    }

    /// 部分ごとの不透明度
    private static func alpha(_ cg: CGContext, _ a: CGFloat, _ body: () -> Void) {
        guard a > 0.001 else { return }
        cg.saveGState()
        cg.setAlpha(min(1, a))
        body()
        cg.restoreGState()
    }

    /// まとめて薄くする(重なった線が濃くならないように 1 枚にしてから)
    private static func fade(_ cg: CGContext, _ a: CGFloat, _ body: () -> Void) {
        guard a > 0.001 else { return }
        if a >= 0.999 {
            body()
            return
        }
        cg.saveGState()
        cg.setAlpha(a)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    /// center を中心に拡大・回転し、offset だけずらして描く
    private static func transformed(_ cg: CGContext, around center: CGPoint = .zero, offset: CGPoint = .zero,
                                    scale: CGFloat = 1, rotation: CGFloat = 0, _ body: () -> Void) {
        cg.saveGState()
        cg.translateBy(x: center.x + offset.x, y: center.y + offset.y)
        if rotation != 0 { cg.rotate(by: rotation) }
        if scale != 1 { cg.scaleBy(x: scale, y: scale) }
        cg.translateBy(x: -center.x, y: -center.y)
        body()
        cg.restoreGState()
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
    }

    private static func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        let corner = max(0, min(r, w / 2 - 0.01, h / 2 - 0.01))
        return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    private static func linePoints(_ a: CGPoint, _ b: CGPoint, count: Int) -> [CGPoint] {
        (0...max(1, count)).map { i in
            let t = CGFloat(i) / CGFloat(max(1, count))
            return pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        }
    }

    private static func quadPoints(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, count: Int) -> [CGPoint] {
        (0...max(1, count)).map { i in
            let t = CGFloat(i) / CGFloat(max(1, count))
            let u = 1 - t
            return pt(u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                      u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
    }

    /// 折れ線の先頭から fraction(0...1)の長さだけの線
    private static func partialPath(_ points: [CGPoint], fraction: CGFloat) -> CGPath? {
        guard points.count >= 2, fraction > 0.001 else { return nil }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        var budget = total * min(1, fraction)
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            let segment = hypot(b.x - a.x, b.y - a.y)
            if segment <= budget {
                path.addLine(to: b)
                budget -= segment
            } else {
                let t = segment > 0 ? budget / segment : 0
                path.addLine(to: pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                break
            }
        }
        return path
    }

    /// 線の先の三角(from → tip の向き)
    private static func arrowHead(tip: CGPoint, from: CGPoint, size: CGFloat, color: UIColor, _ cg: CGContext) {
        let dx = tip.x - from.x
        let dy = tip.y - from.y
        let length = max(0.001, hypot(dx, dy))
        let ux = dx / length
        let uy = dy / length
        let head = CGMutablePath()
        head.addLines(between: [pt(tip.x + ux * size * 0.6, tip.y + uy * size * 0.6),
                                pt(tip.x - ux * size * 0.5 - uy * size * 0.7, tip.y - uy * size * 0.5 + ux * size * 0.7),
                                pt(tip.x - ux * size * 0.5 + uy * size * 0.7, tip.y - uy * size * 0.5 - ux * size * 0.7)])
        head.closeSubpath()
        fill(head, color, cg, outlineWidth: 5)
    }

    private static func starPath(_ center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = max(3, points) * 2
        for k in 0..<n {
            let angle = -CGFloat.pi / 2 + rotation + CGFloat(k) * CGFloat.pi / CGFloat(max(3, points))
            let r = k % 2 == 0 ? outer : inner
            let point = pt(center.x + r * cos(angle), center.y + r * sin(angle))
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// 4 本とげのキラッとした形
    private static func sparklePath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        let k = r * 0.18
        let path = CGMutablePath()
        path.move(to: pt(c.x, c.y - r))
        path.addQuadCurve(to: pt(c.x + r, c.y), control: pt(c.x + k, c.y - k))
        path.addQuadCurve(to: pt(c.x, c.y + r), control: pt(c.x + k, c.y + k))
        path.addQuadCurve(to: pt(c.x - r, c.y), control: pt(c.x - k, c.y + k))
        path.addQuadCurve(to: pt(c.x, c.y - r), control: pt(c.x - k, c.y - k))
        path.closeSubpath()
        return path
    }

    /// ハート(横幅 2s、中心 center)
    private static func heartPath(_ c: CGPoint, _ s: CGFloat) -> CGPath {
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { pt(c.x + x * s, c.y + y * s) }
        let path = CGMutablePath()
        path.move(to: q(0, 0.9))
        path.addCurve(to: q(-1, -0.2), control1: q(-0.5, 0.55), control2: q(-1, 0.25))
        path.addCurve(to: q(0, -0.45), control1: q(-1, -0.85), control2: q(-0.15, -0.95))
        path.addCurve(to: q(1, -0.2), control1: q(0.15, -0.95), control2: q(1, -0.85))
        path.addCurve(to: q(0, 0.9), control1: q(1, 0.25), control2: q(0.5, 0.55))
        path.closeSubpath()
        return path
    }

    /// しずく(上がとがった形)
    private static func dropPath(_ c: CGPoint, _ s: CGFloat) -> CGPath {
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { pt(c.x + x * s, c.y + y * s) }
        let path = CGMutablePath()
        path.move(to: q(0, -1))
        path.addQuadCurve(to: q(0.55, 0.35), control: q(0.5, -0.2))
        path.addArc(center: q(0, 0.35), radius: 0.55 * s, startAngle: 0, endAngle: .pi, clockwise: false)
        path.addQuadCurve(to: q(0, -1), control: q(-0.5, -0.2))
        path.closeSubpath()
        return path
    }

    /// ベル(中心 center、大きさ s)
    private static func bellPath(_ c: CGPoint, _ s: CGFloat) -> CGPath {
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { pt(c.x + x * s, c.y + y * s) }
        let path = CGMutablePath()
        path.move(to: q(-0.7, 0.55))
        path.addLine(to: q(-0.52, 0.35))
        path.addCurve(to: q(0, -0.75), control1: q(-0.52, -0.3), control2: q(-0.38, -0.75))
        path.addCurve(to: q(0.52, 0.35), control1: q(0.38, -0.75), control2: q(0.52, -0.3))
        path.addLine(to: q(0.7, 0.55))
        path.closeSubpath()
        return path
    }

    /// 角丸の吹き出し(しっぽは左下)
    private static func speechPath() -> CGPath {
        let x0: CGFloat = 8, y0: CGFloat = 8, x1: CGFloat = 152, y1: CGFloat = 70, r: CGFloat = 22
        let path = CGMutablePath()
        path.move(to: pt(x0 + r, y0))
        path.addArc(tangent1End: pt(x1, y0), tangent2End: pt(x1, y1), radius: r)
        path.addArc(tangent1End: pt(x1, y1), tangent2End: pt(x0, y1), radius: r)
        path.addLine(to: pt(66, y1))
        path.addLine(to: pt(34, 94))
        path.addLine(to: pt(46, y1))
        path.addArc(tangent1End: pt(x0, y1), tangent2End: pt(x0, y0), radius: r)
        path.addArc(tangent1End: pt(x0, y0), tangent2End: pt(x1, y0), radius: r)
        path.closeSubpath()
        return path
    }

    /// ギザギザの叫び吹き出し
    private static func spikyPath(center: CGPoint, rx: CGFloat, ry: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = 32
        for k in 0..<n {
            let angle = -CGFloat.pi / 2 + CGFloat(k) / CGFloat(n) * CGFloat.pi * 2
            let r: CGFloat = k % 2 == 0 ? 0.9 + 0.1 * CGFloat((k * 37) % 7) / 6 : 0.72
            let point = pt(center.x + rx * r * cos(angle), center.y + ry * r * sin(angle))
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// ボタン風(横長の丸い帯 + 左の白丸アイコン + 文字)
    private static func pill(text: String, color: UIColor, p: Double, _ cg: CGContext, icon: (CGPoint) -> Void) {
        let scale = 1 + 0.03 * CGFloat(sin(Double.pi * 2 * p))
        transformed(cg, around: pt(150, 50), scale: scale) {
            fill(roundedRect(10, 18, 280, 64, 32), color, cg)
            solidFill(circle(50, 50, 24), .white, cg)
            icon(pt(50, 50))
            drawText(text, in: CGRect(x: 84, y: 26, width: 192, height: 48), color: contrast(color), maxSize: 40)
        }
    }

    /// 明るい色には黒っぽい文字、暗い色には白い文字
    private static func contrast(_ c: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62 ? UIColor(white: 0.1, alpha: 1) : .white
    }

    private static func roundedFont(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .heavy)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    /// rect に収まる大きさで中央に文字を描く(outline で暗い縁取り)
    private static func drawText(_ text: String, in rect: CGRect, color: UIColor, maxSize: CGFloat, outline: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let string = trimmed as NSString
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let huge = CGSize(width: 100_000, height: 100_000)
        let base: CGFloat = 100
        let measured = string.boundingRect(with: huge, options: options, attributes: [.font: roundedFont(base)], context: nil)
        guard measured.width > 0, measured.height > 0 else { return }
        let size = max(4, min(maxSize, base * min(rect.width / measured.width, rect.height / measured.height)))
        let font = roundedFont(size)
        let box = string.boundingRect(with: huge, options: options, attributes: [.font: font], context: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let width = ceil(box.width) + 2
        let drawRect = CGRect(x: rect.midX - width / 2, y: rect.midY - box.height / 2, width: width, height: ceil(box.height) + 2)
        if outline {
            let strokeAttributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: outlineColor, .strokeColor: outlineColor,
                .strokeWidth: NSNumber(value: 16)
            ]
            string.draw(with: drawRect, options: options, attributes: strokeAttributes, context: nil)
        }
        let fillAttributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: color]
        string.draw(with: drawRect, options: options, attributes: fillAttributes, context: nil)
    }
}

/// 毎回同じ並びになる乱数(キラキラの位置など)
private struct StickerRandom {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed &* 747_796_405 &+ 2_891_336_453
    }

    /// 0 ..< 1
    mutating func next() -> CGFloat {
        state = state &* 1_664_525 &+ 1_013_904_223
        return CGFloat(state >> 8) / CGFloat(1 << 24)
    }
}
