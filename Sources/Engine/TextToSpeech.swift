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
        case .emptyText: return "読み上げる文章が空です"
        case .noAudioProduced: return "音声を作成できませんでした(別の声を選んでお試しください)"
        case .cannotWrite(let detail): return "音声ファイルを書き込めませんでした: \(detail)"
        }
    }
}

enum TextToSpeech {
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
        switch voice.quality {
        case .premium: return "\(voice.name)(最高品質)"
        case .enhanced: return "\(voice.name)(高品質)"
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

        let destination = MediaStore.uniqueDestination(forFileName: "読み上げ.caf")
        let session = TextToSpeechWriteSession(destination: destination)
        return try await session.run(utterance)
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
