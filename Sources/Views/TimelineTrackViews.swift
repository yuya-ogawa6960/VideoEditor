import SwiftUI
import UIKit
import QuartzCore

// =====================================================================
// タイムラインの部品(寸法・状態・各トラックの見た目)
// =====================================================================

enum TimelineMetrics {
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 6
    static let trackSpacing: CGFloat = 8
    static let rulerHeight: CGFloat = 20
    /// 重ね合わせ(Bロール / ワイプ / 写真)トラック
    static let overlayHeight: CGFloat = 28
    static let videoHeight: CGFloat = 58
    /// 映像クリップの直下に出す J カット / L カットの音声バー用レーン
    static let splitAudioLaneHeight: CGFloat = 4
    static let subtitleHeight: CGFloat = 28
    static let audioHeight: CGFloat = 28
    /// ナレーショントラック
    static let narrationHeight: CGFloat = 30
    /// 全トラックを並べたときの高さ(目盛り + 重ね合わせ + 映像 + 字幕 + BGM + ナレーション)
    static let totalHeight: CGFloat = topPadding + rulerHeight + overlayHeight + videoHeight + splitAudioLaneHeight
        + subtitleHeight + audioHeight + narrationHeight + trackSpacing * 5 + bottomPadding

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

    static let background = Color(white: 0.07)
    static let subtitleColor = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let audioColor = Color(red: 0.16, green: 0.58, blue: 0.34)
    static let overlayColor = Color(red: 0.55, green: 0.36, blue: 0.86)
    static let narrationColor = Color(red: 0.93, green: 0.40, blue: 0.26)
    static let splitAudioColor = Color(red: 0.30, green: 0.86, blue: 0.46)
    /// クリップ内の波形(控えめ)
    static let clipWaveformColor = Color.white.opacity(0.42)
    /// 音声バー(BGM・ナレーション)内の波形
    static let barWaveformColor = Color.white.opacity(0.55)

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

    /// 重なりの深さに応じた上側のずらし量
    static func overlayInset(depth: Int) -> CGFloat {
        CGFloat(min(max(depth, 0), overlayMaxStackDepth)) * overlayStackInset
    }
}

struct TimelineSpan {
    let x: CGFloat
    let width: CGFloat
}

/// 再描画を伴わないジェスチャー管理用の状態
final class TimelineInteraction {
    var scrollStartTime: Double? = nil
    var scrollStartTranslation: CGFloat = 0
    var scrollBlocked: Bool = false
    var lastSeekTime: CFTimeInterval = 0
    var pinchStartPPS: Double? = nil
    var edit: TimelineEditKind? = nil
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

/// 字幕など、幅を持つ要素の配置
struct TimelineSpanItem: Identifiable {
    let id: UUID
    let text: String
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
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

    var body: some View {
        let speed = max(clip.speed, 0.01)
        let pps = max(pointsPerSecond, 0.0001)
        let tileW = TimelineMetrics.tileWidth
        // 元素材の 0 秒を基準にしたポイント位置(トリムしてもサムネイルがずれない)
        let startPts = CGFloat(clip.startTime / speed) * pps
        let endPts = CGFloat(clip.endTime / speed) * pps
        let localLeft = visibleX - screenX
        let tiles = TimelineClipView.tileIndices(startPts: startPts, endPts: endPts, localLeft: localLeft,
                                                 visibleWidth: visibleWidth, tileWidth: tileW)
        let tileSpan = Double(tileW / pps) * speed
        let badgeX = TimelineMetrics.stickyLabelX(trueX: screenX, visibleX: visibleX,
                                                   visibleWidth: visibleWidth, labelWidth: 60)
        let showsWaveform = clip.hasAudio && !clip.isMuted && visibleWidth >= 6
        // 見えている範囲に対応する元素材上の秒
        let waveStart = clip.startTime + Double(localLeft / pps) * speed
        let waveEnd = min(clip.endTime, clip.startTime + Double((localLeft + visibleWidth) / pps) * speed)
        let waveHeight = (height * 0.3).rounded(.down)

        ZStack(alignment: .topLeading) {
            Color(white: 0.2)

            ForEach(tiles, id: \.self) { j in
                let sourceCenter = Double((CGFloat(j) * tileW + tileW / 2) / pps) * speed
                TimelineThumbnailTile(url: clip.url,
                                      time: TimelineThumbnailCache.quantizedTime(sourceCenter, tileSpan: tileSpan,
                                                                                 duration: clip.duration),
                                      placeholder: clip.thumbnail)
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

            if visibleWidth > 28 {
                HStack(spacing: 3) {
                    if abs(clip.speed - 1) > 0.001 {
                        Text(String(format: "%.1fx", clip.speed))
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.6), in: Capsule())
                    }
                    if clip.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(3)
                            .background(Color.black.opacity(0.6), in: Circle())
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
            let midY = size.height / 2
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
                        context.draw(label, at: CGPoint(x: x, y: midY), anchor: .center)
                    } else {
                        let dot = CGRect(x: x - 1, y: midY - 1, width: 2, height: 2)
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
