# フリー素材の .ogg を、PC に入っている VLC で WAV(44.1kHz ステレオ 16bit)に変える(Windows の変換機能は ogg を読めないため)。
# 使い方: python ogg_to_wav.py 入力フォルダ 出力フォルダ
#   入力フォルダの下の .ogg をすべて探し、出力フォルダ/<最初のフォルダ名>/<ファイル名>.wav に書く。あるものは作らない。
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

VLC = r"C:\Program Files\VideoLAN\VLC\vlc.exe"


def convert(src, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 44:
        return "skip"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    sout = '#transcode{acodec=s16l,channels=2,samplerate=44100}:std{access=file,mux=wav,dst="%s"}' % dst
    try:
        subprocess.run([VLC, "-I", "dummy", "--no-repeat", "--no-loop", src, "--sout", sout, "vlc://quit"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except subprocess.TimeoutExpired:
        return "timeout"
    return "ok" if os.path.exists(dst) and os.path.getsize(dst) > 44 else "fail"


def main():
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    jobs = []
    for root, _, files in os.walk(src_dir):
        for f in files:
            if f.lower().endswith(".ogg"):
                rel = os.path.relpath(root, src_dir).split(os.sep)[0]
                jobs.append((os.path.join(root, f), os.path.join(out_dir, rel, f[:-4] + ".wav")))
    counts = {}
    with ThreadPoolExecutor(3) as pool:
        for r in pool.map(lambda j: convert(*j), jobs):
            counts[r] = counts.get(r, 0) + 1
    print(len(jobs), counts)


if __name__ == "__main__":
    main()
