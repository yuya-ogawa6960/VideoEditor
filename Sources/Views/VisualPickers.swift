import SwiftUI

// =====================================================================
// 種類を「動く見本」で選ぶ部品(トランジション・アニメーション・字幕デザイン)。
// 見本は縦長(ショートの画面)。動くのは選んでいるタイルだけで、ほかは途中の 1 コマで止める。
// =====================================================================

/// 見本タイルの中の絵を動かすか(タイルが選ばれているときだけ true)
private struct VisualTileAnimatingKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var visualTileAnimating: Bool {
        get { self[VisualTileAnimatingKey.self] }
        set { self[VisualTileAnimatingKey.self] = newValue }
    }
}

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
                    .environment(\.visualTileAnimating, isSelected)
                    .frame(width: 42, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .brandSelected(isSelected)
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(width: 62, height: 28, alignment: .top)
            }
            .frame(minWidth: 62, minHeight: 102)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 0 → 1 を繰り返す進み具合(最後に少し止まる)。止めるときは途中の 1 コマを見せる
private struct LoopingProgress<Content: View>: View {
    var period: Double = 1.6
    @ViewBuilder let content: (Double) -> Content
    @Environment(\.visualTileAnimating) private var isAnimating

    /// 止めているときに見せる進み具合
    private static var stillProgress: Double { 0.6 }

    var body: some View {
        if isAnimating {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: period)) / period
                // 0 ... 0.15 は始めの状態で止める、0.15 ... 0.8 で動く、0.8 ... 1 は終わりの状態で止める
                let raw = (phase - 0.15) / 0.65
                let p = min(max(raw, 0), 1)
                content(p * p * (3 - 2 * p))
            }
        } else {
            content(Self.stillProgress)
        }
    }
}

private let previewA = LinearGradient(colors: [BrandStyle.orange, BrandStyle.pink],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
private let previewB = LinearGradient(colors: [BrandStyle.blue, Color(red: 0.10, green: 0.66, blue: 0.62)],
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
        default:
            extendedContent(p: p, w: w, h: h, a: a, b: b)
        }
    }

    @ViewBuilder
    private func extendedContent(p: Double, w: CGFloat, h: CGFloat, a: PreviewPanel, b: PreviewPanel) -> some View {
        let k = sin(Double.pi * p)
        let d = max(0.1, (w + h) * 1.2 * p)
        switch type {
        case .wipeUp:
            ZStack { a; b.mask(alignment: .bottom) { Rectangle().frame(height: max(0.1, h * p)) } }
        case .wipeDown:
            ZStack { a; b.mask(alignment: .top) { Rectangle().frame(height: max(0.1, h * p)) } }
        case .coverLeft:
            ZStack { a; b.offset(x: w * (1 - p)) }
        case .coverRight:
            ZStack { a; b.offset(x: -w * (1 - p)) }
        case .irisOpen:
            ZStack { a; b.mask { Circle().frame(width: d, height: d) } }
        case .irisClose:
            let dc = max(0.1, (w + h) * 1.2 * (1 - p))
            ZStack { b; a.mask { Circle().frame(width: dc, height: dc) } }
        case .doorOpen:
            ZStack { a; b.mask { Rectangle().frame(width: max(0.1, w * p)) } }
        case .spin:
            ZStack {
                a.rotationEffect(.degrees(90 * p)).scaleEffect(1 - 0.3 * p).opacity(1 - p)
                b.rotationEffect(.degrees(-90 * (1 - p))).scaleEffect(0.7 + 0.3 * p).opacity(p)
            }
        case .swirl:
            ZStack { a.opacity(1 - p); b.opacity(p) }
                .rotationEffect(.degrees(k * 160))
                .scaleEffect(1 + 0.4 * k)
        case .zoomBlur:
            ZStack {
                a.scaleEffect(1 + p).opacity(1 - p)
                b.scaleEffect(1.5 - 0.5 * p).opacity(p)
            }
            .blur(radius: k * 4)
        case .whipLeft:
            ZStack { a.offset(x: -w * p); b.offset(x: w * (1 - p)) }.blur(radius: k * 5)
        case .whipRight:
            ZStack { a.offset(x: w * p); b.offset(x: -w * (1 - p)) }.blur(radius: k * 5)
        case .flash:
            ZStack {
                if p < 0.5 { a } else { b }
                Color.white.opacity(k)
            }
        case .exposureFlash:
            // 画面全体が明るく飛ぶ(白を重ねるのではなく、明るさと鮮やかさを上げる)
            (p < 0.5 ? a : b)
                .brightness(0.55 * pow(k, 0.7))
                .saturation(1 + 0.4 * k)
        case .lightLeak:
            ZStack {
                a
                b.opacity(p)
                RadialGradient(colors: [Color.orange.opacity(0.9), Color.red.opacity(0)],
                               center: UnitPoint(x: -0.2 + 1.4 * p, y: 0.4), startRadius: 0, endRadius: w)
                    .opacity(k)
                    .blendMode(.screen)
            }
        case .glitch:
            ZStack {
                if p < 0.5 { a } else { b }
                Color.red.opacity(0.35 * k).offset(x: k * 6).blendMode(.screen)
                Color.cyan.opacity(0.35 * k).offset(x: -k * 6).blendMode(.screen)
            }
            .offset(x: Int(p * 24) % 2 == 0 ? k * 2 : -k * 2)
        case .pixelate:
            ZStack {
                if p < 0.5 { a } else { b }
            }
            .blur(radius: k * 3)
            .overlay {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.white.opacity(0.5 * k))
            }
        case .bars:
            ZStack {
                a
                b.mask {
                    HStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { i in
                            Rectangle()
                                .scaleEffect(x: 1, y: CGFloat(min(1, max(0, p * 1.6 - Double(i) * 0.12))), anchor: .top)
                        }
                    }
                }
            }
        case .pageCurl:
            ZStack {
                b
                a.mask(alignment: .leading) { Rectangle().frame(width: max(0.1, w * (1 - p))) }
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 2)
            }
        default:
            ZStack { a; b.opacity(p) }
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
    /// 文字の見本(言語に関係なく同じ)
    private let sample = "Abc"

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
            .font(.system(size: 12, weight: .bold))
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
                label("Bb").opacity(p > 0.4 ? 1 : 0)
                label("Cc").opacity(p > 0.75 ? 1 : 0)
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
    private let words = [String(localized: "今日は"), String(localized: "いい"), String(localized: "天気")]

    var body: some View {
        LoopingProgress(period: 2.2) { p in
            ZStack {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                VStack {
                    Spacer()
                    caption(p: p)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    /// 今しゃべっている単語(0...2)
    private func activeIndex(_ p: Double) -> Int {
        min(words.count - 1, Int(p * Double(words.count)))
    }

    /// 縦の画面に合わせて 2 行に並べる(1 行目に 1 語、2 行目に 2 語)
    private func twoLines<Word: View>(spacing: CGFloat = 1, @ViewBuilder _ word: (Int) -> Word) -> some View {
        VStack(spacing: 1) {
            word(0)
            HStack(spacing: spacing) {
                word(1)
                word(2)
            }
        }
    }

    @ViewBuilder
    private func caption(p: Double) -> some View {
        let size: CGFloat = 9
        switch template {
        case .plain:
            Text(words[0] + "\n" + words[1] + words[2])
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
        case .karaoke:
            twoLines { i in
                Text(words[i])
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(i <= activeIndex(p) ? highlight : Color.white)
            }
            .shadow(color: .black, radius: 1)
        case .boxPop:
            twoLines { i in
                let active = i == activeIndex(p)
                Text(words[i])
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(active ? Color.black : Color.white)
                    .padding(.horizontal, 1)
                    .background(active ? highlight : Color.clear, in: RoundedRectangle(cornerRadius: 2))
                    .scaleEffect(active ? 1.15 : 1)
            }
        case .outlineBig:
            Text(words[1] + "\n" + words[2])
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black, radius: 0, x: -1, y: -1)
                .shadow(color: .black, radius: 0, x: 1, y: -1)
                .shadow(color: .black, radius: 0, x: -1, y: 1)
        case .pillHighlight:
            twoLines(spacing: 0) { i in
                let active = i == activeIndex(p)
                Text(words[i])
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(active ? highlight.opacity(0.85) : Color.clear, in: Capsule())
            }
            .shadow(color: .black.opacity(0.6), radius: 1)
        case .typewriter:
            let full = words[0] + "\n" + words[1] + words[2]
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

// MARK: - キャプションの見た目(色・大きさ・背景・位置・原文/訳文)

/// キャプションの見た目の見本(縦の画面に「今日はいい天気」を出す)
struct CaptionLookPreview: View {
    var color: Color = .white
    /// 文字の大きさ(sizeRatio。0.02 ... 0.08)
    var sizeRatio: CGFloat = 0.045
    var background: Bool = false
    var position: SubtitlePosition = .bottom
    var mode: SubtitleDisplayMode = .original

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fontSize: CGFloat = max(6, min(14, h * sizeRatio * 3.2))
            ZStack {
                LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.75), Color(red: 0.2, green: 0.32, blue: 0.22)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    if position != .top { Spacer(minLength: 0) }
                    VStack(spacing: 1) {
                        if mode != .translated {
                            line(String(localized: "今日はいい天気"), size: fontSize)
                        }
                        if mode != .original {
                            line("Nice weather today", size: fontSize * 0.85)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, position == .center ? 0 : h * 0.12)
                    if position != .bottom { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func line(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, background ? 3 : 0)
            .background(background ? Color.black.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 2))
            .shadow(color: background ? .clear : .black.opacity(0.8), radius: 1)
    }
}

/// 字幕の位置を見本付きで選ぶ
struct CaptionPositionPicker: View {
    @Binding var selection: SubtitlePosition

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SubtitlePosition.allCases) { position in
                EditorVisualTile(title: position.displayName, isSelected: selection == position) {
                    selection = position
                } preview: {
                    CaptionLookPreview(position: position)
                }
            }
        }
    }
}

/// 原文 / 訳文 / 両方を見本付きで選ぶ
struct CaptionDisplayModePicker: View {
    @Binding var selection: SubtitleDisplayMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SubtitleDisplayMode.allCases) { mode in
                EditorVisualTile(title: mode.displayName, isSelected: selection == mode) {
                    selection = mode
                } preview: {
                    CaptionLookPreview(mode: mode)
                }
            }
        }
    }
}

/// 文字色を色の見本で選ぶ
struct CaptionColorPicker: View {
    @Binding var selection: SubtitleColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SubtitleColor.allCases) { color in
                EditorVisualTile(title: color.displayName, isSelected: selection == color) {
                    selection = color
                } preview: {
                    CaptionLookPreview(color: Color(uiColor: color.uiColor))
                }
            }
        }
    }
}

// MARK: - おまかせ編集のスタイル

/// おまかせ編集のスタイルの見本(色味・黒帯・画面の形・文字の雰囲気)
struct AutoEditStylePreview: View {
    let style: AutoEditStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Color.black
                switch style {
                case .documentary:
                    // くすんだ色味 + シネスコの黒帯 + 章タイトル
                    LinearGradient(colors: [Color(red: 0.25, green: 0.36, blue: 0.38), Color(red: 0.42, green: 0.33, blue: 0.24)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: h * 0.62)
                    Text("第1章")
                        .font(.system(size: 10, weight: .medium, design: .serif))
                        .foregroundStyle(.white.opacity(0.9))
                case .vlog:
                    // 暖かい色味 + 手書き風の日付
                    LinearGradient(colors: [Color(red: 0.98, green: 0.74, blue: 0.45), Color(red: 0.85, green: 0.45, blue: 0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text("Day 1")
                        .font(.custom("Pacifico-Regular", size: 12))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                case .short:
                    // 縦の画面 + 大きな字幕
                    LinearGradient(colors: [Color(red: 0.3, green: 0.2, blue: 0.6), Color(red: 0.9, green: 0.3, blue: 0.5)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: h * 0.56)
                    Text("ヤバい!")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.yellow)
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                        .offset(y: h * 0.18)
                case .family:
                    // やわらかい明るい色味 + ハート
                    LinearGradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.8), Color(red: 0.95, green: 0.7, blue: 0.75)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.95, green: 0.4, blue: 0.5))
                case .howto:
                    // すっきりした背景 + 手順の番号
                    Color(red: 0.9, green: 0.92, blue: 0.95)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STEP 1")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(Color(red: 0.2, green: 0.5, blue: 0.9), in: RoundedRectangle(cornerRadius: 2))
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.5)).frame(width: w * 0.5, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.35)).frame(width: w * 0.35, height: 3)
                    }
                }
            }
            .frame(width: w, height: h)
        }
    }
}
