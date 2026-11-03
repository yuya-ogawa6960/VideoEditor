import Foundation
import CoreGraphics

// =====================================================================
// V1(メインの映像)とオーバーレイ(V2・V3 …)のあいだで部品を移す(タイムラインのドラッグ)。
// V1 → V2: クリップを持ち上げて上に上げる(liftClipToOverlay)。V2 → V1: オーバーレイを下へ下ろす(moveOverlayToMain)
// =====================================================================

extension EditorProject {
    /// V2 へ持ち上げられるクリップか(V1 が空にならない、マルチカメラ・逆再生・速度カーブを使っていない)。
    /// 最後のクリップは、持ち上げると V1 の終わりより後ろになって映らないので持ち上げない
    func canLiftClipToOverlay(id: UUID) -> Bool {
        Self.canLiftClipToOverlay(id: id, in: clips)
    }

    /// clips の並び(並べ替え中は動かし始めたときの並び)で判定する
    static func canLiftClipToOverlay(id: UUID, in clips: [Clip]) -> Bool {
        guard clips.count > 1, let i = clips.firstIndex(where: { $0.id == id }), i < clips.count - 1 else { return false }
        let clip = clips[i]
        return !clip.multicam.isActive && !clip.isReversed && !clip.speedCurve.enabled
    }

    /// V1 のクリップをオーバーレイにする。V1 は削除と同じく詰め、オーバーレイは同じ時刻(詰めた場所)から始める。
    /// そのクリップの区間に収まっていた部品(字幕・テキスト・ナレーション・オーバーレイ・手書き・章タイトル・テロップ・
    /// 映像エフェクト・マーカー)は同じ時刻に残す(持ち上げたオーバーレイの映像・音と合ったまま)。
    /// 戻り値は作ったオーバーレイの id
    @discardableResult
    func liftClipToOverlay(id: UUID) -> UUID? {
        guard canLiftClipToOverlay(id: id), let i = index(of: id),
              let range = outputRange(ofClip: id) else { return nil }
        let clip = clips[i]
        let inside: (Double, Double) -> Bool = { start, end in
            start >= range.start - 0.0005 && end <= range.end + 0.0005
        }
        let keptSubtitles = subtitles.filter { inside($0.start, $0.end) }
        let keptTexts = textClips.filter { inside($0.start, $0.end) }
        let keptNarration = narration.filter { inside($0.start, $0.start + $0.duration) }
        let keptOverlays = overlays.filter { inside($0.start, $0.end) }
        let keptDrawings = drawings.filter { inside($0.start, $0.start + $0.duration) }
        let keptTitleCards = titleCards.filter { inside($0.start, $0.start + $0.duration) }
        let keptLowerThirds = lowerThirds.filter { inside($0.start, $0.start + $0.duration) }
        let keptEffects = videoEffects.filter { inside($0.start, $0.start + $0.duration) }
        let keptMarkers = markers.filter { $0.time >= range.start - 0.0005 && $0.time < range.end - 0.0005 }

        var overlay = OverlayClip(url: clip.stillImageURL ?? clip.url,
                                  isImage: clip.isStill,
                                  name: clip.name,
                                  naturalSize: clip.naturalSize,
                                  preferredTransform: clip.isStill ? .identity : clip.preferredTransform,
                                  sourceDuration: clip.duration,
                                  start: range.start,
                                  duration: max(0.1, clip.outputDuration))
        if !clip.isStill {
            overlay.sourceStart = clip.startTime
            overlay.speed = clip.speed
            overlay.volume = clip.hasAudio && !clip.isMuted ? clip.audio.volume * clip.audio.gain : 0
        }
        overlay.filter = clip.filter
        overlay.mask = clip.mask
        overlay.backgroundRemoval = clip.backgroundRemoval
        // V1 では全面に映っていたので、持ち上げても急に薄くならないようにフェードは付けない
        overlay.fadeIn = 0
        overlay.fadeOut = 0

        removeClip(id: id)
        subtitles.append(contentsOf: keptSubtitles.filter { cue in !subtitles.contains { $0.id == cue.id } })
        textClips.append(contentsOf: keptTexts.filter { t in !textClips.contains { $0.id == t.id } })
        narration.append(contentsOf: keptNarration.filter { n in !narration.contains { $0.id == n.id } })
        overlays.append(contentsOf: keptOverlays.filter { o in !overlays.contains { $0.id == o.id } })
        drawings.append(contentsOf: keptDrawings.filter { d in !drawings.contains { $0.id == d.id } })
        titleCards.append(contentsOf: keptTitleCards.filter { c in !titleCards.contains { $0.id == c.id } })
        lowerThirds.append(contentsOf: keptLowerThirds.filter { l in !lowerThirds.contains { $0.id == l.id } })
        videoEffects.append(contentsOf: keptEffects.filter { e in !videoEffects.contains { $0.id == e.id } })
        markers.append(contentsOf: keptMarkers.filter { m in !markers.contains { $0.id == m.id } })
        drawings.sort { $0.start < $1.start }
        titleCards.sort { $0.start < $1.start }
        lowerThirds.sort { $0.start < $1.start }
        sortVideoEffects()
        sortMarkers()
        sortSubtitles()
        sortTextClips()
        sortNarration()
        // 元は V1(いちばん下)だったので、重なるオーバーレイより下の段になるよう先頭に入れる(開始が同じときも下)
        overlays.insert(overlay, at: 0)
        sortOverlays()
        return overlay.id
    }

    /// オーバーレイから V1 に入れるクリップを作る(素材を読み直して音声の有無を調べる)。動く画像(GIF)は入れられない
    static func mainClip(fromOverlay o: OverlayClip) async -> Clip? {
        guard !o.isAnimatedImage else { return nil }
        if o.isImage {
            guard let size = MediaStore.imagePixelSize(of: o.url) else { return nil }
            var clip = Clip(url: o.url,
                            duration: MediaStore.imageSourceDuration,
                            naturalSize: size,
                            preferredTransform: .identity,
                            hasAudio: false,
                            thumbnail: MediaStore.makeImageClipThumbnail(url: o.url, maxPixel: 320),
                            name: o.name)
            clip.stillImageURL = o.url
            clip.startTime = 0
            clip.endTime = max(0.5, o.duration)
            clip.filter = o.filter
            clip.mask = o.mask
            clip.backgroundRemoval = o.backgroundRemoval
            return clip
        }
        guard var clip = try? await MediaStore.makeClip(from: o.url) else { return nil }
        let speed = max(0.1, o.speed)
        clip.speed = speed
        clip.startTime = min(max(0, o.sourceStart), clip.duration)
        clip.endTime = min(clip.duration, clip.startTime + o.duration * speed)
        guard clip.endTime - clip.startTime > 0.05 else { return nil }
        clip.filter = o.filter
        clip.mask = o.mask
        clip.backgroundRemoval = o.backgroundRemoval
        return clip
    }

    /// オーバーレイを消して、作ったクリップを V1 のいちばん近い切れ目(オーバーレイの開始に近いところ)へ入れる。
    /// 後ろのクリップに付いていた部品は、そのクリップと一緒に後ろへずれる
    @discardableResult
    func moveOverlayToMain(id: UUID, clip: Clip) -> Bool {
        guard let o = overlays.first(where: { $0.id == id }) else { return false }
        overlays.removeAll { $0.id == id }
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        var bestIndex = 0
        var bestDistance = Double.infinity
        for k in 0...layout.count {
            let t = k == 0 ? 0 : layout[k - 1].end
            let d = abs(t - o.start)
            if d < bestDistance {
                bestDistance = d
                bestIndex = k
            }
        }
        let before = captureClipLayout()
        clips.insert(clip, at: min(bestIndex, clips.count))
        rippleTimelineItems(from: before)
        return true
    }
}
