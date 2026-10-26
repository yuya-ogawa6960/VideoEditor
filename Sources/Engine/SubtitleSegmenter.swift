import Foundation
import NaturalLanguage

// =====================================================================
// 字幕セグメンタ(純粋ロジック、UI・AVFoundation 非依存)
//
// 入力: 時刻付きトークン [(text, start, end)](秒。基準は任意、出力も同じ基準)
// 出力: 文・文節単位で区切られた [SubtitleCue]
//
// 手順:
//   0. フィラー(あのー / えーと / um / uh …)・吃音・直後の重複を除去(removeFillers)
//      日本語では単独の相づち(うん / ふーん / へえ …)とローマ字の相づち(hun? / hmm …)も除去し、
//      分割後に相づち・句読点だけになった字幕は捨てる
//   1. トークンを連結して全文を作り、1文字ごとの時刻対応を保持
//   2. NLTokenizer(.sentence) と 。！？!?. 改行(および長い無音)で「文」に分割
//      → 文の途中では原則切らない
//   3. 制限(日本語 26 文字 / 6.0 秒、英語 42 文字 / 6.0 秒)を超える文だけ、
//      読点 → 助詞・接続語の境界 → 単語境界 の優先順で、中央に近い位置で再帰的に分割
//   4. 短すぎる文(< 1.0 秒 または < 4 文字)は前後と結合(制限内・間隔 < 0.8 秒のとき)
//   5. 時刻: 最低 1.0 秒、読む速さ(日 8 文字/秒・英 17 文字/秒)を満たすよう
//      次の字幕まで延長し、重なりは 次の開始 − 0.05 秒 にクランプ
// =====================================================================

/// 認識結果の1トークン
struct TimedToken: Equatable {
    var text: String
    var start: Double
    var end: Double
    /// 音声認識の自信度(0〜1)。わからなければ nil。低い言葉は字幕の一覧で要確認になる
    var confidence: Double?

    init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = max(start, end)
        self.confidence = confidence
    }

    var duration: Double { max(0, end - start) }
}

struct SubtitleSegmenter {

    // MARK: - フィラー辞書(ここを編集すれば挙動が変わる)

    /// 日本語: 単独トークンなら常に削除
    static let japaneseFillers: Set<String> = [
        "あの", "あのー", "あのう", "あのぉ", "あのさ", "あのね",
        "えー", "えーー", "えーと", "えーっと", "えっと", "えと", "ええと", "ええっと", "えっとー",
        "うーん", "うーーん", "んー", "んーと", "んーっと",
        "まあ", "まぁ", "まー",
        "ええ", "あー", "あーー", "えっ", "ん",
    ]
    /// 日本語: 文頭で単独のときだけ削除(相づち)
    static let japaneseSentenceStartFillers: Set<String> = ["うん", "ううん"]
    /// 日本語: 文頭かつ直後に間(> 0.3 秒 or 読点)があるときだけ削除
    static let japaneseSentenceStartPauseFillers: Set<String> = ["はい"]
    /// 日本語: 節の先頭で単独のときだけ削除
    static let japaneseClauseStartFillers: Set<String> = ["なんか", "なんて言うか", "なんていうか"]
    /// 日本語: 単独かつ直後に間(> 0.3 秒 or 読点)があるときだけ削除(「その、」)
    static let japanesePauseFillers: Set<String> = ["その", "この", "まあその"]

    /// 日本語: 相づち・感動詞。単独の発話(節の先頭かつ直後に間 or 句読点)のトークンなら削除。
    /// 「うんうん」「はいはい」のような繰り返しも削除。カタカナ・半角・長音(ー ～ 〜)・小書き母音の表記ゆれは
    /// backchannelKey で吸収するので、ここには代表的な表記だけを書けばよい
    static let japaneseBackchannels: [String] = [
        "うん", "うんうん", "ふーん", "ふん", "へえ", "へー", "ほう", "ほー",
        "ああ", "あー", "おお", "おー", "ええ", "はい",
    ]
    /// 日本語: 字幕全体がこれ(と上の相づち)だけのときに限り、その字幕ごと削除
    static let japaneseCueOnlyBackchannels: [String] = [
        "なるほど", "そうそう", "そっか",
    ]
    /// 日本語モードのみ: クラウド認識がローマ字で書いた相づち(hun? / hmm など)。
    /// トークン全体がこれ(大文字小文字無視・末尾の ?!.,… は無視)で、前後が英語の本文でないときだけ削除
    static let japaneseLatinInterjections: [String] = [
        "hun", "hmm", "hm", "mm", "mhm", "mm-hmm", "uh", "uh-huh", "um", "ah", "oh", "eh", "huh",
        "yeah", "yep", "nn", "n", "un", "fun", "hee", "hai", "aa", "oo", "ee",
        "hmmm", "mmm", "umm", "uhh", "ahh", "ohh", "hunn", "nnn", "mmhmm", "mm-hm", "uh-hu",
    ]

    private static let japaneseBackchannelKeys: Set<String> = Set(japaneseBackchannels.map { SubtitleSegmenter.backchannelKey($0) })
    private static let japaneseCueBackchannelKeys: Set<String> =
        japaneseBackchannelKeys.union(japaneseCueOnlyBackchannels.map { SubtitleSegmenter.backchannelKey($0) })
    private static let japaneseLatinInterjectionKeys: Set<String> = Set(japaneseLatinInterjections.map { SubtitleSegmenter.backchannelKey($0) })

    /// 英語: 単独トークンなら常に削除(小文字・句読点除去後で比較)
    static let englishFillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh",
        "hmm", "hm", "hmmm", "mm", "mmm", "mhm",
    ]
    /// 英語: 2語の挿入句。節頭にあり直後に間/句読点があるとき削除
    static let englishPhraseFillers: [[String]] = [["you", "know"], ["i", "mean"]]

    // MARK: - 分割境界の辞書

    /// 日本語: この助詞・接続助詞の直後は分割候補(優先度 2)
    static let japaneseBreakParticles: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "へ", "や",
        "から", "まで", "より", "ので", "のに", "けど", "けれど", "けれども",
        "て", "ば", "たら", "なら", "し", "ながら", "つつ", "ても", "でも",
        "のは", "には", "では", "とは", "って", "けども",
    ]
    /// 英語: この語の直前は分割候補(優先度 2)
    static let englishBreakWords: Set<String> = [
        "and", "but", "because", "so", "or", "which", "that", "when", "while",
        "if", "then", "although", "though", "after", "before", "until", "unless",
        "where", "who", "whereas", "since",
    ]

    // MARK: - 設定

    var language: TranscriptionLanguage
    var removeFillers: Bool = true
    /// 1字幕の最大文字数
    var maxCharacters: Int
    /// 1字幕の最大長(秒)
    var maxDuration: Double = 6.0
    /// 1字幕の最低表示時間(秒)
    var minDuration: Double = 1.0
    /// 読む速さ(文字/秒)。これを満たすよう終了時刻を延ばす
    var charactersPerSecond: Double
    /// 短い字幕を結合してよい最大の間隔(秒)
    var mergeGap: Double = 0.8
    /// これ以上の無音は文の切れ目とみなす(秒)
    var longPause: Double = 1.5
    /// 終了時刻の延長をこれ以上は行わない(秒)
    var maxExtension: Double = 3.0
    /// 最後の字幕の終了時刻の上限(クリップ終端など)。nil なら制限なし
    var hardEnd: Double? = nil

    init(language: TranscriptionLanguage, removeFillers: Bool = true) {
        self.language = language
        self.removeFillers = removeFillers
        switch language {
        case .japanese:
            maxCharacters = 26
            charactersPerSecond = 8
        case .english:
            maxCharacters = 42
            charactersPerSecond = 17
        }
    }

    private var isJapanese: Bool { language == .japanese }

    // MARK: - 公開 API

    func segment(_ rawTokens: [TimedToken]) -> [SubtitleCue] {
        var tokens = Self.normalize(rawTokens)
        if removeFillers {
            tokens = Self.removeFillerTokens(tokens, language: language)
        }
        guard !tokens.isEmpty else { return [] }

        let layout = makeLayout(tokens)
        guard !layout.scalars.isEmpty else { return [] }

        // 文に分割
        var sentences: [Range<Int>] = []
        for range in sentenceRanges(in: layout) {
            sentences.append(contentsOf: hardSplit(range, layout: layout, tokens: tokens))
        }

        // 制限を超える文を文節で分割
        var pieces: [Range<Int>] = []
        for sentence in sentences {
            pieces.append(contentsOf: softSplit(sentence, layout: layout, depth: 0))
        }

        // 短い断片を結合
        let merged = mergeShortPieces(pieces, layout: layout)

        // キューを作成
        var cues: [SubtitleCue] = []
        for range in merged {
            guard let r = trimmed(range, layout) else { continue }
            let text = Self.cleanCueText(layout.text(of: r))
            guard !text.isEmpty else { continue }
            // 句読点・記号だけ、または相づちだけの字幕は出さない
            if Self.isPunctuationOnly(text) { continue }
            if removeFillers, Self.isBackchannelOnlyText(text, language: language) { continue }
            let start = layout.starts[r.lowerBound]
            let end = max(start, layout.ends[r.upperBound - 1])
            var cue = SubtitleCue(start: start, end: end, text: text)
            cue.words = words(in: r, layout: layout)
            cues.append(cue)
        }
        cues.sort { $0.start < $1.start }
        adjustTiming(&cues)
        return cues
    }

    // MARK: - 単語タイミング(カラオケ風テンプレート用)

    /// 範囲内のスカラーを元トークンごとにまとめ、SubtitleWord の列にする。
    /// トークンの途中で分割された字幕でも、その字幕に含まれる部分だけが入る
    private func words(in r: Range<Int>, layout: Layout) -> [SubtitleWord] {
        var result: [SubtitleWord] = []
        var i = r.lowerBound
        while i < r.upperBound {
            let owner = layout.owner[i]
            if owner < 0 {
                i += 1
                continue
            }
            var j = i
            while j < r.upperBound, layout.owner[j] == owner { j += 1 }
            let text = layout.text(of: i..<j).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let start = layout.starts[i]
                let end = max(start, layout.ends[j - 1])
                result.append(SubtitleWord(text: text, start: start, end: end))
            }
            i = j
        }
        // 字幕本文(cleanCueText)と同じく、末尾の読点は最後の単語からも除く
        if let last = result.last {
            var text = last.text
            while let scalar = text.unicodeScalars.last, Self.clauseEnders.contains(scalar) {
                text.removeLast()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1].text = text
            }
        }
        return result
    }

    /// 単語の時刻を start...end に収める(字幕の時刻を変えたとき用)
    static func clampWords(_ words: [SubtitleWord], start: Double, end: Double) -> [SubtitleWord] {
        guard !words.isEmpty else { return words }
        let hi = max(start, end)
        return words.map { word in
            let s = min(max(word.start, start), hi)
            let e = min(max(word.end, s), hi)
            return SubtitleWord(text: word.text, start: s, end: e)
        }
    }

    // MARK: - トークン正規化

    private static func normalize(_ tokens: [TimedToken]) -> [TimedToken] {
        var result: [TimedToken] = []
        for raw in tokens {
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var token = raw
            token.text = text
            if let last = result.last, token.start < last.start {
                // 時刻が逆転していたら直前に揃える(安全策)
                token.start = last.start
                token.end = max(token.end, token.start)
            }
            result.append(token)
        }
        return result
    }

    // MARK: - フィラー除去

    static func removeFillerTokens(_ input: [TimedToken], language: TranscriptionLanguage) -> [TimedToken] {
        // トークン内の吃音("わ、わたし" → "わたし")
        var tokens: [TimedToken] = []
        for raw in normalize(input) {
            var token = raw
            token.text = collapseInnerStutter(token.text, language: language)
            if !token.text.isEmpty { tokens.append(token) }
        }

        var kept: [TimedToken] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let core = coreText(token.text, language: language)
            let prev = kept.last
            let next: TimedToken? = i + 1 < tokens.count ? tokens[i + 1] : nil

            // 句読点だけのトークンは直前に付ける
            if core.isEmpty {
                if !kept.isEmpty {
                    kept[kept.count - 1].text += token.text
                    kept[kept.count - 1].end = max(kept[kept.count - 1].end, token.end)
                }
                i += 1
                continue
            }

            let gapBefore: Double = prev.map { token.start - $0.end } ?? .infinity
            let gapAfter: Double = next.map { $0.start - token.end } ?? .infinity
            let prevText = prev?.text ?? ""
            let sentenceStart = prev == nil || endsWithSentencePunctuation(prevText) || gapBefore > 0.6
            let clauseStart = sentenceStart || endsWithClausePunctuation(prevText) || gapBefore > 0.3
            let pauseAfter = next == nil || gapAfter > 0.3
                || endsWithClausePunctuation(token.text) || endsWithSentencePunctuation(token.text)

            var drop = false
            var consumed = 1

            switch language {
            case .japanese:
                if japaneseFillers.contains(core) {
                    drop = true
                } else if japaneseSentenceStartFillers.contains(core), sentenceStart {
                    drop = true
                } else if japaneseSentenceStartPauseFillers.contains(core), sentenceStart, pauseAfter {
                    drop = true
                } else if japaneseClauseStartFillers.contains(core), clauseStart {
                    drop = true
                } else if japanesePauseFillers.contains(core), pauseAfter {
                    drop = true
                } else {
                    let key = backchannelKey(token.text)
                    if clauseStart, pauseAfter, isComposed(of: japaneseBackchannelKeys, key) {
                        // 単独の相づち(「うん、」「ふーん。」「はいはい」)
                        drop = true
                    } else if japaneseLatinInterjectionKeys.contains(key),
                              !isLatinContentToken(prev?.text),
                              !isLatinContentToken(next?.text) {
                        // ローマ字の相づち("hun?" "Hmm.")。英語の本文の一部なら残す
                        drop = true
                    }
                }
            case .english:
                let nextCore = next.map { coreText($0.text, language: language) } ?? ""
                if englishFillers.contains(core) {
                    drop = true
                } else if core == "so", sentenceStart, endsWithClausePunctuation(token.text) {
                    drop = true
                } else if core == "like" {
                    if nextCore == "like" {
                        drop = true
                    } else if endsWithClausePunctuation(token.text), clauseStart {
                        drop = true
                    }
                } else if let next, englishPhraseFillers.contains(where: { $0.count == 2 && $0[0] == core && $0[1] == nextCore }) {
                    let nextNext: TimedToken? = i + 2 < tokens.count ? tokens[i + 2] : nil
                    let pauseAfterPhrase = nextNext == nil
                        || (nextNext!.start - next.end) > 0.3
                        || endsWithClausePunctuation(next.text)
                        || endsWithSentencePunctuation(next.text)
                    if clauseStart, pauseAfterPhrase {
                        drop = true
                        consumed = 2
                    }
                }
            }

            if drop {
                i += consumed
                continue
            }

            // 直前と同一語の繰り返し("the the" / "はい はい")→ 後ろを残す
            if let prev, !kept.isEmpty {
                let prevCore = coreText(prev.text, language: language)
                if !prevCore.isEmpty, prevCore == core, gapBefore < 0.5, !isNumeric(core) {
                    var replacement = token
                    if let f = prev.text.first, f.isUppercase, let g = token.text.first, g.isLowercase {
                        replacement.text = capitalizedFirst(token.text)
                    }
                    kept[kept.count - 1] = replacement
                    i += 1
                    continue
                }
                // 吃音の接頭("わ、" + "わたし" / "I-" + "I'm")→ 前を捨てる
                if prevCore.count <= 2, core.count > prevCore.count, !isNumeric(prevCore),
                   core.lowercased().hasPrefix(prevCore.lowercased()),
                   gapBefore < 0.5, isStutterMarker(prev.text, gapAfter: gapBefore, language: language) {
                    kept[kept.count - 1] = token
                    i += 1
                    continue
                }
            }

            kept.append(token)
            i += 1
        }
        return kept
    }

    /// "わ、わたし" → "わたし"、"I-I" → "I"
    static func collapseInnerStutter(_ text: String, language: TranscriptionLanguage) -> String {
        let separators: [Character] = language == .japanese ? ["、", ","] : ["-", ","]
        for separator in separators {
            guard let index = text.firstIndex(of: separator) else { continue }
            let head = String(text[..<index])
            let tail = String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, head.count <= 2, !tail.isEmpty, !isNumeric(head),
                  tail.count >= head.count,
                  tail.lowercased().hasPrefix(head.lowercased()) else { continue }
            return tail
        }
        return text
    }

    private static func isStutterMarker(_ previousText: String, gapAfter: Double, language: TranscriptionLanguage) -> Bool {
        guard let last = previousText.last else { return false }
        switch language {
        case .japanese:
            return last == "、" || last == "っ" || last == "ー" || gapAfter < 0.2
        case .english:
            return last == "-" || last == ","
        }
    }

    /// 前後の句読点・記号・空白を除いた本体(英語は小文字化)
    static func coreText(_ text: String, language: TranscriptionLanguage) -> String {
        let scalars = Array(text.unicodeScalars)
        var lo = 0
        var hi = scalars.count
        while lo < hi, isPunctuationOrSpace(scalars[lo]) { lo += 1 }
        while hi > lo, isPunctuationOrSpace(scalars[hi - 1]) { hi -= 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lo..<hi])
        let core = String(view)
        return language == .english ? core.lowercased() : core
    }

    private static func isPunctuationOrSpace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .otherPunctuation, .openPunctuation, .closePunctuation, .dashPunctuation,
             .initialPunctuation, .finalPunctuation, .connectorPunctuation,
             .otherSymbol, .mathSymbol, .currencySymbol:
            return true
        default:
            return false
        }
    }

    // MARK: - 相づちの判定

    /// 相づち照合用の正規化キー: 全角/半角の統一(NFKC)・カタカナ→ひらがな・小文字化・
    /// 長音(ー ～ 〜 ~ と小書き母音)を「ー」1 つに統一・前後の句読点と空白を除去
    static func backchannelKey(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping
        s = s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s
        s = s.lowercased()
        let longMarks: Set<Unicode.Scalar> = ["ー", "～", "〜", "~", "〰", "ｰ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]
        var view = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if longMarks.contains(scalar) {
                if view.last != "ー" { view.append("ー") }
            } else {
                view.append(scalar)
            }
        }
        let scalars = Array(view)
        var lo = 0
        var hi = scalars.count
        while lo < hi, isPunctuationOrSpace(scalars[lo]) { lo += 1 }
        while hi > lo, isPunctuationOrSpace(scalars[hi - 1]) { hi -= 1 }
        var core = String.UnicodeScalarView()
        core.append(contentsOf: scalars[lo..<hi])
        return String(core)
    }

    /// key が辞書の語の繰り返し・連結だけでできているか(「うんうん」「はいはい」「ああ」)。
    /// 末尾の促音(「ああっ」「へえっ」)は無視する
    private static func isComposed(of dictionary: Set<String>, _ key: String) -> Bool {
        var chars = Array(key)
        while chars.count > 1, chars.last == "っ" { chars.removeLast() }
        guard !chars.isEmpty, chars.count <= 24 else { return false }
        var reachable = [Bool](repeating: false, count: chars.count + 1)
        reachable[0] = true
        for i in 0..<chars.count where reachable[i] {
            for j in (i + 1)...chars.count where !reachable[j] {
                if dictionary.contains(String(chars[i..<j])) { reachable[j] = true }
            }
        }
        return reachable[chars.count]
    }

    /// 英字を含み、ローマ字の相づちではない(=英語の本文の)トークンか
    private static func isLatinContentToken(_ text: String?) -> Bool {
        guard let text else { return false }
        let key = backchannelKey(text)
        guard key.unicodeScalars.contains(where: { isASCIIAlphanumeric($0) && !($0.value >= 48 && $0.value <= 57) }) else {
            return false
        }
        return !japaneseLatinInterjectionKeys.contains(key)
    }

    /// 句読点・記号・空白だけの文字列か
    static func isPunctuationOnly(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { isPunctuationOrSpace($0) }
    }

    /// 字幕本文が相づち(日本語)/フィラー(英語)だけでできているか。句読点・空白は無視
    static func isBackchannelOnlyText(_ text: String, language: TranscriptionLanguage) -> Bool {
        // 長音記号(〜 ～)が区切り扱いにならないよう、先に正規化してから区切る
        let normalized = language == .japanese ? backchannelKey(text) : text.lowercased()
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if isPunctuationOrSpace(scalar) {
                if !current.isEmpty { pieces.append(String(current)) }
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        guard !pieces.isEmpty else { return true }
        switch language {
        case .japanese:
            return pieces.allSatisfy { piece in
                japaneseLatinInterjectionKeys.contains(piece) || isComposed(of: japaneseCueBackchannelKeys, piece)
            }
        case .english:
            return pieces.allSatisfy { englishFillers.contains($0) }
        }
    }

    private static func isNumeric(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber }
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    // MARK: - 句読点

    /// 文末記号(常に文の切れ目)
    static let sentenceEnders: Set<Unicode.Scalar> = ["。", "！", "？", "!", "?", ".", "…", "‼", "⁉"]
    /// 読点類(分割候補・末尾からは除去)
    static let clauseEnders: Set<Unicode.Scalar> = ["、", "，", ",", ";", "；", ":", "："]
    /// 文末記号に続けて取り込む閉じ記号
    private static let trailingClosers: Set<Unicode.Scalar> = ["」", "』", "）", ")", "\"", "”", "’", "'", "】", "〕"]

    static func endsWithSentencePunctuation(_ text: String) -> Bool {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, trailingClosers.contains(last) || last.properties.isWhitespace {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return sentenceEnders.contains(last)
    }

    static func endsWithClausePunctuation(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return clauseEnders.contains(last)
    }

    // MARK: - レイアウト(全文と文字ごとの時刻)

    private struct Layout {
        var scalars: [Unicode.Scalar] = []
        /// 各スカラーの元トークン番号(区切り空白は -1)
        var owner: [Int] = []
        var starts: [Double] = []
        var ends: [Double] = []

        var fullText: String { text(of: 0..<scalars.count) }

        func text(of range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
    }

    private func makeLayout(_ tokens: [TimedToken]) -> Layout {
        var layout = Layout()
        for (index, token) in tokens.enumerated() {
            let tokenScalars = Array(token.text.unicodeScalars)
            guard !tokenScalars.isEmpty else { continue }

            if let lastScalar = layout.scalars.last {
                let needsSpace: Bool
                if isJapanese {
                    needsSpace = Self.isASCIIAlphanumeric(lastScalar) && Self.isASCIIAlphanumeric(tokenScalars[0])
                } else {
                    needsSpace = !lastScalar.properties.isWhitespace
                }
                if needsSpace {
                    let previousEnd = layout.ends.last ?? token.start
                    layout.scalars.append(" ")
                    layout.owner.append(-1)
                    layout.starts.append(previousEnd)
                    layout.ends.append(max(previousEnd, token.start))
                }
            }

            let count = Double(tokenScalars.count)
            let duration = token.duration
            for (i, scalar) in tokenScalars.enumerated() {
                layout.scalars.append(scalar)
                layout.owner.append(index)
                layout.starts.append(token.start + duration * Double(i) / count)
                layout.ends.append(token.start + duration * Double(i + 1) / count)
            }
        }
        return layout
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        let v = scalar.value
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }

    private func trimmed(_ range: Range<Int>, _ layout: Layout) -> Range<Int>? {
        var lo = range.lowerBound
        var hi = range.upperBound
        while lo < hi, layout.scalars[lo].properties.isWhitespace { lo += 1 }
        while hi > lo, layout.scalars[hi - 1].properties.isWhitespace { hi -= 1 }
        return lo < hi ? lo..<hi : nil
    }

    private func characterCount(_ range: Range<Int>, _ layout: Layout) -> Int {
        var count = 0
        for i in range {
            let scalar = layout.scalars[i]
            if scalar.properties.isWhitespace {
                if !isJapanese { count += 1 }
            } else {
                count += 1
            }
        }
        return count
    }

    private func duration(_ range: Range<Int>, _ layout: Layout) -> Double {
        guard !range.isEmpty else { return 0 }
        return max(0, layout.ends[range.upperBound - 1] - layout.starts[range.lowerBound])
    }

    private func fitsLimits(_ range: Range<Int>, _ layout: Layout) -> Bool {
        characterCount(range, layout) <= maxCharacters && duration(range, layout) <= maxDuration
    }

    private func isShort(_ range: Range<Int>, _ layout: Layout) -> Bool {
        duration(range, layout) < minDuration || characterCount(range, layout) < 4
    }

    // MARK: - 文の境界

    private var nlLanguage: NLLanguage { isJapanese ? .japanese : .english }

    private func sentenceRanges(in layout: Layout) -> [Range<Int>] {
        let text = layout.fullText
        let total = layout.scalars.count
        let view = text.unicodeScalars
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(nlLanguage)

        var ranges: [Range<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let lo = view.distance(from: view.startIndex, to: range.lowerBound)
            let hi = view.distance(from: view.startIndex, to: range.upperBound)
            if lo >= 0, hi <= total, hi > lo {
                ranges.append(lo..<hi)
            }
            return true
        }

        // トークナイザが飛ばした部分も落とさない
        var filled: [Range<Int>] = []
        var cursor = 0
        for range in ranges where range.lowerBound >= cursor {
            if range.lowerBound > cursor { filled.append(cursor..<range.lowerBound) }
            filled.append(range)
            cursor = range.upperBound
        }
        if cursor < total { filled.append(cursor..<total) }
        return filled.isEmpty ? [0..<total] : filled
    }

    /// 文末記号・改行・長い無音で強制分割
    private func hardSplit(_ range: Range<Int>, layout: Layout, tokens: [TimedToken]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        let n = range.upperBound
        var lo = range.lowerBound
        var i = range.lowerBound

        func nextOwner(after index: Int) -> Int? {
            var j = index + 1
            while j < n {
                if layout.owner[j] >= 0 { return layout.owner[j] }
                j += 1
            }
            return nil
        }

        while i < n {
            let scalar = layout.scalars[i]
            var breakAfter = false

            if scalar == "\n" || scalar == "\r" {
                breakAfter = true
            } else if scalar == "。" || scalar == "！" || scalar == "？" || scalar == "‼" || scalar == "⁉" {
                breakAfter = true
            } else if scalar == "." || scalar == "!" || scalar == "?" || scalar == "…" {
                // 次が空白か末尾なら文末("3.5" や "Mr." は分割しない)
                let next = i + 1
                let followedBySpace = next >= n || layout.scalars[next].properties.isWhitespace
                if followedBySpace && !(scalar == "." && isLikelyAbbreviation(before: i, layout: layout)) {
                    breakAfter = true
                }
            }

            // 長い無音(トークン間)
            if !breakAfter, i + 1 < n {
                let a = layout.owner[i]
                let isLastOfToken = a >= 0 && (layout.owner[i + 1] != a)
                if isLastOfToken, let b = nextOwner(after: i), b != a, b < tokens.count, a < tokens.count,
                   tokens[b].start - tokens[a].end > longPause {
                    breakAfter = true
                }
            }

            if breakAfter {
                var j = i + 1
                while j < n, Self.trailingClosers.contains(layout.scalars[j]) || Self.sentenceEnders.contains(layout.scalars[j]) {
                    j += 1
                }
                if j > lo { result.append(lo..<j) }
                lo = j
                i = j
            } else {
                i += 1
            }
        }
        if lo < n { result.append(lo..<n) }
        return result
    }

    /// "Mr." "Dr." "U.S." のような略語か(直前が 3 文字以下の大文字始まりの英字)
    private func isLikelyAbbreviation(before dotIndex: Int, layout: Layout) -> Bool {
        var j = dotIndex - 1
        var letters: [Unicode.Scalar] = []
        while j >= 0, letters.count <= 3 {
            let s = layout.scalars[j]
            if s.properties.isAlphabetic && s.isASCII {
                letters.insert(s, at: 0)
                j -= 1
            } else {
                break
            }
        }
        guard !letters.isEmpty, letters.count <= 3 else { return false }
        let boundaryOK = j < 0 || layout.scalars[j].properties.isWhitespace || layout.scalars[j] == "."
        let first = letters[0].value
        let isUpper = first >= 65 && first <= 90
        return boundaryOK && isUpper
    }

    // MARK: - 文節での分割

    private func softSplit(_ range: Range<Int>, layout: Layout, depth: Int) -> [Range<Int>] {
        guard let r = trimmed(range, layout) else { return [] }
        if fitsLimits(r, layout) || depth > 16 { return [r] }
        guard let p = bestBreak(in: r, layout: layout) else { return [r] }
        return softSplit(r.lowerBound..<p, layout: layout, depth: depth + 1)
            + softSplit(p..<r.upperBound, layout: layout, depth: depth + 1)
    }

    /// 優先度順の候補から、中央寄り(20%〜80%)で最も中央に近い位置を選ぶ
    private func bestBreak(in r: Range<Int>, layout: Layout) -> Int? {
        let tiers = breakCandidates(in: r, layout: layout)
        let length = Double(r.count)
        guard length >= 2 else { return nil }
        let mid = Double(r.lowerBound) + length / 2

        let bands: [(Double, Double)] = [(0.2, 0.8), (0.0, 1.0)]
        for band in bands {
            for tier in tiers {
                var best: Int? = nil
                var bestDistance = Double.infinity
                for p in tier {
                    guard p > r.lowerBound, p < r.upperBound else { continue }
                    let fraction = Double(p - r.lowerBound) / length
                    guard fraction >= band.0, fraction <= band.1 else { continue }
                    guard trimmed(r.lowerBound..<p, layout) != nil,
                          trimmed(p..<r.upperBound, layout) != nil else { continue }
                    let distance = abs(Double(p) - mid)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = p
                    }
                }
                if let best { return best }
            }
        }
        return nil
    }

    /// [優先度1: 読点・ダッシュ, 優先度2: 助詞/接続語, 優先度3: 単語境界]
    private func breakCandidates(in r: Range<Int>, layout: Layout) -> [[Int]] {
        var tier1: [Int] = []
        var tier2: [Int] = []
        var tier3: [Int] = []

        // 優先度1: 読点・セミコロン・ダッシュの直後
        for i in r {
            let s = layout.scalars[i]
            if Self.clauseEnders.contains(s) {
                tier1.append(i + 1)
            } else if s == "–" || s == "—" || s == "―" {
                tier1.append(i + 1)
            } else if s == "-", i > r.lowerBound, i + 1 < r.upperBound,
                      layout.scalars[i - 1].properties.isWhitespace,
                      layout.scalars[i + 1].properties.isWhitespace {
                tier1.append(i + 1)
            }
        }

        // 優先度2・3: 単語トークナイザ
        let text = layout.text(of: r)
        let view = text.unicodeScalars
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(nlLanguage)
        let base = r.lowerBound
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { wordRange, _ in
            let lo = base + view.distance(from: view.startIndex, to: wordRange.lowerBound)
            let hi = base + view.distance(from: view.startIndex, to: wordRange.upperBound)
            let word = String(text[wordRange])
            if isJapanese {
                if Self.japaneseBreakParticles.contains(word) {
                    tier2.append(hi)
                } else if let last = word.unicodeScalars.last, last == "て" || last == "で" {
                    tier2.append(hi)
                }
                tier3.append(hi)
            } else {
                if Self.englishBreakWords.contains(word.lowercased()) {
                    tier2.append(lo)
                }
            }
            return true
        }

        if !isJapanese {
            for i in r where layout.scalars[i].properties.isWhitespace {
                tier3.append(i)
            }
        }
        return [tier1, tier2, tier3]
    }

    // MARK: - 短い断片の結合

    private func mergeShortPieces(_ pieces: [Range<Int>], layout: Layout) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for piece in pieces {
            guard let current = trimmed(piece, layout) else { continue }
            if let last = merged.last {
                let gap = layout.starts[current.lowerBound] - layout.ends[last.upperBound - 1]
                if (isShort(last, layout) || isShort(current, layout)), gap < mergeGap {
                    let combined = last.lowerBound..<current.upperBound
                    if fitsLimits(combined, layout) {
                        merged[merged.count - 1] = combined
                        continue
                    }
                }
            }
            merged.append(current)
        }
        return merged
    }

    // MARK: - 仕上げ

    /// 改行→空白、連続空白の圧縮、末尾の読点を除去。文末記号は残す
    static func cleanCueText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.unicodeScalars.last, clauseEnders.contains(last) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func adjustTiming(_ cues: inout [SubtitleCue]) {
        guard !cues.isEmpty else { return }
        for i in cues.indices {
            let start = cues[i].start
            let originalEnd = max(cues[i].end, start)
            let limit: Double
            if i + 1 < cues.count {
                limit = cues[i + 1].start - 0.05
            } else {
                limit = hardEnd ?? .infinity
            }
            let needed = max(minDuration, Double(cues[i].text.count) / charactersPerSecond)
            let desired = min(max(originalEnd, start + needed), originalEnd + maxExtension)
            var end = min(desired, limit)
            if end < start + 0.2 {
                // 次の字幕が直後に始まる場合でも最低限は表示する
                end = start + 0.2
            }
            cues[i].end = end
            cues[i].words = Self.clampWords(cues[i].words, start: start, end: end)
        }
    }
}
