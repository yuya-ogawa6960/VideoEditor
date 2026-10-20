import SwiftUI
import UIKit
import Observation

// =====================================================================
// オーバーレイ(Bロール / ワイプ / 写真)のための下部パネル
//   - EditorOverlayPlacementPanel : プリセット・位置・サイズ・収め方・不透明度・角丸・フェード
//   - EditorOverlayKenBurnsPanel  : ケン・バーンズ(ゆっくりしたズーム / パン)
//   - EditorOverlayVolumePanel    : 音量(動画のみ)
//   - EditorOverlaySpeedPanel     : 速度(動画のみ)
//   - EditorOverlayFilterPanel    : フィルタ(FilterPickerView を再利用)
// すべて project.overlayBinding(id:) で得た Binding<OverlayClip> を通して編集する。
// =====================================================================

// MARK: - 共通部品

/// パネル内の小見出し
private struct OverlaySectionTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// 操作の下に出す 1 行の説明(やさしい言葉で)
private struct OverlayHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 右寄せの「リセット」ボタン
private struct OverlayResetRow: View {
    let action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            EditorChip(title: "リセット", isSelected: false, action: action)
        }
    }
}

private func overlayPercentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func overlaySecondsText(_ value: Double) -> String {
    String(format: "%.1f 秒", value)
}

/// 2 つの正規化矩形がほぼ同じか(チップの選択表示用)
private func overlayRectsAlmostEqual(_ a: NormalizedRect, _ b: NormalizedRect, tolerance: Double = 0.005) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// オーバーレイの名前と時間の 1 行
private struct OverlayHeaderRow: View {
    let overlay: OverlayClip

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: overlay.isImage ? "photo" : "film")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(overlay.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(MediaTimeText.precise(overlay.start)) – \(MediaTimeText.precise(overlay.end))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 配置

struct EditorOverlayPlacementPanel: View {
    let project: EditorProject
    @Binding var overlay: OverlayClip

    /// 位置チップ
    private enum Position: String, CaseIterable, Identifiable {
        case full, topLeft, topRight, bottomLeft, bottomRight, leftHalf, rightHalf, center

        var id: String { rawValue }

        var title: String {
            switch self {
            case .full: return "全面"
            case .topLeft: return "左上"
            case .topRight: return "右上"
            case .bottomLeft: return "左下"
            case .bottomRight: return "右下"
            case .leftHalf: return "左半分"
            case .rightHalf: return "右半分"
            case .center: return "中央"
            }
        }
    }

    /// ワイプの端からの余白(正規化)
    private let margin: Double = 0.04

    /// キャンバス(プレビュー)のピクセルサイズ
    private var canvasSize: CGSize {
        let size = CompositionBuilder.renderSize(for: project.snapshot(), purpose: .preview)
        if size.width > 0, size.height > 0 { return size }
        return CGSize(width: 1080, height: 1920)
    }

    /// 幅 width(正規化)のときに素材の縦横比を保つ高さ(正規化、1 以下)
    private func aspectHeight(forWidth width: Double) -> Double {
        let canvas = canvasSize
        let source = overlay.displaySize
        guard source.width > 0, source.height > 0, canvas.height > 0 else { return min(max(width, 0.05), 1) }
        let h = width * Double(canvas.width / canvas.height) * Double(source.height / source.width)
        return min(max(h, 0.05), 1)
    }

    private var isHalfFrame: Bool {
        overlay.frame.height >= 0.999 && abs(overlay.frame.width - 0.5) < 0.01
    }

    /// 四隅・中央に置くときの幅(いまワイプなら現在の幅を保つ)
    private var wipeWidth: Double {
        if overlay.frame.isFull || isHalfFrame { return 0.33 }
        return min(max(overlay.frame.width, 0.2), 0.9)
    }

    private func frame(for position: Position) -> NormalizedRect {
        switch position {
        case .full:
            return .full
        case .leftHalf:
            return NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf:
            return NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .center:
            let w = wipeWidth
            let h = aspectHeight(forWidth: w)
            let m = margin
            let rect: NormalizedRect
            switch position {
            case .topLeft:
                rect = NormalizedRect(x: m, y: m, width: w, height: h)
            case .topRight:
                rect = NormalizedRect(x: 1 - m - w, y: m, width: w, height: h)
            case .bottomLeft:
                rect = NormalizedRect(x: m, y: 1 - m - h, width: w, height: h)
            case .bottomRight:
                rect = NormalizedRect(x: 1 - m - w, y: 1 - m - h, width: w, height: h)
            default:
                rect = NormalizedRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
            }
            return rect.clamped()
        }
    }

    private func isSelected(_ position: Position) -> Bool {
        overlayRectsAlmostEqual(overlay.frame, frame(for: position))
    }

    /// サイズスライダー(幅 0.2 ... 1、中心を保ったまま縦横比に合わせて高さも変える)
    private var sizeBinding: Binding<Double> {
        Binding<Double>(
            get: { min(max(overlay.frame.width, 0.2), 1) },
            set: { newValue in
                let w = min(max(newValue, 0.2), 1)
                let h = aspectHeight(forWidth: w)
                let cx = overlay.frame.midX
                let cy = overlay.frame.midY
                overlay.frame = NormalizedRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).clamped()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OverlayHeaderRow(overlay: overlay)

            // プリセット
            VStack(alignment: .leading, spacing: 6) {
                OverlaySectionTitle(title: "よく使う配置")
                OverlayHint(text: "Bロールは画面全体に、ワイプは隅に小さく重ねます。")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(OverlayPreset.allCases) { preset in
                            EditorChip(title: preset.displayName,
                                       isSelected: overlayRectsAlmostEqual(overlay.frame, preset.frame)) {
                                var updated = overlay
                                preset.apply(to: &updated)
                                overlay = updated
                            }
                        }
                    }
                }
            }

            // 位置
            VStack(alignment: .leading, spacing: 6) {
                OverlaySectionTitle(title: "位置")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Position.allCases) { position in
                            EditorChip(title: position.title,
                                       isSelected: isSelected(position)) {
                                overlay.frame = frame(for: position)
                            }
                        }
                    }
                }
            }

            // サイズ
            EditorSliderRow(title: "サイズ(幅)",
                            value: sizeBinding,
                            range: 0.2...1,
                            display: overlayPercentText(overlay.frame.width))

            // 収め方
            VStack(alignment: .leading, spacing: 6) {
                OverlaySectionTitle(title: "収め方")
                HStack(spacing: 8) {
                    ForEach(OverlayFit.allCases) { fit in
                        EditorChip(title: fit.displayName,
                                   isSelected: overlay.fit == fit) {
                            overlay.fit = fit
                        }
                    }
                    Spacer()
                }
                OverlayHint(text: "埋める: 枠いっぱいに広げて端を切る / 収める: 全体が見えるように縮める")
            }

            EditorSliderRow(title: "濃さ(透けにくさ)",
                            value: $overlay.opacity,
                            range: 0...1,
                            display: overlayPercentText(overlay.opacity))

            EditorSliderRow(title: "角丸",
                            value: $overlay.cornerRadius,
                            range: 0...0.5,
                            display: overlayPercentText(overlay.cornerRadius))

            EditorSliderRow(title: "ふわっと出す(フェードイン)",
                            value: $overlay.fadeIn,
                            range: 0...2,
                            display: overlaySecondsText(overlay.fadeIn))

            EditorSliderRow(title: "ふわっと消す(フェードアウト)",
                            value: $overlay.fadeOut,
                            range: 0...2,
                            display: overlaySecondsText(overlay.fadeOut))

            OverlayResetRow {
                overlay.opacity = 1
                overlay.cornerRadius = 0
                overlay.fadeIn = 0.3
                overlay.fadeOut = 0.3
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - ケン・バーンズ

struct EditorOverlayKenBurnsPanel: View {
    @Binding var overlay: OverlayClip

    /// 動きの種類
    private enum Motion: String, CaseIterable, Identifiable {
        case zoomIn, zoomOut, panLeftToRight

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zoomIn: return "ズームイン"
            case .zoomOut: return "ズームアウト"
            case .panLeftToRight: return "左から右へ"
            }
        }

        var preset: KenBurns {
            switch self {
            case .zoomIn: return KenBurns.zoomIn
            case .zoomOut: return KenBurns.zoomOut
            case .panLeftToRight: return KenBurns.panLeftToRight
            }
        }
    }

    @State private var motion: Motion = .zoomIn

    /// 現在の設定からいちばん近い動きの種類を推定する
    private static func inferMotion(from kenBurns: KenBurns) -> Motion {
        if kenBurns.startCrop == KenBurns.zoomOut.startCrop { return .zoomOut }
        if kenBurns.startCrop == KenBurns.panLeftToRight.startCrop { return .panLeftToRight }
        return .zoomIn
    }

    /// 現在の endCrop がプリセットの動きの何割か(0 ... 1)
    private var intensity: Double {
        let preset = motion.preset
        let start = preset.startCrop
        let target = preset.endCrop
        let current = overlay.kenBurns.endCrop
        // プリセットで最も大きく変化する成分から進み具合を求める
        let deltas: [(full: Double, now: Double)] = [
            (target.x - start.x, current.x - start.x),
            (target.y - start.y, current.y - start.y),
            (target.width - start.width, current.width - start.width),
            (target.height - start.height, current.height - start.height)
        ]
        guard let best = deltas.max(by: { abs($0.full) < abs($1.full) }), abs(best.full) > 1e-6 else { return 1 }
        let ratio = best.now / best.full
        return ratio.isFinite ? min(max(ratio, 0), 1) : 1
    }

    private var intensityBinding: Binding<Double> {
        Binding<Double>(
            get: { max(0.1, intensity) },
            set: { newValue in apply(motion, intensity: newValue) }
        )
    }

    /// 動きの種類と強さを設定する(強さ 1 でプリセットそのもの、小さいほど控えめ)
    private func apply(_ newMotion: Motion, intensity: Double) {
        let preset = newMotion.preset
        let t = min(max(intensity, 0.1), 1)
        var kb = overlay.kenBurns
        kb.enabled = true
        kb.startCrop = preset.startCrop
        kb.endCrop = preset.startCrop.interpolated(to: preset.endCrop, t: t)
        overlay.kenBurns = kb
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OverlayHeaderRow(overlay: overlay)

            Toggle(isOn: $overlay.kenBurns.enabled) {
                Label("Ken Burns", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            OverlayHint(text: "写真や映像をゆっくり拡大・移動させて、動きのある見た目にします。")

            VStack(alignment: .leading, spacing: 6) {
                OverlaySectionTitle(title: "動き")
                HStack(spacing: 8) {
                    ForEach(Motion.allCases) { candidate in
                        EditorChip(title: candidate.title,
                                   isSelected: motion == candidate && overlay.kenBurns.enabled) {
                            let keep = intensity
                            motion = candidate
                            apply(candidate, intensity: keep < 0.1 ? 1 : keep)
                        }
                    }
                    Spacer()
                }
            }
            .disabled(!overlay.kenBurns.enabled)
            .opacity(overlay.kenBurns.enabled ? 1 : 0.4)

            EditorSliderRow(title: "強さ",
                            value: intensityBinding,
                            range: 0.1...1,
                            display: overlayPercentText(intensity))
                .disabled(!overlay.kenBurns.enabled)
                .opacity(overlay.kenBurns.enabled ? 1 : 0.4)

            OverlayResetRow {
                apply(motion, intensity: 1)
            }
            .disabled(!overlay.kenBurns.enabled)
            .opacity(overlay.kenBurns.enabled ? 1 : 0.4)

            let note: String = overlay.isImage
                ? "写真が \(overlaySecondsText(overlay.duration)) かけてゆっくり動きます。"
                : "動画にも使えます(ゆっくり拡大したり、横に動いたりします)。"
            Text(verbatim: note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
        .onAppear {
            motion = Self.inferMotion(from: overlay.kenBurns)
        }
        .onChange(of: overlay.kenBurns.enabled) { _, enabled in
            // オンにしたとき動きがなければ、選択中の動きを適用する
            if enabled, overlay.kenBurns.startCrop == overlay.kenBurns.endCrop {
                apply(motion, intensity: 1)
            }
        }
    }
}

// MARK: - 音量(動画オーバーレイ)

struct EditorOverlayVolumePanel: View {
    @Binding var overlay: OverlayClip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverlayHeaderRow(overlay: overlay)

            if overlay.isImage {
                Text("写真には音声がありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                EditorSliderRow(title: "音量",
                                value: $overlay.volume,
                                range: 0...1,
                                display: "\(Int((overlay.volume * 100).rounded()))%")

                HStack(spacing: 8) {
                    EditorChip(title: "ミュート", isSelected: overlay.volume <= 0.001) {
                        overlay.volume = 0
                    }
                    EditorChip(title: "50%", isSelected: abs(overlay.volume - 0.5) < 0.001) {
                        overlay.volume = 0.5
                    }
                    EditorChip(title: "100%", isSelected: overlay.volume >= 0.999) {
                        overlay.volume = 1
                    }
                    Spacer()
                }

                Text("重ねた映像はふつう音を消して、下のメイン映像の音を聞かせます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 速度(動画オーバーレイ)

struct EditorOverlaySpeedPanel: View {
    @Binding var overlay: OverlayClip

    private let presets: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]

    private func label(for value: Double) -> String {
        switch value {
        case 0.25: return "0.25x"
        case 0.5: return "0.5x"
        case 1.5: return "1.5x"
        default: return "\(Int(value))x"
        }
    }

    private func setSpeed(_ value: Double) {
        var updated = overlay
        updated.speed = min(max(value, 0.25), 4)
        updated.clampDurationToSource()
        overlay = updated
    }

    /// log2(速度) を -2 ... 2 で操作する(0.25x ... 4x)
    private var logSpeed: Binding<Double> {
        Binding<Double>(
            get: { log2(min(max(overlay.speed, 0.25), 4)) },
            set: { newValue in
                let raw = pow(2.0, newValue)
                let rounded = (raw * 20).rounded() / 20
                setSpeed(rounded)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverlayHeaderRow(overlay: overlay)

            if overlay.isImage {
                Text("写真の表示時間はタイムラインで端をドラッグして変えられます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            EditorChip(title: label(for: preset),
                                       isSelected: abs(overlay.speed - preset) < 0.001) {
                                setSpeed(preset)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("速度")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2fx", overlay.speed))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: logSpeed, in: -2...2)
                        .tint(.white)
                    HStack {
                        Text("ゆっくり 0.25x")
                        Spacer()
                        Text("1x")
                        Spacer()
                        Text("4x 速く")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                OverlayResetRow {
                    setSpeed(1)
                }

                Text("長さ \(MediaTimeText.precise(overlay.duration))(素材の残り最大 \(MediaTimeText.precise(overlay.maxDuration)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - フィルタ(オーバーレイ)

struct EditorOverlayFilterPanel: View {
    let project: EditorProject
    @Binding var overlay: OverlayClip

    @State private var thumbnail: UIImage?

    var body: some View {
        FilterPickerView(filter: $overlay.filter,
                         sourceImage: thumbnail,
                         onApplyToAll: {
                             let filter = overlay.filter
                             for i in project.overlays.indices {
                                 project.overlays[i].filter = filter
                             }
                         })
        .task(id: overlay.url) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        let url = overlay.url
        if overlay.isImage {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                MediaStore.makeImageClipThumbnail(url: url, maxPixel: 320)
            }.value
            if !Task.isCancelled {
                thumbnail = image
            }
        } else {
            let image = await MediaStore.thumbnail(for: url, at: overlay.sourceStart + 0.1, maxPixel: 320)
            if !Task.isCancelled {
                thumbnail = image
            }
        }
    }
}
