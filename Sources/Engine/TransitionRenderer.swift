import Foundation
import CoreGraphics
import CoreImage

// =====================================================================
// TransitionRenderer: クリップ間のトランジションと、クリップのイン/アウト アニメーション
// どちらもキャンバス大(余白は透明でもよい)の画像を受け取り、キャンバス大の画像を返す。
// VideoCompositor から毎フレーム呼ばれるので、画像の生成は行わず変換だけを積む。
// =====================================================================

enum TransitionRenderer {

    // MARK: - トランジション

    /// outgoing(終わるクリップ)から incoming(始まるクリップ)へ progress(0...1)だけ進んだフレーム。
    /// 結果は不透明(黒の上に合成済み)でキャンバスに切り抜かれている。
    static func blend(outgoing: CIImage,
                      incoming: CIImage,
                      type: TransitionType,
                      progress: Double,
                      canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let p = GeometryMath.clamp(progress, 0, 1)
        let black = CIImage(color: CIColor.black).cropped(to: canvas)
        let w = canvasSize.width
        let h = canvasSize.height

        func over(_ top: CIImage, _ bottom: CIImage) -> CIImage {
            top.composited(over: bottom).cropped(to: canvas)
        }
        func crossfade(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
            if t <= 0.001 { return a }
            if t >= 0.999 { return b }
            return a.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: b,
                kCIInputTimeKey: NSNumber(value: t)
            ]).cropped(to: canvas)
        }

        switch type {
        case .none:
            return over(p < 0.5 ? outgoing : incoming, black)

        case .dissolve:
            return over(crossfade(outgoing, incoming, GeometryMath.smoothstep(p)), black)

        case .fadeBlack, .fadeWhite:
            let background: CIImage = type == .fadeBlack
                ? black
                : CIImage(color: CIColor.white).cropped(to: canvas)
            if p < 0.5 {
                let alpha = 1 - GeometryMath.smoothstep(p * 2)
                return over(GeometryMath.withAlpha(outgoing, alpha), background)
            } else {
                let alpha = GeometryMath.smoothstep((p - 0.5) * 2)
                return over(GeometryMath.withAlpha(incoming, alpha), background)
            }

        case .slideLeft, .slideRight, .slideUp, .slideDown:
            let e = CGFloat(GeometryMath.easeInOutCubic(p))
            var outShift = CGPoint.zero
            var inShift = CGPoint.zero
            switch type {
            case .slideLeft:
                outShift = CGPoint(x: -e * w, y: 0)
                inShift = CGPoint(x: (1 - e) * w, y: 0)
            case .slideRight:
                outShift = CGPoint(x: e * w, y: 0)
                inShift = CGPoint(x: -(1 - e) * w, y: 0)
            case .slideUp:
                // 上へ: 終わるクリップは上に抜け、次は下から入る(CoreImage は y 上向き)
                outShift = CGPoint(x: 0, y: e * h)
                inShift = CGPoint(x: 0, y: -(1 - e) * h)
            default:
                outShift = CGPoint(x: 0, y: -e * h)
                inShift = CGPoint(x: 0, y: (1 - e) * h)
            }
            let movedOut = outgoing.transformed(by: CGAffineTransform(translationX: outShift.x, y: outShift.y))
            let movedIn = incoming.transformed(by: CGAffineTransform(translationX: inShift.x, y: inShift.y))
            return over(movedIn, over(movedOut, black))

        case .zoomIn, .zoomOut:
            let e = GeometryMath.easeInOutCubic(p)
            let outScale: CGFloat
            let inScale: CGFloat
            if type == .zoomIn {
                outScale = CGFloat(1 + 0.25 * e)
                inScale = CGFloat(0.8 + 0.2 * e)
            } else {
                outScale = CGFloat(1 - 0.2 * e)
                inScale = CGFloat(1.25 - 0.25 * e)
            }
            let scaledOut = GeometryMath.scaledAboutCenter(outgoing, scale: outScale).cropped(to: canvas)
            let scaledIn = GeometryMath.scaledAboutCenter(incoming, scale: inScale).cropped(to: canvas)
            let mixed = crossfade(over(scaledOut, black), over(scaledIn, black), GeometryMath.smoothstep(p))
            return over(mixed, black)

        case .wipeLeft, .wipeRight:
            let soft = max(2, w * 0.06)
            let e = CGFloat(GeometryMath.easeInOutCubic(p))
            let mask: CIImage?
            if type == .wipeLeft {
                // 右端から現れて左へ進む(境界の右側が incoming)
                let edge = (w + soft / 2) - e * (w + soft)
                mask = linearGradient(from: CGPoint(x: edge - soft / 2, y: 0), color0: CIColor.black,
                                      to: CGPoint(x: edge + soft / 2, y: 0), color1: CIColor.white,
                                      canvas: canvas)
            } else {
                // 左端から現れて右へ進む(境界の左側が incoming)
                let edge = -soft / 2 + e * (w + soft)
                mask = linearGradient(from: CGPoint(x: edge - soft / 2, y: 0), color0: CIColor.white,
                                      to: CGPoint(x: edge + soft / 2, y: 0), color1: CIColor.black,
                                      canvas: canvas)
            }
            guard let mask else { return over(crossfade(outgoing, incoming, p), black) }
            let blended = over(incoming, black).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: over(outgoing, black),
                kCIInputMaskImageKey: mask
            ])
            return blended.cropped(to: canvas)

        case .blur:
            let sigma = Double(min(w, h)) * 0.05 * sin(Double.pi * p)
            let blurredOut = GeometryMath.blurred(over(outgoing, black), sigma: sigma)
            let blurredIn = GeometryMath.blurred(over(incoming, black), sigma: sigma)
            return over(crossfade(blurredOut, blurredIn, GeometryMath.smoothstep(p)), black)

        default:
            return extended(outgoing: over(outgoing, black), incoming: over(incoming, black),
                            type: type, p: p, canvas: canvas)
        }
    }

    /// 追加の種類(A・B は黒の上に合成済みの不透明な画像)
    private static func extended(outgoing a: CIImage, incoming b: CIImage, type: TransitionType,
                                 p: Double, canvas: CGRect) -> CIImage {
        let w = canvas.width
        let h = canvas.height
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let e = CGFloat(GeometryMath.easeInOutCubic(p))
        /// 0 → 1 → 0(真ん中でいちばん強い)
        let k = sin(Double.pi * p)
        let black = CIImage(color: CIColor.black).cropped(to: canvas)

        func over(_ top: CIImage, _ bottom: CIImage) -> CIImage {
            top.composited(over: bottom).cropped(to: canvas)
        }
        func crossfade(_ x: CIImage, _ y: CIImage, _ t: Double) -> CIImage {
            if t <= 0.001 { return x }
            if t >= 0.999 { return y }
            return x.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: y,
                kCIInputTimeKey: NSNumber(value: t)
            ]).cropped(to: canvas)
        }
        /// mask の白い所が top、黒い所が bottom
        func masked(_ top: CIImage, _ bottom: CIImage, _ mask: CIImage?) -> CIImage {
            guard let mask else { return crossfade(bottom, top, p) }
            return top.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: bottom,
                kCIInputMaskImageKey: mask
            ]).cropped(to: canvas)
        }
        func circleMask(radius: CGFloat, soft: CGFloat) -> CIImage? {
            guard let filter = CIFilter(name: "CIRadialGradient") else { return nil }
            filter.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
            filter.setValue(max(0, radius - soft), forKey: "inputRadius0")
            filter.setValue(max(0.5, radius), forKey: "inputRadius1")
            filter.setValue(CIColor.white, forKey: "inputColor0")
            filter.setValue(CIColor.black, forKey: "inputColor1")
            return filter.outputImage?.cropped(to: canvas)
        }
        func rectMask(_ rect: CGRect) -> CIImage {
            CIImage(color: CIColor.white).cropped(to: rect.intersection(canvas)).composited(over: black).cropped(to: canvas)
        }
        let extent = CIVector(cgRect: canvas)
        let maxRadius = hypot(w, h) / 2

        switch type {
        case .wipeUp, .wipeDown:
            let soft = max(2, h * 0.06)
            let mask: CIImage?
            if type == .wipeUp {
                // 下から現れて上へ(CoreImage は y 上向き)
                let edge = -soft / 2 + e * (h + soft)
                mask = linearGradient(from: CGPoint(x: 0, y: edge - soft / 2), color0: CIColor.white,
                                      to: CGPoint(x: 0, y: edge + soft / 2), color1: CIColor.black, canvas: canvas)
            } else {
                let edge = (h + soft / 2) - e * (h + soft)
                mask = linearGradient(from: CGPoint(x: 0, y: edge - soft / 2), color0: CIColor.black,
                                      to: CGPoint(x: 0, y: edge + soft / 2), color1: CIColor.white, canvas: canvas)
            }
            return masked(b, a, mask)

        case .coverLeft, .coverRight:
            // 終わるクリップはそのまま、次のクリップが上から滑り込む
            let dx = (type == .coverLeft ? 1 : -1) * (1 - e) * w
            return over(b.transformed(by: CGAffineTransform(translationX: dx, y: 0)), a)

        case .irisOpen:
            return masked(b, a, circleMask(radius: e * (maxRadius + 20), soft: max(2, w * 0.03)))

        case .irisClose:
            return masked(a, b, circleMask(radius: (1 - e) * (maxRadius + 20), soft: max(2, w * 0.03)))

        case .doorOpen:
            // 真ん中から左右に開く
            let width = e * w
            return masked(b, a, rectMask(CGRect(x: center.x - width / 2, y: 0, width: width, height: h)))

        case .spin:
            let outImage = GeometryMath.transformed(a, scale: 1 - 0.3 * e, rotationDegrees: Double(90 * e), center: center)
            let inImage = GeometryMath.transformed(b, scale: 0.7 + 0.3 * e, rotationDegrees: Double(-90 * (1 - e)), center: center)
            return over(crossfade(over(outImage, black), over(inImage, black), GeometryMath.smoothstep(p)), black)

        case .swirl:
            let base = crossfade(a, b, GeometryMath.smoothstep(p))
            let swirled = base.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputRadiusKey: NSNumber(value: Double(min(w, h)) * 0.7),
                kCIInputAngleKey: NSNumber(value: k * Double.pi * 3)
            ])
            return over(swirled, black)

        case .zoomBlur:
            let outImage = GeometryMath.scaledAboutCenter(a, scale: 1 + 0.3 * e).cropped(to: canvas)
            let inImage = GeometryMath.scaledAboutCenter(b, scale: 1.3 - 0.3 * e).cropped(to: canvas)
            let base = crossfade(over(outImage, black), over(inImage, black), GeometryMath.smoothstep(p))
            guard k > 0.02 else { return base }
            let blurred = base.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                "inputAmount": NSNumber(value: k * Double(min(w, h)) * 0.08)
            ])
            return over(blurred, black)

        case .whipLeft, .whipRight:
            let sign: CGFloat = type == .whipLeft ? -1 : 1
            let outMoved = a.transformed(by: CGAffineTransform(translationX: sign * e * w, y: 0))
            let inMoved = b.transformed(by: CGAffineTransform(translationX: -sign * (1 - e) * w, y: 0))
            let base = over(inMoved, over(outMoved, black))
            guard k > 0.02 else { return base }
            let blurred = base.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: NSNumber(value: k * Double(w) * 0.12),
                kCIInputAngleKey: NSNumber(value: 0)
            ])
            return over(blurred, black)

        case .flash:
            return a.applyingFilter("CIFlashTransition", parameters: [
                kCIInputTargetImageKey: b,
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputExtentKey: extent,
                kCIInputTimeKey: NSNumber(value: p),
                "inputColor": CIColor(red: 1, green: 0.95, blue: 0.85)
            ]).composited(over: black).cropped(to: canvas)

        case .lightLeak:
            // オレンジの光が左から右へ流れながら切り替わる
            let base = crossfade(a, b, GeometryMath.smoothstep(p))
            guard k > 0.02, let filter = CIFilter(name: "CIRadialGradient") else { return base }
            filter.setValue(CIVector(x: -w * 0.2 + CGFloat(p) * w * 1.4, y: h * 0.6), forKey: "inputCenter")
            filter.setValue(0, forKey: "inputRadius0")
            filter.setValue(max(w, h) * 0.8, forKey: "inputRadius1")
            filter.setValue(CIColor(red: 1, green: 0.55, blue: 0.2, alpha: 1), forKey: "inputColor0")
            filter.setValue(CIColor(red: 1, green: 0.2, blue: 0.1, alpha: 0), forKey: "inputColor1")
            guard let glow = filter.outputImage?.cropped(to: canvas) else { return base }
            return GeometryMath.withAlpha(glow, k).applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: base
            ]).cropped(to: canvas)

        case .glitch:
            // 真ん中で切り替え、色ずれとブロックのずれを重ねる
            let base = crossfade(a, b, GeometryMath.smoothstep((p - 0.4) / 0.2))
            guard k > 0.02 else { return base }
            let jitter: CGFloat = Int(p * 24) % 2 == 0 ? 1 : -1
            let shift = CGFloat(k) * w * 0.025 * jitter
            let red = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]).transformed(by: CGAffineTransform(translationX: shift, y: 0))
            let cyan = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]).transformed(by: CGAffineTransform(translationX: -shift, y: 0))
            let split = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: cyan])
                .cropped(to: canvas)
            // 横の帯を 1 本ずらす
            let bandY = h * CGFloat((Int(p * 24) * 37) % 10) / 10
            let band = split.cropped(to: CGRect(x: 0, y: bandY, width: w, height: h * 0.08))
                .transformed(by: CGAffineTransform(translationX: shift * 3, y: 0))
            return over(band, over(split, black))

        case .pixelate:
            let base = crossfade(a, b, GeometryMath.smoothstep((p - 0.35) / 0.3))
            let scale = max(1, k * Double(min(w, h)) * 0.06)
            guard scale > 1.5 else { return base }
            return base.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputScaleKey: NSNumber(value: scale)
            ]).cropped(to: canvas)

        case .bars:
            return a.applyingFilter("CIBarsSwipeTransition", parameters: [
                kCIInputTargetImageKey: b,
                kCIInputAngleKey: NSNumber(value: Double.pi),
                kCIInputWidthKey: NSNumber(value: Double(w) * 0.1),
                "inputBarOffset": NSNumber(value: 10),
                kCIInputTimeKey: NSNumber(value: p)
            ]).composited(over: black).cropped(to: canvas)

        case .pageCurl:
            let shading = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85)).cropped(to: canvas)
            return a.applyingFilter("CIPageCurlTransition", parameters: [
                kCIInputTargetImageKey: b,
                "inputBacksideImage": a,
                "inputShadingImage": shading,
                kCIInputExtentKey: extent,
                kCIInputTimeKey: NSNumber(value: p),
                kCIInputAngleKey: NSNumber(value: Double.pi * 0.85),
                kCIInputRadiusKey: NSNumber(value: Double(min(w, h)) * 0.2)
            ]).composited(over: black).cropped(to: canvas)

        default:
            return crossfade(a, b, GeometryMath.smoothstep(p))
        }
    }

    /// 生成フィルタ(inputImage を持たない)は CIFilter を直接組み立てる
    private static func linearGradient(from p0: CGPoint, color0: CIColor,
                                       to p1: CGPoint, color1: CIColor,
                                       canvas: CGRect) -> CIImage? {
        guard let filter = CIFilter(name: "CILinearGradient") else { return nil }
        filter.setValue(CIVector(x: p0.x, y: p0.y), forKey: "inputPoint0")
        filter.setValue(CIVector(x: p1.x, y: p1.y), forKey: "inputPoint1")
        filter.setValue(color0, forKey: "inputColor0")
        filter.setValue(color1, forKey: "inputColor1")
        return filter.outputImage?.cropped(to: canvas)
    }

    // MARK: - クリップのイン/アウト アニメーション

    /// クリップの画像(キャンバス大、原点 (0,0))にイン/アウトのアニメーションを掛ける。
    /// localTime はクリップの出力上の先頭からの秒、clipDuration はクリップの出力上の長さ。
    static func animate(_ image: CIImage,
                        animation: ClipAnimation,
                        localTime: Double,
                        clipDuration: Double,
                        canvasSize: CGSize) -> CIImage {
        if animation.isIdentity { return image }
        guard clipDuration > 0, localTime.isFinite else { return image }
        let inDuration = min(max(animation.inDuration, 0), clipDuration / 2)
        let outDuration = min(max(animation.outDuration, 0), clipDuration / 2)

        if animation.inType != .none, inDuration > 0.01, localTime < inDuration {
            let u = GeometryMath.clamp(localTime / inDuration, 0, 1)
            return apply(animation.inType, to: image, visibility: u, canvasSize: canvasSize)
        }
        let remaining = clipDuration - localTime
        if animation.outType != .none, outDuration > 0.01, remaining < outDuration {
            let u = GeometryMath.clamp(remaining / outDuration, 0, 1)
            return apply(animation.outType, to: image, visibility: u, canvasSize: canvasSize)
        }
        return image
    }

    /// visibility 0 = まだ見えない(登場前 / 退場後)、1 = 完全に表示
    static func apply(_ type: ClipAnimationType,
                      to image: CIImage,
                      visibility: Double,
                      canvasSize: CGSize) -> CIImage {
        let u = GeometryMath.clamp(visibility, 0, 1)
        if u >= 0.999 || type == .none { return image }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let e = GeometryMath.easeOutCubic(u)
        let w = canvasSize.width
        let h = canvasSize.height

        switch type {
        case .none:
            return image
        case .fade:
            return GeometryMath.withAlpha(image, u)
        case .slideFromLeft:
            let dx = -(1 - CGFloat(e)) * w
            return image.transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: canvas)
        case .slideFromRight:
            let dx = (1 - CGFloat(e)) * w
            return image.transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: canvas)
        case .slideFromBottom:
            let dy = -(1 - CGFloat(e)) * h
            return image.transformed(by: CGAffineTransform(translationX: 0, y: dy)).cropped(to: canvas)
        case .slideFromTop:
            let dy = (1 - CGFloat(e)) * h
            return image.transformed(by: CGAffineTransform(translationX: 0, y: dy)).cropped(to: canvas)
        case .zoomIn:
            let scale = CGFloat(0.6 + 0.4 * e)
            let scaled = GeometryMath.scaledAboutCenter(image, scale: scale).cropped(to: canvas)
            return GeometryMath.withAlpha(scaled, min(1, u * 1.5))
        case .zoomOut:
            let scale = CGFloat(1.4 - 0.4 * e)
            let scaled = GeometryMath.scaledAboutCenter(image, scale: scale).cropped(to: canvas)
            return GeometryMath.withAlpha(scaled, min(1, u * 1.5))
        case .blur:
            let sigma = (1 - e) * Double(min(w, h)) * 0.04
            return GeometryMath.withAlpha(GeometryMath.blurred(image, sigma: sigma), min(1, u * 1.5))
        case .spin:
            let degrees = (1 - e) * 180
            let scale = CGFloat(0.5 + 0.5 * e)
            let center = CGPoint(x: canvas.midX, y: canvas.midY)
            let spun = GeometryMath.transformed(GeometryMath.normalizedToOrigin(image.cropped(to: canvas)),
                                                scale: scale, rotationDegrees: degrees, center: center)
            return GeometryMath.withAlpha(spun.cropped(to: canvas), min(1, u * 1.5))
        }
    }
}
