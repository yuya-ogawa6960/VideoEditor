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
    case motion, pop, sparkle, impact, daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .motion: return String(localized: "動き")
        case .pop: return String(localized: "ポップ")
        case .sparkle: return String(localized: "キラキラ")
        case .impact: return String(localized: "衝撃")
        case .daily: return String(localized: "日常")
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
        }
    }

    var category: SoundEffectCategory {
        switch self {
        case .whoosh, .swooshUp, .swooshDown, .swipe, .riser: return .motion
        case .pop, .click, .bubble, .boing: return .pop
        case .kira, .sparkle, .bell, .success: return .sparkle
        case .impact, .drum, .cymbal, .heartbeat, .glitch: return .impact
        case .shutter, .typing, .notification: return .daily
        }
    }
}

// MARK: - 生成したファイルの保管

enum SoundEffectLibrary {
    /// 合成のしかたを変えたら上げる(ファイル名が変わり、作り直される)
    static let fileVersion = 1

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
        guard let kind = kind(forFileName: fileName) else { return nil }
        return url(for: kind)
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
        kind(forFileName: url.lastPathComponent) != nil
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
