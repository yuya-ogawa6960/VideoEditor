import SwiftUI
import UIKit
import QuartzCore

/// タイムラインの「+ 追加」から追加するものの種類
enum TimelineAddKind {
    case media, text, subtitle, overlay, bgm, narration
    /// いちばんの見どころを先頭にコピーして差し込む(AI)
    case coldOpen
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
/// トラック(上から): 目盛り(+ マーカーの旗) / テキスト・ステッカー / 手書き / 重ね合わせ(Bロール・ワイプ・写真) /
/// モザイク(FX。V1 の映像だけにかかるので V1 の直上) /
/// 映像(+ J/L カットの音声バー、クリップ間のトランジションのバッジ) /
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
    /// クリップの切れ目のボタン・バッジをタップしたとき(前側のクリップの ID)。nil ならクリップを選ぶだけ
    var onTransition: ((UUID) -> Void)? = nil
    /// カメラのトラックの区間から、マルチカメラのスイッチャーを開く(V1 のクリップの ID、作品の秒)
    var onOpenMulticam: ((UUID, Double) -> Void)? = nil

    /// 全トラックを並べたときの高さ(互換用の固定値。画面側は preferredHeight(for:) を使う)
    static let totalHeight: CGFloat = TimelineMetrics.totalHeight

    /// 中身のあるトラック + 目盛り + 映像 + 「+ 追加」行(32pt)の高さ。行が多いときは上限まで
    static func preferredHeight(for project: EditorProject) -> CGFloat {
        TimelineMetrics.height(for: visibleTracks(for: project))
    }

    /// 映像トラックの上端の y(タイムラインのローカル座標。縦スクロールしていないとき)
    static func videoTrackTop(for project: EditorProject) -> CGFloat {
        let top: CGFloat = TimelineMetrics.topPadding + TimelineMetrics.rulerHeight + TimelineMetrics.trackSpacing
        // V1 より上の行(テキスト・手書き・オーバーレイ)の分だけ下がる
        let placement = rowPlacements(visibleTracks(for: project)).first { row in
            if case .video = row.kind { return true }
            return false
        }
        return top + (placement?.y ?? 0)
    }

    private static func visibleTracks(for project: EditorProject) -> [TimelineTrackKind] {
        TimelineMetrics.visibleTracks(overlayLanes: TimelineMetrics.overlayLaneCount(project.overlays),
                                      textLanes: TimelineMetrics.textLaneCount(TimelineMetrics.textOnlyClips(project.textClips)),
                                      hasDrawings: !project.drawings.isEmpty,
                                      hasSubtitles: !project.subtitles.isEmpty,
                                      hasBGM: project.audio.bgmURL != nil,
                                      narrationLanes: TimelineMetrics.narrationLaneCount(project.narration),
                                      mosaicLanes: TimelineMetrics.mosaicLaneCount(project.textClips),
                                      effectLanes: TimelineMetrics.effectLaneCount(project.videoEffects),
                                      cameraLanes: TimelineMetrics.cameraLaneCount(project.clips),
                                      linkedAudioTracks: TimelineMetrics.linkedAudioTrackCount(clips: project.clips,
                                                                                               overlays: project.overlays,
                                                                                               narration: project.narration))
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
         onAdd: @escaping (TimelineAddKind) -> Void = { _ in },
         onTransition: ((UUID) -> Void)? = nil,
         onOpenMulticam: ((UUID, Double) -> Void)? = nil) {
        self.project = project
        self.player = player
        self.history = history
        self.timeline = timeline
        self._selection = selection
        self.onAdd = onAdd
        self.onTransition = onTransition
        self.onOpenMulticam = onOpenMulticam
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
    /// V1 と V2 のあいだで移すドラッグ中に出す案内(離すとどうなるか)
    @State private var trackDropHint: String? = nil
    /// 段を移すドラッグ中の、離したときの置き場所の印
    @State private var carrySlot: TimelineCarrySlot? = nil
    /// 上下に動かしているオーバーレイ(バーを指に付けて上下に動かす)と、その量
    @State private var carryingOverlayID: UUID? = nil
    @State private var carryOffsetY: CGFloat = 0
    /// 並べ替え中のクリップを V1 より上へ持ち上げている(並べ替えは止めて、影をオーバーレイの段に出す)
    @State private var liftingClip = false
    /// 複数選択したクリップをまとめて動かしているときの、かたまりのクリップ(並び順)
    @State private var reorderGroupIDs: [UUID] = []
    /// 並べ替え中のタイルの並びの左端(タイムライン原点からの pt)。全クリップを同じ幅のタイルにして詰め、
    /// 持ち上げたクリップ(かたまりなら先頭)のタイルが持ち上げた位置に来るようにする(長いクリップでも隣を越えられる)
    @State private var reorderRowX: CGFloat = 0
    /// 持ち上げたクリップが画面の端に近いときの自動スクロール
    @State private var reorderScrollTask: Task<Void, Never>? = nil

    /// スナップ中の時刻(黄色の縦線を出す)
    @State private var snapGuideTime: Double? = nil
    /// トラック行の縦スクロール量
    @State private var verticalOffset: CGFloat = 0
    /// 部品のドラッグ中は段の割り当てと行の高さを固定する(終わったらアニメーションで整える)
    @State private var frozenLanes: TimelineFrozenLanes? = nil
    /// タップしたカメラの区間(操作の一覧を出す。nil なら閉じている)
    @State private var cameraActionSegment: TimelineCameraSegment? = nil

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
        // V1 より後ろへはみ出したオーバーレイの終わりまで(目盛り・BGM・スクロールの範囲)
        let total = max(TimelineView.totalEnd(of: ranges, fallback: snapshot.totalDuration),
                        CompositionBuilder.overlayTailEnd(snapshot.overlays))
        let frameData = TimelineFrameData(time: time, pps: pps, total: total, ranges: ranges, snapshot: snapshot)
        let rows = frozenLanes?.rows ?? TimelineMetrics.visibleTracks(for: snapshot)
        let height = TimelineMetrics.height(for: rows)
        let showsHint = !hintShown && !snapshot.clips.isEmpty
        let isScrubbing = scrubTime != nil

        GeometryReader { geo in
            content(width: geo.size.width, frame: frameData, rows: rows,
                    showsHint: showsHint, isScrubbing: isScrubbing)
        }
        .frame(height: height)
        // 画面側の高さが先に変わっても(段が増えた直後など)、トラックは上に揃えたまま動かさない
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TimelineMetrics.background)
        .confirmationDialog(cameraActionSegment.map { String(localized: "アングル\($0.angle)") } ?? "",
                            isPresented: Binding(get: { cameraActionSegment != nil },
                                                 set: { if !$0 { cameraActionSegment = nil } }),
                            titleVisibility: .visible,
                            presenting: cameraActionSegment) { segment in
            cameraSegmentActions(segment)
        }
        .onChange(of: selection) { _, new in
            // 部品を選んだら、段の選択(追加先)は外す
            if new != nil, timeline.targetOverlayLane != nil {
                timeline.targetOverlayLane = nil
            }
        }
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
        max(totalEnd(of: clipRanges(for: snapshot), fallback: snapshot.totalDuration),
            CompositionBuilder.overlayTailEnd(snapshot.overlays))
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
                    if tapStopsMomentum() { return }
                    selection = nil
                    timeline.targetOverlayLane = nil
                }

            rulerTrack(width: width, originX: originX, pps: pps, total: f.total, markers: f.snapshot.markers)
                .offset(y: TimelineMetrics.topPadding)

            tracksArea(width: width, originX: originX, frame: f, rows: rows,
                       offset: vOffset, viewportHeight: viewportH)
                .frame(width: width, height: viewportH, alignment: .topLeading)
                .clipped()
                // clipped() は描画を切るだけ。縦にスクロールして半分隠れた行が、目盛り(マーカーの旗)のタップを横取りしないようにする。
                // 上下の端の段の判定を広げている分(行間の半分)は残す
                .contentShape(TimelineHitShape(top: TimelineMetrics.trackSpacing / 2,
                                               bottom: TimelineMetrics.trackSpacing / 2))
                .offset(y: rowsTop)

            // 置き場所の印(行の領域の外にも出す。いちばん上の行より上の新しい段や、V1 しかないときの V2 の影)
            if let slot = carrySlot {
                carrySlotView(slot, originX: originX, pps: pps)
                    .offset(y: max(0, rowsTop + slot.y - vOffset))
                    .allowsHitTesting(false)
            }

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
        .coordinateSpace(.named(TimelineView.carrySpace))
        .overlay(alignment: .top) {
            if let trackDropHint {
                Text(trackDropHint)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
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
        let labels: [String: [String]] = TimelineMetrics.trackLabels(for: rows)
        ZStack(alignment: .topLeading) {
            // 空いている所のタップ: 後ろの背景と同じく選択を外し、慣性スクロールを止める
            // (この領域はタップの判定を枠に収めているので、後ろの背景まで届かない。上下の端の段の判定の広がり分も覆う)
            Color.clear
                .frame(width: width, height: viewportHeight + TimelineMetrics.trackSpacing)
                .contentShape(Rectangle())
                .onTapGesture {
                    if tapStopsMomentum() { return }
                    selection = nil
                    timeline.targetOverlayLane = nil
                }
                .offset(y: -TimelineMetrics.trackSpacing / 2)
            ForEach(placements) { p in
                trackRow(kind: p.kind, width: width, originX: originX, frame: f, labels: labels[p.kind.key] ?? [])
                    .offset(y: p.y - offset)
                    // 上下に動かしているオーバーレイが、ほかの行(V1 など)の上に出るように
                    .zIndex(carryingOverlayID != nil && isOverlayRow(p.kind) ? 40 : 0)
            }
        }
    }

    private func isOverlayRow(_ kind: TimelineTrackKind) -> Bool {
        if case .overlay = kind { return true }
        return false
    }

    private func overlayLaneCount(of kind: TimelineTrackKind) -> Int? {
        if case .overlay(let lanes) = kind { return lanes }
        return nil
    }

    /// V2・V3 … の札のタップ: その段を追加先に選ぶ(もう一度で外す)。部品の選択は外す
    private func toggleTargetLane(_ lane: Int) {
        if tapStopsMomentum() { return }
        if timeline.targetOverlayLane == lane {
            timeline.targetOverlayLane = nil
        } else {
            selection = nil
            timeline.targetOverlayLane = lane
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 1 行(中身 + 左端のアイコン)
    private func trackRow(kind: TimelineTrackKind, width: CGFloat, originX: CGFloat,
                          frame f: TimelineFrameData, labels: [String]) -> some View {
        // 1 段の高さ(段が複数あるトラックは段ごとに名前を出す)
        let laneHeight: CGFloat
        switch kind {
        case .video: laneHeight = TimelineMetrics.videoHeight
        case .camera: laneHeight = TimelineMetrics.cameraHeight
        case .overlay: laneHeight = TimelineMetrics.overlayHeight
        case .text, .mosaic: laneHeight = TimelineMetrics.textHeight
        case .effect: laneHeight = TimelineMetrics.effectHeight
        case .narration, .linkedAudio: laneHeight = TimelineMetrics.narrationHeight
        default: laneHeight = kind.height
        }
        let laneStep: CGFloat = laneHeight + TimelineMetrics.textLaneGap
        let chipSize: CGFloat = min(TimelineMetrics.trackChipSize, max(12, laneHeight - 2))
        let chipInset: CGFloat = max(0, (laneHeight - chipSize) / 2)
        return ZStack(alignment: .topLeading) {
            trackContent(kind: kind, width: width, originX: originX, frame: f)
            if labels.isEmpty {
                if let icon = kind.iconName {
                    TimelineTrackChip(systemName: icon, rowHeight: laneHeight)
                        .offset(x: 4, y: chipInset)
                        .zIndex(30)
                }
            } else {
                ForEach(Array(labels.enumerated()), id: \.offset) { entry in
                    // オーバーレイの段(V2・V3 …)は札をタップすると追加先に選べる(上の段から並ぶ)
                    let lane: Int? = overlayLaneCount(of: kind).map { $0 - 1 - entry.offset }
                    TimelineTrackLabelChip(label: entry.element, rowHeight: laneHeight,
                                           isSelected: lane != nil && lane == timeline.targetOverlayLane,
                                           tappable: lane != nil)
                        .onTapGesture {
                            if let lane { toggleTargetLane(lane) }
                        }
                        .offset(x: 4, y: CGFloat(entry.offset) * laneStep + chipInset)
                        .zIndex(30)
                }
            }
        }
        .frame(width: width, height: kind.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func trackContent(kind: TimelineTrackKind, width: CGFloat, originX: CGFloat,
                              frame f: TimelineFrameData) -> some View {
        let pps = f.pps
        switch kind {
        case .camera(let lanes):
            cameraTrack(width: width, originX: originX, pps: pps, ranges: f.ranges, lanes: lanes)
        case .overlay:
            overlayTrack(width: width, originX: originX, pps: pps, overlays: f.snapshot.overlays)
        case .video:
            // 「+」タイルは V1 の終わりに置く(f.total は V1 より後ろへはみ出したオーバーレイまで含む)
            videoTrack(width: width, originX: originX, pps: pps, ranges: f.ranges,
                       total: TimelineView.totalEnd(of: f.ranges, fallback: f.snapshot.totalDuration))
        case .text:
            textTrack(width: width, originX: originX, pps: pps,
                      textClips: TimelineMetrics.textOnlyClips(f.snapshot.textClips), mosaic: false)
        case .mosaic:
            textTrack(width: width, originX: originX, pps: pps,
                      textClips: TimelineMetrics.mosaicClips(f.snapshot.textClips), mosaic: true)
        case .drawing:
            drawingTrack(width: width, originX: originX, pps: pps, drawings: f.snapshot.drawings)
        case .effect:
            effectTrack(width: width, originX: originX, pps: pps, effects: f.snapshot.videoEffects)
        case .subtitle:
            subtitleTrack(width: width, originX: originX, pps: pps, subtitles: f.snapshot.subtitles)
        case .audio:
            audioTrack(width: width, originX: originX, pps: pps, total: f.total, audio: f.snapshot.audio)
        case .narration:
            narrationTrack(width: width, originX: originX, pps: pps,
                           narration: TimelineMetrics.narrationOnly(f.snapshot.narration))
        case .linkedAudio(let tracks):
            linkedAudioTrack(width: width, originX: originX, pps: pps, frame: f, tracks: tracks)
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
                Label("キャプション", systemImage: "captions.bubble")
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
            Divider()
            Button {
                onAdd(.coldOpen)
            } label: {
                Label("冒頭フック", systemImage: "bolt.fill")
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

    /// 上下の帯 + 長さのバッジ + 左右のハンドル(掴める幅 44pt を部品の端をはさんで内側と外側に分ける)
    @ViewBuilder
    private func selectionDecor<L: Gesture, T: Gesture>(screenX: CGFloat, width: CGFloat,
                                                        visibleX: CGFloat, visibleWidth: CGFloat,
                                                        y: CGFloat, height: CGFloat, duration: Double,
                                                        leading: L, trailing: T) -> some View {
        let hit = TimelineMetrics.handleHitWidth
        // 外側だけに広げると隣の部品のタップを奪うので半分は内側へ。細い部品は真ん中を動かせるよう内側を狭くする
        let inside: CGFloat = min(hit / 2, max(0, width / 3))
        let badgeX = TimelineMetrics.stickyLabelX(trueX: screenX, visibleX: visibleX,
                                                  visibleWidth: visibleWidth, labelWidth: 44)
        TimelineSelectionFrame(visibleWidth: visibleWidth, height: height, duration: duration, badgeX: badgeX)
            .offset(x: visibleX, y: y)
            .zIndex(18)
        TimelineTrimHandleHitArea(leading: true, inset: inside)
            .frame(width: hit, height: height)
            .offset(x: screenX - hit + inside, y: y)
            .gesture(leading)
            .zIndex(20)
        TimelineTrimHandleHitArea(leading: false, inset: inside)
            .frame(width: hit, height: height)
            .offset(x: screenX + width - inside, y: y)
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

        let pacing: [PacingSegment] = timeline.pacing
        return ZStack(alignment: .topLeading) {
            TimelineRulerView(originX: originX, pointsPerSecond: pps, totalDuration: total)
                .frame(width: width, height: h)
                .allowsHitTesting(false)

            // 中だるみチェックの結果(緑・黄・赤の帯)
            if !pacing.isEmpty {
                TimelinePacingStrip(segments: pacing, originX: originX, pointsPerSecond: pps)
                    .frame(width: width, height: 4)
                    .offset(y: h - 4)
                    .allowsHitTesting(false)
            }

            if hasMarkers {
                // 旗の外(ビートの点など)をタップしたら最寄りのマーカーを選ぶ(無ければ選択解除)
                Color.clear
                    .frame(width: width, height: h)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if tapStopsMomentum() { return }
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
                        if tapStopsMomentum() { return }
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

    // MARK: - カメラのトラック(マルチカメラ)

    /// マルチカメラの切替を、V2・V3 … のカメラのトラックとして描く。データはクリップの中の切替のまま
    /// (合成と同じ区切り方なので、V1 の分割・トリム・無音カット・速度変更のあとも映像とずれない)
    private func cameraTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                             ranges: [TimelineClipRange], lanes: Int) -> some View {
        let h: CGFloat = TimelineMetrics.cameraHeight
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap
        // 並べ替え中はクリップがタイルになるので描かない
        let segments: [TimelineCameraSegment] = reorderClipID == nil
            ? cameraSegments(width: width, originX: originX, pps: pps, ranges: ranges).filter { $0.angle <= lanes }
            : []
        return ZStack(alignment: .topLeading) {
            ForEach(segments) { segment in
                // アングル 1(V2)がいちばん下。上の段ほど番号が大きい
                let laneY: CGFloat = CGFloat(max(0, lanes - segment.angle)) * laneStep
                cameraSegmentMenu(segment, height: h, lanes: lanes)
                    .offset(x: segment.visibleX, y: laneY)
            }
        }
        .frame(width: width, height: TimelineMetrics.stackedHeight(h, lanes: lanes), alignment: .topLeading)
    }

    /// 切替から、画面に描くカメラの区間を作る(映像のある所とない所は分けて描く)
    private func cameraSegments(width: CGFloat, originX: CGFloat, pps: CGFloat,
                                ranges: [TimelineClipRange]) -> [TimelineCameraSegment] {
        var result: [TimelineCameraSegment] = []
        let shiftIndex: Int? = leftTrimClipID.flatMap { project.index(of: $0) }
        let gap: CGFloat = TimelineMetrics.clipGap
        let margin: CGFloat = TimelineMetrics.cullMargin
        // 素材フォルダの場所とアングルの素材の有無は、1 回の描画で 1 度だけ調べる(無音カットの切れ端はどれも同じアングルを持つ)
        let mediaPath = MediaStore.mediaDirectory.standardizedFileURL.path
        var missingByPath: [String: Bool] = [:]
        for (index, clip) in project.clips.enumerated() {
            guard index < ranges.count, !clip.multicam.angles.isEmpty,
                  !(clip.isReversed && clip.reversedURL != nil) else { continue }
            let range = ranges[index]
            // V1 のクリップのバーと同じ位置(左端トリム中のずらしも同じ)
            var clipX: CGFloat = originX + CGFloat(range.start) * pps
            if let shiftIndex, index >= shiftIndex {
                clipX += CGFloat(leftTrimShiftSeconds) * pps
            }
            var barLeft: CGFloat = clipX + gap / 2
            var barRight: CGFloat = clipX + max(CGFloat(range.duration) * pps - gap / 2, gap / 2 + 1)
            // V1(clipItems)と同じく、トランジションで重なる所は重なりの中央を切れ目にする(隣のクリップの区間と重ならない)
            let shift: Double = leftTrimShiftSeconds
            if index > 0 {
                var prevEnd: Double = ranges[index - 1].end
                var myStart: Double = range.start
                if let shiftIndex {
                    if index - 1 >= shiftIndex { prevEnd += shift }
                    if index >= shiftIndex { myStart += shift }
                }
                if prevEnd > myStart {
                    barLeft = max(barLeft, originX + CGFloat((prevEnd + myStart) / 2) * pps + gap / 2)
                }
            }
            if index + 1 < project.clips.count, index + 1 < ranges.count {
                var myEnd: Double = range.end
                var nextStart: Double = ranges[index + 1].start
                if let shiftIndex {
                    if index >= shiftIndex { myEnd += shift }
                    if index + 1 >= shiftIndex { nextStart += shift }
                }
                if myEnd > nextStart {
                    barRight = min(barRight, originX + CGFloat((myEnd + nextStart) / 2) * pps - gap / 2)
                }
            }
            // 画面の外のクリップは調べない(区間はどれも barLeft...barRight に収まるので、描くものは変わらない)。
            // 再生中は毎コマ描き直すので、長い多カメラの収録を無音カットした後も重くならないように
            guard barRight > -margin, barLeft < width + margin else { continue }
            let runs = MulticamSwitcherPanel.runs(multicam: clip.multicam, start: clip.startTime, end: clip.endTime)
            // 素材フォルダに無い・写真ライブラリから読めないアングルは、合成ではメインの映像になるので「映像なし」で描く
            var missingAngles: Set<Int> = []
            for k in clip.multicam.angles.indices {
                let url = clip.multicam.angles[k].url
                let path = url.standardizedFileURL.path
                let missing: Bool
                if let known = missingByPath[path] {
                    missing = known
                } else {
                    missing = ProjectStore.isUnavailablePhotoURL(url)
                        || (path.hasPrefix(mediaPath) && !FileManager.default.fileExists(atPath: url.path))
                    missingByPath[path] = missing
                }
                if missing { missingAngles.insert(k) }
            }
            for run in runs where run.angle >= 1 && run.angle <= clip.multicam.angles.count {
                let angle = clip.multicam.angles[run.angle - 1]
                let footageStart = angle.mainTime(atAngle: 0)
                let footageEnd = angle.mainTime(atAngle: angle.duration)
                var pieces: [(start: Double, end: Double, hasFootage: Bool)] = []
                let fs = max(run.start, footageStart)
                let fe = min(run.end, footageEnd)
                if fe > fs && !missingAngles.contains(run.angle - 1) {
                    if fs > run.start { pieces.append((start: run.start, end: fs, hasFootage: false)) }
                    pieces.append((start: fs, end: fe, hasFootage: true))
                    if run.end > fe { pieces.append((start: fe, end: run.end, hasFootage: false)) }
                } else {
                    pieces.append((start: run.start, end: run.end, hasFootage: false))
                }
                for piece in pieces {
                    let x0: CGFloat = clipX + CGFloat(clip.outputOffset(atSourceTime: piece.start)) * pps
                    let x1: CGFloat = clipX + CGFloat(clip.outputOffset(atSourceTime: piece.end)) * pps
                    let left: CGFloat = max(x0, barLeft)
                    let right: CGFloat = min(x1, barRight)
                    guard right - left >= 1,
                          let span = TimelineMetrics.visibleSpan(x: left, width: right - left, viewWidth: width) else { continue }
                    result.append(TimelineCameraSegment(
                        id: "\(clip.id.uuidString)-\(piece.start)",
                        clipID: clip.id,
                        angle: run.angle,
                        angleCount: clip.multicam.angles.count,
                        // 映像なしの部分のメニューは、その部分だけを変える(隣の映像のある部分は残す)。
                        // 映像のある部分は切替の区間ごと(前後の映像なしも一緒に変える)
                        runStart: piece.hasFootage ? run.start : piece.start,
                        runEnd: piece.hasFootage ? run.end : piece.end,
                        hasFootage: piece.hasFootage,
                        visibleX: span.x,
                        visibleWidth: span.width,
                        timelineStart: range.start + clip.outputOffset(atSourceTime: piece.start)))
                }
            }
        }
        return result
    }

    /// 区間のバー。ほかの部品と同じく onTapGesture にする(Menu は押した瞬間に開くので、
    /// バーの上から始めたスクラブがメニューになり、指を離した所の操作が選ばれてしまう)。操作は confirmationDialog で出す
    private func cameraSegmentMenu(_ segment: TimelineCameraSegment, height: CGFloat, lanes: Int) -> some View {
        TimelineCameraBar(angle: segment.angle,
                          hasFootage: segment.hasFootage,
                          width: segment.visibleWidth,
                          height: height)
            // ほかの部品と同じく、段の判定を行間の半分まで広げる(すき間のタップで選択が外れないように)
            .timelineLaneHitArea(row: max(0, lanes - segment.angle), rows: lanes)
            .onTapGesture {
                // 慣性スクロール中のタップはスクロールを止めるだけ
                if tapStopsMomentum() { return }
                cameraActionSegment = segment
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "アングル\(segment.angle)"))
            .accessibilityAddTraits(.isButton)
    }

    /// カメラの区間の操作: ほかのカメラにする / 消す(V1 に戻す)/ スイッチャーで開く
    @ViewBuilder
    private func cameraSegmentActions(_ segment: TimelineCameraSegment) -> some View {
        ForEach(1...max(1, segment.angleCount), id: \.self) { n in
            if n != segment.angle {
                Button("アングル\(n)(V\(n + 1))にする") {
                    setCameraAngle(segment, to: n)
                }
            }
        }
        Button("このカットを消す(V1 に戻す)", role: .destructive) {
            setCameraAngle(segment, to: 0)
        }
        if onOpenMulticam != nil {
            Button("スイッチャーで開く") {
                onOpenMulticam?(segment.clipID, segment.timelineStart + 0.01)
            }
        }
    }

    /// 区間のカメラを変える(0 = メインに戻す)。↶ で戻せる
    private func setCameraAngle(_ segment: TimelineCameraSegment, to angle: Int) {
        guard let index = project.index(of: segment.clipID) else { return }
        history.record(project)
        var clip = project.clips[index]
        clip.multicam.setAngle(angle, from: segment.runStart, to: segment.runEnd)
        project.clips[index] = clip
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 重ね合わせトラック

    /// lanes は段(重なりの深さ)の割り当て(TimelineMetrics.overlayLanes。ドラッグ中は固定したもの)
    private func overlayItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                              overlays: [OverlayClip], lanes: [UUID: Int]) -> [TimelineOverlayItem] {
        var result: [TimelineOverlayItem] = []
        for overlay in overlays {
            let x = originX + CGFloat(overlay.start) * pps
            let w = max(CGFloat(overlay.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 70)
            result.append(TimelineOverlayItem(id: overlay.id, overlay: overlay, screenX: x, width: w,
                                              visibleX: span.x, visibleWidth: span.width,
                                              labelX: labelX, depth: lanes[overlay.id] ?? 0))
        }
        return result
    }

    private func overlayTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                              overlays: [OverlayClip]) -> some View {
        let h = TimelineMetrics.overlayHeight
        // 時間が重なるオーバーレイは別の段に並べる(depth = 段)。ドラッグ中は固定
        let lanes: [UUID: Int] = frozenLanes?.overlayLanes ?? TimelineMetrics.overlayLanes(overlays)
        let items = overlayItems(width: width, originX: originX, pps: pps, overlays: overlays, lanes: lanes)
        let selectedID: UUID? = selection?.overlayID
        let selectedItem: TimelineOverlayItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })
        let laneCount: Int = TimelineMetrics.laneCount(lanes)
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                // 段 0(V2)をいちばん下にして、上の段ほど番号が大きい(V1 の上へ積み重ねる)
                let laneY: CGFloat = CGFloat(laneCount - 1 - item.depth) * laneStep
                TimelineOverlayBar(overlay: item.overlay,
                                   labelX: item.labelX,
                                   visibleWidth: item.visibleWidth,
                                   height: h,
                                   isSelected: isSel)
                    .timelineLaneHitArea(row: laneCount - 1 - item.depth, rows: laneCount)
                    .shadow(color: .black.opacity(item.id == carryingOverlayID ? 0.45 : 0), radius: 6, y: 3)
                    // 上下に動かしている間は指に付いて動く(離した段へ置く)
                    .offset(x: item.visibleX, y: laneY + (item.id == carryingOverlayID ? carryOffsetY : 0))
                    .onTapGesture {
                        if tapStopsMomentum() { return }
                        selection = .overlay(item.id)
                    }
                    .gesture(overlayMoveGesture(id: item.id, width: width), including: isSel ? .all : .subviews)
                    // 選んでいないものは長押しでつかんで動かす(V1 の並べ替えと同じ)
                    .gesture(overlayLiftGesture(id: item.id, width: width), including: isSel ? .subviews : .all)
                    .zIndex(item.id == carryingOverlayID ? 20 : (isSel ? 10 : Double(item.depth)))
            }

            // 選んだ段(追加先)を薄く塗り、再生位置の右に「動画・写真を追加」を出す
            if let target = timeline.targetOverlayLane, target < laneCount {
                let laneTop: CGFloat = CGFloat(laneCount - 1 - target) * laneStep
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: width, height: h)
                    .offset(y: laneTop)
                    .allowsHitTesting(false)
                    .zIndex(-1)
                Button {
                    onAdd(.overlay)
                } label: {
                    Label("動画・写真を追加", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: max(20, h - 8))
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .offset(x: width / 2 + 6, y: laneTop + (h - max(20, h - 8)) / 2)
                .zIndex(25)
            }

            if let sel = selectedItem, sel.id != carryingOverlayID {
                let inset: CGFloat = CGFloat(laneCount - 1 - sel.depth) * laneStep
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
        // 並べ替え中はどのクリップも同じ幅のタイルにして詰めて並べる(長いクリップでも隣の中点を越えられる)。
        // 持ち上げたクリップ(かたまりなら先頭)は reorderAnchorX + 指の移動量に置く
        let reordering = reorderClipID != nil
        let tileStep: CGFloat = TimelineMetrics.tileWidth + gap
        let groupSet: Set<UUID> = Set(reorderGroupIDs)
        let groupFirstIndex: Int? = groupSet.isEmpty ? nil : clips.firstIndex(where: { groupSet.contains($0.id) })
        // ranges が足りないときの保険(重なりなしで並べた位置)
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            let d = max(0, clip.outputDuration)
            let range: TimelineClipRange = i < ranges.count ? ranges[i] : TimelineClipRange(start: t, end: t + d)
            t += d
            let fullWidth = reordering ? tileStep : CGFloat(range.duration) * pps
            var contentX = reordering ? reorderSlotX(i) : CGFloat(range.start) * pps
            if let shiftIndex, i >= shiftIndex {
                contentX += CGFloat(shift) * pps
            }
            var lifted = false
            if let groupFirstIndex, groupSet.contains(clip.id) {
                contentX = reorderAnchorX + reorderTranslation + CGFloat(i - groupFirstIndex) * tileStep
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

            // このクリップから次のクリップへの切れ目(重なりの中央にバッジ。トランジションが無ければ小さなボタン)
            if reorderClipID == nil, i + 1 < clips.count {
                let next: TimelineClipRange = i + 1 < ranges.count ? ranges[i + 1] : TimelineClipRange(start: t, end: t)
                var endA = range.end
                var startB = next.start
                if let shiftIndex {
                    if i >= shiftIndex { endA += shift }
                    if i + 1 >= shiftIndex { startB += shift }
                }
                let cx = originX + CGFloat((endA + startB) / 2) * pps
                let x0 = originX + CGFloat(min(endA, startB)) * pps
                let x1 = originX + CGFloat(max(endA, startB)) * pps
                if cx.isFinite, x0.isFinite, x1.isFinite, x1 > -margin, x0 < width + margin {
                    // 前後のクリップの細い方の半分まで(クリップ本体のタップ・長押しを残す)
                    let narrower: CGFloat = min(CGFloat(range.duration), CGFloat(next.duration)) * pps
                    let hitW: CGFloat = min(TimelineMetrics.transitionHitSize,
                                            max(TimelineMetrics.transitionBadgeSize, narrower * 0.5))
                    transitions.append(TimelineTransitionItem(id: clip.id, centerX: cx, startX: x0, endX: x1,
                                                              seconds: max(0, endA - startB),
                                                              type: clip.transition.type,
                                                              isActive: clip.transition.isActive,
                                                              hitWidth: hitW,
                                                              nextID: clips[i + 1].id))
                }
            }

            // トランジションで重なっている部分は、重なりの中央を切れ目として描く(前後のクリップが重ならない)
            var drawX = screenX
            var drawEnd = screenX + w
            if !lifted, reorderClipID == nil {
                if i > 0, i - 1 < ranges.count {
                    var prevEnd = ranges[i - 1].end
                    var myStart = range.start
                    if let shiftIndex {
                        if i - 1 >= shiftIndex { prevEnd += shift }
                        if i >= shiftIndex { myStart += shift }
                    }
                    if prevEnd > myStart {
                        drawX = max(drawX, originX + CGFloat((prevEnd + myStart) / 2) * pps + gap / 2)
                    }
                }
                if i + 1 < clips.count, i + 1 < ranges.count {
                    var myEnd = range.end
                    var nextStart = ranges[i + 1].start
                    if let shiftIndex {
                        if i >= shiftIndex { myEnd += shift }
                        if i + 1 >= shiftIndex { nextStart += shift }
                    }
                    if myEnd > nextStart {
                        drawEnd = min(drawEnd, originX + CGFloat((myEnd + nextStart) / 2) * pps - gap / 2)
                    }
                }
            }
            guard drawEnd - drawX >= 1,
                  let span = TimelineMetrics.visibleSpan(x: drawX, width: drawEnd - drawX, viewWidth: width) else { continue }
            result.append(TimelineClipItem(id: clip.id, clip: clip, screenX: screenX, width: w,
                                           visibleX: span.x, visibleWidth: span.width, isLifted: lifted))
        }
        return (result, bars, transitions)
    }

    private func videoTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                            ranges: [TimelineClipRange], total: Double) -> some View {
        let h = TimelineMetrics.videoHeight
        let lane = TimelineMetrics.splitAudioLaneHeight
        let waveH = TimelineMetrics.audioWaveOverlayHeight
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
                    // 慣性スクロール中に指の下へ滑ってきたタイルでは開かない(止めるだけ)
                    if tapStopsMomentum() { return }
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
                        if tapStopsMomentum() { return }
                        if timeline.isMultiSelecting {
                            timeline.toggleMultiSelect(item.id)
                            UISelectionFeedbackGenerator().selectionChanged()
                        } else {
                            selection = .clip(item.id)
                        }
                    }
                    .gesture(reorderGesture(clipID: item.id, width: width))
                    .zIndex(item.isLifted ? 10 : (item.id == selectedClipID ? 1 : 0))
            }

            // サムネイルの下部に重ねる、クリップの音の大きさの波形(別の段にせず、プレビューを広く保つ)
            TimelineClipAudioLane(items: items, pointsPerSecond: pps, height: waveH)
                .frame(width: width, height: waveH, alignment: .topLeading)
                .offset(y: h - waveH)
                .zIndex(4)

            if !splitBars.isEmpty {
                TimelineSplitAudioLane(bars: splitBars)
                    .frame(width: width, height: lane)
                    .offset(y: h)
                    .zIndex(5)
            }

            ForEach(transitions) { item in
                // 選択中のクリップの両端はトリムハンドルが受けるので、押せる範囲を広げない
                let nearSelected: Bool = selectedItem != nil
                    && (item.id == selectedClipID || item.nextID == selectedClipID)
                let hitW: CGFloat = nearSelected ? badge : item.hitWidth
                let hitH: CGFloat = nearSelected ? badge : min(TimelineMetrics.transitionHitSize, h)
                if item.isActive {
                    let bandW = max(4, item.endX - item.startX)
                    TimelineTransitionRange(seconds: item.seconds, isSelected: item.id == selectedClipID)
                        .frame(width: bandW, height: h)
                        .offset(x: item.centerX - bandW / 2)
                        .allowsHitTesting(false)
                        .zIndex(14)
                    TimelineTransitionBadge(type: item.type, isSelected: item.id == selectedClipID)
                        .frame(width: badge, height: badge)
                        .frame(width: hitW, height: hitH)
                        .contentShape(Rectangle())
                        .offset(x: item.centerX - hitW / 2, y: (h - hitH) / 2)
                        .onTapGesture {
                            transitionTapped(item.id)
                        }
                        .allowsHitTesting(!isMulti)
                        .zIndex(15)
                } else if !nearSelected && !isMulti {
                    TimelineTransitionAddButton()
                        .frame(width: hitW, height: hitH)
                        .contentShape(Rectangle())
                        .offset(x: item.centerX - hitW / 2, y: (h - hitH) / 2)
                        .onTapGesture {
                            transitionTapped(item.id)
                        }
                        .zIndex(15)
                }
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

    /// 切れ目のボタン・バッジ: トランジションの設定を直接開く(前側のクリップを選んでから)
    private func transitionTapped(_ clipID: UUID) {
        if tapStopsMomentum() { return }
        selection = .clip(clipID)
        onTransition?(clipID)
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

    /// テキスト・ステッカー行(mosaic = false)と、モザイク(FX)行(mosaic = true)の両方をこの 1 つで描く。
    /// textClips には行に出す部品だけ(モザイク以外 / モザイクだけ)を渡し、段もその中だけで決める
    private func textTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                           textClips: [TextClip], mosaic: Bool) -> some View {
        let h = TimelineMetrics.textHeight
        let items = textItems(width: width, originX: originX, pps: pps, textClips: textClips)
        // 選択中の部品がこの行の物でなければ(モザイクをテキスト行で、など)選択枠は出さない
        let selectedID: UUID? = selection?.textID.flatMap { id in
            textClips.contains(where: { $0.id == id }) ? id : nil
        }
        let selectedItem: TimelineTextItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })
        // 時間が重なるテキストは別の段に並べる(ドラッグ中は固定)。モザイクはモザイクどうしだけで段を決める
        let frozen: [UUID: Int]? = mosaic ? frozenLanes?.mosaicLanes : frozenLanes?.textLanes
        let lanes: [UUID: Int] = frozen ?? TimelineMetrics.textLanes(textClips)
        let laneCount: Int = (lanes.values.max() ?? 0) + 1
        let trackHeight: CGFloat = TimelineMetrics.textTrackHeight(lanes: laneCount)
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap
        // 段 0 をいちばん下にして、上の段ほど番号が大きい(V1 の上へ積み重ねる)
        let selectedY: CGFloat = CGFloat(laneCount - 1 - (selectedID.flatMap { lanes[$0] } ?? 0)) * laneStep

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                let laneY: CGFloat = CGFloat(laneCount - 1 - (lanes[item.id] ?? 0)) * laneStep
                TimelineTextBar(textClip: item.textClip,
                                labelX: item.labelX,
                                visibleWidth: item.visibleWidth,
                                height: h,
                                isSelected: isSel)
                    .timelineLaneHitArea(row: laneCount - 1 - (lanes[item.id] ?? 0), rows: laneCount)
                    .offset(x: item.visibleX, y: laneY)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
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
                    .timelineLaneHitArea(row: 0, rows: 1)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
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

    // MARK: - 映像エフェクトトラック

    private func effectItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                             effects: [VideoEffectClip]) -> [TimelineEffectItem] {
        var result: [TimelineEffectItem] = []
        for effect in effects {
            let x = originX + CGFloat(effect.start) * pps
            let w = max(CGFloat(effect.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 40)
            result.append(TimelineEffectItem(id: effect.id, effect: effect, screenX: x, width: w,
                                             visibleX: span.x, visibleWidth: span.width, labelX: labelX))
        }
        return result
    }

    /// 映像エフェクトの行(時間が重なるものは別の段。段 0 がいちばん下)
    private func effectTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                             effects: [VideoEffectClip]) -> some View {
        let h = TimelineMetrics.effectHeight
        let items = effectItems(width: width, originX: originX, pps: pps, effects: effects)
        let selectedID: UUID? = selection?.videoEffectID
        let selectedItem: TimelineEffectItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })
        let lanes: [UUID: Int] = frozenLanes?.effectLanes ?? TimelineMetrics.effectLanes(effects)
        let laneCount: Int = max(1, (lanes.values.max() ?? 0) + 1)
        let trackHeight: CGFloat = TimelineMetrics.stackedHeight(h, lanes: laneCount)
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap
        let selectedY: CGFloat = CGFloat(laneCount - 1 - (selectedID.flatMap { lanes[$0] } ?? 0)) * laneStep

        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let isSel = item.id == selectedID
                let row = laneCount - 1 - (lanes[item.id] ?? 0)
                TimelineEffectBar(effect: item.effect,
                                  labelX: item.labelX,
                                  visibleWidth: item.visibleWidth,
                                  height: h,
                                  isSelected: isSel)
                    .timelineLaneHitArea(row: row, rows: laneCount)
                    .offset(x: item.visibleX, y: CGFloat(row) * laneStep)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
                        selection = .videoEffect(item.id)
                    }
                    .gesture(effectMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 1 : 0)
            }

            if let sel = selectedItem {
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: selectedY, height: h, duration: sel.effect.duration,
                               leading: effectTrimGesture(id: sel.id, leading: true),
                               trailing: effectTrimGesture(id: sel.id, leading: false))
            }
        }
        .frame(width: width, height: trackHeight, alignment: .topLeading)
    }

    private func effectMoveGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard shouldBeginEdit(value), let effect = project.videoEffects.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveEffect(id: id, originalStart: effect.start), snapExcluding: id)
                }
                applyEffectEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func effectTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard shouldBeginEdit(value), let effect = project.videoEffects.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimEffect(id: id, leading: leading, original: effect), snapExcluding: id)
                }
                applyEffectEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func applyEffectEdit(translation: CGFloat) {
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let delta = Double(translation) / pps
        let minimumLength = 0.3
        switch interaction.edit {
        case let .moveEffect(id, originalStart)?:
            guard let i = project.videoEffects.firstIndex(where: { $0.id == id }) else { return }
            let length = max(0, project.videoEffects[i].duration)
            let upperStart = max(0, max(timelineDuration(), originalStart + length) - length)
            let moved = snappedDelta(delta, edges: [originalStart, originalStart + length])
            let newStart = min(max(0, originalStart + moved), upperStart)
            if abs(project.videoEffects[i].start - newStart) > 0.0001 {
                recordEditHistory()
                project.videoEffects[i].start = newStart
            }
        case let .trimEffect(id, leading, original)?:
            guard let i = project.videoEffects.firstIndex(where: { $0.id == id }) else { return }
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
            if project.videoEffects[i] != updated {
                recordEditHistory()
                project.videoEffects[i] = updated
            }
        default:
            break
        }
    }

    // MARK: - 字幕トラック

    private func subtitleItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                               subtitles: [SubtitleCue]) -> [TimelineSpanItem] {
        var result: [TimelineSpanItem] = []
        for (index, cue) in subtitles.enumerated() {
            let x = originX + CGFloat(cue.start) * pps
            let w = max(CGFloat(cue.duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { continue }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 24)
            // 要確認かどうかは、見えている字幕だけ調べる(再生中も毎フレーム描き直すため)
            let previous: SubtitleCue? = index > 0 ? subtitles[index - 1] : nil
            let flagged = CaptionIssueCheck.issue(for: cue, previous: previous) != nil
            result.append(TimelineSpanItem(id: cue.id, text: cue.text, screenX: x, width: w,
                                           visibleX: span.x, visibleWidth: span.width, labelX: labelX,
                                           duration: cue.duration, isFlagged: flagged))
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
                                        isSelected: isSel,
                                        isFlagged: item.isFlagged)
                    .timelineLaneHitArea(row: 0, rows: 1)
                    .offset(x: item.visibleX)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
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
                    .timelineLaneHitArea(row: 0, rows: 1)
                    .offset(x: span.x)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
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
        // 時間が重なるナレーションは別の段に並べる(ドラッグ中は固定)
        let lanes: [UUID: Int] = frozenLanes?.narrationLanes ?? TimelineMetrics.narrationLanes(narration)
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
                    .timelineLaneHitArea(row: lanes[item.id] ?? 0, rows: laneCount)
                    .offset(x: item.visibleX, y: laneY)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
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

    // MARK: - 映像の音声の段(A1 = V1、A2 = V2 …)

    /// 映像とリンク中の音声。V1 のクリップ・オーバーレイと同じ位置に描き、タップでその映像を選ぶ
    /// (動かす・長さを変える・切るは映像の側で。音声もいっしょに変わる)
    private func linkedAudioItems(width: CGFloat, originX: CGFloat, pps: CGFloat,
                                  frame f: TimelineFrameData, tracks: Int) -> [TimelineLinkedAudioItem] {
        var result: [TimelineLinkedAudioItem] = []
        func add(id: UUID, name: String, url: URL, sourceStart: Double, start: Double, duration: Double,
                 lane: Int, target: EditorSelection, waveform: Bool) {
            let x = originX + CGFloat(start) * pps
            let w = max(CGFloat(duration) * pps, 6)
            guard let span = TimelineMetrics.visibleSpan(x: x, width: w, viewWidth: width) else { return }
            let labelX = TimelineMetrics.stickyLabelX(trueX: x, visibleX: span.x,
                                                      visibleWidth: span.width, labelWidth: 60)
            var display = NarrationClip(url: url, name: name, start: start, duration: duration)
            display.sourceStart = sourceStart
            result.append(TimelineLinkedAudioItem(id: id, clip: display, lane: lane, screenX: x,
                                                  visibleX: span.x, visibleWidth: span.width, labelX: labelX,
                                                  target: target, showsWaveform: waveform))
        }
        let snapshot = f.snapshot
        for (i, clip) in snapshot.clips.enumerated() where i < f.ranges.count && TimelineMetrics.clipHasLinkedAudio(clip) {
            let range = f.ranges[i]
            // 速度を変えたクリップは音声ファイルの位置と合わないので波形を出さない
            let plain = abs(clip.speed - 1) < 0.001 && !clip.speedCurve.enabled && !clip.isReversed
            add(id: clip.id, name: clip.name, url: clip.url, sourceStart: clip.startTime,
                start: range.start, duration: range.duration, lane: 0, target: .clip(clip.id), waveform: plain)
        }
        let overlayLanes: [UUID: Int] = frozenLanes?.overlayLanes ?? TimelineMetrics.overlayLanes(snapshot.overlays)
        for overlay in snapshot.overlays where TimelineMetrics.overlayHasLinkedAudio(overlay) {
            let lane = (overlayLanes[overlay.id] ?? 0) + 1
            guard lane < tracks else { continue }
            add(id: overlay.id, name: overlay.name, url: overlay.url, sourceStart: overlay.sourceStart,
                start: overlay.start, duration: overlay.duration, lane: lane, target: .overlay(overlay.id),
                waveform: abs(overlay.speed - 1) < 0.001)
        }
        return result
    }

    private func linkedAudioTrack(width: CGFloat, originX: CGFloat, pps: CGFloat,
                                  frame f: TimelineFrameData, tracks: Int) -> some View {
        let h = TimelineMetrics.narrationHeight
        let laneStep: CGFloat = h + TimelineMetrics.textLaneGap
        let linked = linkedAudioItems(width: width, originX: originX, pps: pps, frame: f, tracks: tracks)
        // リンクを解除した音声(その段で別々に動かす・長さを変える・切る)
        let unlinked: [NarrationClip] = f.snapshot.narration.filter { n in
            guard let track = n.track else { return false }
            return track >= 1 && track <= tracks
        }
        let items = narrationItems(width: width, originX: originX, pps: pps, narration: unlinked)
        let selectedID: UUID? = selection?.narrationID
        let selectedItem: TimelineNarrationItem? = selectedID == nil ? nil : items.first(where: { $0.id == selectedID })
        func lane(of clip: NarrationClip) -> Int { max(0, (clip.track ?? 1) - 1) }

        return ZStack(alignment: .topLeading) {
            ForEach(linked) { item in
                TimelineNarrationBar(clip: item.clip,
                                     screenX: item.screenX,
                                     visibleX: item.visibleX,
                                     visibleWidth: item.visibleWidth,
                                     pointsPerSecond: pps,
                                     labelX: item.labelX,
                                     height: h,
                                     isSelected: selection == item.target,
                                     color: TimelineMetrics.linkedAudioColor,
                                     iconName: "link",
                                     showsWaveform: item.showsWaveform)
                    .timelineLaneHitArea(row: item.lane, rows: tracks)
                    .offset(x: item.visibleX, y: CGFloat(item.lane) * laneStep)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
                        selection = item.target
                    }
            }

            ForEach(items) { item in
                let isSel = item.id == selectedID
                let row = lane(of: item.clip)
                TimelineNarrationBar(clip: item.clip,
                                     screenX: item.screenX,
                                     visibleX: item.visibleX,
                                     visibleWidth: item.visibleWidth,
                                     pointsPerSecond: pps,
                                     labelX: item.labelX,
                                     height: h,
                                     isSelected: isSel,
                                     iconName: "waveform")
                    .timelineLaneHitArea(row: row, rows: tracks)
                    .offset(x: item.visibleX, y: CGFloat(row) * laneStep)
                    .onTapGesture {
                        if tapStopsMomentum() { return }
                        selection = .narration(item.id)
                    }
                    .gesture(narrationMoveGesture(id: item.id), including: isSel ? .all : .subviews)
                    .zIndex(isSel ? 2 : 1)
            }

            if let sel = selectedItem {
                selectionDecor(screenX: sel.screenX, width: sel.width,
                               visibleX: sel.visibleX, visibleWidth: sel.visibleWidth,
                               y: CGFloat(lane(of: sel.clip)) * laneStep, height: h, duration: sel.clip.duration,
                               leading: narrationTrimGesture(id: sel.id, leading: true),
                               trailing: narrationTrimGesture(id: sel.id, leading: false))
                    .zIndex(3)
            }
        }
        .frame(width: width, height: TimelineMetrics.stackedHeight(h, lanes: tracks), alignment: .topLeading)
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
        // 選択中の部品に触れていて横に動かしているなら、その部品の移動・トリムが始まるのを待つ(縦なら縦スクロール)
        if interaction.editPending,
           interaction.editAllowsVertical || abs(value.translation.width) >= abs(value.translation.height) { return }

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

    /// 慣性スクロール中のタップは止めるだけにする(指の下に滑ってきた部品を選ばない)。止めたら true
    private func tapStopsMomentum() -> Bool {
        guard momentumTask != nil else { return false }
        endScrubbing()
        return true
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
                if interaction.edit != nil {
                    // 選択中の部品の上で始めたピンチが移動・トリムにならないよう、途中の編集は取り消す
                    cancelEdit()
                }
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
        for e in snapshot.videoEffects where e.id != id {
            targets.append(e.start)
            targets.append(e.end)
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
        // 動かしていないうちは吸い付かせない(触れただけで再生位置や隣の端へ飛ばない)
        guard abs(delta) > 0.0001 else {
            setSnapGuide(nil)
            return delta
        }
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

    /// 選択中の部品に触れただけでは動かさない。editStartDistance 以上、横方向が主のドラッグになったら編集を始める。
    /// 縦方向が主なら(トラックの縦スクロール)この指では編集しない
    /// allowVertical: 縦のドラッグでも編集を始める(オーバーレイを V2・V3 … の別の段へ動かす)
    private func shouldBeginEdit(_ value: DragGesture.Value, allowVertical: Bool = false) -> Bool {
        if interaction.editDeclined { return false }
        // 触れている間は、横のドラッグをタイムラインのスクロールに渡さない(scrollChanged)
        interaction.editPending = true
        interaction.editAllowsVertical = allowVertical
        let dx = abs(value.translation.width)
        let dy = abs(value.translation.height)
        guard max(dx, dy) >= TimelineMetrics.editStartDistance else { return false }
        interaction.editPending = false
        if dy > dx && !allowVertical {
            interaction.editDeclined = true
            return false
        }
        return true
    }

    private func beginEdit(_ kind: TimelineEditKind, snapExcluding id: UUID? = nil, snaps: Bool = true) {
        if interaction.scrollStartTime != nil {
            interaction.scrollStartTime = nil
            interaction.scrollBlocked = true
        }
        endScrubbing()
        if player.isPlaying { player.pause() }
        interaction.edit = kind
        // 画面側はこの間タイムラインの高さを固定する(finishEdit で戻す。取り消しもそこを通る)
        timeline.isEditing = true
        // 履歴は最初に実際に値が変わるときに取る(recordEditHistory)。触れただけでは取らず、やり直しも消さない
        interaction.historyRecorded = false
        switch kind {
        case .trimClip, .reorder:
            // V1 を変えたあと、ほかのトラックの部品を同じ元素材の位置に付いたまま動かす(finishEdit)
            interaction.clipLayout = project.captureClipLayout()
        default:
            interaction.clipLayout = nil
        }
        interaction.snapTargets = snaps ? collectSnapTargets(excluding: id) : []
        interaction.lastSnapTarget = nil
        interaction.snapPrimed = false
        interaction.atTrimLimit = false
        freezeLanes()
        // 操作中はプレビューの合成を作り直さない(終了時に 1 回だけ)
        player.beginInteraction()
        if !hintShown {
            hintShown = true
        }
    }

    /// 最初に実際に値が変わるときに 1 回だけ履歴を取る(値を変える直前に呼ぶ)
    private func recordEditHistory() {
        guard interaction.edit != nil, !interaction.historyRecorded else { return }
        interaction.historyRecorded = true
        history.record(project)
    }

    /// ドラッグ中は段の割り当てと行の高さを今のまま固定する(動かすたびにバーが段を飛んだり行の高さが変わったりしない)
    private func freezeLanes() {
        let snapshot = project.snapshot()
        frozenLanes = TimelineFrozenLanes(rows: TimelineMetrics.visibleTracks(for: snapshot),
                                          textLanes: TimelineMetrics.textLanes(TimelineMetrics.textOnlyClips(snapshot.textClips)),
                                          mosaicLanes: TimelineMetrics.mosaicLanes(snapshot.textClips),
                                          overlayLanes: TimelineMetrics.overlayLanes(snapshot.overlays),
                                          narrationLanes: TimelineMetrics.narrationLanes(snapshot.narration),
                                          effectLanes: TimelineMetrics.effectLanes(snapshot.videoEffects))
    }

    private func finishEdit() {
        // 編集が始まらなかった指(触れただけ・縦スクロール・ピンチで取り消し)の後始末
        interaction.editPending = false
        interaction.editDeclined = false
        interaction.editAllowsVertical = false
        let startOverlayLanes = interaction.editStartOverlayLanes
        interaction.editStartOverlayLanes = nil
        let carryLane = interaction.carryLane
        let carryStart = interaction.carryStart
        interaction.carryLane = nil
        interaction.carryStart = nil
        if liftingClip {
            liftingClip = false
        }
        if carrySlot != nil {
            carrySlot = nil
        }
        let overlayToMain = interaction.overlayToMain
        let clipToOverlay = interaction.clipToOverlay
        interaction.overlayToMain = false
        interaction.clipToOverlay = false
        if trackDropHint != nil {
            trackDropHint = nil
        }
        guard let edit = interaction.edit else { return }
        var liftClipID: UUID? = nil
        interaction.edit = nil
        timeline.isEditing = false
        switch edit {
        case .trimClip:
            leftTrimClipID = nil
            leftTrimShiftSeconds = 0
            // プレビューに重ねていた端のコマを消す
            timeline.clearTrimPreview()
        case .trimSubtitle, .moveSubtitle:
            project.sortSubtitles()
        case .reorder(let id):
            reorderScrollTask?.cancel()
            reorderScrollTask = nil
            interaction.reorderScrollFactor = 0
            // V2 へ持ち上げるときは、並べ替えた分を戻してから(持ち上げる前の位置の時刻から重ねる)
            // 持ち上げられるかは並べ替える前の並び(戻した後)で決める
            if clipToOverlay, let startClips = interaction.editStartClips {
                let reordered = project.clips
                project.clips = startClips
                if project.canLiftClipToOverlay(id: id) {
                    liftClipID = id
                } else {
                    project.clips = reordered
                }
            }
            interaction.editStartClips = nil
            // 端の自動スクロールで動いた分は、その位置を再生位置にする
            endScrubbing()
            withAnimation(.easeOut(duration: 0.18)) {
                reorderClipID = nil
                reorderTranslation = 0
                reorderGroupIDs = []
            }
        case let .moveOverlay(id, _) where overlayToMain:
            project.sortOverlays()
            dropOverlayToMain(id: id)
        case let .moveOverlay(id, _):
            // 上下に動かして別の段で離したら、その段へ(ほかのオーバーレイは動かし始めたときの段のまま固定)
            if let lane = carryLane, let original = startOverlayLanes, lane != original[id] {
                if !interaction.historyRecorded {
                    history.record(project)
                    interaction.historyRecorded = true
                }
                for j in project.overlays.indices {
                    project.overlays[j].lane = original[project.overlays[j].id] ?? 0
                }
                if let i = project.overlays.firstIndex(where: { $0.id == id }) {
                    project.overlays[i].lane = lane
                }
            }
            project.sortOverlays()
        case .trimOverlay:
            project.sortOverlays()
        case .moveNarration, .trimNarration:
            project.sortNarration()
        case .moveText, .trimText:
            project.sortTextClips()
        case .moveDrawing, .trimDrawing:
            project.drawings.sort { $0.start < $1.start }
        case .moveEffect, .trimEffect:
            project.sortVideoEffects()
        case .moveMarker:
            project.sortMarkers()
        }
        // V1 のトリム・並べ替えに合わせて、字幕・テキスト・モザイクなどを同じ元素材の位置へ動かす(同じ 1 回の履歴)
        if let layout = interaction.clipLayout {
            interaction.clipLayout = nil
            project.rippleTimelineItems(from: layout)
        }
        // V1 のクリップを V2 へ持ち上げる(並べ替えと同じ 1 回の履歴)
        if let liftClipID {
            if !interaction.historyRecorded {
                history.record(project)
                interaction.historyRecorded = true
            }
            if let overlayID = project.liftClipToOverlay(id: liftClipID, start: carryStart, lane: carryLane) {
                selection = .overlay(overlayID)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        // 動かして元の位置に戻しただけなら履歴に残さない
        if interaction.historyRecorded {
            interaction.historyRecorded = false
            history.discardLastIfUnchanged(project)
        }
        interaction.snapTargets = []
        interaction.lastSnapTarget = nil
        interaction.snapPrimed = false
        interaction.atTrimLimit = false
        if snapGuideTime != nil {
            snapGuideTime = nil
        }
        withAnimation(.easeOut(duration: 0.18)) {
            frozenLanes = nil
            carryingOverlayID = nil
            carryOffsetY = 0
        }
        player.endInteraction()
    }

    /// 途中の移動・トリムを元に戻して編集を終える(ピンチが始まったとき)。同じ指のドラッグが続いても編集は始めない
    private func cancelEdit() {
        guard let edit = interaction.edit else { return }
        if case .reorder = edit {
            if let clips = interaction.editStartClips, clips.map(\.id) != project.clips.map(\.id) {
                project.clips = clips
            }
        } else {
            applyEdit(translation: 0)
        }
        // 取り消したときは V1・V2 のあいだ・段のあいだで移さない
        interaction.clipToOverlay = false
        interaction.overlayToMain = false
        interaction.carryLane = nil
        finishEdit()
        interaction.editDeclined = true
    }

    /// 進行中の編集に指の移動量を適用する
    private func applyEdit(translation: CGFloat) {
        switch interaction.edit {
        case .trimClip?:
            applyClipTrim(translation: translation)
        case .trimSubtitle?, .moveSubtitle?:
            applySubtitleEdit(translation: translation)
        case .moveOverlay?, .trimOverlay?:
            applyOverlayEdit(translation: translation)
        case .moveNarration?, .trimNarration?:
            applyNarrationEdit(translation: translation)
        case .moveText?, .trimText?:
            applyTextEdit(translation: translation)
        case .moveDrawing?, .trimDrawing?:
            applyDrawingEdit(translation: translation)
        case .moveEffect?, .trimEffect?:
            applyEffectEdit(translation: translation)
        case .moveMarker?:
            applyMarkerEdit(translation: translation)
        case .reorder?, nil:
            break
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
                    guard shouldBeginEdit(value), let i = project.index(of: clipID) else { return }
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
        // 動かしている端の元素材の秒(プレビューに重ねるコマの位置)
        let edgeSeconds: Double
        if movesStart {
            let upper = max(0, originalEnd - minimumLength)
            let proposed = originalStart + signedDelta
            let newStart = min(max(0, proposed), upper)
            edgeSeconds = newStart
            noteTrimLimit(abs(newStart - proposed) > 0.0001)
            if abs(newStart - clip.startTime) > 0.0001 {
                recordEditHistory()
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
            edgeSeconds = newEnd
            noteTrimLimit(abs(newEnd - proposed) > 0.0001)
            if abs(newEnd - clip.endTime) > 0.0001 {
                recordEditHistory()
                project.clips[i].endTime = newEnd
            }
            if leading {
                if leftTrimClipID != id { leftTrimClipID = id }
                leftTrimShiftSeconds = (originalEnd - newEnd) / speed
            }
        }
        // 共有プレイヤーはシークせず(currentTime がタイムラインの原点)、端のコマだけプレビューに重ねる。
        // startTime / endTime は逆再生でも元素材上の秒なので、元の url のその秒のコマでよい
        if !clip.isStill {
            timeline.requestTrimPreview(url: clip.url, sourceSeconds: edgeSeconds)
        }
    }

    // MARK: - クリップの並べ替え(長押し → ドラッグ)

    private func reorderGesture(clipID: UUID, width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineView.carrySpace)))
            .updating($editGestureActive) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if interaction.edit == nil {
                    // ゆっくりスクロールしている指(長押しの許容距離の中で動いた)では並べ替えを始めない。
                    // ピンチで取り消した(editDeclined)あとも、同じ指のドラッグで持ち上げ直さない
                    guard interaction.scrollStartTime == nil, interaction.verticalScroll == nil,
                          !interaction.editDeclined else { return }
                    beginReorder(clipID: clipID)
                }
                guard case let .reorder(id)? = interaction.edit, id == clipID else { return }
                // 指を V1 より上へ上げたら持ち上げて、指の時刻・指のある段に置く(V1 へ戻すと並べ替えに戻る)
                if let drag {
                    updateClipCarry(clipID: clipID, drag: drag, width: width)
                }
                if !liftingClip {
                    reorderTranslation = drag?.translation.width ?? 0
                    updateReorder()
                    updateReorderAutoScroll(width: width)
                }
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    private func beginReorder(clipID: UUID) {
        guard project.index(of: clipID) != nil else { return }
        beginEdit(.reorder(id: clipID), snaps: false)
        interaction.editStartClips = project.clips
        interaction.carryPressTime = scrubTime ?? player.currentTime
        // 複数選択中に選んだクリップを持ち上げたら、選んだクリップをひとかたまりにして一緒に動かす
        var group: [UUID] = []
        if timeline.isMultiSelecting {
            if !timeline.multiSelectedClipIDs.contains(clipID) {
                timeline.multiSelectedClipIDs.insert(clipID)
            }
            let ids = timeline.multiSelectedClipIDs
            if ids.count > 1 {
                // 離れていたクリップを寄せるときだけ並びが変わる(履歴を取る)
                let positions = project.clips.indices.filter { ids.contains(project.clips[$0].id) }
                if let first = positions.first, let last = positions.last, last - first + 1 != positions.count {
                    recordEditHistory()
                }
                project.gatherClips(ids: ids)
                group = project.clips.map { $0.id }.filter { ids.contains($0) }
            }
        }
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        let ranges = clipRanges()
        let anchorID: UUID = group.first ?? clipID
        let anchorIndex: Int = project.index(of: anchorID) ?? 0
        reorderAnchorX = anchorIndex < ranges.count ? CGFloat(ranges[anchorIndex].start) * pps : 0
        // 持ち上げたクリップのタイルが今の位置に来るようにタイルの並びを置く
        reorderRowX = reorderAnchorX - CGFloat(anchorIndex) * (TimelineMetrics.tileWidth + TimelineMetrics.clipGap)
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

    /// 並べ替え中のタイルの並び: 番号 i のタイルの左端(タイムライン原点からの pt)
    private func reorderSlotX(_ i: Int) -> CGFloat {
        reorderRowX + CGFloat(i) * (TimelineMetrics.tileWidth + TimelineMetrics.clipGap)
    }

    /// 複数のクリップのかたまりを動かす: かたまりの中心が隣のタイルの中点を越えたら、そのクリップを反対側へ回す
    private func updateGroupReorder() {
        let ids: Set<UUID> = Set(reorderGroupIDs)
        let step = TimelineMetrics.tileWidth + TimelineMetrics.clipGap
        var iterations = 0
        while iterations < project.clips.count {
            iterations += 1
            let clips = project.clips
            guard let lo = clips.firstIndex(where: { ids.contains($0.id) }),
                  let hi = clips.lastIndex(where: { ids.contains($0.id) }) else { return }
            let center = reorderAnchorX + reorderTranslation + CGFloat(hi - lo + 1) * step / 2
            if hi + 1 < clips.count, center > reorderSlotX(hi + 1) + step / 2 {
                recordEditHistory()
                withAnimation(.easeInOut(duration: 0.18)) {
                    let moved = project.clips.remove(at: hi + 1)
                    project.clips.insert(moved, at: lo)
                }
                UISelectionFeedbackGenerator().selectionChanged()
                continue
            }
            if lo > 0, center < reorderSlotX(lo - 1) + step / 2 {
                recordEditHistory()
                withAnimation(.easeInOut(duration: 0.18)) {
                    let moved = project.clips.remove(at: lo - 1)
                    project.clips.insert(moved, at: hi)
                }
                UISelectionFeedbackGenerator().selectionChanged()
                continue
            }
            break
        }
    }

    /// 持ち上げたクリップの中心が隣のタイルの中点を越えたら入れ替える
    private func updateReorder() {
        if !reorderGroupIDs.isEmpty {
            updateGroupReorder()
            return
        }
        guard let id = reorderClipID else { return }
        let step = TimelineMetrics.tileWidth + TimelineMetrics.clipGap
        var iterations = 0
        while iterations < project.clips.count {
            iterations += 1
            guard let i = project.index(of: id) else { return }
            let center = reorderAnchorX + reorderTranslation + step / 2
            if i + 1 < project.clips.count, center > reorderSlotX(i + 1) + step / 2 {
                recordEditHistory()
                withAnimation(.easeInOut(duration: 0.18)) {
                    project.clips.swapAt(i, i + 1)
                }
                UISelectionFeedbackGenerator().selectionChanged()
                continue
            }
            if i > 0, center < reorderSlotX(i - 1) + step / 2 {
                recordEditHistory()
                withAnimation(.easeInOut(duration: 0.18)) {
                    project.clips.swapAt(i, i - 1)
                }
                UISelectionFeedbackGenerator().selectionChanged()
                continue
            }
            break
        }
    }

    /// 持ち上げたクリップが画面の端に近づいたら、その方向へタイムラインを流す(遠くまで運べるように)。
    /// 流れた分だけ reorderAnchorX もずらし、持ち上げたクリップは指の下に留める
    private func updateReorderAutoScroll(width: CGFloat) {
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        let step = TimelineMetrics.tileWidth + TimelineMetrics.clipGap
        let originX = width / 2 - CGFloat(scrubTime ?? player.currentTime) * pps
        let left = originX + reorderAnchorX + reorderTranslation
        let right = left + CGFloat(max(1, reorderGroupIDs.count)) * step
        let margin = TimelineMetrics.reorderScrollMargin
        var factor: CGFloat = 0
        if left < margin {
            factor = -min(1, (margin - left) / margin)
        } else if right > width - margin {
            factor = min(1, (right - (width - margin)) / margin)
        }
        interaction.reorderScrollFactor = factor
        if factor != 0, reorderScrollTask == nil {
            startReorderAutoScroll()
        }
    }

    private func startReorderAutoScroll() {
        // タイルの並びの端が画面の中央に来るところまでスクロールできる
        let pps = max(timeline.pointsPerSecond, 0.0001)
        let lower = min(0, Double(reorderSlotX(0)) / pps)
        let upper = max(timelineDuration(), Double(reorderSlotX(project.clips.count)) / pps)
        reorderScrollTask = Task { @MainActor in
            var last = CACurrentMediaTime()
            // 取り消されたときは return で抜ける(下の reorderScrollTask = nil を通らない。
            // finishEdit が取り消したあとに始めた次の並べ替えのタスクを消さないため)
            while true {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Task.isCancelled { return }
                guard case .reorder? = interaction.edit, interaction.reorderScrollFactor != 0 else { break }
                let now = CACurrentMediaTime()
                let dt = min(max(now - last, 0.001), 0.05)
                last = now
                let current = scrubTime ?? player.currentTime
                let points = Double(interaction.reorderScrollFactor) * TimelineMetrics.reorderScrollPointsPerSecond * dt
                let next = min(max(current + points / pps, lower), upper)
                let moved = next - current
                // 端まで来たら止める
                guard abs(moved) > 0.000001 else { break }
                scrubTime = next
                reorderAnchorX += CGFloat(moved * pps)
                updateReorder()
            }
            reorderScrollTask = nil
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
                    guard shouldBeginEdit(value), let cue = project.subtitles.first(where: { $0.id == id }) else { return }
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
                    guard shouldBeginEdit(value), let cue = project.subtitles.first(where: { $0.id == id }) else { return }
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
                    recordEditHistory()
                    project.subtitles[i].start = newStart
                }
            } else {
                let upper = max(timelineDuration(), originalEnd)
                let proposed = originalEnd + snappedDelta(delta, edges: [originalEnd])
                let newEnd = max(min(proposed, upper), originalStart + minimumLength)
                noteTrimLimit(abs(newEnd - proposed) > 0.0001)
                if abs(project.subtitles[i].end - newEnd) > 0.0001 {
                    recordEditHistory()
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
                recordEditHistory()
                project.subtitles[i].start = newStart
                project.subtitles[i].end = newStart + length
            }
        default:
            break
        }
    }

    // MARK: - 重ね合わせの移動・長さ変更

    private func overlayMoveGesture(id: UUID, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineView.carrySpace))
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard shouldBeginEdit(value, allowVertical: true),
                          let overlay = project.overlays.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveOverlay(id: id, originalStart: overlay.start), snapExcluding: id)
                    interaction.editStartOverlayLanes = frozenLanes?.overlayLanes
                    interaction.carryLane = frozenLanes?.overlayLanes[id]
                }
                applyOverlayEdit(translation: value.translation.width)
                updateOverlayCarry(id: id, value: value, width: width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    /// 選んでいないオーバーレイを長押しでつかみ、そのまま左右(時間)・上下(段、V2 より下なら V1 へ)に動かす。
    /// 途中で選択を変えると上の including が切り替わってジェスチャーが切れるので、選ぶのは離したとき
    private func overlayLiftGesture(id: UUID, width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineView.carrySpace)))
            .updating($editGestureActive) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if interaction.edit == nil {
                    guard interaction.scrollStartTime == nil, interaction.verticalScroll == nil,
                          !interaction.editDeclined,
                          let overlay = project.overlays.first(where: { $0.id == id }) else { return }
                    beginEdit(.moveOverlay(id: id, originalStart: overlay.start), snapExcluding: id)
                    interaction.editStartOverlayLanes = frozenLanes?.overlayLanes
                    interaction.carryLane = frozenLanes?.overlayLanes[id]
                    carryingOverlayID = id
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                guard case let .moveOverlay(editID, _)? = interaction.edit, editID == id, let drag else { return }
                applyOverlayEdit(translation: drag.translation.width)
                updateOverlayCarry(id: id, value: drag, width: width)
            }
            .onEnded { _ in
                var grabbed = false
                if case let .moveOverlay(editID, _)? = interaction.edit, editID == id { grabbed = true }
                let toMain = interaction.overlayToMain
                finishEdit()
                // V1 へ入れたときは dropOverlayToMain が入れたクリップを選ぶ
                if grabbed, !toMain, project.overlays.contains(where: { $0.id == id }) {
                    selection = .overlay(id)
                }
            }
    }

    private func overlayTrimGesture(id: UUID, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($editGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if interaction.edit == nil {
                    guard shouldBeginEdit(value), let overlay = project.overlays.first(where: { $0.id == id }) else { return }
                    beginEdit(.trimOverlay(id: id, leading: leading, original: overlay), snapExcluding: id)
                }
                applyOverlayEdit(translation: value.translation.width)
            }
            .onEnded { _ in
                finishEdit()
            }
    }

    // MARK: - 段を移すドラッグ(Premiere Rush のように、つかんだものを指に付けて動かし、離した行へ置く)

    /// 段を移すドラッグの指の位置を測る座標(タイムライン全体)
    static let carrySpace = "timelineCarry"

    /// 今の行の並び(ドラッグ中は固定したもの)
    private func carryRows() -> [TimelineTrackKind] {
        frozenLanes?.rows ?? TimelineMetrics.visibleTracks(for: project.snapshot())
    }

    /// V1 の行の上端の y(トラック行の座標。縦スクロール前)
    private func videoRowY(_ rows: [TimelineTrackKind]) -> CGFloat {
        TimelineView.rowPlacements(rows).first(where: { p in
            if case .video = p.kind { return true }
            return false
        })?.y ?? 0
    }

    /// 指の位置(carrySpace の座標)を、時刻(秒)とトラック行の y(縦スクロール前)に直す
    /// playhead: 指を置いたときの再生位置で測る(nil = 今の再生位置)
    private func carryPoint(_ location: CGPoint, width: CGFloat, playhead: Double? = nil) -> (time: Double, rowY: CGFloat) {
        let pps = CGFloat(max(timeline.pointsPerSecond, 0.0001))
        let originX = width / 2 - CGFloat(playhead ?? scrubTime ?? player.currentTime) * pps
        let rows = carryRows()
        let viewportH = TimelineMetrics.rowsViewportHeight(rows)
        let maxOffset = max(0, TimelineMetrics.rowsHeight(rows) - viewportH)
        let vOffset = min(max(0, verticalOffset), maxOffset)
        let rowsTop: CGFloat = TimelineMetrics.topPadding + TimelineMetrics.rulerHeight + TimelineMetrics.trackSpacing
        return (Double((location.x - originX) / pps), location.y - rowsTop + vOffset)
    }

    /// 指のある行から置き場所を決める。V1 の行(とその下)なら V1(lane = nil)、オーバーレイの行ならその段、
    /// オーバーレイの行より上なら新しい段(いちばん上の段の上)。V1 との間の行(モザイクなど)は V2。
    /// 決めた段に時間の重なるオーバーレイがあれば、空いている上の段へずらす。y は印の上端(トラック行の座標)
    private func carryTarget(rowY: CGFloat, start: Double, duration: Double,
                             excluding excluded: UUID?, lanes: [UUID: Int]) -> (lane: Int?, y: CGFloat) {
        let rows = carryRows()
        let videoY = videoRowY(rows)
        if rowY >= videoY - TimelineMetrics.trackSpacing / 2 { return (nil, videoY) }
        let step = TimelineMetrics.overlayHeight + TimelineMetrics.textLaneGap
        let laneCount = TimelineMetrics.laneCount(lanes)
        let overlayY: CGFloat? = laneCount > 0 ? TimelineView.rowPlacements(rows).first(where: { p in
            if case .overlay = p.kind { return true }
            return false
        })?.y : nil
        var lane = 0
        if let overlayY {
            if rowY < overlayY {
                lane = laneCount
            } else {
                let fromTop = Int(((rowY - overlayY) / step).rounded(.down))
                lane = min(max(0, laneCount - 1 - fromTop), laneCount - 1)
            }
        }
        let end = start + duration
        func occupied(_ k: Int) -> Bool {
            project.overlays.contains { o in
                o.id != excluded && lanes[o.id] == k && o.start < end - 0.0005 && start < o.end - 0.0005
            }
        }
        while occupied(lane) {
            lane += 1
        }
        let y: CGFloat
        if let overlayY {
            y = overlayY + CGFloat(laneCount - 1 - lane) * step
        } else {
            y = videoY - TimelineMetrics.trackSpacing - TimelineMetrics.overlayHeight - CGFloat(lane) * step
        }
        return (lane, y)
    }

    /// V1 のいちばん近い切れ目の時刻(オーバーレイを V1 に入れる場所。moveOverlayToMain と同じ選び方)
    private func mainBoundary(near time: Double) -> Double {
        var best = 0.0
        for t in clipRanges().map(\.end) where abs(t - time) < abs(best - time) {
            best = t
        }
        return best
    }

    /// オーバーレイを動かしている指: バーを指に付けて上下に動かし、離したときの置き場所(段 / V1)の印を出す
    private func updateOverlayCarry(id: UUID, value: DragGesture.Value, width: CGFloat) {
        guard let original = interaction.editStartOverlayLanes,
              let overlay = project.overlays.first(where: { $0.id == id }) else { return }
        if carryingOverlayID != id {
            carryingOverlayID = id
        }
        carryOffsetY = value.translation.height
        let startLane = original[id] ?? 0
        let point = carryPoint(value.location, width: width)
        let target = carryTarget(rowY: point.rowY, start: overlay.start, duration: overlay.duration,
                                 excluding: id, lanes: original)
        var slot: TimelineCarrySlot? = nil
        var hint: String? = nil
        var lane: Int? = startLane
        if let k = target.lane {
            lane = k
            if k != startLane {
                slot = TimelineCarrySlot(isMain: false, y: target.y, start: overlay.start,
                                         duration: overlay.duration, label: "V\(k + 2)")
                hint = String(localized: "離すと V\(k + 2) に移します")
            }
        } else if overlay.isAnimatedImage {
            hint = String(localized: "動く画像は V1 に入れられません")
        } else {
            lane = nil
            slot = TimelineCarrySlot(isMain: true, y: target.y, start: mainBoundary(near: overlay.start), duration: 0)
            hint = String(localized: "離すと V1 に入れます")
        }
        let toMain = slot?.isMain == true
        if interaction.carryLane != lane || interaction.overlayToMain != toMain {
            interaction.carryLane = lane
            interaction.overlayToMain = toMain
            UISelectionFeedbackGenerator().selectionChanged()
        }
        if slot != carrySlot {
            carrySlot = slot
        }
        if hint != trackDropHint {
            withAnimation(.easeOut(duration: 0.12)) {
                trackDropHint = hint
            }
        }
    }

    /// 並べ替え中の指が V1 より上へ出たら持ち上げる(並びを元に戻し、クリップの影を指の時刻・指のある段に出す)。
    /// V1 の行へ戻したら持ち上げをやめて並べ替えに戻る
    private func updateClipCarry(clipID: UUID, drag: DragGesture.Value, width: CGFloat) {
        let startClips = interaction.editStartClips ?? project.clips
        guard reorderGroupIDs.isEmpty,
              EditorProject.canLiftClipToOverlay(id: clipID, in: startClips),
              let clip = startClips.first(where: { $0.id == clipID }) else { return }
        let point = carryPoint(drag.location, width: width)
        let videoY = videoRowY(carryRows())
        if !liftingClip {
            guard point.rowY < videoY - 8 else { return }
            interaction.reorderScrollFactor = 0
            withAnimation(.easeOut(duration: 0.15)) {
                if project.clips.map(\.id) != startClips.map(\.id) {
                    project.clips = startClips
                }
                reorderTranslation = 0
            }
            liftingClip = true
            interaction.clipToOverlay = true
            interaction.carryLane = nil
            // 指がクリップのどこにあったか(元の並びの時刻で)。影はその位置を指に付けて動かす
            let ranges = clipRanges()
            let index = startClips.firstIndex(where: { $0.id == clipID }) ?? 0
            let clipStart = index < ranges.count ? ranges[index].start : 0
            let grabTime = carryPoint(drag.startLocation, width: width, playhead: interaction.carryPressTime).time
            interaction.carryGrabOffset = min(max(0, grabTime - clipStart), clip.outputDuration)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if point.rowY > videoY + 8 {
            liftingClip = false
            interaction.clipToOverlay = false
            interaction.carryLane = nil
            interaction.carryStart = nil
            carrySlot = nil
            withAnimation(.easeOut(duration: 0.12)) {
                trackDropHint = nil
            }
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        let duration = clip.outputDuration
        let start = max(0, point.time - interaction.carryGrabOffset)
        let lanes = frozenLanes?.overlayLanes ?? TimelineMetrics.overlayLanes(project.overlays)
        // V1 のすぐ上(持ち上げ始めの境目)は V2 として扱う
        let target = carryTarget(rowY: min(point.rowY, videoY - TimelineMetrics.trackSpacing),
                                 start: start, duration: duration, excluding: nil, lanes: lanes)
        let lane = target.lane ?? 0
        if interaction.carryLane != lane {
            if interaction.carryLane != nil {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            interaction.carryLane = lane
            withAnimation(.easeOut(duration: 0.12)) {
                trackDropHint = String(localized: "離すと V\(lane + 2) に重ねます")
            }
        }
        interaction.carryStart = start
        carrySlot = TimelineCarrySlot(isMain: false, y: target.y, start: start, duration: duration,
                                      label: "V\(lane + 2)", showsGhost: true, thumbnail: clip.thumbnail)
    }

    /// 置き場所の印: V1 なら切れ目の縦線、段なら点線の枠(V1 から持ち上げたクリップはサムネイル付きの影)
    @ViewBuilder
    private func carrySlotView(_ slot: TimelineCarrySlot, originX: CGFloat, pps: CGFloat) -> some View {
        let x = originX + CGFloat(slot.start) * pps
        if slot.isMain {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: TimelineMetrics.videoHeight + 8)
                .shadow(color: Color.accentColor.opacity(0.6), radius: 4)
                .offset(x: x - 1.5, y: -4)
        } else {
            let w: CGFloat = min(max(CGFloat(slot.duration) * pps, 6), 6000)
            let h: CGFloat = TimelineMetrics.overlayHeight
            let thumbW: CGFloat = min(w, h * 16 / 9)
            ZStack(alignment: .leading) {
                if slot.showsGhost {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(TimelineMetrics.overlayColor.opacity(0.85))
                    if let thumb = slot.thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: thumbW, height: h)
                            .clipped()
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.12))
                }
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                if !slot.label.isEmpty {
                    Text(slot.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(.leading, slot.showsGhost && slot.thumbnail != nil ? thumbW + 4 : 4)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(slot.showsGhost ? 0.4 : 0), radius: 6, y: 3)
            .offset(x: x)
        }
    }

    /// オーバーレイを V1 に入れる(素材を読み直すので少し待つ)。入れられないときは振動で知らせる
    private func dropOverlayToMain(id: UUID) {
        guard let overlay = project.overlays.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            guard let clip = await EditorProject.mainClip(fromOverlay: overlay),
                  project.overlays.contains(where: { $0.id == id }) else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            history.record(project)
            if project.moveOverlayToMain(id: id, clip: clip) {
                selection = .clip(clip.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
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
            // V1 の終わりより後ろへもはみ出せる(後ろは黒の上に映る)。頭は V1 の終わりまで
            let mainEnd = TimelineView.totalEnd(of: clipRanges(), fallback: 0)
            let upperStart = max(0, max(mainEnd, originalStart))
            let moved = snappedDelta(delta, edges: [originalStart, originalStart + length])
            let newStart = min(max(0, originalStart + moved), upperStart)
            if abs(project.overlays[i].start - newStart) > 0.0001 {
                recordEditHistory()
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
                // キーフレームは部品の先頭からの秒なので、切ったぶん前へずらす(元のキーから毎回作り直す)
                updated.keyframes = KeyframeInterpolator.shifted(original.keyframes, removingHead: newStart - original.start)
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
                recordEditHistory()
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
                    guard shouldBeginEdit(value), let clip = project.narration.first(where: { $0.id == id }) else { return }
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
                    guard shouldBeginEdit(value), let clip = project.narration.first(where: { $0.id == id }) else { return }
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
                recordEditHistory()
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
                recordEditHistory()
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
                    guard shouldBeginEdit(value), let clip = project.textClips.first(where: { $0.id == id }) else { return }
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
                    guard shouldBeginEdit(value), let clip = project.textClips.first(where: { $0.id == id }) else { return }
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
                recordEditHistory()
                project.textClips[i].start = newStart
            }
        case let .trimText(id, leading, original)?:
            guard let i = project.textClips.firstIndex(where: { $0.id == id }) else { return }
            var updated = original
            if leading {
                // 左端: 開始を動かし終了は固定。キーフレームは部品の先頭からの秒なので、切ったぶん前へずらす
                // (追尾のモザイクが顔から外れないよう、元のキーから毎回作り直す)
                let upperStart = max(0, original.end - minimumLength)
                let proposed = original.start + snappedDelta(delta, edges: [original.start])
                let newStart = min(max(0, proposed), upperStart)
                noteTrimLimit(abs(newStart - proposed) > 0.0001)
                updated.start = newStart
                updated.duration = max(minimumLength, original.end - newStart)
                updated.keyframes = KeyframeInterpolator.shifted(original.keyframes, removingHead: newStart - original.start)
            } else {
                // 右端: 長さだけ変える
                let upperEnd = max(timelineDuration(), original.end)
                let maxLength = max(minimumLength, upperEnd - original.start)
                let proposed = original.duration + snappedDelta(delta, edges: [original.end])
                updated.duration = min(max(minimumLength, proposed), maxLength)
                noteTrimLimit(abs(updated.duration - proposed) > 0.0001)
            }
            if project.textClips[i] != updated {
                recordEditHistory()
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
                    guard shouldBeginEdit(value), let drawing = project.drawings.first(where: { $0.id == id }) else { return }
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
                    guard shouldBeginEdit(value), let drawing = project.drawings.first(where: { $0.id == id }) else { return }
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
                recordEditHistory()
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
                recordEditHistory()
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
                    guard shouldBeginEdit(value), let marker = project.markers.first(where: { $0.id == id }) else { return }
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
            recordEditHistory()
            project.markers[i].time = newTime
        }
    }
}
