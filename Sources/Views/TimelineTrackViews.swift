import SwiftUI
import UIKit
import QuartzCore

// =====================================================================
// タイムラインの部品(寸法・状態・各トラックの見た目)
// =====================================================================

enum TimelineMetrics {
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 6
    static let trackSpacing: CGFloat = 6
    /// 目盛り(上段にマーカーの旗、下段に時刻)
    static let rulerHeight: CGFloat = 26
    /// 重ね合わせ(Bロール / ワイプ / 写真)トラック
    static let overlayHeight: CGFloat = 28
    static let videoHeight: CGFloat = 58
    /// 映像クリップの直下に出す J カット / L カットの音声バー用レーン
    static let splitAudioLaneHeight: CGFloat = 4
    /// テキスト・ステッカートラック
    static let textHeight: CGFloat = 26
    /// 手書きトラック
    static let drawingHeight: CGFloat = 18
    static let subtitleHeight: CGFloat = 28
    static let audioHeight: CGFloat = 28
    /// ナレーショントラック
    static let narrationHeight: CGFloat = 30
    /// 全トラックを並べたときの高さ
    /// (目盛り + 重ね合わせ + 映像 + テキスト + 手書き + 字幕 + BGM + ナレーション = 8 トラック、すき間 7 つ)
    static let totalHeight: CGFloat = topPadding + rulerHeight + overlayHeight + videoHeight + splitAudioLaneHeight
        + textHeight + drawingHeight + subtitleHeight + audioHeight + narrationHeight
        + trackSpacing * 7 + bottomPadding

    /// サムネイル 1 枚の幅(正方形)
    static let tileWidth: CGFloat = 58
    /// クリップ間のすき間
    static let clipGap: CGFloat = 2
    static let handleWidth: CGFloat = 16
    static let subtitleHandleWidth: CGFloat = 12
    /// 画面外でも描画しておく余白
    static let cullMargin: CGFloat = 80
    /// 重なった重ね合わせを 1 段ずらす量(pt)
    static let overlayStackInset: CGFloat = 5
    /// 重ね合わせのずらし段数の上限
    static let overlayMaxStackDepth: Int = 3
    /// クリップ間のトランジションのバッジ(円)の直径
    static let transitionBadgeSize: CGFloat = 20
    /// マーカーの旗の高さ・旗竿の太さ・名前の最大幅
    static let markerFlagHeight: CGFloat = 12
    static let markerPoleWidth: CGFloat = 2
    static let markerLabelMaxWidth: CGFloat = 90
    /// マーカーをタップで拾う許容距離(pt)
    static let markerTapTolerance: CGFloat = 12

    /// トリムハンドルの見た目の幅と、指で掴める幅(外側へ広げる)
    static let handleVisualWidth: CGFloat = 14
    static let handleHitWidth: CGFloat = 44
    /// 選択枠の上下の帯の太さ
    static let selectionBarThickness: CGFloat = 3
    /// スナップする距離(pt)
    static let snapThreshold: CGFloat = 8
    /// 空のトラックをまとめた「+ 追加」行の高さ
    static let addRowHeight: CGFloat = 32
    /// 左端のトラックアイコンの大きさ
    static let trackChipSize: CGFloat = 24
    /// これより行が多いときは縦にスクロールする(映像 + 中身のあるトラック + 追加行)
    static let maxVisibleRows: Int = 5
    /// 最後のクリップの後ろの「+」タイルの幅
    static let addTileWidth: CGFloat = 44
    static let snapGuideColor = Color.yellow

    /// 映像トラック(J/L カットのレーン込み)の高さ
    static var videoRowHeight: CGFloat { videoHeight + splitAudioLaneHeight }

    /// 表示するトラック行(中身のあるトラックだけ + 映像 + 追加行)
    static func visibleTracks(overlayLanes: Int, textLanes: Int, hasDrawings: Bool,
                              hasSubtitles: Bool, hasBGM: Bool, narrationLanes: Int) -> [TimelineTrackKind] {
        var rows: [TimelineTrackKind] = []
        if overlayLanes > 0 { rows.append(.overlay(lanes: overlayLanes)) }
        rows.append(.video)
        if textLanes > 0 { rows.append(.text(lanes: textLanes)) }
        if hasDrawings { rows.append(.drawing) }
        if hasSubtitles { rows.append(.subtitle) }
        if hasBGM { rows.append(.audio) }
        if narrationLanes > 0 { rows.append(.narration(lanes: narrationLanes)) }
        rows.append(.add)
        return rows
    }

    static func visibleTracks(for snapshot: ProjectSnapshot) -> [TimelineTrackKind] {
        visibleTracks(overlayLanes: overlayLaneCount(snapshot.overlays),
                      textLanes: textLaneCount(snapshot.textClips),
                      hasDrawings: !snapshot.drawings.isEmpty,
                      hasSubtitles: !snapshot.subtitles.isEmpty,
                      hasBGM: snapshot.audio.bgmURL != nil,
                      narrationLanes: narrationLaneCount(snapshot.narration))
    }

    /// 行を全部並べたときの高さ(行間込み)
    static func rowsHeight(_ rows: [TimelineTrackKind]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        var sum: CGFloat = 0
        for row in rows {
            sum += row.height
        }
        let gaps = CGFloat(rows.count - 1) * trackSpacing
        return sum + gaps
    }

    /// 画面に見せる行の高さ(maxVisibleRows を超える分はスクロール)
    static func rowsViewportHeight(_ rows: [TimelineTrackKind]) -> CGFloat {
        if rows.count <= maxVisibleRows { return rowsHeight(rows) }
        return rowsHeight(Array(rows.prefix(maxVisibleRows)))
    }

    /// タイムライン全体の高さ(目盛り + 見せる行 + 余白)
    static func height(for rows: [TimelineTrackKind]) -> CGFloat {
        let top: CGFloat = topPadding + rulerHeight + trackSpacing
        return top + rowsViewportHeight(rows) + bottomPadding
    }

    static let background = Color(white: 0.07)
    static let subtitleColor = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let audioColor = Color(red: 0.16, green: 0.58, blue: 0.34)
    static let overlayColor = Color(red: 0.55, green: 0.36, blue: 0.86)
    static let narrationColor = Color(red: 0.93, green: 0.40, blue: 0.26)
    static let splitAudioColor = Color(red: 0.30, green: 0.86, blue: 0.46)
    /// テキスト・ステッカー(ティール)
    static let textColor = Color(red: 0.14, green: 0.64, blue: 0.66)
    /// 手書き
    static let drawingColor = Color(red: 0.86, green: 0.34, blue: 0.56)
    /// マーカー
    static let markerChapterColor = Color(red: 1.0, green: 0.58, blue: 0.16)
    static let markerNoteColor = Color(red: 1.0, green: 0.86, blue: 0.25)
    static let markerBeatColor = Color.white.opacity(0.45)
    /// クリップ内の波形(控えめ)
    static let clipWaveformColor = Color.white.opacity(0.42)
    /// 音声バー(BGM・ナレーション)内の波形
    static let barWaveformColor = Color.white.opacity(0.55)

    static func markerColor(for kind: MarkerKind) -> Color {
        switch kind {
        case .chapter: return markerChapterColor
        case .note: return markerNoteColor
        case .beat: return markerBeatColor
        }
    }

    /// 画面内に見えている部分だけに切り詰めた範囲(見えなければ nil)
    static func visibleSpan(x: CGFloat, width: CGFloat, viewWidth: CGFloat) -> TimelineSpan? {
        guard x.isFinite, width.isFinite, width > 0 else { return nil }
        let left = max(x, -cullMargin)
        let right = min(x + width, viewWidth + cullMargin)
        guard right > left else { return nil }
        return TimelineSpan(x: left, width: right - left)
    }

    /// 端に貼り付くラベルの位置(見えている範囲内のローカル座標)
    static func stickyLabelX(trueX: CGFloat, visibleX: CGFloat, visibleWidth: CGFloat, labelWidth: CGFloat) -> CGFloat {
        let local = max(trueX, 0) - visibleX
        return min(max(0, local), max(0, visibleWidth - labelWidth))
    }

    /// テキストの段と段の間(pt)
    static let textLaneGap: CGFloat = 2

    /// 時間が重なる要素を別の段に振り分ける(開始が早い順に、空いている一番上の段へ)。
    /// spans は (id, 開始, 終了) を元の並び順で渡す(開始が同じなら元の順)
    static func lanes(_ spans: [(id: UUID, start: Double, end: Double)]) -> [UUID: Int] {
        let ordered = spans.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            return a.offset < b.offset
        }
        var laneEnds: [Double] = []
        var result: [UUID: Int] = [:]
        for entry in ordered {
            let span = entry.element
            if let lane = laneEnds.firstIndex(where: { $0 <= span.start + 0.0005 }) {
                laneEnds[lane] = span.end
                result[span.id] = lane
            } else {
                laneEnds.append(span.end)
                result[span.id] = laneEnds.count - 1
            }
        }
        return result
    }

    static func laneCount(_ lanes: [UUID: Int]) -> Int {
        guard !lanes.isEmpty else { return 0 }
        return (lanes.values.max() ?? 0) + 1
    }

    /// 1 段の高さ h を lanes 段重ねた高さ
    static func stackedHeight(_ h: CGFloat, lanes: Int) -> CGFloat {
        let n = CGFloat(max(1, lanes))
        return h * n + textLaneGap * (n - 1)
    }

    static func textLanes(_ clips: [TextClip]) -> [UUID: Int] {
        lanes(clips.map { (id: $0.id, start: $0.start, end: $0.end) })
    }

    static func overlayLanes(_ overlays: [OverlayClip]) -> [UUID: Int] {
        lanes(overlays.map { (id: $0.id, start: $0.start, end: $0.end) })
    }

    static func narrationLanes(_ narration: [NarrationClip]) -> [UUID: Int] {
        lanes(narration.map { (id: $0.id, start: $0.start, end: $0.start + $0.duration) })
    }

    static func textLaneCount(_ clips: [TextClip]) -> Int { laneCount(textLanes(clips)) }
    static func overlayLaneCount(_ overlays: [OverlayClip]) -> Int { laneCount(overlayLanes(overlays)) }
    static func narrationLaneCount(_ narration: [NarrationClip]) -> Int { laneCount(narrationLanes(narration)) }

    /// 段数に応じたテキストトラックの高さ
    static func textTrackHeight(lanes: Int) -> CGFloat {
        stackedHeight(textHeight, lanes: lanes)
    }

    /// 重なりの深さに応じた上側のずらし量
    static func overlayInset(depth: Int) -> CGFloat {
        CGFloat(min(max(depth, 0), overlayMaxStackDepth)) * overlayStackInset
    }
}

struct TimelineSpan {
    let x: CGFloat
    let width: CGFloat
}

/// タイムラインのトラック行の種類(目盛りは別扱い)
enum TimelineTrackKind: Hashable {
    case video, drawing, subtitle, audio, add
    /// 重なる分だけ段を増やすトラック
    case overlay(lanes: Int)
    /// テキスト・ステッカー・モザイク
    case text(lanes: Int)
    case narration(lanes: Int)

    /// 行の見分け(段数が変わっても同じ行として扱う)
    var key: String {
        switch self {
        case .overlay: return "overlay"
        case .video: return "video"
        case .text: return "text"
        case .drawing: return "drawing"
        case .subtitle: return "subtitle"
        case .audio: return "audio"
        case .narration: return "narration"
        case .add: return "add"
        }
    }

    var height: CGFloat {
        switch self {
        case .overlay(let lanes): return TimelineMetrics.stackedHeight(TimelineMetrics.overlayHeight, lanes: lanes)
        case .video: return TimelineMetrics.videoRowHeight
        case .text(let lanes): return TimelineMetrics.textTrackHeight(lanes: lanes)
        case .drawing: return TimelineMetrics.drawingHeight
        case .subtitle: return TimelineMetrics.subtitleHeight
        case .audio: return TimelineMetrics.audioHeight
        case .narration(let lanes): return TimelineMetrics.stackedHeight(TimelineMetrics.narrationHeight, lanes: lanes)
        case .add: return TimelineMetrics.addRowHeight
        }
    }

    /// 左端に出すアイコン(追加行は無し)
    var iconName: String? {
        switch self {
        case .overlay: return "photo.on.rectangle"
        case .video: return "film"
        case .text: return "textformat"
        case .drawing: return "scribble"
        case .subtitle: return "captions.bubble"
        case .audio: return "music.note"
        case .narration: return "mic.fill"
        case .add: return nil
        }
    }
}

/// 出力タイムライン上のクリップの範囲(トランジションの重なりを反映した秒)
struct TimelineClipRange {
    let start: Double
    let end: Double
    var duration: Double { max(0, end - start) }
}

/// 1 回の描画で使う値のまとめ(body で監視対象を読んでから GeometryReader の中へ渡す)
struct TimelineFrameData {
    /// 表示する時刻(スクラブ中はその値)
    let time: Double
    let pps: CGFloat
    /// トランジションの重なりを反映した全体の長さ
    let total: Double
    /// project.clips と同じ順のクリップ範囲
    let ranges: [TimelineClipRange]
    let snapshot: ProjectSnapshot
}

/// 再描画を伴わないジェスチャー管理用の状態
final class TimelineInteraction {
    var scrollStartTime: Double? = nil
    var scrollStartTranslation: CGFloat = 0
    var scrollBlocked: Bool = false
    var lastSeekTime: CFTimeInterval = 0
    var pinchStartPPS: Double? = nil
    var edit: TimelineEditKind? = nil
    /// 編集中にスナップする候補の時刻(編集開始時に 1 回だけ集める)
    var snapTargets: [Double] = []
    /// 今スナップしている時刻(同じ候補で何度も振動させないため)
    var lastSnapTarget: Double? = nil
    /// トリムが限界に達しているか(達した瞬間に 1 回だけ振動させるため)
    var atTrimLimit: Bool = false
    /// スクロールのドラッグが縦方向(トラックの縦スクロール)か。nil ならまだ決めていない
    var verticalScroll: Bool? = nil
    var verticalStartOffset: CGFloat = 0
    var verticalMaxOffset: CGFloat = 0
    var verticalStartTranslation: CGFloat = 0
    /// クリップのトリム開始時の、動かす端のタイムライン上の時刻(スナップ用)
    var trimEdgeTime: Double = 0
    /// 編集開始直後の最初のスナップでは振動させない(隣の端に最初から揃っている場合)
    var snapPrimed: Bool = false
}

enum TimelineEditKind {
    case trimClip(id: UUID, leading: Bool, originalStart: Double, originalEnd: Double)
    case trimSubtitle(id: UUID, leading: Bool, originalStart: Double, originalEnd: Double)
    case moveSubtitle(id: UUID, originalStart: Double, originalEnd: Double)
    case reorder(id: UUID)
    case moveOverlay(id: UUID, originalStart: Double)
    case trimOverlay(id: UUID, leading: Bool, original: OverlayClip)
    case moveNarration(id: UUID, originalStart: Double)
    case trimNarration(id: UUID, leading: Bool, original: NarrationClip)
    case moveText(id: UUID, originalStart: Double)
    case trimText(id: UUID, leading: Bool, original: TextClip)
    case moveDrawing(id: UUID, originalStart: Double)
    case trimDrawing(id: UUID, leading: Bool, original: DrawingClip)
    case moveMarker(id: UUID, originalTime: Double)
}

/// 映像トラック上の 1 クリップの配置
struct TimelineClipItem: Identifiable {
    let id: UUID
    let clip: Clip
    /// 実際の左端(画面座標)
    let screenX: CGFloat
    /// 実際の幅
    let width: CGFloat
    /// 画面内に見えている範囲
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let isLifted: Bool
}

/// クリップ間のトランジションのバッジの配置(id はトランジションを持つ前側のクリップ)
struct TimelineTransitionItem: Identifiable {
    let id: UUID
    let centerX: CGFloat
    let type: TransitionType
}

/// 字幕など、幅を持つ要素の配置
struct TimelineSpanItem: Identifiable {
    let id: UUID
    let text: String
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
    /// 長さ(秒)
    var duration: Double = 0
}

/// 重ね合わせトラック上の 1 要素の配置
struct TimelineOverlayItem: Identifiable {
    let id: UUID
    let overlay: OverlayClip
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
    /// 重なりの深さ(0 = 一番上のレーン)
    let depth: Int
}

/// ナレーショントラック上の 1 要素の配置
struct TimelineNarrationItem: Identifiable {
    let id: UUID
    let clip: NarrationClip
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
}

/// テキスト・ステッカートラック上の 1 要素の配置
struct TimelineTextItem: Identifiable {
    let id: UUID
    let textClip: TextClip
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
}

/// 手書きトラック上の 1 要素の配置
struct TimelineDrawingItem: Identifiable {
    let id: UUID
    let drawing: DrawingClip
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
}

/// 目盛り上のマーカー(メモ・チャプター)の配置
struct TimelineMarkerItem: Identifiable {
    let id: UUID
    let marker: TimelineMarker
    /// マーカーの時刻の画面 x 座標
    let screenX: CGFloat
}

enum TimelineFormat {
    /// 0:05 / 1:30 / 1:02:03
    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 0:05.2 / 1:30.0(10 分の 1 秒まで)
    static func precise(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        let totalSeconds = tenths / 10
        let fraction = tenths % 10
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d.%d", m, s, fraction)
    }

    /// 長さの表示(3.2s / 1:05.0)
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0.0s" }
        let value = max(0, seconds)
        if value < 60 {
            return String(format: "%.1fs", value)
        }
        return precise(value)
    }
}

// MARK: - 波形

/// 素材の一部分の波形を Canvas で描く帯。
/// 波形は TimelineWaveformCache から取り、未読み込みなら非同期に読み込んで差し替える。
struct TimelineWaveformStrip: View {
    let url: URL
    /// 描画する素材上の範囲(秒)
    let sourceStart: Double
    let sourceEnd: Double
    let color: Color
    /// true なら素材をループ再生しているものとして折り返す(BGM)
    var loops: Bool = false
    /// true なら上下対称、false なら下から立ち上がる
    var centered: Bool = false

    @State private var waveform: AudioWaveform? = nil
    @State private var loadedPath: String = ""

    var body: some View {
        let urlPath = url.path
        let current: AudioWaveform? = (loadedPath == urlPath ? waveform : nil)
            ?? TimelineWaveformCache.shared.cached(for: url)
        let start = sourceStart
        let end = sourceEnd
        let looping = loops
        let symmetric = centered
        let fill = color

        Canvas { context, size in
            guard let wf = current, size.width >= 2, size.height >= 1, end > start else { return }
            let count = max(1, min(Int(size.width / 2), 4000))
            let loop = looping ? wf.duration : 0
            let peaks = TimelineWaveformStrip.peaks(wf, from: start, to: end, count: count, loop: loop)
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(count)
            let barWidth = max(1, step - 1)
            var shape = Path()
            for (i, p) in peaks.enumerated() {
                let v = CGFloat(min(max(p, 0), 1))
                let x = CGFloat(i) * step
                let h = max(1, v * size.height)
                let y = symmetric ? (size.height - h) / 2 : size.height - h
                shape.addRect(CGRect(x: x, y: y, width: barWidth, height: h))
            }
            context.fill(shape, with: .color(fill))
        }
        .allowsHitTesting(false)
        .task(id: urlPath) {
            if let hit = TimelineWaveformCache.shared.cached(for: url) {
                waveform = hit
                loadedPath = urlPath
                return
            }
            let loaded = await TimelineWaveformCache.shared.waveform(for: url)
            if Task.isCancelled { return }
            if let loaded {
                waveform = loaded
                loadedPath = urlPath
            }
        }
    }

    /// 表示範囲 [start, end) を count 本にリサンプリング。素材の終端より先は 0。
    /// loop > 0 なら素材をループ再生しているものとして折り返す。
    static func peaks(_ wf: AudioWaveform, from start: Double, to end: Double,
                      count: Int, loop: Double) -> [Float] {
        guard count > 0, start.isFinite, end.isFinite, end > start else { return [] }
        if loop > 0.01, loop.isFinite {
            var result: [Float] = []
            result.reserveCapacity(count)
            let span = (end - start) / Double(count)
            guard span > 0, span.isFinite else { return [] }
            var i = 0
            var guardCount = 0
            while i < count && guardCount < 10_000 {
                guardCount += 1
                let t = max(0, start + Double(i) * span)
                let cycle = (t / loop).rounded(.down)
                let local = max(0, t - cycle * loop)
                let remaining = max(0, loop - local)
                let ratio = remaining / span
                let n: Int
                if ratio.isFinite, ratio < Double(count - i) {
                    n = max(1, Int(ratio.rounded(.up)))
                } else {
                    n = count - i
                }
                result.append(contentsOf: clipped(wf, from: local, to: local + Double(n) * span, count: n))
                i += n
            }
            return result
        }
        return clipped(wf, from: start, to: end, count: count)
    }

    /// 素材の長さを越える部分と負の時刻を 0 で埋めたリサンプリング(常に count 個を返す)
    private static func clipped(_ wf: AudioWaveform, from start: Double, to end: Double, count: Int) -> [Float] {
        guard count > 0, end > start else { return [] }
        let limit = wf.duration > 0 ? wf.duration : Double(wf.peaks.count) / max(wf.samplesPerSecond, 1)
        let from = max(0, start)
        if from >= limit || end <= 0 || from >= end {
            return [Float](repeating: 0, count: count)
        }
        let total = end - start
        // 負の時刻ぶんは先頭を 0 で埋める
        let leading = start < 0 ? Int((Double(count) * (0 - start) / total).rounded(.down)) : 0
        var result = [Float](repeating: 0, count: min(leading, count))
        if end <= limit {
            let n = count - result.count
            result.append(contentsOf: padded(wf.peaks(from: from, to: end, count: n), to: n))
            return result
        }
        let inside = Int((Double(count) * (limit - from) / total).rounded(.down))
        let n = max(0, min(inside, count - result.count))
        result.append(contentsOf: padded(wf.peaks(from: from, to: limit, count: n), to: n))
        if result.count < count {
            result.append(contentsOf: [Float](repeating: 0, count: count - result.count))
        }
        return result
    }

    private static func padded(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if values.count >= count { return Array(values.prefix(count)) }
        return values + [Float](repeating: 0, count: count - values.count)
    }
}

// MARK: - 映像クリップ

struct TimelineClipView: View {
    let clip: Clip
    let screenX: CGFloat
    let fullWidth: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let pointsPerSecond: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let isLifted: Bool

    /// サムネイル・波形の位置計算に使う「平均の速度」。
    /// 速度カーブが有効なときはトリミング後の長さ ÷ 出力の長さ、それ以外は clip.speed
    static func effectiveSpeed(of clip: Clip) -> Double {
        if clip.speedCurve.enabled {
            let out = clip.outputDuration
            guard out > 0.0001, clip.trimmedDuration > 0 else { return max(clip.speed, 0.01) }
            let s = clip.trimmedDuration / out
            return s.isFinite && s > 0.01 ? s : max(clip.speed, 0.01)
        }
        return max(clip.speed, 0.01)
    }

    var body: some View {
        let speed = TimelineClipView.effectiveSpeed(of: clip)
        let pps = max(pointsPerSecond, 0.0001)
        let tileW = TimelineMetrics.tileWidth
        let isStill = clip.isStill
        let isReversed = clip.isReversed && clip.reversedURL != nil
        // 静止画クリップは画像そのものをサムネイルにする(時刻は使わない)
        let tileURL: URL = isStill ? (clip.stillImageURL ?? clip.url) : clip.url
        // 元素材の 0 秒を基準にしたポイント位置(トリムしてもサムネイルがずれない)
        let startPts = CGFloat(clip.startTime / speed) * pps
        let endPts = CGFloat(clip.endTime / speed) * pps
        let localLeft = visibleX - screenX
        let tiles = TimelineClipView.tileIndices(startPts: startPts, endPts: endPts, localLeft: localLeft,
                                                 visibleWidth: visibleWidth, tileWidth: tileW)
        let tileSpan = Double(tileW / pps) * speed
        let badgeX = TimelineMetrics.stickyLabelX(trueX: screenX, visibleX: visibleX,
                                                   visibleWidth: visibleWidth, labelWidth: 60)
        let showsWaveform = clip.hasAudio && !clip.isMuted && !isStill && visibleWidth >= 6
        // 見えている範囲に対応する元素材上の秒
        let waveStart = clip.startTime + Double(localLeft / pps) * speed
        let waveEnd = min(clip.endTime, clip.startTime + Double((localLeft + visibleWidth) / pps) * speed)
        let waveHeight = (height * 0.3).rounded(.down)
        let showsBadges = visibleWidth > 28
        let hasSpeedCurve = clip.speedCurve.enabled
        let hasGeometry = !clip.geometry.isIdentity

        ZStack(alignment: .topLeading) {
            Color(white: 0.2)

            ForEach(tiles, id: \.self) { j in
                let gridCenter = Double((CGFloat(j) * tileW + tileW / 2) / pps) * speed
                // 逆再生は表示上の先頭が元素材の終わりになる(時刻を鏡像にする)
                let sourceCenter = isReversed ? (clip.startTime + clip.endTime - gridCenter) : gridCenter
                TimelineThumbnailTile(url: tileURL,
                                      time: TimelineThumbnailCache.quantizedTime(sourceCenter, tileSpan: tileSpan,
                                                                                 duration: clip.duration),
                                      placeholder: clip.thumbnail,
                                      isImage: isStill)
                    .frame(width: tileW, height: height)
                    .clipped()
                    .offset(x: CGFloat(j) * tileW - startPts - localLeft)
            }

            if showsWaveform {
                TimelineWaveformStrip(url: clip.url,
                                      sourceStart: waveStart,
                                      sourceEnd: waveEnd,
                                      color: TimelineMetrics.clipWaveformColor)
                    .frame(width: visibleWidth, height: waveHeight)
                    .offset(y: height - waveHeight)
            }

            if showsBadges {
                HStack(spacing: 3) {
                    if hasSpeedCurve {
                        TimelineClipBadge(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    } else if abs(clip.speed - 1) > 0.001 {
                        Text(String(format: "%.1fx", clip.speed))
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.6), in: Capsule())
                    }
                    if isReversed {
                        TimelineClipBadge(systemName: "backward.fill")
                    }
                    if hasGeometry {
                        TimelineClipBadge(systemName: "crop")
                    }
                    if isStill {
                        TimelineClipBadge(systemName: "photo.fill")
                    }
                    if clip.isMuted {
                        TimelineClipBadge(systemName: "speaker.slash.fill")
                    }
                }
                .padding(4)
                .offset(x: badgeX)
            }
        }
        .frame(width: visibleWidth, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(isLifted ? 1.06 : 1)
        .shadow(color: Color.black.opacity(isLifted ? 0.6 : 0), radius: isLifted ? 8 : 0, x: 0, y: isLifted ? 4 : 0)
        .opacity(isLifted ? 0.92 : 1)
    }

    /// 見えている範囲に入るサムネイル番号(元素材基準の格子)
    static func tileIndices(startPts: CGFloat, endPts: CGFloat, localLeft: CGFloat,
                            visibleWidth: CGFloat, tileWidth: CGFloat) -> [Int] {
        guard tileWidth > 0, startPts.isFinite, endPts.isFinite, localLeft.isFinite,
              visibleWidth.isFinite, endPts > startPts else { return [] }
        let a = (startPts + localLeft) / tileWidth
        let b = (startPts + localLeft + visibleWidth) / tileWidth
        let c = max(endPts - 0.5, 0) / tileWidth
        guard a.isFinite, b.isFinite, c.isFinite, a < 10_000_000, b < 10_000_000 else { return [] }
        let first = max(0, Int(a.rounded(.down)))
        var last = min(Int(b.rounded(.down)), Int(c.rounded(.down)))
        guard last >= first else { return [] }
        last = min(last, first + 60)
        return Array(first...last)
    }
}

/// クリップの左上に並べる小さな丸いバッジ(アイコン 1 つ)
struct TimelineClipBadge: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 10, height: 10)
            .padding(3)
            .background(Color.black.opacity(0.6), in: Circle())
    }
}

// MARK: - クリップ間のトランジションのバッジ

struct TimelineTransitionBadge: View {
    let type: TransitionType
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black)
        }
        .frame(width: TimelineMetrics.transitionBadgeSize, height: TimelineMetrics.transitionBadgeSize)
        .overlay {
            Circle()
                .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.6), lineWidth: 1.5)
        }
        .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 1)
        .contentShape(Circle())
        .accessibilityLabel("トランジション: \(type.displayName)")
    }
}

// MARK: - J カット / L カットの音声バー(映像クリップの直下のレーン)

struct TimelineSplitAudioLane: View {
    /// 各バーの x と幅(レーン内のローカル座標)
    let bars: [CGRect]

    var body: some View {
        let rects = bars
        Canvas { context, size in
            guard size.height > 0 else { return }
            let inset: CGFloat = size.height >= 3 ? 0.5 : 0
            for bar in rects {
                let rect = CGRect(x: bar.minX, y: inset, width: bar.width, height: max(1, size.height - inset * 2))
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, rect.height / 2)),
                             with: .color(TimelineMetrics.splitAudioColor))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - トリムハンドル

struct TimelineTrimHandle: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
            Capsule()
                .fill(Color.black.opacity(0.55))
                .frame(width: 2.5, height: 12)
        }
        .contentShape(Rectangle())
    }
}

/// トリムハンドルの掴める範囲(幅 44pt)。見た目(約 14pt)は部品側の端に寄せ、外側へ掴める範囲を広げる。
/// leading = true なら部品の左端に付くハンドル(見た目は右寄せ)
struct TimelineTrimHandleHitArea: View {
    let leading: Bool

    var body: some View {
        let visual = TimelineMetrics.handleVisualWidth
        TimelineTrimHandle()
            .frame(width: visual)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leading ? .trailing : .leading)
            .contentShape(Rectangle())
    }
}

/// 選択中の部品の枠(上下の帯で左右のハンドルをつなぐ)と、長さのバッジ
struct TimelineSelectionFrame: View {
    /// 見えている範囲の幅
    let visibleWidth: CGFloat
    let height: CGFloat
    /// 部品の長さ(秒、トリム中は刻々と変わる)
    let duration: Double
    /// バッジの x(見えている範囲内のローカル座標)
    let badgeX: CGFloat

    var body: some View {
        let bar = TimelineMetrics.selectionBarThickness
        let showsBadge = visibleWidth >= 34 && height >= 16
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white)
                .frame(width: max(0, visibleWidth), height: bar)
            Rectangle()
                .fill(Color.white)
                .frame(width: max(0, visibleWidth), height: bar)
                .offset(y: max(0, height - bar))
            if showsBadge {
                Text(TimelineFormat.duration(duration))
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .offset(x: badgeX + 4, y: bar + 1)
            }
        }
        .frame(width: max(0, visibleWidth), height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// トラック左端の小さなアイコン(画面に固定、半透明)
struct TimelineTrackChip: View {
    let systemName: String
    let rowHeight: CGFloat

    var body: some View {
        let size = min(TimelineMetrics.trackChipSize, rowHeight)
        Image(systemName: systemName)
            .font(.system(size: max(8, size * 0.45), weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(0.5)
            .allowsHitTesting(false)
    }
}

/// スクラブ中に再生位置の上に出す時刻の吹き出し
struct TimelineTimeBubble: View {
    let time: Double

    var body: some View {
        Text(TimelineFormat.precise(time))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white, in: Capsule())
            .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// トラック行を縦スクロールできるときの細いつまみ
struct TimelineScrollIndicator: View {
    let offset: CGFloat
    let maxOffset: CGFloat
    let viewportHeight: CGFloat

    var body: some View {
        let contentHeight: CGFloat = viewportHeight + max(0, maxOffset)
        let ratio: CGFloat = contentHeight > 0 ? viewportHeight / contentHeight : 1
        let thumbHeight: CGFloat = max(16, viewportHeight * ratio)
        let travel: CGFloat = max(0, viewportHeight - thumbHeight)
        let progress: CGFloat = maxOffset > 0 ? min(max(0, offset / maxOffset), 1) : 0
        let thumbY: CGFloat = travel * progress
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(height: thumbHeight)
                .offset(y: thumbY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// 最後のクリップの後ろに出す「+」タイル(見た目のみ。タップは呼び出し側の Button)
struct TimelineAddTile: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.12))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .frame(width: TimelineMetrics.addTileWidth, height: height)
        .contentShape(Rectangle())
    }
}

// MARK: - キーフレームのひし形(選択中のテキスト / 重ね合わせのバーの上に描く)

struct TimelineKeyframeDiamonds: View {
    /// 部品の開始からの相対秒
    let times: [Double]
    let pointsPerSecond: CGFloat
    /// バーの実際の左端(画面座標)と、見えている範囲の左端
    let screenX: CGFloat
    let visibleX: CGFloat

    var body: some View {
        let pps = max(pointsPerSecond, 0.0001)
        let left = screenX
        let origin = visibleX
        let values = times
        Canvas { context, size in
            let r: CGFloat = 4
            let cy = size.height / 2
            for t in values {
                guard t.isFinite else { continue }
                let x = left + CGFloat(t) * pps - origin
                guard x.isFinite, x >= -r, x <= size.width + r else { continue }
                var p = Path()
                p.move(to: CGPoint(x: x, y: cy - r))
                p.addLine(to: CGPoint(x: x + r, y: cy))
                p.addLine(to: CGPoint(x: x, y: cy + r))
                p.addLine(to: CGPoint(x: x - r, y: cy))
                p.closeSubpath()
                context.fill(p, with: .color(Color.white))
                context.stroke(p, with: .color(Color.black.opacity(0.7)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 重ね合わせ(Bロール / ワイプ / 写真)

struct TimelineOverlayBar: View {
    let overlay: OverlayClip
    let labelX: CGFloat
    let visibleWidth: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        let thumbW = height
        let showsThumb = visibleWidth - labelX >= thumbW + 4
        // 動画は素材上の開始位置のコマ、写真はそのまま
        let thumbTime = overlay.isImage
            ? 0
            : TimelineThumbnailCache.quantizedTime(overlay.sourceStart, tileSpan: 1, duration: overlay.sourceDuration)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineMetrics.overlayColor)
            HStack(spacing: 4) {
                if showsThumb {
                    TimelineThumbnailTile(url: overlay.url,
                                          time: thumbTime,
                                          placeholder: nil,
                                          isImage: overlay.isImage)
                        .frame(width: thumbW, height: height)
                        .clipped()
                }
                Image(systemName: overlay.isImage ? "photo.fill" : "film.fill")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.leading, showsThumb ? 0 : 6)
                Text(overlay.name.isEmpty ? " " : overlay.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                if overlay.blendMode != nil {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(Color.white)
            .padding(.trailing, 6)
            .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
            .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - ナレーション

struct TimelineNarrationBar: View {
    let clip: NarrationClip
    let screenX: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let pointsPerSecond: CGFloat
    let labelX: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        let pps = max(pointsPerSecond, 0.0001)
        let localLeft = visibleX - screenX
        // 見えている範囲に対応する音声ファイル上の秒
        let waveStart = clip.sourceStart + Double(localLeft / pps)
        let waveEnd = min(clip.sourceEnd, clip.sourceStart + Double((localLeft + visibleWidth) / pps))

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineMetrics.narrationColor)
            if visibleWidth >= 6 {
                TimelineWaveformStrip(url: clip.url,
                                      sourceStart: waveStart,
                                      sourceEnd: waveEnd,
                                      color: TimelineMetrics.barWaveformColor,
                                      centered: true)
                    .frame(width: visibleWidth, height: max(1, height - 6))
            }
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(clip.name.isEmpty ? " " : clip.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .shadow(color: Color.black.opacity(0.5), radius: 1)
            .padding(.horizontal, 6)
            .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
            .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 字幕

struct TimelineSubtitleCapsule: View {
    let text: String
    let labelX: CGFloat
    let visibleWidth: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(TimelineMetrics.subtitleColor)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
                .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - テキスト・ステッカー

struct TimelineTextBar: View {
    let textClip: TextClip
    let labelX: CGFloat
    let visibleWidth: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        let isSticker = textClip.isSticker
        let label = textClip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKeyframes = !textClip.keyframes.isEmpty

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(TimelineMetrics.textColor)
            HStack(spacing: 4) {
                if isSticker {
                    // ステッカーは絵文字そのものを大きく見せる
                    if label.isEmpty {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 11, weight: .bold))
                    } else {
                        Text(label)
                            .font(.system(size: max(10, height - 8)))
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "textformat")
                        .font(.system(size: 9, weight: .bold))
                    Text(label.isEmpty ? "テキスト" : label)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                if textClip.animIn != TextAnimationType.none || textClip.animOut != TextAnimationType.none {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.9)
                }
                if hasKeyframes {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(Color.white)
            .shadow(color: Color.black.opacity(0.35), radius: 1)
            .padding(.horizontal, 5)
            .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
            .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 手書き

struct TimelineDrawingBar: View {
    let drawing: DrawingClip
    let labelX: CGFloat
    let visibleWidth: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        let count = drawing.strokes.count
        let label: String = count > 0 ? "手書き \(count)" : "手書き"
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineMetrics.drawingColor)
            HStack(spacing: 3) {
                Image(systemName: "scribble")
                    .font(.system(size: 9, weight: .bold))
                if visibleWidth - labelX >= 48 {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
            .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - BGM

struct TimelineAudioBar: View {
    let name: String
    let labelX: CGFloat
    let visibleWidth: CGFloat
    let height: CGFloat
    let isSelected: Bool
    /// 波形を描く BGM ファイル(nil なら描かない)
    var waveformURL: URL? = nil
    /// 見えている範囲のタイムライン秒(BGM は 0 秒から全体長までループ)
    var visibleStartTime: Double = 0
    var visibleEndTime: Double = 0

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineMetrics.audioColor)
            if let waveformURL, visibleEndTime > visibleStartTime, visibleWidth >= 6 {
                TimelineWaveformStrip(url: waveformURL,
                                      sourceStart: visibleStartTime,
                                      sourceEnd: visibleEndTime,
                                      color: TimelineMetrics.barWaveformColor,
                                      loops: true,
                                      centered: true)
                    .frame(width: visibleWidth, height: max(1, height - 6))
            }
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .shadow(color: Color.black.opacity(0.5), radius: 1)
            .padding(.horizontal, 6)
            .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
            .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - マーカー(目盛りの上の旗)

/// メモ・チャプターのマーカー。旗竿がマーカーの時刻、右に名前の旗
struct TimelineMarkerFlag: View {
    let marker: TimelineMarker
    let isSelected: Bool

    /// 旗竿を含めた全体の幅(名前の長さに応じて変わる、上限あり)
    static func width(for marker: TimelineMarker) -> CGFloat {
        let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var w: CGFloat = TimelineMetrics.markerPoleWidth + 8 + 10
        if !name.isEmpty {
            let font = UIFont.systemFont(ofSize: 9, weight: .semibold)
            let textW = (name as NSString).size(withAttributes: [.font: font]).width
            let clamped = min(textW.isFinite ? ceil(textW) + 1 : 0, TimelineMetrics.markerLabelMaxWidth)
            w += 3 + clamped
        }
        return w
    }

    var body: some View {
        let kind = marker.kind
        let color = TimelineMetrics.markerColor(for: kind)
        let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let flagH = TimelineMetrics.markerFlagHeight
        let poleW = TimelineMetrics.markerPoleWidth
        let totalW = TimelineMarkerFlag.width(for: marker)
        let rulerH = TimelineMetrics.rulerHeight

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: poleW, height: rulerH)
            HStack(spacing: 3) {
                Image(systemName: kind == .chapter ? "bookmark.fill" : "flag.fill")
                    .font(.system(size: 8, weight: .bold))
                if !name.isEmpty {
                    Text(name)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 4)
            .frame(width: max(0, totalW - poleW), height: flagH, alignment: .leading)
            .background(color, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                           bottomTrailingRadius: 4, topTrailingRadius: 4,
                                                           style: .continuous))
            .offset(x: poleW)
        }
        .frame(width: totalW, height: rulerH, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: totalW, height: flagH)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(kind.displayName) \(name)")
    }
}

/// ビートマーカーの小さな目印(目盛りの下端に並ぶ灰色の点)
struct TimelineBeatTicks: View {
    /// 各ビートの画面 x 座標
    let xs: [CGFloat]
    /// 選択中のビートの x(強調表示)
    let selectedX: CGFloat?

    var body: some View {
        let positions = xs
        let highlighted = selectedX
        Canvas { context, size in
            var path = Path()
            for x in positions where x.isFinite {
                path.addRect(CGRect(x: x - 1, y: size.height - 7, width: 2, height: 7))
            }
            context.fill(path, with: .color(TimelineMetrics.markerBeatColor))
            if let hx = highlighted, hx.isFinite {
                let rect = CGRect(x: hx - 1.5, y: size.height - 11, width: 3, height: 11)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color.white))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 目盛り

struct TimelineRulerView: View {
    /// タイムライン 0 秒の画面 x 座標
    let originX: CGFloat
    let pointsPerSecond: CGFloat
    let totalDuration: Double

    private static let majorSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    static func majorStep(pps: CGFloat) -> Double {
        for s in majorSteps where CGFloat(s) * pps >= 56 {
            return s
        }
        return 3600
    }

    static func minorDivisions(major: Double, pps: CGFloat) -> Int {
        let candidates: [Int]
        switch major {
        case 1, 10, 600: candidates = [10, 5, 2]
        case 2, 120: candidates = [4, 2]
        case 5, 300: candidates = [5]
        case 15, 900: candidates = [3]
        case 30, 1800: candidates = [6, 3]
        default: candidates = [6, 4, 2]
        }
        for d in candidates where CGFloat(major) * pps / CGFloat(d) >= 12 {
            return d
        }
        return 1
    }

    var body: some View {
        let origin = originX
        let pps = max(pointsPerSecond, 0.0001)
        Canvas { context, size in
            let major = TimelineRulerView.majorStep(pps: pps)
            let divisions = TimelineRulerView.minorDivisions(major: major, pps: pps)
            let minor = major / Double(divisions)
            let startT = max(0, Double((0 - origin) / pps) - minor)
            let endT = Double((size.width - origin) / pps) + minor
            guard endT >= 0, minor > 0, startT.isFinite, endT.isFinite else { return }
            var i = Int((startT / minor).rounded(.down))
            let lastI = Int((endT / minor).rounded(.up))
            // 上段はマーカーの旗のために空けておき、時刻は下段に描く
            let labelY = max(size.height / 2, size.height - 7.5)
            var guardCount = 0
            while i <= lastI && guardCount < 2000 {
                guardCount += 1
                if i >= 0 {
                    let t = Double(i) * minor
                    let x = origin + CGFloat(t) * pps
                    if i % divisions == 0 {
                        let label = Text(TimelineFormat.label(t))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                        context.draw(label, at: CGPoint(x: x, y: labelY), anchor: .center)
                    } else {
                        let dot = CGRect(x: x - 1, y: labelY - 1, width: 2, height: 2)
                        context.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.3)))
                    }
                }
                i += 1
            }
        }
    }
}

// MARK: - 再生位置(中央固定の白線)

struct TimelinePlayheadView: View {
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white)
                .frame(width: 8, height: 4)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
        }
        .shadow(color: Color.black.opacity(0.5), radius: 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 複数選択モードでクリップの左上に出すチェック
struct TimelineMultiSelectBadge: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.white : Color.black.opacity(0.45))
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black)
            }
        }
        .frame(width: 18, height: 18)
    }
}
