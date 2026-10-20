import SwiftUI

// =====================================================================
// 種類を「動く見本」で選ぶ部品(トランジション・アニメーション・字幕デザイン)。
// 見本は TimelineView で 1.6 秒ごとに繰り返す小さなアニメーション。
// =====================================================================

/// 見本 + 名前のタイル
struct EditorVisualTile<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            VStack(spacing: 4) {
                preview()
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? BrandStyle.coral : Color.white.opacity(0.15),
                                    lineWidth: isSelected ? 2.5 : 1)
                    )
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72, height: 26, alignment: .top)
            }
            .frame(minWidth: 72, minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 0 → 1 を繰り返す進み具合(最後に少し止まる)
private struct LoopingProgress<Content: View>: View {
    var period: Double = 1.6
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: period)) / period
            // 0 ... 0.15 は始めの状態で止める、0.15 ... 0.8 で動く、0.8 ... 1 は終わりの状態で止める
            let raw = (phase - 0.15) / 0.65
            let p = min(max(raw, 0), 1)
            content(p * p * (3 - 2 * p))
        }
    }
}

private let previewA = LinearGradient(colors: [Color(red: 0.86, green: 0.47, blue: 0.13), Color(red: 0.76, green: 0.19, blue: 0.33)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
private let previewB = LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.75), Color(red: 0.10, green: 0.66, blue: 0.62)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)

private struct PreviewPanel: View {
    let fill: LinearGradient
    let label: String
    var body: some View {
        ZStack {
            Rectangle().fill(fill)
            Text(label)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
        }
    }
}

// MARK: - トランジション

struct TransitionPreview: View {
    let type: TransitionType

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            LoopingProgress { p in
                ZStack {
                    content(p: p, w: w, h: h)
                }
                .frame(width: w, height: h)
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func content(p: Double, w: CGFloat, h: CGFloat) -> some View {
        let a = PreviewPanel(fill: previewA, label: "A")
        let b = PreviewPanel(fill: previewB, label: "B")
        switch type {
        case .none:
            if p < 0.5 { a } else { b }
        case .dissolve:
            ZStack { a; b.opacity(p) }
        case .fadeBlack, .fadeWhite:
            let base: Color = type == .fadeBlack ? .black : .white
            ZStack {
                base
                if p < 0.5 { a.opacity(1 - p * 2) } else { b.opacity((p - 0.5) * 2) }
            }
        case .slideLeft:
            ZStack { a.offset(x: -w * p); b.offset(x: w * (1 - p)) }
        case .slideRight:
            ZStack { a.offset(x: w * p); b.offset(x: -w * (1 - p)) }
        case .slideUp:
            ZStack { a.offset(y: -h * p); b.offset(y: h * (1 - p)) }
        case .slideDown:
            ZStack { a.offset(y: h * p); b.offset(y: -h * (1 - p)) }
        case .zoomIn:
            ZStack { b; a.scaleEffect(1 + p * 1.5).opacity(1 - p) }
        case .zoomOut:
            ZStack { a; b.scaleEffect(0.2 + 0.8 * p).opacity(p) }
        case .wipeLeft:
            ZStack {
                a
                b.mask(alignment: .trailing) { Rectangle().frame(width: max(0.1, w * p)) }
            }
        case .wipeRight:
            ZStack {
                a
                b.mask(alignment: .leading) { Rectangle().frame(width: max(0.1, w * p)) }
            }
        case .blur:
            if p < 0.5 {
                a.blur(radius: p * 2 * 8)
            } else {
                b.blur(radius: (1 - p) * 2 * 8)
            }
        }
    }
}

/// トランジションの種類を見本付きで選ぶ横一列
struct TransitionTypePicker: View {
    @Binding var selection: TransitionType

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TransitionType.allCases) { type in
                    EditorVisualTile(title: type.displayName, isSelected: selection == type) {
                        selection = type
                    } preview: {
                        TransitionPreview(type: type)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - クリップのアニメーション

struct ClipAnimationPreview: View {
    let type: ClipAnimationType
    /// 終わるときの動き(逆再生で見せる)
    let isOut: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            LoopingProgress { raw in
                let p = isOut ? 1 - raw : raw
                ZStack {
                    Color.black
                    clip(p: p, w: w, h: h)
                }
                .frame(width: w, height: h)
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func clip(p: Double, w: CGFloat, h: CGFloat) -> some View {
        let panel = PreviewPanel(fill: previewA, label: "")
            .frame(width: w * 0.62, height: h * 0.62)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        switch type {
        case .none: panel
        case .fade: panel.opacity(p)
        case .slideFromLeft: panel.offset(x: -w * (1 - p)).opacity(min(1, p * 3))
        case .slideFromRight: panel.offset(x: w * (1 - p)).opacity(min(1, p * 3))
        case .slideFromBottom: panel.offset(y: h * (1 - p)).opacity(min(1, p * 3))
        case .slideFromTop: panel.offset(y: -h * (1 - p)).opacity(min(1, p * 3))
        case .zoomIn: panel.scaleEffect(0.2 + 0.8 * p).opacity(p)
        case .zoomOut: panel.scaleEffect(1.8 - 0.8 * p).opacity(p)
        case .blur: panel.blur(radius: (1 - p) * 8).opacity(0.3 + 0.7 * p)
        case .spin: panel.rotationEffect(.degrees((1 - p) * -180)).scaleEffect(0.4 + 0.6 * p).opacity(p)
        }
    }
}

struct ClipAnimationPicker: View {
    @Binding var selection: ClipAnimationType
    let isOut: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClipAnimationType.allCases) { type in
                    EditorVisualTile(title: type.displayName, isSelected: selection == type) {
                        selection = type
                    } preview: {
                        ClipAnimationPreview(type: type, isOut: isOut)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - テキストのアニメーション

struct TextAnimationPreview: View {
    let type: TextAnimationType
    let isOut: Bool
    private let sample = "Aa字幕"

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            LoopingProgress { raw in
                let p = isOut ? 1 - raw : raw
                ZStack {
                    Color(white: 0.12)
                    text(p: p, h: h)
                }
            }
        }
    }

    /// ポップ: 0 → 1.2 → 1
    private static func popScale(_ p: Double) -> Double {
        if p < 0.7 {
            return p / 0.7 * 1.2
        }
        let back: Double = (p - 0.7) / 0.3 * 0.2
        return 1.2 - back
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.white)
            .fixedSize()
    }

    @ViewBuilder
    private func text(p: Double, h: CGFloat) -> some View {
        switch type {
        case .none: label(sample)
        case .fade: label(sample).opacity(p)
        case .typewriter:
            label(String(sample.prefix(Int((Double(sample.count) * p).rounded(.up)))))
        case .pop: label(sample).scaleEffect(Self.popScale(p)).opacity(min(1, p * 3))
        case .slideUp: label(sample).offset(y: (1 - p) * h * 0.5).opacity(p)
        case .slideLeft: label(sample).offset(x: (1 - p) * 30).opacity(p)
        case .blurIn: label(sample).blur(radius: (1 - p) * 6).opacity(0.3 + 0.7 * p)
        case .scaleDown: label(sample).scaleEffect(1 + (1 - p) * 0.8).opacity(min(1, p * 2))
        case .wordByWord:
            HStack(spacing: 3) {
                label("Aa").opacity(p > 0.05 ? 1 : 0)
                label("字").opacity(p > 0.4 ? 1 : 0)
                label("幕").opacity(p > 0.75 ? 1 : 0)
            }
        }
    }
}

struct TextAnimationPicker: View {
    @Binding var selection: TextAnimationType
    let isOut: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TextAnimationType.allCases) { type in
                    EditorVisualTile(title: type.displayName, isSelected: selection == type) {
                        selection = type
                    } preview: {
                        TextAnimationPreview(type: type, isOut: isOut)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 字幕デザイン

struct CaptionTemplatePreview: View {
    let template: CaptionTemplate
    var highlight: Color = .yellow
    private let words = ["今日は", "いい", "天気"]

    var body: some View {
        LoopingProgress(period: 2.2) { p in
            ZStack {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                VStack {
                    Spacer()
                    caption(p: p)
                        .padding(.bottom, 5)
                }
            }
        }
    }

    /// 今しゃべっている単語(0...2)
    private func activeIndex(_ p: Double) -> Int {
        min(words.count - 1, Int(p * Double(words.count)))
    }

    @ViewBuilder
    private func caption(p: Double) -> some View {
        let size: CGFloat = 10
        switch template {
        case .plain:
            Text(words.joined())
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
        case .karaoke:
            HStack(spacing: 1) {
                ForEach(0..<words.count, id: \.self) { i in
                    Text(words[i])
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(i <= activeIndex(p) ? highlight : Color.white)
                }
            }
            .shadow(color: .black, radius: 1)
        case .boxPop:
            HStack(spacing: 1) {
                ForEach(0..<words.count, id: \.self) { i in
                    let active = i == activeIndex(p)
                    Text(words[i])
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(active ? Color.black : Color.white)
                        .padding(.horizontal, 2)
                        .background(active ? highlight : Color.clear, in: RoundedRectangle(cornerRadius: 2))
                        .scaleEffect(active ? 1.15 : 1)
                }
            }
        case .outlineBig:
            Text("いい天気")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black, radius: 0, x: -1, y: -1)
                .shadow(color: .black, radius: 0, x: 1, y: -1)
                .shadow(color: .black, radius: 0, x: -1, y: 1)
        case .pillHighlight:
            HStack(spacing: 1) {
                ForEach(0..<words.count, id: \.self) { i in
                    let active = i == activeIndex(p)
                    Text(words[i])
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(active ? highlight.opacity(0.85) : Color.clear, in: Capsule())
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 1)
        case .typewriter:
            let full = words.joined()
            Text(String(full.prefix(max(1, Int((Double(full.count) * p).rounded(.up))))))
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
        }
    }
}

struct CaptionTemplatePicker: View {
    @Binding var selection: CaptionTemplate
    var highlight: Color = .yellow

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CaptionTemplate.allCases) { template in
                    EditorVisualTile(title: template.displayName, isSelected: selection == template) {
                        selection = template
                    } preview: {
                        CaptionTemplatePreview(template: template, highlight: highlight)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
