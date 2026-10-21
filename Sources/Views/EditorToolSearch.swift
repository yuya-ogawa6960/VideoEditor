import SwiftUI

// =====================================================================
// 機能を探す(上部バーの 🔍)。
// 下のツールバーの項目(グループ・「その他」の中も含む)を一覧にし、名前と別名
// (CapCut の呼び方・ふだんの言葉・英語)で絞り込む。選ぶとその機能を実行するか、
// 写真を選ぶ機能などはツールバーをその場所まで開く。
// =====================================================================

struct EditorToolSearchEntry: Identifiable {
    let id: String
    let item: EditorToolItem
    /// 見つけた場所(「Lumetri カラー › HSL セカンダリ」の左側)
    let breadcrumb: String
    /// ツールバーでこの項目を表示するために開くグループ ID の並び
    let groupPath: [String]
    /// 何も選んでいないとき(全体の編集)の機能か
    let isRoot: Bool
}

enum EditorToolSearchIndex {
    /// ツールバーの項目を平らに並べる(グループは中身だけ、小見出しは除く)
    static func flatten(_ items: [EditorToolItem], isRoot: Bool, contextTitle: String) -> [EditorToolSearchEntry] {
        var result: [EditorToolSearchEntry] = []
        func walk(_ list: [EditorToolItem], path: [String], crumbs: [String]) {
            for item in list {
                switch item.kind {
                case .section:
                    continue
                case .group(let children):
                    walk(children, path: path + [item.id], crumbs: crumbs + [item.title])
                default:
                    let crumb = ([contextTitle] + crumbs).joined(separator: " › ")
                    let key = (isRoot ? "root/" : "ctx/") + (path + [item.id]).joined(separator: "/")
                    result.append(EditorToolSearchEntry(id: key, item: item, breadcrumb: crumb,
                                                        groupPath: path, isRoot: isRoot))
                }
            }
        }
        walk(items, path: [], crumbs: [])
        return result
    }

    /// 別名(CapCut の呼び方・ふだんの言葉・英語)。キーはツールバーの表示名
    static let synonyms: [String: [String]] = [
        String(localized: "スプリット"): [String(localized: "分割"), String(localized: "カット"), String(localized: "切る"), String(localized: "レーザー"), String(localized: "編集点"), "split", "cut"],
        String(localized: "リップル削除"): [String(localized: "削除"), String(localized: "消す"), String(localized: "詰める"), "delete"],
        String(localized: "削除"): [String(localized: "消す"), "delete"],
        String(localized: "ビデオトランジション"): [String(localized: "トランジション"), String(localized: "ディゾルブ"), String(localized: "クロスディゾルブ"), String(localized: "暗転"), String(localized: "切り替え"), String(localized: "つなぎ"), "transition", "dissolve"],
        String(localized: "速度・デュレーション"): [String(localized: "速度"), String(localized: "スピード"), String(localized: "早送り"), String(localized: "スロー"), String(localized: "倍速"), String(localized: "長さ"), "speed"],
        String(localized: "タイムリマップ"): [String(localized: "速度カーブ"), String(localized: "なめらか変速"), String(localized: "スピードランプ"), "curve"],
        String(localized: "ボリューム"): [String(localized: "音量"), String(localized: "音の大きさ"), String(localized: "ミュート"), "volume"],
        String(localized: "オーディオエフェクト"): [String(localized: "音声効果"), String(localized: "雑音"), String(localized: "ノイズ"), String(localized: "イコライザー"), "EQ", String(localized: "ピッチ"), String(localized: "声"), "audio"],
        String(localized: "Lumetri プリセット"): [String(localized: "フィルタ"), String(localized: "フィルター"), String(localized: "色味"), String(localized: "ルック"), "filter"],
        String(localized: "Lumetri カラー"): [String(localized: "色調整"), String(localized: "色"), String(localized: "明るさ"), String(localized: "コントラスト"), String(localized: "彩度"), String(localized: "カラー"), "color"],
        String(localized: "HSL セカンダリ"): ["HSL", String(localized: "色ごと"), String(localized: "特定の色")],
        String(localized: "LUT を参照"): ["LUT", "cube", String(localized: "カラーLUT")],
        String(localized: "Lumetri スコープ"): [String(localized: "スコープ"), String(localized: "波形"), String(localized: "ヒストグラム")],
        String(localized: "カラーマッチ"): [String(localized: "色合わせ"), String(localized: "色をそろえる")],
        String(localized: "自動補正"): [String(localized: "オート"), String(localized: "自動"), "auto"],
        String(localized: "描画モード"): [String(localized: "ブレンド"), String(localized: "乗算"), String(localized: "スクリーン"), "blend"],
        String(localized: "フレーム保持"): [String(localized: "フリーズ"), String(localized: "静止画"), String(localized: "止める"), "freeze"],
        String(localized: "ワープスタビライザー"): [String(localized: "手ぶれ補正"), String(localized: "ブレ"), String(localized: "安定"), "stabilize"],
        String(localized: "モーション・クロップ"): [String(localized: "切り抜き"), String(localized: "回転"), String(localized: "トリミング"), String(localized: "クロップ"), String(localized: "反転"), "crop", "rotate"],
        String(localized: "フッテージを置き換え"): [String(localized: "置き換え"), String(localized: "差し替え"), "replace"],
        String(localized: "キャプション"): [String(localized: "字幕"), String(localized: "テロップ"), "subtitle", "caption"],
        String(localized: "キャプションを作成"): [String(localized: "自動字幕"), String(localized: "文字起こし"), String(localized: "字幕"), "Whisper", "AI"],
        String(localized: "キャプションのスタイル"): [String(localized: "字幕のスタイル"), String(localized: "字幕の見た目"), String(localized: "フォント")],
        String(localized: "キャプションのデザイン"): [String(localized: "字幕デザイン"), String(localized: "カラオケ"), String(localized: "テンプレート")],
        String(localized: "ボイスオーバー録音"): [String(localized: "ナレーション"), String(localized: "録音"), String(localized: "声を入れる"), String(localized: "アフレコ")],
        String(localized: "AI読み上げ"): [String(localized: "読み上げ"), String(localized: "音声合成"), "TTS"],
        String(localized: "音声抽出"): [String(localized: "音を取り出す"), String(localized: "動画から音"), "extract"],
        String(localized: "ラウドネスを自動一致"): [String(localized: "音量そろえ"), String(localized: "音量を合わせる"), String(localized: "ノーマライズ"), "loudness"],
        String(localized: "無音部分を削除"): [String(localized: "無音カット"), String(localized: "間を詰める"), String(localized: "ジェットカット"), "silence"],
        "BGM": [String(localized: "音楽"), String(localized: "曲"), String(localized: "ミュージック"), "music"],
        String(localized: "オーバーレイ"): [String(localized: "重ねる"), String(localized: "ワイプ"), String(localized: "Bロール"), String(localized: "ピクチャインピクチャ"), "PiP", "overlay"],
        String(localized: "ステッカー"): [String(localized: "絵文字"), String(localized: "スタンプ"), "sticker"],
        String(localized: "モザイク"): [String(localized: "ぼかし"), String(localized: "顔を隠す"), "mosaic", "blur"],
        String(localized: "スピーチを強調"): [String(localized: "雑音"), String(localized: "ノイズ"), String(localized: "声"), String(localized: "音声分離"), "AI"],
        String(localized: "カラー"): [String(localized: "色"), String(localized: "フィルタ"), "color"],
        String(localized: "モーション"): [String(localized: "動き"), String(localized: "位置"), String(localized: "回転"), "motion"],
        String(localized: "エフェクト"): [String(localized: "効果"), "effect"],
        String(localized: "オーディオ"): [String(localized: "音"), String(localized: "音楽"), "audio"],
        String(localized: "顔に自動モザイク"): [String(localized: "顔"), String(localized: "モザイク"), String(localized: "顔を隠す"), String(localized: "自動")],
        String(localized: "テキスト"): [String(localized: "文字"), String(localized: "タイトル"), "text"],
        String(localized: "名前テロップ"): [String(localized: "ローワーサード"), String(localized: "名前"), String(localized: "肩書き")],
        String(localized: "章タイトル"): [String(localized: "チャプター"), String(localized: "見出し"), String(localized: "タイトルカード")],
        String(localized: "トラッキング"): [String(localized: "追従"), String(localized: "追いかける"), String(localized: "動きに合わせる"), "tracking"],
        String(localized: "キーフレーム"): [String(localized: "動きをつける"), String(localized: "アニメーション"), "keyframe"],
        String(localized: "アニメーション"): [String(localized: "登場"), String(localized: "出てくる動き"), String(localized: "イン"), String(localized: "アウト")],
        String(localized: "マスク"): [String(localized: "切り抜き"), String(localized: "形"), "mask"],
        String(localized: "オートリフレーム"): [String(localized: "中央に"), String(localized: "縦動画"), String(localized: "人物を中央"), "reframe"],
        String(localized: "画質補正"): [String(localized: "画質アップ"), String(localized: "きれいにする"), String(localized: "美肌"), String(localized: "ノイズ除去")],
        String(localized: "3Dズーム"): [String(localized: "立体"), String(localized: "パララックス"), String(localized: "奥行き")],
        "Ken Burns": [String(localized: "ゆっくりズーム"), String(localized: "パン"), String(localized: "ズーム")],
        String(localized: "比率"): [String(localized: "縦横"), "9:16", "16:9", String(localized: "正方形"), String(localized: "アスペクト")],
        String(localized: "全体の仕上げ"): [String(localized: "ドキュメンタリー"), String(localized: "シネマ"), String(localized: "黒帯"), String(localized: "フィルム"), String(localized: "粒子")],
        String(localized: "マーカー"): [String(localized: "目印"), String(localized: "印"), "marker"],
        String(localized: "ロゴ・透かし"): [String(localized: "ウォーターマーク"), String(localized: "ロゴ"), String(localized: "透かし")],
        String(localized: "サムネ"): [String(localized: "表紙"), String(localized: "サムネイル"), String(localized: "カバー"), "thumbnail"],
        String(localized: "フォーマット"): [String(localized: "お決まりパーツ"), String(localized: "テンプレート"), String(localized: "オープニング")],
        String(localized: "前回と比較"): [String(localized: "比較"), String(localized: "ビフォーアフター")],
        String(localized: "手書き"): [String(localized: "描く"), String(localized: "ペン"), String(localized: "落書き")],
        String(localized: "複製"): [String(localized: "コピー"), "duplicate"],
        String(localized: "逆再生"): [String(localized: "リバース"), String(localized: "巻き戻し"), "reverse"],
        String(localized: "マルチカメラ"): [String(localized: "複数カメラ"), String(localized: "カメラ切り替え"), "multicam"],
        String(localized: "複数選択"): [String(localized: "まとめて"), String(localized: "一括"), String(localized: "選択")],
        String(localized: "ビートに合わせる"): [String(localized: "ビート"), String(localized: "リズム"), String(localized: "音楽に合わせる")],
        String(localized: "J/Lカット"): [String(localized: "音のずらし"), String(localized: "音を先行"), String(localized: "Jカット"), String(localized: "Lカット")],
        String(localized: "おまかせ編集"): [String(localized: "自動編集"), String(localized: "AI編集")],
        String(localized: "中だるみ・編集チェック"): [String(localized: "中だるみ"), String(localized: "チェック"), String(localized: "テンポ"), String(localized: "離脱"), "YouTube", String(localized: "アドバイス"), String(localized: "診断")],
        String(localized: "動画・写真を追加"): [String(localized: "追加"), String(localized: "素材"), String(localized: "読み込み"), String(localized: "インポート")],
    ]

    static func matches(_ entry: EditorToolSearchEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let title = entry.item.title
        if title.localizedCaseInsensitiveContains(q) { return true }
        if entry.breadcrumb.localizedCaseInsensitiveContains(q) { return true }
        for word in synonyms[title] ?? [] where word.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains(word) {
            return true
        }
        return false
    }
}

struct EditorToolSearchSheet: View {
    let contextEntries: [EditorToolSearchEntry]
    let contextTitle: String
    let rootEntries: [EditorToolSearchEntry]
    let onPick: (EditorToolSearchEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let context = contextEntries.filter { EditorToolSearchIndex.matches($0, query: query) }
                let root = rootEntries.filter { EditorToolSearchIndex.matches($0, query: query) }
                if context.isEmpty && root.isEmpty {
                    Text("見つかりませんでした。別の言葉で探してみてください(例: 字幕、ぼかし、速度)。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !context.isEmpty {
                    Section(contextTitle) {
                        ForEach(context) { entry in
                            row(entry)
                        }
                    }
                }
                if !root.isEmpty {
                    Section("全体の編集") {
                        ForEach(root) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "機能の名前・やりたいこと"))
            .navigationTitle("機能を探す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ entry: EditorToolSearchEntry) -> some View {
        Button {
            onPick(entry)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.item.systemImage.isEmpty ? "square" : entry.item.systemImage)
                    .frame(width: 28)
                    .foregroundStyle(entry.item.isDestructive ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                        .foregroundStyle(entry.item.isEnabled ? Color.primary : Color.secondary)
                    Text(entry.breadcrumb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
