# フリー素材(CC0)から効果音を選んで、AI の音の代わりに使う。
# 使い方: python build_free.py free_map.tsv フリー素材のWAVフォルダ(kenney_wav2) 生成フォルダ(raw) sfx_list.tsv
#   WAV はブラウザ(decodeAudioData)で戻したものを使う。VLC で戻すと短い音の頭が消える(2026-11-11 に確認)
#   free_map.tsv の 1 行ごとに、同じ種類の音(click_001〜005 など)から代表を 1 つ選び(割れていない・大きさが真ん中のもの)、
#   生成フォルダに <id>_100.wav として書く。process_sfx.py はいちばん大きい番号を使うので、AI の音(1, 2)より優先される。
#   mode: single = 1 つ選ぶ / seq = 何個かをつなげて歩く音にする /
#         rise-long・rise-short・fall・short・long = ジングルを音の高さの動き(上がる・下がる)と長さで選ぶ
#   sfx_list.tsv の該当行は engine=free・prompt=出どころ に書き換え、ない id は行を足す。
#   出どころは free_sources.json と LICENSES.md に残す。
import csv, json, os, re, sys, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SR = 44100
PACK_TITLES = {
    "interface-sounds": "Interface Sounds", "ui-audio": "UI Audio", "impact-sounds": "Impact Sounds",
    "digital-audio": "Digital Audio", "music-jingles": "Music Jingles", "casino-audio": "Casino Audio",
    "rpg-audio": "RPG Audio", "sci-fi-sounds": "Sci-fi Sounds",
}


def read(path):
    with wave.open(path, "rb") as w:
        ch, sr, n = w.getnchannels(), w.getframerate(), w.getnframes()
        x = np.frombuffer(w.readframes(n), "<i2").astype(np.float64).reshape(-1, ch).T / 32768
    if ch == 1:
        x = np.vstack([x, x])
    if sr != SR:
        t_old = np.arange(x.shape[1]) / sr
        t_new = np.arange(int(round(x.shape[1] * SR / sr))) / SR
        x = np.vstack([np.interp(t_new, t_old, c) for c in x[:2]])
    return x[:2]


def write(path, x):
    pcm = (np.clip(x.T, -1, 1) * 32767).round().astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())


def stats(x):
    m = np.abs(x).max(axis=0)
    return {"dur": x.shape[1] / SR, "peak": float(m.max()), "rms": float(np.sqrt((x ** 2).mean())),
            "clipped": int((m > 0.995).sum())}


def pitch_trend(x):
    # 音の高さが上がるか下がるか(はじめの 1/4 と終わりの 1/4 の、いちばん強い周波数の比。2 を底にした対数)
    mono = x.mean(axis=0)
    win, hop = 4096, 2048
    freqs, energies = [], []
    window = np.hanning(win)
    for i in range(0, max(1, len(mono) - win), hop):
        seg = mono[i:i + win] * window
        spec = np.abs(np.fft.rfft(seg))
        f = np.fft.rfftfreq(win, 1 / SR)
        band = (f > 80) & (f < 4000)
        k = np.argmax(spec[band])
        freqs.append(f[band][k])
        energies.append(float((seg ** 2).mean()))
    if len(freqs) < 4:
        return 0.0
    e = np.array(energies)
    keep = e > e.max() * 0.03
    fr = np.array(freqs)[keep]
    if len(fr) < 4:
        return 0.0
    q = max(1, len(fr) // 4)
    return float(np.log2(np.median(fr[-q:]) / np.median(fr[:q])))


def candidates(wav_dir, pack, group):
    d = os.path.join(wav_dir, pack)
    pat = re.compile(re.escape(group) + r"[_-]?\d*\.wav$", re.IGNORECASE)
    return sorted(os.path.join(d, f) for f in os.listdir(d) if pat.fullmatch(f))


def pick_single(files):
    rows = []
    for f in files:
        s = stats(read(f))
        rows.append((s["clipped"] > 10, s["rms"], -s["dur"], f))
    ok = [r for r in rows if not r[0]] or rows
    # 短すぎるもの(0.05 秒未満。聞き取りにくい)は、ほかに候補があれば使わない
    ok = [r for r in ok if -r[2] >= 0.05] or ok
    ok.sort(key=lambda r: r[1])
    return ok[len(ok) // 2][3]


def pick_jingle(files, mode, used):
    rows = []
    for f in files:
        if f in used:
            continue
        x = read(f)
        rows.append({"file": f, "dur": x.shape[1] / SR, "trend": pitch_trend(x)})
    if mode == "rise-long":
        pool = [r for r in rows if r["trend"] > 0.2] or rows
        return max(pool, key=lambda r: r["dur"])["file"]
    if mode == "rise-short":
        pool = [r for r in rows if r["trend"] > 0.2] or rows
        return min(pool, key=lambda r: r["dur"])["file"]
    if mode == "fall":
        return min(rows, key=lambda r: r["trend"])["file"]
    if mode == "short":
        return min(rows, key=lambda r: r["dur"])["file"]
    if mode == "long":
        return max(rows, key=lambda r: r["dur"])["file"]
    raise ValueError(mode)


def build_seq(files, gap):
    # 足音: 何種類かを一定の間隔で並べる(同じ音のくり返しにならないように順に使う)
    parts = [read(f) for f in files[:5]]
    step = int(gap * SR)
    total = step * (len(parts) - 1) + max(p.shape[1] for p in parts)
    out = np.zeros((2, total))
    for i, p in enumerate(parts):
        out[:, i * step:i * step + p.shape[1]] += p
    return out


def main():
    map_path, wav_dir, raw_dir, list_path = sys.argv[1:5]
    rows = list(csv.DictReader(open(map_path, encoding="utf-8"), delimiter="\t"))
    used_by_group = {}
    sources = {}
    for r in rows:
        files = candidates(wav_dir, r["pack"], r["group"])
        if not files:
            print("no files for", r["id"], r["pack"], r["group"])
            continue
        mode = r["mode"]
        if mode == "single":
            chosen = [pick_single(files)]
            x = read(chosen[0])
        elif mode == "seq":
            chosen = files[:5]
            x = build_seq(chosen, 0.5 if "snow" in r["group"] else 0.42)
        else:
            used = used_by_group.setdefault(r["group"], set())
            chosen = [pick_jingle(files, mode, used)]
            used.add(chosen[0])
            x = read(chosen[0])
        write(os.path.join(raw_dir, f"{r['id']}_100.wav"), x)
        names = [os.path.basename(f)[:-4] + ".ogg" for f in chosen]
        sources[r["id"]] = {"pack": r["pack"], "title": f"Kenney {PACK_TITLES[r['pack']]}", "files": names,
                            "license": "CC0 1.0", "url": f"https://kenney.nl/assets/{r['pack']}"}
        print(f"{r['id']:16s} <- {', '.join(names)}  ({x.shape[1] / SR:.2f}s)")
    json.dump(sources, open(os.path.join(HERE, "free_sources.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)

    # 一覧を書き換える(AI の行は出どころを書き換え、ない id は足す)
    lines = open(list_path, encoding="utf-8").read().splitlines()
    header = lines[0].split("\t")
    body = [l.split("\t") for l in lines[1:]]
    index = {c[0]: c for c in body}
    added = 0
    for r in rows:
        if r["id"] not in sources:
            continue
        src = sources[r["id"]]
        prompt = f"{src['title']} ({', '.join(src['files'])}) {src['license']}"
        if r["id"] in index:
            c = index[r["id"]]
            c[1], c[2], c[4], c[5], c[6] = r["category"], r["name_ja"], "free", r["style"], prompt
        else:
            body.append([r["id"], r["category"], r["name_ja"], "3.0", "free", r["style"], prompt])
            added += 1
    open(list_path, "w", encoding="utf-8", newline="\n").write(
        "\n".join(["\t".join(header)] + ["\t".join(c) for c in body]) + "\n")

    # ライセンスの記録
    packs = sorted({s["pack"] for s in sources.values()})
    md = ["# 効果音の出どころとライセンス", "",
          "アプリに入れている効果音(Sources/Resources/SFX/se_<id>.m4a)の出どころ。",
          "", "## フリー素材(CC0 1.0 / パブリックドメイン)", "",
          "Kenney (https://kenney.nl) の次のパック。CC0 なので、アプリに入れて配ることも、表示なしで使うこともできる。", ""]
    for p in packs:
        md.append(f"- Kenney {PACK_TITLES[p]}: https://kenney.nl/assets/{p}")
    md += ["", "| id | 名前 | 元のファイル |", "|---|---|---|"]
    names = {r["id"]: r["name_ja"] for r in rows}
    for sid, s in sources.items():
        md.append(f"| {sid} | {names[sid]} | {s['title']} / {', '.join(s['files'])} |")
    md += ["", "## AI で作った音", "",
           "上の表にない id は Stability AI の Stable Audio 2.5 で作った音(2026-11-10。Stability AI の利用規約 §4(a) で、",
           "作った音の権利は利用者のもの)。指示文と日時は Temp\\vmd\\sfx_out\\raw\\log.jsonl に残している。", ""]
    open(os.path.join(HERE, "LICENSES.md"), "w", encoding="utf-8", newline="\n").write("\n".join(md))
    print(f"free {len(sources)}, added {added}")


if __name__ == "__main__":
    main()
