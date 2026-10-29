import SwiftUI

// =====================================================================
// タイムラインの映像エフェクト行の部品(配置と見た目)。
// 行の描画・移動・長さ変更は TimelineView.swift の effectTrack。
// =====================================================================

/// 映像エフェクト行の 1 要素の配置
struct TimelineEffectItem: Identifiable {
    let id: UUID
    let effect: VideoEffectClip
    let screenX: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let visibleWidth: CGFloat
    let labelX: CGFloat
}

struct TimelineEffectBar: View {
    let effect: VideoEffectClip
    let labelX: CGFloat
    let visibleWidth: CGFloat
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TimelineMetrics.effectColor)
            HStack(spacing: 3) {
                Image(systemName: effect.type.systemImage)
                    .font(.system(size: 9, weight: .bold))
                if visibleWidth - labelX >= 40 {
                    Text(effect.type.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .frame(maxWidth: max(0, visibleWidth - labelX), alignment: .leading)
            .offset(x: labelX)
        }
        .frame(width: visibleWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}
