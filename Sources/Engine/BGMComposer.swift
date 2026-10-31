import Foundation

// =====================================================================
// BGM の作曲(楽譜づくり)。音は出さず、コード・セクション・音符の並びだけを決める。
// BGMGenerator はこの楽譜を読んで、音色ごとに鳴らすだけ。
// 乱数は用途ごとに種を分ける(seed ^ 定数)ので、1 つのパートを変えても他のパートは変わらない。
// 表や重みは C:\Users\yogaw\AppData\Local\Temp\vmd\audit\BGM_COMPOSER_TABLES.md にも書いてある
// (Python の検証がこれを写しているので、表を変えたらそちらも直すこと)。
// 主旋律が他の曲と似ないように、variantIndex は指紋だけでなく「似ている度」(similarity)も見て
// ずらし番号を決める(BGMLibrary.all の順に、先に決まった曲と似ていない variant を探す)。
// =====================================================================

/// 楽譜の 1 音
struct ScoreNote {
    enum Part {
        case pad, comp, bass, arp, lead, counter, sparkle
    }
    var part: Part
    var bar: Int
    /// 小節内の 16 分の位置
    var step: Int
    /// 16 分の数
    var length: Int
    var midi: Int
    var velocity: Float
    /// 16 分より細かいずれ(0..<1 ステップ。3 連符に使う)
    var micro: Double = 0
}

/// 1 曲ぶんの楽譜
struct BGMScore {
    /// 小節ごとのコード(小節の頭のコード)
    var chords: [BGMGenerator.BarChord]
    var sections: [BGMGenerator.Section]
    /// パートごとにまとまって並ぶ(パッド・伴奏は同時に鳴る音が続けて並ぶ)
    var notes: [ScoreNote]
    /// 曲ごとの音色・ミックスの違い
    var sound: BGMSoundDesign
}

/// 曲のジャンル(作曲の性格を決める)
enum BGMGenre: Int {
    case ballad, pop, jazz, bossa, house, march, cute, horror, variety
}

/// 主旋律の楽器(pluckTone とは別に選ぶ)
enum BGMLeadInstrument: Int {
    case piano, brightPiano, stringsLegato, softBell, pluck, marimba, ePiano, mutedGuitar, vibraphone,
         supersaw, musicBox, glassFM, lowStrings, koto, shakuhachi, brass
}

/// 曲ごとの音色・ミックスのばらつき
struct BGMSoundDesign {
    var lead: BGMLeadInstrument
    /// 明るさ(カットオフ・弦の明るさ・FM の深さ)の倍率
    var leadCutoff: Double
    var arpCutoff: Double
    var compCutoff: Double
    /// エンベロープ(アタック・減衰・余韻)の倍率
    var leadEnv: Double
    var arpEnv: Double
    var compEnv: Double
    /// デチューンの倍率
    var detune: Double
    /// パッドのコーラスの深さの倍率
    var chorusDepth: Double
    /// 左右の広がり(0.6〜1)
    var width: Float
    var leadPan: Float
    var counterPan: Float
    var arpPan: Float
    var compOffset: Float
    /// リバーブの大きさに足す量と、プリディレイ(秒)
    var reverbSize: Double
    var preDelay: Double
    /// 主旋律を 1 オクターブ下で弾く(低い弦)
    var leadOctave: Int
}

enum BGMComposer {
    typealias Random = BGMGenerator.Random
    typealias BarChord = BGMGenerator.BarChord
    typealias Section = BGMGenerator.Section

    // MARK: - 種(用途ごとに分ける)

    enum Stream: UInt64 {
        case style = 0x5354_594C_0000_0001
        case chord = 0x5354_594C_0000_0002
        case lead = 0x5354_594C_0000_0003
        case chorus = 0x5354_594C_0000_0004
        case counter = 0x5354_594C_0000_0005
        case comp = 0x5354_594C_0000_0006
        case arp = 0x5354_594C_0000_0007
        case bass = 0x5354_594C_0000_0008
        case sparkle = 0x5354_594C_0000_0009
        case sound = 0x5354_594C_0000_000A
    }

    /// 曲の種(variant > 0 は他の曲と同じ組み合わせになったときのずらし)
    static func baseSeed(_ preset: BGMPreset, variant: Int) -> UInt64 {
        let s = BGMGenerator.seed(for: preset.id)
        return variant == 0 ? s : s ^ (UInt64(variant) &* 0x9E37_79B9_7F4A_7C15)
    }

    static func rng(_ base: UInt64, _ stream: Stream) -> Random {
        Random(seed: base ^ stream.rawValue)
    }

    // MARK: - ジャンル

    static func genre(of p: BGMPreset) -> BGMGenre {
        if p.mood == .horror { return .horror }
        if p.drums == .march { return .march }
        if p.drums == .house || p.mood == .party { return .house }
        if p.drumPattern == 3, [BGMMood.meal, .stylish, .slowLiving].contains(p.mood) { return .bossa }
        if p.drums == .lofi || p.sevenths || p.swing >= 0.15 { return .jazz }
        if p.mood == .cute { return .cute }
        if p.mood == .variety { return .variety }
        if [BGMMood.emotional, .calm, .natural, .slowLiving, .tense, .mysterious].contains(p.mood) { return .ballad }
        if p.drums == .none || p.drums == .soft, p.bpm < 90 { return .ballad }
        return .pop
    }

    /// ジャンルの記号(リズム型のタグに使う)
    static let genreLetters: [Character] = ["B", "P", "J", "S", "H", "M", "C", "X", "V"]

    // ジャンル別の既定値(BGMGenre の順)
    static let densityBias: [Double] = [0.25, 0.55, 0.45, 0.5, 0.6, 0.6, 0.65, 0.15, 0.5]
    static let syncBias: [Double] = [0.15, 0.4, 0.6, 0.55, 0.55, 0.2, 0.35, 0.2, 0.45]
    static let legatoBias: [Double] = [0.85, 0.5, 0.55, 0.5, 0.3, 0.35, 0.3, 0.8, 0.15]
    static let registerBias: [Int] = [0, 0, -1, 0, 1, 0, 3, -3, 1]
    /// 輪郭の型(0 アーチ / 1 下降 / 2 上昇 / 3 波 / 4 同音反復 / 5 跳躍して下降)の重み
    static let contourWeights: [[Double]] = [
        [3, 2, 1, 1, 0.5, 3],
        [2, 1, 2, 2, 2, 1],
        [1, 2, 1, 3, 1, 2],
        [1, 2, 1, 3, 1, 1],
        [1, 1, 1, 2, 4, 1],
        [2, 1, 3, 1, 2, 1],
        [2, 1, 2, 3, 2, 1],
        [1, 3, 1, 2, 1, 2],
        [1, 1, 2, 2, 3, 1]
    ]
    /// 味付けの確率: 副属七 / iv 借用 / sus4→3 / 経過和音 / 転回形ベース / ペダル
    static let colourProbs: [[Double]] = [
        [0.20, 0.15, 0.15, 0.10, 0.15, 0.45],
        [0.15, 0.10, 0.12, 0.10, 0.10, 0.20],
        [0.30, 0.10, 0.05, 0.15, 0.05, 0.15],
        [0.25, 0.10, 0.05, 0.15, 0.05, 0.20],
        [0.05, 0.05, 0.10, 0.05, 0.05, 0.40],
        [0.15, 0.00, 0.05, 0.10, 0.10, 0.10],
        [0.12, 0.08, 0.10, 0.10, 0.08, 0.15],
        [0.00, 0.00, 0.10, 0.05, 0.00, 0.60],
        [0.12, 0.05, 0.08, 0.12, 0.08, 0.15]
    ]

    // MARK: - 主旋律のリズム型(1 小節。(位置, 長さ) は 16 分)

    struct RhythmTemplate {
        var tags: String
        var notes: [(Int, Int)]
    }

    static let rhythms4: [RhythmTemplate] = [
        RhythmTemplate(tags: "MBP", notes: [(0, 4), (4, 4), (8, 4), (12, 4)]),
        RhythmTemplate(tags: "BX", notes: [(0, 8), (8, 8)]),
        RhythmTemplate(tags: "BX", notes: [(0, 12), (12, 4)]),
        RhythmTemplate(tags: "BX", notes: [(0, 16)]),
        RhythmTemplate(tags: "CPV", notes: [(0, 2), (2, 2), (4, 2), (6, 2), (8, 2), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "MC", notes: [(0, 6), (6, 2), (8, 6), (14, 2)]),
        RhythmTemplate(tags: "MC", notes: [(0, 3), (3, 1), (4, 3), (7, 1), (8, 3), (11, 1), (12, 4)]),
        RhythmTemplate(tags: "PH", notes: [(0, 4), (6, 2), (8, 4), (14, 2)]),
        RhythmTemplate(tags: "JP", notes: [(2, 2), (4, 4), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "PHS", notes: [(0, 3), (3, 3), (6, 2), (8, 8)]),
        RhythmTemplate(tags: "S", notes: [(0, 3), (3, 3), (6, 4), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "PH", notes: [(0, 2), (2, 4), (6, 2), (8, 2), (10, 4), (14, 2)]),
        RhythmTemplate(tags: "VH", notes: [(0, 2), (3, 1), (6, 2), (8, 2), (11, 1), (14, 2)]),
        RhythmTemplate(tags: "V", notes: [(0, 1), (2, 1), (4, 1), (8, 1), (10, 1), (12, 1)]),
        RhythmTemplate(tags: "BJ", notes: [(0, 6), (6, 6), (12, 4)]),
        RhythmTemplate(tags: "JBX", notes: [(4, 4), (8, 8)]),
        RhythmTemplate(tags: "PB", notes: [(0, 4), (4, 2), (6, 6), (12, 4)]),
        RhythmTemplate(tags: "CP", notes: [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "CM", notes: [(0, 2), (2, 2), (4, 2), (6, 2), (8, 8)]),
        RhythmTemplate(tags: "XB", notes: [(0, 8), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "HV", notes: [(0, 2), (6, 2), (8, 2), (14, 2)]),
        RhythmTemplate(tags: "JH", notes: [(2, 4), (6, 4), (10, 6)]),
        RhythmTemplate(tags: "JS", notes: [(0, 3), (3, 5), (8, 3), (11, 5)]),
        RhythmTemplate(tags: "CMP", notes: [(0, 2), (2, 2), (4, 2), (6, 2), (8, 2), (10, 2), (12, 2), (14, 2)]),
        RhythmTemplate(tags: "P", notes: [(0, 4), (8, 2), (10, 2), (12, 2), (14, 2)]),
        RhythmTemplate(tags: "CV", notes: [(0, 1), (1, 1), (2, 2), (4, 4), (8, 1), (9, 1), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "XB", notes: [(0, 10), (10, 6)]),
        RhythmTemplate(tags: "JP", notes: [(6, 2), (8, 4), (12, 4)]),
        RhythmTemplate(tags: "SJ", notes: [(0, 6), (6, 2), (8, 2), (10, 6)]),
        // 追加 29〜44: 16 分のずれ・食い(アンティシペーション)・3 対 4・1 拍目の休みなど、8 分の格子に乗らない型
        RhythmTemplate(tags: "PBS", notes: [(0, 3), (3, 5), (8, 2), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "PV", notes: [(0, 2), (3, 3), (6, 2), (8, 2), (11, 3), (14, 2)]),
        RhythmTemplate(tags: "JS", notes: [(1, 3), (4, 2), (6, 2), (9, 3), (12, 4)]),
        RhythmTemplate(tags: "HV", notes: [(0, 1), (3, 1), (6, 2), (9, 1), (12, 1), (14, 2)]),
        RhythmTemplate(tags: "BM", notes: [(0, 5), (5, 3), (8, 5), (13, 3)]),
        RhythmTemplate(tags: "CP", notes: [(0, 2), (2, 2), (4, 2), (7, 1), (8, 2), (11, 1), (12, 4)]),
        RhythmTemplate(tags: "JX", notes: [(0, 2), (5, 3), (8, 2), (13, 3)]),
        RhythmTemplate(tags: "PH", notes: [(2, 2), (4, 2), (6, 2), (8, 4), (13, 3)]),
        RhythmTemplate(tags: "SJ", notes: [(0, 3), (3, 3), (6, 3), (9, 3), (12, 4)]),
        RhythmTemplate(tags: "MP", notes: [(0, 4), (4, 3), (7, 1), (8, 2), (10, 2), (12, 2), (14, 2)]),
        RhythmTemplate(tags: "BC", notes: [(0, 6), (6, 2), (8, 4), (12, 2), (14, 2)]),
        RhythmTemplate(tags: "VC", notes: [(0, 1), (1, 1), (2, 1), (4, 2), (8, 1), (9, 1), (10, 1), (12, 2)]),
        RhythmTemplate(tags: "HS", notes: [(1, 1), (2, 2), (5, 1), (6, 2), (9, 1), (10, 2), (13, 1), (14, 2)]),
        RhythmTemplate(tags: "BX", notes: [(0, 10), (10, 2), (12, 4)]),
        RhythmTemplate(tags: "JP", notes: [(2, 2), (6, 2), (8, 3), (11, 1), (12, 4)]),
        RhythmTemplate(tags: "MC", notes: [(0, 2), (4, 2), (6, 1), (7, 1), (8, 2), (12, 2), (14, 1), (15, 1)])
    ]

    static let rhythms3: [RhythmTemplate] = [
        RhythmTemplate(tags: "BMPC", notes: [(0, 4), (4, 4), (8, 4)]),
        RhythmTemplate(tags: "BX", notes: [(0, 8), (8, 4)]),
        RhythmTemplate(tags: "BX", notes: [(0, 12)]),
        RhythmTemplate(tags: "MCP", notes: [(0, 6), (6, 2), (8, 4)]),
        RhythmTemplate(tags: "PC", notes: [(0, 4), (4, 2), (6, 2), (8, 4)]),
        RhythmTemplate(tags: "CV", notes: [(0, 2), (2, 2), (4, 2), (6, 2), (8, 4)]),
        RhythmTemplate(tags: "CP", notes: [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2)]),
        RhythmTemplate(tags: "JBX", notes: [(4, 4), (8, 4)]),
        RhythmTemplate(tags: "BJS", notes: [(0, 6), (6, 6)]),
        RhythmTemplate(tags: "JSH", notes: [(0, 3), (3, 3), (6, 3), (9, 3)]),
        RhythmTemplate(tags: "PJ", notes: [(0, 4), (6, 2), (8, 4)]),
        RhythmTemplate(tags: "VH", notes: [(0, 2), (4, 2), (6, 2), (8, 2), (10, 2)]),
        // 追加 12〜17: 16 分のずれ・食いを含む 3 拍子の型
        RhythmTemplate(tags: "PJ", notes: [(0, 3), (3, 1), (4, 4), (8, 4)]),
        RhythmTemplate(tags: "CV", notes: [(0, 2), (3, 1), (4, 2), (6, 2), (9, 1), (10, 2)]),
        RhythmTemplate(tags: "BS", notes: [(0, 5), (5, 3), (8, 4)]),
        RhythmTemplate(tags: "HM", notes: [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2)]),
        RhythmTemplate(tags: "JX", notes: [(1, 3), (4, 2), (6, 2), (8, 4)]),
        RhythmTemplate(tags: "PC", notes: [(0, 4), (4, 1), (5, 1), (6, 2), (8, 4)])
    ]

    /// 密度・シンコペに近く、ジャンルに合う型ほど選ばれやすい
    static func pickRhythm(genre: BGMGenre, density: Double, sync: Double, waltz: Bool, rng: inout Random) -> Int {
        let table = waltz ? rhythms3 : rhythms4
        let letter = genreLetters[genre.rawValue]
        var weights: [Double] = []
        for t in table {
            let d = min(1, Double(t.notes.count) / (waltz ? 6 : 8))
            let offbeat = t.notes.filter { $0.0 % 4 != 0 }.count
            let s = Double(offbeat) / Double(max(t.notes.count, 1))
            let g = t.tags.contains(letter) ? 3.0 : 0.5
            weights.append(g / (0.15 + abs(d - density) + abs(s - sync)))
        }
        return weightedPick(weights, rng: &rng)
    }

    static func weightedPick(_ weights: [Double], rng: inout Random) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var r = rng.unit() * total
        for (i, w) in weights.enumerated() {
            if r < w { return i }
            r -= w
        }
        return weights.count - 1
    }

    // MARK: - 旋律の発展の型(フック = 1 単位目。残り 3 単位をどう作るか)

    enum Dev {
        case again
        case seq(Int)
        case invert
        case shift
        case augment
        case diminish
        case fresh
    }

    static let forms: [[Dev]] = [
        [.seq(1), .fresh, .again],
        [.again, .fresh, .seq(-1)],
        [.invert, .seq(2), .again],
        [.shift, .fresh, .augment],
        [.seq(-1), .diminish, .again],
        [.fresh, .again, .invert],
        [.diminish, .seq(1), .fresh],
        [.again, .invert, .augment]
    ]

    static func formHasFresh(_ f: Int) -> Bool {
        forms[f].contains { if case .fresh = $0 { return true } else { return false } }
    }

    // MARK: - 伴奏の型((位置, 長さ, 弾く音) 弾く音: -1 全部 / -2 いちばん下 / -3 上の音 / 0〜3 その声部)

    static let F = -1, L = -2, U = -3
    static let compTables: [[[(Int, Int, Int)]]] = [
        // バラード
        [[(0, 16, F)], [(0, 8, F), (8, 8, F)], [(0, 4, 0), (4, 4, 1), (8, 4, 2), (12, 4, 3)], [(0, 4, L), (4, 12, U)],
         [(0, 2, 0), (2, 2, 1), (4, 2, 2), (6, 2, 1), (8, 2, 0), (10, 2, 1), (12, 2, 2), (14, 2, 1)]],
        // ポップ
        [[(0, 2, F), (2, 2, U), (4, 2, F), (6, 2, U), (8, 2, F), (10, 2, U), (12, 2, F), (14, 2, U)],
         [(0, 6, F), (6, 4, F), (10, 6, F)],
         [(0, 3, F), (3, 3, F), (6, 2, F), (8, 3, F), (11, 3, F), (14, 2, F)],
         [(0, 2, F), (3, 1, U), (4, 2, F), (6, 2, U), (8, 2, F), (11, 1, U), (12, 2, F), (14, 2, U)],
         [(0, 4, F), (4, 4, F), (8, 4, F), (12, 4, F)],
         [(0, 8, F), (10, 2, U), (12, 4, F)]],
        // ジャズ・ローファイ
        [[(0, 6, F), (6, 4, F)], [(2, 2, F), (6, 2, U), (10, 4, F)], [(0, 4, F), (7, 1, U), (14, 2, F)],
         [(4, 4, F), (12, 4, F)], [(0, 8, F), (11, 5, F)], [(2, 4, U), (8, 2, F), (14, 2, F)]],
        // ボサノバ
        [[(0, 3, L), (3, 3, U), (6, 2, U), (8, 3, L), (11, 3, U), (14, 2, U)],
         [(0, 2, L), (2, 2, U), (6, 2, U), (8, 2, L), (10, 2, U), (12, 2, U)],
         [(0, 3, F), (3, 3, F), (6, 4, F), (10, 3, F), (13, 3, F)],
         [(0, 2, L), (3, 2, U), (6, 2, U), (10, 2, U), (12, 2, L), (14, 2, U)]],
        // ハウス・パーティー
        [[(2, 1, F), (6, 1, F), (10, 1, F), (14, 1, F)], [(2, 2, F), (6, 2, F), (10, 2, F), (14, 2, F)],
         [(0, 1, F), (3, 1, F), (6, 1, F), (10, 1, F), (12, 1, F)], [(3, 1, F), (6, 2, F), (11, 1, F), (14, 2, F)]],
        // マーチ
        [[(4, 2, F), (12, 2, F)], [(0, 2, L), (4, 2, U), (8, 2, L), (12, 2, U)],
         [(0, 2, L), (2, 2, U), (4, 2, L), (6, 2, U), (8, 2, L), (10, 2, U), (12, 2, L), (14, 2, U)],
         [(0, 4, F), (4, 4, F), (8, 4, F), (12, 4, F)]],
        // かわいい
        [[(0, 2, F), (4, 2, F), (6, 2, U), (8, 2, F), (12, 2, F), (14, 2, U)],
         [(0, 2, L), (2, 2, U), (4, 2, L), (6, 2, U), (8, 2, L), (10, 2, U), (12, 2, L), (14, 2, U)],
         [(0, 3, F), (4, 2, F), (8, 3, F), (12, 2, F)],
         [(0, 2, 0), (2, 2, 2), (4, 2, 1), (6, 2, 2), (8, 2, 0), (10, 2, 2), (12, 2, 1), (14, 2, 2)]],
        // ホラー
        [[(0, 16, F)], [(0, 4, 0), (8, 8, U)], [(0, 2, L), (10, 6, U)], [(6, 10, F)]],
        // バラエティ
        [[(0, 1, F), (4, 1, F), (8, 1, F), (12, 1, F)], [(0, 1, F), (3, 1, F), (8, 1, F), (10, 1, F)],
         [(2, 1, F), (4, 1, F), (10, 1, F), (12, 1, F)], [(0, 2, F), (6, 1, F), (8, 2, F), (14, 1, F)]]
    ]
    /// 3 拍子(どのジャンルでも)
    static let compWaltz: [[(Int, Int, Int)]] = [
        [(0, 4, L), (4, 4, U), (8, 4, U)], [(0, 4, L), (4, 2, U), (8, 2, U)],
        [(0, 2, 0), (2, 2, 1), (4, 2, 2), (6, 2, 3), (8, 2, 2), (10, 2, 1)],
        [(0, 12, F)], [(0, 6, F), (6, 6, F)], [(0, 4, L), (4, 8, U)]
    ]

    // MARK: - ベースの型((位置, 長さ, 音) 音: 0 ルート / 1 5 度 / 2 オクターブ上 / 3 3 度。空 = ウォーキング)

    static let bassTables: [[[(Int, Int, Int)]]] = [
        [[(0, 16, 0)], [(0, 8, 0), (8, 8, 1)], [(0, 12, 0), (12, 4, 1)], [(0, 8, 0), (8, 4, 1), (12, 4, 2)]],
        [[(0, 6, 0), (6, 2, 1), (8, 6, 0), (14, 2, 2)],
         [(0, 2, 0), (2, 2, 0), (4, 2, 0), (6, 2, 0), (8, 2, 0), (10, 2, 0), (12, 2, 0), (14, 2, 0)],
         [(0, 3, 0), (3, 3, 0), (6, 2, 1), (8, 6, 0), (14, 2, 1)],
         [(0, 4, 0), (6, 2, 0), (8, 4, 1), (14, 2, 2)],
         [(0, 6, 0), (6, 6, 0), (12, 4, 1)]],
        [[], [(0, 7, 0), (7, 3, 0), (10, 6, 1)], [(0, 6, 0), (6, 2, 3), (8, 8, 1)], [(0, 10, 0), (10, 2, 1), (12, 4, 2)]],
        [[(0, 6, 0), (6, 2, 1), (8, 6, 1), (14, 2, 0)], [(0, 6, 0), (6, 2, 0), (8, 6, 1), (14, 2, 1)], []],
        [[(0, 2, 0), (2, 2, 2), (4, 2, 0), (6, 2, 2), (8, 2, 0), (10, 2, 2), (12, 2, 0), (14, 2, 2)],
         [(2, 2, 0), (6, 2, 0), (10, 2, 0), (14, 2, 0)],
         [(0, 3, 0), (3, 1, 2), (6, 2, 0), (8, 3, 0), (11, 1, 2), (14, 2, 1)]],
        [[(0, 4, 0), (4, 4, 1), (8, 4, 0), (12, 4, 1)], [(0, 2, 0), (4, 2, 1), (8, 2, 0), (12, 2, 1)],
         [(0, 4, 0), (4, 4, 1), (8, 4, 2), (12, 4, 1)]],
        [[(0, 2, 0), (4, 2, 1), (8, 2, 0), (12, 2, 1)],
         [(0, 4, 0), (4, 2, 1), (6, 2, 2), (8, 4, 0), (12, 2, 1), (14, 2, 2)],
         [(0, 4, 0), (6, 2, 1), (8, 4, 2), (12, 4, 1)]],
        [[(0, 16, 0)], [(0, 4, 0), (8, 8, 0)], [(0, 2, 0), (4, 2, 0)]],
        [[(0, 2, 0), (4, 2, 0), (8, 2, 1), (12, 2, 0)], [(0, 2, 0), (3, 1, 0), (8, 2, 1), (14, 2, 2)],
         [(0, 2, 0), (6, 2, 1), (8, 2, 2), (12, 2, 1)]]
    ]
    static let bassWaltz: [[(Int, Int, Int)]] = [
        [(0, 4, 0)], [(0, 4, 0), (4, 4, 1), (8, 4, 1)], [(0, 8, 0), (8, 4, 1)], [(0, 4, 0), (8, 4, 1)]
    ]

    // MARK: - 主旋律の楽器(ジャンル別)

    static let leadChoices: [[BGMLeadInstrument]] = [
        [.piano, .stringsLegato, .softBell],
        [.pluck, .brightPiano, .marimba],
        [.ePiano, .mutedGuitar, .vibraphone],
        [.mutedGuitar, .ePiano, .vibraphone],
        [.supersaw, .pluck],
        [.brass, .brightPiano, .marimba],
        [.softBell, .marimba, .musicBox],
        [.musicBox, .glassFM, .lowStrings],
        [.marimba, .pluck, .brightPiano]
    ]
    static let japaneseLeads: [BGMLeadInstrument] = [.koto, .shakuhachi]
    /// 定位の並び(主旋律, 対旋律, アルペジオ(±), 伴奏の中心)
    static let panLayouts: [(Float, Float, Float, Float)] = [
        (0.1, -0.3, 0.3, 0), (-0.1, 0.3, 0.4, 0.1), (0, -0.4, 0.2, -0.1), (0.15, 0.35, 0.35, -0.15)
    ]

    // MARK: - 曲ごとの選択(安い。重複チェックにも使う)

    struct Choices {
        var genre: BGMGenre
        var energy: Double
        var density: Double
        var syncopation: Double
        var legato: Double
        var register: Int
        var contour: Int
        var hookForm: Int
        var verse2Form: Int
        var chorusForm: Int
        var chorusContour: Int
        var counterMode: Int
        var bPrimeOctave: Bool
        var compA: Int
        var compB: Int
        var arpA: Int
        var arpB: Int
        /// 0 = 8 分 / 1 = 16 分 / 2 = 3 連 / 3 = 付点
        var rateA: Int
        var rateB: Int
        var bassA: Int
        var bassB: Int
        var verseRhythms: [Int]
        var chorusRhythms: [Int]
        /// [周回 0/1][進行の位置] 0 なし / 1 副属七 / 2 iv 借用 / 3 sus4→3 / 4 経過和音 / 5 転回形ベース
        var colour: [[Int]]
        var pedalIntro: Bool
        var pedalVerse: Bool
        // 作曲の続きに使う乱数(選択のあとの状態)
        var leadRNG: Random
        var chorusRNG: Random
        var arpRNG: Random
        var bassRNG: Random
        var base: UInt64
    }

    static func choices(preset: BGMPreset, variant: Int) -> Choices {
        let base = baseSeed(preset, variant: variant)
        let g = genre(of: preset)
        let gi = g.rawValue
        let waltz = preset.beatsPerBar == 3

        // 作曲の性格
        var s = rng(base, .style)
        var energy = min(max((preset.bpm - 60) / 80, 0), 1)
        switch preset.drums {
        case .none: energy -= 0.25
        case .soft: energy -= 0.1
        case .pop: energy += 0.1
        case .lofi: energy -= 0.05
        case .house: energy += 0.25
        case .heartbeat: energy -= 0.3
        case .march: energy += 0.15
        }
        energy = min(max(energy, 0), 1)
        let density = min(max(densityBias[gi] + 0.3 * (energy - 0.5) + s.uniform(-0.15...0.15), 0.05), 0.95)
        let sync = min(max(syncBias[gi] + s.uniform(-0.15...0.15), 0), 0.9)
        let legato = min(max(legatoBias[gi] + s.uniform(-0.1...0.1), 0.05), 0.95)
        let register = 72 + s.int(7) + registerBias[gi]
        let contour = weightedPick(contourWeights[gi], rng: &s)
        let hookForm = s.int(8)
        let verse2Form = (hookForm + 1 + s.int(7)) % 8
        let chorusForm = s.int(8)
        let chorusContour = (contour + 1 + s.int(5)) % 6
        let counterMode = s.int(3)
        let bPrimeOctave = s.chance(0.5)

        // 伴奏
        var c = rng(base, .comp)
        let compCount = waltz ? compWaltz.count : compTables[gi].count
        let compA = c.int(compCount)
        let compB = compCount > 1 ? (compA + 1 + c.int(compCount - 1)) % compCount : compA

        // アルペジオ
        var a = rng(base, .arp)
        let arpA = a.int(8)
        let arpB = (arpA + 1 + a.int(7)) % 8
        let rateWeights: [Double] = preset.bpm < 90 ? [1, 3, 2, 1] : (preset.bpm <= 115 ? [2, 2, 1, 2] : [3, 0.5, 0.5, 2])
        var rateA = weightedPick(rateWeights, rng: &a)
        var rateB = a.chance(0.5) ? rateA : weightedPick(rateWeights, rng: &a)
        if waltz {
            if rateA == 2 { rateA = 0 }
            if rateB == 2 { rateB = 0 }
        }
        // 伴奏が忙しいときはアルペジオを 8 分にする(同時に忙しくしない)
        let compPattern = waltz ? compWaltz[compA] : compTables[gi][compA]
        if compPattern.count >= 6 {
            if rateA == 1 || rateA == 2 { rateA = 0 }
            if rateB == 1 || rateB == 2 { rateB = 0 }
        }

        // ベース
        var b = rng(base, .bass)
        let bassCount = waltz ? bassWaltz.count : bassTables[gi].count
        let bassA = b.int(bassCount)
        let bassB = bassCount > 1 ? (bassA + 1 + b.int(bassCount - 1)) % bassCount : bassA

        // 主旋律のリズム型
        var l = rng(base, .lead)
        let r1 = pickRhythm(genre: g, density: density, sync: sync, waltz: waltz, rng: &l)
        let r2 = pickRhythm(genre: g, density: density - 0.15, sync: sync, waltz: waltz, rng: &l)
        let r3 = pickRhythm(genre: g, density: density + 0.1, sync: sync + 0.1, waltz: waltz, rng: &l)
        let r4 = pickRhythm(genre: g, density: density - 0.1, sync: sync, waltz: waltz, rng: &l)
        var ch = rng(base, .chorus)
        let c1 = pickRhythm(genre: g, density: density + 0.2, sync: sync + 0.05, waltz: waltz, rng: &ch)
        let c2 = pickRhythm(genre: g, density: density + 0.05, sync: sync, waltz: waltz, rng: &ch)
        let c3 = pickRhythm(genre: g, density: density + 0.25, sync: sync + 0.1, waltz: waltz, rng: &ch)
        let c4 = pickRhythm(genre: g, density: density, sync: sync, waltz: waltz, rng: &ch)

        // コードの味付け
        var h = rng(base, .chord)
        let count = max(preset.progression.count, 1)
        let probs = colourProbs[gi]
        var colour: [[Int]] = []
        for _ in 0..<2 {
            var row: [Int] = []
            for _ in 0..<count {
                let u = h.unit()
                var cum = 0.0
                var code = 0
                for k in 0..<5 {
                    cum += probs[k]
                    if u < cum { code = k + 1; break }
                }
                row.append(code)
            }
            colour.append(row)
        }
        let pedalIntro = h.chance(0.5)
        let pedalVerse = h.chance(probs[5])

        return Choices(genre: g, energy: energy, density: density, syncopation: sync, legato: legato,
                       register: register, contour: contour, hookForm: hookForm, verse2Form: verse2Form,
                       chorusForm: chorusForm, chorusContour: chorusContour, counterMode: counterMode,
                       bPrimeOctave: bPrimeOctave, compA: compA, compB: compB, arpA: arpA, arpB: arpB,
                       rateA: rateA, rateB: rateB, bassA: bassA, bassB: bassB,
                       verseRhythms: [r1, r2, r3, r4], chorusRhythms: [c1, c2, c3, c4],
                       colour: colour, pedalIntro: pedalIntro, pedalVerse: pedalVerse,
                       leadRNG: l, chorusRNG: ch, arpRNG: a, bassRNG: b, base: base)
    }

    /// 曲の「組み合わせ」の指紋(全曲で重ならないようにする)
    static func fingerprint(preset: BGMPreset, _ c: Choices) -> String {
        let prog = preset.progression.map(String.init).joined(separator: ",")
        let col = c.colour.map { $0.map(String.init).joined() }.joined(separator: "/")
        let rh = c.verseRhythms.map(String.init).joined(separator: ",")
        return "\(preset.beatsPerBar)|\(prog)|\(col)|c\(c.compA)|a\(c.arpA).\(c.rateA)|b\(c.bassA)|r\(rh)|k\(c.contour)|h\(c.hookForm)"
    }

    // MARK: - 似ている度(主旋律)とずらし番号

    /// 主旋律の特徴(A の最初の 8 小節)。半音の間隔の列と、16 分の格子上の発音位置の集合
    struct LeadFeature {
        var intervals: [Int]
        var onsets: Set<Int>
    }

    /// この値以上に似ている曲があれば、その variant は使わない
    static let similarityThreshold = 0.38
    /// variant を試す上限(0...variantCap)
    static let variantCap = 64

    /// 編集距離(レーベンシュタイン)
    static func levenshtein(_ a: [Int], _ b: [Int]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 2 曲の主旋律の似ている度(0〜1)= (間隔の列の正規化した編集距離の類似 + 発音位置のジャカード) / 2
    static func similarity(_ a: LeadFeature, _ b: LeadFeature) -> Double {
        let m = max(a.intervals.count, b.intervals.count)
        let lev = m == 0 ? 1.0 : 1 - Double(levenshtein(a.intervals, b.intervals)) / Double(m)
        let union = a.onsets.union(b.onsets).count
        let jac = union == 0 ? 1.0 : Double(a.onsets.intersection(b.onsets).count) / Double(union)
        return (lev + jac) / 2
    }

    /// 似ている度の計算に使う曲の形(長い曲と同じ: イントロ 2 小節、A は 2〜9 小節目)
    static let featureIntroBars = 2
    static let featureBars = 8

    /// A の最初の 8 小節の主旋律を置いて特徴にする(compose と同じ手順・同じ乱数の順)
    static func leadFeature(preset: BGMPreset, _ ch: Choices) -> LeadFeature {
        guard preset.melody else { return LeadFeature(intervals: [], onsets: []) }
        let spb = max(preset.beatsPerBar, 2) * 4
        let bars = featureIntroBars + featureBars
        var classes: [[(Int, [Int])]] = []
        for bar in 0..<bars {
            let hc = barClasses(preset: preset, ch, bar: bar, introBars: featureIntroBars)
            var s: [(Int, [Int])] = [(0, hc.first)]
            if let second = hc.second { s.append((spb / 2, second)) }
            classes.append(s)
        }
        let ctx = LeadContext(preset: preset, ch: ch, spb: spb, introBars: featureIntroBars, totalBars: bars, classes: classes)
        var lrng = ch.leadRNG
        let vr = ch.verseRhythms
        let hook = cell(vr[0], vr[1], contour: ch.contour, offset: 0, spb: spb, waltz: ctx.waltz, rng: &lrng)
        let fresh = formHasFresh(ch.hookForm)
            ? cell(vr[2], vr[3], contour: (ch.contour + 2) % 6, offset: 2, spb: spb, waltz: ctx.waltz, rng: &lrng) : []
        let verse = phrase(hook: hook, form: ch.hookForm, fresh: fresh, spb: spb, legato: ch.legato)
        let placed = place(verse, startBar: featureIntroBars, offsetBars: 0, bars: featureBars, center: ch.register, prevMidi: nil, ctx: ctx)
        var intervals: [Int] = []
        var onsets = Set<Int>()
        for (i, p) in placed.enumerated() {
            if i > 0 { intervals.append(p.midi - placed[i - 1].midi) }
            onsets.insert((p.bar - featureIntroBars) * spb + p.step)
        }
        return LeadFeature(intervals: intervals, onsets: onsets)
    }

    /// ずらし番号と、採用した variant の主旋律の特徴
    struct DedupTable {
        var variants: [String: Int]
        var features: [String: LeadFeature]
    }

    /// BGMLibrary.all の順に variant k = 0, 1, 2… を試し、指紋が新しく、先に決まったどの曲とも
    /// 似ている度 < similarityThreshold の最初の k を採る。上限まで見つからなければ、指紋が新しい k のうち
    /// 「いちばん似ている曲との値」が最も小さい k。主旋律のない曲は指紋だけで決める。
    static let dedupTable: DedupTable = {
        var seen = Set<String>()
        var accepted: [LeadFeature] = []
        var variants: [String: Int] = [:]
        var features: [String: LeadFeature] = [:]
        for p in BGMLibrary.all {
            var chosen: (k: Int, fp: String, feat: LeadFeature?)? = nil
            var fallback: (k: Int, fp: String, feat: LeadFeature, maxSim: Double)? = nil
            for k in 0...variantCap {
                let c = choices(preset: p, variant: k)
                let fp = fingerprint(preset: p, c)
                if seen.contains(fp) { continue }
                guard p.melody else { chosen = (k, fp, nil); break }
                let feat = leadFeature(preset: p, c)
                var maxSim = 0.0
                for f in accepted { maxSim = max(maxSim, similarity(feat, f)) }
                if maxSim < similarityThreshold { chosen = (k, fp, feat); break }
                if fallback == nil || maxSim < fallback!.maxSim { fallback = (k, fp, feat, maxSim) }
            }
            let pick: (k: Int, fp: String, feat: LeadFeature?)
            if let chosen {
                pick = chosen
            } else if let fallback {
                pick = (fallback.k, fallback.fp, fallback.feat)
            } else {
                // 指紋がすべて重なった(まず起きない): variant 0 をそのまま使う
                let c = choices(preset: p, variant: 0)
                pick = (0, fingerprint(preset: p, c), p.melody ? leadFeature(preset: p, c) : nil)
            }
            seen.insert(pick.fp)
            if let f = pick.feat {
                accepted.append(f)
                features[p.id] = f
            }
            variants[p.id] = pick.k
        }
        return DedupTable(variants: variants, features: features)
    }()

    /// 曲ごとのずらし番号
    static var variantIndex: [String: Int] { dedupTable.variants }

    /// 採用した variant での主旋律の特徴(主旋律のない曲は空)
    static func leadFeature(of preset: BGMPreset) -> LeadFeature {
        if let f = dedupTable.features[preset.id] { return f }
        return leadFeature(preset: preset, choices(preset: preset, variant: variantIndex[preset.id] ?? 0))
    }

    /// 2 曲の主旋律の似ている度(0〜1)。どちらかに主旋律がなければ 0
    static func similarity(_ a: BGMPreset, _ b: BGMPreset) -> Double {
        guard a.melody, b.melody else { return 0 }
        return similarity(leadFeature(of: a), leadFeature(of: b))
    }

    /// 開発者向け: 全曲の中でいちばん似ている組(値と 2 曲の id)
    static func maxPairSimilarity() -> (value: Double, a: String, b: String) {
        let songs = BGMLibrary.all.filter { $0.melody }
        var best: (value: Double, a: String, b: String) = (0, "", "")
        guard songs.count > 1 else { return best }
        let feats = songs.map { leadFeature(of: $0) }
        for i in 0..<(songs.count - 1) {
            for j in (i + 1)..<songs.count {
                let s = similarity(feats[i], feats[j])
                if s > best.value { best = (s, songs[i].id, songs[j].id) }
            }
        }
        return best
    }

    // MARK: - 音色・ミックスのばらつき

    static func soundDesign(preset: BGMPreset, variant: Int) -> BGMSoundDesign {
        var r = rng(baseSeed(preset, variant: variant), .sound)
        let g = genre(of: preset)
        let list = (preset.scale == .yo || preset.scale == .miyakobushi) ? japaneseLeads : leadChoices[g.rawValue]
        let lead = list[r.int(list.count)]
        let leadCutoff = r.uniform(0.7...1.3)
        let arpCutoff = r.uniform(0.7...1.3)
        let compCutoff = r.uniform(0.7...1.3)
        let leadEnv = r.uniform(0.6...1.4)
        let arpEnv = r.uniform(0.6...1.4)
        let compEnv = r.uniform(0.6...1.4)
        let detune = r.uniform(0.6...1.4)
        let chorusDepth = r.uniform(0.7...1.3)
        let width = Float(r.uniform(0.6...1.0))
        let layout = panLayouts[r.int(panLayouts.count)]
        let reverbSize = r.uniform(-0.1...0.1)
        let preDelay = r.uniform(0.008...0.045)
        return BGMSoundDesign(lead: lead, leadCutoff: leadCutoff, arpCutoff: arpCutoff, compCutoff: compCutoff,
                              leadEnv: leadEnv, arpEnv: arpEnv, compEnv: compEnv, detune: detune,
                              chorusDepth: chorusDepth, width: width,
                              leadPan: layout.0 * width, counterPan: layout.1 * width, arpPan: layout.2 * width,
                              compOffset: layout.3, reverbSize: reverbSize, preDelay: preDelay,
                              leadOctave: lead == .lowStrings ? -12 : 0)
    }

    // MARK: - コード(声部連結つき)

    /// 小節の調と音階(liftToMajor の曲は 2 周目から 3 半音上の長調)
    static func keyScale(_ preset: BGMPreset, bar: Int, introBars: Int) -> (Int, BGMScale) {
        let count = max(preset.progression.count, 1)
        if preset.liftToMajor, bar >= introBars + count * 2 { return ((preset.key + 3) % 12, .major) }
        return (preset.key, preset.scale)
    }

    /// 小節のコードの音(前半 / 後半(なければ nil))と、転回形ベースにするか。味付けもここで入れる
    static func barClasses(preset: BGMPreset, _ ch: Choices, bar: Int, introBars: Int) -> (first: [Int], second: [Int]?, slash: Bool) {
        let progression = preset.progression.isEmpty ? [1] : preset.progression
        let count = progression.count
        let (key, scale) = keyScale(preset, bar: bar, introBars: introBars)
        let rel = bar - introBars + count * 64
        let pos = rel % count
        let cycle = (rel / count) % 2
        let degree = progression[pos]
        let nextDegree = progression[(pos + 1) % count]
        let baseClasses = BGMGenerator.chordClasses(degree: degree, key: key, scale: scale, sevenths: preset.sevenths)
        var first = baseClasses
        var second: [Int]? = nil
        var slash = false
        switch ch.colour[cycle][pos] {
        case 1:
            // 副属七(次のコードの 5 度上の属七を後半に)
            if [BGMScale.major, .minor, .dorian].contains(scale), nextDegree != 1, nextDegree != 7 {
                let nextRoot = BGMGenerator.chordClasses(degree: nextDegree, key: key, scale: scale, sevenths: false)[0]
                let r = (nextRoot + 7) % 12
                second = [r, (r + 4) % 12, (r + 7) % 12, (r + 10) % 12]
            }
        case 2:
            // 長調の iv(借用)
            if scale == .major, degree == 4 {
                let r = (key + 5) % 12
                var iv = [r, (r + 3) % 12, (r + 7) % 12]
                if preset.sevenths { iv.append((r + 10) % 12) }
                if nextDegree == 1 { second = iv } else { first = iv }
            }
        case 3:
            // sus4 → 3
            let r = baseClasses[0]
            first = [r, (r + 5) % 12, (r + 7) % 12]
            second = baseClasses
        case 4:
            // 後半に経過和音
            if nextDegree != degree {
                let pd = nextDegree > degree ? nextDegree - 1 : nextDegree + 1
                if pd != degree {
                    second = BGMGenerator.chordClasses(degree: pd, key: key, scale: scale, sevenths: preset.sevenths)
                }
            }
        case 5:
            slash = true
        default:
            break
        }
        return (first, second, slash)
    }

    /// コードの音(ピッチクラス、ルートが先頭)から BarChord を作る
    static func chord(classes: [Int], key: Int, scale: BGMScale, previous: [Int]?) -> BarChord {
        let voicing = BGMGenerator.voiceLead(classes: classes, previous: previous)
        let bassRoot = 36 + classes[0]
        let fifthClass = classes.count > 2 ? classes[2] : (classes[0] + 7) % 12
        var bassFifth = 36 + fifthClass
        if bassFifth < bassRoot { bassFifth += 12 }
        if bassFifth - bassRoot > 7 { bassFifth -= 12 }
        // アルペジオ: コードの音を 72〜83 に(5 音階なら近い音に寄せる)
        let melodic = scale.melodicIntervals
        var arp: [Int] = []
        for c in classes {
            var rel = (c - key + 12) % 12
            if !melodic.contains(rel) {
                rel = melodic.min { abs($0 - rel) < abs($1 - rel) } ?? rel
            }
            let m = 72 + (key + rel) % 12
            if !arp.contains(m) { arp.append(m) }
        }
        arp.sort()
        if let first = arp.first { arp.append(first + 12) }
        return BarChord(classes: classes, voicing: voicing, bassRoot: bassRoot, bassFifth: bassFifth, arp: arp)
    }

    /// 小節内のコード 1 つぶん
    struct Slot {
        var start: Int
        var chord: BarChord
        /// ベースのルート(転回形・ペダルを反映)
        var bass: Int
        var pedal: Bool
    }

    /// 旋律の 1 音(8 小節の句の中。idx は音域の中心からの音階上の距離)
    struct PNote {
        var step: Int
        var len: Int
        var idx: Int
        /// 0 普通 / 2 問いの終わり / 3 答えの終わり
        var role: Int
        /// レガートで短くする前の長さ(強拍の判定に使う。phrase で入れる)
        var tlen: Int = 0
    }

    /// 置いた旋律の 1 音
    struct Placed {
        var bar: Int
        var step: Int
        var len: Int
        var midi: Int
        var role: Int
    }

    // MARK: - 主旋律(作曲と「似ている度」の計算で同じ手順を使う)

    /// 主旋律を置くのに要るもの(小節ごとのコードの音と、旋律に使える音)
    struct LeadContext {
        var preset: BGMPreset
        var ch: Choices
        var spb: Int
        var introBars: Int
        var totalBars: Int
        var waltz: Bool
        /// 小節ごとの (始まりのステップ, コードの音)
        var classes: [[(Int, [Int])]]
        /// 小節ごとの旋律に使える音(48〜100)
        var pools: [[Int]]

        init(preset: BGMPreset, ch: Choices, spb: Int, introBars: Int, totalBars: Int, classes: [[(Int, [Int])]]) {
            self.preset = preset
            self.ch = ch
            self.spb = spb
            self.introBars = introBars
            self.totalBars = totalBars
            self.waltz = spb == 12
            self.classes = classes
            var list: [[Int]] = []
            list.reserveCapacity(max(totalBars, 0))
            for bar in 0..<max(totalBars, 0) {
                let (k, sc) = BGMComposer.keyScale(preset, bar: bar, introBars: introBars)
                var ivs = sc.melodicIntervals
                if ch.genre == .cute, sc == .major { ivs = [0, 2, 4, 7, 9] }
                var pl: [Int] = []
                for m in 48...100 where ivs.contains(((m - k) % 12 + 12) % 12) { pl.append(m) }
                list.append(pl)
            }
            self.pools = list
        }

        func keyScale(_ bar: Int) -> (Int, BGMScale) {
            BGMComposer.keyScale(preset, bar: bar, introBars: introBars)
        }

        /// その位置で鳴っているコードの音
        func chordClasses(_ bar: Int, _ step: Int) -> [Int] {
            let s = classes[bar]
            return (s.count > 1 && step >= s[1].0) ? s[1].1 : s[0].1
        }
    }

    /// pl の中で midi にいちばん近い音の番号(同じ近さなら前のもの)
    static func nearest(_ pl: [Int], _ midi: Int) -> Int {
        var best = 0
        for (i, m) in pl.enumerated() where abs(m - midi) < abs(pl[best] - midi) { best = i }
        return best
    }

    /// 2 小節の型(リズム型 2 つ+輪郭)
    static func cell(_ ra: Int, _ rb: Int, contour: Int, offset: Int, spb: Int, waltz: Bool, rng: inout Random) -> [PNote] {
        let table = waltz ? rhythms3 : rhythms4
        var steps: [(Int, Int)] = table[ra].notes
        steps += table[rb].notes.map { ($0.0 + spb, $0.1) }
        let n = steps.count
        let span = 3 + rng.int(3)
        let startOff = rng.int(3) - 1
        // 拍の頭でない音を 16 分 1 つ前か後ろへずらす(曲ごとにリズムの格子を変える)。
        // 2 小節の外に出る音は動かさない。ずらして音が重なるときは全部やめる
        let shift = rng.int(3) - 1
        if shift != 0 {
            let moved: [(Int, Int)] = steps.map { s in
                let t = s.0 + shift
                return (s.0 % 4 != 0 && t >= 0 && t < 2 * spb) ? (t, s.1) : s
            }
            if Set(moved.map { $0.0 }).count == moved.count { steps = moved }
        }
        var offs = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            switch contour {
            case 0: offs[i] = Int((Double(span) * sin(.pi * t)).rounded())
            case 1: offs[i] = Int((Double(span) * (1 - t)).rounded())
            case 2: offs[i] = Int((Double(span) * t).rounded())
            case 3: offs[i] = Int((Double(span) * 0.6 * sin(3 * .pi * t)).rounded())
            case 5: offs[i] = i == 0 ? 0 : max(span + 1 - (i - 1), -3)
            default: break
            }
        }
        if contour == 4 {
            let cells = [[0, 0, 1], [0, 0, -1], [0, 1, 0, -1]]
            let c = cells[rng.int(cells.count)]
            for i in 0..<n { offs[i] = c[i % c.count] }
            if n > 1 { offs[n - 1] = -1 }
        } else if n > 2 {
            for i in 1..<(n - 1) {
                if rng.chance(0.25) { offs[i] += rng.chance(0.5) ? 1 : -1 }
            }
        }
        return (0..<n).map { PNote(step: steps[$0].0, len: steps[$0].1, idx: offs[$0] + startOff + offset, role: 0) }
    }

    /// 8 小節の句(問い 4 小節+答え 4 小節)
    static func phrase(hook: [PNote], form: Int, fresh: [PNote], spb: Int, legato: Double) -> [PNote] {
        let unit = 2 * spb
        var out = hook
        for (k, dev) in forms[form].enumerated() {
            let off = (k + 1) * unit
            var cellNotes: [PNote]
            switch dev {
            case .again:
                cellNotes = hook
            case .seq(let d):
                cellNotes = hook.map { PNote(step: $0.step, len: $0.len, idx: $0.idx + d, role: 0) }
            case .invert:
                let f = hook.first?.idx ?? 0
                cellNotes = hook.map { PNote(step: $0.step, len: $0.len, idx: 2 * f - $0.idx, role: 0) }
            case .shift:
                cellNotes = hook.compactMap {
                    let s = $0.step + 2
                    return s < unit ? PNote(step: s, len: min($0.len, unit - s), idx: $0.idx, role: 0) : nil
                }
            case .augment:
                cellNotes = hook.filter { $0.step < spb }.compactMap {
                    let s = $0.step * 2
                    return s < unit ? PNote(step: s, len: min($0.len * 2, unit - s), idx: $0.idx, role: 0) : nil
                }
            case .diminish:
                let h = hook.map { PNote(step: $0.step / 2, len: max(1, $0.len / 2), idx: $0.idx, role: 0) }
                cellNotes = h + h.map { PNote(step: $0.step + spb, len: $0.len, idx: $0.idx + 1, role: 0) }
            case .fresh:
                cellNotes = fresh
            }
            if cellNotes.isEmpty { cellNotes = hook }
            out += cellNotes.map { PNote(step: $0.step + off, len: $0.len, idx: $0.idx, role: 0) }
        }
        // 並べ直し(同じ位置の音は先に作った方を残す。sort は安定とは限らないので元の順番も比べる)・重なりを除く
        let ordered = out.enumerated().sorted { (x, y) -> Bool in
            x.element.step != y.element.step ? x.element.step < y.element.step : x.offset < y.offset
        }
        var cleaned: [PNote] = []
        for item in ordered {
            if let last = cleaned.last, last.step == item.element.step { continue }
            cleaned.append(item.element)
        }
        for i in 0..<cleaned.count {
            let end = i + 1 < cleaned.count ? cleaned[i + 1].step : 8 * spb
            cleaned[i].len = max(1, min(cleaned[i].len, end - cleaned[i].step))
        }
        // 句の終わり(問い = 2 単位目の最後、答え = 4 単位目の最後)を伸ばして着地させる
        for (role, unitEnd) in [(2, 2 * unit), (3, 4 * unit)] {
            if let i = cleaned.lastIndex(where: { $0.step < unitEnd && $0.step >= unitEnd - unit }) {
                cleaned[i].role = role
                let next = i + 1 < cleaned.count ? cleaned[i + 1].step : 8 * spb
                cleaned[i].len = max(cleaned[i].len, min(min(next, unitEnd) - cleaned[i].step, spb))
            }
        }
        // 強拍の判定はレガートで短くする前の長さで(スタッカートの曲でも同じ型なら同じ音をコードの音にする)
        for i in 0..<cleaned.count { cleaned[i].tlen = cleaned[i].len }
        // レガート(短く切る曲もある)
        let factor = min(1.0, 0.45 + legato)
        for i in 0..<cleaned.count where cleaned[i].role == 0 {
            cleaned[i].len = max(1, Int((Double(cleaned[i].len) * factor).rounded()))
        }
        return cleaned
    }

    /// 句を小節に置く(強拍はコードの音、句の終わりは 2・5 度/主音、音域と跳躍を整える)。
    /// prevMidi は前のセクションの最後の音(このセクションのオクターブに直した高さ)。最初の音もそこから 9 半音以内にする
    static func place(_ ph: [PNote], startBar: Int, offsetBars: Int, bars: Int, center: Int, prevMidi: Int?, ctx: LeadContext) -> [Placed] {
        let spb = ctx.spb
        let lo = offsetBars * spb
        let hi = (offsetBars + bars) * spb
        var out: [Placed] = []
        for n in ph where n.step >= lo && n.step < hi {
            let rel = n.step - lo
            let bar = startBar + rel / spb
            let st = rel % spb
            guard bar < ctx.totalBars else { continue }
            let pl = ctx.pools[bar]
            guard !pl.isEmpty else { continue }
            let (key, sc) = ctx.keyScale(bar)
            var i = max(0, min(pl.count - 1, nearest(pl, center) + n.idx))
            let strong = st == 0 || (!ctx.waltz && st == 8) || n.tlen >= 6
            var targets: [Int] = []
            if n.role == 3 {
                targets = [key % 12]
            } else if n.role == 2 {
                targets = [(key + sc.intervals[1]) % 12, (key + sc.intervals[4]) % 12]
            } else if strong {
                let c = ctx.chordClasses(bar, st)
                targets = c
                if ctx.ch.genre == .jazz, ctx.preset.sevenths, let r = c.first { targets.append((r + 2) % 12) }
            }
            if !targets.isEmpty, !targets.contains(pl[i] % 12) {
                for d in [1, -1, 2, -2, 3, -3] {
                    let j = i + d
                    if j >= 0, j < pl.count, targets.contains(pl[j] % 12) { i = j; break }
                }
            }
            var midi = pl[i]
            // ホラー: 弱拍に半音の不協和な装飾
            if ctx.ch.genre == .horror, !strong, n.role == 0, (bar + st) % 3 == 0 { midi += 1 }
            out.append(Placed(bar: bar, step: st, len: n.len, midi: midi, role: n.role))
        }
        guard !out.isEmpty else { return out }
        // 音域(中心 ± 9 半音)
        let rLo = center - 9, rHi = center + 9
        for i in 0..<out.count {
            while out[i].midi > rHi { out[i].midi -= 12 }
            while out[i].midi < rLo { out[i].midi += 12 }
        }
        // 跳躍は 9 半音まで(セクションの最初の音は前のセクションの最後の音から)
        for i in 0..<out.count {
            let prev: Int
            if i > 0 {
                prev = out[i - 1].midi
            } else if let prevMidi {
                prev = prevMidi
            } else {
                continue
            }
            let d = out[i].midi - prev
            guard abs(d) > 9 else { continue }
            let alt = out[i].midi - (d > 0 ? 12 : -12)
            if alt >= rLo, alt <= rHi, abs(alt - prev) < abs(d) { out[i].midi = alt }
            if abs(out[i].midi - prev) > 9 {
                let pl = ctx.pools[out[i].bar]
                var j = nearest(pl, out[i].midi)
                while abs(pl[j] - prev) > 9 {
                    let nj = j + (prev > pl[j] ? 1 : -1)
                    if nj < 0 || nj >= pl.count { break }
                    j = nj
                }
                out[i].midi = pl[j]
            }
        }
        // 最高音は 1 回だけ(句の 6 割あたりに山を残す)
        for _ in 0..<2 {
            let top = out.map { $0.midi }.max() ?? 0
            let tops = out.indices.filter { out[$0].midi == top }
            guard tops.count > 1 else { break }
            let aim = Int(Double(out.count) * 0.6)
            let keep = tops.min { abs($0 - aim) < abs($1 - aim) } ?? tops[0]
            for i in tops where i != keep {
                let pl = ctx.pools[out[i].bar]
                let j = nearest(pl, out[i].midi) - 1
                guard j >= 0 else { continue }
                let m = pl[j]
                let okPrev = i == 0 ? (prevMidi.map { abs($0 - m) <= 9 } ?? true) : abs(out[i - 1].midi - m) <= 9
                let okNext = i == out.count - 1 || abs(out[i + 1].midi - m) <= 9
                if okPrev, okNext { out[i].midi = m }
            }
        }
        return out
    }

    // MARK: - 構成

    static func sectionPlan(totalBars: Int, introBars: Int, short: Bool) -> [Section] {
        let sectionBars = short ? 4 : 8
        let outroBars = short ? 1 : 2
        let cycle: [Section] = short ? [.b, .a, .bPrime, .aPrime] : [.a, .b, .aPrime, .bPrime]
        var out: [Section] = []
        for bar in 0..<max(totalBars, 0) {
            if bar < introBars { out.append(.intro); continue }
            if bar >= totalBars - outroBars - 1 { out.append(.outro); continue }
            out.append(cycle[((bar - introBars) / sectionBars) % cycle.count])
        }
        return out
    }

    // MARK: - 作曲

    static func compose(preset: BGMPreset, totalBars: Int, stepsPerBar spb: Int, introBars: Int, short: Bool) -> BGMScore {
        let variant = variantIndex[preset.id] ?? 0
        let ch = choices(preset: preset, variant: variant)
        let sound = soundDesign(preset: preset, variant: variant)
        let sections = sectionPlan(totalBars: totalBars, introBars: introBars, short: short)
        let gi = ch.genre.rawValue
        let waltz = spb == 12
        let half = spb / 2
        let sectionBars = short ? 4 : 8
        var notes: [ScoreNote] = []
        notes.reserveCapacity(totalBars * 40)

        func keyScale(_ bar: Int) -> (Int, BGMScale) {
            BGMComposer.keyScale(preset, bar: bar, introBars: introBars)
        }
        func isVerse(_ s: Section) -> Bool { s == .a || s == .aPrime }
        func isChorus(_ s: Section) -> Bool { s == .b || s == .bPrime }
        func blockStart(_ bar: Int) -> Int {
            var s = bar
            while s > 0, sections[s - 1] == sections[bar] { s -= 1 }
            return s
        }

        // ---------- コード(小節ごとに 1〜2 個) ----------
        var harmony: [[Slot]] = []
        harmony.reserveCapacity(totalBars)
        var previous: [Int]? = nil
        for bar in 0..<totalBars {
            let (key, scale) = keyScale(bar)
            let (first, second, slash) = barClasses(preset: preset, ch, bar: bar, introBars: introBars)
            let sec = sections[bar]
            var pedal = false
            if sec == .intro {
                pedal = ch.pedalIntro
            } else if isVerse(sec), ch.pedalVerse, bar - blockStart(bar) < 4 {
                pedal = true
            }
            let tonicBass = 36 + key % 12
            var slots: [Slot] = []
            let c1 = chord(classes: first, key: key, scale: scale, previous: previous)
            previous = c1.voicing
            var b1 = c1.bassRoot
            if slash, first.count > 1 {
                b1 = 36 + first[1]
                if b1 > c1.bassRoot + 7 { b1 -= 12 }
            }
            slots.append(Slot(start: 0, chord: c1, bass: pedal ? tonicBass : b1, pedal: pedal))
            if let second {
                let c2 = chord(classes: second, key: key, scale: scale, previous: previous)
                previous = c2.voicing
                slots.append(Slot(start: half, chord: c2, bass: pedal ? tonicBass : c2.bassRoot, pedal: pedal))
            }
            harmony.append(slots)
        }
        func slot(_ bar: Int, _ step: Int) -> Slot {
            let s = harmony[bar]
            return (s.count > 1 && step >= s[1].start) ? s[1] : s[0]
        }

        // ---------- 1. パッド(同じ声部が続くあいだは伸ばす) ----------
        if preset.pad {
            var runStart = 0                // 絶対ステップ
            var runBar = 0
            var runStep = 0
            var runVoicing: [Int] = []
            var runSection: Section = .intro
            var open = false
            func flush(endAbs: Int) {
                guard open else { return }
                let length = max(endAbs - runStart, 1)
                let vel: Float = runSection == .intro ? 0.8 : 1
                for m in runVoicing {
                    notes.append(ScoreNote(part: .pad, bar: runBar, step: runStep, length: length, midi: m, velocity: vel))
                }
            }
            for bar in 0..<totalBars {
                for s in harmony[bar] {
                    let abs = bar * spb + s.start
                    if open, s.chord.voicing == runVoicing, sections[bar] == runSection { continue }
                    flush(endAbs: abs)
                    open = true
                    runStart = abs
                    runBar = bar
                    runStep = s.start
                    runVoicing = s.chord.voicing
                    runSection = sections[bar]
                }
            }
            flush(endAbs: totalBars * spb)
        }

        // ---------- 2. 伴奏 ----------
        if preset.pluck {
            let tableA = waltz ? compWaltz[ch.compA] : compTables[gi][ch.compA]
            let tableB = waltz ? compWaltz[ch.compB] : compTables[gi][ch.compB]
            func emit(bar: Int, start: Int, len: Int, kind: Int, s: Slot, sec: Section) {
                var v = s.chord.voicing.sorted()
                guard !v.isEmpty, len > 0 else { return }
                // 転回・オクターブを変えて単調にしない
                if isChorus(sec), bar % 2 == 1, v[0] + 12 <= 81 {
                    v[0] += 12
                    v.sort()
                } else if sec == .aPrime, bar % 2 == 1, v[v.count - 1] - 12 >= 52 {
                    v[v.count - 1] -= 12
                    v.sort()
                }
                let picked: [Int]
                switch kind {
                case -1: picked = v
                case -2: picked = [v[0]]
                case -3: picked = Array(v.dropFirst())
                default: picked = [kind < v.count ? v[kind] : v[kind - v.count] + 12]
                }
                let vel: Float = (start == 0 ? 1 : 0.8) * (sec == .aPrime ? 0.9 : 1)
                for m in picked {
                    notes.append(ScoreNote(part: .comp, bar: bar, step: start, length: len, midi: m, velocity: vel))
                }
            }
            for bar in 0..<totalBars {
                let sec = sections[bar]
                guard sec != .intro else { continue }
                let table = isChorus(sec) ? tableB : tableA
                let slots = harmony[bar]
                for ev in table where ev.0 < spb {
                    let len = min(ev.1, spb - ev.0)
                    if slots.count > 1, ev.0 < slots[1].start, ev.0 + len > slots[1].start {
                        // コードが変わるところで切って弾き直す
                        emit(bar: bar, start: ev.0, len: slots[1].start - ev.0, kind: ev.2, s: slots[0], sec: sec)
                        emit(bar: bar, start: slots[1].start, len: ev.0 + len - slots[1].start, kind: ev.2, s: slots[1], sec: sec)
                    } else {
                        emit(bar: bar, start: ev.0, len: len, kind: ev.2, s: slot(bar, ev.0), sec: sec)
                    }
                }
            }
        }

        // ---------- 3. アルペジオ ----------
        if preset.arpeggio {
            var arng = ch.arpRNG
            var walk = -1
            for bar in 0..<totalBars {
                let sec = sections[bar]
                guard sec != .aPrime else { continue }
                let useB = isChorus(sec)
                let pattern = useB ? ch.arpB : ch.arpA
                let rate = useB ? ch.rateB : ch.rateA
                var positions: [(Int, Double, Int)] = []
                switch rate {
                case 1:
                    for s in 0..<spb { positions.append((s, 0, 1)) }
                case 2:
                    for i in 0..<(spb * 3 / 4) {
                        positions.append(((i * 4) / 3, Double((i * 4) % 3) / 3, 1))
                    }
                case 3:
                    var s = 0
                    var long = true
                    while s < spb {
                        positions.append((s, 0, long ? 3 : 1))
                        s += long ? 3 : 1
                        long.toggle()
                    }
                default:
                    for s in stride(from: 0, to: spb, by: 2) { positions.append((s, 0, 2)) }
                }
                for (j, p) in positions.enumerated() {
                    let tones = slot(bar, p.0).chord.arp
                    let n = tones.count
                    guard n > 0 else { continue }
                    var idx = 0
                    var add = 0
                    switch pattern {
                    case 0: idx = j % n
                    case 1: idx = n - 1 - j % n
                    case 2:
                        let cyc = max(n * 2 - 2, 1)
                        let k = j % cyc
                        idx = k < n ? k : cyc - k
                    case 3:
                        let seq = [(0, 0), (min(2, n - 1), 0), (n - 1, 0), (min(1, n - 1), 12)]
                        idx = seq[j % 4].0
                        add = seq[j % 4].1
                    case 4:
                        idx = [0, 2, 1, 2][j % 4]
                    case 5:
                        idx = j % 2 == 0 ? 0 : n - 1
                    case 6:
                        if walk < 0 { walk = n / 2 }
                        walk += arng.chance(0.5) ? 1 : -1
                        if walk >= n { walk = max(n - 2, 0) }
                        if walk < 0 { walk = min(1, n - 1) }
                        idx = walk
                    default:
                        let k = j / 2
                        idx = (j % 2 == 0 ? k : k + 2) % n
                    }
                    idx = max(0, min(n - 1, idx))
                    var midi = tones[idx] + add
                    if useB, add == 0, p.0 % 8 == 6 { midi += 12 }   // 1 オクターブ上のパターンではさらに上げない(高すぎるため)
                    let accent: Float = (p.0 % 4 == 0 && p.1 == 0) ? 1 : 0.7
                    notes.append(ScoreNote(part: .arp, bar: bar, step: p.0, length: p.2, midi: midi,
                                           velocity: accent * (sec == .intro ? 0.75 : 1), micro: p.1))
                }
            }
        }

        // ---------- 4. ベース ----------
        if preset.bass {
            var brng = ch.bassRNG
            func fold(_ m: Int) -> Int {
                var x = m
                while x > 52 { x -= 12 }
                while x < 28 { x += 12 }
                return x
            }
            func bassMidi(_ s: Slot, _ tone: Int) -> Int {
                if s.pedal { return tone == 2 ? s.bass + 12 : s.bass }
                switch tone {
                case 1: return s.chord.bassFifth
                case 2: return s.bass + 12
                case 3:
                    var t = 36 + (s.chord.classes.count > 1 ? s.chord.classes[1] : s.chord.classes[0])
                    if t < s.chord.bassRoot { t += 12 }
                    return t
                default: return s.bass
                }
            }
            let tableA = waltz ? bassWaltz[ch.bassA] : bassTables[gi][ch.bassA]
            let tableB = waltz ? bassWaltz[ch.bassB] : bassTables[gi][ch.bassB]
            for bar in 0..<totalBars {
                let sec = sections[bar]
                guard sec != .intro else { continue }
                let table = isChorus(sec) ? tableB : tableA
                let approach = brng.chance(0.15 + 0.5 * ch.energy)
                let target: Int? = bar + 1 < totalBars ? fold(bassMidi(harmony[bar + 1][0], 0)) : nil
                var events: [(Int, Int, Int)] = []
                if table.isEmpty {
                    // ウォーキング(4 分でコード音+経過音)
                    let beats = spb / 4
                    var prev = fold(bassMidi(slot(bar, 0), 0))
                    for k in 0..<beats {
                        let st = k * 4
                        let s = slot(bar, st)
                        var m: Int
                        if k == 0 {
                            m = bassMidi(s, 0)
                        } else if k == beats - 1, let target {
                            m = brng.chance(0.5) ? target + (target > prev ? -1 : 1) : target + (target > prev ? -2 : 2)
                        } else if k == 1 {
                            m = brng.chance(0.5) ? bassMidi(s, 3) : bassMidi(s, 1)
                        } else {
                            m = brng.chance(0.5) ? bassMidi(s, 1) : bassMidi(s, 2)
                        }
                        m = fold(m)
                        events.append((st, 4, m))
                        prev = m
                    }
                } else {
                    for ev in table where ev.0 < spb {
                        events.append((ev.0, min(ev.1, spb - ev.0), fold(bassMidi(slot(bar, ev.0), ev.2))))
                    }
                    // コードが変わる直前に接近音
                    if approach, let target, let last = events.last, last.2 != target {
                        let prevMidi = events.count > 1 ? events[events.count - 2].2 : last.2
                        let ap = fold(target + (target > prevMidi ? -1 : 1))
                        if last.0 >= spb - 4 {
                            events[events.count - 1].2 = ap
                        } else if last.0 < spb - 2 {
                            events[events.count - 1].1 = min(last.1, spb - 2 - last.0)
                            events.append((spb - 2, 2, ap))
                        }
                    }
                }
                for ev in events {
                    notes.append(ScoreNote(part: .bass, bar: bar, step: ev.0, length: ev.1, midi: ev.2,
                                           velocity: ev.0 == 0 ? 1 : 0.85))
                }
            }
        }

        // ---------- 5. 主旋律・対旋律 ----------
        if preset.melody {
            // 小節ごとのコードの音と旋律に使える音(48〜100)。似ている度の計算と同じものを使う
            let ctx = LeadContext(preset: preset, ch: ch, spb: spb, introBars: introBars, totalBars: totalBars,
                                  classes: harmony.map { slots in slots.map { ($0.start, $0.chord.classes) } })
            let pools = ctx.pools

            var lrng = ch.leadRNG
            var crng = ch.chorusRNG
            let vr = ch.verseRhythms
            let cr = ch.chorusRhythms
            let hookV = cell(vr[0], vr[1], contour: ch.contour, offset: 0, spb: spb, waltz: waltz, rng: &lrng)
            let freshV = formHasFresh(ch.hookForm)
                ? cell(vr[2], vr[3], contour: (ch.contour + 2) % 6, offset: 2, spb: spb, waltz: waltz, rng: &lrng) : []
            let verse = phrase(hook: hookV, form: ch.hookForm, fresh: freshV, spb: spb, legato: ch.legato)
            let freshV2 = formHasFresh(ch.verse2Form)
                ? cell(vr[3], vr[2], contour: (ch.contour + 4) % 6, offset: 1, spb: spb, waltz: waltz, rng: &lrng) : []
            let verse2 = phrase(hook: hookV, form: ch.verse2Form, fresh: freshV2, spb: spb, legato: ch.legato)
            let hookC = cell(cr[0], cr[1], contour: ch.chorusContour, offset: 0, spb: spb, waltz: waltz, rng: &crng)
            let freshC = formHasFresh(ch.chorusForm)
                ? cell(cr[2], cr[3], contour: (ch.chorusContour + 3) % 6, offset: 2, spb: spb, waltz: waltz, rng: &crng) : []
            let chorus = phrase(hook: hookC, form: ch.chorusForm, fresh: freshC, spb: spb, legato: ch.legato)

            let verseCenter = ch.register
            let chorusCenter = ch.register + 4
            let counterOn = ch.energy >= 0.4
            let octaveUp = (ch.bPrimeOctave || !counterOn) && chorusCenter + 21 <= 96
            let counterInBPrime = counterOn || !octaveUp

            // セクションごとに置く(短い試聴では 4 小節ずつ、2 回目は句の後半)
            var occurrence: [Int: Int] = [:]   // 0 = A, 1 = A', 2 = サビ
            // 前のセクションの最後の主旋律の音(鳴る高さ)。次のセクションの最初の跳躍もここから 9 半音以内にする
            var lastHeard: Int? = nil
            var bar = 0
            while bar < totalBars {
                let sec = sections[bar]
                var end = bar + 1
                while end < totalBars, sections[end] == sec, end - bar < sectionBars { end += 1 }
                defer { bar = end }
                guard sec != .intro, sec != .outro else { continue }
                let family = sec == .a ? 0 : (sec == .aPrime ? 1 : 2)
                let occ = occurrence[family] ?? 0
                occurrence[family] = occ + 1
                let offsetBars = short ? (occ % 2) * 4 : 0
                let ph = family == 0 ? verse : (family == 1 ? verse2 : chorus)
                let center = family == 2 ? chorusCenter : verseCenter
                let octave = (sec == .bPrime && octaveUp) ? 12 : 0
                let placed = place(ph, startBar: bar, offsetBars: offsetBars, bars: end - bar, center: center,
                                   prevMidi: lastHeard.map { $0 - octave }, ctx: ctx)
                if let last = placed.last { lastHeard = last.midi + octave }
                for p in placed {
                    let vel: Float = (p.step % 4 == 0 ? 0.9 : 0.75) * (family == 2 ? 1.05 : 1)
                    notes.append(ScoreNote(part: .lead, bar: p.bar, step: p.step, length: p.len, midi: p.midi + octave, velocity: vel))
                }

                // 対旋律(B・A'・B')
                let wantCounter = (sec == .b || sec == .aPrime) ? counterOn : (sec == .bPrime ? counterInBPrime : false)
                guard wantCounter else { continue }
                switch ch.counterMode {
                case 0:
                    // 主旋律の休みに答える短い句
                    for b in bar..<end {
                        let inBar = placed.filter { $0.bar == b }
                        var g = min(inBar.map { $0.step + $0.len }.max() ?? 0, spb)
                        if g % 2 == 1 { g += 1 }
                        guard spb - g >= 4 else { continue }
                        let tones = slot(b, g).chord.classes
                        var ref = (inBar.last?.midi ?? center) - 3
                        var st = g
                        var k = 0
                        while st + 2 <= spb, k < 3 {
                            var m = min(ref, 84)
                            while m > 55, !tones.contains(((m % 12) + 12) % 12) { m -= 1 }
                            if m < 58 { m += 12 }
                            notes.append(ScoreNote(part: .counter, bar: b, step: st, length: 2, midi: m, velocity: 0.6))
                            ref = m - 1
                            st += 2
                            k += 1
                        }
                    }
                default:
                    // 3 度下(1)/ 6 度下(2)の平行
                    for p in placed where p.len >= 2 {
                        let pl = pools[p.bar]
                        let perOct = max(pl.filter { $0 >= 60 && $0 < 72 }.count, 1)
                        let i = nearest(pl, p.midi)
                        let j = ch.counterMode == 1 ? i - 2 : i + 2 - perOct
                        guard j >= 0, j < pl.count else { continue }
                        notes.append(ScoreNote(part: .counter, bar: p.bar, step: p.step, length: p.len, midi: pl[j], velocity: 0.55))
                    }
                }
            }
        }

        // ---------- 6. きらめき ----------
        if preset.sparkle {
            var srng = rng(ch.base, .sparkle)
            for bar in 0..<totalBars where sections[bar] != .outro {
                let (key, sc) = keyScale(bar)
                var pool: [Int] = []
                for octave in [72, 84] {
                    for rel in sc.melodicIntervals { pool.append(octave + (key + rel) % 12) }
                }
                pool.sort()
                for step in stride(from: 0, to: spb, by: 2) where srng.chance(0.14) {
                    let midi = pool[pool.count / 2 + srng.int(pool.count / 2)] + (srng.chance(0.3) ? 12 : 0)
                    let vel = Float(srng.uniform(0.5...1))
                    notes.append(ScoreNote(part: .sparkle, bar: bar, step: step, length: 1, midi: midi, velocity: vel))
                }
            }
        }

        return BGMScore(chords: harmony.map { $0[0].chord }, sections: sections, notes: notes, sound: sound)
    }
}
