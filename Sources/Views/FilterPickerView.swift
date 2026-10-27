import SwiftUI
import UIKit

/// フィルタのプリセット一覧+強さ+色調整
struct FilterPickerView: View {
    @Binding var filter: FilterSettings
    let sourceImage: UIImage?
    let onApplyToAll: () -> Void

    @State private var thumbnails: [FilterPreset: UIImage] = [:]
    @State private var isGenerating = false
    @State private var showApplyAllConfirm = false

    private var sourceKey: ObjectIdentifier? {
        sourceImage.map { ObjectIdentifier($0) }
    }

    /// このパネルで触る値(プリセット・強さ・明るさ・コントラスト・彩度)が初期値か。HSL・LUT・ほかの補正は見ない
    private var isPresetLookDefault: Bool {
        filter.preset == .none && filter.intensity == 1
            && filter.adjustments.brightness == 0 && filter.adjustments.contrast == 1 && filter.adjustments.saturation == 1
    }

    /// source のプリセット・強さ・明るさ・コントラスト・彩度だけを target に写す。
    /// リセットや「全クリップに適用」で、HSL・LUT・露出などの「カラー補正」を消さないために使う
    static func presetLook(from source: FilterSettings, onto target: FilterSettings) -> FilterSettings {
        var result = target
        result.preset = source.preset
        result.intensity = source.intensity
        result.adjustments.brightness = source.adjustments.brightness
        result.adjustments.contrast = source.adjustments.contrast
        result.adjustments.saturation = source.adjustments.saturation
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetStrip

            // 数字は「強さ」が 0〜100、ほかは真ん中を 0 にした -100〜+100 にそろえる。名前をダブルタップで初期値に戻す
            sliderRow(title: String(localized: "強さ"),
                      value: $filter.intensity,
                      range: 0...1,
                      display: "\(Int((filter.intensity * 100).rounded()))",
                      defaultValue: 1)
                .disabled(filter.preset == .none)

            sliderRow(title: String(localized: "明るさ"),
                      value: $filter.adjustments.brightness,
                      range: -0.5...0.5,
                      display: Self.signed(filter.adjustments.brightness * 200),
                      defaultValue: 0)

            sliderRow(title: String(localized: "コントラスト"),
                      value: $filter.adjustments.contrast,
                      range: 0.5...1.5,
                      display: Self.signed((filter.adjustments.contrast - 1) * 200),
                      defaultValue: 1)

            sliderRow(title: String(localized: "彩度"),
                      value: $filter.adjustments.saturation,
                      range: 0...2,
                      display: Self.signed((filter.adjustments.saturation - 1) * 100),
                      defaultValue: 1)

            HStack(spacing: 10) {
                Button {
                    EditorHaptics.tap()
                    showApplyAllConfirm = true
                } label: {
                    Label("全クリップに適用", systemImage: "square.stack.3d.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(BrandStyle.surfaceStrong,
                                    in: RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    EditorHaptics.tap()
                    filter = Self.presetLook(from: FilterSettings(), onto: filter)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 36, height: 32)
                        .background(BrandStyle.surface,
                                    in: RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(isPresetLookDefault ? 0.35 : 1)
                .disabled(isPresetLookDefault)
                .accessibilityLabel("リセット")
            }
        }
        .padding(.vertical, 4)
        .task(id: sourceKey) {
            await generateThumbnails()
        }
        .confirmationDialog("すべてのクリップに適用しますか?",
                            isPresented: $showApplyAllConfirm,
                            titleVisibility: .visible) {
            Button("全クリップに適用") { onApplyToAll() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - プリセット一覧

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilterPreset.allCases) { preset in
                    presetCell(preset)
                        .onTapGesture {
                            filter.preset = preset
                            if preset != .none && filter.intensity <= 0 {
                                filter.intensity = 1
                            }
                        }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    private func presetCell(_ preset: FilterPreset) -> some View {
        let isSelected = filter.preset == preset
        return VStack(spacing: 4) {
            ZStack {
                if let image = thumbnails[preset] ?? (preset == .none ? sourceImage : nil) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "camera.filters")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 52, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            .brandSelected(isSelected)
            Text(preset.displayName)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 60)
        .contentShape(Rectangle())
    }

    /// -100〜+100 の表記(0 は符号なし)
    private static func signed(_ value: Double) -> String {
        let n = Int(value.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           display: String, defaultValue: Double) -> some View {
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                EditorHaptics.tap()
                value.wrappedValue = defaultValue
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - サムネイル生成(メインスレッド外で1回だけ、キャッシュ)

    private func generateThumbnails() async {
        guard let image = sourceImage else {
            thumbnails = [:]
            return
        }
        if let cached = FilterPickerThumbnailCache.shared.thumbnails(for: image) {
            thumbnails = cached
            return
        }
        isGenerating = true
        let result: [FilterPreset: UIImage] = await Task.detached(priority: .userInitiated) {
            var dict: [FilterPreset: UIImage] = [:]
            for preset in FilterPreset.allCases {
                var settings = FilterSettings()
                settings.preset = preset
                if let output = FilterEngine.preview(image, settings: settings) {
                    dict[preset] = output
                }
            }
            return dict
        }.value
        FilterPickerThumbnailCache.shared.store(result, for: image)
        isGenerating = false
        if !Task.isCancelled {
            thumbnails = result
        }
    }
}

/// 元画像ごとのフィルタサムネイルキャッシュ(メインスレッドからのみ使用)
final class FilterPickerThumbnailCache {
    static let shared = FilterPickerThumbnailCache()

    private final class Entry {
        weak var source: UIImage?
        let thumbnails: [FilterPreset: UIImage]

        init(source: UIImage, thumbnails: [FilterPreset: UIImage]) {
            self.source = source
            self.thumbnails = thumbnails
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func thumbnails(for image: UIImage) -> [FilterPreset: UIImage]? {
        guard let entry = entries[ObjectIdentifier(image)], entry.source === image else { return nil }
        return entry.thumbnails
    }

    func store(_ thumbnails: [FilterPreset: UIImage], for image: UIImage) {
        entries = entries.filter { $0.value.source != nil }
        entries[ObjectIdentifier(image)] = Entry(source: image, thumbnails: thumbnails)
    }
}
