import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Observation

// =====================================================================
// 第3弾: クリップの効果のための下部パネル
//   - EditorTransitionPanel    : トランジション(種類・長さ・全クリップに適用)
//   - EditorClipAnimationPanel : イン・アウトのアニメーション
//   - EditorGeometryPanel      : 切り抜き / 回転 / 反転 / ズーム
//   - EditorSpeedCurvePanel    : 速度カーブ(プリセット + ドラッグできるグラフ)
//   - EditorAudioEffectsPanel  : 音声効果(EQ・ピッチ・ボイス・ノイズ低減)。0.6 秒待ってから処理
//   - EditorBeatDetectPanel    : ビート検出(マーカー追加 / ビートで分割)
//   - EditorHSLPanel           : HSL(8 つの色相帯)
//   - EditorLUTPanel           : LUT(.cube の読み込みと強さ)
//   - EditorColorMatchPanel    : 色合わせ(基準クリップを選ぶ)
//   - ScopeSheetView           : スコープ(ヒストグラム・波形)
//   - ClipFXProgressOverlay    : 逆再生・フリーズなどの進捗表示
// =====================================================================

// MARK: - 進捗表示

/// 逆再生の作成・フリーズフレーム・音声抽出などの進み具合
struct ClipFXProgress: Equatable {
    var title: String
    /// 0...1。nil なら不定(くるくる)
    var fraction: Double?
}

/// 画面全体を覆う進捗表示(キャンセルつき)
struct ClipFXProgressOverlay: View {
    let progress: ClipFXProgress
    let onCancel: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            // AI が見ているコマと、ロボットの作業のアニメーション(AIWorkingOverlay.swift)
            AIWorkingCard(progress: progress, onCancel: onCancel)
        }
    }
}

// MARK: - タイムライン計算の補助

enum ClipFXTimeline {
    /// クリップの出力タイムライン上の範囲(トランジションの重なりを考慮)
    static func range(of clipID: UUID, in project: EditorProject) -> ClosedRange<Double>? {
        let layout = CompositionBuilder.timelineLayout(for: project.snapshot())
        if let placement = layout.first(where: { $0.clipID == clipID }) {
            return placement.start...max(placement.start, placement.end)
        }
        guard let start = project.clipTimelineStart(id: clipID),
              let clip = project.clips.first(where: { $0.id == clipID }) else { return nil }
        return start...(start + clip.outputDuration)
    }

    /// 元素材上の時刻 → クリップ先頭からの出力秒(速度・速度カーブを考慮)
    static func outputOffset(sourceTime: Double, clip: Clip) -> Double {
        let trimmed = clip.trimmedDuration
        let local = min(max(sourceTime - clip.startTime, 0), trimmed)
        if clip.speedCurve.enabled, trimmed > 0 {
            let n = 256
            let step = trimmed / Double(n)
            let count = min(n, Int((local / trimmed) * Double(n)))
            var total = 0.0
            for i in 0..<count {
                let p = (Double(i) + 0.5) / Double(n)
                total += step / clip.speedCurve.speed(at: p)
            }
            return total
        }
        return local / max(clip.speed, 0.01)
    }
}

/// 操作の下に出す 1 行の説明(やさしい言葉で)
private struct ClipFXHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func clipFXSeconds(_ value: Double) -> String {
    String(format: "%.1f 秒", value)
}

private func clipFXPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// MARK: - トランジション

struct EditorTransitionPanel: View {
    let project: EditorProject
    @Binding var clip: Clip
    var player: PlayerController? = nil

    @State private var showApplyAllConfirm = false

    private var isLast: Bool { project.clips.last?.id == clip.id }

    /// 前後のクリップの出力長の半分まで(0.2 ... 2.0)
    private var maxDuration: Double {
        guard let i = project.index(of: clip.id) else { return 2 }
        var limit = clip.outputDuration / 2
        if i + 1 < project.clips.count {
            limit = min(limit, project.clips[i + 1].outputDuration / 2)
        }
        return max(0.2, min(2, limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLast {
                Text("最後のクリップには次のクリップがないため、トランジションは使えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("トランジション: このクリップから次のクリップへの切り替わり方です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "種類"))
                TransitionTypePicker(selection: $clip.transition.type)
            }

            EditorSliderRow(title: String(localized: "長さ"),
                            value: $clip.transition.duration,
                            range: 0.2...2.0,
                            display: clipFXSeconds(clip.transition.duration))
                .disabled(clip.transition.type == .none)
                .opacity(clip.transition.type == .none ? 0.4 : 1)

            if clip.transition.duration > maxDuration + 0.001 {
                Text("※ 前後のクリップが短いため、実際には最大 \(clipFXSeconds(maxDuration)) になります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.transition = ClipTransition()
                }
                .disabled(clip.transition.type == .none)
                .opacity(clip.transition.type == .none ? 0.4 : 1)
                Spacer()
                EditorPillButton(title: String(localized: "全クリップに適用"), systemImage: "square.stack.3d.down.right", prominent: true) {
                    showApplyAllConfirm = true
                }
            }
        }
        .padding(.top, 6)
        // 選んでいる間は、切り替わりの 2 秒前から 2 秒後までをプレビューで繰り返し再生する
        .onAppear { updateLoop() }
        .onChange(of: clip.transition) { _, _ in updateLoop() }
        .onChange(of: player?.duration ?? 0) { _, _ in updateLoop() }
        .onDisappear { player?.stopLoop() }
        .confirmationDialog("このトランジションをすべてのクリップに使いますか?",
                            isPresented: $showApplyAllConfirm,
                            titleVisibility: .visible) {
            Button("全クリップに適用") {
                let transition = clip.transition
                for i in project.clips.indices {
                    project.clips[i].transition = transition
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
}

extension EditorTransitionPanel {
    /// 切り替わり(重なり)の 2 秒前〜2 秒後
    private var loopRange: ClosedRange<Double>? {
        guard !isLast else { return nil }
        let snapshot = project.snapshot()
        let layout = CompositionBuilder.timelineLayout(for: snapshot)
        guard let i = layout.firstIndex(where: { $0.clipID == clip.id }), i + 1 < layout.count else { return nil }
        let cutEnd = layout[i].end
        let cutStart = layout[i + 1].start
        let lower = max(0, min(cutStart, cutEnd) - 2)
        let upper = max(cutStart, cutEnd) + 2
        return lower...upper
    }

    fileprivate func updateLoop() {
        guard let player else { return }
        if let range = loopRange {
            player.startLoop(range)
        } else {
            player.stopLoop()
        }
    }
}

// MARK: - アニメーション(クリップ)

struct EditorClipAnimationPanel: View {
    @Binding var clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClipFXHint(text: String(localized: "アニメーション: クリップが始まるとき・終わるときの動きを選びます。"))

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "始まるとき"))
                ClipAnimationPicker(selection: Binding(get: { clip.animation.inType }, set: { clip.animation.inType = $0 }), isOut: false)
                EditorSliderRow(title: String(localized: "始まりの動きの時間"),
                                value: Binding(get: { clip.animation.inDuration }, set: { clip.animation.inDuration = $0 }),
                                range: 0.1...2.0,
                                display: clipFXSeconds(clip.animation.inDuration))
                    .disabled(clip.animation.inType == .none)
                    .opacity(clip.animation.inType == .none ? 0.4 : 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "終わるとき"))
                ClipAnimationPicker(selection: Binding(get: { clip.animation.outType }, set: { clip.animation.outType = $0 }), isOut: true)
                EditorSliderRow(title: String(localized: "終わりの動きの時間"),
                                value: Binding(get: { clip.animation.outDuration }, set: { clip.animation.outDuration = $0 }),
                                range: 0.1...2.0,
                                display: clipFXSeconds(clip.animation.outDuration))
                    .disabled(clip.animation.outType == .none)
                    .opacity(clip.animation.outType == .none ? 0.4 : 1)
            }

            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.animation = ClipAnimation()
                }
                .disabled(clip.animation.isIdentity)
                .opacity(clip.animation.isIdentity ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 切り抜き / 回転

struct EditorGeometryPanel: View {
    @Binding var clip: Clip

    private enum CropPreset: String, CaseIterable, Identifiable {
        case free, square, portrait4x5, portrait9x16, landscape16x9
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: return String(localized: "自由")
            case .square: return "1:1"
            case .portrait4x5: return "4:5"
            case .portrait9x16: return "9:16"
            case .landscape16x9: return "16:9"
            }
        }
        /// 幅 / 高さ。free は nil
        var aspect: Double? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .portrait4x5: return 4.0 / 5.0
            case .portrait9x16: return 9.0 / 16.0
            case .landscape16x9: return 16.0 / 9.0
            }
        }
    }

    /// 回転後の元映像のサイズ
    private var rotatedSourceSize: CGSize {
        let s = clip.displaySize
        if clip.geometry.rotationQuarterTurns % 2 == 1 {
            return CGSize(width: s.height, height: s.width)
        }
        return s
    }

    /// 回転後の映像の中央から、指定の縦横比で最大の範囲
    private func cropRect(for preset: CropPreset) -> NormalizedRect {
        guard let aspect = preset.aspect else { return .full }
        let src = rotatedSourceSize
        guard src.width > 0, src.height > 0 else { return .full }
        let srcAspect = Double(src.width / src.height)
        var w = 1.0
        var h = 1.0
        if srcAspect > aspect {
            w = aspect / srcAspect
        } else {
            h = srcAspect / aspect
        }
        return NormalizedRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func isSelected(_ preset: CropPreset) -> Bool {
        let target = cropRect(for: preset)
        let c = clip.geometry.crop
        let tolerance = 0.005
        return abs(c.x - target.x) <= tolerance && abs(c.y - target.y) <= tolerance
            && abs(c.width - target.width) <= tolerance && abs(c.height - target.height) <= tolerance
    }

    private var rotationText: String {
        "\((clip.geometry.rotationQuarterTurns % 4) * 90)°"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 回転・反転
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "回転・反転(いま \(rotationText))"))
                HStack(spacing: 8) {
                    EditorPillButton(title: String(localized: "左へ90°"), systemImage: "rotate.left") {
                        clip.geometry.rotationQuarterTurns = (clip.geometry.rotationQuarterTurns + 3) % 4
                    }
                    EditorPillButton(title: String(localized: "右へ90°"), systemImage: "rotate.right") {
                        clip.geometry.rotationQuarterTurns = (clip.geometry.rotationQuarterTurns + 1) % 4
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    EditorChip(title: String(localized: "左右反転"), isSelected: clip.geometry.flipHorizontal) {
                        clip.geometry.flipHorizontal.toggle()
                    }
                    EditorChip(title: String(localized: "上下反転"), isSelected: clip.geometry.flipVertical) {
                        clip.geometry.flipVertical.toggle()
                    }
                    Spacer()
                }
            }

            // 切り抜き
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "切り抜き(縦横の比率)"))
                ClipFXHint(text: String(localized: "映像の一部を切り取ります。9:16 は縦長、16:9 は横長です。"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CropPreset.allCases) { preset in
                            EditorChip(title: preset.title, isSelected: isSelected(preset)) {
                                clip.geometry.crop = cropRect(for: preset)
                            }
                        }
                    }
                }
            }

            // ズーム・位置
            EditorSliderRow(title: String(localized: "ズーム"),
                            value: $clip.geometry.zoom,
                            range: 1...4,
                            display: String(format: "%.2fx", clip.geometry.zoom))
            EditorSliderRow(title: String(localized: "横の位置(左 ← → 右)"),
                            value: $clip.geometry.offsetX,
                            range: -0.5...0.5,
                            display: String(format: "%+.2f", clip.geometry.offsetX))
            EditorSliderRow(title: String(localized: "縦の位置(上 ← → 下)"),
                            value: $clip.geometry.offsetY,
                            range: -0.5...0.5,
                            display: String(format: "%+.2f", clip.geometry.offsetY))

            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.geometry = ClipGeometry()
                }
                .disabled(clip.geometry.isIdentity)
                .opacity(clip.geometry.isIdentity ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 速度カーブ

struct EditorSpeedCurvePanel: View {
    @Binding var clip: Clip

    private let presets: [(title: String, curve: SpeedCurve)] = [
        (String(localized: "速く→ゆっくり→速く"), SpeedCurve.montage),
        (String(localized: "途中をスローに"), SpeedCurve.hero),
        (String(localized: "一瞬だけ止まる"), SpeedCurve.bullet),
        (String(localized: "始めだけ速く"), SpeedCurve.flashIn),
        (String(localized: "終わりだけ速く"), SpeedCurve.flashOut)
    ]

    private var enabledBinding: Binding<Bool> {
        Binding<Bool>(
            get: { clip.speedCurve.enabled },
            set: { newValue in
                var curve = clip.speedCurve
                curve.enabled = newValue
                if newValue, curve.points.count < 3 {
                    // 等速(2点)から始めるときは、ドラッグできるよう 5 点に増やす
                    var probe = curve
                    probe.enabled = true
                    curve.points = [0, 0.25, 0.5, 0.75, 1].map { SpeedPoint(position: $0, speed: probe.speed(at: $0)) }
                }
                clip.speedCurve = curve
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: enabledBinding) {
                Label("速度カーブを使う", systemImage: "waveform.path.ecg")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            ClipFXHint(text: String(localized: "クリップの途中で速さを変えます(ゆっくり→速く など)。"))

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "おすすめの変え方"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.title) { preset in
                            EditorChip(title: preset.title,
                                       isSelected: clip.speedCurve.enabled && clip.speedCurve.points == preset.curve.points) {
                                var curve = preset.curve
                                curve.smoothSlow = clip.speedCurve.smoothSlow
                                clip.speedCurve = curve
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSectionTitle(title: String(localized: "速さのグラフ(点をドラッグ: 上で速く、下で遅く)"))
                SpeedCurveGraphView(points: $clip.speedCurve.points, isEnabled: clip.speedCurve.enabled)
            }

            Toggle("スローの部分をなめらかに見せる", isOn: $clip.speedCurve.smoothSlow)
                .font(.subheadline)
                .tint(.accentColor)
                .disabled(!clip.speedCurve.enabled)
                .opacity(clip.speedCurve.enabled ? 1 : 0.4)

            HStack {
                Text("長さ \(MediaTimeText.precise(clip.trimmedDuration)) → \(MediaTimeText.precise(clip.outputDuration))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.speedCurve = SpeedCurve()
                }
                .disabled(!clip.speedCurve.enabled)
                .opacity(clip.speedCurve.enabled ? 1 : 0.4)
            }
        }
        .padding(.top, 6)
    }
}

/// 速度カーブのグラフ(Canvas)。点をドラッグして速度(縦・対数)と位置(横)を変える
struct SpeedCurveGraphView: View {
    @Binding var points: [SpeedPoint]
    let isEnabled: Bool

    @State private var dragIndex: Int? = nil

    private let minSpeed = 0.1
    private let maxSpeed = 10.0
    private let inset: CGFloat = 12

    private func yFraction(_ speed: Double) -> CGFloat {
        let s = min(max(speed, minSpeed), maxSpeed)
        return CGFloat((log(s) - log(minSpeed)) / (log(maxSpeed) - log(minSpeed)))
    }

    private func speed(forYFraction f: CGFloat) -> Double {
        let t = Double(min(max(f, 0), 1))
        return exp(log(minSpeed) + t * (log(maxSpeed) - log(minSpeed)))
    }

    private func location(of point: SpeedPoint, in size: CGSize) -> CGPoint {
        let w = max(size.width - inset * 2, 1)
        let h = max(size.height - inset * 2, 1)
        return CGPoint(x: inset + CGFloat(min(max(point.position, 0), 1)) * w,
                       y: inset + (1 - yFraction(point.speed)) * h)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, _ in
                let w = max(size.width - inset * 2, 1)
                let h = max(size.height - inset * 2, 1)

                // 目安の横線
                for guide in [0.25, 0.5, 1.0, 2.0, 4.0] {
                    let y = inset + (1 - yFraction(guide)) * h
                    var line = Path()
                    line.move(to: CGPoint(x: inset, y: y))
                    line.addLine(to: CGPoint(x: inset + w, y: y))
                    let isUnit = guide == 1.0
                    context.stroke(line,
                                   with: .color(Color.white.opacity(isUnit ? 0.35 : 0.12)),
                                   style: StrokeStyle(lineWidth: 1, dash: isUnit ? [] : [3, 3]))
                    let label = Text(String(format: guide < 1 ? "%.2gx" : "%.0fx", guide))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: inset + w - 2, y: y - 6), anchor: .trailing)
                }

                // 折れ線
                var path = Path()
                for (i, point) in points.enumerated() {
                    let loc = location(of: point, in: size)
                    if i == 0 { path.move(to: loc) } else { path.addLine(to: loc) }
                }
                context.stroke(path, with: .color(isEnabled ? Color.white : Color.gray), lineWidth: 2)

                // 点
                for (i, point) in points.enumerated() {
                    let loc = location(of: point, in: size)
                    let r: CGFloat = dragIndex == i ? 9 : 7
                    let circle = Path(ellipseIn: CGRect(x: loc.x - r, y: loc.y - r, width: r * 2, height: r * 2))
                    context.fill(circle, with: .color(dragIndex == i ? Color.accentColor : Color.white))
                    context.stroke(circle, with: .color(Color.black.opacity(0.6)), lineWidth: 1)
                    let speedLabel = Text(String(format: "%.2gx", point.speed))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                    context.draw(speedLabel, at: CGPoint(x: loc.x, y: loc.y - 14), anchor: .center)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        handleDrag(value.location, size: size)
                    }
                    .onEnded { _ in
                        dragIndex = nil
                    }
            )
        }
        .frame(height: 150)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
    }

    private func handleDrag(_ loc: CGPoint, size: CGSize) {
        if dragIndex == nil {
            var best: Int? = nil
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (i, point) in points.enumerated() {
                let p = location(of: point, in: size)
                let d = hypot(loc.x - p.x, loc.y - p.y)
                if d < bestDistance {
                    bestDistance = d
                    best = i
                }
            }
            guard let best, bestDistance <= 40 else { return }
            dragIndex = best
        }
        guard let i = dragIndex, points.indices.contains(i) else { return }
        let w = max(size.width - inset * 2, 1)
        let h = max(size.height - inset * 2, 1)
        var point = points[i]
        let yf = 1 - (loc.y - inset) / h
        point.speed = (speed(forYFraction: yf) * 100).rounded() / 100
        if i > 0 && i < points.count - 1 {
            let lower = points[i - 1].position + 0.02
            let upper = points[i + 1].position - 0.02
            let x = Double((loc.x - inset) / w)
            point.position = min(max(x, lower), max(lower, upper))
        } else if i == 0 {
            point.position = 0
        } else {
            point.position = 1
        }
        points[i] = point
    }
}

// MARK: - 音声効果(クリップ / ナレーション共通)

/// EQ・ピッチ・ボイスプリセット・ノイズ低減。
/// スライダーはローカルの下書きを動かし、0.6 秒止まったら AudioEffectsRenderer で処理してから
/// 本体(Binding)に書き込む(書き込みで再生プレビューが作り直される)。
struct EditorAudioEffectsPanel: View {
    /// 処理する音声ファイル(クリップの url / ナレーションの url)
    let url: URL
    let name: String
    @Binding var effects: AudioEffects

    @State private var draft = AudioEffects()
    @State private var didLoad = false
    @State private var isProcessing = false
    @State private var errorText: String?
    @State private var debounceTask: Task<Void, Never>?

    private func db(_ value: Double) -> String {
        if abs(value) < 0.05 { return String(localized: "そのまま") }
        let amount = String(format: "%.1f", abs(value))
        return value > 0 ? String(localized: "強め +\(amount)") : String(localized: "弱め -\(amount)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("処理中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ClipFXHint(text: String(localized: "音声効果: 声を変えたり、低い音・高い音の強さを変えたりします。"))

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "声の変化"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(VoicePreset.allCases) { preset in
                            EditorChip(title: preset.displayName, isSelected: draft.voicePreset == preset) {
                                draft.voicePreset = preset
                            }
                        }
                    }
                }
            }

            EditorSliderRow(title: String(localized: "低い音(ドンドン)"), value: $draft.eqLow, range: -12...12, display: db(draft.eqLow))
            EditorSliderRow(title: String(localized: "中くらいの音(声)"), value: $draft.eqMid, range: -12...12, display: db(draft.eqMid))
            EditorSliderRow(title: String(localized: "高い音(シャカシャカ)"), value: $draft.eqHigh, range: -12...12, display: db(draft.eqHigh))
            EditorSliderRow(title: String(localized: "音の高さ(+1 で半音上がる)"),
                            value: $draft.pitchSemitones,
                            range: -12...12,
                            display: String(format: "%+.1f", draft.pitchSemitones))
            EditorSliderRow(title: String(localized: "スピーチを強調(AI)"),
                            value: $draft.noiseReduction,
                            range: 0...1,
                            display: clipFXPercent(draft.noiseReduction))

            HStack {
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("変えると、少しして音に反映されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    draft = AudioEffects()
                }
                .disabled(draft.isIdentity)
                .opacity(draft.isIdentity ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
        .onAppear {
            if !didLoad {
                didLoad = true
                draft = effects
            }
        }
        .onChange(of: draft) { _, newValue in
            schedule(newValue)
        }
        .onDisappear {
            // 閉じたときに未反映の変更があれば、待たずに反映する
            debounceTask?.cancel()
            debounceTask = nil
            let pending = draft
            if pending != effects {
                Task { @MainActor in
                    await commit(pending)
                }
            }
        }
    }

    private func schedule(_ newValue: AudioEffects) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await commit(newValue)
        }
    }

    @MainActor
    private func commit(_ newValue: AudioEffects) async {
        if newValue == effects { return }
        if newValue.isIdentity {
            effects = newValue
            return
        }
        isProcessing = true
        errorText = nil
        do {
            _ = try await AudioEffectsRenderer.processedURL(for: url, effects: newValue)
            effects = newValue
        } catch is CancellationError {
            // 何もしない
        } catch {
            errorText = String(localized: "音声効果を反映できませんでした。もう一度お試しください(\(error.localizedDescription))")
        }
        isProcessing = false
    }
}

// MARK: - ビート検出

struct EditorBeatDetectPanel: View {
    let project: EditorProject
    let history: EditorHistory
    let clipID: UUID

    @State private var sensitivity: Double = 0.5
    @State private var isRunning = false
    /// 検出したビート(元素材上の秒)
    @State private var beats: [Double] = []
    @State private var bpm: Double?
    @State private var message: String?
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private var clip: Clip? { project.clips.first(where: { $0.id == clipID }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ビートに合わせる: 音楽の拍(ビート)を見つけて、タイムラインにマーカーを付けます。マーカーの位置で分割もできます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            EditorSliderRow(title: String(localized: "感度(高いほど多く見つける)"),
                            value: $sensitivity,
                            range: 0.1...1.0,
                            display: clipFXPercent(sensitivity))
                .disabled(isRunning)
            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    sensitivity = 0.5
                }
                .disabled(isRunning)
            }

            HStack(spacing: 10) {
                EditorPillButton(title: isRunning ? String(localized: "探しています…") : String(localized: "ビートを探す"), systemImage: "metronome", prominent: true) {
                    detect()
                }
                .disabled(isRunning || clip == nil || !(clip?.hasAudio ?? false))
                .opacity(isRunning ? 0.6 : 1)

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Button {
                        task?.cancel()
                    } label: {
                        Text("キャンセル")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if let clip, !clip.hasAudio {
                Text("このクリップには音声がありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            if !beats.isEmpty {
                HStack(spacing: 10) {
                    EditorPillButton(title: String(localized: "ビートの位置で分割"), systemImage: "square.split.2x1") {
                        splitAtBeats()
                    }
                    EditorPillButton(title: String(localized: "ビートのマーカーを消す"), systemImage: "flag.slash") {
                        removeBeatMarkers()
                    }
                    Spacer()
                }
            }
        }
        .padding(.top, 6)
        .onDisappear {
            task?.cancel()
        }
    }

    private func detect() {
        guard let clip else { return }
        task?.cancel()
        isRunning = true
        errorText = nil
        message = nil
        let url = clip.url
        let start = clip.startTime
        let end = clip.endTime
        let sens = sensitivity
        task = Task { @MainActor in
            do {
                let found = try await BeatDetector.detectBeats(url: url, start: start, end: end, sensitivity: sens)
                if Task.isCancelled {
                    isRunning = false
                    return
                }
                beats = found.sorted()
                bpm = BeatDetector.estimateBPM(onsets: beats)
                addMarkers(sourceBeats: beats)
                var text = String(localized: "\(beats.count) 個のビートを見つけてマーカーを付けました。")
                if let bpm, bpm.isFinite, bpm > 0 {
                    text += String(localized: "(テンポ: 1分間に約 \(Int(bpm.rounded())) 拍)")
                }
                message = text
            } catch is CancellationError {
                message = String(localized: "キャンセルしました。")
            } catch {
                if !Task.isCancelled {
                    errorText = String(localized: "ビートを見つけられませんでした。もう一度お試しください(\(error.localizedDescription))")
                }
            }
            isRunning = false
        }
    }

    /// このクリップの範囲にある古いビートマーカーを消して、新しいビートを追加する
    private func addMarkers(sourceBeats: [Double]) {
        guard let clip, let range = ClipFXTimeline.range(of: clipID, in: project) else { return }
        history.record(project)
        project.markers.removeAll {
            $0.kind == .beat && $0.time >= range.lowerBound - 0.01 && $0.time <= range.upperBound + 0.01
        }
        for beat in sourceBeats {
            let t = range.lowerBound + ClipFXTimeline.outputOffset(sourceTime: beat, clip: clip)
            if t <= range.upperBound + 0.01 {
                project.markers.append(TimelineMarker(time: t, name: "", kind: .beat))
            }
        }
        project.sortMarkers()
    }

    private func removeBeatMarkers() {
        guard let range = ClipFXTimeline.range(of: clipID, in: project) else { return }
        history.record(project)
        project.markers.removeAll {
            $0.kind == .beat && $0.time >= range.lowerBound - 0.01 && $0.time <= range.upperBound + 0.01
        }
        message = String(localized: "ビートのマーカーを消しました。")
    }

    /// ビート(元素材上の秒)ごとにクリップを分割する。0.25 秒より近いビートは飛ばす
    private func splitAtBeats() {
        guard !beats.isEmpty else { return }
        history.record(project)
        var currentID = clipID
        var lastSplit = -Double.infinity
        var count = 0
        for beat in beats.sorted() {
            if beat - lastSplit < 0.25 { continue }
            guard let idx = project.index(of: currentID) else { break }
            let piece = project.clips[idx]
            guard beat > piece.startTime + 0.2, beat < piece.endTime - 0.2 else { continue }
            if project.splitClip(id: currentID, atSourceTime: beat) {
                count += 1
                lastSplit = beat
                if let newIdx = project.index(of: currentID), newIdx + 1 < project.clips.count {
                    currentID = project.clips[newIdx + 1].id
                }
            }
        }
        message = count > 0 ? String(localized: "\(count) か所でスプリットしました。") : String(localized: "スプリットできる位置がありませんでした。")
    }
}

// MARK: - HSL

struct EditorHSLPanel: View {
    @Binding var clip: Clip

    @State private var band: Int = 0

    private var bandBinding: Binding<HSLBand> {
        Binding<HSLBand>(
            get: {
                let bands = clip.filter.hsl.bands
                return bands.indices.contains(band) ? bands[band] : HSLBand()
            },
            set: { newValue in
                var hsl = clip.filter.hsl
                if hsl.bands.count < 8 {
                    hsl.bands = Array(repeating: HSLBand(), count: 8)
                }
                if hsl.bands.indices.contains(band) {
                    hsl.bands[band] = newValue
                }
                clip.filter.hsl = hsl
            }
        )
    }

    private func bandColor(_ index: Int) -> Color {
        Color(hue: Double(index) / 8.0, saturation: 0.85, brightness: 0.95)
    }

    private func isBandIdentity(_ index: Int) -> Bool {
        let bands = clip.filter.hsl.bands
        return bands.indices.contains(index) ? bands[index].isIdentity : true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "調整する色"))
                ClipFXHint(text: String(localized: "HSL: 選んだ色だけ、色味・彩度・明るさを変えます(例: 空の青だけ濃くする)。"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<8, id: \.self) { index in
                            let name = HSLAdjustment.bandNames.indices.contains(index) ? HSLAdjustment.bandNames[index] : "\(index)"
                            Button {
                                EditorHaptics.tap()
                                band = index
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(bandColor(index))
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Circle()
                                                .stroke(band == index ? Color.white : Color.clear, lineWidth: 3)
                                                .padding(-3)
                                        )
                                        .overlay(alignment: .topTrailing) {
                                            if !isBandIdentity(index) {
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 7, height: 7)
                                                    .offset(x: 2, y: -2)
                                            }
                                        }
                                    Text(name)
                                        .font(.caption2)
                                        .foregroundStyle(band == index ? Color.white : Color.secondary)
                                }
                                .frame(width: 44)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            EditorSliderRow(title: String(localized: "色味(となりの色へずらす)"),
                            value: bandBinding.hue,
                            range: -1...1,
                            display: String(format: "%+.2f", bandBinding.wrappedValue.hue))
            EditorSliderRow(title: String(localized: "彩度"),
                            value: bandBinding.saturation,
                            range: -1...1,
                            display: String(format: "%+.2f", bandBinding.wrappedValue.saturation))
            EditorSliderRow(title: String(localized: "明るさ"),
                            value: bandBinding.luminance,
                            range: -1...1,
                            display: String(format: "%+.2f", bandBinding.wrappedValue.luminance))

            HStack(spacing: 8) {
                EditorChip(title: String(localized: "この色をリセット"), isSelected: false) {
                    bandBinding.wrappedValue = HSLBand()
                }
                .disabled(isBandIdentity(band))
                .opacity(isBandIdentity(band) ? 0.4 : 1)
                Spacer()
                EditorChip(title: String(localized: "すべてリセット"), isSelected: false) {
                    clip.filter.hsl = HSLAdjustment()
                }
                .disabled(clip.filter.hsl.isIdentity)
                .opacity(clip.filter.hsl.isIdentity ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - LUT

struct EditorLUTPanel: View {
    @Binding var clip: Clip

    @State private var names: [String] = []
    @State private var showImporter = false
    @State private var errorText: String?

    private var cubeTypes: [UTType] {
        var types: [UTType] = []
        if let cube = UTType(filenameExtension: "cube") { types.append(cube) }
        types.append(.plainText)
        types.append(.data)
        return types
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LUT読み込み: 映画風などの「色の設定ファイル(.cube)」を読み込んで、その色合いに仕上げます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "読み込んだ色"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        EditorChip(title: String(localized: "なし"), isSelected: clip.filter.lutFileName == nil) {
                            clip.filter.lutFileName = nil
                        }
                        ForEach(names, id: \.self) { name in
                            EditorChip(title: displayName(name), isSelected: clip.filter.lutFileName == name) {
                                clip.filter.lutFileName = name
                                if clip.filter.lutIntensity <= 0 { clip.filter.lutIntensity = 1 }
                            }
                        }
                    }
                }
                if names.isEmpty {
                    Text("まだ読み込んでいません。下のボタンからファイルを選んでください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            EditorSliderRow(title: String(localized: "強さ"),
                            value: $clip.filter.lutIntensity,
                            range: 0...1,
                            display: clipFXPercent(clip.filter.lutIntensity))
                .disabled(clip.filter.lutFileName == nil)
                .opacity(clip.filter.lutFileName == nil ? 0.4 : 1)

            HStack {
                EditorPillButton(title: String(localized: "ファイル(.cube)を読み込む"), systemImage: "square.and.arrow.down") {
                    showImporter = true
                }
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.filter.lutFileName = nil
                    clip.filter.lutIntensity = 1
                }
                .disabled(clip.filter.lutFileName == nil)
                .opacity(clip.filter.lutFileName == nil ? 0.4 : 1)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .onAppear {
            names = MediaTools.storedLUTNames()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: cubeTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let name = try MediaTools.importLUT(from: url)
                    names = MediaTools.storedLUTNames()
                    clip.filter.lutFileName = name
                    if clip.filter.lutIntensity <= 0 { clip.filter.lutIntensity = 1 }
                    errorText = nil
                } catch {
                    errorText = String(localized: "色の設定ファイルを読み込めませんでした。.cube ファイルか確認してください(\(error.localizedDescription))")
                }
            case .failure(let error):
                errorText = String(localized: "色の設定ファイルを読み込めませんでした。もう一度お試しください(\(error.localizedDescription))")
            }
        }
    }

    private func displayName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }
}

// MARK: - 色合わせ

struct EditorColorMatchPanel: View {
    let project: EditorProject
    @Binding var clip: Clip

    @State private var selectedReference: UUID?
    @State private var isWorking = false
    @State private var errorText: String?

    private var candidates: [Clip] {
        project.clips.filter { $0.id != clip.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("色合わせ: お手本にするクリップをタップすると、明るさ・彩度・色味をそのクリップに近づけます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                Text("ほかのクリップがありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(candidates) { candidate in
                            Button {
                                EditorHaptics.tap()
                                match(to: candidate)
                            } label: {
                                VStack(spacing: 4) {
                                    ZStack {
                                        Color.black
                                        if let image = candidate.thumbnail {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            Image(systemName: "film")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedReference == candidate.id ? Color.yellow : Color.clear, lineWidth: 3)
                                    )
                                    Text(candidate.name)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .foregroundStyle(selectedReference == candidate.id ? Color.yellow : Color.white)
                                }
                                .frame(width: 78)
                            }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("色を合わせています…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if selectedReference != nil {
                    Text("色調整に反映しました。「色調整」でさらに微調整できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.filter.adjustments = ColorAdjustments()
                    selectedReference = nil
                }
                .disabled(clip.filter.adjustments.isIdentity)
                .opacity(clip.filter.adjustments.isIdentity ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }

    private func match(to reference: Clip) {
        isWorking = true
        errorText = nil
        let source = clip
        Task { @MainActor in
            let referenceImage = await thumbnail(for: reference)
            let sourceImage = await thumbnail(for: source)
            guard let referenceImage, let sourceImage else {
                errorText = String(localized: "映像の色を読み取れませんでした。もう一度お試しください。")
                isWorking = false
                return
            }
            let adjustments = FilterEngine.suggestedAdjustments(toMatch: referenceImage, from: sourceImage)
            clip.filter.adjustments = adjustments
            selectedReference = reference.id
            isWorking = false
        }
    }

    private func thumbnail(for target: Clip) async -> UIImage? {
        if let image = target.thumbnail { return image }
        if let still = target.stillImageURL {
            return MediaStore.makeImageClipThumbnail(url: still, maxPixel: 320)
        }
        return await MediaStore.thumbnail(for: target.url, at: target.startTime, maxPixel: 320)
    }
}

// MARK: - スコープ(ヒストグラム・波形)

struct ScopeSheetView: View {
    let player: PlayerController
    let clip: Clip?

    @Environment(\.dismiss) private var dismiss

    @State private var frameImage: UIImage?
    @State private var histogram: [Float] = []
    @State private var waveform: [[Float]] = []
    @State private var meanR: Float = 0
    @State private var meanG: Float = 0
    @State private var meanB: Float = 0
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    frameSection
                    histogramSection
                    waveformSection
                    meansSection
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Lumetri スコープ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task { await capture() }
                    } label: {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                await capture()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 表示

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("再生位置 \(MediaTimeText.precise(player.currentTime)) の画面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            ZStack {
                Color.white.opacity(0.06)
                if let frameImage {
                    Image(uiImage: frameImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var histogramSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("明るさの分布(左が暗い、右が明るい)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ClipFXHint(text: String(localized: "右端に山があると白く飛び、左端に山があると黒くつぶれています。"))
            Canvas { context, size in
                let values = histogram
                guard !values.isEmpty else { return }
                let maxValue = max(values.max() ?? 1, 0.0001)
                let barWidth = size.width / CGFloat(values.count)
                for (i, v) in values.enumerated() {
                    let h = CGFloat(v / maxValue) * (size.height - 4)
                    let rect = CGRect(x: CGFloat(i) * barWidth, y: size.height - h, width: max(barWidth - 1, 1), height: h)
                    context.fill(Path(rect), with: .color(Color.white.opacity(0.85)))
                }
            }
            .frame(height: 120)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("場所ごとの明るさ(横: 画面の左右、縦: 明るさ)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                let columns = waveform
                guard !columns.isEmpty else { return }
                var maxValue: Float = 0.0001
                for column in columns {
                    for v in column where v > maxValue { maxValue = v }
                }
                let cellW = size.width / CGFloat(columns.count)
                for (ci, column) in columns.enumerated() {
                    guard !column.isEmpty else { continue }
                    let cellH = size.height / CGFloat(column.count)
                    for (ri, v) in column.enumerated() {
                        let alpha = Double(min(max(v / maxValue, 0), 1))
                        guard alpha > 0.01 else { continue }
                        // row 0 = 暗い(下)、最後 = 明るい(上)
                        let rect = CGRect(x: CGFloat(ci) * cellW,
                                          y: size.height - CGFloat(ri + 1) * cellH,
                                          width: ceil(cellW),
                                          height: ceil(cellH))
                        context.fill(Path(rect), with: .color(Color.green.opacity(0.15 + alpha * 0.85)))
                    }
                }
            }
            .frame(height: 140)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var meansSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("色の平均(赤・緑・青)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                meanLabel(String(localized: "赤"), meanR, .red)
                meanLabel(String(localized: "緑"), meanG, .green)
                meanLabel(String(localized: "青"), meanB, .blue)
                Spacer()
            }
        }
    }

    private func meanLabel(_ name: String, _ value: Float, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(name) \(Int((min(max(Double(value), 0), 1) * 100).rounded()))%")
                .font(.callout)
                .monospacedDigit()
        }
    }

    // MARK: 取得

    @MainActor
    private func capture() async {
        isLoading = true
        errorText = nil
        var cgImage: CGImage? = nil

        // いまのプレビュー(合成後)のコマ
        if let item = player.player.currentItem {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.videoComposition = item.videoComposition
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: max(0, player.currentTime), preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                cgImage = result.image
            }
        }

        // 取れなければクリップのサムネイル
        if cgImage == nil, let clip {
            if let still = clip.stillImageURL {
                cgImage = MediaStore.makeImageClipThumbnail(url: still, maxPixel: 480)?.cgImage
            } else {
                let location = clip.startTime
                cgImage = await MediaStore.thumbnail(for: clip.url, at: location, maxPixel: 480)?.cgImage
            }
        }

        guard let cgImage else {
            errorText = String(localized: "画面を読み取れませんでした。再生位置を動かしてもう一度お試しください。")
            isLoading = false
            return
        }

        frameImage = UIImage(cgImage: cgImage)
        histogram = ScopeAnalyzer.luminanceHistogram(cgImage, bins: 64)
        waveform = ScopeAnalyzer.waveform(cgImage, columns: 64, rows: 32)
        let means = ScopeAnalyzer.rgbMeans(cgImage)
        meanR = means.r
        meanG = means.g
        meanB = means.b
        isLoading = false
    }
}
