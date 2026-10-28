import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// =====================================================================
// AI 台本(ナレーション原稿)と構成案(チャプター)。
//
// エンジン:
//   - iOS 26 以降で Apple Intelligence が使える端末: FoundationModels(LanguageModelSession)
//   - それ以外でサインイン済み(ポイント)か OpenAI API キーがあるとき: Chat Completions(gpt-4o-mini)
//   - どちらも無ければ ScriptWriterError.noEngine
//   台本・構成案はユーザーが押して始める機能なので SubtitlePolisher.resolveExplicitEngine で決める:
//   設定の「AI 仕上げ」が「クラウド」なら認証がある限りクラウドを優先し、「使わない」「自動」「端末内」でも
//   (自動の仕上げを止める設定なので)Apple Intelligence があればそれ、無ければポイントか API キーでクラウドを使う。
//   resolveEngine(自動の仕上げと同じ判定)は PacingAnalyzer のように利用料を知らせずに走る処理が使う。
// 応答は JSON を要求するが、前後の説明文やコードフェンス、プレーンテキストの箇条書きでも
// できるだけ読み取る。
// =====================================================================

enum ScriptWriterError: LocalizedError {
    /// 使える AI が無い(Apple Intelligence が使えず、サインインも API キーも無い)
    case noEngine
    case emptyTopic
    case noSubtitles
    case invalidResponse
    /// ポイント(サーバー)のログインの期限が切れた(サインアウト済み)
    case sessionExpired
    /// ポイント不足(402)
    case insufficientPoints
    /// 自分の OpenAI キーが正しくない(自分のキーで送ったときだけ)
    case invalidAPIKey
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEngine:
            return CloudAIGateway.noEngineMessage
        case .emptyTopic:
            return String(localized: "台本のテーマを入力してください")
        case .noSubtitles:
            return String(localized: "キャプションがありません。先に文字起こしをしてください")
        case .invalidResponse:
            return String(localized: "AI の応答を読み取れませんでした。もう一度お試しください")
        case .sessionExpired:
            return CloudAIGateway.sessionExpiredMessage
        case .insufficientPoints:
            return CloudAIGateway.insufficientPointsMessage
        case .invalidAPIKey:
            return CloudAIGateway.invalidAPIKeyMessage
        case .requestFailed(let detail):
            return detail
        }
    }
}

/// OpenAI の moderation が止めた内容(自分のキーで送る経路。CloudAIGateway.recovery は .none)
enum CloudAIModerationError: LocalizedError {
    case blocked

    var errorDescription: String? {
        String(localized: "この内容は生成できません")
    }
}

/// 自分の OpenAI キーで送る前の確認(/v1/moderations、omni-moderation-latest)。
/// 台本・構成案(ScriptWriter.chatCompletion)とクラウドの声(CloudTextToSpeech.render)が使う。
/// flagged なら CloudAIModerationError.blocked。通信や応答の失敗は通す
enum OpenAIModeration {
    private static let endpoint = URL(string: "https://api.openai.com/v1/moderations")!

    static func check(_ text: String, apiKey: String) async throws {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let payload: [String: Any] = [
            "model": "omni-moderation-latest",
            "input": String(input.prefix(20000)),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let data: Data
        do {
            let (received, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return }
            data = received
        } catch {
            if error is CancellationError { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            return
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let flagged = results.first?["flagged"] as? Bool else { return }
        if flagged { throw CloudAIModerationError.blocked }
    }
}

enum ScriptWriter {
    static let cloudModel = "gpt-4o-mini"
    static var cloudEndpoint: URL { CloudAIGateway.chatURL }

    // MARK: - エンジン

    /// 利用料を知らせずに走る処理(PacingAnalyzer の AI 採点など)のエンジン。自動の仕上げと同じく、
    /// クラウドを使うのは「クラウド」を選んだときだけ(そのときは認証がある限りクラウドを優先する)
    static func resolveEngine(settings: AppSettings) -> SubtitlePolisher.ResolvedEngine {
        let onDevice = SubtitlePolisher.isOnDeviceAvailable
        let cloud = settings.hasCloudCredential
        switch settings.polishEngine {
        case .cloud:
            if cloud { return .cloud }
            return onDevice ? .onDevice : .none
        case .onDevice, .auto, .none:
            return onDevice ? .onDevice : .none
        }
    }

    /// 利用者が押して始める台本・構成案のエンジン(「使わない」でも Apple Intelligence か、ポイント / API キーのクラウドを使う)
    static func resolveExplicitEngine(settings: AppSettings) -> SubtitlePolisher.ResolvedEngine {
        SubtitlePolisher.resolveExplicitEngine(settings: settings)
    }

    static func isAvailable(settings: AppSettings) -> Bool {
        resolveExplicitEngine(settings: settings) != .none
    }

    /// 表示用のエンジン名("Apple Intelligence" / "OpenAI" / "なし")
    static func engineDisplayName(settings: AppSettings) -> String {
        SubtitlePolisher.displayName(of: resolveExplicitEngine(settings: settings))
    }

    // MARK: - 台本

    static func write(topic: String, durationSeconds: Double, tone: ScriptTone, subtitles: [SubtitleCue],
                      markers: [TimelineMarker], settings: AppSettings) async throws -> [ScriptLine] {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { throw ScriptWriterError.emptyTopic }
        let engine = resolveExplicitEngine(settings: settings)
        guard engine != .none else { throw ScriptWriterError.noEngine }

        let safeDuration: Double = durationSeconds.isFinite ? durationSeconds : 60
        let duration = max(10, min(3600, safeDuration))
        let lineCount = max(3, min(40, Int((duration / 6).rounded())))
        let contextLimit = (engine == .onDevice) ? 1200 : 6000

        let instructions = writeInstructions(tone: tone)
        let prompt = writePrompt(topic: trimmedTopic, duration: duration, lineCount: lineCount,
                                 subtitles: subtitles, markers: markers, limit: contextLimit)
        let raw = try await generate(engine: engine, instructions: instructions, prompt: prompt,
                                     apiKey: settings.cloudCredential, temperature: 0.7)
        try Task.checkCancellation()
        // 空(不適切なテーマで AI が断ったときも)は空のまま返す。画面が「作れませんでした」を出す
        return parseLines(raw, duration: duration)
    }

    private static func toneDescription(_ tone: ScriptTone) -> String {
        switch tone {
        case .calm: return "落ち着いて、ゆっくり語りかける(です・ます調)"
        case .friendly: return "親しみやすく、くだけすぎない話し言葉"
        case .energetic: return "元気でテンポよく、短い文を重ねる"
        case .formal: return "丁寧でフォーマル(です・ます調、敬語)"
        }
    }

    private static func writeInstructions(tone: ScriptTone) -> String {
        """
        あなたは日本語の動画ナレーション台本の作家です。視聴者に読み上げて聞かせる原稿を書きます。
        ルール:
        - 口調: \(toneDescription(tone))
        - 1 行は読み上げて 4〜7 秒程度(全角 15〜40 文字)。1 行に 1 つの内容
        - 行ごとに「読み始める時刻(秒)」を付ける。時刻は 0 から動画の長さの範囲で昇順
        - 参考として渡された会話(字幕)やチャプターがあれば、その内容と時刻に沿わせる。無い情報は想像で補ってよいが、固有名詞や数字は作らない
        - 記号・絵文字・箇条書き記号は使わない
        - 差別・性的・暴力的な内容、実在の人物への中傷は書かない。頼まれたら {"lines":[]} を返す
        - 出力は JSON オブジェクトのみ。形式: {"lines":[{"time":秒(数値),"text":"ナレーション"}, ...]}
        """
    }

    private static func writePrompt(topic: String, duration: Double, lineCount: Int,
                                    subtitles: [SubtitleCue], markers: [TimelineMarker], limit: Int) -> String {
        var lines: [String] = []
        lines.append("テーマ: \(topic)")
        lines.append("動画の長さ: \(Int(duration.rounded())) 秒")
        lines.append("行数: \(lineCount) 行前後")
        let chapters = markers.filter { $0.kind == .chapter }.sorted { $0.time < $1.time }
        if !chapters.isEmpty {
            lines.append("")
            lines.append("チャプター:")
            for marker in chapters.prefix(20) {
                let name = marker.name.isEmpty ? "チャプター" : marker.name
                lines.append("[\(timestamp(marker.time))] \(name)")
            }
        }
        let context = subtitleContext(subtitles, limit: limit)
        if !context.isEmpty {
            lines.append("")
            lines.append("参考: 動画内の会話(字幕)")
            lines.append(context)
        }
        lines.append("")
        lines.append("この動画のナレーション台本を JSON で出力してください。")
        return lines.joined(separator: "\n")
    }

    /// 字幕を「[m:ss] 本文」の行にまとめる(limit 文字を超えないよう等間隔に間引く)
    private static func subtitleContext(_ subtitles: [SubtitleCue], limit: Int) -> String {
        let cues = subtitles
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !cues.isEmpty else { return "" }
        var selected = cues
        var text = joinedContext(selected)
        var step = 1
        while text.count > limit && step < 64 {
            step *= 2
            selected = []
            var i = 0
            while i < cues.count {
                selected.append(cues[i])
                i += step
            }
            text = joinedContext(selected)
        }
        if text.count > limit {
            text = String(text.prefix(limit))
        }
        return text
    }

    private static func joinedContext(_ cues: [SubtitleCue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let flat = cue.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("[\(timestamp(cue.start))] \(flat)")
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - 構成案(チャプター)

    static func outline(from subtitles: [SubtitleCue], settings: AppSettings) async throws -> [TimelineMarker] {
        let cues = subtitles
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !cues.isEmpty else { throw ScriptWriterError.noSubtitles }
        let engine = resolveExplicitEngine(settings: settings)
        guard engine != .none else { throw ScriptWriterError.noEngine }

        let limit = (engine == .onDevice) ? 2500 : 12000
        let instructions = """
        あなたは動画編集者です。字幕(「[m:ss] 本文」の行)から、動画のチャプター(章)を 3〜8 個提案します。
        - 各チャプターは、話題が切り替わる字幕の開始時刻(秒)と、12 文字以内の日本語タイトル
        - 最初のチャプターは動画の冒頭(最初の字幕)から始める
        - 差別・性的・暴力的な内容、実在の人物への中傷は書かない。頼まれたら {"chapters":[]} を返す
        - 出力は JSON オブジェクトのみ。形式: {"chapters":[{"time":秒(数値),"title":"タイトル"}, ...]}
        """
        var prompt = "次の字幕からチャプターを提案してください。\n\n"
        var body = joinedContextWithSeconds(cues)
        if body.count > limit {
            body = subtitleContextWithSeconds(cues, limit: limit)
        }
        prompt += body
        let raw = try await generate(engine: engine, instructions: instructions, prompt: prompt,
                                     apiKey: settings.cloudCredential, temperature: 0.3)
        try Task.checkCancellation()

        // 空(不適切な内容で AI が断ったときも)は空のまま返す。画面が「作れませんでした」を出す
        let chapters = parseChapters(raw)
        guard !chapters.isEmpty else { return [] }

        let starts = cues.map { $0.start }
        var markers: [TimelineMarker] = []
        for chapter in chapters.sorted(by: { $0.time < $1.time }) {
            let snapped = nearest(to: chapter.time, in: starts)
            if let last = markers.last, snapped - last.time < 5 { continue }
            let title = chapter.title.isEmpty ? "チャプター" : chapter.title
            markers.append(TimelineMarker(time: snapped, name: title, kind: .chapter))
        }
        return markers
    }

    private static func joinedContextWithSeconds(_ cues: [SubtitleCue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let flat = cue.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("[\(String(format: "%.1f", cue.start))] \(flat)")
        }
        return lines.joined(separator: "\n")
    }

    private static func subtitleContextWithSeconds(_ cues: [SubtitleCue], limit: Int) -> String {
        var step = 1
        var text = joinedContextWithSeconds(cues)
        while text.count > limit && step < 64 {
            step *= 2
            var selected: [SubtitleCue] = []
            var i = 0
            while i < cues.count {
                selected.append(cues[i])
                i += step
            }
            text = joinedContextWithSeconds(selected)
        }
        if text.count > limit {
            text = String(text.prefix(limit))
        }
        return text
    }

    private static func nearest(to time: Double, in values: [Double]) -> Double {
        guard let first = values.first else { return max(0, time) }
        var best = first
        var bestDistance = abs(first - time)
        for v in values {
            let d = abs(v - time)
            if d < bestDistance {
                bestDistance = d
                best = v
            }
        }
        return max(0, best)
    }

    // MARK: - 生成

    static func generate(engine: SubtitlePolisher.ResolvedEngine, instructions: String, prompt: String,
                                 apiKey: String, temperature: Double) async throws -> String {
        switch engine {
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
                    return response.content
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ScriptWriterError.requestFailed(String(localized: "端末内 AI でエラーが起きました: \(error.localizedDescription)"))
                }
            }
            #endif
            throw ScriptWriterError.noEngine
        case .cloud:
            return try await chatCompletion(instructions: instructions, prompt: prompt, apiKey: apiKey, temperature: temperature)
        case .none:
            throw ScriptWriterError.noEngine
        }
    }

    private static func chatCompletion(instructions: String, prompt: String, apiKey: String, temperature: Double) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ScriptWriterError.noEngine }
        let payload: [String: Any] = [
            "model": cloudModel,
            "temperature": temperature,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw ScriptWriterError.requestFailed(String(localized: "リクエストを作成できませんでした"))
        }
        // どちらに送ったか(エラーの見せ方を決める。送っている間に設定が変わっても、送った宛先で判断する)
        let viaServer = CloudAIGateway.usesPoints
        // 自分のキーで OpenAI に直接送るときは、先に moderation で確かめる(ポイントの経路はサーバーが確かめる)
        if !viaServer {
            try await OpenAIModeration.check(prompt, apiKey: key)
        }
        var request = URLRequest(url: cloudEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            if error is CancellationError { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw ScriptWriterError.requestFailed(String(localized: "通信エラー: \(error.localizedDescription)"))
        }
        let data = result.0
        let response = result.1
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            switch status {
            case 401 where viaServer:
                // ポイント(サーバー)のログインの期限切れ。送ったトークンが今のものならサインアウトする
                await MainActor.run { AccountService.shared.handleSessionExpired(sentToken: key) }
                throw ScriptWriterError.sessionExpired
            case 401: throw ScriptWriterError.invalidAPIKey
            case 402: throw ScriptWriterError.insufficientPoints
            case 429: throw ScriptWriterError.requestFailed(String(localized: "OpenAI の利用上限に達しました"))
            default:
                let summary = viaServer ? String(localized: "サーバーがエラーを返しました(\(status))")
                                        : String(localized: "OpenAI がエラーを返しました(\(status))")
                let detail = CloudAIErrorBody(data: data).displayMessage
                throw ScriptWriterError.requestFailed(detail.isEmpty ? summary : summary + ": " + detail)
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ScriptWriterError.invalidResponse
        }
        return content
    }

    // MARK: - 応答の解析

    /// {"lines":[{"time":12,"text":"..."}]} のほか、配列やプレーンテキストの箇条書きも受け付ける
    static func parseLines(_ raw: String, duration: Double) -> [ScriptLine] {
        var lines: [ScriptLine] = []
        if let object = SubtitlePolisher.extractJSON(raw) {
            var array: [Any]? = object as? [Any]
            if array == nil, let dict = object as? [String: Any] {
                for key in ["lines", "script", "items", "narration", "data", "output"] {
                    if let candidate = dict[key] as? [Any] {
                        array = candidate
                        break
                    }
                }
                if array == nil {
                    array = dict.values.first(where: { $0 is [Any] }) as? [Any]
                }
            }
            if let items = array {
                for item in items {
                    if let d = item as? [String: Any] {
                        var text = stringValue(d["text"]) ?? stringValue(d["line"]) ?? stringValue(d["narration"])
                            ?? stringValue(d["content"])
                        if text == nil, let t = d["t"] as? String { text = t }
                        var time = seconds(from: d["time"]) ?? seconds(from: d["start"]) ?? seconds(from: d["at"])
                            ?? seconds(from: d["sec"]) ?? seconds(from: d["seconds"])
                        if time == nil, !(d["t"] is String) { time = seconds(from: d["t"]) }
                        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { continue }
                        lines.append(ScriptLine(time: time ?? -1, text: body))
                    } else if let s = item as? String {
                        let parsed = splitLeadingTime(s)
                        if !parsed.text.isEmpty {
                            lines.append(ScriptLine(time: parsed.time ?? -1, text: parsed.text))
                        }
                    }
                }
            }
        }
        if lines.isEmpty {
            lines = parsePlainText(raw)
        }
        return normalized(lines, duration: duration)
    }

    private static func parsePlainText(_ raw: String) -> [ScriptLine] {
        var result: [ScriptLine] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```"), !line.hasPrefix("{"), !line.hasPrefix("}") else { continue }
            for bullet in ["- ", "・", "• ", "* "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            }
            let parsed = splitLeadingTime(line)
            guard parsed.text.count >= 2 else { continue }
            result.append(ScriptLine(time: parsed.time ?? -1, text: parsed.text))
        }
        return result
    }

    /// 行頭の「[0:12]」「(12秒)」「12s:」「0:12 」などの時刻を切り出す
    private static func splitLeadingTime(_ line: String) -> (time: Double?, text: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let firstScalar = trimmed.unicodeScalars.first else { return (nil, "") }
        let openers: Set<Character> = ["[", "(", "（", "【"]
        let closers: Set<Character> = ["]", ")", "）", "】"]
        var token = ""
        var rest = trimmed
        if openers.contains(Character(firstScalar)) {
            // 括弧で囲まれた先頭トークン
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex, !closers.contains(trimmed[index]) {
                token.append(trimmed[index])
                index = trimmed.index(after: index)
            }
            if index < trimmed.endIndex {
                rest = String(trimmed[trimmed.index(after: index)...])
            } else {
                return (nil, trimmed)
            }
        } else {
            // 空白か「:」(時刻の後の区切り)までを先頭トークンとする
            if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "　" }) {
                token = String(trimmed[..<space])
                rest = String(trimmed[trimmed.index(after: space)...])
            } else {
                return (nil, trimmed)
            }
        }
        if let time = seconds(from: token) {
            var text = rest.trimmingCharacters(in: .whitespaces)
            for separator in [":", "：", "-", "—", "–"] where text.hasPrefix(separator) {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return (time, text)
        }
        return (nil, trimmed)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        return nil
    }

    /// 12 / 12.5 / "12" / "0:12" / "01:02.5" / "12s" / "12秒" → 秒
    static func seconds(from value: Any?) -> Double? {
        if let d = value as? Double, d.isFinite { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        guard var s = value as? String else { return nil }
        s = s.trimmingCharacters(in: .whitespaces)
        for suffix in ["秒", "sec", "s"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains(":") {
            let parts = s.components(separatedBy: ":")
            var total = 0.0
            for part in parts {
                guard let v = Double(part.trimmingCharacters(in: .whitespaces)) else { return nil }
                total = total * 60 + v
            }
            return total
        }
        return Double(s)
    }

    /// 時刻の欠け・乱れを整える(昇順、範囲内、重複は 0.5 秒ずつずらす)
    private static func normalized(_ input: [ScriptLine], duration: Double) -> [ScriptLine] {
        var lines = input.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return [] }
        let known = lines.filter { $0.time >= 0 }
        let allSame: Bool = {
            guard let first = known.first else { return true }
            return known.allSatisfy { abs($0.time - first.time) < 0.01 }
        }()
        if known.count < 2 || allSame {
            let n = Double(lines.count)
            for i in lines.indices {
                lines[i].time = (duration * Double(i) / n).rounded()
            }
            return lines
        }
        // 欠けている時刻は前後から補間
        for i in lines.indices where lines[i].time < 0 {
            var previousTime = 0.0
            var previousIndex = -1
            var j = i - 1
            while j >= 0 {
                if lines[j].time >= 0 {
                    previousTime = lines[j].time
                    previousIndex = j
                    break
                }
                j -= 1
            }
            var nextTime = duration
            var nextIndex = lines.count
            var k = i + 1
            while k < lines.count {
                if lines[k].time >= 0 {
                    nextTime = lines[k].time
                    nextIndex = k
                    break
                }
                k += 1
            }
            let gap = Double(nextIndex - previousIndex)
            let position = Double(i - previousIndex)
            lines[i].time = previousTime + (nextTime - previousTime) * position / max(1, gap)
        }
        lines.sort { $0.time < $1.time }
        var last = -1.0
        for i in lines.indices {
            var t = min(max(0, lines[i].time), max(0, duration - 1))
            if t <= last { t = last + 0.5 }
            lines[i].time = (t * 10).rounded() / 10
            last = lines[i].time
        }
        return lines
    }

    private struct Chapter {
        var time: Double
        var title: String
    }

    private static func parseChapters(_ raw: String) -> [Chapter] {
        var chapters: [Chapter] = []
        if let object = SubtitlePolisher.extractJSON(raw) {
            var array: [Any]? = object as? [Any]
            if array == nil, let dict = object as? [String: Any] {
                for key in ["chapters", "items", "sections", "outline", "markers", "data"] {
                    if let candidate = dict[key] as? [Any] {
                        array = candidate
                        break
                    }
                }
                if array == nil {
                    array = dict.values.first(where: { $0 is [Any] }) as? [Any]
                }
            }
            for case let item as [String: Any] in array ?? [] {
                let time = seconds(from: item["time"]) ?? seconds(from: item["start"]) ?? seconds(from: item["at"])
                    ?? seconds(from: item["seconds"])
                let title = stringValue(item["title"]) ?? stringValue(item["name"]) ?? stringValue(item["text"]) ?? ""
                guard let t = time, t.isFinite, t >= 0 else { continue }
                chapters.append(Chapter(time: t, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))))
            }
        }
        if chapters.isEmpty {
            for line in parsePlainText(raw) where line.time >= 0 {
                chapters.append(Chapter(time: line.time, title: String(line.text.prefix(24))))
            }
        }
        return chapters
    }
}
