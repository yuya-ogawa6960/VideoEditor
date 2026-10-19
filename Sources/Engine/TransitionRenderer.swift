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
