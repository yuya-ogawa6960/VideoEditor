import Foundation

// =====================================================================
// クリップ削除に合わせて、タイムライン上の部品(字幕・章タイトル・テロップ・テキスト・
// 手書き・マーカー・重ね合わせ・ナレーション)を消したり前に詰めたりする。
//
// これらの部品は「出力タイムライン上の秒」だけで位置を持ち、どのクリップに属するかを
// 覚えていない。そのためクリップを消しても同じ時刻に残り、後から追加した別の動画の上に
// 前の字幕が出てしまっていた。
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
                let removedHead = to - item.start
                result.keyframes = item.keyframes.compactMap { key in
                    var k = key
                    k.time = key.time - removedHead
                    return k.time >= -0.001 ? k : nil
                }
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
                result.keyframes = item.keyframes.compactMap { key in
                    var k = key
                    k.time = key.time - removedHead
                    return k.time >= -0.001 ? k : nil
                }
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
