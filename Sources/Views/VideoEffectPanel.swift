import SwiftUI

// =====================================================================
// 映像エフェクトのパネル。
// ・EditorVideoEffectAddPanel: ルートの「映像エフェクト」から開く。見本をタップすると再生位置に追加する
// ・EditorVideoEffectPanel: タイムラインで選んだエフェクトの種類・強さを変える(開いている間は区間を繰り返し再生)
// 見本は SwiftUI だけで描く小さな動く絵(実際の描画は Engine/VideoEffectRenderer.swift)。
// =====================================================================

/// エフェクトの種類を分類ごとの横一列で並べる
struct VideoEffectTypeGrid: View {
    /// 選んでいる種類(追加パネルでは nil)
    let selection: VideoEffectType?
    let onPick: (VideoEffectType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(VideoEffectCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 4) {
                    EditorSectionTitle(title: category.displayName)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(category.types) { type in
                                EditorVisualTile(title: type.displayName, isSelected: selection == type) {
                                    onPick(type)
                                } preview: {
                                    VideoEffectPreview(type: type)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

/// ルートの「映像エフェクト」: 選ぶと再生位置に追加する
struct EditorVideoEffectAddPanel: View {
    let onPick: (VideoEffectType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClipFXHint(text: String(localized: "選ぶと再生位置から3秒かかります。長さはタイムラインで変えられます。"))
            VideoEffectTypeGrid(selection: nil, onPick: onPick)
        }
        .padding(.top, 6)
    }
}

/// 選んだエフェクトの種類・強さ
struct EditorVideoEffectPanel: View {
    @Binding var effect: VideoEffectClip
    /// 動画全体の長さ(「動画全体にかける」に使う)
    let totalDuration: Double
    var player: PlayerController? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if effect.type.usesIntensity {
                EditorSliderRow(title: String(localized: "強さ"),
                                value: $effect.intensity,
                                range: 0.05...1.0,
                                display: "\(Int((effect.intensity * 100).rounded()))%")
            }
            HStack(spacing: 8) {
                EditorChip(title: String(localized: "動画全体にかける"),
                           isSelected: effect.start < 0.01 && abs(effect.end - totalDuration) < 0.05) {
                    guard totalDuration > 0.3 else { return }
                    effect.start = 0
                    effect.duration = totalDuration
                }
                Spacer(minLength: 0)
                Text(EditorTimeFormat.tenths(effect.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            VideoEffectTypeGrid(selection: effect.type) { type in
                guard type != effect.type else { return }
                effect.type = type
            }
        }
        .padding(.top, 6)
        .onAppear { updateLoop() }
        .onChange(of: effect.start) { _, _ in updateLoop() }
        .onChange(of: effect.duration) { _, _ in updateLoop() }
        .onDisappear { player?.stopLoop() }
    }

    /// エフェクトの区間を繰り返し再生する(長いときは先頭の 4 秒)
    private func updateLoop() {
        guard let player else { return }
        let start = max(0, effect.start)
        let end = start + min(max(effect.duration, 0.3), 4)
        player.startLoop(start...end)
    }
}

// MARK: - 動く見本

/// 見本タイルの中の絵(縦長の小さな画面)
struct VideoEffectPreview: View {
    let type: VideoEffectType
    @Environment(\.visualTileAnimating) private var isAnimating

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if isAnimating {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 600)
                    tile(t: t, w: w, h: h)
                }
            } else {
                tile(t: 0.62, w: w, h: h)
            }
        }
    }

    private func tile(t: Double, w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            Color.black
            content(t: t, w: w, h: h)
        }
        .frame(width: w, height: h)
        .clipped()
    }

    @ViewBuilder
    private func content(t: Double, w: CGFloat, h: CGFloat) -> some View {
        switch type.category {
        case .motion: motionContent(t: t, w: w, h: h)
        case .retro: retroContent(t: t, w: w, h: h)
        case .light: lightContent(t: t, w: w, h: h)
        case .blur, .color: blurColorContent(t: t, w: w, h: h)
        case .screen: screenContent(t: t, w: w, h: h)
        }
    }

    private var sample: EffectPreviewSample { EffectPreviewSample() }

    private static func beatDecay(_ t: Double, rate: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: VideoEffectRenderer.beatPeriod) / VideoEffectRenderer.beatPeriod
        return exp(-phase * rate)
    }

    @ViewBuilder
    private func motionContent(t: Double, w: CGFloat, h: CGFloat) -> some View {
        switch type {
        case .shake:
            sample.scaleEffect(1.12)
                .offset(x: CGFloat(3 * sin(t * 41)), y: CGFloat(3 * cos(t * 37)))
        case .zoomPulse:
            sample.scaleEffect(CGFloat(1 + 0.2 * Self.beatDecay(t, rate: 5)))
        case .beatShake:
            let d = Self.beatDecay(t, rate: 7)
            sample.scaleEffect(CGFloat(1 + 0.12 * d))
                .offset(x: CGFloat(4 * d * sin(t * 60)), y: CGFloat(3 * d * cos(t * 53)))
        case .fisheye:
            sample.scaleEffect(CGFloat(1.3 + 0.06 * sin(t * 2)))
                .clipShape(Ellipse().scale(1.25))
        default:
            sample
        }
    }

    @ViewBuilder
    private func retroContent(t: Double, w: CGFloat, h: CGFloat) -> some View {
        let slot = floor(t * 10)
        switch type {
        case .vhs:
            ZStack {
                sample.saturation(0.7)
                sample.colorMultiply(.red).offset(x: 1.5).blendMode(.screen).opacity(0.5)
                EffectPreviewScanLines()
            }
        case .rgbSplit:
            let a = CGFloat(1 + 4 * VideoEffectRenderer.rand(slot, 1))
            ZStack {
                sample
                sample.colorMultiply(.cyan).offset(x: -a).blendMode(.screen).opacity(0.6)
                sample.colorMultiply(.red).offset(x: a, y: a * 0.3).blendMode(.screen).opacity(0.6)
            }
        case .noise:
            ZStack {
                sample
                EffectPreviewNoise(seed: floor(t * 20))
            }
        case .filmScratch:
            let x = w * CGFloat(VideoEffectRenderer.rand(floor(t * 12), 3))
            ZStack(alignment: .topLeading) {
                sample.colorMultiply(Color(red: 1, green: 0.88, blue: 0.7))
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 1, height: h)
                    .offset(x: x)
            }
        default:
            sample
        }
    }

    @ViewBuilder
    private func lightContent(t: Double, w: CGFloat, h: CGFloat) -> some View {
        switch type {
        case .lightLeak:
            ZStack {
                sample
                RadialGradient(colors: [Color.orange.opacity(0.9), Color.orange.opacity(0)],
                               center: UnitPoint(x: CGFloat(0.5 + 0.6 * sin(t * 0.9)), y: 0.2),
                               startRadius: 0, endRadius: h * 0.6)
                    .blendMode(.screen)
            }
        case .lensFlare:
            let cx = w * CGFloat(0.25 + 0.5 * (0.5 + 0.5 * sin(t * 0.8)))
            ZStack(alignment: .topLeading) {
                sample
                Circle()
                    .fill(RadialGradient(colors: [Color.white, Color.yellow.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 12))
                    .frame(width: 24, height: 24)
                    .offset(x: cx - 12, y: h * 0.18 - 12)
                    .blendMode(.screen)
                Circle()
                    .fill(Color.cyan.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .offset(x: w - cx - 4, y: h * 0.7)
            }
        case .sparkles:
            ZStack(alignment: .topLeading) {
                sample
                ForEach(0..<6, id: \.self) { i in
                    let seed = Double(i)
                    let twinkle = max(0, sin(t * (2 + 3 * VideoEffectRenderer.rand(seed, 3)) + seed * 1.7))
                    Image(systemName: "sparkle")
                        .font(.system(size: 7 + 5 * CGFloat(VideoEffectRenderer.rand(seed, 5))))
                        .foregroundStyle(Color.white)
                        .opacity(twinkle)
                        .offset(x: w * CGFloat(VideoEffectRenderer.rand(seed, 1)) - 4,
                                y: h * CGFloat(VideoEffectRenderer.rand(seed, 2)) - 4)
                }
            }
        case .neonGlow:
            let color = Color(hue: (t * 0.2).truncatingRemainder(dividingBy: 1), saturation: 1, brightness: 1)
            Image(systemName: "figure.wave")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(color)
                .shadow(color: color, radius: 4)
                .shadow(color: color, radius: 2)
        case .strobe:
            let phase = t.truncatingRemainder(dividingBy: 0.25) / 0.25
            ZStack {
                sample
                Color.white.opacity(phase < 0.4 ? 0.85 * (1 - phase / 0.4) : 0)
            }
        default:
            sample
        }
    }

    @ViewBuilder
    private func blurColorContent(t: Double, w: CGFloat, h: CGFloat) -> some View {
        switch type {
        case .blur:
            sample.blur(radius: 3)
        case .zoomBlur:
            ZStack {
                sample
                sample.scaleEffect(1.1).opacity(0.4)
                sample.scaleEffect(1.2).opacity(0.25)
            }
            .blur(radius: 0.6)
        case .motionBlur:
            let dx = 2 + 2 * CGFloat(sin(t * 1.5))
            ZStack {
                sample.offset(x: -dx).opacity(0.45)
                sample.offset(x: dx).opacity(0.45)
                sample.opacity(0.5)
            }
        case .monoToColor:
            let p = t.truncatingRemainder(dividingBy: 2) / 2
            let s = min(max((p - 0.35) / 0.35, 0), 1)
            sample.saturation(s * s * (3 - 2 * s))
        case .vignette:
            sample.overlay(
                RadialGradient(colors: [Color.clear, Color.black.opacity(0.85)],
                               center: .center, startRadius: w * 0.25, endRadius: max(w, h) * 0.65)
            )
        default:
            sample
        }
    }

    @ViewBuilder
    private func screenContent(t: Double, w: CGFloat, h: CGFloat) -> some View {
        switch type {
        case .mirror:
            HStack(spacing: 0) {
                sample.frame(width: w, height: h).frame(width: w / 2, alignment: .leading).clipped()
                sample.frame(width: w, height: h).frame(width: w / 2, alignment: .leading).clipped()
                    .scaleEffect(x: -1, y: 1)
            }
        case .split2:
            VStack(spacing: 1) {
                sample.frame(width: w, height: h).frame(width: w, height: h / 2 - 0.5).clipped()
                sample.frame(width: w, height: h).frame(width: w, height: h / 2 - 0.5).clipped()
            }
        case .split4:
            VStack(spacing: 1) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 1) {
                        ForEach(0..<2, id: \.self) { _ in
                            sample.frame(width: w / 2 - 0.5, height: h / 2 - 0.5)
                        }
                    }
                }
            }
        default:
            sample
        }
    }
}

/// 見本の絵(グラデーションの背景 + 人)
private struct EffectPreviewSample: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [BrandStyle.orange, BrandStyle.pink],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "figure.wave")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.95))
        }
    }
}

/// 見本の走査線
private struct EffectPreviewScanLines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(Color.black.opacity(0.3)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

/// 見本の砂嵐の粒
private struct EffectPreviewNoise: View {
    let seed: Double
    var body: some View {
        Canvas { context, size in
            for i in 0..<90 {
                let x = size.width * CGFloat(VideoEffectRenderer.rand(seed + Double(i) * 0.37, 1))
                let y = size.height * CGFloat(VideoEffectRenderer.rand(seed + Double(i) * 0.37, 2))
                let light = VideoEffectRenderer.rand(seed + Double(i) * 0.37, 3) > 0.5
                context.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                             with: .color(light ? Color.white.opacity(0.7) : Color.black.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
    }
}
