import SwiftUI
import UIKit

// =====================================================================
// 動くステッカーの見本と一覧
//   VectorStickerPreview: 書き出しと同じ描画(VectorStickerDrawer)を Canvas で動かして見せる
//   VectorStickerGrid   : ステッカーパネルの 1 カテゴリ分のタイル(タップで追加)
// =====================================================================

struct VectorStickerPreview: View {
    let kind: VectorStickerKind
    /// nil なら種類ごとの初期色
    var colorHex: String? = nil
    /// nil なら初期の文字
    var text: String? = nil
    /// false なら止まった見本(描き終わったところ)
    var animated: Bool = true

    var body: some View {
        if animated {
            // プロジェクトに TimelineView(タイムライン画面)があるので SwiftUI のものを明示する
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                canvas(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: kind.posterPhase * kind.period)
        }
    }

    private func canvas(time: Double) -> some View {
        let kind = self.kind
        let hex = colorHex ?? kind.defaultColorHex
        let label = kind.hasText ? (text ?? kind.defaultText) : ""
        return Canvas { context, size in
            context.withCGContext { cg in
                VectorStickerDrawer.drawFitted(kind, in: cg, size: size, time: time, colorHex: hex, text: label)
            }
        }
        .accessibilityHidden(true)
    }
}

struct VectorStickerGrid: View {
    let category: VectorStickerCategory
    let onPick: (VectorStickerKind) -> Void

    /// 横長のステッカー(ボタン・下線)がある並びは 2 列にして大きく見せる
    private var columns: [GridItem] {
        let wide = category.kinds.contains { $0.aspect >= 2 }
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: wide ? 2 : 4)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(category.kinds) { kind in
                Button {
                    EditorHaptics.tap()
                    onPick(kind)
                } label: {
                    VStack(spacing: 4) {
                        VectorStickerPreview(kind: kind)
                            .frame(height: 52)
                            .frame(maxWidth: .infinity)
                        Text(kind.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.displayName)
            }
        }
    }
}
