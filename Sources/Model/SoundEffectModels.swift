import Foundation
import AVFoundation

// =====================================================================
// 内蔵の効果音(SE)。素材ファイルは使わず、すべてコードで合成する(SoundEffectSynth.swift)。
// 合成した音は Caches/SoundEffects/sfx_<種類>_v1.caf に 1 回だけ書き出して使い回す。
// タイムラインにはナレーション(NarrationClip)として置くので、移動・トリム・音量・書き出しはそのまま効く。
// Caches は消えることがあるので、ProjectStore が復元時にファイル名から作り直す(generatedURL(fileName:))。
// =====================================================================

/// 効果音の分類(パネルのタブ)
enum SoundEffectCategory: String, CaseIterable, Identifiable {
    // 「ネタ・リアクション」は見つけやすいよう 2 番目(先頭の「動き」はパネルの初期値)
    case motion, meme, pop, sparkle, impact, daily
    // 環境音(雨・風など)、場面の空気を作る音、ゲーム風の音
    case nature, emotion, game

    var id: String { rawValue }

    var title: String {
        switch self {
        case .motion: return String(localized: "動き")
        case .meme: return String(localized: "ネタ・リアクション")
        case .pop: return String(localized: "ポップ")
        case .sparkle: return String(localized: "キラキラ")
        case .impact: return String(localized: "衝撃")
        case .daily: return String(localized: "日常")
        case .nature: return String(localized: "自然")
        case .emotion: return String(localized: "雰囲気")
        case .game: return String(localized: "ゲーム")
        }
    }
}

/// 効果音の種類。rawValue はファイル名に使うので変えない
enum SoundEffectKind: String, CaseIterable, Identifiable {
    // 動き
    case whoosh, swooshUp, swooshDown, swipe, riser
    // ポップ
    case pop, click, bubble, boing
    // キラキラ
    case kira, sparkle, bell, success
    // 衝撃
    case impact, drum, cymbal, heartbeat, glitch
    // 日常
    case shutter, typing, notification
    // ネタ・リアクション(ショート動画でよく使われる音)
    case sadTrombone, vineBoom, dramatic, recordScratch, jajaan, correct, wrong
    case drumRoll, crickets, applause, tada, rimshot
    // ---- 追加分(50 種) ----
    // 動き・ポップ(カットやテロップの出現に)
    case zip, slideIn, rewind, fastForward, teleport, airWhoosh
    case pop2, blip, tick, bounce
    // ネタ・リアクション
    case yay, boo, wahWah, dundun, honk, quack, kazoo, slideWhistle
    // 日常
    case doorKnock, sizzle, pourWater, footsteps, keyboardEnter, phoneRing, cashRegister, cameraFocus
    // 自然
    case birds, rain, wind, waveWash, fireCrackle, insects, night, thunder
    // 雰囲気(場面の空気を作る短い音)
    case pianoHit, warmChord, sadNote, tensionDrone, heartbeatSlow, surpriseSting
    // ゲーム
    case coinGet, levelUp, fail, jump8bit, powerUp
    // スポーツ・アクション(衝撃の分類に入れる)
    case whistle, crowdCheer, buzzer, punch, countdown
    // ---- シーン別(BGM のシーン分類に合わせて追加) ----
    // 日常
    case crunch, corkPop, clink, kettle, cupSet, pageFlip, clockTick, schoolBell, creak
    // キラキラ
    case mealChime, windChime, magicShimmer, musicBox, churchBells, sleighBells
    // 衝撃
    case partyPopper, starterPistol, tsuzumi
    // 自然
    case cicadas, leavesRustle, snowCrunch, shishiOdoshi
    // 雰囲気
    case breath, eerieSting, questionSting, orin, softLowChord, risingSwell
    // ポップ
    case rattle

    var id: String { rawValue }

    /// 表示名
    var name: String {
        switch self {
        case .whoosh: return String(localized: "シュッ")
        case .swooshUp: return String(localized: "シュワッ(上へ)")
        case .swooshDown: return String(localized: "シュワッ(下へ)")
        case .swipe: return String(localized: "スワイプ")
        case .riser: return String(localized: "ライザー")
        case .pop: return String(localized: "ポン")
        case .click: return String(localized: "カチッ")
        case .bubble: return String(localized: "ポコッ")
        case .boing: return String(localized: "ビヨーン")
        case .kira: return String(localized: "キラーン")
        case .sparkle: return String(localized: "キラキラ")
        case .bell: return String(localized: "チーン")
        case .success: return String(localized: "成功チャイム")
        case .impact: return String(localized: "ドン")
        case .drum: return String(localized: "ドラム")
        case .cymbal: return String(localized: "シャーン")
        case .heartbeat: return String(localized: "ドクン(心音)")
        case .glitch: return String(localized: "ザザッ(ノイズ)")
        case .shutter: return String(localized: "カシャ")
        case .typing: return String(localized: "カタカタ(タイピング)")
        case .notification: return String(localized: "ピコン(通知)")
        case .sadTrombone: return String(localized: "ファーファーファーファー(残念)")
        case .vineBoom: return String(localized: "ドゥーン(ブーム)")
        case .dramatic: return String(localized: "ドゥーン(緊迫)")
        case .recordScratch: return String(localized: "キュッ(レコード)")
        case .jajaan: return String(localized: "ジャジャーン")
        case .correct: return String(localized: "ピンポーン(正解)")
        case .wrong: return String(localized: "ブッブー(不正解)")
        case .drumRoll: return String(localized: "ドロロロ(ドラムロール)")
        case .crickets: return String(localized: "シーン(コオロギ)")
        case .applause: return String(localized: "パチパチ(拍手)")
        case .tada: return String(localized: "ジャーン(タダー)")
        case .rimshot: return String(localized: "バダム・ツ(リムショット)")
        // 動き・ポップ
        case .zip: return String(localized: "ジッ")
        case .slideIn: return String(localized: "スッ")
        case .rewind: return String(localized: "巻き戻し")
        case .fastForward: return String(localized: "早送り")
        case .teleport: return String(localized: "ヒュン")
        case .airWhoosh: return String(localized: "フォッ")
        case .pop2: return String(localized: "プチッ")
        case .blip: return String(localized: "ピッ")
        case .tick: return String(localized: "チッ")
        case .bounce: return String(localized: "ポヨン")
        // ネタ・リアクション
        case .yay: return String(localized: "ワーイ")
        case .boo: return String(localized: "ブーイング")
        case .wahWah: return String(localized: "ワウワウ")
        case .dundun: return String(localized: "デデン")
        case .honk: return String(localized: "プップー")
        case .quack: return String(localized: "ガーガー")
        case .kazoo: return String(localized: "カズー")
        case .slideWhistle: return String(localized: "スライド笛")
        // 日常
        case .doorKnock: return String(localized: "コンコン")
        case .sizzle: return String(localized: "ジュー")
        case .pourWater: return String(localized: "水を注ぐ")
        case .footsteps: return String(localized: "足音")
        case .keyboardEnter: return String(localized: "エンター")
        case .phoneRing: return String(localized: "着信音")
        case .cashRegister: return String(localized: "レジ")
        case .cameraFocus: return String(localized: "ピント")
        // 自然
        case .birds: return String(localized: "小鳥")
        case .rain: return String(localized: "雨")
        case .wind: return String(localized: "風")
        case .waveWash: return String(localized: "波")
        case .fireCrackle: return String(localized: "焚き火")
        case .insects: return String(localized: "虫の声")
        case .night: return String(localized: "夜")
        case .thunder: return String(localized: "雷")
        // 雰囲気
        case .pianoHit: return String(localized: "ピアノ一打")
        case .warmChord: return String(localized: "あたたかい和音")
        case .sadNote: return String(localized: "悲しい音")
        case .tensionDrone: return String(localized: "緊張")
        case .heartbeatSlow: return String(localized: "遅い心音")
        case .surpriseSting: return String(localized: "ビクッ")
        // ゲーム
        case .coinGet: return String(localized: "チャリン")
        case .levelUp: return String(localized: "レベルアップ")
        case .fail: return String(localized: "失敗ジングル")
        case .jump8bit: return String(localized: "ジャンプ")
        case .powerUp: return String(localized: "パワーアップ")
        // スポーツ・アクション
        case .whistle: return String(localized: "ホイッスル")
        case .crowdCheer: return String(localized: "歓声")
        case .buzzer: return String(localized: "ブザー")
        case .punch: return String(localized: "バシッ")
        case .countdown: return String(localized: "カウントダウン")
        // シーン別
        case .crunch: return String(localized: "ポリポリ")
        case .corkPop: return String(localized: "ポン(栓)")
        case .clink: return String(localized: "乾杯")
        case .kettle: return String(localized: "やかん")
        case .cupSet: return String(localized: "コトッ")
        case .pageFlip: return String(localized: "ページめくり")
        case .clockTick: return String(localized: "チクタク")
        case .schoolBell: return String(localized: "学校チャイム")
        case .creak: return String(localized: "ギィ")
        case .mealChime: return String(localized: "いただきます")
        case .windChime: return String(localized: "風鈴")
        case .magicShimmer: return String(localized: "魔法")
        case .musicBox: return String(localized: "オルゴール")
        case .churchBells: return String(localized: "教会の鐘")
        case .sleighBells: return String(localized: "鈴")
        case .partyPopper: return String(localized: "クラッカー")
        case .starterPistol: return String(localized: "パン(合図)")
        case .tsuzumi: return String(localized: "鼓")
        case .cicadas: return String(localized: "セミ")
        case .leavesRustle: return String(localized: "落ち葉")
        case .snowCrunch: return String(localized: "雪を踏む")
        case .shishiOdoshi: return String(localized: "ししおどし")
        case .breath: return String(localized: "息づかい")
        case .eerieSting: return String(localized: "不気味")
        case .questionSting: return String(localized: "はてな")
        case .orin: return String(localized: "おりん")
        case .softLowChord: return String(localized: "静かな和音")
        case .risingSwell: return String(localized: "幕開け")
        case .rattle: return String(localized: "ガラガラ")
        }
    }

    var category: SoundEffectCategory {
        switch self {
        case .whoosh, .swooshUp, .swooshDown, .swipe, .riser: return .motion
        case .pop, .click, .bubble, .boing: return .pop
        case .kira, .sparkle, .bell, .success: return .sparkle
        case .impact, .drum, .cymbal, .heartbeat, .glitch: return .impact
        case .shutter, .typing, .notification: return .daily
        case .sadTrombone, .vineBoom, .dramatic, .recordScratch, .jajaan, .correct, .wrong,
             .drumRoll, .crickets, .applause, .tada, .rimshot: return .meme
        case .zip, .slideIn, .rewind, .fastForward, .teleport, .airWhoosh: return .motion
        case .pop2, .blip, .tick, .bounce: return .pop
        case .yay, .boo, .wahWah, .dundun, .honk, .quack, .kazoo, .slideWhistle: return .meme
        case .doorKnock, .sizzle, .pourWater, .footsteps, .keyboardEnter, .phoneRing, .cashRegister, .cameraFocus: return .daily
        case .birds, .rain, .wind, .waveWash, .fireCrackle, .insects, .night, .thunder: return .nature
        case .pianoHit, .warmChord, .sadNote, .tensionDrone, .heartbeatSlow, .surpriseSting: return .emotion
        case .coinGet, .levelUp, .fail, .jump8bit, .powerUp: return .game
        case .whistle, .crowdCheer, .buzzer, .punch, .countdown: return .impact
        case .crunch, .corkPop, .clink, .kettle, .cupSet, .pageFlip, .clockTick, .schoolBell, .creak: return .daily
        case .mealChime, .windChime, .magicShimmer, .musicBox, .churchBells, .sleighBells: return .sparkle
        case .partyPopper, .starterPistol, .tsuzumi: return .impact
        case .cicadas, .leavesRustle, .snowCrunch, .shishiOdoshi: return .nature
        case .breath, .eerieSting, .questionSting, .orin, .softLowChord, .risingSwell: return .emotion
        case .rattle: return .pop
        }
    }
}

extension SoundScene {
    /// この場面に合う内蔵の効果音(レシピと一緒にパネルに並べる。おすすめ順)
    var relatedKinds: [SoundEffectKind] {
        switch self {
        case .ui: return [.zip, .slideIn, .pop2, .blip, .tick, .whoosh, .swipe, .click, .airWhoosh, .teleport]
        case .meme: return [.boing, .slideWhistle, .wahWah, .dundun, .honk, .quack, .kazoo, .sadTrombone, .vineBoom, .recordScratch]
        case .game: return [.coinGet, .levelUp, .fail, .jump8bit, .powerUp, .glitch]
        case .sports: return [.starterPistol, .whistle, .crowdCheer, .buzzer, .punch, .countdown, .drumRoll]
        case .daily: return [.doorKnock, .footsteps, .keyboardEnter, .phoneRing, .cashRegister, .cameraFocus, .shutter, .typing, .notification]
        case .food: return [.sizzle, .pourWater, .crunch, .mealChime, .corkPop, .kettle, .clink]
        case .party: return [.partyPopper, .clink, .yay, .sparkle, .tada, .applause, .sleighBells]
        case .kurashi: return [.kettle, .cupSet, .pageFlip, .clockTick, .windChime, .birds, .pourWater]
        case .nature: return [.birds, .rain, .wind, .waveWash, .fireCrackle, .insects, .night, .thunder]
        case .season: return [.cicadas, .windChime, .leavesRustle, .sleighBells, .snowCrunch, .shishiOdoshi, .tsuzumi]
        case .horror: return [.vineBoom, .creak, .breath, .heartbeatSlow, .eerieSting, .dramatic, .night]
        case .mystery: return [.clockTick, .magicShimmer, .questionSting, .tensionDrone, .glitch]
        case .variety: return [.boing, .slideWhistle, .wrong, .correct, .drumRoll, .jajaan, .rimshot, .crickets]
        case .life: return [.schoolBell, .applause, .rattle, .musicBox, .orin, .softLowChord, .churchBells, .warmChord, .risingSwell, .success]
        }
    }
}

// MARK: - 生成したファイルの保管

enum SoundEffectLibrary {
    /// 合成のしかたを変えたら上げる(ファイル名が変わり、作り直される)
    /// 2: 聞こえる大きさでそろえる仕上げ(SoundLoudness.swift)に変更
    static let fileVersion = 2

    private static let lock = NSLock()

    /// Caches/SoundEffects(必要に応じて作成)
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("SoundEffects", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileName(for kind: SoundEffectKind) -> String {
        "sfx_\(kind.rawValue)_v\(fileVersion).caf"
    }

    /// 効果音のファイル。なければ合成して書き出す(失敗したら nil)
    static func url(for kind: SoundEffectKind) -> URL? {
        let url = directory.appendingPathComponent(fileName(for: kind))
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let samples = SoundEffectSynth.render(kind)
        guard !samples.isEmpty else { return nil }
        // 途中まで書いたファイルを使わないよう、別名に書いてから置き換える
        let temp = directory.appendingPathComponent("tmp_\(UUID().uuidString).caf")
        do {
            try SoundEffectSynth.write(samples, to: temp)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: temp)
            print("SoundEffectLibrary: write failed: \(error)")
            return nil
        }
    }

    /// 生成した効果音の名前なら(消えていれば作り直して)URL を返す。それ以外の名前は nil
    static func generatedURL(fileName: String) -> URL? {
        // 古い版の名前でも今の版で作り直す。作れなかったときは、残っている古いファイルを使う
        if let kind = kind(forFileName: fileName) { return url(for: kind) ?? existingFile(named: fileName) }
        if let recipeID = recipeID(forFileName: fileName) {
            return url(forRecipeID: recipeID) ?? existingFile(named: fileName)
        }
        return nil
    }

    /// 保管場所に残っているファイル(なければ nil)
    private static func existingFile(named fileName: String) -> URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: レシピ(データで書いた効果音)

    /// レシピの合成のしかたを変えたら上げる
    /// 2: 聞こえる大きさでそろえる仕上げ(SoundLoudness.swift)に変更
    static let recipeFileVersion = 2

    static func fileName(forRecipe recipe: SoundRecipe) -> String {
        "sfxr_\(recipe.id)_v\(recipeFileVersion).caf"
    }

    /// ファイル名 → レシピ id(sfxr_<id>_v<n>.caf)
    static func recipeID(forFileName fileName: String) -> String? {
        guard fileName.hasPrefix("sfxr_"), fileName.hasSuffix(".caf") else { return nil }
        let body = fileName.dropFirst(5).dropLast(4)
        guard let mark = body.range(of: "_v", options: .backwards) else { return nil }
        return String(body[..<mark.lowerBound])
    }

    static func url(forRecipeID id: String) -> URL? {
        guard let recipe = SoundRecipe.find(id) else { return nil }
        return url(forRecipe: recipe)
    }

    /// レシピの効果音ファイル。なければ合成して書き出す(失敗したら nil)
    static func url(forRecipe recipe: SoundRecipe) -> URL? {
        let url = directory.appendingPathComponent(fileName(forRecipe: recipe))
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (left, right) = SoundEffectSynth.renderSamples(recipe: recipe)
        guard !left.isEmpty else { return nil }
        let temp = directory.appendingPathComponent("tmp_\(UUID().uuidString).caf")
        do {
            try SoundEffectSynth.writeStereo(left: left, right: right, to: temp)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: temp)
            print("SoundEffectLibrary: recipe write failed: \(error)")
            return nil
        }
    }

    /// 場面のレシピをまとめて作っておく(バックグラウンドから呼ぶ)
    static func prepare(scene: SoundScene) {
        for recipe in SoundRecipe.recipes(in: scene) {
            _ = url(forRecipe: recipe)
        }
    }

    /// ファイル名 → 効果音の種類(古い版の名前も今の版で作り直す)
    static func kind(forFileName fileName: String) -> SoundEffectKind? {
        guard fileName.hasPrefix("sfx_"), fileName.hasSuffix(".caf") else { return nil }
        let body = fileName.dropFirst(4).dropLast(4)
        guard let mark = body.range(of: "_v", options: .backwards) else { return nil }
        return SoundEffectKind(rawValue: String(body[..<mark.lowerBound]))
    }

    /// この URL が生成した効果音か
    static func isGenerated(_ url: URL) -> Bool {
        let fileName = url.lastPathComponent
        // 内蔵効果音(sfx_)とレシピ(sfxr_)のどちらも生成ファイルとして扱う
        return kind(forFileName: fileName) != nil || recipeID(forFileName: fileName) != nil
    }

    /// ファイルの長さ(秒)
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// パネルを開いたときに、まだないものをまとめて作っておく(バックグラウンドから呼ぶ)
    static func prepareAll() {
        for kind in SoundEffectKind.allCases {
            _ = url(for: kind)
        }
    }
}
