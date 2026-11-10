import Foundation

// =====================================================================
// マルチカメラの「V1 に書き出す」: スイッチャーで切り替えたとおりに、V1 のカットへ分ける。
// 各カットはそのアングル(またはメイン)の動画のクリップ(ミュート)になり、メインの動画の音声は映像から分けて
// A の段に 1 本で置く(元のクリップと同じ時刻・同じ長さなので、映像と音はずれない)。
// 書き出したあとはふつうのクリップなので、カットごとに長さを変えたり、消したり、色を変えたりできる
// =====================================================================

extension MulticamInfo {
    /// 元素材上の範囲 [start, end) をアングル番号ごとの区間に分ける(MulticamSwitcherPanel.runs・合成と同じ区切り方)
    func runs(start: Double, end: Double) -> [(start: Double, end: Double, angle: Int)] {
        guard end > start else { return [] }
        var result: [(start: Double, end: Double, angle: Int)] = []
        var current = angleIndex(at: start)
        var runStart = start
        for sw in switches.sorted(by: { $0.time < $1.time }) where sw.time > start && sw.time < end {
            let angle = min(max(sw.angle, 0), angles.count)
            if angle != current {
                result.append((start: runStart, end: sw.time, angle: current))
                runStart = sw.time
                current = angle
            }
        }
        result.append((start: runStart, end: end, angle: current))
        return result
    }
}

extension Clip {
    /// 元素材上の秒 sourceTime に映っている別のカメラの動画と、その動画の上の秒
    /// (マルチカメラで別のカメラに切り替えている所だけ。メインのカメラ・アングルの動画の外なら nil)
    func angleFrame(atSourceTime sourceTime: Double) -> (url: URL, time: Double)? {
        guard multicam.isActive else { return nil }
        let index = multicam.angleIndex(at: sourceTime)
        guard index > 0, index <= multicam.angles.count else { return nil }
        let angle = multicam.angles[index - 1]
        let time = angle.angleTime(atMain: sourceTime)
        guard time >= 0, time <= angle.duration else { return nil }
        return (url: angle.url, time: time)
    }
}

extension EditorProject {
    /// 書き出せないマルチカメラのクリップの理由(書き出せるなら nil)
    static func multicamFlattenBlockReason(_ clip: Clip) -> String? {
        if !clip.multicam.isActive { return String(localized: "マルチカメラのクリップではありません") }
        if clip.isReversed || clip.speedCurve.enabled || abs(clip.speed - 1) > 0.001 {
            return String(localized: "速度・逆再生・タイムリマップを使ったマルチカメラは書き出せません")
        }
        return nil
    }

    /// 元素材の区間ごとに使う映像(0 = メイン、1 以上 = アングル)。合成と同じく、アングルの動画が無い所はメイン。
    /// minHead・minTail: 先頭・最後のカットの最低の長さ(秒)。前後のトランジションの重なりは各クリップの半分までなので、
    /// 短いカットになると重なりが縮んで全体の長さが変わる。足りないときはその分をメインの映像にする
    static func multicamCuts(_ clip: Clip, minHead: Double = 0, minTail: Double = 0)
        -> [(start: Double, end: Double, angle: Int)] {
        let multicam = clip.multicam
        var pieces: [(start: Double, end: Double, angle: Int)] = []
        func add(_ start: Double, _ end: Double, _ angle: Int) {
            guard end - start > 0.0005 else { return }
            if let last = pieces.last, last.angle == angle, abs(last.end - start) < 0.0005 {
                pieces[pieces.count - 1].end = end
            } else {
                pieces.append((start: start, end: end, angle: angle))
            }
        }
        for run in multicam.runs(start: clip.startTime, end: clip.endTime) {
            guard run.angle > 0, run.angle <= multicam.angles.count else {
                add(run.start, run.end, 0)
                continue
            }
            let angle = multicam.angles[run.angle - 1]
            let lower = max(run.start, angle.mainTime(atAngle: 0))
            let upper = min(run.end, angle.mainTime(atAngle: angle.duration))
            guard upper - lower >= 0.05 else {
                add(run.start, run.end, 0)
                continue
            }
            add(run.start, lower, 0)
            add(lower, upper, run.angle)
            add(upper, run.end, 0)
        }
        // 1 コマより短いアングルの切れ端はメインにする(アングルの動画の外へ伸ばさない)。メインどうしはつなぐ
        var merged: [(start: Double, end: Double, angle: Int)] = []
        for piece in pieces {
            var p = piece
            if p.end - p.start < 0.04 {
                p.angle = 0
            }
            if let last = merged.last, last.angle == p.angle {
                merged[merged.count - 1].end = p.end
            } else {
                merged.append(p)
            }
        }
        // 先頭・最後のカットが短すぎるときは、その長さまでメインの映像にする(隣のカットは内側へ縮むだけ)
        if merged.count > 1, minHead > 0, merged[0].end - merged[0].start < minHead {
            let edge = min(clip.endTime, merged[0].start + minHead)
            merged[0].angle = 0
            merged[0].end = edge
            while merged.count > 1, merged[1].end <= edge + 0.0005 {
                merged.remove(at: 1)
            }
            if merged.count > 1 {
                merged[1].start = edge
                if merged[1].angle == 0 {
                    merged[0].end = merged[1].end
                    merged.remove(at: 1)
                }
            }
        }
        if merged.count > 1, minTail > 0, merged[merged.count - 1].end - merged[merged.count - 1].start < minTail {
            let last = merged.count - 1
            let edge = max(merged[0].start, merged[last].end - minTail)
            merged[last].angle = 0
            merged[last].start = edge
            while merged.count > 1, merged[merged.count - 2].start >= edge - 0.0005 {
                merged.remove(at: merged.count - 2)
            }
            if merged.count > 1 {
                let k = merged.count - 2
                merged[k].end = edge
                if merged[k].angle == 0 {
                    merged[k].end = merged[k + 1].end
                    merged.removeLast()
                }
            }
        }
        return merged
    }

    /// マルチカメラのクリップを V1 のカットに分ける。戻り値は作ったカットの id(先頭から。書き出せなければ nil)
    @MainActor
    func flattenMulticam(clipID: UUID) async -> [UUID]? {
        guard let original = clips.first(where: { $0.id == clipID }),
              Self.multicamFlattenBlockReason(original) == nil else { return nil }
        let firstCuts = Self.multicamCuts(original)
        // 使うアングルの動画を読む(読めないアングルの区間は、合成と同じくメインの映像にする)
        var angleClips: [Int: Clip] = [:]
        for k in Set(firstCuts.map(\.angle)) where k > 0 && k <= original.multicam.angles.count {
            if let loaded = try? await MediaStore.makeClip(from: original.multicam.angles[k - 1].url) {
                angleClips[k] = loaded
            }
        }
        // 読み込んでいる間に消された・変えられたら何もしない
        guard let i = clips.firstIndex(where: { $0.id == clipID }), clips[i] == original,
              let range = outputRange(ofClip: clipID) else { return nil }
        // 前後のトランジションの重なり(先頭・最後のカットはその倍の長さを残す)
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        func placement(_ k: Int) -> ClipPlacement? {
            guard clips.indices.contains(k) else { return nil }
            let id = clips[k].id
            return layout.first(where: { $0.clipID == id })
        }
        let overlapIn = placement(i - 1).map { max(0, $0.end - range.start) } ?? 0
        let overlapOut = placement(i + 1).map { max(0, range.end - $0.start) } ?? 0
        let cuts = Self.multicamCuts(original,
                                     minHead: overlapIn > 0.001 ? overlapIn * 2 + 0.02 : 0,
                                     minTail: overlapOut > 0.001 ? overlapOut * 2 + 0.02 : 0)
        guard !cuts.isEmpty else { return nil }

        var pieces: [Clip] = []
        for (n, cut) in cuts.enumerated() {
            let isFirst = n == 0
            let isLast = n == cuts.count - 1
            var piece: Clip
            if cut.angle > 0, let base = angleClips[cut.angle] {
                let angle = original.multicam.angles[cut.angle - 1]
                piece = base.duplicated()
                piece.startTime = max(0, angle.angleTime(atMain: cut.start))
                piece.endTime = min(base.duration, angle.angleTime(atMain: cut.end))
                // 時計のずれの補正(rate)の分だけ速さを変えて、メインと同じ長さにする
                piece.speed = max(0.01, angle.rate)
                piece.filter = original.filter
                piece.geometry = original.geometry
                piece.animation = original.animation
                // 書き出す前はどのアングルにも効いていた効果も写す(写さないと、アングルのカットだけ素の映像になっていた)。
                // 手ぶれ補正・リフレームはメインのカメラで調べた値なので写さない
                piece.mask = original.mask
                piece.enhance = original.enhance
                piece.backgroundRemoval = original.backgroundRemoval
                piece.retouch = original.retouch
                // キーフレームの時刻はメインの元素材の秒なので、アングルの動画の秒に直す
                piece.keyframes = original.keyframes.map { key in
                    var k = key
                    k.id = UUID()
                    k.time = angle.angleTime(atMain: key.time)
                    return k
                }
                // 被写体フラッシュ(クリップの出力上の先頭からの秒): 光り始めがこのカットにあるときだけ、カットの先頭からの秒にする
                if original.subjectFlash.enabled {
                    let head = original.outputOffset(atSourceTime: cut.start)
                    let tail = original.outputOffset(atSourceTime: cut.end)
                    let flashTime = original.subjectFlash.time
                    if flashTime >= head - 0.0005, flashTime < tail {
                        piece.subjectFlash = original.subjectFlash
                        piece.subjectFlash.time = max(0, flashTime - head)
                    }
                }
                if !isFirst {
                    piece.animation.inType = .none
                }
                if isLast {
                    piece.transition = original.transition
                } else {
                    piece.animation.outType = .none
                }
            } else {
                piece = original.duplicated()
                piece.multicam = MulticamInfo()
                piece.restrictToSource(cut.start, cut.end, of: original)
                piece.clearCutEdges(head: !isFirst, tail: !isLast)
            }
            // 音はメインの音声 1 本で鳴らす(カットの音は使わない)
            piece.isMuted = true
            piece.audio.audioLeadIn = 0
            piece.audio.audioTailOut = 0
            piece.audioFadeIn = 0
            piece.audioFadeOut = 0
            pieces.append(piece)
        }

        // メインの音声(差し替える前の並びで作る。J/L カット・トランジションのフェードも同じに)
        let mainAudio: NarrationClip? = original.hasAudio && !original.isMuted ? detachedAudio(ofClipAt: i) : nil
        clips.remove(at: i)
        clips.insert(contentsOf: pieces, at: i)
        if let mainAudio {
            narration.append(mainAudio)
            sortNarration()
        }
        return pieces.map(\.id)
    }
}
