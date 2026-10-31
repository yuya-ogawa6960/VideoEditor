import Foundation

// Synthesized sound-effect recipes: UI, meme, game, sports, party.
// Each recipe = transient (2–10 ms click/noise) + body (detuned / FM) + tail (filtered noise or decaying partial).
// Layer gains sum below 1.0.
extension SoundRecipe {
    static let uiGame: [SoundRecipe] = [
        // MARK: UI
        SoundRecipe(id: "ui.switch", name: "画面切替", scene: .ui, duration: 0.4, layers: [
            SoundLayer(source: .noise, length: 0.006, gain: 0.15, attack: 0.001, decay: 0.005, sustain: 0, release: 0.002, highpass: 3000),
            SoundLayer(source: .noise, length: 0.25, gain: 0.25, attack: 0.03, decay: 0.15, sustain: 0.2, release: 0.08, filterStart: 800, filterEnd: 6000, highpass: 400),
            SoundLayer(source: .triangle, start: 0.05, length: 0.14, gain: 0.2, decay: 0.08, sustain: 0.3, release: 0.06, pitchStart: 660, pitchEnd: 990, filterStart: 1500, filterEnd: 5000),
            SoundLayer(source: .triangle, start: 0.05, length: 0.14, gain: 0.15, decay: 0.08, sustain: 0.3, release: 0.06, pitchStart: 664, pitchEnd: 996, filterStart: 1500, filterEnd: 5000, pan: 0.2),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.6), start: 0.12, length: 0.2, gain: 0.12, attack: 0.002, decay: 0.15, sustain: 0.05, release: 0.1, pitchStart: 1320)
        ], echoes: [(delay: 0.08, gain: 0.2)]),
        SoundRecipe(id: "ui.textIn", name: "文字登場", scene: .ui, duration: 0.5, layers: [
            SoundLayer(source: .noise, length: 0.18, gain: 0.2, attack: 0.05, decay: 0.1, sustain: 0.2, release: 0.04, filterStart: 2000, filterEnd: 9000, highpass: 1500),
            SoundLayer(source: .noise, start: 0.12, length: 0.004, gain: 0.15, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 4000),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.2), start: 0.12, length: 0.3, gain: 0.25, attack: 0.002, decay: 0.2, sustain: 0.05, release: 0.15, pitchStart: 1760, filterStart: 8000, filterEnd: 3000),
            SoundLayer(source: .triangle, start: 0.12, length: 0.25, gain: 0.15, attack: 0.002, decay: 0.15, sustain: 0.1, release: 0.12, pitchStart: 1766)
        ], echoes: [(delay: 0.07, gain: 0.25), (delay: 0.14, gain: 0.12)]),
        SoundRecipe(id: "ui.popup", name: "ポップアップ", scene: .ui, duration: 0.35, layers: [
            SoundLayer(source: .noise, length: 0.005, gain: 0.2, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, highpass: 2500),
            SoundLayer(source: .triangle, length: 0.12, gain: 0.35, attack: 0.002, decay: 0.08, sustain: 0.2, release: 0.05, pitchStart: 300, pitchEnd: 1100, filterStart: 1200, filterEnd: 6000),
            SoundLayer(source: .sine, length: 0.12, gain: 0.2, attack: 0.002, decay: 0.08, sustain: 0.2, release: 0.05, pitchStart: 150, pitchEnd: 550),
            SoundLayer(source: .fm(ratio: 1.41, index: 0.8), start: 0.06, length: 0.2, gain: 0.12, attack: 0.002, decay: 0.12, sustain: 0.05, release: 0.1, pitchStart: 2200)
        ], echoes: [(delay: 0.06, gain: 0.15)]),
        SoundRecipe(id: "ui.swipe", name: "シャッ", scene: .ui, duration: 0.35, layers: [
            SoundLayer(source: .noise, length: 0.004, gain: 0.12, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 5000, pan: -0.5),
            SoundLayer(source: .noise, length: 0.22, gain: 0.4, attack: 0.03, decay: 0.12, sustain: 0.3, release: 0.06, filterStart: 1200, filterEnd: 7000, highpass: 600, pan: -0.4),
            SoundLayer(source: .pinkNoise, start: 0.03, length: 0.25, gain: 0.3, attack: 0.03, decay: 0.12, sustain: 0.25, release: 0.1, filterStart: 3000, filterEnd: 900, pan: 0.4)
        ], echoes: [(delay: 0.05, gain: 0.12)]),
        SoundRecipe(id: "ui.confirm", name: "決定音", scene: .ui, duration: 0.6, layers: [
            SoundLayer(source: .noise, length: 0.004, gain: 0.12, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 3000),
            SoundLayer(source: .fm(ratio: 2.0, index: 0.8), length: 0.12, gain: 0.25, decay: 0.08, sustain: 0.3, release: 0.06, pitchStart: 1046.5, filterStart: 6000, filterEnd: 2500),
            SoundLayer(source: .fm(ratio: 2.0, index: 0.8), start: 0.09, length: 0.35, gain: 0.25, decay: 0.2, sustain: 0.2, release: 0.18, pitchStart: 1568, filterStart: 7000, filterEnd: 2500),
            SoundLayer(source: .triangle, start: 0.09, length: 0.35, gain: 0.15, decay: 0.2, sustain: 0.2, release: 0.18, pitchStart: 1574, pan: 0.2),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.5), start: 0.09, length: 0.45, gain: 0.08, attack: 0.002, decay: 0.3, sustain: 0.05, release: 0.2, pitchStart: 3136)
        ], echoes: [(delay: 0.09, gain: 0.18)]),
        SoundRecipe(id: "ui.cancel", name: "キャンセル音", scene: .ui, duration: 0.45, layers: [
            SoundLayer(source: .noise, length: 0.005, gain: 0.12, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, filterStart: 3000),
            SoundLayer(source: .triangle, length: 0.1, gain: 0.3, decay: 0.07, sustain: 0.4, release: 0.04, pitchStart: 784, filterStart: 4000, filterEnd: 1500),
            SoundLayer(source: .triangle, start: 0.09, length: 0.22, gain: 0.3, decay: 0.12, sustain: 0.3, release: 0.1, pitchStart: 523, pitchEnd: 494, filterStart: 3000, filterEnd: 800),
            SoundLayer(source: .sine, start: 0.09, length: 0.25, gain: 0.15, decay: 0.12, sustain: 0.2, release: 0.1, pitchStart: 262, pitchEnd: 247)
        ], echoes: [(delay: 0.07, gain: 0.12)]),
        // MARK: Meme
        SoundRecipe(id: "meme.doya", name: "ドヤ顔", scene: .meme, duration: 1.1, layers: [
            SoundLayer(source: .noise, start: 0.15, length: 0.008, gain: 0.15, attack: 0.001, decay: 0.006, sustain: 0, release: 0.002, highpass: 4000),
            SoundLayer(source: .saw, length: 0.12, gain: 0.2, decay: 0.08, sustain: 0.5, release: 0.04, pitchStart: 392, filterStart: 2500, filterEnd: 1200),
            SoundLayer(source: .saw, start: 0.15, length: 0.65, gain: 0.22, attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.25, pitchStart: 523, filterStart: 4000, filterEnd: 1000, vibratoRate: 6, vibratoDepth: 0.02),
            SoundLayer(source: .saw, start: 0.15, length: 0.65, gain: 0.18, attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.25, pitchStart: 527, filterStart: 4000, filterEnd: 1000, vibratoRate: 5.5, vibratoDepth: 0.02, pan: 0.3),
            SoundLayer(source: .pinkNoise, start: 0.15, length: 0.7, gain: 0.08, attack: 0.01, decay: 0.3, sustain: 0.2, release: 0.3, filterStart: 6000, filterEnd: 1500, highpass: 2000)
        ], echoes: [(delay: 0.12, gain: 0.18)]),
        SoundRecipe(id: "meme.zukko", name: "ズコー", scene: .meme, duration: 1.3, layers: [
            SoundLayer(source: .noise, length: 0.01, gain: 0.25, attack: 0.001, decay: 0.008, sustain: 0, release: 0.002, filterStart: 3000),
            SoundLayer(source: .pinkNoise, length: 0.2, gain: 0.2, attack: 0.002, decay: 0.12, sustain: 0.1, release: 0.08, filterStart: 1500, filterEnd: 200),
            SoundLayer(source: .saw, start: 0.05, length: 0.95, gain: 0.25, attack: 0.02, decay: 0.3, sustain: 0.6, release: 0.25, pitchStart: 600, pitchEnd: 90, filterStart: 3000, filterEnd: 400, vibratoRate: 7, vibratoDepth: 0.03),
            SoundLayer(source: .sine, start: 0.05, length: 0.95, gain: 0.25, attack: 0.02, decay: 0.3, sustain: 0.6, release: 0.25, pitchStart: 300, pitchEnd: 45)
        ]),
        SoundRecipe(id: "meme.gaan", name: "ガーン", scene: .meme, duration: 2.2, layers: [
            SoundLayer(source: .noise, length: 0.008, gain: 0.2, attack: 0.001, decay: 0.006, sustain: 0, release: 0.002, filterStart: 5000),
            SoundLayer(source: .fm(ratio: 1.41, index: 4), length: 2.0, gain: 0.3, attack: 0.002, decay: 0.6, sustain: 0.3, release: 1.1, pitchStart: 110, filterStart: 5000, filterEnd: 600, drive: 0.3),
            SoundLayer(source: .saw, length: 1.7, gain: 0.15, attack: 0.002, decay: 0.5, sustain: 0.3, release: 0.9, pitchStart: 116.5, filterStart: 2500, filterEnd: 300),
            SoundLayer(source: .sine, length: 1.6, gain: 0.2, attack: 0.002, decay: 0.5, sustain: 0.3, release: 0.9, pitchStart: 55, pitchEnd: 50),
            SoundLayer(source: .pinkNoise, length: 1.4, gain: 0.08, attack: 0.002, decay: 0.5, sustain: 0.1, release: 0.8, filterStart: 3000, filterEnd: 400)
        ], echoes: [(delay: 0.18, gain: 0.22), (delay: 0.36, gain: 0.1)], reverb: 0.3, reverbTime: 2.0),
        // MARK: Game (deliberate 8-bit)
        SoundRecipe(id: "game.coin", name: "コイン獲得", scene: .game, duration: 0.7, layers: [
            SoundLayer(source: .noise, length: 0.003, gain: 0.1, attack: 0.001, decay: 0.002, sustain: 0, release: 0.001, highpass: 6000),
            SoundLayer(source: .square, length: 0.07, gain: 0.25, attack: 0.001, decay: 0.05, sustain: 0.8, release: 0.01, pitchStart: 988),
            SoundLayer(source: .square, start: 0.07, length: 0.45, gain: 0.25, attack: 0.001, decay: 0.3, sustain: 0.4, release: 0.12, pitchStart: 1319, filterStart: 9000, filterEnd: 3000),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.6), start: 0.07, length: 0.5, gain: 0.1, decay: 0.3, sustain: 0.1, release: 0.15, pitchStart: 2638)
        ], echoes: [(delay: 0.1, gain: 0.15)]),
        SoundRecipe(id: "game.levelUp", name: "レベルUP", scene: .game, duration: 1.1, layers: [
            SoundLayer(source: .square, length: 0.06, gain: 0.2, attack: 0.001, decay: 0.04, sustain: 0.8, release: 0.01, pitchStart: 523, filterStart: 6000),
            SoundLayer(source: .square, start: 0.07, length: 0.06, gain: 0.2, attack: 0.001, decay: 0.04, sustain: 0.8, release: 0.01, pitchStart: 659, filterStart: 6000),
            SoundLayer(source: .square, start: 0.14, length: 0.06, gain: 0.2, attack: 0.001, decay: 0.04, sustain: 0.8, release: 0.01, pitchStart: 784, filterStart: 6000),
            SoundLayer(source: .square, start: 0.21, length: 0.6, gain: 0.22, attack: 0.001, decay: 0.2, sustain: 0.6, release: 0.2, pitchStart: 1046, filterStart: 7000, filterEnd: 2500, vibratoRate: 8, vibratoDepth: 0.015),
            SoundLayer(source: .triangle, start: 0.21, length: 0.6, gain: 0.15, decay: 0.2, sustain: 0.6, release: 0.2, pitchStart: 523)
        ], echoes: [(delay: 0.12, gain: 0.15)]),
        SoundRecipe(id: "game.jump8bit", name: "ピョン", scene: .game, duration: 0.35, layers: [
            SoundLayer(source: .noise, length: 0.004, gain: 0.1, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 3000),
            SoundLayer(source: .square, length: 0.22, gain: 0.3, attack: 0.001, decay: 0.15, sustain: 0.4, release: 0.05, pitchStart: 220, pitchEnd: 880, filterStart: 2000, filterEnd: 7000),
            SoundLayer(source: .triangle, length: 0.22, gain: 0.2, attack: 0.001, decay: 0.12, sustain: 0.3, release: 0.06, pitchStart: 110, pitchEnd: 440)
        ], echoes: [(delay: 0.06, gain: 0.1)]),
        SoundRecipe(id: "game.powerUp8bit", name: "パワーUP", scene: .game, duration: 1.0, layers: [
            SoundLayer(source: .square, length: 0.05, gain: 0.2, attack: 0.001, decay: 0.03, sustain: 0.9, release: 0.005, pitchStart: 392, pitchEnd: 1568, repeats: 3, repeatGap: 0.27),
            SoundLayer(source: .square, start: 0.025, length: 0.05, gain: 0.15, attack: 0.001, decay: 0.03, sustain: 0.9, release: 0.005, pitchStart: 523, pitchEnd: 2093, repeats: 3, repeatGap: 0.27),
            SoundLayer(source: .triangle, length: 0.85, gain: 0.2, decay: 0.3, sustain: 0.7, release: 0.12, pitchStart: 196, pitchEnd: 784, vibratoRate: 12, vibratoDepth: 0.03),
            SoundLayer(source: .noise, length: 0.85, gain: 0.05, attack: 0.2, decay: 0.3, sustain: 0.3, release: 0.12, filterStart: 2000, filterEnd: 9000, highpass: 1500)
        ], echoes: [(delay: 0.1, gain: 0.12)]),
        // MARK: Sports
        SoundRecipe(id: "sports.whistle", name: "審判の笛", scene: .sports, duration: 1.0, layers: [
            SoundLayer(source: .noise, length: 0.01, gain: 0.12, attack: 0.002, decay: 0.008, sustain: 0, release: 0.002, highpass: 3000),
            SoundLayer(source: .fm(ratio: 1.0, index: 0.4), length: 0.75, gain: 0.3, attack: 0.015, decay: 0.1, sustain: 0.85, release: 0.08, pitchStart: 2900, pitchEnd: 2850, vibratoRate: 32, vibratoDepth: 0.04),
            SoundLayer(source: .fm(ratio: 2.0, index: 0.3), length: 0.75, gain: 0.1, attack: 0.015, decay: 0.1, sustain: 0.85, release: 0.08, pitchStart: 2915, vibratoRate: 30, vibratoDepth: 0.04),
            SoundLayer(source: .noise, length: 0.78, gain: 0.12, attack: 0.015, decay: 0.1, sustain: 0.8, release: 0.1, filterStart: 6000, filterEnd: 4500, highpass: 2500)
        ], echoes: [(delay: 0.11, gain: 0.18), (delay: 0.25, gain: 0.08)], reverb: 0.3, reverbTime: 1.6),
        SoundRecipe(id: "sports.bigCheer", name: "大歓声", scene: .sports, duration: 3.0, layers: [
            SoundLayer(source: .pinkNoise, length: 2.9, gain: 0.3, attack: 0.5, decay: 0.8, sustain: 0.7, release: 1.0, filterStart: 1200, filterEnd: 3500, highpass: 200, pan: -0.3),
            SoundLayer(source: .pinkNoise, start: 0.2, length: 2.7, gain: 0.28, attack: 0.6, decay: 0.6, sustain: 0.6, release: 0.9, filterStart: 1800, filterEnd: 2500, highpass: 300, pan: 0.3),
            SoundLayer(source: .saw, start: 0.3, length: 2.2, gain: 0.04, attack: 0.5, decay: 0.5, sustain: 0.6, release: 0.8, pitchStart: 330, filterStart: 900, vibratoRate: 5, vibratoDepth: 0.06, pan: -0.2),
            SoundLayer(source: .saw, start: 0.35, length: 2.2, gain: 0.04, attack: 0.5, decay: 0.5, sustain: 0.6, release: 0.8, pitchStart: 415, filterStart: 1100, vibratoRate: 4.3, vibratoDepth: 0.07, pan: 0.2),
            SoundLayer(source: .noise, start: 0.4, length: 2.2, gain: 0.08, attack: 0.6, decay: 0.5, sustain: 0.5, release: 0.9, highpass: 4000)
        ], echoes: [(delay: 0.09, gain: 0.2)], randomSeed: 7, reverb: 0.35, reverbTime: 2.2),
        SoundRecipe(id: "sports.endBuzzer", name: "試合終了", scene: .sports, duration: 1.5, layers: [
            SoundLayer(source: .noise, length: 0.006, gain: 0.12, attack: 0.001, decay: 0.005, sustain: 0, release: 0.001, filterStart: 4000),
            SoundLayer(source: .square, length: 1.2, gain: 0.2, attack: 0.005, decay: 0.1, sustain: 0.9, release: 0.1, pitchStart: 220, filterStart: 3000, filterEnd: 2000, drive: 0.25),
            SoundLayer(source: .saw, length: 1.2, gain: 0.2, attack: 0.005, decay: 0.1, sustain: 0.9, release: 0.1, pitchStart: 223, filterStart: 3000, filterEnd: 2000),
            SoundLayer(source: .saw, length: 1.2, gain: 0.1, attack: 0.005, decay: 0.1, sustain: 0.9, release: 0.1, pitchStart: 441, filterStart: 3500),
            SoundLayer(source: .pinkNoise, start: 1.15, length: 0.3, gain: 0.06, attack: 0.002, decay: 0.15, sustain: 0.1, release: 0.15, filterStart: 1500, filterEnd: 400)
        ], echoes: [(delay: 0.15, gain: 0.2), (delay: 0.3, gain: 0.08)]),
        // MARK: Party
        SoundRecipe(id: "party.popper", name: "パーン!", scene: .party, duration: 1.3, layers: [
            SoundLayer(source: .noise, length: 0.01, gain: 0.35, attack: 0.001, decay: 0.008, sustain: 0, release: 0.002, drive: 0.4),
            SoundLayer(source: .noise, length: 0.12, gain: 0.25, attack: 0.001, decay: 0.08, sustain: 0.05, release: 0.04, filterStart: 8000, filterEnd: 1500),
            SoundLayer(source: .sine, length: 0.1, gain: 0.2, attack: 0.001, decay: 0.07, sustain: 0, release: 0.03, pitchStart: 180, pitchEnd: 60),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.0), start: 0.1, length: 0.05, gain: 0.08, attack: 0.001, decay: 0.04, sustain: 0, release: 0.03, pitchStart: 3520, repeats: 8, repeatGap: 0.09, pan: -0.3),
            SoundLayer(source: .fm(ratio: 1.41, index: 1.0), start: 0.14, length: 0.05, gain: 0.07, attack: 0.001, decay: 0.04, sustain: 0, release: 0.03, pitchStart: 4698, repeats: 7, repeatGap: 0.11, pan: 0.3)
        ], echoes: [(delay: 0.1, gain: 0.22), (delay: 0.22, gain: 0.1)], randomSeed: 3),
        SoundRecipe(id: "party.clink", name: "カチン", scene: .party, duration: 1.2, layers: [
            SoundLayer(source: .noise, length: 0.003, gain: 0.15, attack: 0.001, decay: 0.002, sustain: 0, release: 0.001, highpass: 5000),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.5), length: 0.8, gain: 0.25, attack: 0.001, decay: 0.4, sustain: 0.05, release: 0.35, pitchStart: 2637, pan: -0.15),
            SoundLayer(source: .sine, length: 0.6, gain: 0.12, attack: 0.001, decay: 0.3, sustain: 0.05, release: 0.25, pitchStart: 6280, pan: -0.15),
            SoundLayer(source: .noise, start: 0.11, length: 0.003, gain: 0.12, attack: 0.001, decay: 0.002, sustain: 0, release: 0.001, highpass: 5000, pan: 0.15),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.3), start: 0.11, length: 0.8, gain: 0.22, attack: 0.001, decay: 0.4, sustain: 0.05, release: 0.35, pitchStart: 2793, pan: 0.15)
        ], echoes: [(delay: 0.07, gain: 0.15), (delay: 0.15, gain: 0.07)], reverb: 0.2, reverbTime: 1.0)
    ]
}
