import Foundation

// =====================================================================
// 分割を戻す: 同じ素材の続きになっている隣のクリップを 1 つにまとめる(純粋なロジック。
// タイムラインの動かし直し・取り消しの登録は ContentView 側で行う)
// =====================================================================

enum ClipRejoin {
    /// 「1 コマ以内」とみなす誤差(秒。24fps の 1 コマ)
    static let tolerance = 1.0 / 24.0

    /// clips[index] とその次のクリップをつなぎ直せるか
    static func canRejoin(_ clips: [Clip], at index: Int) -> Bool {
        guard index >= 0, index + 1 < clips.count else { return false }
        return canRejoin(clips[index], clips[index + 1])
    }

    /// 同じ素材・逆再生なし・同じ速度/見た目/切り抜きで、前の終わりと後ろの始まりがつながっているか
    static func canRejoin(_ first: Clip, _ second: Clip) -> Bool {
        guard first.id != second.id, first.url == second.url, !first.isStill, !second.isStill else { return false }
        guard !first.isReversed, !second.isReversed else { return false }
        guard abs(first.endTime - second.startTime) <= tolerance else { return false }
        guard first.speed == second.speed, !first.speedCurve.enabled, !second.speedCurve.enabled else { return false }
        guard first.geometry == second.geometry,
              first.filter == second.filter,
              first.mask == second.mask,
              first.enhance == second.enhance,
              first.retouch == second.retouch,
              first.backgroundRemoval == second.backgroundRemoval,
              first.subjectFlash == second.subjectFlash,
              first.flowSlow == second.flowSlow,
              first.isMuted == second.isMuted,
              first.multicam.angles == second.multicam.angles,
              first.captionLanguage == second.captionLanguage else { return false }
        // 音量・ゲイン・音声エフェクトは同じであること(J/L カットは端の話なので問わない)
        guard first.audio.volume == second.audio.volume,
              first.audio.gain == second.audio.gain,
              first.audio.effects == second.audio.effects else { return false }
        return true
    }

    /// 2 つを 1 つにまとめたクリップ(前の設定を残し、素材の範囲を後ろまで伸ばす。
    /// 後ろのクリップの終わり側の設定(次へのトランジション・アウトのアニメーション・L カット・フェードアウト)は引き継ぐ)
    static func merge(_ first: Clip, _ second: Clip) -> Clip? {
        guard canRejoin(first, second) else { return nil }
        var merged = first
        merged.endTime = second.endTime
        merged.transition = second.transition
        merged.animation.outType = second.animation.outType
        merged.animation.outDuration = second.animation.outDuration
        merged.audio.audioTailOut = second.audio.audioTailOut
        merged.audioFadeOut = second.audioFadeOut

        // キーフレームとカメラの切り替え点は元素材上の秒なので、つなぎ目より後ろのものを足す
        let joint = first.endTime
        var keyframes = first.keyframes.filter { $0.time <= joint + tolerance }
        keyframes.append(contentsOf: second.keyframes.filter { $0.time > joint + tolerance })
        merged.keyframes = keyframes.sorted { $0.time < $1.time }

        var multicam = first.multicam
        multicam.switches = first.multicam.switches.filter { $0.time <= joint + tolerance }
            + second.multicam.switches.filter { $0.time > joint + tolerance }
        multicam.sortSwitches()
        merged.multicam = multicam
        return merged
    }
}
