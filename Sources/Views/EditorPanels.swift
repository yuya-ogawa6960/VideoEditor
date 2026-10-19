import SwiftUI
import UIKit
import Observation

// =====================================================================
// CapCut 風の小さな下部パネル(ツールバーの位置に差し替えて表示する)
// =====================================================================

/// 下部パネルの種類
enum EditorPanel: Hashable {
    case speed(UUID)
    case volume(UUID)
    case filter(UUID)
    case textEdit(UUID)
    case subtitleStyle
    case aspect
    case bgmVolume

    var title: String {
        switch self {
        case .speed: return "速度"
        case .volume: return "音量"
        case .filter: return "フィルタ"
        case .textEdit: return "テキスト編集"
        case .subtitleStyle: return "字幕スタイル"
        case .aspect: return "比率"
        case .bgmVolume: return "BGM 音量"
        }
    }

    var height: CGFloat {
        switch self {
        case .filter: return 300
        default: return 220
        }
    }

    /// 選択状態が変わったときにこのパネルを開いたままにしてよいか
    func isCompatible(with selection: EditorSelection?) -> Bool {
        switch self {
        case .speed(let id), .volume(let id), .filter(let id):
            return selection == .clip(id)
        case .textEdit(let id):
            return selection == .subtitle(id)
        case .subtitleStyle:
            return selection?.subtitleID != nil
        case .aspect:
            return true
        case .bgmVolume:
            return selection == .bgm
        }
    }
}

/// 時刻表示(m:ss)
enum EditorTimeFormat {
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

// MARK: - 共通部品

/// パネルの外枠(タイトル+✓ボタン+中身)
struct EditorPanelContainer<Content: View>: View {
    let title: String
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    EditorHaptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完了")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.top, 6)

            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color(white: 0.11),
                    in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
    }
}

/// 選択肢チップ
struct EditorChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 対象が見つからないとき
struct EditorMissingPanelContent: View {
    var body: some View {
        Text("対象が見つかりません")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }
}

/// ラベル+値表示つきのスライダー行
struct EditorSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(display)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}

// MARK: - 速度

struct EditorSpeedPanel: View {
    @Binding var clip: Clip

    private let presets: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]

    private func label(for value: Double) -> String {
        switch value {
        case 0.25: return "0.25x"
        case 0.5: return "0.5x"
        case 1.5: return "1.5x"
        default: return "\(Int(value))x"
        }
    }

    /// log2(速度) を -2 ... 2 で操作する(0.25x ... 4x)
    private var logSpeed: Binding<Double> {
        Binding<Double>(
            get: { log2(min(max(clip.speed, 0.25), 4)) },
            set: { newValue in
                let raw = pow(2.0, newValue)
                let rounded = (raw * 20).rounded() / 20
                clip.speed = min(max(rounded, 0.25), 4)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        EditorChip(title: label(for: preset),
                                   isSelected: abs(clip.speed - preset) < 0.001) {
                            clip.speed = preset
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("速度")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", clip.speed))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: logSpeed, in: -2...2)
                    .tint(.white)
                HStack {
                    Text("0.25x")
                    Spacer()
                    Text("1x")
                    Spacer()
                    Text("4x")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Text("長さ \(MediaTimeText.precise(clip.trimmedDuration)) → \(MediaTimeText.precise(clip.outputDuration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

// MARK: - 音量(クリップ)

struct EditorVolumePanel: View {
    @Bindable var project: EditorProject
    @Binding var clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $clip.isMuted) {
                Label("このクリップをミュート", systemImage: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            .disabled(!clip.hasAudio)

            if !clip.hasAudio {
                Text("このクリップには音声がありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            EditorSliderRow(title: "元の音声の音量(全クリップ共通)",
                            value: $project.audio.originalVolume,
                            range: 0...1,
                            display: "\(Int((project.audio.originalVolume * 100).rounded()))%")
        }
        .padding(.top, 6)
    }
}

// MARK: - フィルタ

struct EditorFilterPanel: View {
    let project: EditorProject
    @Binding var clip: Clip

    var body: some View {
        FilterPickerView(filter: $clip.filter,
                         sourceImage: clip.thumbnail,
                         onApplyToAll: {
                             project.applyFilterToAllClips(clip.filter)
                         })
    }
}

// MARK: - テキスト編集(字幕 1 件)

struct EditorTextEditPanel: View {
    @Binding var cue: SubtitleCue

    private var translatedBinding: Binding<String> {
        Binding<String>(
            get: { cue.translatedText ?? "" },
            set: { newValue in
                cue.translatedText = newValue.isEmpty ? nil : newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(MediaTimeText.precise(cue.start)) – \(MediaTimeText.precise(cue.end))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("テキスト")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("字幕を入力", text: $cue.text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("英訳(任意)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Translation", text: translatedBinding, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 字幕スタイル(全字幕共通)

struct EditorSubtitleStylePanel: View {
    @Bindable var project: EditorProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("位置") {
                Picker("位置", selection: $project.subtitleStyle.position) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.segmented)
            }

            row("色") {
                HStack(spacing: 14) {
                    ForEach(SubtitleColor.allCases) { color in
                        let isSelected = project.subtitleStyle.color == color
                        Button {
                            EditorHaptics.tap()
                            project.subtitleStyle.color = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                        .padding(-4)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.displayName)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            EditorSliderRow(title: "文字サイズ",
                            value: $project.subtitleStyle.sizeRatio,
                            range: 0.03...0.10,
                            display: "\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")

            Toggle("背景をつける", isOn: $project.subtitleStyle.hasBackground)
                .font(.subheadline)
                .tint(.accentColor)

            row("表示") {
                Picker("表示", selection: $project.subtitleStyle.displayMode) {
                    ForEach(SubtitleDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.top, 6)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - 比率

struct EditorAspectPanel: View {
    @Bindable var project: EditorProject

    private func shortName(_ aspect: CanvasAspect) -> String {
        switch aspect {
        case .original: return "元のまま"
        case .portrait9x16: return "9:16"
        case .landscape16x9: return "16:9"
        case .square: return "1:1"
        case .portrait4x5: return "4:5"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("画面比率")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CanvasAspect.allCases) { aspect in
                            EditorChip(title: shortName(aspect),
                                       isSelected: project.canvas.aspect == aspect) {
                                project.canvas.aspect = aspect
                            }
                        }
                    }
                }
                Text(project.canvas.aspect.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("はみ出し / 余白の扱い")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScalingMode.allCases) { mode in
                            EditorChip(title: mode.displayName,
                                       isSelected: project.canvas.scaling == mode) {
                                project.canvas.scaling = mode
                            }
                        }
                    }
                }
                .disabled(project.canvas.aspect == .original)
                .opacity(project.canvas.aspect == .original ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - BGM 音量

struct EditorBGMVolumePanel: View {
    @Bindable var project: EditorProject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(project.audio.bgmName ?? "BGM", systemImage: "music.note")
                .font(.subheadline)
                .lineLimit(1)

            EditorSliderRow(title: "BGM の音量",
                            value: $project.audio.bgmVolume,
                            range: 0...1,
                            display: "\(Int((project.audio.bgmVolume * 100).rounded()))%")

            Toggle("最後の 2 秒でフェードアウト", isOn: $project.audio.bgmFadeOut)
                .font(.subheadline)
                .tint(.accentColor)
        }
        .padding(.top, 6)
    }
}
