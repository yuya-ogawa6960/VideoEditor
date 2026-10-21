import Foundation
import AVFoundation
#if canImport(WhisperKit)
import WhisperKit
#endif

// =====================================================================
// Whisper(端末内)音声認識 — WhisperKit ラッパー
//
// - WhisperKit パッケージが解決できないビルドでも通るよう、利用箇所はすべて
//   `#if canImport(WhisperKit)` で囲む(その場合は `isAvailable == false`)
// - モデルは Application Support/WhisperKit 以下に保存(iCloud バックアップ対象外)
// - 入力音声は TranscriptionAudioExtractor で 16kHz モノラル WAV にしてから渡す
// - 長い音声は約 5 分ごとの「最も静かな所」で区切って順に認識し、進捗を返す
//   (各ピース内は WhisperKit の VAD チャンク分割に任せる)。31 分の音声なら 7 ピース。
//   ピースを短くしないのは意図的: VAD 分割と単語時刻は WhisperKit がピース内で行うので、ピースの境界は少ない方が
//   文の途中で切れにくく、ピースごとの準備(配列化・VAD)の無駄も少ない。ピースが長くて進捗が止まって見えないよう、
//   ピース内の進み具合を WhisperKit の Progress と処理速度から見積もって約 0.25 秒ごとに返す
// - モデルの読み込み(初回は CoreML の Neural Engine 向け特殊化で数分)の間は経過時間を状態文で返す
// - CoreML(GPU / Neural Engine)はバックグラウンドでは使えないので、画面ロックなどでバックグラウンドにいる間は
//   次のピースを始めず、フォアグラウンドに戻るまで待つ。認識中にバックグラウンドへ入ったら(進捗コールバックで気づいた時点で)
//   そのピースの推論を打ち切り、戻ってからやり直す。戻ってから結果や失敗が届いた場合も、ピースの前後で
//   BackgroundEpoch が変わっていればやり直す(やり直しは必ずフォアグラウンド待ちを通るので回数の上限は設けない)
// =====================================================================

enum WhisperTranscriberError: LocalizedError {
    case unavailable
    case modelNotReady
    case downloadFailed(String)
    case loadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Whisper エンジンはこのビルドに含まれていません(WhisperKit パッケージが未導入です)。設定で別のエンジンを選んでください。")
        case .modelNotReady:
            return String(localized: "Whisper モデルが読み込まれていません。")
        case .downloadFailed(let detail):
            return String(localized: "Whisper モデルのダウンロードに失敗しました: \(detail)")
        case .loadFailed(let detail):
            return String(localized: "Whisper モデルの読み込みに失敗しました: \(detail)")
        case .transcriptionFailed(let detail):
            return String(localized: "Whisper の音声認識に失敗しました: \(detail)")
        }
    }
}

final class WhisperTranscriber {
    static let shared = WhisperTranscriber()

    /// Hugging Face 上の CoreML モデルリポジトリ
    static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// WhisperKit がリンクされているか
    static var isAvailable: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    /// モデルの保存先(Application Support/WhisperKit)
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WhisperKit", isDirectory: true)
    }

    /// 1 回に WhisperKit へ渡す音声の長さ(秒)。進捗の単位でもある
    static let pieceSeconds: Double = 300
    /// 区切り位置の探索範囲(pieceSeconds の手前 lookBack 秒〜先 lookAhead 秒で最も静かな所)
    static let lookBackSeconds: Double = 10
    static let lookAheadSeconds: Double = 3

    private let lock = NSLock()
    private var loadedModel: String?
    private var stopRequested = false
    private var preparing = false
    /// 直近のモデル読み込みにかかった秒数(未読み込みなら nil。調査用)
    private(set) var lastLoadDuration: TimeInterval?
    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    private init() {}

    // MARK: - 状態

    var isModelReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(WhisperKit)
        return loadedModel != nil && whisperKit != nil
        #else
        return false
        #endif
    }

    /// 読み込み済みのモデル名(未読み込みなら nil)
    var loadedModelName: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadedModel
    }

    // MARK: - モデルファイルの管理

    /// モデルのフォルダ(WhisperKit/HubApi の配置規則: <base>/models/<repo>/<variant>)
    static func modelFolder(for model: String) -> URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepo, isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
    }

    func isModelDownloaded(_ model: String) -> Bool {
        let folder = Self.modelFolder(for: model)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return required.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// ダウンロード済みのモデル名(設定画面の一覧に含まれるもの)
    func downloadedModels() -> [String] {
        WhisperModelOption.all.map { $0.id }.filter { isModelDownloaded($0) }
    }

    /// 保存領域の合計サイズ(バイト)
    func downloadedSizeBytes() -> Int64 {
        Self.directorySize(Self.modelsDirectory)
    }

    /// ダウンロード済みモデルをすべて削除(読み込み済みなら解放もする)
    func deleteDownloadedModels() {
        unload()
        try? FileManager.default.removeItem(at: Self.modelsDirectory)
    }

    /// メモリ上のモデルを解放する(次回 prepare で再読み込み)
    func unload() {
        lock.lock()
        loadedModel = nil
        #if canImport(WhisperKit)
        whisperKit = nil
        #endif
        lock.unlock()
    }

    // MARK: - ダウンロード・読み込み

    /// モデルをダウンロードする(読み込みはしない)。progress は (0...1, 状態文)
    func download(model: String, progress: @escaping (Double, String) -> Void) async throws {
        #if canImport(WhisperKit)
        try await waitUntilIdle()
        setPreparing(true)
        defer { setPreparing(false) }

        try Self.prepareDirectory(Self.modelsDirectory)
        if isModelDownloaded(model) {
            progress(1, String(localized: "Whisperモデルはダウンロード済みです"))
            return
        }

        progress(0, "Whisperモデルをダウンロード中 0%")
        let reporter = WhisperProgressThrottle()
        do {
            _ = try await WhisperKit.download(variant: model,
                                              downloadBase: Self.modelsDirectory,
                                              progressCallback: { downloadProgress in
                                                  let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
                                                  if reporter.shouldReport(fraction) {
                                                      progress(fraction, "Whisperモデルをダウンロード中 \(Int(fraction * 100))%")
                                                  }
                                              })
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw WhisperTranscriberError.downloadFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard isModelDownloaded(model) else {
            throw WhisperTranscriberError.downloadFailed(String(localized: "モデルファイルが見つかりません"))
        }
        progress(1, String(localized: "Whisperモデルのダウンロードが完了しました"))
        #else
        throw WhisperTranscriberError.unavailable
        #endif
    }

    /// モデルをダウンロード(必要なら)して読み込む。progress は (0...1, 状態文)
    func prepare(model: String, progress: @escaping (Double, String) -> Void) async throws {
        #if canImport(WhisperKit)
        if isModelReady, loadedModelName == model { return }

        try await download(model: model, progress: progress)
        try Task.checkCancellation()

        try await waitUntilIdle()
        setPreparing(true)
        defer { setPreparing(false) }

        unload()
        // 読み込み(CoreML の Neural Engine 向け特殊化を含む)は初回に数分かかり、その間は進捗が取れない。
        // 止まっていると思われないよう、20 秒を過ぎたら経過時間を 5 秒ごとに添えて知らせる
        let loadingText = String(localized: "Whisperモデルを準備中(初回のみ数分かかります)…")
        progress(1, loadingText)
        let loadStart = Date()
        let ticker = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(loadStart)
                progress(1, loadingText + String(localized: " — 経過 ") + Self.elapsedText(elapsed))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        defer { ticker.cancel() }

        let folder = Self.modelFolder(for: model)
        let config = WhisperKitConfig(model: model,
                                      downloadBase: Self.modelsDirectory,
                                      modelFolder: folder.path)
        config.tokenizerFolder = Self.modelsDirectory
        config.verbose = false
        config.logLevel = .error
        config.prewarm = false
        config.load = true
        config.download = false

        do {
            let kit = try await WhisperKit(config)
            ticker.cancel()
            lock.lock()
            whisperKit = kit
            loadedModel = model
            lastLoadDuration = Date().timeIntervalSince(loadStart)
            lock.unlock()
        } catch {
            ticker.cancel()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw WhisperTranscriberError.loadFailed(error.localizedDescription)
        }
        #else
        throw WhisperTranscriberError.unavailable
        #endif
    }

    // MARK: - 認識

    /// 音声ファイル全体を認識し、ファイル先頭からの秒のトークン列を返す。
    /// language は "ja" / "en" など ISO 639-1。
    func transcribe(audioURL: URL, language: String,
                    progress: @escaping (Double) -> Void) async throws -> [TimedToken] {
        try await transcribe(sourceURL: audioURL, start: 0, end: nil, language: language) { update in
            progress(update.fraction)
        }
    }

    /// 長さ seconds の音声を何ピースに分けるかの見込み(実際の区切りは静かな所なので ±1 ずれることがある)
    static func estimatedPieceCount(seconds: Double) -> Int {
        guard seconds > 0 else { return 1 }
        var remaining = seconds
        var count = 1
        while remaining > pieceSeconds + lookAheadSeconds {
            remaining -= pieceSeconds
            count += 1
        }
        return count
    }

    /// 経過時間の表示(「45秒」「1分20秒」「1時間2分」)
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return "\(total / 3600)時間\((total % 3600) / 60)分"
        }
        if total >= 60 {
            return "\(total / 60)分\(total % 60)秒"
        }
        return String(localized: "\(total)秒")
    }

    /// 元素材 sourceURL の start〜end(秒。end が nil なら末尾まで)を認識し、
    /// 元素材上の秒に揃えたトークン列を返す。
    /// バックグラウンド中は次のピースを始めずに待つ(待っている間は pauseReporter に伝える)。
    /// progress はピースの開始・完了時と、認識中は約 0.25 秒ごとに呼ばれる(任意のスレッドから)
    func transcribe(sourceURL: URL, start: Double, end: Double?, language: String,
                    pauseReporter: BackgroundPauseReporter? = nil,
                    progress: @escaping (WhisperTranscriptionProgress) -> Void) async throws -> [TimedToken] {
        #if canImport(WhisperKit)
        guard let kit = currentKit() else { throw WhisperTranscriberError.modelNotReady }
        // 認識の途中でバックグラウンドへ入ったかを判定できるように、監視を始めておく
        await BackgroundEpoch.install()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let extracted = try await TranscriptionAudioExtractor.extract(from: sourceURL, start: start, end: end,
                                                                      to: tempURL, format: .wav16kMono)
        try Task.checkCancellation()

        let file = try AVAudioFile(forReading: tempURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, format.channelCount >= 1 else {
            throw WhisperTranscriberError.transcriptionFailed(String(localized: "音声形式を読み取れません"))
        }
        let totalFrames = file.length
        guard totalFrames > 0 else { return [] }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.wordTimestamps = true
        options.skipSpecialTokens = true
        options.chunkingStrategy = .vad

        setStop(false)
        let pieceFrames = AVAudioFramePosition(Self.pieceSeconds * sampleRate)
        let lookBack = AVAudioFramePosition(Self.lookBackSeconds * sampleRate)
        let lookAhead = AVAudioFramePosition(Self.lookAheadSeconds * sampleRate)
        let energyWindow = max(1, Int(sampleRate * 0.1))

        var tokens: [TimedToken] = []
        var position: AVAudioFramePosition = 0

        // 進捗の集計(ピース数・処理済みの音声秒・推論にかかった秒)
        let totalAudioSeconds = Double(totalFrames) / sampleRate
        var totalPieces = Self.estimatedPieceCount(seconds: totalAudioSeconds)
        var completedPieces = 0
        var processedAudioSeconds = 0.0
        /// 完了したピースの推論にかかった秒の合計(フォアグラウンド待ち・やり直した分は含めない)
        var activeSeconds = 0.0
        progress(WhisperTranscriptionProgress(completedPieces: 0, totalPieces: totalPieces, fractionInPiece: 0,
                                              processedAudioSeconds: 0, currentPieceAudioSeconds: 0,
                                              totalAudioSeconds: totalAudioSeconds, activeSeconds: 0,
                                              currentPieceElapsed: 0))

        try await withTaskCancellationHandler {
            while position < totalFrames {
                try Task.checkCancellation()
                if isStopRequested { throw CancellationError() }
                // バックグラウンドでは推論(GPU / Neural Engine)を始めない。フォアグラウンドに戻るまで待つ
                try await AppForegroundWaiter.wait(reporter: pauseReporter)
                if isStopRequested { throw CancellationError() }

                let remaining = totalFrames - position
                let wantFrames = min(remaining, pieceFrames + lookAhead)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wantFrames)) else {
                    throw WhisperTranscriberError.transcriptionFailed(String(localized: "音声バッファを確保できません"))
                }
                file.framePosition = position
                try file.read(into: buffer, frameCount: AVAudioFrameCount(wantFrames))
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { break }

                var samples = Self.monoSamples(from: buffer)
                var cut = frames
                if remaining > pieceFrames + lookAhead {
                    let from = max(0, Int(pieceFrames - lookBack))
                    let to = min(frames, Int(pieceFrames + lookAhead))
                    cut = Self.quietestIndex(in: samples, from: from, to: to, windowSize: energyWindow)
                    cut = min(max(cut, 1), frames)
                    if cut < frames { samples.removeSubrange(cut..<frames) }
                }

                let pieceStart = Double(position) / sampleRate
                let pieceTokens: [TimedToken]
                /// このピースの認識中にバックグラウンドへ入ったか(進捗コールバックで立てる)
                let backgroundFlag = WhisperBackgroundFlag()
                /// ピースの前後で変わったら、その間にバックグラウンドへ入った(一時停止だけで戻った場合も含む)
                let epochBefore = BackgroundEpoch.current

                // ピース内の進捗: WhisperKit の kit.progress(呼び出しをまたいで積み上がることがあるので開始時との差分)と、
                // それまでのピースの処理速度からの時間見積もりの大きい方。約 0.25 秒ごとに知らせる
                let pieceAudioSeconds = Double(cut) / sampleRate
                let knownRate = processedAudioSeconds > 0 && activeSeconds > 0
                let rate = knownRate ? activeSeconds / processedAudioSeconds : WhisperPieceTracker.guessedSecondsPerAudioSecond
                let baseProgress = kit.progress
                let tracker = WhisperPieceTracker(
                    base: WhisperTranscriptionProgress(completedPieces: completedPieces, totalPieces: totalPieces,
                                                       fractionInPiece: 0,
                                                       processedAudioSeconds: processedAudioSeconds,
                                                       currentPieceAudioSeconds: pieceAudioSeconds,
                                                       totalAudioSeconds: totalAudioSeconds,
                                                       activeSeconds: activeSeconds, currentPieceElapsed: 0),
                    expectedSeconds: max(1, rate * pieceAudioSeconds),
                    timeEstimateCap: knownRate ? 0.95 : 0.8,
                    baseProgress: baseProgress,
                    baseFraction: baseProgress.fractionCompleted)
                let sampler = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if Task.isCancelled { break }
                        tracker.sample(current: kit.progress, report: progress)
                    }
                }

                do {
                    let results = try await kit.transcribe(audioArray: samples,
                                                           decodeOptions: options,
                                                           callback: { [weak self] _ in
                                                               if self?.isStopRequested == true { return false }
                                                               // バックグラウンドへ入った → 推論を打ち切る(新しい窓も始めない)。戻ってからやり直す
                                                               if AppLifecycle.shared.isInBackground {
                                                                   backgroundFlag.set()
                                                                   return false
                                                               }
                                                               return nil
                                                           })
                    sampler.cancel()
                    tracker.finish()
                    pieceTokens = Self.tokens(from: results, offset: extracted.startOffset + pieceStart)
                } catch {
                    sampler.cancel()
                    tracker.finish()
                    if error is CancellationError || Task.isCancelled || isStopRequested { throw CancellationError() }
                    // 認識中にバックグラウンドへ入って失敗した(戻ってから失敗が届いた場合も含む)
                    // → ループの先頭で戻るまで待ち、同じピースをやり直す
                    if backgroundFlag.isSet || AppLifecycle.shared.isInBackground || BackgroundEpoch.current != epochBefore {
                        continue
                    }
                    throw error
                }
                if isStopRequested { throw CancellationError() }
                // 認識の途中でバックグラウンドへ入った(打ち切った・GPU が使えず結果が欠けている可能性がある) → 戻ってからやり直す
                if backgroundFlag.isSet || AppLifecycle.shared.isInBackground || BackgroundEpoch.current != epochBefore {
                    continue
                }
                tokens.append(contentsOf: pieceTokens)

                position += AVAudioFramePosition(cut)
                completedPieces += 1
                processedAudioSeconds += pieceAudioSeconds
                activeSeconds += tracker.elapsed
                let remainingSeconds = Double(max(0, totalFrames - position)) / sampleRate
                totalPieces = completedPieces + (position < totalFrames ? Self.estimatedPieceCount(seconds: remainingSeconds) : 0)
                progress(WhisperTranscriptionProgress(completedPieces: completedPieces, totalPieces: totalPieces,
                                                      fractionInPiece: 0,
                                                      processedAudioSeconds: processedAudioSeconds,
                                                      currentPieceAudioSeconds: 0,
                                                      totalAudioSeconds: totalAudioSeconds,
                                                      activeSeconds: activeSeconds, currentPieceElapsed: 0))
            }
        } onCancel: { [weak self] in
            self?.setStop(true)
        }

        tokens.sort { $0.start < $1.start }
        return tokens
        #else
        throw WhisperTranscriberError.unavailable
        #endif
    }

    // MARK: - WhisperKit 結果 → TimedToken

    #if canImport(WhisperKit)
    private static func tokens(from results: [TranscriptionResult], offset: Double) -> [TimedToken] {
        var tokens: [TimedToken] = []
        for result in results {
            for segment in result.segments {
                let segmentStart = offset + Double(segment.start)
                let segmentEnd = offset + Double(segment.end)
                let words: [WordTiming] = segment.words ?? []
                var added = 0
                for word in words {
                    let text = cleanText(word.word)
                    guard !text.isEmpty else { continue }
                    let start = offset + Double(word.start)
                    let end = offset + Double(word.end)
                    tokens.append(TimedToken(text: text, start: start, end: max(start, end)))
                    added += 1
                }
                if added == 0 {
                    // 単語時刻が無い → セグメント単位(SubtitleSegmenter が文字数比で時刻を配る)
                    let text = cleanText(segment.text)
                    guard !text.isEmpty else { continue }
                    tokens.append(TimedToken(text: text, start: segmentStart, end: max(segmentStart, segmentEnd)))
                }
            }
        }
        return tokens
    }

    private func currentKit() -> WhisperKit? {
        lock.lock()
        defer { lock.unlock() }
        return whisperKit
    }
    #endif

    /// 特殊トークン(<|ja|> <|0.00|> など)を除いて前後の空白を落とす
    private static func cleanText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 音声ユーティリティ

    /// バッファをモノラル Float 配列にする(複数チャンネルなら平均)
    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let channels = max(1, Int(buffer.format.channelCount))
        if let floatData = buffer.floatChannelData {
            if channels == 1 {
                return Array(UnsafeBufferPointer(start: floatData[0], count: frames))
            }
            var result = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                let pointer = floatData[c]
                for i in 0..<frames { result[i] += pointer[i] }
            }
            let scale = 1 / Float(channels)
            for i in 0..<frames { result[i] *= scale }
            return result
        }
        if let int16Data = buffer.int16ChannelData {
            let pointer = int16Data[0]
            var result = [Float](repeating: 0, count: frames)
            if buffer.format.isInterleaved, channels > 1 {
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(pointer[i * channels + c]) }
                    result[i] = sum / Float(channels) / 32768
                }
            } else {
                for i in 0..<frames { result[i] = Float(pointer[i]) / 32768 }
            }
            return result
        }
        return []
    }

    /// from..<to の中で、windowSize サンプルのエネルギーが最小になる窓の中央の添字
    private static func quietestIndex(in samples: [Float], from: Int, to: Int, windowSize: Int) -> Int {
        let lo = max(0, from)
        let hi = min(samples.count, to)
        guard windowSize > 0, hi - lo >= windowSize * 2 else { return hi }
        var best = hi
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = lo
        let step = max(1, windowSize / 2)
        while i + windowSize <= hi {
            var energy: Float = 0
            for j in i..<(i + windowSize) {
                let v = samples[j]
                energy += v * v
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = i + windowSize / 2
            }
            i += step
        }
        return best
    }

    // MARK: - 状態管理

    private var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func setStop(_ value: Bool) {
        lock.lock()
        stopRequested = value
        lock.unlock()
    }

    private var isPreparing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preparing
    }

    private func setPreparing(_ value: Bool) {
        lock.lock()
        preparing = value
        lock.unlock()
    }

    /// 別の prepare/download が走っていれば終わるまで待つ
    private func waitUntilIdle() async throws {
        while isPreparing {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func prepareDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// WhisperTranscriber.transcribe の進捗(1 回の呼び出し = 1 クリップ分)
struct WhisperTranscriptionProgress {
    /// 認識が終わったピース数
    var completedPieces: Int
    /// 全ピース数(見込み。区切りは静かな所なので途中で ±1 変わることがある)
    var totalPieces: Int
    /// 認識中のピースの進み具合(0...1。ピースの合間は 0)
    var fractionInPiece: Double
    /// 認識が終わったピースの音声の長さ(秒)の合計
    var processedAudioSeconds: Double
    /// 認識中のピースの音声の長さ(秒。ピースの合間は 0)
    var currentPieceAudioSeconds: Double
    /// この呼び出しで認識する音声全体の長さ(秒)
    var totalAudioSeconds: Double
    /// 完了したピースの推論にかかった秒の合計(フォアグラウンド待ち・やり直しは含めない)
    var activeSeconds: Double
    /// 認識中のピースを始めてからの秒
    var currentPieceElapsed: Double

    /// この呼び出し全体の進み具合(音声の長さの比。0...1)
    var fraction: Double {
        guard totalAudioSeconds > 0 else { return 0 }
        let done = processedAudioSeconds + min(max(fractionInPiece, 0), 1) * currentPieceAudioSeconds
        return min(max(done / totalAudioSeconds, 0), 1)
    }
}

/// 1 ピースの認識中の進捗の見積もり(タイマーから呼ぶ。スレッドセーフ)。
/// finish() のあとは何も知らせない(完了の通知より後に古い進捗が届かないよう、知らせるのはロックの中)
private final class WhisperPieceTracker: @unchecked Sendable {
    /// まだ処理速度が分からない最初のピースで仮に使う「音声 1 秒あたりの推論秒」
    static let guessedSecondsPerAudioSecond: Double = 0.3

    private let lock = NSLock()
    private let base: WhisperTranscriptionProgress
    private let startedAt = Date()
    private let expectedSeconds: Double
    private let timeEstimateCap: Double
    private let baseProgress: Progress
    private let baseFraction: Double
    private var fraction: Double = 0
    private var done = false

    init(base: WhisperTranscriptionProgress, expectedSeconds: Double, timeEstimateCap: Double,
         baseProgress: Progress, baseFraction: Double) {
        self.base = base
        self.expectedSeconds = expectedSeconds
        self.timeEstimateCap = timeEstimateCap
        self.baseProgress = baseProgress
        self.baseFraction = baseFraction
    }

    /// ピースを始めてからの秒
    var elapsed: Double {
        Date().timeIntervalSince(startedAt)
    }

    /// current は今の kit.progress(WhisperKit は完了・キャンセル時に新しい Progress に差し替える)
    func sample(current: Progress, report: (WhisperTranscriptionProgress) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        let elapsedSeconds = elapsed

        // WhisperKit の進捗(同じ Progress のままなら開始時からの差分、差し替わっていればそのまま)
        var fromKit: Double = 0
        let raw = current.fractionCompleted
        if raw.isFinite {
            if current === baseProgress {
                if baseFraction < 0.999 {
                    fromKit = (raw - baseFraction) / (1 - baseFraction)
                }
            } else {
                fromKit = raw
            }
        }
        fromKit = min(max(fromKit, 0), 0.99)

        // 時間からの見積もり(これまでのピースの処理速度。最初のピースは仮の速度で控えめに)
        let fromTime = min(timeEstimateCap, elapsedSeconds / max(expectedSeconds, 1))

        // 後戻りさせない
        fraction = max(fraction, fromKit, fromTime)

        var update = base
        update.fractionInPiece = fraction
        update.currentPieceElapsed = elapsedSeconds
        report(update)
    }

    func finish() {
        lock.lock()
        done = true
        lock.unlock()
    }
}

/// 1 ピースの認識中にバックグラウンドへ入ったかの印(WhisperKit の進捗コールバックから立てる。スレッドセーフ)
private final class WhisperBackgroundFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// 進捗コールバックの間引き(1% 刻み)
private final class WhisperProgressThrottle {
    private let lock = NSLock()
    private var last: Double = -1

    func shouldReport(_ value: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value >= 1, last < 1 {
            last = value
            return true
        }
        if value - last >= 0.01 {
            last = value
            return true
        }
        return false
    }
}

// =====================================================================
// 音声の切り出し(16kHz モノラル)
//
// AVAssetReaderAudioMixOutput でデコード+リサンプル+モノラル化し、
// AVAssetWriter で WAV(16bit PCM)または M4A(AAC 16kHz モノラル)に書き出す。
// Whisper(端末内)は WAV、クラウド送信は小さい M4A を使う。
// =====================================================================

enum TranscriptionAudioExtractionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let detail):
            return String(localized: "音声の切り出しに失敗しました: \(detail)")
        }
    }
}

enum TranscriptionAudioExtractor {
    enum Format {
        case wav16kMono
        case m4a16kMono
    }

    struct Output {
        let url: URL
        /// ファイル先頭(0 秒)に対応する元素材上の秒
        let startOffset: Double
        /// ファイルのおおよその長さ(秒)
        let duration: Double
        let fileSize: Int64
    }

    static let sampleRate: Double = 16_000

    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// AAC 16kHz モノラル。ビットレートはエンコーダ既定(16kHz モノラルでは数十 kbps)に任せる
    /// — 範囲外の値を指定すると AVAssetWriterInput が例外を投げるため、明示しない
    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
    ]

    /// sourceURL(動画または音声)の start〜end 秒を outputURL に書き出す。end が nil なら末尾まで
    static func extract(from sourceURL: URL, start: Double, end: Double?,
                        to outputURL: URL, format: Format) async throws -> Output {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionAudioExtractionError.failed(String(localized: "音声トラックがありません"))
        }
        let assetDuration = try await asset.load(.duration).seconds
        let rangeStart = max(0, start)
        var rangeEnd = end ?? assetDuration
        if assetDuration.isFinite, assetDuration > 0 {
            rangeEnd = min(rangeEnd, assetDuration)
        }
        guard rangeEnd.isFinite, rangeEnd > rangeStart + 0.05 else {
            throw TranscriptionAudioExtractionError.failed(String(localized: "音声の範囲が短すぎます"))
        }
        try? FileManager.default.removeItem(at: outputURL)
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscriptionAudioExtractionError.failed(String(localized: "音声を読み取れません"))
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: rangeStart, preferredTimescale: 600),
                                       end: CMTime(seconds: rangeEnd, preferredTimescale: 600))

        let fileType: AVFileType = (format == .wav16kMono) ? .wav : .m4a
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let writerSettings: [String: Any] = (format == .wav16kMono) ? pcmSettings : aacSettings
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw TranscriptionAudioExtractionError.failed(String(localized: "書き出し形式に対応していません"))
        }
        writer.add(input)

        guard reader.startReading() else {
            throw TranscriptionAudioExtractionError.failed(reader.error?.localizedDescription ?? String(localized: "読み込みを開始できません"))
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscriptionAudioExtractionError.failed(writer.error?.localizedDescription ?? String(localized: "書き出しを開始できません"))
        }

        let state = ExtractionState()
        let queue = DispatchQueue(label: "VideoEditor.TranscriptionAudioExtractor")

        let firstTime: Double = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if state.isCancelled {
                            reader.cancelReading()
                            input.markAsFinished()
                            writer.cancelWriting()
                            if state.claimResume() { continuation.resume(throwing: CancellationError()) }
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            if reader.status == .failed {
                                writer.cancelWriting()
                                if state.claimResume() {
                                    continuation.resume(throwing: TranscriptionAudioExtractionError.failed(
                                        reader.error?.localizedDescription ?? String(localized: "読み込みに失敗しました")))
                                }
                            } else if reader.status == .cancelled || state.isCancelled {
                                writer.cancelWriting()
                                if state.claimResume() { continuation.resume(throwing: CancellationError()) }
                            } else if !state.started {
                                writer.cancelWriting()
                                if state.claimResume() {
                                    continuation.resume(throwing: TranscriptionAudioExtractionError.failed(String(localized: "音声が空です")))
                                }
                            } else {
                                let first = state.firstTime
                                writer.finishWriting {
                                    if writer.status == .completed {
                                        if state.claimResume() { continuation.resume(returning: first) }
                                    } else if state.claimResume() {
                                        continuation.resume(throwing: TranscriptionAudioExtractionError.failed(
                                            writer.error?.localizedDescription ?? String(localized: "書き出しに失敗しました")))
                                    }
                                }
                            }
                            return
                        }
                        if !state.started {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            let seconds = pts.seconds
                            state.markStarted(firstTime: seconds.isFinite ? seconds : rangeStart)
                            writer.startSession(atSourceTime: pts)
                        }
                        if !input.append(sample) {
                            reader.cancelReading()
                            input.markAsFinished()
                            let message = writer.error?.localizedDescription ?? String(localized: "書き出しに失敗しました")
                            writer.cancelWriting()
                            if state.claimResume() {
                                continuation.resume(throwing: TranscriptionAudioExtractionError.failed(message))
                            }
                            return
                        }
                    }
                }
            }
        } onCancel: {
            state.cancel()
            reader.cancelReading()
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw TranscriptionAudioExtractionError.failed(String(localized: "書き出したファイルが空です"))
        }
        return Output(url: outputURL, startOffset: firstTime, duration: max(0, rangeEnd - firstTime), fileSize: size)
    }

    /// 切り出し中の共有状態(スレッドセーフ)
    private final class ExtractionState {
        private let lock = NSLock()
        private var cancelled = false
        private var resumed = false
        private var startedFlag = false
        private var first: Double = 0

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        func claimResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }

        var started: Bool {
            lock.lock(); defer { lock.unlock() }
            return startedFlag
        }

        var firstTime: Double {
            lock.lock(); defer { lock.unlock() }
            return first
        }

        func markStarted(firstTime: Double) {
            lock.lock()
            startedFlag = true
            first = firstTime
            lock.unlock()
        }
    }
}
