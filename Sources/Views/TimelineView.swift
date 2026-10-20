import SwiftUI
import UIKit
import QuartzCore

/// タイムラインの「+ 追加」から追加するものの種類
enum TimelineAddKind {
    case media, text, subtitle, overlay, bgm, narration
}

/// トラック行の縦位置(行の領域内のローカル座標)
struct TimelineRowPlacement: Identifiable {
    let kind: TimelineTrackKind
    let y: CGFloat
    var id: String { kind.key }
}

/// CapCut 風タイムライン。
/// 中央に固定された白い再生位置の下を、トラックが横にスクロールする。
/// スクロール位置 = 時刻 × pointsPerSecond(ScrollView は使わず、ドラッグ + 慣性を自前で処理)。
///
/// トラック(上から): 目盛り(+ マーカーの旗) / 重ね合わせ(Bロール・ワイプ・写真) /
/// 映像(+ J/L カットの音声バー、クリップ間のトランジションのバッジ) / テキスト・ステッカー / 手書き /
/// 字幕 / BGM / ナレーション / 「+ 追加」行
/// 中身の無いトラックは表示せず、「+ 追加」行のメニューから追加する。
/// 行が多いとき(maxVisibleRows 超)は縦にドラッグしてスクロールする。
///
/// クリップの横位置は `CompositionBuilder.timelineLayout(for:)`(トランジションの重なりで短くなった
/// 出力タイムライン)に従う。
struct TimelineView: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let timeline: TimelineState
    @Binding var selection: EditorSelection?
    let onAdd: (TimelineAddKind) -> Void

    /// 全トラックを並べたときの高さ(互換用の固定値。画面側は preferredHeight(for:) を使う)
    static let totalHeight: CGFloat = TimelineMetrics.totalHeight

    /// 中身のあるトラック + 目盛り + 映像 + 「+ 追加」行(32pt)の高さ。行が多いときは上限まで
    static func preferredHeight(for project: EditorProject) -> CGFloat {
        TimelineMetrics.height(for: visibleTracks(for: project))
    }

    /// 映像トラックの上端の y(タイムラインのローカル座標。縦スクロールしていないとき)
    static func videoTrackTop(for project: EditorProject) -> CGFloat {
        var y: CGFloat = TimelineMetrics.topPadding + TimelineMetrics.rulerHeight + TimelineMetrics.trackSpacing
        if !project.overlays.isEmpty {
            let lanes = TimelineMetrics.overlayLaneCount(project.overlays)
            y += TimelineMetrics.stackedHeight(TimelineMetrics.overlayHeight, lanes: lanes) + TimelineMetrics.trackSpacing
        }
        return y
    }

    private static func visibleTracks(for project: EditorProject) -> [TimelineTrackKind] {
        TimelineMetrics.visibleTracks(overlayLanes: TimelineMetrics.overlayLaneCount(project.overlays),
                                      textLanes: TimelineMetrics.textLaneCount(project.textClips),
                                      hasDrawings: !project.drawings.isEmpty,
                                      hasSubtitles: !project.subtitles.isEmpty,
                                      hasBGM: project.audio.bgmURL != nil,
                                      narrationLanes: TimelineMetrics.narrationLaneCount(project.narration))
    }

    static func rowPlacements(_ rows: [TimelineTrackKind]) -> [TimelineRowPlacement] {
        var result: [TimelineRowPlacement] = []
        var y: CGFloat = 0
        for row in rows {
            result.append(TimelineRowPlacement(kind: row, y: y))
            y += row.height + TimelineMetrics.trackSpacing
        }
        return result
    }

    init(project: EditorProject, player: PlayerController, history: EditorHistory,
         timeline: TimelineState, selection: Binding<EditorSelection?>,
         onAdd: @escaping (TimelineAddKind) -> Void = { _ in }) {
        self.project = project
        self.player = player
        self.history = history
        self.timeline = timeline
        self._selection = selection
        self.onAdd = onAdd
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
    /// 複数選択したクリップをまとめて動かしているときの、かたまりのクリップ(並び順)
    @State private var reorderGroupIDs: [UUID] = []

    /// スナップ中の時刻(黄色の縦線を出す)
    @State private var snapGuideTime: Double? = nil
    /// トラック行の縦スクロール量
    @State private var verticalOffset: CGFloat = 0

    /// 操作のヒントを一度だけ出す
    @AppStorage("timeline.reorderTrimHintShown") private var hintShown: Bool = false

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
        let rows = TimelineMetrics.visibleTracks(for: snapshot)
        let height = TimelineMetrics.height(for: rows)
        let showsHint = !hintShown && !snapshot.clips.isEmpty
        let isScrubbing = scrubTime != nil

        GeometryReader { geo in
            content(width: geo.size.width, frame: frameData, rows: rows,
                    showsHint: showsHint, isScrubbing: isScrubbing)
        }
        .frame(height: height)
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
            finishEdit()
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
    private func content(width: CGFloat, frame f: TimelineFrameData, rows: [TimelineTrackKind],
                         showsHint: Bool, isScrubbing: Bool) -> some View {
        // タイムライン 0 秒の画面 x 座標
        let originX = width / 2 - CGFloat(f.time) * f.pps
        let pps = f.pps
        let totalH = TimelineMetrics.height(for: rows)
        let viewportH = TimelineMetrics.rowsViewportHeight(rows)
        let contentH = TimelineMetrics.rowsHeight(rows)
        let maxOffset = max(0, contentH - viewportH)
        let vOffset = min(max(0, verticalOffset), maxOffset)
        let rowsTop: CGFloat = TimelineMetrics.topPadding + TimelineMetrics.rulerHeight + TimelineMetrics.trackSpacing
        let guideX: CGFloat? = snapGuideTime.map { originX + CGFloat($0) * pps }

        ZStack(alignment: .topLeading) {
            TimelineMetrics.background
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }

            rulerTrack(width: width, originX: originX, pps: pps, total: f.total, markers: f.snapshot.markers)
                .offset(y: TimelineMetrics.topPadding)

            tracksArea(width: width, originX: originX, frame: f, rows: rows,
                       offset: vOffset, viewportHeight: viewportH)
                .frame(width: width, height: viewportH, alignment: .topLeading)
                .clipped()
                .offset(y: rowsTop)

            if maxOffset > 0 {
                TimelineScrollIndicator(offset: vOffset, maxOffset: maxOffset, viewportHeight: viewportH)
                    .frame(width: 3, height: viewportH)
                    .offset(x: width - 4, y: rowsTop)
                    .allowsHitTesting(false)
            }

            if let gx = guideX, gx.isFinite, gx > -2, gx < width + 2 {
                Rectangle()
                    .fill(TimelineMetrics.snapGuideColor)
                    .frame(width: 1, height: totalH)
                    .offset(x: gx - 0.5)
                    .allowsHitTesting(false)
            }

            TimelinePlayheadView()
                .frame(width: width, height: totalH)
                .allowsHitTesting(false)

            if isScrubbing {
                TimelineTimeBubble(time: f.time)
                    .position(x: width / 2, y: 10)
                    .allowsHitTesting(false)
            }

            if showsHint {
                hintView
                    .frame(width: width)
                    .offset(y: rowsTop + 2)
            }
        }
        .frame(width: width, height: totalH, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(scrollGesture(maxVerticalOffset: maxOffset))
        .simultaneousGesture(zoomGesture(width: width, total: f.total))
    }

    /// トラック行(縦スクロール分ずらし、見えない行は描かない)
    @ViewBuilder
    private func tracksArea(width: CGFloat, originX: CGFloat, frame f: TimelineFrameData,
                            rows: [TimelineTrackKind], offset: CGFloat, viewportHeight: CGFloat) -> some View {
        let placements = TimelineView.rowPlacements(rows).filter { p in
            p.y + p.kind.height > offset - 1 && p.y < offset + viewportHeight + 1
        }
        ZStack(alignment: .topLeading) {
            ForEach(placements) { p in
                trackRow(kind: p.kind, width: width, originX: originX, frame: f)
                    .offset(y: p.y - offset)
            }
        }
    }

    /// 1 行(中身 + 左端のアイコン)
    private func trackRow(kind: TimelineTrackKind, width: CGFloat, originX: CGFloat,
                          frame f: TimelineFrameData) -> some View {
        let chipRowHeight: CGFloat = kind == .video ? TimelineMetrics.videoHeight : kind.height
        let chipSize = min(TimelineMetrics.trackChipSize, chipRowHeight)
        let chipY = max(0, (chipRowHeight - chipSize) / 2)
        return ZStack(alignment: .topLeading) {
            trackContent(kind: kind, width: width, originX: originX, frame: f)
            if let icon = kind.iconName {
                TimelineTrackChip(systemName: icon, rowHeight: chipRowHeight)
                    .offset(x: 4, y: chipY)
                    .zIndex(30)
            }
        }
        .frame(width: width, height: kind.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func trackContent(kind: TimelineTrackKind, width: CGFloat, originX: CGFloat,
                              frame f: TimelineFrameData) -> some View {
        let pps = f.pps
        switch kind {
        case .overlay:
            overlayTrack(width: width, originX: originX, pps: pps, overlays: f.snapshot.overlays)
        case .video:
            videoTrack(width: width, originX: originX, pps: pps, ranges: f.ranges, total: f.total)
        case .text:
            textTrack(width: width, originX: originX, pps: pps, textClips: f.snapshot.textClips)
        case .drawing:
            drawingTrack(width: width, originX: originX, pps: pps, drawings: f.snapshot.drawings)
        case .subtitle:
            subtitleTrack(width: width, originX: originX, pps: pps, subtitles: f.snapshot.subtitles)
        case .audio:
            audioTrack(width: width, originX: originX, pps: pps, total: f.total, audio: f.snapshot.audio)
        case .narration:
            narrationTrack(width: width, originX: originX, pps: pps, narration: f.snapshot.narration)
        case .add:
            addRow(width: width)
        }
    }

    // MARK: - 「+ 追加」行・ヒント

    private func addRow(width: CGFloat) -> some View {
        let h = TimelineMetrics.addRowHeight
        return Menu {
            Button {
                onAdd(.text)
            } label: {
                Label("テキスト", systemImage: "textformat")
            }
            Button {
                onAdd(.subtitle)
            } label: {
                Label("字幕", systemImage: "captions.bubble")
            }
            Button {
                onAdd(.overlay)
            } label: {
                Label("オーバーレイ", systemImage: "photo.on.rectangle")
            }
            Button {
                onAdd(.bgm)
            } label: {
                Label("BGM", systemImage: "music.note")
            }
            Button {
                onAdd(.narration)
            } label: {
                Label("ナレーション", systemImage: "mic.fill")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("追加")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Color.white.opacity(0.12), in: Capsule())
            .frame(minWidth: 44, minHeight: h)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("トラックを追加")
        .padding(.leading, 8)
        .frame(width: width, height: h, alignment: .leading)
    }

    private var hintView: some View {
        Text("長押しで並べ替え・端をドラッグで長さ調整")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.92), in: Capsule())
            .shadow(color: Color.black.opacity(0.4), radius: 3, x: 0, y: 1)
            .onTapGesture {
                hintShown = true
            }
            .task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    hintShown = true
                }
            }
    }

    // MARK: - 選択中の部品の枠とトリムハンドル

    /// 上下の帯 + 長さのバッジ + 左右のハンドル(掴める幅 44pt、外側へ広げる)
    @ViewBuilder
    private func selectionDecor<L: Gesture, T: Gesture>(screenX: CGFloat, width: CGFloat,
                                                        visibleX: CGFloat, visibleWidth: CGFloat,
                                                        y: CGFloat, height: CGFloat, duration: Double,
                                                        leading: L, trailing: T) -> some View {
        let hit = TimelineMetrics.handleHitWidth
        let badgeX = TimelineMetrics.stickyLabelX(trueX: screenX, visibleX: visibleX,
                                                  visibleWidth: visibleWidth, labelWidth: 44)
        TimelineSelectionFrame(visibleWidth: visibleWidth, height: height, duration: duration, badgeX: badgeX)
            .offset(x: visibleX, y: y)
            .zIndex(18)
        TimelineTrimHandleHitArea(leading: true)
            .frame(width: hit, height: height)
            .offset(x: screenX - hit, y: y)
            .gesture(leading)
            .zIndex(20)
        TimelineTrimHandleHitArea(leading: false)
            .frame(width: hit, height: height)
            .offset(x: screenX + width, y: y)
            .gesture(trailing)
            .zIndex(20)
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
        let items = overlayItems(width: width, originX: originX, pps: pps, overlays: overlays)
        let selectedID: UUID? = selection?.overlayID
        let selectedItem: TimelineOverlayItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        // 時間が重なるオーバーレイは別の段に並べる(depth = 段)
        let laneCount: Int = TimelineMetrics.overlayLaneCount(overlays)
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                let laneY: CGFloat = CGFloat(item.depth) * laneStep
                TimelineOverlayBar(overlay: item.overlay,
                                   labelX: item.labelX,
                                   visibleWidth: item.visibleWidth,
                                   height: h,
                                   isSelected: isSel)
                    .offset(x: item.visibleX, y: laneY)
                    .onTapGesture {
                        selection = .overlay(item.id)
                    }
                    .gesture(overlayMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 10 : Double(item.depth))
            }

            if let sel = selectedItem {
                let inset: CGFloat = CGFloat(sel.depth) * laneStep
                let barH = h
                if !sel.overlay.keyframes.isEmpty {
                    TimelineKeyframeDiamonds(times: sel.overlay.keyframes.map { $0.time },
                                             pointsPerSecond: pps,
                                             screenX: sel.screenX,
                                             visibleX: sel.visibleX)
                        .frame(width: sel.visibleWidth, height: barH)
                        .offset(x: sel.visibleX, y: inset)
                        .zIndex(15)
                }
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: inset, height: barH, duration: sel.overlay.duration,
                               leading: overlayTrimGesture(id: sel.id, leading: true),
                               trailing: overlayTrimGesture(id: sel.id, leading: false))
            }
        }
        .frame(width: width, height: TimelineMetrics.stackedHeight(h, lanes: laneCount), alignment: .topLeading)
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
        // 複数のクリップをまとめて動かしているときの、かたまりの先頭の位置(秒)
        let groupSet: Set<UUID> = Set(reorderGroupIDs)
        var groupStart: Double? = nil
        if !groupSet.isEmpty, let firstIndex = clips.firstIndex(where: { groupSet.contains($0.id) }),
           firstIndex < ranges.count {
            groupStart = ranges[firstIndex].start
        }
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
            if let groupStart, groupSet.contains(clip.id) {
                let offsetInGroup = CGFloat(range.start - groupStart) * pps
                contentX = reorderAnchorX + reorderTranslation + offsetInGroup
                lifted = true
            } else if let reorderClipID, reorderClipID == clip.id {
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
                            ranges: [TimelineClipRange], total: Double) -> some View {
        let h = TimelineMetrics.videoHeight
        let lane = TimelineMetrics.splitAudioLaneHeight
        let badge = TimelineMetrics.transitionBadgeSize
        let layout = clipItems(width: width, originX: originX, pps: pps, ranges: ranges)
        let items = layout.items
        let splitBars = layout.splitBars
        let transitions = layout.transitions
        let selectedClipID: UUID? = selection?.clipID
        let isMulti: Bool = timeline.isMultiSelecting
        let multiIDs: Set<UUID> = timeline.multiSelectedClipIDs
        let selectedItem: TimelineClipItem? = (reorderClipID == nil && !isMulti && selectedClipID != nil)
            ? items.first(where: { $0.id == selectedClipID })
            : nil
        let isEmpty = project.clips.isEmpty

        // 最後のクリップの後ろの「+」タイル(最後のクリップを選択中はハンドルの外に出す)
        let lastSelected = selectedClipID != nil && project.clips.last?.id == selectedClipID
        let tileGap: CGFloat = lastSelected ? TimelineMetrics.handleHitWidth + 4 : 10
        let tileShift: Double = leftTrimClipID != nil ? leftTrimShiftSeconds : 0
        let endX: CGFloat = originX + CGFloat(total + tileShift) * pps
        let tileX: CGFloat = endX + tileGap
        let tileW = TimelineMetrics.addTileWidth
        let margin = TimelineMetrics.cullMargin
        let showsTile = reorderClipID == nil && tileX.isFinite && tileX < width + margin && tileX + tileW > -margin

        return ZStack(alignment: .topLeading) {
            if showsTile {
                Button {
                    onAdd(.media)
                } label: {
                    TimelineAddTile(height: h)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("動画・写真を追加")
                .offset(x: tileX)
                .zIndex(2)

                if isEmpty {
                    Text("動画・写真を追加")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .frame(height: h)
                        .offset(x: tileX + tileW + 8)
                        .allowsHitTesting(false)
                }
            }

            ForEach(items) { item in
                TimelineClipView(clip: item.clip,
                                 screenX: item.screenX,
                                 fullWidth: item.width,
                                 visibleX: item.visibleX,
                                 visibleWidth: item.visibleWidth,
                                 pointsPerSecond: pps,
                                 height: h,
                                 isSelected: isMulti ? multiIDs.contains(item.id) : item.id == selectedClipID,
                                 isLifted: item.isLifted)
                    .overlay(alignment: .topLeading) {
                        if isMulti {
                            TimelineMultiSelectBadge(isOn: multiIDs.contains(item.id))
                                .padding(4)
                                .allowsHitTesting(false)
                        }
                    }
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        if timeline.isMultiSelecting {
                            timeline.toggleMultiSelect(item.id)
                            UISelectionFeedbackGenerator().selectionChanged()
                        } else {
                            selection = .clip(item.id)
                        }
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
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: 0, height: h, duration: sel.clip.outputDuration,
                               leading: clipTrimGesture(clipID: sel.id, leading: true),
                               trailing: clipTrimGesture(clipID: sel.id, leading: false))
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
        let items = textItems(width: width, originX: originX, pps: pps, textClips: textClips)
        let selectedID: UUID? = selection?.textID
        let selectedItem: TimelineTextItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })
        // 時間が重なるテキストは別の段に並べる
        let lanes: [UUID: Int] = TimelineMetrics.textLanes(textClips)
        let laneCount: Int = (lanes.values.max() ?? 0) + 1
        let trackHeight: CGFloat = TimelineMetrics.textTrackHeight(lanes: laneCount)
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap
        let selectedY: CGFloat = CGFloat(selectedID.flatMap { lanes[$0] } ?? 0) * laneStep

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                let laneY: CGFloat = CGFloat(lanes[item.id] ?? 0) * laneStep
                TimelineTextBar(textClip: item.textClip,
                                labelX: item.labelX,
                                visibleWidth: item.visibleWidth,
                                height: h,
                                isSelected: isSel)
                    .offset(x: item.visibleX, y: laneY)
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
                        .offset(x: sel.visibleX, y: selectedY)
                        .zIndex(15)
                }
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: selectedY, height: h, duration: sel.textClip.duration,
                               leading: textTrimGesture(id: sel.id, leading: true),
                               trailing: textTrimGesture(id: sel.id, leading: false))
            }
        }
        .frame(width: width, height: trackHeight, alignment: .topLeading)
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
        let items = drawingItems(width: width, originX: originX, pps: pps, drawings: drawings)
        let selectedID: UUID? = selection?.drawingID
        let selectedItem: TimelineDrawingItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })

        return ZStack(alignment: .topLeading) {
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
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: 0, height: h, duration: sel.drawing.duration,
                               leading: drawingTrimGesture(id: sel.id, leading: true),
                               trailing: drawingTrimGesture(id: sel.id, leading: false))
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
                                           visibleX: span.x, visibleWidth: span.width, labelX: labelX,
                                           duration: cue.duration))
        }
        return result
    }

    private func subtitleTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                               subtitles: [SubtitleCue]) -> some View {
        let h = TimelineMetrics.subtitleHeight
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
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: 0, height: h, duration: sel.duration,
                               leading: subtitleTrimGesture(id: sel.id, leading: true),
                               trailing: subtitleTrimGesture(id: sel.id, leading: false))
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
            if hasBGM, let span {
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
        let items = narrationItems(width: width, originX: originX, pps: pps, narration: narration)
        let selectedID: UUID? = selection?.narrationID
        let selectedItem: TimelineNarrationItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })
        // 時間が重なるナレーションは別の段に並べる
        let lanes: [UUID: Int] = TimelineMetrics.narrationLanes(narration)
        let laneCount: Int = TimelineMetrics.laneCount(lanes)
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap
        let selectedY: CGFloat = CGFloat(selectedID.flatMap { lanes[$0] } ?? 0) * laneStep

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                let laneY: CGFloat = CGFloat(lanes[item.id] ?? 0) * laneStep
                TimelineNarrationBar(clip: item.clip,
                                     screenX: item.screenX,
                                     visibleX: item.visibleX,
                                     visibleWidth: item.visibleWidth,
                                     pointsPerSecond: pps,
                                     labelX: item.labelX,
                                     height: h,
                                     isSelected: isSel)
                    .offset(x: item.visibleX, y: laneY)
                    .onTapGesture {
                        selection = .narration(item.id)
                    }
                    .gesture(narrationMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 1 : 0)
            }

            if let sel = selectedItem {
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: selectedY, height: h, duration: sel.clip.duration,
                               leading: narrationTrimGesture(id: sel.id, leading: true),
                               trailing: narrationTrimGesture(id: sel.id, leading: false))
            }
        }
        .frame(width: width, height: TimelineMetrics.stackedHeight(h, lanes: laneCount), alignment: .topLeading)
    }

    // MARK: - スクロール(時刻の移動・トラックの縦スクロール)

    private func scrollGesture(maxVerticalOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($scrollGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                scrollChanged(value, maxVerticalOffset: maxVerticalOffset)
            }
            .onEnded { value in
                scrollEnded(value)
            }
    }

    private func clampTime(_ t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(0, t), max(0, timelineDuration()))
    }

    private func scrollChanged(_ value: DragGesture.Value, maxVerticalOffset: CGFloat) {
        if interaction.scrollBlocked { return }
        if interaction.edit != nil || interaction.pinchStartPPS != nil {
            interaction.scrollBlocked = true
            interaction.verticalScroll = nil
            if interaction.scrollStartTime != nil {
                interaction.scrollStartTime = nil
                endScrubbing()
            }
            return
        }

        // 最初の動きで縦(トラックの縦スクロール)か横(時刻の移動)かを決める
        if interaction.verticalScroll == nil {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            if maxVerticalOffset > 0 && dy > dx {
                interaction.verticalScroll = true
                interaction.verticalStartOffset = min(max(0, verticalOffset), maxVerticalOffset)
                interaction.verticalMaxOffset = maxVerticalOffset
                interaction.verticalStartTranslation = value.translation.height
            } else {
                interaction.verticalScroll = false
            }
        }
        if interaction.verticalScroll == true {
            let dy = value.translation.height - interaction.verticalStartTranslation
            let proposed = interaction.verticalStartOffset - dy
            let next = min(max(0, proposed), interaction.verticalMaxOffset)
            if abs(next - verticalOffset) > 0.5 {
                verticalOffset = next
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
        // 間引かずに追いかけシーク(PlayerController 側でまとめる)
        player.scrub(to: t)
    }

    private func scrollEnded(_ value: DragGesture.Value) {
        let wasBlocked = interaction.scrollBlocked
        let wasVertical = interaction.verticalScroll == true
        interaction.scrollBlocked = false
        interaction.verticalScroll = nil
        if wasVertical {
            interaction.scrollStartTime = nil
            return
        }
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
            interaction.verticalScroll = nil
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
                player.scrub(to: next)
                // 1 ミリ秒ごとに 0.998 倍(iOS のスクロールに近い減速)
                let elapsedMs: Double = dt * 1000
                let decay: Double = pow(0.998, elapsedMs)
                velocity *= decay
                let pointsPerSecondNow = max(timeline.pointsPerSecond, 0.0001)
                if hitEdge || abs(velocity) * pointsPerSecondNow < 15 {
                    break
                }
            }
            if Task.isCancelled { return }
            momentumTask = nil
            endScrubbing()
        }
    }

    /// スクラブ(ドラッグ・慣性)を終了し、最終位置へ正確にシークする
    private func endScrubbing() {
        momentumTask?.cancel()
        momentumTask = nil
        if let t = scrubTime {
            player.endScrub(at: t)
        }
        scrubTime = nil
        if timeline.isUserScrolling {
            timeline.isUserScrolling = false
        }
    }

    // MARK: - ピンチで拡大縮小

    private func zoomGesture(width: CGFloat, total: Double) -> some Gesture {
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
                // 縮小の下限は動画の長さで変わる(全体が画面の 8 割に収まるところまで)
                timeline.clampZoom(duration: total, viewWidth: Double(width))
            }
            .onEnded { _ in
                interaction.pinchStartPPS = nil
            }
    }

    // MARK: - スナップ・限界の振動

    /// スナップ候補(再生位置・クリップの端・マーカー・ほかの部品の端)を集める。
    /// excluding の部品自身は含めない。clipTrimIndex を渡すとそのクリップ以降のクリップの端は含めない
    /// (トリムで一緒に動くため)。trailing のトリムではそのクリップの開始は含める。
    private func collectSnapTargets(excluding id: UUID?, clipTrimIndex: Int? = nil,
                                    trimLeading: Bool = false) -> [Double] {
        let snapshot = project.snapshot()
        var targets: [Double] = [player.currentTime]
        let ranges = TimelineView.clipRanges(for: snapshot)
        for (i, r) in ranges.enumerated() {
            if let limit = clipTrimIndex {
                if i < limit {
                    targets.append(r.start)
                    targets.append(r.end)
                } else if i == limit && !trimLeading {
                    targets.append(r.start)
                }
            } else {
                targets.append(r.start)
                targets.append(r.end)
            }
        }
        for m in snapshot.markers where m.id != id {
            targets.append(m.time)
        }
        for o in snapshot.overlays where o.id != id {
            targets.append(o.start)
            targets.append(o.end)
        }
        for t in snapshot.textClips where t.id != id {
            targets.append(t.start)
            targets.append(t.end)
        }
        for d in snapshot.drawings where d.id != id {
            targets.append(d.start)
            targets.append(d.end)
        }
        for c in snapshot.subtitles where c.id != id {
            targets.append(c.start)
            targets.append(c.end)
        }
        for n in snapshot.narration where n.id != id {
            targets.append(n.start)
            targets.append(n.end)
        }
        return targets.filter { $0.isFinite && $0 >= 0 }
    }

    /// 端(edges、元の時刻)を delta だけ動かしたとき、8pt 以内の候補があれば吸い付くよう delta を補正する
    private func snappedDelta(_ delta: Double, edges: [Double]) -> Double {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let threshold = Double(TimelineMetrics.snapThreshold) / pps
        var bestAdjust: Double? = nil
        var bestTarget: Double? = nil
        for edge in edges {
            let moved = edge + delta
            for target in interaction.snapTargets {
                let diff = target - moved
                if abs(diff) > threshold { continue }
                if let current = bestAdjust, abs(current) <= abs(diff) { continue }
                bestAdjust = diff
                bestTarget = target
            }
        }
        setSnapGuide(bestTarget)
        if let bestAdjust {
            return delta + bestAdjust
        }
        return delta
    }

    /// スナップ中の時刻を更新し、新しい候補に吸い付いたときだけ軽く振動させる
    private func setSnapGuide(_ target: Double?) {
        if let target {
            var isNew = true
            if let last = interaction.lastSnapTarget, abs(last - target) < 0.0001 {
                isNew = false
            }
            if isNew && interaction.snapPrimed {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        interaction.snapPrimed = true
        interaction.lastSnapTarget = target
        if snapGuideTime != target {
            snapGuideTime = target
        }
    }

    /// トリムが限界(最短・素材の端など)に達した瞬間に 1 回だけ振動させる
    private func noteTrimLimit(_ hit: Bool) {
        if hit && !interaction.atTrimLimit {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        interaction.atTrimLimit = hit
    }

    // MARK: - 編集操作の開始・終了

    private func beginEdit(_ kind: TimelineEditKind, snapExcluding id: UUID? = nil, snaps: Bool = true) {
        if interaction.scrollStartTime != nil {
            interaction.scrollStartTime = nil
            interaction.scrollBlocked = true
        }
        endScrubbing()
        if player.isPlaying { player.pause() }
        history.record(project)
        interaction.edit = kind
        interaction.snapTargets = snaps ? collectSnapTargets(excluding: id) : []
        interaction.lastSnapTarget = nil
        interaction.snapPrimed = false
        interaction.atTrimLimit = false
        // 操作中はプレビューの合成を作り直さない(終了時に 1 回だけ)
        player.beginInteraction()
        if !hintShown {
            hintShown = true
        }
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
                reorderGroupIDs = []
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
        interaction.snapTargets = []
        interaction.lastSnapTarget = nil
        interaction.snapPrimed = false
        interaction.atTrimLimit = false
        if snapGuideTime != nil {
            snapGuideTime = nil
        }
        player.endInteraction()
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
                    let ranges = clipRanges()
                    beginEdit(.trimClip(id: clipID, leading: leading,
                                        originalStart: clip.startTime, originalEnd: clip.endTime),
                              snaps: false)
                    interaction.snapTargets = collectSnapTargets(excluding: clipID, clipTrimIndex: i,
                                                                 trimLeading: leading)
                    if i < ranges.count {
                        interaction.trimEdgeTime = leading ? ranges[i].start : ranges[i].end
                    } else {
                        interaction.trimEdgeTime = 0
                    }
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
        // 表示上の端はタイムライン秒で translation / pps だけ動く。そこでスナップを掛ける
        let rawVisualDelta = Double(translation) / pps
        let visualDelta = snappedDelta(rawVisualDelta, edges: [interaction.trimEdgeTime])
        // Δ元素材秒 = Δタイムライン秒 × 速度
        let delta = visualDelta * speed
        let minimumLength = 0.2
        // 逆再生のクリップは表示上の先頭が元素材の終わり(endTime)なので、動かす端を入れ替える
        let reversed = clip.isReversed && clip.reversedURL != nil
        let movesStart = (leading != reversed)
        let signedDelta = reversed ? -delta : delta
        if movesStart {
            let upper = max(0, originalEnd - minimumLength)
            let proposed = originalStart + signedDelta
            let newStart = min(max(0, proposed), upper)
            noteTrimLimit(abs(newStart - proposed) > 0.0001)
            if abs(newStart - clip.startTime) > 0.0001 {
                project.clips[i].startTime = newStart
            }
            if leading {
                if leftTrimClipID != id { leftTrimClipID = id }
                leftTrimShiftSeconds = (newStart - originalStart) / speed
            }
        } else {
            let lower = min(clip.duration, originalStart + minimumLength)
            let proposed = originalEnd + signedDelta
            let newEnd = max(min(clip.duration, proposed), lower)
            noteTrimLimit(abs(newEnd - proposed) > 0.0001)
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
        guard project.index(of: clipID) != nil else { return }
        beginEdit(.reorder(id: clipID), snaps: false)
        // 複数選択中に選んだクリップを持ち上げたら、選んだクリップをひとかたまりにして一緒に動かす
        var group: [UUID] = []
        if timeline.isMultiSelecting {
            if !timeline.multiSelectedClipIDs.contains(clipID) {
                timeline.multiSelectedClipIDs.insert(clipID)
            }
            let ids = timeline.multiSelectedClipIDs
            if ids.count > 1 {
                project.gatherClips(ids: ids)
                group = project.clips.map { $0.id }.filter { ids.contains($0) }
            }
        }
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        let ranges = clipRanges()
        let anchorID: UUID = group.first ?? clipID
        let anchorIndex: Int = project.index(of: anchorID) ?? 0
        reorderAnchorX = anchorIndex < ranges.count ? CGFloat(ranges[anchorIndex].start) * pps : 0
        reorderTranslation = 0
        withAnimation(.easeOut(duration: 0.15)) {
            reorderClipID = clipID
            reorderGroupIDs = group
        }
        if !timeline.isMultiSelecting {
            selection = .clip(clipID)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 複数のクリップのかたまりを動かす: かたまりの中心が隣のクリップの中点を越えたら、そのクリップを反対側へ回す
    private func updateGroupReorder() {
        let ids: Set<UUID> = Set(reorderGroupIDs)
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        var iterations = 0
        while iterations < project.clips.count {
            iterations += 1
            let clips = project.clips
            let ranges = clipRanges()
            guard ranges.count == clips.count,
                  let lo = clips.firstIndex(where: { ids.contains($0.id) }),
                  let hi = clips.lastIndex(where: { ids.contains($0.id) }) else { return }
            let blockStart: Double = ranges[lo].start
            let blockEnd: Double = ranges[hi].end
            let blockWidth = CGFloat(blockEnd - blockStart) * pps
            let center = reorderAnchorX + reorderTranslation + blockWidth / 2
            if hi + 1 < clips.count {
                let nextMid = CGFloat((ranges[hi + 1].start + ranges[hi + 1].end) / 2) * pps
                if center > nextMid {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        let moved = project.clips.remove(at: hi + 1)
                        project.clips.insert(moved, at: lo)
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                    continue
                }
            }
            if lo > 0 {
                let previousMid = CGFloat((ranges[lo - 1].start + ranges[lo - 1].end) / 2) * pps
                if center < previousMid {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        let moved = project.clips.remove(at: lo - 1)
                        project.clips.insert(moved, at: hi)
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                    continue
                }
            }
            break
        }
    }

    /// 持ち上げたクリップの中心が隣のクリップの中点を越えたら入れ替える
    private func updateReorder() {
        if !reorderGroupIDs.isEmpty {
            updateGroupReorder()
            return
        }
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
                    beginEdit(.moveSubtitle(id: id, originalStart: cue.start, originalEnd: cue.end), snapExcluding: id)
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
                                            originalStart: cue.start, originalEnd: cue.end),
                              snapExcluding: id)
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
                let proposed = originalStart + snappedDelta(delta, edges: [originalStart])
                let newStart = min(max(0, proposed), max(0, originalEnd - minimumLength))
                noteTrimLimit(abs(newStart - proposed) > 0.0001)
                if abs(project.subtitles[i].start - newStart) > 0.0001 {
                    project.subtitles[i].start = newStart
                }
            } else {
                let upper = max(timelineDuration(), originalEnd)
                let proposed = originalEnd + snappedDelta(delta, edges: [originalEnd])
                let newEnd = max(min(proposed, upper), originalStart + minimumLength)
                noteTrimLimit(abs(newEnd - proposed) > 0.0001)
                if abs(project.subtitles[i].end - newEnd) > 0.0001 {
                    project.subtitles[i].end = newEnd
                }
            }
        case let .moveSubtitle(id, originalStart, originalEnd)?:
            guard let i = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, originalEnd - originalStart)
            let upperStart = max(0, max(timelineDuration(), originalEnd) - length)
            let moved = snappedDelta(delta, edges: [originalStart, originalEnd])
            let newStart = min(max(0, originalStart + moved), upperStart)
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
                    beginEdit(.moveOverlay(id: id, originalStart: overlay.start), snapExcluding: id)
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
                    beginEdit(.trimOverlay(id: id, leading: leading, original: overlay), snapExcluding: id)
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
            let moved = snappedDelta(delta, edges: [originalStart, originalStart + length])
            let newStart = min(max(0, originalStart + moved), upperStart)
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
                let proposed = original.start + snappedDelta(delta, edges: [original.start])
                let newStart = min(max(lowerStart, proposed), upperStart)
                noteTrimLimit(abs(newStart - proposed) > 0.0001)
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
                let proposed = original.duration + snappedDelta(delta, edges: [original.end])
                updated.duration = min(max(minimumLength, proposed), maxLength)
                noteTrimLimit(abs(updated.duration - proposed) > 0.0001)
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
                    beginEdit(.moveNarration(id: id, originalStart: clip.start), snapExcluding: id)
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
                    beginEdit(.trimNarration(id: id, leading: leading, original: clip), snapExcluding: id)
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
            let moved = snappedDelta(delta, edges: [originalStart, originalStart + length])
            let newStart = min(max(0, originalStart + moved), upperStart)
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
                let proposed = original.start + snappedDelta(delta, edges: [original.start])
                let newStart = min(max(lowerStart, proposed), upperStart)
                noteTrimLimit(abs(newStart - proposed) > 0.0001)
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
                let proposed = original.duration + snappedDelta(delta, edges: [original.end])
                updated.duration = min(max(minimumLength, proposed), maxLength)
                noteTrimLimit(abs(updated.duration - proposed) > 0.0001)
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
                    beginEdit(.moveText(id: id, originalStart: clip.start), snapExcluding: id)
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
                    beginEdit(.trimText(id: id, leading: leading, original: clip), snapExcluding: id)
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
            let moved = snappedDelta(delta, edges: [originalStart, originalStart + length])
            let newStart = min(max(0, originalStart + moved), upperStart)
            if abs(project.textClips[i].start - newStart) > 0.0001 {
                project.textClips[i].start = newStart
            }
        case let .trimText(id, leading, original)?:
            guard let i = project.textClips.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                // 左端: 開始を動かし終了は固定
                let upperStart = max(0, original.end - minimumLength)
                let proposed = original.start + snappedDelta(delta, edges: [original.start])
                let newStart = min(max(0, proposed), upperStart)
                noteTrimLimit(abs(newStart - proposed) > 0.0001)
                updated.start = newStart
                updated.duration = max(minimumLength, original.end - newStart)
            } else {
                // 右端: 長さだけ変える
                let upperEnd = max(timelineDuration(), original.end)
                let maxLength = max(minimumLength, upperEnd - original.start)
                let proposed = original.duration + snappedDelta(delta, edges: [original.end])
                updated.duration = min(max(minimumLength, proposed), maxLength)
                noteTrimLimit(abs(updated.duration - proposed) > 0.0001)
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
                    beginEdit(.moveDrawing(id: id, originalStart: drawing.start), snapExcluding: id)
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
                    beginEdit(.trimDrawing(id: id, leading: leading, original: drawing), snapExcluding: id)
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
            let moved = snappedDelta(delta, edges: [originalStart, originalStart + length])
            let newStart = min(max(0, originalStart + moved), upperStart)
            if abs(project.drawings[i].start - newStart) > 0.0001 {
                project.drawings[i].start = newStart
            }
        case let .trimDrawing(id, leading, original)?:
            guard let i = project.drawings.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                let upperStart = max(0, original.end - minimumLength)
                let proposed = original.start + snappedDelta(delta, edges: [original.start])
                let newStart = min(max(0, proposed), upperStart)
                noteTrimLimit(abs(newStart - proposed) > 0.0001)
                updated.start = newStart
                updated.duration = max(minimumLength, original.end - newStart)
            } else {
                let upperEnd = max(timelineDuration(), original.end)
                let maxLength = max(minimumLength, upperEnd - original.start)
                let proposed = original.duration + snappedDelta(delta, edges: [original.end])
                updated.duration = min(max(minimumLength, proposed), maxLength)
                noteTrimLimit(abs(updated.duration - proposed) > 0.0001)
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
                    beginEdit(.moveMarker(id: id, originalTime: marker.time), snapExcluding: id)
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
        let delta = snappedDelta(Double(translation) / pps, edges: [originalTime])
        let newTime = clampTime(originalTime + delta)
        if abs(project.markers[i].time - newTime) > 0.0001 {
            project.markers[i].time = newTime
        }
    }
}
