import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// =====================================================================
// 字幕の AI 仕上げ(LLM による校正)
//
// 音声認識 → SubtitleSegmenter の後に呼ぶ。句読点の補正・残ったフィラーの除去・
// 誤認識の修正を行い、長すぎる字幕は文の切れ目で 2 つに分ける(時刻は文字数比で配分)。
//
// エンジン:
//   (a) 端末内: FoundationModels(iOS 26+、Apple Intelligence が有効な端末)
//   (b) クラウド: OpenAI Chat Completions(gpt-4o-mini、ユーザーの API キー)
//   (c) なし
//
// 字幕はバッチ(クラウド 40 件 / 端末内 16 件)に分けて送る。クラウドは最大 3 バッチを同時に送り、
// 端末内モデルは 1 本ずつ。結果はバッチ順にまとめる。
// 失敗しても例外は投げず、入力をそのまま返す(バッチ単位で部分的に適用される)。
// id・時刻・単語タイミングはできる限り保持し、本文が変わった cue の単語は新しい本文に合わせて再配分する。
//
// クラウドの一時的な通信エラー(タイムアウト・回線切れ・NSPOSIXErrorDomain の接続中断など)はバッチごとに送り直す:
// 送信中にバックグラウンド(画面ロックなど)へ入っていたなら(戻ってから失敗が届いた場合も含む)
// フォアグラウンドに戻るまで待ってから(回数に数えない)、
// フォアグラウンドなら 2・4・8・16 秒おいて合計 6 回まで。使い切ったら同じ実行の残りのリクエストはすぐに諦める。
// =====================================================================

enum SubtitlePolisher {

    enum ResolvedEngine: Equatable {
        case onDevice
        case cloud
        case none
    }

    static let cloudModel = "gpt-4o-mini"
    static var cloudEndpoint: URL { CloudAIGateway.chatURL }

    /// 1 回のリクエストに入れる字幕数
    static let cloudBatchSize = 40
    /// 端末内モデルはコンテキストが小さいので少なめ
    static let onDeviceBatchSize = 16
    /// クラウドで同時に送るバッチ数の上限(端末内モデルは 1 本ずつ)
    static let cloudMaxConcurrentBatches = 3

    private static func batchSize(for engine: ResolvedEngine) -> Int {
        engine == .onDevice ? onDeviceBatchSize : cloudBatchSize
    }

    private static func maxConcurrentBatches(for engine: ResolvedEngine) -> Int {
        engine == .cloud ? cloudMaxConcurrentBatches : 1
    }

    // MARK: - 直近のエラー(表示・デバッグ用。キーは含めない)

    private static let errorLock = NSLock()
    private static var storedLastError: String?

    static var lastErrorMessage: String? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return storedLastError
    }

    private static func setLastError(_ message: String?) {
        errorLock.lock()
        storedLastError = message
        errorLock.unlock()
    }

    // MARK: - クラウド通信の状態(1 回の polish / translate / summarize で共有)

    private final class CloudRequestState: @unchecked Sendable {
        /// バックグラウンド待ちの通知先(文字起こしの状態表示用。無ければ nil)
        let pauseReporter: BackgroundPauseReporter?
        private let lock = NSLock()
        private var gaveUp = false

        init(pauseReporter: BackgroundPauseReporter?) {
            self.pauseReporter = pauseReporter
        }

        /// どれかのリクエストが一時的な通信エラーの再試行を使い切ったか
        /// (それ以降のバッチや、半分に割った再試行はすぐに諦める)
        var hasGivenUp: Bool {
            lock.lock()
            defer { lock.unlock() }
            return gaveUp
        }

        func giveUp() {
            lock.lock()
            gaveUp = true
            lock.unlock()
        }
    }

    // MARK: - エンジンの解決

    /// 端末内モデル(Apple Intelligence)が今すぐ使えるか
    static var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
        }
        #endif
        return false
    }

    static func resolveEngine(settings: AppSettings) -> ResolvedEngine {
        switch settings.polishEngine {
        case .none:
            return .none
        case .onDevice:
            return isOnDeviceAvailable ? .onDevice : .none
        case .cloud:
            return settings.isCloudConfigured ? .cloud : .none
        case .auto:
            if isOnDeviceAvailable { return .onDevice }
            if settings.isCloudConfigured { return .cloud }
            return .none
        }
    }

    /// 進捗表示用の名前
    static func displayName(of engine: ResolvedEngine) -> String {
        switch engine {
        case .onDevice: return "Apple Intelligence"
        case .cloud: return "OpenAI"
        case .none: return String(localized: "なし")
        }
    }

    // MARK: - 公開 API

    /// 字幕を校正して返す。失敗した部分は入力のまま。例外は投げない
    /// - pauseReporter: クラウドのリクエストがバックグラウンド待ちになったときの通知先(任意)
    static func polish(_ cues: [SubtitleCue], language: TranscriptionLanguage, settings: AppSettings,
                       pauseReporter: BackgroundPauseReporter? = nil) async -> [SubtitleCue] {
        guard !cues.isEmpty else { return cues }
        let engine = resolveEngine(settings: settings)
        guard engine != .none else { return cues }
        setLastError(nil)

        let instructions = polishInstructions(language: language)
        let header = polishPromptHeader(language: language)
        let apiKey = settings.cloudCredential
        let texts: [String] = cues.map { $0.text }
        let network = CloudRequestState(pauseReporter: pauseReporter)

        let replies = await runBatches(count: cues.count, batchSize: batchSize(for: engine),
                                       maxConcurrent: maxConcurrentBatches(for: engine)) { indices in
            let prompt = SubtitlePolisher.itemsPrompt(header: header, items: indices.map { ($0, texts[$0]) })
            return await SubtitlePolisher.generate(engine: engine, instructions: instructions, prompt: prompt,
                                                   apiKey: apiKey, network: network)
        }
        if Task.isCancelled || replies.isEmpty { return cues }
        return apply(replies, to: cues, language: language)
    }

    /// 字幕を翻訳して translatedText に入れる(本文・時刻・単語は変えない)。
    /// エンジンが無い / 1 件も翻訳できなかったときは nil
    static func translate(_ cues: [SubtitleCue], from language: TranscriptionLanguage, toEnglish: Bool,
                          settings: AppSettings) async -> [SubtitleCue]? {
        guard !cues.isEmpty else { return nil }
        let engine = resolveEngine(settings: settings)
        guard engine != .none else { return nil }
        setLastError(nil)

        let instructions = translationInstructions(source: language, toEnglish: toEnglish)
        let header = toEnglish ? "Translate the following subtitles."
                               : "次の字幕を翻訳してください。"
        let apiKey = settings.cloudCredential
        let texts: [String] = cues.map { $0.text }
        let network = CloudRequestState(pauseReporter: nil)

        let replies = await runBatches(count: cues.count, batchSize: batchSize(for: engine),
                                       maxConcurrent: maxConcurrentBatches(for: engine)) { indices in
            let prompt = SubtitlePolisher.itemsPrompt(header: header, items: indices.map { ($0, texts[$0]) })
            return await SubtitlePolisher.generate(engine: engine, instructions: instructions, prompt: prompt,
                                                   apiKey: apiKey, network: network)
        }
        if Task.isCancelled || replies.isEmpty { return nil }

        var result = cues
        var count = 0
        for (index, text) in replies where index >= 0 && index < result.count {
            let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            result[index].translatedText = cleaned
            count += 1
        }
        return count > 0 ? result : nil
    }

    /// 文章(字幕をつないだものなど)を日本語 2〜3 文に要約する。
    /// エンジンが無い / 失敗したときは nil(例外は投げない)
    static func summarize(_ text: String, settings: AppSettings) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let engine = resolveEngine(settings: settings)
        guard engine != .none else { return nil }
        setLastError(nil)

        let limit = (engine == .onDevice) ? 2500 : 12000
        let body = trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
        let instructions = """
        あなたは動画の内容を短く伝える編集者です。与えられた文章(動画の字幕をつないだもの)を、日本語で 2〜3 文(合計 120 文字以内)に要約します。
        - 事実関係を変えない。文章に無い情報は足さない
        - 出力は JSON オブジェクトのみ。形式: {"summary":"要約"}
        """
        let prompt = "次の文章を要約してください。\n\n" + body
        guard let raw = await generate(engine: engine, instructions: instructions, prompt: prompt,
                                       apiKey: settings.cloudCredential,
                                       network: CloudRequestState(pauseReporter: nil)) else { return nil }
        if Task.isCancelled { return nil }
        if let object = extractJSON(raw) as? [String: Any] {
            for key in ["summary", "text", "result", "output"] {
                if let value = object[key] as? String {
                    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - プロンプト

    private static func polishInstructions(language: TranscriptionLanguage) -> String {
        switch language {
        case .japanese:
            return """
            あなたは動画字幕の校正者です。音声認識で作られた日本語の字幕を、意味を変えずに読みやすく整えます。
            ルール:
            - 明らかな誤認識は文脈から自然な表記に直す(固有名詞・数字は確信があるときだけ)
            - 句読点(、。)を自然に補う。「あのー」「えーと」などのフィラーや言い直しは削る
            - 相づち・感動詞(「うん」「うんうん」「ふーん」「へえ」「ほう」「ああ」「はい」だけの返事など)は削る
            - ローマ字で書かれた相づち・感動詞(hun, hmm, hm, mm, uh, um, ah, oh, eh, huh, un, nn など)は誤認識なので削る
            - 内容は絶対に追加しない。要約・意訳・敬語への言い換えもしない。話し言葉の語尾はそのまま残す
            - 字幕の数と番号は入力と同じにする(複数の字幕を 1 つにまとめない)
            - 1 つの字幕は日本語で約 26 文字以内にする。長すぎるときだけ、文節の切れ目(読点・助詞の後など、単語の途中ではない位置)に改行(\\n)を 1 つ入れて 2 つに分ける
            - フィラーや相づちだけで意味の無い字幕は空文字列 "" にする
            - 出力は JSON オブジェクトのみ。形式: {"items":[{"i":番号,"t":"字幕"}, ...]}
            """
        case .english:
            return """
            You are a subtitle editor. Clean up English subtitles produced by speech recognition without changing their meaning.
            Rules:
            - Fix obvious misrecognitions from context (be careful with names and numbers).
            - Add natural punctuation and capitalization. Remove fillers (um, uh, you know) and false starts.
            - Do not add, summarize, or paraphrase content. Keep the speaker's wording.
            - Keep the same number of subtitles and the same numbering (never merge subtitles).
            - Only if a subtitle is too long, insert exactly one line break (\\n) at a sentence boundary to split it in two.
            - If a subtitle is only filler with no meaning, return an empty string "".
            - Output JSON only, in the form: {"items":[{"i":number,"t":"subtitle"}, ...]}
            """
        }
    }

    private static func polishPromptHeader(language: TranscriptionLanguage) -> String {
        switch language {
        case .japanese: return "次の字幕を校正してください。番号: 本文 の形式です。"
        case .english: return "Clean up the following subtitles. Each line is number: text."
        }
    }

    private static func translationInstructions(source: TranscriptionLanguage, toEnglish: Bool) -> String {
        if toEnglish {
            return """
            You translate video subtitles from \(source == .japanese ? "Japanese" : "English") into natural, concise English suitable for on-screen captions.
            - Translate each subtitle on its own; keep the same numbering and the same number of items.
            - Keep names and numbers. Do not add explanations.
            - Output JSON only, in the form: {"items":[{"i":number,"t":"translation"}, ...]}
            """
        }
        return """
        あなたは動画字幕の翻訳者です。\(source == .english ? "英語" : "日本語")の字幕を、画面に表示する字幕として自然で簡潔な日本語に翻訳します。
        - 字幕ごとに翻訳し、番号と件数は入力と同じにする
        - 固有名詞・数字はそのまま。説明は加えない
        - 出力は JSON オブジェクトのみ。形式: {"items":[{"i":番号,"t":"訳文"}, ...]}
        """
    }

    private static func itemsPrompt(header: String, items: [(Int, String)]) -> String {
        var lines: [String] = [header, ""]
        for (index, text) in items {
            let flat = text.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(index): \(flat)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - バッチ実行

    /// count 件を batchSize ごとに処理し、index → 応答テキストを集める。失敗したバッチは半分に割って再試行。
    /// maxConcurrent > 1 なら最大その数のバッチを同時に処理する(クラウド用)。結果はバッチ順にまとめる
    private static func runBatches(count: Int, batchSize: Int, maxConcurrent: Int,
                                   generate: @escaping @Sendable ([Int]) async -> String?) async -> [Int: String] {
        let size = max(1, batchSize)
        let batches: [[Int]] = stride(from: 0, to: count, by: size).map { (first: Int) -> [Int] in
            Array(first..<min(count, first + size))
        }
        guard !batches.isEmpty else { return [:] }

        var perBatch: [[Int: String]] = []
        if maxConcurrent <= 1 || batches.count == 1 {
            // 1 本ずつ(端末内モデルは同時に 1 セッションだけ)
            for indices in batches {
                if Task.isCancelled { return [:] }
                let got = await SubtitlePolisher.process(indices: indices, depth: 0, generate: generate)
                perBatch.append(got)
            }
        } else {
            let batchCount = batches.count
            let limit = maxConcurrent
            perBatch = await withTaskGroup(of: (Int, [Int: String]).self, returning: [[Int: String]].self) { group in
                var collected = [[Int: String]](repeating: [:], count: batchCount)
                var launched = 0
                var finished = 0
                while finished < batchCount {
                    while launched < batchCount, launched - finished < limit, !Task.isCancelled {
                        let batchIndex = launched
                        let indices = batches[batchIndex]
                        group.addTask {
                            let got = await SubtitlePolisher.process(indices: indices, depth: 0, generate: generate)
                            return (batchIndex, got)
                        }
                        launched += 1
                    }
                    guard let item = await group.next() else { break }
                    collected[item.0] = item.1
                    finished += 1
                }
                return collected
            }
        }
        if Task.isCancelled { return [:] }

        var replies: [Int: String] = [:]
        for got in perBatch {
            replies.merge(got) { _, new in new }
        }
        return replies
    }

    private static func process(indices: [Int], depth: Int,
                                generate: ([Int]) async -> String?) async -> [Int: String] {
        if Task.isCancelled || indices.isEmpty { return [:] }
        if let raw = await generate(indices), let parsed = parseItems(raw) {
            let valid = parsed.filter { indices.contains($0.key) }
            if !valid.isEmpty { return valid }
        }
        guard indices.count > 4, depth < 3 else { return [:] }
        let mid = indices.count / 2
        let left = await process(indices: Array(indices[0..<mid]), depth: depth + 1, generate: generate)
        let right = await process(indices: Array(indices[mid...]), depth: depth + 1, generate: generate)
        return left.merging(right) { _, new in new }
    }

    // MARK: - 生成

    private static func generate(engine: ResolvedEngine, instructions: String, prompt: String, apiKey: String,
                                 network: CloudRequestState) async -> String? {
        switch engine {
        case .onDevice:
            return await generateOnDevice(instructions: instructions, prompt: prompt)
        case .cloud:
            return await chatCompletion(instructions: instructions, prompt: prompt, apiKey: apiKey, network: network)
        case .none:
            return nil
        }
    }

    private static func generateOnDevice(instructions: String, prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                return response.content
            } catch {
                if error is CancellationError { return nil }
                setLastError(String(localized: "端末内 AI: \(error.localizedDescription)"))
                return nil
            }
        }
        #endif
        setLastError(String(localized: "端末内 AI はこの端末では利用できません"))
        return nil
    }

    /// OpenAI Chat Completions を呼んで本文を返す。失敗したら nil(例外は投げない)。
    /// 一時的な通信エラーは、送信中にバックグラウンドへ入っていたならフォアグラウンドに戻るまで待って送り直し(回数に数えない)、
    /// フォアグラウンドなら 2・4・8・16 秒おいて合計 TransientNetworkRetry.maxAttempts 回まで送り直す。
    /// 使い切ったら network に記録し、同じ実行の残りのリクエストはすぐに諦める
    private static func chatCompletion(instructions: String, prompt: String, apiKey: String,
                                       network: CloudRequestState) async -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setLastError(String(localized: "OpenAI の API キーが設定されていません"))
            return nil
        }
        let payload: [String: Any] = [
            "model": cloudModel,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        // 通信の途中でバックグラウンドへ入ったかを判定できるように、監視を始めておく
        await BackgroundEpoch.install()

        /// フォアグラウンドで起きた一時的な通信エラーの回数
        var networkFailures = 0
        // どちらに送るか(ポイントのサーバー / 自分の OpenAI キー)は、受け取った鍵に合わせて最初に 1 回だけ決める。
        // 途中でサインアウトされても、セッションの鍵を OpenAI へ送らないように
        let viaServer = CloudAIGateway.usesPoints
        let endpoint = cloudEndpoint

        while true {
            if Task.isCancelled || network.hasGivenUp { return nil }
            // 画面ロック中などは新しいリクエストを始めず、フォアグラウンドに戻るまで待つ
            do {
                try await AppForegroundWaiter.wait(reporter: network.pauseReporter)
            } catch {
                return nil
            }
            // 待っている間に、ほかのバッチが諦めた(ログインの期限切れなど)か、送り先が変わった(サインアウト)ならやめる
            if Task.isCancelled || network.hasGivenUp || CloudAIGateway.usesPoints != viaServer { return nil }

            // リクエストは送るたびに作り直す
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 120

            // 送信のたびに読み直す(前後で変わったら、この送信の間にバックグラウンドへ入った)
            let epochBefore = BackgroundEpoch.current
            let received: (Data, URLResponse)
            do {
                received = try await URLSession.shared.data(for: request)
            } catch {
                if error is CancellationError || Task.isCancelled { return nil }
                // Task がキャンセルされていない .cancelled や NSPOSIXErrorDomain の接続中断(53 など)は、
                // 画面ロックなどでシステムが通信を打ち切ったもの → 一時的
                guard TransientNetworkRetry.isTransient(error) else {
                    setLastError(String(localized: "通信エラー: \(error.localizedDescription)"))
                    return nil
                }
                if AppLifecycle.shared.isInBackground || BackgroundEpoch.current != epochBefore {
                    // 画面ロックなどで切れた(戻ってから失敗が届いた場合も含む)
                    // → ループの先頭で戻るまで待ってから送り直す(回数に数えない)
                    continue
                }
                networkFailures += 1
                if networkFailures >= TransientNetworkRetry.maxAttempts {
                    network.giveUp()
                    setLastError(String(localized: "通信エラー: \(error.localizedDescription)"))
                    return nil
                }
                do {
                    try await Task.sleep(nanoseconds: TransientNetworkRetry.delayNanoseconds(afterFailures: networkFailures))
                } catch {
                    return nil
                }
                continue
            }

            let (data, response) = received
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                switch status {
                case 401 where viaServer:
                    // ポイント(サーバー)のログインの期限切れ。送ったトークンが今のものならサインアウトし、残りのバッチも送らない
                    // (サインアウトより先に止める。止める前に次のバッチが OpenAI 宛てにセッショントークンを送らないように)
                    network.giveUp()
                    await MainActor.run { AccountService.shared.handleSessionExpired(sentToken: key) }
                    setLastError(String(localized: "ログインの期限が切れました。「文字起こしの方式」の画面で、もう一度 Apple でサインインしてください。"))
                case 401: setLastError(String(localized: "APIキーが正しくありません"))
                case 402:
                    // ポイント不足は他のバッチも同じなので、残りは送らない
                    network.giveUp()
                    setLastError(String(localized: "ポイントが足りません。毎日ボーナスを受け取るか、自分の OpenAI キーを使ってください。"))
                case 429: setLastError(String(localized: "利用上限です"))
                default:
                    let summary = viaServer ? String(localized: "サーバーがエラーを返しました(\(status))")
                                            : String(localized: "OpenAI がエラーを返しました(\(status))")
                    let detail = CloudAIErrorBody(data: data).displayMessage
                    setLastError(detail.isEmpty ? summary : summary + ": " + detail)
                }
                return nil
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                setLastError(String(localized: "OpenAI の応答を読み取れませんでした"))
                return nil
            }
            return content
        }
    }

    // MARK: - 応答の解析

    /// {"items":[{"i":0,"t":"..."}]} / [{"i":..}] / {"0":"..."} のいずれも受け付ける
    static func parseItems(_ raw: String) -> [Int: String]? {
        guard let object = extractJSON(raw) else { return nil }
        var array: [Any]? = object as? [Any]
        if array == nil, let dict = object as? [String: Any] {
            for key in ["items", "cues", "results", "subtitles", "data", "output"] {
                if let candidate = dict[key] as? [Any] {
                    array = candidate
                    break
                }
            }
            if array == nil {
                let anyArray = dict.values.first(where: { $0 is [Any] })
                array = anyArray as? [Any]
            }
            if array == nil {
                var map: [Int: String] = [:]
                for (key, value) in dict {
                    if let index = Int(key.trimmingCharacters(in: .whitespaces)), let text = value as? String {
                        map[index] = text
                    }
                }
                return map.isEmpty ? nil : map
            }
        }
        guard let items = array else { return nil }
        var result: [Int: String] = [:]
        for case let item as [String: Any] in items {
            let index = intValue(item["i"]) ?? intValue(item["index"]) ?? intValue(item["id"]) ?? intValue(item["n"])
            let text = (item["t"] as? String) ?? (item["text"] as? String) ?? (item["subtitle"] as? String)
                ?? (item["translation"] as? String)
            guard let index, let text else { continue }
            result[index] = text
        }
        return result.isEmpty ? nil : result
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        return nil
    }

    /// 応答テキストから JSON(オブジェクトか配列)を取り出す。コードフェンスや前後の説明文があっても可。
    /// ScriptWriter など他の AI 機能からも使う
    static func extractJSON(_ raw: String) -> Any? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return object
        }
        let openers: [Character] = ["{", "["]
        guard let startIndex = text.firstIndex(where: { openers.contains($0) }) else { return nil }
        let closer: Character = (text[startIndex] == "{") ? "}" : "]"
        guard let endIndex = text.lastIndex(of: closer), endIndex > startIndex else { return nil }
        let slice = String(text[startIndex...endIndex])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - 適用

    private static func apply(_ replies: [Int: String], to cues: [SubtitleCue], language: TranscriptionLanguage) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        result.reserveCapacity(cues.count)
        for (index, cue) in cues.enumerated() {
            guard let reply = replies[index] else {
                result.append(cue)
                continue
            }
            let original = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = stripLeadingIndex(reply.replacingOccurrences(of: "\r", with: ""), index: index)
            let pieces = stripped.components(separatedBy: "\n")
                .map { SubtitleSegmenter.cleanCueText($0) }
                .filter { !$0.isEmpty }

            if pieces.isEmpty {
                // 空 → フィラーだけの短い字幕なら削除、長いものは念のため元のまま
                if original.count <= 8 { continue }
                result.append(cue)
                continue
            }

            let joined = pieces.joined(separator: language == .japanese ? "" : " ")
            guard isPlausible(original: original, candidate: joined) else {
                result.append(cue)
                continue
            }

            if pieces.count == 1 || cue.duration < 1.6 {
                result.append(retexted(cue, newText: pieces.count == 1 ? pieces[0] : joined, language: language))
            } else {
                result.append(contentsOf: split(cue, into: Array(pieces.prefix(3)), language: language))
            }
        }
        return result
    }

    /// 「12: 本文」のように番号が混入していたら外す
    private static func stripLeadingIndex(_ text: String, index: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\(index): ", "\(index):", "\(index). ", "\(index)） ", "\(index)) "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    /// 元の本文から大きく逸脱していないか(長さ比・文字の重なり)
    private static func isPlausible(original: String, candidate: String) -> Bool {
        let a = original.count
        let b = candidate.count
        guard b > 0, b <= 240 else { return false }
        if a >= 6 {
            let ratio = Double(b) / Double(max(1, a))
            if ratio > 2.2 || ratio < 0.35 { return false }
            let originalSet = Set(original.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            let candidateChars = candidate.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
            guard !candidateChars.isEmpty else { return false }
            let overlap = candidateChars.filter { originalSet.contains($0) }.count
            if Double(overlap) / Double(candidateChars.count) < 0.4 { return false }
        }
        return true
    }

    private static func retexted(_ cue: SubtitleCue, newText: String, language: TranscriptionLanguage) -> SubtitleCue {
        guard cue.text != newText else { return cue }
        var updated = cue
        updated.words = rescaleWords(cue.words, newText: newText, start: cue.start, end: cue.end, language: language)
        updated.text = newText
        return updated
    }

    /// 1 つの cue を pieces に分割(時刻は文字数比、単語は区間ごとに再配分)
    private static func split(_ cue: SubtitleCue, into pieces: [String], language: TranscriptionLanguage) -> [SubtitleCue] {
        let weights = pieces.map { Double(max(1, $0.count)) }
        let total = max(1, weights.reduce(0, +))
        let span = max(0, cue.end - cue.start)
        var cursor = cue.start
        var result: [SubtitleCue] = []
        for (i, piece) in pieces.enumerated() {
            let pieceEnd = (i == pieces.count - 1) ? cue.end : min(cue.end, cursor + span * weights[i] / total)
            var newCue = SubtitleCue(id: i == 0 ? cue.id : UUID(), start: cursor, end: pieceEnd, text: piece)
            if !cue.words.isEmpty {
                let inRange = cue.words.filter { word in
                    let mid = (word.start + word.end) / 2
                    return mid >= cursor && mid < pieceEnd + 0.000_001
                }
                if inRange.isEmpty {
                    newCue.words = TranscriptionTokenUtilities.distributeEvenly(
                        text: piece, start: cursor, end: pieceEnd, language: language.languageCode)
                        .map { SubtitleWord(text: $0.text, start: $0.start, end: $0.end) }
                } else {
                    newCue.words = rescaleWords(inRange, newText: piece, start: cursor, end: pieceEnd, language: language)
                }
            }
            result.append(newCue)
            cursor = pieceEnd
        }
        return result
    }

    /// 本文が変わった cue の単語タイミングを新しい本文に合わせる。
    /// 単語数が同じならテキストだけ差し替え、違えば元の単語列の時間範囲に文字数比で配分する
    static func rescaleWords(_ words: [SubtitleWord], newText: String, start: Double, end: Double,
                             language: TranscriptionLanguage) -> [SubtitleWord] {
        guard !words.isEmpty else { return [] }
        let pieces = TranscriptionTokenUtilities.wordPieces(newText, language: language.languageCode)
        guard !pieces.isEmpty else { return [] }
        if pieces.count == words.count {
            var result: [SubtitleWord] = []
            for (word, piece) in zip(words, pieces) {
                result.append(SubtitleWord(text: piece, start: word.start, end: word.end))
            }
            return result
        }
        var rangeStart = max(start, words[0].start)
        var rangeEnd = min(end, words[words.count - 1].end)
        if rangeEnd <= rangeStart + 0.05 {
            rangeStart = start
            rangeEnd = max(end, start + 0.2)
        }
        return TranscriptionTokenUtilities.distributeEvenly(text: newText, start: rangeStart, end: rangeEnd,
                                                            language: language.languageCode)
            .map { SubtitleWord(text: $0.text, start: $0.start, end: $0.end) }
    }
}
