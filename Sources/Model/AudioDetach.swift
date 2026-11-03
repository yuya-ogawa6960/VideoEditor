import Foundation

// =====================================================================
// 映像と音声のリンク解除: クリップ・オーバーレイの音声を映像から分けて、対応する音声の段
// (V1 → A1、V2 → A2 …)に置く。映像はミュートにし、音声は同じ時刻に別の部品として残す
// (あとで別々に動かす・切る・消す・音量を変えられる)。元の動画ファイルの音声をそのまま使うので、ファイルは増えない。
// リンク中の音声は映像の部品の中にあり、タイムラインの A の段に映像と同じ位置で描くだけ(動かす・切るといっしょに変わる)
// =====================================================================

extension EditorProject {
    /// 音声を分けられないクリップの理由(分けられるなら nil)
    static func audioDetachBlockReason(_ clip: Clip) -> String? {
        if clip.isStill || !clip.hasAudio { return String(localized: "このクリップには音声がありません") }
        if clip.isMuted { return String(localized: "ミュート中のクリップは音声を分けられません") }
        if abs(clip.speed - 1) > 0.001 || clip.speedCurve.enabled || clip.isReversed || clip.multicam.isActive {
            return String(localized: "速度・逆再生・タイムリマップ・マルチカメラを使ったクリップは音声を分けられません")
        }
        return nil
    }

    /// V1 のクリップの音声を分ける。J カット・L カットで前後にはみ出していた音声も含める。戻り値は作った音声の id
    @discardableResult
    func detachAudio(clipID: UUID) -> UUID? {
        guard let i = index(of: clipID), Self.audioDetachBlockReason(clips[i]) == nil,
              let detached = detachedAudio(ofClipAt: i) else { return nil }
        clips[i].isMuted = true
        clips[i].audio.audioLeadIn = 0
        clips[i].audio.audioTailOut = 0
        narration.append(detached)
        sortNarration()
        return detached.id
    }

    /// V1 の i 番目のクリップの音声だけの部品(速度 1 倍のクリップ用。音声の部品は速さを変えられない)。
    /// 合成でのクリップの音と同じに鳴るようにする:
    /// - J カット・L カットのはみ出しは、合成と同じく前後のクリップの長さまで(最後のクリップの後ろへは出ない)
    /// - トランジションの重なりではクリップの音がクロスフェードするので、その長さのフェードを付ける
    /// - 全体の「元の音量」はクリップの音にだけ掛かるので、ゲインに入れておく
    func detachedAudio(ofClipAt i: Int) -> NarrationClip? {
        guard clips.indices.contains(i), let range = outputRange(ofClip: clips[i].id) else { return nil }
        let clip = clips[i]
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        func placement(_ k: Int) -> ClipPlacement? {
            guard clips.indices.contains(k) else { return nil }
            let id = clips[k].id
            return layout.first(where: { $0.clipID == id })
        }
        let overlapIn = placement(i - 1).map { max(0, $0.end - range.start) } ?? 0
        let overlapOut = placement(i + 1).map { max(0, range.end - $0.start) } ?? 0
        let previousLength = i > 0 ? clips[i - 1].outputDuration : 0
        let nextLength = i + 1 < clips.count ? clips[i + 1].outputDuration : 0
        let lead = max(0, min(clip.audio.audioLeadIn, clip.startTime, range.start, previousLength))
        let tail = max(0, min(clip.audio.audioTailOut, clip.duration - clip.endTime, nextLength))
        var detached = NarrationClip(url: clip.url,
                                     name: String(localized: "\(clip.name) の音声"),
                                     start: range.start - lead,
                                     duration: clip.outputDuration + lead + tail)
        detached.sourceStart = clip.startTime - lead
        // クリップの音量は 0...2、音声の部品は 0...1。1 を超えた分はゲインに入れる
        detached.volume = min(1, max(0, clip.audio.volume))
        detached.gain = clip.audio.gain * max(1, clip.audio.volume) * max(0, audio.originalVolume)
        detached.effects = clip.audio.effects
        detached.fadeIn = min(max(0, max(overlapIn, clip.audioFadeIn)), 3)
        detached.fadeOut = min(max(0, max(overlapOut, clip.audioFadeOut)), 3)
        detached.track = 1
        return detached
    }

    /// 音声を分けられないオーバーレイの理由(分けられるなら nil。音声トラックがあるかは呼ぶ側で調べる)
    static func audioDetachBlockReason(_ overlay: OverlayClip) -> String? {
        if overlay.isImage { return String(localized: "写真には音声がありません") }
        if overlay.volume <= 0.001 { return String(localized: "音量が 0 のオーバーレイは音声を分けられません") }
        if abs(overlay.speed - 1) > 0.001 { return String(localized: "速度を変えたオーバーレイは音声を分けられません") }
        return nil
    }

    /// オーバーレイの音声を分ける(オーバーレイの音量は 0 にする)。戻り値は作った音声の id
    @discardableResult
    func detachAudio(overlayID: UUID) -> UUID? {
        guard let i = overlays.firstIndex(where: { $0.id == overlayID }),
              Self.audioDetachBlockReason(overlays[i]) == nil else { return nil }
        let o = overlays[i]
        var detached = NarrationClip(url: o.url,
                                     name: String(localized: "\(o.name) の音声"),
                                     start: o.start,
                                     duration: o.duration)
        detached.sourceStart = o.sourceStart
        detached.volume = min(1, max(0, o.volume))
        detached.gain = max(1, o.volume)
        // V2 の段(lane 0)の音声は A2
        detached.track = (TimelineMetrics.overlayLanes(overlays)[o.id] ?? 0) + 2
        // オーバーレイの音にはフェードが掛かっていない(見た目のフェードだけ)ので、付けない
        overlays[i].volume = 0
        narration.append(detached)
        sortNarration()
        return detached.id
    }

    /// 音声の部品(リンクを解除した音声・ナレーション・効果音)を出力タイムラインの time で 2 つに切る。
    /// 前側は同じ id のまま。戻り値は後ろ側の id(端に近すぎれば nil)
    @discardableResult
    func splitNarration(id: UUID, at time: Double) -> UUID? {
        guard let i = narration.firstIndex(where: { $0.id == id }) else { return nil }
        let original = narration[i]
        let offset = time - original.start
        guard offset > 0.1, original.duration - offset > 0.1 else { return nil }
        var head = original
        head.duration = offset
        head.fadeIn = min(original.fadeIn, offset)
        head.fadeOut = 0
        var tail = original
        tail.id = UUID()
        tail.start = time
        tail.sourceStart = original.sourceStart + offset
        tail.duration = original.duration - offset
        tail.fadeIn = 0
        tail.fadeOut = min(original.fadeOut, tail.duration)
        narration[i] = head
        narration.insert(tail, at: i + 1)
        sortNarration()
        return tail.id
    }

    /// オーバーレイを出力タイムラインの time で 2 つに切る(映像とリンク中の音声もいっしょに切れる)。
    /// 前側は同じ id のまま、後ろ側は同じ段に置く。戻り値は後ろ側の id(端に近すぎれば nil)
    @discardableResult
    func splitOverlay(id: UUID, at time: Double) -> UUID? {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return nil }
        let original = overlays[i]
        let offset = time - original.start
        guard offset > 0.1, original.duration - offset > 0.1 else { return nil }
        // 段を選んだオーバーレイがあるときは、ほかが段を移らないよう今の段に固定してから切る
        // (どれも自動の段なら固定しない。前後はつながっているだけで重ならないので同じ段に並ぶ)
        if overlays.contains(where: { $0.lane != nil }) {
            let lanes = TimelineMetrics.overlayLanes(overlays)
            for k in overlays.indices {
                overlays[k].lane = lanes[overlays[k].id]
            }
        }
        var head = overlays[i]
        var tail = head.duplicated()
        head.duration = offset
        head.fadeIn = min(original.fadeIn, offset)
        head.fadeOut = 0
        head.transitionOut = ClipTransition()
        tail.start = time
        tail.duration = original.duration - offset
        if !original.isImage {
            tail.sourceStart = original.sourceStart + offset * max(original.speed, 0.01)
        }
        tail.fadeIn = 0
        tail.fadeOut = min(original.fadeOut, tail.duration)
        tail.transitionIn = ClipTransition()
        // キーフレームは切れ目の値を両側に残す(start からの相対秒)
        if !original.keyframes.isEmpty {
            tail.keyframes = KeyframeInterpolator.shifted(original.keyframes, removingHead: offset)
            var kept = original.keyframes.filter { $0.time <= offset + 0.0005 }
            if original.keyframes.contains(where: { $0.time > offset + 0.0005 }),
               !kept.contains(where: { abs($0.time - offset) < 0.001 }) {
                let v = KeyframeInterpolator.value(at: offset, keyframes: original.keyframes,
                                                   fallback: KeyframeInterpolator.Value(center: .center, scale: 1,
                                                                                        rotation: 0, opacity: 1))
                kept.append(Keyframe(time: offset, center: v.center, scale: v.scale,
                                     rotation: v.rotation, opacity: v.opacity))
            }
            head.keyframes = kept
        }
        // ケン・バーンズは切れ目の位置の切り抜きでつなぐ
        if original.kenBurns.enabled, original.duration > 0 {
            let mid = original.kenBurns.startCrop.interpolated(to: original.kenBurns.endCrop,
                                                              t: offset / original.duration)
            head.kenBurns.endCrop = mid
            tail.kenBurns.startCrop = mid
        }
        overlays[i] = head
        overlays.insert(tail, at: i + 1)
        sortOverlays()
        return tail.id
    }
}
