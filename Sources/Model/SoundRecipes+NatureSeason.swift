import Foundation

// 自然・季節の効果音レシピ。フィールド録音らしさを出すため、
// 環境音は「フィルター違いのノイズ層を複数重ね、アタック/リリースをずらしてゆっくり揺らす」、
// 粒(雨粒・パチパチ・鳴き声)は「高さ・左右・時刻を散らした短い層をたくさん」で作る。

/// 決まった種から散らばった短いイベント層を作る(毎回同じ結果)
private func nsScatter(count: Int, seed: UInt64, from t0: Double, to t1: Double,
                       make: (_ time: Double, _ r1: Double, _ r2: Double, _ pan: Float) -> SoundLayer) -> [SoundLayer] {
    var s = seed &* 6364136223846793005 &+ 1442695040888963407
    func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    var out: [SoundLayer] = []
    for _ in 0..<count {
        let t = t0 + (t1 - t0) * next()
        let r1 = next(), r2 = next()
        let pan = Float(next() * 1.6 - 0.8)
        out.append(make(t, r1, r2, pan))
    }
    return out
}

/// 鳥のさえずり 1 フレーズ(短い上下の音程スイープ)
private func nsChirp(at t: Double, base: Double, up: Bool, notes: Int, pan: Float, gain: Float) -> SoundLayer {
    SoundLayer(source: .sine, start: t, length: 0.06, gain: gain, attack: 0.004, decay: 0.03, sustain: 0.5, release: 0.02, pitchStart: up ? base : base * 1.45, pitchEnd: up ? base * 1.45 : base, repeats: notes, repeatGap: 0.075, vibratoRate: 22, vibratoDepth: 0.4, pan: pan, bandpass: base * 1.2, resonance: 0.7)
}

extension SoundRecipe {
    // 型チェックを軽くするため、レシピごとに明示型の定数へ分けている
    static let natureSeason: [SoundRecipe] = [
        nsBirds, nsRain, nsThunder, nsWind, nsWaves, nsCampfire, nsInsects, nsNightForest, nsSpringBird, nsCicada, nsSummerChime, nsFallenLeaves, nsSnowStep, nsSleighBells, nsTempleBell, nsTsuzumi, nsShishiodoshi, nsXmasSparkle,
    ]

    // MARK: - nature
    // 小鳥: 遠近 2 羽 + 葉ずれの薄い空気
    private static let nsBirdsLayers: [SoundLayer] = [
        SoundLayer(source: .pinkNoise, length: 3.0, gain: 0.08, attack: 0.6, decay: 0.3, sustain: 0.9, release: 0.8, highpass: 400, bandpass: 2500, resonance: 0.6),
        nsChirp(at: 0.10, base: 3400, up: true, notes: 3, pan: -0.5, gain: 0.42),
        nsChirp(at: 0.55, base: 4100, up: false, notes: 2, pan: -0.45, gain: 0.36),
        nsChirp(at: 1.05, base: 2900, up: true, notes: 4, pan: 0.55, gain: 0.22),
        nsChirp(at: 1.60, base: 3700, up: false, notes: 5, pan: -0.4, gain: 0.4),
        nsChirp(at: 2.25, base: 3100, up: true, notes: 2, pan: 0.6, gain: 0.2),
        SoundLayer(source: .sine, start: 2.55, length: 0.22, gain: 0.3, attack: 0.01, decay: 0.1, sustain: 0.5, release: 0.08, pitchStart: 4600, pitchEnd: 2600, vibratoRate: 35, vibratoDepth: 0.8, pan: -0.3),
    ]
    private static let nsBirds: SoundRecipe = SoundRecipe(id: "nature.birds", name: "小鳥の声", scene: .nature, duration: 3.0, layers: nsBirdsLayers, randomSeed: 31, reverb: 0.3, reverbTime: 1.6)

    // 雨: 帯域の違う 3 枚のノイズ床 + 散らばった雨粒(近い粒・遠い粒)
    private static let nsRainLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .pinkNoise, length: 5.0, gain: 0.32, attack: 1.0, decay: 0.5, sustain: 0.85, release: 1.2, filterStart: 6000, filterEnd: 5200, highpass: 500, pan: -0.3),
            SoundLayer(source: .pinkNoise, start: 0.3, length: 4.7, gain: 0.28, attack: 1.6, decay: 0.8, sustain: 0.8, release: 0.9, filterStart: 4800, filterEnd: 6200, highpass: 700, pan: 0.3),
            SoundLayer(source: .brownNoise, length: 5.0, gain: 0.18, attack: 1.2, decay: 0.5, sustain: 0.9, release: 1.2, filterStart: 500),
            SoundLayer(source: .noise, length: 5.0, gain: 0.06, attack: 1.5, decay: 0.5, sustain: 0.9, release: 1.2, highpass: 7000),
        ]
        l += nsScatter(count: 34, seed: 101, from: 0.2, to: 4.6) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .noise, start: t, length: 0.018, gain: Float(0.12 + 0.22 * r1), attack: 0.0005, decay: 0.012, sustain: 0, release: 0.005, pan: pan, bandpass: 2000 + 4500 * r2, resonance: 3.5)
        }
        return l
    }()
    private static let nsRain: SoundRecipe = SoundRecipe(id: "nature.rain", name: "雨音", scene: .nature, duration: 5.0, layers: nsRainLayers, randomSeed: 11, reverb: 0.2, reverbTime: 1.0)

    // 雷: 鋭い裂け目 → 低い転がり(ブラウンノイズ数枚を時間差で)
    private static let nsThunderLayers: [SoundLayer] = [
        SoundLayer(source: .noise, length: 0.18, gain: 0.85, attack: 0.001, decay: 0.12, sustain: 0.15, release: 0.05, filterStart: 9000, filterEnd: 1800, drive: 0.5),
        SoundLayer(source: .noise, start: 0.04, length: 0.12, gain: 0.5, attack: 0.001, decay: 0.08, sustain: 0.1, release: 0.03, filterStart: 5000, pan: 0.4, drive: 0.4),
        SoundLayer(source: .brownNoise, start: 0.08, length: 3.8, gain: 0.95, attack: 0.08, decay: 1.4, sustain: 0.35, release: 1.6, filterStart: 900, filterEnd: 140, drive: 0.25),
        SoundLayer(source: .brownNoise, start: 0.6, length: 2.8, gain: 0.6, attack: 0.3, decay: 0.8, sustain: 0.4, release: 1.4, filterStart: 400, filterEnd: 110, pan: -0.5),
        SoundLayer(source: .brownNoise, start: 1.2, length: 2.6, gain: 0.45, attack: 0.4, decay: 0.8, sustain: 0.3, release: 1.3, filterStart: 300, filterEnd: 90, pan: 0.5),
        SoundLayer(source: .pinkNoise, start: 0.1, length: 2.0, gain: 0.25, attack: 0.05, decay: 1.0, sustain: 0.2, release: 0.8, filterStart: 2500, filterEnd: 400),
    ]
    private static let nsThunder: SoundRecipe = SoundRecipe(id: "nature.thunder", name: "雷鳴", scene: .nature, duration: 4.0, layers: nsThunderLayers, randomSeed: 7, reverb: 0.45, reverbTime: 2.5)

    // 風: バンドパスで「ヒュー」を作り、中心周波数と音量をゆっくり動かす
    private static let nsWindLayers: [SoundLayer] = [
        SoundLayer(source: .brownNoise, length: 6.0, gain: 0.45, attack: 1.8, decay: 1.2, sustain: 0.6, release: 2.0, filterStart: 250, filterEnd: 600),
        SoundLayer(source: .pinkNoise, length: 3.6, gain: 0.35, attack: 1.6, decay: 0.6, sustain: 0.7, release: 1.4, pan: -0.4, bandpass: 650, resonance: 2.5),
        SoundLayer(source: .pinkNoise, start: 1.8, length: 3.8, gain: 0.4, attack: 1.4, decay: 0.8, sustain: 0.6, release: 1.6, pan: 0.4, bandpass: 900, resonance: 3.0),
        SoundLayer(source: .noise, start: 2.6, length: 2.6, gain: 0.12, attack: 1.0, decay: 0.5, sustain: 0.6, release: 1.0, pan: 0.1, bandpass: 1500, resonance: 5.0),
        SoundLayer(source: .pinkNoise, start: 0.8, length: 4.8, gain: 0.1, attack: 2.0, decay: 0.5, sustain: 0.8, release: 1.6, highpass: 3000),
    ]
    private static let nsWind: SoundRecipe = SoundRecipe(id: "nature.wind", name: "風の音", scene: .nature, duration: 6.0, layers: nsWindLayers, randomSeed: 3, reverb: 0.2, reverbTime: 1.5)

    // 波: 寄せる低いうねり → 砕ける → 引き波のシャー(左右に広げる)
    private static let nsWavesLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .brownNoise, length: 3.2, gain: 0.7, attack: 1.8, decay: 0.6, sustain: 0.5, release: 1.0, filterStart: 250, filterEnd: 900),
            SoundLayer(source: .pinkNoise, start: 1.6, length: 1.4, gain: 0.55, attack: 0.15, decay: 0.6, sustain: 0.4, release: 0.6, filterStart: 6000, filterEnd: 2500, highpass: 300, drive: 0.15),
            SoundLayer(source: .noise, start: 2.0, length: 3.8, gain: 0.28, attack: 0.3, decay: 1.5, sustain: 0.35, release: 2.0, filterStart: 7000, filterEnd: 1500, highpass: 1200, pan: -0.5),
            SoundLayer(source: .noise, start: 2.2, length: 3.6, gain: 0.25, attack: 0.4, decay: 1.4, sustain: 0.35, release: 2.0, filterStart: 6500, filterEnd: 1300, highpass: 1400, pan: 0.5),
            SoundLayer(source: .brownNoise, start: 3.5, length: 2.5, gain: 0.3, attack: 1.2, decay: 0.5, sustain: 0.5, release: 1.0, filterStart: 300),
        ]
        l += nsScatter(count: 18, seed: 202, from: 2.3, to: 5.2) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .noise, start: t, length: 0.02, gain: Float(0.05 + 0.08 * r1), attack: 0.001, decay: 0.015, sustain: 0, release: 0.005, pan: pan, bandpass: 3000 + 4000 * r2, resonance: 2.5)
        }
        return l
    }()
    private static let nsWaves: SoundRecipe = SoundRecipe(id: "nature.waves", name: "波の音", scene: .nature, duration: 6.0, layers: nsWavesLayers, randomSeed: 5, reverb: 0.25, reverbTime: 1.8)

    // 焚き火: 低いゴー + 炎のシュー + 散らばったパチッ(大小)
    private static let nsCampfireLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .brownNoise, length: 5.0, gain: 0.4, attack: 0.8, decay: 0.5, sustain: 0.85, release: 1.0, filterStart: 300, filterEnd: 380),
            SoundLayer(source: .pinkNoise, length: 2.8, gain: 0.14, attack: 1.0, decay: 0.5, sustain: 0.7, release: 1.0, pan: -0.2, bandpass: 1200, resonance: 1.2),
            SoundLayer(source: .pinkNoise, start: 2.0, length: 3.0, gain: 0.16, attack: 0.9, decay: 0.5, sustain: 0.7, release: 1.0, pan: 0.2, bandpass: 1000, resonance: 1.2),
        ]
        l += nsScatter(count: 30, seed: 303, from: 0.15, to: 4.7) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .noise, start: t, length: 0.012, gain: Float(0.15 + 0.45 * r1), attack: 0.0003, decay: 0.008, sustain: 0, release: 0.003, pan: pan * 0.6, bandpass: 1500 + 5000 * r2, resonance: 2.0, drive: 0.3)
        }
        l += nsScatter(count: 6, seed: 304, from: 0.5, to: 4.3) { (t: Double, r1: Double, _: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .noise, start: t, length: 0.04, gain: Float(0.35 + 0.25 * r1), attack: 0.0005, decay: 0.03, sustain: 0, release: 0.008, filterStart: 4000, highpass: 600, pan: pan * 0.5, drive: 0.5)
        }
        return l
    }()
    private static let nsCampfire: SoundRecipe = SoundRecipe(id: "nature.campfire", name: "焚き火", scene: .nature, duration: 5.0, layers: nsCampfireLayers, randomSeed: 21, reverb: 0.12, reverbTime: 0.8)

    // 虫の声: 秋の夜のコオロギ。FM のトリルを左右に散らし、遠い虫は小さく
    private static let nsInsectsLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .pinkNoise, length: 4.5, gain: 0.06, attack: 1.0, decay: 0.5, sustain: 0.9, release: 1.0, filterStart: 1200),
        ]
        l += nsScatter(count: 9, seed: 404, from: 0.0, to: 3.9) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .fm(ratio: 1.0 + r2 * 0.02, index: 1.2), start: t, length: 0.045, gain: Float(0.08 + 0.2 * r1), attack: 0.004, decay: 0.02, sustain: 0.6, release: 0.015, pitchStart: 4300 + 900 * r2, repeats: 4 + Int(r1 * 4), repeatGap: 0.06, pan: pan, bandpass: 4300 + 900 * r2, resonance: 2.0)
        }
        return l
    }()
    private static let nsInsects: SoundRecipe = SoundRecipe(id: "nature.insects", name: "虫の声", scene: .nature, duration: 4.5, layers: nsInsectsLayers, randomSeed: 41, reverb: 0.3, reverbTime: 1.4)

    // 夜の森: 風の床 + 遠い虫 + 枝のきしみ + フクロウ
    private static let nsNightForestLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .brownNoise, length: 6.0, gain: 0.3, attack: 2.0, decay: 1.0, sustain: 0.7, release: 2.0, filterStart: 300, filterEnd: 450),
            SoundLayer(source: .pinkNoise, start: 0.5, length: 4.0, gain: 0.1, attack: 1.8, decay: 0.5, sustain: 0.7, release: 1.5, pan: -0.4, bandpass: 700, resonance: 2.0),
            SoundLayer(source: .pinkNoise, start: 2.5, length: 3.5, gain: 0.1, attack: 1.5, decay: 0.5, sustain: 0.7, release: 1.5, pan: 0.4, bandpass: 850, resonance: 2.0),
            // フクロウ(ホー、ホホー)遠め
            SoundLayer(source: .sine, start: 1.8, length: 0.4, gain: 0.16, attack: 0.08, decay: 0.15, sustain: 0.6, release: 0.15, pitchStart: 400, pitchEnd: 370, filterStart: 900, vibratoRate: 5, vibratoDepth: 0.2, pan: -0.55),
            SoundLayer(source: .sine, start: 2.6, length: 0.22, gain: 0.13, attack: 0.05, decay: 0.08, sustain: 0.6, release: 0.08, pitchStart: 410, pitchEnd: 380, filterStart: 900, repeats: 2, repeatGap: 0.28, pan: -0.55),
            SoundLayer(source: .noise, start: 4.0, length: 0.03, gain: 0.12, attack: 0.001, decay: 0.02, sustain: 0, release: 0.008, pan: 0.6, bandpass: 1800, resonance: 3.0),
        ]
        l += nsScatter(count: 6, seed: 505, from: 0.3, to: 5.3) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .fm(ratio: 1.0, index: 1.0), start: t, length: 0.04, gain: Float(0.04 + 0.06 * r1), attack: 0.004, decay: 0.02, sustain: 0.6, release: 0.015, pitchStart: 4600 + 600 * r2, repeats: 3, repeatGap: 0.07, pan: pan, bandpass: 4800, resonance: 1.5)
        }
        return l
    }()
    private static let nsNightForest: SoundRecipe = SoundRecipe(id: "nature.nightForest", name: "夜の森", scene: .nature, duration: 6.0, layers: nsNightForestLayers, randomSeed: 9, reverb: 0.45, reverbTime: 2.4)

    // MARK: - season
    // 春の鳥: ウグイス(ホーー、ホケキョ)
    private static let nsSpringBirdLayers: [SoundLayer] = [
        SoundLayer(source: .pinkNoise, length: 3.0, gain: 0.06, attack: 0.6, decay: 0.3, sustain: 0.9, release: 0.8, highpass: 500, bandpass: 2000, resonance: 0.6),
        SoundLayer(source: .sine, start: 0.1, length: 0.9, gain: 0.42, attack: 0.12, decay: 0.3, sustain: 0.75, release: 0.15, pitchStart: 1350, pitchEnd: 1450, vibratoRate: 7, vibratoDepth: 0.15, pan: -0.2),
        SoundLayer(source: .sine, start: 1.1, length: 0.09, gain: 0.45, attack: 0.005, decay: 0.04, sustain: 0.6, release: 0.03, pitchStart: 2000, pitchEnd: 3200, pan: -0.2),
        SoundLayer(source: .sine, start: 1.22, length: 0.1, gain: 0.45, attack: 0.005, decay: 0.05, sustain: 0.6, release: 0.03, pitchStart: 3300, pitchEnd: 2400, pan: -0.2),
        SoundLayer(source: .sine, start: 1.36, length: 0.3, gain: 0.42, attack: 0.01, decay: 0.12, sustain: 0.6, release: 0.1, pitchStart: 2600, pitchEnd: 1900, vibratoRate: 30, vibratoDepth: 0.5, pan: -0.2),
        nsChirp(at: 2.1, base: 3800, up: true, notes: 3, pan: 0.6, gain: 0.15),
    ]
    private static let nsSpringBird: SoundRecipe = SoundRecipe(id: "season.springBird", name: "春の鳥", scene: .season, duration: 3.0, layers: nsSpringBirdLayers, randomSeed: 12, reverb: 0.35, reverbTime: 1.8)

    // セミ: ジージー。強い FM + バンドパスのノイズ、うなり(トレモロ)は少しずれた 2 匹で
    private static let nsCicadaLayers: [SoundLayer] = [
        SoundLayer(source: .fm(ratio: 1.07, index: 7.0), length: 3.9, gain: 0.3, attack: 0.5, decay: 0.4, sustain: 0.8, release: 0.8, pitchStart: 4000, vibratoRate: 14, vibratoDepth: 0.6, pan: -0.4, bandpass: 4200, resonance: 1.5, drive: 0.2),
        SoundLayer(source: .fm(ratio: 1.11, index: 6.0), start: 0.4, length: 3.5, gain: 0.22, attack: 0.7, decay: 0.4, sustain: 0.8, release: 0.8, pitchStart: 4600, vibratoRate: 17, vibratoDepth: 0.6, pan: 0.45, bandpass: 4800, resonance: 1.5, drive: 0.2),
        SoundLayer(source: .noise, length: 3.9, gain: 0.18, attack: 0.6, decay: 0.4, sustain: 0.8, release: 0.8, pan: -0.1, bandpass: 4500, resonance: 2.5),
        SoundLayer(source: .pinkNoise, length: 4.0, gain: 0.05, attack: 1.0, decay: 0.5, sustain: 0.9, release: 1.0, filterStart: 1500),
    ]
    private static let nsCicada: SoundRecipe = SoundRecipe(id: "season.cicada", name: "セミの声", scene: .season, duration: 4.0, layers: nsCicadaLayers, randomSeed: 4, reverb: 0.2, reverbTime: 1.2)

    // 夏の風鈴: ガラスの不調和な倍音 + 長い余韻。短冊が揺れて 3 回
    private static let nsSummerChimeLayers: [SoundLayer] = [
        SoundLayer(source: .fm(ratio: 2.76, index: 1.8), length: 2.0, gain: 0.38, attack: 0.001, decay: 1.6, sustain: 0.05, release: 0.4, pitchStart: 2650, pan: -0.15),
        SoundLayer(source: .fm(ratio: 5.4, index: 0.8), length: 0.9, gain: 0.15, attack: 0.001, decay: 0.7, sustain: 0.0, release: 0.2, pitchStart: 2650, pan: -0.15),
        SoundLayer(source: .fm(ratio: 2.76, index: 1.5), start: 0.55, length: 2.0, gain: 0.25, attack: 0.001, decay: 1.6, sustain: 0.05, release: 0.4, pitchStart: 2680, pan: 0.15),
        SoundLayer(source: .fm(ratio: 2.76, index: 1.2), start: 1.3, length: 1.7, gain: 0.16, attack: 0.001, decay: 1.4, sustain: 0.05, release: 0.3, pitchStart: 2640, pan: 0.05),
        SoundLayer(source: .noise, length: 0.01, gain: 0.25, attack: 0.0005, decay: 0.008, sustain: 0, release: 0.002, highpass: 5000, repeats: 3, repeatGap: 0.6),
    ]
    private static let nsSummerChime: SoundRecipe = SoundRecipe(id: "season.summerChime", name: "夏の風鈴", scene: .season, duration: 3.0, layers: nsSummerChimeLayers, randomSeed: 15, reverb: 0.3, reverbTime: 1.8)

    // 落ち葉: カサカサ。高い帯域の短いノイズを不規則に重ねる
    private static let nsFallenLeavesLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .pinkNoise, length: 1.6, gain: 0.2, attack: 0.15, decay: 0.6, sustain: 0.4, release: 0.5, bandpass: 4000, resonance: 0.8),
        ]
        l += nsScatter(count: 26, seed: 606, from: 0.0, to: 1.5) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .noise, start: t, length: 0.03 + 0.05 * r2, gain: Float(0.1 + 0.25 * r1), attack: 0.002, decay: 0.03, sustain: 0.2, release: 0.01, pan: pan * 0.5, bandpass: 2500 + 4000 * r2, resonance: 1.2)
        }
        return l
    }()
    private static let nsFallenLeaves: SoundRecipe = SoundRecipe(id: "season.fallenLeaves", name: "落ち葉", scene: .season, duration: 1.8, layers: nsFallenLeavesLayers, randomSeed: 13, reverb: 0.1, reverbTime: 0.6)

    // 雪を踏む: ギュッ(低めのつぶれ + 細かいきしみ)×4 歩
    private static let nsSnowStepLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .brownNoise, length: 0.22, gain: 0.5, attack: 0.03, decay: 0.12, sustain: 0.3, release: 0.05, filterStart: 900, filterEnd: 400, repeats: 4, repeatGap: 0.5, pan: -0.1),
        ]
        for step in 0..<4 {
            let stepPan: Float = step % 2 == 0 ? -0.15 : 0.15
            let from: Double = Double(step) * 0.5 + 0.01
            let to: Double = Double(step) * 0.5 + 0.2
            l += nsScatter(count: 9, seed: 700 + UInt64(step), from: from, to: to) { (t: Double, r1: Double, r2: Double, _: Float) -> SoundLayer in
                SoundLayer(source: .noise, start: t, length: 0.01, gain: Float(0.12 + 0.2 * r1), attack: 0.0005, decay: 0.007, sustain: 0, release: 0.002, pan: stepPan, bandpass: 1500 + 2500 * r2, resonance: 2.0)
            }
        }
        return l
    }()
    private static let nsSnowStep: SoundRecipe = SoundRecipe(id: "season.snowStep", name: "雪を踏む", scene: .season, duration: 2.2, layers: nsSnowStepLayers, randomSeed: 17, reverb: 0.08, reverbTime: 0.5)

    // そりの鈴: 不調和 FM の小鈴をたくさん、シャンシャンの拍で
    private static let nsSleighBellsLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .noise, length: 0.12, gain: 0.18, attack: 0.002, decay: 0.08, sustain: 0.2, release: 0.04, highpass: 6000, repeats: 8, repeatGap: 0.25),
        ]
        l += nsScatter(count: 40, seed: 808, from: 0.0, to: 2.0) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .fm(ratio: 2.76 + r2 * 0.6, index: 2.5), start: t, length: 0.18, gain: Float(0.06 + 0.12 * r1), attack: 0.0005, decay: 0.15, sustain: 0.0, release: 0.04, pitchStart: 4200 + 2200 * r2, highpass: 2500, pan: pan)
        }
        return l
    }()
    private static let nsSleighBells: SoundRecipe = SoundRecipe(id: "season.sleighBells", name: "そりの鈴", scene: .season, duration: 2.4, layers: nsSleighBellsLayers, randomSeed: 6, reverb: 0.25, reverbTime: 1.2)

    // 除夜の鐘: 撞木の打撃 + 不調和な分音 + うなり + とても長い余韻
    private static let nsTempleBellLayers: [SoundLayer] = [
        SoundLayer(source: .brownNoise, length: 0.12, gain: 0.5, attack: 0.002, decay: 0.08, sustain: 0.1, release: 0.04, filterStart: 600, drive: 0.3),
        SoundLayer(source: .sine, length: 6.0, gain: 0.55, attack: 0.01, decay: 5.0, sustain: 0.15, release: 0.9, pitchStart: 65, vibratoRate: 0.8, vibratoDepth: 0.05),
        SoundLayer(source: .sine, length: 6.0, gain: 0.45, attack: 0.01, decay: 4.5, sustain: 0.12, release: 0.9, pitchStart: 131.5, vibratoRate: 1.3, vibratoDepth: 0.06),
        SoundLayer(source: .fm(ratio: 2.41, index: 1.4), length: 4.0, gain: 0.35, attack: 0.005, decay: 3.2, sustain: 0.05, release: 0.6, pitchStart: 196),
        SoundLayer(source: .fm(ratio: 1.73, index: 1.0), length: 2.5, gain: 0.2, attack: 0.005, decay: 2.0, sustain: 0.0, release: 0.4, pitchStart: 347),
    ]
    private static let nsTempleBell: SoundRecipe = SoundRecipe(id: "season.templeBell", name: "除夜の鐘", scene: .season, duration: 6.0, layers: nsTempleBellLayers, echoes: [(delay: 0.45, gain: 0.2), (delay: 1.1, gain: 0.1)], randomSeed: 2, reverb: 0.5, reverbTime: 4.0)

    // 鼓: 張った皮の「ポン」。高めの膜の音程が素早く下がる + 掌の打撃
    private static let nsTsuzumiLayers: [SoundLayer] = [
        SoundLayer(source: .sine, length: 0.7, gain: 0.75, attack: 0.001, decay: 0.4, sustain: 0.08, release: 0.2, pitchStart: 520, pitchEnd: 300, drive: 0.15),
        SoundLayer(source: .fm(ratio: 1.59, index: 0.8), length: 0.35, gain: 0.25, attack: 0.001, decay: 0.2, sustain: 0.0, release: 0.08, pitchStart: 520, pitchEnd: 330),
        SoundLayer(source: .noise, length: 0.025, gain: 0.45, attack: 0.0005, decay: 0.02, sustain: 0, release: 0.004, bandpass: 2200, resonance: 1.5),
    ]
    private static let nsTsuzumi: SoundRecipe = SoundRecipe(id: "season.tsuzumi", name: "鼓の音", scene: .season, duration: 1.2, layers: nsTsuzumiLayers, randomSeed: 3, reverb: 0.4, reverbTime: 1.6)

    // ししおどし: 水が流れ続ける → 竹の「カーン」→ 水がこぼれる
    private static let nsShishiodoshiLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .pinkNoise, length: 3.0, gain: 0.12, attack: 0.5, decay: 0.3, sustain: 0.8, release: 0.6, bandpass: 2500, resonance: 1.0),
            SoundLayer(source: .triangle, start: 1.0, length: 0.25, gain: 0.7, attack: 0.0005, decay: 0.12, sustain: 0.0, release: 0.08, pitchStart: 820, pitchEnd: 760, bandpass: 900, resonance: 4.0, drive: 0.2),
            SoundLayer(source: .fm(ratio: 2.3, index: 1.0), start: 1.0, length: 0.2, gain: 0.25, attack: 0.0005, decay: 0.1, sustain: 0.0, release: 0.05, pitchStart: 820),
            SoundLayer(source: .noise, start: 1.0, length: 0.02, gain: 0.45, attack: 0.0005, decay: 0.015, sustain: 0, release: 0.004, bandpass: 3000, resonance: 1.5),
            SoundLayer(source: .noise, start: 0.95, length: 0.5, gain: 0.25, attack: 0.03, decay: 0.3, sustain: 0.2, release: 0.15, pan: 0.2, bandpass: 1800, resonance: 1.5),
        ]
        l += nsScatter(count: 14, seed: 909, from: 1.0, to: 1.5) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .sine, start: t, length: 0.03, gain: Float(0.05 + 0.08 * r1), attack: 0.002, decay: 0.02, sustain: 0, release: 0.008, pitchStart: 900 + 1500 * r2, pitchEnd: 1800 + 2000 * r2, pan: pan * 0.4)
        }
        return l
    }()
    private static let nsShishiodoshi: SoundRecipe = SoundRecipe(id: "season.shishiodoshi", name: "ししおどし", scene: .season, duration: 3.0, layers: nsShishiodoshiLayers, randomSeed: 8, reverb: 0.5, reverbTime: 2.2)

    // 聖夜のきらめき: グロッケン風の不調和ベル(高い分音)を上へ散らし、空気のシャラッ
    private static let nsXmasSparkleLayers: [SoundLayer] = {
        var l: [SoundLayer] = [
            SoundLayer(source: .noise, length: 1.6, gain: 0.07, attack: 0.3, decay: 0.8, sustain: 0.2, release: 0.5, highpass: 8000),
            SoundLayer(source: .fm(ratio: 3.5, index: 1.0), length: 1.4, gain: 0.25, attack: 0.001, decay: 1.1, sustain: 0.0, release: 0.3, pitchStart: 2093, pan: -0.5),
            SoundLayer(source: .fm(ratio: 3.5, index: 1.0), start: 0.12, length: 1.4, gain: 0.23, attack: 0.001, decay: 1.1, sustain: 0.0, release: 0.3, pitchStart: 2637, pan: -0.2),
            SoundLayer(source: .fm(ratio: 3.5, index: 1.0), start: 0.24, length: 1.4, gain: 0.22, attack: 0.001, decay: 1.1, sustain: 0.0, release: 0.3, pitchStart: 3136, pan: 0.2),
            SoundLayer(source: .fm(ratio: 3.5, index: 1.0), start: 0.36, length: 1.6, gain: 0.22, attack: 0.001, decay: 1.3, sustain: 0.0, release: 0.3, pitchStart: 4186, pan: 0.5),
        ]
        l += nsScatter(count: 16, seed: 1010, from: 0.3, to: 1.8) { (t: Double, r1: Double, r2: Double, pan: Float) -> SoundLayer in
            SoundLayer(source: .fm(ratio: 2.76, index: 1.5), start: t, length: 0.25, gain: Float(0.04 + 0.07 * r1), attack: 0.0005, decay: 0.2, sustain: 0, release: 0.05, pitchStart: 5000 + 3000 * r2, highpass: 3000, pan: pan)
        }
        return l
    }()
    private static let nsXmasSparkle: SoundRecipe = SoundRecipe(id: "season.xmasSparkle", name: "聖夜のきらめき", scene: .season, duration: 2.8, layers: nsXmasSparkleLayers, randomSeed: 25, reverb: 0.45, reverbTime: 2.2)

}
