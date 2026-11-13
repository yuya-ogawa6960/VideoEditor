# Freesound の CC0 の音を、AI の音の代わりに使う(Kenney と同じ仕組み。build_free.py の続き)。
# 使い方: python build_fs.py fs_sources.json デコード済みWAVフォルダ 生成フォルダ(raw) sfx_list.tsv
#   fs_sources.json: {id: {"sound_id", "user", "title", "file", "license": "CC0 1.0", "url"}}(ダウンロードしたものだけ)
#   デコード済みWAV: ブラウザで戻した <フォルダ>/freesound/<元のファイル名から拡張子を除いたもの>.wav
#   生成フォルダに <id>_200.wav を書く(Kenney の 100 や AI の 1, 2 より優先される)。
#   長い録音(環境音など)は頭の 1 秒を飛ばして使う(録り始めの物音を避ける)。長さは process_sfx.py が整える。
#   sfx_list.tsv の該当行を engine=free・prompt=出どころ に書き換え、LICENSES.md に Freesound の表を足す。
import csv, json, os, sys, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SR = 44100


def read(path):
    with wave.open(path, "rb") as w:
        ch, sr, n = w.getnchannels(), w.getframerate(), w.getnframes()
        x = np.frombuffer(w.readframes(n), "<i2").astype(np.float64).reshape(-1, ch).T / 32768
    if ch == 1:
        x = np.vstack([x, x])
    return x[:2], sr


def write(path, x):
    pcm = (np.clip(x.T, -1, 1) * 32767).round().astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())


def main():
    src_json, wav_dir, raw_dir, list_path = sys.argv[1:5]
    sources = json.load(open(src_json, encoding="utf-8"))
    rows = {r["id"]: r for r in csv.DictReader(open(list_path, encoding="utf-8"), delimiter="\t")}
    used = {}
    for sid, s in sources.items():
        if sid not in rows:
            print("not in list:", sid)
            continue
        stem = os.path.splitext(s["file"])[0]
        path = os.path.join(wav_dir, "freesound", stem + ".wav")
        if not os.path.exists(path):
            print("missing wav:", sid, stem)
            continue
        x, sr = read(path)
        target = float(rows[sid]["seconds"])
        if x.shape[1] / sr > target + 3:
            x = x[:, int(1.0 * sr):]
        # 必要な分だけ(指定の長さ + 2 秒)。残りは process_sfx.py が無音を切ってフェードする
        x = x[:, :int((target + 2) * sr)]
        write(os.path.join(raw_dir, f"{sid}_200.wav"), x)
        used[sid] = s
        print(f"{sid:18s} <- {s['file']} ({x.shape[1] / sr:.2f}s)")

    # 一覧を書き換える
    lines = open(list_path, encoding="utf-8").read().splitlines()
    out = [lines[0]]
    for l in lines[1:]:
        c = l.split("\t")
        if c[0] in used:
            s = used[c[0]]
            c[4] = "free"
            c[6] = f"Freesound #{s['sound_id']} by {s['user']} ({s['title']}) CC0 1.0"
        out.append("\t".join(c))
    open(list_path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")

    # ライセンスの記録(Freesound の節を作り直す)
    lic_path = os.path.join(HERE, "LICENSES.md")
    md = open(lic_path, encoding="utf-8").read()
    marker = "\n## フリー素材(Freesound / CC0 1.0)\n"
    if marker in md:
        md = md[:md.index(marker)]
    names = {k: r["name_ja"] for k, r in rows.items()}
    sec = [marker.rstrip("\n"), "",
           "Freesound (https://freesound.org) で「Creative Commons 0」と表示されている音だけを、Freesound のサイトから",
           "ダウンロードして使っている(API は使っていない)。CC0 なので表示は不要だが、出どころを残す。", "",
           "| id | 名前 | 元の音 |", "|---|---|---|"]
    for sid, s in used.items():
        sec.append(f"| {sid} | {names.get(sid, '')} | [#{s['sound_id']}]({s['url']}) {s['title']} / {s['user']} |")
    open(lic_path, "w", encoding="utf-8", newline="\n").write(md.rstrip("\n") + "\n" + "\n".join(sec) + "\n")
    json.dump(used, open(os.path.join(HERE, "fs_sources.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"freesound {len(used)}")


if __name__ == "__main__":
    main()
