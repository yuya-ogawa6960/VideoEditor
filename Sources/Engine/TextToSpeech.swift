import Foundation
import AVFoundation

// =====================================================================
// 読み上げ(AVSpeechSynthesizer)を音声ファイルにする。
// write(_:toBufferCallback:) で受け取った PCM を CAF(16bit)として
// MediaStore.mediaDirectory に保存し、UI はそれをナレーションとして置く。
// =====================================================================

enum TextToSpeechError: LocalizedError {
    case emptyText
    case noAudioProduced
    case cannotWrite(String)
    /// 声が途中で届かなくなり、文章の最後まで作れなかった
    case incomplete

    var errorDescription: String? {
        switch self {
        case .emptyText: return String(localized: "読み上げる文章が空です")
        case .noAudioProduced: return String(localized: "音声を作成できませんでした(別の声を選んでお試しください)")
        case .cannotWrite(let detail): return String(localized: "音声ファイルを書き込めませんでした: \(detail)")
        case .incomplete: return String(localized: "読み上げが途中で止まりました。文章を短く分けて、もう一度お試しください")
        }
    }
}

/// 読み上げに使う声。端末の声(AVSpeechSynthesisVoice)か、クラウドの声(OpenAI gpt-4o-mini-tts / Google)
enum TTSVoiceChoice: Equatable {
    /// 端末の声(nil は言語の標準の声)
    case device(String?)
    /// クラウドの声(OpenAI)
    case cloud(CloudVoice)

    var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }
}

/// クラウドの読み上げの声。OpenAI(gpt-4o-mini-tts / tts-1 共通の名前)と Google(日本語。rawValue は Google の声の名前)
enum CloudVoice: String, CaseIterable, Identifiable {
    case alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse
    // Google(日本語)。Chirp 3 HD は自然さ重視、Neural2 は少し安定した読み方
    case googleAoede = "ja-JP-Chirp3-HD-Aoede"
    case googleKore = "ja-JP-Chirp3-HD-Kore"
    case googleLeda = "ja-JP-Chirp3-HD-Leda"
    case googleZephyr = "ja-JP-Chirp3-HD-Zephyr"
    case googleCharon = "ja-JP-Chirp3-HD-Charon"
    case googleFenrir = "ja-JP-Chirp3-HD-Fenrir"
    case googleOrus = "ja-JP-Chirp3-HD-Orus"
    case googlePuck = "ja-JP-Chirp3-HD-Puck"
    case googleNeural2B = "ja-JP-Neural2-B"
    case googleNeural2C = "ja-JP-Neural2-C"
    case googleNeural2D = "ja-JP-Neural2-D"

    var id: String { rawValue }

    /// Google の声か(ポイントでだけ使える。話し方の指示は使えない)
    var isGoogle: Bool { rawValue.hasPrefix("ja-JP-") }

    static var openAIVoices: [CloudVoice] { allCases.filter { !$0.isGoogle } }
    static var googleVoices: [CloudVoice] { allCases.filter { $0.isGoogle } }

    /// 一覧に出す名前(名前 + 雰囲気)
    var displayName: String {
        if isGoogle {
            let name = rawValue.components(separatedBy: "Chirp3-HD-").last ?? rawValue
            return "\(name.replacingOccurrences(of: "ja-JP-", with: ""))(\(mood))"
        }
        return "\(rawValue.capitalized)(\(mood))"
    }

    var mood: String {
        switch self {
        case .alloy: return String(localized: "中性的・落ち着き")
        case .ash: return String(localized: "男性・落ち着き")
        case .ballad: return String(localized: "男性・やわらかい")
        case .coral: return String(localized: "女性・明るい")
        case .echo: return String(localized: "男性・はっきり")
        case .fable: return String(localized: "物語の語り手")
        case .onyx: return String(localized: "男性・低く深い")
        case .nova: return String(localized: "女性・元気")
        case .sage: return String(localized: "穏やか・知的")
        case .shimmer: return String(localized: "女性・澄んだ")
        case .verse: return String(localized: "男性・若い")
        case .googleAoede: return String(localized: "女性・軽やか")
        case .googleKore: return String(localized: "女性・しっかり")
        case .googleLeda: return String(localized: "女性・若々しい")
        case .googleZephyr: return String(localized: "女性・明るい")
        case .googleCharon: return String(localized: "男性・落ち着き")
        case .googleFenrir: return String(localized: "男性・はつらつ")
        case .googleOrus: return String(localized: "男性・しっかり")
        case .googlePuck: return String(localized: "男性・元気")
        case .googleNeural2B: return String(localized: "女性・標準")
        case .googleNeural2C: return String(localized: "男性・標準")
        case .googleNeural2D: return String(localized: "男性・低め")
        }
    }
}

enum TextToSpeech {
    /// 読み上げの声を 1 つの入口で作る(端末 / クラウド)。instructions はクラウドのときだけ(話し方の指示)
    /// language は端末の声の「標準の声」に使う言語(BCP-47。nil なら日本語)
    static func render(choice: TTSVoiceChoice, text: String, rate: Float, pitch: Float,
                       instructions: String?, language: String? = nil) async throws -> URL {
        // 登録した読み方に置き換えてから声に渡す(家系ラーメン → いえけいラーメン など)
        let text = ReadingDictionary.apply(to: text)
        switch choice {
        case .device(let identifier):
            return try await render(text: text, voiceIdentifier: identifier, rate: rate, pitch: pitch, language: language)
        case .cloud(let voice):
            // 端末の rate(0.3...0.7、標準 0.5)→ クラウドの speed(0.6...1.4)
            let speed = Double(min(max(rate, 0.3), 0.7)) * 2
            return try await CloudTextToSpeech.render(text: text, voice: voice, speed: speed, instructions: instructions)
        }
    }

    // MARK: 自分の声(パーソナルボイス)

    /// 設定 → アクセシビリティ → パーソナルボイス で作った自分の声を、このアプリで使ってよいか
    static var personalVoiceAuthorized: Bool {
        if #available(iOS 17.0, *) {
            return AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
        }
        return false
    }

    static var personalVoiceDenied: Bool {
        if #available(iOS 17.0, *) {
            return AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .denied
        }
        return false
    }

    /// 自分の声の使用を求める(システムの確認が出る)。許可されれば availableVoices に「(自分の声)」として並ぶ
    static func requestPersonalVoice() async -> Bool {
        guard #available(iOS 17.0, *) else { return false }
        return await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// language は "ja-JP" や "ja" のような BCP-47。該当する声が無ければ全部返す
    static func availableVoices(language: String) -> [(id: String, name: String)] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let short = String(language.lowercased().prefix(2))
        var matched = short.isEmpty ? all : all.filter { $0.language.lowercased().hasPrefix(short) }
        if matched.isEmpty { matched = all }
        matched.sort { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return matched.map { voice in
            (id: voice.identifier, name: displayName(for: voice))
        }
    }

    private static func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        if #available(iOS 17.0, *), voice.voiceTraits.contains(.isPersonalVoice) {
            return String(localized: "\(voice.name)(自分の声)")
        }
        switch voice.quality {
        case .premium: return String(localized: "\(voice.name)(最高品質)")
        case .enhanced: return String(localized: "\(voice.name)(高品質)")
        default: return voice.name
        }
    }

    /// 言語(BCP-47)のいちばん品質の高い端末の声(自分の声・おもしろ声は除く。地域まで同じ声を優先する)
    static func defaultVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
        let lower = language.lowercased()
        let short = String(lower.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.lowercased().hasPrefix(short)
                && !voice.voiceTraits.contains(.isPersonalVoice)
                && !voice.voiceTraits.contains(.isNoveltyVoice)
        }
        let sameRegion = candidates.filter { $0.language.lowercased() == lower }
        let pool = sameRegion.isEmpty ? candidates : sameRegion
        if let best = pool.max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return best }
        return AVSpeechSynthesisVoice(language: language)
    }

    /// 文章を読み上げて音声ファイルにし、その URL を返す。rate は 0...1(標準 0.5)、pitch は 0.5...2。
    /// voiceIdentifier が nil(標準の声)なら language の声で読む
    static func render(text: String, voiceIdentifier: String?, rate: Float, pitch: Float,
                       language: String? = nil) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextToSpeechError.emptyText }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            // 「標準の声」は選んだ言語の声で読む(English を選んだのに日本語の声で英文を読んでいた)
            utterance.voice = defaultVoice(forLanguage: language ?? "ja-JP")
        }
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
        utterance.volume = 1

        let destination = MediaStore.uniqueDestination(forFileName: String(localized: "読み上げ.caf"))
        let session = TextToSpeechWriteSession(destination: destination)
        return try await session.run(utterance)
    }
}

// MARK: - 端末の声の言語

/// 端末の声の読み上げで選べる言語(BCP-47)。チップの名前はその言語での呼び方(日本語だけ訳す)
enum TTSLanguage {
    static let codes = ["ja-JP", "en-US", "es-MX", "pt-BR"]

    static func displayName(_ code: String) -> String {
        switch code {
        case "ja-JP": return String(localized: "日本語")
        case "en-US": return "English"
        case "es-MX": return "Español"
        case "pt-BR": return "Português"
        default: return code
        }
    }

    /// 最初に選ぶ言語(端末の言語に合わせる。日本語・スペイン語・ポルトガル語以外は英語)
    static var deviceDefault: String {
        let preferred = (Locale.preferredLanguages.first ?? "ja").lowercased()
        if preferred.hasPrefix("ja") { return "ja-JP" }
        if preferred.hasPrefix("es") { return "es-MX" }
        if preferred.hasPrefix("pt") { return "pt-BR" }
        return "en-US"
    }
}

// MARK: - 作った声の使い回し(途中の失敗・キャンセルのあとの続き)

/// クラウドの声で作った音声を、声・速さ・文章ごとに覚えておく(アプリを終了するまで)。
/// 台本のナレーションや吹き替えが途中の失敗やキャンセルで止まったあと、もう一度作るときに
/// できていた分は作り直さずに使う(ポイントを二重に使わないため)。ファイルが消えていれば使わない
enum TTSResumeCache {
    private static let lock = NSLock()
    private static var urls: [String: URL] = [:]

    static func key(choice: TTSVoiceChoice, text: String, rate: Float, pitch: Float, extra: String = "") -> String {
        let voice: String
        switch choice {
        case .device(let identifier): voice = "device:" + (identifier ?? "")
        case .cloud(let cloud): voice = "cloud:" + cloud.rawValue
        }
        return [voice, String(format: "%.3f", rate), String(format: "%.3f", pitch), extra, text].joined(separator: "|")
    }

    static func url(for key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = urls[key] else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            urls[key] = nil
            return nil
        }
        return url
    }

    static func store(_ url: URL, for key: String) {
        lock.lock()
        urls[key] = url
        lock.unlock()
    }
}

// MARK: - クラウドの声(OpenAI gpt-4o-mini-tts)

enum CloudTextToSpeechError: LocalizedError {
    case notConfigured
    case insufficientPoints(String)
    /// 自分の OpenAI キーが正しくない(自分のキーで送ったときだけ)
    case upstreamAuth
    /// ポイント(サーバー)のログインの期限が切れた(サインアウト済み)
    case sessionExpired
    /// Google の声はポイント(サーバー経由)でだけ使える
    case googleNeedsPoints
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            // ポイントで使う設定ならサインイン、そうでなければ API キーを案内する
            return CloudAIGateway.prefersPoints
                ? String(localized: "クラウドの声を使うには、「アカウントとポイント」で Apple でサインインしてください。")
                : String(localized: "クラウドの声を使うには、「文字起こしとAI仕上げ」で OpenAI の API キーを設定してください。")
        case .insufficientPoints(let detail):
            return detail.isEmpty ? CloudAIGateway.insufficientPointsMessage : detail
        case .upstreamAuth:
            return CloudAIGateway.invalidAPIKeyMessage
        case .sessionExpired:
            return CloudAIGateway.sessionExpiredMessage
        case .googleNeedsPoints:
            return String(localized: "Google の声はポイントで使います。「アカウントとポイント」で Apple でサインインし、「ポイントで使う」を選んでください。")
        case .server(let status, let detail):
            return String(localized: "クラウドの声を作れませんでした(\(status)): \(detail)")
        }
    }
}

/// OpenAI の読み上げを、ポイント(自前サーバー経由)か自分のキーで呼び、mp3 を Media フォルダに保存する
enum CloudTextToSpeech {
    static func render(text: String, voice: CloudVoice, speed: Double, instructions: String?) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextToSpeechError.emptyText }
        // どちらに送ったか(エラーの見せ方を決める。送っている間に設定が変わっても、送った宛先で判断する)
        let viaServer = CloudAIGateway.usesPoints
        // Google の声は自分の OpenAI キーでは作れない(サーバーが Google に頼む)
        if voice.isGoogle, !viaServer { throw CloudTextToSpeechError.googleNeedsPoints }
        let credential = CloudAIGateway.credential
        guard !credential.isEmpty else { throw CloudTextToSpeechError.notConfigured }
        // 自分のキーで OpenAI に直接送るときは、先に moderation で確かめる(ScriptWriter.swift の OpenAIModeration。ポイントの経路はサーバーが確かめる)
        if !viaServer {
            let spoken = [trimmed, instructions ?? ""].joined(separator: "\n")
            try await OpenAIModeration.check(spoken, apiKey: credential)
        }

        var body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": trimmed,
            "voice": voice.rawValue,
            "speed": min(max(speed, 0.25), 4),
            "response_format": "mp3"
        ]
        if voice.isGoogle {
            body["provider"] = "google"
        } else if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            body["instructions"] = instructions
        }
        var request = URLRequest(url: CloudAIGateway.speechURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let errorBody = CloudAIErrorBody(data: data)
            let detail = errorBody.displayMessage.isEmpty
                ? (String(data: data.prefix(200), encoding: .utf8) ?? "")
                : errorBody.displayMessage
            // ポイント不足(サーバーの文は日本語だけなので、端末の言語の文を出す)
            if status == 402 { throw CloudTextToSpeechError.insufficientPoints("") }
            if status == 401, viaServer {
                // ログインの期限切れ。送ったトークンが今のものならサインアウトする
                await MainActor.run { AccountService.shared.handleSessionExpired(sentToken: credential) }
                throw CloudTextToSpeechError.sessionExpired
            }
            // サーバー側の OpenAI キーの問題(ポイントは戻してある)。利用者のキーの問題ではない
            if errorBody.code == "upstream_auth" { throw CloudTextToSpeechError.server(status, detail) }
            if !viaServer, status == 401 || status == 403 { throw CloudTextToSpeechError.upstreamAuth }
            throw CloudTextToSpeechError.server(status, detail)
        }
        guard data.count > 100 else { throw TextToSpeechError.noAudioProduced }
        let destination = MediaStore.uniqueDestination(forFileName: "speech.mp3")
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw TextToSpeechError.cannotWrite(error.localizedDescription)
        }
        return destination
    }
}

/// 1 回分の書き出し。完了まで AVSpeechSynthesizer を保持する
private final class TextToSpeechWriteSession {
    private static let activeLock = NSLock()
    private static var active: [ObjectIdentifier: TextToSpeechWriteSession] = [:]

    private let destination: URL
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var finished = false
    /// 最後に声(バッファ)が届いた時刻。長い文章でも届き続けている間は待つ
    private var lastActivity = Date()
    private var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL) {
        self.destination = destination
    }

    func run(_ utterance: AVSpeechUtterance) async throws -> URL {
        Self.activeLock.lock()
        Self.active[ObjectIdentifier(self)] = self
        Self.activeLock.unlock()
        defer {
            Self.activeLock.lock()
            Self.active[ObjectIdentifier(self)] = nil
            Self.activeLock.unlock()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            DispatchQueue.main.async { [self] in
                self.lock.lock()
                self.lastActivity = Date()
                self.lock.unlock()
                self.synthesizer.write(utterance) { [weak self] buffer in
                    self?.handle(buffer)
                }
                // 声が届かなくなったときの保険(前は開始から 60 秒で必ず打ち切り、長い文章が途中で切れていた)
                self.scheduleWatchdog()
            }
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        lastActivity = Date()
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            if framesWritten > 0 {
                finishLocked(error: nil)
            } else {
                // 声によっては先頭に空のバッファが来ることがあるので、少し待ってから判断する
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.finishIfStillEmpty()
                }
            }
            return
        }
        do {
            if file == nil {
                let format = pcm.format
                let fileSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                file = try AVAudioFile(forWriting: destination,
                                       settings: fileSettings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            }
            try file?.write(from: pcm)
            framesWritten += AVAudioFramePosition(pcm.frameLength)
        } catch {
            finishLocked(error: TextToSpeechError.cannotWrite(error.localizedDescription))
        }
    }

    private func finishIfStillEmpty() {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        if framesWritten > 0 {
            finishLocked(error: nil)
        } else {
            finishLocked(error: TextToSpeechError.noAudioProduced)
        }
    }

    /// 声が届いているかを 5 秒ごとに確かめる(メインスレッド)
    private func scheduleWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkStalled()
        }
    }

    /// 最初の声が 60 秒、途中で 20 秒届かなければ打ち切る
    private func checkStalled() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        let idle = Date().timeIntervalSince(lastActivity)
        let limit: TimeInterval = framesWritten > 0 ? 20 : 60
        lock.unlock()
        if idle > limit {
            timeout()
        } else {
            scheduleWatchdog()
        }
    }

    private func timeout() {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        _ = synthesizer.stopSpeaking(at: .immediate)
        // 途中までの音声を成功として追加しない(文章の後半が無いナレーションになり、入力も消えていた)
        if framesWritten > 0 {
            finishLocked(error: TextToSpeechError.incomplete)
        } else {
            finishLocked(error: TextToSpeechError.noAudioProduced)
        }
    }

    /// lock を保持した状態で呼ぶ
    private func finishLocked(error: Error?) {
        finished = true
        file = nil
        let cont = continuation
        continuation = nil
        if let error {
            try? FileManager.default.removeItem(at: destination)
            cont?.resume(throwing: error)
        } else if framesWritten == 0 {
            try? FileManager.default.removeItem(at: destination)
            cont?.resume(throwing: TextToSpeechError.noAudioProduced)
        } else {
            cont?.resume(returning: destination)
        }
    }
}
