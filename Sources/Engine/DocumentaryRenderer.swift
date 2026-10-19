import Foundation
import UIKit
import CoreImage

// =====================================================================
// DocumentaryRenderer: ドキュメンタリー風の仕上げ(VideoCompositor から毎フレーム呼ばれる)
// 順序: ルック LUT → 周辺減光 → フィルム粒子 → 章タイトル / テロップ → (字幕) → シネスコ黒帯 → 黒フェード
// =====================================================================

/// コンポジタ命令に渡すプレーンデータ(時刻は出力タイムライン上の秒)
struct DocumentaryRenderInfo {
    var style: DocumentaryStyle
    var titleCards: [TitleCard]
    var lowerThirds: [LowerThird]
    /// 作品全体の長さ(秒)
    var totalDuration: Double
    /// クリップのつなぎ目(先頭 0 と末尾は含まない)
    var clipBoundaries: [Double]

    static let empty = DocumentaryRenderInfo(style: DocumentaryStyle(), titleCards: [], lowerThirds: [],
                                             totalDuration: 0, clipBoundaries: [])
}

enum DocumentaryRenderer {

    static let titleCardFade: Double = 0.6
    static let lowerThirdFade: Double = 0.4
    static let edgeFade: Double = 1.5
    static let dipHalf: Double = 0.25
    static let letterboxRatio: CGFloat = 2.39

    // MARK: - 1. ルック

    /// キャンバスに配置済みの映像(余白は透明)にルックを適用する
    static func applyLook(_ image: CIImage, info: DocumentaryRenderInfo) -> CIImage {
        let style = info.style
        guard style.look != .none, style.lookIntensity > 0 else { return image }
        return FilterEngine.applyLook(style.look, intensity: style.lookIntensity, to: image)
    }

    // MARK: - 2. 周辺減光 + フィルム粒子

    static func applyTexture(_ frame: CIImage, time: Double, info: DocumentaryRenderInfo, canvasSize: CGSize) -> CIImage {
        let style = info.style
        let canvas = CGRect(origin: .zero, size: canvasSize)
        var out = frame

        let vignette = min(max(style.vignette, 0), 1)
        if vignette > 0.001 {
            let halfDiagonal = hypot(canvasSize.width, canvasSize.height) * 0.5
            let radius = Double(halfDiagonal) * (1.0 - 0.25 * vignette)
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: canvasSize.width / 2, y: canvasSize.height / 2),
                kCIInputRadiusKey: NSNumber(value: radius),
                kCIInputIntensityKey: NSNumber(value: 0.9 * vignette)
            ]).cropped(to: canvas)
        }

        let grain = min(max(style.filmGrain, 0), 1)
        if grain > 0.001 {
            out = applyGrain(out, strength: grain, time: time, canvasSize: canvasSize)
        }
        return out
    }

    /// 一度だけ作るモノクロのノイズ(無限範囲。CIRandomGenerator の 3ch 平均で粒が柔らかい)
    private static let grainBase: CIImage = {
        let random = CIFilter(name: "CIRandomGenerator")?.outputImage
            ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        let third = CGFloat(1.0 / 3.0)
        let mixVector = CIVector(x: third, y: third, z: third, w: 0)
        return random.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": mixVector,
            "inputGVector": mixVector,
            "inputBVector": mixVector,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }()

    private static func applyGrain(_ frame: CIImage, strength: Double, time: Double, canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        // 0.5 を中心に振幅を調整(soft light で 0.5 は無変化)
        let amp = CGFloat(strength * 0.6)
        let bias = 0.5 - 0.5 * amp
        // 24 コマ/秒で粒を入れ替える(フレームレートに依存しないフィルムらしい動き)
        let safeTime = time.isFinite ? max(time, 0) : 0
        let index = Int((safeTime * 24).rounded(.down))
        let ox = CGFloat((index * 7919 + 131) % 4093)
        let oy = CGFloat((index * 104_729 + 977) % 4091)
        // 解像度が上がっても粒の見た目サイズを揃える
        let scale = max(1, min(canvasSize.width, canvasSize.height) / 720)

        let noise = grainBase
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amp, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: amp, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amp, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: canvas)

        return noise.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: frame
        ]).cropped(to: canvas)
    }

    // MARK: - 3. 章タイトル / テロップ

    static func applyOverlays(_ frame: CIImage, time: Double, info: DocumentaryRenderInfo, canvasSize: CGSize) -> CIImage {
        if info.titleCards.isEmpty && info.lowerThirds.isEmpty { return frame }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let picture = pictureRect(canvasSize: canvasSize, style: info.style)
        let ref = min(canvasSize.width, canvasSize.height)
        var out = frame

        // 章タイトル
        for card in info.titleCards where card.duration > 0 && time >= card.start && time < card.end {
            let fade = min(titleCardFade, card.duration / 2)
            let alpha = fadeAlpha(sinceStart: time - card.start, untilEnd: card.end - time, fade: fade)
            if alpha <= 0.001 { continue }
            if card.opaqueBackground {
                let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(alpha))).cropped(to: canvas)
                out = black.composited(over: out)
            }
            if let block = titleCardImage(heading: card.heading, title: card.title, canvasSize: canvasSize) {
                let e = block.extent
                let x = ((canvasSize.width - e.width) / 2).rounded()
                let y = ((canvasSize.height - e.height) / 2).rounded()
                let placed = block.transformed(by: CGAffineTransform(translationX: x, y: y))
                out = withAlpha(placed, alpha).composited(over: out)
            }
        }

        // テロップ
        for item in info.lowerThirds where item.duration > 0 && time >= item.start && time < item.end {
            let fade = min(lowerThirdFade, item.duration / 2)
            let sinceStart = time - item.start
            let alpha = fadeAlpha(sinceStart: sinceStart, untilEnd: item.end - time, fade: fade)
            if alpha <= 0.001 { continue }
            let marginX = (canvasSize.width * 0.06).rounded()
            let marginY = (picture.height * 0.06).rounded()

            switch item.kind {
            case .nameplate:
                guard let block = nameplateImage(primary: item.primary, secondary: item.secondary,
                                                 canvasSize: canvasSize) else { continue }
                // 左からスライドイン(登場時のみ)
                let slideProgress = fade > 0 ? min(1, max(0, sinceStart / fade)) : 1
                let eased = 1 - pow(1 - slideProgress, 3)
                let slide = (1 - eased) * Double(ref) * 0.03
                let pad = block.padding
                let x = picture.minX + marginX - pad - CGFloat(slide)
                let y = picture.minY + marginY - pad
                let placed = block.image.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
                out = withAlpha(placed, alpha).composited(over: out)
            case .location:
                guard let block = locationImage(primary: item.primary, secondary: item.secondary,
                                                canvasSize: canvasSize) else { continue }
                let pad = block.padding
                let e = block.image.extent
                let x = picture.minX + marginX - pad
                let y = picture.maxY - marginY - (e.height - pad)
                let placed = block.image.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
                out = withAlpha(placed, alpha).composited(over: out)
            }
        }
        return out.cropped(to: canvas)
    }

    // MARK: - 4. 黒帯 + 黒フェード

    static func applyFinish(_ frame: CIImage, time: Double, info: DocumentaryRenderInfo, canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        var out = frame

        let bar = letterboxBarHeight(canvasSize: canvasSize, style: info.style)
        if bar > 0 {
            let black = CIImage(color: CIColor.black)
            let bottom = black.cropped(to: CGRect(x: 0, y: 0, width: canvasSize.width, height: bar))
            let top = black.cropped(to: CGRect(x: 0, y: canvasSize.height - bar, width: canvasSize.width, height: bar))
            out = top.composited(over: bottom.composited(over: out))
        }

        let k = fadeBrightness(at: time, info: info)
        if k < 0.999 {
            let cover = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(1 - k))).cropped(to: canvas)
            out = cover.composited(over: out)
        }
        return out.cropped(to: canvas)
    }

    /// 上下の黒帯の高さ(px)。letterbox オフ、またはすでに 2.39:1 より横長なら 0
    static func letterboxBarHeight(canvasSize: CGSize, style: DocumentaryStyle) -> CGFloat {
        guard style.letterbox, canvasSize.width > 0, canvasSize.height > 0 else { return 0 }
        if canvasSize.width / canvasSize.height >= letterboxRatio - 0.005 { return 0 }
        let pictureHeight = canvasSize.width / letterboxRatio
        return max(0, ((canvasSize.height - pictureHeight) / 2).rounded())
    }

    /// 黒帯を除いた映像部分
    static func pictureRect(canvasSize: CGSize, style: DocumentaryStyle) -> CGRect {
        let bar = letterboxBarHeight(canvasSize: canvasSize, style: style)
        return CGRect(x: 0, y: bar, width: canvasSize.width, height: max(1, canvasSize.height - bar * 2))
    }

    /// 黒フェードの明るさ係数 0(真っ黒)...1(そのまま)
    static func fadeBrightness(at time: Double, info: DocumentaryRenderInfo) -> Double {
        let style = info.style
        var k = 1.0
        let total = info.totalDuration
        if style.fadeFromToBlack && total > 0 {
            let f = min(edgeFade, total / 2)
            if f > 0 {
                k = min(k, time / f, (total - time) / f)
            }
        }
        if style.dipToBlackBetweenClips {
            for b in info.clipBoundaries {
                let d = abs(time - b)
                if d < dipHalf { k = min(k, d / dipHalf) }
            }
        }
        k = min(max(k, 0), 1)
        return k * k * (3 - 2 * k)
    }

    // MARK: - ヘルパー

    private static func fadeAlpha(sinceStart: Double, untilEnd: Double, fade: Double) -> Double {
        guard fade > 0 else { return 1 }
        let a = min(max(min(sinceStart / fade, untilEnd / fade), 0), 1)
        return a * a * (3 - 2 * a)
    }

    private static func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        if alpha >= 0.999 { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(alpha, 0)))
        ])
    }

    // MARK: - 文字画像(キャッシュ付き)

    /// 余白(影のはみ出し用)つきの文字画像
    struct TextBlock {
        let image: CIImage
        /// 画像の端から文字までの余白(px)
        let padding: CGFloat
    }

    private final class TextBlockBox {
        let block: TextBlock
        init(_ block: TextBlock) { self.block = block }
    }

    /// NSCache 自体がスレッドセーフ
    private static let textCache: NSCache<NSString, TextBlockBox> = {
        let c = NSCache<NSString, TextBlockBox>()
        c.countLimit = 60
        return c
    }()

    private static func cached(_ key: String, make: () -> TextBlock?) -> TextBlock? {
        let k = key as NSString
        if let box = textCache.object(forKey: k) { return box.block }
        guard let block = make() else { return nil }
        textCache.setObject(TextBlockBox(block), forKey: k)
        return block
    }

    private static func sizeKey(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    /// 明朝体(ヒラギノ明朝 → システムのセリフ体)
    static func serifFont(size: CGFloat) -> UIFont {
        if let font = UIFont(name: "HiraMinProN-W3", size: size) { return font }
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private static func sansFont(size: CGFloat, bold: Bool) -> UIFont {
        if let font = UIFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size) { return font }
        return UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private static func textShadow(fontSize: CGFloat, alpha: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(white: 0, alpha: alpha)
        shadow.shadowBlurRadius = max(2, fontSize * 0.15)
        shadow.shadowOffset = CGSize(width: 0, height: max(1, fontSize * 0.04))
        return shadow
    }

    /// 字間(最後の文字には付けない。中央揃えがずれないように)
    private static func spaced(_ text: String, attributes: [NSAttributedString.Key: Any], kern: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: attributes)
        let length = s.length
        if length > 1 && kern != 0 {
            s.addAttribute(.kern, value: NSNumber(value: Double(kern)), range: NSRange(location: 0, length: length - 1))
        }
        return s
    }

    private static func measure(_ s: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    private static func makeCIImage(size: CGSize, draw: @escaping () -> Void) -> CIImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { _ in draw() }
        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// 章タイトル: 小さな見出し(字間広め・薄いグレー)+ 大きな明朝体タイトル。原点 (0,0)
    private static func titleCardImage(heading: String, title: String, canvasSize: CGSize) -> CIImage? {
        let heading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(heading.isEmpty && title.isEmpty) else { return nil }
        let key = "title|\(heading)|\(title)|\(sizeKey(canvasSize))"
        let block = cached(key) { () -> TextBlock? in
            let ref = min(canvasSize.width, canvasSize.height)
            let headingSize = max(10, (ref * 0.03).rounded())
            let titleSize = max(16, (ref * 0.065).rounded())
            let maxWidth = canvasSize.width * 0.84

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = titleSize * 0.2

            let headingAttr: [NSAttributedString.Key: Any] = [
                .font: serifFont(size: headingSize),
                .foregroundColor: UIColor(white: 0.78, alpha: 1),
                .paragraphStyle: paragraph,
                .shadow: textShadow(fontSize: headingSize, alpha: 0.5)
            ]
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: serifFont(size: titleSize),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: textShadow(fontSize: titleSize, alpha: 0.5)
            ]
            let headingString = spaced(heading, attributes: headingAttr, kern: headingSize * 0.35)
            let titleString = spaced(title, attributes: titleAttr, kern: titleSize * 0.06)

            let headingBox = heading.isEmpty ? .zero : measure(headingString, maxWidth: maxWidth)
            let titleBox = title.isEmpty ? .zero : measure(titleString, maxWidth: maxWidth)
            let gap: CGFloat = (heading.isEmpty || title.isEmpty) ? 0 : (titleSize * 0.55).rounded()
            let pad = (titleSize * 0.4).rounded()
            let contentWidth = min(maxWidth, max(headingBox.width, titleBox.width))
            let imageSize = CGSize(width: ceil(contentWidth + pad * 2),
                                   height: ceil(headingBox.height + gap + titleBox.height + pad * 2))

            let image = makeCIImage(size: imageSize) {
                if !heading.isEmpty {
                    headingString.draw(with: CGRect(x: pad, y: pad, width: contentWidth, height: headingBox.height),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                if !title.isEmpty {
                    titleString.draw(with: CGRect(x: pad, y: pad + headingBox.height + gap,
                                                  width: contentWidth, height: titleBox.height),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
            }
            guard let image else { return nil }
            return TextBlock(image: image, padding: pad)
        }
        return block?.image
    }

    /// ネームプレート: 細いアクセント線 + 名前(太字白)+ 肩書き(薄いグレー)。原点 (0,0)
    private static func nameplateImage(primary: String, secondary: String, canvasSize: CGSize) -> TextBlock? {
        let name = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(name.isEmpty && role.isEmpty) else { return nil }
        let key = "name|\(name)|\(role)|\(sizeKey(canvasSize))"
        return cached(key) { () -> TextBlock? in
            let ref = min(canvasSize.width, canvasSize.height)
            let nameSize = max(12, (ref * 0.042).rounded())
            let roleSize = max(9, (ref * 0.028).rounded())
            let maxWidth = canvasSize.width * 0.6

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byWordWrapping

            let nameAttr: [NSAttributedString.Key: Any] = [
                .font: sansFont(size: nameSize, bold: true),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: textShadow(fontSize: nameSize, alpha: 0.55)
            ]
            let roleAttr: [NSAttributedString.Key: Any] = [
                .font: sansFont(size: roleSize, bold: false),
                .foregroundColor: UIColor(white: 0.82, alpha: 1),
                .paragraphStyle: paragraph,
                .shadow: textShadow(fontSize: roleSize, alpha: 0.55)
            ]
            let nameString = spaced(name, attributes: nameAttr, kern: nameSize * 0.04)
            let roleString = spaced(role, attributes: roleAttr, kern: roleSize * 0.08)
            let nameBox = name.isEmpty ? .zero : measure(nameString, maxWidth: maxWidth)
            let roleBox = role.isEmpty ? .zero : measure(roleString, maxWidth: maxWidth)
            let lineGap: CGFloat = (name.isEmpty || role.isEmpty) ? 0 : (roleSize * 0.35).rounded()

            let pad = (nameSize * 0.5).rounded()
            let accentWidth = max(2, (ref * 0.002).rounded())
            let accentGap = (nameSize * 0.5).rounded()
            let textWidth = max(nameBox.width, roleBox.width)
            let textHeight = nameBox.height + lineGap + roleBox.height
            let imageSize = CGSize(width: ceil(pad + accentWidth + accentGap + textWidth + pad),
                                   height: ceil(pad + textHeight + pad))

            let image = makeCIImage(size: imageSize) {
                // アクセント線(UIKit 座標: 左上原点)
                let shadowPath = UIBezierPath(rect: CGRect(x: pad + 1, y: pad + 1, width: accentWidth, height: textHeight))
                UIColor(white: 0, alpha: 0.35).setFill()
                shadowPath.fill()
                let linePath = UIBezierPath(rect: CGRect(x: pad, y: pad, width: accentWidth, height: textHeight))
                UIColor(white: 1, alpha: 0.92).setFill()
                linePath.fill()

                let textX = pad + accentWidth + accentGap
                if !name.isEmpty {
                    nameString.draw(with: CGRect(x: textX, y: pad, width: textWidth, height: nameBox.height),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                if !role.isEmpty {
                    roleString.draw(with: CGRect(x: textX, y: pad + nameBox.height + lineGap,
                                                 width: textWidth, height: roleBox.height),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
            }
            guard let image else { return nil }
            return TextBlock(image: image, padding: pad)
        }
    }

    /// 場所・日付: 1 行の字間広め小文字(英字は大文字化)「場所  |  日付」。原点 (0,0)
    private static func locationImage(primary: String, secondary: String, canvasSize: CGSize) -> TextBlock? {
        let place = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = place
        if !detail.isEmpty { text = text.isEmpty ? detail : text + "  |  " + detail }
        text = text.uppercased()
        guard !text.isEmpty else { return nil }
        let key = "loc|\(text)|\(sizeKey(canvasSize))"
        return cached(key) { () -> TextBlock? in
            let ref = min(canvasSize.width, canvasSize.height)
            let fontSize = max(9, (ref * 0.026).rounded())
            let maxWidth = canvasSize.width * 0.8

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail

            let attr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: UIColor(white: 0.92, alpha: 1),
                .paragraphStyle: paragraph,
                .shadow: textShadow(fontSize: fontSize, alpha: 0.6)
            ]
            let string = spaced(text, attributes: attr, kern: fontSize * 0.2)
            let box = measure(string, maxWidth: maxWidth)
            let pad = (fontSize * 0.6).rounded()
            let imageSize = CGSize(width: ceil(box.width + pad * 2), height: ceil(box.height + pad * 2))
            let image = makeCIImage(size: imageSize) {
                string.draw(with: CGRect(x: pad, y: pad, width: box.width, height: box.height),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            guard let image else { return nil }
            return TextBlock(image: image, padding: pad)
        }
    }
}
