# 聞き比べページ(オーナーが聴いて「作り直し」に印をつける)を作る。
# 使い方: python make_review.py sfx_list.tsv 仕上げフォルダ(proc) 出力フォルダ
#   出力フォルダに index.html と a/<id>_<take>.mp4 を置き、公開用のファイル一覧(files_1.json, files_2.json …)を書く。
#   ページ用の音は頭に 0.35 秒の無音を足して作り直す(iPhone のブラウザは再生の最初の一瞬を飛ばすことがあり、
#   短い音が丸ごと消えたり、頭が切れて聞こえたりしたため)。アプリに入れる音には足さない。
#   中身が変わったら ?v=<ハッシュ> で読み直させる(同じ名前のままキャッシュの古い音が鳴らないように)。
import csv, hashlib, json, os, shutil, subprocess, sys, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_catalog import CATEGORIES  # noqa: E402

CHUNK = 240   # 1 回の公開で送るファイル数(上限 255。ページの分を空けておく)
LEAD = 0.35   # ページ用の音の頭に足す無音(秒)


def pad_wav(src, dst):
    with wave.open(src, "rb") as w:
        params = w.getparams()
        frames = w.readframes(w.getnframes())
    silence = b"\x00" * (int(LEAD * params.framerate) * params.nchannels * params.sampwidth)
    with wave.open(dst, "wb") as w:
        w.setparams(params)
        w.writeframes(silence + frames)


def main():
    list_path, proc_dir, out_dir = sys.argv[1:4]
    rows = list(csv.DictReader(open(list_path, encoding="utf-8"), delimiter="\t"))
    pad_dir, enc_dir, a_dir = (os.path.join(out_dir, d) for d in ("pad", "enc", "a"))
    for d in (pad_dir, enc_dir, a_dir):
        os.makedirs(d, exist_ok=True)
    sounds, files, revs = [], {}, {}
    for r in rows:
        wav = os.path.join(proc_dir, f"{r['id']}.wav")
        if not os.path.exists(wav):
            continue
        stamp = wav + ".take"
        take = int(open(stamp).read()) if os.path.exists(stamp) else 1
        data = open(wav, "rb").read()
        rev = hashlib.md5(data).hexdigest()[:8]
        revs[r["id"]] = rev
        with wave.open(wav, "rb") as w:
            seconds = w.getnframes() / w.getframerate()
        padded = os.path.join(pad_dir, f"{r['id']}.wav")
        enc = os.path.join(enc_dir, f"{r['id']}.m4a")
        rev_file = enc + ".rev"
        # 中身が変わったものだけ作り直す
        if not (os.path.exists(enc) and os.path.exists(rev_file) and open(rev_file).read() == rev):
            pad_wav(wav, padded)
            if os.path.exists(enc):
                os.remove(enc)
        name = f"a/{r['id']}_{take}.mp4"  # 公開先は .m4a を配れないので .mp4(中身は同じ AAC)
        files[name] = os.path.join(out_dir, name)
        sounds.append({"id": r["id"], "cat": r["category"], "name": r["name_ja"], "take": take,
                       "seconds": round(seconds, 2), "file": name, "rev": rev,
                       "free": r.get("engine") == "free"})
    # 足りない m4a をまとめて作る(Windows の変換機能。-MTA がないと終わっても戻らない)
    subprocess.run(["powershell.exe", "-MTA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                    os.path.join(HERE, "to_m4a.ps1"), pad_dir, enc_dir, "128"], check=True, stdout=subprocess.DEVNULL)
    for s in sounds:
        enc = os.path.join(enc_dir, f"{s['id']}.m4a")
        shutil.copyfile(enc, os.path.join(out_dir, s["file"]))
        open(enc + ".rev", "w").write(revs[s["id"]])
        padded = os.path.join(pad_dir, f"{s['id']}.wav")
        if os.path.exists(padded):
            os.remove(padded)
    template = open(os.path.join(HERE, "review_template.html"), encoding="utf-8").read()
    cats = [{"key": k, "title": t} for k, t in CATEGORIES if any(s["cat"] == k for s in sounds)]
    html = template.replace("/*DATA*/[]", json.dumps(sounds, ensure_ascii=False)) \
                   .replace("/*CATS*/[]", json.dumps(cats, ensure_ascii=False))
    with open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(html)
    names = sorted(files)
    chunks = [names[i:i + CHUNK] for i in range(0, len(names), CHUNK)]
    for i, chunk in enumerate(chunks, 1):
        with open(os.path.join(out_dir, f"files_{i}.json"), "w", encoding="utf-8") as f:
            json.dump([{"path": n} for n in chunk], f)
    print(f"{len(sounds)} sounds, {len(chunks)} file chunks -> {out_dir}")


if __name__ == "__main__":
    main()
