# パブリックドメインのクラシック録音をウィキメディア・コモンズで探す(候補の一覧と権利表示を記録するだけで、ダウンロードはしない)。
# 曲(作曲)は作曲者の没後に著作権が切れているが、録音には演奏者・レーベルの権利が別にあるので、
# 録音そのものが Public domain / CC0 と表示されているファイルだけを候補にする。
# 使い方: python find_classical.py 出力.json
import json, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://commons.wikimedia.org/w/api.php"
UA = "VideoManiaBGMResearch/1.0 (contact: app developer; classical public-domain recordings)"

PIECES = [
    ("canon", "カノン(パッヘルベル)", "Pachelbel Canon in D"),
    ("wedding_march", "結婚行進曲(メンデルスゾーン)", "Mendelssohn Wedding March Midsummer Night's Dream"),
    ("pomp", "威風堂々 第1番(エルガー)", "Elgar Pomp and Circumstance March No. 1"),
    ("cancan", "天国と地獄(オッフェンバック)", "Offenbach Orpheus in the Underworld overture can-can"),
    ("william_tell", "ウィリアム・テル序曲(ロッシーニ)", "Rossini William Tell Overture"),
    ("clair_de_lune", "月の光(ドビュッシー)", "Debussy Clair de lune"),
    ("gymnopedie", "ジムノペディ第1番(サティ)", "Satie Gymnopedie No. 1"),
    ("nocturne", "ノクターン 作品9-2(ショパン)", "Chopin Nocturne op. 9 no. 2"),
    ("morning", "朝(ペール・ギュント)(グリーグ)", "Grieg Peer Gynt Morning Mood"),
    ("spring", "四季「春」(ヴィヴァルディ)", "Vivaldi Four Seasons Spring allegro"),
    ("air", "G線上のアリア(バッハ)", "Bach Air orchestral suite no. 3"),
    ("eine_kleine", "アイネ・クライネ・ナハトムジーク(モーツァルト)", "Mozart Eine kleine Nachtmusik"),
    ("fur_elise", "エリーゼのために(ベートーヴェン)", "Beethoven Für Elise"),
    ("new_world", "新世界より(ドヴォルザーク)", "Dvorak symphony no. 9 New World"),
    ("blue_danube", "美しく青きドナウ(J.シュトラウス2世)", "Strauss Blue Danube"),
    ("hungarian5", "ハンガリー舞曲第5番(ブラームス)", "Brahms Hungarian Dance No. 5"),
    ("lullaby", "子守唄(ブラームス)", "Brahms Wiegenlied lullaby op. 49"),
    ("toccata", "トッカータとフーガ ニ短調(バッハ)", "Bach Toccata and Fugue in D minor BWV 565"),
    ("danse_macabre", "死の舞踏(サン=サーンス)", "Saint-Saens Danse macabre"),
    ("bald_mountain", "はげ山の一夜(ムソルグスキー)", "Mussorgsky Night on Bald Mountain"),
    ("bumblebee", "熊蜂の飛行(リムスキー=コルサコフ)", "Rimsky-Korsakov Flight of the Bumblebee"),
    ("moonlight", "月光 第1楽章(ベートーヴェン)", "Beethoven Moonlight sonata adagio sostenuto"),
    ("mountain_king", "山の魔王の宮殿にて(グリーグ)", "Grieg In the Hall of the Mountain King"),
    ("flowers_waltz", "花のワルツ(チャイコフスキー)", "Tchaikovsky Nutcracker Waltz of the Flowers"),
]

OK_LICENSES = ("public domain", "pd", "cc0", "pdm")

def api(params):
    params = dict(params, format="json", maxlag=5)
    req = urllib.request.Request(API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": UA})
    # 429(問い合わせが多すぎる)のときは待ってからやり直す
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                return json.loads(res.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5:
                raise
            time.sleep(30 * (attempt + 1))

def candidates(query):
    res = api({"action": "query", "list": "search", "srsearch": query + " filetype:audio", "srnamespace": 6, "srlimit": 15})
    titles = [r["title"] for r in res.get("query", {}).get("search", [])]
    if not titles:
        return []
    info = api({"action": "query", "titles": "|".join(titles), "prop": "imageinfo",
                "iiprop": "url|size|mime|extmetadata", "iiextmetadatafilter": "LicenseShortName|Artist|Credit|UsageTerms|ImageDescription"})
    out = []
    for page in info.get("query", {}).get("pages", {}).values():
        ii = (page.get("imageinfo") or [{}])[0]
        meta = ii.get("extmetadata", {})
        lic = meta.get("LicenseShortName", {}).get("value", "")
        out.append({
            "title": page.get("title"),
            "url": ii.get("url"), "descriptionUrl": ii.get("descriptionurl"),
            "size": ii.get("size"), "mime": ii.get("mime"),
            "license": lic,
            "artist": meta.get("Artist", {}).get("value", "")[:200],
            "credit": meta.get("Credit", {}).get("value", "")[:200],
            "licenseOK": any(k in lic.lower() for k in OK_LICENSES),
        })
    return out

def main():
    import os
    done = {}
    if os.path.exists(sys.argv[1]):
        for r in json.load(open(sys.argv[1], encoding="utf-8")):
            if r["candidates"]:
                done[r["key"]] = r
    result = []
    for key, ja, query in PIECES:
        if key in done:
            result.append(done[key])
            continue
        try:
            c = candidates(query)
        except Exception as e:
            c = []
            print("error", key, e, flush=True)
        result.append({"key": key, "name": ja, "query": query, "candidates": c})
        print(key, len(c), sum(1 for x in c if x["licenseOK"]), flush=True)
        time.sleep(8)
    json.dump(result, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=1)

if __name__ == "__main__":
    main()
