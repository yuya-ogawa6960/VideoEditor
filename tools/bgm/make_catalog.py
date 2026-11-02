# アプリが読む BGM の一覧(catalog.json)を作る。サーバーの R2 に catalog.json として置く(upload_bgm.py)。
# 曲の長さは MP3 のフレームを数えて出す(ffmpeg なしで正確に出せる)。
# 使い方: python make_catalog.py presets.json 曲のフォルダ catalog.json
import json, os, sys

BITRATES = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]  # MPEG-1 Layer III (kbps)
RATES = [44100, 48000, 32000]

def mp3_seconds(path):
    data = open(path, "rb").read()
    i = 0
    if data[:3] == b"ID3":  # ID3v2 タグを飛ばす
        i = 10 + ((data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 | (data[8] & 0x7F) << 7 | (data[9] & 0x7F))
    frames, rate = 0, 44100
    while i + 4 <= len(data):
        b1, b2 = data[i + 1], data[i + 2]
        if data[i] != 0xFF or (b1 & 0xFE) != 0xFA:  # MPEG-1 Layer III の同期でなければ 1 バイトずつ探す
            i += 1
            continue
        bi, ri, pad = b2 >> 4, (b2 >> 2) & 3, (b2 >> 1) & 1
        if bi in (0, 15) or ri == 3:
            i += 1
            continue
        rate = RATES[ri]
        frames += 1
        i += 144000 * BITRATES[bi] // rate + pad
    return frames * 1152 / rate

def main():
    presets = json.load(open(sys.argv[1], encoding="utf-8"))
    folder = sys.argv[2]
    tracks = []
    for p in presets:
        path = os.path.join(folder, p["id"] + "_1.mp3")
        if not os.path.exists(path):
            print("missing", p["id"])
            continue
        tracks.append({
            "id": p["id"], "name": p["name"], "mood": p["mood"], "bpm": p["bpm"],
            "duration": round(mp3_seconds(path), 2),
            "file": p["id"] + "_1.mp3", "bytes": os.path.getsize(path),
        })
    catalog = {"version": 1, "tracks": tracks}
    json.dump(catalog, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("tracks", len(tracks), "min", min(t["duration"] for t in tracks), "max", max(t["duration"] for t in tracks))

if __name__ == "__main__":
    main()
