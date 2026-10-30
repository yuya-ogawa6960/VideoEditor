import Foundation

// Horror / mystery / life sound-effect recipes (data only).
// Layered for depth: sub + dissonant mid body + noise texture + echo tails.
extension SoundRecipe {
    static let moodLife: [SoundRecipe] = [
        // MARK: Horror
        SoundRecipe(id: "horror.subboom", name: "低い衝撃", scene: .horror, duration: 3.5, layers: [
            SoundLayer(source: .sine, length: 3.2, gain: 0.95, attack: 0.003, decay: 0.8, sustain: 0.35, release: 2.0, pitchStart: 60, pitchEnd: 30),
            SoundLayer(source: .triangle, length: 1.6, gain: 0.35, attack: 0.003, decay: 0.5, sustain: 0.3, release: 0.9, pitchStart: 92, pitchEnd: 46, filterStart: 600, filterEnd: 150),
            SoundLayer(source: .pinkNoise, length: 0.6, gain: 0.55, attack: 0.002, decay: 0.25, sustain: 0.15, release: 0.3, pitchStart: 100, filterStart: 1400, filterEnd: 120),
            SoundLayer(source: .brownNoise, start: 0.1, length: 3.0, gain: 0.18, attack: 0.2, decay: 0.8, sustain: 0.3, release: 1.8, pitchStart: 100, filterStart: 300, filterEnd: 90)
        ], echoes: [(delay: 0.31, gain: 0.3), (delay: 0.67, gain: 0.18), (delay: 1.1, gain: 0.08)], randomSeed: 2, reverb: 0.45, reverbTime: 3.5),
        SoundRecipe(id: "horror.creak", name: "きしむ音", scene: .horror, duration: 2.2, layers: [
            SoundLayer(source: .fm(ratio: 1.41, index: 3.5), length: 1.8, gain: 0.5, attack: 0.08, decay: 0.3, sustain: 0.7, release: 0.35, pitchStart: 180, pitchEnd: 130, filterStart: 2600, filterEnd: 1100, highpass: 120, vibratoRate: 9, vibratoDepth: 0.06, pan: -0.15),
            SoundLayer(source: .saw, start: 0.05, length: 1.7, gain: 0.28, attack: 0.1, decay: 0.3, sustain: 0.6, release: 0.35, pitchStart: 191, pitchEnd: 137, filterStart: 1800, filterEnd: 700, highpass: 100, vibratoRate: 13, vibratoDepth: 0.05, pan: 0.15),
            SoundLayer(source: .noise, length: 0.02, gain: 0.25, attack: 0.001, decay: 0.015, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 3000, highpass: 800, repeats: 14, repeatGap: 0.11),
            SoundLayer(source: .sine, length: 1.8, gain: 0.25, attack: 0.2, decay: 0.4, sustain: 0.5, release: 0.6, pitchStart: 48, pitchEnd: 42)
        ], echoes: [(delay: 0.22, gain: 0.25), (delay: 0.5, gain: 0.12)], randomSeed: 4, reverb: 0.3, reverbTime: 1.8),
        SoundRecipe(id: "horror.breath", name: "不気味な息", scene: .horror, duration: 3.2, layers: [
            SoundLayer(source: .pinkNoise, length: 1.2, gain: 0.55, attack: 0.55, decay: 0.3, sustain: 0.5, release: 0.4, pitchStart: 100, filterStart: 450, filterEnd: 1500, highpass: 180, pan: -0.2),
            SoundLayer(source: .pinkNoise, start: 1.4, length: 1.5, gain: 0.5, attack: 0.3, decay: 0.4, sustain: 0.4, release: 0.7, pitchStart: 100, filterStart: 1400, filterEnd: 350, highpass: 150, pan: 0.2),
            SoundLayer(source: .sine, length: 3.0, gain: 0.2, attack: 0.8, decay: 0.5, sustain: 0.5, release: 1.0, pitchStart: 38, vibratoRate: 0.5, vibratoDepth: 0.05),
            SoundLayer(source: .triangle, start: 1.4, length: 1.4, gain: 0.06, attack: 0.3, decay: 0.4, sustain: 0.4, release: 0.6, pitchStart: 233, pitchEnd: 220, filterStart: 700, vibratoRate: 5, vibratoDepth: 0.02)
        ], echoes: [(delay: 0.4, gain: 0.2)], randomSeed: 7, reverb: 0.35, reverbTime: 2.5),
        SoundRecipe(id: "horror.heartbeat", name: "ゆっくり鼓動", scene: .horror, duration: 3.6, layers: [
            SoundLayer(source: .sine, length: 0.2, gain: 0.95, attack: 0.003, decay: 0.13, sustain: 0.1, release: 0.06, pitchStart: 62, pitchEnd: 38, repeats: 3, repeatGap: 0.9),
            SoundLayer(source: .sine, start: 0.26, length: 0.18, gain: 0.7, attack: 0.003, decay: 0.11, sustain: 0.1, release: 0.06, pitchStart: 52, pitchEnd: 34, repeats: 3, repeatGap: 0.92),
            SoundLayer(source: .pinkNoise, length: 0.06, gain: 0.3, attack: 0.002, decay: 0.04, sustain: 0.1, release: 0.02, pitchStart: 100, filterStart: 300, repeats: 3, repeatGap: 1.04),
            SoundLayer(source: .pinkNoise, length: 3.4, gain: 0.08, attack: 0.5, decay: 0.5, sustain: 0.5, release: 1.0, pitchStart: 100, filterStart: 200)
        ], echoes: [(delay: 0.18, gain: 0.15)], randomSeed: 6, reverb: 0.2, reverbTime: 1.5),
        SoundRecipe(id: "horror.stinger", name: "ホラーの一撃", scene: .horror, duration: 3.6, layers: [
            SoundLayer(source: .sine, length: 3.0, gain: 0.85, attack: 0.002, decay: 0.7, sustain: 0.35, release: 1.8, pitchStart: 55, pitchEnd: 32),
            SoundLayer(source: .saw, length: 2.6, gain: 0.32, attack: 0.002, decay: 0.5, sustain: 0.5, release: 1.4, pitchStart: 311, filterStart: 5000, filterEnd: 700, vibratoRate: 6, vibratoDepth: 0.015, pan: -0.35, drive: 0.35),
            SoundLayer(source: .saw, length: 2.6, gain: 0.32, attack: 0.002, decay: 0.5, sustain: 0.5, release: 1.4, pitchStart: 330, filterStart: 5000, filterEnd: 700, vibratoRate: 7, vibratoDepth: 0.015, pan: 0.35, drive: 0.35),
            SoundLayer(source: .square, length: 2.2, gain: 0.18, attack: 0.002, decay: 0.4, sustain: 0.4, release: 1.2, pitchStart: 466, filterStart: 3000, filterEnd: 500),
            SoundLayer(source: .fm(ratio: 2.76, index: 4), length: 1.8, gain: 0.2, attack: 0.002, decay: 0.6, sustain: 0.2, release: 1.0, pitchStart: 622, pitchEnd: 587, highpass: 300),
            SoundLayer(source: .noise, length: 0.4, gain: 0.5, attack: 0.001, decay: 0.2, sustain: 0.1, release: 0.15, pitchStart: 100, filterStart: 7000, filterEnd: 700)
        ], echoes: [(delay: 0.27, gain: 0.35), (delay: 0.61, gain: 0.2), (delay: 1.05, gain: 0.1)], randomSeed: 3, reverb: 0.5, reverbTime: 4.0),
        SoundRecipe(id: "horror.musicbox", name: "オルゴール", scene: .horror, duration: 4.4, layers: [
            SoundLayer(source: .fm(ratio: 5.4, index: 0.6), length: 0.8, gain: 0.45, attack: 0.002, decay: 0.5, sustain: 0.1, release: 0.3, pitchStart: 1318, vibratoRate: 4, vibratoDepth: 0.008, pan: -0.2),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.6), start: 0.55, length: 0.8, gain: 0.45, attack: 0.002, decay: 0.5, sustain: 0.1, release: 0.3, pitchStart: 1245, vibratoRate: 4, vibratoDepth: 0.01, pan: 0.1),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.6), start: 1.15, length: 0.8, gain: 0.45, attack: 0.002, decay: 0.5, sustain: 0.1, release: 0.3, pitchStart: 1046, vibratoRate: 3.5, vibratoDepth: 0.012, pan: -0.1),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.6), start: 1.8, length: 0.8, gain: 0.45, attack: 0.002, decay: 0.5, sustain: 0.1, release: 0.3, pitchStart: 988, vibratoRate: 3, vibratoDepth: 0.014, pan: 0.2),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.6), start: 2.6, length: 1.6, gain: 0.45, attack: 0.002, decay: 1.0, sustain: 0.1, release: 0.6, pitchStart: 830, pitchEnd: 800, vibratoRate: 2.5, vibratoDepth: 0.018),
            SoundLayer(source: .sine, start: 2.6, length: 1.6, gain: 0.3, attack: 0.002, decay: 1.0, sustain: 0.1, release: 0.6, pitchStart: 879, pitchEnd: 850),
            SoundLayer(source: .sine, length: 4.2, gain: 0.15, attack: 1.0, decay: 0.5, sustain: 0.5, release: 1.2, pitchStart: 41)
        ], echoes: [(delay: 0.33, gain: 0.35), (delay: 0.7, gain: 0.2), (delay: 1.2, gain: 0.1)], reverb: 0.45, reverbTime: 3.0),

        // MARK: Mystery
        SoundRecipe(id: "mystery.clock", name: "時計の針", scene: .mystery, duration: 3.2, layers: [
            SoundLayer(source: .noise, length: 0.03, gain: 0.55, attack: 0.001, decay: 0.02, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 6500, highpass: 2500, repeats: 3, repeatGap: 0.97, pan: -0.15),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.5), length: 0.05, gain: 0.25, attack: 0.001, decay: 0.03, sustain: 0.1, release: 0.02, pitchStart: 2100, repeats: 3, repeatGap: 0.95, pan: -0.15),
            SoundLayer(source: .noise, start: 0.5, length: 0.03, gain: 0.4, attack: 0.001, decay: 0.02, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 4000, highpass: 1500, repeats: 3, repeatGap: 0.97, pan: 0.15),
            SoundLayer(source: .sine, length: 3.0, gain: 0.12, attack: 0.6, decay: 0.5, sustain: 0.5, release: 0.8, pitchStart: 46)
        ], echoes: [(delay: 0.12, gain: 0.2)], randomSeed: 11, reverb: 0.25, reverbTime: 1.5),
        SoundRecipe(id: "mystery.sparkle", name: "魔法のきらめき", scene: .mystery, duration: 2.4, layers: [
            SoundLayer(source: .fm(ratio: 2.76, index: 1.2), length: 0.3, gain: 0.35, attack: 0.002, decay: 0.2, sustain: 0.15, release: 0.1, pitchStart: 1760, pitchEnd: 2640, repeats: 7, repeatGap: 0.07, pan: -0.35),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.8), start: 0.05, length: 0.3, gain: 0.3, attack: 0.002, decay: 0.2, sustain: 0.15, release: 0.1, pitchStart: 2349, pitchEnd: 3520, repeats: 7, repeatGap: 0.075, pan: 0.35),
            SoundLayer(source: .pinkNoise, length: 1.8, gain: 0.14, attack: 0.15, decay: 0.5, sustain: 0.3, release: 0.8, pitchStart: 100, highpass: 6000),
            SoundLayer(source: .sine, start: 0.5, length: 1.7, gain: 0.25, attack: 0.05, decay: 0.6, sustain: 0.3, release: 0.9, pitchStart: 1760, vibratoRate: 6, vibratoDepth: 0.006)
        ], echoes: [(delay: 0.19, gain: 0.35), (delay: 0.43, gain: 0.18)], randomSeed: 5, reverb: 0.4, reverbTime: 2.5),
        SoundRecipe(id: "mystery.question", name: "なぞの音", scene: .mystery, duration: 2.4, layers: [
            SoundLayer(source: .fm(ratio: 2.0, index: 1.5), length: 0.35, gain: 0.45, attack: 0.005, decay: 0.15, sustain: 0.5, release: 0.1, pitchStart: 392, pan: -0.15),
            SoundLayer(source: .fm(ratio: 2.0, index: 1.5), start: 0.35, length: 1.3, gain: 0.45, attack: 0.005, decay: 0.3, sustain: 0.5, release: 0.6, pitchStart: 466, pitchEnd: 554, vibratoRate: 6, vibratoDepth: 0.015, pan: 0.15),
            SoundLayer(source: .triangle, start: 0.35, length: 1.3, gain: 0.25, attack: 0.01, decay: 0.3, sustain: 0.5, release: 0.6, pitchStart: 659, pitchEnd: 784, filterStart: 2000),
            SoundLayer(source: .sine, length: 2.0, gain: 0.35, attack: 0.005, decay: 0.5, sustain: 0.3, release: 1.0, pitchStart: 49),
            SoundLayer(source: .pinkNoise, length: 0.25, gain: 0.2, attack: 0.002, decay: 0.12, sustain: 0.1, release: 0.1, pitchStart: 100, filterStart: 2500, filterEnd: 400)
        ], echoes: [(delay: 0.24, gain: 0.3), (delay: 0.55, gain: 0.15)], reverb: 0.35, reverbTime: 2.5),
        SoundRecipe(id: "mystery.solved", name: "謎解き成功", scene: .mystery, duration: 2.6, layers: [
            SoundLayer(source: .fm(ratio: 2.0, index: 1.0), length: 0.16, gain: 0.45, attack: 0.003, decay: 0.08, sustain: 0.5, release: 0.06, pitchStart: 523),
            SoundLayer(source: .fm(ratio: 2.0, index: 1.0), start: 0.12, length: 0.16, gain: 0.45, attack: 0.003, decay: 0.08, sustain: 0.5, release: 0.06, pitchStart: 659),
            SoundLayer(source: .fm(ratio: 2.0, index: 1.0), start: 0.24, length: 0.16, gain: 0.45, attack: 0.003, decay: 0.08, sustain: 0.5, release: 0.06, pitchStart: 784),
            SoundLayer(source: .triangle, start: 0.36, length: 1.8, gain: 0.4, attack: 0.003, decay: 0.5, sustain: 0.4, release: 1.0, pitchStart: 1046, vibratoRate: 5, vibratoDepth: 0.008, pan: -0.2),
            SoundLayer(source: .sine, start: 0.36, length: 1.8, gain: 0.3, attack: 0.003, decay: 0.5, sustain: 0.4, release: 1.0, pitchStart: 1318, pan: 0.2),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.5), start: 0.36, length: 1.2, gain: 0.15, attack: 0.002, decay: 0.6, sustain: 0.1, release: 0.6, pitchStart: 2093),
            SoundLayer(source: .sine, start: 0.36, length: 1.6, gain: 0.3, attack: 0.01, decay: 0.5, sustain: 0.3, release: 0.9, pitchStart: 65)
        ], echoes: [(delay: 0.17, gain: 0.3), (delay: 0.4, gain: 0.15)], reverb: 0.3, reverbTime: 2.0),

        // MARK: Life
        SoundRecipe(id: "life.schoolchime", name: "学校のチャイム", scene: .life, duration: 6.0, layers: [
            SoundLayer(source: .fm(ratio: 2.76, index: 1.4), length: 2.2, gain: 0.45, attack: 0.002, decay: 0.8, sustain: 0.2, release: 1.2, pitchStart: 659),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.4), start: 0.9, length: 2.2, gain: 0.45, attack: 0.002, decay: 0.8, sustain: 0.2, release: 1.2, pitchStart: 523),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.4), start: 1.8, length: 2.2, gain: 0.45, attack: 0.002, decay: 0.8, sustain: 0.2, release: 1.2, pitchStart: 587),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.4), start: 2.7, length: 3.1, gain: 0.45, attack: 0.002, decay: 1.2, sustain: 0.2, release: 1.6, pitchStart: 392),
            SoundLayer(source: .sine, length: 0.9, gain: 0.2, attack: 0.002, decay: 0.6, sustain: 0.2, release: 0.3, pitchStart: 1318, repeats: 4, repeatGap: 0.0, pan: 0.2)
        ], echoes: [(delay: 0.35, gain: 0.3), (delay: 0.8, gain: 0.15)], reverb: 0.35, reverbTime: 2.5),
        SoundRecipe(id: "life.applause", name: "拍手", scene: .life, duration: 3.0, layers: [
            SoundLayer(source: .noise, length: 0.035, gain: 0.45, attack: 0.001, decay: 0.025, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 3200, highpass: 700, repeats: 34, repeatGap: 0.047, pan: -0.55),
            SoundLayer(source: .noise, start: 0.021, length: 0.035, gain: 0.4, attack: 0.001, decay: 0.025, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 2600, highpass: 500, repeats: 30, repeatGap: 0.059, pan: 0.5),
            SoundLayer(source: .noise, start: 0.037, length: 0.03, gain: 0.35, attack: 0.001, decay: 0.02, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 4500, highpass: 1000, repeats: 28, repeatGap: 0.067, pan: -0.1),
            SoundLayer(source: .noise, start: 0.011, length: 0.04, gain: 0.35, attack: 0.001, decay: 0.03, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 2200, highpass: 400, repeats: 24, repeatGap: 0.073, pan: 0.2),
            SoundLayer(source: .pinkNoise, length: 2.9, gain: 0.3, attack: 0.15, decay: 0.5, sustain: 0.7, release: 0.9, pitchStart: 100, filterStart: 4500, highpass: 350)
        ], echoes: [(delay: 0.09, gain: 0.2)], randomSeed: 21, reverb: 0.3, reverbTime: 1.6),
        SoundRecipe(id: "life.startpan", name: "運動会のパン", scene: .life, duration: 2.2, layers: [
            SoundLayer(source: .noise, length: 0.12, gain: 0.95, attack: 0.001, decay: 0.06, sustain: 0.1, release: 0.05, pitchStart: 100, filterStart: 9000, filterEnd: 2000, highpass: 300),
            SoundLayer(source: .sine, length: 0.25, gain: 0.55, attack: 0.001, decay: 0.12, sustain: 0.1, release: 0.1, pitchStart: 140, pitchEnd: 45),
            SoundLayer(source: .pinkNoise, start: 0.05, length: 1.6, gain: 0.15, attack: 0.05, decay: 0.5, sustain: 0.2, release: 1.0, pitchStart: 100, filterStart: 1500, filterEnd: 300)
        ], echoes: [(delay: 0.21, gain: 0.4), (delay: 0.48, gain: 0.22), (delay: 0.9, gain: 0.1)], randomSeed: 9, reverb: 0.4, reverbTime: 2.2),
        SoundRecipe(id: "life.cheer", name: "応援の歓声", scene: .life, duration: 3.2, layers: [
            SoundLayer(source: .pinkNoise, length: 3.0, gain: 0.5, attack: 0.3, decay: 0.6, sustain: 0.7, release: 0.9, pitchStart: 100, filterStart: 1100, filterEnd: 2600, highpass: 250),
            SoundLayer(source: .saw, length: 2.5, gain: 0.08, attack: 0.3, decay: 0.5, sustain: 0.6, release: 0.7, pitchStart: 330, pitchEnd: 392, filterStart: 1400, vibratoRate: 7, vibratoDepth: 0.05, pan: -0.4),
            SoundLayer(source: .saw, start: 0.1, length: 2.5, gain: 0.08, attack: 0.3, decay: 0.5, sustain: 0.6, release: 0.7, pitchStart: 446, pitchEnd: 528, filterStart: 1700, vibratoRate: 6, vibratoDepth: 0.06, pan: 0.4),
            SoundLayer(source: .triangle, start: 0.2, length: 2.3, gain: 0.07, attack: 0.3, decay: 0.5, sustain: 0.6, release: 0.7, pitchStart: 587, pitchEnd: 659, filterStart: 2000, vibratoRate: 8, vibratoDepth: 0.05),
            SoundLayer(source: .noise, start: 0.2, length: 0.035, gain: 0.25, attack: 0.001, decay: 0.025, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 3000, highpass: 600, repeats: 40, repeatGap: 0.031, pan: 0.3),
            SoundLayer(source: .noise, start: 0.23, length: 0.035, gain: 0.22, attack: 0.001, decay: 0.025, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 2500, highpass: 500, repeats: 36, repeatGap: 0.043, pan: -0.35)
        ], echoes: [(delay: 0.11, gain: 0.2)], randomSeed: 13, reverb: 0.3, reverbTime: 1.8),
        SoundRecipe(id: "life.rattle", name: "ガラガラ", scene: .life, duration: 1.6, layers: [
            SoundLayer(source: .noise, length: 0.05, gain: 0.45, attack: 0.002, decay: 0.035, sustain: 0.2, release: 0.02, pitchStart: 100, filterStart: 9000, highpass: 3000, repeats: 12, repeatGap: 0.06, pan: -0.2),
            SoundLayer(source: .noise, start: 0.03, length: 0.04, gain: 0.35, attack: 0.002, decay: 0.03, sustain: 0.2, release: 0.02, pitchStart: 100, filterStart: 7000, highpass: 2200, repeats: 12, repeatGap: 0.067, pan: 0.2),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.0), start: 0.02, length: 0.06, gain: 0.15, attack: 0.001, decay: 0.04, sustain: 0.1, release: 0.02, pitchStart: 2800, pitchEnd: 2500, repeats: 12, repeatGap: 0.07)
        ], randomSeed: 17, reverb: 0.15, reverbTime: 0.8),
        SoundRecipe(id: "life.orin", name: "おりん", scene: .life, duration: 8.0, layers: [
            SoundLayer(source: .sine, length: 7.8, gain: 0.55, attack: 0.002, decay: 2.5, sustain: 0.25, release: 4.5, pitchStart: 660, vibratoRate: 2.2, vibratoDepth: 0.003),
            SoundLayer(source: .sine, length: 7.8, gain: 0.25, attack: 0.002, decay: 2.5, sustain: 0.25, release: 4.5, pitchStart: 663, vibratoRate: 2.6, vibratoDepth: 0.003, pan: 0.15),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.4), length: 6.0, gain: 0.3, attack: 0.002, decay: 2.0, sustain: 0.2, release: 3.5, pitchStart: 1822, vibratoRate: 3.1, vibratoDepth: 0.003, pan: -0.2),
            SoundLayer(source: .sine, length: 4.0, gain: 0.18, attack: 0.002, decay: 1.4, sustain: 0.15, release: 2.4, pitchStart: 3564, pan: 0.25),
            SoundLayer(source: .sine, length: 2.4, gain: 0.1, attack: 0.002, decay: 0.8, sustain: 0.1, release: 1.4, pitchStart: 5874),
            SoundLayer(source: .noise, length: 0.02, gain: 0.25, attack: 0.001, decay: 0.015, sustain: 0.1, release: 0.01, pitchStart: 100, filterStart: 5000, highpass: 1500)
        ], echoes: [(delay: 0.45, gain: 0.3), (delay: 1.0, gain: 0.16), (delay: 1.8, gain: 0.08)], randomSeed: 8, reverb: 0.35, reverbTime: 4.0),
        SoundRecipe(id: "life.churchbell", name: "教会の鐘", scene: .life, duration: 7.0, layers: [
            SoundLayer(source: .fm(ratio: 2.76, index: 2.5), length: 3.0, gain: 0.5, attack: 0.002, decay: 1.0, sustain: 0.25, release: 1.8, pitchStart: 294, repeats: 2, repeatGap: 0.4),
            SoundLayer(source: .sine, length: 3.2, gain: 0.35, attack: 0.002, decay: 1.4, sustain: 0.3, release: 1.6, pitchStart: 147, repeats: 2, repeatGap: 0.2),
            SoundLayer(source: .sine, length: 3.0, gain: 0.25, attack: 0.002, decay: 1.2, sustain: 0.2, release: 1.6, pitchStart: 350, repeats: 2, repeatGap: 0.4, pan: -0.2),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.8), length: 1.8, gain: 0.15, attack: 0.002, decay: 0.7, sustain: 0.1, release: 1.0, pitchStart: 1588, repeats: 2, repeatGap: 1.6, pan: 0.25),
            SoundLayer(source: .sine, length: 1.0, gain: 0.08, attack: 0.002, decay: 0.4, sustain: 0.1, release: 0.5, pitchStart: 2617, repeats: 2, repeatGap: 2.4)
        ], echoes: [(delay: 0.4, gain: 0.32), (delay: 0.9, gain: 0.18), (delay: 1.6, gain: 0.08)], reverb: 0.45, reverbTime: 4.0),
        SoundRecipe(id: "life.newstep", name: "新しい一歩", scene: .life, duration: 3.2, layers: [
            SoundLayer(source: .saw, length: 2.8, gain: 0.18, attack: 0.9, decay: 0.5, sustain: 0.7, release: 1.0, pitchStart: 262, pitchEnd: 294, filterStart: 500, filterEnd: 2800, pan: -0.3),
            SoundLayer(source: .saw, length: 2.8, gain: 0.18, attack: 0.9, decay: 0.5, sustain: 0.7, release: 1.0, pitchStart: 263.5, pitchEnd: 295.5, filterStart: 500, filterEnd: 2800, pan: 0.3),
            SoundLayer(source: .triangle, length: 2.8, gain: 0.25, attack: 1.0, decay: 0.5, sustain: 0.7, release: 1.0, pitchStart: 330, pitchEnd: 370, filterStart: 800, filterEnd: 3000),
            SoundLayer(source: .sine, length: 2.8, gain: 0.25, attack: 1.1, decay: 0.5, sustain: 0.7, release: 1.0, pitchStart: 392, pitchEnd: 440, vibratoRate: 5, vibratoDepth: 0.006),
            SoundLayer(source: .sine, length: 3.0, gain: 0.3, attack: 0.8, decay: 0.5, sustain: 0.6, release: 1.0, pitchStart: 65, pitchEnd: 73),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.6), start: 1.2, length: 1.8, gain: 0.15, attack: 0.01, decay: 0.6, sustain: 0.3, release: 0.9, pitchStart: 880)
        ], echoes: [(delay: 0.28, gain: 0.25), (delay: 0.6, gain: 0.12)], reverb: 0.35, reverbTime: 2.5)
    ]
}
