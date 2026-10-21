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

    var errorDescription: String? {
        switch self {
        case .emptyText: return String(localized: "読み上げる文章が空です")
        case .noAudioProduced: return String(localized: "音声を作成できませんでした(別の声を選んでお試しください)")
        case .cannotWrite(let detail): return String(localized: "音声ファイルを書き込めませんでした: \(detail)")
        }
    }
}

/// 読み上げに使う声。端末の声(AVSpeechSynthesisVoice)か、クラウドの声(OpenAI gpt-4o-mini-tts)
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

/// OpenAI の読み上げの声(gpt-4o-mini-tts / tts-1 共通の名前)
enum CloudVoice: String, CaseIterable, Identifiable {
    case alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse
    var id: String { rawValue }

    /// 一覧に出す名前(英語名 + 雰囲気)
    var displayName: String { "\(rawValue.capitalized)(\(mood))" }

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
        }
    }
}

enum TextToSpeech {
    /// 読み上げの声を 1 つの入口で作る(端末 / クラウド)。instructions はクラウドのときだけ(話し方の指示)
    static func render(choice: TTSVoiceChoice, text: String, rate: Float, pitch: Float,
                       instructions: String?) async throws -> URL {
        switch choice {
        case .device(let identifier):
            return try await render(text: text, voiceIdentifier: identifier, rate: rate, pitch: pitch)
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

    /// 文章を読み上げて音声ファイルにし、その URL を返す。rate は 0...1(標準 0.5)、pitch は 0.5...2
    static func render(text: String, voiceIdentifier: String?, rate: Float, pitch: Float) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextToSpeechError.emptyText }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        }
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
        utterance.volume = 1

        let destination = MediaStore.uniqueDestination(forFileName: String(localized: "読み上げ.caf"))
        let session = TextToSpeechWriteSession(destination: destination)
        return try await session.run(utterance)
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
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "クラウドの声を使うには、「文字起こしの方式」の画面で Apple でサインインするか、OpenAI の API キーを設定してください。")
        case .insufficientPoints(let detail):
            return detail.isEmpty ? String(localized: "ポイントが足りません。毎日ボーナスを受け取るか、自分の OpenAI キーを使ってください。") : detail
        case .upstreamAuth:
            return String(localized: "APIキーが正しくありません。「文字起こしの方式」の画面で OpenAI の API キーを確認してください。")
        case .sessionExpired:
            return String(localized: "ログインの期限が切れました。「文字起こしの方式」の画面で、もう一度 Apple でサインインしてください。")
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
        let credential = CloudAIGateway.credential
        guard !credential.isEmpty else { throw CloudTextToSpeechError.notConfigured }

        var body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": trimmed,
            "voice": voice.rawValue,
            "speed": min(max(speed, 0.25), 4),
            "response_format": "mp3"
        ]
        if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
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
                self.synthesizer.write(utterance) { [weak self] buffer in
                    self?.handle(buffer)
                }
                // 何も返ってこない場合の保険(60 秒)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    self?.timeout()
                }
            }
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
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

    private func timeout() {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        _ = synthesizer.stopSpeaking(at: .immediate)
        if framesWritten > 0 {
            finishLocked(error: nil)
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
