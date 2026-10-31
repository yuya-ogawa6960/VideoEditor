import Foundation

// 季節・人生の行事の BGM プリセット(データのみ)。
extension BGMLibrary {
    static let eventsPresets: [BGMPreset] = [
        // ---- 季節 ----
        BGMPreset("events.spring_breeze", "春風", .seasonal, bpm: 100, key: 7, scale: .pentatonic,
                  progression: [1, 5, 4, 1], tone: .pluck, drums: .soft, arpeggio: true, pattern: 3, sparkle: true, melody: true, reverb: 0.4),
        BGMPreset("events.summer_sky", "夏空", .seasonal, bpm: 126, key: 9, scale: .major,
                  progression: [1, 4, 6, 5], pad: false, tone: .marimba, drums: .pop, arpeggio: true, swing: 0.2, pattern: 2, claps: true, melody: true, reverb: 0.3),
        BGMPreset("events.autumn_afternoon", "秋の午後", .seasonal, bpm: 78, key: 4, scale: .major,
                  progression: [2, 5, 1, 6], sevenths: true, tone: .pluck, drums: .soft, swing: 0.25, pattern: 0, vinyl: true, melody: true, reverb: 0.35),
        BGMPreset("events.winter_lights", "冬の灯り", .seasonal, bpm: 70, key: 10, scale: .major,
                  progression: [1, 3, 4, 5], widePad: true, tone: .bell, drums: .soft, arpeggio: true, pattern: 1, sleighBells: true, sparkle: true, melody: true, reverb: 0.45),
        BGMPreset("events.hatsumode", "初詣", .seasonal, bpm: 84, key: 9, scale: .miyakobushi,
                  progression: [1, 4, 5, 1], tone: .pluck, bass: false, drums: .none, arpeggio: true, pattern: 0, sparkle: true, melody: true, reverb: 0.45),
        BGMPreset("events.holy_night", "聖夜", .seasonal, bpm: 66, key: 7, scale: .major,
                  progression: [1, 6, 4, 5, 1, 6, 2, 5], widePad: true, tone: .bell, drums: .none, arpeggio: true,
                  sleighBells: true, sparkle: true, beatsPerBar: 3, melody: true, reverb: 0.5),
        // ---- 入学 ----
        BGMPreset("events.entrance_ceremony", "入学式", .lifeEvent, bpm: 112, key: 10, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 4, 5], tone: .brass, drums: .march, pattern: 1, melody: true, reverb: 0.25),
        BGMPreset("events.school_gate", "桜の校門", .lifeEvent, bpm: 98, key: 4, scale: .pentatonic,
                  progression: [4, 5, 3, 6], tone: .piano, drums: .soft, arpeggio: true, pattern: 0, sparkle: true, melody: true, reverb: 0.4),
        // ---- 卒業 ----
        BGMPreset("events.departure_day", "旅立ちの日", .lifeEvent, bpm: 72, key: 2, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 2, 5], widePad: true, drums: .none, arpeggio: true, pattern: 0, melody: true, reverb: 0.5),
        BGMPreset("events.classroom_memories", "思い出の教室", .lifeEvent, bpm: 80, key: 11, scale: .major,
                  progression: [4, 5, 3, 6, 2, 5, 1, 1], sevenths: true, widePad: true, tone: .pluck, drums: .soft, pattern: 3, melody: true, reverb: 0.5),
        // ---- 運動会 ----
        BGMPreset("events.ready_go", "よーいドン", .lifeEvent, bpm: 144, key: 7, scale: .major,
                  progression: [1, 4, 5, 1], pad: false, tone: .brass, drums: .march, arpeggio: true, pattern: 2, claps: true, melody: true, reverb: 0.2),
        BGMPreset("events.cheer_battle", "応援合戦", .lifeEvent, bpm: 136, key: 0, scale: .yo,
                  progression: [1, 5, 4, 5], pad: false, tone: .marimba, drums: .pop, pattern: 1, claps: true, melody: true, reverb: 0.2),
        // ---- 誕生 ----
        BGMPreset("events.nice_to_meet", "はじめまして", .lifeEvent, bpm: 76, key: 0, scale: .major,
                  progression: [1, 4, 1, 5], widePad: true, tone: .piano, bass: false, drums: .none, arpeggio: true,
                  sparkle: true, beatsPerBar: 3, melody: true, reverb: 0.5),
        BGMPreset("events.cradle", "ゆりかご", .lifeEvent, bpm: 88, key: 3, scale: .pentatonic,
                  progression: [1, 6, 4, 5], pad: false, tone: .bell, bass: false, drums: .none, arpeggio: true,
                  sparkle: true, beatsPerBar: 3, melody: true, reverb: 0.5),
        // ---- 追悼 ----
        BGMPreset("events.remembrance", "追憶", .lifeEvent, bpm: 54, key: 5, scale: .minor,
                  progression: [1, 4, 6, 5], widePad: true, pluck: false, drums: .none, organ: true, melody: false, reverb: 0.65),
        BGMPreset("events.quiet_prayer", "静かな祈り", .lifeEvent, bpm: 58, key: 11, scale: .minor,
                  progression: [1, 6, 3, 7, 4, 1, 5, 1], sevenths: true, widePad: true, tone: .piano, drums: .none, arpeggio: true, organ: true, melody: false, reverb: 0.6),
        // ---- ウエディング ----
        BGMPreset("events.eternal_love", "永遠の愛", .lifeEvent, bpm: 70, key: 8, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 4, 5], sevenths: true, widePad: true, drums: .none, arpeggio: true, sparkle: true, melody: true, reverb: 0.5),
        BGMPreset("events.banquet", "祝宴", .lifeEvent, bpm: 118, key: 2, scale: .major,
                  progression: [1, 6, 2, 5], tone: .brass, drums: .pop, arpeggio: true, swing: 0.1, pattern: 1, claps: true, sparkle: true, melody: true, reverb: 0.3),
        // ---- 新しい一歩(内省→希望) ----
        BGMPreset("events.toward_tomorrow", "明日へ", .lifeEvent, bpm: 84, key: 6, scale: .minor,
                  progression: [1, 6, 3, 7], widePad: true, tone: .pluck, drums: .soft, arpeggio: true, pattern: 0, liftToMajor: true, melody: true, reverb: 0.38),
        BGMPreset("events.open_door", "扉をひらく", .lifeEvent, bpm: 100, key: 1, scale: .dorian,
                  progression: [1, 4, 1, 7], sevenths: true, tone: .piano, drums: .lofi, arpeggio: true, swing: 0.1, pattern: 3, liftToMajor: true, melody: true, reverb: 0.35),
    ]
}
