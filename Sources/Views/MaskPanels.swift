import SwiftUI
import UIKit
import AVFoundation
import Observation

// =====================================================================
// 第4弾: クリップ・オーバーレイの効果のための下部パネル
//   - EditorAnalysisRunner       : 長い解析を 1 つだけ走らせ、進捗(ClipFXProgress)とキャンセルを持つ
//   - EditorMaskControls         : マスクの形・大きさ・ぼかし・回転・反転(クリップ / オーバーレイ共通)
//   - EditorClipMaskPanel / EditorOverlayMaskPanel
//   - EditorAutoReframePanel     : 自動リフレーム(VisionReframe.analyze → clip.reframe)
//   - EditorStabilizePanel       : 手ぶれ補正(Stabilizer.analyze → clip.stabilization)
//   - EditorEnhancePanel         : 画質(ノイズ除去・美肌・簡易高画質化)
//   - EditorParallaxControls     : 3D ズーム(DepthParallaxRenderer.hasDepth で奥行きの有無を表示)
//   - EditorClipParallaxPanel / EditorOverlayParallaxPanel
//   - EditorTrackingController   : プレビューで囲んだ四角 → MotionTracker.track → キーフレーム
//   - EditorTrackingPanel        : トラッキングの説明と結果
// マスクの中心・大きさ・角度はプレビュー上(PreviewGestureOverlay の maskTarget)でも操作できる。
// =====================================================================

// MARK: - 長い解析の実行(進捗つき・キャンセルつき)

/// 長い解析を 1 つだけ走らせる。ContentView は `progress` が nil でないとき ClipFXProgressOverlay を出し、
/// キャンセルで `cancel()` を呼ぶ。body は @MainActor で動くので、結果をそのままプロジェクトへ書いてよい。
@Observable
final class EditorAnalysisRunner {
    var progress: ClipFXProgress?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isRunning: Bool { progress != nil }

    /// 解析を始める(実行中のものは止める)。`report` に 0...1 を渡すと進捗表示が更新される。
    /// CancellationError は黙って終わり、それ以外のエラーは onError に渡す。
    func run(title: String,
             indeterminate: Bool = false,
             body: @escaping @MainActor (_ report: @escaping (Double) -> Void) async throws -> Void,
             onError: @escaping @MainActor (Error) -> Void) {
        task?.cancel()
        generation += 1
        let current = generation
        progress = ClipFXProgress(title: title, fraction: indeterminate ? nil : 0)

        let report: (Double) -> Void = { [weak self] value in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.progress != nil else { return }
                let clamped = value.isFinite ? min(max(value, 0), 1) : 0
                self.progress?.fraction = clamped
            }
        }

        task = Task { @MainActor [weak self] in
            do {
                try await body(report)
            } catch is CancellationError {
                // キャンセルは静かに終わる
            } catch {
                if !Task.isCancelled {
                    onError(error)
                }
            }
            guard let self, self.generation == current else { return }
            self.progress = nil
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        generation += 1
    }
}

private func maskPanelPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// MARK: - マスク(共通の操作部)

/// マスクの形・大きさ・ぼかし・回転・反転。中心はスライダーとプレビュー上のドラッグの両方で変えられる
struct EditorMaskControls: View {
    @Binding var mask: MaskSettings
    /// 形の下に出す補足(プレビュー操作の説明など)
    let note: String

    private var widthBinding: Binding<Double> {
        Binding<Double>(get: { mask.width }, set: { mask.width = $0 })
    }
    private var heightBinding: Binding<Double> {
        Binding<Double>(get: { mask.height }, set: { mask.height = $0 })
    }
    private var featherBinding: Binding<Double> {
        Binding<Double>(get: { mask.feather }, set: { mask.feather = $0 })
    }
    private var rotationBinding: Binding<Double> {
        Binding<Double>(get: { mask.rotation }, set: { mask.rotation = $0 })
    }
    private var cornerBinding: Binding<Double> {
        Binding<Double>(get: { mask.cornerRadius }, set: { mask.cornerRadius = $0 })
    }
    private var centerXBinding: Binding<Double> {
        Binding<Double>(get: { mask.center.x }, set: { mask.center = NormalizedPoint(x: $0, y: mask.center.y) })
    }
    private var centerYBinding: Binding<Double> {
        Binding<Double>(get: { mask.center.y }, set: { mask.center = NormalizedPoint(x: mask.center.x, y: $0) })
    }
    private var invertedBinding: Binding<Bool> {
        Binding<Bool>(get: { mask.inverted }, set: { mask.inverted = $0 })
    }

    private var isBand: Bool { mask.shape == .linear || mask.shape == .mirror }

    private var isDefaultGeometry: Bool {
        let d = MaskSettings()
        return mask.center == d.center && mask.width == d.width && mask.height == d.height
            && mask.rotation == d.rotation && mask.feather == d.feather && !mask.inverted
            && mask.cornerRadius == d.cornerRadius
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "形")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MaskShape.allCases) { shape in
                            EditorChip(title: shape.displayName, isSelected: mask.shape == shape) {
                                mask.shape = shape
                            }
                        }
                    }
                }
            }

            if mask.isActive {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Group {
                    if !isBand {
                        EditorSliderRow(title: "幅(画面の短辺に対して)",
                                        value: widthBinding,
                                        range: 0.05...2,
                                        display: maskPanelPercent(mask.width))
                    }
                    EditorSliderRow(title: isBand ? "帯の幅" : "高さ",
                                    value: heightBinding,
                                    range: 0.05...2,
                                    display: maskPanelPercent(mask.height))
                    if !isBand {
                        HStack {
                            EditorChip(title: "縦横を同じに", isSelected: false) {
                                mask.height = mask.width
                            }
                            Spacer()
                        }
                    }
                    EditorSliderRow(title: "ぼかし(境目のやわらかさ)",
                                    value: featherBinding,
                                    range: 0...0.3,
                                    display: maskPanelPercent(mask.feather))
                    EditorSliderRow(title: "回転",
                                    value: rotationBinding,
                                    range: -180...180,
                                    display: String(format: "%.0f°", mask.rotation))
                    if mask.shape == .roundedRectangle {
                        EditorSliderRow(title: "角丸",
                                        value: cornerBinding,
                                        range: 0...0.5,
                                        display: maskPanelPercent(mask.cornerRadius))
                    }
                }

                Group {
                    EditorSliderRow(title: "横位置",
                                    value: centerXBinding,
                                    range: 0...1,
                                    display: String(format: "%.2f", mask.center.x))
                    EditorSliderRow(title: "縦位置",
                                    value: centerYBinding,
                                    range: 0...1,
                                    display: String(format: "%.2f", mask.center.y))
                    Toggle("反転(形の外側を見せる)", isOn: invertedBinding)
                        .font(.subheadline)
                        .tint(.accentColor)
                }

                HStack {
                    EditorChip(title: "位置・大きさをリセット", isSelected: false) {
                        let shape = mask.shape
                        var reset = MaskSettings()
                        reset.shape = shape
                        mask = reset
                    }
                    .disabled(isDefaultGeometry)
                    .opacity(isDefaultGeometry ? 0.4 : 1)
                    Spacer()
                    EditorChip(title: "マスクを外す", isSelected: false) {
                        mask = MaskSettings()
                    }
                }
            } else {
                Text("形を選ぶと、その形の中だけが映り、外側は黒(オーバーレイは透明)になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - マスク(クリップ)

struct EditorClipMaskPanel: View {
    @Binding var clip: Clip

    private var maskBinding: Binding<MaskSettings> {
        Binding<MaskSettings>(get: { clip.mask }, set: { clip.mask = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: clip.isStill ? "photo" : "film",
                                name: clip.name,
                                start: clip.startTime,
                                end: clip.endTime)
            EditorMaskControls(mask: maskBinding,
                               note: "プレビューの点線の形をドラッグで移動、ピンチで大きさ、2 本指で回転できます。形の外側は黒になります。")
        }
        .padding(.top, 6)
    }
}

// MARK: - マスク(オーバーレイ)

struct EditorOverlayMaskPanel: View {
    @Binding var overlay: OverlayClip

    private var maskBinding: Binding<MaskSettings> {
        Binding<MaskSettings>(get: { overlay.mask }, set: { overlay.mask = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: overlay.isImage ? "photo" : "film",
                                name: overlay.name,
                                start: overlay.start,
                                end: overlay.end)
            EditorMaskControls(mask: maskBinding,
                               note: "位置と大きさはこのオーバーレイの枠の中で決まります。プレビューの点線の形をドラッグで移動、ピンチで大きさ、2 本指で回転できます。形の外側は透明になり、下の映像が見えます。")
        }
        .padding(.top, 6)
    }
}

// MARK: - 自動リフレーム

struct EditorAutoReframePanel: View {
    let project: EditorProject
    @Binding var clip: Clip
    let analysis: EditorAnalysisRunner

    @State private var errorText: String?
    @State private var message: String?

    private var hasTrack: Bool { clip.reframe.samples.count >= 2 }

    private var enabledBinding: Binding<Bool> {
        Binding<Bool>(get: { clip.reframe.enabled }, set: { clip.reframe.enabled = $0 })
    }
    private var smoothingBinding: Binding<Double> {
        Binding<Double>(get: { clip.reframe.smoothing }, set: { clip.reframe.smoothing = $0 })
    }
    private var zoomBinding: Binding<Double> {
        Binding<Double>(get: { clip.reframe.zoom }, set: { clip.reframe.zoom = $0 })
    }

    /// 画面比率の設定によって効くかどうかの説明
    private var canvasNote: String {
        let canvas = project.canvas
        if canvas.aspect == .original {
            return "いまの画面比率は「元のまま」なので切り出しは起きません。「比率」で 9:16 や 1:1 にすると、人物が中央に来るように自動で切り出します。"
        }
        if canvas.scaling == .fill {
            return "画面比率 \(canvas.aspect.displayName)・埋める: 切り出す位置が人物を追いかけます。"
        }
        return "画面比率が元の映像と違うときに効きます(いまは \(canvas.aspect.displayName))。「比率」で「埋める」にすると確実に効きます。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("人物や顔を検出し、縦動画などに切り出すときも被写体が画面の中央に来るように追いかけます。解析結果はこのクリップに保存されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if clip.isStill {
                Text("静止画クリップでは使えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    EditorPillButton(title: hasTrack ? "もう一度解析" : "解析",
                                     systemImage: "person.crop.rectangle",
                                     prominent: true) {
                        analyze()
                    }
                    .disabled(analysis.isRunning)
                    .opacity(analysis.isRunning ? 0.5 : 1)
                    if hasTrack {
                        Text("注目点 \(clip.reframe.samples.count) 点")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Toggle(isOn: enabledBinding) {
                    Label("自動リフレームを使う", systemImage: "person.and.background.dotted")
                        .font(.subheadline)
                }
                .tint(.accentColor)
                .disabled(!hasTrack)
                .opacity(hasTrack ? 1 : 0.4)

                EditorSliderRow(title: "なめらかさ(大きいほどゆっくり追う)",
                                value: smoothingBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.reframe.smoothing))
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)
                EditorSliderRow(title: "被写体の大きさ(ズーム)",
                                value: zoomBinding,
                                range: 1...2,
                                display: String(format: "%.2fx", clip.reframe.zoom))
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)

                Text(canvasNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    EditorChip(title: "解析結果を消す", isSelected: false) {
                        clip.reframe = ReframeTrack()
                        message = nil
                    }
                    .disabled(clip.reframe.samples.isEmpty)
                    .opacity(clip.reframe.samples.isEmpty ? 0.4 : 1)
                }
            }
        }
        .padding(.top, 6)
    }

    private func analyze() {
        let target = clip
        errorText = nil
        message = nil
        analysis.run(title: "人物を検出中") { report in
            let track = try await VisionReframe.analyze(clip: target, step: 0.25, progress: report)
            if Task.isCancelled { return }
            var merged = track
            merged.enabled = true
            merged.smoothing = clip.reframe.smoothing
            merged.zoom = clip.reframe.zoom
            clip.reframe = merged
            if track.samples.count < 2 {
                message = "人物や顔を見つけられませんでした。別のクリップでお試しください。"
            } else {
                message = "\(track.samples.count) 点の注目点を記録しました。"
            }
        } onError: { error in
            errorText = "解析できませんでした: \(error.localizedDescription)"
        }
    }
}

// MARK: - 手ぶれ補正

struct EditorStabilizePanel: View {
    @Binding var clip: Clip
    let analysis: EditorAnalysisRunner

    @State private var errorText: String?
    @State private var message: String?

    private var hasTrack: Bool { clip.stabilization.samples.count >= 2 }

    private var enabledBinding: Binding<Bool> {
        Binding<Bool>(get: { clip.stabilization.enabled }, set: { clip.stabilization.enabled = $0 })
    }
    private var strengthBinding: Binding<Double> {
        Binding<Double>(get: { clip.stabilization.strength }, set: { clip.stabilization.strength = $0 })
    }
    private var cropZoomBinding: Binding<Double> {
        Binding<Double>(get: { clip.stabilization.cropZoom }, set: { clip.stabilization.cropZoom = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("カメラの揺れを解析して、映像を少し拡大しながら逆方向に動かして揺れを打ち消します。解析には映像の長さと同じくらいの時間がかかることがあります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if clip.isStill {
                Text("静止画クリップでは使えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    EditorPillButton(title: hasTrack ? "もう一度解析" : "解析",
                                     systemImage: "camera.metering.center.weighted",
                                     prominent: true) {
                        analyze()
                    }
                    .disabled(analysis.isRunning)
                    .opacity(analysis.isRunning ? 0.5 : 1)
                    if hasTrack {
                        Text("\(clip.stabilization.samples.count) コマ分")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Toggle(isOn: enabledBinding) {
                    Label("手ぶれ補正を使う", systemImage: "hand.raised.slash")
                        .font(.subheadline)
                }
                .tint(.accentColor)
                .disabled(!hasTrack)
                .opacity(hasTrack ? 1 : 0.4)

                EditorSliderRow(title: "強さ",
                                value: strengthBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.stabilization.strength))
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)
                EditorSliderRow(title: "拡大(端の黒を隠す)",
                                value: cropZoomBinding,
                                range: 1.0...1.3,
                                display: String(format: "%.2fx", clip.stabilization.cropZoom))
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("揺れが大きいときは「拡大」を上げると端の黒が出にくくなります。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    EditorChip(title: "解析結果を消す", isSelected: false) {
                        clip.stabilization = StabilizationTrack()
                        message = nil
                    }
                    .disabled(clip.stabilization.samples.isEmpty)
                    .opacity(clip.stabilization.samples.isEmpty ? 0.4 : 1)
                }
            }
        }
        .padding(.top, 6)
    }

    private func analyze() {
        let target = clip
        errorText = nil
        message = nil
        analysis.run(title: "揺れを解析中") { report in
            let track = try await Stabilizer.analyze(clip: target, fps: 30, progress: report)
            if Task.isCancelled { return }
            var merged = track
            merged.enabled = true
            merged.strength = clip.stabilization.strength
            merged.cropZoom = max(clip.stabilization.cropZoom, track.cropZoom)
            clip.stabilization = merged
            if track.samples.count < 2 {
                message = "揺れを解析できませんでした(映像が短すぎるか、動きが読み取れませんでした)。"
            } else {
                message = "解析が終わりました。再生して揺れの減り方を確認してください。"
            }
        } onError: { error in
            errorText = "解析できませんでした: \(error.localizedDescription)"
        }
    }
}

// MARK: - 画質

struct EditorEnhancePanel: View {
    @Binding var clip: Clip

    private var denoiseBinding: Binding<Double> {
        Binding<Double>(get: { clip.enhance.denoise }, set: { clip.enhance.denoise = $0 })
    }
    private var retouchBinding: Binding<Double> {
        Binding<Double>(get: { clip.enhance.retouch }, set: { clip.enhance.retouch = $0 })
    }
    private var sharpenBinding: Binding<Double> {
        Binding<Double>(get: { clip.enhance.sharpenUpscale }, set: { clip.enhance.sharpenUpscale = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: clip.isStill ? "photo" : "film",
                                name: clip.name,
                                start: clip.startTime,
                                end: clip.endTime)

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: "ノイズ除去",
                                value: denoiseBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.enhance.denoise))
                Text("暗い場所で撮ったザラつきを減らします。上げすぎると細かい模様がぼやけます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: "美肌",
                                value: retouchBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.enhance.retouch))
                Text("肌色の部分だけをなめらかにします(顔の検出はせず、肌の色で判断する簡易方式です)。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: "簡易高画質化(輪郭強調)",
                                value: sharpenBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.enhance.sharpenUpscale))
                Text("元の映像が出力サイズより小さいときに、輪郭を強調してくっきり見せます。本当の解像度は上がりません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("※ 処理が重いため、プレビューがカクつくことがあります。書き出しには正しく反映されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    clip.enhance = ClipEnhancements()
                }
                .disabled(clip.enhance.isIdentity)
                .opacity(clip.enhance.isIdentity ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 3D ズーム(共通の操作部)

struct EditorParallaxControls: View {
    @Binding var parallax: DepthParallax
    /// 奥行き情報を調べる写真
    let imageURL: URL
    /// 表示される長さ(説明用)
    let durationSeconds: Double

    /// nil = 確認中
    @State private var hasDepth: Bool? = nil

    private var enabledBinding: Binding<Bool> {
        Binding<Bool>(get: { parallax.enabled }, set: { parallax.enabled = $0 })
    }
    private var strengthBinding: Binding<Double> {
        Binding<Double>(get: { parallax.strength }, set: { parallax.strength = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: enabledBinding) {
                Label("3Dズーム(奥行きで動かす)", systemImage: "cube.transparent")
                    .font(.subheadline)
            }
            .tint(.accentColor)

            if let hasDepth {
                if hasDepth {
                    Text("この写真には奥行き情報があります。手前と奥で動く量が変わり、立体的に見えます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("この写真には奥行き情報がありません(ケン・バーンズで代用)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("奥行き情報を確認中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "動きの向き")
                HStack(spacing: 8) {
                    ForEach(ParallaxDirection.allCases) { direction in
                        EditorChip(title: direction.displayName, isSelected: parallax.direction == direction) {
                            parallax.direction = direction
                        }
                    }
                    Spacer()
                }
            }
            .disabled(!parallax.enabled)
            .opacity(parallax.enabled ? 1 : 0.4)

            EditorSliderRow(title: "強さ",
                            value: strengthBinding,
                            range: 0...1,
                            display: maskPanelPercent(parallax.strength))
                .disabled(!parallax.enabled)
                .opacity(parallax.enabled ? 1 : 0.4)

            Text("写真が \(String(format: "%.1f", durationSeconds)) 秒かけて動きます。ポートレートモードで撮った写真など、奥行き(深度)つきの写真で立体的に見えます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: imageURL) {
            let url = imageURL
            let result = await Task.detached(priority: .userInitiated) { () -> Bool in
                DepthParallaxRenderer.hasDepth(url: url)
            }.value
            if !Task.isCancelled {
                hasDepth = result
            }
        }
    }
}

// MARK: - 3D ズーム(静止画クリップ)

struct EditorClipParallaxPanel: View {
    @Binding var clip: Clip

    private var parallaxBinding: Binding<DepthParallax> {
        Binding<DepthParallax>(get: { clip.parallax }, set: { clip.parallax = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: "photo",
                                name: clip.name,
                                start: clip.startTime,
                                end: clip.endTime)
            if clip.isStill {
                EditorParallaxControls(parallax: parallaxBinding,
                                       imageURL: clip.stillImageURL ?? clip.url,
                                       durationSeconds: clip.outputDuration)
            } else {
                Text("3Dズームは写真(静止画クリップ)でのみ使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 3D ズーム(写真オーバーレイ)

struct EditorOverlayParallaxPanel: View {
    @Binding var overlay: OverlayClip

    private var parallaxBinding: Binding<DepthParallax> {
        Binding<DepthParallax>(get: { overlay.parallax }, set: { overlay.parallax = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: overlay.isImage ? "photo" : "film",
                                name: overlay.name,
                                start: overlay.start,
                                end: overlay.end)
            if overlay.isImage {
                EditorParallaxControls(parallax: parallaxBinding,
                                       imageURL: overlay.url,
                                       durationSeconds: overlay.duration)
                if overlay.kenBurns.enabled {
                    Text("ケン・バーンズも有効です。3Dズームをオンにすると 3Dズームの動きが優先されます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("3Dズームは写真のオーバーレイでのみ使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - トラッキング

/// トラッキングでキーフレームを付ける部品
enum EditorTrackingTarget: Equatable {
    case text(UUID)
    case overlay(UUID)
}

/// プレビュー(キャンバス)座標と、メインクリップの映像座標の相互変換。
/// 収める / 埋める の単純な近似で、切り抜き・回転・自動リフレーム・手ぶれ補正は考慮しない。
enum PreviewTrackingMath {
    /// クリップがキャンバスに描かれる矩形(キャンバス画素)
    static func clipRect(clipSize: CGSize, canvasSize: CGSize, scaling: ScalingMode) -> CGRect {
        guard clipSize.width > 0, clipSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let sx: CGFloat = canvasSize.width / clipSize.width
        let sy: CGFloat = canvasSize.height / clipSize.height
        let scale: CGFloat = (scaling == .fill) ? max(sx, sy) : min(sx, sy)
        let w: CGFloat = clipSize.width * scale
        let h: CGFloat = clipSize.height * scale
        return CGRect(x: (canvasSize.width - w) / 2, y: (canvasSize.height - h) / 2, width: w, height: h)
    }

    /// キャンバス正規化座標 → 映像正規化座標
    static func sourcePoint(fromCanvas p: NormalizedPoint, clipRect: CGRect, canvasSize: CGSize) -> NormalizedPoint {
        let px: CGFloat = CGFloat(p.x) * canvasSize.width
        let py: CGFloat = CGFloat(p.y) * canvasSize.height
        let x: CGFloat = (px - clipRect.minX) / max(clipRect.width, 1)
        let y: CGFloat = (py - clipRect.minY) / max(clipRect.height, 1)
        return NormalizedPoint(x: Double(x), y: Double(y))
    }

    /// 映像正規化座標 → キャンバス正規化座標
    static func canvasPoint(fromSource p: NormalizedPoint, clipRect: CGRect, canvasSize: CGSize) -> NormalizedPoint {
        let px: CGFloat = clipRect.minX + CGFloat(p.x) * clipRect.width
        let py: CGFloat = clipRect.minY + CGFloat(p.y) * clipRect.height
        return NormalizedPoint(x: Double(px / max(canvasSize.width, 1)),
                               y: Double(py / max(canvasSize.height, 1)))
    }

    /// キャンバス正規化矩形 → 映像正規化矩形(0...1 に収める)
    static func sourceRect(fromCanvas r: NormalizedRect, clipRect: CGRect, canvasSize: CGSize) -> NormalizedRect {
        let a = sourcePoint(fromCanvas: NormalizedPoint(x: r.minX, y: r.minY), clipRect: clipRect, canvasSize: canvasSize)
        let b = sourcePoint(fromCanvas: NormalizedPoint(x: r.maxX, y: r.maxY), clipRect: clipRect, canvasSize: canvasSize)
        let x0 = min(max(a.x, 0), 1)
        let y0 = min(max(a.y, 0), 1)
        let x1 = min(max(b.x, 0), 1)
        let y1 = min(max(b.y, 0), 1)
        return NormalizedRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

/// プレビューで囲んだ四角から MotionTracker を走らせ、部品のキーフレームにする
@Observable
final class EditorTrackingController {
    var statusText: String?
    var errorText: String?
    var lastRect: NormalizedRect?

    func reset() {
        statusText = nil
        errorText = nil
        lastRect = nil
    }

    /// rect はキャンバス正規化座標(PreviewRectSelection の結果)
    func track(rect: NormalizedRect,
               target: EditorTrackingTarget,
               project: EditorProject,
               player: PlayerController,
               history: EditorHistory,
               analysis: EditorAnalysisRunner) {
        errorText = nil
        statusText = nil
        lastRect = rect
        player.pause()
        let t = player.currentTime

        // 部品の表示範囲と、いまの配置
        var itemStart = 0.0
        var itemEnd = 0.0
        var itemCenter = NormalizedPoint.center
        var itemScale = 1.0
        var itemRotation = 0.0
        var itemOpacity = 1.0
        switch target {
        case .text(let id):
            guard let text = project.textClips.first(where: { $0.id == id }) else {
                errorText = "対象のテキストが見つかりません。"
                return
            }
            itemStart = text.start
            itemEnd = text.end
            itemCenter = text.center
            itemScale = text.scale
            itemRotation = text.rotation
            itemOpacity = text.opacity
        case .overlay(let id):
            guard let overlay = project.overlays.first(where: { $0.id == id }) else {
                errorText = "対象のオーバーレイが見つかりません。"
                return
            }
            itemStart = overlay.start
            itemEnd = overlay.end
            itemCenter = NormalizedPoint(x: overlay.frame.midX, y: overlay.frame.midY)
            itemScale = 1
            itemRotation = 0
            itemOpacity = overlay.opacity
        }

        guard t >= itemStart - 0.001, t < itemEnd else {
            errorText = "再生位置(中央の白い線)を、この部品が表示されている範囲に合わせてから囲んでください。"
            return
        }
        guard let location = project.locate(timelineTime: t), location.index < project.clips.count else {
            errorText = "再生位置にクリップがありません。"
            return
        }
        let clip = project.clips[location.index]
        if clip.isStill {
            errorText = "静止画クリップの上では動きを追跡できません。"
            return
        }
        if clip.isReversed {
            errorText = "逆再生中のクリップでは追跡できません。いったん逆再生を解除してください。"
            return
        }

        let sourceStart = min(max(location.sourceTime, clip.startTime), clip.endTime)
        let remainingOutput = max(0, itemEnd - t)
        let averageSpeed: Double
        if clip.outputDuration > 0 {
            averageSpeed = clip.trimmedDuration / clip.outputDuration
        } else {
            averageSpeed = max(clip.speed, 0.01)
        }
        let sourceEnd = min(clip.endTime, sourceStart + remainingOutput * averageSpeed)
        guard sourceEnd - sourceStart >= 0.2 else {
            errorText = "追跡できる長さが短すぎます(部品の残り時間が 0.2 秒以上必要です)。"
            return
        }

        let snapshot = project.snapshot()
        let canvasSize = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)
        let scaling: ScalingMode = (snapshot.canvas.aspect == .original) ? .fit : snapshot.canvas.scaling
        let clipRect = PreviewTrackingMath.clipRect(clipSize: clip.displaySize, canvasSize: canvasSize, scaling: scaling)
        let sourceRect = PreviewTrackingMath.sourceRect(fromCanvas: rect, clipRect: clipRect, canvasSize: canvasSize)
        guard sourceRect.width > 0.005, sourceRect.height > 0.005 else {
            errorText = "囲んだ範囲が映像の外です。映像の上で対象を囲んでください。"
            return
        }

        // 部品の中心と対象の中心のずれを保ったまま追いかける
        let offsetX = itemCenter.x - rect.midX
        let offsetY = itemCenter.y - rect.midY
        let itemOffset = max(0, t - itemStart)
        let baseOutput = ClipFXTimeline.outputOffset(sourceTime: sourceStart, clip: clip)
        let url = clip.url

        analysis.run(title: "動きを追跡中") { [weak self] report in
            let tracked = try await MotionTracker.track(url: url,
                                                        start: sourceStart,
                                                        end: sourceEnd,
                                                        initialRect: sourceRect,
                                                        fps: 15,
                                                        progress: report)
            if Task.isCancelled { return }
            guard let self else { return }
            guard !tracked.isEmpty else {
                self.statusText = "対象を追跡できませんでした。もう一度、対象をぴったり囲んでみてください。"
                return
            }
            var keyframes: [Keyframe] = []
            keyframes.reserveCapacity(tracked.count)
            for tracker in tracked {
                let out = ClipFXTimeline.outputOffset(sourceTime: sourceStart + tracker.time, clip: clip) - baseOutput
                let canvas = PreviewTrackingMath.canvasPoint(fromSource: tracker.center,
                                                             clipRect: clipRect,
                                                             canvasSize: canvasSize)
                let cx = min(max(canvas.x + offsetX, -0.25), 1.25)
                let cy = min(max(canvas.y + offsetY, -0.25), 1.25)
                let keyframe = Keyframe(time: itemOffset + max(0, out),
                                        center: NormalizedPoint(x: cx, y: cy),
                                        scale: itemScale,
                                        rotation: itemRotation,
                                        opacity: itemOpacity,
                                        easing: .linear)
                keyframes.append(keyframe)
            }
            keyframes.sort { $0.time < $1.time }

            history.record(project)
            switch target {
            case .text(let id):
                if let i = project.textClips.firstIndex(where: { $0.id == id }) {
                    project.textClips[i].keyframes = keyframes
                }
            case .overlay(let id):
                if let i = project.overlays.firstIndex(where: { $0.id == id }) {
                    project.overlays[i].keyframes = keyframes
                }
            }
            let seconds = String(format: "%.1f", sourceEnd - sourceStart)
            self.statusText = "\(keyframes.count) 個のキーフレームを作りました(\(seconds) 秒分)。「キーフレーム」で確認・調整できます。"
        } onError: { [weak self] error in
            self?.errorText = "追跡できませんでした: \(error.localizedDescription)"
        }
    }
}

/// トラッキングの説明と結果(四角はプレビュー上で描く)
struct EditorTrackingPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let analysis: EditorAnalysisRunner
    let controller: EditorTrackingController
    let target: EditorTrackingTarget

    private var keyframeCount: Int {
        switch target {
        case .text(let id):
            return project.textClips.first(where: { $0.id == id })?.keyframes.count ?? 0
        case .overlay(let id):
            return project.overlays.first(where: { $0.id == id })?.keyframes.count ?? 0
        }
    }

    private var rangeText: String {
        switch target {
        case .text(let id):
            guard let text = project.textClips.first(where: { $0.id == id }) else { return "" }
            return "\(MediaTimeText.precise(text.start)) – \(MediaTimeText.precise(text.end))"
        case .overlay(let id):
            guard let overlay = project.overlays.first(where: { $0.id == id }) else { return "" }
            return "\(MediaTimeText.precise(overlay.start)) – \(MediaTimeText.precise(overlay.end))"
        }
    }

    private var targetName: String {
        switch target {
        case .text(let id):
            let isSticker = project.textClips.first(where: { $0.id == id })?.isSticker ?? false
            return isSticker ? "ステッカー" : "テキスト"
        case .overlay:
            return "オーバーレイ"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("プレビューの上で、追いかけたい対象(人や物)を囲むように四角をドラッグしてください。いまの\(targetName)と対象の位置関係を保ったまま、対象の動きに合わせて移動するキーフレームを作ります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("再生位置 \(MediaTimeText.precise(player.currentTime)) / \(targetName)の表示範囲 \(rangeText)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if analysis.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("追跡中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText = controller.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let statusText = controller.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if keyframeCount > 0 {
                    Text("キーフレーム \(keyframeCount) 個")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EditorChip(title: "キーフレームを消す", isSelected: false) {
                    clearKeyframes()
                }
                .disabled(keyframeCount == 0)
                .opacity(keyframeCount == 0 ? 0.4 : 1)
            }

            Text("※ 追跡は再生位置にあるメインのクリップの映像に対して行い、部品の残り時間ぶんだけ続けます。切り抜き・回転・自動リフレーム中のクリップでは位置がずれることがあります。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
        .onAppear {
            controller.reset()
            player.pause()
        }
    }

    private func clearKeyframes() {
        history.record(project)
        switch target {
        case .text(let id):
            if let i = project.textClips.firstIndex(where: { $0.id == id }) {
                project.textClips[i].keyframes = []
            }
        case .overlay(let id):
            if let i = project.overlays.firstIndex(where: { $0.id == id }) {
                project.overlays[i].keyframes = []
            }
        }
        controller.statusText = "キーフレームを消しました。"
    }
}
