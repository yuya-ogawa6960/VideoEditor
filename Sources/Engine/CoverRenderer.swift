import Foundation
import AVFoundation
import UIKit
import Photos

// =====================================================================
// サムネ(カバー画像)の描画。
// 背景 = cover.imageURL の写真、または合成した映像の cover.frameTime のコマ。
// その上にメモ風のカード(タイトル + 本文)を少し傾けて重ねる。
// =====================================================================

enum CoverRendererError: LocalizedError {
    case noSource
    case cannotRenderFrame
    case cannotLoadImage
    case photosAccessDenied

    var errorDescription: String? {
        switch self {
        case .noSource: return "背景にする動画か写真がありません"
        case .cannotRenderFrame: return "動画のコマを取り出せませんでした"
        case .cannotLoadImage: return "写真を読み込めませんでした"
        case .photosAccessDenied: return "写真ライブラリへの保存が許可されていません。設定アプリから許可してください"
        }
    }
}

enum CoverRenderer {
    private struct PaperStyle {
        let fill: UIColor
        let text: UIColor
        let line: UIColor?
    }

    // MARK: - 公開 API

    /// size ピクセルのカバー画像を作る
    static func render(snapshot: ProjectSnapshot, cover: CoverSettings, size: CGSize) async throws -> UIImage {
        let targetSize = CGSize(width: max(16, size.width.rounded()), height: max(16, size.height.rounded()))
        let background = try await backgroundImage(snapshot: snapshot, cover: cover, size: targetSize)
        try Task.checkCancellation()
        return compose(background: background, cover: cover, size: targetSize)
    }

    /// 写真ライブラリに保存する(追加のみの許可)
    static func saveToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CoverRendererError.photosAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    // MARK: - 背景

    private static func backgroundImage(snapshot: ProjectSnapshot, cover: CoverSettings, size: CGSize) async throws -> UIImage {
        if let imageURL = cover.imageURL {
            let maxPixel = max(size.width, size.height) * 1.5
            guard let image = MediaStore.makeImageClipThumbnail(url: imageURL, maxPixel: maxPixel) else {
                throw CoverRendererError.cannotLoadImage
            }
            return image
        }
        guard !snapshot.clips.isEmpty else { throw CoverRendererError.noSource }

        // 字幕・手書き・透かし・冒頭のフェードはサムネには入れない
        var buildSnapshot = snapshot
        buildSnapshot.subtitles = []
        buildSnapshot.drawings = []
        buildSnapshot.watermark = WatermarkSettings()
        buildSnapshot.documentary.fadeFromToBlack = false
        buildSnapshot.documentary.dipToBlackBetweenClips = false
        if !cover.applyLook {
            for i in buildSnapshot.clips.indices {
                buildSnapshot.clips[i].filter = FilterSettings()
            }
            buildSnapshot.documentary.look = .none
            buildSnapshot.documentary.letterbox = false
            buildSnapshot.documentary.filmGrain = 0
            buildSnapshot.documentary.vignette = 0
        }

        let purpose: RenderPurpose = size.width > 1300 ? .export : .preview
        let built = try await CompositionBuilder.build(buildSnapshot, purpose: purpose)
        try Task.checkCancellation()

        let total = built.duration.seconds
        var seconds = cover.frameTime.isFinite ? max(0, cover.frameTime) : 0
        if total.isFinite && total > 0 {
            seconds = min(seconds, max(0, total - 0.05))
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        if let result = try? await generator.image(at: time) {
            return UIImage(cgImage: result.image)
        }
        // 厳密な時刻で取れないときは許容幅を広げる
        let relaxed = AVAssetImageGenerator(asset: built.composition)
        relaxed.videoComposition = built.videoComposition
        relaxed.appliesPreferredTrackTransform = true
        relaxed.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        relaxed.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let result = try await relaxed.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            throw CoverRendererError.cannotRenderFrame
        }
    }

    // MARK: - 合成

    private static func compose(background: UIImage, cover: CoverSettings, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // 背景をアスペクトフィルで敷く
            let bgSize = background.size
            if bgSize.width > 0 && bgSize.height > 0 {
                let scale = max(size.width / bgSize.width, size.height / bgSize.height)
                let w = bgSize.width * scale
                let h = bgSize.height * scale
                background.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            }

            drawMemoCard(in: cg, cover: cover, size: size)
        }
    }

    private static func paperStyle(_ paper: MemoPaper) -> PaperStyle {
        switch paper {
        case .yellow:
            return PaperStyle(fill: UIColor(hex: "#FFF2A8") ?? .yellow,
                              text: UIColor(hex: "#3A3A3A") ?? .darkGray,
                              line: UIColor(hex: "#E8D98A"))
        case .white:
            return PaperStyle(fill: .white,
                              text: UIColor(hex: "#333333") ?? .darkGray,
                              line: UIColor(hex: "#D8D8D8"))
        case .kraft:
            return PaperStyle(fill: UIColor(hex: "#D8B98A") ?? .brown,
                              text: UIColor(hex: "#3B2A14") ?? .black,
                              line: nil)
        case .dark:
            return PaperStyle(fill: UIColor(hex: "#2E3A36") ?? .darkGray,
                              text: UIColor(hex: "#F4F4F4") ?? .white,
                              line: UIColor(hex: "#5A6A64"))
        case .pink:
            return PaperStyle(fill: UIColor(hex: "#FFC9D6") ?? .systemPink,
                              text: UIColor(hex: "#4A2A33") ?? .black,
                              line: UIColor(hex: "#F0A8B8"))
        }
    }

    /// 指定名のフォント → 無ければ丸ゴシック(ヒラギノ丸ゴ)→ 無ければ丸みのあるシステムフォント
    private static func font(named name: String?, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        if let name, !name.isEmpty, let custom = UIFont(name: name, size: size) {
            return custom
        }
        if let maru = UIFont(name: "HiraMaruProN-W4", size: size) {
            if weight == .bold || weight == .semibold || weight == .heavy {
                let descriptor = maru.fontDescriptor.withSymbolicTraits(.traitBold) ?? maru.fontDescriptor
                return UIFont(descriptor: descriptor, size: size)
            }
            return maru
        }
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        if let rounded = system.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: rounded, size: size)
        }
        return system
    }

    /// 複数行なら「・」を付けた箇条書きにする
    private static func bulletized(_ memo: String) -> String {
        let lines = memo
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return lines.first ?? "" }
        return lines.map { line in
            line.hasPrefix("・") || line.hasPrefix("-") || line.hasPrefix("•") ? line : "・" + line
        }.joined(separator: "\n")
    }

    private static func drawMemoCard(in cg: CGContext, cover: CoverSettings, size: CGSize) {
        let title = cover.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bulletized(cover.memoText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !title.isEmpty || !body.isEmpty else { return }

        let paper = paperStyle(cover.paper)
        let widthRatio = CGFloat(min(max(cover.memoWidthRatio, 0.15), 0.9))
        let cardWidth = size.width * widthRatio
        let padding = cardWidth * 0.08
        let textWidth = max(10, cardWidth - padding * 2)

        let titleFont = font(named: cover.fontName, size: cardWidth * 0.11, weight: .bold)
        let bodyFont = font(named: cover.fontName, size: cardWidth * 0.065, weight: .medium)

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineBreakMode = .byWordWrapping
        titleParagraph.lineSpacing = titleFont.pointSize * 0.12
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineBreakMode = .byWordWrapping
        bodyParagraph.lineSpacing = bodyFont.pointSize * 0.45

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: paper.text,
            .paragraphStyle: titleParagraph
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: paper.text,
            .paragraphStyle: bodyParagraph
        ]
        let bounding = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let titleHeight: CGFloat = title.isEmpty ? 0
            : ceil((title as NSString).boundingRect(with: bounding, options: options, attributes: titleAttributes, context: nil).height)
        let bodyHeight: CGFloat = body.isEmpty ? 0
            : ceil((body as NSString).boundingRect(with: bounding, options: options, attributes: bodyAttributes, context: nil).height)
        let gap: CGFloat = (title.isEmpty || body.isEmpty) ? 0 : padding * 0.6
        var cardHeight = padding * 2 + titleHeight + gap + bodyHeight
        cardHeight = max(cardHeight, cardWidth * 0.45)

        let center = CGPoint(x: size.width * CGFloat(cover.memoCenter.x), y: size.height * CGFloat(cover.memoCenter.y))
        let rotation = CGFloat(cover.memoRotation) * .pi / 180
        let cardRect = CGRect(x: -cardWidth / 2, y: -cardHeight / 2, width: cardWidth, height: cardHeight)

        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: rotation)

        // 紙と影
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: cardWidth * 0.02),
                     blur: cardWidth * 0.06,
                     color: UIColor.black.withAlphaComponent(0.45).cgColor)
        let paperPath = UIBezierPath(roundedRect: cardRect, cornerRadius: cardWidth * 0.02)
        paper.fill.setFill()
        paperPath.fill()
        cg.restoreGState()

        // 罫線
        if let lineColor = paper.line, !body.isEmpty {
            lineColor.setStroke()
            let lineStep = bodyFont.lineHeight + bodyParagraph.lineSpacing
            var y = cardRect.minY + padding + titleHeight + gap + bodyFont.lineHeight + bodyFont.descender * 0.5
            var guardCount = 0
            while y < cardRect.maxY - padding * 0.5 && guardCount < 200 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: cardRect.minX + padding * 0.5, y: y))
                path.addLine(to: CGPoint(x: cardRect.maxX - padding * 0.5, y: y))
                path.lineWidth = max(1, cardWidth * 0.003)
                path.stroke()
                y += lineStep
                guardCount += 1
            }
        }

        // マスキングテープ
        let tapeRect = CGRect(x: -cardWidth * 0.12, y: cardRect.minY - padding * 0.35, width: cardWidth * 0.24, height: padding * 0.7)
        cg.saveGState()
        cg.rotate(by: -0.04)
        UIColor.white.withAlphaComponent(0.55).setFill()
        UIBezierPath(rect: tapeRect).fill()
        cg.restoreGState()

        // 文字
        var y = cardRect.minY + padding
        if !title.isEmpty {
            let rect = CGRect(x: cardRect.minX + padding, y: y, width: textWidth, height: titleHeight)
            (title as NSString).draw(with: rect, options: options, attributes: titleAttributes, context: nil)
            y += titleHeight + gap
        }
        if !body.isEmpty {
            let rect = CGRect(x: cardRect.minX + padding, y: y, width: textWidth, height: bodyHeight)
            (body as NSString).draw(with: rect, options: options, attributes: bodyAttributes, context: nil)
        }
        cg.restoreGState()
    }
}
