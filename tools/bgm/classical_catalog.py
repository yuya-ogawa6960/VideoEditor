# クラシック(パブリックドメインの録音)を BGM の一覧に足す。classical_manifest.json(fetch_classical.py の記録)から作る。
# 曲は MP3(元が MP3 ならそのまま、ほかは Commons が作った MP3 版 listen.mp3)を classical_<key>_1.mp3 として出す。
# 使い方: python classical_catalog.py classical_manifest.json ダウンロードしたフォルダ 出力フォルダ catalog.json
import json, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_catalog import mp3_seconds

# 画面に出す名前と、クレジット(演奏・出どころ)。Musopen は名前を書いてほしいと頼んでいる
SONGS = {
    "cancan": ("天国と地獄", "演奏: Musopen"),
    "william_tell": ("ウィリアム・テル序曲", "演奏: 米海兵隊バンド"),
    "gymnopedie": ("ジムノペディ第1番", "ピアノ: Robin Alciatore(Musopen)"),
    "nocturne": ("ノクターン 作品9-2", "ピアノ: Frank Lévy(Musopen)"),
    "morning": ("朝(ペール・ギュント)", "演奏: Musopen Symphony"),
    "mountain_king": ("山の魔王の宮殿にて", "演奏: Musopen Symphony"),
    "air": ("G線上のアリア", "演奏: 米空軍バンド"),
    "fur_elise": ("エリーゼのために", "ピアノ: V Gao"),
    "new_world_4": ("新世界より 第4楽章", "演奏: Musopen"),
    "new_world_2": ("新世界より 第2楽章", "演奏: Musopen"),
    "bald_mountain": ("はげ山の一夜", "演奏: Musopen"),
    "moonlight": ("月光 第1楽章", "ピアノ: Paul Pitman(Musopen)"),
    "canon": ("カノン", "演奏: 米空軍バンド"),
    "pomp": ("威風堂々 第1番", "演奏: 米海兵隊バンド"),
    "blue_danube": ("美しく青きドナウ", "演奏: 米海兵隊バンド"),
    "flowers_waltz": ("花のワルツ", "演奏: 米空軍バンド"),
    "clair_de_lune": ("月の光", "演奏: 米空軍バンド"),
    "bumblebee": ("熊蜂の飛行", "演奏: 米空軍バンド"),
    "spring": ("四季「春」第1楽章", "演奏: The Modena Chamber Orchestra(Musopen)"),
    "berceuse": ("子守歌(ショパン)", "ピアノ: Veronica van der Knaap"),
    "toccata": ("トッカータとフーガ", "オルガン: Ashtar Moïra"),
    "danse_macabre": ("死の舞踏", "演奏: フィラデルフィア管弦楽団(1925年)"),
    "hungarian5": ("ハンガリー舞曲第5番", "ピアノ: Arthur Nikisch(1906年)"),
}

def main():
    manifest = {e["key"]: e for e in json.load(open(sys.argv[1], encoding="utf-8"))}
    src, out_dir, catalog_path = sys.argv[2], sys.argv[3], sys.argv[4]
    os.makedirs(out_dir, exist_ok=True)
    tracks = []
    for key, (name, credit) in SONGS.items():
        e = manifest[key]
        folder = os.path.join(src, key)
        path = os.path.join(src, e["localFile"]) if e["mime"] == "audio/mpeg" else os.path.join(folder, "listen.mp3")
        file = f"classical_{key}_1.mp3"
        shutil.copyfile(path, os.path.join(out_dir, file))
        tracks.append({"id": "classical_" + key, "name": name, "mood": "classical", "bpm": 0,
                       "duration": round(mp3_seconds(path), 2), "file": file, "bytes": os.path.getsize(path),
                       "credit": credit, "source": e["page"], "license": e["license"]})
    catalog = json.load(open(catalog_path, encoding="utf-8"))
    catalog["tracks"] = [t for t in catalog["tracks"] if t["mood"] != "classical"] + tracks
    json.dump(catalog, open(catalog_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("classical", len(tracks), "total", len(catalog["tracks"]))
    for t in tracks: print(t["id"], t["duration"])

if __name__ == "__main__":
    main()
