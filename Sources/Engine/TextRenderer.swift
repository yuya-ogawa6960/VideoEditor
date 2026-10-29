import Foundation
import UIKit
import CoreImage

// =====================================================================
// TextRenderer: 自由配置テキスト(TextClip)とステッカーを CIImage に描く
//   - 文字画像は 内容 + スタイル + 幅 + キャンバスサイズ でキャッシュ(NSCache、スレッドセーフ)
//   - 配置(中心・拡大・回転・不透明度)、キーフレーム、イン/アウトのアニメーションは
//     毎フレーム CIImage の変換として掛ける(新しいビットマップは作らない)
//   - 縁取りは NSAttributedString の strokeWidth、影は NSShadow、背景は角丸矩形、
//     縦書きは 1 文字ずつ積む、曲線は弧に沿って 1 文字ずつ回して置く
// DrawingLayerRenderer: 手書き(Catmull-Rom で滑らかにした線)を描く。線が伸びていくアニメーション付き
// =====================================================================

// MARK: - テンプレート(スタイルのプリセット)

extension TextStyle {
    static func preset(_ t: TextTemplate) -> TextStyle {
        var s = TextStyle()
        switch t {
        case .plain:
            break
        case .headline:
            s.bold = true
            s.sizeRatio = 0.1
            s.colorHex = "#FFFFFF"
            s.strokeColorHex = "#000000"
            s.strokeWidth = 0.08
            s.letterSpacing = 0.04
            s.shadow.opacity = 0.5
        case .newsBar:
            s.bold = true
            s.sizeRatio = 0.05
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#C8102E"
            s.backgroundOpacity = 0.92
            s.backgroundPadding = 0.5
            s.backgroundCornerRadius = 0.05
            s.alignment = .left
            s.shadow.enabled = false
        case .caption:
            s.bold = false
            s.sizeRatio = 0.04
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#000000"
            s.backgroundOpacity = 0.55
            s.backgroundPadding = 0.45
            s.backgroundCornerRadius = 0.3
            s.lineSpacing = 1.2
            s.shadow.enabled = false
        case .quote:
            s.fontName = "HiraMinProN-W6"
            s.bold = false
            s.sizeRatio = 0.055
            s.colorHex = "#FFFFFF"
            s.letterSpacing = 0.12
            s.lineSpacing = 1.5
            s.shadow.opacity = 0.7
            s.shadow.radius = 0.01
        case .handwritten:
            s.fontName = "HiraMaruProN-W4"
            s.bold = false
            s.sizeRatio = 0.07
            s.colorHex = "#FFF2B2"
            s.shadow.enabled = true
            s.shadow.opacity = 0.5
        case .neon:
            s.bold = true
            s.sizeRatio = 0.08
            s.colorHex = "#9FF8FF"
            s.strokeColorHex = "#00E5FF"
            s.strokeWidth = 0.04
            s.shadow = TextShadow(enabled: true, colorHex: "#00E5FF", opacity: 0.95, radius: 0.02, offsetX: 0, offsetY: 0)
            s.letterSpacing = 0.08
        case .minimalSerif:
            s.fontName = "HiraMinProN-W3"
            s.bold = false
            s.sizeRatio = 0.05
            s.colorHex = "#F5F5F5"
            s.letterSpacing = 0.2
            s.lineSpacing = 1.4
            s.shadow.opacity = 0.4
        case .subtitleBox:
            s.bold = true
            s.sizeRatio = 0.045
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#000000"
            s.backgroundOpacity = 0.8
            s.backgroundPadding = 0.4
            s.backgroundCornerRadius = 0
            s.shadow.enabled = false
        case .bigImpact:
            s.bold = true
            s.sizeRatio = 0.14
            s.colorHex = "#FFE600"
            s.strokeColorHex = "#000000"
            s.strokeWidth = 0.12
            s.shadow.opacity = 0.6
            s.shadow.offsetY = 0.008
            s.letterSpacing = -0.02
        }
        return s
    }
}

// MARK: - テキストレイヤー

enum TextRenderer {

    /// NSCache 自体がスレッドセーフ
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 120
        return c
    }()

    // MARK: 公開 API

    /// 時刻 time のテキストレイヤーをキャンバスに配置した画像(キーフレーム・アニメーション込み、左下原点)。
    /// 表示中でなければ nil
    static func layer(for clip: TextClip, time: Double, canvasSize: CGSize) -> CIImage? {
        guard !clip.isMosaic, clip.duration > 0, clip.contains(timelineTime: time),
              canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let local = time - clip.start
        let duration = clip.duration
        let shortSide = Double(min(canvasSize.width, canvasSize.height))

        // 位置・大きさ・回転・不透明度(キーフレームがあればそちら)
        var center = clip.center
        var scale = clip.scale
        var rotation = clip.rotation
        var opacity = clip.opacity
        if !clip.keyframes.isEmpty {
            let fallback = KeyframeInterpolator.Value(center: clip.center, scale: clip.scale,
                                                      rotation: clip.rotation, opacity: clip.opacity)
            let v = KeyframeInterpolator.value(at: local, keyframes: clip.keyframes, fallback: fallback)
            center = v.center
            scale = v.scale
            rotation = v.rotation
            opacity = v.opacity
        }

        // イン / アウト アニメーション
        var alphaMul = 1.0
        var scaleMul = 1.0
        var offset = CGPoint.zero
        var blur = 0.0
        var visibleUnits: Int? = nil
        var unitIsWord = false

        let inDuration = min(max(clip.animInDuration, 0), duration / 2)
        let outDuration = min(max(clip.animOutDuration, 0), duration / 2)
        var phase: (type: TextAnimationType, u: Double)? = nil
        if clip.animIn != .none, inDuration > 0.01, local < inDuration {
            phase = (type: clip.animIn, u: local / inDuration)
        } else if clip.animOut != .none, outDuration > 0.01, duration - local < outDuration {
            phase = (type: clip.animOut, u: (duration - local) / outDuration)
        }
        if let phase {
            let u = GeometryMath.clamp(phase.u, 0, 1)
            let e = GeometryMath.easeOutCubic(u)
            switch phase.type {
            case .none:
                break
            case .fade:
                alphaMul = u
            case .typewriter:
                let count = clip.text.count
                visibleUnits = Int(ceil(u * Double(count)))
                unitIsWord = false
            case .pop:
                scaleMul = max(0.01, GeometryMath.easeOutBack(u))
                alphaMul = min(1, u * 4)
            case .slideUp:
                offset.y = CGFloat(-(1 - e) * shortSide * 0.12)
                alphaMul = u
            case .slideLeft:
                offset.x = CGFloat((1 - e) * shortSide * 0.12)
                alphaMul = u
            case .blurIn:
                blur = (1 - e) * shortSide * 0.02
                alphaMul = min(1, u * 1.5)
            case .scaleDown:
                scaleMul = 1 + (1 - e) * 0.6
                alphaMul = min(1, u * 1.5)
            case .wordByWord:
                let words = wordUnits(clip.text)
                if words.count <= 1 {
                    visibleUnits = Int(ceil(u * Double(clip.text.count)))
                    unitIsWord = false
                } else {
                    visibleUnits = Int(ceil(u * Double(words.count)))
                    unitIsWord = true
                }
            }
        }
        // 動くステッカーは文字単位の表示(タイプライターなど)を使わない
        if clip.vectorSticker != nil { visibleUnits = nil }
        if let v = visibleUnits {
            if v <= 0 { return nil }
            let total = unitIsWord ? wordUnits(clip.text).count : clip.text.count
            if v >= total { visibleUnits = nil }
        }

        let baseImage: CIImage?
        if clip.vectorSticker != nil {
            // 動くステッカー: クリップ内の時刻のコマ(VectorStickerRenderer.swift)
            baseImage = VectorStickerRenderer.image(for: clip, localTime: local, canvasSize: canvasSize)
        } else {
            baseImage = Self.image(for: clip, canvasSize: canvasSize, visibleUnits: visibleUnits, unitIsWord: unitIsWord)
        }
        guard var textImage = baseImage else {
            return nil
        }
        if blur > 0.3 {
            textImage = GeometryMath.blurred(textImage, sigma: blur)
        }
        let anchor = GeometryMath.point(topLeft: center, in: canvasSize)
        let placed = GeometryMath.transformed(textImage,
                                              scale: CGFloat(max(0.01, scale * scaleMul)),
                                              rotationDegrees: rotation,
                                              center: CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y))
        return GeometryMath.withAlpha(placed, opacity * alphaMul).cropped(to: canvas)
    }

    /// TextClip の文字画像(原点 (0,0)、配置・拡大・回転は未適用)。
    /// visibleUnits: タイプライター用に先頭から表示する文字数(unitIsWord なら単語数)。nil = 全部
    static func image(for clip: TextClip, canvasSize: CGSize, visibleUnits: Int? = nil, unitIsWord: Bool = false) -> CIImage? {
        var text = clip.text
        if let v = visibleUnits {
            if unitIsWord {
                text = wordUnits(text).prefix(max(0, v)).joined(separator: " ")
            } else {
                text = String(text.prefix(max(0, v)))
            }
        }
        if clip.isSticker {
            var style = TextStyle()
            style.bold = false
            style.sizeRatio = clip.style.sizeRatio
            style.strokeWidth = 0
            style.strokeColorHex = nil
            style.backgroundColorHex = nil
            style.shadow.enabled = false
            style.alignment = .center
            return Self.image(text: text, style: style, canvasSize: canvasSize, widthRatio: 1, isSticker: true)
        }
        return Self.image(text: text, style: clip.style, canvasSize: canvasSize, widthRatio: clip.widthRatio)
    }

    /// 任意の文字列を TextStyle で描く(原点 (0,0))。widthRatio は折り返し幅(キャンバス幅に対する比率)
    static func image(text: String, style: TextStyle, canvasSize: CGSize, widthRatio: Double, isSticker: Bool = false) -> CIImage? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty,
              canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let key = cacheKey(text: trimmed, style: style, canvasSize: canvasSize, widthRatio: widthRatio, isSticker: isSticker)
        if let cached = cache.object(forKey: key) { return cached }

        let shortSide = min(canvasSize.width, canvasSize.height)
        let ratio = CGFloat(GeometryMath.clamp(style.sizeRatio, 0.01, 0.6))
        let fontSize = max(6, (ratio * shortSide).rounded())
        let maxWidth = max(fontSize * 2, (CGFloat(GeometryMath.clamp(widthRatio, 0.1, 1)) * canvasSize.width).rounded())
        let spec = Spec(text: trimmed, style: style, fontSize: fontSize, maxWidth: maxWidth,
                        shortSide: shortSide, isSticker: isSticker)
        guard let rendered = render(spec) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    /// スタイルに合うフォント(登録済みのカスタムフォント名にも対応)
    static func font(for style: TextStyle, size: CGFloat) -> UIFont {
        var base: UIFont
        if let name = style.fontName, !name.isEmpty, let custom = UIFont(name: name, size: size) {
            base = custom
        } else {
            base = UIFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.bold && style.fontName != nil { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits)) {
            base = UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    /// 単語に分ける(空白・改行区切り)
    static func wordUnits(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map { String($0) }
    }

    // MARK: 内部

    private struct Spec {
        let text: String
        let style: TextStyle
        let fontSize: CGFloat
        let maxWidth: CGFloat
        let shortSide: CGFloat
        let isSticker: Bool
    }

    private static func cacheKey(text: String, style: TextStyle, canvasSize: CGSize, widthRatio: Double, isSticker: Bool) -> NSString {
        let s = style
        let shadow = s.shadow
        let parts: [String] = [
            text,
            s.fontName ?? "",
            "\(s.bold)\(s.italic)",
            "\(s.sizeRatio)", s.colorHex, s.strokeColorHex ?? "", "\(s.strokeWidth)",
            "\(shadow.enabled)\(shadow.colorHex)\(shadow.opacity)\(shadow.radius)\(shadow.offsetX)\(shadow.offsetY)",
            s.backgroundColorHex ?? "", "\(s.backgroundOpacity)\(s.backgroundPadding)\(s.backgroundCornerRadius)",
            s.alignment.rawValue, "\(s.letterSpacing)\(s.lineSpacing)\(s.vertical)\(s.curveRadius)",
            "\(widthRatio)", "\(isSticker)",
            "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        ]
        return parts.joined(separator: "\u{1F}") as NSString
    }

    private static func color(_ hex: String, fallback: UIColor) -> UIColor {
        UIColor(hex: hex) ?? fallback
    }

    private static func nsAlignment(_ a: TextAlignment2) -> NSTextAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    /// 描画に使う各種寸法と属性
    private struct Prepared {
        let font: UIFont
        let fillAttributes: [NSAttributedString.Key: Any]
        let strokeAttributes: [NSAttributedString.Key: Any]?
        let kern: CGFloat
        /// 影と縁取りがはみ出す分の余白
        let margin: CGFloat
        let backgroundColor: UIColor?
        let backgroundPadding: CGFloat
        let backgroundCorner: CGFloat
    }

    private static func prepare(_ spec: Spec) -> Prepared {
        let style = spec.style
        let fontSize = spec.fontSize
        let uiFont: UIFont = spec.isSticker ? UIFont.systemFont(ofSize: fontSize) : TextRenderer.font(for: style, size: fontSize)
        let textColor = color(style.colorHex, fallback: .white)
        let kern = CGFloat(GeometryMath.clamp(style.letterSpacing, -0.2, 2)) * fontSize

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment(style.alignment)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = CGFloat(GeometryMath.clamp(style.lineSpacing, 0.6, 3))

        var shadow: NSShadow? = nil
        var shadowExtent: CGFloat = 0
        if style.shadow.enabled && !spec.isSticker {
            let s = NSShadow()
            let opacity = CGFloat(GeometryMath.clamp(style.shadow.opacity, 0, 1))
            s.shadowColor = color(style.shadow.colorHex, fallback: .black).withAlphaComponent(opacity)
            let radius = CGFloat(GeometryMath.clamp(style.shadow.radius, 0, 0.1)) * spec.shortSide
            s.shadowBlurRadius = radius
            let ox = CGFloat(GeometryMath.clamp(style.shadow.offsetX, -0.1, 0.1)) * spec.shortSide
            let oy = CGFloat(GeometryMath.clamp(style.shadow.offsetY, -0.1, 0.1)) * spec.shortSide
            s.shadowOffset = CGSize(width: ox, height: oy)
            shadow = s
            shadowExtent = ceil(radius * 2 + max(abs(ox), abs(oy)))
        }

        let strokeRatio = CGFloat(GeometryMath.clamp(style.strokeWidth, 0, 0.3))
        let hasStroke = !spec.isSticker && strokeRatio > 0.001 && style.strokeColorHex != nil
        let strokeOutside = hasStroke ? ceil(strokeRatio * fontSize) : 0

        var fill: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        if kern != 0 { fill[.kern] = NSNumber(value: Double(kern)) }

        var stroke: [NSAttributedString.Key: Any]? = nil
        if hasStroke {
            let strokeColor = color(style.strokeColorHex ?? "#000000", fallback: .black)
            // 線は輪郭の中心に描かれるので、見える外側の太さを strokeRatio × fontSize にするため 2 倍
            let percent = Double(strokeRatio * 2 * 100)
            var s: [NSAttributedString.Key: Any] = [
                .font: uiFont,
                .foregroundColor: strokeColor,
                .strokeColor: strokeColor,
                .strokeWidth: NSNumber(value: percent),
                .paragraphStyle: paragraph
            ]
            if kern != 0 { s[.kern] = NSNumber(value: Double(kern)) }
            if let shadow { s[.shadow] = shadow }
            stroke = s
        } else if let shadow {
            fill[.shadow] = shadow
        }

        var backgroundColor: UIColor? = nil
        var backgroundPadding: CGFloat = 0
        var backgroundCorner: CGFloat = 0
        if !spec.isSticker, let hex = style.backgroundColorHex, let base = UIColor(hex: hex) {
            backgroundColor = base.withAlphaComponent(CGFloat(GeometryMath.clamp(style.backgroundOpacity, 0, 1)))
            backgroundPadding = (CGFloat(GeometryMath.clamp(style.backgroundPadding, 0, 2)) * fontSize).rounded()
            backgroundCorner = CGFloat(GeometryMath.clamp(style.backgroundCornerRadius, 0, 2)) * fontSize
        }

        return Prepared(font: uiFont,
                        fillAttributes: fill,
                        strokeAttributes: stroke,
                        kern: kern,
                        margin: strokeOutside + shadowExtent + 2,
                        backgroundColor: backgroundColor,
                        backgroundPadding: backgroundPadding,
                        backgroundCorner: backgroundCorner)
    }

    private static func render(_ spec: Spec) -> CIImage? {
        let prepared = prepare(spec)
        if spec.style.vertical && !spec.isSticker {
            return renderVertical(spec, prepared)
        }
        if spec.style.curveRadius > 0.001 && !spec.isSticker {
            return renderArc(spec, prepared)
        }
        return renderStraight(spec, prepared)
    }

    /// テキストブロック(幅 textSize)を背景・余白込みの画像にする共通処理
    private static func makeImage(textSize: CGSize,
                                  prepared: Prepared,
                                  draw: @escaping (CGContext, CGRect) -> Void) -> CIImage? {
        let margin = prepared.margin
        let pad = prepared.backgroundPadding
        let width = ceil(textSize.width + pad * 2 + margin * 2)
        let height = ceil(textSize.height + pad * 2 + margin * 2)
        guard width >= 1, height >= 1, width <= 8192, height <= 8192 else { return nil }
        let imageSize = CGSize(width: width, height: height)
        let textRect = CGRect(x: margin + pad, y: margin + pad, width: textSize.width, height: textSize.height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let uiImage = renderer.image { context in
            if let bg = prepared.backgroundColor {
                let box = CGRect(x: margin, y: margin, width: textSize.width + pad * 2, height: textSize.height + pad * 2)
                let path = UIBezierPath(roundedRect: box, cornerRadius: prepared.backgroundCorner)
                bg.setFill()
                path.fill()
            }
            draw(context.cgContext, textRect)
        }
        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    private static func measure(_ s: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    // 横書き(通常)
    private static func renderStraight(_ spec: Spec, _ prepared: Prepared) -> CIImage? {
        let fillString = NSAttributedString(string: spec.text, attributes: prepared.fillAttributes)
        let strokeString = prepared.strokeAttributes.map { NSAttributedString(string: spec.text, attributes: $0) }
        let measured = measure(fillString, maxWidth: spec.maxWidth)
        let textSize = CGSize(width: min(spec.maxWidth, measured.width), height: measured.height)
        guard textSize.width >= 1, textSize.height >= 1 else { return nil }
        return makeImage(textSize: textSize, prepared: prepared) { _, rect in
            let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            strokeString?.draw(with: rect, options: options, context: nil)
            fillString.draw(with: rect, options: options, context: nil)
        }
    }

    // 縦書き: 改行ごとに列、右から左へ。1 文字ずつ積む
    private static func renderVertical(_ spec: Spec, _ prepared: Prepared) -> CIImage? {
        let columns = spec.text.components(separatedBy: "\n").map { Array($0) }.filter { !$0.isEmpty }
        guard !columns.isEmpty else { return nil }
        let fontSize = spec.fontSize
        let pitchY = fontSize * CGFloat(GeometryMath.clamp(spec.style.lineSpacing, 0.8, 3)) + prepared.kern
        let pitchX = fontSize * 1.2
        let maxChars = columns.map { $0.count }.max() ?? 1
        let textSize = CGSize(width: ceil(pitchX * CGFloat(columns.count)), height: ceil(pitchY * CGFloat(maxChars)))
        guard textSize.width >= 1, textSize.height >= 1 else { return nil }

        // 段落スタイルの字間・配置は 1 文字描画では使わない
        var fill = prepared.fillAttributes
        fill[.kern] = nil
        fill[.paragraphStyle] = nil
        var stroke = prepared.strokeAttributes
        stroke?[.kern] = nil
        stroke?[.paragraphStyle] = nil

        return makeImage(textSize: textSize, prepared: prepared) { _, rect in
            for (columnIndex, column) in columns.enumerated() {
                let x = rect.minX + CGFloat(columns.count - 1 - columnIndex) * pitchX
                for (charIndex, ch) in column.enumerated() {
                    let s = String(ch)
                    let fillString = NSAttributedString(string: s, attributes: fill)
                    let size = fillString.size()
                    let cell = CGRect(x: x, y: rect.minY + CGFloat(charIndex) * pitchY, width: pitchX, height: pitchY)
                    let origin = CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2)
                    if let stroke {
                        NSAttributedString(string: s, attributes: stroke).draw(at: origin)
                    }
                    fillString.draw(at: origin)
                }
            }
        }
    }

    // 弧に沿った配置: 1 文字ずつ接線方向に回して置く
    private static func renderArc(_ spec: Spec, _ prepared: Prepared) -> CIImage? {
        let flat = spec.text.replacingOccurrences(of: "\n", with: " ")
        let chars = Array(flat)
        guard !chars.isEmpty else { return nil }
        let fontSize = spec.fontSize

        var fill = prepared.fillAttributes
        fill[.paragraphStyle] = nil
        fill[.kern] = nil
        var stroke = prepared.strokeAttributes
        stroke?[.paragraphStyle] = nil
        stroke?[.kern] = nil

        let strings = chars.map { NSAttributedString(string: String($0), attributes: fill) }
        let sizes = strings.map { $0.size() }
        let advances = sizes.map { $0.width + prepared.kern }
        let totalLength = advances.reduce(0, +)
        guard totalLength > 0 else { return nil }

        var radius = max(fontSize, CGFloat(GeometryMath.clamp(spec.style.curveRadius, 0.01, 3)) * spec.shortSide)
        var span = totalLength / radius
        let maxSpan = CGFloat(1.9 * Double.pi)
        if span > maxSpan {
            span = maxSpan
            radius = totalLength / span
        }
        let half = span / 2
        let widthSpan: CGFloat = half <= CGFloat(Double.pi / 2) ? 2 * radius * sin(half) : 2 * radius
        let heightSpan: CGFloat = half <= CGFloat(Double.pi) ? radius * (1 - cos(half)) : 2 * radius
        let textSize = CGSize(width: ceil(widthSpan + fontSize * 1.2), height: ceil(heightSpan + fontSize * 1.4))
        guard textSize.width >= 1, textSize.height >= 1 else { return nil }

        return makeImage(textSize: textSize, prepared: prepared) { context, rect in
            let center = CGPoint(x: rect.midX, y: rect.minY + fontSize * 0.7 + radius)
            var cursor: CGFloat = 0
            for i in 0..<chars.count {
                let mid = cursor + advances[i] / 2
                cursor += advances[i]
                let angle = -half + mid / radius
                let position = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
                let size = sizes[i]
                context.saveGState()
                context.translateBy(x: position.x, y: position.y)
                context.rotate(by: angle)
                let origin = CGPoint(x: -size.width / 2, y: -size.height / 2)
                if let stroke {
                    NSAttributedString(string: String(chars[i]), attributes: stroke).draw(at: origin)
                }
                strings[i].draw(at: origin)
                context.restoreGState()
            }
        }
    }
}

// MARK: - 手書き

enum DrawingLayerRenderer {

    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 48
        return c
    }()

    /// 最後にこの秒数だけフェードアウト
    static let fadeOutDuration: Double = 0.25
    /// 線が伸びるアニメーションの段階数(キャッシュ数を抑える)
    private static let revealSteps = 48

    /// 時刻 time の手書きレイヤー(キャンバス座標に配置済み、左下原点)。表示中でなければ nil
    static func layer(for drawing: DrawingClip, time: Double, canvasSize: CGSize) -> CIImage? {
        guard drawing.duration > 0, time >= drawing.start, time < drawing.end,
              !drawing.strokes.isEmpty, canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let local = time - drawing.start
        var progress = 1.0
        if drawing.revealDuration > 0.01 {
            progress = min(1, local / drawing.revealDuration)
        }
        let quantized: Double = progress >= 1 ? 1 : Double(Int(progress * Double(revealSteps))) / Double(revealSteps)
        guard quantized > 0 else { return nil }
        guard let image = cachedImage(drawing, progress: quantized, canvasSize: canvasSize) else { return nil }
        var alpha = 1.0
        let remaining = drawing.end - time
        if remaining < fadeOutDuration {
            alpha = max(0, remaining / fadeOutDuration)
        }
        return GeometryMath.withAlpha(image, alpha)
    }

    private static func cachedImage(_ drawing: DrawingClip, progress: Double, canvasSize: CGSize) -> CIImage? {
        var signature = "\(drawing.id.uuidString)|\(drawing.strokes.count)|"
        var pointTotal = 0
        for stroke in drawing.strokes {
            pointTotal += stroke.points.count
            signature += "\(stroke.colorHex)\(stroke.width);"
        }
        let key = "\(signature)|\(pointTotal)|\(progress)|\(Int(canvasSize.width))x\(Int(canvasSize.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = render(drawing, progress: progress, canvasSize: canvasSize) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private struct Polyline {
        let points: [CGPoint]
        let color: UIColor
        let width: CGFloat
        let length: CGFloat
    }

    private static func render(_ drawing: DrawingClip, progress: Double, canvasSize: CGSize) -> CIImage? {
        let w = canvasSize.width
        let h = canvasSize.height
        let shortSide = min(w, h)

        var polylines: [Polyline] = []
        var bounds: CGRect? = nil
        var maxWidth: CGFloat = 1
        for stroke in drawing.strokes {
            var pts = stroke.points.map { CGPoint(x: CGFloat($0.x) * w, y: CGFloat($0.y) * h) }
            guard !pts.isEmpty else { continue }
            if pts.count == 1 { pts.append(pts[0]) }
            let smooth = GeometryMath.catmullRom(points: pts, subdivisions: 6)
            let width = max(1, CGFloat(GeometryMath.clamp(stroke.width, 0.001, 0.2)) * shortSide)
            maxWidth = max(maxWidth, width)
            let color = UIColor(hex: stroke.colorHex) ?? UIColor.red
            polylines.append(Polyline(points: smooth, color: color, width: width,
                                      length: GeometryMath.polylineLength(smooth)))
            for p in smooth {
                let r = CGRect(x: p.x, y: p.y, width: 0, height: 0)
                bounds = bounds.map { $0.union(r) } ?? r
            }
        }
        guard !polylines.isEmpty, let rawBounds = bounds else { return nil }

        let inset = maxWidth / 2 + 2
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let box = rawBounds.insetBy(dx: -inset, dy: -inset).intersection(canvas).integral
        guard box.width >= 1, box.height >= 1 else { return nil }

        let totalLength = polylines.reduce(CGFloat(0)) { $0 + $1.length }
        var remaining = totalLength * CGFloat(GeometryMath.clamp(progress, 0, 1))
        let drawAll = progress >= 1

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: box.size, format: format)
        let uiImage = renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for line in polylines {
                if !drawAll && remaining <= 0 { break }
                let path = UIBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.lineWidth = line.width
                let pts = line.points
                guard let first = pts.first else { continue }
                path.move(to: first)
                var budget = drawAll ? CGFloat.greatestFiniteMagnitude : remaining
                var drawnLength: CGFloat = 0
                if pts.count == 1 || line.length < 0.5 {
                    // 点: 小さな丸
                    let dot = UIBezierPath(ovalIn: CGRect(x: first.x - line.width / 2, y: first.y - line.width / 2,
                                                          width: line.width, height: line.width))
                    line.color.setFill()
                    dot.fill()
                    continue
                }
                for i in 1..<pts.count {
                    let a = pts[i - 1]
                    let b = pts[i]
                    let segment = hypot(b.x - a.x, b.y - a.y)
                    if segment <= budget {
                        path.addLine(to: b)
                        budget -= segment
                        drawnLength += segment
                    } else {
                        let t = segment > 0 ? budget / segment : 0
                        path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                        drawnLength += budget
                        budget = 0
                        break
                    }
                }
                line.color.setStroke()
                path.stroke()
                if !drawAll { remaining -= drawnLength }
            }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        // 左上原点の box → CoreImage 座標(左下原点)
        let y = h - box.maxY
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: box.minX, y: y))
    }
}
