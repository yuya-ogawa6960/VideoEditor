import Foundation

// =====================================================================
// 用意された曲(アプリ内で合成する BGM)のプリセット。
// 音はすべて BGMGenerator がその場で作るので、著作権の心配なく使える。
// id を種にして合成するため、同じプリセットは何度作っても同じ曲になる。
//
// ■ BGMPreset の書き方(各フィールドの意味と範囲)
//   id          英数字と _ だけ。全ファイルで重複しないこと。変えると曲が変わるので決めたら固定
//   name        画面に出す日本語名。8 文字以内、場面がわかる言葉(朝の散歩、乾杯 など)
//   mood        BGMMood(絞り込みチップ)。どれか 1 つ
//   bpm         50〜140。3 拍子にするなら beatsPerBar: 3
//   key         0=C 1=C# 2=D 3=D# 4=E 5=F 6=F# 7=G 8=G# 9=A 10=A# 11=B
//   scale       .major / .minor / .dorian / .pentatonic / .yo(お正月) / .miyakobushi(和風しっとり)
//   progression 度数 1〜7 の配列、4〜8 個(1 小節に 1 つ)。例: [1,5,6,4] [2,5,1,1] [6,4,1,5] [1,6,4,5]
//               [1,5,6,3,4,1,4,5] カノン / 短調の [1,6,3,7] / [4,5,3,6] 王道
//   sevenths    true で 4 和音(ローファイ・ジャズ・おしゃれ)
//   pad         持続音(スーパーソウ+コーラスの温かいパッド。既定 true)。widePad: true で弦楽合奏風に広く・ゆっくり
//   pluck       弾く音(既定 true)。tone: .piano(FM+打鍵ノイズ) / .pluck(カープラス・ストロングのギター) /
//               .bell(FM ベル・チェレスタ) / .marimba(FM マレット) / .pizzicato(短い弦) / .brass(のこぎり波の金管)
//   bass        ベース(サブ+中域、サチュレーション。既定 true)。子守唄・追悼など軽くしたいときは false
//   drums       .none / .soft / .pop / .lofi / .house / .heartbeat(ホラーの鼓動) / .march(行進・運動会)
//   arpeggio    コードの音を上下に刻む(bpm < 100 なら 16 分、それ以上は 8 分)
//   melody      上にモチーフ(短い旋律)を乗せる(既定 true。ナレーション用など邪魔なら false)
//   swing       0〜0.4。裏拍を遅らせる(0.2〜0.35 でジャズ・はずむ感じ)
//   pattern     0〜3。ドラムと伴奏のリズム違い(0: 1・3 拍、1: 毎拍、2: はずむ、3: ボサ風)
//   vinyl       レコードノイズ(ローファイ)   drone: 主音を鳴らし続ける(緊張・ホラー)
//   detuned     パッドをずらして不気味に(ホラー)   claps: 2・4 拍に手拍子(パーティー)
//   sleighBells ハイハットを鈴に(冬・クリスマス)   sparkle: 高い鈴をときどき散らす(鳥・春・オルゴール)
//   beatsPerBar 4(既定)か 3(ワルツ・子守唄)   organ: パッドをオルガン風(追悼)
//   liftToMajor 進行を 2 周したら平行長調に移る(再出発: 短調 → 長調)
//   reverb      0〜1。残響の量(既定 0.3。風景・感動は 0.5〜0.6、ローファイは 0.2)
//   構成は自動: イントロ(2 小節)→ A → B(楽器を足す)→ A' → アウトロ(フィルターを閉じてフェード)。
// =====================================================================

/// 曲の雰囲気(絞り込みに使う)
enum BGMMood: String, CaseIterable, Identifiable, Codable {
    case bright
    case calm
    case stylish
    case emotional
    case energetic
    case cute
    case tense
    case natural
    case meal
    case party
    case variety
    case slowLiving
    case horror
    case mysterious
    case seasonal
    case lifeEvent

    var id: String { rawValue }

    /// 画面に出す名前
    var title: String {
        switch self {
        case .bright: return String(localized: "明るい")
        case .calm: return String(localized: "落ち着いた")
        case .stylish: return String(localized: "おしゃれ")
        case .emotional: return String(localized: "感動")
        case .energetic: return String(localized: "元気")
        case .cute: return String(localized: "かわいい")
        case .tense: return String(localized: "緊張")
        case .natural: return String(localized: "ナチュラル")
        case .meal: return String(localized: "食事")
        case .party: return String(localized: "パーティー")
        case .variety: return String(localized: "バラエティ")
        case .slowLiving: return String(localized: "ていねいな暮らし")
        case .horror: return String(localized: "ホラー")
        case .mysterious: return String(localized: "ミステリアス")
        case .seasonal: return String(localized: "季節")
        case .lifeEvent: return String(localized: "行事")
        }
    }

    /// 絞り込みチップのアイコン
    var symbolName: String {
        switch self {
        case .bright: return "sun.max"
        case .calm: return "moon"
        case .stylish: return "sparkles"
        case .emotional: return "heart"
        case .energetic: return "bolt"
        case .cute: return "star"
        case .tense: return "exclamationmark.triangle"
        case .natural: return "leaf"
        case .meal: return "fork.knife"
        case .party: return "party.popper"
        case .variety: return "face.smiling"
        case .slowLiving: return "cup.and.saucer"
        case .horror: return "moon.haze"
        case .mysterious: return "questionmark.circle"
        case .seasonal: return "calendar"
        case .lifeEvent: return "gift"
        }
    }
}

/// 音階
enum BGMScale: String, Codable {
    case major
    case minor
    case dorian
    case pentatonic
    /// 日本の「ヨナ抜き」(明るいお正月風)
    case yo
    /// 都節(しっとりした和風)
    case miyakobushi

    /// 1オクターブ内の半音(コードはこの並びから三度積みで作る)
    var intervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        // 5 音の音階は、コードだけ 7 音の並びで作り、アルペジオを 5 音にする
        case .pentatonic, .yo: return [0, 2, 4, 5, 7, 9, 11]
        case .miyakobushi: return [0, 1, 3, 5, 7, 8, 10]
        }
    }

    /// アルペジオやフレーズに使う音
    var melodicIntervals: [Int] {
        switch self {
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .yo: return [0, 2, 5, 7, 9]
        case .miyakobushi: return [0, 1, 5, 7, 8]
        default: return intervals
        }
    }
}

/// ドラムの種類
enum BGMDrumKit: String, Codable {
    case none
    case soft
    case pop
    case lofi
    case house
    /// ゆっくりした心臓の鼓動のようなキックだけ(ホラー)
    case heartbeat
    /// 行進曲風(スネアの刻み+小節末のロール)
    case march
}

/// 弾く音の音色
enum BGMPluckTone: String, Codable {
    /// ピアノ風(三角波+正弦波、減衰やや長め)
    case piano
    /// ギター風(ナイロン弦っぽい短い音)
    case pluck
    /// ベル・オルゴール風(倍音を足したキラキラした音)
    case bell
    /// マリンバ風(丸く短い音)
    case marimba
    /// ピチカート風(ごく短く、はずむ音)
    case pizzicato
    /// 金管風(のこぎり波、少し長め)
    case brass
}

/// 曲のプリセット
struct BGMPreset: Identifiable, Hashable {
    /// 英数字の id(合成の種。変えると曲が変わるので固定)
    let id: String
    /// 画面に出す名前(8 文字以内)
    let name: String
    let mood: BGMMood
    /// テンポ(BPM)
    let bpm: Double
    /// キー(0 = C, 1 = C#, … 11 = B)
    let key: Int
    let scale: BGMScale
    /// コード進行(度数 1〜7。4〜8 小節)
    let progression: [Int]
    /// 7th を足す(ローファイ・ジャズ風)
    let sevenths: Bool
    /// パッド(持続音)
    let pad: Bool
    /// パッドを広く・ゆっくり鳴らす(風景・映画風)
    let widePad: Bool
    /// ピアノ風の弾く音
    let pluck: Bool
    let pluckTone: BGMPluckTone
    let bass: Bool
    let drums: BGMDrumKit
    let arpeggio: Bool
    /// 裏拍を遅らせる量(0 = ストレート、0.3 = しっかりスウィング)
    let swing: Double
    /// ドラム・伴奏のリズムパターン(0〜3)
    let drumPattern: Int
    /// レコードのような小さなノイズを重ねる
    let vinyl: Bool
    /// 低いドローン(緊張感)
    let drone: Bool
    /// パッドを大きくずらして不気味にする(ホラー)
    let detuned: Bool
    /// 2・4 拍に手拍子を入れる(パーティー)
    let claps: Bool
    /// ハイハットを鈴(スレイベル)にする(冬・クリスマス)
    let sleighBells: Bool
    /// 高い鈴の音をときどき散らす(鳥のさえずり・オルゴール風)
    let sparkle: Bool
    /// 1 小節の拍数(3 = ワルツ・子守唄)
    let beatsPerBar: Int
    /// パッドをオルガン風(厚く、減衰しない)にする
    let organ: Bool
    /// 進行を 2 周したら平行長調に移って明るくする(再出発)
    let liftToMajor: Bool
    /// 上にモチーフ(短い旋律)を乗せる
    let melody: Bool
    /// 残響の量(0〜1)
    let reverb: Double

    init(_ id: String, _ name: String, _ mood: BGMMood, bpm: Double, key: Int, scale: BGMScale,
         progression: [Int], sevenths: Bool = false,
         pad: Bool = true, widePad: Bool = false,
         pluck: Bool = true, tone: BGMPluckTone = .piano, bass: Bool = true,
         drums: BGMDrumKit = .pop, arpeggio: Bool = false, swing: Double = 0, pattern: Int = 0,
         vinyl: Bool = false, drone: Bool = false, detuned: Bool = false,
         claps: Bool = false, sleighBells: Bool = false, sparkle: Bool = false,
         beatsPerBar: Int = 4, organ: Bool = false, liftToMajor: Bool = false,
         melody: Bool = true, reverb: Double = 0.3) {
        self.id = id
        self.name = name
        self.mood = mood
        self.bpm = bpm
        self.key = key
        self.scale = scale
        self.progression = progression
        self.sevenths = sevenths
        self.pad = pad
        self.widePad = widePad
        self.pluck = pluck
        self.pluckTone = tone
        self.bass = bass
        self.drums = drums
        self.arpeggio = arpeggio
        self.swing = swing
        self.drumPattern = pattern
        self.vinyl = vinyl
        self.drone = drone
        self.detuned = detuned
        self.claps = claps
        self.sleighBells = sleighBells
        self.sparkle = sparkle
        self.beatsPerBar = beatsPerBar
        self.organ = organ
        self.liftToMajor = liftToMajor
        self.melody = melody
        self.reverb = min(max(reverb, 0), 1)
    }

    /// 全部の曲(BGMLibrary.all と同じ)
    static var all: [BGMPreset] { BGMLibrary.all }

    static func preset(id: String) -> BGMPreset? { BGMLibrary.preset(id: id) }

    /// 雰囲気で絞り込む(nil なら全部)
    static func presets(mood: BGMMood?) -> [BGMPreset] { BGMLibrary.presets(mood: mood) }
}

// =====================================================================
// 曲の一覧。最初からの 75 曲は BGMPresets+Base.swift、グループごとの追加は BGMPresets+<Group>.swift で
//   extension BGMLibrary { static let <group>Presets: [BGMPreset] = [...] }
// として書く。id は全体で重複しないこと。
// =====================================================================
enum BGMLibrary {
    /// 全部の曲(グループ順)
    static var all: [BGMPreset] {
        basePresets + everydayPresets + upbeatPresets + moodPresets + eventsPresets
    }

    static func preset(id: String) -> BGMPreset? {
        all.first { $0.id == id }
    }

    /// 雰囲気で絞り込む(nil なら全部)
    static func presets(mood: BGMMood?) -> [BGMPreset] {
        guard let mood else { return all }
        return all.filter { $0.mood == mood }
    }
}
