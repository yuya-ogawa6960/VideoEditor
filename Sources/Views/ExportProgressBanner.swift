import SwiftUI
import Observation

/// 書き出し中だけ表示される小さなバナー(メイン画面上部に配置)
struct ExportProgressBanner: View {
    var body: some View {
        let exporter = ExportManager.shared
        if exporter.isRunning {
            let progress = min(max(exporter.progress, 0), 1)
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "書き出し中 \(Int((progress * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                }
                Button {
                    exporter.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("書き出しをキャンセル")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.15), radius: 6, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            EmptyView()
        }
    }
}
