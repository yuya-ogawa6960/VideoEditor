import Foundation
import AVFoundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// =====================================================================
// GIF 書き出し。合成(CompositionBuilder.build)した映像から
// AVAssetImageGenerator でコマを取り出し、ImageIO でアニメーション GIF にする。
// =====================================================================

enum GIFExporterError: LocalizedError {
    case invalidRange
    case cannotCreateDestination
    case noFrames
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .invalidRange: return "GIF の範囲が正しくありません"
        case .cannotCreateDestination: return "GIF ファイルを作成できませんでした"
        case .noFrames: return "GIF にするコマを取り出せませんでした"
        case .finalizeFailed: return "GIF の書き込みに失敗しました"
        }
    }
}

enum GIFExporter {
    /// 1 本あたりの最大コマ数(容量と時間の上限)
    static let maximumFrames = 900

    /// tmp/VideoManiaGIF(必要に応じて作成)
    static var outputDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoManiaGIF", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// [start, end](出力タイムライン上の秒)を GIF にして URL を返す。progress は 0...1
    static func export(snapshot: ProjectSnapshot,
                       start: Double,
                       end: Double,
                       fps: Int = 12,
                       maxWidth: CGFloat = 480,
                       progress: ((Double) -> Void)?) async throws -> URL {
        let built = try await CompositionBuilder.build(snapshot, purpose: .preview)
        try Task.checkCancellation()

        let total = built.duration.seconds
        let rangeStart = max(0, min(start, end))
        var rangeEnd = max(start, end)
        if total.isFinite && total > 0 { rangeEnd = min(rangeEnd, total) }
        guard rangeEnd - rangeStart >= 0.1 else { throw GIFExporterError.invalidRange }

        let rate = max(1, min(30, fps))
        let frameInterval = 1.0 / Double(rate)
        var frameCount = Int(((rangeEnd - rangeStart) * Double(rate)).rounded(.down))
        frameCount = max(1, min(frameCount, maximumFrames))

        let renderSize = built.renderSize
        let scale = min(1, max(16, maxWidth) / max(1, renderSize.width))
        let targetSize = CGSize(width: max(16, (renderSize.width * scale).rounded()),
                                height: max(16, (renderSize.height * scale).rounded()))

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize
        let tolerance = CMTime(seconds: frameInterval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = outputDirectory.appendingPathComponent("VideoMania_\(formatter.string(from: Date())).gif")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw GIFExporterError.cannotCreateDestination
        }
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameInterval,
                kCGImagePropertyGIFUnclampedDelayTime: frameInterval
            ]
        ]

        // コマ数は作成時に宣言した数と合わせる必要があるため、取れなかったコマは直前のコマ(または黒)で埋める
        var lastImage: CGImage?
        var added = 0
        var succeeded = 0
        for i in 0..<frameCount {
            try Task.checkCancellation()
            let seconds = rangeStart + Double(i) * frameInterval
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            var image: CGImage?
            if let result = try? await generator.image(at: time) {
                image = result.image
                succeeded += 1
            } else {
                image = lastImage ?? blackImage(size: targetSize)
            }
            guard let image else { continue }
            lastImage = image
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            added += 1
            progress?(Double(i + 1) / Double(frameCount))
        }
        guard added > 0, succeeded > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw GIFExporterError.noFrames
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw GIFExporterError.finalizeFailed
        }
        return url
    }

    private static func blackImage(size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }
}
