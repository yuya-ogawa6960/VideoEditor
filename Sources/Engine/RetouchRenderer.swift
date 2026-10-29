import Foundation
import CoreGraphics
import CoreImage
import Vision

// =====================================================================
// RetouchRenderer: レタッチ(ClipRetouch)の描画。
// VideoCompositor.renderLayer から、向き反映済みのソース(画質補正の後、切り抜き・配置の前)に掛ける。
//
// - 顔: VNDetectFaceLandmarksRequest で目・鼻・口・輪郭を探す(長辺 960px に縮めて調べる)。
//   調べるのは 1/30 秒に 1 回まで。位置はクリップごとに指数平滑で追い、ガタつきを抑える
//   (自動リフレームの注目点と同じ考え方)。1 コマ見失っても 0.25 秒は前の位置を使う
// - 顔の形: 目 = CIBumpDistortion、鼻・口角 = CIPinchDistortion、小顔 = 顔の縦の線に向けて
//   横に縮める CIBumpDistortionLinear を、あごまわりのぼかした円で切り抜いて重ねる
// - メイク: 唇の輪郭(外 − 内)をやわらかいマスクにして色を乗せる / 頬にぼかした円で赤みを足す /
//   口の内側を少し明るく・黄みを抜く。形を変える前に掛ける(形の変化に一緒についていく)
// - 体型: VNDetectHumanRectanglesRequest の人物の枠で、スリム = 枠の中心線へ横に縮める、
//   脚長 = 腰より下を縦に少し伸ばす(足先は画面の下にはみ出る)
// どれも控えめな強さにしている。見つからなければ何もしない。描画キュー上でだけ使う
// =====================================================================

final class RetouchRenderer {

    /// 1 つの顔の目印(元画像の座標、CoreImage 左下原点)
    private struct Face {
        var jaw: [CGPoint]
        var leftEye: [CGPoint]
        var rightEye: [CGPoint]
        var nose: [CGPoint]
        var outerLips: [CGPoint]
        var innerLips: [CGPoint]
        var box: CGRect
        var lastSeen: Double
    }

    /// クリップごとの追従の状態
    private struct State {
        var time: Double
        var imageSize: CGSize
        var lastFaceDetect: Double?
        var lastBodyDetect: Double?
        var faces: [Face] = []
        var body: CGRect? = nil
        var bodyLastSeen: Double = 0
    }

    private var states: [UUID: State] = [:]

    /// 調べる間隔(秒)
    private let detectInterval = 1.0 / 30 - 0.002
    /// 1/30 秒あたりの追従の速さ(1 = 平滑なし)
    private let followRate = 0.55

    func reset() {
        states.removeAll()
    }

    /// image(向き反映済みのソース)にレタッチを掛ける。time は出力上の秒
    func apply(_ retouch: ClipRetouch, to image: CIImage, clipID: UUID, time: Double, isStill: Bool) -> CIImage {
        let extent = image.extent
        guard !retouch.isIdentity, !extent.isInfinite, extent.width >= 16, extent.height >= 16,
              extent.width.isFinite, extent.height.isFinite else { return image }
        prune(now: time)

        // シーク(時間が戻る / 大きく飛ぶ)や大きさが変わったときは追い直す
        var state: State
        if let previous = states[clipID], previous.imageSize == extent.size,
           time >= previous.time - 0.0001, time - previous.time < 0.5 {
            state = previous
        } else {
            state = State(time: time, imageSize: extent.size, lastFaceDetect: nil, lastBodyDetect: nil)
        }

        let needFace = retouch.usesFace && Self.due(state.lastFaceDetect, now: time, interval: detectInterval, isStill: isStill)
        let needBody = retouch.usesBody && Self.due(state.lastBodyDetect, now: time, interval: detectInterval, isStill: isStill)
        if needFace || needBody {
            let detected = Self.detect(image, faces: needFace, body: needBody)
            if needFace {
                let alpha = Self.followAlpha(since: state.lastFaceDetect, now: time, rate: followRate)
                state.faces = Self.merge(previous: state.faces, detected: detected.faces, alpha: alpha, time: time)
                state.lastFaceDetect = time
            }
            if needBody {
                let alpha = Self.followAlpha(since: state.lastBodyDetect, now: time, rate: followRate)
                if let found = detected.body {
                    if let old = state.body, alpha < 0.999 {
                        state.body = Self.lerp(old, found, alpha)
                    } else {
                        state.body = found
                    }
                    state.bodyLastSeen = time
                } else if time - state.bodyLastSeen > 0.25 {
                    state.body = nil
                }
                state.lastBodyDetect = time
            }
        }
        state.time = time
        states[clipID] = state

        var out = image
        if retouch.usesFace {
            for face in state.faces {
                out = Self.applyFace(retouch, face: face, to: out, extent: extent)
            }
        }
        if retouch.usesBody, let body = state.body {
            out = Self.applyBody(retouch, body: body, to: out, extent: extent)
        }
        return out.cropped(to: extent)
    }

    // MARK: - 追従

    private static func due(_ last: Double?, now: Double, interval: Double, isStill: Bool) -> Bool {
        guard let last else { return true }
        // 静止画は一度調べれば十分
        if isStill { return false }
        return now - last >= interval
    }

    private static func followAlpha(since last: Double?, now: Double, rate: Double) -> Double {
        guard let last else { return 1 }
        let dt = now - last
        guard dt > 0.0001 else { return 0 }
        return 1 - pow(1 - rate, dt * 30)
    }

    /// 1 秒以上触っていないクリップの状態を手放す
    private func prune(now: Double) {
        guard !states.isEmpty else { return }
        for (key, value) in states where abs(now - value.time) > 1 {
            states[key] = nil
        }
    }

    /// 前の顔と見つけた顔を近いもの同士で結び、なめらかに寄せる
    private static func merge(previous: [Face], detected: [Face], alpha: Double, time: Double) -> [Face] {
        var used = Set<Int>()
        var result: [Face] = []
        for var face in detected {
            var bestIndex: Int? = nil
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (i, old) in previous.enumerated() where !used.contains(i) {
                let d = hypot(old.box.midX - face.box.midX, old.box.midY - face.box.midY)
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = i
                }
            }
            if let i = bestIndex, bestDistance < max(face.box.width, 1) * 0.6 {
                used.insert(i)
                let old = previous[i]
                face.jaw = lerp(old.jaw, face.jaw, alpha)
                face.leftEye = lerp(old.leftEye, face.leftEye, alpha)
                face.rightEye = lerp(old.rightEye, face.rightEye, alpha)
                face.nose = lerp(old.nose, face.nose, alpha)
                face.outerLips = lerp(old.outerLips, face.outerLips, alpha)
                face.innerLips = lerp(old.innerLips, face.innerLips, alpha)
                face.box = lerp(old.box, face.box, alpha)
            }
            face.lastSeen = time
            result.append(face)
        }
        // 見失った顔は少しの間だけ残す(1 コマ見失ってもちらつかない)
        for (i, old) in previous.enumerated() where !used.contains(i) && time - old.lastSeen < 0.25 {
            result.append(old)
        }
        return result
    }

    private static func lerp(_ a: [CGPoint], _ b: [CGPoint], _ t: Double) -> [CGPoint] {
        guard a.count == b.count, !a.isEmpty else { return b }
        let k = CGFloat(t)
        return zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * k, y: $0.y + ($1.y - $0.y) * k) }
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        let k = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * k,
                      y: a.minY + (b.minY - a.minY) * k,
                      width: a.width + (b.width - a.width) * k,
                      height: a.height + (b.height - a.height) * k)
    }

    // MARK: - 検出

    /// 顔の目印と人物の枠を探す(縮めた画像で調べ、元画像の座標に戻す)
    private static func detect(_ image: CIImage, faces wantFaces: Bool, body wantBody: Bool) -> (faces: [Face], body: CGRect?) {
        let extent = image.extent
        let scale = min(1, 960 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        let smallSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        guard smallSize.width >= 8, smallSize.height >= 8 else { return ([], nil) }

        func back(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x / scale + extent.minX, y: p.y / scale + extent.minY)
        }
        func backRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * extent.width + extent.minX,
                   y: normalized.minY * extent.height + extent.minY,
                   width: normalized.width * extent.width,
                   height: normalized.height * extent.height)
        }

        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanRectanglesRequest()
        bodyRequest.upperBodyOnly = false
        var requests: [VNRequest] = []
        if wantFaces { requests.append(faceRequest) }
        if wantBody { requests.append(bodyRequest) }
        VisionCompute.prepare(requests)
        let handler = VNImageRequestHandler(ciImage: small, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            return ([], nil)
        }

        var faces: [Face] = []
        if wantFaces {
            let minSide = min(extent.width, extent.height)
            let observations = (faceRequest.results ?? [])
                .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            for observation in observations.prefix(4) {
                guard let landmarks = observation.landmarks else { continue }
                let box = backRect(observation.boundingBox)
                // 小さすぎる顔は目印がぶれやすいので触らない
                guard box.width >= max(24, minSide * 0.04) else { continue }
                func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                    guard let region else { return [] }
                    return region.pointsInImage(imageSize: smallSize).map(back)
                }
                faces.append(Face(jaw: points(landmarks.faceContour),
                                  leftEye: points(landmarks.leftEye),
                                  rightEye: points(landmarks.rightEye),
                                  nose: points(landmarks.nose),
                                  outerLips: points(landmarks.outerLips),
                                  innerLips: points(landmarks.innerLips),
                                  box: box,
                                  lastSeen: 0))
            }
        }

        var body: CGRect? = nil
        if wantBody {
            // いちばん大きく写っている人
            let best = (bodyRequest.results ?? [])
                .max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            if let best, best.boundingBox.width > 0.05, best.boundingBox.height > 0.15 {
                body = backRect(best.boundingBox)
            }
        }
        return (faces, body)
    }

    // MARK: - 顔の向き

    /// 顔の横方向 u(画面の右寄り)と上方向 v、目の中点 origin、顔の幅
    private struct FaceAxes {
        let u: CGVector
        let v: CGVector
        let origin: CGPoint
        let width: CGFloat

        func pu(_ p: CGPoint) -> CGFloat { (p.x - origin.x) * u.dx + (p.y - origin.y) * u.dy }
        func pv(_ p: CGPoint) -> CGFloat { (p.x - origin.x) * v.dx + (p.y - origin.y) * v.dy }
        func point(u a: CGFloat, v b: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + u.dx * a + v.dx * b, y: origin.y + u.dy * a + v.dy * b)
        }
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for p in points {
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }

    private static func axes(for face: Face) -> FaceAxes {
        let box = face.box
        var u = CGVector(dx: 1, dy: 0)
        var origin = CGPoint(x: box.midX, y: box.minY + box.height * 0.62)
        if let l = centroid(face.leftEye), let r = centroid(face.rightEye) {
            var dx = r.x - l.x
            var dy = r.y - l.y
            if dx < 0 {
                dx = -dx
                dy = -dy
            }
            let length = hypot(dx, dy)
            if length > 1 {
                u = CGVector(dx: dx / length, dy: dy / length)
            }
            origin = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        }
        var v = CGVector(dx: -u.dy, dy: u.dx)
        // 口から目に向かう向きを「上」にそろえる
        if let mouth = centroid(face.outerLips) {
            let dot = (origin.x - mouth.x) * v.dx + (origin.y - mouth.y) * v.dy
            if dot < 0 { v = CGVector(dx: -v.dx, dy: -v.dy) }
        }
        var width = box.width * 0.9
        if face.jaw.count >= 3 {
            let projections = face.jaw.map { ($0.x - origin.x) * u.dx + ($0.y - origin.y) * u.dy }
            if let lo = projections.min(), let hi = projections.max(), hi - lo > 4 {
                width = hi - lo
            }
        }
        return FaceAxes(u: u, v: v, origin: origin, width: max(width, 8))
    }

    // MARK: - 顔

    private static func applyFace(_ retouch: ClipRetouch, face: Face, to image: CIImage, extent: CGRect) -> CIImage {
        let ax = axes(for: face)
        var out = image

        // ---- メイク(形を変える前)
        if retouch.lip > 0.001, face.outerLips.count >= 3 {
            var polygons = [face.outerLips]
            if face.innerLips.count >= 3 { polygons.append(face.innerLips) }
            if let mask = polygonMask(polygons, evenOdd: true, feather: max(1, ax.width * 0.012), extent: extent) {
                let color = ciColor(hex: retouch.lipColorHex)
                let colorLayer = CIImage(color: color).cropped(to: mask.extent)
                let tinted = colorLayer.applyingFilter("CIColorBlendMode", parameters: [
                    kCIInputBackgroundImageKey: out
                ]).cropped(to: mask.extent)
                out = blend(tinted, over: out, mask: mask, amount: retouch.lip * 0.7, extent: extent)
            }
        }

        if retouch.blush > 0.001, let mouth = centroid(face.outerLips) {
            let mouthV = ax.pv(mouth)
            let radius = ax.width * 0.17
            let pink = CIImage(color: CIColor(red: 1, green: 0.70, blue: 0.74))
            for side in [CGFloat(-1), CGFloat(1)] {
                let center = ax.point(u: side * ax.width * 0.28, v: mouthV * 0.5)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    .intersection(extent)
                guard rect.width >= 2, rect.height >= 2 else { continue }
                let mask = radialMask(center: center, inner: 0, outer: radius, rect: rect)
                let tinted = pink.cropped(to: rect).applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: out
                ]).cropped(to: rect)
                out = blend(tinted, over: out, mask: mask, amount: retouch.blush * 0.55, extent: extent)
            }
        }

        if retouch.whitenTeeth > 0.001, face.innerLips.count >= 3, face.outerLips.count >= 3 {
            let openness = spanAlong(face.innerLips) { ax.pv($0) }
            let mouthWidth = spanAlong(face.outerLips) { ax.pu($0) }
            // 口が開いているときだけ
            if mouthWidth > 4, openness > mouthWidth * 0.08,
               let mask = polygonMask([face.innerLips], evenOdd: false, feather: max(1, ax.width * 0.006), extent: extent) {
                let t = retouch.whitenTeeth
                let brighter = out.cropped(to: mask.extent)
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: NSNumber(value: 1 - 0.55 * t),
                        kCIInputBrightnessKey: NSNumber(value: 0),
                        kCIInputContrastKey: NSNumber(value: 1)
                    ])
                    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: NSNumber(value: 0.35 * t)])
                    .cropped(to: mask.extent)
                out = blend(brighter, over: out, mask: mask, amount: 0.9, extent: extent)
            }
        }

        // ---- 顔の形
        if retouch.slimFace > 0.001, face.jaw.count >= 3 {
            let us = face.jaw.map { ax.pu($0) }
            let vs = face.jaw.map { ax.pv($0) }
            if let uLo = us.min(), let uHi = us.max(), let vLo = vs.min() {
                let centerU = (uLo + uHi) / 2
                let lineCenter = ax.point(u: centerU, v: vLo * 0.5)
                let angle = atan2(ax.v.dy, ax.v.dx)
                let warped = distort(out, "CIBumpDistortionLinear", [
                    kCIInputCenterKey: CIVector(x: lineCenter.x, y: lineCenter.y),
                    kCIInputRadiusKey: NSNumber(value: Double(ax.width * 0.75)),
                    kCIInputAngleKey: NSNumber(value: Double(angle)),
                    kCIInputScaleKey: NSNumber(value: -0.32 * retouch.slimFace)
                ], extent: extent)
                // あごまわりだけ(目より上はほとんど変えない)
                let maskCenter = ax.point(u: centerU, v: vLo * 0.55)
                let outer = ax.width * 0.95
                let rect = CGRect(x: maskCenter.x - outer, y: maskCenter.y - outer, width: outer * 2, height: outer * 2)
                    .intersection(extent)
                if rect.width >= 2, rect.height >= 2 {
                    let mask = radialMask(center: maskCenter, inner: ax.width * 0.5, outer: outer, rect: rect)
                    out = blend(warped.cropped(to: rect), over: out, mask: mask, amount: 1, extent: extent)
                }
            }
        }

        if retouch.bigEyes > 0.001 {
            for eye in [face.leftEye, face.rightEye] where eye.count >= 3 {
                guard let center = centroid(eye) else { continue }
                let eyeWidth = spanAlong(eye) { ax.pu($0) }
                let radius = max(eyeWidth * 1.15, 4)
                out = distort(out, "CIBumpDistortion", [
                    kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                    kCIInputRadiusKey: NSNumber(value: Double(radius)),
                    kCIInputScaleKey: NSNumber(value: 0.3 * retouch.bigEyes)
                ], extent: extent)
            }
        }

        if retouch.slimNose > 0.001, face.nose.count >= 3, let center = centroid(face.nose) {
            let noseWidth = spanAlong(face.nose) { ax.pu($0) }
            let radius = max(noseWidth * 0.85, 4)
            out = distort(out, "CIPinchDistortion", [
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputRadiusKey: NSNumber(value: Double(radius)),
                kCIInputScaleKey: NSNumber(value: 0.35 * retouch.slimNose)
            ], extent: extent)
        }

        if retouch.smile > 0.001, face.outerLips.count >= 3 {
            let projections = face.outerLips.map { ax.pu($0) }
            if let loIndex = projections.indices.min(by: { projections[$0] < projections[$1] }),
               let hiIndex = projections.indices.max(by: { projections[$0] < projections[$1] }) {
                let mouthWidth = projections[hiIndex] - projections[loIndex]
                if mouthWidth > 4 {
                    for (index, side) in [(loIndex, CGFloat(-1)), (hiIndex, CGFloat(1))] {
                        let corner = face.outerLips[index]
                        // 口角の少し上(と外側)に向けて寄せる → 口角が上がる
                        let center = CGPoint(x: corner.x + ax.v.dx * mouthWidth * 0.12 + ax.u.dx * side * mouthWidth * 0.03,
                                             y: corner.y + ax.v.dy * mouthWidth * 0.12 + ax.u.dy * side * mouthWidth * 0.03)
                        out = distort(out, "CIPinchDistortion", [
                            kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                            kCIInputRadiusKey: NSNumber(value: Double(max(mouthWidth * 0.3, 4))),
                            kCIInputScaleKey: NSNumber(value: 0.35 * retouch.smile)
                        ], extent: extent)
                    }
                }
            }
        }
        return out
    }

    // MARK: - 体型

    private static func applyBody(_ retouch: ClipRetouch, body: CGRect, to image: CIImage, extent: CGRect) -> CIImage {
        var out = image
        if retouch.slimBody > 0.001, body.width >= 8 {
            out = distort(out, "CIBumpDistortionLinear", [
                kCIInputCenterKey: CIVector(x: body.midX, y: body.midY),
                kCIInputRadiusKey: NSNumber(value: Double(body.width * 0.8)),
                kCIInputAngleKey: NSNumber(value: Double.pi / 2),
                kCIInputScaleKey: NSNumber(value: -0.28 * retouch.slimBody)
            ], extent: extent)
        }
        // 全身がある程度の大きさで写っているときだけ
        if retouch.longLegs > 0.001, body.height >= extent.height * 0.35 {
            let hipY = max(extent.minY + 2, min(extent.maxY - 2, body.minY + body.height * 0.47))
            let stretch = 1 + 0.1 * CGFloat(retouch.longLegs)
            // 腰の線を動かさずに、下を縦に伸ばす
            let transform = CGAffineTransform(translationX: 0, y: -hipY)
                .concatenating(CGAffineTransform(scaleX: 1, y: stretch))
                .concatenating(CGAffineTransform(translationX: 0, y: hipY))
            let lowerRect = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: hipY - extent.minY + 1)
            let upperRect = CGRect(x: extent.minX, y: hipY, width: extent.width, height: extent.maxY - hipY)
            let lower = out.transformed(by: transform).cropped(to: lowerRect)
            let upper = out.cropped(to: upperRect)
            out = upper.composited(over: lower).cropped(to: extent)
        }
        return out
    }

    // MARK: - 部品

    private static func distort(_ image: CIImage, _ name: String, _ parameters: [String: Any], extent: CGRect) -> CIImage {
        image.clampedToExtent().applyingFilter(name, parameters: parameters).cropped(to: extent)
    }

    /// layer を mask(白 = 使う)× amount で image に重ねる
    private static func blend(_ layer: CIImage, over image: CIImage, mask: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let a = GeometryMath.clamp(amount, 0, 1)
        guard a > 0.001 else { return image }
        let scaledMask = GeometryMath.withAlpha(mask, a)
        return layer.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: scaledMask
        ]).cropped(to: extent)
    }

    /// 中心が白、外へなだらかに黒になる円(rect の範囲だけ)
    private static func radialMask(center: CGPoint, inner: CGFloat, outer: CGFloat, rect: CGRect) -> CIImage {
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: center.x, y: center.y),
            "inputRadius0": NSNumber(value: Double(max(0, inner))),
            "inputRadius1": NSNumber(value: Double(max(inner + 1, outer))),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])?.outputImage ?? CIImage(color: CIColor.black)
        return gradient.cropped(to: rect)
    }

    /// 多角形を白く塗ったマスク(まわりは黒、ふちを feather でぼかす)。点の範囲だけの小さな画像
    private static func polygonMask(_ polygons: [[CGPoint]], evenOdd: Bool, feather: CGFloat, extent: CGRect) -> CIImage? {
        let all = polygons.flatMap { $0 }
        guard let first = all.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in all {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        let margin = feather * 3 + 2
        let bounds = CGRect(x: minX - margin, y: minY - margin,
                            width: maxX - minX + margin * 2, height: maxY - minY + margin * 2)
            .intersection(extent)
            .integral
        guard !bounds.isNull, bounds.width >= 2, bounds.height >= 2,
              bounds.width * bounds.height < 4_000_000 else { return nil }
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGMutablePath()
        for polygon in polygons where polygon.count >= 3 {
            path.addLines(between: polygon.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) })
            path.closeSubpath()
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: evenOdd ? .evenOdd : .winding)
        guard let cgImage = context.makeImage() else { return nil }
        var mask = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        if feather > 0.3 {
            mask = GeometryMath.blurred(mask, sigma: Double(feather))
        }
        return mask
    }

    /// 点を f で 1 次元に並べたときの幅
    private static func spanAlong(_ points: [CGPoint], _ f: (CGPoint) -> CGFloat) -> CGFloat {
        let values = points.map(f)
        guard let lo = values.min(), let hi = values.max() else { return 0 }
        return hi - lo
    }

    private static func ciColor(hex: String) -> CIColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else {
            return CIColor(red: 0.78, green: 0.2, blue: 0.29)
        }
        return CIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255)
    }
}
