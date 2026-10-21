import SwiftUI
import UIKit
import PhotosUI

// =====================================================================
// CapCut 風の下部ツールバー(横スクロールのアイコン+ラベル、左寄せ)
// よく使う項目だけを並べ、関連する機能は「グループ」(タップで 2 段目の列に切り替わり ‹ で戻る)と
// 「その他」にまとめる。
// =====================================================================

/// 触覚フィードバック
enum EditorHaptics {
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
}

/// ツールバーの 1 ボタン
struct EditorToolItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        /// 動画・写真を追加する PhotosPicker(写真は静止画クリップになる)
        case addMedia
        /// 動画・写真を選んでオーバーレイ(Bロール / ワイプ / 写真)として追加する PhotosPicker
        case addOverlay
        /// 選択中のクリップの素材を置き換える PhotosPicker(動画 1 本)
        case replaceMedia
        /// 動画から音声だけを取り出してナレーションにする PhotosPicker(動画 1 本)
        case extractAudio
        /// 写真を複数選んでスライドショーを作る PhotosPicker(第4弾)
        case addSlideshow
        /// タップすると中の項目を 2 段目の列として表示する(‹ で戻る)
        case group([EditorToolItem])
        /// 列の中の小見出し(「設定」など)。タップできない
        case section
    }

    let id: String
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let isEnabled: Bool
    /// 使えないときにタップすると出す理由
    let disabledReason: String?
    let kind: Kind

    init(_ title: String, systemImage: String, id: String? = nil, destructive: Bool = false,
         enabled: Bool = true, disabledReason: String? = nil, action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = destructive
        self.isEnabled = enabled
        self.disabledReason = disabledReason
        self.kind = .action(action)
    }

    private init(id: String, title: String, systemImage: String, enabled: Bool,
                 disabledReason: String?, kind: Kind) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = false
        self.isEnabled = enabled
        self.disabledReason = disabledReason
        self.kind = kind
    }

    static func addMedia(_ title: String, systemImage: String, enabled: Bool = true,
                         disabledReason: String? = nil) -> EditorToolItem {
        EditorToolItem(id: title, title: title, systemImage: systemImage, enabled: enabled,
                       disabledReason: disabledReason, kind: .addMedia)
    }

    /// 動画と写真の両方を選べるオーバーレイ追加ボタン
    static func addOverlay(_ title: String, systemImage: String, enabled: Bool = true,
                           disabledReason: String? = nil) -> EditorToolItem {
        EditorToolItem(id: title, title: title, systemImage: systemImage, enabled: enabled,
                       disabledReason: disabledReason, kind: .addOverlay)
    }

    /// 選択中クリップの素材を置き換えるボタン(動画 1 本)
    static func replaceMedia(_ title: String, systemImage: String, enabled: Bool = true,
                             disabledReason: String? = nil) -> EditorToolItem {
        EditorToolItem(id: title, title: title, systemImage: systemImage, enabled: enabled,
                       disabledReason: disabledReason, kind: .replaceMedia)
    }

    /// 動画から音声を取り出すボタン(動画 1 本)
    static func extractAudio(_ title: String, systemImage: String, enabled: Bool = true,
                             disabledReason: String? = nil) -> EditorToolItem {
        EditorToolItem(id: title, title: title, systemImage: systemImage, enabled: enabled,
                       disabledReason: disabledReason, kind: .extractAudio)
    }

    /// 写真を複数選んでスライドショーを作るボタン
    static func addSlideshow(_ title: String, systemImage: String, enabled: Bool = true,
                             disabledReason: String? = nil) -> EditorToolItem {
        EditorToolItem(id: title, title: title, systemImage: systemImage, enabled: enabled,
                       disabledReason: disabledReason, kind: .addSlideshow)
    }

    /// 関連する項目をまとめたグループ(タップで 2 段目の列を開く)
    static func group(_ title: String, systemImage: String, id: String? = nil,
                      items: [EditorToolItem]) -> EditorToolItem {
        EditorToolItem(id: id ?? "group-\(title)", title: title, systemImage: systemImage, enabled: true,
                       disabledReason: nil, kind: .group(items))
    }

    /// 「その他」グループ
    static func more(_ items: [EditorToolItem]) -> EditorToolItem {
        group(String(localized: "その他"), systemImage: "ellipsis.circle", id: "group-more", items: items)
    }

    /// 列の中の小見出し
    static func section(_ title: String) -> EditorToolItem {
        EditorToolItem(id: "section-\(title)", title: title, systemImage: "", enabled: true,
                       disabledReason: nil, kind: .section)
    }

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }
}

struct EditorToolbar: View {
    let items: [EditorToolItem]
    /// nil 以外なら(グループを開いていないとき)先頭に「‹」(選択解除)を表示
    let onBack: (() -> Void)?
    /// 使えない項目をタップしたとき(理由を受け取ってトーストを出す)
    let onDisabledTap: (String) -> Void
    /// 開いているグループの ID(外側で持つので、パネルを閉じて戻ったときも同じ列が出る)
    @Binding var groupPath: [String]
    /// 「動画・写真を追加」で選ばれた項目
    @Binding var pickerItems: [PhotosPickerItem]
    /// 「重ねる」(動画・写真)で選ばれた項目
    @Binding var overlayPickerItems: [PhotosPickerItem]
    /// 「置き換え」で選ばれた動画
    @Binding var replacePickerItem: PhotosPickerItem?
    /// 「音声抽出」で選ばれた動画
    @Binding var extractAudioPickerItem: PhotosPickerItem?
    /// 「スライドショー」で選ばれた写真
    @Binding var slideshowPickerItems: [PhotosPickerItem]

    /// 開いているグループの列(見つからなくなったら、たどれたところまで)
    private var resolved: (items: [EditorToolItem], groupTitle: String?) {
        var current = items
        var title: String? = nil
        for id in groupPath {
            guard let group = current.first(where: { $0.id == id }),
                  case .group(let children) = group.kind else { break }
            current = children
            title = group.title
        }
        return (current, title)
    }

    var body: some View {
        let state = resolved
        let showsBack = !groupPath.isEmpty || onBack != nil

        HStack(spacing: 0) {
            if showsBack {
                Button {
                    EditorHaptics.tap()
                    goBack()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                        if let title = state.groupTitle {
                            Text(title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 56)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.groupTitle != nil ? String(localized: "戻る") : String(localized: "選択を解除"))

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 32)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.items) { item in
                        cell(item)
                    }
                }
                .padding(.horizontal, 6)
            }
            .id(groupPath.joined(separator: "/"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 78)
        .background(Color(white: 0.07))
    }

    private func goBack() {
        if !groupPath.isEmpty {
            groupPath.removeLast()
        } else {
            onBack?()
        }
    }

    // MARK: - セル

    @ViewBuilder
    private func cell(_ item: EditorToolItem) -> some View {
        if item.isSection {
            sectionLabel(item)
        } else if !item.isEnabled {
            Button {
                // 触覚(注意)はトーストを出す側で鳴らす
                onDisabledTap(item.disabledReason ?? String(localized: "今は使えません"))
            } label: {
                label(item)
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.disabledReason ?? String(localized: "今は使えません"))
        } else {
            enabledCell(item)
        }
    }

    @ViewBuilder
    private func enabledCell(_ item: EditorToolItem) -> some View {
        switch item.kind {
        case .action(let action):
            Button {
                EditorHaptics.tap()
                action()
            } label: {
                label(item)
            }
            .buttonStyle(.plain)
        case .group:
            Button {
                EditorHaptics.tap()
                groupPath.append(item.id)
            } label: {
                label(item)
            }
            .buttonStyle(.plain)
        case .section:
            sectionLabel(item)
        case .addMedia:
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .any(of: [.videos, .images]),
                         preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                label(item)
            }
            .buttonStyle(.plain)
        case .addOverlay:
            PhotosPicker(selection: $overlayPickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .any(of: [.videos, .images]),
                         preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                label(item)
            }
            .buttonStyle(.plain)
        case .replaceMedia:
            PhotosPicker(selection: $replacePickerItem,
                         matching: .videos,
                         preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                label(item)
            }
            .buttonStyle(.plain)
        case .extractAudio:
            PhotosPicker(selection: $extractAudioPickerItem,
                         matching: .videos,
                         preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                label(item)
            }
            .buttonStyle(.plain)
        case .addSlideshow:
            PhotosPicker(selection: $slideshowPickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .images,
                         preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                label(item)
            }
            .buttonStyle(.plain)
        }
    }

    private func label(_ item: EditorToolItem) -> some View {
        let color: Color = item.isDestructive ? Color.red : Color.white
        return VStack(spacing: 4) {
            Image(systemName: item.systemImage)
                .font(.system(size: 20))
                .frame(height: 26)
            // 長い名前は区切りのよいところで 2 行にする
            Text(EditorToolLabel.wrapped(item.title))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .lineSpacing(-1)
                .fixedSize()
                .frame(height: 28, alignment: .top)
        }
        .foregroundStyle(color)
        .opacity(item.isEnabled ? 1 : 0.45)
        .frame(minWidth: 58, minHeight: 64)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func sectionLabel(_ item: EditorToolItem) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 32)
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - トースト(画面を止めない短いお知らせ)

struct EditorToast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case warning
        case info
    }

    let id: UUID
    let message: String
    let style: Style
    /// 「元に戻す」ボタンを出すか
    let canUndo: Bool

    init(_ message: String, style: Style = .success, canUndo: Bool = false) {
        self.id = UUID()
        self.message = message
        self.style = style
        self.canUndo = canUndo
    }
}

struct EditorToastView: View {
    let toast: EditorToast
    let onUndo: () -> Void

    private var iconName: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.style {
        case .success: return Color.green
        case .warning: return Color.yellow
        case .info: return Color.white
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if toast.canUndo {
                Button {
                    EditorHaptics.tap()
                    onUndo()
                } label: {
                    Text("元に戻す")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, toast.canUndo ? 0 : 12)
        .background(Color(white: 0.18).opacity(0.96), in: Capsule())
        .shadow(color: Color.black.opacity(0.4), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }
}

/// 下のボタンが何の編集か(「クリップの編集」「全体の編集」など)を、切り替わったときに 1 秒だけ小さく出す
struct EditorModeBadge: View {
    let title: String
    @State private var isVisible = false
    @State private var shownTitle = ""

    var body: some View {
        Text(shownTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: title) {
                shownTitle = title
                withAnimation(.easeOut(duration: 0.15)) { isVisible = true }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.25)) { isVisible = false }
            }
    }
}

/// ツールバーの名前の改行位置(長い名前は意味の切れ目で 2 行にする)
enum EditorToolLabel {
    private static let breaks: [String: String] = [
        "動画・写真を追加": "動画・写真\nを追加",
        "ビデオトランジション": "ビデオ\nトランジション",
        "リップル削除": "リップル\n削除",
        "Lumetri プリセット": "Lumetri\nプリセット",
        "Lumetri カラー": "Lumetri\nカラー",
        "Lumetri スコープ": "Lumetri\nスコープ",
        "HSL セカンダリ": "HSL\nセカンダリ",
        "LUT を参照": "LUT\nを参照",
        "速度・デュレーション": "速度・\nデュレーション",
        "タイムリマップ": "タイム\nリマップ",
        "ボイスオーバー録音": "ボイスオーバー\n録音",
        "キャプションを作成": "キャプション\nを作成",
        "キャプションのスタイル": "キャプション\nのスタイル",
        "キャプションのデザイン": "キャプション\nのデザイン",
        "ラウドネスを自動一致": "ラウドネスを\n自動一致",
        "無音部分を削除": "無音部分\nを削除",
        "モーション・クロップ": "モーション・\nクロップ",
        "フッテージを置き換え": "フッテージを\n置き換え",
        "ワープスタビライザー": "ワープ\nスタビライザー",
        "オーディオエフェクト": "オーディオ\nエフェクト",
        "スピーチを強調": "スピーチ\nを強調",
        "ビートに合わせる": "ビートに\n合わせる",
        "顔に自動モザイク": "顔に自動\nモザイク",
        "おまかせテンプレ": "おまかせ\nテンプレ",
        "おまかせ編集": "おまかせ\n編集",
        "このプロジェクトを空にする": "プロジェクト\nを空にする",
        "パーツとして保存": "パーツとして\n保存",
        "フレーム保持": "フレーム\n保持",
        "オートリフレーム": "オート\nリフレーム",
        "名前テロップ": "名前\nテロップ",
        "ロゴ・透かし": "ロゴ・\n透かし",
        "前回と比較": "前回と\n比較",
        "動画の置き場所": "動画の\n置き場所",
        "全体の仕上げ": "全体の\n仕上げ",
        "聞きやすくする": "聞きやすく\nする",
        "キーフレーム": "キー\nフレーム",
        "アニメーション": "アニメー\nション",
        "文字・スタイル": "文字・\nスタイル",
        "位置・サイズ": "位置・\nサイズ",
        "表示する時間": "表示する\n時間",
        "逆再生を解除": "逆再生を\n解除",
        "曲を変更": "曲を\n変更",
        "文字を直す": "文字を\n直す",
        "オーバーレイ": "オーバー\nレイ"
    ]

    static func wrapped(_ title: String) -> String {
        if let hit = breaks[title] { return hit }
        guard title.count > 6, !title.contains("\n") else { return title }
        // 「・」や空白のあとで折る。なければ真ん中で
        if let dot = title.firstIndex(where: { $0 == "・" || $0 == " " }) {
            let head = title[...dot].trimmingCharacters(in: .whitespaces)
            let tail = title[title.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, !tail.isEmpty { return head + "\n" + tail }
        }
        let mid = title.index(title.startIndex, offsetBy: title.count / 2)
        return String(title[..<mid]) + "\n" + String(title[mid...])
    }
}
