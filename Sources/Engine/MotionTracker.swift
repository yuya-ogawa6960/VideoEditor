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
// trackDetailed / trackComposited は、どこで見失ったか(lostRanges)と、最初の枠に対する大きさ(scale)も返す。
// redetectFaces(顔モザイク)では、見失ったら打ち切らずに最後まで読み、最後に見えていた所の近くに顔が見つかれば
// そこから追い直す。trackComposited は合成後のコマ(見えているとおりの映像。CompositedFrameReader)で追う
// =====================================================================

enum MotionTracker {
    /// 解析用のコマの長辺(px)
    static let frameDimension = 640
    /// この確からしさ未満は「見失い」とみなす
    static let minimumConfidence: Double = 0.3
    /// 見失いがこの秒数を超えたら打ち切る
    static let lostTimeout: Double = 0.5

    /// 見失っていた区間(start からの相対秒)
    struct LostRange {
        var start: Double
        var end: Double
    }

    /// 追跡の結果(trackDetailed / trackComposited)
    struct Result {
        /// time は start からの相対秒、center は矩形の中心(左上原点)、scale は最初の枠に対する大きさ
        var keyframes: [Keyframe]
        /// 見失っていた区間。顔を探し直して見つかればその時刻で閉じ、最後まで見つからなければ end = 頼んだ範囲の終わり
        var lostRanges: [LostRange]
        /// 最後に追えていた時刻(start からの相対秒)
        var lastTrackedTime: Double
        /// 頼んだ範囲の長さ(秒)
        var span: Double
    }

    /// 1 回の追跡の状態。コマを順に process に渡す(バックグラウンドのスレッドから順番に呼ばれる)
    private final class Session {
        let redetectFaces: Bool
        let initialWidth: Double
        let initialHeight: Double
        var keyframes: [Keyframe] = []
        var lostRanges: [LostRange] = []
        var lowConfidenceSince: Double?
        var consecutiveFailures = 0
        var lastTracked: Double = 0
        var lastBox: NormalizedRect
        /// 見失って顔を探し直している区間の始まり(追えている間は nil)
        var lostSince: Double?
        var searchCount = 0
        var sequence = VNSequenceRequestHandler()
        var request: VNTrackObjectRequest
        let faceRequest = VNDetectFaceRectanglesRequest()

        init(rect initialRect: NormalizedRect, redetectFaces: Bool) {
            var rect = initialRect.clamped()
            if rect.width < 0.02 { rect.width = 0.02 }
            if rect.height < 0.02 { rect.height = 0.02 }
            rect = rect.clamped()
            self.redetectFaces = redetectFaces
            initialWidth = rect.width
            initialHeight = rect.height
            lastBox = rect
            request = Session.makeRequest(rect)
            keyframes.append(MotionTracker.makeKeyframe(time: 0, center: NormalizedPoint(x: rect.midX, y: rect.midY), scale: 1))
        }

        static func makeRequest(_ rect: NormalizedRect) -> VNTrackObjectRequest {
            let observation = VNDetectedObjectObservation(boundingBox: AnalysisFrameReader.visionRect(fromTopLeft: rect))
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            return request
        }

        /// 1 コマ分。false を返すとそこで読むのをやめる
        func process(_ buffer: CVPixelBuffer, relative: Double) -> Bool {
            if lostSince != nil {
                searchFace(in: buffer, relative: relative)
                return true
            }
            do {
                VisionCompute.prepare([request])
                try sequence.perform([request], on: buffer, orientation: .up)
            } catch {
                return failed()
            }
            guard let observation = request.results?.first as? VNDetectedObjectObservation else {
                return failed()
            }
            consecutiveFailures = 0
            let confidence = Double(observation.confidence)
            request.inputObservation = observation
            if confidence >= MotionTracker.minimumConfidence {
                lowConfidenceSince = nil
                let box = AnalysisFrameReader.topLeftRect(fromVision: observation.boundingBox)
                lastBox = box
                lastTracked = relative
                if relative > 0.001 {
                    keyframes.append(MotionTracker.makeKeyframe(time: relative,
                                                                center: NormalizedPoint(x: box.midX, y: box.midY),
                                                                scale: scale(of: box)))
                }
                return true
            }
            if let since = lowConfidenceSince {
                if relative - since > MotionTracker.lostTimeout { return lose() }
            } else {
                lowConfidenceSince = relative
            }
            return true
        }

        /// Vision が続けて失敗したとき(3 回で見失いとする)
        private func failed() -> Bool {
            consecutiveFailures += 1
            if consecutiveFailures < 3 { return true }
            return lose()
        }

        /// 見失った(最後に追えていた時刻から)。顔なら探し直しながら最後まで読み、それ以外はここで打ち切る
        private func lose() -> Bool {
            lostSince = lastTracked
            lowConfidenceSince = nil
            consecutiveFailures = 0
            searchCount = 0
            return redetectFaces
        }

        /// 見失っている間は 2 コマに 1 回顔を探し、最後に見えていた所の近くに顔があれば、そこから追い直す
        /// (離れすぎた顔は別の人とみなして追わない)
        private func searchFace(in buffer: CVPixelBuffer, relative: Double) {
            searchCount += 1
            guard searchCount % 2 == 1 else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
            do {
                VisionCompute.prepare([faceRequest])
                try handler.perform([faceRequest])
            } catch {
                return
            }
            let limit = max(0.25, max(lastBox.width, lastBox.height) * 3)
            var best: NormalizedRect?
            var bestDistance = Double.infinity
            for observation in faceRequest.results ?? [] {
                let face = AnalysisFrameReader.topLeftRect(fromVision: observation.boundingBox)
                guard face.width >= 0.01, face.height >= 0.01 else { continue }
                let dx = face.midX - lastBox.midX
                let dy = face.midY - lastBox.midY
                let distance = sqrt(dx * dx + dy * dy)
                if distance <= limit, distance < bestDistance {
                    best = face
                    bestDistance = distance
                }
            }
            guard let face = best, let since = lostSince else { return }
            lostRanges.append(LostRange(start: since, end: relative))
            lostSince = nil
            request = Session.makeRequest(face)
            sequence = VNSequenceRequestHandler()
            lastBox = face
            lastTracked = relative
            keyframes.append(MotionTracker.makeKeyframe(time: relative,
                                                        center: NormalizedPoint(x: face.midX, y: face.midY),
                                                        scale: scale(of: face)))
        }

        /// 最初の枠に対する大きさ(幅・高さの大きい方の比)
        private func scale(of box: NormalizedRect) -> Double {
            let sw = box.width / max(initialWidth, 0.001)
            let sh = box.height / max(initialHeight, 0.001)
            return min(max(max(sw, sh), 0.2), 5)
        }

        func finish(span: Double) -> Result {
            if let since = lostSince {
                lostRanges.append(LostRange(start: since, end: max(since, span)))
                lostSince = nil
            }
            return Result(keyframes: MotionTracker.thinned(keyframes), lostRanges: lostRanges,
                          lastTrackedTime: lastTracked, span: span)
        }
    }

    static func track(url: URL, start: Double, end: Double, initialRect: NormalizedRect,
                      fps: Double = 15, progress: ((Double) -> Void)?) async throws -> [Keyframe] {
        let result = try await trackDetailed(url: url, start: start, end: end, initialRect: initialRect,
                                             fps: fps, redetectFaces: false, progress: progress)
        guard result.keyframes.count >= 2 else { throw VisionAnalysisError.trackingLost }
        // 今までどおり、大きさは 1 のまま返す
        return result.keyframes.map { key in
            var k = key
            k.scale = 1
            return k
        }
    }

    /// 元素材(url)のコマで追う。どこで見失ったかと大きさも返す(キーフレームが 2 個未満でもエラーにしない)
    static func trackDetailed(url: URL, start: Double, end: Double, initialRect: NormalizedRect,
                              fps: Double = 15, redetectFaces: Bool,
                              progress: ((Double) -> Void)?) async throws -> Result {
        guard end - start > 0.05 else { throw VisionAnalysisError.invalidRange }
        let session = Session(rect: initialRect, redetectFaces: redetectFaces)
        let span = end - start
        try await AnalysisFrameReader.readFrames(url: url, start: start, end: end, fps: fps,
                                                 maxDimension: frameDimension) { buffer, time in
            let relative = max(0, time - start)
            progress?(min(1, relative / span))
            return session.process(buffer, relative: relative)
        }
        try Task.checkCancellation()
        progress?(1)
        return session.finish(span: span)
    }

    /// 合成後のコマ(見えているとおりの映像)で追う。start・end は出力タイムライン上の秒、initialRect はキャンバスの正規化座標。
    /// クリップの拡大・切り抜き・反転・リフレーム・キーフレーム・並べた枠・マルチカメラのアングル・重ねた素材をそのまま追える
    static func trackComposited(built: BuiltComposition, start: Double, end: Double, initialRect: NormalizedRect,
                                fps: Double = 15, redetectFaces: Bool,
                                progress: ((Double) -> Void)?) async throws -> Result {
        guard end - start > 0.05 else { throw VisionAnalysisError.invalidRange }
        let session = Session(rect: initialRect, redetectFaces: redetectFaces)
        let span = end - start
        try await CompositedFrameReader.readFrames(of: built, start: start, end: end, fps: fps) { buffer, time in
            let relative = max(0, time - start)
            progress?(min(1, relative / span))
            return session.process(buffer, relative: relative)
        }
        try Task.checkCancellation()
        progress?(1)
        return session.finish(span: span)
    }

    private static func makeKeyframe(time: Double, center: NormalizedPoint, scale: Double) -> Keyframe {
        var keyframe = Keyframe(time: time)
        keyframe.center = center
        keyframe.scale = scale
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

// MARK: - 顔モザイク

/// 「顔にモザイク」: 再生位置で見えている映像(合成後のコマ。文字・字幕は外す)で顔を探し、顔ごとにモザイクを置いて追いかけさせる。
/// 見えているとおりに探して追うので、クリップの拡大・切り抜き・反転・回転・リフレーム・キーフレーム・並べた枠・
/// マルチカメラのアングル・重ねた素材(V2 以上)に映った顔も、映っている位置で隠せる(元の素材の座標から置き直すと外れていた)。
/// 重ねた素材に映った顔のモザイクは重ねた素材の上にかけ(MosaicStyle.coversOverlays)、その素材の終わりまで追う。
/// V1 の顔は重ねた素材を外した映像で、V1 のクリップの終わりまで追う(B ロールで隠れている間も見失わない)。
/// 顔を見失ったら近くの顔を探し直し、見つからない間は、見失う直前の位置でモザイクを大きくして隠し続ける(黙って外さない)。
/// 見失った時刻は Plan に入れて、画面で知らせる
enum FaceMosaicPlanner {
    struct Plan {
        var mosaics: [TextClip] = []
        /// 顔を見失った区間(タイムラインの秒)
        var lostRanges: [MotionTracker.LostRange] = []

        /// いちばん早く見失った時刻(無ければ nil)
        var firstLostTime: Double? { lostRanges.map(\.start).min() }

        /// 結果のお知らせ(見失った所があれば、その時刻と、モザイクを大きくして残したこと)
        var message: String {
            guard let lost = firstLostTime else {
                return String(localized: "\(mosaics.count) 人の顔にモザイクをかけました")
            }
            let time = EditorTimeFormat.tenths(lost)
            return String(localized: "\(mosaics.count) 人の顔にモザイクをかけました。\(time) から顔を見失ったため、モザイクを大きくして残しています。再生して確かめてください")
        }
    }

    /// 顔より少し大きめに隠す(幅・高さ)
    private static let widthMargin = 1.35
    private static let heightMargin = 1.5
    /// 見失っている間に広げる倍率
    private static let lostGrowth = 1.8

    /// snapshot の time(出力タイムライン上の秒)で見えている顔ごとのモザイク(キーフレームつき)
    static func plan(snapshot: ProjectSnapshot, time: Double,
                     progress: @escaping (Double) -> Void) async throws -> Plan {
        let visible = CompositedFrameReader.videoOnly(snapshot)
        let built = try await CompositedFrameReader.build(visible)
        let total = built.duration.seconds
        var t = max(0, time)
        if total.isFinite, total > 0.1 {
            t = min(t, total - 0.05)
        }
        let image = try await CompositedFrameReader.image(of: built, at: t)
        try Task.checkCancellation()
        let faces = try detectFaces(in: image)
        var plan = Plan()
        guard !faces.isEmpty else { return plan }
        progress(0.05)

        // 再生位置の V1 のクリップの終わり(トランジションの重なりでは後ろのクリップ)
        var mainEnd = (total.isFinite && total > t) ? total : t + 3
        if let placement = CompositionBuilder.timelineLayout(for: snapshot).last(where: { t >= $0.start - 0.0005 && t < $0.end }) {
            mainEnd = placement.end
        }
        // 重ねた素材を外した映像(V1 の顔を追う)。重ねた素材が無ければ同じもの
        var mainOnly: BuiltComposition? = visible.overlays.isEmpty ? built : nil

        for (n, face) in faces.enumerated() {
            try Task.checkCancellation()
            let center = NormalizedPoint(x: face.midX, y: face.midY)
            let covering = coveringOverlay(at: center, time: t, in: visible.overlays)
            let end = covering?.end ?? mainEnd
            var mosaic = TextClip.newMosaic(start: t, duration: max(0.5, end - t))
            mosaic.center = center
            mosaic.widthRatio = min(1, face.width * widthMargin)
            mosaic.mosaic?.heightRatio = min(1, face.height * heightMargin)
            // 重ねた素材に映った顔は重ねた素材の上にかける。V1 の顔は今までどおり V1 だけ(上に重ねた B ロールまでぼかさない)
            mosaic.mosaic?.coversOverlays = covering != nil
            if end - t >= 0.2 {
                let source: BuiltComposition
                if covering == nil {
                    if mainOnly == nil {
                        var main = visible
                        main.overlays = []
                        mainOnly = try await CompositedFrameReader.build(main)
                    }
                    source = mainOnly ?? built
                } else {
                    source = built
                }
                let progressBase = 0.05 + 0.95 * Double(n) / Double(faces.count)
                let share = 0.95 / Double(faces.count)
                var result: MotionTracker.Result
                do {
                    result = try await MotionTracker.trackComposited(built: source, start: t, end: end, initialRect: face,
                                                                    fps: 15, redetectFaces: true,
                                                                    progress: { progress(progressBase + $0 * share) })
                } catch {
                    if error is CancellationError || Task.isCancelled { throw error }
                    // 読めなかったときは、動かないモザイクを大きめに置いて知らせる(黙って成功にしない)
                    result = MotionTracker.Result(keyframes: [],
                                                  lostRanges: [MotionTracker.LostRange(start: 0, end: end - t)],
                                                  lastTrackedTime: 0, span: end - t)
                }
                mosaic.keyframes = keyframes(for: result, start: center)
                for range in result.lostRanges {
                    plan.lostRanges.append(MotionTracker.LostRange(start: t + range.start, end: t + range.end))
                }
            }
            plan.mosaics.append(mosaic)
        }
        plan.lostRanges.sort { $0.start < $1.start }
        return plan
    }

    /// 合成後のコマの顔(キャンバスの正規化座標、左上原点)
    private static func detectFaces(in image: CGImage) throws -> [NormalizedRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        VisionCompute.prepare([request])
        try handler.perform([request])
        var faces: [NormalizedRect] = []
        for observation in request.results ?? [] {
            let rect = AnalysisFrameReader.topLeftRect(fromVision: observation.boundingBox)
            if rect.width >= 0.01, rect.height >= 0.01 {
                faces.append(rect)
            }
        }
        return faces
    }

    /// 再生位置で point に映っている重ねた素材(いちばん小さい枠。全面の B ロールの上のワイプを選ぶ)。無ければ nil(V1 の顔)
    private static func coveringOverlay(at point: NormalizedPoint, time: Double, in overlays: [OverlayClip]) -> OverlayClip? {
        var best: OverlayClip?
        var bestArea = Double.infinity
        for overlay in overlays where overlay.contains(timelineTime: time) && overlay.effectiveOpacity(at: time) > 0.3 {
            let rect = screenRect(of: overlay, at: time)
            guard point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else { continue }
            let area = rect.width * rect.height
            if area < bestArea {
                best = overlay
                bestArea = area
            }
        }
        return best
    }

    /// 重ねた素材の、time に映っている枠(キーフレームがあれば補間値。回転は見ない)
    private static func screenRect(of overlay: OverlayClip, at time: Double) -> NormalizedRect {
        let frame = overlay.frame.movable()
        guard !overlay.keyframes.isEmpty else { return frame }
        let fallback = KeyframeInterpolator.Value(center: NormalizedPoint(x: frame.midX, y: frame.midY),
                                                  scale: 1, rotation: overlay.rotation, opacity: overlay.opacity)
        let value = KeyframeInterpolator.value(at: time - overlay.start, keyframes: overlay.keyframes, fallback: fallback)
        let s = max(0.01, value.scale)
        let w = frame.width * s
        let h = frame.height * s
        return NormalizedRect(x: value.center.x - w / 2, y: value.center.y - h / 2, width: w, height: h)
    }

    /// 追跡の結果をモザイクのキーフレームにする。顔より小さくはしない(顔の端が出ないように)。
    /// 見失っていた区間は、見失う直前の位置で lostGrowth 倍に広げて隠し続ける(見つかったら、その顔へ移る)
    private static func keyframes(for result: MotionTracker.Result, start: NormalizedPoint) -> [Keyframe] {
        var keys: [Keyframe] = []
        let lost = result.lostRanges.sorted { $0.start < $1.start }
        var next = 0
        func hold(_ range: MotionTracker.LostRange) {
            let last = keys.last
            let center = last?.center ?? start
            let scale = min((last?.scale ?? 1) * lostGrowth, 6)
            let grown = max(0, min(range.start + 0.3, max(range.start + 0.01, range.end - 0.05)))
            keys.append(Keyframe(time: grown, center: center, scale: scale, rotation: 0, opacity: 1, easing: .linear))
            if range.end - 0.04 > grown + 0.01 {
                keys.append(Keyframe(time: range.end - 0.04, center: center, scale: scale, rotation: 0, opacity: 1, easing: .linear))
            }
        }
        for key in result.keyframes.sorted(by: { $0.time < $1.time }) {
            while next < lost.count, lost[next].start < key.time - 0.0005 {
                hold(lost[next])
                next += 1
            }
            var k = key
            k.scale = min(max(key.scale, 1), 4)
            k.center = NormalizedPoint(x: min(max(key.center.x, -0.25), 1.25), y: min(max(key.center.y, -0.25), 1.25))
            k.rotation = 0
            k.opacity = 1
            k.easing = .linear
            keys.append(k)
        }
        while next < lost.count {
            hold(lost[next])
            next += 1
        }
        keys.sort { $0.time < $1.time }
        return keys
    }
}
