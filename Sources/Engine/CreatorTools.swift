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
        // 「えー！」「んー？」は驚きの声や問いかけ。字幕に残すものを言いよどみとして切らない(SubtitleSegmenter と同じ判定)
        if japaneseWords.contains(n) { return !SubtitleSegmenter.endsWithExclamation(word) }
        return english.contains(n)
    }

    /// 言いよどみの区間(出力タイムラインの秒)。単語タイミングがあればそれを、無ければ文字数から推定する
    static func spans(in cues: [SubtitleCue]) -> [Span] {
        var result: [Span] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let duration = max(0.05, cue.end - cue.start)
            // 字幕から取り除いた言いよどみ(「え〜」など)も候補にする。字幕の時刻が作ったときのままのときだけ
            // (タイムラインを編集すると元の時刻は使えない)
            if let removed = cue.removedFillers, removed.cueStart == cue.start, removed.cueEnd == cue.end {
                for word in removed.words where isFiller(word.text) && word.end > word.start {
                    result.append(Span(start: word.start, end: word.end, text: word.text))
                }
            }
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
    /// 出力タイムライン上の区間を取り除く。クリップは分割して詰め、字幕・テキスト(モザイク)・B ロール・ナレーション・マーカーなども
    /// クリップの削除と同じように消したり詰めたりする。トランジションの重なりの所は切らない。
    /// 実際に短くなった秒を返す(クリップの無い所は無視)
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

        // 2) クリップごとに「残す元素材の範囲」を作る。トランジションの重なりは次のように扱う(無音カットと同じ考え方):
        //    - 区間が重なりを両側に余裕をもって覆っているときは、重なりごと前後のクリップから切る(つなぎ目は残りの映像どうしになる)
        //    - それ以外は、重なりの 2 倍(前のクリップの終わり・後ろのクリップの頭)は切らない。重なりの中や端だけを切ると、
        //      短い切れ端が挟まって重なりが変わり、作品の長さと字幕などの詰め方が合わなくなって、つなぎ目ごとに遅れていった
        //    区間がクリップを丸ごと覆うときは、クリップごと取り除く。
        //    逆再生のクリップは分割と同じく切らない(画面の向きと元素材の向きが逆で、違う所を切ってしまう)
        let oldLayout = CompositionBuilder.timelineLayout(for: snapshot())
        /// つなぎ目 k(クリップ k と k+1 の間)の重なり [後ろのクリップの頭, 前のクリップの終わり]。無ければ nil
        func overlapRegion(_ k: Int) -> (start: Double, end: Double)? {
            guard k >= 0, k + 1 < oldLayout.count else { return nil }
            let start = oldLayout[k + 1].start
            let end = oldLayout[k].end
            return end > start + 0.0005 ? (start: start, end: end) : nil
        }
        /// 区間 r がつなぎ目 k の重なりを、両側に余裕をもって覆っているか(重なりが無いつなぎ目は true)
        func cutsThrough(_ r: (start: Double, end: Double), _ k: Int) -> Bool {
            guard let o = overlapRegion(k) else { return true }
            return r.start < o.start - 0.01 && r.end > o.end + 0.01
        }
        var newClips: [Clip] = []
        /// クリップごとに取り除いた区間(組み立て直す前の出力タイムラインの秒)
        var clipRemoved: [[(start: Double, end: Double)]] = []
        /// 元のクリップごとの、組み立て直したあとの最初の切れ端の番号(丸ごと取り除いたら nil)
        var firstPiece: [Int?] = []
        for (index, clip) in clips.enumerated() {
            guard index < oldLayout.count, !(clip.isReversed && clip.reversedURL != nil) else {
                clipRemoved.append([])
                firstPiece.append(newClips.count)
                newClips.append(clip)
                continue
            }
            let placement = oldLayout[index]
            let inOverlap = overlapRegion(index - 1).map { $0.end - $0.start } ?? 0
            let outOverlap = overlapRegion(index).map { $0.end - $0.start } ?? 0
            var cuts: [(start: Double, end: Double)] = []
            for r in ranges where r.end > placement.start && r.start < placement.end {
                let whole = r.start <= placement.start + 0.001 && r.end >= placement.end - 0.001
                let lower = (whole || cutsThrough(r, index - 1))
                    ? max(r.start, placement.start) : max(r.start, placement.start + 2 * inOverlap)
                let upper = (whole || cutsThrough(r, index))
                    ? min(r.end, placement.end) : min(r.end, placement.end - 2 * outOverlap)
                guard upper > lower + 0.01 else { continue }
                let a = clip.sourceTime(atOutputOffset: lower - placement.start)
                let b = clip.sourceTime(atOutputOffset: upper - placement.start)
                if b > a + 0.01 { cuts.append((a, b)) }
            }
            guard !cuts.isEmpty else {
                clipRemoved.append([])
                firstPiece.append(newClips.count)
                newClips.append(clip)
                continue
            }
            var kept: [(start: Double, end: Double)] = []
            var cursor = clip.startTime
            for c in cuts.sorted(by: { $0.start < $1.start }) {
                if c.start > cursor + 0.05 { kept.append((cursor, c.start)) }
                cursor = max(cursor, c.end)
            }
            if clip.endTime > cursor + 0.05 { kept.append((cursor, clip.endTime)) }
            // 取り除いた元素材(残す範囲のすき間)を、組み立て直す前の出力タイムラインの秒にして控える
            var removedHere: [(start: Double, end: Double)] = []
            var cutStart = clip.startTime
            for range in kept + [(start: clip.endTime, end: clip.endTime)] {
                if range.start > cutStart + 0.0005 {
                    removedHere.append((start: placement.start + clip.outputOffset(atSourceTime: cutStart),
                                        end: placement.start + clip.outputOffset(atSourceTime: range.start)))
                }
                cutStart = max(cutStart, range.end)
            }
            clipRemoved.append(removedHere)
            firstPiece.append(kept.isEmpty ? nil : newClips.count)
            for (j, range) in kept.enumerated() {
                var piece = (j == 0) ? clip : clip.duplicated()
                // 速度カーブ・被写体フラッシュも切れ端に合わせる(Clip.restrictToSource)
                piece.restrictToSource(range.start, range.end, of: clip,
                                       flashFrom: j == 0 ? clip.startTime : kept[j - 1].end)
                // 同じクリップの中のジャンプカットはふつうのカットにする(最後の切れ端だけ元のトランジションのまま。
                // J/L カット・フェード・アニメーションも切れ目には付けない)
                piece.clearCutEdges(head: j > 0, tail: j < kept.count - 1)
                newClips.append(piece)
            }
        }
        clips = newClips

        // 部品を詰める区間: 1 本のクリップだけが映っている所はそのクリップで取り除いた所。トランジションの重なりは、
        // 前後の両方のクリップで取り除いた所だけ(片方が残っていれば、そこにある部品も残す)
        func intersect(_ list: [(start: Double, end: Double)], _ lo: Double, _ hi: Double) -> [(start: Double, end: Double)] {
            var result: [(start: Double, end: Double)] = []
            for r in list {
                let s = max(r.start, lo)
                let e = min(r.end, hi)
                if e > s + 0.0005 { result.append((start: s, end: e)) }
            }
            return result
        }
        var removed: [(start: Double, end: Double)] = []
        for index in clipRemoved.indices where index < oldLayout.count {
            let lo = oldLayout[index].start + (overlapRegion(index - 1).map { $0.end - $0.start } ?? 0)
            let hi = max(lo, oldLayout[index].end - (overlapRegion(index).map { $0.end - $0.start } ?? 0))
            removed += intersect(clipRemoved[index], lo, hi)
            if let o = overlapRegion(index), index + 1 < clipRemoved.count {
                for part in intersect(clipRemoved[index], o.start, o.end) {
                    removed += intersect(clipRemoved[index + 1], part.start, part.end)
                }
            }
        }

        // 3) タイムライン上の部品を、クリップの削除・無音カットと同じ removeTimelineRange で消したり詰めたりする(TimelineRipple.swift)。
        //    区間の中だけにある B ロール・効果音・映像エフェクト・テロップは消え、またぐものは縮み、追尾のモザイクやステッカーの
        //    キーフレームも同じだけ詰まり、リンク解除した音声も映像と同じ所で切れる。前は開始位置しか動かさなかったので、
        //    モザイクが顔から外れて顔が映ったり、消した文の B ロール・効果音が次の話の上に出たり、分けた音声だけ消した言葉が鳴り続けたりしていた
        var gaps: [(start: Double, end: Double)] = []
        for r in removed.sorted(by: { $0.start < $1.start }) {
            if let last = gaps.last, r.start <= last.end + 0.0005 {
                gaps[gaps.count - 1].end = max(last.end, r.end)
            } else {
                gaps.append(r)
            }
        }
        func shifted(_ t: Double) -> Double {
            var removedBefore = 0.0
            for r in gaps {
                if t >= r.end { removedBefore += r.end - r.start }
                else if t > r.start { removedBefore += t - r.start }
            }
            return max(0, t - removedBefore)
        }
        // 元のクリップの頭が、詰めたあとに来るはずの時刻(4) で実際の並びと比べる)
        let expectedStarts: [Double] = oldLayout.map { shifted($0.start) }
        // 字幕は前と同じ扱い(短くなった字幕は 0.1 秒まで残し、0.02 秒未満になった単語は外す)
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
        // マーカー(章の区切りなど)は消さずに、詰めた先へ寄せる(無音カットと同じ)
        for i in markers.indices { markers[i].time = shifted(markers[i].time) }
        // 後ろの区間から詰めるので、前の区間の秒は変わらない
        for gap in gaps.reversed() {
            removeTimelineRange(from: gap.start, to: gap.end, keepingSubtitlesAndMarkers: true)
        }

        // 4) 切れ端が短くなったり、クリップを丸ごと取り除いたりしてトランジションの重なりが変わった所は、
        //    再生と同じ並べ方(CompositionBuilder.timelineLayout)で測った実際の位置との差だけ、後ろの部品をずらす
        let newLayout = CompositionBuilder.timelineLayout(for: snapshot())
        var corrections: [(time: Double, delta: Double)] = []
        var applied = 0.0
        for (index, first) in firstPiece.enumerated() where index < expectedStarts.count {
            guard let pieceIndex = first, pieceIndex < newLayout.count else { continue }
            let error = newLayout[pieceIndex].start - expectedStarts[index]
            if abs(error - applied) > 0.002 {
                corrections.append((time: expectedStarts[index], delta: error - applied))
                applied = error
            }
        }
        for correction in corrections.reversed() {
            shiftTimelineItems(from: correction.time, by: correction.delta)
        }
        // 実際に短くなった長さ
        let lengthBefore = oldLayout.last?.end ?? 0
        let lengthAfter = newLayout.last?.end ?? 0
        return max(0, lengthBefore - lengthAfter)
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
