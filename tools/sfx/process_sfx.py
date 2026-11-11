# 作った効果音(WAV)を仕上げる: 頭の無音を切る → 終わりの無音を切ってフェード → 聞こえる大きさをそろえる → -1dBFS に収める。
# 使い方: python process_sfx.py sfx_list.tsv 生成フォルダ 仕上げフォルダ [--take-map takes.json] [--m4a-dir m4aフォルダ] [--force]
#   生成フォルダの <id>_<take>.wav のうち、使う take(既定はいちばん新しい番号、takes.json で指定も可)を仕上げて <id>.wav にする。
#   そのあと to_m4a.ps1 で <id>.m4a にする。
# 大きさのそろえ方はアプリの SoundLoudness.swift と同じ(単発 -16、環境音 -20、LUFS 相当)。
import csv, glob, json, os, re, sys, wave
import numpy as np

SR_OUT = 44100


def read_wav(path):
    with wave.open(path, "rb") as w:
        ch, width, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width == 2:
        x = np.frombuffer(raw, "<i2").astype(np.float64) / 32768
    elif width == 3:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3)
        v = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16))
        v = np.where(v >= 1 << 23, v - (1 << 24), v)
        x = v.astype(np.float64) / (1 << 23)
    elif width == 4:
        x = np.frombuffer(raw, "<i4").astype(np.float64) / 2147483648
    else:
        raise ValueError(f"unsupported width {width}")
    x = x.reshape(-1, ch).T
    if ch == 1:
        x = np.vstack([x, x])
    return x[:2], sr


def write_wav(path, x, sr):
    pcm = (np.clip(x.T, -1, 1) * 32767).round().astype("<i2")
    tmp = path + ".part"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes())
    os.replace(tmp, path)


def resample(x, sr, target):
    if sr == target:
        return x
    n = int(round(x.shape[1] * target / sr))
    t_old = np.arange(x.shape[1]) / sr
    t_new = np.arange(n) / target
    return np.vstack([np.interp(t_new, t_old, c) for c in x])


def biquad(x, b, a):
    # 2 次の IIR(1 チャンネル)。numpy だけで書く
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    b0, b1, b2 = b; a1, a2 = a
    for i, v in enumerate(x):
        out = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, out
        y[i] = out
    return y


def k_weight(c, sr):
    # BS.1770 の K 特性(高域シェルフ +4dB と 38Hz 付近のハイパス)を任意のサンプルレートで作る
    f0, g, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = np.tan(np.pi * f0 / sr); vh = 10 ** (g / 20); vb = vh ** 0.4996667741545416
    a0 = 1 + k / q + k * k
    b = ((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0)
    a = (2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    c = biquad(c, b, a)
    f0, q = 38.13547087602444, 0.5003270373238773
    k = np.tan(np.pi * f0 / sr)
    a0 = 1 + k / q + k * k
    b = (1.0, -2.0, 1.0)
    a = (2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    return biquad(c, b, a)


def loudness(x, sr, ambience):
    win, hop = int(0.4 * sr), int(0.1 * sr)
    power = sum(k_weight(c, sr) ** 2 for c in x)
    if len(power) < win:
        # 400ms に満たない音は、足りない分を無音として数える(アプリと同じ)
        power = np.concatenate([power, np.zeros(win - len(power))])
    cum = np.concatenate([[0], np.cumsum(power)])
    starts = np.arange(0, len(power) - win + 1, hop)
    means = (cum[starts + win] - cum[starts]) / win
    lufs = -0.691 + 10 * np.log10(np.maximum(means, 1e-12))
    if not ambience:
        return float(lufs.max()) if lufs.max() > -70 else None
    gated = means[lufs > -70]
    if len(gated) == 0:
        return None
    rel = -0.691 + 10 * np.log10(gated.mean()) - 10
    gated2 = gated[(-0.691 + 10 * np.log10(gated)) > rel]
    return float(-0.691 + 10 * np.log10(gated2.mean())) if len(gated2) else None


def limit(x, sr, ceiling=0.841):
    # 先読みリミッター: 超える所の手前 3ms から下げ始め、80ms かけて戻す
    peak = np.abs(x).max(axis=0)
    need = np.minimum(1.0, ceiling / np.maximum(peak, 1e-9))
    if need.min() >= 1.0:
        return x
    look = int(0.003 * sr)
    # 先読み: 先の 3ms のうち一番小さい値
    padded = np.concatenate([need, np.ones(look)])
    g = need.copy()
    for s in range(1, look + 1):
        g = np.minimum(g, padded[s:s + len(need)])
    # 戻り(リリース)は滑らかに
    rel = np.exp(-1.0 / (0.08 * sr))
    out = np.empty_like(g)
    cur = 1.0
    for i, v in enumerate(g):
        cur = v if v < cur else v + (cur - v) * rel
        out[i] = cur
    return x * out


def rbj(kind, f0, sr, q=0.7071):
    # RBJ の 2 次フィルター(lowpass / highpass)の係数
    w = 2 * np.pi * f0 / sr
    alpha = np.sin(w) / (2 * q)
    cw = np.cos(w)
    if kind == "lowpass":
        b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
    else:
        b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
    a0 = 1 + alpha
    return tuple(v / a0 for v in b), (-2 * cw / a0, (1 - alpha) / a0)


def low_share(x, sr, cutoff=150.0):
    # 150Hz より下の音が全体の何割か
    m = x.mean(axis=0)
    spec = np.abs(np.fft.rfft(m * np.hanning(len(m)))) ** 2
    f = np.fft.rfftfreq(len(m), 1 / sr)
    return float(spec[f < cutoff].sum() / (spec.sum() + 1e-12))


def phone_bass(x, sr):
    # スマホのスピーカーは 150Hz より下がほとんど鳴らない。低音が主の音(ドゥーン・ブォンなど)は、
    # 低音をひずませて作った倍音(200〜1500Hz)を足し、スマホでも「ドン」と聞こえるようにする(低音そのものは残す)
    share = low_share(x, sr)
    if share < 0.4:
        return x
    b, a = rbj("lowpass", 160, sr)
    out = x.copy()
    for c in range(x.shape[0]):
        low = biquad(biquad(x[c], b, a), b, a)
        pk = np.abs(low).max()
        if pk < 1e-6:
            continue
        harm = np.tanh(4 * low / pk) * pk
        hb, ha = rbj("highpass", 200, sr)
        lb, la = rbj("lowpass", 1500, sr)
        harm = biquad(biquad(biquad(harm, hb, ha), hb, ha), lb, la)
        rl, rh = np.sqrt((low ** 2).mean()), np.sqrt((harm ** 2).mean())
        if rh < 1e-9:
            continue
        # 低音が多いほど倍音を多めに(低音の 60〜100% の大きさ)
        out[c] = x[c] + harm * (rl / rh) * (0.6 + 0.4 * min(1.0, (share - 0.4) / 0.5))
    return out


def trim(x, sr, style, seconds):
    mono = np.abs(x).max(axis=0)
    peak = mono.max()
    if peak <= 1e-5:
        return None
    # 頭: ピークから -40dB を超えた所を見つけ、そこから -60dB を下回るまでさかのぼる
    # (ライザーのように小さく始まって大きくなる音の、立ち上がりを切らないように。さかのぼるのは 1.5 秒まで)
    win = int(0.02 * sr)
    env = np.convolve(mono, np.ones(win) / win, mode="same")
    above = np.nonzero(mono > peak * 0.01)[0]
    start = above[0]
    floor = peak * 0.001
    limit_back = max(0, start - int(1.5 * sr))
    quiet = np.nonzero(env[limit_back:start] <= floor)[0]
    start = limit_back + quiet[-1] if len(quiet) else limit_back
    start = max(0, start - int(0.005 * sr))
    # 終わり: 20ms 窓の大きさがピークから -55dB を下回った最後の所まで
    loud = np.nonzero(env > peak * 0.0018)[0]
    end = min(x.shape[1], loud[-1] + win)
    if style == "amb":
        start = 0  # 環境音は頭を切らない(フェードインする)
    # 長すぎるもの(指定の長さ + 1 秒)は切る
    end = min(end, start + int((seconds + 1.0) * sr))
    y = x[:, start:end].copy()
    n = y.shape[1]
    fade_out = int((0.4 if style == "amb" else 0.04) * sr)
    fade_out = min(fade_out, n // 3)
    if fade_out > 0:
        y[:, -fade_out:] *= np.linspace(1, 0, fade_out) ** 2
    fade_in = int((0.15 if style == "amb" else 0.002) * sr)
    fade_in = min(fade_in, n // 4)
    if fade_in > 0:
        y[:, :fade_in] *= np.linspace(0, 1, fade_in)
    return y


def process(src, dst, row):
    x, sr = read_wav(src)
    x = resample(x, sr, SR_OUT)
    # 直流を取る
    x = x - x.mean(axis=1, keepdims=True)
    y = trim(x, SR_OUT, row["style"], float(row["seconds"]))
    if y is None:
        return "silent"
    if row["style"] != "amb":
        y = phone_bass(y, SR_OUT)
    ambience = row["style"] == "amb" or y.shape[1] / SR_OUT >= 3
    measured = loudness(y, SR_OUT, ambience)
    if measured is not None:
        target = -20 if ambience else -16
        y = y * 10 ** (min(24, target - measured) / 20)
    y = limit(y, SR_OUT)
    write_wav(dst, y, SR_OUT)
    return f"{y.shape[1] / SR_OUT:.2f}s"


def main():
    list_path, raw_dir, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    takes = {}
    if "--take-map" in sys.argv:
        takes = json.load(open(sys.argv[sys.argv.index("--take-map") + 1], encoding="utf-8"))
    m4a_dir = sys.argv[sys.argv.index("--m4a-dir") + 1] if "--m4a-dir" in sys.argv else None
    force = "--force" in sys.argv  # 仕上げ方を変えたときに全部やり直す
    os.makedirs(out_dir, exist_ok=True)
    rows = list(csv.DictReader(open(list_path, encoding="utf-8"), delimiter="\t"))
    made = 0
    for row in rows:
        files = glob.glob(os.path.join(raw_dir, f"{row['id']}_*.wav"))
        found = {}
        for f in files:
            m = re.fullmatch(re.escape(row["id"]) + r"_(\d+)\.wav", os.path.basename(f))
            if m:
                found[int(m.group(1))] = f
        if not found:
            continue
        take = int(takes.get(row["id"], max(found)))
        if take not in found:
            print("missing take", row["id"], take)
            continue
        dst = os.path.join(out_dir, f"{row['id']}.wav")
        # 使う take が変わったときだけ作り直す
        stamp = dst + ".take"
        if not force and os.path.exists(dst) and os.path.exists(stamp) and open(stamp).read() == str(take):
            continue
        result = process(found[take], dst, row)
        # 仕上げ直したら古い m4a を消す(to_m4a.ps1 はあるファイルを作り直さないので)
        if m4a_dir and os.path.exists(os.path.join(m4a_dir, f"{row['id']}.m4a")):
            os.remove(os.path.join(m4a_dir, f"{row['id']}.m4a"))
        open(stamp, "w").write(str(take))
        made += 1
        print(row["id"], take, result, flush=True)
    print("processed", made)


if __name__ == "__main__":
    main()
