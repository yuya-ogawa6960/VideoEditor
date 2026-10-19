import Foundation
import AVFoundation
import Speech
import Observation

// =====================================================================
// 自動文字起こし(SFSpeechRecognizer)
// 各クリップのトリミング範囲の音声を ≤50 秒のチャンクに切り出して認識し、
// 単語のタイムスタンプから字幕(出力タイムライン秒)を組み立てる。
// =====================================================================

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja-JP"
    case english = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "英語"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// 翻訳フレームワーク用の言語コード("ja" / "en")
    var languageCode: String {
        switch self {
        case .japanese: return "ja"
        case .english: return "en"
        }
    }
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable(String)
    case alreadyRunning
    case noAudioClips
    case audioExportFailed(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "音声認識の権限がありません。設定アプリでこのアプリの「音声認識」を許可してください。"
        case .recognizerUnavailable(let language):
            return "\(language)の音声認識器が利用できません。ネットワーク接続や端末の言語設定を確認してください。"
        case .alreadyRunning:
            return "文字起こしはすでに実行中です。"
        case .noAudioClips:
            return "文字起こしできる音声がありません(すべてのクリップが無音またはミュートです)。"
        case .audioExportFailed(let detail):
            return "音声の切り出しに失敗しました: \(detail)"
        case .recognitionFailed(let detail):
            return "音声認識に失敗しました: \(detail)"
        }
    }
}

/// 認識結果の1単語(チャンク先頭からの秒)
private struct TranscriptionWord {
    var text: String
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

/// 認識対象の音声チャンク
private struct TranscriptionChunk {
    let clip: Clip
    /// クリップの出力タイムライン上の開始時刻
    let clipTimelineStart: Double
    /// 元素材上の範囲
    let sourceStart: Double
    let sourceEnd: Double
}

/// continuation の二重 resume 防止
private final class TranscriptionResumeGuard {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

@Observable
final class TranscriptionService {
    private(set) var isRunning: Bool = false
    private(set) var progress: Double = 0
    private(set) var statusText: String = ""

    /// 1チャンクの最大長(秒)
    private static let chunkLength: Double = 50
    /// 1字幕の最大長(秒)
    private static let maxCueDuration: Double = 3.5
    /// 単語間の無音がこれを超えたら字幕を区切る(秒)
    private static let maxGap: Double = 0.8

    private let lock = NSLock()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var currentTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var runningWork: Task<[SubtitleCue], Error>?

    init() {}

    // MARK: - 公開 API

    func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        default:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus == .authorized)
                }
            }
        }
    }

    /// 出力タイムライン秒の字幕を返す(トリミング・速度・クリップ順を反映、ミュートクリップは除外)
    func transcribe(snapshot: ProjectSnapshot, language: TranscriptionLanguage) async throws -> [SubtitleCue] {
        lock.lock()
        if busy {
            lock.unlock()
            throw TranscriptionError.alreadyRunning
        }
        busy = true
        cancelRequested = false
        lock.unlock()

        await updateUI(running: true, progress: 0, status: "準備中…")

        let work = Task<[SubtitleCue], Error> {
            try await self.performTranscription(snapshot: snapshot, language: language)
        }
        lock.lock()
        runningWork = work
        lock.unlock()

        do {
            let cues = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            finishRun()
            await updateUI(running: false, progress: 1, status: "完了(\(cues.count)件)")
            return cues
        } catch {
            finishRun()
            let cancelled = error is CancellationError
            await updateUI(running: false, progress: 0,
                           status: cancelled ? "キャンセルしました" : "失敗しました")
            throw error
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = currentTask
        let work = runningWork
        lock.unlock()
        task?.cancel()
        work?.cancel()
    }

    // MARK: - 本体

    private func performTranscription(snapshot: ProjectSnapshot,
                                      language: TranscriptionLanguage) async throws -> [SubtitleCue] {
        // 権限
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let granted = await requestAuthorization()
            guard granted else { throw TranscriptionError.notAuthorized }
        }

        // 認識器
        guard let recognizer = SFSpeechRecognizer(locale: language.locale) else {
            throw TranscriptionError.recognizerUnavailable(language.displayName)
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable(language.displayName)
        }

        // チャンク分割
        let chunks = Self.makeChunks(for: snapshot)
        guard !chunks.isEmpty else { throw TranscriptionError.noAudioClips }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var cues: [SubtitleCue] = []
        let total = chunks.count

        for (index, chunk) in chunks.enumerated() {
            try checkCancelled()
            await updateUI(progress: Double(index) / Double(total),
                           status: "文字起こし中 \(index + 1)/\(total)")

            let fileURL = tempDir.appendingPathComponent("chunk-\(index).m4a")
            try await exportAudio(from: chunk.clip.url, start: chunk.sourceStart, end: chunk.sourceEnd, to: fileURL)
            try checkCancelled()

            var words = try await recognize(fileURL: fileURL, recognizer: recognizer)
            try? FileManager.default.removeItem(at: fileURL)
            try checkCancelled()

            words = Self.fixMissingTimestamps(words, chunkDuration: chunk.sourceEnd - chunk.sourceStart)
            let groups = Self.groupWords(words, language: language)
            cues.append(contentsOf: Self.makeCues(from: groups, chunk: chunk, language: language))

            await updateUI(progress: Double(index + 1) / Double(total), status: nil)
        }

        return Self.finalize(cues)
    }

    private static func makeChunks(for snapshot: ProjectSnapshot) -> [TranscriptionChunk] {
        var chunks: [TranscriptionChunk] = []
        var timelineStart = 0.0
        for clip in snapshot.clips {
            let clipStart = timelineStart
            timelineStart += clip.outputDuration
            guard clip.hasAudio, !clip.isMuted, clip.trimmedDuration >= 0.3 else { continue }
            var s = clip.startTime
            while s < clip.endTime - 0.05 {
                let e = min(s + chunkLength, clip.endTime)
                if e - s >= 0.3 {
                    chunks.append(TranscriptionChunk(clip: clip, clipTimelineStart: clipStart,
                                                     sourceStart: s, sourceEnd: e))
                }
                s = e
            }
        }
        return chunks
    }

    // MARK: - 音声切り出し

    private func exportAudio(from sourceURL: URL, start: Double, end: Double, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscriptionError.audioExportFailed("音声トラックがありません")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExportFailed("書き出しセッションを作成できません")
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 44_100),
                                        end: CMTime(seconds: end, preferredTimescale: 44_100))
        try? FileManager.default.removeItem(at: outputURL)
        do {
            // iOS 18 の async API(Task のキャンセルで書き出しも中止される)
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            if error is CancellationError || Task.isCancelled || isCancelRequested {
                throw CancellationError()
            }
            throw TranscriptionError.audioExportFailed(error.localizedDescription)
        }
    }

    // MARK: - 音声認識

    private func recognize(fileURL: URL, recognizer: SFSpeechRecognizer) async throws -> [TranscriptionWord] {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation

        let resumeGuard = TranscriptionResumeGuard()

        let words: [TranscriptionWord] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranscriptionWord], Error>) in
                let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    if let result, result.isFinal {
                        if resumeGuard.claim() {
                            continuation.resume(returning: TranscriptionService.words(from: result.bestTranscription))
                        }
                        return
                    }
                    if let error {
                        guard resumeGuard.claim() else { return }
                        if self?.isCancelRequested == true {
                            continuation.resume(throwing: CancellationError())
                        } else if TranscriptionService.isNoSpeechError(error) {
                            continuation.resume(returning: [])
                        } else {
                            continuation.resume(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                        }
                    }
                }
                self.setCurrentTask(task)
                if self.isCancelRequested {
                    task.cancel()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelFromTaskCancellation()
        }

        setCurrentTask(nil)
        return words
    }

    private static func words(from transcription: SFTranscription) -> [TranscriptionWord] {
        transcription.segments.map { segment in
            TranscriptionWord(text: segment.substring, start: segment.timestamp, duration: segment.duration)
        }
    }

    /// 「音声が検出されなかった」系のエラー(空の結果として扱う)
    private static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(nsError.code) {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("no speech") || message.contains("retry")
    }

    // MARK: - 字幕の組み立て

    /// タイムスタンプが全て 0 の場合(稀にある)は文字数比でチャンク内に均等配置する
    private static func fixMissingTimestamps(_ words: [TranscriptionWord], chunkDuration: Double) -> [TranscriptionWord] {
        guard words.count > 1,
              words.allSatisfy({ $0.start == 0 && $0.duration == 0 }) else { return words }
        let totalChars = max(1, words.reduce(0) { $0 + max(1, $1.text.count) })
        var t = 0.0
        return words.map { word in
            let d = chunkDuration * Double(max(1, word.text.count)) / Double(totalChars)
            let fixed = TranscriptionWord(text: word.text, start: t, duration: d)
            t += d
            return fixed
        }
    }

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", ".", "…"]
    private static let clauseEnders: Set<Character> = ["、", ",", "，", ";", ":"]

    private static func groupWords(_ words: [TranscriptionWord], language: TranscriptionLanguage) -> [[TranscriptionWord]] {
        let isJapanese = language == .japanese
        let limit = isJapanese ? 20 : 8
        var groups: [[TranscriptionWord]] = []
        var current: [TranscriptionWord] = []

        func measure(_ list: [TranscriptionWord]) -> Int {
            isJapanese ? joinText(list, language: language).count : list.count
        }

        for raw in words {
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var word = raw
            word.text = text

            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let tooLong = word.end - first.start > maxCueDuration
                let tooManyChars = isJapanese && measure(current) + text.count > limit + 2
                if gap > maxGap || tooLong || tooManyChars {
                    groups.append(current)
                    current = []
                }
            }

            current.append(word)

            let length = measure(current)
            let lastChar = text.last
            let endsSentence = lastChar.map { sentenceEnders.contains($0) } ?? false
            let endsClause = lastChar.map { clauseEnders.contains($0) } ?? false
            if endsSentence || length >= limit || (endsClause && length >= limit / 2) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// 日本語はスペースなし(英数字どうしの間のみスペース)、英語はスペース区切り
    private static func joinText(_ words: [TranscriptionWord], language: TranscriptionLanguage) -> String {
        if language == .english {
            return words.map { $0.text }.joined(separator: " ")
        }
        var result = ""
        for word in words {
            if let prev = result.last, let next = word.text.first,
               isASCIIAlphanumeric(prev), isASCIIAlphanumeric(next) {
                result.append(" ")
            }
            result.append(word.text)
        }
        return result
    }

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber
    }

    private static func makeCues(from groups: [[TranscriptionWord]], chunk: TranscriptionChunk,
                                 language: TranscriptionLanguage) -> [SubtitleCue] {
        let clip = chunk.clip
        let speed = max(clip.speed, 0.01)
        let clipTimelineEnd = chunk.clipTimelineStart + clip.outputDuration

        // チャンク内時刻 → 元素材時刻 → 出力タイムライン時刻
        func toTimeline(_ local: Double) -> Double {
            let source = chunk.sourceStart + local
            let clamped = min(max(source, clip.startTime), clip.endTime)
            return chunk.clipTimelineStart + (clamped - clip.startTime) / speed
        }

        var cues: [SubtitleCue] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            var text = joinText(group, language: language)
            if language == .japanese {
                while let c = text.last, c == "。" || c == "、" {
                    text.removeLast()
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = toTimeline(first.start)
            var end = toTimeline(last.end)
            if end - start < 0.6 {
                end = min(start + 0.6, clipTimelineEnd)
            }
            guard end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues
    }

    /// 時刻順に並べ、重なりを解消する
    private static func finalize(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var sorted = cues.sorted { $0.start < $1.start }
        if sorted.count > 1 {
            for i in 0..<(sorted.count - 1) where sorted[i].end > sorted[i + 1].start {
                sorted[i].end = max(sorted[i].start + 0.1, sorted[i + 1].start)
            }
        }
        return sorted
    }

    // MARK: - 状態管理

    private var isCancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    private func checkCancelled() throws {
        if isCancelRequested { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func setCurrentTask(_ task: SFSpeechRecognitionTask?) {
        lock.lock()
        currentTask = task
        lock.unlock()
    }

    private func cancelFromTaskCancellation() {
        lock.lock()
        cancelRequested = true
        let task = currentTask
        lock.unlock()
        task?.cancel()
    }

    private func finishRun() {
        lock.lock()
        busy = false
        currentTask = nil
        runningWork = nil
        lock.unlock()
    }

    private func updateUI(running: Bool? = nil, progress: Double? = nil, status: String? = nil) async {
        await MainActor.run {
            if let running { self.isRunning = running }
            if let progress { self.progress = min(max(progress, 0), 1) }
            if let status { self.statusText = status }
        }
    }
}
