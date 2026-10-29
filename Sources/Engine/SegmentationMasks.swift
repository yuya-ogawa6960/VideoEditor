import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision

// =====================================================================
// SegmentationMasks: Vision で人物・被写体の切り抜き(白 = 残す部分の灰色画像)を作る共通処理。
// 被写体フラッシュ(SubjectFlashRenderer)と背景を消す(BackgroundRemovalRenderer)で使う。
// VideoCompositor の描画キューから同期で呼ばれる。切り抜けなかったときは nil。
// =====================================================================

enum SegmentationMasks {

    enum Kind {
        /// 人物(人を全員)。accurate = 書き出し用のきれいな切り抜き(遅い)
        case person(accurate: Bool)
        /// 前景の被写体。point(左上原点の 0...1)があれば、その位置の被写体(無ければいちばん近い被写体)だけ。
        /// point が nil なら全部の被写体
        case foreground(point: NormalizedPoint?)
    }

    /// image(rect を覆う不透明な画像)の切り抜きを、rect の大きさ・位置にそろえて返す。
    /// maxInputSide を指定すると、Vision に渡す前にその長辺まで縮める(速くするため)
    static func mask(for image: CIImage, in rect: CGRect, kind: Kind, maxInputSide: CGFloat? = nil) -> CIImage? {
        guard rect.width >= 2, rect.height >= 2, !rect.isInfinite else { return nil }
        var input = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        if let maxSide = maxInputSide, maxSide >= 64 {
            let long = max(rect.width, rect.height)
            if long > maxSide {
                let s = maxSide / long
                input = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
                let e = input.extent
                input = input.cropped(to: CGRect(x: 0, y: 0, width: e.width.rounded(.down), height: e.height.rounded(.down)))
            }
        }
        let handler = VNImageRequestHandler(ciImage: input, options: [:])
        let buffer: CVPixelBuffer?
        switch kind {
        case .person(let accurate):
            buffer = personMask(handler: handler, accurate: accurate)
        case .foreground(let point):
            buffer = foregroundMask(handler: handler, point: point)
        }
        guard let buffer else { return nil }
        return grayMask(from: buffer, fitting: rect)
    }

    /// 1 チャンネルの切り抜きを、赤の値で灰色(不透明)にそろえて rect に合わせる(8bit / float のどちらでも同じに扱う)
    static func grayMask(from buffer: CVPixelBuffer, fitting rect: CGRect) -> CIImage? {
        let raw = CIImage(cvPixelBuffer: buffer)
        let extent = raw.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let gray = raw.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let scaled = gray
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / extent.width,
                                               y: rect.height / extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return scaled.cropped(to: rect)
    }

    private static func personMask(handler: VNImageRequestHandler, accurate: Bool) -> CVPixelBuffer? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        VisionCompute.prepare([request])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first?.pixelBuffer
    }

    private static func foregroundMask(handler: VNImageRequestHandler, point: NormalizedPoint?) -> CVPixelBuffer? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        VisionCompute.prepare([request])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        var instances = observation.allInstances
        guard !instances.isEmpty else { return nil }
        if let point {
            guard let label = instanceLabel(near: point, in: observation.instanceMask) else { return nil }
            instances = IndexSet(integer: label)
        }
        return try? observation.generateScaledMaskForImage(forInstances: instances, from: handler)
    }

    /// 被写体の番号の画像(0 = 背景)で、point の位置の番号。背景なら近くを探す(短辺の 15% まで)
    private static func instanceLabel(near point: NormalizedPoint, in labels: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let width = CVPixelBufferGetWidth(labels)
        let height = CVPixelBufferGetHeight(labels)
        let rowBytes = CVPixelBufferGetBytesPerRow(labels)
        guard width > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        func label(_ x: Int, _ y: Int) -> Int {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return Int(bytes[y * rowBytes + x])
        }
        let cx = Int((min(max(point.x, 0), 1) * Double(width - 1)).rounded())
        let cy = Int((min(max(point.y, 0), 1) * Double(height - 1)).rounded())
        let center = label(cx, cy)
        if center != 0 { return center }
        let maxRadius = max(1, Int(Double(min(width, height)) * 0.15))
        let step = max(1, maxRadius / 24)
        var radius = step
        while radius <= maxRadius {
            // 正方形の輪の上を調べる
            var dx = -radius
            while dx <= radius {
                for (x, y) in [(cx + dx, cy - radius), (cx + dx, cy + radius), (cx - radius, cy + dx), (cx + radius, cy + dx)] {
                    let found = label(x, y)
                    if found != 0 { return found }
                }
                dx += step
            }
            radius += step
        }
        return nil
    }
}
