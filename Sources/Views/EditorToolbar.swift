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

/// ツールバーのボタンを長押ししたときのメニューの 1 項目
struct EditorToolMenuEntry: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.id = title
        self.title = title
        self.systemImage = systemImage
        self.action = action
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
        /// 列の中の小見出し(区切り線だけのものも)。タップできない
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
    /// 長押しで出すメニュー(.action の項目だけ。空なら出さない)
    private(set) var menu: [EditorToolMenuEntry] = []
    /// true ならタップでメニューを開く(長押しは分かりにくいので、選択肢のあるボタンはタップで出す)。
    /// tapTitle があれば、いつもの動作(action)をその名前でメニューの先頭に入れる
    private(set) var menuOnTap: Bool = false
    private(set) var tapTitle: String?

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

    /// 「その他」グループの ID(最上段ではツールバーの右端に「設定」と並べて固定して出す)
    static let moreID = "group-more"

    /// 「その他」グループ
    static func more(_ items: [EditorToolItem]) -> EditorToolItem {
        group(String(localized: "その他"), systemImage: "ellipsis.circle", id: moreID, items: items)
    }

    /// 「設定」グループの ID(最上段では「その他」の右隣に固定して出す)
    static let settingsID = "group-settings"

    /// 「設定」グループ(比率・動画の置き場所・プロジェクトを空にする など)
    static func settings(_ items: [EditorToolItem]) -> EditorToolItem {
        group(String(localized: "設定"), systemImage: "gearshape", id: settingsID, items: items)
    }

    /// 最上段でスクロールの外に固定して出す項目か(「その他」「設定」)
    var isPinnedAtRoot: Bool {
        id == EditorToolItem.moreID || id == EditorToolItem.settingsID
    }

    /// 右の列(縦)で最上段のいちばん下に固定して出す項目か(「設定」だけ。「その他」はスクロール側に入れる)
    var isPinnedAtRootVertical: Bool {
        id == EditorToolItem.settingsID
    }

    /// 列の中の小見出し
    static func section(_ title: String) -> EditorToolItem {
        EditorToolItem(id: "section-\(title)", title: title, systemImage: "", enabled: true,
                       disabledReason: nil, kind: .section)
    }

    /// 長押しのメニューを付けたコピー
    func withMenu(_ entries: [EditorToolMenuEntry]) -> EditorToolItem {
        var copy = self
        copy.menu = entries
        return copy
    }

    /// タップでメニューを開くコピー。tapTitle を渡すと、いつもの動作(action)をその名前で先頭に入れる(nil なら entries だけ)
    func withTapMenu(_ entries: [EditorToolMenuEntry], tapTitle: String? = nil) -> EditorToolItem {
        var copy = self
        copy.menu = entries
        copy.menuOnTap = true
        copy.tapTitle = tapTitle
        return copy
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
    /// .horizontal: 下の横並び(いつもの形)。.vertical: iPhone Duo を開いたときに右の列(時刻などが出る列)に縦に並べる
    var axis: Axis = .horizontal

    /// 項目を並べる列の幅(広い画面では中央に寄せるため)
    @State private var rowWidth: CGFloat = 0
    /// 横スクロールの中身の幅(表示幅より広いときだけ右端にグラデーションを重ねて「続きがある」と見せる)
    @State private var rowContentWidth: CGFloat = 0
    /// 右の列(縦)のスクロール部分の高さ。項目が少ないときに下へ寄せるために使う
    @State private var verticalScrollHeight: CGFloat = 0

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
        if axis == .vertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    /// 下の横並び(いつもの形)
    private var horizontalBody: some View {
        let state = resolved
        let showsBack = !groupPath.isEmpty || onBack != nil
        // 最上段では「その他」「設定」をスクロールの外(右端)に固定する(項目が多いと画面の外に出て見つからないため)
        let pinnedItems: [EditorToolItem] = groupPath.isEmpty ? state.items.filter { $0.isPinnedAtRoot } : []
        let scrolledItems: [EditorToolItem] = pinnedItems.isEmpty ? state.items : state.items.filter { !$0.isPinnedAtRoot }

        return HStack(spacing: 0) {
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
                // 大きな文字の設定では長押しで拡大して見せる
                .accessibilityShowsLargeContentViewer {
                    Label(state.groupTitle ?? String(localized: "選択を解除"), systemImage: "chevron.left")
                }

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 32)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(scrolledItems) { item in
                        cell(item)
                    }
                }
                .padding(.horizontal, 6)
                // iPhone Duo を開いたときなど広い画面では、収まる項目を中央に寄せる(左に固まって右が空かないように)
                .frame(minWidth: rowWidth >= 600 ? rowWidth : 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowContentWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            // 続きがあるときは右端に黒のグラデーションを重ねて「スクロールできる」と見せる(タップは通す)
            .overlay(alignment: .trailing) {
                if rowContentWidth > rowWidth + 1 {
                    LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.85)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .id(groupPath.joined(separator: "/"))

            if !pinnedItems.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 32)
                ForEach(pinnedItems) { item in
                    cell(item)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 78)
        // 下の動画が透けないよう、黒の上に面の色を重ねる
        .background {
            ZStack {
                Color.black
                BrandStyle.surface
            }
        }
    }

    /// 右の列(iPhone Duo)。上は時刻・電池・電波が縦に並ぶ場所なので、項目は下(親指の近く)に寄せる:
    /// 項目の縦スクロール(少ないときは下寄せ) → ‹(戻る / 選択解除) → 「設定」(最上段だけ、いちばん下に固定。「その他」はスクロール側)
    private var verticalBody: some View {
        let state = resolved
        let showsBack = !groupPath.isEmpty || onBack != nil
        // 最上段では「設定」だけをスクロールの外(いちばん下)に固定する(縦は場所が少ないので「その他」はスクロール側に入れる)
        let pinnedItems: [EditorToolItem] = groupPath.isEmpty ? state.items.filter { $0.isPinnedAtRootVertical } : []
        let scrolledItems: [EditorToolItem] = pinnedItems.isEmpty ? state.items : state.items.filter { !$0.isPinnedAtRootVertical }

        return VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(scrolledItems) { item in
                        cell(item)
                    }
                }
                .padding(.vertical, 6)
                // 項目が少ないときは下に寄せる(上は時刻・電池に近いので空けておく)
                .frame(minHeight: verticalScrollHeight, alignment: .bottom)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                verticalScrollHeight = height
            }
            .id(groupPath.joined(separator: "/"))

            if showsBack {
                verticalDivider
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
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.groupTitle != nil ? String(localized: "戻る") : String(localized: "選択を解除"))
                .accessibilityShowsLargeContentViewer {
                    Label(state.groupTitle ?? String(localized: "選択を解除"), systemImage: "chevron.left")
                }
            }

            if !pinnedItems.isEmpty {
                // 戻るボタンと固定の「設定」が続くと押し間違えやすいので 8pt 空ける
                if showsBack {
                    Color.clear.frame(height: 8)
                }
                verticalDivider
                ForEach(pinnedItems) { item in
                    cell(item)
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 下の動画が透けないよう、黒の上に面の色を重ねる
        .background {
            ZStack {
                Color.black
                BrandStyle.surface
            }
        }
    }

    /// 縦の列で使う横の区切り線
    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(height: 1)
            .padding(.horizontal, 10)
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
                // 使い勝手の計測: なぜ使えないか伝わっていない印
                Analytics.shared.track("disabled_tap", ["tool": item.id, "icon": item.systemImage])
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
            let button = Button {
                EditorHaptics.tap()
                action()
            } label: {
                label(item)
            }
            .buttonStyle(.plain)
            if item.menu.isEmpty {
                button
            } else if item.menuOnTap {
                // タップでメニュー(長押しは気づかれにくい)。いつもの動作は tapTitle の名前で先頭に
                Menu {
                    if let tapTitle = item.tapTitle {
                        Button {
                            EditorHaptics.tap()
                            action()
                        } label: {
                            Label(tapTitle, systemImage: item.systemImage)
                        }
                        Divider()
                    }
                    ForEach(item.menu) { entry in
                        Button {
                            entry.action()
                        } label: {
                            Label(entry.title, systemImage: entry.systemImage)
                        }
                    }
                } label: {
                    label(item)
                }
                .buttonStyle(.plain)
            } else {
                button.contextMenu {
                    ForEach(item.menu) { entry in
                        Button {
                            entry.action()
                        } label: {
                            Label(entry.title, systemImage: entry.systemImage)
                        }
                    }
                }
            }
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
                         matching: .any(of: [.videos, .images]),
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

    @ViewBuilder
    private func label(_ item: EditorToolItem) -> some View {
        if axis == .vertical {
            verticalLabel(item)
        } else {
            horizontalLabel(item)
        }
    }

    /// 縦の列のセル: アイコンの下に 1〜2 行の名前。幅は列いっぱい
    private func verticalLabel(_ item: EditorToolItem) -> some View {
        let color: Color = item.isDestructive ? Color.red : Color.white
        return VStack(spacing: 4) {
            Image(systemName: item.systemImage)
                .font(.system(size: 20))
                .frame(height: 26)
            Text(EditorToolLabel.wrapped(item.title))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .lineSpacing(-1)
                // 列の幅に収まらない名前は少しだけ縮める
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(item.title)
        }
        .foregroundStyle(color)
        .opacity(item.isEnabled ? 1 : 0.45)
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.systemImage)
        }
    }

    private func horizontalLabel(_ item: EditorToolItem) -> some View {
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
                // 読み上げは途中で折っていない名前で
                .accessibilityLabel(item.title)
        }
        .foregroundStyle(color)
        .opacity(item.isEnabled ? 1 : 0.45)
        .frame(minWidth: 58, minHeight: 64)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // ツールバーは高さが決まっていて文字を大きくできないので、大きな文字の設定では長押しで拡大して見せる
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.systemImage)
        }
    }

    /// 小見出し。名前が空なら区切り線だけ
    @ViewBuilder
    private func sectionLabel(_ item: EditorToolItem) -> some View {
        if axis == .vertical {
            // 縦の列では横の区切り線。名前があればその下に小さく出す
            VStack(spacing: 4) {
                verticalDivider
                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .padding(.vertical, 6)
            .accessibilityHidden(item.title.isEmpty)
        } else if item.title.isEmpty {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 32)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)
        } else {
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
        .background {
            // 動画の上に出るので、黒で下地を作ってから面の色を重ねる
            Capsule()
                .fill(Color.black.opacity(0.92))
                .overlay(Capsule().fill(BrandStyle.surfaceStrong))
        }
        .shadow(color: Color.black.opacity(0.4), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }

    /// 出るとき: ゆっくりふわっと(少し下からにじむように)
    static let showAnimation: Animation = .spring(duration: 0.6, bounce: 0.18)
    /// 消えるとき: 真ん中へスッと吸い込まれる
    static let hideAnimation: Animation = .easeIn(duration: 0.3)
}

/// トーストの出入りの見た目(ぼかし・大きさ・透明度・位置)
struct ToastCloudModifier: ViewModifier {
    var scale: CGFloat
    var opacity: Double
    var blur: CGFloat
    var offsetY: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .center)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(y: offsetY)
    }
}

extension AnyTransition {
    /// 雲のようにふわっと現れ(ぼけた小さな姿から、少し浮き上がりながらはっきりする)、
    /// 消えるときは真ん中にスッと吸い込まれる(中心へ縮みながら薄くなる)
    static var toastCloud: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ToastCloudModifier(scale: 0.82, opacity: 0, blur: 12, offsetY: 16),
                                 identity: ToastCloudModifier(scale: 1, opacity: 1, blur: 0, offsetY: 0)),
            removal: .modifier(active: ToastCloudModifier(scale: 0.04, opacity: 0, blur: 3, offsetY: 0),
                               identity: ToastCloudModifier(scale: 1, opacity: 1, blur: 0, offsetY: 0))
        )
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
            .background(Capsule().fill(BrandStyle.surfaceStrong))
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
        "トランジション": "トランジ\nション",
        "カラープリセット": "カラー\nプリセット",
        "カラー補正": "カラー\n補正",
        "カラースコープ": "カラー\nスコープ",
        "HSL セカンダリ": "HSL\nセカンダリ",
        "タイムリマップ": "タイム\nリマップ",
        "キャプションのスタイル": "キャプション\nのスタイル",
        "字幕デザイン": "字幕\nデザイン",
        "位置・クロップ": "位置・\nクロップ",
        "スタビライザー": "スタビ\nライザー",
        "スピーチを強調": "スピーチ\nを強調",
        "映像エフェクト": "映像\nエフェクト",
        "スライドショー": "スライド\nショー",
        "オートパンチイン": "オート\nパンチイン",
        "言いよどみカット": "言いよどみ\nカット",
        "文字起こし編集": "文字起こし\n編集",
        "被写体フラッシュ": "被写体\nフラッシュ",
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
        "キーフレーム": "キー\nフレーム",
        "アニメーション": "アニメー\nション",
        "文字・スタイル": "文字・\nスタイル",
        "位置・サイズ": "位置・\nサイズ",
        "表示する時間": "表示する\n時間",
        "逆再生を解除": "逆再生を\n解除",
        "トリミングを解除": "トリミング\nを解除",
        "ファイルから追加": "ファイル\nから追加",
        "BGMを置き換え": "BGMを\n置き換え",
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
        // 真ん中で折るのは日本語で表示しているときだけ(英語などの単語を途中で切らない。1 行のままセルが広がる)
        guard Bundle.main.preferredLocalizations.first == "ja" else { return title }
        let mid = title.index(title.startIndex, offsetBy: title.count / 2)
        return String(title[..<mid]) + "\n" + String(title[mid...])
    }
}
