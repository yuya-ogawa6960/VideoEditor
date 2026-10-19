import SwiftUI
import UIKit
import QuartzCore

/// CapCut 風タイムライン。
/// 中央に固定された白い再生位置の下を、トラックが横にスクロールする。
/// スクロール位置 = 時刻 × pointsPerSecond(ScrollView は使わず、ドラッグ + 慣性を自前で処理)。
///
/// トラック(上から): 目盛り(+ マーカーの旗) / 重ね合わせ(Bロール・ワイプ・写真) /
/// 映像(+ J/L カットの音声バー、クリップ間のトランジションのバッジ) / テキスト・ステッカー / 手書き /
/// 字幕 / BGM / ナレーション
///
/// クリップの横位置は `CompositionBuilder.timelineLayout(for:)`(トランジションの重なりで短くなった
/// 出力タイムライン)に従う。
struct TimelineView: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let timeline: TimelineState
    @Binding var selection: EditorSelection?

    /// タイムライン全体の高さ(画面側はこの値で frame を固定する)
    static let totalHeight: CGFloat = TimelineMetrics.totalHeight

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
        let snapshot = project.snapshot()
        let ranges = TimelineView.clipRanges(for: snapshot)
        let total = TimelineView.totalEnd(of: ranges, fallback: snapshot.totalDuration)
        let frameData = TimelineFrameData(time: time, pps: pps, total: total, ranges: ranges, snapshot: snapshot)

        GeometryReader { geo in
            content(width: geo.size.width, frame: frameData)
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

    // MARK: - クリップの配置(トランジションの重なりを反映)

    /// 各クリップの出力タイムライン上の範囲(project.clips と同じ順)。
    /// `CompositionBuilder.timelineLayout(for:)` の結果を使い、そこに無いクリップは
    /// `clipStartTimes()` 相当(重なりなしで並べた値)で補う。
    static func clipRanges(for snapshot: ProjectSnapshot) -> [TimelineClipRange] {
        var starts: [UUID: Double] = [:]
        var ends: [UUID: Double] = [:]
        for placement in CompositionBuilder.timelineLayout(for: snapshot) {
            starts[placement.clipID] = placement.start
            ends[placement.clipID] = placement.end
        }
        var result: [TimelineClipRange] = []
        result.reserveCapacity(snapshot.clips.count)
        var t = 0.0
        for clip in snapshot.clips {
            let d = max(0, clip.outputDuration)
            if let s = starts[clip.id], let e = ends[clip.id], s.isFinite, e.isFinite, e >= s {
                result.append(TimelineClipRange(start: s, end: e))
            } else {
                result.append(TimelineClipRange(start: t, end: t + d))
            }
            t += d
        }
        return result
    }

    /// クリップ範囲の最後の終わり(秒)。範囲が無ければ fallback
    static func totalEnd(of ranges: [TimelineClipRange], fallback: Double) -> Double {
        let end = ranges.reduce(0.0) { max($0, $1.end) }
        if end > 0, end.isFinite { return end }
        return fallback.isFinite ? max(0, fallback) : 0
    }

    /// トランジションの重なりを反映した全体の長さ(秒)
    static func timelineDuration(for snapshot: ProjectSnapshot) -> Double {
        totalEnd(of: clipRanges(for: snapshot), fallback: snapshot.totalDuration)
    }

    private func clipRanges() -> [TimelineClipRange] {
        TimelineView.clipRanges(for: project.snapshot())
    }

    private func timelineDuration() -> Double {
        TimelineView.timelineDuration(for: project.snapshot())
    }

    // MARK: - 全体

    @ViewBuilder
    private func content(width: CGFloat, frame f: TimelineFrameData) -> some View {
        // タイムライン 0 秒の画面 x 座標
        let originX = width / 2 - CGFloat(f.time) * f.pps
        let pps = f.pps

        ZStack(alignment: .topLeading) {
            TimelineMetrics.background
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }

            VStack(alignment: .leading, spacing: TimelineMetrics.trackSpacing) {
                rulerTrack(width: width, originX: originX, pps: pps, total: f.total, markers: f.snapshot.markers)
                overlayTrack(width: width, originX: originX, pps: pps, overlays: f.snapshot.overlays)
                videoTrack(width: width, originX: originX, pps: pps, ranges: f.ranges)
                textTrack(width: width, originX: originX, pps: pps, textClips: f.snapshot.textClips)
                drawingTrack(width: width, originX: originX, pps: pps, drawings: f.snapshot.drawings)
                subtitleTrack(width: width, originX: originX, pps: pps, subtitles: f.snapshot.subtitles)
                audioTrack(width: width, originX: originX, pps: pps, total: f.total, audio: f.snapshot.audio)
                narrationTrack(width: width, originX: originX, pps: pps, narration: f.snapshot.narration)
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

    // MARK: - 目盛り + マーカー

    private func markerItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                             markers: [TimelineMarker]) -> (flags: [TimelineMarkerItem], beatXs: [CGFloat]) {
        var flags: [TimelineMarkerItem] = []
        var beats: [CGFloat] = []
        let margin = TimelineMetrics.cullMargin + TimelineMetrics.markerLabelMaxWidth
        for marker in markers {
            let x = originX + CGFloat(marker.time) * pps
            guard x.isFinite, x > -margin, x < width + margin else { continue }
            if marker.kind == .beat {
                beats.append(x)
            } else {
                flags.append(TimelineMarkerItem(id: marker.id, marker: marker, screenX: x))
            }
        }
        return (flags, beats)
    }

    private func rulerTrack(width: CGFloat, originX: CGFloat, pps: CGFloat, total: Double,
                            markers: [TimelineMarker]) -> some View {
        let h = TimelineMetrics.rulerHeight
        let items = markerItems(width: width, originX: originX, pps: pps, markers: markers)
        let selectedID: UUID? = selection?.markerID
        let selectedBeatX: CGFloat? = markers
            .first(where: { $0.id == selectedID && $0.kind == .beat })
            .map { originX + CGFloat($0.time) * pps }
        let hasMarkers = !markers.isEmpty

        return ZStack(alignment: .topLeading) {
            TimelineRulerView(originX: originX, pointsPerSecond: pps, totalDuration: total)
                .frame(width: width, height: h)
                .allowsHitTesting(false)

            if hasMarkers {
                // 旗の外(ビートの点など)をタップしたら最寄りのマーカーを選ぶ(無ければ選択解除)
                Color.clear
                    .frame(width: width, height: h)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        selectMarker(nearestTo: location.x, originX: originX, pps: pps, markers: markers)
                    }
            }

            if !items.beatXs.isEmpty || selectedBeatX != nil {
                TimelineBeatTicks(xs: items.beatXs, selectedX: selectedBeatX)
                    .frame(width: width, height: h)
                    .allowsHitTesting(false)
            }

            ForEach(items.flags) { item in
                let isSel = item.id == selectedID
                TimelineMarkerFlag(marker: item.marker, isSelected: isSel)
                    .offset(x: item.screenX - TimelineMetrics.markerPoleWidth / 2)
                    .onTapGesture {
                        selection = .marker(item.id)
                    }
                    .gesture(markerMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 2 : 1)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }

    private func selectMarker(nearestTo x: CGFloat, originX: CGFloat, pps: CGFloat, markers: [TimelineMarker]) {
        var bestID: UUID? = nil
        var bestDistance: CGFloat = TimelineMetrics.markerTapTolerance
        for marker in markers {
            let mx = originX + CGFloat(marker.time) * pps
            guard mx.isFinite else { continue }
            let d = abs(mx - x)
            if d <= bestDistance {
                bestDistance = d
                bestID = marker.id
            }
        }
        if let bestID {
            selection = .marker(bestID)
        } else {
            selection = nil
        }
    }

    // MARK: - 重ね合わせトラック

    private func overlayItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                              overlays: [OverlayClip]) -> [TimelineOverlayItem] {
        var result: [TimelineOverlayItem] = []
        // 開始順に見て、空いているレーンを割り当てる(重なりの深さ)
        let ordered = overlays.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            return a.offset < b.offset
        }
        var laneEnds: [Double] = []
        for entry in ordered {
            let overlay = entry.element
            let depth: Int
            if let free = laneEnds.firstIndex(where: { $0 <= overlay.start + 0.0005 }) {
                laneEnds[free] = overlay.end
                depth = free
            } else {
                laneEnds.append(overlay.end)
                depth = laneEnds.count - 1
            }
            let x = originX + CGFloat(overlay.start) * pps
            let w = max(CGFloat(overlay.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 70)
            result.append(TimelineOverlayItem(id: overlay.id, overlay: overlay, screenX: x, width: w,
                                              visibleX: span.x, visibleWidth: span.width,
                                              labelX: labelX, depth: depth))
        }
        return result
    }

    private func overlayTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                              overlays: [OverlayClip]) -> some View {
        let h = TimelineMetrics.overlayHeight
        let hw = TimelineMetrics.subtitleHandleWidth
        let items = overlayItems(width: width, originX: originX, pps: pps, overlays: overlays)
        let selectedID: UUID? = selection?.overlayID
        let selectedItem: TimelineOverlayItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        return ZStack(alignment: .topLeading) {
            if overlays.isEmpty {
                Text("+ Bロール・写真を重ねる")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(height: h)
                    .offset(x: max(originX + 8, 8))
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                let isSel = item.id == selectedID
                let inset = TimelineMetrics.overlayInset(depth: item.depth)
                TimelineOverlayBar(overlay: item.overlay,
                                   labelX: item.labelX,
                                   visibleWidth: item.visibleWidth,
                                   height: max(8, h - inset),
                                   isSelected: isSel)
                    .offset(x: item.visibleX, y: inset)
                    .onTapGesture {
                        selection = .overlay(item.id)
                    }
                    .gesture(overlayMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 10 : Double(item.depth))
            }

            if let sel = selectedItem {
                let inset = TimelineMetrics.overlayInset(depth: sel.depth)
                if !sel.overlay.keyframes.isEmpty {
                    TimelineKeyframeDiamonds(times: sel.overlay.keyframes.map { $0.time },
                                             pointsPerSecond: pps,
                                             screenX: sel.screenX,
                                             visibleX: sel.visibleX)
                        .frame(width: sel.visibleWidth, height: max(8, h - inset))
                        .offset(x: sel.visibleX, y: inset)
                        .zIndex(15)
                }
                TimelineTrimHandle()
                    .frame(width: hw, height: max(8, h - inset))
                    .offset(x: sel.screenX - hw, y: inset)
                    .gesture(overlayTrimGesture(id: sel.id, leading: true))
                    .zIndex(20)
                TimelineTrimHandle()
                    .frame(width: hw, height: max(8, h - inset))
                    .offset(x: sel.screenX + sel.width, y: inset)
                    .gesture(overlayTrimGesture(id: sel.id, leading: false))
                    .zIndex(20)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }

    // MARK: - 映像トラック

    /// 見えているクリップの配置、J/L カットの音声バー(レーン内ローカル座標)、トランジションのバッジ
    private func clipItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                           ranges: [TimelineClipRange])
        -> (items: [TimelineClipItem], splitBars: [CGRect], transitions: [TimelineTransitionItem]) {
        var result: [TimelineClipItem] = []
        var bars: [CGRect] = []
        var transitions: [TimelineTransitionItem] = []
        let clips = project.clips
        let shiftIndex: Int? = leftTrimClipID.flatMap { project.index(of: $0) }
        let shift = leftTrimShiftSeconds
        let gap = TimelineMetrics.clipGap
        let margin = TimelineMetrics.cullMargin
        let laneH = TimelineMetrics.splitAudioLaneHeight
        // ranges が足りないときの保険(重なりなしで並べた位置)
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            let d = max(0, clip.outputDuration)
            let range: TimelineClipRange = i < ranges.count ? ranges[i] : TimelineClipRange(start: t, end: t + d)
            t += d
            let fullWidth = CGFloat(range.duration) * pps
            var contentX = CGFloat(range.start) * pps
            if let shiftIndex, i >= shiftIndex {
                contentX += CGFloat(shift) * pps
            }
            var lifted = false
            if let reorderClipID, reorderClipID == clip.id {
                contentX = reorderAnchorX + reorderTranslation
                lifted = true
            }
            let screenX = originX + contentX + gap / 2
            let w = max(fullWidth - gap, 1)

            // J カット / L カット: 音声はクリップの前後にはみ出す(lead / tail はタイムライン秒)
            if clip.hasAudio, !clip.isMuted, !clip.isStill, clip.audio.hasSplitEdit {
                let lead = CGFloat(max(0, clip.audio.audioLeadIn)) * pps
                let tail = CGFloat(max(0, clip.audio.audioTailOut)) * pps
                let barX = screenX - lead
                let barW = w + lead + tail
                if barX.isFinite, barW.isFinite, barX < width + margin, barX + barW > -margin {
                    bars.append(CGRect(x: barX, y: 0, width: barW, height: laneH))
                }
            }

            // このクリップから次のクリップへのトランジション(重なりの中央にバッジ)
            if reorderClipID == nil, i + 1 < clips.count, clip.transition.isActive {
                let next: TimelineClipRange = i + 1 < ranges.count ? ranges[i + 1] : TimelineClipRange(start: t, end: t)
                var endA = range.end
                var startB = next.start
                if let shiftIndex {
                    if i >= shiftIndex { endA += shift }
                    if i + 1 >= shiftIndex { startB += shift }
                }
                let cx = originX + CGFloat((endA + startB) / 2) * pps
                if cx.isFinite, cx > -margin, cx < width + margin {
                    transitions.append(TimelineTransitionItem(id: clip.id, centerX: cx, type: clip.transition.type))
                }
            }

            guard let span = TimelineMetrics.visibleSpan(x: screenX, width: w, viewWidth: width) else { continue }
            result.append(TimelineClipItem(id: clip.id, clip: clip, screenX: screenX, width: w,
                                           visibleX: span.x, visibleWidth: span.width, isLifted: lifted))
        }
        return (result, bars, transitions)
    }

    private func videoTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                            ranges: [TimelineClipRange]) -> some View {
        let h = TimelineMetrics.videoHeight
        let lane = TimelineMetrics.splitAudioLaneHeight
        let hw = TimelineMetrics.handleWidth
        let badge = TimelineMetrics.transitionBadgeSize
        let layout = clipItems(width: width, originX: originX, pps: pps, ranges: ranges)
        let items = layout.items
        let splitBars = layout.splitBars
        let transitions = layout.transitions
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

            if !splitBars.isEmpty {
                TimelineSplitAudioLane(bars: splitBars)
                    .frame(width: width, height: lane)
                    .offset(y: h)
                    .zIndex(5)
            }

            ForEach(transitions) { item in
                TimelineTransitionBadge(type: item.type, isSelected: item.id == selectedClipID)
                    .frame(width: badge, height: badge)
                    .offset(x: item.centerX - badge / 2, y: (h - badge) / 2)
                    .onTapGesture {
                        selection = .clip(item.id)
                    }
                    .zIndex(15)
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
        .frame(width: width, height: h + lane, alignment: .topLeading)
    }

    // MARK: - テキスト・ステッカートラック

    private func textItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                           textClips: [TextClip]) -> [TimelineTextItem] {
        var result: [TimelineTextItem] = []
        for clip in textClips {
            let x = originX + CGFloat(clip.start) * pps
            let w = max(CGFloat(clip.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 40)
            result.append(TimelineTextItem(id: clip.id, textClip: clip, screenX: x, width: w,
                                           visibleX: span.x, visibleWidth: span.width, labelX: labelX))
        }
        return result
    }

    private func textTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                           textClips: [TextClip]) -> some View {
        let h = TimelineMetrics.textHeight
        let hw = TimelineMetrics.subtitleHandleWidth
        let items = textItems(width: width, originX: originX, pps: pps, textClips: textClips)
        let selectedID: UUID? = selection?.textID
        let selectedItem: TimelineTextItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        return ZStack(alignment: .topLeading) {
            if textClips.isEmpty {
                Text("+ テキスト・ステッカー")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(height: h)
                    .offset(x: max(originX + 8, 8))
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                let isSel = item.id == selectedID
                TimelineTextBar(textClip: item.textClip,
                                labelX: item.labelX,
                                visibleWidth: item.visibleWidth,
                                height: h,
                                isSelected: isSel)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        selection = .text(item.id)
                    }
                    .gesture(textMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 1 : 0)
            }

            if let sel = selectedItem {
                if !sel.textClip.keyframes.isEmpty {
                    TimelineKeyframeDiamonds(times: sel.textClip.keyframes.map { $0.time },
                                             pointsPerSecond: pps,
                                             screenX: sel.screenX,
                                             visibleX: sel.visibleX)
                        .frame(width: sel.visibleWidth, height: h)
                        .offset(x: sel.visibleX)
                        .zIndex(15)
                }
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX - hw)
                    .gesture(textTrimGesture(id: sel.id, leading: true))
                    .zIndex(20)
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX + sel.width)
                    .gesture(textTrimGesture(id: sel.id, leading: false))
                    .zIndex(20)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }

    // MARK: - 手書きトラック

    private func drawingItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                              drawings: [DrawingClip]) -> [TimelineDrawingItem] {
        var result: [TimelineDrawingItem] = []
        for drawing in drawings {
            let x = originX + CGFloat(drawing.start) * pps
            let w = max(CGFloat(drawing.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 24)
            result.append(TimelineDrawingItem(id: drawing.id, drawing: drawing, screenX: x, width: w,
                                              visibleX: span.x, visibleWidth: span.width, labelX: labelX))
        }
        return result
    }

    private func drawingTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                              drawings: [DrawingClip]) -> some View {
        let h = TimelineMetrics.drawingHeight
        let hw = TimelineMetrics.subtitleHandleWidth
        let items = drawingItems(width: width, originX: originX, pps: pps, drawings: drawings)
        let selectedID: UUID? = selection?.drawingID
        let selectedItem: TimelineDrawingItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        return ZStack(alignment: .topLeading) {
            if drawings.isEmpty {
                Text("+ 手書き")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(height: h)
                    .offset(x: max(originX + 8, 8))
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                let isSel = item.id == selectedID
                TimelineDrawingBar(drawing: item.drawing,
                                   labelX: item.labelX,
                                   visibleWidth: item.visibleWidth,
                                   height: h,
                                   isSelected: isSel)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        selection = .drawing(item.id)
                    }
                    .gesture(drawingMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 1 : 0)
            }

            if let sel = selectedItem {
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX - hw)
                    .gesture(drawingTrimGesture(id: sel.id, leading: true))
                    .zIndex(20)
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX + sel.width)
                    .gesture(drawingTrimGesture(id: sel.id, leading: false))
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
                    // 見えている範囲のタイムライン秒(BGM は 0 秒から始まりループする)
                    let visibleStart = Double((span.x - originX) / pps)
                    let visibleEnd = Double((span.x + span.width - originX) / pps)
                    TimelineAudioBar(name: name,
                                     labelX: TimelineMetrics.stickyLabelX(trueX: originX, visibleX: span.x,
                                                                         visibleWidth: span.width, labelWidth: 80),
                                     visibleWidth: span.width,
                                     height: h,
                                     isSelected: isSelected,
                                     waveformURL: audio.bgmURL,
                                     visibleStartTime: visibleStart,
                                     visibleEndTime: visibleEnd)
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

    // MARK: - ナレーショントラック

    private func narrationItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                                narration: [NarrationClip]) -> [TimelineNarrationItem] {
        var result: [TimelineNarrationItem] = []
        for clip in narration {
            let x = originX + CGFloat(clip.start) * pps
            let w = max(CGFloat(clip.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 60)
            result.append(TimelineNarrationItem(id: clip.id, clip: clip, screenX: x, width: w,
                                                visibleX: span.x, visibleWidth: span.width, labelX: labelX))
        }
        return result
    }

    private func narrationTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                                narration: [NarrationClip]) -> some View {
        let h = TimelineMetrics.narrationHeight
        let hw = TimelineMetrics.subtitleHandleWidth
        let items = narrationItems(width: width, originX: originX, pps: pps, narration: narration)
        let selectedID: UUID? = selection?.narrationID
        let selectedItem: TimelineNarrationItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        return ZStack(alignment: .topLeading) {
            if narration.isEmpty {
                Text("+ ナレーションを録音")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(height: h)
                    .offset(x: max(originX + 8, 8))
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                let isSel = item.id == selectedID
                TimelineNarrationBar(clip: item.clip,
                                     screenX: item.screenX,
                                     visibleX: item.visibleX,
                                     visibleWidth: item.visibleWidth,
                                     pointsPerSecond: pps,
                                     labelX: item.labelX,
                                     height: h,
                                     isSelected: isSel)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        selection = .narration(item.id)
                    }
                    .gesture(narrationMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 1 : 0)
            }

            if let sel = selectedItem {
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX - hw)
                    .gesture(narrationTrimGesture(id: sel.id, leading: true))
                    .zIndex(20)
                TimelineTrimHandle()
                    .frame(width: hw, height: h)
                    .offset(x: sel.screenX + sel.width)
                    .gesture(narrationTrimGesture(id: sel.id, leading: false))
                    .zIndex(20)
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
        return min(max(0, t), max(0, timelineDuration()))
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
        // 慣性中はクリップが変わらないので全体の長さは最初に 1 回だけ求める
        let upper = max(0, timelineDuration())
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
        case .moveOverlay, .trimOverlay:
            project.sortOverlays()
        case .moveNarration, .trimNarration:
            project.sortNarration()
        case .moveText, .trimText:
            project.sortTextClips()
        case .moveDrawing, .trimDrawing:
            project.drawings.sort { $0.start < $1.start }
        case .moveMarker:
            project.sortMarkers()
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
        let speed = TimelineClipView.effectiveSpeed(of: clip)
        let pps = max(timeline.pointsPerSecond, 0.0001)
        // Δ元素材秒 = Δポイント / pps × 速度
        let delta = Double(translation) / pps * speed
        let minimumLength = 0.2
        // 逆再生のクリップは表示上の先頭が元素材の終わり(endTime)なので、動かす端を入れ替える
        let reversed = clip.isReversed && clip.reversedURL != nil
        let movesStart = (leading != reversed)
        let signedDelta = reversed ? -delta : delta
        if movesStart {
            let upper = max(0, originalEnd - minimumLength)
            let newStart = min(max(0, originalStart + signedDelta), upper)
            if abs(newStart - clip.startTime) > 0.0001 {
                project.clips[i].startTime = newStart
            }
            if leading {
                if leftTrimClipID != id { leftTrimClipID = id }
                leftTrimShiftSeconds = (newStart - originalStart) / speed
            }
        } else {
            let lower = min(clip.duration, originalStart + minimumLength)
            let newEnd = max(min(clip.duration, originalEnd + signedDelta), lower)
            if abs(newEnd - clip.endTime) > 0.0001 {
                project.clips[i].endTime = newEnd
            }
            if leading {
                if leftTrimClipID != id { leftTrimClipID = id }
                leftTrimShiftSeconds = (originalEnd - newEnd) / speed
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
        let ranges = clipRanges()
        reorderAnchorX = i < ranges.count ? CGFloat(ranges[i].start) * pps : 0
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
            let ranges = clipRanges()
            guard ranges.count == clips.count, i < ranges.count else { return }
            let draggedWidth = CGFloat(ranges[i].duration) * pps
            let center = reorderAnchorX + reorderTranslation + draggedWidth / 2
            if i + 1 < clips.count {
                let nextMid = CGFloat((ranges[i + 1].start + ranges[i + 1].end) / 2) * pps
                if center > nextMid {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        project.clips.swapAt(i, i + 1)
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                    continue
                }
            }
            if i > 0 {
                let previousMid = CGFloat((ranges[i - 1].start + ranges[i - 1].end) / 2) * pps
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
                let upper = max(timelineDuration(), originalEnd)
                let newEnd = max(min(originalEnd + delta, upper), originalStart + minimumLength)
                if abs(project.subtitles[i].end - newEnd) > 0.0001 {
                    project.subtitles[i].end = newEnd
                }
            }
        case let .moveSubtitle(id, originalStart, originalEnd)?:
            guard let i = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, originalEnd - originalStart)
            let upperStart = max(0, max(timelineDuration(), originalEnd) - length)
            let newStart = min(max(0, originalStart + delta), upperStart)
            if abs(project.subtitles[i].start - newStart) > 0.0001 {
                project.subtitles[i].start = newStart
                project.subtitles[i].end = newStart + length
            }
        default:
            break
        }
    }

    // MARK: - 重ね合わせの移動・長さ変更

    private func overlayMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let overlay = project.overlays.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveOverlay(id: id, originalStart: overlay.start))
                }
                applyOverlayEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func overlayTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let overlay = project.overlays.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimOverlay(id: id, leading: leading, original: overlay))
                }
                applyOverlayEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyOverlayEdit(translation: CGFloat) {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let delta = Double(translation) / pps
        let minimumLength = 0.3
        switch interaction.edit {
        case let .moveOverlay(id, originalStart)?:
            guard let i = project.overlays.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, project.overlays[i].duration)
            let upperStart = max(0, max(timelineDuration(), originalStart + length) - length)
            let newStart = min(max(0, originalStart + delta), upperStart)
            if abs(project.overlays[i].start - newStart) > 0.0001 {
                project.overlays[i].start = newStart
            }
        case let .trimOverlay(id, leading, original)?:
            guard let i = project.overlays.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                // 左端: 開始を動かし終了は固定。動画は素材上の開始位置も一緒にずらす(表示内容がずれない)
                let speed = max(original.speed, 0.01)
                var lowerStart = 0.0
                if !original.isImage {
                    lowerStart = max(lowerStart, original.start - original.sourceStart / speed)
                }
                let upperStart = max(lowerStart, original.end - minimumLength)
                let newStart = min(max(lowerStart, original.start + delta), upperStart)
                updated.start = newStart
                updated.duration = max(0.1, original.end - newStart)
                if !original.isImage {
                    updated.sourceStart = max(0, original.sourceStart + (newStart - original.start) * speed)
                }
            } else {
                // 右端: 長さだけ変える。動画は素材の残り長さまで
                let upperEnd = max(timelineDuration(), original.end)
                var maxLength = max(minimumLength, upperEnd - original.start)
                if !original.isImage {
                    maxLength = min(maxLength, max(minimumLength, original.maxDuration))
                }
                updated.duration = min(max(minimumLength, original.duration + delta), maxLength)
            }
            if project.overlays[i] != updated {
                project.overlays[i] = updated
            }
        default:
            break
        }
    }

    // MARK: - ナレーションの移動・長さ変更

    private func narrationMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let clip = project.narration.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveNarration(id: id, originalStart: clip.start))
                }
                applyNarrationEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func narrationTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let clip = project.narration.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimNarration(id: id, leading: leading, original: clip))
                }
                applyNarrationEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyNarrationEdit(translation: CGFloat) {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let delta = Double(translation) / pps
        let minimumLength = 0.3
        switch interaction.edit {
        case let .moveNarration(id, originalStart)?:
            guard let i = project.narration.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, project.narration[i].duration)
            let upperStart = max(0, max(timelineDuration(), originalStart + length) - length)
            let newStart = min(max(0, originalStart + delta), upperStart)
            if abs(project.narration[i].start - newStart) > 0.0001 {
                project.narration[i].start = newStart
            }
        case let .trimNarration(id, leading, original)?:
            guard let i = project.narration.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                // 左端: 開始を動かし終了は固定。音声ファイル上の開始位置も同じだけずらす
                let lowerStart = max(0, original.start - original.sourceStart)
                let upperStart = max(lowerStart, original.end - minimumLength)
                let newStart = min(max(lowerStart, original.start + delta), upperStart)
                updated.start = newStart
                updated.sourceStart = max(0, original.sourceStart + (newStart - original.start))
                updated.duration = max(0.1, original.end - newStart)
            } else {
                // 右端: 長さだけ変える。音声ファイルの長さが分かればそこまで、分からなければ元の終了位置まで
                let upperEnd = max(timelineDuration(), original.end)
                var maxLength = max(minimumLength, upperEnd - original.start)
                let fileDuration = TimelineWaveformCache.shared.cached(for: original.url)?.duration ?? 0
                let sourceLimit: Double
                if fileDuration > 0 {
                    sourceLimit = max(minimumLength, fileDuration - original.sourceStart)
                } else {
                    sourceLimit = max(minimumLength, original.sourceEnd - original.sourceStart)
                }
                maxLength = min(maxLength, sourceLimit)
                updated.duration = min(max(minimumLength, original.duration + delta), maxLength)
            }
            if project.narration[i] != updated {
                project.narration[i] = updated
            }
        default:
            break
        }
    }

    // MARK: - テキスト・ステッカーの移動・長さ変更

    private func textMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let clip = project.textClips.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveText(id: id, originalStart: clip.start))
                }
                applyTextEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func textTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let clip = project.textClips.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimText(id: id, leading: leading, original: clip))
                }
                applyTextEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyTextEdit(translation: CGFloat) {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let delta = Double(translation) / pps
        let minimumLength = 0.3
        switch interaction.edit {
        case let .moveText(id, originalStart)?:
            guard let i = project.textClips.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, project.textClips[i].duration)
            let upperStart = max(0, max(timelineDuration(), originalStart + length) - length)
            let newStart = min(max(0, originalStart + delta), upperStart)
            if abs(project.textClips[i].start - newStart) > 0.0001 {
                project.textClips[i].start = newStart
            }
        case let .trimText(id, leading, original)?:
            guard let i = project.textClips.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                // 左端: 開始を動かし終了は固定
                let upperStart = max(0, original.end - minimumLength)
                let newStart = min(max(0, original.start + delta), upperStart)
                updated.start = newStart
                updated.duration = max(minimumLength, original.end - newStart)
            } else {
                // 右端: 長さだけ変える
                let upperEnd = max(timelineDuration(), original.end)
                let maxLength = max(minimumLength, upperEnd - original.start)
                updated.duration = min(max(minimumLength, original.duration + delta), maxLength)
            }
            if project.textClips[i] != updated {
                project.textClips[i] = updated
            }
        default:
            break
        }
    }

    // MARK: - 手書きの移動・長さ変更

    private func drawingMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let drawing = project.drawings.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveDrawing(id: id, originalStart: drawing.start))
                }
                applyDrawingEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func drawingTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let drawing = project.drawings.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimDrawing(id: id, leading: leading, original: drawing))
                }
                applyDrawingEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyDrawingEdit(translation: CGFloat) {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let delta = Double(translation) / pps
        let minimumLength = 0.3
        switch interaction.edit {
        case let .moveDrawing(id, originalStart)?:
            guard let i = project.drawings.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, project.drawings[i].duration)
            let upperStart = max(0, max(timelineDuration(), originalStart + length) - length)
            let newStart = min(max(0, originalStart + delta), upperStart)
            if abs(project.drawings[i].start - newStart) > 0.0001 {
                project.drawings[i].start = newStart
            }
        case let .trimDrawing(id, leading, original)?:
            guard let i = project.drawings.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                let upperStart = max(0, original.end - minimumLength)
                let newStart = min(max(0, original.start + delta), upperStart)
                updated.start = newStart
                updated.duration = max(minimumLength, original.end - newStart)
            } else {
                let upperEnd = max(timelineDuration(), original.end)
                let maxLength = max(minimumLength, upperEnd - original.start)
                updated.duration = min(max(minimumLength, original.duration + delta), maxLength)
            }
            if project.drawings[i] != updated {
                project.drawings[i] = updated
            }
        default:
            break
        }
    }

    // MARK: - マーカーの移動

    private func markerMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard let marker = project.markers.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveMarker(id: id, originalTime: marker.time))
                }
                applyMarkerEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyMarkerEdit(translation: CGFloat) {
        guard case let .moveMarker(id, originalTime)? = interaction.edit,
              let i = project.markers.firstIndex(where: { $0.id == id }) else { return }
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let newTime = clampTime(originalTime + Double(translation) / pps)
        if abs(project.markers[i].time - newTime) > 0.0001 {
            project.markers[i].time = newTime
        }
    }
}
