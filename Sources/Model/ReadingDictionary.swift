import Foundation

// =====================================================================
// 読み方の登録(読み上げ用)。
//
// 「家系ラーメン」を「けけいラーメン」と読むように、読み上げの声(端末・OpenAI・Google)が
// 読み間違える言葉を「いえけいラーメン」のような読みで登録しておき、声に渡す直前にだけ置き換える。
// 画面の文章・字幕はそのまま。端末に保存し、プロジェクトをまたいで使う。
// =====================================================================

struct ReadingEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 文章に書く形(家系ラーメン)
    var word: String
    /// 読ませたい形(いえけいラーメン)
    var reading: String
}

enum ReadingDictionary {
    private static let storageKey = "speech.readingDictionary"

    static func load() -> [ReadingEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([ReadingEntry].self, from: data) else { return [] }
        return entries
    }

    static func save(_ entries: [ReadingEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 登録する(同じ言葉があれば読みを新しいものにする)
    static func add(word: String, reading: String) {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty, key != value else { return }
        var entries = load()
        if let i = entries.firstIndex(where: { $0.word == key }) {
            entries[i].reading = value
        } else {
            entries.append(ReadingEntry(word: key, reading: value))
        }
        save(entries)
    }

    /// 声に渡す文章にする(長い言葉から置き換える。「家系ラーメン」を「家系」より先に)
    static func apply(to text: String) -> String {
        let entries = load()
            .filter { !$0.word.isEmpty && !$0.reading.isEmpty }
            .sorted { $0.word.count > $1.word.count }
        guard !entries.isEmpty else { return text }
        var result = text
        for entry in entries where result.contains(entry.word) {
            result = result.replacingOccurrences(of: entry.word, with: entry.reading)
        }
        return result
    }
}
