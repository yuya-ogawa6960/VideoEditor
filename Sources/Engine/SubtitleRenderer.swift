import Foundation
import UIKit
import CoreImage

// =====================================================================
// SubtitleRenderer: 字幕テキスト → 配置済み CIImage(キャッシュ付き・スレッドセーフ)
//
// テンプレート(SubtitleStyle.template):
//   plain         従来どおり(縁取り or 背景)
//   karaoke       現在時刻までの単語を highlightColor で
//   boxPop        現在の単語を色付きの角丸ボックスで(登場時に少し大きく)
//   outlineBig    太い縁取り・大きめ
//   pillHighlight 現在の単語の後ろに丸い帯
//   typewriter    文字が順に現れる(単語タイミングがあればそれに合わせ、無ければ cue の長さから)
// 単語タイミング(cue.words)が無いテンプレートは plain と同じ描画になる。
// 描画結果は「表示状態」(何単語目まで、など)ごとにキャッシュするので、毎フレームの再描画は起きない。
// =====================================================================

enum SubtitleRenderer {

    /// NSCache 自体がスレッドセーフ
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 160
        return c
    }()

    // MARK: - 公開 API

    /// Image already positioned inside a canvas of renderSize (CoreImage coords, origin bottom-left).
    /// 従来 API(単語タイミングなし = plain 相当)
    static func image(lines: [String], style: SubtitleStyle, renderSize: CGSize) -> CIImage? {
        image(lines: lines, words: [], originalText: "", time: 0, cueStart: 0, cueEnd: 0,
              style: style, renderSize: renderSize)
    }

    /// テンプレート対応版。words は cue.words(出力タイムライン秒)、originalText は cue.text、
    /// time は現在の出力時刻。配置済み(左下原点)の CIImage を返す
    static func image(lines: [String],
                      words: [SubtitleWord],
                      originalText: String,
                      time: Double,
                      cueStart: Double,
                      cueEnd: Double,
                      style: SubtitleStyle,
                      renderSize: CGSize) -> CIImage? {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, renderSize.width >= 2, renderSize.height >= 2 else { return nil }

        let state = displayState(lines: cleaned, words: words, originalText: originalText,
                                 time: time, cueStart: cueStart, cueEnd: cueEnd, style: style)
        let key = cacheKey(lines: cleaned, style: style, renderSize: renderSize, state: state)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let rendered = render(lines: cleaned, state: state, style: style, renderSize: renderSize) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    // MARK: - 表示状態(テンプレートごとの離散的な状態)

    private enum WordMode {
        case none
        /// highlighted 個目までの単語を強調色で
        case karaoke(highlighted: Int)
        /// current 番目の単語を箱で。pop は 2 → 1 → 0 と小さくなる
        case boxPop(current: Int, pop: Int)
        case pill(current: Int)
    }

    private struct DisplayState {
        /// 1 行目を単語単位で描くときの単語列(空なら通常描画)
        var words: [String] = []
        var hasSpaces: Bool = false
        var mode: WordMode = .none
        /// タイプライターで 1 行目に表示する文字数(nil = 全部)
        var visibleCharacters: Int? = nil

        var key: String {
            var s = ""
            switch mode {
            case .none: s = "n"
            case .karaoke(let h): s = "k\(h)"
            case .boxPop(let c, let p): s = "b\(c).\(p)"
            case .pill(let c): s = "p\(c)"
            }
            if let v = visibleCharacters { s += "|t\(v)" }
            if !words.isEmpty { s += "|w\(words.count)\(hasSpaces)" }
            return s
        }
    }

    private static func displayState(lines: [String],
                                     words: [SubtitleWord],
                                     originalText: String,
                                     time: Double,
                                     cueStart: Double,
                                     cueEnd: Double,
                                     style: SubtitleStyle) -> DisplayState {
        var state = DisplayState()
        let template = style.template
        guard template != .plain, template != .outlineBig else { return state }

        let first = lines[0]
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableWords = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let wordsMatchFirstLine = !usableWords.isEmpty && (original.isEmpty || first == original)

        switch template {
        case .plain, .outlineBig:
            return state

        case .typewriter:
            let total = first.count
            guard total > 0 else { return state }
            var visible = total
            if wordsMatchFirstLine {
                var count = 0
                for w in usableWords {
                    let chars = w.text.count
                    if time >= w.end {
                        count += chars
                    } else if time >= w.start {
                        let span = max(w.end - w.start, 0.001)
                        count += Int(ceil((time - w.start) / span * Double(chars)))
                    }
                }
                visible = min(total, max(0, count))
            } else if cueEnd > cueStart {
                let typing = min((cueEnd - cueStart) * 0.6, 0.06 * Double(total) + 0.2)
                let progress = typing > 0 ? min(1, max(0, (time - cueStart) / typing)) : 1
                visible = min(total, max(0, Int(ceil(progress * Double(total)))))
            }
            state.visibleCharacters = visible >= total ? nil : visible
            return state

        case .karaoke, .boxPop, .pillHighlight:
            guard wordsMatchFirstLine else { return state }
            state.words = usableWords.map { $0.text.trimmingCharacters(in: .whitespaces) }
            state.hasSpaces = first.contains(" ")
            var current = -1
            for (i, w) in usableWords.enumerated() where w.start <= time {
                current = i
            }
            switch template {
            case .karaoke:
                state.mode = .karaoke(highlighted: current + 1)
            case .boxPop:
                var pop = 0
                if current >= 0 {
                    let since = time - usableWords[current].start
                    if since < 0.07 { pop = 2 } else if since < 0.14 { pop = 1 }
                }
                state.mode = .boxPop(current: current, pop: pop)
            default:
                state.mode = .pill(current: current)
            }
            return state
        }
    }

    // MARK: - 内部

    private static func cacheKey(lines: [String], style: SubtitleStyle, renderSize: CGSize, state: DisplayState) -> NSString {
        let text = lines.joined(separator: "\u{1F}")
        let s = "\(text)|\(style.position.rawValue)|\(style.color.rawValue)|\(style.sizeRatio)|"
            + "\(style.hasBackground)|\(style.template.rawValue)|\(style.highlightColorHex)|\(style.fontName ?? "")|"
            + "\(state.key)|\(Int(renderSize.width))x\(Int(renderSize.height))"
        return s as NSString
    }

    private static func subtitleFont(for style: SubtitleStyle, size: CGFloat) -> UIFont {
        if let name = style.fontName, !name.isEmpty, let custom = UIFont(name: name, size: size) {
            return custom
        }
        return UIFont.systemFont(ofSize: size, weight: .bold)
    }

    private static func outlineAttributes(font: UIFont, color: UIColor, outlineWidth: CGFloat,
                                          paragraph: NSParagraphStyle?) -> [NSAttributedString.Key: Any] {
        // strokeWidth はフォントサイズに対する %。線は輪郭の中心に描かれるため外側は半分
        let percent = outlineWidth * 2 / max(font.pointSize, 1) * 100
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .strokeColor: color,
            .strokeWidth: NSNumber(value: Double(percent))
        ]
        if let paragraph { attrs[.paragraphStyle] = paragraph }
        return attrs
    }

    private struct WordBox {
        let text: String
        /// ブロック内の位置(左上原点)
        let rect: CGRect
    }

    /// 単語を左から並べて折り返し、各行を中央揃えにする
    private static func layoutWords(_ words: [String], font: UIFont, maxWidth: CGFloat, hasSpaces: Bool)
        -> (boxes: [WordBox], size: CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let spaceWidth: CGFloat = hasSpaces
            ? ceil((" " as NSString).size(withAttributes: attrs).width)
            : (font.pointSize * 0.1).rounded()
        let lineHeight = ceil(font.lineHeight * 1.3)
        var lines: [[(text: String, width: CGFloat)]] = [[]]
        var lineWidths: [CGFloat] = [0]
        for word in words {
            let width = ceil((word as NSString).size(withAttributes: attrs).width)
            let current = lineWidths[lineWidths.count - 1]
            let needed = current == 0 ? width : current + spaceWidth + width
            if needed > maxWidth && current > 0 {
                lines.append([(text: word, width: width)])
                lineWidths.append(width)
            } else {
                lines[lines.count - 1].append((text: word, width: width))
                lineWidths[lineWidths.count - 1] = needed
            }
        }
        let blockWidth = lineWidths.max() ?? 0
        var boxes: [WordBox] = []
        for (lineIndex, line) in lines.enumerated() {
            var x = ((blockWidth - lineWidths[lineIndex]) / 2).rounded()
            let y = CGFloat(lineIndex) * lineHeight
            for item in line {
                boxes.append(WordBox(text: item.text, rect: CGRect(x: x, y: y, width: item.width, height: lineHeight)))
                x += item.width + spaceWidth
            }
        }
        return (boxes, CGSize(width: ceil(blockWidth), height: lineHeight * CGFloat(lines.count)))
    }

    private static func render(lines: [String], state: DisplayState, style: SubtitleStyle, renderSize: CGSize) -> CIImage? {
        let canvasW = renderSize.width
        let canvasH = renderSize.height
        let template = style.template
        let ratio = min(max(style.sizeRatio, 0.01), 0.3)
        var fontSize = max(8, (ratio * canvasW).rounded())
        if template == .outlineBig { fontSize = (fontSize * 1.25).rounded() }
        let font = subtitleFont(for: style, size: fontSize)

        let paddingX = (fontSize * 0.5).rounded()
        let paddingY = (fontSize * 0.3).rounded()
        let maxBoxWidth = canvasW * 0.9
        let maxTextWidth = max(fontSize, maxBoxWidth - paddingX * 2)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = fontSize * 0.12

        let textColor = style.color.uiColor
        let isDarkText = style.color == .black
        let outlineColor: UIColor = isDarkText ? .white : .black
        let highlight = UIColor(hex: style.highlightColorHex) ?? UIColor(red: 1, green: 0.84, blue: 0.29, alpha: 1)

        // 縁取りの太さ(背景ありなら無し。outlineBig は常に太く)
        var outlineWidth: CGFloat = style.hasBackground ? 0 : max(2, (fontSize * 0.08).rounded())
        if template == .outlineBig { outlineWidth = max(3, (fontSize * 0.14).rounded()) }

        // 1 行目(タイプライターなら途中まで)と残りの行
        var displayLines = lines
        if let visible = state.visibleCharacters {
            if visible <= 0 { return nil }
            displayLines[0] = String(lines[0].prefix(visible))
        }
        let useWords = !state.words.isEmpty
        let restLines = useWords ? Array(displayLines.dropFirst()) : displayLines

        // --- 計測
        var wordBlock: (boxes: [WordBox], size: CGSize) = ([], .zero)
        if useWords {
            wordBlock = layoutWords(state.words, font: font, maxWidth: maxTextWidth, hasSpaces: state.hasSpaces)
        }
        let restText = restLines.joined(separator: "\n")
        let restFont: UIFont = useWords ? subtitleFont(for: style, size: (fontSize * 0.85).rounded()) : font
        let restAttributes: [NSAttributedString.Key: Any] = [
            .font: restFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let restString = NSAttributedString(string: restText, attributes: restAttributes)
        var restSize = CGSize.zero
        if !restText.isEmpty {
            let bounding = restString.boundingRect(
                with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil)
            restSize = CGSize(width: min(maxTextWidth, ceil(bounding.width)), height: ceil(bounding.height))
        }
        let gap: CGFloat = (useWords && !restText.isEmpty) ? (fontSize * 0.25).rounded() : 0
        let textWidth = min(maxTextWidth, max(wordBlock.size.width, restSize.width))
        let textHeight = wordBlock.size.height + gap + restSize.height
        guard textWidth > 0, textHeight > 0 else { return nil }

        // 箱・帯が単語からはみ出す分
        let boxPadX = (fontSize * 0.22).rounded()
        let boxPadY = (fontSize * 0.12).rounded()
        let extra: CGFloat = useWords ? max(outlineWidth, boxPadX + 2, boxPadY + 2) : outlineWidth

        let imageWidth = ceil(textWidth + paddingX * 2 + extra * 2)
        let imageHeight = ceil(textHeight + paddingY * 2 + extra * 2)
        let imageSize = CGSize(width: imageWidth, height: imageHeight)
        let textRect = CGRect(x: paddingX + extra, y: paddingY + extra, width: textWidth, height: textHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)

        let uiImage = renderer.image { context in
            let cg = context.cgContext
            if style.hasBackground {
                let bgColor: UIColor = isDarkText
                    ? UIColor(white: 1.0, alpha: 0.7)
                    : UIColor(white: 0.0, alpha: 0.55)
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize),
                                        cornerRadius: fontSize * 0.3)
                bgColor.setFill()
                path.fill()
            }

            // --- 単語ブロック(1 行目)
            if useWords {
                let blockOriginX = textRect.minX + ((textWidth - wordBlock.size.width) / 2).rounded()
                let blockOriginY = textRect.minY
                let glyphHeight = font.lineHeight
                for (index, box) in wordBlock.boxes.enumerated() {
                    let rect = box.rect.offsetBy(dx: blockOriginX, dy: blockOriginY)
                    let origin = CGPoint(x: rect.minX, y: rect.minY + ((rect.height - glyphHeight) / 2).rounded())
                    var fillColor = textColor
                    var drawOutline = outlineWidth > 0

                    switch state.mode {
                    case .none:
                        break
                    case .karaoke(let highlighted):
                        if index < highlighted { fillColor = highlight }
                    case .boxPop(let current, let pop):
                        if index == current {
                            let scale: CGFloat = pop == 2 ? 1.12 : (pop == 1 ? 1.05 : 1.0)
                            let glyphRect = CGRect(x: rect.minX, y: origin.y, width: rect.width, height: glyphHeight)
                            var boxRect = glyphRect.insetBy(dx: -boxPadX, dy: -boxPadY)
                            if scale != 1 {
                                let cx = boxRect.midX
                                let cy = boxRect.midY
                                boxRect = CGRect(x: cx - boxRect.width * scale / 2, y: cy - boxRect.height * scale / 2,
                                                 width: boxRect.width * scale, height: boxRect.height * scale)
                            }
                            let path = UIBezierPath(roundedRect: boxRect, cornerRadius: fontSize * 0.18)
                            highlight.setFill()
                            path.fill()
                            fillColor = UIColor(white: 0.08, alpha: 1)
                            drawOutline = false
                            if scale != 1 {
                                cg.saveGState()
                                cg.translateBy(x: glyphRect.midX, y: glyphRect.midY)
                                cg.scaleBy(x: scale, y: scale)
                                cg.translateBy(x: -glyphRect.midX, y: -glyphRect.midY)
                                NSAttributedString(string: box.text, attributes: [.font: font, .foregroundColor: fillColor])
                                    .draw(at: origin)
                                cg.restoreGState()
                                continue
                            }
                        }
                    case .pill(let current):
                        if index == current {
                            let glyphRect = CGRect(x: rect.minX, y: origin.y, width: rect.width, height: glyphHeight)
                            let pillRect = glyphRect.insetBy(dx: -boxPadX, dy: -boxPadY * 0.6)
                            let path = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
                            highlight.withAlphaComponent(0.95).setFill()
                            path.fill()
                            fillColor = .white
                            drawOutline = false
                        }
                    }

                    if drawOutline {
                        let strokeAttrs = outlineAttributes(font: font, color: outlineColor,
                                                            outlineWidth: outlineWidth, paragraph: nil)
                        NSAttributedString(string: box.text, attributes: strokeAttrs).draw(at: origin)
                    }
                    NSAttributedString(string: box.text, attributes: [.font: font, .foregroundColor: fillColor])
                        .draw(at: origin)
                }
            }

            // --- 残りの行(通常描画)
            if !restText.isEmpty {
                let restRect = CGRect(x: textRect.minX,
                                      y: textRect.minY + wordBlock.size.height + gap,
                                      width: textWidth,
                                      height: restSize.height)
                if outlineWidth > 0 {
                    let strokeAttrs = outlineAttributes(font: restFont, color: outlineColor,
                                                        outlineWidth: outlineWidth, paragraph: paragraph)
                    NSAttributedString(string: restText, attributes: strokeAttrs)
                        .draw(with: restRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                restString.draw(with: restRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }

        guard let cgImage = uiImage.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        // 配置(CoreImage 座標: 原点は左下)
        let margin = (canvasH * 0.07).rounded()
        let x = ((canvasW - imageWidth) / 2).rounded()
        let y: CGFloat
        switch style.position {
        case .top:
            y = canvasH - margin - imageHeight
        case .center:
            y = ((canvasH - imageHeight) / 2).rounded()
        case .bottom:
            y = margin
        }
        return ciImage.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
