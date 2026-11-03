import Foundation

// =====================================================================
// おまかせ編集の「オーダー」: 「30秒のショートに。言い直しはカット」のような文章を AutoEditSettings にする。
//   1. 言葉の手がかり(長さ・スタイル・タイトル・切る / 残すもの)をこの端末だけで読む(いつでも使える)
//   2. Apple Intelligence が使える端末では、端末内 AI にも JSON で読ませて上書きする(ポイントは使わない)
// 読み取れなかった項目は今の設定のまま。読み取った内容は summary で見せる
// =====================================================================

enum AutoEditOrder {

    struct Result {
        var settings: AutoEditSettings
        /// 読み取った内容の短い言葉(「ショート」「30 秒」など)
        var summary: [String]
    }

    /// 入力欄に入れ替わりで見せる入力例
    static var examples: [String] {
        [
            String(localized: "旅行の動画を1分のVlogに。BGMのビートに合わせてテンポよく"),
            String(localized: "30秒のショートに。笑顔の場面を中心に、「えー」などの間はカット"),
            String(localized: "子どもの運動会を3分の家族の記録に。タイトルは「はじめての運動会」"),
            String(localized: "商品レビューを解説動画に。言い直しは最後だけ残して"),
            String(localized: "10分のドキュメンタリー風に。色味はそのままで"),
        ]
    }

    static func interpret(_ text: String, current: AutoEditSettings) async -> Result {
        let order = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !order.isEmpty else { return Result(settings: current, summary: []) }
        var settings = current
        var touched = Touched()
        applyKeywords(order, to: &settings, touched: &touched)
        if SubtitlePolisher.isOnDeviceAvailable, !Task.isCancelled {
            if let raw = try? await ScriptWriter.generate(engine: .onDevice, instructions: instructions,
                                                         prompt: order, apiKey: "", temperature: 0.1) {
                applyAIResponse(raw, to: &settings, touched: &touched)
            }
        }
        return Result(settings: settings, summary: summary(settings, touched: touched))
    }

    // MARK: - 読み取った項目

    private struct Touched {
        var style = false
        var duration = false
        var title = false
        var faces = false
        var speech = false
        var cutSilence = false
        var cutRetakes = false
        var cutLookups = false
        var transitions = false
        var look = false
        var beats = false
    }

    private static func summary(_ s: AutoEditSettings, touched t: Touched) -> [String] {
        var items: [String] = []
        if t.style { items.append(s.style.displayName) }
        if t.duration {
            items.append(s.targetDuration <= 0 ? String(localized: "全部使う") : durationText(s.targetDuration))
        }
        if t.title, s.addTitleCard {
            items.append(s.titleText.isEmpty ? String(localized: "タイトルあり") : String(localized: "タイトル「\(s.titleText)」"))
        }
        if t.faces, s.preferFaces { items.append(String(localized: "顔が映っている場面を優先")) }
        if t.speech, s.preferSpeech { items.append(String(localized: "話している場面を優先")) }
        if t.cutSilence, s.cutNonSpeech { items.append(String(localized: "話していない所を切る")) }
        if t.cutRetakes, s.cutRetakes { items.append(String(localized: "言い直しは最後だけ残す")) }
        if t.cutLookups, s.cutLookups { items.append(String(localized: "調べ物の場面を切る")) }
        if t.transitions { items.append(s.addTransitions ? String(localized: "トランジションを入れる") : String(localized: "トランジションなし")) }
        if t.look { items.append(s.applyLook ? String(localized: "スタイルに合った色味にする") : String(localized: "色味はそのまま")) }
        if t.beats, s.useBGMBeats { items.append(String(localized: "BGM のビートに合わせて切り替える")) }
        return items
    }

    static func durationText(_ seconds: Double) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return String(localized: "\(Int(seconds / 60)) 分")
        }
        if seconds >= 60 {
            return String(localized: "\(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒")
        }
        return String(localized: "\(Int(seconds.rounded())) 秒")
    }

    // MARK: - 言葉の手がかり

    private static func contains(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
    }

    private static func applyKeywords(_ raw: String, to s: inout AutoEditSettings, touched t: inout Touched) {
        // 全角の英数字は半角に、半角カナは全角にそろえる(「」やカタカナはそのまま)
        let text = raw.precomposedStringWithCompatibilityMapping

        // スタイル(先に書いてあるものより、はっきりした言葉を優先)
        let styles: [(AutoEditStyle, [String])] = [
            (.short, ["ショート", "short", "tiktok", "リール", "reel", "縦動画"]),
            (.vlog, ["vlog", "ブイログ", "旅行", "旅", "trip", "travel"]),
            (.documentary, ["ドキュメンタリー", "documentary", "映画", "シネマ", "cinematic"]),
            (.family, ["家族", "子ども", "子供", "赤ちゃん", "運動会", "family", "kids"]),
            (.howto, ["解説", "紹介", "レビュー", "ハウツー", "手順", "how to", "howto", "tutorial", "review"]),
        ]
        for (style, words) in styles where contains(text, words) {
            s.style = style
            t.style = true
            break
        }

        // 長さ: 「1分30秒」「3分半」「90秒」「2 min」。「全部」「フル」は全部使う
        if contains(text, ["全部使", "全部つか", "フル尺", "ノーカット", "full length"]) {
            s.targetDuration = 0
            t.duration = true
        } else if let seconds = parseDuration(text) {
            s.targetDuration = min(max(seconds, 5), 3600)
            t.duration = true
        }

        // タイトル: 「タイトルは「…」」「タイトル『…』」
        if let title = quotedTitle(text) {
            s.addTitleCard = true
            s.titleText = title
            t.title = true
        } else if contains(text, ["タイトルなし", "タイトルはいらない", "タイトル不要", "no title"]) {
            s.addTitleCard = false
            t.title = true
        } else if contains(text, ["タイトル", "title"]) {
            s.addTitleCard = true
            t.title = true
        }

        if contains(text, ["顔", "笑顔", "笑って", "表情", "face", "smile"]) {
            s.preferFaces = true
            t.faces = true
        }
        if contains(text, ["話して", "しゃべ", "トーク", "talk", "speech"]) {
            s.preferSpeech = true
            t.speech = true
        }
        if contains(text, ["えー", "あのー", "間はカット", "間をカット", "無言", "沈黙", "間を詰", "silence", "filler"]) {
            s.cutNonSpeech = true
            t.cutSilence = true
        }
        if contains(text, ["言い直し", "撮り直し", "噛んだ", "retake"]) {
            s.cutRetakes = true
            t.cutRetakes = true
        }
        if contains(text, ["調べ物", "調べて", "手元"]) {
            s.cutLookups = true
            t.cutLookups = true
        }
        if contains(text, ["トランジションなし", "トランジションはいらない", "トランジション不要", "切り替え効果なし", "no transition"]) {
            s.addTransitions = false
            t.transitions = true
        } else if contains(text, ["トランジション", "transition"]) {
            s.addTransitions = true
            t.transitions = true
        }
        if contains(text, ["色味はそのまま", "色はそのまま", "色味そのまま", "色は変えない", "色味は変えない", "no color", "keep color"]) {
            s.applyLook = false
            t.look = true
        } else if contains(text, ["色味", "エモ", "フィルム", "シネマ", "color", "look"]) {
            s.applyLook = true
            t.look = true
        }
        if contains(text, ["ビート", "リズム", "テンポよく", "テンポ良く", "beat", "rhythm"]) {
            s.useBGMBeats = true
            t.beats = true
        }
    }

    /// 文章の中の長さ(秒)。「2秒以上の無言」のような条件の秒は長さとみなさない
    static func parseDuration(_ text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(分半|分|min|minutes?|m(?![a-z])|秒|sec|seconds?|s(?![a-z]))(?:\s*(\d+)\s*(秒|sec|s(?![a-z])))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let conditions = ["以上", "以内", "未満", "以下", "前後", "ごと", "おき", "くらいの間", "の間", "or more", "or less"]
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.first(where: { match in
            let after = ns.substring(from: match.range.location + match.range.length)
                .trimmingCharacters(in: .whitespaces)
            return !conditions.contains(where: { after.hasPrefix($0) })
        }), let value = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        var seconds: Double
        switch unit {
        case "分半": seconds = value * 60 + 30
        case "分", "min", "minute", "minutes", "m": seconds = value * 60
        default: seconds = value
        }
        if m.range(at: 3).location != NSNotFound, let extra = Double(ns.substring(with: m.range(at: 3))) {
            seconds += extra
        }
        return seconds > 0 ? seconds : nil
    }

    private static func quotedTitle(_ text: String) -> String? {
        guard let range = text.range(of: "タイトル") ?? text.range(of: "title", options: .caseInsensitive) else { return nil }
        let after = text[range.upperBound...]
        let pairs: [(Character, Character)] = [("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”")]
        for (open, close) in pairs {
            guard let start = after.firstIndex(of: open) else { continue }
            // タイトルの言葉のすぐ後ろ(10 文字以内)の括弧だけ
            guard after.distance(from: after.startIndex, to: start) <= 10 else { continue }
            let rest = after[after.index(after: start)...]
            guard let end = rest.firstIndex(of: close) else { continue }
            let title = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return String(title.prefix(60)) }
        }
        return nil
    }

    // MARK: - 端末内 AI

    private static let instructions = """
    You turn a video-editing request into settings for an automatic editor. \
    Reply with one JSON object only, no other text. Keys (use null when the request does not say):
    "style": one of "documentary", "vlog", "short", "family", "howto";
    "seconds": target length in seconds (0 = use all footage);
    "title": opening title text, or "" for no title;
    "faces": prefer scenes with faces (true/false);
    "speech": prefer scenes with talking (true/false);
    "cutSilence": cut silent gaps and filler words like "um" (true/false);
    "cutRetakes": keep only the last take of repeated lines (true/false);
    "cutLookups": cut silent scenes of looking things up (true/false);
    "transitions": add transitions (true/false);
    "look": apply a color look for the style (true/false);
    "beats": cut on the music beat (true/false).
    The request may be in any language.
    """

    private static func applyAIResponse(_ raw: String, to s: inout AutoEditSettings, touched t: inout Touched) {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let style = (json["style"] as? String).flatMap({ AutoEditStyle(rawValue: $0.lowercased()) }) {
            s.style = style
            t.style = true
        }
        // AI は頼まれていない項目にも false や 0 を返すことがあるので、はっきりした指定(正の秒・空でないタイトル・true)だけ使う。
        // 「全部使う」「〜しない」は言葉の手がかりの方で読む
        if let seconds = ScriptWriter.seconds(from: json["seconds"]), seconds > 0, !t.duration {
            s.targetDuration = min(max(seconds, 5), 3600)
            t.duration = true
        }
        if let title = json["title"] as? String, !t.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                s.addTitleCard = true
                s.titleText = String(trimmed.prefix(60))
                t.title = true
            }
        }
        func flag(_ key: String, _ apply: (Bool) -> Void) {
            if let value = json[key] as? Bool, value { apply(value) }
        }
        flag("faces") { s.preferFaces = $0; t.faces = true }
        flag("speech") { s.preferSpeech = $0; t.speech = true }
        flag("cutSilence") { s.cutNonSpeech = $0; t.cutSilence = true }
        flag("cutRetakes") { s.cutRetakes = $0; t.cutRetakes = true }
        flag("cutLookups") { s.cutLookups = $0; t.cutLookups = true }
        flag("transitions") { s.addTransitions = $0; t.transitions = true }
        flag("look") { s.applyLook = $0; t.look = true }
        flag("beats") { s.useBGMBeats = $0; t.beats = true }
    }
}
