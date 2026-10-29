import SwiftUI

// =====================================================================
// 「GIF を読み込む」(ステッカーパネルの動くステッカーの横に置く)。
// 写真ライブラリか「ファイル」から GIF を選ぶと、動く写真オーバーレイとして
// 再生位置に入る(ほかのオーバーレイと同じように動かしたり大きさを変えたりできる)。
// =====================================================================

struct GIFImportMenu: View {
    /// 写真ライブラリから選ぶ(ContentView の GIF 用 PhotosPicker を開く)
    let onPickPhotos: () -> Void
    /// 「ファイル」から選ぶ(ContentView の GIF 用 fileImporter を開く)
    let onPickFiles: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    EditorHaptics.tap()
                    onPickPhotos()
                } label: {
                    Label("写真から選ぶ", systemImage: "photo.on.rectangle")
                }
                Button {
                    EditorHaptics.tap()
                    onPickFiles()
                } label: {
                    Label("ファイルから選ぶ", systemImage: "folder")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo.stack")
                    Text("GIF を読み込む")
                }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "GIF を読み込む"))

            Text("動く画像を重ねます。位置や大きさはあとで変えられます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
