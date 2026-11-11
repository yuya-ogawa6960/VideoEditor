# Stability AI の Stable Audio 2.5 で効果音を作る。
# 使い方: python generate_sfx.py sfx_list.tsv 出力フォルダ [--ids a,b] [--category telop] [--take 2] [--limit 5] [--dry]
#   --take 2 は作り直し(種を変える)。ファイル名は <id>_<take>.wav。すでにあるファイルは作らない(お金がかからない)。
#   --dry は送らずに、送る内容と件数・おおよその金額だけ表示する。
# 鍵は環境変数 STABILITY_API_KEY から読む。鍵はファイルにも画面にも出さない。
# 作った音ごとに、指示文・種・日時・モデルを log.jsonl に残す(権利を聞かれたときの記録。AI で作ったことの記録)。
import csv, datetime, hashlib, json, math, os, sys, threading, time
from concurrent.futures import ThreadPoolExecutor
import requests

URL = "https://api.stability.ai/v2beta/audio/stable-audio-2/text-to-audio"
MODEL = "stable-audio-2.5"
CREDITS_PER_SOUND = 8          # 1 回 8 クレジット(1 クレジット = 0.01 ドル)。失敗はかからない
WORKERS = 4                    # 同時に送る数(上限は 10 秒に 150 回)

# オーナーの好み(2026-11-10):「できるだけ効果音として癖がない感じ」。定番の、ふつうに使いやすい音に寄せる
STYLE_SUFFIX = {
    "sfx": ("Simple, standard, natural version of this sound, like a common stock sound effect library sound. "
            "Isolated, clean and close, no music, no background noise, no unusual or exaggerated character, "
            "high quality recording."),
    "amb": ("Ordinary, natural ambient field recording, continuous and even, no music, "
            "no unusual or distracting sounds, high quality."),
    "music": ("Short, simple and conventional musical sting, clean professional studio production, "
              "nothing experimental, ends cleanly."),
}

log_lock = threading.Lock()


def load(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def seed_for(sound_id, take):
    # 同じ id と take なら同じ種(作り直すと同じ音になる)。take を変えると別の音
    h = hashlib.sha256(f"{sound_id}:{take}".encode()).digest()
    return int.from_bytes(h[:4], "big") % 4294967294


def full_prompt(row):
    return f"{row['prompt'].strip()}. {STYLE_SUFFIX[row['style']]}"


def generate(key, row, take, out_dir, log):
    path = os.path.join(out_dir, f"{row['id']}_{take}.wav")
    if os.path.exists(path):
        return "skip"
    # 長さは整数の秒に切り捨てられる(2.5 → 2)ので、切り上げて頼む(余った無音は仕上げで切る)
    seconds = float(max(1, math.ceil(float(row["seconds"]))))
    data = {
        "prompt": full_prompt(row),
        "duration": f"{seconds:g}",
        "model": MODEL,
        "output_format": "wav",
        "seed": str(seed_for(row["id"], take)),
    }
    for attempt in range(6):
        try:
            res = requests.post(URL, headers={"authorization": f"Bearer {key}", "accept": "audio/*"},
                                files={"none": ""}, data=data, timeout=180)
        except requests.RequestException as e:
            print("network", row["id"], type(e).__name__, flush=True)
            time.sleep(5 * (attempt + 1))
            continue
        if res.status_code == 200:
            tmp = path + ".part"
            with open(tmp, "wb") as f:
                f.write(res.content)
            os.replace(tmp, path)
            with log_lock:
                log.write(json.dumps({
                    "id": row["id"], "take": take, "file": os.path.basename(path), "model": MODEL,
                    "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "seed": res.headers.get("seed", data["seed"]),
                    "finish_reason": res.headers.get("finish-reason"),
                    "duration": seconds, "prompt": data["prompt"]}, ensure_ascii=False) + "\n")
                log.flush()
            return "ok"
        body = res.text[:300]
        if res.status_code == 429:
            print("rate limited, waiting 60s", flush=True)
            time.sleep(61)
            continue
        if res.status_code in (401, 402, 403):
            # 鍵の間違い・クレジット切れ・内容の制限。続けても同じなので止める(内容の制限はその音だけ)
            print("HTTP", res.status_code, row["id"], body, flush=True)
            return "auth" if res.status_code in (401, 402) else "blocked"
        if res.status_code == 400:
            print("HTTP 400", row["id"], body, flush=True)
            return "bad"
        print("HTTP", res.status_code, row["id"], body, flush=True)
        time.sleep(10 * (attempt + 1))
    return "failed"


def main():
    list_path, out_dir = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    ids = category = None
    take, limit, dry = 1, None, False
    for i, a in enumerate(args):
        if a == "--ids": ids = set(args[i + 1].split(","))
        if a == "--category": category = args[i + 1]
        if a == "--take": take = int(args[i + 1])
        if a == "--limit": limit = int(args[i + 1])
        if a == "--dry": dry = True
    rows = [r for r in load(list_path) if r["engine"] == "stable"]
    if ids: rows = [r for r in rows if r["id"] in ids]
    if category: rows = [r for r in rows if r["category"] == category]
    os.makedirs(out_dir, exist_ok=True)
    todo = [r for r in rows if not os.path.exists(os.path.join(out_dir, f"{r['id']}_{take}.wav"))]
    if limit: todo = todo[:limit]
    print(f"{len(todo)} sounds to make (take {take}), about {len(todo) * CREDITS_PER_SOUND} credits "
          f"= ${len(todo) * CREDITS_PER_SOUND / 100:.2f}", flush=True)
    if dry:
        for r in todo[:10]:
            print(" ", r["id"], r["seconds"], "|", full_prompt(r))
        return
    key = os.environ.get("STABILITY_API_KEY", "").strip()
    if not key:
        # Windows で「ユーザー環境変数」に入れた直後は、開き直したウィンドウでないと読めないことがある
        print("STABILITY_API_KEY is not set", flush=True)
        sys.exit(2)
    # 残りのクレジットで作れる分だけにする(足りないまま送ると、同時に送った分がマイナスになることがある)
    try:
        bal = requests.get("https://api.stability.ai/v1/user/balance",
                           headers={"authorization": f"Bearer {key}"}, timeout=30).json().get("credits")
    except (requests.RequestException, ValueError):
        bal = None
    if bal is not None:
        can = max(0, int(float(bal) // CREDITS_PER_SOUND))
        print(f"balance {float(bal):.0f} credits -> up to {can} sounds", flush=True)
        if can < len(todo):
            todo = todo[:can]
        if not todo:
            print("not enough credits", flush=True)
            sys.exit(3)
    stop = threading.Event()
    counts = {}
    with open(os.path.join(out_dir, "log.jsonl"), "a", encoding="utf-8") as log:
        def work(r):
            if stop.is_set():
                return "stopped"
            result = generate(key, r, take, out_dir, log)
            if result == "auth":
                stop.set()
            counts[result] = counts.get(result, 0) + 1
            done = sum(counts.values())
            print(f"{done}/{len(todo)} {result} {r['id']}", flush=True)
            return result
        with ThreadPoolExecutor(WORKERS) as pool:
            list(pool.map(work, todo))
    print("done", json.dumps(counts), flush=True)
    if stop.is_set():
        print("stopped: the key was refused or credits ran out", flush=True)
        sys.exit(3)


if __name__ == "__main__":
    main()
