# 曲と一覧をサーバーの R2(バケット videomania-bgm)に上げる。アプリはサーバーの /v1/bgm/... から読む。
# 先に一度だけ: npx wrangler login(Cloudflare にログイン)。バケットはサーバーのデプロイで作られる。
# 使い方: python upload_bgm.py catalog.json 曲のフォルダ
# 曲のファイルは中身を変えない約束(サーバーが 1 年キャッシュさせる)なので、作り直した曲は別の名前(_2.mp3 など)にする。
import json, os, subprocess, sys

BUCKET = "videomania-bgm"

def put(key, path, content_type):
    subprocess.run(["npx", "--yes", "wrangler@4", "r2", "object", "put", f"{BUCKET}/{key}", "--file", path,
                    "--content-type", content_type, "--remote"], check=True, shell=(os.name == "nt"))

def main():
    catalog_path, folder = sys.argv[1], sys.argv[2]
    catalog = json.load(open(catalog_path, encoding="utf-8"))
    for i, t in enumerate(catalog["tracks"], 1):
        put("files/" + t["file"], os.path.join(folder, t["file"]), "audio/mpeg")
        print(f"{i}/{len(catalog['tracks'])} {t['file']}", flush=True)
    # 一覧は最後に上げる(曲がそろってから一覧に出す)
    put("catalog.json", catalog_path, "application/json; charset=utf-8")
    print("catalog uploaded")

if __name__ == "__main__":
    main()
