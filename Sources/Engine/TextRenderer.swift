import Foundation
import UIKit
import CoreImage
import CoreText

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
        case .keyword:
            s.sizeRatio = 0.085
            s.letterSpacing = 0.16
            s.shadow.opacity = 0.7
            s.shadow.radius = 0.012
            s.accentColorHex = "#FF8A00"
        case .frostedCard:
            s.sizeRatio = 0.05
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#FFFFFF"
            s.backgroundOpacity = 0.24
            s.backgroundCornerRadius = 0.45
            s.backgroundPadding = 0.8
            s.shadow.enabled = false
            s.lineSpacing = 1.3
            s.accentColorHex = "#FF8A00"
        case .closingBand:
            s.sizeRatio = 0.065
            s.colorHex = "#111111"
            s.backgroundColorHex = "#FFFFFF"
            s.backgroundOpacity = 1
            s.backgroundCornerRadius = 0.05
            s.backgroundPadding = 0.5
            s.shadow.enabled = false
            s.letterSpacing = 0.04
            s.accentColorHex = "#FF8A00"
        case .slideHeading:
            s.sizeRatio = 0.075
            s.colorHex = "#23201A"
            s.letterSpacing = 0.05
            s.shadow.enabled = false
            s.accentColorHex = "#FF8A00"
        case .chapterLabel:
            s.sizeRatio = 0.034
            s.letterSpacing = 0.1
            s.lineSpacing = 1.3
            s.alignment = .left
            s.shadow.opacity = 0.65
            s.accentColorHex = "#FF8A00"
        case .edgeMinimal:
            s.bold = false
            s.sizeRatio = 0.034
            s.letterSpacing = 0.18
            s.shadow.opacity = 0.55
            s.accentColorHex = "#FF8A00"
        case .edgeBlackTag:
            s.sizeRatio = 0.036
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#000000"
            s.backgroundOpacity = 0.82
            s.backgroundCornerRadius = 0.08
            s.backgroundPadding = 0.45
            s.shadow.enabled = false
            s.accentColorHex = "#FF8A00"
        case .edgeWhiteTag:
            s.sizeRatio = 0.036
            s.colorHex = "#111111"
            s.backgroundColorHex = "#FFFFFF"
            s.backgroundOpacity = 0.95
            s.backgroundCornerRadius = 0.08
            s.backgroundPadding = 0.45
            s.shadow.enabled = false
            s.accentColorHex = "#E5482D"
        case .edgeOrange:
            s.sizeRatio = 0.038
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#FF7A00"
            s.backgroundOpacity = 0.96
            s.backgroundCornerRadius = 0.5
            s.backgroundPadding = 0.5
            s.shadow.enabled = false
            s.accentColorHex = "#FFE600"
        case .edgeMarker:
            s.sizeRatio = 0.04
            s.colorHex = "#111111"
            s.backgroundColorHex = "#FFE600"
            s.backgroundOpacity = 1
            s.backgroundCornerRadius = 0
            s.backgroundPadding = 0.3
            s.shadow.enabled = false
            s.accentColorHex = "#D8232A"
        case .edgeMincho:
            s.fontName = "HiraMinProN-W6"
            s.bold = false
            s.sizeRatio = 0.04
            s.letterSpacing = 0.14
            s.shadow.opacity = 0.6
            s.accentColorHex = "#FF8A00"
        case .edgeMagazine:
            s.fontName = "Georgia-Bold"
            s.bold = false
            s.sizeRatio = 0.06
            s.letterSpacing = 0.02
            s.shadow.opacity = 0.45
            s.accentColorHex = "#FF8A00"
        case .edgePop:
            s.fontName = "HiraMaruProN-W4"
            s.bold = false
            s.sizeRatio = 0.05
            s.strokeColorHex = "#FF4F8B"
            s.strokeWidth = 0.14
            s.shadow.enabled = false
            s.accentColorHex = "#FFE600"
        case .edgeNeonPink:
            s.sizeRatio = 0.044
            s.colorHex = "#FFD3EC"
            s.strokeColorHex = "#FF2FA8"
            s.strokeWidth = 0.03
            s.shadow = TextShadow(enabled: true, colorHex: "#FF2FA8", opacity: 0.95, radius: 0.018, offsetX: 0, offsetY: 0)
            s.letterSpacing = 0.08
            s.accentColorHex = "#7CF7FF"
        case .edgeRetro:
            s.sizeRatio = 0.038
            s.colorHex = "#5A3A22"
            s.backgroundColorHex = "#F3E3C3"
            s.backgroundOpacity = 0.96
            s.backgroundCornerRadius = 0.2
            s.backgroundPadding = 0.5
            s.shadow.enabled = false
            s.fontName = "HiraMinProN-W6"
            s.bold = false
            s.accentColorHex = "#C2452D"
        case .edgeCinema:
            s.fontName = "HiraMinProN-W3"
            s.bold = false
            s.sizeRatio = 0.03
            s.letterSpacing = 0.42
            s.shadow.opacity = 0.5
            s.accentColorHex = "#E8C675"
        case .edgeGlass:
            s.sizeRatio = 0.036
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#FFFFFF"
            s.backgroundOpacity = 0.22
            s.backgroundCornerRadius = 0.6
            s.backgroundPadding = 0.6
            s.shadow.enabled = false
            s.accentColorHex = "#FF8A00"
        case .edgeNewsBlue:
            s.sizeRatio = 0.038
            s.colorHex = "#FFFFFF"
            s.backgroundColorHex = "#0B3C8C"
            s.backgroundOpacity = 0.95
            s.backgroundCornerRadius = 0.03
            s.backgroundPadding = 0.45
            s.shadow.enabled = false
            s.accentColorHex = "#FFD400"
        case .edgePastel:
            s.sizeRatio = 0.038
            s.colorHex = "#6B4A5E"
            s.backgroundColorHex = "#FFD9E6"
            s.backgroundOpacity = 0.95
            s.backgroundCornerRadius = 0.7
            s.backgroundPadding = 0.55
            s.shadow.enabled = false
            s.fontName = "HiraMaruProN-W4"
            s.bold = false
            s.accentColorHex = "#E0559A"
        case .edgeTech:
            s.sizeRatio = 0.032
            s.colorHex = "#39FF88"
            s.backgroundColorHex = "#06140C"
            s.backgroundOpacity = 0.82
            s.backgroundCornerRadius = 0.05
            s.backgroundPadding = 0.45
            s.shadow.enabled = false
            s.fontName = "Menlo-Bold"
            s.bold = false
            s.letterSpacing = 0.05
            s.accentColorHex = "#FFFFFF"
        case .edgeLuxury:
            s.fontName = "HiraMinProN-W3"
            s.bold = false
            s.sizeRatio = 0.036
            s.colorHex = "#E8C675"
            s.letterSpacing = 0.24
            s.shadow.opacity = 0.6
            s.accentColorHex = "#FFFFFF"
        case .edgeSport:
            s.fontName = "AvenirNext-HeavyItalic"
            s.bold = false
            s.sizeRatio = 0.052
            s.strokeColorHex = "#D8232A"
            s.strokeWidth = 0.1
            s.shadow.enabled = false
            s.accentColorHex = "#FFE600"
        }
        return s
    }
}

// MARK: - 方眼紙の背景

enum GridPaperBackground {
    /// クリーム色の方眼紙の PNG を一時フォルダに作る(短辺 1080)
    static func makeFile(canvasSize: CGSize) -> URL? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let k = 1080 / min(canvasSize.width, canvasSize.height)
        let size = CGSize(width: (canvasSize.width * k).rounded(), height: (canvasSize.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor(red: 0.975, green: 0.955, blue: 0.895, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            let cell: CGFloat = 60
            func lines(every step: Int, width: CGFloat, color: UIColor) {
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(width)
                var x: CGFloat = 0
                while x <= size.width {
                    cg.move(to: CGPoint(x: x, y: 0))
                    cg.addLine(to: CGPoint(x: x, y: size.height))
                    x += cell * CGFloat(step)
                }
                var y: CGFloat = 0
                while y <= size.height {
                    cg.move(to: CGPoint(x: 0, y: y))
                    cg.addLine(to: CGPoint(x: size.width, y: y))
                    y += cell * CGFloat(step)
                }
                cg.strokePath()
            }
            lines(every: 1, width: 1.5, color: UIColor(red: 0.82, green: 0.80, blue: 0.72, alpha: 1))
            lines(every: 5, width: 3, color: UIColor(red: 0.72, green: 0.70, blue: 0.62, alpha: 1))
        }
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GridPaper-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - テキストレイヤー

enum TextRenderer {

    /// NSCache 自体がスレッドセーフ。拡大したテキストは大きな解像度で描くので、枚数に加えて合計の大きさでも上限を付ける
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 120
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()

    /// 文字のかたまりの大きさ(blockSize)のキャッシュ。画像より軽いので多めに持つ
    private static let sizeCache: NSCache<NSString, NSValue> = {
        let c = NSCache<NSString, NSValue>()
        c.countLimit = 500
        return c
    }()

    // MARK: 公開 API

    /// 時刻 time のテキストレイヤーをキャンバスに配置した画像(キーフレーム・アニメーション込み、左下原点)。
    /// 表示中でなければ nil
    static func layer(for clip: TextClip, time: Double, canvasSize: CGSize, documentary: DocumentaryStyle) -> CIImage? {
        guard !clip.isMosaic, clip.duration > 0, clip.contains(timelineTime: time),
              canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let local = time - clip.start
        let duration = clip.duration
        let shortSide = Double(min(canvasSize.width, canvasSize.height))

        // 位置・大きさ・回転・不透明度(キーフレームがあればそちら)
        var center = placedCenter(for: clip, canvasSize: canvasSize, documentary: documentary)
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
                visibleUnits = Int(ceil(u * Double(visibleText(of: clip).count)))
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
                    visibleUnits = Int(ceil(u * Double(visibleText(of: clip).count)))
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
            let total = unitIsWord ? wordUnits(clip.text).count : visibleText(of: clip).count
            if v >= total { visibleUnits = nil }
        }

        // ピンチや「大きさ」で拡大したテキスト・ステッカーは、その大きさに近い解像度で描いてから縮めて置く
        // (等倍で描いた画像を引き伸ばすと、書き出しで縁がぼやけるため)。倍率は 0.25 刻み・最大 4 倍
        // 4K などもともと大きいキャンバスでは、描く短辺が 4320px を超えない倍率までにする(メモリを使いすぎないように)
        var resolution = min(renderResolution(forScale: scale), max(1, CGFloat(4320 / max(shortSide, 1))))
        var stickerBase: CGSize? = nil
        if let kind = clip.vectorSticker {
            // 動くステッカーの絵は 4096px で頭打ちになるので、その手前までにする
            let base = VectorStickerRenderer.pixelSize(sizeRatio: clip.style.sizeRatio, kind: kind, canvasSize: canvasSize)
            resolution = min(resolution, max(1, 4096 / max(base.width, base.height, 1)))
            stickerBase = base
        }
        let renderCanvas = CGSize(width: canvasSize.width * resolution, height: canvasSize.height * resolution)

        let baseImage: CIImage?
        if clip.vectorSticker != nil {
            // 動くステッカー: クリップ内の時刻のコマ(VectorStickerRenderer.swift)
            baseImage = VectorStickerRenderer.image(for: clip, localTime: local, canvasSize: renderCanvas)
        } else {
            baseImage = Self.image(for: clip, canvasSize: renderCanvas, visibleUnits: visibleUnits, unitIsWord: unitIsWord)
        }
        guard var textImage = baseImage else {
            return nil
        }
        // 描いた画像が等倍の何倍か(動くステッカーは丸めの差も含めて実際の大きさで求める)
        var drawScale = resolution
        if let base = stickerBase, base.height >= 1, textImage.extent.height >= 1 {
            drawScale = textImage.extent.height / base.height
        }
        // 帯(背景の板)のあるテキストのタイプライター・単語ごとは、途中までの文字で描き直す(板も文字といっしょに伸びる)。
        // 書き始めの位置(上端と、行ぞろえの側。縦書きは右の列)を全文のときと揃える(端に置いていないテキストも)。
        // 帯のないテキストは全文の組版のまま、まだ出ていない文字を透明にして描くので、位置も改行もずれない(image(for:))
        if visibleUnits != nil, Self.typesWithGrowingPlate(clip),
           let full = Self.image(for: clip, canvasSize: renderCanvas) {
            let s = CGFloat(max(0.01, scale * scaleMul)) / drawScale
            let dx = (full.extent.width - textImage.extent.width) / 2 * s
            let dy = (full.extent.height - textImage.extent.height) / 2 * s
            var shift = CGPoint(x: 0, y: dy)
            if clip.style.vertical {
                // 縦書きは右の列から増える
                shift.x = dx
            } else if clip.style.alignment == .left {
                shift.x = -dx
            } else if clip.style.alignment == .right {
                shift.x = dx
            }
            // テキストを回しているときは、ずらす向きも同じだけ回す(GeometryMath.transformed と同じ向き)
            if abs(rotation) > 0.001 {
                shift = shift.applying(CGAffineTransform(rotationAngle: CGFloat(-rotation * Double.pi / 180)))
            }
            offset.x += shift.x
            offset.y += shift.y
        }
        if blur > 0.3 {
            textImage = GeometryMath.blurred(textImage, sigma: blur * Double(drawScale))
        }
        let anchor = GeometryMath.point(topLeft: center, in: canvasSize)
        let placed = GeometryMath.transformed(textImage,
                                              scale: CGFloat(max(0.01, scale * scaleMul)) / drawScale,
                                              rotationDegrees: rotation,
                                              center: CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y))
        return GeometryMath.withAlpha(placed, opacity * alphaMul).cropped(to: canvas)
    }

    /// 拡大して置くテキスト・ステッカーを描く解像度の倍率(1 ... 4、0.25 刻み。等倍以下は 1)
    static func renderResolution(forScale scale: Double) -> CGFloat {
        guard scale.isFinite, scale > 1.001 else { return 1 }
        return CGFloat(min(4, (scale * 4).rounded(.up) / 4))
    }

    /// タイプライター・単語ごとで、途中までの文字だけで描き直すテキストか(帯=背景の板があり、曲げていないもの)。
    /// それ以外は全文の組版のまま、まだ出ていない文字を透明にして描く(文字の位置も改行も全文のときのまま)
    static func typesWithGrowingPlate(_ clip: TextClip) -> Bool {
        !clip.isSticker && clip.style.backgroundColorHex != nil && clip.style.backgroundOpacity > 0.001
            && clip.style.curveRadius <= 0.001
    }

    /// 先頭から count 個目の単語の終わりまでの文字数(空白・改行の区切りは数えたまま残す。単語ごとのアニメーション用)
    static func characterCount(throughWords count: Int, in text: String) -> Int {
        guard count > 0 else { return 0 }
        var words = 0
        var inWord = false
        var offset = 0
        for ch in text {
            if ch.isWhitespace || ch.isNewline {
                if inWord {
                    inWord = false
                    if words >= count { return offset }
                }
            } else if !inWord {
                inWord = true
                words += 1
            }
            offset += 1
        }
        return offset
    }

    /// TextClip の文字画像(原点 (0,0)、配置・拡大・回転は未適用)。
    /// visibleUnits: タイプライター用に先頭から表示する文字数(unitIsWord なら単語数)。nil = 全部
    static func image(for clip: TextClip, canvasSize: CGSize, visibleUnits: Int? = nil, unitIsWord: Bool = false) -> CIImage? {
        var text = clip.text
        /// 帯のないテキスト: 全文の組版のまま、先頭からこの文字数だけを描く(残りは透明)
        var visibleCharacters: Int? = nil
        if let v = visibleUnits {
            let shown = max(0, v)
            if typesWithGrowingPlate(clip) {
                // 帯のあるテキスト: 途中までの文字で描き直す。単語ごとも改行・空白は元のまま残す
                if unitIsWord {
                    text = String(text.prefix(characterCount(throughWords: shown, in: text)))
                } else if clip.style.accentColorHex != nil, !clip.isSticker {
                    text = visiblePrefix(of: text, units: shown)
                } else {
                    text = String(text.prefix(shown))
                }
            } else {
                visibleCharacters = unitIsWord ? characterCount(throughWords: shown, in: visibleText(of: clip)) : shown
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
            return Self.image(text: text, style: style, canvasSize: canvasSize, widthRatio: 1, isSticker: true,
                              visibleCharacters: visibleCharacters)
        }
        return Self.image(text: text, style: clip.style, canvasSize: canvasSize, widthRatio: clip.widthRatio,
                          visibleCharacters: visibleCharacters)
    }

    /// 任意の文字列を TextStyle で描く(原点 (0,0))。widthRatio は折り返し幅(キャンバス幅に対する比率)。
    /// visibleCharacters: 先頭から描く文字数(【】の印を除いた文字で数える。残りは透明にして、組版は全文のまま)。nil = 全部
    static func image(text: String, style: TextStyle, canvasSize: CGSize, widthRatio: Double, isSticker: Bool = false,
                      visibleCharacters: Int? = nil) -> CIImage? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty,
              canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        // 先頭の改行は描かないので、描く文字数からも除く
        let leadingNewlines = text.prefix(while: { $0.isNewline }).count
        let shown: Int? = visibleCharacters.map { max(0, $0 - leadingNewlines) }
        if let shown, shown <= 0 { return nil }
        let key = cacheKey(text: trimmed, style: style, canvasSize: canvasSize, widthRatio: widthRatio, isSticker: isSticker,
                           visibleCharacters: shown)
        if let cached = cache.object(forKey: key) { return cached }

        var spec = makeSpec(text: trimmed, style: style, canvasSize: canvasSize, widthRatio: widthRatio, isSticker: isSticker)
        spec.visibleCount = shown
        guard let rendered = render(spec) else { return nil }
        let extent = rendered.extent
        let cost = (extent.width.isFinite && extent.height.isFinite) ? Int(extent.width * extent.height * 4) : 0
        cache.setObject(rendered, forKey: key, cost: cost)
        return rendered
    }

    /// テキストの中心(左上原点の 0...1)。端に置いたテキストは、文字の大きさ・キャンバス・黒帯からその都度求める
    /// (比率を変えた書き出しや、あとから黒帯を付けたときも端に揃う)。文字が空なら clip.center のまま
    static func placedCenter(for clip: TextClip, canvasSize: CGSize, documentary: DocumentaryStyle) -> NormalizedPoint {
        guard let anchor = clip.edgeAnchor, clip.keyframes.isEmpty,
              let block = blockSize(for: clip, canvasSize: canvasSize) else { return clip.center }
        let scale = CGFloat(max(0.01, clip.scale))
        let letterbox = DocumentaryRenderer.letterboxBarHeight(canvasSize: canvasSize, style: documentary)
        return anchor.center(for: CGSize(width: block.width * scale, height: block.height * scale),
                             canvas: canvasSize, letterbox: letterbox)
    }

    /// 文字のかたまりの大きさ(縁取り・背景の板まで。影の透明な余白は含めない)。
    /// 端に揃えるための値で、スライダーの 1 刻みごとに呼ばれるので画像は作らない。文字が空なら nil
    static func blockSize(for clip: TextClip, canvasSize: CGSize) -> CGSize? {
        guard !clip.isMosaic, !clip.isSticker else { return nil }
        let trimmed = clip.text.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty,
              canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let key = cacheKey(text: trimmed, style: clip.style, canvasSize: canvasSize, widthRatio: clip.widthRatio, isSticker: false)
        if let cached = sizeCache.object(forKey: key) { return cached.cgSizeValue }
        let base = makeSpec(text: trimmed, style: clip.style, canvasSize: canvasSize, widthRatio: clip.widthRatio, isSticker: false)
        guard let spec = resolvingAccent(base) else { return nil }
        let prepared = prepare(spec)
        guard let textSize = textBlockSize(spec, prepared) else { return nil }
        let outer = (prepared.backgroundPadding + prepared.strokeOutside) * 2
        let size = CGSize(width: textSize.width + outer, height: textSize.height + outer)
        sizeCache.setObject(NSValue(cgSize: size), forKey: key)
        return size
    }

    /// 画面に出る文字(【】の印を除く)
    static func visibleText(of clip: TextClip) -> String {
        guard clip.style.accentColorHex != nil, !clip.isSticker else { return clip.text }
        return parseAccent(clip.text).plain
    }

    /// スタイルに合うフォント(登録済みのカスタムフォント名にも対応)
    static func font(for style: TextStyle, size: CGFloat) -> UIFont {
        var base: UIFont
        if let name = style.fontName, !name.isEmpty, let custom = UIFont(name: name, size: size) {
            base = custom
        } else {
            base = UIFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        }
        // 太字と斜体は別々に当てる(「太字+斜体」の書体がない書体で、太字の指定まで外れないように)
        if style.bold && style.fontName != nil,
           let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitBold)) {
            base = UIFont(descriptor: descriptor, size: size)
        }
        if style.italic, !base.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            var italicFont: UIFont? = nil
            if let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                let candidate = UIFont(descriptor: descriptor, size: size)
                // 同じ書体の斜体が本当にあるときだけ使う(別の書体に置き換わらないように)
                if candidate.fontDescriptor.symbolicTraits.contains(.traitItalic), candidate.familyName == base.familyName {
                    italicFont = candidate
                }
            }
            // 斜体の書体がない(ヒラギノ・同梱フォントなど)ときは、文字を斜めに変形して傾ける
            base = italicFont ?? UIFont(descriptor: base.fontDescriptor.withMatrix(obliqueMatrix), size: size)
        }
        // 日本語の字形を持たない欧文書体には、雰囲気の近い日本語書体を足す(斜体なら日本語も傾ける)
        if let cascade = japaneseCascade(for: style, size: size) {
            base = UIFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [cascade]]), size: size)
        }
        return base
    }

    /// 斜体の書体がない文字を傾ける量(AvenirNext-HeavyItalic の日本語と同じ)
    private static let obliqueMatrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)

    private static func japaneseCascade(for style: TextStyle, size: CGFloat) -> UIFontDescriptor? {
        switch style.fontName ?? "" {
        case "Georgia-Bold":
            let mincho = UIFontDescriptor(name: "HiraMinProN-W6", size: size)
            return style.italic ? mincho.withMatrix(obliqueMatrix) : mincho
        case "AvenirNext-HeavyItalic":
            // 斜体の書体に合わせて、日本語も少し傾ける
            return UIFontDescriptor(name: "HiraginoSans-W6", size: size).withMatrix(obliqueMatrix)
        default:
            // 日本語は代わりの書体で描かれ、その書体には斜体がない。斜体のときは傾けた日本語の書体を明示する
            // (システムフォントのときも。日本語の字形を持つ書体では使われない)
            guard style.italic else { return nil }
            return UIFontDescriptor(name: style.bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size)
                .withMatrix(obliqueMatrix)
        }
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
        /// 強調する文字の位置(text の文字番号)
        var accentIndices: Set<Int> = []
        /// 先頭から描く文字数(タイプライターの途中。残りは透明にして組版は全文のまま)。nil = 全部
        var visibleCount: Int? = nil
    }

    /// 【】を取り除いた文字列と、囲まれていた文字の位置(タイプライターの途中で閉じていなくても動く)
    private static func parseAccent(_ text: String) -> (plain: String, indices: Set<Int>) {
        var plain = ""
        var indices = Set<Int>()
        var inside = false
        var count = 0
        for ch in text {
            if ch == "【" { inside = true; continue }
            if ch == "】" { inside = false; continue }
            if inside && !ch.isNewline { indices.insert(count) }
            plain.append(ch)
            count += 1
        }
        return (plain, indices)
    }

    /// 【】を数えずに、先頭から units 文字ぶんを切り出す(タイプライターの拍が【】で止まらないように)
    private static func visiblePrefix(of text: String, units: Int) -> String {
        var result = ""
        var shown = 0
        for ch in text {
            if ch == "【" || ch == "】" {
                result.append(ch)
                continue
            }
            if shown == units { break }
            result.append(ch)
            shown += 1
        }
        return result
    }

    private static func makeSpec(text: String, style: TextStyle, canvasSize: CGSize, widthRatio: Double, isSticker: Bool) -> Spec {
        let shortSide = min(canvasSize.width, canvasSize.height)
        let ratio = CGFloat(GeometryMath.clamp(style.sizeRatio, 0.01, 0.6))
        // 整数に丸めない(プレビューと書き出しで文字の大きさの比が変わると、改行位置と端の余白がずれる)
        let fontSize = max(6, ratio * shortSide)
        let maxWidth = max(fontSize * 2, (CGFloat(GeometryMath.clamp(widthRatio, 0.1, 1)) * canvasSize.width).rounded())
        return Spec(text: text, style: style, fontSize: fontSize, maxWidth: maxWidth,
                    shortSide: shortSide, isSticker: isSticker)
    }

    /// 強調があるなら【】を取り除いた文字列に置き換える。何も残らなければ nil
    private static func resolvingAccent(_ spec: Spec) -> Spec? {
        guard !spec.isSticker, spec.style.accentColorHex != nil else { return spec }
        let parsed = parseAccent(spec.text)
        guard !parsed.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Spec(text: parsed.plain, style: spec.style, fontSize: spec.fontSize, maxWidth: spec.maxWidth,
                    shortSide: spec.shortSide, isSticker: spec.isSticker, accentIndices: parsed.indices,
                    visibleCount: spec.visibleCount)
    }

    /// まだ出ていない文字の範囲(タイプライターの途中。全部出ているなら nil)
    private static func hiddenRange(_ spec: Spec) -> NSRange? {
        guard let shown = spec.visibleCount, shown < spec.text.count else { return nil }
        let start = spec.text.index(spec.text.startIndex, offsetBy: max(0, shown))
        return NSRange(start..<spec.text.endIndex, in: spec.text)
    }

    private static func cacheKey(text: String, style: TextStyle, canvasSize: CGSize, widthRatio: Double, isSticker: Bool,
                                 visibleCharacters: Int? = nil) -> NSString {
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
            "\(widthRatio)", "\(isSticker)", s.accentColorHex ?? "",
            "\(Int(canvasSize.width))x\(Int(canvasSize.height))",
            visibleCharacters.map { "v\($0)" } ?? ""
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
        /// 見える縁取りの外側の太さ(margin のうち、端に揃えるときに数える分)
        let strokeOutside: CGFloat
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

        // 斜体(傾けた文字)は行末の字の上側が右へはみ出すので、そのぶん余白を足す(画像の端で切れないように)
        let italicExtent: CGFloat = (style.italic && !spec.isSticker) ? ceil(fontSize * 0.25) : 0

        return Prepared(font: uiFont,
                        fillAttributes: fill,
                        strokeAttributes: stroke,
                        kern: kern,
                        margin: strokeOutside + shadowExtent + italicExtent + 2,
                        strokeOutside: strokeOutside,
                        backgroundColor: backgroundColor,
                        backgroundPadding: backgroundPadding,
                        backgroundCorner: backgroundCorner)
    }

    private static func render(_ original: Spec) -> CIImage? {
        guard let spec = resolvingAccent(original) else { return nil }
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
        guard width >= 1, height >= 1 else { return nil }
        // とても長い縦書きなどは上限の大きさで描き、本来の大きさに拡大して返す(書き出しだけ消えないように)
        let shrink = min(1, 8192 / max(width, height))
        let imageSize = CGSize(width: ceil(width * shrink), height: ceil(height * shrink))
        let textRect = CGRect(x: margin + pad, y: margin + pad, width: textSize.width, height: textSize.height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let uiImage = renderer.image { context in
            if shrink < 1 { context.cgContext.scaleBy(x: shrink, y: shrink) }
            if let bg = prepared.backgroundColor {
                let box = CGRect(x: margin, y: margin, width: textSize.width + pad * 2, height: textSize.height + pad * 2)
                let path = UIBezierPath(roundedRect: box, cornerRadius: prepared.backgroundCorner)
                bg.setFill()
                path.fill()
            }
            draw(context.cgContext, textRect)
        }
        guard let cg = uiImage.cgImage else { return nil }
        let image = CIImage(cgImage: cg)
        return shrink < 1 ? image.transformed(by: CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink)) : image
    }

    private static func measure(_ s: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// 描かずに、文字のかたまり(背景と余白を除く)の大きさだけを求める
    private static func textBlockSize(_ spec: Spec, _ prepared: Prepared) -> CGSize? {
        if spec.style.vertical && !spec.isSticker {
            let columns = verticalColumns(spec)
            guard !columns.isEmpty else { return nil }
            return verticalMetrics(columns, spec, prepared).textSize
        }
        if spec.style.curveRadius > 0.001 && !spec.isSticker {
            return arcLayout(spec, prepared)?.textSize
        }
        return straightLayout(spec, prepared)?.textSize
    }

    // 横書き(通常)
    private struct StraightLayout {
        let fillString: NSAttributedString
        let textSize: CGSize
        /// 行末の文字の後ろの字間(見た目の幅には数えない。右寄せ・中央揃えがずれるので)
        let trailingKern: CGFloat
        /// 1 行目の上に足される行間(見た目の高さには数えない。文字が板の下に寄るので)
        let topExtra: CGFloat
    }

    private static func straightLayout(_ spec: Spec, _ prepared: Prepared) -> StraightLayout? {
        let fillString = NSMutableAttributedString(string: spec.text, attributes: prepared.fillAttributes)
        if !spec.accentIndices.isEmpty, let accent = spec.style.accentColorHex.flatMap({ UIColor(hex: $0) }) {
            for (offset, index) in spec.text.indices.enumerated() where spec.accentIndices.contains(offset) {
                let range = NSRange(index..<spec.text.index(after: index), in: spec.text)
                fillString.addAttribute(.foregroundColor, value: accent, range: range)
            }
        }
        // タイプライターの途中: まだ出ていない文字を透明にする(大きさ・改行の位置は全文のまま)
        if let hidden = hiddenRange(spec) {
            fillString.addAttribute(.foregroundColor, value: UIColor.clear, range: hidden)
            fillString.removeAttribute(.shadow, range: hidden)
        }
        let measured = measure(fillString, maxWidth: spec.maxWidth)
        guard measured.width >= 1, measured.height >= 1 else { return nil }
        let trailingKern = spec.isSticker ? 0 : max(0, prepared.kern)
        let multiple = CGFloat(GeometryMath.clamp(spec.style.lineSpacing, 0.6, 3))
        let topExtra = (!spec.isSticker && multiple > 1) ? (multiple - 1) * prepared.font.lineHeight : 0
        let textSize = CGSize(width: max(1, min(spec.maxWidth, measured.width) - trailingKern),
                              height: max(1, measured.height - topExtra))
        return StraightLayout(fillString: fillString, textSize: textSize, trailingKern: trailingKern, topExtra: topExtra)
    }

    private static func renderStraight(_ spec: Spec, _ prepared: Prepared) -> CIImage? {
        guard let layout = straightLayout(spec, prepared) else { return nil }
        let hidden = hiddenRange(spec)
        let strokeString: NSAttributedString? = prepared.strokeAttributes.map { attributes -> NSAttributedString in
            let s = NSMutableAttributedString(string: spec.text, attributes: attributes)
            if let hidden {
                // まだ出ていない文字は縁取りも描かない
                s.addAttribute(.foregroundColor, value: UIColor.clear, range: hidden)
                s.addAttribute(.strokeColor, value: UIColor.clear, range: hidden)
                s.removeAttribute(.shadow, range: hidden)
            }
            return s
        }
        return makeImage(textSize: layout.textSize, prepared: prepared) { _, rect in
            let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            // 大きさから除いた行末の字間と 1 行目の上の行間のぶん、描く範囲を広げる
            let drawRect = CGRect(x: rect.minX, y: rect.minY - layout.topExtra,
                                  width: rect.width + layout.trailingKern, height: rect.height + layout.topExtra)
            strokeString?.draw(with: drawRect, options: options, context: nil)
            layout.fillString.draw(with: drawRect, options: options, context: nil)
        }
    }

    // 縦書き: 改行ごとに列、右から左へ。1 文字ずつ積む
    private typealias VerticalColumn = [(ch: Character, accent: Bool, index: Int)]

    private static func verticalColumns(_ spec: Spec) -> [VerticalColumn] {
        var splitColumns: [VerticalColumn] = [[]]
        for (offset, ch) in spec.text.enumerated() {
            if ch.isNewline {
                splitColumns.append([])
            } else {
                splitColumns[splitColumns.count - 1].append((ch, spec.accentIndices.contains(offset), offset))
            }
        }
        return splitColumns.filter { !$0.isEmpty }
    }

    private static func verticalMetrics(_ columns: [VerticalColumn], _ spec: Spec,
                                        _ prepared: Prepared) -> (textSize: CGSize, pitchX: CGFloat, pitchY: CGFloat) {
        let fontSize = spec.fontSize
        let pitchY = fontSize * CGFloat(GeometryMath.clamp(spec.style.lineSpacing, 0.8, 3)) + prepared.kern
        let pitchX = fontSize * 1.2
        let maxChars = columns.map { $0.count }.max() ?? 1
        let textSize = CGSize(width: ceil(pitchX * CGFloat(columns.count)), height: ceil(pitchY * CGFloat(maxChars)))
        return (textSize, pitchX, pitchY)
    }

    /// 縦書きでの字形の扱い
    private enum VerticalForm {
        case upright, rotated, punctuation
    }

    private static func verticalForm(_ ch: Character) -> VerticalForm {
        if "、。，．".contains(ch) { return .punctuation }
        if "ー—―‐−–-〜～…‥＝=「」『』（）()【】〔〕［］[]｛｝{}〈〉《》＜＞<>".contains(ch) { return .rotated }
        return .upright
    }

    private static func renderVertical(_ spec: Spec, _ prepared: Prepared) -> CIImage? {
        let columns = verticalColumns(spec)
        guard !columns.isEmpty else { return nil }
        let accentColor = spec.style.accentColorHex.flatMap { UIColor(hex: $0) }
        let fontSize = spec.fontSize
        let metrics = verticalMetrics(columns, spec, prepared)
        let textSize = metrics.textSize
        let pitchX = metrics.pitchX
        let pitchY = metrics.pitchY
        guard textSize.width >= 1, textSize.height >= 1 else { return nil }

        // 段落スタイルの字間・配置は 1 文字描画では使わない
        var fill = prepared.fillAttributes
        fill[.kern] = nil
        fill[.paragraphStyle] = nil
        var stroke = prepared.strokeAttributes
        stroke?[.kern] = nil
        stroke?[.paragraphStyle] = nil
        let visibleCount = spec.visibleCount

        return makeImage(textSize: textSize, prepared: prepared) { context, rect in
            for (columnIndex, column) in columns.enumerated() {
                let x = rect.minX + CGFloat(columns.count - 1 - columnIndex) * pitchX
                for (charIndex, item) in column.enumerated() {
                    // タイプライターの途中: まだ出ていない文字は描かない(列の位置は全文のまま)
                    if let visibleCount, item.index >= visibleCount { continue }
                    let s = String(item.ch)
                    var charFill = fill
                    if item.accent, let accentColor { charFill[.foregroundColor] = accentColor }
                    let fillString = NSAttributedString(string: s, attributes: charFill)
                    let size = fillString.size()
                    let cell = CGRect(x: x, y: rect.minY + CGFloat(charIndex) * pitchY, width: pitchX, height: pitchY)
                    var origin = CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2)
                    context.saveGState()
                    switch Self.verticalForm(item.ch) {
                    case .upright:
                        break
                    case .rotated:
                        // 長音・かっこ類は、マスの中心で 90° 回す
                        context.translateBy(x: cell.midX, y: cell.midY)
                        context.rotate(by: CGFloat(Double.pi / 2))
                        origin = CGPoint(x: -size.width / 2, y: -size.height / 2)
                        if "…‥".contains(item.ch) {
                            // 点の高さは書体で違う(欧文はベースライン上、和文の多くは全角の中央)ので、点そのものを列の中央に合わせる
                            let line = CTLineCreateWithAttributedString(fillString as CFAttributedString)
                            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                            if !ink.isEmpty {
                                var ascent: CGFloat = 0
                                _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
                                origin.y = ink.midY - ascent
                            }
                        }
                    case .punctuation:
                        // 句読点はマスの右上に寄せる
                        origin.x += fontSize * 0.6
                        origin.y -= fontSize * 0.6
                    }
                    if let stroke {
                        NSAttributedString(string: s, attributes: stroke).draw(at: origin)
                    }
                    fillString.draw(at: origin)
                    context.restoreGState()
                }
            }
        }
    }

    // 弧に沿った配置: 1 文字ずつ接線方向に回して置く
    private struct ArcLayout {
        let chars: [Character]
        let strings: [NSAttributedString]
        let sizes: [CGSize]
        let advances: [CGFloat]
        let radius: CGFloat
        let half: CGFloat
        let textSize: CGSize
        let stroke: [NSAttributedString.Key: Any]?
    }

    private static func arcLayout(_ spec: Spec, _ prepared: Prepared) -> ArcLayout? {
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

        let accentColor = spec.style.accentColorHex.flatMap { UIColor(hex: $0) }
        let strings = chars.enumerated().map { index, ch -> NSAttributedString in
            var attributes = fill
            if spec.accentIndices.contains(index), let accentColor { attributes[.foregroundColor] = accentColor }
            return NSAttributedString(string: String(ch), attributes: attributes)
        }
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
        return ArcLayout(chars: chars, strings: strings, sizes: sizes, advances: advances,
                         radius: radius, half: half, textSize: textSize, stroke: stroke)
    }

    private static func renderArc(_ spec: Spec, _ prepared: Prepared) -> CIImage? {
        guard let layout = arcLayout(spec, prepared) else { return nil }
        let chars = layout.chars
        let strings = layout.strings
        let sizes = layout.sizes
        let advances = layout.advances
        let radius = layout.radius
        let half = layout.half
        let stroke = layout.stroke
        let fontSize = spec.fontSize
        let visibleCount = spec.visibleCount

        return makeImage(textSize: layout.textSize, prepared: prepared) { context, rect in
            let center = CGPoint(x: rect.midX, y: rect.minY + fontSize * 0.7 + radius)
            var cursor: CGFloat = 0
            for i in 0..<chars.count {
                let mid = cursor + advances[i] / 2
                cursor += advances[i]
                // タイプライターの途中: まだ出ていない文字は描かない(弧の位置は全文のまま)
                if let visibleCount, i >= visibleCount { continue }
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
