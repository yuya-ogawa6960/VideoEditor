import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import Observation

// =====================================================================
// 第3弾: テキスト・ステッカー・手書き・マーカー・透かし・フォーマット・読み上げ・
// 字幕テンプレートのための下部パネル
//   - EditorFontPickerRow        : フォント選択(内蔵 + 読み込んだフォント + ファイル読み込み)
//   - EditorStickerPanel         : 絵文字ステッカーの一覧
//   - EditorTextStylePanel       : テキストレイヤーの文字・テンプレート・スタイル
//   - EditorTextAnimationPanel   : テキストのイン・アウト
//   - EditorTextPlacementPanel   : 位置・大きさ・回転(プレビュー上の操作と併用)
//   - EditorKeyframePanel        : キーフレーム(テキスト・オーバーレイ共通)
//   - EditorOverlayBlendPanel    : ブレンドモード
//   - EditorDrawingToolsPanel    : 手書き中の色・太さ・完了
//   - EditorDrawingStylePanel / EditorDrawingTimingPanel
//   - EditorMarkerNamePanel / EditorMarkerKindPanel
//   - EditorWatermarkPanel
//   - EditorFormatKitPanel
//   - EditorTextToSpeechPanel
//   - EditorCaptionTemplatePanel
// =====================================================================

// MARK: - 色(16進)と Color の相互変換

enum EditorColorHex {
    /// "#RRGGBB" → Color(読めなければ fallback)
    static func color(_ hex: String?, fallback: Color = .white) -> Color {
        guard let hex, let ui = UIColor(hex: hex) else { return fallback }
        return Color(uiColor: ui)
    }

    /// Color → "#RRGGBB"(成分は 0...1 に丸める)
    static func hex(from color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if ui.getWhite(&white, alpha: &a) {
                r = white
                g = white
                b = white
            }
        }
        func component(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(r), component(g), component(b))
    }

    /// 16進文字列の Binding を Color の Binding にする
    static func binding(_ hexBinding: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { EditorColorHex.color(hexBinding.wrappedValue) },
            set: { hexBinding.wrappedValue = EditorColorHex.hex(from: $0) }
        )
    }

    /// 省略可能な 16進文字列の Binding を Color の Binding にする(nil のときは fallback を表示)
    static func optionalBinding(_ hexBinding: Binding<String?>, fallback: String) -> Binding<Color> {
        Binding<Color>(
            get: { EditorColorHex.color(hexBinding.wrappedValue ?? fallback) },
            set: { hexBinding.wrappedValue = EditorColorHex.hex(from: $0) }
        )
    }
}

/// ラベル + ColorPicker の 1 行
struct EditorColorRow: View {
    let title: String
    @Binding var color: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}

/// 操作の下に出す 1 行の説明(やさしい言葉で)
private struct TextPanelHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 右寄せの「リセット」ボタン
private struct TextPanelResetRow: View {
    var title: String = "リセット"
    let action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            EditorChip(title: title, isSelected: false, action: action)
        }
    }
}

private func textPanelPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func textPanelSeconds(_ value: Double) -> String {
    String(format: "%.1f 秒", value)
}

// MARK: - フォント選択

struct EditorFontPickerRow: View {
    let title: String
    @Binding var fontName: String?

    @State private var showImporter = false
    @State private var storedNames: [String] = []
    @State private var errorText: String?

    /// よく使う内蔵フォント(端末にあるものだけ表示)
    private static let builtIn: [(name: String, label: String)] = [
        ("HiraginoSans-W6", "ヒラギノ角ゴ(太)"),
        ("HiraginoSans-W3", "ヒラギノ角ゴ(細)"),
        ("HiraMinProN-W6", "ヒラギノ明朝"),
        ("HiraMaruProN-W4", "ヒラギノ丸ゴ"),
        ("AvenirNext-Bold", "Avenir Next"),
        ("Futura-Bold", "Futura"),
        ("Georgia-Bold", "Georgia"),
        ("MarkerFelt-Wide", "Marker Felt"),
        ("ChalkboardSE-Bold", "Chalkboard"),
        ("Menlo-Bold", "Menlo")
    ]

    private var availableBuiltIn: [(name: String, label: String)] {
        Self.builtIn.filter { UIFont(name: $0.name, size: 12) != nil }
    }

    private var currentLabel: String {
        guard let fontName else { return "システム(標準)" }
        if let hit = Self.builtIn.first(where: { $0.name == fontName }) { return hit.label }
        return fontName
    }

    private var currentFont: Font {
        if let fontName, UIFont(name: fontName, size: 13) != nil {
            return .custom(fontName, size: 13)
        }
        return .system(size: 13)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Menu {
                    Button {
                        fontName = nil
                    } label: {
                        if fontName == nil {
                            Label("システム(標準)", systemImage: "checkmark")
                        } else {
                            Text("システム(標準)")
                        }
                    }
                    ForEach(availableBuiltIn, id: \.name) { entry in
                        Button {
                            fontName = entry.name
                        } label: {
                            if fontName == entry.name {
                                Label(entry.label, systemImage: "checkmark")
                            } else {
                                Text(entry.label)
                            }
                        }
                    }
                    if !storedNames.isEmpty {
                        Divider()
                        ForEach(storedNames, id: \.self) { name in
                            Button {
                                fontName = name
                            } label: {
                                if fontName == name {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        showImporter = true
                    } label: {
                        Label("フォントを読み込む(.ttf / .otf)…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentLabel)
                            .font(currentFont)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            storedNames = MediaTools.storedFontNames()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.font],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let name = try MediaTools.importFont(from: url)
                    storedNames = MediaTools.storedFontNames()
                    fontName = name
                    errorText = nil
                } catch {
                    errorText = "フォントを読み込めませんでした: \(error.localizedDescription)"
                }
            case .failure(let error):
                errorText = "フォントを読み込めませんでした: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ステッカー(絵文字)

struct EditorStickerPanel: View {
    let onPick: (String) -> Void

    private static let emojis: [String] = [
        "😀", "😂", "🥹", "😍", "😎", "🤔", "😱", "🥳", "😭", "🤣", "😴", "🤯",
        "👍", "👏", "🙏", "💪", "👀", "✌️", "👉", "👈", "☝️", "🫶", "🙌", "🤝",
        "❤️", "🔥", "✨", "⭐️", "🎉", "🎊", "💯", "✅", "❌", "⚠️", "❓", "❗️",
        "💡", "🎬", "🎥", "📷", "🎵", "🎶", "🎤", "📣", "💬", "💭", "📌", "🆕",
        "🍜", "🍣", "🍺", "☕️", "🍰", "🍎", "🚗", "✈️", "🏠", "🗾", "🌸", "🌈",
        "☀️", "🌙", "⛰️", "🌊", "🐶", "🐱", "🐼", "🦊", "⚽️", "🏀", "🎮", "💰",
        "➡️", "⬅️", "⬆️", "⬇️", "🔁", "⏰", "📍", "🏆", "🎁", "🎈", "🧡", "💙"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("タップすると再生位置に 3 秒のステッカーを追加します。追加後はプレビュー上でドラッグ・ピンチ・回転できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    Button {
                        EditorHaptics.tap()
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - テキスト編集(テキストレイヤー)

struct EditorTextStylePanel: View {
    @Binding var text: TextClip

    private var strokeEnabled: Binding<Bool> {
        Binding<Bool>(
            get: { text.style.strokeColorHex != nil },
            set: { on in
                if on {
                    if text.style.strokeColorHex == nil { text.style.strokeColorHex = "#000000" }
                    if text.style.strokeWidth <= 0 { text.style.strokeWidth = 0.08 }
                } else {
                    text.style.strokeColorHex = nil
                }
            }
        )
    }

    private var backgroundEnabled: Binding<Bool> {
        Binding<Bool>(
            get: { text.style.backgroundColorHex != nil },
            set: { on in
                if on {
                    if text.style.backgroundColorHex == nil { text.style.backgroundColorHex = "#000000" }
                } else {
                    text.style.backgroundColorHex = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: text.isSticker ? "face.smiling" : "textformat",
                                name: text.isSticker ? "ステッカー" : "テキスト",
                                start: text.start, end: text.end)

            EditorTextFieldRow(title: text.isSticker ? "絵文字" : "テキスト",
                               placeholder: "テキストを入力",
                               text: $text.text,
                               multiline: !text.isSticker)

            if !text.isSticker {
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: "デザイン")
                    TextPanelHint(text: "選ぶと、色・縁取り・影などがまとめて変わります。")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TextTemplate.allCases) { template in
                                EditorChip(title: template.displayName, isSelected: text.template == template) {
                                    text.template = template
                                    text.style = TextStyle.preset(template)
                                }
                            }
                        }
                    }
                }

                EditorFontPickerRow(title: "フォント", fontName: $text.style.fontName)

                HStack(spacing: 8) {
                    EditorChip(title: "太字", isSelected: text.style.bold) {
                        text.style.bold.toggle()
                    }
                    EditorChip(title: "斜体", isSelected: text.style.italic) {
                        text.style.italic.toggle()
                    }
                    Spacer()
                }
            }

            EditorSliderRow(title: "文字サイズ",
                            value: $text.style.sizeRatio,
                            range: 0.02...0.25,
                            display: "\(Int((text.style.sizeRatio * 1000).rounded()))")

            if !text.isSticker {
                // ViewBuilder は 1 ブロック 10 個まで。色・縁取り・影・背景 / 配置・字間 の 2 つに分ける
                Group {
                EditorColorRow(title: "文字色", color: EditorColorHex.binding($text.style.colorHex))

                // 縁取り
                Toggle("縁取り(文字のふち)", isOn: strokeEnabled)
                    .font(.subheadline)
                    .tint(.accentColor)
                if text.style.strokeColorHex != nil {
                    EditorColorRow(title: "縁取りの色",
                                   color: EditorColorHex.optionalBinding($text.style.strokeColorHex, fallback: "#000000"))
                    EditorSliderRow(title: "縁取りの太さ",
                                    value: $text.style.strokeWidth,
                                    range: 0...0.3,
                                    display: textPanelPercent(text.style.strokeWidth))
                }

                // 影
                Toggle("影", isOn: $text.style.shadow.enabled)
                    .font(.subheadline)
                    .tint(.accentColor)
                if text.style.shadow.enabled {
                    EditorColorRow(title: "影の色", color: EditorColorHex.binding($text.style.shadow.colorHex))
                    EditorSliderRow(title: "影の濃さ",
                                    value: $text.style.shadow.opacity,
                                    range: 0...1,
                                    display: textPanelPercent(text.style.shadow.opacity))
                    EditorSliderRow(title: "影のぼかし",
                                    value: $text.style.shadow.radius,
                                    range: 0...0.03,
                                    display: String(format: "%.3f", text.style.shadow.radius))
                    EditorSliderRow(title: "影のずれ(縦)",
                                    value: $text.style.shadow.offsetY,
                                    range: -0.02...0.02,
                                    display: String(format: "%+.3f", text.style.shadow.offsetY))
                }

                // 背景
                Toggle("文字の後ろに帯を敷く", isOn: backgroundEnabled)
                    .font(.subheadline)
                    .tint(.accentColor)
                if text.style.backgroundColorHex != nil {
                    EditorColorRow(title: "帯の色",
                                   color: EditorColorHex.optionalBinding($text.style.backgroundColorHex, fallback: "#000000"))
                    EditorSliderRow(title: "帯の濃さ",
                                    value: $text.style.backgroundOpacity,
                                    range: 0...1,
                                    display: textPanelPercent(text.style.backgroundOpacity))
                    EditorSliderRow(title: "帯の余白",
                                    value: $text.style.backgroundPadding,
                                    range: 0...1,
                                    display: String(format: "%.2f", text.style.backgroundPadding))
                    EditorSliderRow(title: "帯の角の丸み",
                                    value: $text.style.backgroundCornerRadius,
                                    range: 0...1,
                                    display: String(format: "%.2f", text.style.backgroundCornerRadius))
                }
                }

                Group {
                // 配置・字間・行間
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: "行ぞろえ")
                    HStack(spacing: 8) {
                        ForEach(TextAlignment2.allCases) { alignment in
                            EditorChip(title: alignment.displayName, isSelected: text.style.alignment == alignment) {
                                text.style.alignment = alignment
                            }
                        }
                        Spacer()
                    }
                }
                EditorSliderRow(title: "文字の間隔",
                                value: $text.style.letterSpacing,
                                range: -0.1...0.5,
                                display: String(format: "%+.2f", text.style.letterSpacing))
                EditorSliderRow(title: "行の間隔",
                                value: $text.style.lineSpacing,
                                range: 0.8...2.0,
                                display: String(format: "%.2f", text.style.lineSpacing))
                Toggle("縦書き", isOn: $text.style.vertical)
                    .font(.subheadline)
                    .tint(.accentColor)
                EditorSliderRow(title: "文字を弧のように曲げる",
                                value: $text.style.curveRadius,
                                range: 0...1,
                                display: text.style.curveRadius <= 0.001 ? "直線" : String(format: "%.2f", text.style.curveRadius))
                }
            }

            EditorSliderRow(title: "表示時間",
                            value: $text.duration,
                            range: 0.5...30,
                            display: textPanelSeconds(text.duration))

            if !text.isSticker {
                TextPanelResetRow(title: "スタイルをリセット") {
                    text.style = TextStyle.preset(text.template)
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - テキストのアニメーション

struct EditorTextAnimationPanel: View {
    @Binding var text: TextClip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextPanelHint(text: "登場の動き: 文字が出てくるとき・消えるときの動きを選びます。")

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "出てくるとき")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TextAnimationType.allCases) { type in
                            EditorChip(title: type.displayName, isSelected: text.animIn == type) {
                                text.animIn = type
                            }
                        }
                    }
                }
                EditorSliderRow(title: "出てくるまでの時間",
                                value: $text.animInDuration,
                                range: 0.1...2.0,
                                display: textPanelSeconds(text.animInDuration))
                    .disabled(text.animIn == .none)
                    .opacity(text.animIn == .none ? 0.4 : 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "消えるとき")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TextAnimationType.allCases) { type in
                            EditorChip(title: type.displayName, isSelected: text.animOut == type) {
                                text.animOut = type
                            }
                        }
                    }
                }
                EditorSliderRow(title: "消えるまでの時間",
                                value: $text.animOutDuration,
                                range: 0.1...2.0,
                                display: textPanelSeconds(text.animOutDuration))
                    .disabled(text.animOut == .none)
                    .opacity(text.animOut == .none ? 0.4 : 1)
            }

            HStack {
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    text.animIn = .none
                    text.animOut = .none
                }
                .disabled(text.animIn == .none && text.animOut == .none)
                .opacity(text.animIn == .none && text.animOut == .none ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 配置(テキスト)

struct EditorTextPlacementPanel: View {
    @Binding var text: TextClip

    private enum Anchor: String, CaseIterable, Identifiable {
        case center, top, bottom, left, right
        var id: String { rawValue }
        var title: String {
            switch self {
            case .center: return "中央"
            case .top: return "上"
            case .bottom: return "下"
            case .left: return "左"
            case .right: return "右"
            }
        }
        var point: NormalizedPoint {
            switch self {
            case .center: return NormalizedPoint(x: 0.5, y: 0.5)
            case .top: return NormalizedPoint(x: 0.5, y: 0.18)
            case .bottom: return NormalizedPoint(x: 0.5, y: 0.82)
            case .left: return NormalizedPoint(x: 0.25, y: 0.5)
            case .right: return NormalizedPoint(x: 0.75, y: 0.5)
            }
        }
    }

    private var isDefault: Bool {
        text.center == NormalizedPoint(x: 0.5, y: 0.5) && text.scale == 1 && text.rotation == 0
            && text.widthRatio == 0.8 && text.opacity == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("プレビューの点線の枠をドラッグで移動、ピンチで拡大縮小、2 本指で回転できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "位置")
                HStack(spacing: 8) {
                    ForEach(Anchor.allCases) { anchor in
                        EditorChip(title: anchor.title,
                                   isSelected: abs(text.center.x - anchor.point.x) < 0.01 && abs(text.center.y - anchor.point.y) < 0.01) {
                            text.center = anchor.point
                        }
                    }
                    Spacer()
                }
            }

            EditorSliderRow(title: "横の位置(左 ← → 右)",
                            value: $text.center.x,
                            range: 0...1,
                            display: textPanelPercent(text.center.x))
            EditorSliderRow(title: "縦の位置(上 ← → 下)",
                            value: $text.center.y,
                            range: 0...1,
                            display: textPanelPercent(text.center.y))
            EditorSliderRow(title: "大きさ",
                            value: $text.scale,
                            range: 0.2...4,
                            display: String(format: "%.2fx", text.scale))
            EditorSliderRow(title: "回転",
                            value: $text.rotation,
                            range: -180...180,
                            display: String(format: "%.0f°", text.rotation))
            if !text.isSticker {
                EditorSliderRow(title: "1行の幅(これより長いと折り返す)",
                                value: $text.widthRatio,
                                range: 0.2...1,
                                display: textPanelPercent(text.widthRatio))
            }
            EditorSliderRow(title: "濃さ(透けにくさ)",
                            value: $text.opacity,
                            range: 0...1,
                            display: textPanelPercent(text.opacity))

            HStack {
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    text.center = NormalizedPoint(x: 0.5, y: 0.5)
                    text.scale = 1
                    text.rotation = 0
                    text.widthRatio = 0.8
                    text.opacity = 1
                }
                .disabled(isDefault)
                .opacity(isDefault ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - キーフレーム(テキスト・オーバーレイ共通)

struct EditorKeyframePanel: View {
    let player: PlayerController
    /// 部品の出力タイムライン上の開始・長さ
    let start: Double
    let duration: Double
    /// いまの配置(再生位置にキーフレームを追加するときの値)
    let currentValue: KeyframeInterpolator.Value
    @Binding var keyframes: [Keyframe]

    @State private var selectedID: UUID?

    private var sorted: [Keyframe] { keyframes.sorted { $0.time < $1.time } }

    /// 再生位置の、部品の先頭からの相対秒(範囲内に丸める)
    private var playheadRelative: Double {
        min(max(player.currentTime - start, 0), max(duration, 0))
    }

    private var selected: Keyframe? {
        guard let selectedID else { return nil }
        return keyframes.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextPanelHint(text: "動きをつける: 時間ごとに位置や大きさを記録すると、その間をなめらかに動きます。")

            Text("再生位置 \(MediaTimeText.precise(player.currentTime))(先頭から \(String(format: "%.2f", playheadRelative)) 秒)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                EditorPillButton(title: "ここに動きのポイントを追加", systemImage: "plus.diamond", prominent: true) {
                    addAtPlayhead()
                }
                Spacer()
                EditorChip(title: "すべて削除", isSelected: false) {
                    keyframes.removeAll()
                    selectedID = nil
                }
                .disabled(keyframes.isEmpty)
                .opacity(keyframes.isEmpty ? 0.4 : 1)
            }

            if sorted.isEmpty {
                Text("動きのポイントはまだありません。再生位置を動かし、位置や大きさを変えてから「ここに動きのポイントを追加」を押すと、その時刻の位置・大きさ・回転・濃さが記録されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(sorted) { keyframe in
                        row(keyframe)
                    }
                }
            }

            if let selected {
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: "次のポイントまでの動き方(\(String(format: "%.2f", selected.time)) 秒から)")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(KeyframeEasing.allCases) { easing in
                                EditorChip(title: easing.displayName, isSelected: selected.easing == easing) {
                                    setEasing(easing, for: selected.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func row(_ keyframe: Keyframe) -> some View {
        let isSelected = keyframe.id == selectedID
        return HStack(spacing: 8) {
            Button {
                EditorHaptics.tap()
                selectedID = keyframe.id
                player.seek(to: start + keyframe.time)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "diamond.fill")
                        .font(.caption2)
                    Text(String(format: "%.2f 秒", keyframe.time))
                        .font(.caption)
                        .monospacedDigit()
                    Text(summary(keyframe))
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.8)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isSelected ? Color.white : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                EditorHaptics.tap()
                keyframes.removeAll { $0.id == keyframe.id }
                if selectedID == keyframe.id { selectedID = nil }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("動きのポイントを削除")
        }
    }

    private func summary(_ k: Keyframe) -> String {
        String(format: "位置 %.2f,%.2f  大きさ %.2fx  回転 %.0f°  濃さ %d%%",
               k.center.x, k.center.y, k.scale, k.rotation, Int((k.opacity * 100).rounded()))
    }

    private func addAtPlayhead() {
        let t = playheadRelative
        var keyframe = Keyframe(time: t,
                                center: currentValue.center,
                                scale: currentValue.scale,
                                rotation: currentValue.rotation,
                                opacity: currentValue.opacity)
        if let existing = keyframes.first(where: { abs($0.time - t) < 0.05 }) {
            keyframe.id = existing.id
            keyframe.easing = existing.easing
            keyframes.removeAll { $0.id == existing.id }
        }
        keyframes.append(keyframe)
        keyframes.sort { $0.time < $1.time }
        selectedID = keyframe.id
    }

    private func setEasing(_ easing: KeyframeEasing, for id: UUID) {
        guard let i = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[i].easing = easing
    }
}

// MARK: - ブレンド(オーバーレイ)

struct EditorOverlayBlendPanel: View {
    @Binding var overlay: OverlayClip

    private let modes: [(title: String, filter: String?)] = [
        ("通常", nil),
        ("暗く重ねる(乗算)", "CIMultiplyBlendMode"),
        ("明るく重ねる(スクリーン)", "CIScreenBlendMode"),
        ("くっきり重ねる", "CIOverlayBlendMode"),
        ("やわらかく重ねる", "CISoftLightBlendMode"),
        ("明るい方を残す", "CILightenBlendMode")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: overlay.isImage ? "photo" : "film",
                                name: overlay.name, start: overlay.start, end: overlay.end)

            Text("重ね方: 下の映像との混ぜ方です。光や煙の素材は「明るく重ねる」、黒い線の素材は「暗く重ねる」がおすすめです。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(modes, id: \.title) { mode in
                        EditorChip(title: mode.title, isSelected: overlay.blendMode == mode.filter) {
                            overlay.blendMode = mode.filter
                        }
                    }
                }
            }

            EditorSliderRow(title: "濃さ(透けにくさ)",
                            value: $overlay.opacity,
                            range: 0...1,
                            display: textPanelPercent(overlay.opacity))

            TextPanelResetRow {
                overlay.blendMode = nil
                overlay.opacity = 1
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 手書き

/// 手書きの色チップ
private struct DrawingColorChips: View {
    @Binding var colorHex: String

    private static let palette = ["#FF4D4D", "#FFB020", "#FFE44D", "#4DDC6A", "#4DB8FF", "#B06CFF", "#FFFFFF", "#000000"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.palette, id: \.self) { hex in
                let isSelected = colorHex.uppercased() == hex.uppercased()
                Button {
                    EditorHaptics.tap()
                    colorHex = hex
                } label: {
                    Circle()
                        .fill(EditorColorHex.color(hex))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                .padding(-4)
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("色 \(hex)")
            }
            ColorPicker("", selection: EditorColorHex.binding($colorHex), supportsOpacity: false)
                .labelsHidden()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.vertical, 4)
    }
}

/// 新しい手書きを描いている最中の道具(プレビューのキャンバスと組で使う)
struct EditorDrawingToolsPanel: View {
    @Binding var strokes: [DrawingStroke]
    @Binding var colorHex: String
    @Binding var width: Double
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("プレビューの上を指でなぞって描きます。「完了」を押すと、再生位置に 3 秒間表示されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                EditorSectionTitle(title: "色")
                DrawingColorChips(colorHex: $colorHex)
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "太さ")
                HStack(spacing: 8) {
                    EditorChip(title: "細", isSelected: abs(width - 0.006) < 0.0005) { width = 0.006 }
                    EditorChip(title: "中", isSelected: abs(width - 0.012) < 0.0005) { width = 0.012 }
                    EditorChip(title: "太", isSelected: abs(width - 0.024) < 0.0005) { width = 0.024 }
                    Spacer()
                }
                Slider(value: $width, in: 0.003...0.04)
                    .tint(.white)
            }

            HStack(spacing: 10) {
                EditorPillButton(title: "1つ戻す", systemImage: "arrow.uturn.backward") {
                    if !strokes.isEmpty { strokes.removeLast() }
                }
                .disabled(strokes.isEmpty)
                .opacity(strokes.isEmpty ? 0.4 : 1)
                EditorPillButton(title: "全部消す", systemImage: "trash", tint: .red) {
                    strokes.removeAll()
                }
                .disabled(strokes.isEmpty)
                .opacity(strokes.isEmpty ? 0.4 : 1)
                Spacer()
                EditorPillButton(title: "キャンセル", systemImage: "xmark") {
                    onCancel()
                }
                EditorPillButton(title: "完了", systemImage: "checkmark", prominent: true) {
                    onFinish()
                }
                .disabled(strokes.isEmpty)
                .opacity(strokes.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.top, 6)
    }
}

/// 既存の手書きの色・太さ(全ストロークにまとめて適用)
struct EditorDrawingStylePanel: View {
    @Binding var drawing: DrawingClip

    private var colorBinding: Binding<String> {
        Binding<String>(
            get: { drawing.strokes.first?.colorHex ?? "#FF4D4D" },
            set: { newValue in
                for i in drawing.strokes.indices {
                    drawing.strokes[i].colorHex = newValue
                }
            }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding<Double>(
            get: { drawing.strokes.first?.width ?? 0.012 },
            set: { newValue in
                for i in drawing.strokes.indices {
                    drawing.strokes[i].width = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: "pencil.tip", name: "手書き(\(drawing.strokes.count) 本)",
                                start: drawing.start, end: drawing.end)

            VStack(alignment: .leading, spacing: 4) {
                EditorSectionTitle(title: "色(すべての線)")
                DrawingColorChips(colorHex: colorBinding)
            }

            EditorSliderRow(title: "太さ(すべての線)",
                            value: widthBinding,
                            range: 0.003...0.04,
                            display: String(format: "%.1f", widthBinding.wrappedValue * 1000))

            HStack {
                EditorPillButton(title: "最後の線を消す", systemImage: "arrow.uturn.backward") {
                    if !drawing.strokes.isEmpty { drawing.strokes.removeLast() }
                }
                .disabled(drawing.strokes.isEmpty)
                .opacity(drawing.strokes.isEmpty ? 0.4 : 1)
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    colorBinding.wrappedValue = "#FF4D4D"
                    widthBinding.wrappedValue = 0.012
                }
                .disabled(drawing.strokes.isEmpty)
                .opacity(drawing.strokes.isEmpty ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

/// 手書きの表示時間
struct EditorDrawingTimingPanel: View {
    @Binding var drawing: DrawingClip
    let player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorItemHeaderRow(systemImage: "pencil.tip", name: "手書き",
                                start: drawing.start, end: drawing.end)

            EditorSliderRow(title: "表示時間",
                            value: $drawing.duration,
                            range: 0.5...15,
                            display: textPanelSeconds(drawing.duration))
            EditorSliderRow(title: "線が描かれていく時間",
                            value: $drawing.revealDuration,
                            range: 0...3,
                            display: textPanelSeconds(drawing.revealDuration))
            TextPanelHint(text: "0 秒にすると、線がいきなり全部表示されます。")

            HStack {
                EditorPillButton(title: "再生位置に移動", systemImage: "arrow.right.to.line") {
                    drawing.start = max(0, player.currentTime)
                }
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    drawing.duration = 3
                    drawing.revealDuration = 0.8
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - マーカー

struct EditorMarkerNamePanel: View {
    let project: EditorProject
    let player: PlayerController
    @Binding var marker: TimelineMarker

    @State private var copied = false

    private var chapterPreview: String {
        let text = project.chapterListText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 5 { return text }
        return lines.prefix(5).joined(separator: "\n") + "\n…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("目印(\(marker.kind.displayName))")
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text(MediaTimeText.precise(marker.time))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            EditorTextFieldRow(title: "名前", placeholder: marker.kind == .chapter ? "例: オープニング" : "メモ", text: $marker.name)

            HStack(spacing: 10) {
                EditorPillButton(title: "再生位置に移動", systemImage: "arrow.right.to.line") {
                    marker.time = max(0, player.currentTime)
                    project.sortMarkers()
                }
                EditorPillButton(title: copied ? "コピーしました" : "チャプター一覧をコピー", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = project.chapterListText()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSectionTitle(title: "チャプター一覧(YouTube の概要欄用)")
                Text(chapterPreview)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }
}

struct EditorMarkerKindPanel: View {
    @Binding var marker: TimelineMarker

    private func description(_ kind: MarkerKind) -> String {
        switch kind {
        case .note: return "自分用のメモです。書き出した動画には映りません。"
        case .chapter: return "YouTube の区切り(チャプター)に使います。「チャプター一覧をコピー」で概要欄に貼る文章を作れます。"
        case .beat: return "「ビートに合わせる」で付く、音楽の拍の目印です。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "種類")
                HStack(spacing: 8) {
                    ForEach(MarkerKind.allCases) { kind in
                        EditorChip(title: kind.displayName, isSelected: marker.kind == kind) {
                            marker.kind = kind
                        }
                    }
                    Spacer()
                }
            }
            Text(description(marker.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

// MARK: - 透かし

struct EditorWatermarkPanel: View {
    @Bindable var project: EditorProject

    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $project.watermark.enabled) {
                Label("ロゴ・透かしを入れる", systemImage: "seal")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            TextPanelHint(text: "動画の隅に、名前やロゴをずっと表示します。")

            Group {
                EditorTextFieldRow(title: "文字(画像がないときに使います)",
                                   placeholder: "例: @channel_name",
                                   text: $project.watermark.text)

                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: "画像")
                    HStack(spacing: 10) {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                            Label(project.watermark.imageURL == nil ? "画像を選ぶ" : "画像を変える", systemImage: "photo")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.15), in: Capsule())
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                        if project.watermark.imageURL != nil {
                            EditorPillButton(title: "画像を外す", systemImage: "xmark") {
                                project.watermark.imageURL = nil
                                thumbnail = nil
                            }
                        }
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Spacer()
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: "位置")
                    HStack(spacing: 8) {
                        ForEach(WatermarkCorner.allCases) { corner in
                            EditorChip(title: corner.displayName, isSelected: project.watermark.corner == corner) {
                                project.watermark.corner = corner
                            }
                        }
                        Spacer()
                    }
                }

                EditorSliderRow(title: "濃さ(透けにくさ)",
                                value: $project.watermark.opacity,
                                range: 0.05...1,
                                display: textPanelPercent(project.watermark.opacity))
                EditorSliderRow(title: "大きさ(画面幅に対して)",
                                value: $project.watermark.sizeRatio,
                                range: 0.05...0.5,
                                display: textPanelPercent(project.watermark.sizeRatio))
                TextPanelResetRow {
                    project.watermark.opacity = 0.6
                    project.watermark.sizeRatio = 0.18
                    project.watermark.corner = .bottomRight
                }
            }
            .disabled(!project.watermark.enabled)
            .opacity(project.watermark.enabled ? 1 : 0.4)
        }
        .padding(.top, 6)
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await importImage(item) }
        }
    }

    private func loadThumbnail() {
        guard let url = project.watermark.imageURL else {
            thumbnail = nil
            return
        }
        thumbnail = MediaStore.makeImageClipThumbnail(url: url, maxPixel: 160)
    }

    @MainActor
    private func importImage(_ item: PhotosPickerItem) async {
        isLoading = true
        errorText = nil
        do {
            if let photo = try await item.loadTransferable(type: PickedPhoto.self) {
                project.watermark.imageURL = photo.url
                project.watermark.enabled = true
                loadThumbnail()
            } else {
                errorText = "画像を取得できませんでした。"
            }
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - フォーマット(オープニング・クロージング・ディバイダー)

struct EditorFormatKitPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// クリップを選択中ならその範囲を「保存」に使う
    let selectedClipID: UUID?

    @State private var showSaveForm = false
    @State private var saveName = ""
    @State private var saveKind: FormatKind = .opening
    @State private var message: String?

    private var store: FormatKitStore { FormatKitStore.shared }

    /// 保存する範囲(選択中のクリップ、なければ 0 … 再生位置)
    private var saveRange: ClosedRange<Double> {
        if let selectedClipID, let range = ClipFXTimeline.range(of: selectedClipID, in: project) {
            return range
        }
        let end = max(0.5, player.currentTime)
        return 0...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("お決まりパーツ: 毎回同じオープニングや区切りを、ワンタップで差し込めます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(FormatKind.allCases) { kind in
                let blocks = store.blocks.filter { $0.kind == kind }
                if !blocks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        EditorSectionTitle(title: kind.displayName)
                        ForEach(blocks) { block in
                            blockRow(block)
                        }
                    }
                }
            }

            if store.blocks.isEmpty {
                Text("お決まりパーツはまだありません。下のボタンで今の動画の一部を保存できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    EditorPillButton(title: showSaveForm ? "保存をやめる" : "今の範囲をお決まりパーツとして保存",
                                     systemImage: showSaveForm ? "xmark" : "square.and.arrow.down") {
                        showSaveForm.toggle()
                    }
                    Spacer()
                }
                if showSaveForm {
                    Text("保存する範囲: \(MediaTimeText.precise(saveRange.lowerBound)) – \(MediaTimeText.precise(saveRange.upperBound))" + (selectedClipID != nil ? "(選択中のクリップ)" : "(先頭から再生位置まで)"))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    EditorTextFieldRow(title: "名前", placeholder: "例: いつものオープニング", text: $saveName)
                    HStack(spacing: 8) {
                        ForEach(FormatKind.allCases) { kind in
                            EditorChip(title: kind.displayName, isSelected: saveKind == kind) {
                                saveKind = kind
                            }
                        }
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        EditorPillButton(title: "保存", systemImage: "checkmark", prominent: true) {
                            save()
                        }
                        .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(saveName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    private func blockRow(_ block: FormatBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(block.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text(textPanelSeconds(block.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Menu {
                    Button(role: .destructive) {
                        store.delete(block)
                    } label: {
                        Label("このパーツを削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("その他の操作")
            }
            HStack(spacing: 8) {
                EditorChip(title: "先頭に挿入", isSelected: false) {
                    insert(block, at: 0)
                }
                EditorChip(title: "再生位置に挿入", isSelected: false) {
                    insert(block, at: max(0, player.currentTime))
                }
                EditorChip(title: "末尾に挿入", isSelected: false) {
                    insert(block, at: project.totalDuration + 1)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func insert(_ block: FormatBlock, at time: Double) {
        history.record(project)
        store.insert(block, into: project, at: time)
        message = "「\(block.name)」を挿入しました。"
    }

    private func save() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let block = store.captureFromProject(project, range: saveRange, kind: saveKind, name: name)
        if !store.blocks.contains(where: { $0.id == block.id }) {
            store.add(block)
        }
        showSaveForm = false
        saveName = ""
        message = "「\(name)」を\(saveKind.displayName)として保存しました。"
    }
}

// MARK: - 読み上げ(テキスト → ナレーション)

struct EditorTextToSpeechPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// 追加したナレーションの ID(選択に使う)
    let onAdded: (UUID) -> Void

    @State private var text = ""
    @State private var language = "ja-JP"
    @State private var voices: [(id: String, name: String)] = []
    @State private var voiceID: String?
    @State private var rate: Float = 0.5
    @State private var pitch: Float = 1.0
    @State private var isRendering = false
    @State private var errorText: String?
    @State private var resultText: String?

    private var rateText: String {
        if rate < 0.45 { return "ゆっくり" }
        if rate > 0.55 { return "速め" }
        return "ふつう"
    }

    private var pitchText: String {
        if pitch < 0.9 { return "低め" }
        if pitch > 1.1 { return "高め" }
        return "ふつう"
    }

    private var currentVoiceName: String {
        guard let voiceID, let voice = voices.first(where: { $0.id == voiceID }) else { return "標準の声" }
        return voice.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextPanelHint(text: "AI読み上げ: 入力した文章を声にして、再生位置にナレーションとして追加します。")

            EditorTextFieldRow(title: "読み上げる文章", placeholder: "ここに入力", text: $text, multiline: true)

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "言語")
                HStack(spacing: 8) {
                    EditorChip(title: "日本語", isSelected: language == "ja-JP") {
                        language = "ja-JP"
                        reloadVoices()
                    }
                    EditorChip(title: "English", isSelected: language == "en-US") {
                        language = "en-US"
                        reloadVoices()
                    }
                    Spacer()
                }
            }

            HStack {
                Text("声")
                    .font(.caption)
                Spacer()
                Menu {
                    Button("標準の声") { voiceID = nil }
                    ForEach(voices, id: \.id) { voice in
                        Button(voice.name) { voiceID = voice.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentVoiceName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
            }

            EditorSliderRow(title: "話す速さ",
                            value: $rate,
                            range: 0.3...0.7,
                            display: rateText)
            EditorSliderRow(title: "声の高さ",
                            value: $pitch,
                            range: 0.6...1.6,
                            display: pitchText)
            TextPanelResetRow {
                rate = 0.5
                pitch = 1.0
            }

            HStack(spacing: 10) {
                EditorPillButton(title: isRendering ? "作成中…" : "読み上げて再生位置に追加", systemImage: "waveform.badge.plus", prominent: true) {
                    render()
                }
                .disabled(isRendering || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(isRendering || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Spacer()
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let resultText {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("作った音声はナレーションとして追加され、「音量」「音の効果」で調整できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .onAppear {
            reloadVoices()
        }
    }

    private func reloadVoices() {
        voices = TextToSpeech.availableVoices(language: language)
        if let voiceID, !voices.contains(where: { $0.id == voiceID }) {
            self.voiceID = nil
        }
    }

    private func render() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isRendering = true
        errorText = nil
        resultText = nil
        let startTime = max(0, player.currentTime)
        let chosenVoice = voiceID
        let chosenRate = rate
        let chosenPitch = pitch
        Task { @MainActor in
            do {
                let url = try await TextToSpeech.render(text: content, voiceIdentifier: chosenVoice,
                                                        rate: chosenRate, pitch: chosenPitch)
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                let duration = (seconds.isFinite && seconds > 0) ? seconds : 1
                history.record(project)
                let name = "読み上げ: " + String(content.prefix(12))
                let clip = NarrationClip(url: url, name: name, start: startTime, duration: duration)
                project.narration.append(clip)
                project.sortNarration()
                resultText = "\(MediaTimeText.precise(startTime)) に \(String(format: "%.1f", duration)) 秒のナレーションを追加しました。"
                onAdded(clip.id)
            } catch {
                errorText = "読み上げを作成できませんでした: \(error.localizedDescription)"
            }
            isRendering = false
        }
    }
}

// MARK: - 字幕テンプレート

struct EditorCaptionTemplatePanel: View {
    @Bindable var project: EditorProject

    private var hasWordTimings: Bool {
        project.subtitles.contains(where: { !$0.words.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: "字幕デザイン(全字幕共通)")
                TextPanelHint(text: "話している言葉に合わせて、文字の色や動きが変わるデザインです。")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CaptionTemplate.allCases) { template in
                            EditorChip(title: template.displayName, isSelected: project.subtitleStyle.template == template) {
                                project.subtitleStyle.template = template
                            }
                        }
                    }
                }
            }

            EditorColorRow(title: "話している言葉の色", color: EditorColorHex.binding($project.subtitleStyle.highlightColorHex))

            EditorFontPickerRow(title: "フォント", fontName: $project.subtitleStyle.fontName)

            if project.subtitleStyle.template != .plain && !hasWordTimings {
                Text("手で入力した字幕はふつうの表示になります。このデザインは「自動字幕」で作った字幕で使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }
}
