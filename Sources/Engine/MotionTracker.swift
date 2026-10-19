import Foundation
import AVFoundation
import CoreVideo
import Vision

// =====================================================================
// 物体トラッキング(テキスト・オーバーレイを被写体に追従させる)。
//
// VNTrackObjectRequest + VNSequenceRequestHandler を、AnalysisFrameReader が渡す
// 正立・縮小済みのコマ(約 fps コマ/秒)に順にかける。
// - initialRect は `start`(元素材上の秒)時点の対象の矩形(左上原点・正規化)
// - 戻り値のキーフレームは time が `start` からの相対秒、center が矩形の中心(左上原点)、
//   scale = 1、rotation = 0、opacity = 1、easing = .linear
// - 確からしさが 0.3 未満の状態が 0.5 秒を超えたらそこで打ち切る(以降は最後の位置を保つ)
// - progress は 0...1 をバックグラウンドのスレッドから呼ぶ
// =====================================================================

enum MotionTracker {
    /// 解析用のコマの長辺(px)
    static let frameDimension = 640
    /// この確からしさ未満は「見失い」とみなす
    static let minimumConfidence: Double = 0.3
    /// 見失いがこの秒数を超えたら打ち切る
    static let lostTimeout: Double = 0.5

    private final class State {
        var keyframes: [Keyframe] = []
        var lowConfidenceSince: Double?
        var consecutiveFailures = 0
        var lastTime: Double = 0
        let sequence = VNSequenceRequestHandler()
        let request: VNTrackObjectRequest
        init(initial: VNDetectedObjectObservation) {
            request = VNTrackObjectRequest(detectedObjectObservation: initial)
            request.trackingLevel = .accurate
        }
    }

    static func track(url: URL, start: Double, end: Double, initialRect: NormalizedRect,
                      fps: Double = 15, progress: ((Double) -> Void)?) async throws -> [Keyframe] {
        guard end - start > 0.05 else { throw VisionAnalysisError.invalidRange }
        var rect = initialRect.clamped()
        if rect.width < 0.02 { rect.width = 0.02 }
        if rect.height < 0.02 { rect.height = 0.02 }
        rect = rect.clamped()

        let initialObservation = VNDetectedObjectObservation(boundingBox: AnalysisFrameReader.visionRect(fromTopLeft: rect))
        let state = State(initial: initialObservation)
        let initialCenter = NormalizedPoint(x: rect.midX, y: rect.midY)
        state.keyframes.append(makeKeyframe(time: 0, center: initialCenter))
        let span = end - start

        try await AnalysisFrameReader.readFrames(url: url, start: start, end: end, fps: fps,
                                                 maxDimension: frameDimension) { buffer, time in
            let relative = max(0, time - start)
            state.lastTime = relative
            progress?(min(1, relative / span))
            do {
                try state.sequence.perform([state.request], on: buffer, orientation: .up)
            } catch {
                state.consecutiveFailures += 1
                return state.consecutiveFailures < 3
            }
            guard let observation = state.request.results?.first else {
                state.consecutiveFailures += 1
                return state.consecutiveFailures < 3
            }
            state.consecutiveFailures = 0
            let confidence = Double(observation.confidence)
            state.request.inputObservation = observation
            if confidence >= minimumConfidence {
                state.lowConfidenceSince = nil
                let box = AnalysisFrameReader.topLeftRect(fromVision: observation.boundingBox)
                let center = NormalizedPoint(x: box.midX, y: box.midY)
                if relative > 0.001 {
                    state.keyframes.append(makeKeyframe(time: relative, center: center))
                }
                return true
            }
            if let since = state.lowConfidenceSince {
                if relative - since > lostTimeout { return false }
            } else {
                state.lowConfidenceSince = relative
            }
            return true
        }
        try Task.checkCancellation()

        guard state.keyframes.count >= 2 else { throw VisionAnalysisError.trackingLost }
        progress?(1)
        return thinned(state.keyframes)
    }

    private static func makeKeyframe(time: Double, center: NormalizedPoint) -> Keyframe {
        var keyframe = Keyframe(time: time)
        keyframe.center = center
        keyframe.scale = 1
        keyframe.rotation = 0
        keyframe.opacity = 1
        keyframe.easing = .linear
        return keyframe
    }

    /// ほとんど動いていないキーフレームを間引く(最初と最後は残す)
    private static func thinned(_ keyframes: [Keyframe]) -> [Keyframe] {
        guard keyframes.count > 2 else { return keyframes }
        var result: [Keyframe] = [keyframes[0]]
        var lastKept = keyframes[0]
        for i in 1..<(keyframes.count - 1) {
            let k = keyframes[i]
            let dx = k.center.x - lastKept.center.x
            let dy = k.center.y - lastKept.center.y
            let moved = sqrt(dx * dx + dy * dy)
            if moved >= 0.004 || k.time - lastKept.time >= 0.5 {
                result.append(k)
                lastKept = k
            }
        }
        result.append(keyframes[keyframes.count - 1])
        return result
    }
}
