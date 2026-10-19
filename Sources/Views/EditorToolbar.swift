import SwiftUI
import UIKit
import PhotosUI

// =====================================================================
// CapCut 風の下部ツールバー(横スクロールのアイコン+ラベル)
// 全項目が画面に収まるときは、よく使う「分割」「削除」「テキスト」を右端(親指側)に寄せる。
// =====================================================================

/// 軽い触覚フィードバック
enum EditorHaptics {
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}

/// ツールバーの 1 ボタン
struct EditorToolItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        /// 動画を追加する PhotosPicker
        case addMedia
        /// 動画・写真を選んでオーバーレイ(Bロール / ワイプ / 写真)として追加する PhotosPicker
        case addOverlay
        /// 選択中のクリップの素材を置き換える PhotosPicker(動画 1 本)
        case replaceMedia
        /// 動画から音声だけを取り出してナレーションにする PhotosPicker(動画 1 本)
        case extractAudio
    }

    let id: String
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let isEnabled: Bool
    let kind: Kind

    init(_ title: String, systemImage: String, destructive: Bool = false, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.id = title
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = destructive
        self.isEnabled = enabled
        self.kind = .action(action)
    }

    private init(pickerTitle title: String, systemImage: String, enabled: Bool, kind: Kind) {
        self.id = title
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = false
        self.isEnabled = enabled
        self.kind = kind
    }

    static func addMedia(_ title: String, systemImage: String, enabled: Bool = true) -> EditorToolItem {
        EditorToolItem(pickerTitle: title, systemImage: systemImage, enabled: enabled, kind: .addMedia)
    }

    /// 動画と写真の両方を選べるオーバーレイ追加ボタン
    static func addOverlay(_ title: String, systemImage: String, enabled: Bool = true) -> EditorToolItem {
        EditorToolItem(pickerTitle: title, systemImage: systemImage, enabled: enabled, kind: .addOverlay)
    }

    /// 選択中クリップの素材を置き換えるボタン(動画 1 本)
    static func replaceMedia(_ title: String, systemImage: String, enabled: Bool = true) -> EditorToolItem {
        EditorToolItem(pickerTitle: title, systemImage: systemImage, enabled: enabled, kind: .replaceMedia)
    }

    /// 動画から音声を取り出すボタン(動画 1 本)
    static func extractAudio(_ title: String, systemImage: String, enabled: Bool = true) -> EditorToolItem {
        EditorToolItem(pickerTitle: title, systemImage: systemImage, enabled: enabled, kind: .extractAudio)
    }
}

struct EditorToolbar: View {
    let items: [EditorToolItem]
    /// nil 以外なら先頭に「←」(選択解除)を表示
    let onBack: (() -> Void)?
    /// 「追加」(メインの動画)で選ばれた項目
    @Binding var pickerItems: [PhotosPickerItem]
    /// 「オーバーレイ」(動画・写真)で選ばれた項目
    @Binding var overlayPickerItems: [PhotosPickerItem]
    /// 「置き換え」で選ばれた動画
    @Binding var replacePickerItem: PhotosPickerItem?
    /// 「音声抽出」で選ばれた動画
    @Binding var extractAudioPickerItem: PhotosPickerItem?

    /// 右端(親指側)に寄せる、よく使う項目
    private static let priorityTitles: [String] = ["テキスト", "削除", "分割"]

    private static let backWidth: CGFloat = 45

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - (onBack != nil ? Self.backWidth : 0)
            let fits = estimatedWidth(of: items) <= available
            let ordered = fits ? rightHanded(items) : items

            HStack(spacing: 0) {
                if let onBack {
                    Button {
                        EditorHaptics.tap()
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("戻る")

                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: 32)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(ordered) { item in
                            cell(item)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(minWidth: fits ? max(0, available) : nil, alignment: .trailing)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 68)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.07))
    }

    // MARK: - 並び

    /// セルのおおよその幅(ラベルの文字数から推定)
    private func estimatedWidth(of items: [EditorToolItem]) -> CGFloat {
        var cells: CGFloat = 0
        for item in items {
            let textWidth: CGFloat = CGFloat(item.title.count) * 11.5 + 8
            let cellWidth: CGFloat = max(62, textWidth)
            cells += cellWidth + 2
        }
        return cells + 12
    }

    /// よく使う項目を末尾(右端)へ移す。それ以外の順序は保つ
    private func rightHanded(_ items: [EditorToolItem]) -> [EditorToolItem] {
        let others = items.filter { !Self.priorityTitles.contains($0.title) }
        var tail: [EditorToolItem] = []
        for title in Self.priorityTitles {
            if let found = items.first(where: { $0.title == title }) {
                tail.append(found)
            }
        }
        return others + tail
    }

    // MARK: - セル

    @ViewBuilder
    private func cell(_ item: EditorToolItem) -> some View {
        switch item.kind {
        case .action(let action):
            Button {
                EditorHaptics.tap()
                action()
            } label: {
                label(item)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        case .addMedia:
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .videos,
                         preferredItemEncoding: .current) {
                label(item)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        case .addOverlay:
            PhotosPicker(selection: $overlayPickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .any(of: [.videos, .images]),
                         preferredItemEncoding: .current) {
                label(item)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        case .replaceMedia:
            PhotosPicker(selection: $replacePickerItem,
                         matching: .videos,
                         preferredItemEncoding: .current) {
                label(item)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        case .extractAudio:
            PhotosPicker(selection: $extractAudioPickerItem,
                         matching: .videos,
                         preferredItemEncoding: .current) {
                label(item)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        }
    }

    private func label(_ item: EditorToolItem) -> some View {
        let color: Color = !item.isEnabled ? Color.white.opacity(0.3)
            : (item.isDestructive ? Color.red : Color.white)
        return VStack(spacing: 5) {
            Image(systemName: item.systemImage)
                .font(.system(size: 20))
                .frame(height: 26)
            Text(item.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(color)
        .frame(minWidth: 58)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
