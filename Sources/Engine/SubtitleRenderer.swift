import Foundation
import UIKit
import CoreImage
import NaturalLanguage

// =====================================================================
// SubtitleRenderer: 字幕テキスト → 配置済み CIImage(キャッシュ付き・スレッドセーフ)
//
// テンプレート(SubtitleStyle.template):
//   plain         従来どおり(縁取り or 背景)
//   karaoke       現在時刻までの単語を highlightColor で
//   boxPop        現在の単語を色付きの角丸ボックスで(登場時に少し大きく)
//   outlineBig    太い縁取り・大きめ
//   pillHighlight 現在の単語の後ろに丸い帯
//   typewriter    文字が順に現れる(単語タイミングがあればそれに合わせ、無ければ cue の長さから)
// 単語タイミング(cue.words)が無いテンプレートは plain と同じ描画になる。
// 描画結果は「表示状態」(何単語目まで、など)ごとにキャッシュするので、毎フレームの再描画は起きない。
//
// 改行(全テンプレート共通、breakText):
//   - 1 行に収まれば 1 行。収まらなければ最大 2 行に、見た目の中央付近(1 行目がやや短いか同じ)で改行
//   - 改行位置の優先度: 、。の後 → 助詞の後(NLTokenizer の単語境界)→ 任意の単語境界。単語の途中では切らない
//     英語は空白で同様にバランスを取る
//   - 禁則: 行頭に 、。ー」っ ゃ などを置かない / 行末に 「『（【 を置かない
//   - 2 行でも幅に収まらなければフォントを 80% まで縮小し、それでも無理なら 3 行目を使う
//   - 各行は中央揃え。カラオケ系(単語ボックス)も同じ行の割り当て(文字位置で 1 行目 / 2 行目)を使う
//   - 表示用に字幕末尾の「。」は省く(途中の句読点は残す)
// =====================================================================

enum SubtitleRenderer {

    /// NSCache 自体がスレッドセーフ
    private static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.countLimit = 160
        return c
    }()

    // MARK: - 公開 API

    /// Image already positioned inside a canvas of renderSize (CoreImage coords, origin bottom-left).
    /// 従来 API(単語タイミングなし = plain 相当)
    static func image(lines: [String], style: SubtitleStyle, renderSize: CGSize) -> CIImage? {
        image(lines: lines, words: [], originalText: "", time: 0, cueStart: 0, cueEnd: 0,
              style: style, renderSize: renderSize)
    }

    /// テンプレート対応版。words は cue.words(出力タイムライン秒)、originalText は cue.text、
    /// time は現在の出力時刻。配置済み(左下原点)の CIImage を返す
    static func image(lines: [String],
                      words: [SubtitleWord],
                      originalText: String,
                      time: Double,
                      cueStart: Double,
                      cueEnd: Double,
                      style: SubtitleStyle,
                      renderSize: CGSize) -> CIImage? {
        // 改行は描画側で決め直す(既存の改行は空白扱い)。末尾の「。」は表示しない
        let cleaned = lines
            .map { strippingFinalPeriod(flattened($0)) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, renderSize.width >= 2, renderSize.height >= 2 else { return nil }

        let state = displayState(lines: cleaned, words: words, originalText: originalText,
                                 time: time, cueStart: cueStart, cueEnd: cueEnd, style: style)
        let key = cacheKey(lines: cleaned, style: style, renderSize: renderSize, state: state)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let rendered = render(lines: cleaned, state: state, style: style, renderSize: renderSize) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    // MARK: - 表示状態(テンプレートごとの離散的な状態)

    private enum WordMode {
        case none
        /// highlighted 個目までの単語を強調色で
        case karaoke(highlighted: Int)
        /// current 番目の単語を箱で。pop は 2 → 1 → 0 と小さくなる
        case boxPop(current: Int, pop: Int)
        case pill(current: Int)
    }

    private struct DisplayState {
        /// 1 行目を単語単位で描くときの単語列(空なら通常描画)
        var words: [String] = []
        var hasSpaces: Bool = false
        var mode: WordMode = .none
        /// タイプライターで 1 行目に表示する文字数(nil = 全部)
        var visibleCharacters: Int? = nil

        var key: String {
            var s = ""
            switch mode {
            case .none: s = "n"
            case .karaoke(let h): s = "k\(h)"
            case .boxPop(let c, let p): s = "b\(c).\(p)"
            case .pill(let c): s = "p\(c)"
            }
            if let v = visibleCharacters { s += "|t\(v)" }
            if !words.isEmpty { s += "|w\(words.count)\(hasSpaces)" }
            return s
        }
    }

    private static func displayState(lines: [String],
                                     words: [SubtitleWord],
                                     originalText: String,
                                     time: Double,
                                     cueStart: Double,
                                     cueEnd: Double,
                                     style: SubtitleStyle) -> DisplayState {
        var state = DisplayState()
        let template = style.template
        guard template != .plain, template != .outlineBig else { return state }

        let first = lines[0]
        // lines と同じ整形(改行の除去・末尾の「。」の省略)をしてから比べる
        let original = strippingFinalPeriod(flattened(originalText))
        var usableWords = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        // 最後の単語の末尾の「。」も表示しない
        if var last = usableWords.last {
            last.text = strippingFinalPeriod(last.text)
            if last.text.isEmpty {
                usableWords.removeLast()
            } else {
                usableWords[usableWords.count - 1] = last
            }
        }
        let wordsMatchFirstLine = !usableWords.isEmpty && (original.isEmpty || first == original)

        switch template {
        case .plain, .outlineBig:
            return state

        case .typewriter:
            let total = first.count
            guard total > 0 else { return state }
            var visible = total
            if wordsMatchFirstLine {
                var count = 0
                for w in usableWords {
                    let chars = w.text.count
                    if time >= w.end {
                        count += chars
                    } else if time >= w.start {
                        let span = max(w.end - w.start, 0.001)
                        count += Int(ceil((time - w.start) / span * Double(chars)))
                    }
                }
                visible = min(total, max(0, count))
            } else if cueEnd > cueStart {
                let typing = min((cueEnd - cueStart) * 0.6, 0.06 * Double(total) + 0.2)
                let progress = typing > 0 ? min(1, max(0, (time - cueStart) / typing)) : 1
                visible = min(total, max(0, Int(ceil(progress * Double(total)))))
            }
            state.visibleCharacters = visible >= total ? nil : visible
            return state

        case .karaoke, .boxPop, .pillHighlight:
            guard wordsMatchFirstLine else { return state }
            state.words = usableWords.map { $0.text.trimmingCharacters(in: .whitespaces) }
            state.hasSpaces = first.contains(" ")
            var current = -1
            for (i, w) in usableWords.enumerated() where w.start <= time {
                current = i
            }
            switch template {
            case .karaoke:
                state.mode = .karaoke(highlighted: current + 1)
            case .boxPop:
                var pop = 0
                if current >= 0 {
                    let since = time - usableWords[current].start
                    if since < 0.07 { pop = 2 } else if since < 0.14 { pop = 1 }
                }
                state.mode = .boxPop(current: current, pop: pop)
            default:
                state.mode = .pill(current: current)
            }
            return state
        }
    }

    // MARK: - 内部

    private static func cacheKey(lines: [String], style: SubtitleStyle, renderSize: CGSize, state: DisplayState) -> NSString {
        let text = lines.joined(separator: "\u{1F}")
        let s = "\(text)|\(style.position.rawValue)|\(style.color.rawValue)|\(style.sizeRatio)|"
            + "\(style.hasBackground)|\(style.template.rawValue)|\(style.highlightColorHex)|\(style.fontName ?? "")|"
            + "\(state.key)|\(Int(renderSize.width))x\(Int(renderSize.height))"
        return s as NSString
    }

    private static func subtitleFont(for style: SubtitleStyle, size: CGFloat) -> UIFont {
        if let name = style.fontName, !name.isEmpty, let custom = UIFont(name: name, size: size) {
            return custom
        }
        // 既定は映画字幕のような細めの角ゴシック(太いシステム書体は野暮ったく見えるため)
        if let hiragino = UIFont(name: "HiraginoSans-W3", size: size) {
            return hiragino
        }
        return UIFont.systemFont(ofSize: size, weight: .medium)
    }

    private static func outlineAttributes(font: UIFont, color: UIColor, outlineWidth: CGFloat,
                                          paragraph: NSParagraphStyle?) -> [NSAttributedString.Key: Any] {
        // strokeWidth はフォントサイズに対する %。線は輪郭の中心に描かれるため外側は半分
        let percent = outlineWidth * 2 / max(font.pointSize, 1) * 100
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .strokeColor: color,
            .strokeWidth: NSNumber(value: Double(percent))
        ]
        if let paragraph { attrs[.paragraphStyle] = paragraph }
        return attrs
    }

    private struct WordBox {
        let text: String
        /// ブロック内の位置(左上原点)
        let rect: CGRect
    }

    // MARK: - 表示用テキストの整形

    /// 改行を除いて 1 つの文字列にする(改行位置は breakText で決め直す)
    static func flattened(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return trimmed }
        let separator = containsJapanese(trimmed) ? "" : " "
        var result = trimmed
            .replacingOccurrences(of: "\r\n", with: separator)
            .replacingOccurrences(of: "\r", with: separator)
            .replacingOccurrences(of: "\n", with: separator)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 字幕の最後の「。」を除く(日本語字幕の慣例。途中の句読点は残す)
    static func strippingFinalPeriod(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, last == "。" || last == "｡" {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// ひらがな・カタカナ・漢字・和文記号を含むか
    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3000...0x30FF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xFF61...0xFF9F).contains(v)
        }
    }

    // MARK: - 改行(文節・禁則対応)

    /// 行頭に置かない文字(禁則)
    private static let noLineStart: Set<Character> = [
        "、", "。", "，", "．", "・", "：", "；", "？", "！", "ー", "」", "』", "）", "】",
        "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ",
        "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ",
        ",", ".", "?", "!", ":", ";", ")", "…", "〜", "～",
    ]
    /// 行末に置かない文字(禁則)
    private static let noLineEnd: Set<Character> = ["「", "『", "（", "【", "(", "“"]
    /// この助詞の直後は改行候補(優先度 2)
    private static let lineBreakParticles: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "へ", "や",
        "から", "まで", "より", "けど", "ので", "のに", "って",
    ]

    private struct BrokenText {
        var lines: [String]
        /// 各行の先頭が元の文字列の何文字目か(Character 単位)
        var starts: [Int]
        /// すべての行が幅に収まっているか
        var fits: Bool
    }

    /// 改行候補(位置 p = p 文字目の直前で改行)。優先度順に [、。の後, 助詞の後, 単語境界]
    private static func lineBreakCandidates(_ chars: [Character], text: String, japanese: Bool) -> [[Int]] {
        let n = chars.count
        guard n >= 2 else { return [[], [], []] }
        var tier1 = Set<Int>()
        var tier2 = Set<Int>()
        var tier3 = Set<Int>()
        let japaneseBreakers: Set<Character> = ["、", "。", "，", "！", "？", "!", "?"]
        let englishBreakers: Set<Character> = [",", ".", ";", ":", "!", "?", "、", "。"]

        for i in 1..<n {
            if japanese, japaneseBreakers.contains(chars[i - 1]) {
                tier1.insert(i)
            }
            if chars[i].isWhitespace {
                if !japanese, englishBreakers.contains(chars[i - 1]) {
                    tier1.insert(i)
                } else {
                    tier3.insert(i)
                }
            }
        }

        if japanese {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.setLanguage(.japanese)
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let lo = text.distance(from: text.startIndex, to: range.lowerBound)
                let hi = text.distance(from: text.startIndex, to: range.upperBound)
                if Self.lineBreakParticles.contains(String(text[range])) {
                    tier2.insert(hi)
                }
                tier3.insert(lo)
                tier3.insert(hi)
                return true
            }
        }

        func ordered(_ set: Set<Int>) -> [Int] {
            set.filter { $0 > 0 && $0 < n }.sorted()
        }
        return [ordered(tier1), ordered(tier2), ordered(tier3)]
    }

    /// p で改行してよいか(禁則: 行頭・行末の文字)
    private static func isLegalBreak(_ chars: [Character], at p: Int) -> Bool {
        var a = p - 1
        while a >= 0, chars[a].isWhitespace { a -= 1 }
        var b = p
        while b < chars.count, chars[b].isWhitespace { b += 1 }
        guard a >= 0, b < chars.count else { return false }
        return !noLineEnd.contains(chars[a]) && !noLineStart.contains(chars[b])
    }

    /// text を最大 maxLines 行に分ける。収まれば 1 行のまま。
    /// allowedStarts を渡すと、2 行目以降の先頭がその文字位置(単語の先頭)になる位置だけで改行する
    private static func breakText(_ text: String, font: UIFont, maxWidth: CGFloat, maxLines: Int,
                                  allowedStarts: Set<Int>?) -> BrokenText {
        let chars = Array(text)
        let count = chars.count
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var widthCache: [Int: CGFloat] = [:]

        func trim(_ lo: Int, _ hi: Int) -> (Int, Int) {
            var a = lo
            var b = hi
            while a < b, chars[a].isWhitespace { a += 1 }
            while b > a, chars[b - 1].isWhitespace { b -= 1 }
            return (a, b)
        }
        func width(_ lo: Int, _ hi: Int) -> CGFloat {
            let (a, b) = trim(lo, hi)
            guard a < b else { return 0 }
            let key = a * (count + 1) + b
            if let cached = widthCache[key] { return cached }
            let w = ceil((String(chars[a..<b]) as NSString).size(withAttributes: attrs).width)
            widthCache[key] = w
            return w
        }
        func make(_ breaks: [Int]) -> BrokenText {
            var lines: [String] = []
            var starts: [Int] = []
            var fits = true
            let bounds = [0] + breaks + [count]
            for k in 0..<(bounds.count - 1) {
                let (a, b) = trim(bounds[k], bounds[k + 1])
                guard a < b else { continue }
                lines.append(String(chars[a..<b]))
                starts.append(a)
                if width(a, b) > maxWidth { fits = false }
            }
            return BrokenText(lines: lines, starts: starts, fits: fits)
        }

        let (a0, b0) = trim(0, count)
        guard a0 < b0 else { return BrokenText(lines: [], starts: [], fits: true) }
        if maxLines <= 1 || width(a0, b0) <= maxWidth { return make([]) }

        // --- 候補(禁則を満たすもの)
        let japanese = containsJapanese(text)
        let rawTiers = lineBreakCandidates(chars, text: text, japanese: japanese)
        var tiers: [[Int]] = rawTiers.map { tier in tier.filter { isLegalBreak(chars, at: $0) } }
        if let allowedStarts {
            // 単語ボックスの途中で行が変わらないよう、単語の先頭で始まる位置だけに絞る
            let restricted = tiers.map { tier in tier.filter { allowedStarts.contains(trim($0, count).0) } }
            if restricted.contains(where: { !$0.isEmpty }) {
                tiers = restricted
            } else {
                let wordStarts = allowedStarts.filter { $0 > a0 && $0 < b0 && isLegalBreak(chars, at: $0) }.sorted()
                if !wordStarts.isEmpty { tiers = [wordStarts] }
            }
        }

        // --- バランスの良い位置を再帰的に選ぶ(1 行目がやや短いか同じ長さを優先)
        let bias = font.pointSize * 0.5
        func split(_ lo: Int, _ hi: Int, _ k: Int) -> [Int] {
            let (a, b) = trim(lo, hi)
            guard k >= 2, a < b else { return [] }
            let total = width(a, b)
            if total <= maxWidth { return [] }
            let target = total / CGFloat(k)
            func cost(_ p: Int) -> CGFloat {
                let w1 = width(a, p)
                return abs(w1 - target) + (w1 > target ? bias : 0)
            }
            func valid(_ p: Int) -> Bool {
                p > a && p < b && width(a, p) > 0 && width(p, b) > 0
            }
            func fitsWidth(_ p: Int) -> Bool {
                width(a, p) <= maxWidth && width(p, b) <= maxWidth * CGFloat(k - 1)
            }
            func inBand(_ p: Int) -> Bool {
                let w1 = width(a, p)
                let w2 = width(p, b)
                let fraction = w1 / max(1, w1 + w2)
                return abs(fraction - 1 / CGFloat(k)) <= 0.15
            }
            func best(_ positions: [Int]) -> Int? {
                positions.min { cost($0) < cost($1) }
            }
            var choice: Int? = nil
            for tier in tiers {
                if let p = best(tier.filter { valid($0) && fitsWidth($0) && inBand($0) }) {
                    choice = p
                    break
                }
            }
            if choice == nil {
                let all = tiers.flatMap { $0 }
                choice = best(all.filter { valid($0) && fitsWidth($0) }) ?? best(all.filter { valid($0) })
            }
            guard let p = choice else { return [] }
            return [p] + split(p, b, k - 1)
        }

        let balanced = make(split(0, count, maxLines))
        if balanced.fits || maxLines < 3 { return balanced }

        // --- 3 行でも収まらない: 収まる最も遠い候補で順に折り返す(単語が長すぎるときだけ文字単位)
        let candidateSet = Set(tiers.flatMap { $0 })
        var breaks: [Int] = []
        var lo = a0
        while width(lo, b0) > maxWidth, breaks.count < 12 {
            var chosen: Int? = nil
            for p in stride(from: b0 - 1, to: lo, by: -1)
                where candidateSet.contains(p) && width(lo, p) > 0 && width(lo, p) <= maxWidth {
                chosen = p
                break
            }
            if chosen == nil {
                for p in stride(from: b0 - 1, to: lo, by: -1)
                    where width(lo, p) > 0 && width(lo, p) <= maxWidth && isLegalBreak(chars, at: p) {
                    chosen = p
                    break
                }
            }
            if chosen == nil, lo + 1 < b0 { chosen = lo + 1 }
            guard let p = chosen else { break }
            breaks.append(p)
            lo = p
        }
        return make(breaks)
    }

    /// 各単語が text の何文字目から始まるか(見つからなければ直前の続き)
    private static func wordOffsets(_ words: [String], in text: String) -> [Int] {
        var result: [Int] = []
        var cursor = text.startIndex
        var fallback = 0
        for word in words {
            if !word.isEmpty, let range = text.range(of: word, range: cursor..<text.endIndex) {
                result.append(text.distance(from: text.startIndex, to: range.lowerBound))
                cursor = range.upperBound
                fallback = text.distance(from: text.startIndex, to: range.upperBound)
            } else {
                result.append(fallback)
                fallback += word.count
            }
        }
        return result
    }

    // MARK: - 改行とフォントサイズの決定

    private struct LayoutPlan {
        var fontSize: CGFloat
        var font: UIFont
        /// 単語ブロック以外の行のフォント
        var restFont: UIFont
        var blocks: [BrokenText]
    }

    /// 各ブロック(原文 / 訳文)を最大 2 行に。収まらなければ 80% まで縮小し、最後は 3 行目を使う
    private static func makePlan(lines: [String], baseFontSize: CGFloat, style: SubtitleStyle, useWords: Bool,
                                 allowedStarts: Set<Int>?, maxBoxWidth: CGFloat) -> LayoutPlan {
        func attempt(_ scale: CGFloat, maxLines: Int) -> LayoutPlan {
            let size = max(8, (baseFontSize * scale).rounded())
            let font = subtitleFont(for: style, size: size)
            let restFont = useWords ? subtitleFont(for: style, size: (size * 0.85).rounded()) : font
            let paddingX = (size * 0.5).rounded()
            let maxTextWidth = max(size, maxBoxWidth - paddingX * 2)
            var blocks: [BrokenText] = []
            for (index, line) in lines.enumerated() {
                let isWordBlock = useWords && index == 0
                blocks.append(breakText(line, font: isWordBlock ? font : restFont, maxWidth: maxTextWidth,
                                        maxLines: maxLines, allowedStarts: isWordBlock ? allowedStarts : nil))
            }
            return LayoutPlan(fontSize: size, font: font, restFont: restFont, blocks: blocks)
        }
        let scales: [CGFloat] = [1.0, 0.95, 0.9, 0.85, 0.8]
        for scale in scales {
            let plan = attempt(scale, maxLines: 2)
            if plan.blocks.allSatisfy({ $0.fits }) { return plan }
        }
        return attempt(0.8, maxLines: 3)
    }

    /// 単語を、決められた行(lineOfWord)に並べて各行を中央揃えにする
    private static func layoutWords(_ words: [String], lineOfWord: [Int], font: UIFont, hasSpaces: Bool)
        -> (boxes: [WordBox], size: CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let spaceWidth: CGFloat = hasSpaces
            ? ceil((" " as NSString).size(withAttributes: attrs).width)
            : (font.pointSize * 0.1).rounded()
        let lineHeight = ceil(font.lineHeight * 1.3)
        let lineCount = max(1, (lineOfWord.max() ?? 0) + 1)
        var lines: [[(text: String, width: CGFloat)]] = Array(repeating: [], count: lineCount)
        var lineWidths: [CGFloat] = Array(repeating: 0, count: lineCount)
        for (index, word) in words.enumerated() {
            let line = index < lineOfWord.count ? min(max(0, lineOfWord[index]), lineCount - 1) : lineCount - 1
            let width = ceil((word as NSString).size(withAttributes: attrs).width)
            lineWidths[line] = lines[line].isEmpty ? width : lineWidths[line] + spaceWidth + width
            lines[line].append((text: word, width: width))
        }
        let blockWidth = lineWidths.max() ?? 0
        var boxes: [WordBox] = []
        var row = 0
        for (lineIndex, line) in lines.enumerated() where !line.isEmpty {
            var x = ((blockWidth - lineWidths[lineIndex]) / 2).rounded()
            let y = CGFloat(row) * lineHeight
            for item in line {
                boxes.append(WordBox(text: item.text, rect: CGRect(x: x, y: y, width: item.width, height: lineHeight)))
                x += item.width + spaceWidth
            }
            row += 1
        }
        return (boxes, CGSize(width: ceil(blockWidth), height: lineHeight * CGFloat(max(row, 1))))
    }

    /// 通常描画する 1 行
    private struct TextLine {
        let text: String
        /// タイプライターで表示する文字数(nil = 全部)
        let visible: Int?
        let width: CGFloat
    }

    private static func render(lines: [String], state: DisplayState, style: SubtitleStyle, renderSize: CGSize) -> CIImage? {
        let canvasW = renderSize.width
        let canvasH = renderSize.height
        let template = style.template
        let ratio = min(max(style.sizeRatio, 0.01), 0.3)
        // 画面の短い辺を基準にする(横長の 4K で字幕が大きくなりすぎないように)
        let baseSide: CGFloat = min(canvasW, canvasH)
        var baseFontSize = max(8, (ratio * baseSide).rounded())
        if template == .outlineBig { baseFontSize = (baseFontSize * 1.25).rounded() }

        if let visible = state.visibleCharacters, visible <= 0 { return nil }

        // --- 改行とフォントサイズ(全テンプレート共通)
        let useWords = !state.words.isEmpty
        let wordStarts: [Int] = useWords ? wordOffsets(state.words, in: lines[0]) : []
        let allowedStarts: Set<Int>? = useWords ? Set(wordStarts.filter { $0 > 0 }) : nil
        let plan = makePlan(lines: lines, baseFontSize: baseFontSize, style: style, useWords: useWords,
                            allowedStarts: allowedStarts, maxBoxWidth: canvasW * 0.9)
        let fontSize = plan.fontSize
        let font = plan.font
        let restFont = plan.restFont

        let paddingX = (fontSize * 0.5).rounded()
        let paddingY = (fontSize * 0.3).rounded()
        let lineSpacing = fontSize * 0.12

        let textColor = style.color.uiColor
        let isDarkText = style.color == .black
        let outlineColor: UIColor = isDarkText ? .white : .black
        let highlight = UIColor(hex: style.highlightColorHex) ?? UIColor(red: 1, green: 0.84, blue: 0.29, alpha: 1)

        // 縁取りの太さ(背景ありなら無し。outlineBig は常に太く)
        // 縁取りは髪の毛ほどの細さにして、代わりに柔らかい影で読みやすくする
        var outlineWidth: CGFloat = style.hasBackground ? 0 : max(1, (fontSize * 0.03).rounded())
        if template == .outlineBig { outlineWidth = max(3, (fontSize * 0.14).rounded()) }

        // --- 計測: 単語ブロック(1 行目の字幕。行の割り当ては改行結果と同じ = 文字位置で判定)
        var wordBlock: (boxes: [WordBox], size: CGSize) = ([], .zero)
        if useWords {
            let starts = plan.blocks.first?.starts ?? [0]
            let lineOfWord: [Int] = wordStarts.map { offset in
                var line = 0
                for (index, start) in starts.enumerated() where start <= offset {
                    line = index
                }
                return line
            }
            wordBlock = layoutWords(state.words, lineOfWord: lineOfWord, font: font, hasSpaces: state.hasSpaces)
        }

        // --- 計測: 通常描画の行
        let restAttributes: [NSAttributedString.Key: Any] = [.font: restFont, .foregroundColor: textColor]
        var textLines: [TextLine] = []
        for (blockIndex, block) in plan.blocks.enumerated() {
            if useWords && blockIndex == 0 { continue }
            for (lineIndex, text) in block.lines.enumerated() {
                var visible: Int? = nil
                if blockIndex == 0, let total = state.visibleCharacters {
                    let start = lineIndex < block.starts.count ? block.starts[lineIndex] : 0
                    visible = min(text.count, max(0, total - start))
                }
                let width = ceil((text as NSString).size(withAttributes: restAttributes).width)
                textLines.append(TextLine(text: text, visible: visible, width: width))
            }
        }
        let restLineHeight = ceil(restFont.lineHeight)
        let restHeight: CGFloat = textLines.isEmpty
            ? 0
            : ceil(restLineHeight * CGFloat(textLines.count) + lineSpacing * CGFloat(textLines.count - 1))
        let restWidth = textLines.map { $0.width }.max() ?? 0

        let gap: CGFloat = (useWords && !textLines.isEmpty) ? (fontSize * 0.25).rounded() : 0
        let textWidth = ceil(max(wordBlock.size.width, restWidth))
        let textHeight = wordBlock.size.height + gap + restHeight
        guard textWidth > 0, textHeight > 0 else { return nil }

        // 箱・帯が単語からはみ出す分
        let boxPadX = (fontSize * 0.22).rounded()
        let boxPadY = (fontSize * 0.12).rounded()
        let extra: CGFloat = useWords ? max(outlineWidth, boxPadX + 2, boxPadY + 2) : outlineWidth

        let imageWidth = ceil(textWidth + paddingX * 2 + extra * 2)
        let imageHeight = ceil(textHeight + paddingY * 2 + extra * 2)
        let imageSize = CGSize(width: imageWidth, height: imageHeight)
        let textRect = CGRect(x: paddingX + extra, y: paddingY + extra, width: textWidth, height: textHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)

        let uiImage = renderer.image { context in
            let cg = context.cgContext
            if !style.hasBackground && template != .outlineBig {
                let shadowColor: UIColor = isDarkText ? UIColor.white.withAlphaComponent(0.6) : UIColor.black.withAlphaComponent(0.75)
                let shadowOffset = CGSize(width: 0, height: fontSize * 0.04)
                let shadowBlur: CGFloat = fontSize * 0.18
                cg.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor.cgColor)
            }
            if style.hasBackground {
                let bgColor: UIColor = isDarkText
                    ? UIColor(white: 1.0, alpha: 0.7)
                    : UIColor(white: 0.0, alpha: 0.55)
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize),
                                        cornerRadius: fontSize * 0.3)
                bgColor.setFill()
                path.fill()
            }

            // --- 単語ブロック(1 行目の字幕)
            if useWords {
                let blockOriginX = textRect.minX + ((textWidth - wordBlock.size.width) / 2).rounded()
                let blockOriginY = textRect.minY
                let glyphHeight = font.lineHeight
                for (index, box) in wordBlock.boxes.enumerated() {
                    let rect = box.rect.offsetBy(dx: blockOriginX, dy: blockOriginY)
                    let origin = CGPoint(x: rect.minX, y: rect.minY + ((rect.height - glyphHeight) / 2).rounded())
                    var fillColor = textColor
                    var drawOutline = outlineWidth > 0

                    switch state.mode {
                    case .none:
                        break
                    case .karaoke(let highlighted):
                        if index < highlighted { fillColor = highlight }
                    case .boxPop(let current, let pop):
                        if index == current {
                            let scale: CGFloat = pop == 2 ? 1.12 : (pop == 1 ? 1.05 : 1.0)
                            let glyphRect = CGRect(x: rect.minX, y: origin.y, width: rect.width, height: glyphHeight)
                            var boxRect = glyphRect.insetBy(dx: -boxPadX, dy: -boxPadY)
                            if scale != 1 {
                                let cx = boxRect.midX
                                let cy = boxRect.midY
                                boxRect = CGRect(x: cx - boxRect.width * scale / 2, y: cy - boxRect.height * scale / 2,
                                                 width: boxRect.width * scale, height: boxRect.height * scale)
                            }
                            let path = UIBezierPath(roundedRect: boxRect, cornerRadius: fontSize * 0.18)
                            highlight.setFill()
                            path.fill()
                            fillColor = UIColor(white: 0.08, alpha: 1)
                            drawOutline = false
                            if scale != 1 {
                                cg.saveGState()
                                cg.translateBy(x: glyphRect.midX, y: glyphRect.midY)
                                cg.scaleBy(x: scale, y: scale)
                                cg.translateBy(x: -glyphRect.midX, y: -glyphRect.midY)
                                NSAttributedString(string: box.text, attributes: [.font: font, .foregroundColor: fillColor])
                                    .draw(at: origin)
                                cg.restoreGState()
                                continue
                            }
                        }
                    case .pill(let current):
                        if index == current {
                            let glyphRect = CGRect(x: rect.minX, y: origin.y, width: rect.width, height: glyphHeight)
                            let pillRect = glyphRect.insetBy(dx: -boxPadX, dy: -boxPadY * 0.6)
                            let path = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
                            highlight.withAlphaComponent(0.95).setFill()
                            path.fill()
                            fillColor = .white
                            drawOutline = false
                        }
                    }

                    if drawOutline {
                        let strokeAttrs = outlineAttributes(font: font, color: outlineColor,
                                                            outlineWidth: outlineWidth, paragraph: nil)
                        NSAttributedString(string: box.text, attributes: strokeAttrs).draw(at: origin)
                    }
                    NSAttributedString(string: box.text, attributes: [.font: font, .foregroundColor: fillColor])
                        .draw(at: origin)
                }
            }

            // --- 通常描画の行(1 行ずつ中央揃え。タイプライターは完成形の位置に左から表示)
            if !textLines.isEmpty {
                let strokeAttrs = outlineAttributes(font: restFont, color: outlineColor,
                                                    outlineWidth: outlineWidth, paragraph: nil)
                var y = textRect.minY + wordBlock.size.height + gap
                for line in textLines {
                    let x = textRect.minX + ((textWidth - line.width) / 2).rounded()
                    let shown: String
                    if let visible = line.visible {
                        shown = String(line.text.prefix(visible))
                    } else {
                        shown = line.text
                    }
                    if !shown.isEmpty {
                        let origin = CGPoint(x: x, y: y.rounded())
                        if outlineWidth > 0 {
                            NSAttributedString(string: shown, attributes: strokeAttrs).draw(at: origin)
                        }
                        NSAttributedString(string: shown, attributes: restAttributes).draw(at: origin)
                    }
                    y += restLineHeight + lineSpacing
                }
            }
        }

        guard let cgImage = uiImage.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        // 配置(CoreImage 座標: 原点は左下)
        let margin = (canvasH * 0.07).rounded()
        let x = ((canvasW - imageWidth) / 2).rounded()
        let y: CGFloat
        switch style.position {
        case .top:
            y = canvasH - margin - imageHeight
        case .center:
            y = ((canvasH - imageHeight) / 2).rounded()
        case .bottom:
            y = margin
        }
        return ciImage.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
