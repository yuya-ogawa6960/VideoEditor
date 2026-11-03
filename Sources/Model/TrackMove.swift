import Foundation
import CoreGraphics

// =====================================================================
// V1(メインの映像)とオーバーレイ(V2・V3 …)のあいだで部品を移す(タイムラインのドラッグ)。
// V1 → V2: クリップを持ち上げて上に上げる(liftClipToOverlay)。V2 → V1: オーバーレイを下へ下ろす(moveOverlayToMain)
// =====================================================================

extension EditorProject {
    /// V2 へ持ち上げられるクリップか(V1 が空にならない、マルチカメラ・逆再生・速度カーブを使っていない)。
    /// 最後のクリップも持ち上げられる(V1 より後ろへはみ出したオーバーレイは黒の上に映る。CompositionBuilder.playbackDuration)
    func canLiftClipToOverlay(id: UUID) -> Bool {
        Self.canLiftClipToOverlay(id: id, in: clips)
    }

    /// clips の並び(並べ替え中は動かし始めたときの並び)で判定する
    static func canLiftClipToOverlay(id: UUID, in clips: [Clip]) -> Bool {
        guard clips.count > 1, let i = clips.firstIndex(where: { $0.id == id }) else { return false }
        let clip = clips[i]
        return !clip.multicam.isActive && !clip.isReversed && !clip.speedCurve.enabled
    }

    /// V1 のクリップをオーバーレイにする。V1 は削除と同じく詰める。
    /// start は持ち上げる前のタイムラインの時刻(影を置いた場所)。詰めたあとも同じ場面の上に来るよう、
    /// クリップより後ろなら詰めた分だけ前へずらす(nil なら元の頭の時刻 = 詰めた場所)。
    /// そのクリップの区間に収まっていた部品(字幕・テキスト・ナレーション・オーバーレイ・手書き・章タイトル・テロップ・
    /// 映像エフェクト・マーカー)はオーバーレイと一緒に動かす(映像・音と合ったまま)。
    /// lane: 置く段(0 = V2。ほかのオーバーレイの段も今のまま固定する)。nil なら空いている段へ自動で。
    /// 戻り値は作ったオーバーレイの id
    @discardableResult
    func liftClipToOverlay(id: UUID, start requestedStart: Double? = nil, lane: Int? = nil) -> UUID? {
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

        let removed = removeClip(id: id)
        // 詰めた長さ(トランジションの重なりがあると区間より短い)
        let removedLength = removed.map { max(0, $0.to - $0.from) } ?? 0
        let requested = requestedStart ?? range.start
        var newStart = requested.isFinite ? max(0, requested) : range.start
        if newStart >= range.end {
            newStart -= removedLength
        } else if newStart > range.start {
            newStart = max(range.start, newStart - min(removedLength, newStart - range.start))
        }
        newStart = max(0, newStart)
        let delta = newStart - range.start

        var overlay = OverlayClip(url: clip.stillImageURL ?? clip.url,
                                  isImage: clip.isStill,
                                  name: clip.name,
                                  naturalSize: clip.naturalSize,
                                  preferredTransform: clip.isStill ? .identity : clip.preferredTransform,
                                  sourceDuration: clip.duration,
                                  start: newStart,
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

        // 区間の部品は、詰めたあとに残っていたもの(トランジションの重なりの中)も含めて、ずらしたもので置き換える
        let movedSubtitles = keptSubtitles.map { cue -> SubtitleCue in
            var c = cue
            c.start += delta
            c.end += delta
            c.words = cue.words.map { word in
                var w = word
                w.start += delta
                w.end += delta
                return w
            }
            return c
        }
        let subtitleIDs = Set(movedSubtitles.map(\.id))
        subtitles.removeAll { subtitleIDs.contains($0.id) }
        subtitles.append(contentsOf: movedSubtitles)

        let movedTexts = keptTexts.map { t -> TextClip in
            var r = t
            r.start += delta
            return r
        }
        let textIDs = Set(movedTexts.map(\.id))
        textClips.removeAll { textIDs.contains($0.id) }
        textClips.append(contentsOf: movedTexts)

        let movedNarration = keptNarration.map { n -> NarrationClip in
            var r = n
            r.start += delta
            return r
        }
        let narrationIDs = Set(movedNarration.map(\.id))
        narration.removeAll { narrationIDs.contains($0.id) }
        narration.append(contentsOf: movedNarration)

        let movedOverlays = keptOverlays.map { o -> OverlayClip in
            var r = o
            r.start += delta
            return r
        }
        let overlayIDs = Set(movedOverlays.map(\.id))
        overlays.removeAll { overlayIDs.contains($0.id) }
        overlays.append(contentsOf: movedOverlays)

        let movedDrawings = keptDrawings.map { d -> DrawingClip in
            var r = d
            r.start += delta
            return r
        }
        let drawingIDs = Set(movedDrawings.map(\.id))
        drawings.removeAll { drawingIDs.contains($0.id) }
        drawings.append(contentsOf: movedDrawings)

        let movedTitleCards = keptTitleCards.map { c -> TitleCard in
            var r = c
            r.start += delta
            return r
        }
        let titleCardIDs = Set(movedTitleCards.map(\.id))
        titleCards.removeAll { titleCardIDs.contains($0.id) }
        titleCards.append(contentsOf: movedTitleCards)

        let movedLowerThirds = keptLowerThirds.map { l -> LowerThird in
            var r = l
            r.start += delta
            return r
        }
        let lowerThirdIDs = Set(movedLowerThirds.map(\.id))
        lowerThirds.removeAll { lowerThirdIDs.contains($0.id) }
        lowerThirds.append(contentsOf: movedLowerThirds)

        let movedEffects = keptEffects.map { e -> VideoEffectClip in
            var r = e
            r.start += delta
            return r
        }
        let effectIDs = Set(movedEffects.map(\.id))
        videoEffects.removeAll { effectIDs.contains($0.id) }
        videoEffects.append(contentsOf: movedEffects)

        let movedMarkers = keptMarkers.map { m -> TimelineMarker in
            var r = m
            r.time += delta
            return r
        }
        let markerIDs = Set(movedMarkers.map(\.id))
        markers.removeAll { markerIDs.contains($0.id) }
        markers.append(contentsOf: movedMarkers)

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
        if let lane {
            placeOverlay(id: overlay.id, inLane: lane)
        }
        sortOverlays()
        return overlay.id
    }

    /// オーバーレイを段 lane(0 = V2)に置く。ほかのオーバーレイは今の段のまま固定する(重なれば上の段へずれる)
    func placeOverlay(id: UUID, inLane lane: Int) {
        // 置くもの以外の今の段(置くものを入れて数え直すと、自動の割り当てでほかが段を飛ぶことがある)
        let current = TimelineMetrics.overlayLanes(overlays.filter { $0.id != id })
        for j in overlays.indices where overlays[j].id != id {
            overlays[j].lane = current[overlays[j].id] ?? 0
        }
        if let k = overlays.firstIndex(where: { $0.id == id }) {
            overlays[k].lane = max(0, lane)
        }
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
