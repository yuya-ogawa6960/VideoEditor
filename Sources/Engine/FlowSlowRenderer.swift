import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Vision

// =====================================================================
// なめらかスロー: 前後のコマの動き(Vision のオプティカルフロー)から間のコマを作り、
// コマ数を factor 倍にした映像だけの .mov を mediaDirectory に作る(逆再生の reversedCopy と同じ置き場所)。
//
//   1. 元の動画をトリミング範囲(前後に margin 秒の余白)だけ BGRA で読む
//   2. となりの 2 コマ A・B ごとに、縮小した画像で VNGenerateOpticalFlowRequest を実行
//      (流れの向き・単位は SDK の版で違っても困らないよう、A を流れで動かして B に近づくかを数点で確かめて決める。
//       動きが当てにならないときは前後を混ぜるだけにする)
//   3. 間の時刻 t ごとに A を t、B を 1 − t だけ流れに沿って動かして混ぜる(CPU。行ごとに並列)
//   4. 元のコマと作ったコマを時刻順に書く。ファイルの 0 秒 = 元素材の最初のコマの時刻(sourceStart)
//
// 長さ・時刻は元の素材と同じなので、CompositionBuilder は同じ範囲をずらして差し替えるだけで使える。
// iOS 26 の VideoToolbox のフレーム補間(VTFrameProcessor)は API 名をここで確かめられないため使っていない。
// =====================================================================

enum FlowSlowError: LocalizedError {
    case notSlow
    case notNeeded

    var errorDescription: String? {
        switch self {
        case .notSlow: return String(localized: "速度を1xより遅くすると使えます")
        case .notNeeded: return String(localized: "元の動画のコマ数が多いので、このままでなめらかです")
        }
    }
}

enum FlowSlowRenderer {
    private static let workQueue = DispatchQueue(label: "com.personal.videoeditor.flowslow", qos: .userInitiated)

    /// トリミング範囲の前後に足す余白(秒)。少しトリミングを変えても作り直さずに使える
    static let margin = 0.5

    struct Output {
        let url: URL
        /// ファイルの 0 秒にあたる元素材上の秒
        let sourceStart: Double
        let sourceEnd: Double
        let factor: Int
    }

    private struct RenderedRange {
        let start: Double
        let end: Double
    }

    /// 必要なコマの倍数(1 なら作らなくてよい)。書き出しのコマ数 target に、いちばん遅いところで届く倍数。最大 8 倍・240fps まで
    static func factor(sourceFrameRate: Double, slowestSpeed: Double, targetFrameRate: Double) -> Int {
        let fps = sourceFrameRate > 1 ? sourceFrameRate : 30
        let effective = fps * max(slowestSpeed, 0.05)
        var f = Int((max(targetFrameRate, 24) / effective - 0.05).rounded(.up))
        f = min(f, 8)
        f = min(f, max(1, Int(240 / fps)))
        return max(1, f)
    }

    /// 元の動画のコマ数(読めなければ 30)
    static func sourceFrameRate(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let track = tracks.first, let rate = try? await track.load(.nominalFrameRate) else { return 30 }
        return rate > 1 ? Double(rate) : 30
    }

    /// [start, end](元素材上の秒)のコマを factor 倍にした映像を作る。
    /// progress は 0...1 をバックグラウンドのスレッドから呼ぶ。呼び出し側 Task のキャンセルで中断する
    static func makeCopy(of url: URL, start: Double, end: Double, factor: Int,
                         progress: ((Double) -> Void)?) async throws -> Output {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw MediaToolsError.noVideoTrack }
        let (naturalSize, transform, nominalFrameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let assetDuration = try await asset.load(.duration).seconds

        let rangeStart = max(0, min(start, end) - margin)
        var rangeEnd = max(start, end) + margin
        if assetDuration.isFinite && assetDuration > 0 {
            rangeEnd = min(rangeEnd, assetDuration)
        }
        guard rangeEnd - rangeStart > 0.1 else { throw MediaToolsError.invalidRange }

        let base = MediaStore.displayName(for: url, fallback: String(localized: "動画"))
        let destination = MediaStore.uniqueDestination(forFileName: "\(base)_smooth.mov")
        let frameRate = nominalFrameRate > 1 ? Double(nominalFrameRate) : 30
        let clampedFactor = min(max(factor, 2), 16)
        let flag = MediaToolsCancelFlag()
        let report: (Double) -> Void = { value in
            progress?(min(max(value, 0), 1))
        }

        let rendered: RenderedRange = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RenderedRange, Error>) in
                workQueue.async {
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let value = try renderBlocking(asset: asset,
                                                       track: track,
                                                       naturalSize: naturalSize,
                                                       transform: transform,
                                                       frameRate: frameRate,
                                                       rangeStart: rangeStart,
                                                       rangeEnd: rangeEnd,
                                                       factor: clampedFactor,
                                                       destination: destination,
                                                       flag: flag,
                                                       progress: report)
                        continuation.resume(returning: value)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
        report(1)
        return Output(url: destination, sourceStart: rendered.start, sourceEnd: rendered.end, factor: clampedFactor)
    }

    // MARK: - 本体(同期。専用キューで実行)

    private static func renderBlocking(asset: AVURLAsset,
                                       track: AVAssetTrack,
                                       naturalSize: CGSize,
                                       transform: CGAffineTransform,
                                       frameRate: Double,
                                       rangeStart: Double,
                                       rangeEnd: Double,
                                       factor: Int,
                                       destination: URL,
                                       flag: MediaToolsCancelFlag,
                                       progress: @escaping (Double) -> Void) throws -> RenderedRange {
        // 読み込み(BGRA)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: rangeStart, preferredTimescale: 600),
                                       end: CMTime(seconds: rangeEnd, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaToolsError.readFailed(String(localized: "映像の読み込みを設定できません")) }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaToolsError.readFailed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
        }

        // 書き込み(元の向き情報はそのまま transform に持たせる)
        let width = max(2, Int(naturalSize.width.rounded()) & ~1)
        let height = max(2, Int(naturalSize.height.rounded()) & ~1)
        let outputFrameRate = frameRate * Double(factor)
        let useHEVC = min(width, height) >= 2160
        let rateBoost = min(2.5, 0.4 + 0.6 * Double(factor))
        let bitrate = min(120_000_000, max(4_000_000, Int(Double(width * height) * 8 * rateBoost)))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(outputFrameRate.rounded()),
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(outputFrameRate.rounded()))
        ]
        if !useHEVC {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let codec: AVVideoCodecType = useHEVC ? .hevc : .h264
        let settings: [String: Any] = [
            AVVideoCodecKey: codec.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else { throw MediaToolsError.writeFailed(String(localized: "映像の書き込みを設定できません")) }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaToolsError.writeFailed(writer.error?.localizedDescription ?? String(localized: "書き込みを開始できません"))
        }
        writer.startSession(atSourceTime: .zero)

        func failWriter(_ message: String) -> Error {
            let error = writer.error
            if writer.status == .writing { writer.cancelWriting() }
            reader.cancelReading()
            return error ?? MediaToolsError.writeFailed(message)
        }

        var lastOut = CMTime.invalid
        func append(_ buffer: CVPixelBuffer, at time: CMTime) throws {
            while !input.isReadyForMoreMediaData {
                if flag.isCancelled || writer.status != .writing { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if flag.isCancelled {
                writer.cancelWriting()
                reader.cancelReading()
                throw CancellationError()
            }
            guard writer.status == .writing else { throw failWriter(String(localized: "書き込みが中断されました")) }
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw failWriter(String(localized: "コマを書き込めませんでした"))
            }
            lastOut = time
        }

        let estimator = FlowFieldEstimator()
        let expectedFrames = max(1.0, (rangeEnd - rangeStart) * frameRate)
        var origin: CMTime? = nil
        var previousTime = CMTime.invalid
        var previousBuffer: CVPixelBuffer? = nil
        var frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 60000)
        var readCount = 0

        while let sample = output.copyNextSampleBuffer() {
            if flag.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { continue }
            let base = origin ?? pts
            if origin == nil { origin = pts }
            let outTime = CMTimeSubtract(pts, base)
            if lastOut.isValid && CMTimeCompare(outTime, lastOut) <= 0 { continue }

            // 前のコマとこのコマの間に factor − 1 枚を作る(間が空きすぎていれば作らない)
            if let previousBuffer, previousTime.isValid {
                let gap = CMTimeSubtract(outTime, previousTime)
                let gapSeconds = gap.seconds
                if gapSeconds > 0.0001 && gapSeconds < 0.5 {
                    frameDuration = gap
                    let field = estimator.field(from: previousBuffer, to: buffer)
                    for k in 1..<factor {
                        let t = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(gap, multiplier: Int32(k), divisor: Int32(factor)))
                        if lastOut.isValid && CMTimeCompare(t, lastOut) <= 0 { continue }
                        guard let pool = adaptor.pixelBufferPool else { break }
                        var created: CVPixelBuffer? = nil
                        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
                              let made = created else { break }
                        let phase = Float(k) / Float(factor)
                        guard FlowFrameWarp.render(from: previousBuffer, to: buffer, field: field, phase: phase, into: made) else { break }
                        try append(made, at: t)
                    }
                }
            }

            try append(buffer, at: outTime)
            previousBuffer = buffer
            previousTime = outTime
            readCount += 1
            if readCount % 3 == 0 {
                progress(min(0.99, Double(readCount) / expectedFrames))
            }
        }
        if reader.status == .failed {
            throw failWriter(reader.error?.localizedDescription ?? String(localized: "映像の読み込みに失敗しました"))
        }
        guard let origin, lastOut.isValid else {
            throw failWriter(String(localized: "書き込めるコマがありませんでした"))
        }

        input.markAsFinished()
        let tail = CMTimeMultiplyByRatio(frameDuration, multiplier: 1, divisor: Int32(max(1, factor)))
        let endTime = CMTimeAdd(lastOut, tail)
        writer.endSession(atSourceTime: endTime)
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? MediaToolsError.writeFailed(String(localized: "書き込みを完了できませんでした"))
        }
        let startSeconds = origin.seconds
        return RenderedRange(start: startSeconds, end: startSeconds + endTime.seconds)
    }
}

// MARK: - オプティカルフロー

/// 2 コマの間の動き(元の大きさのピクセル単位に直す倍率つき)
struct FlowField {
    /// kCVPixelFormatType_TwoComponent32Float
    let buffer: CVPixelBuffer
    /// 流れの値 × multiplier = 元の大きさで A のものが B でどれだけ動いたか(ピクセル、下・右が正)
    let multiplierX: Float
    let multiplierY: Float
}

/// Vision で 2 コマの流れを求める(縮小して計算する)
final class FlowFieldEstimator {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    /// 流れを計算する画像の長い辺
    private let maxSide = 640

    func field(from a: CVPixelBuffer, to b: CVPixelBuffer) -> FlowField? {
        let w = CVPixelBufferGetWidth(a)
        let h = CVPixelBufferGetHeight(a)
        guard w >= 16, h >= 16,
              CVPixelBufferGetWidth(b) == w, CVPixelBufferGetHeight(b) == h else { return nil }
        let scale = min(1.0, Double(maxSide) / Double(max(w, h)))
        let sw = max(16, Int((Double(w) * scale).rounded()))
        let sh = max(16, Int((Double(h) * scale).rounded()))
        guard let smallA = downscaled(a, width: sw, height: sh),
              let smallB = downscaled(b, width: sw, height: sh) else { return nil }

        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: smallB, options: [:])
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: smallA, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let flow = observation.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else { return nil }
        return calibrated(flow: flow, a: smallA, b: smallB, fullWidth: w, fullHeight: h)
    }

    private func downscaled(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var created: CVPixelBuffer? = nil
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &created) == kCVReturnSuccess,
              let out = created else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let sx = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(buffer))
        let sy = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(buffer))
        context.render(image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: out)
        return out
    }

    /// 流れの向き(x・y それぞれの符号)と単位(流れの画像のピクセルか、計算した画像のピクセルか)を、
    /// A を流れで動かしたものが B にいちばん近くなる組み合わせに決める。動かさない方が近ければ nil(前後を混ぜるだけ)
    private func calibrated(flow: CVPixelBuffer, a: CVPixelBuffer, b: CVPixelBuffer,
                            fullWidth: Int, fullHeight: Int) -> FlowField? {
        let fw = CVPixelBufferGetWidth(flow)
        let fh = CVPixelBufferGetHeight(flow)
        let sw = CVPixelBufferGetWidth(a)
        let sh = CVPixelBufferGetHeight(a)
        guard fw > 1, fh > 1, sw > 8, sh > 8 else { return nil }

        CVPixelBufferLockBaseAddress(flow, .readOnly)
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(flow, .readOnly)
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let flowBase = CVPixelBufferGetBaseAddress(flow),
              let aBase = CVPixelBufferGetBaseAddress(a),
              let bBase = CVPixelBufferGetBaseAddress(b) else { return nil }
        let fp = flowBase.assumingMemoryBound(to: Float32.self)
        let fStride = CVPixelBufferGetBytesPerRow(flow) / MemoryLayout<Float32>.size
        let ap = UnsafePointer<UInt8>(aBase.assumingMemoryBound(to: UInt8.self))
        let bp = UnsafePointer<UInt8>(bBase.assumingMemoryBound(to: UInt8.self))
        let aStride = CVPixelBufferGetBytesPerRow(a)
        let bStride = CVPixelBufferGetBytesPerRow(b)

        var units: [Float] = [1]
        let alternative = Float(sw) / Float(fw)
        if abs(alternative - 1) > 0.01 { units.append(alternative) }
        let signs: [(Float, Float)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
        var errors = [Float](repeating: 0, count: 1 + units.count * signs.count)

        let step = max(2, min(sw, sh) / 48)
        var y = step
        while y < sh - step {
            var x = step
            while x < sw - step {
                let target = FlowFrameWarp.luma(bp, stride: bStride, width: sw, height: sh, x: Float(x), y: Float(y))
                errors[0] += abs(FlowFrameWarp.luma(ap, stride: aStride, width: sw, height: sh, x: Float(x), y: Float(y)) - target)
                let fx = min(fw - 1, x * fw / sw)
                let fy = min(fh - 1, y * fh / sh)
                let vx = fp[fy * fStride + fx * 2]
                let vy = fp[fy * fStride + fx * 2 + 1]
                if vx.isFinite && vy.isFinite {
                    var i = 1
                    for u in units {
                        for s in signs {
                            let dx = vx * u * s.0
                            let dy = vy * u * s.1
                            let moved = FlowFrameWarp.luma(ap, stride: aStride, width: sw, height: sh,
                                                           x: Float(x) - dx, y: Float(y) - dy)
                            errors[i] += abs(moved - target)
                            i += 1
                        }
                    }
                } else {
                    for i in 1..<errors.count { errors[i] += 255 }
                }
                x += step
            }
            y += step
        }

        var best = 0
        for i in 1..<errors.count where errors[i] < errors[best] {
            best = i
        }
        // 動かした方がはっきり近いときだけ使う
        guard best > 0, errors[best] < errors[0] * 0.97 else { return nil }
        let unit = units[(best - 1) / signs.count]
        let sign = signs[(best - 1) % signs.count]
        let toFullX = Float(fullWidth) / Float(sw)
        let toFullY = Float(fullHeight) / Float(sh)
        return FlowField(buffer: flow,
                         multiplierX: unit * sign.0 * toFullX,
                         multiplierY: unit * sign.1 * toFullY)
    }
}

// MARK: - 間のコマを作る(CPU)

enum FlowFrameWarp {

    /// A と B の間、phase(0...1)の時刻のコマを out に書く。field が nil なら前後を混ぜるだけ
    static func render(from a: CVPixelBuffer, to b: CVPixelBuffer, field: FlowField?, phase: Float,
                       into out: CVPixelBuffer) -> Bool {
        let bgra = kCVPixelFormatType_32BGRA
        guard CVPixelBufferGetPixelFormatType(a) == bgra,
              CVPixelBufferGetPixelFormatType(b) == bgra,
              CVPixelBufferGetPixelFormatType(out) == bgra else { return false }

        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        if let field { CVPixelBufferLockBaseAddress(field.buffer, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
            CVPixelBufferUnlockBaseAddress(out, [])
            if let field { CVPixelBufferUnlockBaseAddress(field.buffer, .readOnly) }
        }
        guard let aBase = CVPixelBufferGetBaseAddress(a),
              let bBase = CVPixelBufferGetBaseAddress(b),
              let oBase = CVPixelBufferGetBaseAddress(out) else { return false }

        let aw = CVPixelBufferGetWidth(a), ah = CVPixelBufferGetHeight(a)
        let bw = CVPixelBufferGetWidth(b), bh = CVPixelBufferGetHeight(b)
        let ow = CVPixelBufferGetWidth(out), oh = CVPixelBufferGetHeight(out)
        guard aw > 1, ah > 1, bw > 1, bh > 1, ow > 0, oh > 0 else { return false }
        let ap = UnsafePointer<UInt8>(aBase.assumingMemoryBound(to: UInt8.self))
        let bp = UnsafePointer<UInt8>(bBase.assumingMemoryBound(to: UInt8.self))
        let op = oBase.assumingMemoryBound(to: UInt8.self)
        let aStride = CVPixelBufferGetBytesPerRow(a)
        let bStride = CVPixelBufferGetBytesPerRow(b)
        let oStride = CVPixelBufferGetBytesPerRow(out)

        // 流れ(あれば)。並列の処理から読むので let にしておく
        var flowPointer: UnsafePointer<Float32>? = nil
        var flowW = 0, flowH = 0, flowStride = 0
        var multX: Float = 0, multY: Float = 0
        if let field, let fBase = CVPixelBufferGetBaseAddress(field.buffer) {
            flowPointer = UnsafePointer<Float32>(fBase.assumingMemoryBound(to: Float32.self))
            flowW = CVPixelBufferGetWidth(field.buffer)
            flowH = CVPixelBufferGetHeight(field.buffer)
            flowStride = CVPixelBufferGetBytesPerRow(field.buffer) / MemoryLayout<Float32>.size
            multX = field.multiplierX
            multY = field.multiplierY
        }
        let fp = flowPointer
        let fw = flowW, fh = flowH, fStride = flowStride
        let mx = multX, my = multY
        let flowScaleX = fw > 0 ? Float(fw) / Float(ow) : 0
        let flowScaleY = fh > 0 ? Float(fh) / Float(oh) : 0

        let t = min(max(phase, 0), 1)
        let it = 1 - t
        let bands = max(1, min(16, oh / 32))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let y0 = band * oh / bands
            let y1 = (band + 1) * oh / bands
            for y in y0..<y1 {
                let row = op + y * oStride
                for x in 0..<ow {
                    var vx: Float = 0
                    var vy: Float = 0
                    if let fp {
                        // 流れを双線形で読む
                        let sx = min(max((Float(x) + 0.5) * flowScaleX - 0.5, 0), Float(fw - 1))
                        let sy = min(max((Float(y) + 0.5) * flowScaleY - 0.5, 0), Float(fh - 1))
                        let x0 = Int(sx), y0f = Int(sy)
                        let x1 = min(x0 + 1, fw - 1), y1f = min(y0f + 1, fh - 1)
                        let ax = sx - Float(x0), ay = sy - Float(y0f)
                        let r0 = fp + y0f * fStride
                        let r1 = fp + y1f * fStride
                        let topX = r0[x0 * 2] + (r0[x1 * 2] - r0[x0 * 2]) * ax
                        let botX = r1[x0 * 2] + (r1[x1 * 2] - r1[x0 * 2]) * ax
                        let topY = r0[x0 * 2 + 1] + (r0[x1 * 2 + 1] - r0[x0 * 2 + 1]) * ax
                        let botY = r1[x0 * 2 + 1] + (r1[x1 * 2 + 1] - r1[x0 * 2 + 1]) * ax
                        let fx = topX + (botX - topX) * ay
                        let fy = topY + (botY - topY) * ay
                        if fx.isFinite && fy.isFinite {
                            vx = fx * mx
                            vy = fy * my
                        }
                    }
                    let pa = sample(ap, stride: aStride, width: aw, height: ah, x: Float(x) - t * vx, y: Float(y) - t * vy)
                    let pb = sample(bp, stride: bStride, width: bw, height: bh, x: Float(x) + it * vx, y: Float(y) + it * vy)
                    let c = pa * it + pb * t
                    let q = row + x * 4
                    q[0] = UInt8(min(max(c[0] + 0.5, 0), 255))
                    q[1] = UInt8(min(max(c[1] + 0.5, 0), 255))
                    q[2] = UInt8(min(max(c[2] + 0.5, 0), 255))
                    q[3] = UInt8(min(max(c[3] + 0.5, 0), 255))
                }
            }
        }
        return true
    }

    /// BGRA を双線形で読む(端は端の色)
    @inline(__always)
    static func sample(_ p: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, x: Float, y: Float) -> SIMD4<Float> {
        let cx = min(max(x.isFinite ? x : 0, 0), Float(width - 1))
        let cy = min(max(y.isFinite ? y : 0, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let r0 = p + y0 * stride
        let r1 = p + y1 * stride
        let p00 = pixel(r0, x0), p10 = pixel(r0, x1)
        let p01 = pixel(r1, x0), p11 = pixel(r1, x1)
        let top = p00 + (p10 - p00) * fx
        let bottom = p01 + (p11 - p01) * fx
        return top + (bottom - top) * fy
    }

    @inline(__always)
    private static func pixel(_ row: UnsafePointer<UInt8>, _ x: Int) -> SIMD4<Float> {
        let q = row + x * 4
        return SIMD4<Float>(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
    }

    /// 明るさ(BGRA。双線形)
    static func luma(_ p: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, x: Float, y: Float) -> Float {
        let c = sample(p, stride: stride, width: width, height: height, x: x, y: y)
        return 0.114 * c[0] + 0.587 * c[1] + 0.299 * c[2]
    }
}
