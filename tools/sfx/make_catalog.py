# sfx_list.tsv から、アプリの一覧(Sources/Model/SFXCatalog.swift)を作る。
# 使い方: python make_catalog.py sfx_list.tsv ../../Sources/Model/SFXCatalog.swift
# id はファイル名(se_<id>.m4a)と保存データに使うので、一度出したら変えない。
import csv, json, sys

CATEGORIES = [
    ("transition", "切り替え"), ("telop", "テロップ・UI"), ("variety", "バラエティ"), ("crowd", "歓声・反応"),
    ("sparkle", "キラキラ"), ("impact", "衝撃・アクション"), ("daily", "日常"), ("food", "料理・食事"),
    ("town", "乗り物・街"), ("nature", "自然・天気"), ("animal", "動物"), ("season", "季節・和"),
    ("game", "ゲーム"), ("horror", "ホラー・ミステリー"), ("sports", "スポーツ・イベント"), ("jingle", "ジングル"),
]


def q(s):
    return json.dumps(s, ensure_ascii=False)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rows = list(csv.DictReader(open(src, encoding="utf-8"), delimiter="\t"))
    keys = [k for k, _ in CATEGORIES]
    ids = set()
    for r in rows:
        assert r["category"] in keys, r
        assert r["id"] not in ids, r["id"]
        assert r["id"].replace("_", "").isalnum() and r["id"].islower(), r["id"]
        ids.add(r["id"])
    out = []
    out.append("import Foundation")
    out.append("")
    out.append("// =====================================================================")
    out.append("// 同梱の効果音の一覧(Stable Audio 2.5 で作った音。ファイルは Resources/SFX/se_<id>.m4a)。")
    out.append("// tools/sfx/make_catalog.py が tools/sfx/sfx_list.tsv から作る。手で直さない(一覧を直して作り直す)。")
    out.append("// id はファイル名と保存データに使うので変えない")
    out.append("// =====================================================================")
    out.append("")
    out.append("/// 効果音パネルの分類(タブ)")
    out.append("enum SFXCategory: String, CaseIterable, Identifiable {")
    out.append("    case " + ", ".join(keys))
    out.append("")
    out.append("    var id: String { rawValue }")
    out.append("")
    out.append("    var title: String {")
    out.append("        switch self {")
    for k, t in CATEGORIES:
        out.append(f"        case .{k}: return String(localized: {q(t)})")
    out.append("        }")
    out.append("    }")
    out.append("}")
    out.append("")
    out.append("/// 同梱の効果音 1 つ")
    out.append("struct SFXItem: Identifiable, Hashable {")
    out.append("    let id: String")
    out.append("    let category: SFXCategory")
    out.append("    /// 表示名の翻訳キー(日本語)")
    out.append("    let nameKey: String")
    out.append("    /// 環境音(雨・街の音など。頭を切らずにフェードインしてある)")
    out.append("    let isAmbience: Bool")
    out.append("")
    out.append("    var name: String { String(localized: String.LocalizationValue(nameKey)) }")
    out.append("}")
    out.append("")
    out.append("enum SFXCatalog {")
    out.append(f"    /// {len(rows)} 種類(パネルに出る順)")
    out.append("    static let all: [SFXItem] = [")
    for r in rows:
        amb = "true" if r["style"] == "amb" else "false"
        out.append(f"        SFXItem(id: {q(r['id'])}, category: .{r['category']}, nameKey: {q(r['name_ja'])}, isAmbience: {amb}),")
    out.append("    ]")
    out.append("}")
    out.append("")
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print(f"{len(rows)} sounds -> {dst}")


if __name__ == "__main__":
    main()
