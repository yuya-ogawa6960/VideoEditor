import Foundation

// 日常系の BGM プリセット(Vlog・旅・カフェ・ていねいな暮らし・食事)
extension BGMLibrary {
    static let everydayPresets: [BGMPreset] = [
        // ---- Vlog・日常(明るい) ----
        BGMPreset("everyday.sunny-errand", "おでかけ日和", .bright, bpm: 112, key: 0, scale: .major,
                  progression: [1, 5, 6, 4], tone: .pluck, drums: .soft, arpeggio: true, swing: 0.1, pattern: 1, reverb: 0.25),
        BGMPreset("everyday.weekend-vlog", "休日Vlog", .bright, bpm: 122, key: 5, scale: .major,
                  progression: [4, 1, 5, 6], pad: false, tone: .marimba, drums: .pop, arpeggio: true, pattern: 2, claps: true, reverb: 0.2),
        BGMPreset("everyday.bicycle", "自転車で", .bright, bpm: 128, key: 9, scale: .pentatonic,
                  progression: [1, 4, 6, 5], tone: .pluck, drums: .pop, arpeggio: true, swing: 0.15, pattern: 3, reverb: 0.2),
        BGMPreset("everyday.my-routine", "私のルーティン", .bright, bpm: 96, key: 3, scale: .major,
                  progression: [1, 6, 2, 5], sevenths: true, tone: .piano, drums: .lofi, swing: 0.2, pattern: 0, reverb: 0.25),
        BGMPreset("everyday.after-school", "放課後", .bright, bpm: 104, key: 11, scale: .major,
                  progression: [6, 4, 1, 5], tone: .bell, drums: .soft, arpeggio: true, pattern: 0, sparkle: true, reverb: 0.3),

        // ---- 旅・風景(ナチュラル) ----
        BGMPreset("everyday.train-window", "車窓の景色", .natural, bpm: 88, key: 4, scale: .major,
                  progression: [1, 3, 4, 5], widePad: true, tone: .pluck, drums: .soft, arpeggio: true, pattern: 1, reverb: 0.4),
        BGMPreset("everyday.island-breeze", "島の風", .natural, bpm: 98, key: 8, scale: .pentatonic,
                  progression: [1, 5, 4, 4], widePad: true, tone: .marimba, drums: .soft, swing: 0.25, pattern: 3, reverb: 0.35),
        BGMPreset("everyday.forest-path", "森の小道", .natural, bpm: 60, key: 1, scale: .dorian,
                  progression: [1, 4, 1, 7], widePad: true, pluck: false, bass: false, drums: .none, arpeggio: true, sparkle: true, melody: false, reverb: 0.6),
        BGMPreset("everyday.old-town", "古い町並み", .natural, bpm: 76, key: 6, scale: .yo,
                  progression: [1, 4, 5, 1, 6, 4, 5, 1], widePad: true, tone: .pluck, drums: .none, arpeggio: true, reverb: 0.45),

        // ---- カフェ・ローファイ(おしゃれ) ----
        BGMPreset("everyday.study-lofi", "勉強ローファイ", .stylish, bpm: 80, key: 2, scale: .dorian,
                  progression: [1, 4, 1, 4], sevenths: true, tone: .piano, drums: .lofi, swing: 0.3, pattern: 1, vinyl: true, melody: false, reverb: 0.2),
        BGMPreset("everyday.afternoon-tea", "午後の紅茶", .stylish, bpm: 92, key: 10, scale: .major,
                  progression: [4, 3, 2, 1], sevenths: true, tone: .bell, drums: .lofi, swing: 0.25, pattern: 3, reverb: 0.25),
        BGMPreset("everyday.city-cafe", "街角カフェ", .stylish, bpm: 100, key: 7, scale: .major,
                  progression: [2, 5, 3, 6], sevenths: true, pad: false, tone: .pluck, drums: .soft, swing: 0.35, pattern: 2, reverb: 0.2),
        BGMPreset("everyday.rainy-desk", "雨の日の机", .stylish, bpm: 70, key: 4, scale: .minor,
                  progression: [1, 4, 7, 3], sevenths: true, widePad: true, tone: .piano, drums: .lofi, swing: 0.2, pattern: 0, vinyl: true, melody: false, reverb: 0.35),

        // ---- ていねいな暮らし ----
        BGMPreset("everyday.bread-baking", "パンを焼く", .slowLiving, bpm: 82, key: 9, scale: .major,
                  progression: [1, 4, 2, 5], sevenths: true, tone: .marimba, drums: .soft, swing: 0.15, pattern: 0, reverb: 0.3),
        BGMPreset("everyday.sunlit-room", "陽だまりの部屋", .slowLiving, bpm: 66, key: 4, scale: .major,
                  progression: [1, 5, 6, 3, 4, 1, 2, 5], widePad: true, tone: .piano, drums: .none, arpeggio: true, reverb: 0.5),
        BGMPreset("everyday.flower-arranging", "花を生ける", .slowLiving, bpm: 72, key: 1, scale: .pentatonic,
                  progression: [4, 1, 4, 5], widePad: true, tone: .bell, bass: false, drums: .none, arpeggio: true,
                  sparkle: true, beatsPerBar: 3, reverb: 0.55),
        BGMPreset("everyday.evening-journal", "夜の日記", .slowLiving, bpm: 78, key: 11, scale: .dorian,
                  progression: [1, 2, 4, 1], sevenths: true, widePad: true, tone: .pluck, drums: .lofi, swing: 0.2, pattern: 2, reverb: 0.35),

        // ---- 食事 ----
        BGMPreset("everyday.breakfast-table", "朝ごはん", .meal, bpm: 112, key: 2, scale: .major,
                  progression: [1, 2, 4, 1], pad: false, tone: .marimba, drums: .pop, arpeggio: true, swing: 0.2, pattern: 1, reverb: 0.2),
        BGMPreset("everyday.home-dinner", "おうちごはん", .meal, bpm: 92, key: 7, scale: .major,
                  progression: [1, 6, 4, 5], sevenths: true, widePad: true, tone: .piano, drums: .soft, pattern: 3, reverb: 0.3),
        BGMPreset("everyday.bistro-night", "夜のビストロ", .meal, bpm: 104, key: 3, scale: .dorian,
                  progression: [2, 5, 1, 6], sevenths: true, tone: .pluck, drums: .lofi, swing: 0.3, pattern: 2, vinyl: true, reverb: 0.25)
    ]
}
