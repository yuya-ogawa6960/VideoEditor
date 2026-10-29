import SwiftUI

// =====================================================================
// 音声のフェードイン・フェードアウトのスライダー(クリップ・ナレーション・BGM で共用)
// =====================================================================

/// 秒数のスライダー 1 本(0.1 秒刻み。0 は「なし」)
struct AudioFadeSliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...3
    /// 編集パネル(暗い背景)用の小さい文字と白いスライダー。false は設定シート(Form)用
    var compact: Bool = true

    private var display: String {
        value < 0.05 ? String(localized: "なし") : String(localized: "\(String(format: "%.1f", value)) 秒")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack {
                Text(title)
                    .font(compact ? .caption : .body)
                Spacer()
                Text(display)
                    .font(compact ? .caption : .callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 0.1)
                .tint(compact ? Color.white : nil)
        }
    }
}

/// フェードイン・フェードアウトの 2 本(クリップとナレーションのボリュームパネル用)
struct AudioFadeSliders: View {
    @Binding var fadeIn: Double
    @Binding var fadeOut: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AudioFadeSliderRow(title: String(localized: "フェードイン"), value: $fadeIn)
            AudioFadeSliderRow(title: String(localized: "フェードアウト"), value: $fadeOut)
        }
    }
}
