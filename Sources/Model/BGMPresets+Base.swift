import Foundation

// =====================================================================
// 最初から入っている 75 曲(リードが書いたもの)。グループ別のファイルと id・名前が重ならないようにしてある。
// 配分: 明るい(日常)5 / ナチュラル(旅・風景)4 / 落ち着いた(夜・チル)4 / おしゃれ(カフェ・会社)5 /
//       元気 4 / 感動 4 / かわいい 3 / 緊張 3 / 食事 4 / パーティー 4 / バラエティ 4 /
//       ていねいな暮らし 4 / ホラー 3 / ミステリアス 3 / 季節 6 / 行事 15
// =====================================================================
extension BGMLibrary {
    static let basePresets: [BGMPreset] = [
        // ---- 明るい(日常・Vlog:アコースティック風の弾く音+やさしいドラム) ----
        BGMPreset("daily_morning_walk", "朝の散歩", .bright, bpm: 108, key: 7, scale: .major,
                  progression: [1, 5, 6, 4], tone: .pluck, drums: .soft, arpeggio: true, swing: 0.15, pattern: 0),
        BGMPreset("daily_shopping", "買い物日和", .bright, bpm: 116, key: 2, scale: .major,
                  progression: [1, 4, 5, 4], tone: .pluck, drums: .soft, pattern: 1),
        BGMPreset("daily_park", "公園の午後", .bright, bpm: 104, key: 9, scale: .major,
                  progression: [4, 5, 3, 6], tone: .pluck, drums: .soft, arpeggio: true, pattern: 0),
        BGMPreset("daily_school_road", "通学路", .bright, bpm: 120, key: 4, scale: .major,
                  progression: [1, 5, 6, 4], pad: false, tone: .pluck, drums: .pop, arpeggio: true, pattern: 1),
        BGMPreset("corp_howto", "使い方ガイド", .bright, bpm: 100, key: 2, scale: .major,
                  progression: [1, 6, 4, 5], tone: .pluck, drums: .soft, arpeggio: true, pattern: 0),

        // ---- ナチュラル(旅・風景:広いパッド、ゆっくり、映画風) ----
        BGMPreset("travel_sky", "旅の空", .natural, bpm: 72, key: 2, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 4, 5], widePad: true, drums: .soft, arpeggio: true, pattern: 0, reverb: 0.55),
        BGMPreset("travel_seaside", "海辺の道", .natural, bpm: 80, key: 7, scale: .major,
                  progression: [1, 4, 6, 5], widePad: true, tone: .pluck, drums: .soft, pattern: 3, reverb: 0.5),
        BGMPreset("travel_mountain_mist", "山の朝もや", .natural, bpm: 64, key: 9, scale: .pentatonic,
                  progression: [1, 4, 1, 5], widePad: true, pluck: false, drums: .none, arpeggio: true, pattern: 0, reverb: 0.6),
        BGMPreset("daily_dog_walk", "犬と散歩", .natural, bpm: 112, key: 3, scale: .pentatonic,
                  progression: [1, 4, 6, 5], tone: .pluck, drums: .soft, arpeggio: true, swing: 0.2, pattern: 3),

        // ---- 落ち着いた(夜・チル:暗めのパッド、ゆっくりしたビート) ----
        BGMPreset("night_view", "夜景", .calm, bpm: 72, key: 1, scale: .minor,
                  progression: [1, 6, 3, 7], sevenths: true, widePad: true, drums: .lofi, swing: 0.2, pattern: 0, reverb: 0.45),
        BGMPreset("night_drive", "深夜のドライブ", .calm, bpm: 86, key: 8, scale: .dorian,
                  progression: [1, 2, 4, 2], sevenths: true, widePad: true, drums: .lofi, pattern: 1),
        BGMPreset("night_moonlight", "月あかり", .calm, bpm: 66, key: 9, scale: .minor,
                  progression: [1, 6, 3, 7], widePad: true, drums: .none, arpeggio: true, pattern: 0, reverb: 0.55),
        BGMPreset("travel_sunset_hill", "夕焼けの丘", .calm, bpm: 68, key: 5, scale: .major,
                  progression: [1, 3, 6, 4, 1, 3, 4, 5], widePad: true, drums: .none, arpeggio: true, pattern: 0, reverb: 0.55),

        // ---- おしゃれ(カフェ・ローファイ、会社紹介) ----
        BGMPreset("cafe_night", "夜のカフェ", .stylish, bpm: 84, key: 11, scale: .major,
                  progression: [1, 6, 2, 5], sevenths: true, drums: .lofi, swing: 0.3, pattern: 2, vinyl: true, reverb: 0.2),
        BGMPreset("cafe_rain", "雨のカフェ", .stylish, bpm: 76, key: 8, scale: .major,
                  progression: [2, 5, 1, 1], sevenths: true, drums: .lofi, swing: 0.35, pattern: 0, vinyl: true, reverb: 0.2),
        BGMPreset("cafe_window_seat", "窓際の席", .stylish, bpm: 90, key: 3, scale: .major,
                  progression: [2, 5, 1, 6], sevenths: true, pad: false, drums: .soft, swing: 0.4, pattern: 3),
        BGMPreset("corp_company", "会社紹介", .stylish, bpm: 104, key: 0, scale: .major,
                  progression: [1, 5, 6, 4], drums: .pop, arpeggio: true, pattern: 0),
        BGMPreset("corp_product", "製品の紹介", .stylish, bpm: 108, key: 7, scale: .major,
                  progression: [1, 4, 6, 5], tone: .pluck, drums: .pop, arpeggio: true, pattern: 1),

        // ---- 元気(ショート動画:ポップ/ハウス 124〜135) ----
        BGMPreset("energy_run", "走り出す", .energetic, bpm: 128, key: 4, scale: .major,
                  progression: [1, 5, 6, 4], pad: false, drums: .pop, arpeggio: true, pattern: 1),
        BGMPreset("energy_jump", "ジャンプ", .energetic, bpm: 132, key: 2, scale: .major,
                  progression: [1, 6, 4, 5], pad: false, drums: .pop, swing: 0.15, pattern: 2),
        BGMPreset("energy_dash", "全力ダッシュ", .energetic, bpm: 135, key: 9, scale: .minor,
                  progression: [1, 6, 7, 1], pad: false, drums: .pop, arpeggio: true, pattern: 1),
        BGMPreset("energy_club", "クラブの夜", .energetic, bpm: 130, key: 0, scale: .dorian,
                  progression: [1, 4, 1, 7], sevenths: true, pluck: false, drums: .house, arpeggio: true, pattern: 1),

        // ---- 感動(ナレーションの下敷き:ピアノ+弦っぽいパッド、ドラム控えめ) ----
        BGMPreset("emotion_important_talk", "大切な話", .emotional, bpm: 70, key: 7, scale: .major,
                  progression: [4, 5, 3, 6, 4, 5, 1, 1], widePad: true, drums: .none, pattern: 0, melody: false, reverb: 0.5),
        BGMPreset("emotion_letter", "手紙", .emotional, bpm: 64, key: 9, scale: .minor,
                  progression: [1, 6, 3, 7], sevenths: true, widePad: true, drums: .none, arpeggio: true, pattern: 0, melody: false, reverb: 0.55),
        BGMPreset("emotion_family", "家族の時間", .emotional, bpm: 78, key: 2, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 4, 5], widePad: true, drums: .soft, arpeggio: true, pattern: 0, reverb: 0.5),
        BGMPreset("emotion_thanks", "ありがとう", .emotional, bpm: 86, key: 0, scale: .major,
                  progression: [6, 4, 1, 5], widePad: true, drums: .soft, arpeggio: true, pattern: 1, reverb: 0.45),

        // ---- かわいい(はずむリズム、ペンタトニック、ベル) ----
        BGMPreset("cute_excited", "わくわく", .cute, bpm: 118, key: 5, scale: .pentatonic,
                  progression: [1, 4, 5, 1], tone: .bell, drums: .pop, arpeggio: true, swing: 0.3, pattern: 2),
        BGMPreset("cute_kitten", "こねこの散歩", .cute, bpm: 102, key: 7, scale: .pentatonic,
                  progression: [1, 5, 4, 5], tone: .bell, drums: .soft, arpeggio: true, swing: 0.3, pattern: 3),
        BGMPreset("cute_toybox", "おもちゃ箱", .cute, bpm: 114, key: 9, scale: .pentatonic,
                  progression: [1, 2, 5, 1], pad: false, tone: .bell, drums: .soft, arpeggio: true, swing: 0.25, pattern: 3),

        // ---- 緊張(短調、ドローン、速い刻み) ----
        BGMPreset("tense_chase", "追跡", .tense, bpm: 138, key: 11, scale: .minor,
                  progression: [1, 7, 6, 7], pad: false, drums: .house, arpeggio: true, pattern: 1, drone: true),
        BGMPreset("tense_countdown", "カウントダウン", .tense, bpm: 128, key: 2, scale: .minor,
                  progression: [1, 1, 6, 7], pluck: false, drums: .house, arpeggio: true, pattern: 0, drone: true),
        BGMPreset("tense_shadow", "迫る影", .tense, bpm: 84, key: 8, scale: .minor,
                  progression: [1, 2, 1, 2], pluck: false, drums: .soft, arpeggio: true, pattern: 1, drone: true, reverb: 0.45),

        // ---- 食事(あたたかく軽い、アコースティック・ボサノバ風 95〜110) ----
        BGMPreset("meal_itadakimasu", "いただきます", .meal, bpm: 100, key: 5, scale: .major,
                  progression: [1, 6, 2, 5], sevenths: true, tone: .pluck, drums: .soft, swing: 0.2, pattern: 3),
        BGMPreset("meal_lunch", "お昼ごはん", .meal, bpm: 106, key: 0, scale: .major,
                  progression: [1, 4, 5, 4], tone: .pluck, drums: .soft, arpeggio: true, swing: 0.25, pattern: 2),
        BGMPreset("meal_kitchen", "キッチンの音", .meal, bpm: 96, key: 9, scale: .major,
                  progression: [4, 5, 3, 6], sevenths: true, tone: .marimba, drums: .soft, swing: 0.15, pattern: 0),
        BGMPreset("meal_sweets", "おやつの時間", .meal, bpm: 110, key: 10, scale: .major,
                  progression: [1, 4, 1, 5], pad: false, tone: .bell, drums: .pop, swing: 0.35, pattern: 2),

        // ---- パーティー(ダンス・ポップ 120〜128、手拍子、明るいシンセ) ----
        BGMPreset("party_cheers", "乾杯", .party, bpm: 124, key: 7, scale: .major,
                  progression: [1, 5, 6, 4], drums: .house, arpeggio: true, pattern: 1, claps: true),
        BGMPreset("party_birthday", "誕生日", .party, bpm: 120, key: 2, scale: .major,
                  progression: [1, 6, 4, 5], drums: .pop, arpeggio: true, pattern: 1, claps: true),
        BGMPreset("party_beach", "ビーチパーティ", .party, bpm: 126, key: 4, scale: .major,
                  progression: [1, 4, 6, 5], drums: .house, arpeggio: true, pattern: 0, claps: true),
        BGMPreset("party_neon_dance", "ネオンダンス", .party, bpm: 128, key: 1, scale: .minor,
                  progression: [1, 6, 7, 1], sevenths: true, drums: .house, arpeggio: true, pattern: 0, claps: true),

        // ---- バラエティ(コミカル、スタッカート、ピチカート、はずむベース) ----
        BGMPreset("variety_slapstick", "ドタバタ", .variety, bpm: 126, key: 0, scale: .major,
                  progression: [1, 4, 5, 1], pad: false, tone: .pizzicato, drums: .pop, arpeggio: true, swing: 0.35, pattern: 2),
        BGMPreset("variety_quiz", "クイズタイム", .variety, bpm: 118, key: 7, scale: .major,
                  progression: [1, 2, 5, 1], pad: false, tone: .pizzicato, drums: .soft, arpeggio: true, swing: 0.3, pattern: 3),
        BGMPreset("variety_sneak", "こっそり", .variety, bpm: 104, key: 9, scale: .minor,
                  progression: [1, 4, 1, 5], pad: false, tone: .pizzicato, drums: .soft, swing: 0.4, pattern: 2),
        BGMPreset("variety_trouble", "ハプニング", .variety, bpm: 132, key: 5, scale: .major,
                  progression: [1, 6, 2, 5], pad: false, tone: .pizzicato, drums: .pop, arpeggio: true, swing: 0.3, pattern: 1),

        // ---- ていねいな暮らし(やわらかいピアノ、ギター風、空気感のあるパッド、70〜90) ----
        BGMPreset("living_morning_coffee", "朝の珈琲", .slowLiving, bpm: 76, key: 5, scale: .major,
                  progression: [1, 3, 4, 5], sevenths: true, widePad: true, tone: .pluck, drums: .none, arpeggio: true, pattern: 0, reverb: 0.45),
        BGMPreset("living_laundry", "洗濯日和", .slowLiving, bpm: 84, key: 0, scale: .major,
                  progression: [1, 4, 6, 5], widePad: true, tone: .pluck, drums: .soft, swing: 0.2, pattern: 0),
        BGMPreset("living_plants", "窓辺の植物", .slowLiving, bpm: 70, key: 7, scale: .pentatonic,
                  progression: [1, 4, 1, 5], widePad: true, drums: .none, arpeggio: true, pattern: 0, reverb: 0.5),
        BGMPreset("living_tidy", "部屋の片づけ", .slowLiving, bpm: 90, key: 2, scale: .major,
                  progression: [1, 6, 4, 5], sevenths: true, widePad: true, tone: .pluck, drums: .soft, swing: 0.15, pattern: 3),

        // ---- ホラー(濁ったドローン、低い鼓動、ずれたパッド、まばらなオルゴール) ----
        BGMPreset("horror_midnight_hall", "真夜中の廊下", .horror, bpm: 66, key: 4, scale: .minor,
                  progression: [1, 2, 1, 6], widePad: true, pluck: true, tone: .bell, bass: false,
                  drums: .heartbeat, pattern: 0, drone: true, detuned: true, sparkle: true, melody: false, reverb: 0.7),
        BGMPreset("horror_abandoned", "廃墟", .horror, bpm: 60, key: 10, scale: .miyakobushi,
                  progression: [1, 2, 1, 2], widePad: true, pluck: false, bass: false,
                  drums: .none, arpeggio: false, pattern: 0, drone: true, detuned: true, melody: false, reverb: 0.75),
        BGMPreset("horror_music_box", "こわいオルゴール", .horror, bpm: 78, key: 8, scale: .minor,
                  progression: [1, 6, 1, 2], widePad: true, tone: .bell, bass: false,
                  drums: .heartbeat, arpeggio: true, pattern: 0, drone: true, detuned: true, melody: false, reverb: 0.65),

        // ---- ミステリアス(短調・ドリアン、ピチカート、刻むハット、好奇心) ----
        BGMPreset("mystery_riddle", "謎解き", .mysterious, bpm: 92, key: 6, scale: .minor,
                  progression: [1, 4, 1, 2], sevenths: true, tone: .pizzicato, drums: .lofi, arpeggio: true, pattern: 0, drone: true),
        BGMPreset("mystery_truth", "真相", .mysterious, bpm: 86, key: 1, scale: .dorian,
                  progression: [1, 4, 1, 4], sevenths: true, tone: .pizzicato, drums: .soft, arpeggio: true, pattern: 1, drone: true),
        BGMPreset("mystery_secret_room", "秘密の部屋", .mysterious, bpm: 98, key: 9, scale: .minor,
                  progression: [1, 7, 6, 7], tone: .pizzicato, drums: .lofi, arpeggio: true, swing: 0.2, pattern: 1),

        // ---- 季節(春・夏・秋・冬・お正月・クリスマス) ----
        BGMPreset("season_spring_sakura", "桜の道", .seasonal, bpm: 96, key: 2, scale: .pentatonic,
                  progression: [1, 4, 6, 5], tone: .pluck, drums: .soft, arpeggio: true, pattern: 0, sparkle: true),
        BGMPreset("season_summer_holiday", "夏休み", .seasonal, bpm: 122, key: 7, scale: .major,
                  progression: [1, 5, 6, 4], tone: .marimba, drums: .pop, arpeggio: true, swing: 0.15, pattern: 1),
        BGMPreset("season_autumn_leaves", "紅葉", .seasonal, bpm: 82, key: 9, scale: .minor,
                  progression: [1, 6, 3, 7], sevenths: true, tone: .pluck, drums: .soft, swing: 0.2, pattern: 3),
        BGMPreset("season_winter_morning", "雪の朝", .seasonal, bpm: 74, key: 3, scale: .major,
                  progression: [1, 6, 4, 5], widePad: true, tone: .bell, drums: .soft, arpeggio: true, pattern: 0, sleighBells: true, reverb: 0.5),
        BGMPreset("season_new_year", "お正月", .seasonal, bpm: 94, key: 2, scale: .yo,
                  progression: [1, 4, 1, 5], tone: .pluck, drums: .soft, arpeggio: true, pattern: 3, sparkle: true),
        BGMPreset("season_christmas", "クリスマス", .seasonal, bpm: 112, key: 5, scale: .major,
                  progression: [1, 6, 2, 5], sevenths: true, tone: .bell, drums: .pop, arpeggio: true, swing: 0.3, pattern: 2, sleighBells: true),

        // ---- 行事(入学・卒業・運動会・誕生・追悼・ウエディング・再出発) ----
        BGMPreset("event_entrance_spring", "入学の春", .lifeEvent, bpm: 104, key: 0, scale: .major,
                  progression: [1, 4, 5, 1], tone: .brass, drums: .march, arpeggio: true, pattern: 0, sparkle: true),
        BGMPreset("event_entrance_first_day", "はじめての日", .lifeEvent, bpm: 110, key: 7, scale: .major,
                  progression: [1, 5, 6, 4], tone: .pluck, drums: .soft, arpeggio: true, pattern: 1),
        BGMPreset("event_graduation_day", "卒業の日", .lifeEvent, bpm: 74, key: 10, scale: .major,
                  progression: [1, 3, 6, 4, 1, 3, 4, 5], widePad: true, drums: .soft, pattern: 3, reverb: 0.5),
        BGMPreset("event_graduation_farewell", "さよならの歌", .lifeEvent, bpm: 68, key: 3, scale: .major,
                  progression: [6, 4, 1, 5, 6, 4, 2, 5], widePad: true, drums: .none, arpeggio: true, pattern: 0, reverb: 0.55),
        BGMPreset("event_sports_day", "運動会", .lifeEvent, bpm: 132, key: 5, scale: .major,
                  progression: [1, 4, 5, 1], pad: false, tone: .brass, drums: .march, arpeggio: true, pattern: 1),
        BGMPreset("event_sports_relay", "リレー", .lifeEvent, bpm: 140, key: 2, scale: .major,
                  progression: [1, 5, 1, 5, 4, 5, 1, 1], pad: false, tone: .brass, drums: .march, pattern: 1),
        BGMPreset("event_birth_lullaby", "子守唄", .lifeEvent, bpm: 84, key: 5, scale: .major,
                  progression: [1, 6, 4, 5], widePad: true, tone: .bell, bass: false, drums: .none,
                  arpeggio: true, pattern: 0, sparkle: true, beatsPerBar: 3, reverb: 0.5),
        BGMPreset("event_birth_little_hands", "小さな手", .lifeEvent, bpm: 72, key: 7, scale: .major,
                  progression: [1, 4, 1, 5], widePad: true, tone: .bell, bass: false, drums: .none,
                  arpeggio: true, pattern: 0, beatsPerBar: 3, reverb: 0.5),
        BGMPreset("event_memorial_remember", "偲ぶ", .lifeEvent, bpm: 56, key: 2, scale: .minor,
                  progression: [1, 6, 4, 5], widePad: true, pluck: false, bass: false, drums: .none, pattern: 0, organ: true, melody: false, reverb: 0.7),
        BGMPreset("event_memorial_prayer", "祈り", .lifeEvent, bpm: 52, key: 9, scale: .minor,
                  progression: [1, 4, 1, 7, 6, 4, 5, 1], widePad: true, bass: false, drums: .none, pattern: 0, organ: true, melody: false, reverb: 0.7),
        BGMPreset("event_wedding_vow", "誓いの日", .lifeEvent, bpm: 76, key: 3, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 4, 5], widePad: true, drums: .none, arpeggio: true, pattern: 0, reverb: 0.55),
        BGMPreset("event_wedding_two", "ふたりの時間", .lifeEvent, bpm: 84, key: 8, scale: .major,
                  progression: [1, 6, 4, 5], sevenths: true, widePad: true, drums: .soft, pattern: 3, reverb: 0.45),
        BGMPreset("event_wedding_celebration", "祝福", .lifeEvent, bpm: 90, key: 0, scale: .major,
                  progression: [1, 5, 6, 4], widePad: true, tone: .bell, drums: .pop, arpeggio: true, pattern: 0, claps: true),
        BGMPreset("event_new_step", "新しい一歩", .lifeEvent, bpm: 88, key: 9, scale: .minor,
                  progression: [1, 6, 3, 7], widePad: true, drums: .soft, arpeggio: true, pattern: 0, liftToMajor: true, reverb: 0.45),
        BGMPreset("event_restart", "再出発", .lifeEvent, bpm: 96, key: 4, scale: .minor,
                  progression: [1, 6, 7, 1], widePad: true, tone: .pluck, drums: .soft, arpeggio: true, pattern: 1, liftToMajor: true)
    ]
}
