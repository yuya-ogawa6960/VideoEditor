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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetStrip

            sliderRow(title: "強さ",
                      value: $filter.intensity,
                      range: 0...1,
                      display: String(format: "%.0f%%", filter.intensity * 100))
                .disabled(filter.preset == .none)

            sliderRow(title: "明るさ",
                      value: $filter.adjustments.brightness,
                      range: -0.5...0.5,
                      display: String(format: "%+.2f", filter.adjustments.brightness))

            sliderRow(title: "コントラスト",
                      value: $filter.adjustments.contrast,
                      range: 0.5...1.5,
                      display: String(format: "%.2f", filter.adjustments.contrast))

            sliderRow(title: "彩度",
                      value: $filter.adjustments.saturation,
                      range: 0...2,
                      display: String(format: "%.2f", filter.adjustments.saturation))

            HStack {
                Button {
                    filter = FilterSettings()
                } label: {
                    Label("リセット", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(filter.isIdentity && filter.intensity == 1)

                Spacer()

                Button {
                    showApplyAllConfirm = true
                } label: {
                    Label("全クリップに適用", systemImage: "square.stack.3d.down.right")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .task(id: sourceKey) {
            await generateThumbnails()
        }
        .confirmationDialog("このフィルタ設定をすべてのクリップに適用しますか?",
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
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.yellow : Color.clear, lineWidth: 3)
            )
            Text(preset.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.yellow : Color.primary)
                .lineLimit(1)
        }
        .frame(width: 70)
        .contentShape(Rectangle())
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           display: String) -> some View {
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
