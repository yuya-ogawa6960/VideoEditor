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
    /// 重ねた素材(B ロール・ワイプ・写真など V2 以上)の上にもかける。false なら V1 の映像だけ(オーバーレイの下)。
    /// 新しく置くモザイクは true(V2 に映った顔も隠れるように)。前の版で作ったモザイク(保存に無い)は false のまま
    var coversOverlays: Bool = true
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

// MARK: - 比率・収め方を変えたときの置き直し

/// モザイクは画面(キャンバス)に対する割合で位置と大きさを持つので、作品の比率・収め方を変えたり、
/// 「SNS パック」で別の向きの 1 本を作ったりすると、映像だけが動いてモザイクが顔から外れていた。
/// 変える前と後で、その時刻に映っている V1 のクリップの同じ点に来るように置き直す(ClipCanvasMapping)。
/// 重ねた素材の上にかけるモザイクで、重ねた素材の枠の中にあるものは、重ねた素材と同じく画面に対する位置のままにする
enum MosaicRemap {
    static func remapped(_ clips: [TextClip], from before: ProjectSnapshot, to after: ProjectSnapshot) -> [TextClip] {
        guard clips.contains(where: { $0.isMosaic }), !before.clips.isEmpty else { return clips }
        let oldSize = CompositionBuilder.renderSize(for: before, purpose: .preview)
        let newSize = CompositionBuilder.renderSize(for: after, purpose: .preview)
        guard oldSize.width > 1, oldSize.height > 1, newSize.width > 1, newSize.height > 1 else { return clips }
        let oldAspect = Double(oldSize.width / oldSize.height)
        let newAspect = Double(newSize.width / newSize.height)
        if abs(oldAspect - newAspect) < 0.001, before.canvas.scaling == after.canvas.scaling { return clips }
        let layout = CompositionBuilder.timelineLayout(for: before)
        let context = Context(snapshot: before, layout: layout, oldSize: oldSize, newSize: newSize,
                              newScaling: after.canvas.scaling)
        return clips.map { clip in
            guard clip.isMosaic else { return clip }
            return remapped(clip, context: context)
        }
    }

    private struct Context {
        let snapshot: ProjectSnapshot
        let layout: [ClipPlacement]
        let oldSize: CGSize
        let newSize: CGSize
        let newScaling: ScalingMode
    }

    private static func remapped(_ clip: TextClip, context: Context) -> TextClip {
        let baseTime = clip.start + min(0.05, max(0, clip.duration) / 2)
        if clip.mosaic?.coversOverlays ?? false,
           liesOnOverlay(clip.center, time: baseTime, overlays: context.snapshot.overlays) {
            return clip
        }
        guard let base = mapping(at: baseTime, context: context) else { return clip }
        let baseSX = Double(hypot(base.a, base.b))
        let baseSY = Double(hypot(base.c, base.d))
        guard baseSX > 0.0001, baseSY > 0.0001 else { return clip }
        var out = clip
        out.center = apply(base, to: clip.center)
        out.widthRatio = clip.widthRatio * baseSX
        out.mosaic?.heightRatio = (clip.mosaic?.heightRatio ?? 0.22) * baseSY
        out.keyframes = clip.keyframes.map { key in
            var k = key
            let m = mapping(at: clip.start + key.time, context: context) ?? base
            k.center = apply(m, to: key.center)
            // 幅・高さは基準の時刻の倍率で直したので、キーの大きさは基準との比だけ掛ける
            k.scale = key.scale * Double(hypot(m.a, m.b)) / baseSX
            return k
        }
        return out
    }

    /// time に映っている V1 のクリップで、古いキャンバス → 元の絵 → 新しいキャンバス の変換(クリップが無ければ nil)
    private static func mapping(at time: Double, context: Context) -> CGAffineTransform? {
        var found: Int?
        for (i, placement) in context.layout.enumerated() where time >= placement.start - 0.0005 && time < placement.end {
            found = i
        }
        guard let i = found, i < context.snapshot.clips.count else { return nil }
        let clip = context.snapshot.clips[i]
        let source = clip.sourceTime(atOutputOffset: max(0, time - context.layout[i].start))
        let old = ClipCanvasMapping.transform(clip: clip, sourceTime: source, canvasSize: context.oldSize,
                                              scaling: context.snapshot.canvas.scaling)
        let new = ClipCanvasMapping.transform(clip: clip, sourceTime: source, canvasSize: context.newSize,
                                              scaling: context.newScaling)
        return old.inverted().concatenating(new)
    }

    private static func apply(_ t: CGAffineTransform, to p: NormalizedPoint) -> NormalizedPoint {
        let q = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)).applying(t)
        return NormalizedPoint(x: min(max(Double(q.x), -1), 2), y: min(max(Double(q.y), -1), 2))
    }

    /// time に見えている重ねた素材の枠の中か
    private static func liesOnOverlay(_ p: NormalizedPoint, time: Double, overlays: [OverlayClip]) -> Bool {
        overlays.contains { overlay in
            guard overlay.contains(timelineTime: time) else { return false }
            let f = overlay.frame
            return p.x >= f.minX && p.x <= f.maxX && p.y >= f.minY && p.y <= f.maxY
        }
    }
}

extension EditorProject {
    /// 作品の比率・収め方を変えたあとに呼ぶ: モザイクを映像に合わせて置き直す(before は変える前の状態)
    func remapMosaics(from before: ProjectSnapshot) {
        let remapped = MosaicRemap.remapped(textClips, from: before, to: snapshot())
        if remapped != textClips {
            textClips = remapped
        }
    }
}
