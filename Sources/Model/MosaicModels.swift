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
        case .pixelate: return "モザイク"
        case .blur: return "ぼかし"
        }
    }
}

enum MosaicShape: String, CaseIterable, Identifiable {
    case ellipse
    case rectangle

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ellipse: return "楕円"
        case .rectangle: return "四角"
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

    /// 再生位置 time のモザイクの範囲(左上原点、size の座標)。キーフレームを反映する
    func mosaicRect(at time: Double, in size: CGSize) -> CGRect? {
        guard let mosaic else { return nil }
        var c = center
        var s = scale
        if !keyframes.isEmpty {
            let fallback = KeyframeInterpolator.Value(center: center, scale: scale,
                                                      rotation: rotation, opacity: opacity)
            let v = KeyframeInterpolator.value(at: time - start, keyframes: keyframes, fallback: fallback)
            c = v.center
            s = v.scale
        }
        let factor: CGFloat = CGFloat(max(0.05, s))
        let w: CGFloat = CGFloat(max(0.02, widthRatio)) * size.width * factor
        let h: CGFloat = CGFloat(max(0.02, mosaic.heightRatio)) * size.height * factor
        let cx: CGFloat = CGFloat(c.x) * size.width
        let cy: CGFloat = CGFloat(c.y) * size.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// 新しいモザイク(画面中央、表示 3 秒)
    static func newMosaic(start: Double, duration: Double = 3) -> TextClip {
        var clip = TextClip(text: "モザイク", start: start)
        clip.duration = duration
        clip.widthRatio = 0.3
        clip.mosaic = MosaicStyle()
        return clip
    }
}
