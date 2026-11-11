# 仕上げた効果音(m4a)をアプリに入れる: Sources/Resources/SFX/se_<id>.m4a にコピーし、一覧にない se_ ファイルは消す。
# 使い方: python install_sfx.py sfx_list.tsv m4aフォルダ ../../Sources/Resources/SFX
import csv, os, shutil, sys


def main():
    list_path, m4a_dir, dst_dir = sys.argv[1:4]
    rows = list(csv.DictReader(open(list_path, encoding="utf-8"), delimiter="\t"))
    ids = {r["id"] for r in rows}
    os.makedirs(dst_dir, exist_ok=True)
    copied, missing = 0, []
    for r in rows:
        src = os.path.join(m4a_dir, r["id"] + ".m4a")
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(dst_dir, "se_" + r["id"] + ".m4a"))
            copied += 1
        else:
            missing.append(r["id"])
    for f in os.listdir(dst_dir):
        if f.startswith("se_") and f.endswith(".m4a") and f[3:-4] not in ids:
            os.remove(os.path.join(dst_dir, f))
            print("removed", f)
    print(f"copied {copied}, missing {len(missing)}", missing[:10])


if __name__ == "__main__":
    main()
