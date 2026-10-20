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
        "スプリット": ["分割", "カット", "切る", "レーザー", "編集点", "split", "cut"],
        "リップル削除": ["削除", "消す", "詰める", "delete"],
        "削除": ["消す", "delete"],
        "ビデオトランジション": ["トランジション", "ディゾルブ", "クロスディゾルブ", "暗転", "切り替え", "つなぎ", "transition", "dissolve"],
        "速度・デュレーション": ["速度", "スピード", "早送り", "スロー", "倍速", "長さ", "speed"],
        "タイムリマップ": ["速度カーブ", "なめらか変速", "スピードランプ", "curve"],
        "ボリューム": ["音量", "音の大きさ", "ミュート", "volume"],
        "オーディオエフェクト": ["音声効果", "雑音", "ノイズ", "イコライザー", "EQ", "ピッチ", "声", "audio"],
        "Lumetri プリセット": ["フィルタ", "フィルター", "色味", "ルック", "filter"],
        "Lumetri カラー": ["色調整", "色", "明るさ", "コントラスト", "彩度", "カラー", "color"],
        "HSL セカンダリ": ["HSL", "色ごと", "特定の色"],
        "LUT を参照": ["LUT", "cube", "カラーLUT"],
        "Lumetri スコープ": ["スコープ", "波形", "ヒストグラム"],
        "カラーマッチ": ["色合わせ", "色をそろえる"],
        "自動補正": ["オート", "自動", "auto"],
        "描画モード": ["ブレンド", "乗算", "スクリーン", "blend"],
        "フレーム保持": ["フリーズ", "静止画", "止める", "freeze"],
        "ワープスタビライザー": ["手ぶれ補正", "ブレ", "安定", "stabilize"],
        "モーション・クロップ": ["切り抜き", "回転", "トリミング", "クロップ", "反転", "crop", "rotate"],
        "フッテージを置き換え": ["置き換え", "差し替え", "replace"],
        "キャプション": ["字幕", "テロップ", "subtitle", "caption"],
        "キャプションを作成": ["自動字幕", "文字起こし", "字幕", "Whisper", "AI"],
        "キャプションのスタイル": ["字幕のスタイル", "字幕の見た目", "フォント"],
        "キャプションのデザイン": ["字幕デザイン", "カラオケ", "テンプレート"],
        "ボイスオーバー録音": ["ナレーション", "録音", "声を入れる", "アフレコ"],
        "AI読み上げ": ["読み上げ", "音声合成", "TTS"],
        "音声抽出": ["音を取り出す", "動画から音", "extract"],
        "ラウドネスを自動一致": ["音量そろえ", "音量を合わせる", "ノーマライズ", "loudness"],
        "無音部分を削除": ["無音カット", "間を詰める", "ジェットカット", "silence"],
        "BGM": ["音楽", "曲", "ミュージック", "music"],
        "オーバーレイ": ["重ねる", "ワイプ", "Bロール", "ピクチャインピクチャ", "PiP", "overlay"],
        "ステッカー": ["絵文字", "スタンプ", "sticker"],
        "モザイク": ["ぼかし", "顔を隠す", "mosaic", "blur"],
        "スピーチを強調": ["雑音", "ノイズ", "声", "音声分離", "AI"],
        "カラー": ["色", "フィルタ", "color"],
        "モーション": ["動き", "位置", "回転", "motion"],
        "エフェクト": ["効果", "effect"],
        "オーディオ": ["音", "音楽", "audio"],
        "顔に自動モザイク": ["顔", "モザイク", "顔を隠す", "自動"],
        "テキスト": ["文字", "タイトル", "text"],
        "名前テロップ": ["ローワーサード", "名前", "肩書き"],
        "章タイトル": ["チャプター", "見出し", "タイトルカード"],
        "トラッキング": ["追従", "追いかける", "動きに合わせる", "tracking"],
        "キーフレーム": ["動きをつける", "アニメーション", "keyframe"],
        "アニメーション": ["登場", "出てくる動き", "イン", "アウト"],
        "マスク": ["切り抜き", "形", "mask"],
        "オートリフレーム": ["中央に", "縦動画", "人物を中央", "reframe"],
        "画質補正": ["画質アップ", "きれいにする", "美肌", "ノイズ除去"],
        "3Dズーム": ["立体", "パララックス", "奥行き"],
        "Ken Burns": ["ゆっくりズーム", "パン", "ズーム"],
        "比率": ["縦横", "9:16", "16:9", "正方形", "アスペクト"],
        "全体の仕上げ": ["ドキュメンタリー", "シネマ", "黒帯", "フィルム", "粒子"],
        "マーカー": ["目印", "印", "marker"],
        "ロゴ・透かし": ["ウォーターマーク", "ロゴ", "透かし"],
        "サムネ": ["表紙", "サムネイル", "カバー", "thumbnail"],
        "フォーマット": ["お決まりパーツ", "テンプレート", "オープニング"],
        "前回と比較": ["比較", "ビフォーアフター"],
        "手書き": ["描く", "ペン", "落書き"],
        "複製": ["コピー", "duplicate"],
        "逆再生": ["リバース", "巻き戻し", "reverse"],
        "マルチカメラ": ["複数カメラ", "カメラ切り替え", "multicam"],
        "複数選択": ["まとめて", "一括", "選択"],
        "ビートに合わせる": ["ビート", "リズム", "音楽に合わせる"],
        "J/Lカット": ["音のずらし", "音を先行", "Jカット", "Lカット"],
        "おまかせ編集": ["自動編集", "AI編集"],
        "動画・写真を追加": ["追加", "素材", "読み込み", "インポート"],
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
                        prompt: "機能の名前・やりたいこと")
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
