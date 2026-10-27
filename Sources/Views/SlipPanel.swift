import SwiftUI
import UIKit
import AVFoundation

// =====================================================================
// スリップ: クリップの長さはそのままで、元の動画のどの部分を使うかをずらす
// (Premiere のスリップツール)。置き換えたあとに「どこを切り取るか」を細かく合わせるのに使う。
//   - 帯をドラッグ: 大きく動かす
//   - スライダー: 細かく動かす
//   - ±1秒 / ±0.1秒 / ±1コマ: さらに細かく
// 始まりと終わりのコマを見本として出し、動かすたびにプレビューもクリップの先頭へ移す。
// =====================================================================

struct EditorSlipPanel: View {
    let project: EditorProject
    @Binding var clip: Clip
    let player: PlayerController

    @State private var startImage: UIImage?
    @State private var endImage: UIImage?
    @State private var reloadTask: Task<Void, Never>?
    @State private var dragStartValue: Double?

    /// 使う長さ(元素材の秒。変えない)
    private var length: Double { max(0.05, clip.endTime - clip.startTime) }
    /// 始まりを動かせる範囲
    private var maxStart: Double { max(0, clip.duration - length) }
    private var frameSeconds: Double { 1.0 / Double(min(max(project.canvas.frameRate, 1), 120)) }

    private var startBinding: Binding<Double> {
        Binding(get: { clip.startTime }, set: { setStart($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // 始まりと終わりのコマ
            HStack(spacing: 10) {
                frameTile(image: startImage, title: String(localized: "始まり"), time: clip.startTime)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                frameTile(image: endImage, title: String(localized: "終わり"), time: clip.endTime)
            }
            .frame(maxWidth: .infinity)

            // 元の動画の帯と、使う部分の窓
            GeometryReader { geo in
                let w = geo.size.width
                let total = max(clip.duration, 0.05)
                let x = CGFloat(clip.startTime / total) * w
                let windowWidth = max(6, CGFloat(length / total) * w)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(BrandStyle.surfaceStrong)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(BrandStyle.gradient)
                        .frame(width: windowWidth)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white, lineWidth: 1.5)
                        )
                        .offset(x: x)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartValue == nil {
                                dragStartValue = clip.startTime
                                player.beginInteraction()
                            }
                            let seconds = Double(value.translation.width / max(w, 1)) * total
                            setStart((dragStartValue ?? clip.startTime) + seconds)
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                            player.endInteraction()
                            seekToClipStart()
                        }
                )
            }
            .frame(height: 28)

            EditorSliderRow(title: String(localized: "使う部分の始まり"),
                            value: startBinding,
                            range: 0...max(0.001, maxStart),
                            display: clipFXSeconds(clip.startTime))
                .disabled(maxStart <= 0.001)
                .opacity(maxStart <= 0.001 ? 0.4 : 1)

            HStack(spacing: 6) {
                nudge("-1s", -1)
                nudge("-0.1s", -0.1)
                nudge(String(localized: "-1コマ"), -frameSeconds)
                Spacer(minLength: 0)
                nudge(String(localized: "+1コマ"), frameSeconds)
                nudge("+0.1s", 0.1)
                nudge("+1s", 1)
            }

            HStack {
                Text(String(localized: "長さ \(clipFXSeconds(length))(変わりません)・元の動画 \(clipFXSeconds(clip.duration))"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if maxStart <= 0.001 {
                    Text("元の動画をすべて使っているので、ずらせません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            seekToClipStart()
            scheduleReload()
        }
        .onChange(of: clip.startTime) { _, _ in scheduleReload() }
        .onChange(of: clip.url) { _, _ in scheduleReload() }
    }

    private func frameTile(image: UIImage?, title: String, time: Double) -> some View {
        VStack(spacing: 4) {
            ZStack {
                BrandStyle.surfaceStrong
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 112, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous))
            Text("\(title) \(clipFXSeconds(time))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func nudge(_ title: String, _ delta: Double) -> some View {
        Button {
            EditorHaptics.tap()
            setStart(clip.startTime + delta)
            seekToClipStart()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(BrandStyle.surfaceStrong, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 始まりを動かす(長さは変えない)
    private func setStart(_ value: Double) {
        let start = min(max(0, value), maxStart)
        clip.startTime = start
        clip.endTime = start + length
    }

    /// プレビューをこのクリップの先頭に移す(始まりのコマが見えるように)
    private func seekToClipStart() {
        guard let index = project.index(of: clip.id) else { return }
        let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
        guard index < layout.count else { return }
        player.pause()
        player.seek(to: layout[index].start + 0.02)
    }

    /// 始まりと終わりのコマを取り直す(連続で動かしたときは最後の 1 回だけ)
    private func scheduleReload() {
        reloadTask?.cancel()
        let snapshot = clip
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            async let a = DocumentaryPreviewSource.frame(clip: snapshot, sourceTime: snapshot.startTime)
            async let b = DocumentaryPreviewSource.frame(clip: snapshot, sourceTime: max(0, snapshot.endTime - 0.05))
            let (first, last) = await (a, b)
            guard !Task.isCancelled else { return }
            startImage = first
            endImage = last
        }
    }
}
