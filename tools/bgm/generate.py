# Lyria 3 Pro(Google Cloud / Vertex AI)で BGM を作る。
# 使い方: python generate.py prompts.json 出力フォルダ [--ids a,b,c] [--takes 1]
# 認証は gcloud(gcloud auth print-access-token)を使う。鍵はファイルに書かない。
# 作った曲ごとに、指示文・日時・モデル・応答の ID を log.jsonl に残す(権利を聞かれたときの記録)。
import base64, datetime, json, os, subprocess, sys, time, urllib.request, urllib.error

GCLOUD = os.environ.get("GCLOUD", r"C:\Users\yogaw\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd")
MODEL = "lyria-3-pro-preview"

def gcloud(*args):
    return subprocess.run([GCLOUD, *args], capture_output=True, text=True, check=True).stdout.strip()

def generate(project, token, prompt):
    url = f"https://aiplatform.googleapis.com/v1beta1/projects/{project}/locations/global/interactions"
    body = json.dumps({"model": MODEL, "input": [{"type": "text", "text": prompt}]}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=600) as res:
        return json.loads(res.read().decode("utf-8"))

def main():
    prompts_path, out_dir = sys.argv[1], sys.argv[2]
    ids = None
    takes = 1
    log_name = "log.jsonl"  # 同時に何本か動かすときは別の名前にする(書き込みが混ざらないように)
    args = sys.argv[3:]
    for i, a in enumerate(args):
        if a == "--ids": ids = set(args[i + 1].split(","))
        if a == "--takes": takes = int(args[i + 1])
        if a == "--log": log_name = args[i + 1]
    os.makedirs(out_dir, exist_ok=True)
    prompts = json.load(open(prompts_path, encoding="utf-8"))
    if ids: prompts = [p for p in prompts if p["id"] in ids]
    project = gcloud("config", "get-value", "project")
    token = gcloud("auth", "print-access-token")
    log = open(os.path.join(out_dir, log_name), "a", encoding="utf-8")
    for p in prompts:
        for take in range(1, takes + 1):
            path = os.path.join(out_dir, f"{p['id']}_{take}.mp3")
            if os.path.exists(path):
                continue
            # まれに理由なく content_blocked で断られる(同じ指示で頼み直すと通る)ので、多めにやり直す
            res = None
            for attempt in range(6):
                try:
                    res = generate(project, token, p["prompt"])
                    break
                except urllib.error.HTTPError as e:
                    msg = e.read().decode("utf-8", "replace")[:500]
                    print("HTTP", e.code, p["id"], msg, flush=True)
                    # 利用ポリシー(禁止語など)で断られたものは、頼み直しても同じなので、そこでやめる
                    if "prohibited_content" in msg:
                        break
                    if e.code == 401: token = gcloud("auth", "print-access-token")
                    time.sleep(10 * (attempt + 1))
            if res is None:
                continue
            audio = next((o for o in res.get("outputs", []) if o.get("type") == "audio"), None)
            if not audio:
                print("no audio", p["id"], json.dumps(res)[:300], flush=True)
                continue
            with open(path, "wb") as f:
                f.write(base64.b64decode(audio["data"]))
            texts = [o.get("text", "") for o in res.get("outputs", []) if o.get("type") == "text"]
            log.write(json.dumps({"id": p["id"], "take": take, "file": os.path.basename(path), "model": MODEL,
                                  "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                  "response_id": res.get("id"), "prompt": p["prompt"], "notes": texts},
                                 ensure_ascii=False) + "\n")
            log.flush()
            print("ok", p["id"], take, flush=True)
            time.sleep(7)  # 1 分 10 回までの制限に合わせる

if __name__ == "__main__":
    main()
