# BGM 150 曲の指示文を作る(Google Lyria 3 Pro 用)。
# オーナーが良いと判断した型(2026-11-02):プロのプロデューサーの仕上がり・立体的なミックス・強い低音・
# 複数の生楽器・ありきたりでない和音・途中でビートが変わる展開・主旋律は控えめ・グロッケン/ベル類は使わない・C メジャーは避ける。
# 使い方: python make_prompts.py presets.json prompts.json
import json, sys

# 雰囲気ごとのジャンル候補(同じ雰囲気の中でも曲ごとに順に回して、似た曲が続かないようにする)
GENRES = {
    "dance": [
        ("late-70s / early-80s synth disco with a pulsing arpeggiated sequencer bass line, four-on-the-floor kick, analog synth layers and disco strings", "hypnotic and euphoric"),
        ("Italo-disco and eurobeat lineage Japanese dance-pop: a pulsing sequencer-style synth bass line in the classic late-70s synth-disco manner, fast four-on-the-floor drums, bright synth stabs, disco strings and big hand-raising choreography energy", "catchy and high energy"),
        ("Italo disco with sequenced octave bass, gated drums, analog brass synths and retro arpeggios", "retro and glamorous"),
        ("modern nu-disco / French-touch house with filtered disco loops, funky bass and sidechained synths", "groovy and shiny"),
        ("80s-inspired synthwave dance with driving arpeggiated bass, big snares and shimmering pads (no bells)", "neon and nostalgic"),
    ],
    "bright": [
        ("modern funk-pop with slap bass and clean electric guitar chops", "groovy and sunny"),
        ("future-garage pop with chopped guitar and warm sub bass", "light and fresh"),
        ("indie-soul pop with live drums, Rhodes and nylon guitar", "warm and cheerful"),
        ("UK-garage tinged pop with shuffled drums and plucky synth bass", "bouncy and upbeat"),
    ],
    "calm": [
        ("late-night lo-fi neo-soul with dusty drums and Rhodes", "relaxed and intimate"),
        ("ambient R&B with deep 808 sub, airy pads and muted guitar", "calm and nocturnal"),
        ("downtempo trip-hop with brushed drums, upright bass and dark piano", "moody and smooth"),
    ],
    "stylish": [
        ("chill R&B / neo-soul with minor 9th chords, Rhodes and muted guitar", "stylish and urban"),
        ("nu-jazz with live drums, upright bass, electric piano and muted trumpet pads", "sophisticated"),
        ("deep-house groove with warm bass, chord stabs and organic percussion", "classy and smooth"),
    ],
    "emotional": [
        ("cinematic ambient with felt piano chords, cello and deep sub swells", "moving and heartfelt"),
        ("emotional post-rock with ambient guitars, live drums building slowly", "hopeful and moving"),
        ("modern cinematic piano and strings with a deep low end", "tender and cinematic"),
    ],
    "energetic": [
        ("hard-hitting trap / hip-hop beat with heavy 808 bass and dark synths", "powerful and driving"),
        ("electro-rock with distorted bass, big drums and gritty guitars", "high energy"),
        ("drum and bass with rolling breakbeats and deep reese bass", "fast and intense"),
        ("modern EDM / future bass with heavy drops and wide supersaws", "explosive and bright"),
    ],
    "cute": [
        ("playful bossa-pop with nylon guitar, light live drums and round bass", "cute and light"),
        ("kawaii future-funk with groovy bass and bright electric piano (no bells)", "sweet and bouncy"),
    ],
    "tense": [
        ("dark cinematic hybrid trailer music with pulsing synth bass and taiko-like drums", "tense and urgent"),
        ("thriller underscore with ticking percussion, low strings and deep drones", "suspenseful"),
    ],
    "natural": [
        ("organic folk-electronica with acoustic guitar, warm bass and soft live drums", "open and natural"),
        ("cinematic acoustic travel music with guitars, strings and deep low end", "wide and scenic"),
        ("chill tropical house with marimba-free organic percussion and warm bass", "breezy and relaxed"),
    ],
    "meal": [
        ("cozy jazz-hop with upright bass, Rhodes and brushed drums", "cozy and tasty"),
        ("latin jazz groove with nylon guitar, congas and walking bass", "warm and lively"),
    ],
    "party": [
        ("modern dance-pop / house with punchy four-on-the-floor kick and big bass", "festive and energetic"),
        ("disco-funk with live bass, horns section and tight drums", "fun and groovy"),
        ("afro-house with layered percussion and deep rolling bass", "celebratory"),
    ],
    "variety": [
        ("quirky funk with slap bass, clavinet and stop-and-go drums", "comedic and lively"),
        ("swing-hop with upright bass, brass stabs and boom-bap drums", "playful and punchy"),
    ],
    "slowLiving": [
        ("soft acoustic neo-soul with nylon guitar, Rhodes and gentle live drums", "calm and refined"),
        ("minimal chillhop with warm bass, felt piano and soft room drums", "quiet and tasteful"),
    ],
    "horror": [
        ("dark horror ambient with deep sub rumbles, dissonant strings and metallic hits (no bells)", "creepy and dark"),
        ("slow industrial horror with distorted low drones and heavy reverbed drums", "ominous"),
    ],
    "mysterious": [
        ("dark minimal electronica with deep sub, plucked synths and evolving textures", "mysterious"),
        ("noir detective jazz with upright bass, brushed drums and dark piano", "mysterious and stylish"),
    ],
    "seasonal": [
        ("seasonal cinematic pop with warm strings, piano chords and deep bass", "seasonal and warm"),
        ("cozy acoustic soul with guitars, Rhodes and soft live drums", "seasonal and cozy"),
    ],
    "lifeEvent": [
        ("uplifting cinematic pop with live drums, strings and deep bass", "uplifting and grand"),
        ("gentle piano and strings with soft pulses and a warm low end", "tender and sincere"),
        ("modern gospel-tinged soul with organ, warm bass and live drums", "joyful and warm"),
    ],
}

# 曲名から特別に足す一言(和風・季節・行事など)
NAME_HINTS = [
    ("お正月", "with a modern Japanese New Year feel using koto and shamisen phrases over the groove"),
    ("初詣", "with a modern Japanese shrine-visit feel using koto and shakuhachi-like flute textures"),
    ("桜", "with a spring cherry-blossom feel"),
    ("春", "with a fresh spring feel"),
    ("夏", "with a bright summer feel"),
    ("秋", "with a warm autumn feel"),
    ("紅葉", "with a warm autumn feel"),
    ("冬", "with a crisp winter feel"),
    ("雪", "with a crisp, snowy winter feel"),
    ("クリスマス", "with a modern Christmas feel (warm, no sleigh bells, no glockenspiel)"),
    ("聖夜", "with a quiet Christmas night feel (no bells)"),
    ("誕生日", "for a birthday celebration"),
    ("卒業", "for a graduation"),
    ("入学", "for a school entrance ceremony"),
    ("運動会", "for a school sports day"),
    ("リレー", "for a relay race"),
    ("子守唄", "as a soft lullaby (very gentle drums)"),
    ("ゆりかご", "as a soft lullaby (very gentle drums)"),
    ("祈り", "as a quiet prayer (no drums)"),
    ("偲ぶ", "for remembrance, respectful and quiet (no drums)"),
    ("永遠の愛", "for a wedding"),
    ("誓い", "for a wedding vow"),
    ("祝", "for a celebration"),
    ("雨", "with a rainy-day feel"),
    ("夜", "with a night-time feel"),
    ("朝", "with a morning feel"),
    ("カフェ", "with a cafe feel"),
    ("ドライブ", "for a night drive"),
    ("ゲーム", "for a game showdown"),
    ("クイズ", "for a quiz show"),
    ("ビーチ", "for a beach party"),
]

# キー(C メジャー・A マイナーは使わない)。雰囲気の明暗で長調・短調を分ける
MINOR_KEYS = ["E minor", "F# minor", "G minor", "B minor", "D minor", "C# minor", "F minor", "G# minor", "Bb minor"]
MAJOR_KEYS = ["D major", "E major", "F major", "G major", "Bb major", "Eb major", "A major", "Ab major", "B major"]
MINOR_MOODS = {"calm", "stylish", "tense", "horror", "mysterious", "energetic"}

def build(preset, index_in_mood):
    mood = preset["mood"]
    # genreIndex があれば、その曲はそのジャンルにする(ダンスの曲名とジャンルを合わせるため)
    genre, feel = GENRES[mood][preset.get("genreIndex", index_in_mood) % len(GENRES[mood])]
    keys = MINOR_KEYS if mood in MINOR_MOODS or index_in_mood % 3 == 2 else MAJOR_KEYS
    key = keys[(index_in_mood * 5 + len(preset["name"])) % len(keys)]
    bpm = int(round(preset["bpm"]))
    hints = [h for word, h in NAME_HINTS if word in preset["name"]]
    hint = (" " + hints[0]) if hints else ""
    quiet = any(w in preset["name"] for w in ("祈り", "偲ぶ", "子守唄", "ゆりかご"))
    drums = ("No drums or only very soft textures." if quiet else
             "Modern punchy drums that change through the song: a lighter groove in the intro, a fuller beat in the main section, "
             "a half-time or breakdown switch in the middle, then the beat returns stronger.")
    low = ("A warm, deep low end." if quiet else "Strong, heavy low end: deep sub bass plus a bass line that moves and grooves.")
    return (
        f"Instrumental background track, no vocals, in {key} (not C major, not A minor). "
        f"Style: {genre}, {feel}{hint}. Made by a top professional music producer, not karaoke or stock music. "
        f"{low} Several real instruments layered in a wide, three-dimensional stereo mix with depth, tasteful reverb and delay, "
        f"polished mixing and mastering. Absolutely no glockenspiel, no bells, no music box, no toy sounds. "
        f"Rich, natural harmony with tasteful voicings and passing chords, avoiding generic four-chord loops. "
        f"{drums} No prominent lead melody; it must sit under a voice. {bpm} BPM. "
        f"Steady tempo throughout, phrases in clear 8-bar sections (intro, main sections, breakdown, final section) so it can be edited on bar lines. "
        f"Ending on a clean final chord without fading out. About 3 minutes long."
    )

def main():
    presets = json.load(open(sys.argv[1], encoding="utf-8"))
    counters = {}
    out = []
    for p in presets:
        i = counters.get(p["mood"], 0)
        counters[p["mood"]] = i + 1
        out.append({"id": p["id"], "name": p["name"], "mood": p["mood"], "bpm": p["bpm"], "prompt": build(p, i)})
    json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(len(out), "prompts")

if __name__ == "__main__":
    main()
