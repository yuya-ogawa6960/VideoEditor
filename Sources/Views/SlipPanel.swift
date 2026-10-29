import SwiftUI
import UIKit
import AVFoundation

// =====================================================================
// スリップ: クリップの長さはそのままで、元の動画のどの部分を使うかをずらす
// (Premiere のスリップツール)。置き換えたあとに「どこから使うか」を合わせるのに使う。
//   - 大きな「始まりのコマ」: 動かすたびに更新する。横になぞると細かく動く(幅いっぱい = クリップの長さぶん)
//   - 元の動画の帯(コマの一覧)と、使う部分の窓: なぞると大きく動く。タップでそこを始まりにする
//   - ±1秒 / ±0.1秒 / ±1コマ: さらに細かく
//   - 「この部分を再生」: クリップの先頭から再生して確かめる
// 動かし終えるたびにプレビューもクリップの先頭へ移す。
// =====================================================================

struct EditorSlipPanel: View {
    let project: EditorProject
    @Binding var clip: Clip
    let player: PlayerController

    @State private var startImage: UIImage?
    @State private var endImage: UIImage?
    /// 元の動画の帯のコマ(読み込み中は nil)
    @State private var strip: [UIImage?] = []
    @State private var stripURL: URL?
    @State private var stripTask: Task<Void, Never>?
    @State private var reloadTask: Task<Void, Never>?
    @State private var dragStartValue: Double?
    @State private var frameSource = SlipFrameSource()

    /// 使う長さ(元素材の秒。変えない)
    private var length: Double { max(0.05, clip.endTime - clip.startTime) }
    /// 始まりを動かせる範囲
    private var maxStart: Double { max(0, clip.duration - length) }
    private var frameSeconds: Double { 1.0 / Double(min(max(project.canvas.frameRate, 1), 120)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            startFrameView
                .frame(height: 132)

            stripView
                .frame(height: 52)

            HStack(spacing: 6) {
                nudge("-1s", -1)
                nudge("-0.1s", -0.1)
                nudge(String(localized: "-1コマ"), -frameSeconds)
                Spacer(minLength: 0)
                nudge(String(localized: "+1コマ"), frameSeconds)
                nudge("+0.1s", 0.1)
                nudge("+1s", 1)
            }

            HStack(spacing: 10) {
                Button {
                    EditorHaptics.tap()
                    playFromClipStart()
                } label: {
                    Label("この部分を再生", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(BrandStyle.surfaceStrong, in: Capsule())
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "長さ \(clipFXSeconds(length))(変わりません)・元の動画 \(clipFXSeconds(clip.duration))"))
                    if maxStart <= 0.001 {
                        Text("元の動画をすべて使っているので、ずらせません")
                    } else {
                        Text("コマをなぞると細かく、帯をなぞると大きく動きます")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 6)
        .onAppear {
            seekToClipStart()
            scheduleReload()
        }
        .onChange(of: clip.startTime) { _, _ in scheduleReload() }
        .onChange(of: clip.url) { _, _ in
            scheduleReload()
            if !strip.isEmpty { loadStrip(count: strip.count) }
        }
        .onDisappear {
            stripTask?.cancel()
            reloadTask?.cancel()
        }
    }

    // MARK: - 始まりのコマ(大きく)

    private var startFrameView: some View {
        GeometryReader { geo in
            ZStack {
                BrandStyle.surfaceStrong
                if let startImage {
                    Image(uiImage: startImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .bottomLeading) {
                Text("\(String(localized: "始まり")) \(clipFXSeconds(clip.startTime))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                // 終わりのコマは小さく添える
                VStack(spacing: 2) {
                    ZStack {
                        Color.black.opacity(0.4)
                        if let endImage {
                            Image(uiImage: endImage).resizable().scaledToFill()
                        }
                    }
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("\(String(localized: "終わり")) \(clipFXSeconds(clip.endTime))")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(6)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            .contentShape(Rectangle())
            // 横になぞると細かく動く(幅いっぱい = クリップの長さぶん)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartValue == nil {
                            dragStartValue = clip.startTime
                            player.beginInteraction()
                        }
                        let seconds = Double(value.translation.width / max(geo.size.width, 1)) * length
                        setStart((dragStartValue ?? clip.startTime) + seconds)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        player.endInteraction()
                        seekToClipStart()
                    }
            )
            .accessibilityLabel(String(localized: "始まり"))
        }
    }

    // MARK: - 元の動画の帯と、使う部分の窓

    private var stripView: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let total = max(clip.duration, 0.05)
            let x = CGFloat(clip.startTime / total) * w
            let windowWidth = max(8, CGFloat(length / total) * w)
            ZStack(alignment: .leading) {
                // コマの一覧(読み込み中の所は面の色)
                HStack(spacing: 0) {
                    ForEach(strip.indices, id: \.self) { i in
                        ZStack {
                            BrandStyle.surfaceStrong
                            if let image = strip[i] {
                                Image(uiImage: image).resizable().scaledToFill()
                            }
                        }
                        .frame(width: w / CGFloat(max(strip.count, 1)), height: geo.size.height)
                        .clipped()
                    }
                }
                .frame(width: w, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // 使わない部分を暗くする
                Color.black.opacity(0.55)
                    .frame(width: max(0, x))
                Color.black.opacity(0.55)
                    .frame(width: max(0, w - x - windowWidth))
                    .offset(x: x + windowWidth)
                // 使う部分の窓
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(BrandStyle.coral, lineWidth: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white, lineWidth: 1.5)
                            .padding(1)
                    )
                    .frame(width: windowWidth, height: geo.size.height)
                    .offset(x: x)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            // タップした所を始まりにする
            .onTapGesture { location in
                EditorHaptics.tap()
                setStart(Double(location.x / w) * total)
                seekToClipStart()
            }
            // なぞると大きく動く(幅いっぱい = 元の動画の長さぶん)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartValue == nil {
                            dragStartValue = clip.startTime
                            player.beginInteraction()
                        }
                        let seconds = Double(value.translation.width / w) * total
                        setStart((dragStartValue ?? clip.startTime) + seconds)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        player.endInteraction()
                        seekToClipStart()
                    }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let count = max(6, min(24, Int(width / 44)))
                if strip.count != count || stripURL != clip.url {
                    loadStrip(count: count)
                }
            }
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

    // MARK: - 動かす

    /// 始まりを動かす(長さは変えない)
    private func setStart(_ value: Double) {
        let start = min(max(0, value), maxStart)
        clip.startTime = start
        clip.endTime = start + length
    }

    /// このクリップの先頭(出力タイムライン上の秒)
    private var clipTimelineStart: Double? {
        guard let index = project.index(of: clip.id) else { return nil }
        let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
        guard index < layout.count else { return nil }
        return layout[index].start
    }

    /// プレビューをこのクリップの先頭に移す(始まりのコマが見えるように)
    private func seekToClipStart() {
        guard let start = clipTimelineStart else { return }
        player.pause()
        player.seek(to: start + 0.02)
    }

    /// クリップの先頭から再生して確かめる
    private func playFromClipStart() {
        guard let start = clipTimelineStart else { return }
        player.seek(to: start + 0.02)
        player.play()
    }

    // MARK: - コマの読み込み

    /// 始まりと終わりのコマを取り直す(連続で動かしたときは最後の 1 回だけ。始まりは速く、終わりはゆっくりでよい)
    private func scheduleReload() {
        reloadTask?.cancel()
        let snapshot = clip
        let source = frameSource
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            if let first = await source.frame(clip: snapshot, sourceTime: snapshot.startTime) {
                guard !Task.isCancelled else { return }
                startImage = first
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            if let last = await source.frame(clip: snapshot, sourceTime: max(0, snapshot.endTime - 0.05)) {
                guard !Task.isCancelled else { return }
                endImage = last
            }
        }
    }

    /// 元の動画の帯のコマを count 枚、均等な時刻で読み込む
    private func loadStrip(count: Int) {
        stripTask?.cancel()
        strip = Array(repeating: nil, count: count)
        stripURL = clip.url
        let url = clip.url
        let duration = max(clip.duration, 0.05)
        let still = clip.stillImageURL
        stripTask = Task { @MainActor in
            if let still, let image = UIImage(contentsOfFile: still.path) {
                let small = await image.byPreparingThumbnail(ofSize: CGSize(width: 120, height: 120)) ?? image
                guard !Task.isCancelled else { return }
                strip = Array(repeating: small, count: count)
                return
            }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 120)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
            let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) / Double(count) * duration, preferredTimescale: 600) }
            var index = 0
            for await result in generator.images(for: times) {
                guard !Task.isCancelled else { return }
                if let cg = try? result.image, index < strip.count {
                    strip[index] = UIImage(cgImage: cg)
                }
                index += 1
            }
        }
    }
}

/// 始まり・終わりのコマを取り出す(同じ動画なら AVAssetImageGenerator を使い回して速くする)
@MainActor
private final class SlipFrameSource {
    private var url: URL?
    private var generator: AVAssetImageGenerator?

    func frame(clip: Clip, sourceTime: Double) async -> UIImage? {
        if let still = clip.stillImageURL, let image = UIImage(contentsOfFile: still.path) {
            return await image.byPreparingThumbnail(ofSize: CGSize(width: 720, height: 720)) ?? clip.thumbnail
        }
        if generator == nil || url != clip.url {
            let asset = AVURLAsset(url: clip.url)
            let fresh = AVAssetImageGenerator(asset: asset)
            fresh.appliesPreferredTrackTransform = true
            fresh.maximumSize = CGSize(width: 720, height: 720)
            fresh.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
            fresh.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
            generator = fresh
            url = clip.url
        }
        guard let generator else { return clip.thumbnail }
        let time = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
        if let cg = try? await generator.image(at: time).image {
            return UIImage(cgImage: cg)
        }
        return clip.thumbnail
    }
}
