import SwiftUI

// =====================================================================
// レタッチのパネル(クリップの「AI」、画質補正のとなり)。
// 顔 / メイク / 体型 を切り替えて、それぞれのスライダーで強さを決める(0 = 何もしない)。
// 顔はプレビューのたびに自動で探す。かんたんな美肌は「画質補正」にある。
// =====================================================================

struct EditorRetouchPanel: View {
    @Binding var clip: Clip

    @State private var group: RetouchGroup = .face

    private func binding(_ keyPath: WritableKeyPath<ClipRetouch, Double>) -> Binding<Double> {
        Binding<Double>(get: { clip.retouch[keyPath: keyPath] },
                        set: { clip.retouch[keyPath: keyPath] = $0 })
    }

    private var lipColorBinding: Binding<String> {
        Binding<String>(get: { clip.retouch.lipColorHex }, set: { clip.retouch.lipColorHex = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(RetouchGroup.allCases) { item in
                    EditorChip(title: item.displayName, isSelected: group == item) {
                        group = item
                    }
                }
                Spacer(minLength: 0)
            }

            switch group {
            case .face:
                slider(String(localized: "小顔"), \.slimFace)
                slider(String(localized: "目を大きく"), \.bigEyes)
                slider(String(localized: "鼻を細く"), \.slimNose)
                slider(String(localized: "口角アップ"), \.smile)
            case .makeup:
                slider(String(localized: "リップ"), \.lip)
                lipColors
                slider(String(localized: "チーク"), \.blush)
                slider(String(localized: "歯を白く"), \.whitenTeeth)
            case .body:
                slider(String(localized: "スリム"), \.slimBody)
                slider(String(localized: "脚長"), \.longLegs)
                ClipFXHint(text: String(localized: "全身が写っている動画で使います。まわりの背景も少し動きます。"))
            }

            HStack {
                Text("顔は自動で探します。プレビューは重くなることがあります")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.retouch.reset(group)
                }
                .disabled(clip.retouch.isZero(group))
                .opacity(clip.retouch.isZero(group) ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<ClipRetouch, Double>) -> some View {
        EditorSliderRow(title: title,
                        value: binding(keyPath),
                        range: 0...1,
                        display: "\(Int((clip.retouch[keyPath: keyPath] * 100).rounded()))")
    }

    /// リップの色(候補 + 自由に選ぶ)
    private var lipColors: some View {
        HStack(spacing: 10) {
            ForEach(ClipRetouch.lipPresets, id: \.self) { hex in
                let selected = clip.retouch.lipColorHex.uppercased() == hex.uppercased()
                Button {
                    EditorHaptics.tap()
                    clip.retouch.lipColorHex = hex
                    // 色を選んだら、リップが 0 のときは見えるようにする
                    if clip.retouch.lip < 0.001 { clip.retouch.lip = 0.5 }
                } label: {
                    Circle()
                        .fill(EditorColorHex.color(hex))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.white, lineWidth: selected ? 2 : 0))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("リップの色"))
            }
            ColorPicker("", selection: EditorColorHex.binding(lipColorBinding), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
            Spacer(minLength: 0)
        }
    }
}
