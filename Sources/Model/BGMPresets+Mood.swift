import Foundation

// 雰囲気別の追加プリセット(感動・夜/チル・ホラー・ミステリアス)。データのみ。
extension BGMLibrary {
    static let moodPresets: [BGMPreset] = [
        // ---- 感動(ナレーションの下敷き:ピアノ+パッド、ドラムなし/控えめ) ----
        BGMPreset("mood.heartfelt", "想いを込めて", .emotional, bpm: 68, key: 5, scale: .major,
                  progression: [1, 3, 6, 4, 1, 3, 4, 5], widePad: true, tone: .piano, drums: .none, arpeggio: true, pattern: 0, melody: true, reverb: 0.55),
        BGMPreset("mood.quiet-resolve", "静かな決意", .emotional, bpm: 80, key: 10, scale: .major,
                  progression: [6, 6, 4, 4, 1, 1, 5, 5], sevenths: true, widePad: true, tone: .piano, drums: .soft, pattern: 3, melody: true, reverb: 0.5),
        BGMPreset("mood.distant-memory", "遠い記憶", .emotional, bpm: 60, key: 4, scale: .minor,
                  progression: [1, 1, 6, 6, 3, 3, 7, 7], widePad: true, tone: .piano, bass: false, drums: .none, arpeggio: true, pattern: 0, sparkle: true, melody: true, reverb: 0.6),
        BGMPreset("mood.promise-day", "あの日の約束", .emotional, bpm: 74, key: 8, scale: .major,
                  progression: [4, 5, 3, 6], sevenths: true, widePad: true, tone: .piano, drums: .none, pattern: 1, beatsPerBar: 3, melody: true, reverb: 0.5),
        BGMPreset("mood.monologue", "ひとり語り", .emotional, bpm: 66, key: 1, scale: .dorian,
                  progression: [1, 1, 4, 4, 2, 2, 5, 5], sevenths: true, widePad: true, tone: .piano, bass: false, drums: .none, pattern: 0, melody: false, reverb: 0.45),

        // ---- 夜・チル ----
        BGMPreset("mood.streetlight", "街灯の下", .calm, bpm: 80, key: 3, scale: .dorian,
                  progression: [1, 4, 2, 5], sevenths: true, tone: .pluck, drums: .lofi, swing: 0.3, pattern: 2, vinyl: true, melody: true, reverb: 0.45),
        BGMPreset("mood.starfall", "星降る夜", .calm, bpm: 70, key: 6, scale: .pentatonic,
                  progression: [1, 1, 6, 6, 4, 4, 5, 5], widePad: true, tone: .bell, drums: .none, arpeggio: true, pattern: 0, sparkle: true, melody: true, reverb: 0.6),
        BGMPreset("mood.sleepless", "眠れない夜", .calm, bpm: 88, key: 11, scale: .minor,
                  progression: [1, 7, 6, 7], sevenths: true, pad: false, tone: .piano, drums: .lofi, swing: 0.2, pattern: 3, vinyl: true, melody: true, reverb: 0.5),
        BGMPreset("mood.before-dawn", "夜明け前", .calm, bpm: 62, key: 0, scale: .minor,
                  progression: [1, 6, 3, 7, 1, 6, 4, 5], widePad: true, pluck: false, drums: .none, arpeggio: true, pattern: 0, liftToMajor: true, melody: true, reverb: 0.55),

        // ---- ホラー(濁ったドローン、ずれたパッド、ドラムなし/遅い鼓動) ----
        BGMPreset("mood.sealed-room", "開かずの間", .horror, bpm: 64, key: 1, scale: .minor,
                  progression: [1, 2, 1, 2], widePad: true, pluck: false, bass: false, drums: .heartbeat, pattern: 0,
                  drone: true, detuned: true, melody: false, reverb: 0.65),
        BGMPreset("mood.old-well", "古井戸", .horror, bpm: 60, key: 6, scale: .miyakobushi,
                  progression: [1, 2, 6, 1], widePad: true, tone: .pluck, bass: false, drums: .none, arpeggio: true, pattern: 0,
                  drone: false, detuned: true, melody: true, reverb: 0.6),
        BGMPreset("mood.cursed-doll", "呪いの人形", .horror, bpm: 76, key: 11, scale: .minor,
                  progression: [1, 6, 2, 1], pad: true, tone: .bell, bass: false, drums: .none, arpeggio: true, pattern: 0,
                  drone: true, detuned: true, sparkle: true, beatsPerBar: 3, melody: true, reverb: 0.6),
        BGMPreset("mood.fog-forest", "霧の森", .horror, bpm: 70, key: 3, scale: .dorian,
                  progression: [1, 7, 1, 2], widePad: true, pluck: false, bass: true, drums: .heartbeat, pattern: 1,
                  drone: true, detuned: true, organ: true, melody: false, reverb: 0.55),

        // ---- ミステリアス(短調/ドリアンの弾く音、刻むハット、85〜100) ----
        BGMPreset("mood.missing-key", "消えた鍵", .mysterious, bpm: 94, key: 2, scale: .minor,
                  progression: [1, 6, 2, 5], sevenths: true, tone: .pizzicato, drums: .lofi, arpeggio: true, pattern: 2, melody: true, reverb: 0.35),
        BGMPreset("mood.detective", "探偵の午後", .mysterious, bpm: 88, key: 5, scale: .dorian,
                  progression: [1, 4, 1, 7], sevenths: true, pad: false, tone: .pluck, drums: .soft, swing: 0.3, pattern: 3, vinyl: true, melody: true, reverb: 0.4),
        BGMPreset("mood.old-map", "古い地図", .mysterious, bpm: 100, key: 7, scale: .dorian,
                  progression: [1, 2, 4, 1], tone: .marimba, drums: .lofi, arpeggio: true, swing: 0.15, pattern: 1, melody: true, reverb: 0.35),
        BGMPreset("mood.clock-tower", "時計塔", .mysterious, bpm: 85, key: 10, scale: .minor,
                  progression: [1, 1, 6, 7], widePad: true, tone: .bell, drums: .soft, arpeggio: true, pattern: 0, drone: true, melody: true, reverb: 0.45)
    ]
}
