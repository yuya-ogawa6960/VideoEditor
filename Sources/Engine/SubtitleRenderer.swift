import Foundation
import UIKit
import CoreImage

// =====================================================================
// SubtitleRenderer: 字幕テキスト → 配置済み CIImage(キャッシュ付き・スレッドセーフ)
// =====================================================================

enum SubtitleRenderer {

    /// NSCache 自体がスレッドセーフ
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 80
        return c
    }()

    /// Image already positioned inside a canvas of renderSize (CoreImage coords, origin bottom-left).
    static func image(lines: [String], style: SubtitleStyle, renderSize: CGSize) -> CIImage? {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, renderSize.width >= 2, renderSize.height >= 2 else { return nil }

        let key = cacheKey(lines: cleaned, style: style, renderSize: renderSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let rendered = render(lines: cleaned, style: style, renderSize: renderSize) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    // MARK: - 内部

    private static func cacheKey(lines: [String], style: SubtitleStyle, renderSize: CGSize) -> NSString {
        let text = lines.joined(separator: "\u{1F}")
        let s = "\(text)|\(style.position.rawValue)|\(style.color.rawValue)|\(style.sizeRatio)|"
            + "\(style.hasBackground)|\(Int(renderSize.width))x\(Int(renderSize.height))"
        return s as NSString
    }

    private static func render(lines: [String], style: SubtitleStyle, renderSize: CGSize) -> CIImage? {
        let canvasW = renderSize.width
        let canvasH = renderSize.height
        let ratio = min(max(style.sizeRatio, 0.01), 0.3)
        let fontSize = max(8, (ratio * canvasW).rounded())
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)

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

        let text = lines.joined(separator: "\n")
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let fillString = NSAttributedString(string: text, attributes: fillAttributes)

        let bounding = fillString.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textWidth = min(maxTextWidth, ceil(bounding.width))
        let textHeight = ceil(bounding.height)
        guard textWidth > 0, textHeight > 0 else { return nil }

        // アウトライン分の余白
        let outlineWidth = style.hasBackground ? 0 : max(2, (fontSize * 0.08).rounded())
        let imageWidth = ceil(textWidth + paddingX * 2 + outlineWidth * 2)
        let imageHeight = ceil(textHeight + paddingY * 2 + outlineWidth * 2)
        let imageSize = CGSize(width: imageWidth, height: imageHeight)
        let textRect = CGRect(x: paddingX + outlineWidth, y: paddingY + outlineWidth,
                              width: textWidth, height: textHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)

        let uiImage = renderer.image { _ in
            if style.hasBackground {
                let bgColor: UIColor = isDarkText
                    ? UIColor(white: 1.0, alpha: 0.7)
                    : UIColor(white: 0.0, alpha: 0.55)
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize),
                                        cornerRadius: fontSize * 0.3)
                bgColor.setFill()
                path.fill()
            } else {
                // 縁取り: ストロークのみ(正の strokeWidth)で描画してから塗りを重ねる
                // strokeWidth はフォントサイズに対する % 。線は輪郭の中心に描かれるため外側は半分。
                let strokePercent = outlineWidth * 2 / fontSize * 100
                let strokeAttributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: outlineColor,
                    .strokeColor: outlineColor,
                    .strokeWidth: NSNumber(value: Double(strokePercent)),
                    .paragraphStyle: paragraph
                ]
                let strokeString = NSAttributedString(string: text, attributes: strokeAttributes)
                strokeString.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            fillString.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
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
