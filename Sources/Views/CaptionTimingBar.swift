import SwiftUI

// =====================================================================
// キャプション 1 件の時刻を、バーのつまみで直す(キャプションを編集の「タイミング」)。
// 前後の時間を横に並べ、このキャプションを色の帯で出す。帯の左右のつまみをドラッグで始まり・終わり、
// 帯の真ん中のドラッグで長さを変えずに前後へ動かす。前後のキャプション(灰色)とは重ならない。
// 前は「開始」「終了」の +/- ボタンと「再生位置にする」で直していて、分かりづらく操作しづらかった。
// つまみは帯の外側に付ける(短いキャプションでも帯の真ん中をつかめるように)。見える範囲は
// キャプションの長さに合わせて拡大する。ドラッグの間はプレビューがその位置に付いてくる(onScrub)。
// =====================================================================

struct CaptionTimingBar: View {
    let cue: SubtitleCue
    /// 前後のキャプション(重ならないようにする。無ければ nil)
    let previousEnd: Double?
    let nextStart: Double?
    /// 作品の長さ(0 なら制限しない)
    let totalDuration: Double
    let playheadTime: Double
    /// 始まり・終わりが変わった
    let onChange: (_ start: Double, _ end: Double) -> Void
    /// このキャプションを流す
    let onPlay: () -> Void
    /// ドラッグの間、動かしている所の時刻(プレビューをそこへ動かす)。done はドラッグの終わり
    var onScrub: (_ time: Double, _ done: Bool) -> Void = { _, _ in }

    /// ドラッグの間は見えている範囲を動かさない(つまみが指から逃げないように)
    @State private var frozenWindow: ClosedRange<Double>?
    /// ドラッグを始めたときの始まり・終わり
    @State private var dragOrigin: (start: Double, end: Double)?
    /// ドラッグの間に最後にプレビューへ送った時刻
    @State private var lastScrub: Double?

    private static let minimumLength: Double = 0.2
    private static let step: Double = 0.05
    private static let barHeight: CGFloat = 54
    private static let handleWidth: CGFloat = 28

    private var window: ClosedRange<Double> {
        if let frozenWindow { return frozenWindow }
        // 帯が見える幅のおよそ半分になるように、前後の余白をキャプションの長さに合わせる(短いほど拡大する)
        let pad = min(max(cue.duration * 0.6, 0.4), 3)
        let lower = max(0, cue.start - pad)
        var upper = cue.end + pad
        if totalDuration > 0 { upper = min(max(upper, cue.end), max(totalDuration, cue.end)) }
        return lower...max(upper, lower + 0.5)
    }

    private var lowerLimit: Double { max(0, previousEnd ?? 0) }
    private var upperLimit: Double {
        var limit = nextStart ?? .greatestFiniteMagnitude
        if totalDuration > 0 { limit = min(limit, max(totalDuration, cue.end)) }
        return limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                // つまみの幅だけ左右を空ける(作品の頭や終わりでもつまみが画面の外に出ない)
                let inset = Self.handleWidth
                let inner = max(1, width - inset * 2)
                let w = window
                let span = max(0.001, w.upperBound - w.lowerBound)
                let x: (Double) -> CGFloat = { t in
                    inset + CGFloat(min(max((t - w.lowerBound) / span, 0), 1)) * inner
                }
                let startX = x(cue.start)
                let endX = x(cue.end)
                ZStack(alignment: .topLeading) {
                    // 下地(見えている前後の時間)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: width, height: Self.barHeight)
                    // 前後のキャプション(重ねられない所)
                    if let previousEnd, previousEnd > w.lowerBound {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: max(0, x(previousEnd)), height: Self.barHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let nextStart, nextStart < w.upperBound {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: max(0, width - x(nextStart)), height: Self.barHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .offset(x: x(nextStart))
                    }
                    // このキャプション(真ん中のドラッグで前後へ動かす)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(12, endX - startX), height: Self.barHeight)
                        .overlay {
                            Text(cue.text.isEmpty ? " " : cue.text)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .padding(.horizontal, 6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .offset(x: startX)
                        .gesture(dragGesture(width: inner, span: span, part: .move))
                    // 始まりのつまみ(帯の左の外側)
                    handle(edge: .leading)
                        .offset(x: startX - Self.handleWidth)
                        .gesture(dragGesture(width: inner, span: span, part: .start))
                    // 終わりのつまみ(帯の右の外側)
                    handle(edge: .trailing)
                        .offset(x: max(startX + 12, endX))
                        .gesture(dragGesture(width: inner, span: span, part: .end))
                    // 再生位置
                    if w.contains(playheadTime) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: Self.barHeight + 8)
                            .offset(x: x(playheadTime) - 1, y: -4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: Self.barHeight)

            HStack {
                Label(subtitleTimeString(cue.start), systemImage: "arrow.right.to.line")
                Spacer()
                Text(String(localized: "長さ \(String(format: "%.1f", cue.duration)) 秒"))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(subtitleTimeString(cue.end), systemImage: "arrow.left.to.line")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .font(.caption.monospacedDigit())

            Button {
                onPlay()
            } label: {
                Label("このキャプションを再生", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)

            Text("帯の左右のつまみで始まりと終わり、帯の真ん中で全体を前後に動かせます。動かしている間は、その位置の映像と音が出ます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private enum Part { case start, end, move }

    private func handle(edge: HorizontalEdge) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white)
            .frame(width: Self.handleWidth, height: Self.barHeight)
            .overlay {
                Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .shadow(color: .black.opacity(0.3), radius: 2)
            .contentShape(Rectangle().inset(by: -8))
    }

    private func dragGesture(width: CGFloat, span: Double, part: Part) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (cue.start, cue.end)
                    frozenWindow = window
                }
                guard let origin = dragOrigin, width > 0 else { return }
                let delta = Double(value.translation.width / width) * span
                var start = origin.start
                var end = origin.end
                switch part {
                case .start:
                    start = snap(origin.start + delta)
                    start = min(max(start, lowerLimit), end - Self.minimumLength)
                case .end:
                    end = snap(origin.end + delta)
                    end = max(min(end, upperLimit), start + Self.minimumLength)
                case .move:
                    let length = origin.end - origin.start
                    start = snap(origin.start + delta)
                    start = min(max(start, lowerLimit), upperLimit - length)
                    end = start + length
                }
                if abs(start - cue.start) > 0.0001 || abs(end - cue.end) > 0.0001 {
                    onChange(start, end)
                    // 終わりのつまみは終わりの所、それ以外は始まりの所の映像と音を出す
                    let time = part == .end ? end : start
                    lastScrub = time
                    onScrub(time, false)
                }
            }
            .onEnded { _ in
                if let lastScrub { onScrub(lastScrub, true) }
                lastScrub = nil
                dragOrigin = nil
                frozenWindow = nil
                EditorHaptics.tap()
            }
    }

    private func snap(_ t: Double) -> Double {
        (t / Self.step).rounded() * Self.step
    }
}

/// 文字のあとにアイコン(終わりの時刻)
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
