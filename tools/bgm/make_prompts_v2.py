# BGM の指示文 第2版(2026-11-03)。オーナー:「全体的に似たような曲が多い。バリエーションを多くして」。
# 第1版は全曲に同じ長い説明(重低音・立体的なミックス・ネオソウル寄りの和音・同じビートの展開)を付けていたため、
# 曲どうしが似た。第2版は曲ごとにジャンル・編成・時代感・テンポ・キー・構成を個別に決め、共通の文は最小限にする。
# オーナーの決まり: 歌なし / 目立つ主旋律なし / グロッケン・ベル・オルゴール・おもちゃの音なし / C メジャーを使わない /
# 打ち込みっぽい(カラオケっぽい)伴奏にしない / ビートのある曲は低音をしっかり。
# 使い方: python make_prompts_v2.py presets.json prompts.json
import json, sys

FORMS = {
    "build": "starts sparse, builds to a full groove, breaks down in the middle, then returns full",
    "drive": "full energy from the start, with a short breakdown and a big final section",
    "even": "gentle and even throughout, with slowly evolving textures",
    "halves": "two contrasting halves: a light first half and a richer, fuller second half",
    "song": "verse and chorus sections with an instrumental hook played by the rhythm section, a bridge, and a final chorus",
    "climb": "a slow build from almost nothing to a powerful climax, then a short calm ending",
}

# id: (style, bpm, key, form)
SPEC = {
    # ---- 明るい
    "daily_morning_walk": None,  # 第1版の曲をオーナーが「完璧」と判断したので作り直さない
    "daily_shopping": ("upbeat 1960s Motown-style soul-pop band: tambourine, upright piano, baritone sax riffs, bouncing electric bass, live drums", 124, "F major", "song"),
    "daily_park": ("sunny acoustic folk-pop: fingerpicked steel-string guitars, ukulele strums, cajon, upright bass", 98, "G major", "even"),
    "daily_school_road": ("energetic Japanese guitar band rock like an anime opening instrumental: driving 8-beat drums, crunchy guitars, melodic bass runs", 168, "E major", "drive"),
    "corp_howto": ("clean modern electro-pop for tutorials: soft plucked synth arpeggios, light four-on-the-floor kick, warm bass, airy pads, very unobtrusive", 110, "D major", "even"),
    "everyday.sunny-errand": ("breezy 1980s Japanese city pop: syncopated slap bass, bright electric piano, funky guitar cutting, short brass hits", 116, "Eb major", "song"),
    "everyday.weekend-vlog": ("chill tropical house: nylon guitar chops, plucky synths, soft claps, deep sub bass", 104, "Ab major", "build"),
    "everyday.bicycle": ("bright indie pop: jangly chorus guitars, driving floor-tom groove, handclaps, melodic bass", 132, "A major", "drive"),
    "everyday.my-routine": ("lo-fi bedroom pop: dusty drum machine, chorus-drenched guitar, mellow Rhodes, warm tape saturation", 90, "Bb major", "even"),
    "everyday.after-school": ("fast pop-punk instrumental: palm-muted power chords, energetic drums, melodic bass", 176, "D major", "drive"),
    "upbeat.kaisha": ("inspiring corporate orchestral pop: staccato strings, piano ostinato, light percussion, warm brass swells", 100, "F major", "climb"),
    "upbeat.kaisetsu": ("minimal, unobtrusive glitch-hop for explainer videos: soft clicks, warm sub bass, gentle keys, lots of space for a voice", 92, "B minor", "even"),
    "upbeat.service": ("polished modern tech pop: sidechained synth chords, crisp claps, punchy kick, bright guitar plucks, heavy sub bass", 120, "E major", "build"),
    # ---- 落ち着いた
    "night_view": ("slow chillwave: washed-out analog synths, gentle drum machine, deep warm bass, hazy reverb", 80, "F# minor", "even"),
    "night_drive": ("hypnotic motorik electronic night drive: Berlin-school sequencer arpeggios over a steady krautrock beat and a deep bass pulse", 100, "D minor", "build"),
    "night_moonlight": ("solo felt piano in a quiet room, sparse and intimate, no drums", 66, "Db major", "even"),
    "travel_sunset_hill": ("warm Americana: pedal steel and slide guitar over brushed drums and upright bass", 76, "E major", "even"),
    "mood.streetlight": ("late-night jazz ballad trio: brushed drums, walking upright bass, gentle piano voicings", 70, "Eb major", "even"),
    "mood.starfall": ("ambient post-rock: reverb-drenched clean guitars, swelling e-bow textures, soft mallet toms", 72, "B major", "climb"),
    "mood.sleepless": ("downtempo trip-hop: slow dusty breakbeat, vinyl crackle, deep dub bass, haunting Rhodes", 84, "C# minor", "even"),
    "mood.before-dawn": ("minimal ambient: slowly evolving string drones and distant piano, no drums", 60, "Ab major", "even"),
    # ---- おしゃれ
    "cafe_night": ("modern chill R&B / neo-soul: Rhodes, muted clean electric guitar, soft analog pads, deep 808 sub bass, laid-back swung drums", 88, "F# minor", "build"),
    "cafe_rain": ("bossa nova: nylon guitar, brushed drums, upright bass, soft flute pads, rain-day mood", 132, "D major", "even"),
    "cafe_window_seat": ("French cafe gypsy jazz: pompe rhythm guitars, upright bass, accordion textures", 160, "G minor", "song"),
    "corp_company": ("sleek minimal deep house: warm jazzy chords, rolling bassline, crisp hats, classy and modern", 120, "Bb minor", "build"),
    "corp_product": ("premium product-reveal electronica: precise percussion, sub bass hits, glassy synth textures, minimal and modern", 110, "E minor", "build"),
    "everyday.study-lofi": ("classic lo-fi hip hop study beat: swung boom-bap drums, jazzy sampled piano chords, tape hiss, warm bass", 78, "Eb major", "even"),
    "everyday.afternoon-tea": ("elegant chamber pop: string quartet with pizzicato and harpsichord, light and graceful", 100, "A major", "song"),
    "everyday.city-cafe": ("1990s acid jazz: funky clavinet, wah guitar, Hammond organ, live breakbeat, groovy bass", 108, "D minor", "song"),
    "everyday.rainy-desk": ("authentic 1990s R&B slow jam: swung boom-bap drums, round sub bass, Rhodes, chorus guitar licks, minor 9th chords", 86, "Bb minor", "build"),
    # ---- 感動
    "emotion_important_talk": ("cinematic duet of felt piano and cello, slow and intimate, no drums", 72, "D major", "climb"),
    "emotion_letter": ("acoustic singer-songwriter instrumental: fingerpicked steel guitar, soft piano, light shaker", 80, "G major", "even"),
    "emotion_family": ("warm folk: acoustic guitars, upright bass, soft brushed drums, harmonium", 92, "F major", "halves"),
    "emotion_thanks": ("uplifting gospel-soul instrumental: Hammond organ, piano, warm bass, claps, live drums", 76, "Ab major", "climb"),
    "mood.heartfelt": ("orchestral ballad: full string section, French horn, harp and timpani swells", 68, "Eb major", "climb"),
    "mood.quiet-resolve": ("post-rock build: clean delayed guitars and a growing snare roll that bursts into big drums", 120, "E minor", "climb"),
    "mood.distant-memory": ("nostalgic ambient: tape-warped piano, soft vinyl noise, distant strings", 64, "B minor", "even"),
    "mood.promise-day": ("emotional Japanese band ballad instrumental: piano, clean electric guitar, live drums building to a big chorus", 82, "Db major", "song"),
    "mood.monologue": ("minimal neo-classical: solo piano with subtle electronic pulses", 70, "F# minor", "even"),
    # ---- 元気
    "energy_run": ("hard-hitting trap: heavy sliding 808s, crisp hi-hat rolls, dark synth stabs", 140, "G minor", "drive"),
    "energy_jump": ("1990s big beat: chunky breakbeats, distorted bass riffs, turntable-style scratches and stabs", 130, "E minor", "drive"),
    "energy_dash": ("liquid drum and bass: rolling breakbeats, deep reese bass, atmospheric pads", 174, "F minor", "drive"),
    "energy_club": ("peak-time tech house: punchy kick, rolling bass, percussive grooves, filtered stabs", 126, "D minor", "build"),
    "upbeat.hashiridasu": ("stadium rock: power chords, pounding toms, anthemic guitars, driving bass", 140, "D major", "drive"),
    "upbeat.shorts": ("UK drill beat: sliding 808s, syncopated hats, dark piano chords", 142, "C# minor", "drive"),
    "upbeat.challenge": ("epic hybrid trailer music: taiko drums, deep braams, driving strings, risers", 120, "D minor", "climb"),
    "upbeat.vlogday": ("funk-rock: slap bass, tight horn section, wah guitar, live drums", 118, "E major", "song"),
    # ---- かわいい
    "cute_excited": ("bouncy swing-pop: upright bass, brushed drums, clarinet riffs, pizzicato strings", 140, "F major", "song"),
    "cute_kitten": ("tiptoeing comedic chamber music: pizzicato strings, bassoon and light percussion", 104, "Bb major", "even"),
    "cute_toybox": ("kawaii future bass: bright supersaw chords, punchy drums, wobbly bass (real synths only)", 150, "A major", "build"),
    "upbeat.wakuwaku": ("sunny reggae-pop: offbeat guitar skank, warm bass, one-drop drums, light percussion", 92, "G major", "song"),
    "upbeat.pet": ("playful acoustic pop: ukulele, handclaps, upright bass, light drums", 120, "D major", "song"),
    "upbeat.sweets": ("sweet soul-pop: Wurlitzer electric piano, soft drums, round bass, light guitar", 96, "E major", "even"),
    # ---- 緊張
    "tense_chase": ("pulsing action thriller: staccato strings, ticking hi-hats, low synth ostinato, heavy hits", 150, "D minor", "drive"),
    "tense_countdown": ("suspenseful electronic countdown: rising tension, ticking percussion, sub drops", 120, "F minor", "climb"),
    "tense_shadow": ("slow ominous orchestral tension: low brass, string clusters, distant thuds", 70, "B minor", "climb"),
    # ---- ナチュラル
    "travel_sky": ("wide indie folk: strummed acoustic guitars, mandolin, stomps and claps, warm bass", 112, "A major", "build"),
    "travel_seaside": ("Hawaiian slack-key guitar with gentle ukulele and soft hand percussion", 84, "G major", "even"),
    "travel_mountain_mist": ("Celtic-flavored folk: Celtic harp, acoustic guitar, soft bodhran", 90, "D major", "halves"),
    "daily_dog_walk": ("light country shuffle: acoustic guitar, upright bass, brushes, pedal steel", 108, "E major", "song"),
    "everyday.train-window": ("motorik indie groove: chiming guitars over a steady krautrock pulse and round bass", 116, "F# major", "even"),
    "everyday.island-breeze": ("Okinawan-inspired island music: sanshin over gentle island percussion and warm bass", 96, "F major", "even"),
    "everyday.forest-path": ("organic downtempo: nylon guitar, frame drums, soft forest ambience, warm bass", 95, "E minor", "even"),
    "everyday.old-town": ("Japanese traditional fusion: koto and shakuhachi-like flute textures over a relaxed lo-fi beat", 84, "Eb minor", "even"),
    # ---- 食事
    "meal_itadakimasu": ("happy New Orleans second-line brass band groove: tuba bass, snare and bass drum, trumpets and trombones", 104, "Bb major", "song"),
    "meal_lunch": ("light acoustic swing: rhythm guitar, upright bass, brushed drums", 128, "G major", "even"),
    "meal_kitchen": ("percussion-led cooking groove: congas, bongos, shakers, funky bass, rhythm guitar", 110, "E minor", "build"),
    "meal_sweets": ("1960s French pop instrumental: harpsichord, bass, light drums, strings", 112, "D major", "song"),
    "everyday.breakfast-table": ("bright morning acoustic pop: piano and acoustic guitar, soft shaker, light kick", 100, "A major", "even"),
    "everyday.home-dinner": ("warm Americana soul: Wurlitzer, slide guitar, laid-back drums, warm bass", 88, "F major", "even"),
    "everyday.bistro-night": ("tango-inspired bistro music: bandoneon, piano, double bass, dramatic but light", 118, "D minor", "song"),
    # ---- パーティー
    "party_cheers": ("1970s disco-funk: live bass, horn section, strings, tight four-on-the-floor drums", 118, "E major", "song"),
    "party_birthday": ("big band swing party: full horn section, walking bass, swinging drums", 160, "Bb major", "song"),
    "party_beach": ("reggaeton / dancehall: dembow rhythm, deep bass, tropical guitar plucks", 96, "G minor", "drive"),
    "party_neon_dance": ("electro house: big saw bass drops, punchy kick, rising builds", 128, "F minor", "build"),
    "upbeat.kanpai": ("Japanese festival groove: taiko and shamisen over modern drums and bass, festive and loud", 140, "D minor", "drive"),
    "upbeat.dancefloor": ("afro-house: layered hand percussion, rolling bass, hypnotic chords", 122, "A major", "build"),
    "upbeat.birthday": ("upbeat ska: offbeat guitar, horn stabs, walking bass, fast drums", 160, "F major", "song"),
    "upbeat.nightout": ("amapiano: log-drum bass, shakers, jazzy keys, deep groove", 112, "B minor", "build"),
    # ---- バラエティ
    "variety_slapstick": ("frantic slapstick ragtime: honky-tonk piano, tuba, snare drum, comic timing", 180, "F major", "drive"),
    "variety_quiz": ("game-show funk: stop-and-go drums, brass stabs, clavinet, funky bass", 112, "G major", "song"),
    "variety_sneak": ("spy-movie surf guitar: reverb twang, tom grooves, upright bass, sneaky mood", 120, "E minor", "song"),
    "variety_trouble": ("chaotic comedic polka: tuba, accordion, snare, oom-pah rhythm", 150, "Bb major", "drive"),
    "upbeat.dotabata": ("high-energy Balkan brass band: trumpets, tuba, frantic drums", 140, "D minor", "drive"),
    "upbeat.oshiete": ("quirky electro-swing: chopped swing brass over a boom-bap beat and upright bass", 112, "G minor", "song"),
    "upbeat.shippai": ("lazy slow blues: slide guitar, tired shuffle drums, walking bass", 70, "E major", "even"),
    "upbeat.challengegame": ("high-energy esports electro-rock: distorted synth bass, big drums, guitars", 150, "F# minor", "drive"),
    # ---- ていねいな暮らし
    "living_morning_coffee": ("minimal acoustic guitar and soft piano, spacious and quiet", 84, "D major", "even"),
    "living_laundry": ("breezy indie folk: ukulele, soft claps, light acoustic bass", 100, "G major", "even"),
    "living_plants": ("ambient lo-fi: soft Rhodes, gentle vinyl crackle, slow soft beat", 70, "F major", "even"),
    "living_tidy": ("upbeat lo-fi house: filtered chords, soft kick, warm bass", 118, "Eb major", "build"),
    "everyday.bread-baking": ("warm acoustic jazz guitar duo, slow and cozy, upright bass", 88, "Bb major", "even"),
    "everyday.sunlit-room": ("gentle harp and strings, soft and sunny, no drums", 72, "A major", "even"),
    "everyday.flower-arranging": ("a slow, gentle solo piano waltz in 3/4 in an early-20th-century French impressionist style", 72, "F major", "even"),
    "everyday.evening-journal": ("lo-fi chillhop: warm bass, soft piano, gentle rain ambience", 80, "B minor", "even"),
    # ---- ホラー
    "horror_midnight_hall": ("dark ambient horror: deep sub rumbles, creaking textures, dissonant strings", 60, "D minor", "climb"),
    "horror_abandoned": ("industrial horror: distorted drones, heavy reverbed metallic percussion", 80, "C# minor", "build"),
    "horror_music_box": ("creepy detuned upright piano lullaby with eerie reverb and low drones", 64, "Bb minor", "even"),
    "mood.sealed-room": ("suspense horror: sudden silences, tense violin harmonics, low thuds", 70, "E minor", "climb"),
    "mood.old-well": ("Japanese horror: eerie breathy shakuhachi-like tones, low taiko hits, dark drones", 60, "D minor", "climb"),
    "mood.cursed-doll": ("creepy waltz with out-of-tune strings and ghostly textures", 90, "G minor", "even"),
    "mood.fog-forest": ("slow dark folk horror: droning cello, distant hand drums", 66, "F# minor", "climb"),
    # ---- ミステリアス
    "mystery_riddle": ("playful mystery: pizzicato strings and clarinet over a light walking bass", 108, "D minor", "song"),
    "mystery_truth": ("dramatic revelation: building strings, piano ostinato, big percussion", 90, "C# minor", "climb"),
    "mystery_secret_room": ("dark minimal electronica: deep sub, plucked synths, evolving textures", 100, "F minor", "build"),
    "mood.missing-key": ("noir detective jazz: upright bass, brushed drums, dark piano, muted horn pads", 92, "Eb minor", "even"),
    "mood.detective": ("1960s spy jazz: upright bass, flute, bongos, jazz guitar", 116, "G minor", "song"),
    "mood.old-map": ("adventure orchestral: exotic hand percussion, strings, curious woodwinds", 100, "E minor", "halves"),
    "mood.clock-tower": ("Victorian mystery: harpsichord, strings, ticking woodblock percussion", 96, "B minor", "even"),
    # ---- 季節
    "season_spring_sakura": ("gentle Japanese spring: koto and piano with soft strings and a light beat", 84, "G major", "even"),
    "season_summer_holiday": ("sunny surf pop: reverb guitars, tambourine, bouncy bass, live drums", 132, "A major", "drive"),
    "season_autumn_leaves": ("warm autumn folk: acoustic guitar, cello, soft brushes", 80, "F# minor", "even"),
    "season_winter_morning": ("crisp winter ambient: piano, soft strings, airy pads, no drums", 70, "E major", "even"),
    "season_new_year": ("modern Japanese New Year: koto and shamisen over a hip-hop beat with taiko", 92, "D minor", "build"),
    "season_christmas": ("cozy swinging jazz Christmas: piano trio with brushes and warm upright bass", 120, "F major", "song"),
    "events.spring_breeze": ("fresh acoustic pop: light strings, claps, acoustic guitar", 116, "D major", "song"),
    "events.summer_sky": ("summer funk-pop: bright horns, congas, funky guitar, bouncy bass", 112, "Bb major", "song"),
    "events.autumn_afternoon": ("lo-fi jazz guitar with warm bass, autumn afternoon mood", 84, "Ab major", "even"),
    "events.winter_lights": ("warm orchestral winter waltz in 3/4: strings and soft brass", 92, "Eb major", "halves"),
    "events.hatsumode": ("solemn modern Japanese: breathy shakuhachi-like textures, koto, deep taiko pulses", 80, "E minor", "climb"),
    "events.holy_night": ("quiet sacred ambience: pipe organ and strings, gentle, no drums", 66, "Db major", "even"),
    # ---- 行事
    "event_entrance_spring": ("bright hopeful piano pop with strings and light drums", 112, "F major", "song"),
    "event_entrance_first_day": ("gentle indie pop: acoustic guitar, soft synth pads, light drums", 104, "E major", "even"),
    "event_graduation_day": ("emotional piano and strings building to a full band", 76, "Bb major", "climb"),
    "event_graduation_farewell": ("melancholic duet of acoustic guitar and cello", 72, "D minor", "even"),
    "event_sports_day": ("brass marching band: snare cadences, bass drum, trumpets, sousaphone", 120, "Eb major", "drive"),
    "event_sports_relay": ("fast driving rock-pop with galloping drums and guitars", 164, "A major", "drive"),
    "event_birth_lullaby": ("soft lullaby: harp, soft strings and piano, no drums", 60, "G major", "even"),
    "event_birth_little_hands": ("tender fingerpicked acoustic guitar with soft piano", 76, "D major", "even"),
    "event_memorial_remember": ("respectful remembrance: solo cello and string orchestra, no drums", 60, "F minor", "even"),
    "event_memorial_prayer": ("quiet prayer: pipe organ and soft strings, no drums", 60, "Ab major", "even"),
    "event_wedding_vow": ("wedding ceremony: elegant string quartet with harp", 84, "E major", "even"),
    "event_wedding_two": ("romantic slow R&B on the progression Bm - G - A - D with rich voicings (Bm9, Gmaj7, A6, Dmaj9): Rhodes, clean guitar, deep sub bass, laid-back drums", 84, "B minor", "build"),
    "event_wedding_celebration": ("joyful celebration: bright brass and strings with a lively beat", 120, "Bb major", "song"),
    "event_new_step": ("uplifting indie electronic: steady pulse, wide synths, live drums", 118, "G major", "build"),
    "event_restart": ("anthemic pop-rock that builds from piano to a full band", 128, "D major", "climb"),
    "events.entrance_ceremony": ("formal ceremonial strings and brass, dignified", 90, "Eb major", "even"),
    "events.school_gate": ("nostalgic Japanese pop band ballad with piano and strings", 84, "Ab major", "song"),
    "events.departure_day": ("cinematic uplifting orchestral music with driving strings", 110, "F major", "climb"),
    "events.classroom_memories": ("nostalgic lo-fi piano with tape warmth and a soft beat", 76, "B major", "even"),
    "events.ready_go": ("fast marching snare and brass fanfare-style groove", 140, "F major", "drive"),
    "events.cheer_battle": ("cheer drumline: big marching drums and brass stabs", 130, "G major", "drive"),
    "events.nice_to_meet": ("friendly light acoustic pop: ukulele, claps, bass", 110, "Db major", "song"),
    "events.cradle": ("gentle lullaby in 3/4: harp and soft strings, no drums", 66, "F major", "even"),
    "events.remembrance": ("nostalgic orchestral piano ballad with strings", 70, "C# minor", "climb"),
    "events.quiet_prayer": ("minimal ambient pads and soft piano, very calm, no drums", 60, "E major", "even"),
    "events.eternal_love": ("romantic wedding piano and strings with a gentle build", 72, "G major", "climb"),
    "events.banquet": ("joyful Latin salsa celebration: piano montuno, horn section, congas, timbales, bass", 180, "D major", "song"),
    "events.toward_tomorrow": ("uplifting cinematic electronic: big drums, wide synths, deep bass", 124, "B major", "climb"),
    "events.open_door": ("grand opening: orchestral brass fanfare and timpani flowing into an uplifting groove", 112, "D major", "climb"),
    # ---- ダンス
    "dance_mirrorball": ("late-1970s Munich synth disco: pulsing arpeggiated sequencer bass, four-on-the-floor kick, analog synth layers, disco strings", 120, "F# minor", "build"),
    "dance_neon_floor": ("1980s synthwave dance: driving arpeggiated bass, big gated snares, shimmering pads", 118, "B minor", "drive"),
    "dance_sequencer": ("minimal techno: hypnotic sequencer, deep rolling kick, subtle evolving textures", 128, "E minor", "build"),
    "dance_party_up": ("Italo-disco and eurobeat lineage Japanese dance-pop: pulsing sequencer-style synth bass, fast four-on-the-floor drums, bright synth stabs, disco strings, big hand-raising choreography energy", 150, "E major", "drive"),
    "dance_eurobeat": ("classic eurobeat instrumental: fast octave synth bass, punchy drums, bright synth stabs", 155, "F# minor", "drive"),
    "dance_retro_star": ("Italo disco: sequenced octave bass, gated drums, analog brass synths, retro arpeggios", 118, "D minor", "song"),
    "dance_choreo": ("Korean-pop-style dance instrumental: hard-hitting drums, synth brass, deep sub bass, sharp breaks for choreography", 126, "G# minor", "drive"),
    "dance_shine": ("modern French-touch nu-disco: filtered disco loops, funky bass, sidechained synths", 120, "Ab major", "build"),
    "dance_midnight_disco": ("1980s boogie / electro-funk: rubbery synth bass, claps, funky guitar, warm pads", 112, "A major", "song"),
    "dance_rush": ("UK garage 2-step: shuffled drums, deep sub bass, chopped chords", 132, "F minor", "build"),
}

def build(spec):
    style, bpm, key, form = spec
    assert key not in ("C major", "A minor"), key
    return (
        "Instrumental only: no vocals, no singing, no humming, no choir. "
        f"Style: {style}. Key: {key}. Tempo: {bpm} BPM, steady. Form: {FORMS[form]}. "
        "Recorded and mixed like a professional production, never karaoke-like or stock-music-like. "
        "Any melody stays subtle and is played by real instruments; no catchy lead line on top. "
        "No glockenspiel, no bells, no chimes, no music box, no toy sounds. "
        "Phrases in clear 8-bar sections; end on a clean final chord or hit, no fade-out. About 3 minutes long."
    )

def main():
    presets = json.load(open(sys.argv[1], encoding="utf-8"))
    out = []
    missing = [p["id"] for p in presets if p["id"] not in SPEC]
    assert not missing, missing
    styles = {}
    for p in presets:
        spec = SPEC[p["id"]]
        if spec is None:
            continue
        styles.setdefault(spec[0], []).append(p["id"])
        out.append({"id": p["id"], "name": p["name"], "mood": p["mood"], "bpm": spec[1], "key": spec[2], "prompt": build(spec)})
    dup = {s: ids for s, ids in styles.items() if len(ids) > 1}
    assert not dup, dup
    json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(len(out), "prompts (", len(presets) - len(out), "kept from v1 )")

if __name__ == "__main__":
    main()
