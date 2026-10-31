import Foundation

// アップテンポ系プリセット(元気・パーティー・バラエティ・かわいい・会社紹介)
extension BGMLibrary {
    static let upbeatPresets: [BGMPreset] = [
        // 元気 / ショート
        BGMPreset("upbeat.hashiridasu", "スタート", .energetic, bpm: 128, key: 7, scale: .major,
                  progression: [1, 5, 6, 4], tone: .pluck, drums: .house, arpeggio: true, pattern: 1, melody: true, reverb: 0.2),
        BGMPreset("upbeat.shorts", "ショート用", .energetic, bpm: 134, key: 2, scale: .minor,
                  progression: [6, 4, 1, 5], pad: false, tone: .brass, drums: .house, pattern: 2, claps: true, melody: true, reverb: 0.18),
        BGMPreset("upbeat.challenge", "挑戦する", .energetic, bpm: 122, key: 9, scale: .dorian,
                  progression: [1, 4, 1, 5, 1, 4, 7, 5], sevenths: true, tone: .piano, drums: .pop, pattern: 3, melody: true, reverb: 0.2),
        BGMPreset("upbeat.vlogday", "今日も全力", .energetic, bpm: 126, key: 4, scale: .major,
                  progression: [4, 5, 3, 6], widePad: true, tone: .marimba, drums: .pop, arpeggio: true, pattern: 0, liftToMajor: false, melody: true, reverb: 0.22),
        // パーティー
        BGMPreset("upbeat.kanpai", "宴だ!", .party, bpm: 124, key: 0, scale: .major,
                  progression: [1, 6, 4, 5], tone: .brass, drums: .house, pattern: 0, claps: true, melody: true, reverb: 0.2),
        BGMPreset("upbeat.dancefloor", "踊ろう", .party, bpm: 130, key: 5, scale: .minor,
                  progression: [1, 6, 3, 7], sevenths: true, pad: true, tone: .pluck, drums: .house, arpeggio: true, pattern: 3, claps: true, melody: true, reverb: 0.22),
        BGMPreset("upbeat.birthday", "誕生日会", .party, bpm: 116, key: 10, scale: .major,
                  progression: [1, 4, 5, 1, 6, 2, 5, 1], tone: .piano, drums: .pop, swing: 0.15, pattern: 1, claps: true, sparkle: true, melody: true, reverb: 0.25),
        BGMPreset("upbeat.nightout", "夜遊び", .party, bpm: 120, key: 1, scale: .dorian,
                  progression: [1, 4, 1, 7], sevenths: true, tone: .bell, drums: .house, pattern: 2, organ: true, melody: true, reverb: 0.25),
        // バラエティ
        BGMPreset("upbeat.dotabata", "大騒ぎ", .variety, bpm: 140, key: 3, scale: .major,
                  progression: [1, 5, 1, 5, 4, 1, 5, 1], pad: false, tone: .pizzicato, drums: .march, pattern: 1, melody: true, reverb: 0.15),
        BGMPreset("upbeat.oshiete", "なになに?", .variety, bpm: 112, key: 8, scale: .major,
                  progression: [1, 2, 5, 1], pad: false, tone: .marimba, drums: .pop, swing: 0.25, pattern: 2, melody: true, reverb: 0.18),
        BGMPreset("upbeat.shippai", "しくじり", .variety, bpm: 96, key: 6, scale: .minor,
                  progression: [1, 4, 5, 1], pad: false, tone: .brass, drums: .march, swing: 0.3, pattern: 3, melody: true, reverb: 0.2),
        BGMPreset("upbeat.challengegame", "ゲーム対決", .variety, bpm: 132, key: 11, scale: .dorian,
                  progression: [1, 7, 6, 7], pad: false, tone: .pluck, drums: .pop, arpeggio: true, pattern: 0, claps: true, melody: true, reverb: 0.18),
        // かわいい
        BGMPreset("upbeat.wakuwaku", "お出かけ", .cute, bpm: 118, key: 2, scale: .pentatonic,
                  progression: [1, 2, 4, 5], tone: .bell, drums: .soft, arpeggio: true, pattern: 1, sparkle: true, melody: true, reverb: 0.32),
        BGMPreset("upbeat.pet", "ペットと遊ぶ", .cute, bpm: 108, key: 9, scale: .pentatonic,
                  progression: [4, 5, 1, 6], pad: false, tone: .marimba, drums: .soft, swing: 0.2, pattern: 2, claps: true, melody: true, reverb: 0.28),
        BGMPreset("upbeat.sweets", "おやつ時間", .cute, bpm: 100, key: 5, scale: .pentatonic,
                  progression: [4, 1, 5, 6], tone: .pizzicato, bass: true, drums: .pop, pattern: 3, sparkle: true, melody: true, reverb: 0.3),
        // 会社紹介 / 解説
        BGMPreset("upbeat.kaisha", "会社案内", .bright, bpm: 104, key: 0, scale: .major,
                  progression: [1, 4, 6, 5], widePad: true, tone: .piano, drums: .soft, arpeggio: true, pattern: 0, melody: false, reverb: 0.3),
        BGMPreset("upbeat.kaisetsu", "解説動画", .bright, bpm: 110, key: 7, scale: .major,
                  progression: [1, 3, 6, 4], sevenths: true, tone: .pluck, drums: .pop, pattern: 1, melody: false, reverb: 0.25),
        BGMPreset("upbeat.service", "サービス紹介", .bright, bpm: 100, key: 4, scale: .major,
                  progression: [1, 3, 4, 5, 1, 3, 2, 5], tone: .bell, drums: .soft, pattern: 2, liftToMajor: false, melody: false, reverb: 0.28),
    ]
}
