import Foundation

// =====================================================================
// インフルエンサー向けの自動編集の部品
//   - PunchInPlanner : オートパンチイン(話の区切りでズームを交互に切り替える)のカット位置
//   - FillerDetector : 言いよどみ(「えー」「あのー」「um」など)の区間を字幕から見つける
//   - EditorProject.removeOutputRanges : 出力タイムラインの区間を取り除き、字幕やテキストも前にずらす
//   - EditorProject.shiftTimelineItems  : 先頭に差し込んだ分だけ、字幕やテキストを後ろにずらす
// =====================================================================

enum PunchInPlanner {
    /// パンチインのカット位置(元素材の秒)。発話の始まりを使い、無ければ fallbackInterval 秒ごと。
    /// 隣のカットとは minGap 秒以上あけ、クリップの両端 1.5 秒には入れない
    static func cutPoints(for clip: Clip, index: Int, guardSpeech: SpeechGuard,
                          fallbackInterval: Double, minGap: Double = 2.5) -> [Double] {
        let lower = clip.startTime + 1.5
        let upper = clip.endTime - 1.5
        guard upper > lower else { return [] }
        var starts = guardSpeech.utteranceStarts(clip: index).filter { $0 > lower && $0 < upper }
        if starts.isEmpty {
            var t = clip.startTime + fallbackInterval
            while t < upper {
                starts.append(t)
                t += fallbackInterval
            }
        }
        var result: [Double] = []
        for s in starts.sorted() {
            if let last = result.last, s - last < minGap { continue }
            result.append(s)
        }
        return result
    }
}

enum FillerDetector {
    struct Span: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    /// 単語タイミングがあるときに使う(単語がそのものズバリのときだけ)
    private static let japaneseWords: Set<String> = ["えー", "えーと", "えーっと", "えっと", "えと", "ええと", "あのー", "あの", "あのう", "うーん", "んー", "んーと"]
    /// 単語タイミングが無いときは、文の中から探しても間違えにくいものだけ
    private static let japaneseSafe: [String] = ["えーっと", "えーと", "えっと", "ええと", "あのー", "あのう", "うーん", "んーと", "えー", "んー"]
    private static let english: Set<String> = ["um", "uh", "uhm", "er", "erm", "hmm", "mm", "ah", "umm"]

    static func normalize(_ text: String) -> String {
        var s = text.lowercased().replacingOccurrences(of: "〜", with: "ー").replacingOccurrences(of: "～", with: "ー")
        s = String(s.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) })
        return s
    }

    static func isFiller(_ word: String) -> Bool {
        let n = normalize(word)
        guard !n.isEmpty else { return false }
        return japaneseWords.contains(n) || english.contains(n)
    }

    /// 言いよどみの区間(出力タイムラインの秒)。単語タイミングがあればそれを、無ければ文字数から推定する
    static func spans(in cues: [SubtitleCue]) -> [Span] {
        var result: [Span] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let duration = max(0.05, cue.end - cue.start)
            if !cue.words.isEmpty {
                for word in cue.words where isFiller(word.text) && word.end > word.start {
                    result.append(Span(start: word.start, end: word.end, text: word.text))
                }
                continue
            }
            // 推定: 文字の位置を時間に比例させる(日本語は安全な語だけ、英語は単語単位)
            let text = cue.text
            let chars = max(1, text.count)
            let scalars = Array(text)
            for filler in japaneseSafe {
                var searchStart = text.startIndex
                while let range = text.range(of: filler, range: searchStart..<text.endIndex) {
                    let from = text.distance(from: text.startIndex, to: range.lowerBound)
                    let to = text.distance(from: text.startIndex, to: range.upperBound)
                    // 直後に「ー」が続くときは、それも含める(えーー)
                    var toIndex = to
                    while toIndex < scalars.count, scalars[toIndex] == "ー" { toIndex += 1 }
                    let start = cue.start + duration * Double(from) / Double(chars)
                    let end = cue.start + duration * Double(toIndex) / Double(chars)
                    result.append(Span(start: start, end: end, text: filler))
                    searchStart = range.upperBound
                }
            }
            if text.contains(" ") {
                var cursor = 0
                for token in text.split(separator: " ", omittingEmptySubsequences: false) {
                    let length = token.count
                    if english.contains(normalize(String(token))) {
                        let start = cue.start + duration * Double(cursor) / Double(chars)
                        let end = cue.start + duration * Double(cursor + length) / Double(chars)
                        result.append(Span(start: start, end: end, text: String(token)))
                    }
                    cursor += length + 1
                }
            }
        }
        // 重なりをまとめ、短すぎるものは捨てる
        let sorted = result.sorted { $0.start < $1.start }
        var merged: [Span] = []
        for span in sorted {
            if var last = merged.last, span.start <= last.end + 0.05 {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged.filter { $0.end - $0.start >= 0.12 }
    }
}

extension EditorProject {
    /// 出力タイムライン上の区間を取り除く。クリップは分割して詰め、字幕・テキスト・マーカーなども前にずらす。
    /// 取り除けた合計秒を返す(クリップの無い所は無視)
    @discardableResult
    func removeOutputRanges(_ input: [(start: Double, end: Double)]) -> Double {
        // 1) 区間を整えてまとめる
        let sorted = input.filter { $0.end > $0.start + 0.01 }.sorted { $0.start < $1.start }
        var ranges: [(start: Double, end: Double)] = []
        for r in sorted {
            if var last = ranges.last, r.start <= last.end {
                last.end = max(last.end, r.end)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(r)
            }
        }
        guard !ranges.isEmpty else { return 0 }

        // 2) クリップごとに「残す元素材の範囲」を作る
        let layout = CompositionBuilder.timelineLayout(for: snapshot())
        var newClips: [Clip] = []
        var removedOutput = 0.0
        for (index, clip) in clips.enumerated() {
            guard index < layout.count, !clip.isStill || true else { newClips.append(clip); continue }
            let placement = layout[index]
            var cuts: [(start: Double, end: Double)] = []
            for r in ranges where r.end > placement.start && r.start < placement.end {
                let a = clip.sourceTime(atOutputOffset: max(0, r.start - placement.start))
                let b = clip.sourceTime(atOutputOffset: min(placement.end, r.end) - placement.start)
                if b > a + 0.01 { cuts.append((a, b)) }
            }
            guard !cuts.isEmpty else { newClips.append(clip); continue }
            var kept: [(start: Double, end: Double)] = []
            var cursor = clip.startTime
            for c in cuts.sorted(by: { $0.start < $1.start }) {
                if c.start > cursor + 0.05 { kept.append((cursor, c.start)) }
                cursor = max(cursor, c.end)
            }
            if clip.endTime > cursor + 0.05 { kept.append((cursor, clip.endTime)) }
            let keptSource = kept.reduce(0.0) { $0 + ($1.end - $1.start) }
            removedOutput += max(0, clip.trimmedDuration - keptSource) / max(clip.speed, 0.01)
            for (j, range) in kept.enumerated() {
                var piece = (j == 0) ? clip : clip.duplicated()
                piece.startTime = range.start
                piece.endTime = range.end
                // 同じクリップの中のジャンプカットにはトランジションを付けない(最後の切れ端だけ元のまま)
                if j < kept.count - 1 { piece.transition = ClipTransition() }
                newClips.append(piece)
            }
        }
        clips = newClips

        // 3) タイムライン上の部品を前にずらす
        func shifted(_ t: Double) -> Double {
            var removedBefore = 0.0
            for r in ranges {
                if t >= r.end { removedBefore += r.end - r.start }
                else if t > r.start { removedBefore += t - r.start }
            }
            return max(0, t - removedBefore)
        }
        subtitles = subtitles.compactMap { cue in
            var c = cue
            c.start = shifted(cue.start)
            c.end = shifted(cue.end)
            guard c.end - c.start >= 0.1 else { return nil }
            c.words = cue.words.compactMap { w in
                var word = w
                word.start = shifted(w.start)
                word.end = shifted(w.end)
                return word.end - word.start >= 0.02 ? word : nil
            }
            return c
        }
        for i in textClips.indices { textClips[i].start = shifted(textClips[i].start) }
        for i in narration.indices { narration[i].start = shifted(narration[i].start) }
        for i in overlays.indices { overlays[i].start = shifted(overlays[i].start) }
        for i in drawings.indices { drawings[i].start = shifted(drawings[i].start) }
        for i in videoEffects.indices { videoEffects[i].start = shifted(videoEffects[i].start) }
        for i in markers.indices { markers[i].time = shifted(markers[i].time) }
        for i in titleCards.indices { titleCards[i].start = shifted(titleCards[i].start) }
        for i in lowerThirds.indices { lowerThirds[i].start = shifted(lowerThirds[i].start) }
        return removedOutput
    }

    /// time 以降にある字幕・テキスト・マーカーなどを delta 秒だけ後ろへずらす(先頭にクリップを差し込んだときに使う)
    func shiftTimelineItems(from time: Double, by delta: Double) {
        guard abs(delta) > 0.001 else { return }
        func move(_ t: Double) -> Double { t >= time - 0.001 ? max(0, t + delta) : t }
        for i in subtitles.indices {
            subtitles[i].start = move(subtitles[i].start)
            subtitles[i].end = move(subtitles[i].end)
            for w in subtitles[i].words.indices {
                subtitles[i].words[w].start = move(subtitles[i].words[w].start)
                subtitles[i].words[w].end = move(subtitles[i].words[w].end)
            }
        }
        for i in textClips.indices { textClips[i].start = move(textClips[i].start) }
        for i in narration.indices { narration[i].start = move(narration[i].start) }
        for i in overlays.indices { overlays[i].start = move(overlays[i].start) }
        for i in drawings.indices { drawings[i].start = move(drawings[i].start) }
        for i in videoEffects.indices { videoEffects[i].start = move(videoEffects[i].start) }
        for i in markers.indices { markers[i].time = move(markers[i].time) }
        for i in titleCards.indices { titleCards[i].start = move(titleCards[i].start) }
        for i in lowerThirds.indices { lowerThirds[i].start = move(lowerThirds[i].start) }
    }
}
