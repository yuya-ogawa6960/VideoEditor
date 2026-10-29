import Foundation

// =====================================================================
// リール風のおまかせテンプレの仕上げ(AutoEditor.build のあとにかける)。
//   tempoTalk : テンポ系トーク。無音と言いよどみを詰め、カットごとに寄り・引きを交互に、
//               話題の変わり目(8 秒以上あけて)に「白飛びフラッシュ」。キャプションは小さめのカラオケ風を上に
//   kurashi   : 丁寧な暮らし系。明るくやわらかい色、ゆっくりしたディゾルブ、細い明朝のタイトルとキャプション
//   recipe / roomTour / travelBeat / grwm / pet / cafe / beforeAfter / gameHighlight:
//               色(クリップごとの補正)・つなぎ・キャプションの見た目・冒頭のタイトルを決めるだけの軽い仕上げ
// どちらも EditorProject を直接書きかえる(呼ぶ側で履歴を 1 回記録してから呼ぶ)。
// キャプションの文字は作らない(作成は「キャプションを作成」から。見た目だけ先に決めておく)。
// =====================================================================

enum ReelFinish: String {
    case tempoTalk, kurashi
    case recipe, roomTour, travelBeat, grwm, pet, cafe, beforeAfter, gameHighlight
}

@MainActor
enum ReelFinisher {

    /// 仕上げの結果(画面に出す一言に使う)
    struct Summary {
        var silenceCuts = 0
        var fillerCuts = 0
        var flashes = 0
    }

    static func apply(_ finish: ReelFinish, to project: EditorProject,
                      progress: ((Double) -> Void)?) async throws -> Summary {
        switch finish {
        case .tempoTalk:
            return try await applyTempoTalk(to: project, progress: progress)
        case .kurashi:
            applyKurashi(to: project)
            progress?(1)
            return Summary()
        case .recipe:
            applyRecipe(to: project)
        case .roomTour:
            applyRoomTour(to: project)
        case .travelBeat:
            applyTravelBeat(to: project)
        case .grwm:
            applyGRWM(to: project)
        case .pet:
            applyPet(to: project)
        case .cafe:
            applyCafe(to: project)
        case .beforeAfter:
            applyBeforeAfter(to: project)
        case .gameHighlight:
            applyGameHighlight(to: project)
        }
        progress?(1)
        return Summary()
    }

    // MARK: - テンポ系トーク

    /// 寄りの倍率
    private static let punchZoom = 1.18
    /// フラッシュどうしの最低間隔(秒)
    private static let flashSpacing = 8.0

    private static func applyTempoTalk(to project: EditorProject,
                                       progress: ((Double) -> Void)?) async throws -> Summary {
        var summary = Summary()

        // 1. 無音を詰める(テンポよく)。字幕などもいっしょに前へずらす
        let pace = SilenceCutPace.snappy
        let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
        var silentOutput: [(start: Double, end: Double)] = []
        let targets = Array(project.clips.enumerated())
        for (index, clip) in targets {
            try Task.checkCancellation()
            progress?(0.05 + 0.45 * Double(index) / Double(max(targets.count, 1)))
            guard index < layout.count, clip.hasAudio, !clip.isMuted, !clip.isStill, !clip.isReversed,
                  !clip.speedCurve.enabled else { continue }
            let silences: [AudioAnalysis.SilenceRange]
            do {
                silences = try await AudioAnalysis.detectSilence(in: clip.url, start: clip.startTime, end: clip.endTime,
                                                                 minimumDuration: pace.minimumDuration,
                                                                 padding: pace.padding)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            let placement = layout[index]
            for silence in silences {
                let a = placement.start + ClipFXTimeline.outputOffset(sourceTime: silence.start, clip: clip)
                let b = placement.start + ClipFXTimeline.outputOffset(sourceTime: silence.end, clip: clip)
                if b > a + 0.05 { silentOutput.append((start: a, end: min(b, placement.end))) }
            }
        }
        if !silentOutput.isEmpty {
            summary.silenceCuts = silentOutput.count
            project.removeOutputRanges(silentOutput)
        }
        progress?(0.55)

        // 2. 言いよどみ(キャプションがあるときだけ)
        if !project.subtitles.isEmpty {
            let spans = FillerDetector.spans(in: project.subtitles)
            if !spans.isEmpty {
                summary.fillerCuts = spans.count
                project.removeOutputRanges(spans.map { (start: max(0, $0.start - 0.03), end: $0.end + 0.03) })
            }
        }
        try Task.checkCancellation()

        // 3. 長いカットは話の区切りでさらに分ける(パンチイン用)
        let snapshot = project.snapshot()
        try await HighlightAnalyzer.ensureVoiceRuns(snapshot: snapshot) { fraction in
            progress?(0.6 + 0.3 * fraction)
        }
        try Task.checkCancellation()
        let guardSpeech = SpeechGuard(snapshot: snapshot, pad: 0)
        var splits: [(id: UUID, cuts: [Double])] = []
        for (index, clip) in snapshot.clips.enumerated() where !clip.isStill && clip.outputDuration > 5 {
            let cuts = PunchInPlanner.cutPoints(for: clip, index: index, guardSpeech: guardSpeech,
                                                fallbackInterval: 3.5, minGap: 2.0)
            if !cuts.isEmpty { splits.append((clip.id, cuts)) }
        }
        for item in splits {
            for t in item.cuts.sorted(by: >) {
                _ = project.splitClip(id: item.id, atSourceTime: t)
            }
        }

        // 4. カットごとに寄り・引きを交互に。トランジションは基本なし(ジャンプカット)
        let before = project.captureClipLayout()
        var punched = false
        for i in project.clips.indices {
            let base = project.clips[i].geometry.zoom
            if punched {
                project.clips[i].geometry.zoom = min(4, max(1, base) * punchZoom)
            }
            project.clips[i].transition = ClipTransition()
            punched.toggle()
        }

        // 5. 話題の変わり目に白飛びフラッシュ(前のフラッシュから flashSpacing 秒以上あけ、いちばん長く詰めた所を選ぶ)
        // 切れ目(クリップの終わり。最後のクリップは除く)の時刻と、そこで詰めた無音の長さ
        let cutEnds = CompositionBuilder.timelineLayout(for: project.snapshot()).map(\.end)
        var candidates: [(index: Int, time: Double, score: Double)] = []
        for (index, time) in cutEnds.enumerated() where index < project.clips.count - 1 {
            candidates.append((index, time, removedSilence(near: time, silentOutput: silentOutput)))
        }
        // 前のフラッシュから flashSpacing 秒たった所から 4 秒の間で、いちばん長く詰めた切れ目を選ぶ
        var chosen: [Int] = []
        var lastFlash = 2.0 - flashSpacing   // 冒頭 2 秒は入れない
        var i = 0
        while i < candidates.count {
            guard candidates[i].time - lastFlash >= flashSpacing else {
                i += 1
                continue
            }
            let windowStart = candidates[i].time
            var j = i
            var best = candidates[i]
            while j < candidates.count, candidates[j].time - windowStart <= 4 {
                if candidates[j].score > best.score { best = candidates[j] }
                j += 1
            }
            chosen.append(best.index)
            lastFlash = best.time
            i = j
        }
        for index in chosen where index < project.clips.count - 1 {
            let length = min(0.24, project.clips[index].outputDuration / 2, project.clips[index + 1].outputDuration / 2)
            guard length >= 0.1 else { continue }
            project.clips[index].transition = ClipTransition(type: .exposureFlash, duration: length)
            summary.flashes += 1
        }
        project.rippleTimelineItems(from: before)

        // 6. キャプションの見た目: 小さめの丸ゴシック、話している単語を黄色に、上のほう
        var style = project.subtitleStyle
        style.template = .karaoke
        style.fontName = "RoundedMplus1c-Bold"
        style.color = .white
        style.highlightColorHex = "#FFD54A"
        style.sizeRatio = 0.042
        style.position = .top
        style.hasBackground = false
        project.subtitleStyle = style
        progress?(1)
        return summary
    }

    /// 今の時刻 time の切れ目で詰めた無音の長さ(大きいほど話題の変わり目らしい)。
    /// silentOutput は詰める前の時刻なので、それより前で詰めた合計を引いて今の時刻に直して比べる
    /// (言いよどみを詰めた分のずれは小さいので無視する)
    private static func removedSilence(near time: Double, silentOutput: [(start: Double, end: Double)]) -> Double {
        var removedBefore = 0.0
        var best = 0.0
        for range in silentOutput.sorted(by: { $0.start < $1.start }) {
            let length = max(0, range.end - range.start)
            if abs((range.start - removedBefore) - time) < 0.3 { best = max(best, length) }
            removedBefore += length
        }
        return best
    }

    // MARK: - 丁寧な暮らし系

    /// 雑誌や暮らし系 Vlog のような、自然光の明るくやわらかい空気感。
    /// 細い明朝・広い字間の静かな文字、ゆっくりしたディゾルブ
    private static func applyKurashi(to project: EditorProject) {
        // 1. 色: 明るく、コントラストと彩度は控えめ、ほんのり暖かく、白飛びを抑えて影を持ち上げる
        //    (全体のルックは外して、クリップごとの補正だけにする)
        project.documentary.look = .none
        project.documentary.vignette = 0
        project.documentary.filmGrain = 0
        project.documentary.letterbox = false
        for i in project.clips.indices {
            var filter = project.clips[i].filter
            filter.preset = .none
            filter.adjustments.exposure = 0.25
            filter.adjustments.brightness = 0.03
            filter.adjustments.contrast = 0.88
            filter.adjustments.saturation = 0.85
            filter.adjustments.temperature = 0.12
            filter.adjustments.highlights = -0.25
            filter.adjustments.shadows = 0.3
            project.clips[i].filter = filter
        }

        // 2. つなぎ: ゆっくりしたディゾルブ(長さが変わるので字幕などを付いたまま動かす)
        let before = project.captureClipLayout()
        for i in project.clips.indices where i < project.clips.count - 1 {
            let limit = min(project.clips[i].outputDuration, project.clips[i + 1].outputDuration) / 2
            let length = min(0.9, limit)
            project.clips[i].transition = length >= 0.2
                ? ClipTransition(type: .dissolve, duration: length)
                : ClipTransition()
        }
        project.rippleTimelineItems(from: before)

        // 3. キャプション: 細い明朝・白・小さめ・下(縁取りや帯は付けない)
        var style = project.subtitleStyle
        style.template = .plain
        style.fontName = "HiraMinProN-W3"
        style.color = .white
        style.sizeRatio = 0.032
        style.position = .bottom
        style.hasBackground = false
        project.subtitleStyle = style

        // 4. 冒頭のタイトル(あとで書きかえられる): 細い英字の大きな一行と、字間を広げた明朝の一行
        var title = TextClip(text: "My Daily Vlog", start: 0.4)
        title.duration = 3.6
        title.center = NormalizedPoint(x: 0.5, y: 0.46)
        title.widthRatio = 0.9
        title.template = .minimalSerif
        title.style.fontName = "AvenirNext-UltraLight"
        title.style.bold = false
        title.style.sizeRatio = 0.1
        title.style.colorHex = "#FFFFFF"
        title.style.letterSpacing = 0.03
        title.style.shadow.opacity = 0.25
        title.animIn = .fade
        title.animInDuration = 0.8
        title.animOut = .fade
        title.animOutDuration = 0.7

        var sub = TextClip(text: String(localized: "丁寧に暮らす、わたしの一日。"), start: 0.7)
        sub.duration = 3.3
        sub.center = NormalizedPoint(x: 0.5, y: 0.555)
        sub.widthRatio = 0.9
        sub.template = .minimalSerif
        sub.style.fontName = "HiraMinProN-W3"
        sub.style.bold = false
        sub.style.sizeRatio = 0.032
        sub.style.colorHex = "#FFFFFF"
        sub.style.letterSpacing = 0.35
        sub.style.shadow.opacity = 0.3
        sub.animIn = .fade
        sub.animInDuration = 0.8
        sub.animOut = .fade
        sub.animOutDuration = 0.7

        project.textClips.append(contentsOf: [title, sub])
        project.sortTextClips()
    }

    // MARK: - 料理レシピ(手元・テンポ)

    /// 料理がおいしそうに見える、少し暖かく鮮やかな色。つなぎ無しのテンポのいいカット、
    /// 手順が読みやすい帯つきの丸ゴシックのキャプション、冒頭に大きなタイトル
    private static func applyRecipe(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.12
            a.contrast = 1.06
            a.saturation = 1.18
            a.temperature = 0.1
            a.highlights = -0.15
            a.shadows = 0.1
            a.sharpness = 0.15
        }
        applyTransitions(to: project, maxLength: 0) { _ in .none }
        setCaption(project, template: .boxPop, font: "ZenMaruGothic-Bold", size: 0.045, position: .bottom, background: true)
        addTitle(project, text: String(localized: "今日のレシピ"), template: .bigImpact, font: "DelaGothicOne-Regular",
                 size: 0.1, colorHex: "#FFFFFF", y: 0.2, animIn: .pop)
    }

    // MARK: - ルームツアー

    /// 白い壁がくすまない、明るく少しすっきりした色。部屋から部屋へ横に流れるつなぎ、
    /// 細めのキャプション、冒頭に「ROOM TOUR」
    private static func applyRoomTour(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.22
            a.contrast = 0.96
            a.saturation = 0.95
            a.temperature = -0.03
            a.highlights = -0.2
            a.shadows = 0.25
        }
        applyTransitions(to: project, maxLength: 0.35) { i in i % 2 == 0 ? .whipLeft : .whipRight }
        setCaption(project, template: .plain, font: "ZenMaruGothic-Bold", size: 0.036, position: .bottom, background: false)
        addTitle(project, text: "ROOM TOUR", template: .headline, font: "AvenirNext-Bold",
                 size: 0.1, colorHex: "#FFFFFF", y: 0.45, animIn: .slideUp, letterSpacing: 0.12)
    }

    // MARK: - 旅行ハイライト(ビート)

    /// 空と海が映える鮮やかな色。ビートの切れ目にズームブラーとホイップを交互に、冒頭に大きな「TRIP」
    private static func applyTravelBeat(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.05
            a.contrast = 1.1
            a.saturation = 1.22
            a.temperature = 0.04
            a.highlights = -0.2
            a.shadows = 0.1
        }
        applyTransitions(to: project, maxLength: 0.25) { i in
            switch i % 3 {
            case 0: return .zoomBlur
            case 1: return .none
            default: return .whipLeft
            }
        }
        setCaption(project, template: .outlineBig, font: "RoundedMplus1c-Bold", size: 0.05, position: .center, background: false)
        addTitle(project, text: "TRIP", template: .bigImpact, font: "Fraunces-Black",
                 size: 0.16, colorHex: "#FFFFFF", y: 0.42, duration: 1.8, animIn: .scaleDown)
    }

    // MARK: - ファッション / GRWM

    /// 肌がきれいに見える、明るくやわらかい色と美肌。テンポのいいフラッシュのつなぎ、
    /// 話している言葉に色が付くキャプション、冒頭に「GET READY WITH ME」
    private static func applyGRWM(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.15
            a.contrast = 0.95
            a.saturation = 0.96
            a.temperature = 0.05
            a.highlights = -0.18
            a.shadows = 0.15
        }
        for i in project.clips.indices where !project.clips[i].isStill {
            project.clips[i].enhance.retouch = max(project.clips[i].enhance.retouch, 0.35)
        }
        applyTransitions(to: project, maxLength: 0.2) { i in i % 2 == 1 ? .flash : .none }
        setCaption(project, template: .pillHighlight, font: "ZenMaruGothic-Bold", highlight: "#FF8FB1",
                   size: 0.042, position: .bottom, background: false)
        addTitle(project, text: "GET READY WITH ME", template: .headline, font: "Quicksand-Bold",
                 size: 0.07, colorHex: "#FFFFFF", y: 0.18, animIn: .slideUp, letterSpacing: 0.06)
    }

    // MARK: - ペット

    /// 毛並みがふんわり見える、明るく暖かい色。ときどき寄るつなぎ、手書き風のポップなキャプションとタイトル
    private static func applyPet(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.15
            a.contrast = 1.0
            a.saturation = 1.08
            a.temperature = 0.1
            a.highlights = -0.15
            a.shadows = 0.2
        }
        applyTransitions(to: project, maxLength: 0.3) { i in i % 3 == 2 ? .zoomIn : .none }
        setCaption(project, template: .boxPop, font: "HachiMaruPop-Regular", size: 0.046, position: .bottom, background: true)
        addTitle(project, text: String(localized: "うちの子"), template: .handwritten, font: "HachiMaruPop-Regular",
                 size: 0.1, colorHex: "#FFF2B2", y: 0.2, animIn: .pop)
    }

    // MARK: - カフェ巡り

    /// フィルムのような、暖かく少し落ち着いた色と薄い粒子。ゆっくりめのディゾルブ、
    /// 細い明朝のキャプション、冒頭に筆記体の「café time」
    private static func applyCafe(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.08
            a.contrast = 0.94
            a.saturation = 0.88
            a.temperature = 0.18
            a.highlights = -0.22
            a.shadows = 0.18
        }
        project.documentary.filmGrain = 0.15
        project.documentary.vignette = 0.15
        applyTransitions(to: project, maxLength: 0.6) { _ in .dissolve }
        setCaption(project, template: .plain, font: "HiraMinProN-W3", size: 0.034, position: .bottom, background: false)
        addTitle(project, text: "café time", template: .plain, font: "Pacifico-Regular",
                 size: 0.11, colorHex: "#FFF8EE", y: 0.46, duration: 3.0, animIn: .fade, animInDuration: 0.8)
    }

    // MARK: - Before / After

    /// 最初のクリップに「BEFORE」、最後のクリップに「AFTER」。After の直前だけ白く光らせる(色は変えない)。
    /// クリップが 1 つなら前半と後半に分ける
    private static func applyBeforeAfter(to project: EditorProject) {
        if project.clips.count >= 2 {
            let before = project.captureClipLayout()
            for i in project.clips.indices {
                project.clips[i].transition = ClipTransition()
            }
            let i = project.clips.count - 2
            let length = min(0.3, project.clips[i].outputDuration / 2, project.clips[i + 1].outputDuration / 2)
            if length >= 0.1 {
                project.clips[i].transition = ClipTransition(type: .exposureFlash, duration: length)
            }
            project.rippleTimelineItems(from: before)
        }

        let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
        guard let last = layout.last, last.end > 0.5 else { return }
        let beforeRange: (start: Double, end: Double)
        let afterRange: (start: Double, end: Double)
        if layout.count >= 2 {
            beforeRange = (layout[0].start, layout[0].end)
            afterRange = (last.start, last.end)
        } else {
            let half = last.end / 2
            beforeRange = (0, half)
            afterRange = (half, last.end)
        }
        for (text, range) in [("BEFORE", beforeRange), ("AFTER", afterRange)] {
            let length = range.end - range.start
            guard length >= 0.4 else { continue }
            addTitle(project, text: text, template: .bigImpact, font: "DelaGothicOne-Regular",
                     size: 0.09, colorHex: text == "AFTER" ? "#FFE600" : "#FFFFFF", y: 0.14,
                     start: range.start + 0.05, duration: max(0.3, length - 0.1), animIn: .pop, animOut: .none)
        }
        setCaption(project, template: .outlineBig, font: "HiraginoSans-W6", size: 0.05, position: .bottom, background: false)
    }

    // MARK: - ゲーム実況ハイライト

    /// 画面がくっきり見える、コントラスト高めの色。ときどきグリッチのつなぎ、
    /// 太い縁取りのキャプション(話している言葉を黄色に)、冒頭に「HIGHLIGHTS」
    private static func applyGameHighlight(to project: EditorProject) {
        applyColor(to: project) { a in
            a.exposure = 0.03
            a.contrast = 1.12
            a.saturation = 1.15
            a.sharpness = 0.25
        }
        applyTransitions(to: project, maxLength: 0.2) { i in i % 2 == 1 ? .glitch : .none }
        setCaption(project, template: .karaoke, font: "DelaGothicOne-Regular", highlight: "#FFE600",
                   size: 0.05, position: .bottom, background: false)
        addTitle(project, text: "HIGHLIGHTS", template: .neon, font: "AvenirNext-HeavyItalic",
                 size: 0.1, colorHex: "#9FF8FF", y: 0.45, duration: 1.8, animIn: .scaleDown)
    }

    // MARK: - 仕上げの共通部品

    /// クリップごとの色補正にする(全体のルック・プリセットは外す。LUT はそのまま)。edit で値を決める
    private static func applyColor(to project: EditorProject, _ edit: (inout ColorAdjustments) -> Void) {
        project.documentary.look = LookPreset.none
        project.documentary.vignette = 0
        project.documentary.filmGrain = 0
        project.documentary.letterbox = false
        for i in project.clips.indices {
            var filter = project.clips[i].filter
            filter.preset = .none
            var adjustments = ColorAdjustments()
            edit(&adjustments)
            filter.adjustments = adjustments
            project.clips[i].filter = filter
        }
    }

    /// つなぎを決める(pick はクリップ番号 → 種類)。長さは前後のクリップの半分まで。
    /// 長さが変わるので字幕などを付いたまま動かす
    private static func applyTransitions(to project: EditorProject, maxLength: Double,
                                         _ pick: (Int) -> TransitionType) {
        let before = project.captureClipLayout()
        for i in project.clips.indices {
            guard i < project.clips.count - 1 else {
                project.clips[i].transition = ClipTransition()
                continue
            }
            let limit = min(project.clips[i].outputDuration, project.clips[i + 1].outputDuration) / 2
            let length = min(maxLength, limit)
            let type = pick(i)
            project.clips[i].transition = (type != .none && length >= 0.2)
                ? ClipTransition(type: type, duration: length)
                : ClipTransition()
        }
        project.rippleTimelineItems(from: before)
    }

    /// キャプションの見た目だけ決める(文字は作らない)
    private static func setCaption(_ project: EditorProject, template: CaptionTemplate, font: String?,
                                   highlight: String? = nil, size: CGFloat, position: SubtitlePosition,
                                   background: Bool) {
        var style = project.subtitleStyle
        style.template = template
        style.fontName = font
        style.color = .white
        if let highlight { style.highlightColorHex = highlight }
        style.sizeRatio = size
        style.position = position
        style.hasBackground = background
        project.subtitleStyle = style
    }

    /// 冒頭などのタイトル(あとで書きかえられる)
    private static func addTitle(_ project: EditorProject, text: String, template: TextTemplate, font: String?,
                                 size: Double, colorHex: String, y: Double,
                                 start: Double = 0.3, duration: Double = 2.4,
                                 animIn: TextAnimationType, animInDuration: Double = 0.4,
                                 animOut: TextAnimationType = .fade, letterSpacing: Double? = nil) {
        var title = TextClip(text: text, start: start)
        title.duration = duration
        title.center = NormalizedPoint(x: 0.5, y: y)
        title.widthRatio = 0.9
        title.template = template
        title.style = TextStyle.preset(template)
        if let font { title.style.fontName = font }
        title.style.sizeRatio = size
        title.style.colorHex = colorHex
        if let letterSpacing { title.style.letterSpacing = letterSpacing }
        title.animIn = animIn
        title.animInDuration = animInDuration
        title.animOut = animOut
        title.animOutDuration = animOut == .none ? 0.5 : 0.4
        project.textClips.append(title)
        project.sortTextClips()
    }
}
