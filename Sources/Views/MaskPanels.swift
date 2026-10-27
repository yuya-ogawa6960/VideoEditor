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
/// 書き出し・文字起こしと同じように、ホームに戻ったり画面をロックしても続く:
///   - iOS 26 以降: ContinuedProcessing.begin(kind: .analyze)(ロック画面に進み具合が出る。ユーザーが止めたらキャンセル)
///   - それ以前: UIApplication.beginBackgroundTask(約 30 秒だけ続く)
///   - 実行中は画面を自動でロックしない
@Observable
final class EditorAnalysisRunner {
    var progress: ClipFXProgress?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var continuedHandle: ContinuedProcessingHandle?
    /// 画面の自動ロックを止めるときの名前(係ごとに別にする。書き出しやほかの解析が先に終わっても解除されないように)
    @ObservationIgnored private let idleTimerKey = "analysis-" + UUID().uuidString

    var isRunning: Bool { progress != nil }

    deinit {
        // シートを下に引いて閉じたときなど、解析の途中で破棄されたら止める。
        // 画面の自動ロックの止めとバックグラウンドの延長も外す(係ごとの名前なので、ほかの処理が終わっても外れないため)
        guard let task else { return }
        task.cancel()
        let key = idleTimerKey
        let taskID = backgroundTaskID
        let handle = continuedHandle
        Task { @MainActor in
            handle?.finish(success: false)
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            IdleTimerGuard.set(false, for: key)
        }
    }

    /// 解析を始める(実行中のものは止める)。`report` に 0...1 を渡すと進捗表示が更新される。
    /// CancellationError は黙って終わり、それ以外のエラーは onError に渡す。
    func run(title: String,
             indeterminate: Bool = false,
             robot: RobotAnimation = .workshop,
             body: @escaping @MainActor (_ report: @escaping (Double) -> Void) async throws -> Void,
             onError: @escaping @MainActor (Error) -> Void) {
        task?.cancel()
        finishBackgroundSupport(success: false)
        generation += 1
        let current = generation
        progress = ClipFXProgress(title: title, fraction: indeterminate ? nil : 0, robot: robot)
        beginBackgroundSupport(title: title)
        Analytics.shared.track("analysis", ["name": title])
        // 解析は広告の間も続く
        Task { @MainActor in AdsManager.shared.showInterstitial(.analysisStart) }

        let report: (Double) -> Void = { [weak self] value in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.progress != nil else { return }
                let clamped = value.isFinite ? min(max(value, 0), 1) : 0
                self.progress?.fraction = clamped
                self.continuedHandle?.update(completed: clamped, subtitle: nil)
            }
        }

        task = Task { @MainActor [weak self] in
            var succeeded = true
            do {
                try await body(report)
            } catch is CancellationError {
                succeeded = false
            } catch {
                succeeded = false
                if !Task.isCancelled {
                    onError(error)
                }
            }
            guard let self, self.generation == current else { return }
            self.progress = nil
            self.task = nil
            self.finishBackgroundSupport(success: succeeded)
            if succeeded {
                AdsManager.shared.showInterstitial(.analysisFinished)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        generation += 1
        finishBackgroundSupport(success: false)
    }

    // MARK: バックグラウンドでも続ける

    /// run() はユーザー操作からメインスレッドで呼ばれる(継続処理はアプリが前面にある間にしか始められない)
    private func beginBackgroundSupport(title: String) {
        MainActor.assumeIsolated {
            let app = UIApplication.shared
            IdleTimerGuard.set(true, for: idleTimerKey)
            backgroundTaskID = app.beginBackgroundTask(withName: "Analysis") { [weak self] in
                // 時間切れ(メインスレッドで呼ばれる)。終了しないとアプリが強制終了される。処理そのものは止めない
                MainActor.assumeIsolated {
                    self?.endBackgroundTask()
                }
            }
            let handle = ContinuedProcessing.begin(kind: .analyze, title: title, subtitle: title, wantsGPU: true)
            handle?.onExpire = { [weak self] in
                // ロック画面などでユーザーが止めた / システムが打ち切った → 解析もやめる
                self?.cancel()
            }
            continuedHandle = handle
        }
    }

    private func finishBackgroundSupport(success: Bool) {
        MainActor.assumeIsolated {
            if let handle = continuedHandle {
                continuedHandle = nil
                handle.finish(success: success)
            }
            endBackgroundTask()
            IdleTimerGuard.set(false, for: idleTimerKey)
        }
    }

    @MainActor
    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

private func maskPanelPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// MARK: - マスク(共通の操作部)

/// マスクの形・大きさ・ぼかし・回転・反転。中心はスライダーとプレビュー上のドラッグの両方で変えられる
struct EditorMaskControls: View {
    @Binding var mask: MaskSettings
    /// 形の下に出す短い補足(無ければ出さない)
    var note: String? = nil

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
                EditorSectionTitle(title: String(localized: "形"))
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
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Group {
                    if !isBand {
                        EditorSliderRow(title: String(localized: "幅"),
                                        value: widthBinding,
                                        range: 0.05...2,
                                        display: maskPanelPercent(mask.width))
                    }
                    EditorSliderRow(title: isBand ? String(localized: "帯の幅") : String(localized: "高さ"),
                                    value: heightBinding,
                                    range: 0.05...2,
                                    display: maskPanelPercent(mask.height))
                    if !isBand {
                        HStack {
                            EditorChip(title: String(localized: "縦横を同じに"), isSelected: false) {
                                mask.height = mask.width
                            }
                            Spacer()
                        }
                    }
                    EditorSliderRow(title: String(localized: "境目のぼかし"),
                                    value: featherBinding,
                                    range: 0...0.3,
                                    display: maskPanelPercent(mask.feather))
                    EditorSliderRow(title: String(localized: "回転"),
                                    value: rotationBinding,
                                    range: -180...180,
                                    display: String(format: "%.0f°", mask.rotation))
                    if mask.shape == .roundedRectangle {
                        EditorSliderRow(title: String(localized: "角丸"),
                                        value: cornerBinding,
                                        range: 0...0.5,
                                        display: maskPanelPercent(mask.cornerRadius))
                    }
                }

                Group {
                    EditorSliderRow(title: String(localized: "横位置"),
                                    value: centerXBinding,
                                    range: 0...1,
                                    display: maskPanelPercent(mask.center.x))
                    EditorSliderRow(title: String(localized: "縦位置"),
                                    value: centerYBinding,
                                    range: 0...1,
                                    display: maskPanelPercent(mask.center.y))
                    Toggle("反転", isOn: invertedBinding)
                        .font(.subheadline)
                        .tint(.accentColor)
                }

                HStack {
                    EditorChip(title: String(localized: "リセット"), isSelected: false) {
                        let shape = mask.shape
                        var reset = MaskSettings()
                        reset.shape = shape
                        mask = reset
                    }
                    .disabled(isDefaultGeometry)
                    .opacity(isDefaultGeometry ? 0.4 : 1)
                    Spacer()
                    EditorChip(title: String(localized: "マスクを外す"), isSelected: false) {
                        mask = MaskSettings()
                    }
                }
            } else {
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
            EditorMaskControls(mask: maskBinding)
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
            EditorMaskControls(mask: maskBinding,
                               note: String(localized: "形の外は透明になります"))
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

    /// 効くかどうか。合成(VideoCompositor.reframeCrop)と同じ条件:
    /// 「埋める」か、画面と(回転・クロップ後の)映像の縦横比が 2% より違うとき
    private var isEffective: Bool {
        let snapshot = project.snapshot()
        if snapshot.canvas.scaling == .fill { return true }
        let canvas = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)
        var size = clip.displaySize
        if clip.geometry.rotationQuarterTurns % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        size.width *= CGFloat(clip.geometry.crop.width)
        size.height *= CGFloat(clip.geometry.crop.height)
        guard size.width > 0, size.height > 0, canvas.width > 0, canvas.height > 0 else { return true }
        let canvasAspect = canvas.width / canvas.height
        let imageAspect = size.width / size.height
        return abs(canvasAspect - imageAspect) / imageAspect > 0.02
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            if clip.isStill {
                Text("静止画では使えません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    EditorPillButton(title: hasTrack ? String(localized: "もう一度合わせる") : String(localized: "人物に合わせる"),
                                     systemImage: "person.crop.rectangle",
                                     prominent: true) {
                        analyze()
                    }
                    .disabled(analysis.isRunning)
                    .opacity(analysis.isRunning ? 0.5 : 1)
                    Spacer()
                    if hasTrack {
                        // 合わせる前と見比べるためのオン / オフ
                        Toggle(isOn: enabledBinding) {
                            Image(systemName: "person.and.background.dotted")
                                .font(.subheadline)
                        }
                        .fixedSize()
                        .tint(.accentColor)
                        .accessibilityLabel(String(localized: "オートリフレーム"))
                    }
                }

                if !isEffective {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("同じ比率のため動きません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        // 元のままの比率なら縦にして拡大、比率を決めてあれば拡大だけ
                        EditorChip(title: project.canvas.aspect == .original ? String(localized: "縦にする") : String(localized: "拡大にする"),
                                   isSelected: false) {
                            if project.canvas.aspect == .original { project.canvas.aspect = .portrait9x16 }
                            project.canvas.scaling = .fill
                        }
                    }
                }

                if hasTrack {
                    EditorSliderRow(title: String(localized: "なめらかさ"),
                                    value: smoothingBinding,
                                    range: 0...1,
                                    display: maskPanelPercent(clip.reframe.smoothing))
                    EditorSliderRow(title: String(localized: "ズーム"),
                                    value: zoomBinding,
                                    range: 1...2,
                                    display: String(format: "%.2fx", clip.reframe.zoom))
                }

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

                if hasTrack {
                    HStack {
                        Spacer()
                        EditorChip(title: String(localized: "リセット"), isSelected: false) {
                            clip.reframe = ReframeTrack()
                            message = nil
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func analyze() {
        let target = clip
        errorText = nil
        message = nil
        analysis.run(title: String(localized: "人物を探しています")) { report in
            let track = try await VisionReframe.analyze(clip: target, step: 0.25, progress: report)
            if Task.isCancelled { return }
            var merged = track
            merged.enabled = true
            merged.smoothing = clip.reframe.smoothing
            merged.zoom = clip.reframe.zoom
            clip.reframe = merged
            if track.samples.count < 2 {
                message = String(localized: "人物が見つかりませんでした")
            } else {
                message = nil
            }
        } onError: { error in
            errorText = String(localized: "調べられませんでした: \(error.localizedDescription)")
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
            Text("解析にはクリップと同じくらいの時間がかかります")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if clip.isStill {
                Text("静止画クリップでは使えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    EditorPillButton(title: hasTrack ? String(localized: "もう一度調べる") : String(localized: "揺れを調べる"),
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
                    Label("スタビライザーを使う", systemImage: "hand.raised.slash")
                        .font(.subheadline)
                }
                .tint(.accentColor)
                .disabled(!hasTrack)
                .opacity(hasTrack ? 1 : 0.4)

                EditorSliderRow(title: String(localized: "強さ"),
                                value: strengthBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.stabilization.strength))
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)
                EditorSliderRow(title: String(localized: "拡大"),
                                value: cropZoomBinding,
                                range: 1.0...1.3,
                                display: String(format: "%.2fx", clip.stabilization.cropZoom))
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)
                HStack {
                    Spacer()
                    EditorChip(title: String(localized: "リセット"), isSelected: false) {
                        clip.stabilization.strength = 0.8
                        clip.stabilization.cropZoom = 1.1
                    }
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)
                }

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
                }

                HStack {
                    Spacer()
                    EditorChip(title: String(localized: "調べた結果を消す"), isSelected: false) {
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
        analysis.run(title: String(localized: "揺れを調べています")) { report in
            let track = try await Stabilizer.analyze(clip: target, fps: 30, progress: report)
            if Task.isCancelled { return }
            var merged = track
            merged.enabled = true
            merged.strength = clip.stabilization.strength
            merged.cropZoom = max(clip.stabilization.cropZoom, track.cropZoom)
            clip.stabilization = merged
            if track.samples.count < 2 {
                message = String(localized: "揺れを調べられませんでした。映像が短すぎるか、動きが読み取れませんでした。")
            } else {
                message = String(localized: "調べ終わりました。再生して揺れの減り方を確認してください。")
            }
        } onError: { error in
            errorText = String(localized: "調べられませんでした: \(error.localizedDescription)")
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


            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: String(localized: "ノイズ除去"),
                                value: denoiseBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.enhance.denoise))
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: String(localized: "美肌"),
                                value: retouchBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.enhance.retouch))
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: String(localized: "ディテール強調"),
                                value: sharpenBinding,
                                range: 0...1,
                                display: maskPanelPercent(clip.enhance.sharpenUpscale))
            }

            HStack {
                Text("プレビューは重くなることがあります")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
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
                Label("3Dズーム", systemImage: "cube.transparent")
                    .font(.subheadline)
            }
            .tint(.accentColor)

            if let hasDepth {
                if hasDepth {
                } else {
                    Text("奥行きがない写真のため、ズーム・パンで動かします")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("奥行きの情報を確認中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "動きの向き"))
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

            EditorSliderRow(title: String(localized: "強さ"),
                            value: strengthBinding,
                            range: 0...1,
                            display: maskPanelPercent(parallax.strength))
                .disabled(!parallax.enabled)
                .opacity(parallax.enabled ? 1 : 0.4)

            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    parallax.strength = 0.5
                    parallax.direction = .zoomIn
                }
                .disabled(!parallax.enabled)
                .opacity(parallax.enabled ? 1 : 0.4)
            }

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
            if clip.isStill {
                EditorParallaxControls(parallax: parallaxBinding,
                                       imageURL: clip.stillImageURL ?? clip.url,
                                       durationSeconds: clip.outputDuration)
            } else {
                Text("「3Dズーム」は写真でのみ使えます。")
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
            if overlay.isImage {
                EditorParallaxControls(parallax: parallaxBinding,
                                       imageURL: overlay.url,
                                       durationSeconds: overlay.duration)
            } else {
                Text("重ねた写真で使えます")
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
                errorText = String(localized: "対象のテキストが見つかりません。")
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
                errorText = String(localized: "対象の重ねた素材が見つかりません。")
                return
            }
            itemStart = overlay.start
            itemEnd = overlay.end
            itemCenter = NormalizedPoint(x: overlay.frame.midX, y: overlay.frame.midY)
            itemScale = 1
            itemRotation = overlay.rotation
            itemOpacity = overlay.opacity
        }

        guard t >= itemStart - 0.001, t < itemEnd else {
            errorText = String(localized: "再生位置(中央の白い線)を、この部品が表示されている範囲に合わせてから囲んでください。")
            return
        }
        guard let location = project.locate(timelineTime: t), location.index < project.clips.count else {
            errorText = String(localized: "再生位置にクリップがありません。")
            return
        }
        let clip = project.clips[location.index]
        if clip.isStill {
            errorText = String(localized: "静止画クリップの上では動きを追跡できません。")
            return
        }
        if clip.isReversed {
            errorText = String(localized: "逆再生中のクリップでは追跡できません。いったん逆再生を解除してください。")
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
            errorText = String(localized: "追跡できる長さが短すぎます(部品の残り時間が 0.2 秒以上必要です)。")
            return
        }

        let snapshot = project.snapshot()
        let canvasSize = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)
        let scaling: ScalingMode = (snapshot.canvas.aspect == .original) ? .fit : snapshot.canvas.scaling
        let clipRect = PreviewTrackingMath.clipRect(clipSize: clip.displaySize, canvasSize: canvasSize, scaling: scaling)
        let sourceRect = PreviewTrackingMath.sourceRect(fromCanvas: rect, clipRect: clipRect, canvasSize: canvasSize)
        guard sourceRect.width > 0.005, sourceRect.height > 0.005 else {
            errorText = String(localized: "囲んだ範囲が映像の外です。映像の上で対象を囲んでください。")
            return
        }

        // 部品の中心と対象の中心のずれを保ったまま追いかける
        let offsetX = itemCenter.x - rect.midX
        let offsetY = itemCenter.y - rect.midY
        let itemOffset = max(0, t - itemStart)
        let baseOutput = ClipFXTimeline.outputOffset(sourceTime: sourceStart, clip: clip)
        let url = clip.url

        analysis.run(title: String(localized: "動きを追いかけています")) { [weak self] report in
            let tracked = try await MotionTracker.track(url: url,
                                                        start: sourceStart,
                                                        end: sourceEnd,
                                                        initialRect: sourceRect,
                                                        fps: 15,
                                                        progress: report)
            if Task.isCancelled { return }
            guard let self else { return }
            guard !tracked.isEmpty else {
                self.statusText = String(localized: "対象を追跡できませんでした。もう一度、対象をぴったり囲んでみてください。")
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
            self.statusText = String(localized: "\(seconds) 秒分を追従させました(キーフレーム \(keyframes.count) 個)")
        } onError: { [weak self] error in
            self?.errorText = String(localized: "追跡できませんでした: \(error.localizedDescription)")
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
            return isSticker ? String(localized: "ステッカー") : String(localized: "テキスト")
        case .overlay:
            return String(localized: "重ねた素材")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("プレビューで追いかけたい対象を指で囲みます")
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
                EditorChip(title: String(localized: "追従の動きを消す"), isSelected: false) {
                    clearKeyframes()
                }
                .disabled(keyframeCount == 0)
                .opacity(keyframeCount == 0 ? 0.4 : 1)
            }

            Text("クロップ・回転・オートリフレーム中のクリップではずれることがあります")
                .font(.caption)
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
        controller.statusText = String(localized: "追従の動きを消しました。")
    }
}
