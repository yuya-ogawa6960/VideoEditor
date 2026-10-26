import Foundation

// =====================================================================
// クリップ削除に合わせて、タイムライン上の部品(字幕・章タイトル・テロップ・テキスト・
// 手書き・マーカー・重ね合わせ・ナレーション)を消したり前に詰めたりする。
//
// これらの部品は「出力タイムライン上の秒」だけで位置を持ち、どのクリップに属するかを
// 覚えていない。そのためクリップを消しても同じ時刻に残り、後から追加した別の動画の上に
// 前の字幕が出てしまっていた。
// トリム・並べ替えなど配置の変更に合わせて付いて動かす処理(ClipLayoutSnapshot)もここ。
// =====================================================================

extension EditorProject {

    /// 出力タイムライン上の [from, to) を取り除いて後ろを詰めたときの時刻の対応
    private struct RippleMap {
        let from: Double
        let to: Double
        var gap: Double { max(0, to - from) }

        /// 取り除いた区間の中の時刻は from に寄せる
        func map(_ t: Double) -> Double {
            if t < from { return t }
            if t >= to { return t - gap }
            return from
        }

        /// 時刻が取り除いた区間の中にあるか
        func isInside(_ t: Double) -> Bool { t >= from && t < to }
    }

    /// 出力タイムラインの [from, to) を取り除く。区間の中の部品は消し、
    /// またがる部品は切り詰め、後ろの部品は前に詰める。
    func removeTimelineRange(from: Double, to: Double) {
        let ripple = RippleMap(from: from, to: to)
        guard ripple.gap > 0.001 else { return }
        let minimumLength = 0.2

        // 字幕
        subtitles = subtitles.compactMap { cue in
            let start = ripple.map(cue.start)
            let end = ripple.map(cue.end)
            guard end - start >= minimumLength else { return nil }
            var result = cue
            result.start = start
            result.end = end
            result.words = cue.words.compactMap { word in
                let ws = ripple.map(word.start)
                let we = ripple.map(word.end)
                guard we > ws else { return nil }
                var w = word
                w.start = ws
                w.end = we
                return w
            }
            return result
        }

        // 章タイトル
        titleCards = titleCards.compactMap { card in
            let start = ripple.map(card.start)
            let end = ripple.map(card.start + card.duration)
            guard end - start >= minimumLength else { return nil }
            var result = card
            result.start = start
            result.duration = end - start
            return result
        }

        // ネームプレート・場所テロップ
        lowerThirds = lowerThirds.compactMap { item in
            let start = ripple.map(item.start)
            let end = ripple.map(item.start + item.duration)
            guard end - start >= minimumLength else { return nil }
            var result = item
            result.start = start
            result.duration = end - start
            return result
        }

        // テキスト・ステッカー
        textClips = textClips.compactMap { item in
            let start = ripple.map(item.start)
            let end = ripple.map(item.start + item.duration)
            guard end - start >= minimumLength else { return nil }
            var result = item
            result.start = start
            result.duration = end - start
            if ripple.isInside(item.start) {
                // 先頭が切られたぶん、キーフレームを前にずらす
                result.keyframes = KeyframeInterpolator.shifted(item.keyframes, removingHead: to - item.start)
            }
            return result
        }

        // 手書き
        drawings = drawings.compactMap { item in
            let start = ripple.map(item.start)
            let end = ripple.map(item.start + item.duration)
            guard end - start >= minimumLength else { return nil }
            var result = item
            result.start = start
            result.duration = end - start
            return result
        }

        // マーカー(区間の中にあったものは消す)
        markers = markers.compactMap { marker in
            guard !ripple.isInside(marker.time) else { return nil }
            var result = marker
            result.time = ripple.map(marker.time)
            return result
        }

        // 重ね合わせ(Bロール・ワイプ・写真)
        overlays = overlays.compactMap { item in
            let start = ripple.map(item.start)
            let end = ripple.map(item.start + item.duration)
            guard end - start >= minimumLength else { return nil }
            var result = item
            if ripple.isInside(item.start) {
                let removedHead = to - item.start
                if !item.isImage {
                    result.sourceStart = item.sourceStart + removedHead * item.speed
                }
                result.keyframes = KeyframeInterpolator.shifted(item.keyframes, removingHead: removedHead)
            }
            result.start = start
            result.duration = end - start
            return result
        }

        // ナレーション
        narration = narration.compactMap { item in
            let start = ripple.map(item.start)
            let end = ripple.map(item.start + item.duration)
            guard end - start >= minimumLength else { return nil }
            var result = item
            if ripple.isInside(item.start) {
                result.sourceStart = item.sourceStart + (to - item.start)
            }
            result.start = start
            result.duration = end - start
            return result
        }
    }

    /// 出力タイムラインの time に length 秒を差し込んだ(クリップを途中に追加した)とき、
    /// time 以降に始まる部品を同じだけ後ろへずらす(元の動画と同じ場所に付いたままにする)。
    /// time をまたいでいる部品(前から続いている BGM など)は途切れさせないよう、そのままにする
    func insertTimelineGap(at time: Double, length: Double) {
        guard length > 0.001 else { return }
        let edge = time - 0.001

        subtitles = subtitles.map { cue in
            guard cue.start >= edge else { return cue }
            var result = cue
            result.start += length
            result.end += length
            result.words = cue.words.map { word in
                var w = word
                w.start += length
                w.end += length
                return w
            }
            return result
        }
        titleCards = titleCards.map { item in
            guard item.start >= edge else { return item }
            var result = item
            result.start += length
            return result
        }
        lowerThirds = lowerThirds.map { item in
            guard item.start >= edge else { return item }
            var result = item
            result.start += length
            return result
        }
        // キーフレームは部品の先頭からの秒なので、start だけずらせばよい
        textClips = textClips.map { item in
            guard item.start >= edge else { return item }
            var result = item
            result.start += length
            return result
        }
        drawings = drawings.map { item in
            guard item.start >= edge else { return item }
            var result = item
            result.start += length
            return result
        }
        markers = markers.map { marker in
            guard marker.time >= edge else { return marker }
            var result = marker
            result.time += length
            return result
        }
        overlays = overlays.map { item in
            guard item.start >= edge else { return item }
            var result = item
            result.start += length
            return result
        }
        narration = narration.map { item in
            guard item.start >= edge else { return item }
            var result = item
            result.start += length
            return result
        }
    }

    /// 出力タイムライン全体の長さ(トランジションの重なりを考慮)
    var layoutDuration: Double {
        CompositionBuilder.timelineLayout(for: snapshot()).map(\.end).max() ?? totalDuration
    }

    /// タイムライン上の部品をすべて消す(クリップが無くなったとき)
    func clearTimelineItems() {
        subtitles = []
        titleCards = []
        lowerThirds = []
        textClips = []
        drawings = []
        markers = []
        overlays = []
        narration = []
    }

    /// クリップの出力タイムライン上の範囲(トランジションの重なりを考慮)
    func outputRange(ofClip id: UUID) -> (start: Double, end: Double)? {
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        if let placement = layout.first(where: { $0.clipID == id }) {
            return (placement.start, placement.end)
        }
        guard let i = index(of: id) else { return nil }
        let start = clipStartTimes()[i]
        return (start, start + clips[i].outputDuration)
    }
}

// MARK: - クリップの配置が変わったときの追従

/// クリップの配置(トリミング・順序・速度・トランジション)を変える前に取っておく、クリップごとの位置。
/// 変えた後に `EditorProject.rippleTimelineItems(from:)` へ渡すと、部品が同じ元素材の位置に付いたまま動く
struct ClipLayoutSnapshot {
    /// 1 本のクリップの出力タイムライン上の範囲(トランジションの重なりを反映)と元素材の使い方
    fileprivate struct Entry {
        let clip: Clip
        let start: Double
        let end: Double

        var id: UUID { clip.id }
        var isReversed: Bool { clip.isReversed && clip.reversedURL != nil }

        /// 元素材の使い方(トリミング・速度・逆再生)が同じか
        func usesSameSource(as other: Entry) -> Bool {
            clip.startTime == other.clip.startTime && clip.endTime == other.clip.endTime
                && clip.speed == other.clip.speed && clip.speedCurve == other.clip.speedCurve
                && isReversed == other.isReversed
        }

        /// クリップ先頭からの出力秒 → 画面に出ている元素材の時刻(逆再生は鏡像。TimelineClipView のサムネイルと同じ)
        func shownSourceTime(atOutputOffset offset: Double) -> Double {
            let source = clip.sourceTime(atOutputOffset: offset)
            return isReversed ? clip.startTime + clip.endTime - source : source
        }

        /// 画面に出ている元素材の時刻 → クリップ先頭からの出力秒。
        /// トリミング範囲の外は端の速度でそのまま延ばす(負、または出力の長さを超える値になる)
        func outputOffset(atShownSourceTime shown: Double) -> Double {
            let source = isReversed ? clip.startTime + clip.endTime - shown : shown
            if source < clip.startTime {
                let speed = clip.speedCurve.enabled ? clip.speedCurve.speed(at: 0) : clip.speed
                return (source - clip.startTime) / max(speed, 0.01)
            }
            if source > clip.endTime {
                let speed = clip.speedCurve.enabled ? clip.speedCurve.speed(at: 1) : clip.speed
                return clip.outputDuration + (source - clip.endTime) / max(speed, 0.01)
            }
            return clip.outputOffset(atSourceTime: source)
        }

        /// 元素材の時刻 shown がトリミング範囲の中にあるか
        func covers(shownSourceTime shown: Double) -> Bool {
            shown >= clip.startTime - 0.0005 && shown <= clip.endTime + 0.0005
        }
    }

    fileprivate let entries: [Entry]
}

/// 変える前の配置の時刻 → 変えた後の配置の時刻
private struct TimelineRemap {
    /// 動かした結果。clamped は新しいクリップの範囲に収めた時刻。
    /// removedHead は、部品の先頭がこの時刻にあったときに切られた長さ(変える前のタイムラインの秒。範囲の中なら 0)
    struct Mapped {
        let clamped: Double
        let removedHead: Double
        init(_ clamped: Double, removedHead: Double = 0) {
            self.clamped = clamped
            self.removedHead = removedHead
        }
    }

    /// 動かした部品の範囲
    struct Span {
        let start: Double
        let end: Double
        /// 先頭が切られた長さ(変える前のタイムラインの秒)
        let removedHead: Double
        /// 両端が別のクリップに付いていて、並べ替えで前後が入れ替わった(先頭に付いて行き、長さはそのまま)
        let swapped: Bool
    }

    /// これより短くなった部品は消す(removeTimelineRange と同じ)
    static let minimumLength = 0.2

    private let before: [ClipLayoutSnapshot.Entry]
    private let after: [ClipLayoutSnapshot.Entry]
    private let afterIndex: [UUID: Int]

    init(before: ClipLayoutSnapshot, after: ClipLayoutSnapshot) {
        self.before = before.entries
        self.after = after.entries
        var index: [UUID: Int] = [:]
        for (i, entry) in after.entries.enumerated() where index[entry.id] == nil {
            index[entry.id] = i
        }
        afterIndex = index
    }

    /// 配置が変わっていない(動かすものがない)
    var isIdentity: Bool {
        guard before.count == after.count else { return false }
        return zip(before, after).allSatisfy { a, b in
            a.id == b.id && a.start == b.start && a.end == b.end && a.usesSameSource(as: b)
        }
    }

    /// 時刻 t を持っていたクリップ。重なり(トランジション)の中は前のクリップ。
    /// 部品の終わり(isEnd)がクリップの切れ目にぴったりなら前のクリップに付ける
    private func oldOwner(of t: Double, isEnd: Bool) -> ClipLayoutSnapshot.Entry? {
        before.first(where: { isEnd ? t <= $0.end : t < $0.end }) ?? before.last
    }

    func map(_ t: Double, isEnd: Bool = false) -> Mapped {
        guard let owner = oldOwner(of: t, isEnd: isEnd), let i = afterIndex[owner.id] else {
            // 持ち主のクリップが消えた(または元から無い)ときは絶対時刻のまま
            return Mapped(t)
        }
        let target = after[i]
        if t > owner.end + 0.0005 {
            // 最後のクリップより後ろ: 終わりからの距離を保つ
            return Mapped(t + (target.end - owner.end))
        }
        if owner.usesSameSource(as: target) {
            // 元素材の使い方が同じなら位置のずれぶんだけ動かす(計算誤差を入れない)
            return Mapped(t + (target.start - owner.start))
        }
        let local = min(max(t - owner.start, 0), owner.clip.outputDuration)
        let shown = owner.shownSourceTime(atOutputOffset: local)
        var home = target
        var raw = target.start + target.outputOffset(atShownSourceTime: shown)
        // 分割したクリップは同じ素材の続きが隣にある。そちらの範囲にある時刻はそちらに付け替える
        if raw < target.start - 0.0005 || raw > target.end + 0.0005,
           let next = continuation(of: i, toward: raw > target.end ? 1 : -1, shownSourceTime: shown) {
            home = next
            raw = next.start + next.outputOffset(atShownSourceTime: shown)
        }
        // トリミング範囲の外に出た時刻はクリップの端に寄せる
        if raw < home.start - 0.0005 {
            // 先頭を切った: 新しい先頭までの長さが切られた(端の速度で延ばした値。速度が同じなら元の秒と一致する)
            return Mapped(home.start, removedHead: home.start - raw)
        }
        if raw > home.end + 0.0005 {
            // 終わりを切った: 元のクリップの終わり(次のクリップの始まり)までが切られた
            return Mapped(home.end, removedHead: max(0, owner.end - t))
        }
        return Mapped(raw)
    }

    private func continuation(of index: Int, toward direction: Int,
                              shownSourceTime shown: Double) -> ClipLayoutSnapshot.Entry? {
        let j = index + direction
        guard after.indices.contains(j) else { return nil }
        let base = after[index]
        let candidate = after[j]
        guard candidate.clip.url == base.clip.url, candidate.isReversed == base.isReversed,
              candidate.covers(shownSourceTime: shown) else { return nil }
        return candidate
    }

    /// 部品の範囲を動かす。短くなりすぎたら nil
    func span(_ start: Double, _ end: Double) -> Span? {
        let s = map(start)
        let e = map(end, isEnd: true)
        let removedHead = s.removedHead
        if e.clamped < s.clamped - 0.0005 {
            // 両端が別のクリップに付いていて、並べ替えで前後が入れ替わった: 先頭に付いて行き、長さはそのまま
            let length = (end - start) - removedHead
            guard length >= Self.minimumLength else { return nil }
            return Span(start: s.clamped, end: s.clamped + length, removedHead: removedHead, swapped: true)
        }
        guard e.clamped - s.clamped >= Self.minimumLength else { return nil }
        return Span(start: s.clamped, end: e.clamped, removedHead: removedHead, swapped: false)
    }

    /// 部品の先頭からの相対秒で持つキーフレームを、動かした後の相対秒にする。
    /// 先頭が切られたぶんは前へずらし(KeyframeInterpolator.shifted)、速度を変えたクリップの上では
    /// 同じ元素材のコマに付いたまま伸び縮みさせる(追尾のモザイクが顔から外れないように)
    func keyframes(_ keyframes: [Keyframe], itemStart: Double, span: Span) -> [Keyframe] {
        var result = KeyframeInterpolator.shifted(keyframes, removingHead: span.removedHead)
        guard !span.swapped, !result.isEmpty else { return result }
        // 切った後の先頭の、変える前のタイムライン上の時刻
        let head = itemStart + span.removedHead
        for i in result.indices {
            result[i].time = max(0, map(head + result[i].time).clamped - span.start)
        }
        result.sort { $0.time < $1.time }
        return result
    }
}

extension EditorProject {
    /// クリップの配置(トリミング・順序・速度・トランジション)を変える前に取っておく
    func captureClipLayout() -> ClipLayoutSnapshot {
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        var entries: [ClipLayoutSnapshot.Entry] = []
        entries.reserveCapacity(clips.count)
        for (i, clip) in clips.enumerated() where i < layout.count {
            entries.append(ClipLayoutSnapshot.Entry(clip: clip, start: layout[i].start, end: layout[i].end))
        }
        return ClipLayoutSnapshot(entries: entries)
    }

    /// 配置が変わったぶん、字幕・テキスト(モザイク含む)・手書き・オーバーレイ・ナレーション・マーカー・章タイトル・テロップを
    /// 同じ元素材の位置に付いたまま動かす。切られた区間に入った端はクリップの端に寄せ、短くなりすぎた部品は消す
    func rippleTimelineItems(from snapshot: ClipLayoutSnapshot) {
        let remap = TimelineRemap(before: snapshot, after: captureClipLayout())
        guard !remap.isIdentity else { return }

        subtitles = subtitles.compactMap { cue in
            guard let span = remap.span(cue.start, cue.end) else { return nil }
            var result = cue
            result.start = span.start
            result.end = span.end
            // 字幕の範囲から出た単語(並べ替えで散ったもの)は消す(単語が無ければ標準の描画になる)
            result.words = cue.words.compactMap { word in
                let ws = remap.map(word.start).clamped
                let we = remap.map(word.end, isEnd: true).clamped
                guard we > ws, ws >= span.start - 0.0005, we <= span.end + 0.0005 else { return nil }
                var w = word
                w.start = ws
                w.end = we
                return w
            }
            return result
        }
        titleCards = titleCards.compactMap { card in
            guard let span = remap.span(card.start, card.end) else { return nil }
            var result = card
            result.start = span.start
            result.duration = span.end - span.start
            return result
        }
        lowerThirds = lowerThirds.compactMap { item in
            guard let span = remap.span(item.start, item.end) else { return nil }
            var result = item
            result.start = span.start
            result.duration = span.end - span.start
            return result
        }
        // キーフレームは部品の先頭からの秒なので、先頭が切られたぶん前へずらし、速度を変えたクリップの上では伸び縮みさせる
        textClips = textClips.compactMap { item in
            guard let span = remap.span(item.start, item.end) else { return nil }
            var result = item
            result.start = span.start
            result.duration = span.end - span.start
            result.keyframes = remap.keyframes(item.keyframes, itemStart: item.start, span: span)
            return result
        }
        drawings = drawings.compactMap { item in
            guard let span = remap.span(item.start, item.end) else { return nil }
            var result = item
            result.start = span.start
            result.duration = span.end - span.start
            return result
        }
        markers = markers.map { marker in
            var result = marker
            result.time = remap.map(marker.time).clamped
            return result
        }
        overlays = overlays.compactMap { item in
            guard let span = remap.span(item.start, item.end) else { return nil }
            var result = item
            result.start = span.start
            result.duration = span.end - span.start
            if !item.isImage {
                // 動画は素材上の開始位置も一緒にずらし、素材の残りより長くはしない
                result.sourceStart = item.sourceStart + span.removedHead * item.speed
                result.duration = min(result.duration, max(TimelineRemap.minimumLength, result.maxDuration))
            }
            result.keyframes = remap.keyframes(item.keyframes, itemStart: item.start, span: span)
            return result
        }
        narration = narration.compactMap { item in
            guard let span = remap.span(item.start, item.end) else { return nil }
            var result = item
            result.start = span.start
            result.duration = span.end - span.start
            result.sourceStart = item.sourceStart + span.removedHead
            return result
        }

        sortSubtitles()
        titleCards.sort { $0.start < $1.start }
        lowerThirds.sort { $0.start < $1.start }
        sortTextClips()
        drawings.sort { $0.start < $1.start }
        sortMarkers()
        sortOverlays()
        sortNarration()
    }
}
