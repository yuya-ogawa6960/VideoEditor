import Foundation
import CoreGraphics

// =====================================================================
// モザイク / ぼかし。
// テキストレイヤー(TextClip)の 1 種類として持つ(mosaic が nil でなければモザイク)。
// 時間・位置(center)・大きさ(scale)・キーフレーム・トラッキング・タイムライン・保存は
// テキストの仕組みをそのまま使う。幅は widthRatio(画面幅に対する比率)、高さは heightRatio。
// =====================================================================

enum MosaicKind: String, CaseIterable, Identifiable {
    /// 四角いブロックのモザイク
    case pixelate
    /// ぼかし
    case blur

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pixelate: return String(localized: "モザイク")
        case .blur: return String(localized: "ぼかし")
        }
    }
}

enum MosaicShape: String, CaseIterable, Identifiable {
    case ellipse
    case rectangle

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ellipse: return String(localized: "楕円")
        case .rectangle: return String(localized: "四角")
        }
    }
}

struct MosaicStyle: Equatable {
    var kind: MosaicKind = .pixelate
    var shape: MosaicShape = .ellipse
    /// 強さ 0...1(モザイクの粗さ / ぼかしの強さ)
    var strength: Double = 0.5
    /// 高さ(画面の高さに対する比率)。幅は TextClip.widthRatio
    var heightRatio: Double = 0.22
}

extension TextClip {
    var isMosaic: Bool { mosaic != nil }

    /// 再生位置 time のモザイクの範囲(左上原点、size の座標。回転前)。キーフレームを反映する
    func mosaicRect(at time: Double, in size: CGSize) -> CGRect? {
        mosaicPlacement(at: time, in: size)?.rect
    }

    /// 再生位置 time のモザイクの範囲と回転(度、時計回りが正)
    func mosaicPlacement(at time: Double, in size: CGSize) -> (rect: CGRect, rotation: Double)? {
        guard let mosaic else { return nil }
        var c = center
        var s = scale
        var r = rotation
        if !keyframes.isEmpty {
            let fallback = KeyframeInterpolator.Value(center: center, scale: scale,
                                                      rotation: rotation, opacity: opacity)
            let v = KeyframeInterpolator.value(at: time - start, keyframes: keyframes, fallback: fallback)
            c = v.center
            s = v.scale
            r = v.rotation
        }
        let factor: CGFloat = CGFloat(max(0.05, s))
        let w: CGFloat = CGFloat(max(0.02, widthRatio)) * size.width * factor
        let h: CGFloat = CGFloat(max(0.02, mosaic.heightRatio)) * size.height * factor
        let cx: CGFloat = CGFloat(c.x) * size.width
        let cy: CGFloat = CGFloat(c.y) * size.height
        return (CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), r)
    }

    /// 回転したモザイクの範囲が画面(size)からはみ出さないように直す。
    /// 大きすぎるときは縦横比のまま縮め(scale)、はみ出した分は内側へ寄せる(center)。モザイク以外は何もしない
    mutating func keepMosaicInside(_ size: CGSize) {
        guard let mosaic, size.width > 1, size.height > 1 else { return }
        let canvasWidth = Double(size.width)
        let canvasHeight = Double(size.height)
        let angle = rotation.isFinite ? rotation * Double.pi / 180 : 0
        let cosine = abs(cos(angle))
        let sine = abs(sin(angle))
        let factor = max(scale, 0.01)
        let width = max(0.02, widthRatio) * canvasWidth * factor
        let height = max(0.02, mosaic.heightRatio) * canvasHeight * factor
        var boundsWidth = width * cosine + height * sine
        var boundsHeight = width * sine + height * cosine
        let shrink = min(1, canvasWidth / max(boundsWidth, 0.000_001), canvasHeight / max(boundsHeight, 0.000_001))
        if shrink < 1 {
            scale = factor * shrink
            boundsWidth *= shrink
            boundsHeight *= shrink
        }
        let halfX = min(0.5, boundsWidth / 2 / canvasWidth)
        let halfY = min(0.5, boundsHeight / 2 / canvasHeight)
        center = NormalizedPoint(x: min(max(center.x, halfX), 1 - halfX),
                                 y: min(max(center.y, halfY), 1 - halfY))
    }

    /// 新しいモザイク(画面中央、表示 3 秒)
    static func newMosaic(start: Double, duration: Double = 3) -> TextClip {
        var clip = TextClip(text: String(localized: "モザイク"), start: start)
        clip.duration = duration
        clip.widthRatio = 0.3
        clip.mosaic = MosaicStyle()
        return clip
    }
}
