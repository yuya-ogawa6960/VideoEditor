import Foundation

// =====================================================================
// 用語の登録(字幕の自動置き換え)。
//
// 「カフェ小川」→「CAFE OGAWA」のように、音声認識が毎回同じように書き間違える固有名詞を登録しておき、
// 文字起こしのあと(AI 仕上げの前と後)に自動で置き換える。プロジェクトをまたいで使う(端末に保存)。
// 字幕を直したときの「ほかの〇か所も変えますか?」で「次からも自動で直す」を選ぶと登録される。
// 設定の「用語の登録」で追加・削除できる。
// =====================================================================

struct CaptionTerm: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 置き換える前(音声認識が書く形)
    var from: String
    /// 置き換えた後。空なら消す
    var to: String
}

enum CaptionTermDictionary {
    private static let storageKey = "captions.termDictionary"

    static func load() -> [CaptionTerm] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let terms = try? JSONDecoder().decode([CaptionTerm].self, from: data) else { return [] }
        return terms
    }

    static func save(_ terms: [CaptionTerm]) {
        if let data = try? JSONEncoder().encode(terms) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 登録する(同じ「置き換える前」があれば、置き換えた後を新しいものにする)
    static func add(from: String, to: String) {
        let key = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let value = to.trimmingCharacters(in: .whitespacesAndNewlines)
        var terms = load()
        if let i = terms.firstIndex(where: { $0.from == key }) {
            terms[i].to = value
        } else {
            terms.append(CaptionTerm(from: key, to: value))
        }
        save(terms)
    }

    /// 登録した用語で字幕の文を置き換える(長い用語から。単語ごとの時刻は文字が変わった字幕だけ付け直す)
    static func apply(to cues: [SubtitleCue]) -> [SubtitleCue] {
        let terms = load()
            .filter { !$0.from.isEmpty && $0.from != $0.to }
            .sorted { $0.from.count > $1.from.count }
        guard !terms.isEmpty else { return cues }
        return cues.map { cue in
            var text = cue.text
            for term in terms where text.contains(term.from) {
                text = text.replacingOccurrences(of: term.from, with: term.to)
            }
            guard text != cue.text else { return cue }
            var result = cue
            result.text = text
            if !cue.words.isEmpty {
                result.words = SubtitleWordTiming.distribute(cue: result)
            }
            return result
        }
    }
}
