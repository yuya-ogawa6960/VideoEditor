import Foundation

// 日常・食事・暮らし・バラエティの効果音レシピ。
// どの音も「アタック(2〜10ms のノイズ/クリック)+ 胴鳴り(非整数比 FM / デチューン)+ 余韻(フィルターしたノイズ・長い倍音)」で組む。
// 層の gain の合計は 1.0 未満に保つ。
extension SoundRecipe {
    static let dailyFood: [SoundRecipe] = [
        // MARK: - daily
        // 革靴の足音。左右交互(別の層で音程・音量を少し変える)
        SoundRecipe(id: "daily.footsteps", name: "足音コツコツ", scene: .daily, duration: 2.2, layers: [
            SoundLayer(source: .noise, length: 0.006, gain: 0.22, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, highpass: 2500, repeats: 3, repeatGap: 0.6, pan: -0.15, bandpass: 4200, resonance: 1.2),
            SoundLayer(source: .noise, start: 0.3, length: 0.006, gain: 0.18, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, highpass: 2500, repeats: 3, repeatGap: 0.6, pan: 0.15, bandpass: 3700, resonance: 1.2),
            SoundLayer(source: .fm(ratio: 1.41, index: 1.4), length: 0.07, gain: 0.2, attack: 0.001, decay: 0.05, sustain: 0, release: 0.02, pitchStart: 160, pitchEnd: 110, filterStart: 2200, filterEnd: 500, repeats: 3, repeatGap: 0.6, pan: -0.15),
            SoundLayer(source: .fm(ratio: 1.41, index: 1.2), start: 0.3, length: 0.07, gain: 0.17, attack: 0.001, decay: 0.05, sustain: 0, release: 0.02, pitchStart: 145, pitchEnd: 100, filterStart: 2000, filterEnd: 450, repeats: 3, repeatGap: 0.6, pan: 0.15),
            SoundLayer(source: .brownNoise, length: 0.05, gain: 0.15, attack: 0.002, decay: 0.04, sustain: 0, release: 0.01, filterStart: 400, repeats: 6, repeatGap: 0.3)
        ], randomSeed: 11, reverb: 0.18, reverbTime: 0.8),
        // 木のドアを拳で 3 回。最後だけ少し強い
        SoundRecipe(id: "daily.knock", name: "ドアノック", scene: .daily, duration: 1.0, layers: [
            SoundLayer(source: .noise, length: 0.005, gain: 0.2, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, repeats: 2, repeatGap: 0.17, bandpass: 2400, resonance: 1.5),
            SoundLayer(source: .fm(ratio: 1.41, index: 1.8), length: 0.09, gain: 0.3, attack: 0.001, decay: 0.06, sustain: 0, release: 0.03, pitchStart: 190, pitchEnd: 150, filterStart: 1800, filterEnd: 400, repeats: 2, repeatGap: 0.17, drive: 0.2),
            SoundLayer(source: .fm(ratio: 1.41, index: 2.2), start: 0.34, length: 0.11, gain: 0.33, attack: 0.001, decay: 0.07, sustain: 0, release: 0.04, pitchStart: 180, pitchEnd: 135, filterStart: 2200, filterEnd: 400, drive: 0.3),
            SoundLayer(source: .brownNoise, length: 0.12, gain: 0.12, attack: 0.002, decay: 0.09, sustain: 0, release: 0.03, filterStart: 350, repeats: 3, repeatGap: 0.17)
        ], echoes: [(delay: 0.023, gain: 0.15)], randomSeed: 12, reverb: 0.2, reverbTime: 0.7),
        // ピンポーン(金属バーを打つ 2 音)
        SoundRecipe(id: "daily.doorbell", name: "玄関チャイム", scene: .daily, duration: 2.6, layers: [
            SoundLayer(source: .noise, length: 0.004, gain: 0.08, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 3000),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.9), length: 1.1, gain: 0.32, attack: 0.002, decay: 0.9, sustain: 0.05, release: 0.2, pitchStart: 659.3, filterStart: 6000, filterEnd: 1800),
            SoundLayer(source: .fm(ratio: 2.76, index: 0.9), start: 0.55, length: 1.9, gain: 0.32, attack: 0.002, decay: 1.5, sustain: 0.05, release: 0.4, pitchStart: 523.3, filterStart: 6000, filterEnd: 1500),
            SoundLayer(source: .triangle, start: 0.55, length: 1.9, gain: 0.12, attack: 0.004, decay: 1.6, sustain: 0, release: 0.3, pitchStart: 524.5, vibratoRate: 4.5, vibratoDepth: 0.03)
        ], echoes: [(delay: 0.11, gain: 0.15)], randomSeed: 13, reverb: 0.25, reverbTime: 1.0),
        // ポロン(ガラス質の上昇 2 音)
        SoundRecipe(id: "daily.notify", name: "スマホ通知", scene: .daily, duration: 0.9, layers: [
            SoundLayer(source: .noise, length: 0.003, gain: 0.06, attack: 0.001, decay: 0.002, sustain: 0, release: 0.001, highpass: 5000),
            SoundLayer(source: .fm(ratio: 3.01, index: 0.7), length: 0.25, gain: 0.3, attack: 0.002, decay: 0.18, sustain: 0.1, release: 0.06, pitchStart: 1318.5, filterStart: 7000, filterEnd: 3000),
            SoundLayer(source: .fm(ratio: 3.01, index: 0.7), start: 0.11, length: 0.6, gain: 0.32, attack: 0.002, decay: 0.45, sustain: 0.05, release: 0.15, pitchStart: 1760, filterStart: 8000, filterEnd: 2500),
            SoundLayer(source: .triangle, start: 0.11, length: 0.6, gain: 0.1, attack: 0.003, decay: 0.5, sustain: 0, release: 0.1, pitchStart: 1763)
        ], echoes: [(delay: 0.09, gain: 0.12)], randomSeed: 14, reverb: 0.2, reverbTime: 0.8),
        // レジ: ボタン 2 回 → ドロワーが滑る → チーンの金属ベル
        SoundRecipe(id: "daily.register", name: "レジの音", scene: .daily, duration: 1.8, layers: [
            SoundLayer(source: .noise, length: 0.008, gain: 0.15, attack: 0.001, decay: 0.006, sustain: 0, release: 0.001, repeats: 2, repeatGap: 0.13, bandpass: 3000, resonance: 2),
            SoundLayer(source: .fm(ratio: 1.41, index: 2.0), length: 0.03, gain: 0.12, attack: 0.001, decay: 0.02, sustain: 0, release: 0.01, pitchStart: 900, repeats: 2, repeatGap: 0.13),
            SoundLayer(source: .noise, start: 0.3, length: 0.22, gain: 0.2, attack: 0.01, decay: 0.15, sustain: 0.3, release: 0.05, filterStart: 3500, filterEnd: 900, highpass: 200, drive: 0.2),
            SoundLayer(source: .fm(ratio: 2.76, index: 2.2), start: 0.48, length: 1.3, gain: 0.3, attack: 0.001, decay: 1.1, sustain: 0, release: 0.2, pitchStart: 2093, filterStart: 9000, filterEnd: 3000),
            SoundLayer(source: .fm(ratio: 1.41, index: 0.8), start: 0.48, length: 1.2, gain: 0.12, attack: 0.001, decay: 1.0, sustain: 0, release: 0.2, pitchStart: 2101)
        ], randomSeed: 15, reverb: 0.18, reverbTime: 0.9),

        // MARK: - food
        // 鉄板で肉が焼ける。高域ノイズの帯 + ランダムなパチパチ
        SoundRecipe(id: "food.sizzle", name: "ジュージュー", scene: .food, duration: 3.5, layers: [
            SoundLayer(source: .noise, length: 3.5, gain: 0.22, attack: 0.15, decay: 0.3, sustain: 0.85, release: 0.5, filterStart: 9000, filterEnd: 7000, highpass: 2800),
            SoundLayer(source: .pinkNoise, length: 3.5, gain: 0.14, attack: 0.2, decay: 0.3, sustain: 0.7, release: 0.5, highpass: 1500, vibratoRate: 3, vibratoDepth: 0.1, bandpass: 4500, resonance: 0.8),
            SoundLayer(source: .noise, start: 0.05, length: 0.006, gain: 0.22, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, highpass: 3500, repeats: 29, repeatGap: 0.115, pan: -0.25, drive: 0.4),
            SoundLayer(source: .noise, start: 0.11, length: 0.004, gain: 0.18, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 5000, repeats: 19, repeatGap: 0.175, pan: 0.3, drive: 0.4),
            SoundLayer(source: .noise, start: 0.2, length: 0.01, gain: 0.12, attack: 0.001, decay: 0.008, sustain: 0, release: 0.002, repeats: 11, repeatGap: 0.29, bandpass: 2200, resonance: 2)
        ], randomSeed: 21, reverb: 0.08, reverbTime: 0.6),
        // グラスに注ぐ。共鳴帯域が上がっていく(水位が上がる)+ トクトクの泡
        SoundRecipe(id: "food.pour", name: "トクトク注ぐ", scene: .food, duration: 2.6, layers: [
            SoundLayer(source: .noise, length: 0.006, gain: 0.08, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, highpass: 2000),
            SoundLayer(source: .pinkNoise, length: 2.5, gain: 0.3, attack: 0.08, decay: 0.3, sustain: 0.75, release: 0.3, filterStart: 700, filterEnd: 3200, highpass: 250, resonance: 3.5),
            SoundLayer(source: .sine, length: 0.06, gain: 0.2, attack: 0.004, decay: 0.04, sustain: 0, release: 0.015, pitchStart: 380, pitchEnd: 620, filterStart: 1500, repeats: 11, repeatGap: 0.21),
            SoundLayer(source: .noise, length: 2.5, gain: 0.12, attack: 0.2, decay: 0.3, sustain: 0.6, release: 0.3, highpass: 4000, vibratoRate: 7, vibratoDepth: 0.1),
            SoundLayer(source: .brownNoise, length: 2.5, gain: 0.1, attack: 0.1, decay: 0.3, sustain: 0.6, release: 0.3, filterStart: 300)
        ], randomSeed: 22, reverb: 0.12, reverbTime: 0.6),
        // 揚げ物をかじる。細かい破片が連続で割れる
        SoundRecipe(id: "food.crunch", name: "サクッ", scene: .food, duration: 0.45, layers: [
            SoundLayer(source: .noise, length: 0.008, gain: 0.25, attack: 0.001, decay: 0.006, sustain: 0, release: 0.001, highpass: 2000, drive: 0.5),
            SoundLayer(source: .noise, start: 0.006, length: 0.012, gain: 0.22, attack: 0.001, decay: 0.009, sustain: 0, release: 0.002, highpass: 2500, repeats: 6, repeatGap: 0.018, bandpass: 5000, resonance: 1.5),
            SoundLayer(source: .noise, length: 0.15, gain: 0.2, attack: 0.002, decay: 0.1, sustain: 0.1, release: 0.04, filterStart: 8000, filterEnd: 1800, highpass: 1200),
            SoundLayer(source: .brownNoise, length: 0.06, gain: 0.14, attack: 0.001, decay: 0.05, sustain: 0, release: 0.01, filterStart: 500)
        ], randomSeed: 23, reverb: 0.06, reverbTime: 0.4),
        // ワインのコルク。空洞の共鳴(バンドパスが下がる)+ ガスの抜け
        SoundRecipe(id: "food.cork", name: "ポンッと栓", scene: .food, duration: 0.9, layers: [
            SoundLayer(source: .noise, length: 0.005, gain: 0.25, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, drive: 0.4),
            SoundLayer(source: .sine, length: 0.09, gain: 0.33, attack: 0.001, decay: 0.06, sustain: 0, release: 0.03, pitchStart: 820, pitchEnd: 420, filterStart: 2500, drive: 0.25),
            SoundLayer(source: .noise, length: 0.08, gain: 0.18, attack: 0.001, decay: 0.06, sustain: 0, release: 0.02, filterStart: 3000, filterEnd: 900, bandpass: 900, resonance: 4),
            SoundLayer(source: .noise, start: 0.06, length: 0.6, gain: 0.12, attack: 0.03, decay: 0.4, sustain: 0.1, release: 0.15, filterStart: 9000, filterEnd: 4000, highpass: 3500)
        ], echoes: [(delay: 0.04, gain: 0.12)], randomSeed: 24, reverb: 0.15, reverbTime: 0.6),
        // やわらかい 2 音のチャイム(鉄琴風)
        SoundRecipe(id: "food.itadakimasu", name: "いただきます", scene: .food, duration: 2.0, layers: [
            SoundLayer(source: .noise, length: 0.004, gain: 0.05, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 4000),
            SoundLayer(source: .fm(ratio: 4.0, index: 0.5), length: 0.8, gain: 0.3, attack: 0.004, decay: 0.6, sustain: 0.05, release: 0.2, pitchStart: 783.99, filterStart: 5000, filterEnd: 1800),
            SoundLayer(source: .fm(ratio: 4.0, index: 0.5), start: 0.24, length: 1.6, gain: 0.32, attack: 0.004, decay: 1.2, sustain: 0.05, release: 0.35, pitchStart: 1046.5, filterStart: 5000, filterEnd: 1500),
            SoundLayer(source: .triangle, start: 0.24, length: 1.5, gain: 0.12, attack: 0.02, decay: 1.2, sustain: 0, release: 0.3, pitchStart: 1048, vibratoRate: 4, vibratoDepth: 0.03)
        ], echoes: [(delay: 0.16, gain: 0.14)], randomSeed: 25, reverb: 0.25, reverbTime: 1.2),

        // MARK: - kurashi
        // やかんが沸く: ゴボゴボ → 細い笛がかすれながら上がる
        SoundRecipe(id: "kurashi.kettle", name: "やかんピー", scene: .kurashi, duration: 3.8, layers: [
            SoundLayer(source: .brownNoise, length: 3.7, gain: 0.14, attack: 0.3, decay: 0.3, sustain: 0.7, release: 0.4, filterStart: 500, filterEnd: 900, vibratoRate: 9, vibratoDepth: 0.2),
            SoundLayer(source: .noise, start: 0.5, length: 3.2, gain: 0.14, attack: 0.8, decay: 0.3, sustain: 0.8, release: 0.3, highpass: 1500, bandpass: 2600, resonance: 6),
            SoundLayer(source: .fm(ratio: 1.0, index: 0.25), start: 1.0, length: 2.7, gain: 0.3, attack: 0.9, decay: 0.3, sustain: 0.9, release: 0.3, pitchStart: 1900, pitchEnd: 2500, filterStart: 3000, filterEnd: 5000, vibratoRate: 6.5, vibratoDepth: 0.08),
            SoundLayer(source: .triangle, start: 1.2, length: 2.5, gain: 0.08, attack: 1.0, decay: 0.3, sustain: 0.8, release: 0.3, pitchStart: 3810, pitchEnd: 5010, vibratoRate: 6.5, vibratoDepth: 0.08)
        ], randomSeed: 31, reverb: 0.15, reverbTime: 0.8),
        // 陶器のカップを木のテーブルに置く
        SoundRecipe(id: "kurashi.cup", name: "カップ置く", scene: .kurashi, duration: 0.7, layers: [
            SoundLayer(source: .noise, length: 0.004, gain: 0.2, attack: 0.001, decay: 0.003, sustain: 0, release: 0.001, highpass: 1500),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.4), length: 0.35, gain: 0.25, attack: 0.001, decay: 0.2, sustain: 0, release: 0.12, pitchStart: 1850, filterStart: 7000, filterEnd: 2500),
            SoundLayer(source: .fm(ratio: 1.41, index: 0.9), length: 0.25, gain: 0.15, attack: 0.001, decay: 0.15, sustain: 0, release: 0.08, pitchStart: 3240),
            SoundLayer(source: .fm(ratio: 1.41, index: 1.5), length: 0.06, gain: 0.18, attack: 0.001, decay: 0.04, sustain: 0, release: 0.02, pitchStart: 170, pitchEnd: 120, filterStart: 900)
        ], randomSeed: 32, reverb: 0.15, reverbTime: 0.6),
        // 柱時計: チク(高)とタク(低)を別の層で
        SoundRecipe(id: "kurashi.clock", name: "チクタク", scene: .kurashi, duration: 4.0, layers: [
            SoundLayer(source: .noise, length: 0.005, gain: 0.25, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, repeats: 4, repeatGap: 1.0, pan: -0.1, bandpass: 4500, resonance: 3),
            SoundLayer(source: .noise, start: 0.5, length: 0.006, gain: 0.22, attack: 0.001, decay: 0.005, sustain: 0, release: 0.001, repeats: 4, repeatGap: 1.0, pan: 0.1, bandpass: 3000, resonance: 3),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.0), length: 0.04, gain: 0.14, attack: 0.001, decay: 0.03, sustain: 0, release: 0.01, pitchStart: 2600, repeats: 4, repeatGap: 1.0, pan: -0.1),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.0), start: 0.5, length: 0.05, gain: 0.12, attack: 0.001, decay: 0.04, sustain: 0, release: 0.01, pitchStart: 1950, repeats: 4, repeatGap: 1.0, pan: 0.1),
            SoundLayer(source: .brownNoise, length: 0.05, gain: 0.08, attack: 0.002, decay: 0.04, sustain: 0, release: 0.01, filterStart: 600, repeats: 8, repeatGap: 0.5)
        ], echoes: [(delay: 0.018, gain: 0.2), (delay: 0.037, gain: 0.1)], randomSeed: 33, reverb: 0.22, reverbTime: 0.9),
        // ガラスの風鈴: 舌が当たるクリック + 非整数倍音 + 2 打目
        SoundRecipe(id: "kurashi.windchime", name: "風鈴チリン", scene: .kurashi, duration: 3.5, layers: [
            SoundLayer(source: .noise, length: 0.003, gain: 0.1, attack: 0.001, decay: 0.002, sustain: 0, release: 0.001, highpass: 6000, repeats: 2, repeatGap: 0.37),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.6), length: 2.6, gain: 0.28, attack: 0.001, decay: 2.2, sustain: 0, release: 0.4, pitchStart: 2637, filterStart: 10000, filterEnd: 4000, vibratoRate: 5, vibratoDepth: 0.02),
            SoundLayer(source: .fm(ratio: 5.4, index: 0.4), length: 1.6, gain: 0.12, attack: 0.001, decay: 1.3, sustain: 0, release: 0.3, pitchStart: 2641),
            SoundLayer(source: .fm(ratio: 2.76, index: 1.2), start: 0.37, length: 2.8, gain: 0.22, attack: 0.001, decay: 2.4, sustain: 0, release: 0.4, pitchStart: 2960, filterStart: 10000, filterEnd: 3500, vibratoRate: 4.3, vibratoDepth: 0.02, pan: 0.3),
            SoundLayer(source: .noise, length: 1.5, gain: 0.05, attack: 0.3, decay: 0.8, sustain: 0, release: 0.4, highpass: 5000)
        ], echoes: [(delay: 0.14, gain: 0.18), (delay: 0.31, gain: 0.09)], randomSeed: 34, reverb: 0.3, reverbTime: 1.6),

        // MARK: - variety
        // バネのボヨーン: 揺れながら減衰。共鳴フィルターでビヨン感
        SoundRecipe(id: "variety.boing", name: "ボヨーン", scene: .variety, duration: 1.3, layers: [
            SoundLayer(source: .noise, length: 0.006, gain: 0.12, attack: 0.001, decay: 0.004, sustain: 0, release: 0.001, filterStart: 2000),
            SoundLayer(source: .saw, length: 1.2, gain: 0.3, attack: 0.002, decay: 1.0, sustain: 0.05, release: 0.2, pitchStart: 110, pitchEnd: 230, filterStart: 2400, filterEnd: 500, vibratoRate: 11, vibratoDepth: 1.8, resonance: 4),
            SoundLayer(source: .sine, length: 1.2, gain: 0.3, attack: 0.002, decay: 1.0, sustain: 0.05, release: 0.2, pitchStart: 111, pitchEnd: 232, vibratoRate: 11, vibratoDepth: 1.8),
            SoundLayer(source: .fm(ratio: 1.41, index: 1.0), length: 0.3, gain: 0.1, attack: 0.002, decay: 0.25, sustain: 0, release: 0.05, pitchStart: 330, pitchEnd: 480)
        ], randomSeed: 41, reverb: 0.12, reverbTime: 0.6),
        // スライドホイッスル上がり(息のノイズ付き)
        SoundRecipe(id: "variety.slideUp", name: "笛ヒュー↑", scene: .variety, duration: 1.1, layers: [
            SoundLayer(source: .noise, length: 0.01, gain: 0.08, attack: 0.002, decay: 0.006, sustain: 0, release: 0.002, highpass: 2000),
            SoundLayer(source: .sine, length: 1.0, gain: 0.42, attack: 0.04, decay: 0.2, sustain: 0.85, release: 0.12, pitchStart: 520, pitchEnd: 1900, vibratoRate: 6, vibratoDepth: 0.25),
            SoundLayer(source: .triangle, length: 1.0, gain: 0.1, attack: 0.04, decay: 0.2, sustain: 0.8, release: 0.12, pitchStart: 1043, pitchEnd: 3805, filterStart: 3000, filterEnd: 6000, vibratoRate: 6, vibratoDepth: 0.25),
            SoundLayer(source: .noise, length: 1.0, gain: 0.1, attack: 0.04, decay: 0.2, sustain: 0.7, release: 0.12, highpass: 800, bandpass: 1500, resonance: 2)
        ], randomSeed: 42, reverb: 0.15, reverbTime: 0.7),
        // スライドホイッスル下がり
        SoundRecipe(id: "variety.slideDown", name: "笛ヒュー↓", scene: .variety, duration: 1.1, layers: [
            SoundLayer(source: .noise, length: 0.01, gain: 0.08, attack: 0.002, decay: 0.006, sustain: 0, release: 0.002, highpass: 2000),
            SoundLayer(source: .sine, length: 1.0, gain: 0.42, attack: 0.04, decay: 0.2, sustain: 0.85, release: 0.12, pitchStart: 1900, pitchEnd: 450, vibratoRate: 6, vibratoDepth: 0.25),
            SoundLayer(source: .triangle, length: 1.0, gain: 0.1, attack: 0.04, decay: 0.2, sustain: 0.8, release: 0.12, pitchStart: 3805, pitchEnd: 903, filterStart: 6000, filterEnd: 2500, vibratoRate: 6, vibratoDepth: 0.25),
            SoundLayer(source: .noise, length: 1.0, gain: 0.1, attack: 0.04, decay: 0.2, sustain: 0.7, release: 0.12, highpass: 800, bandpass: 1500, resonance: 2)
        ], randomSeed: 43, reverb: 0.15, reverbTime: 0.7),
        // スネアのロール(だんだん強く)→ キック + シンバル
        SoundRecipe(id: "variety.drumrollCrash", name: "ロール→ジャン", scene: .variety, duration: 4.0, layers: [
            SoundLayer(source: .noise, length: 0.035, gain: 0.14, attack: 0.001, decay: 0.025, sustain: 0, release: 0.01, highpass: 400, repeats: 36, repeatGap: 0.055, pan: -0.1, bandpass: 2500, resonance: 1.2),
            SoundLayer(source: .noise, start: 0.027, length: 0.035, gain: 0.12, attack: 0.001, decay: 0.025, sustain: 0, release: 0.01, highpass: 400, repeats: 36, repeatGap: 0.055, pan: 0.1, bandpass: 2800, resonance: 1.2),
            SoundLayer(source: .noise, start: 0.9, length: 1.1, gain: 0.12, attack: 1.0, decay: 0.05, sustain: 1, release: 0.05, filterStart: 3000, filterEnd: 7000, highpass: 600),
            SoundLayer(source: .fm(ratio: 1.41, index: 5.0), start: 2.0, length: 1.9, gain: 0.25, attack: 0.001, decay: 1.6, sustain: 0, release: 0.3, pitchStart: 430, filterStart: 12000, filterEnd: 4000, highpass: 1500, drive: 0.3),
            SoundLayer(source: .sine, start: 2.0, length: 0.4, gain: 0.3, attack: 0.001, decay: 0.3, sustain: 0, release: 0.1, pitchStart: 120, pitchEnd: 45, drive: 0.4)
        ], echoes: [(delay: 0.08, gain: 0.15)], randomSeed: 44, reverb: 0.28, reverbTime: 1.5)
    ]
}
