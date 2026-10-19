import SwiftUI
import UIKit
import QuartzCore

// =====================================================================
// タイムラインの部品(寸法・状態・各トラックの見た目)
// =====================================================================

enum TimelineMetrics {
    static let totalHeight: CGFloat = 200
    static let topPadding: CGFloat = 6
    static let trackSpacing: CGFloat = 10
    static let rulerHeight: CGFloat = 20
    static let videoHeight: CGFloat = 58
    static let subtitleHeight: CGFloat = 30
    static let audioHeight: CGFloat = 28
    /// サムネイル 1 枚の幅(正方形)
    static let tileWidth: CGFloat = 58
    /// クリップ間のすき間
    static let clipGap: CGFloat = 2
    static let handleWidth: CGFloat = 16
    static let subtitleHandleWidth: CGFloat = 12
    /// 画面外でも描画しておく余白
    static let cullMargin: CGFloat = 80

    static let background = Color(white: 0.07)
    static let subtitleColor = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let audioColor = Color(red: 0.16, green: 0.58, blue: 0.34)

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

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineMetrics.audioColor)
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
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
