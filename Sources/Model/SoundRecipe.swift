import Foundation

// =====================================================================
// データで書く効果音(レシピ)。SoundEffectKind のようにコードで合成するのではなく、
// 「層(SoundLayer)」の配列として書いておき、SoundEffectSynth.render(recipe:) が音にする。
// レシピ本体は SoundRecipes+UIGame / +DailyFood / +NatureSeason / +MoodLife に分けて書く。
// id はファイル名(Caches/SoundEffects/sfxr_<id>_v1.caf)と保存に使うので変えない。
// =====================================================================

/// 場面(パネルのチップ)。BGM の場面分けに近い並び
enum SoundScene: String, CaseIterable, Identifiable {
    case ui, meme, game, sports, daily, food, party, kurashi, nature, season, horror, mystery, variety, life

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ui: return String(localized: "UI・切り替え")
        case .meme: return String(localized: "ネタ")
        case .game: return String(localized: "ゲーム")
        case .sports: return String(localized: "スポーツ")
        case .daily: return String(localized: "日常")
        case .food: return String(localized: "食事")
        case .party: return String(localized: "パーティー")
        case .kurashi: return String(localized: "暮らし")
        case .nature: return String(localized: "自然")
        case .season: return String(localized: "季節")
        case .horror: return String(localized: "ホラー")
        case .mystery: return String(localized: "ミステリー")
        case .variety: return String(localized: "バラエティ")
        case .life: return String(localized: "行事")
        }
    }
}

/// 効果音を作る 1 つの層(発振器かノイズ + エンベロープ + フィルター)
struct SoundLayer {
    enum Source {
        case sine, triangle, saw, square, noise, pinkNoise
        /// FM(キャリアに対する変調周波数の比と変調の深さ)。金属音・ベルに
        case fm(ratio: Double, index: Double)
        /// ブラウンノイズ(低いゴーという音。雷・波・風の土台に)
        case brownNoise
    }

    var source: Source
    /// 鳴り始め(秒)
    var start: Double = 0
    /// 長さ(秒)
    var length: Double
    var gain: Float = 0.8
    /// エンベロープ: attack 秒で 1 → decay 秒で sustain → 終わりの release 秒で 0
    var attack: Double = 0.005, decay: Double = 0.1, sustain: Float = 0.6, release: Double = 0.1
    /// 音程(Hz)。pitchEnd が nil なら一定。ノイズでは無視
    var pitchStart: Double = 440, pitchEnd: Double? = nil
    /// ローパスのカットオフ(Hz)。filterEnd があれば長さの間で動かす
    var filterStart: Double? = nil, filterEnd: Double? = nil
    /// ハイパス(Hz)
    var highpass: Double? = nil
    /// 同じ音をくり返す(足音・ノックなど)。2 回目以降は音程と間隔がわずかに揺れる
    var repeats: Int = 1, repeatGap: Double = 0
    /// ビブラート(Hz / 半音)
    var vibratoRate: Double = 0, vibratoDepth: Double = 0
    /// 左右(-1 左 … 1 右)
    var pan: Float = 0

    // ---- あとから足した項目(省略できる) ----

    /// バンドパスの中心(Hz)。指定するとローパスの代わりに帯域だけを通す
    var bandpass: Double? = nil
    /// フィルターの鋭さ(共鳴)。0.7 で素直、2〜6 で鳴きが出る
    var resonance: Double = 0.9
    /// 歪みの量(0 でなし、1 で強め)。アタックを太くする
    var drive: Float = 0
}

/// 効果音 1 つ分
struct SoundRecipe: Identifiable {
    /// 例 "food.sizzle"。一意
    let id: String
    /// 日本語 7 文字以内
    let name: String
    let scene: SoundScene
    let duration: Double
    let layers: [SoundLayer]
    /// 短い遅れを戻す(ディレイ)
    var echoes: [(delay: Double, gain: Float)] = []
    var randomSeed: UInt64 = 1

    // ---- あとから足した項目(省略できる) ----

    /// 残響の送り量(0 でなし、0.15 で部屋の響き、0.5 でホール)
    var reverb: Float = 0.15
    /// 残響の長さ(秒)
    var reverbTime: Double = 1.2

    init(id: String, name: String, scene: SoundScene, duration: Double, layers: [SoundLayer],
         echoes: [(delay: Double, gain: Float)] = [], randomSeed: UInt64 = 1,
         reverb: Float = 0.15, reverbTime: Double = 1.2) {
        self.id = id
        self.name = name
        self.scene = scene
        self.duration = duration
        self.layers = layers
        self.echoes = echoes
        self.randomSeed = randomSeed
        self.reverb = reverb
        self.reverbTime = reverbTime
    }
}

extension SoundRecipe {
    /// すべてのレシピ(各チームのファイルを合わせる)
    static var all: [SoundRecipe] { uiGame + dailyFood + natureSeason + moodLife }

    /// id で引く
    static func find(_ id: String) -> SoundRecipe? {
        all.first { $0.id == id }
    }

    /// 場面ごと
    static func recipes(in scene: SoundScene) -> [SoundRecipe] {
        all.filter { $0.scene == scene }
    }
}
