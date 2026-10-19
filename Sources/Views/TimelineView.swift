import SwiftUI
import UIKit
import QuartzCore

/// CapCut 風タイムライン。
/// 中央に固定された白い再生位置の下を、トラックが横にスクロールする。
/// スクロール位置 = 時刻 × pointsPerSecond(ScrollView は使わず、ドラッグ + 慣性を自前で処理)。
struct TimelineView: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let timeline: TimelineState
    @Binding var selection: EditorSelection?

    init(project: EditorProject, player: PlayerController, history: EditorHistory,
         timeline: TimelineState, selection: Binding<EditorSelection?>) {
        self.project = project
        self.player = player
        self.history = history
        self.timeline = timeline
        self._selection = selection
    }

    /// ジェスチャー管理(変更しても再描画しない)
    @State private var interaction = TimelineInteraction()
    /// ユーザー操作中(ドラッグ・慣性)に表示する時刻。nil なら player.currentTime を表示
    @State private var scrubTime: Double? = nil
    @State private var momentumTask: Task<Void, Never>? = nil

    /// 左端トリム中は、トリム量だけ後ろのクリップを右へずらして表示(左端が指に付いてくるように)
    @State private var leftTrimClipID: UUID? = nil
    @State private var leftTrimShiftSeconds: Double = 0

    /// 長押しで並べ替え中のクリップ
    @State private var reorderClipID: UUID? = nil
    @State private var reorderAnchorX: CGFloat = 0
    @State private var reorderTranslation: CGFloat = 0

    @GestureState private var scrollGestureActive = false
    @GestureState private var editGestureActive = false
    @GestureState private var pinchGestureActive = false

    var body: some View {
        // 監視対象はここ(body)で読んでおく(GeometryReader 内でも確実に更新されるように)
        let time = scrubTime ?? player.currentTime
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        let total = project.totalDuration
        let subtitles = project.subtitles
        let audio = project.audio

        GeometryReader { geo in
            content(width: geo.size.width, time: time, pps: pps, total: total,
                    subtitles: subtitles, audio: audio)
        }
        .frame(height: TimelineMetrics.totalHeight)
        .background(TimelineMetrics.background)
        .onChange(of: editGestureActive) { _, active in
            if !active { finishEdit() }
        }
        .onChange(of: scrollGestureActive) { _, active in
            if !active { scrollGestureDidReset() }
        }
        .onChange(of: pinchGestureActive) { _, active in
            if !active { interaction.pinchStartPPS = nil }
        }
        .onDisappear {
            endScrubbing()
        }
    }

    // MARK: - 全体

    @ViewBuilder
    private func content(width: CGFloat, time: Double, pps: CGFloat, total: Double,
                         subtitles: [SubtitleCue], audio: AudioSettings) -> some View {
        // タイムライン 0 秒の画面 x 座標
        let originX = width / 2 - CGFloat(time) * pps

        ZStack(alignment: .topLeading) {
            TimelineMetrics.background
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }

            VStack(alignment: .leading, spacing: TimelineMetrics.trackSpacing) {
                TimelineRulerView(originX: originX, pointsPerSecond: pps, totalDuration: total)
                    .frame(width: width, height: TimelineMetrics.rulerHeight)
                    .allowsHitTesting(false)
                videoTrack(width: width, originX: originX, pps: pps)
                subtitleTrack(width: width, originX: originX, pps: pps, subtitles: subtitles)
                audioTrack(width: width, originX: originX, pps: pps, total: total, audio: audio)
            }
            .padding(.top, TimelineMetrics.topPadding)

            TimelinePlayheadView()
                .frame(width: width, height: TimelineMetrics.totalHeight)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: TimelineMetrics.totalHeight, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(scrollGesture)
        .simultaneousGesture(zoomGesture)
    }

    // MARK: - 映像トラック

    private func clipItems(width: CGFloat, originX: CGFloat, pps: CGFloat) -> [TimelineClipItem] {
        var result: [TimelineClipItem] = []
        let shiftIndex: Int? = leftTrimClipID.flatMap { project.index(of: $0) }
        let gap = TimelineMetrics.clipGap
        var t = 0.0
        for (i, clip) in project.clips.enumerated() {
            let fullWidth = CGFloat(clip.outputDuration) * pps
            var contentX = CGFloat(t) * pps
            t += clip.outputDuration
            if let shiftIndex, i >= shiftIndex {
                contentX += CGFloat(leftTrimShiftSeconds) * pps
            }
            var lifted = false
            if let reorderClipID, reorderClipID == clip.id {
                contentX = reorderAnchorX + reorderTranslation
                lifted = true
            }
            let screenX = originX + contentX + gap / 2
            let w = max(fullWidth - gap, 1)
            guard let span = TimelineMetrics.visibleSpan(x: screenX, width: w, viewWidth: width) else { continue }
            result.append(TimelineClipItem(id: clip.id, clip: clip, screenX: screenX, width: w,
                                           visibleX: span.x, visibleWidth: span.width, isLifted: lifted))
        }
        return result
    }

    private func videoTrack(width: CGFloat, originX: CGFloat, pps: CGFloat) -> some View {
        let h = TimelineMetrics.videoHeight
        let hw = TimelineMetrics.handleWidth
        let items = clipItems(width: width, originX: originX, pps: pps)
        let selectedClipID: UUID? = selection?.clipID
        let selectedItem: TimelineClipItem? = (reorderClipID == nil && selectedClipID != nil)
            ? items.first(where: { $0.id == selectedClipID })
            : nil
        let isEmpty = project.clips.isEmpty

        return ZStack(alignment: .topLeading) {
            if isEmpty {
                Text("動画を追加するとここに表示されます")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(width: width, height: h)
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                TimelineClipView(clip: item.clip,
                                 screenX: item.screenX,
                                 fullWidth: item.width,
                                 visibleX: item.visibleX,
                                 visibleWidth: item.visibleWidth,
                                 pointsPerSecond: pps,
                                 height: h,
                                 isSelected: item.id == selectedClipID,
                                 isLifted: item.isLifted)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        selection = .clip(item.id)
                    }
                    .gesture(reorderGesture(clipID: item.id))
                    .zIndex(item.isLifted ? 10 : (item.id == selectedClipID ? 1 : 0))
            }

            if let sel = selectedItem {
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX - hw)
                    .gesture(clipTrimGesture(clipID: sel.id, leading: true))
                    .zIndex(20)
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX + sel.width)
                    .gesture(clipTrimGesture(clipID: sel.id, leading: false))
                    .zIndex(20)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }

    // MARK: - 字幕トラック

    private func subtitleItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                               subtitles: [SubtitleCue]) -> [TimelineSpanItem] {
        var result: [TimelineSpanItem] = []
        for cue in subtitles {
            let x = originX + CGFloat(cue.start) * pps
            let w = max(CGFloat(cue.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 24)
            result.append(TimelineSpanItem(id: cue.id, text: cue.text, screenX: x, width: w,
                                           visibleX: span.x, visibleWidth: span.width, labelX: labelX))
        }
        return result
    }

    private func subtitleTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                               subtitles: [SubtitleCue]) -> some View {
        let h = TimelineMetrics.subtitleHeight
        let hw = TimelineMetrics.subtitleHandleWidth
        let items = subtitleItems(width: width, originX: originX, pps: pps, subtitles: subtitles)
        let selectedID: UUID? = selection?.subtitleID
        let selectedItem: TimelineSpanItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                TimelineSubtitleCapsule(text: item.text,
                                        labelX: item.labelX,
                                        visibleWidth: item.visibleWidth,
                                        height: h,
                                        isSelected: isSel)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        selection = .subtitle(item.id)
                    }
                    .gesture(subtitleMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 1 : 0)
            }

            if let sel = selectedItem {
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX - hw)
                    .gesture(subtitleTrimGesture(id: sel.id, leading: true))
                    .zIndex(20)
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX + sel.width)
                    .gesture(subtitleTrimGesture(id: sel.id, leading: false))
                    .zIndex(20)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }

    // MARK: - BGM トラック

    private func audioTrack(width: CGFloat, originX: CGFloat, pps: CGFloat, total: Double,
                            audio: AudioSettings) -> some View {
        let h = TimelineMetrics.audioHeight
        let hasBGM = audio.bgmURL != nil
        let name = audio.bgmName ?? "BGM"
        let fullWidth = max(CGFloat(total) * pps, 40)
        let span = TimelineMetrics.visibleSpan(x: originX, width: fullWidth, viewWidth: width)
        let isSelected = selection == EditorSelection.bgm

        return ZStack(alignment: .topLeading) {
            if hasBGM {
                if let span {
                    TimelineAudioBar(name: name,
                                     labelX: TimelineMetrics.stickyLabelX(trueX: originX, visibleX: span.x,
                                                                         visibleWidth: span.width, labelWidth: 80),
                                     visibleWidth: span.width,
                                     height: h,
                                     isSelected: isSelected)
                        .offset(x: span.x)
                        .onTapGesture {
                            selection = .bgm
                        }
                }
            } else {
                Text("+ BGMを追加")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(height: h)
                    .offset(x: max(originX + 8, 8))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }

    // MARK: - スクロール(時刻の移動)

    private var scrollGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($scrollGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                scrollChanged(value)
            }
            .onEnded { value in
                scrollEnded(value)
            }
    }

    private func clampTime(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(0, t), max(0, project.totalDuration))
    }

    private func throttledSeek(_ t: Double) {
        let now = CACurrentMediaTime()
        if now - interaction.lastSeekTime >= 1.0 / 30.0 {
            interaction.lastSeekTime = now
            player.seek(to: t)
        }
    }

    private func scrollChanged(_ value: DragGesture.Value) {
        if interaction.scrollBlocked { return }
        if interaction.edit != nil || interaction.pinchStartPPS != nil {
            interaction.scrollBlocked = true
            if interaction.scrollStartTime != nil {
                interaction.scrollStartTime = nil
                endScrubbing()
            }
            return
        }
        let pps = max(timeline.pointsPerSecond, 0.0001)
        if interaction.scrollStartTime == nil {
            momentumTask?.cancel()
            momentumTask = nil
            let start = scrubTime ?? player.currentTime
            if player.isPlaying { player.pause() }
            if !timeline.isUserScrolling { timeline.isUserScrolling = true }
            interaction.scrollStartTime = start
            interaction.scrollStartTranslation = value.translation.width
            scrubTime = start
        }
        let base = interaction.scrollStartTime ?? 0
        let dx = Double(value.translation.width - interaction.scrollStartTranslation)
        let t = clampTime(base - dx / pps)
        scrubTime = t
        throttledSeek(t)
    }

    private func scrollEnded(_ value: DragGesture.Value) {
        let wasBlocked = interaction.scrollBlocked
        interaction.scrollBlocked = false
        guard !wasBlocked, interaction.scrollStartTime != nil else {
            interaction.scrollStartTime = nil
            return
        }
        interaction.scrollStartTime = nil
        startMomentum(pointsVelocity: value.velocity.width)
    }

    /// ジェスチャーがキャンセルされた場合など onEnded が来なかったときの後始末
    private func scrollGestureDidReset() {
        // onEnded の後に処理されるよう 1 回遅らせる
        Task { @MainActor in
            interaction.scrollBlocked = false
            if interaction.scrollStartTime != nil {
                interaction.scrollStartTime = nil
                endScrubbing()
            }
        }
    }

    private func startMomentum(pointsVelocity: CGFloat) {
        momentumTask?.cancel()
        momentumTask = nil
        let pps = max(timeline.pointsPerSecond, 0.0001)
        guard pointsVelocity.isFinite, abs(pointsVelocity) >= 80 else {
            endScrubbing()
            return
        }
        // 秒 / 秒(指を右へ払うと時刻は戻る)
        let initialVelocity = -Double(pointsVelocity) / pps
        momentumTask = Task { @MainActor in
            var velocity = initialVelocity
            var last = CACurrentMediaTime()
            while true {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Task.isCancelled { return }
                if player.isPlaying {
                    // 慣性中に再生が始まったら追従に戻す
                    momentumTask = nil
                    scrubTime = nil
                    if timeline.isUserScrolling { timeline.isUserScrolling = false }
                    return
                }
                let now = CACurrentMediaTime()
                let dt = min(max(now - last, 0.001), 0.05)
                last = now
                let current = scrubTime ?? player.currentTime
                let upper = max(0, project.totalDuration)
                var next = current + velocity * dt
                var hitEdge = false
                if next <= 0 {
                    next = 0
                    hitEdge = true
                } else if next >= upper {
                    next = upper
                    hitEdge = true
                }
                scrubTime = next
                throttledSeek(next)
                velocity *= pow(0.95, dt * 60)
                if hitEdge || abs(velocity) * max(timeline.pointsPerSecond, 0.0001) < 15 {
                    break
                }
            }
            if Task.isCancelled { return }
            momentumTask = nil
            endScrubbing()
        }
    }

    /// スクラブ(ドラッグ・慣性)を終了し、最終位置へシークする
    private func endScrubbing() {
        momentumTask?.cancel()
        momentumTask = nil
        if let t = scrubTime {
            player.seek(to: t)
        }
        scrubTime = nil
        if timeline.isUserScrolling {
            timeline.isUserScrolling = false
        }
    }

    // MARK: - ピンチで拡大縮小

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit != nil { return }
                if interaction.pinchStartPPS == nil {
                    interaction.pinchStartPPS = timeline.pointsPerSecond
                    if interaction.scrollStartTime != nil {
                        interaction.scrollStartTime = nil
                        interaction.scrollBlocked = true
                    }
                    endScrubbing()
                }
                let start = interaction.pinchStartPPS ?? timeline.pointsPerSecond
                let factor = Double(value.magnification)
                guard factor.isFinite, factor > 0 else { return }
                timeline.pointsPerSecond = start * factor
                timeline.clampZoom()
            }
            .onEnded { _ in
                interaction.pinchStartPPS = nil
            }
    }

    // MARK: - 編集操作の開始・終了

    private func beginEdit(_ kind: TimelineEditKind) {
        if interaction.scrollStartTime != nil {
            interaction.scrollStartTime = nil
            interaction.scrollBlocked = true
        }
        endScrubbing()
        if player.isPlaying { player.pause() }
        history.record(project)
        interaction.edit = kind
    }

    private func finishEdit() {
        guard let edit = interaction.edit else { return }
        interaction.edit = nil
        switch edit {
        case .trimClip:
            leftTrimClipID = nil
            leftTrimShiftSeconds = 0
        case .trimSubtitle, .moveSubtitle:
            project.sortSubtitles()
        case .reorder:
            withAnimation(.easeOut(duration: 0.18)) {
                reorderClipID = nil
                reorderTranslation = 0
            }
        }
    }

    // MARK: - クリップのトリム

    private func clipTrimGesture(clipID: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let i = project.index(of: clipID) else { return }
                    let clip = project.clips[i]
                    beginEdit(.trimClip(id: clipID, leading: leading,
                                        originalStart: clip.startTime, originalEnd: clip.endTime))
                }
                applyClipTrim(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyClipTrim(translation: CGFloat) {
        guard case let .trimClip(id, leading, originalStart, originalEnd)? = interaction.edit,
              let i = project.index(of: id) else { return }
        let clip = project.clips[i]
        let speed = max(clip.speed, 0.01)
        let pps = max(timeline.pointsPerSecond, 0.0001)
        // Δ元素材秒 = Δポイント / pps × 速度
        let delta = Double(translation) / pps * speed
        let minimumLength = 0.2
        if leading {
            let upper = max(0, originalEnd - minimumLength)
            let newStart = min(max(0, originalStart + delta), upper)
            if abs(newStart - clip.startTime) > 0.0001 {
                project.clips[i].startTime = newStart
            }
            if leftTrimClipID != id { leftTrimClipID = id }
            leftTrimShiftSeconds = (newStart - originalStart) / speed
        } else {
            let lower = min(clip.duration, originalStart + minimumLength)
            let newEnd = max(min(clip.duration, originalEnd + delta), lower)
            if abs(newEnd - clip.endTime) > 0.0001 {
                project.clips[i].endTime = newEnd
            }
        }
    }

    // MARK: - クリップの並べ替え(長押し → ドラッグ)

    private func reorderGesture(clipID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($editGestureActive) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if interaction.edit == nil {
                    beginReorder(clipID: clipID)
                }
                guard case let .reorder(id)? = interaction.edit, id == clipID else { return }
                reorderTranslation = drag?.translation.width ?? 0
                updateReorder()
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func beginReorder(clipID: UUID) {
        guard let i = project.index(of: clipID) else { return }
        beginEdit(.reorder(id: clipID))
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        let starts = project.clipStartTimes()
        reorderAnchorX = i < starts.count ? CGFloat(starts[i]) * pps : 0
        reorderTranslation = 0
        withAnimation(.easeOut(duration: 0.15)) {
            reorderClipID = clipID
        }
        selection = .clip(clipID)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 持ち上げたクリップの中心が隣のクリップの中点を越えたら入れ替える
    private func updateReorder() {
        guard let id = reorderClipID else { return }
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        var iterations = 0
        while iterations < project.clips.count {
            iterations += 1
            guard let i = project.index(of: id) else { return }
            let clips = project.clips
            let starts = project.clipStartTimes()
            let draggedWidth = CGFloat(clips[i].outputDuration) * pps
            let center = reorderAnchorX + reorderTranslation + draggedWidth / 2
            if i + 1 < clips.count {
                let nextMid = CGFloat(starts[i + 1] + clips[i + 1].outputDuration / 2) * pps
                if center > nextMid {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        project.clips.swapAt(i, i + 1)
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                    continue
                }
            }
            if i > 0 {
                let previousMid = CGFloat(starts[i - 1] + clips[i - 1].outputDuration / 2) * pps
                if center < previousMid {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        project.clips.swapAt(i, i - 1)
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                    continue
                }
            }
            break
        }
    }

    // MARK: - 字幕の移動・長さ変更

    private func subtitleMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let cue = project.subtitles.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveSubtitle(id: id, originalStart: cue.start, originalEnd: cue.end))
                }
                applySubtitleEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func subtitleTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let cue = project.subtitles.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimSubtitle(id: id, leading: leading,
                                            originalStart: cue.start, originalEnd: cue.end))
                }
                applySubtitleEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applySubtitleEdit(translation: CGFloat) {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let delta = Double(translation) / pps
        let minimumLength = 0.3
        switch interaction.edit {
        case let .trimSubtitle(id, leading, originalStart, originalEnd)?:
            guard let i = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
            if leading {
                let newStart = min(max(0, originalStart + delta), max(0, originalEnd - minimumLength))
                if abs(project.subtitles[i].start - newStart) > 0.0001 {
                    project.subtitles[i].start = newStart
                }
            } else {
                let upper = max(project.totalDuration, originalEnd)
                let newEnd = max(min(originalEnd + delta, upper), originalStart + minimumLength)
                if abs(project.subtitles[i].end - newEnd) > 0.0001 {
                    project.subtitles[i].end = newEnd
                }
            }
        case let .moveSubtitle(id, originalStart, originalEnd)?:
            guard let i = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, originalEnd - originalStart)
            let upperStart = max(0, max(project.totalDuration, originalEnd) - length)
            let newStart = min(max(0, originalStart + delta), upperStart)
            if abs(project.subtitles[i].start - newStart) > 0.0001 {
                project.subtitles[i].start = newStart
                project.subtitles[i].end = newStart + length
            }
        default:
            break
        }
    }
}
