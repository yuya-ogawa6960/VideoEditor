import SwiftUI
import UIKit
import AVFoundation
import Observation

// =====================================================================
// ドキュメンタリー風演出のための下部パネル
//   - EditorDocumentaryPanel : 全体の色味・黒帯・フェード・ダッキングなど
//   - EditorTitleCardPanel   : 章タイトル 1 件の編集 + 一覧
//   - EditorLowerThirdPanel  : テロップ 1 件の編集 + 一覧
// =====================================================================

// MARK: - 共通部品

/// パネル内の小見出し
private struct DocumentarySectionTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// ラベルつきの 1 行テキスト入力
private struct DocumentaryTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DocumentarySectionTitle(title: title)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 一覧の 1 行(時刻 + 本文)。選択中は白背景
private struct DocumentaryListRow: View {
    let time: Double
    let text: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Text(EditorTimeFormat.short(time))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
                Text(text.isEmpty ? "(空)" : text)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.black : Color.white)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(Color.black.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 「再生位置に移動」「削除」の 2 ボタン行
private struct DocumentaryActionRow: View {
    let onMoveToPlayhead: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                EditorHaptics.tap()
                onMoveToPlayhead()
            } label: {
                Label("再生位置に移動", systemImage: "arrow.right.to.line")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                EditorHaptics.tap()
                onDelete()
            } label: {
                Label("削除", systemImage: "trash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 操作の下に出す 1 行の説明(やさしい言葉で)
private struct DocumentaryHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func percentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func secondsText(_ value: Double) -> String {
    String(format: "%.1f 秒", value)
}

// MARK: - ドキュメンタリー(全体演出)

struct EditorDocumentaryPanel: View {
    @Bindable var project: EditorProject
    /// 見本に使う再生位置のコマを取るため(なければ先頭クリップのサムネイル)
    var player: PlayerController? = nil

    @State private var previews = DocumentaryPreviews()
    @State private var isLoadingPreviews = false

    /// 「おまかせ」で適用する設定
    static var recommendedStyle: DocumentaryStyle {
        var style = DocumentaryStyle()
        style.look = .documentary
        style.lookIntensity = 0.85
        style.letterbox = true
        style.filmGrain = 0
        style.vignette = 0
        style.fadeFromToBlack = true
        style.dipToBlackBetweenClips = false
        style.autoDucking = true
        style.duckingLevel = 0.3
        return style
    }

    /// 「リセット」で適用する設定(演出をすべてオフ)
    private static var offStyle: DocumentaryStyle {
        var style = DocumentaryStyle()
        style.look = .none
        style.letterbox = false
        style.filmGrain = 0
        style.vignette = 0
        style.fadeFromToBlack = false
        style.dipToBlackBetweenClips = false
        style.autoDucking = false
        return style
    }

    private var duckingPercent: String {
        "\(Int((Double(project.documentary.duckingLevel) * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // おまかせ
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    EditorHaptics.tap()
                    project.documentary = Self.recommendedStyle
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                        Text("おまかせでドキュメンタリー風にする")
                            .font(.subheadline.weight(.bold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                DocumentaryHint(text: "全体の仕上げ: 作品全体の色・黒帯・フェード・BGMの下げ方をまとめて整えます。")

                HStack(spacing: 8) {
                    EditorChip(title: "リセット(すべてオフ)",
                               isSelected: false) {
                        project.documentary = Self.offStyle
                    }
                    Spacer()
                    if project.documentary.isActive {
                        Text("適用中")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 色味(再生位置のコマに色をかけた見本から選ぶ)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DocumentarySectionTitle(title: "色味")
                    Spacer()
                    Button {
                        EditorHaptics.tap()
                        reloadPreviews()
                    } label: {
                        Label("いまのコマで見本を更新", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isLoadingPreviews)
                }
                DocumentaryHint(text: "動画全体の色の雰囲気を選びます。見本は再生位置のコマです。")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LookPreset.allCases) { preset in
                            EditorVisualTile(title: preset.displayName,
                                             isSelected: project.documentary.look == preset) {
                                project.documentary.look = preset
                            } preview: {
                                DocumentaryFrameTile(image: previews.looks[preset] ?? previews.base)
                            }
                        }
                    }
                }
                EditorSliderRow(title: "強さ",
                                value: $project.documentary.lookIntensity,
                                range: 0...1,
                                display: percentText(project.documentary.lookIntensity))
                    .disabled(project.documentary.look == .none)
                    .opacity(project.documentary.look == .none ? 0.4 : 1)
            }

            // 画面演出(タップでオン・オフ。見本つき)
            VStack(alignment: .leading, spacing: 10) {
                DocumentarySectionTitle(title: "画面")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        EditorVisualTile(title: "上下の黒帯",
                                         isSelected: project.documentary.letterbox) {
                            project.documentary.letterbox.toggle()
                        } preview: {
                            DocumentaryFrameTile(image: previews.base)
                                .overlay(alignment: .top) { Color.black.frame(height: 9) }
                                .overlay(alignment: .bottom) { Color.black.frame(height: 9) }
                        }
                        EditorVisualTile(title: "最初と最後を黒から",
                                         isSelected: project.documentary.fadeFromToBlack) {
                            project.documentary.fadeFromToBlack.toggle()
                        } preview: {
                            DocumentaryFrameTile(image: previews.base)
                                .overlay {
                                    LinearGradient(colors: [.black, .black.opacity(0)],
                                                   startPoint: .leading,
                                                   endPoint: UnitPoint(x: 0.65, y: 0.5))
                                }
                        }
                        EditorVisualTile(title: "つなぎ目を一瞬黒に",
                                         isSelected: project.documentary.dipToBlackBetweenClips) {
                            project.documentary.dipToBlackBetweenClips.toggle()
                        } preview: {
                            HStack(spacing: 0) {
                                DocumentaryFrameTile(image: previews.base)
                                    .frame(width: 28, height: 44)
                                    .clipped()
                                Color.black.frame(width: 8, height: 44)
                                DocumentaryFrameTile(image: previews.base)
                                    .frame(width: 28, height: 44)
                                    .clipped()
                            }
                        }
                    }
                }
                DocumentaryHint(text: "黒帯は映画のような横長(2.39:1)にします。フェードは最初と最後の 1.5 秒、つなぎ目の黒は 0.5 秒です。")

                DocumentarySectionTitle(title: "フィルムのざらつき")
                levelTiles(current: project.documentary.filmGrain, images: previews.grain) { value in
                    project.documentary.filmGrain = value
                }
                EditorSliderRow(title: "強さ",
                                value: $project.documentary.filmGrain,
                                range: 0...1,
                                display: percentText(project.documentary.filmGrain))
                DocumentaryHint(text: "昔のフィルムのような細かい粒を加えます。")

                DocumentarySectionTitle(title: "四すみを暗く")
                levelTiles(current: project.documentary.vignette, images: previews.vignette) { value in
                    project.documentary.vignette = value
                }
                EditorSliderRow(title: "強さ",
                                value: $project.documentary.vignette,
                                range: 0...1,
                                display: percentText(project.documentary.vignette))
                DocumentaryHint(text: "画面のまわりを少し暗くして、中央に目が行くようにします。")
            }

            // 音
            VStack(alignment: .leading, spacing: 10) {
                DocumentarySectionTitle(title: "音")
                Toggle("話している間 BGM を下げる", isOn: $project.documentary.autoDucking)
                    .font(.subheadline)
                    .tint(.accentColor)
                EditorSliderRow(title: "下げたときの BGM の大きさ",
                                value: $project.documentary.duckingLevel,
                                range: 0.1...0.8,
                                display: duckingPercent)
                    .disabled(!project.documentary.autoDucking)
                    .opacity(project.documentary.autoDucking ? 1 : 0.4)
                Text("字幕(話している区間)がある間だけ BGM を下げます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .onAppear { reloadPreviews() }
    }

    // MARK: 見本

    /// 強さの見本(オフ / 弱め / ふつう / 強め)。タップでその強さにする
    private func levelTiles(current: Double, images: [Int: UIImage],
                            set: @escaping (Double) -> Void) -> some View {
        let selectedIndex = DocumentaryPreviews.nearestLevel(current)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(DocumentaryPreviews.levels.enumerated()), id: \.offset) { index, level in
                    EditorVisualTile(title: level.name, isSelected: index == selectedIndex) {
                        set(level.value)
                    } preview: {
                        DocumentaryFrameTile(image: images[index] ?? previews.base)
                    }
                }
            }
        }
    }

    /// 再生位置のコマを取り、色味・ざらつき・四すみの見本を作り直す
    private func reloadPreviews() {
        guard !isLoadingPreviews else { return }
        let time = player?.currentTime ?? 0
        var clip: Clip? = project.clips.first
        var sourceTime: Double = clip?.startTime ?? 0
        if let location = project.locate(timelineTime: time), location.index < project.clips.count {
            clip = project.clips[location.index]
            sourceTime = location.sourceTime
        }
        guard let clip else {
            previews = DocumentaryPreviews()
            return
        }
        isLoadingPreviews = true
        Task {
            let base = await DocumentaryPreviewSource.frame(clip: clip, sourceTime: sourceTime)
            let built = await Task.detached(priority: .userInitiated) {
                DocumentaryPreviews.build(from: base)
            }.value
            previews = built
            isLoadingPreviews = false
        }
    }
}

/// 「全体の仕上げ」の見本画像(元のコマ、色味ごと、ざらつき・四すみの強さごと)
struct DocumentaryPreviews {
    var base: UIImage?
    var looks: [LookPreset: UIImage] = [:]
    var grain: [Int: UIImage] = [:]
    var vignette: [Int: UIImage] = [:]

    static let levels: [(name: String, value: Double)] = [("オフ", 0), ("弱め", 0.35), ("ふつう", 0.7), ("強め", 1)]

    /// スライダーの値にいちばん近い見本の番号(0 はオフだけ)
    static func nearestLevel(_ value: Double) -> Int {
        if value <= 0.001 { return 0 }
        var best = 1
        var bestDistance = Double.infinity
        for (index, level) in levels.enumerated() where index > 0 {
            let distance = abs(level.value - value)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    static func build(from base: UIImage?) -> DocumentaryPreviews {
        var result = DocumentaryPreviews(base: base)
        guard let base else { return result }
        for look in LookPreset.allCases {
            result.looks[look] = look == .none ? base : (FilterEngine.previewLook(base, look: look, intensity: 1) ?? base)
        }
        for (index, level) in levels.enumerated() {
            if index == 0 {
                result.grain[index] = base
                result.vignette[index] = base
            } else {
                result.grain[index] = FilterEngine.previewTexture(base, grain: level.value, vignette: 0) ?? base
                result.vignette[index] = FilterEngine.previewTexture(base, grain: 0, vignette: level.value) ?? base
            }
        }
        return result
    }
}

/// 見本用に、クリップの元素材から 1 コマ取り出す(小さめ)
enum DocumentaryPreviewSource {
    static func frame(clip: Clip, sourceTime: Double) async -> UIImage? {
        if let still = clip.stillImageURL, let image = UIImage(contentsOfFile: still.path) {
            return await image.byPreparingThumbnail(ofSize: fitSize(image.size, max: 360)) ?? clip.thumbnail
        }
        let asset = AVURLAsset(url: clip.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let time = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
        if let cg = try? await generator.image(at: time).image {
            return UIImage(cgImage: cg)
        }
        return clip.thumbnail
    }

    private static func fitSize(_ size: CGSize, max limit: CGFloat) -> CGSize {
        let longest = Swift.max(size.width, size.height, 1)
        let scale = Swift.min(1, limit / longest)
        return CGSize(width: Swift.max(1, size.width * scale), height: Swift.max(1, size.height * scale))
    }
}

/// 見本のタイル(64 × 44 に切り抜いた 1 コマ)
private struct DocumentaryFrameTile: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.16)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 44)
        .clipped()
    }
}

// MARK: - 章タイトル

struct EditorTitleCardPanel: View {
    @Bindable var project: EditorProject
    let player: PlayerController
    /// 編集中のカード。見つからない(削除済みなど)なら nil
    let card: Binding<TitleCard>?
    /// 一覧でタップされたとき
    let onSelect: (UUID) -> Void
    /// 削除ボタン
    let onDelete: (UUID) -> Void

    private var sortedCards: [TitleCard] {
        project.titleCards.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let card {
                editor(card)
            } else {
                Text("章タイトルが見つかりません。下の一覧から選んでください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                DocumentarySectionTitle(title: "章タイトル一覧")
                if sortedCards.isEmpty {
                    Text("章タイトルはまだありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(sortedCards) { item in
                            DocumentaryListRow(time: item.start,
                                               text: listText(item),
                                               isSelected: card?.wrappedValue.id == item.id) {
                                onSelect(item.id)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func listText(_ item: TitleCard) -> String {
        let heading = item.heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if heading.isEmpty { return title }
        if title.isEmpty { return heading }
        return "\(heading)  \(title)"
    }

    @ViewBuilder
    private func editor(_ card: Binding<TitleCard>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(MediaTimeText.precise(card.wrappedValue.start)) – \(MediaTimeText.precise(card.wrappedValue.end))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            DocumentaryTextFieldRow(title: "見出し", placeholder: "例: 第1章", text: card.heading)
            DocumentaryTextFieldRow(title: "タイトル", placeholder: "例: はじまり", text: card.title)

            EditorSliderRow(title: "長さ",
                            value: card.duration,
                            range: 1.5...8,
                            display: secondsText(card.wrappedValue.duration))
            HStack {
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    card.wrappedValue.duration = 3
                }
            }

            Toggle("黒背景(映像を隠す)", isOn: card.opaqueBackground)
                .font(.subheadline)
                .tint(.accentColor)

            DocumentaryActionRow(onMoveToPlayhead: {
                card.wrappedValue.start = max(0, player.currentTime)
            }, onDelete: {
                onDelete(card.wrappedValue.id)
            })
        }
    }
}

// MARK: - テロップ

struct EditorLowerThirdPanel: View {
    @Bindable var project: EditorProject
    let player: PlayerController
    /// 編集中のテロップ。見つからない(削除済みなど)なら nil
    let item: Binding<LowerThird>?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void

    private var sortedItems: [LowerThird] {
        project.lowerThirds.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let item {
                editor(item)
            } else {
                Text("テロップが見つかりません。下の一覧から選んでください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                DocumentarySectionTitle(title: "テロップ一覧")
                if sortedItems.isEmpty {
                    Text("テロップはまだありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(sortedItems) { entry in
                            DocumentaryListRow(time: entry.start,
                                               text: listText(entry),
                                               isSelected: item?.wrappedValue.id == entry.id) {
                                onSelect(entry.id)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func listText(_ entry: LowerThird) -> String {
        let primary = entry.primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = entry.secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "[\(entry.kind.displayName)] "
        if primary.isEmpty { return prefix + secondary }
        if secondary.isEmpty { return prefix + primary }
        return prefix + "\(primary) / \(secondary)"
    }

    private func primaryLabel(_ kind: CaptionKind) -> String {
        switch kind {
        case .nameplate: return "名前"
        case .location: return "場所"
        }
    }

    private func secondaryLabel(_ kind: CaptionKind) -> String {
        switch kind {
        case .nameplate: return "肩書き"
        case .location: return "日付"
        }
    }

    @ViewBuilder
    private func editor(_ item: Binding<LowerThird>) -> some View {
        let kind = item.wrappedValue.kind
        VStack(alignment: .leading, spacing: 12) {
            Text("\(MediaTimeText.precise(item.wrappedValue.start)) – \(MediaTimeText.precise(item.wrappedValue.end))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                DocumentarySectionTitle(title: "種類")
                Picker("種類", selection: item.kind) {
                    ForEach(CaptionKind.allCases) { captionKind in
                        Text(captionKind.displayName).tag(captionKind)
                    }
                }
                .pickerStyle(.segmented)
                DocumentaryHint(text: "名前と肩書きは左下、場所と日付は左上に出ます。")
            }

            DocumentaryTextFieldRow(title: primaryLabel(kind),
                                    placeholder: kind == .nameplate ? "例: 山田 太郎" : "例: 東京・浅草",
                                    text: item.primary)
            DocumentaryTextFieldRow(title: secondaryLabel(kind),
                                    placeholder: kind == .nameplate ? "例: 代表取締役" : "例: 2026年10月",
                                    text: item.secondary)

            EditorSliderRow(title: "長さ",
                            value: item.duration,
                            range: 2...10,
                            display: secondsText(item.wrappedValue.duration))
            HStack {
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    item.wrappedValue.duration = 4
                }
            }

            DocumentaryActionRow(onMoveToPlayhead: {
                item.wrappedValue.start = max(0, player.currentTime)
            }, onDelete: {
                onDelete(item.wrappedValue.id)
            })
        }
    }
}
