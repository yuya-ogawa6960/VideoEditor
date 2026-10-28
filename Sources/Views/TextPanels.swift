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
    var title: String = String(localized: "リセット")
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
    /// Google Fonts を探す画面
    @State private var showBrowser = false
    @State private var storedNames: [String] = []
    @State private var errorText: String?

    /// よく使う内蔵フォント(端末にあるものだけ表示)
    private static let builtIn: [(name: String, label: String)] = [
        ("HiraginoSans-W6", String(localized: "ヒラギノ角ゴ(太)")),
        ("HiraginoSans-W3", String(localized: "ヒラギノ角ゴ(細)")),
        ("HiraMinProN-W6", String(localized: "ヒラギノ明朝")),
        ("HiraMaruProN-W4", String(localized: "ヒラギノ丸ゴ")),
        ("AvenirNext-Bold", "Avenir Next"),
        ("Futura-Bold", "Futura"),
        ("Georgia-Bold", "Georgia"),
        ("MarkerFelt-Wide", "Marker Felt"),
        ("ChalkboardSE-Bold", "Chalkboard"),
        ("Menlo-Bold", "Menlo")
    ]

    private var availableBuiltIn: [(name: String, label: String)] {
        BundledFonts.registerAll()
        let bundled: [(name: String, label: String)] = BundledFonts.all.map { (name: $0.name, label: $0.label) }
        return (Self.builtIn + bundled).filter { UIFont(name: $0.name, size: 12) != nil }
    }

    private var currentLabel: String {
        guard let fontName else { return "システム(標準)" }
        if let hit = Self.builtIn.first(where: { $0.name == fontName }) { return hit.label }
        if let hit = BundledFonts.all.first(where: { $0.name == fontName }) { return hit.label }
        return fontName
    }

    private var currentFont: Font {
        if let fontName, UIFont(name: fontName, size: 13) != nil {
            return .custom(fontName, size: 13)
        }
        return .system(size: 13)
    }

    private struct FontEntry: Identifiable {
        let name: String?
        let label: String
        var id: String { name ?? "" }
    }

    /// 一覧に出すフォント(システム → 内蔵 → 読み込んだもの)
    private var entries: [FontEntry] {
        var list: [FontEntry] = [FontEntry(name: nil, label: String(localized: "システム(標準)"))]
        for entry in availableBuiltIn {
            list.append(FontEntry(name: entry.name, label: entry.label))
        }
        for name in storedNames where !list.contains(where: { $0.name == name }) {
            list.append(FontEntry(name: name, label: GoogleFontsService.displayName(forPostScript: name) ?? name))
        }
        if let fontName, !list.contains(where: { $0.name == fontName }) {
            list.append(FontEntry(name: fontName, label: fontName))
        }
        return list
    }

    /// そのフォント自体で書いた見本(フォントが無ければシステム)
    private static func sampleFont(_ name: String?, size: CGFloat) -> Font {
        if let name, UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(currentLabel)
                    .font(currentFont)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            // 各フォントの名前を、そのフォントで表示する(見ながら選べるように)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entries) { entry in
                            let selected: Bool = fontName == entry.name
                            Button {
                                fontName = entry.name
                            } label: {
                                VStack(spacing: 2) {
                                    Text("あAa")
                                        .font(Self.sampleFont(entry.name, size: 20))
                                    Text(entry.label)
                                        .font(Self.sampleFont(entry.name, size: 11))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(selected ? Color.black : Color.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(minWidth: 72, minHeight: 52)
                                .background(selected ? Color.white : Color.white.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                        }
                        Button {
                            showBrowser = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 18))
                                Text("もっと探す")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minWidth: 72, minHeight: 52)
                            .background(BrandStyle.coral.opacity(0.35),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Google Fonts からフォントを探す")
                        Button {
                            showImporter = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 18))
                                Text("読み込む")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minWidth: 72, minHeight: 52)
                            .background(Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("フォントを読み込む(.ttf / .otf)")
                    }
                    .padding(.vertical, 2)
                }
                .onAppear {
                    if let hit = entries.first(where: { $0.name == fontName }) {
                        proxy.scrollTo(hit.id, anchor: .center)
                    }
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
        .sheet(isPresented: $showBrowser) {
            GoogleFontsBrowser { name in
                storedNames = MediaTools.storedFontNames()
                fontName = name
            }
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
                    errorText = String(localized: "フォントを読み込めませんでした: \(error.localizedDescription)")
                }
            case .failure(let error):
                errorText = String(localized: "フォントを読み込めませんでした: \(error.localizedDescription)")
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

    /// タブ。項目が多いので 5 つに分けて、1 画面に収まる量だけ見せる
    private enum Tab: String, CaseIterable, Identifiable {
        case text, font, color, decoration, layout
        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: return String(localized: "テキスト")
            case .font: return String(localized: "フォント")
            case .color: return String(localized: "色")
            case .decoration: return String(localized: "縁・影・背景")
            case .layout: return String(localized: "配置")
            }
        }
    }

    @State private var tab: Tab = .text
    /// 文字の入力中(「完了」でキーボードを閉じる)
    @FocusState private var textFocused: Bool

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
            if text.isSticker {
                textField(title: String(localized: "絵文字"))
                sizeRow
                durationRow
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Tab.allCases) { item in
                            EditorChip(title: item.title, isSelected: tab == item) {
                                tab = item
                            }
                        }
                    }
                }

                switch tab {
                case .text: textTab
                case .font: fontTab
                case .color: colorTab
                case .decoration: decorationTab
                case .layout: layoutTab
                }

                TextPanelResetRow(title: String(localized: "スタイルをリセット")) {
                    text.style = TextStyle.preset(text.template)
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            // 追加したばかり(文字が初期の「テキスト」のまま)のときだけ、すぐ打てるように入力欄を選ぶ。
            // 既存のテキストを開いたときは、キーボードで画面を隠さない
            guard !text.isSticker, tab == .text, text.text == String(localized: "テキスト") else { return }
            Task { @MainActor in
                // パネルが出きってからでないとフォーカスが入らないことがある
                try? await Task.sleep(for: .milliseconds(350))
                textFocused = true
            }
        }
    }

    /// 文字の入力。入力中は右上の「完了」でキーボードを閉じられる
    private func textField(title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                EditorSectionTitle(title: title)
                Spacer()
                if textFocused {
                    Button {
                        textFocused = false
                    } label: {
                        Text("完了")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .padding(.vertical, -14)
                    }
                    .buttonStyle(.plain)
                }
            }
            Group {
                if text.isSticker {
                    TextField(String(localized: "テキストを入力"), text: $text.text)
                } else {
                    TextField(String(localized: "テキストを入力"), text: $text.text, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .focused($textFocused)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sizeRow: some View {
        EditorSliderRow(title: String(localized: "文字サイズ"),
                        value: $text.style.sizeRatio,
                        range: 0.02...0.25,
                        display: "\(Int((text.style.sizeRatio * 1000).rounded()))")
    }

    private var durationRow: some View {
        EditorSliderRow(title: String(localized: "表示時間"),
                        value: $text.duration,
                        range: 0.5...30,
                        display: textPanelSeconds(text.duration))
    }

    /// テキスト: 文字・デザイン・表示時間
    private var textTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            textField(title: String(localized: "テキスト"))

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "デザイン"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TextTemplatePreview.order) { template in
                            EditorVisualTile(title: template.displayName, isSelected: text.template == template) {
                                text.template = template
                                text.style = TextStyle.preset(template)
                            } preview: {
                                TextTemplatePreview(template: template)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            durationRow
        }
    }

    /// フォント: 書体・太字・斜体・文字サイズ
    private var fontTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorFontPickerRow(title: "フォント", fontName: $text.style.fontName)

            HStack(spacing: 8) {
                EditorChip(title: String(localized: "太字"), isSelected: text.style.bold) {
                    text.style.bold.toggle()
                }
                EditorChip(title: String(localized: "斜体"), isSelected: text.style.italic) {
                    text.style.italic.toggle()
                }
                Spacer()
            }

            sizeRow
        }
    }

    /// 色: 文字色(よく使う色のチップ + 自由な色)
    private var colorTab: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorSectionTitle(title: String(localized: "文字色"))
            DrawingColorChips(colorHex: $text.style.colorHex)
        }
    }

    /// 縁・影・背景: それぞれのスイッチと、オンのときだけ出る細かい調整
    private var decorationTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("縁取り", isOn: strokeEnabled)
                .font(.subheadline)
                .tint(.accentColor)
            if text.style.strokeColorHex != nil {
                Group {
                    EditorColorRow(title: String(localized: "色"),
                                   color: EditorColorHex.optionalBinding($text.style.strokeColorHex, fallback: "#000000"))
                    EditorSliderRow(title: String(localized: "太さ"),
                                    value: $text.style.strokeWidth,
                                    range: 0...0.3,
                                    display: textPanelPercent(text.style.strokeWidth))
                }
                .padding(.leading, 12)
            }

            Toggle("影", isOn: $text.style.shadow.enabled)
                .font(.subheadline)
                .tint(.accentColor)
            if text.style.shadow.enabled {
                Group {
                    EditorColorRow(title: String(localized: "色"), color: EditorColorHex.binding($text.style.shadow.colorHex))
                    EditorSliderRow(title: String(localized: "濃さ"),
                                    value: $text.style.shadow.opacity,
                                    range: 0...1,
                                    display: textPanelPercent(text.style.shadow.opacity))
                    EditorSliderRow(title: String(localized: "ぼかし"),
                                    value: $text.style.shadow.radius,
                                    range: 0...0.03,
                                    display: String(format: "%.3f", text.style.shadow.radius))
                    EditorSliderRow(title: String(localized: "ずれ"),
                                    value: $text.style.shadow.offsetY,
                                    range: -0.02...0.02,
                                    display: String(format: "%+.3f", text.style.shadow.offsetY))
                }
                .padding(.leading, 12)
            }

            Toggle("背景", isOn: backgroundEnabled)
                .font(.subheadline)
                .tint(.accentColor)
            if text.style.backgroundColorHex != nil {
                Group {
                    EditorColorRow(title: String(localized: "色"),
                                   color: EditorColorHex.optionalBinding($text.style.backgroundColorHex, fallback: "#000000"))
                    EditorSliderRow(title: String(localized: "濃さ"),
                                    value: $text.style.backgroundOpacity,
                                    range: 0...1,
                                    display: textPanelPercent(text.style.backgroundOpacity))
                    EditorSliderRow(title: String(localized: "余白"),
                                    value: $text.style.backgroundPadding,
                                    range: 0...1,
                                    display: String(format: "%.2f", text.style.backgroundPadding))
                    EditorSliderRow(title: String(localized: "角丸"),
                                    value: $text.style.backgroundCornerRadius,
                                    range: 0...1,
                                    display: String(format: "%.2f", text.style.backgroundCornerRadius))
                }
                .padding(.leading, 12)
            }
        }
    }

    /// 配置: 行ぞろえ・字間・行間・縦書き・曲げる
    private var layoutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "行ぞろえ"))
                HStack(spacing: 8) {
                    ForEach(TextAlignment2.allCases) { alignment in
                        EditorChip(title: alignment.displayName, isSelected: text.style.alignment == alignment) {
                            text.style.alignment = alignment
                        }
                    }
                    Spacer()
                }
            }
            EditorSliderRow(title: String(localized: "字間"),
                            value: $text.style.letterSpacing,
                            range: -0.1...0.5,
                            display: String(format: "%+.2f", text.style.letterSpacing))
            EditorSliderRow(title: String(localized: "行間"),
                            value: $text.style.lineSpacing,
                            range: 0.8...2.0,
                            display: String(format: "%.2f", text.style.lineSpacing))
            Toggle("縦書き", isOn: $text.style.vertical)
                .font(.subheadline)
                .tint(.accentColor)
            EditorSliderRow(title: String(localized: "曲げる"),
                            value: $text.style.curveRadius,
                            range: 0...1,
                            display: text.style.curveRadius <= 0.001 ? String(localized: "直線") : String(format: "%.2f", text.style.curveRadius))
        }
    }
}

// MARK: - テキストのアニメーション

struct EditorTextAnimationPanel: View {
    @Binding var text: TextClip
    /// 選んでいる間、出てくるところ(消えるところ)をプレビューで繰り返すために使う(無ければ繰り返さない)
    var player: PlayerController? = nil

    @State private var side: EditorInOutSide = .enter

    /// いま選んでいる側(イン / アウト)の種類
    private var type: Binding<TextAnimationType> {
        Binding(get: { side == .enter ? text.animIn : text.animOut },
                set: { newValue in
                    if side == .enter {
                        text.animIn = newValue
                    } else {
                        text.animOut = newValue
                    }
                })
    }

    /// いま選んでいる側(イン / アウト)の長さ
    private var duration: Binding<Double> {
        Binding(get: { side == .enter ? text.animInDuration : text.animOutDuration },
                set: { newValue in
                    if side == .enter {
                        text.animInDuration = newValue
                    } else {
                        text.animOutDuration = newValue
                    }
                })
    }

    /// イン: 出てくる 0.5 秒前〜動きの 1 秒後 / アウト: 動きの 1 秒前〜消えた 0.5 秒後
    private var loopRange: ClosedRange<Double> {
        if side == .enter {
            return max(0, text.start - 0.5)...(text.start + text.animInDuration + 1)
        }
        return max(0, text.end - text.animOutDuration - 1)...(text.end + 0.5)
    }

    var body: some View {
        let isNone = type.wrappedValue == .none
        VStack(alignment: .leading, spacing: 14) {
            EditorInOutPicker(side: $side)

            TextAnimationPicker(selection: type, isOut: side == .exit)

            EditorSliderRow(title: String(localized: "長さ"),
                            value: duration,
                            range: 0.1...2.0,
                            display: textPanelSeconds(duration.wrappedValue))
                .disabled(isNone)
                .opacity(isNone ? 0.4 : 1)

            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    text.animIn = .none
                    text.animOut = .none
                }
                .disabled(text.animIn == .none && text.animOut == .none)
                .opacity(text.animIn == .none && text.animOut == .none ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
        // 選んでいる間は、出てくるところ(消えるところ)をプレビューで繰り返し再生する
        .onAppear { player?.startLoop(loopRange) }
        .onChange(of: side) { _, _ in player?.startLoop(loopRange) }
        .onChange(of: text.animInDuration) { _, _ in player?.startLoop(loopRange) }
        .onChange(of: text.animOutDuration) { _, _ in player?.startLoop(loopRange) }
        .onDisappear { player?.stopLoop() }
    }
}

// MARK: - 配置(テキスト)

struct EditorTextPlacementPanel: View {
    @Binding var text: TextClip
    /// 再生位置を知るのに使う(キーフレームのあるテキストは、基本の値ではなく再生位置のキーに書くため)。無ければ先頭(0 秒)のキーに書く
    var player: PlayerController? = nil

    private enum Anchor: String, CaseIterable, Identifiable {
        case center, top, bottom, left, right
        var id: String { rawValue }
        var title: String {
            switch self {
            case .center: return String(localized: "中央")
            case .top: return String(localized: "上")
            case .bottom: return String(localized: "下")
            case .left: return String(localized: "左")
            case .right: return String(localized: "右")
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

    /// キーフレームがあるか。あると描画は基本の値(center / scale / rotation)を見ない(TextRenderer)
    private var isKeyed: Bool { !text.keyframes.isEmpty }

    /// 基本の値(キーフレームを見ない配置)
    private var baseValue: KeyframeInterpolator.Value {
        KeyframeInterpolator.Value(center: text.center, scale: text.scale, rotation: text.rotation, opacity: text.opacity)
    }

    /// キーを書く時刻 = 再生位置の、テキストの先頭からの相対秒(範囲内に丸める。EditorKeyframePanel・プレビューの操作と同じ)
    private var keyTime: Double {
        let now = player?.currentTime ?? text.start
        return min(max(now - text.start, 0), max(text.duration, 0))
    }

    /// スライダーに見せる配置。キーフレームがあれば再生位置の補間値(プレビューの枠と同じ)、無ければ基本の値
    private var shownValue: KeyframeInterpolator.Value {
        guard isKeyed else { return baseValue }
        return KeyframeInterpolator.value(at: keyTime, keyframes: text.keyframes, fallback: baseValue)
    }

    /// キーフレームで動いている値の見出しに ◆ を付ける
    private func keyed(_ title: String) -> String {
        isKeyed ? "◆ " + title : title
    }

    private var isDefault: Bool {
        let shown = shownValue
        return shown.center == NormalizedPoint(x: 0.5, y: 0.5) && shown.scale == 1 && shown.rotation == 0
            && text.widthRatio == 0.8 && text.opacity == 1
    }

    var body: some View {
        let shown = shownValue
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "位置"))
                HStack(spacing: 8) {
                    ForEach(Anchor.allCases) { anchor in
                        EditorChip(title: anchor.title,
                                   isSelected: abs(shown.center.x - anchor.point.x) < 0.01 && abs(shown.center.y - anchor.point.y) < 0.01) {
                            updatePlacement { $0.center = anchor.point }
                        }
                    }
                    Spacer()
                }
            }

            EditorSliderRow(title: keyed(String(localized: "横位置")),
                            value: placementBinding(\.center.x),
                            range: 0...1,
                            display: textPanelPercent(shown.center.x))
            EditorSliderRow(title: keyed(String(localized: "縦位置")),
                            value: placementBinding(\.center.y),
                            range: 0...1,
                            display: textPanelPercent(shown.center.y))
            EditorSliderRow(title: keyed(String(localized: "大きさ")),
                            value: placementBinding(\.scale),
                            range: 0.2...4,
                            display: String(format: "%.2fx", shown.scale))
            EditorSliderRow(title: keyed(String(localized: "回転")),
                            value: placementBinding(\.rotation),
                            range: -180...180,
                            display: String(format: "%.0f°", shown.rotation))
            if !text.isSticker {
                EditorSliderRow(title: String(localized: "折り返し幅"),
                                value: $text.widthRatio,
                                range: 0.2...1,
                                display: textPanelPercent(text.widthRatio))
            }
            EditorSliderRow(title: String(localized: "不透明度"),
                            value: $text.opacity,
                            range: 0...1,
                            display: textPanelPercent(text.opacity))

            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    updatePlacement {
                        $0.center = NormalizedPoint(x: 0.5, y: 0.5)
                        $0.scale = 1
                        $0.rotation = 0
                    }
                    text.widthRatio = 0.8
                    text.opacity = 1
                }
                .disabled(isDefault)
                .opacity(isDefault ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }

    /// 配置の 1 成分(横位置・縦位置・大きさ・回転)のスライダー用 Binding。見せる値は shownValue、書き込みは updatePlacement
    private func placementBinding(_ keyPath: WritableKeyPath<KeyframeInterpolator.Value, Double>) -> Binding<Double> {
        Binding(get: { shownValue[keyPath: keyPath] },
                set: { newValue in updatePlacement { $0[keyPath: keyPath] = newValue } })
    }

    /// 位置・大きさ・回転を直す。キーフレームが無ければ基本の値に書く。
    /// あれば基本の値は変えず、再生位置のキーへ書く(プレビューの操作と同じ KeyframeEditing:
    /// 大きさ・角度が全キーで同じなら差分を全キーにかけ、位置は再生位置のキーを置き換え / 追加)
    private func updatePlacement(_ change: (inout KeyframeInterpolator.Value) -> Void) {
        let time = keyTime
        let start = shownValue
        var value = start
        change(&value)
        guard isKeyed else {
            text.center = value.center
            text.scale = value.scale
            text.rotation = value.rotation
            return
        }
        // 書く時刻と再生位置がずれないように、再生中なら止める(プレビューの操作と同じ)
        if let player, player.isPlaying { player.pause() }
        text.keyframes = KeyframeEditing.applying(value, from: start, at: time, to: text.keyframes)
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

    /// 再生位置にあるキーフレーム(KeyframeEditing.sameTimeTolerance 秒以内。プレビューの操作と同じ基準)
    private var keyframeAtPlayhead: Keyframe? {
        keyframes.first { abs($0.time - playheadRelative) < KeyframeEditing.sameTimeTolerance }
    }

    private var previousKeyframe: Keyframe? {
        sorted.last { $0.time < playheadRelative - KeyframeEditing.sameTimeTolerance }
    }

    private var nextKeyframe: Keyframe? {
        sorted.first { $0.time > playheadRelative + KeyframeEditing.sameTimeTolerance }
    }

    var body: some View {
        let atPlayhead = keyframeAtPlayhead
        VStack(alignment: .leading, spacing: 14) {
            // 前へ / 追加・削除 / 次へ(業務用ソフトと同じ並び)
            HStack(spacing: 6) {
                navigationButton(systemImage: "chevron.left", target: previousKeyframe,
                                 label: String(localized: "前のキーフレーム"))
                Button {
                    EditorHaptics.tap()
                    if let atPlayhead {
                        keyframes.removeAll { $0.id == atPlayhead.id }
                        if selectedID == atPlayhead.id { selectedID = nil }
                    } else {
                        addAtPlayhead()
                    }
                } label: {
                    Image(systemName: atPlayhead == nil ? "plus.diamond" : "diamond.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(atPlayhead == nil ? Color.white : BrandStyle.coral)
                        .frame(width: 52, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(atPlayhead == nil ? String(localized: "キーフレームを追加") : String(localized: "キーフレームを削除"))
                navigationButton(systemImage: "chevron.right", target: nextKeyframe,
                                 label: String(localized: "次のキーフレーム"))
                Text(verbatim: String(format: "%.2fs", playheadRelative))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if !keyframes.isEmpty {
                    Button(role: .destructive) {
                        EditorHaptics.tap()
                        keyframes.removeAll()
                        selectedID = nil
                    } label: {
                        Text("すべて削除")
                            .font(.caption)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.red.opacity(0.85))
                }
            }

            if sorted.isEmpty {
                Text("キーフレームなし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sorted) { keyframe in
                            chip(keyframe)
                        }
                    }
                }
            }

            if let selected {
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: String(localized: "イージング"))
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

    private func navigationButton(systemImage: String, target: Keyframe?, label: String) -> some View {
        Button {
            guard let target else { return }
            EditorHaptics.tap()
            selectedID = target.id
            player.seek(to: start + target.time)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? Color.white.opacity(0.25) : Color.white)
        .disabled(target == nil)
        .accessibilityLabel(label)
    }

    /// キーフレームの時刻のチップ(押すとその時刻へ移動して選ぶ)
    private func chip(_ keyframe: Keyframe) -> some View {
        let isSelected = keyframe.id == selectedID
        return Button {
            EditorHaptics.tap()
            selectedID = keyframe.id
            player.seek(to: start + keyframe.time)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                Text(verbatim: String(format: "%.2fs", keyframe.time))
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.white.opacity(0.1), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 再生位置に、いまの配置のキーを必ず置く(近くにあれば id・イージングを引き継いで置き換え)。
    /// KeyframeEditing.applying は「変わった分だけ」を書く(変化が無ければ何もしない・全キーで同じ大きさ・角度は
    /// 全キーにかける・キーが無ければ追加しない)ので、この操作には使わず、同じ時刻の基準(sameTimeTolerance)だけ共有する
    private func addAtPlayhead() {
        let t = playheadRelative
        var keyframe = Keyframe(time: t,
                                center: currentValue.center,
                                scale: currentValue.scale,
                                rotation: currentValue.rotation,
                                opacity: currentValue.opacity)
        if let existing = keyframes.first(where: { abs($0.time - t) < KeyframeEditing.sameTimeTolerance }) {
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
        (String(localized: "通常"), nil),
        (String(localized: "乗算"), "CIMultiplyBlendMode"),
        (String(localized: "スクリーン"), "CIScreenBlendMode"),
        (String(localized: "オーバーレイ"), "CIOverlayBlendMode"),
        (String(localized: "ソフトライト"), "CISoftLightBlendMode"),
        (String(localized: "比較(明)"), "CILightenBlendMode")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {


            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(modes, id: \.title) { mode in
                        EditorChip(title: mode.title, isSelected: overlay.blendMode == mode.filter) {
                            overlay.blendMode = mode.filter
                        }
                    }
                }
            }

            EditorSliderRow(title: String(localized: "不透明度"),
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
            VStack(alignment: .leading, spacing: 4) {
                EditorSectionTitle(title: String(localized: "色"))
                DrawingColorChips(colorHex: $colorHex)
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "太さ"))
                HStack(spacing: 8) {
                    EditorChip(title: String(localized: "細"), isSelected: abs(width - 0.006) < 0.0005) { width = 0.006 }
                    EditorChip(title: String(localized: "中"), isSelected: abs(width - 0.012) < 0.0005) { width = 0.012 }
                    EditorChip(title: String(localized: "太"), isSelected: abs(width - 0.024) < 0.0005) { width = 0.024 }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Slider(value: $width, in: 0.003...0.04)
                        .tint(.white)
                    Text(String(format: "%.1f", width * 1000))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }

            HStack(spacing: 10) {
                EditorPillButton(title: String(localized: "1つ戻す"), systemImage: "arrow.uturn.backward") {
                    if !strokes.isEmpty { strokes.removeLast() }
                }
                .disabled(strokes.isEmpty)
                .opacity(strokes.isEmpty ? 0.4 : 1)
                EditorPillButton(title: String(localized: "全部消す"), systemImage: "trash", tint: .red) {
                    strokes.removeAll()
                }
                .disabled(strokes.isEmpty)
                .opacity(strokes.isEmpty ? 0.4 : 1)
                Spacer()
                EditorPillButton(title: String(localized: "キャンセル"), systemImage: "xmark") {
                    onCancel()
                }
                EditorPillButton(title: String(localized: "完了"), systemImage: "checkmark", prominent: true) {
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

            VStack(alignment: .leading, spacing: 4) {
                EditorSectionTitle(title: String(localized: "色"))
                DrawingColorChips(colorHex: colorBinding)
            }

            EditorSliderRow(title: String(localized: "太さ"),
                            value: widthBinding,
                            range: 0.003...0.04,
                            display: String(format: "%.1f", widthBinding.wrappedValue * 1000))

            HStack {
                EditorPillButton(title: String(localized: "最後の線を消す"), systemImage: "arrow.uturn.backward") {
                    if !drawing.strokes.isEmpty { drawing.strokes.removeLast() }
                }
                .disabled(drawing.strokes.isEmpty)
                .opacity(drawing.strokes.isEmpty ? 0.4 : 1)
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
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

            EditorSliderRow(title: String(localized: "表示時間"),
                            value: $drawing.duration,
                            range: 0.5...15,
                            display: textPanelSeconds(drawing.duration))
            EditorSliderRow(title: String(localized: "線が描かれていく時間"),
                            value: $drawing.revealDuration,
                            range: 0...3,
                            display: textPanelSeconds(drawing.revealDuration))

            HStack {
                EditorPillButton(title: String(localized: "再生位置から始める"), systemImage: "arrow.right.to.line") {
                    drawing.start = max(0, player.currentTime)
                }
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
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
                Image(systemName: EditorMarkerKindPanel.icon(marker.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(marker.kind.displayName)
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text(MediaTimeText.precise(marker.time))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            EditorTextFieldRow(title: String(localized: "名前"), placeholder: marker.kind == .chapter ? String(localized: "例: オープニング") : String(localized: "メモ"), text: $marker.name)

            HStack(spacing: 10) {
                EditorPillButton(title: String(localized: "再生位置へ移す"), systemImage: "arrow.right.to.line") {
                    marker.time = max(0, player.currentTime)
                    project.sortMarkers()
                }
                if marker.kind == .chapter {
                    EditorPillButton(title: copied ? String(localized: "コピーしました") : String(localized: "チャプター一覧をコピー"), systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = project.chapterListText()
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }
                }
                Spacer()
            }

            if marker.kind == .chapter {
                VStack(alignment: .leading, spacing: 4) {
                    EditorSectionTitle(title: String(localized: "チャプター一覧"))
                    Text(chapterPreview)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
    }
}

struct EditorMarkerKindPanel: View {
    @Binding var marker: TimelineMarker

    static func icon(_ kind: MarkerKind) -> String {
        switch kind {
        case .note: return "note.text"
        case .chapter: return "list.number"
        case .beat: return "metronome"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(MarkerKind.allCases) { kind in
                    let selected = marker.kind == kind
                    Button {
                        EditorHaptics.tap()
                        marker.kind = kind
                    } label: {
                        Label(kind.displayName, systemImage: Self.icon(kind))
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .padding(.vertical, -7)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            if marker.kind == .note {
                Text("書き出しには映りません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    @State private var presetStore = WatermarkPresetStore.shared

    /// いまの設定に保存できる中身(画像か文字)があるか
    private var hasContent: Bool {
        project.watermark.imageURL != nil || !project.watermark.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 文字を入れるか画像を選ぶと自動でオンになる(スイッチはその下)
            EditorTextFieldRow(title: String(localized: "テキスト"),
                               placeholder: String(localized: "例: @channel_name"),
                               text: $project.watermark.text)

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "画像"))
                HStack(spacing: 10) {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                        Label(project.watermark.imageURL == nil ? String(localized: "画像を選ぶ") : String(localized: "画像を変える"), systemImage: "photo")
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
                        EditorPillButton(title: String(localized: "画像を外す"), systemImage: "xmark") {
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

            Toggle(isOn: $project.watermark.enabled) {
                Label("ロゴ・透かしを入れる", systemImage: "seal")
                    .font(.subheadline)
            }
            .tint(.accentColor)

            Group {
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: String(localized: "位置"))
                    HStack(spacing: 8) {
                        ForEach(WatermarkCorner.allCases) { corner in
                            EditorChip(title: corner.displayName, isSelected: project.watermark.corner == corner) {
                                project.watermark.corner = corner
                            }
                        }
                        Spacer()
                    }
                }

                EditorSliderRow(title: String(localized: "不透明度"),
                                value: $project.watermark.opacity,
                                range: 0.05...1,
                                display: textPanelPercent(project.watermark.opacity))
                EditorSliderRow(title: String(localized: "サイズ"),
                                value: $project.watermark.sizeRatio,
                                range: 0.05...1,
                                display: textPanelPercent(project.watermark.sizeRatio))
                TextPanelResetRow {
                    project.watermark.opacity = 0.6
                    project.watermark.sizeRatio = 0.18
                    project.watermark.corner = .bottomRight
                }
            }
            .disabled(!project.watermark.enabled)
            .opacity(project.watermark.enabled ? 1 : 0.4)

            // 自分用に保存したロゴ(最大 5 件)。タップで使う、長押しで消す
            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "保存したロゴ"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presetStore.presets) { preset in
                            Button {
                                EditorHaptics.tap()
                                project.watermark = presetStore.settings(from: preset)
                                loadThumbnail()
                            } label: {
                                WatermarkPresetTile(preset: preset, image: presetStore.thumbnail(of: preset))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    presetStore.remove(preset)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                        EditorPillButton(title: String(localized: "いまの設定を保存"), systemImage: "plus") {
                            presetStore.save(project.watermark)
                        }
                        .disabled(presetStore.isFull || !hasContent)
                        .opacity(presetStore.isFull || !hasContent ? 0.4 : 1)
                    }
                }
                TextPanelHint(text: presetStore.isFull
                              ? String(localized: "5 件まで保存できます。消すには長押しします。")
                              : String(localized: "タップで使います。消すには長押しします。"))
            }
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
        // 文字を入れたら自動でオンにする(消したときはそのまま。オン・オフはスイッチで)
        .onChange(of: project.watermark.text) { _, value in
            if !value.trimmingCharacters(in: .whitespaces).isEmpty, !project.watermark.enabled {
                project.watermark.enabled = true
            }
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
                errorText = String(localized: "画像を取得できませんでした。")
            }
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

/// 保存したロゴの 1 枚(画像があれば画像、なければ文字)
private struct WatermarkPresetTile: View {
    let preset: WatermarkPresetStore.Preset
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Text(preset.text.isEmpty ? "Aa" : preset.text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(4)
            }
        }
        .frame(width: 56, height: 56)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - パーツ(オープニング・クロージング・ディバイダー)

/// パーツの保存フォームの入力。パネルを閉じても消えないよう、アプリを終了するまで残す
enum FormatKitDraft {
    static var name = ""
    static var kind: FormatKind = .opening
}

struct EditorFormatKitPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// クリップを選択中ならその範囲を「保存」に使う
    let selectedClipID: UUID?

    @State private var saveName = FormatKitDraft.name
    @State private var saveKind: FormatKind = FormatKitDraft.kind
    @State private var message: String?
    /// 削除の確認を出しているパーツ
    @State private var deleteTarget: FormatBlock?

    private var store: FormatKitStore { FormatKitStore.shared }

    private var canSave: Bool { !saveName.trimmingCharacters(in: .whitespaces).isEmpty }

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
            // 今の範囲を保存(いつも見えるように先頭に。名前を入れて Return でも保存できる)
            VStack(alignment: .leading, spacing: 8) {
                EditorSectionTitle(title: String(localized: "今の範囲を保存"))
                Text("\(MediaTimeText.precise(saveRange.lowerBound)) – \(MediaTimeText.precise(saveRange.upperBound))" + (selectedClipID != nil ? String(localized: "(選択中のクリップ)") : String(localized: "(先頭から再生位置まで)")))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                EditorTextFieldRow(title: String(localized: "名前"), placeholder: String(localized: "例: いつものオープニング"), text: $saveName)
                    .onSubmit { save() }
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
                    EditorPillButton(title: String(localized: "保存"), systemImage: "checkmark", prominent: true) {
                        save()
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 保存したパーツ(種類ごと)
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
                Text("保存したパーツはまだありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        // 閉じても入力が消えないように残す
        .onChange(of: saveName) { _, value in FormatKitDraft.name = value }
        .onChange(of: saveKind) { _, value in FormatKitDraft.kind = value }
        .confirmationDialog("このパーツを削除しますか?",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteTarget) { block in
            Button("削除", role: .destructive) {
                store.delete(block)
            }
            Button("キャンセル", role: .cancel) {}
        }
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
                        deleteTarget = block
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
                EditorChip(title: String(localized: "先頭に挿入"), isSelected: false) {
                    insert(block, at: 0)
                }
                EditorChip(title: String(localized: "再生位置に挿入"), isSelected: false) {
                    insert(block, at: max(0, player.currentTime))
                }
                EditorChip(title: String(localized: "末尾に挿入"), isSelected: false) {
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
        message = String(localized: "「\(block.name)」を挿入しました。")
    }

    private func save() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let block = store.captureFromProject(project, range: saveRange, kind: saveKind, name: name)
        if !store.blocks.contains(where: { $0.id == block.id }) {
            store.add(block)
        }
        saveName = ""
        FormatKitDraft.name = ""
        message = String(localized: "「\(name)」を\(saveKind.displayName)として保存しました。")
    }
}

// MARK: - 読み上げ(テキスト → ナレーション)

/// 読み上げパネルの入力。パネルを閉じても消えないよう、アプリを終了するまで残す
enum TextToSpeechDraft {
    static var text = ""
    static var language = "ja-JP"
    static var voiceID: String?
    static var cloudVoice: CloudVoice?
    static var instructions = ""
    static var voiceEffect: VoicePreset = .none
    static var rate: Float = 0.5
    static var pitch: Float = 1.0
}

struct EditorTextToSpeechPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// 追加したナレーションの ID(選択に使う)
    let onAdded: (UUID) -> Void

    @State private var text = TextToSpeechDraft.text
    @State private var language = TextToSpeechDraft.language
    @State private var voices: [(id: String, name: String)] = []
    @State private var voiceID: String? = TextToSpeechDraft.voiceID
    /// 「読み方の登録」を開いている
    @State private var showsReadings = false
    /// クラウドの声(nil なら端末の声)
    @State private var cloudVoice: CloudVoice? = TextToSpeechDraft.cloudVoice
    /// クラウドの声への話し方の指示(「元気に」「ささやくように」など)
    @State private var instructions = TextToSpeechDraft.instructions
    /// 作ったナレーションにかける声の雰囲気(音声効果)
    @State private var voiceEffect: VoicePreset = TextToSpeechDraft.voiceEffect
    @State private var personalVoiceAuthorized = TextToSpeech.personalVoiceAuthorized
    @State private var rate: Float = TextToSpeechDraft.rate
    @State private var pitch: Float = TextToSpeechDraft.pitch
    @State private var isRendering = false
    @State private var errorText: String?
    /// エラーの直し方。サインインやポイント不足なら「アカウントとポイント」への入り口を出す
    @State private var recovery: CloudAIRecovery = .none
    @State private var showsAccount = false
    @State private var resultText: String?
    /// 声の追加のしかたを出している
    @State private var showsVoiceHelp = false

    private var choice: TTSVoiceChoice {
        if let cloudVoice { return .cloud(cloudVoice) }
        return .device(voiceID)
    }

    /// Google の声(「AIボイス 日本語」)が使えるか(サーバーの設定。AccountService.googleVoicesAvailable)
    private var googleVoicesAvailable: Bool {
        AccountService.shared.googleVoicesAvailable
    }

    private var rateText: String {
        if rate < 0.45 { return String(localized: "ゆっくり") }
        if rate > 0.55 { return String(localized: "速め") }
        return String(localized: "ふつう")
    }

    private var pitchText: String {
        if pitch < 0.9 { return String(localized: "低め") }
        if pitch > 1.1 { return String(localized: "高め") }
        return String(localized: "ふつう")
    }

    private var currentVoiceName: String {
        if let cloudVoice { return cloudVoice.displayName }
        guard let voiceID, let voice = voices.first(where: { $0.id == voiceID }) else { return String(localized: "標準の声") }
        return voice.name
    }

    /// クラウドの声で使う見込みのポイント(1000 文字ごとに 1pt)。自分の OpenAI キーや端末の声なら nil
    private var estimatedPoints: Int? {
        // Google の声はポイントでだけ使える(TextToSpeech の googleNeedsPoints)
        guard let cloudVoice, cloudVoice.isGoogle || CloudAIGateway.prefersPoints else { return nil }
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return max(1, (count + 999) / 1000)
    }

    private var renderTitle: String {
        if isRendering { return String(localized: "作成中…") }
        if let points = estimatedPoints { return String(localized: "読み上げて追加 ・ \(points)pt") }
        return String(localized: "読み上げて追加")
    }

    private var canRender: Bool {
        !isRendering && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 「アカウントとポイント」で直せるエラーか
    private var needsAccount: Bool {
        switch recovery {
        case .signIn, .points: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorTextFieldRow(title: String(localized: "読み上げる文章"), placeholder: String(localized: "ここに入力"), text: $text, multiline: true)

            voiceSection

            // 作る(いちばん大事な操作なので、文章と声のすぐ下に大きく)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    render()
                } label: {
                    HStack(spacing: 8) {
                        if isRendering {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "waveform.badge.plus")
                        }
                        Text(renderTitle)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(BrandStyle.coral, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRender)
                .opacity(canRender || isRendering ? 1 : 0.45)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if needsAccount {
                        EditorPillButton(title: String(localized: "アカウントとポイント"), systemImage: "person.crop.circle") {
                            showsAccount = true
                        }
                    }
                } else if let resultText {
                    Label(resultText, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            adjustmentSection
        }
        .padding(.top, 6)
        .onAppear {
            reloadVoices()
            // Google の声が使えない設定なら、前に選んでいた Google の声は OpenAI の声に戻す
            if cloudVoice?.isGoogle == true, !googleVoicesAvailable {
                cloudVoice = .alloy
            }
        }
        // 閉じても入力が消えないように残す
        .onChange(of: text) { _, value in TextToSpeechDraft.text = value }
        .onDisappear(perform: saveDraft)
        .sheet(isPresented: $showsAccount) {
            AccountPointsSheet()
        }
        .sheet(isPresented: $showsReadings) {
            NavigationStack {
                ReadingListView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了") { showsReadings = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    /// 声: 端末の声(無料)・OpenAI・Google。右上で声を選ぶ
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EditorSectionTitle(title: String(localized: "声"))
                Spacer()
                Menu {
                    if cloudVoice == nil {
                        Button(String(localized: "標準の声")) { voiceID = nil }
                        ForEach(voices, id: \.id) { voice in
                            Button(voice.name) { voiceID = voice.id }
                        }
                        Divider()
                        Button(String(localized: "声を追加する"), systemImage: "plus") { showsVoiceHelp = true }
                    } else {
                        // Google の声の一覧はサーバーで使える設定のときだけ
                        ForEach(cloudVoice?.isGoogle == true && googleVoicesAvailable ? CloudVoice.googleVoices : CloudVoice.openAIVoices) { voice in
                            Button(voice.displayName) { cloudVoice = voice }
                        }
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
            HStack(spacing: 8) {
                EditorChip(title: String(localized: "標準"), isSelected: cloudVoice == nil) {
                    cloudVoice = nil
                }
                EditorChip(title: String(localized: "AIボイス"), isSelected: cloudVoice.map { !$0.isGoogle } ?? false) {
                    if cloudVoice == nil || cloudVoice?.isGoogle == true { cloudVoice = .alloy }
                }
                if googleVoicesAvailable {
                    EditorChip(title: String(localized: "AIボイス 日本語"), isSelected: cloudVoice?.isGoogle ?? false) {
                        if cloudVoice?.isGoogle != true { cloudVoice = .googleAoede }
                    }
                }
                Spacer()
            }
            if cloudVoice == nil {
                if !personalVoiceAuthorized && !TextToSpeech.personalVoiceDenied {
                    EditorPillButton(title: String(localized: "自分の声を使う"), systemImage: "person.wave.2") {
                        Task { @MainActor in
                            personalVoiceAuthorized = await TextToSpeech.requestPersonalVoice()
                            reloadVoices()
                        }
                    }
                }
                if showsVoiceHelp {
                    TextPanelHint(text: String(localized: "設定 › アクセシビリティ › 読み上げコンテンツ › 声"))
                }
            } else if cloudVoice?.isGoogle != true {
                EditorTextFieldRow(title: String(localized: "話し方"),
                                   placeholder: String(localized: "例: 元気に、ささやくように"),
                                   text: $instructions)
            }
        }
    }

    /// 細かい調整(言語・声の雰囲気・速さ・高さ・読み方)
    private var adjustmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorSectionTitle(title: String(localized: "細かい調整"))

            HStack(spacing: 8) {
                EditorChip(title: String(localized: "日本語"), isSelected: language == "ja-JP") {
                    language = "ja-JP"
                    reloadVoices()
                }
                EditorChip(title: "English", isSelected: language == "en-US") {
                    language = "en-US"
                    reloadVoices()
                }
                Spacer()
            }

            // 声の雰囲気(作ったナレーションにかける音声効果)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VoicePreset.allCases) { preset in
                        EditorChip(title: preset == .none ? String(localized: "そのまま") : preset.displayName,
                                   isSelected: voiceEffect == preset) {
                            voiceEffect = preset
                        }
                    }
                }
            }

            EditorSliderRow(title: String(localized: "話す速さ"),
                            value: $rate,
                            range: 0.3...0.7,
                            display: rateText)
            EditorSliderRow(title: String(localized: "声の高さ"),
                            value: $pitch,
                            range: 0.6...1.6,
                            display: pitchText)
                .disabled(cloudVoice != nil)
                .opacity(cloudVoice != nil ? 0.4 : 1)

            HStack(spacing: 10) {
                // 声が読み間違える言葉(家系ラーメン → けけい など)は、読み方を登録して直す
                EditorPillButton(title: String(localized: "読み方の登録"), systemImage: "character.book.closed") {
                    showsReadings = true
                }
                Spacer()
            }
            TextPanelResetRow {
                rate = 0.5
                pitch = 1.0
                voiceEffect = .none
                instructions = ""
            }
        }
    }

    /// 入力と選んだ声を残す(パネルを閉じても次に開いたときにそのまま)
    private func saveDraft() {
        TextToSpeechDraft.text = text
        TextToSpeechDraft.language = language
        TextToSpeechDraft.voiceID = voiceID
        TextToSpeechDraft.cloudVoice = cloudVoice
        TextToSpeechDraft.instructions = instructions
        TextToSpeechDraft.voiceEffect = voiceEffect
        TextToSpeechDraft.rate = rate
        TextToSpeechDraft.pitch = pitch
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
        recovery = .none
        resultText = nil
        let startTime = max(0, player.currentTime)
        let chosen = choice
        let chosenRate = rate
        let chosenPitch = pitch
        let chosenInstructions = instructions
        let chosenEffect = voiceEffect
        Task { @MainActor in
            // クラウドの声(OpenAI / Google)に送る前の、初回だけの確認(CloudAIGateway.ensureConsent)
            if chosen.isCloud {
                let agreed = await CloudAIGateway.ensureConsent()
                if !agreed {
                    isRendering = false
                    return
                }
            }
            do {
                let url = try await TextToSpeech.render(choice: chosen, text: content, rate: chosenRate,
                                                        pitch: chosenPitch, instructions: chosenInstructions)
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                let duration = (seconds.isFinite && seconds > 0) ? seconds : 1
                history.record(project)
                let name = String(localized: "読み上げ: ") + String(content.prefix(12))
                var clip = NarrationClip(url: url, name: name, start: startTime, duration: duration)
                clip.effects.voicePreset = chosenEffect
                project.narration.append(clip)
                project.sortNarration()
                resultText = String(localized: "\(MediaTimeText.precise(startTime)) に \(String(format: "%.1f", duration)) 秒のナレーションを追加しました。")
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == content { text = "" }
                if TextToSpeechDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == content {
                    TextToSpeechDraft.text = ""
                }
                onAdded(clip.id)
            } catch {
                // moderation が止めた内容(ScriptWriter.swift)はその文だけ(ScriptWriterView.presentError と同じ)
                if error is CloudAIModerationError {
                    errorText = error.localizedDescription
                    recovery = .none
                } else {
                    errorText = String(localized: "読み上げを作成できませんでした: \(error.localizedDescription)")
                    recovery = CloudAIGateway.recovery(for: error)
                }
            }
            isRendering = false
        }
    }
}

// MARK: - 字幕テンプレート

struct EditorCaptionTemplatePanel: View {
    @Bindable var project: EditorProject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CaptionTemplatePicker(selection: $project.subtitleStyle.template)

            EditorColorRow(title: String(localized: "強調色"), color: EditorColorHex.binding($project.subtitleStyle.highlightColorHex))

            EditorFontPickerRow(title: "フォント", fontName: $project.subtitleStyle.fontName)
        }
        .padding(.top, 6)
    }
}

// MARK: - オーバーレイの不透明度

/// 重ねた素材(オーバーレイ)の不透明度。スライダーと数字だけ(タイトルに名前が出るので、説明や見出しは重ねない)
struct EditorOverlayOpacityPanel: View {
    @Binding var overlay: OverlayClip

    var body: some View {
        HStack(spacing: 16) {
            Slider(value: $overlay.opacity, in: 0...1)
                .tint(.white)
            Text(verbatim: "\(Int((overlay.opacity * 100).rounded()))")
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.top, 20)
    }
}

// MARK: - テキストのデザインの見本

/// テキストのデザインを小さな画面に「Aa」で見せる(TextStyle.preset の色・縁・背景をざっくり再現)
struct TextTemplatePreview: View {
    let template: TextTemplate

    /// ショートでよく使うものを前に
    static let order: [TextTemplate] = [
        .bigImpact, .headline, .caption, .neon, .handwritten, .plain, .subtitleBox, .newsBar, .quote, .minimalSerif
    ]

    var body: some View {
        let style = TextStyle.preset(template)
        let fill = EditorColorHex.color(style.colorHex)
        let stroke = style.strokeColorHex.map { EditorColorHex.color($0, fallback: .black) }
        let fontSize: CGFloat = template == .bigImpact ? 20 : (style.sizeRatio >= 0.07 ? 17 : 14)
        ZStack {
            LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.55), Color(red: 0.16, green: 0.2, blue: 0.26)],
                           startPoint: .top, endPoint: .bottom)
            Text("Aa")
                .font(previewFont(style, size: fontSize))
                .foregroundStyle(fill)
                .shadow(color: stroke ?? .clear, radius: 0, x: 1, y: 1)
                .shadow(color: stroke ?? .clear, radius: 0, x: -1, y: -1)
                .shadow(color: stroke ?? .clear, radius: 0, x: 1, y: -1)
                .shadow(color: stroke ?? .clear, radius: 0, x: -1, y: 1)
                .shadow(color: template == .neon ? fill : (style.shadow.enabled && stroke == nil && style.backgroundColorHex == nil ? .black.opacity(0.6) : .clear),
                        radius: template == .neon ? 4 : 1)
                .padding(.horizontal, style.backgroundColorHex == nil ? 0 : 6)
                .padding(.vertical, style.backgroundColorHex == nil ? 0 : 2)
                .background {
                    if let bg = style.backgroundColorHex {
                        RoundedRectangle(cornerRadius: CGFloat(style.backgroundCornerRadius) * 10)
                            .fill(EditorColorHex.color(bg, fallback: .black).opacity(style.backgroundOpacity))
                    }
                }
        }
    }

    private func previewFont(_ style: TextStyle, size: CGFloat) -> Font {
        if let name = style.fontName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: style.bold ? .heavy : .regular)
    }
}
