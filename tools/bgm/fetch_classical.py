# 選んだパブリックドメインのクラシック録音を Wikimedia Commons から取ってきて、権利の記録(manifest)を残す。
# 曲(作曲)の権利は切れているが、録音には別に権利があるので、録音ごとに Commons の権利表示とファイルページの
# 権利の欄をそのまま記録しておく(あとで「どこから持ってきたか」を聞かれたときに見せられるように)。
# 使い方: python fetch_classical.py classical_selection.json 出力フォルダ manifest.json [--pause 秒]
# Wikimedia は短時間にたくさん取ると 429(混雑)で断るので、1ファイルごとに間をあける(既定 20 秒)。
import datetime, hashlib, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://commons.wikimedia.org/w/api.php"
UA = "VideoManiaBGMResearch/1.0 (public-domain classical recordings for an app's music library; low volume)"

def get(url, params=None):
    if params:
        url += "?" + urllib.parse.urlencode(dict(params, format="json", maxlag=5))
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(6):
        try:
            return urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 503) or attempt == 5:
                raise
            # 混んでいるときは、言われた時間(言われなければ長め)待ってからやり直す
            wait = e.headers.get("Retry-After")
            time.sleep(int(wait) if wait and wait.isdigit() else 60 * (attempt + 1))

def file_info(title):
    with get(API, {"action": "query", "titles": title, "prop": "imageinfo|videoinfo|revisions",
                   "iiprop": "url|size|sha1|mime|extmetadata|metadata", "viprop": "derivatives",
                   "rvprop": "content", "rvslots": "main"}) as res:
        page = next(iter(json.loads(res.read().decode("utf-8"))["query"]["pages"].values()))
    if "missing" in page:
        raise RuntimeError("missing on Commons: " + title)
    ii = page["imageinfo"][0]
    meta = ii.get("extmetadata", {})
    md = {m.get("name"): m.get("value") for m in (ii.get("metadata") or []) if isinstance(m, dict)}
    rev = page["revisions"][0]
    text = rev.get("slots", {}).get("main", {}).get("*", "")
    # ファイルページの「ライセンス」見出しから下(権利表示のテンプレートと注記)をそのまま残す
    lic = text[text.find("{{int:license-header}}"):] if "{{int:license-header}}" in text else text[-1500:]
    derivs = (page.get("videoinfo") or [{}])[0].get("derivatives", [])
    mp3 = next((d["src"] for d in derivs if d.get("type", "").startswith("audio/mpeg")), None)
    def plain(key):
        return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", meta.get(key, {}).get("value", ""))).strip()
    return {
        "page": ii.get("descriptionurl"), "url": ii.get("url"), "mime": ii.get("mime"),
        "size": ii.get("size"), "sha1": ii.get("sha1"), "length": md.get("length") or md.get("playtime_seconds"),
        "license": plain("LicenseShortName"), "usageTerms": plain("UsageTerms"),
        "artist": plain("Artist")[:500], "credit": plain("Credit")[:500],
        "licenseSection": lic[:3000], "listenMp3": mp3,
    }

def download(url, path):
    tmp = path + ".part"
    with get(url) as res, open(tmp, "wb") as f:
        while True:
            chunk = res.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, path)

def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def safe_name(title):
    return re.sub(r'[<>:"/\|?*]', "_", title.split(":", 1)[1]).strip()

def main():
    selection = json.load(open(sys.argv[1], encoding="utf-8"))
    out_dir, manifest_path = sys.argv[2], sys.argv[3]
    pause = int(sys.argv[sys.argv.index("--pause") + 1]) if "--pause" in sys.argv else 20
    manifest = []
    for item in selection:
        entry = dict(item)
        try:
            info = file_info(item["title"])
            entry.update(info)
            folder = os.path.join(out_dir, item["key"])
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, safe_name(item["title"]))
            if not (os.path.exists(path) and sha1(path) == info["sha1"]):
                download(info["url"], path)
                time.sleep(pause)
            entry["sha1OK"] = sha1(path) == info["sha1"]
            entry["localFile"] = os.path.relpath(path, out_dir)
            # スマホで聴いて確かめる用(Commons が元のファイルから作った MP3)
            if info["mime"] != "audio/mpeg" and info["listenMp3"]:
                listen = os.path.join(folder, "listen.mp3")
                if not os.path.exists(listen):
                    download(info["listenMp3"], listen)
                    time.sleep(pause)
                entry["listenFile"] = os.path.relpath(listen, out_dir)
            entry["retrievedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            print("ok", item["key"], entry["license"], entry["sha1OK"], flush=True)
        except Exception as e:
            entry["error"] = str(e)
            print("error", item["key"], e, flush=True)
        manifest.append(entry)
        json.dump(manifest, open(manifest_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        time.sleep(2)

if __name__ == "__main__":
    main()
