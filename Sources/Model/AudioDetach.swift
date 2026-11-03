import Foundation

// =====================================================================
// クリップ・オーバーレイの音声を映像から分けて、音声の段(ナレーションと同じ A の段)に置く。
// 映像はミュートにし、音声は同じ時刻に別の部品として残す(あとで別々に動かす・消す・音量を変えられる)。
// 元の動画ファイルの音声をそのまま使うので、ファイルは増えない
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
        // オーバーレイの音にはフェードが掛かっていない(見た目のフェードだけ)ので、付けない
        overlays[i].volume = 0
        narration.append(detached)
        sortNarration()
        return detached.id
    }
}
