import SwiftUI

// =====================================================================
// カラーの画面(単色の静止画クリップ)を差し込むパネル。
// 色(候補 + 自由に選ぶ)と長さを決めて「追加」を押すと、ContentView.insertColorScreen が
// 作品の大きさの PNG を作り、写真と同じ静止画クリップとして再生位置の後ろに差し込む。
// 黒い画面に章タイトルのテロップを乗せる、場面の切り替えに白をはさむ、といった使い方。
// =====================================================================

struct EditorColorScreenPanel: View {
    /// 「追加」: 色("#RRGGBB")と長さ(秒)
    let onAdd: (_ hex: String, _ seconds: Double) -> Void

    @State private var hex: String = "#000000"
    @State private var seconds: Double = 3

    /// 色の候補(名前, "#RRGGBB")
    private static let presets: [(name: String, hex: String)] = [
        (String(localized: "黒"), "#000000"),
        (String(localized: "白"), "#FFFFFF"),
        (String(localized: "グレー"), "#808080"),
        (String(localized: "赤"), "#E53935"),
        (String(localized: "オレンジ"), "#FB8C00"),
        (String(localized: "黄"), "#FDD835"),
        (String(localized: "緑"), "#43A047"),
        (String(localized: "青"), "#1E88E5"),
        (String(localized: "紫"), "#8E24AA"),
        (String(localized: "ピンク"), "#EC407A"),
        (String(localized: "クリーム"), "#FFF3E0"),
        (String(localized: "ネイビー"), "#1A237E"),
    ]
    private static let durations: [Double] = [1, 2, 3, 5, 10]

    private var hexBinding: Binding<String> {
        Binding(get: { hex }, set: { hex = $0.uppercased() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // いま選んでいる色
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous)
                    .fill(EditorColorHex.color(hex))
                    .frame(width: 96, height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: hex)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("色と長さを選んで「追加」を押すと、再生位置の後ろに差し込みます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // 色の候補 + 自由に選ぶ
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.presets, id: \.hex) { preset in
                        let selected = hex.uppercased() == preset.hex.uppercased()
                        Button {
                            EditorHaptics.tap()
                            hex = preset.hex
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(EditorColorHex.color(preset.hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.white, lineWidth: selected ? 2.5 : 0.5))
                                Text(preset.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(selected ? .white : .secondary)
                            }
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                    VStack(spacing: 4) {
                        ColorPicker("", selection: EditorColorHex.binding(hexBinding), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 30, height: 30)
                        Text("自由に")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }

            // 長さ(狭い画面では横に流れる)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("長さ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Self.durations, id: \.self) { value in
                        EditorChip(title: String(localized: "\(Int(value)) 秒"), isSelected: seconds == value) {
                            seconds = value
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            EditorPillButton(title: String(localized: "追加"), systemImage: "plus", prominent: true) {
                EditorHaptics.tap()
                onAdd(hex, seconds)
            }
        }
        .padding(.top, 6)
    }
}
