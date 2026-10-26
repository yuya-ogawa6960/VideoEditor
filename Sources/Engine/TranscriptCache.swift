import Foundation

// =====================================================================
// 文字起こしの結果の記録(API・時間の節約)。
//
// クリップの素材ファイル・使う範囲・方式(と、そのモデル)・話している言語が同じなら、
// 前回の文字起こしの結果(元素材上の秒のトークン)をそのまま使い、音声を送り直さない。
// 字幕の区切り・AI 仕上げ・訳はこの結果から毎回作り直すので、言語の選び方や仕上げを変えても使える。
// 記録は Caches に置く(容量が足りないと OS が消すことがある。消えたら普通に文字起こしする)。
// =====================================================================

final class TranscriptCache: @unchecked Sendable {
    static let shared = TranscriptCache()

    private struct StoredToken: Codable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double?
    }

    private let lock = NSLock()
    private var memory: [String: [TimedToken]] = [:]

    private var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("TranscriptCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 記録の見出し(素材ファイル名と大きさ・範囲・方式・モデル・言語)
    static func key(engine: String, variant: String, language: TranscriptionLanguage, clip: Clip) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: clip.url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return [engine, variant, language.rawValue, clip.url.lastPathComponent, String(size),
                String(format: "%.3f", clip.startTime), String(format: "%.3f", clip.endTime)].joined(separator: "|")
    }

    func tokens(for key: String) -> [TimedToken]? {
        lock.lock()
        if let hit = memory[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let file = fileURL(for: key),
              let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([StoredToken].self, from: data) else { return nil }
        let tokens = stored.map { TimedToken(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence) }
        lock.lock()
        memory[key] = tokens
        lock.unlock()
        return tokens
    }

    func store(_ tokens: [TimedToken], for key: String) {
        lock.lock()
        memory[key] = tokens
        lock.unlock()
        guard let file = fileURL(for: key) else { return }
        let stored = tokens.map { StoredToken(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence) }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// すべての記録を消す(設定の「前回の文字起こし結果を消す」)
    func removeAll() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 記録の数(設定に出す)
    var storedCount: Int {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    private func fileURL(for key: String) -> URL? {
        // 見出しは長く記号も入るので、ファイル名には 64 ビットの FNV-1a を使う
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return directory?.appendingPathComponent(String(format: "%016llx", hash) + ".json")
    }
}
