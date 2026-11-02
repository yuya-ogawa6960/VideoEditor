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
              // 被写体フラッシュは 1 クリップに 1 つ。分割では光る側にだけ残す(もう片方は enabled = false)ので、
              // 片方だけ光る・どちらも光らない・同じもの(前の版の分割で両方に写したもの)ならつなげる
              first.subjectFlash == second.subjectFlash || !(first.subjectFlash.enabled && second.subjectFlash.enabled),
              first.flowSlow == second.flowSlow,
              first.isMuted == second.isMuted,
              first.multicam.angles.count == second.multicam.angles.count,
              zip(first.multicam.angles, second.multicam.angles).allSatisfy({ $0.hasSameTiming(as: $1) }),
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
        // 被写体フラッシュは「クリップの出力上の先頭からの秒」。後ろだけが光るときは、前の長さだけ後ろへずらして引き継ぐ
        // (両方同じなら前のまま。分割の逆。canRejoin で同じ速度・速度カーブなしなので、前の長さは素材の差 ÷ 速度)
        if !first.subjectFlash.enabled, second.subjectFlash.enabled {
            var flash = second.subjectFlash
            flash.time += max(0, second.startTime - first.startTime) / max(first.speed, 0.01)
            merged.subjectFlash = flash
        }

        // キーフレームとカメラの切り替え点は元素材上の秒なので、つなぎ目より後ろのものを足す
        let joint = first.endTime
        var keyframes = first.keyframes.filter { $0.time <= joint + tolerance }
        keyframes.append(contentsOf: second.keyframes.filter { $0.time > joint + tolerance })
        merged.keyframes = keyframes.sorted { $0.time < $1.time }

        var multicam = first.multicam
        // つなぎ目より前は前のクリップ、つなぎ目からは後ろのクリップの見え方にする
        // (タイムラインのカメラのトラックで後ろの最初の区間を変える・消すと、後ろの始まりちょうどに切替が入る。
        //  前の最後の区間を変えると、つなぎ目に戻しの切替が入る。どちらも後ろの見え方を優先する)
        let pivot = max(joint, second.startTime)
        multicam.switches = first.multicam.switches.filter { $0.time < joint }
        let rearAngle = second.multicam.angleIndex(at: pivot)
        if multicam.angleIndex(at: joint) != rearAngle {
            multicam.switches.append(AngleSwitch(time: joint, angle: rearAngle))
        }
        multicam.switches.append(contentsOf: second.multicam.switches.filter { $0.time > pivot })
        multicam.sortSwitches()
        merged.multicam = multicam
        return merged
    }
}
