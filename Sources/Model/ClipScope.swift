import Foundation

// =====================================================================
// AI のツールを「選んだクリップだけ」にかけるときの範囲。
// 何も選んでいないときの AI(全体)と、クリップを選んだときの AI の両方に同じツールを並べ、
// クリップを選んでいるときは、そのクリップの持ち分の字幕・区間だけを扱う(無音カット・言いよどみカット・
// 文字起こし編集・字幕を翻訳・吹き替え・おまかせ編集)。
// =====================================================================

extension EditorProject {
    /// クリップの持ち分(出力タイムライン上の秒)。前後のクリップとトランジションで重なる所は除く(重なりの中は隣のもの)
    func ownOutputRange(ofClip id: UUID) -> (start: Double, end: Double)? {
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        guard let k = layout.firstIndex(where: { $0.clipID == id }) else { return outputRange(ofClip: id) }
        var start = layout[k].start
        var end = layout[k].end
        if k > 0 { start = max(start, layout[k - 1].end) }
        if k + 1 < layout.count { end = min(end, layout[k + 1].start) }
        guard end - start > 0.05 else { return (layout[k].start, layout[k].end) }
        return (start, end)
    }

    /// そのクリップの持ち分に真ん中があるキャプション(境にかかる字幕は、真ん中のある側のものとみなす)
    func subtitles(inClip id: UUID) -> [SubtitleCue] {
        guard let range = ownOutputRange(ofClip: id) else { return [] }
        return subtitles.filter { cue in
            let middle = (cue.start + cue.end) / 2
            return middle >= range.start && middle < range.end
        }
    }
}
