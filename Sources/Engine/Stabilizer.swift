import Foundation
import AVFoundation
import CoreVideo
import Vision

// =====================================================================
// 手ぶれ補正の解析。
//
// 連続する 2 コマ(縮小・正立)に VNTranslationalImageRegistrationRequest をかけて
// コマ間の平行移動を求め、累積してカメラの軌跡を作る。軌跡をガウス窓(±15 コマ)で
// なめらかにし、「なめらかな軌跡 − 実際の軌跡」を補正量とする。
//
// サンプルの意味(コンポジタとの取り決め):
//   - time は元素材上の秒
//   - dx, dy は「正立したコマに加える平行移動」を画面の幅・高さに対する比率で表したもの。
//     座標系は左上原点(UIKit / NormalizedPoint と同じ。+x が右、+y が下)。
//     VideoCompositor.stabilized はこれを CoreImage 座標系(左下原点)に直して
//       translationX: dx * W * strength, y: -dy * H * strength
//     として適用する。Vision の alignmentTransform は左下原点なので、ここで y の符号を反転して保存する。
//   - rotation は度。平行移動の位置合わせのみ使うので常に 0(回転ぶれは補正しない)。
//   - cropZoom は補正後に端の黒が出ないよう、補正量の 95 パーセンタイルから 1.1 ... 1.3 で決める。
//     補正量はその cropZoom で隠せる範囲に収めてある。
// 解析結果は enabled = true、strength は clip の値を引き継ぐ。
// progress は 0...1 をバックグラウンドのスレッドから呼ぶ。
// =====================================================================

enum Stabilizer {
    /// 解析用のコマの長辺(px)
    static let frameDimension = 480
    /// ガウス窓の半径(コマ数)
    static let smoothingRadius = 15

    private final class State {
        var previous: CVPixelBuffer?
        var times: [Double] = []
        var pathX: [Double] = []
        var pathY: [Double] = []
        var positionX: Double = 0
        var positionY: Double = 0
        var width: Double = 1
        var height: Double = 1
    }

    static func analyze(clip: Clip, fps: Double = 30, progress: ((Double) -> Void)?) async throws -> StabilizationTrack {
        guard !clip.isStill else { throw VisionAnalysisError.stillImage }
        let start = clip.startTime
        let end = clip.endTime
        guard end - start > 0.1 else { throw VisionAnalysisError.invalidRange }
        let url = clip.url
        let span = end - start
        let state = State()

        try await AnalysisFrameReader.readFrames(url: url, start: start, end: end, fps: fps,
                                                 maxDimension: frameDimension) { buffer, time in
            if state.times.isEmpty {
                state.width = Double(max(1, CVPixelBufferGetWidth(buffer)))
                state.height = Double(max(1, CVPixelBufferGetHeight(buffer)))
            }
            if let previous = state.previous {
                let shift = translation(from: previous, to: buffer)
                let shiftX = Double(shift.x)
                let shiftY = Double(shift.y)
                // 画面の 1/4 を超える移動はシーンの切り替わりなどとみなして無視する
                let limitX = state.width * 0.25
                let limitY = state.height * 0.25
                if abs(shiftX) <= limitX && abs(shiftY) <= limitY {
                    state.positionX += shiftX
                    state.positionY += shiftY
                }
            }
            state.times.append(time)
            state.pathX.append(state.positionX)
            state.pathY.append(state.positionY)
            state.previous = buffer
            progress?(min(1, max(0, (time - start) / span)))
            return true
        }
        try Task.checkCancellation()
        state.previous = nil

        let count = state.times.count
        guard count >= 2 else { throw VisionAnalysisError.noFrames }

        let smoothX = gaussianSmoothed(state.pathX, radius: smoothingRadius)
        let smoothY = gaussianSmoothed(state.pathY, radius: smoothingRadius)

        // 補正量(比率)
        var dxs = [Double](repeating: 0, count: count)
        var dys = [Double](repeating: 0, count: count)
        var magnitudes: [Double] = []
        magnitudes.reserveCapacity(count)
        for i in 0..<count {
            let cx = (smoothX[i] - state.pathX[i]) / state.width
            let cy = (smoothY[i] - state.pathY[i]) / state.height
            dxs[i] = cx
            dys[i] = cy
            magnitudes.append(max(abs(cx), abs(cy)))
        }

        // 95 パーセンタイルから拡大率を決め、補正量はその範囲に収める
        let sorted = magnitudes.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let p95 = sorted[index]
        var cropZoom = 1.1
        if p95 > 0 {
            let needed = 1.0 / max(0.4, 1.0 - 2.2 * p95)
            cropZoom = min(1.3, max(1.1, needed))
        }
        let limit = (cropZoom - 1.0) / (2.0 * cropZoom)

        var samples: [StabilizationSample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let dx = min(limit, max(-limit, dxs[i]))
            // Vision / CoreImage は左下原点(+y が上)。保存するサンプルは左上原点(+y が下)なので符号を反転する
            let dyUp = min(limit, max(-limit, dys[i]))
            let dy = -dyUp
            samples.append(StabilizationSample(time: state.times[i], dx: dx, dy: dy, rotation: 0))
        }
        progress?(1)

        var track = clip.stabilization
        track.enabled = true
        track.samples = samples
        track.cropZoom = cropZoom
        return track
    }

    // MARK: 位置合わせ

    /// previous → current の内容の移動量(px、CoreImage 座標系)。失敗時は 0
    private static func translation(from previous: CVPixelBuffer, to current: CVPixelBuffer) -> CGPoint {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current, orientation: .up, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: previous, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .zero
        }
        guard let observation = request.results?.first else { return .zero }
        let transform = observation.alignmentTransform
        // alignmentTransform は current を previous に重ねるための移動。内容の移動はその逆
        guard transform.tx.isFinite, transform.ty.isFinite else { return .zero }
        return CGPoint(x: -Double(transform.tx), y: -Double(transform.ty))
    }

    // MARK: 平滑化

    /// ガウス窓(半径 radius、σ = radius / 2.2)。端は使える範囲で正規化する
    static func gaussianSmoothed(_ values: [Double], radius: Int) -> [Double] {
        let n = values.count
        guard n > 1, radius > 0 else { return values }
        let sigma = Double(radius) / 2.2
        var weights = [Double](repeating: 0, count: radius + 1)
        for k in 0...radius {
            let x = Double(k) / sigma
            weights[k] = exp(-0.5 * x * x)
        }
        var result = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = 0.0
            var weightSum = 0.0
            let lo = max(0, i - radius)
            let hi = min(n - 1, i + radius)
            for j in lo...hi {
                let w = weights[abs(j - i)]
                sum += values[j] * w
                weightSum += w
            }
            result[i] = weightSum > 0 ? sum / weightSum : values[i]
        }
        return result
    }
}
