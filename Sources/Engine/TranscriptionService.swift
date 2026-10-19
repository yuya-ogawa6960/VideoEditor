import Foundation
import AVFoundation
import Speech
import Observation

// =====================================================================
// 自動文字起こし
//
// - iOS 26 以降: SpeechAnalyzer + SpeechTranscriber(句読点付き・単語ごとの時刻)で
//   クリップ全体を一度に認識する。モデル未導入なら自動ダウンロード、失敗時は従来方式へ。
// - iOS 18〜25: SFSpeechRecognizer(addsPunctuation)で ≤50 秒のチャンクに分けて認識。
//
// どちらの経路でも「クリップ全体の時刻付きトークン列」を作ってから
// SubtitleSegmenter で文・文節単位に区切る(チャンク境界で文が切れない)。
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

/// SFSpeech の認識結果の1単語(チャンク先頭からの秒)
private struct TranscriptionWord {
    var text: String
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

/// 元素材上の音声範囲(秒)
private struct SourceRange {
    let start: Double
    let end: Double
    var length: Double { max(0, end - start) }
}

/// 1クリップ分の認識ジョブ
private struct ClipJob {
    let clip: Clip
    /// クリップの出力タイムライン上の開始時刻
    let clipTimelineStart: Double
    /// SFSpeech 用のチャンク(元素材上の秒)。進捗の単位にも使う
    let chunks: [SourceRange]

    var clipTimelineEnd: Double { clipTimelineStart + clip.outputDuration }
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

    /// SFSpeech 経路の 1チャンクの最大長(秒)
    private static let chunkLength: Double = 50

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
    /// - Parameter removeFillers: 「あのー」「えーと」「um」などのフィラーや吃音を字幕から除く(既定 true)
    func transcribe(snapshot: ProjectSnapshot, language: TranscriptionLanguage,
                    removeFillers: Bool = true) async throws -> [SubtitleCue] {
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
            try await self.performTranscription(snapshot: snapshot, language: language, removeFillers: removeFillers)
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
                                      language: TranscriptionLanguage,
                                      removeFillers: Bool) async throws -> [SubtitleCue] {
        // 権限
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let granted = await requestAuthorization()
            guard granted else { throw TranscriptionError.notAuthorized }
        }

        // クリップごとのジョブ
        let jobs = Self.makeJobs(for: snapshot)
        guard !jobs.isEmpty else { throw TranscriptionError.noAudioClips }
        let totalUnits = max(1, jobs.reduce(0) { $0 + $1.chunks.count })
        var doneUnits = 0

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 従来の認識器は必要になったときだけ作る
        var legacyRecognizer: SFSpeechRecognizer?

        var cues: [SubtitleCue] = []

        for job in jobs {
            try checkCancelled()

            // 元素材上の秒で揃えたトークン列
            var sourceTokens: [TimedToken]? = nil

            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                sourceTokens = try await recognizeClipWithAnalyzer(job: job, language: language, tempDir: tempDir,
                                                                   doneUnits: doneUnits, totalUnits: totalUnits)
            }
            #endif

            if sourceTokens == nil {
                if legacyRecognizer == nil {
                    guard let recognizer = SFSpeechRecognizer(locale: language.locale), recognizer.isAvailable else {
                        throw TranscriptionError.recognizerUnavailable(language.displayName)
                    }
                    legacyRecognizer = recognizer
                }
                sourceTokens = try await recognizeClipWithSFSpeech(job: job, recognizer: legacyRecognizer!, tempDir: tempDir,
                                                                   doneUnits: doneUnits, totalUnits: totalUnits)
            }
            doneUnits += job.chunks.count
            try checkCancelled()

            // 元素材時刻 → 出力タイムライン時刻 に変換してから文単位に区切る
            let timelineTokens = Self.mapToTimeline(sourceTokens ?? [], job: job)
            var segmenter = SubtitleSegmenter(language: language, removeFillers: removeFillers)
            segmenter.hardEnd = job.clipTimelineEnd
            cues.append(contentsOf: segmenter.segment(timelineTokens))

            await updateUI(progress: Double(doneUnits) / Double(totalUnits), status: nil)
        }

        return Self.finalize(cues)
    }

    private static func makeJobs(for snapshot: ProjectSnapshot) -> [ClipJob] {
        var jobs: [ClipJob] = []
        var timelineStart = 0.0
        for clip in snapshot.clips {
            let clipStart = timelineStart
            timelineStart += clip.outputDuration
            guard clip.hasAudio, !clip.isMuted, clip.trimmedDuration >= 0.3 else { continue }
            var chunks: [SourceRange] = []
            var s = clip.startTime
            while s < clip.endTime - 0.05 {
                let e = min(s + chunkLength, clip.endTime)
                if e - s >= 0.3 {
                    chunks.append(SourceRange(start: s, end: e))
                }
                s = e
            }
            guard !chunks.isEmpty else { continue }
            jobs.append(ClipJob(clip: clip, clipTimelineStart: clipStart, chunks: chunks))
        }
        return jobs
    }

    /// 元素材上の秒 → 出力タイムライン上の秒(トリミング・速度を反映)
    private static func mapToTimeline(_ tokens: [TimedToken], job: ClipJob) -> [TimedToken] {
        let clip = job.clip
        let speed = max(clip.speed, 0.01)
        func convert(_ source: Double) -> Double {
            let clamped = min(max(source, clip.startTime), clip.endTime)
            return job.clipTimelineStart + (clamped - clip.startTime) / speed
        }
        return tokens.map { token in
            TimedToken(text: token.text, start: convert(token.start), end: convert(token.end))
        }
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

    // MARK: - iOS 26+: SpeechAnalyzer / SpeechTranscriber

    #if compiler(>=6.2)
    /// クリップ全体を SpeechAnalyzer で認識し、元素材上の秒のトークン列を返す。
    /// 利用不可・モデル導入失敗・認識エラーのときは nil(呼び出し側が従来方式へ切り替える)。
    @available(iOS 26.0, *)
    private func recognizeClipWithAnalyzer(job: ClipJob, language: TranscriptionLanguage, tempDir: URL,
                                           doneUnits: Int, totalUnits: Int) async throws -> [TimedToken]? {
        let locale = language.locale
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            return nil
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // 言語モデルの確認・導入
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                await updateUI(status: "音声認識モデルをダウンロード中…")
                try await request.downloadAndInstall()
            }
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            return nil
        }
        try checkCancelled()

        let clip = job.clip
        await updateUI(progress: Double(doneUnits) / Double(totalUnits),
                       status: "文字起こし中 \(doneUnits + 1)/\(totalUnits)")

        let fileURL = tempDir.appendingPathComponent("clip-\(clip.id.uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await exportAudio(from: clip.url, start: clip.startTime, end: clip.endTime, to: fileURL)
        try checkCancelled()

        let clipLength = max(0.001, clip.trimmedDuration)
        let unitCount = Double(job.chunks.count)

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            // 結果の収集は解析開始前に始めておく
            let collector = Task<[TimedToken], Error> { [weak self] in
                var tokens: [TimedToken] = []
                for try await result in transcriber.results {
                    let newTokens = TranscriptionService.tokens(from: result.text)
                    tokens.append(contentsOf: newTokens)
                    if let self, let lastEnd = newTokens.last?.end {
                        let fraction = min(max(lastEnd / clipLength, 0), 1)
                        let value = (Double(doneUnits) + fraction * unitCount) / Double(totalUnits)
                        await self.updateUI(progress: value, status: nil)
                    }
                }
                return tokens
            }

            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }

            let fileTokens = try await collector.value
            // ファイル先頭 = clip.startTime
            return fileTokens.map { token in
                TimedToken(text: token.text, start: clip.startTime + token.start, end: clip.startTime + token.end)
            }
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            return nil
        }
    }

    /// AttributedString の run ごとの audioTimeRange からトークンを組み立てる
    @available(iOS 26.0, *)
    private static func tokens(from text: AttributedString) -> [TimedToken] {
        var tokens: [TimedToken] = []
        var pendingPrefix = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            if let timeRange = run.audioTimeRange,
               timeRange.start.seconds.isFinite, timeRange.end.seconds.isFinite {
                let start = max(0, timeRange.start.seconds)
                let end = max(start, timeRange.end.seconds)
                tokens.append(TimedToken(text: pendingPrefix + piece, start: start, end: end))
                pendingPrefix = ""
            } else {
                // 時刻のない run(句読点・空白など)は前のトークンに付ける
                if tokens.isEmpty {
                    pendingPrefix += piece
                } else {
                    tokens[tokens.count - 1].text += piece
                }
            }
        }
        if !pendingPrefix.isEmpty, !tokens.isEmpty {
            tokens[0].text = pendingPrefix + tokens[0].text
        }
        return tokens
    }
    #endif

    // MARK: - iOS 18〜25: SFSpeechRecognizer(チャンク認識)

    /// クリップをチャンクごとに認識し、元素材上の秒に揃えたトークン列(クリップ全体)を返す
    private func recognizeClipWithSFSpeech(job: ClipJob, recognizer: SFSpeechRecognizer, tempDir: URL,
                                           doneUnits: Int, totalUnits: Int) async throws -> [TimedToken] {
        var tokens: [TimedToken] = []
        for (index, chunk) in job.chunks.enumerated() {
            try checkCancelled()
            let unit = doneUnits + index
            await updateUI(progress: Double(unit) / Double(totalUnits),
                           status: "文字起こし中 \(unit + 1)/\(totalUnits)")

            let fileURL = tempDir.appendingPathComponent("chunk-\(job.clip.id.uuidString)-\(index).m4a")
            try await exportAudio(from: job.clip.url, start: chunk.start, end: chunk.end, to: fileURL)
            try checkCancelled()

            var words = try await recognize(fileURL: fileURL, recognizer: recognizer)
            try? FileManager.default.removeItem(at: fileURL)
            try checkCancelled()

            words = Self.fixMissingTimestamps(words, chunkDuration: chunk.length)
            for word in words {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                tokens.append(TimedToken(text: text, start: chunk.start + word.start, end: chunk.start + word.end))
            }

            await updateUI(progress: Double(unit + 1) / Double(totalUnits), status: nil)
        }
        return tokens
    }

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

    // MARK: - 仕上げ

    /// 時刻順に並べ、クリップをまたぐ重なりを解消する
    private static func finalize(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var sorted = cues.sorted { $0.start < $1.start }
        if sorted.count > 1 {
            for i in 0..<(sorted.count - 1) where sorted[i].end > sorted[i + 1].start - 0.05 {
                sorted[i].end = max(sorted[i].start + 0.2, sorted[i + 1].start - 0.05)
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
