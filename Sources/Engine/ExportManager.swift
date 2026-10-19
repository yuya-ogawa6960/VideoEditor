import Foundation
import AVFoundation
import CoreMedia
import UIKit
import Photos
import UserNotifications
import BackgroundTasks
import Observation

// =====================================================================
// 動画の書き出し。
//
// パイプライン: AVAssetReader(合成) → AVAssetWriter(.mp4)
//   映像: AVAssetReaderVideoCompositionOutput(32BGRA, カスタムコンポジタ) → H.264 / HEVC
//   音声: AVAssetReaderAudioMixOutput(LPCM, .spectral) → AAC 48kHz 2ch 192kbps
//
// バックグラウンド:
//   - 書き出し全体を UIApplication.beginBackgroundTask で包む。
//   - iOS 26 以降は BGContinuedProcessingTaskRequest も submit し、システム UI に進捗を出しつつ
//     バックグラウンドでも書き出しを続けられる(AppLifecycle.start() でハンドラ登録済み)。
//   - iOS 26 未満では、バックグラウンドに移ってから iOS が許すのは約 30 秒だけ。長い書き出しは
//     その時間内に終わらないので、時間切れ(expirationHandler)で書き出しを安全に中断し、
//     `.failed("バックグラウンドの時間制限で中断しました。…")` にする(クラッシュさせない)。
//     中途半端な mp4 は再生できないため削除するが、progress は中断時点の値を残す。
// =====================================================================

/// ExportManager が投げるエラー
enum ExportManagerError: LocalizedError {
    case noOutput
    case photosAccessDenied

    var errorDescription: String? {
        switch self {
        case .noOutput: return "書き出したファイルがありません"
        case .photosAccessDenied: return "写真ライブラリへの保存が許可されていません。設定アプリから許可してください"
        }
    }
}

@Observable
final class ExportManager {
    static let shared = ExportManager()

    enum State: Equatable {
        case idle, preparing, exporting, finished, failed(String), cancelled
    }

    private(set) var state: State = .idle
    /// 0...1
    private(set) var progress: Double = 0
    private(set) var isRunning: Bool = false
    private(set) var lastOutputURL: URL?
    private(set) var savedToPhotos: Bool = false
    /// ユーザー向けの状態表示(日本語)
    private(set) var statusText: String = "待機中"

    // 以下はメインスレッドからのみ触る
    @ObservationIgnored private var currentPipeline: ExportPipeline?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var expiredInBackground = false
    @ObservationIgnored private var continuedTaskExpired = false
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier?
    /// iOS 26+ の BGContinuedProcessingTask(型を iOS 18 でも扱えるよう AnyObject で保持)
    @ObservationIgnored private var continuedTask: AnyObject?
    @ObservationIgnored private var didRequestNotificationAuthorization = false

    // 進捗の間引き(任意スレッドから)
    private let progressLock = NSLock()
    @ObservationIgnored private var lastProgressReport: CFAbsoluteTime = 0

    private init() {}

    // MARK: - Public API

    func start(snapshot: ProjectSnapshot, saveToPhotos: Bool) {
        exportOnMain { [weak self] in
            self?.startOnMain(snapshot: snapshot, saveToPhotos: saveToPhotos)
        }
    }

    func cancel() {
        exportOnMain { [weak self] in
            self?.cancelOnMain(dueToBackgroundLimit: false)
        }
    }

    func saveLastOutputToPhotos() async throws {
        let url: URL? = await MainActor.run { self.lastOutputURL }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw ExportManagerError.noOutput
        }
        try await Self.saveVideoToPhotos(url)
        await MainActor.run {
            self.savedToPhotos = true
            self.statusText = "写真に保存しました"
        }
    }

    // MARK: - Main-thread helpers

    /// メインスレッドで実行(すでにメインなら同期的に実行)
    private func exportOnMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                work()
            }
        } else {
            Task { @MainActor in
                work()
            }
        }
    }

    @MainActor
    private func startOnMain(snapshot: ProjectSnapshot, saveToPhotos: Bool) {
        guard !isRunning else { return }

        guard !snapshot.isEmpty, snapshot.totalDuration > 0 else {
            let message = "書き出すクリップがありません"
            state = .failed(message)
            statusText = message
            return
        }

        // 空き容量チェック
        let estimate = StorageEstimator.estimate(for: snapshot)
        guard estimate.canExport else {
            let message = "空き容量が不足しています(必要: \(StorageEstimator.formatBytes(estimate.requiredBytes)) / 空き: \(StorageEstimator.formatBytes(estimate.availableBytes)))"
            state = .failed(message)
            statusText = message
            return
        }

        isRunning = true
        state = .preparing
        progress = 0
        savedToPhotos = false
        lastOutputURL = nil
        statusText = "書き出しの準備中…"
        cancelRequested = false
        expiredInBackground = false
        continuedTaskExpired = false
        currentPipeline = nil
        progressLock.lock()
        lastProgressReport = 0
        progressLock.unlock()

        requestNotificationAuthorizationIfNeeded()
        if saveToPhotos {
            // 許可ダイアログはフォアグラウンドでしか出せないので、先に聞いておく
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
        beginBackgroundWork()
        submitContinuedProcessingRequest()

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runExport(snapshot: snapshot, saveToPhotos: saveToPhotos)
        }
    }

    @MainActor
    private func cancelOnMain(dueToBackgroundLimit: Bool) {
        guard isRunning else { return }
        if dueToBackgroundLimit {
            expiredInBackground = true
        }
        cancelRequested = true
        statusText = "キャンセルしています…"
        currentPipeline?.cancel()
    }

    // MARK: - Export flow (background)

    private func runExport(snapshot: ProjectSnapshot, saveToPhotos: Bool) async {
        let outputURL: URL
        do {
            outputURL = try Self.makeOutputURL()
        } catch {
            let message = "書き出し先フォルダを作成できませんでした: \(error.localizedDescription)"
            await MainActor.run { self.finishFailed(message, outputURL: nil) }
            return
        }

        let built: BuiltComposition
        do {
            built = try await CompositionBuilder.build(snapshot, purpose: .export)
        } catch {
            let message = "映像の構成に失敗しました: \(error.localizedDescription)"
            await MainActor.run {
                if self.cancelRequested {
                    self.finishCancelled(outputURL: outputURL)
                } else {
                    self.finishFailed(message, outputURL: outputURL)
                }
            }
            return
        }

        let pipeline = ExportPipeline(built: built,
                                      outputURL: outputURL,
                                      videoBitrate: StorageEstimator.videoBitrate(for: snapshot),
                                      preferHEVC: StorageEstimator.usesHEVC(for: snapshot),
                                      frameRate: max(1, snapshot.canvas.frameRate),
                                      onProgress: { [weak self] value in
                                          self?.pipelineReportedProgress(value)
                                      })

        let proceed: Bool = await MainActor.run {
            if self.cancelRequested { return false }
            self.currentPipeline = pipeline
            self.state = .exporting
            self.statusText = "書き出し中… 0%"
            return true
        }
        guard proceed else {
            await MainActor.run { self.finishCancelled(outputURL: outputURL) }
            return
        }

        let outcome = await pipeline.run()

        switch outcome {
        case .completed:
            var saved = false
            var photoError: Error?
            if saveToPhotos {
                do {
                    try await Self.saveVideoToPhotos(outputURL)
                    saved = true
                } catch {
                    photoError = error
                }
            }
            let savedResult = saved
            let photoErrorResult = photoError
            await MainActor.run {
                self.finishSucceeded(outputURL: outputURL, saved: savedResult, photoError: photoErrorResult)
            }
        case .cancelled:
            await MainActor.run { self.finishCancelled(outputURL: outputURL) }
        case .failed(let error):
            let message = "書き出しに失敗しました: \(error.localizedDescription)"
            await MainActor.run { self.finishFailed(message, outputURL: outputURL) }
        }
    }

    // MARK: - Finish (main)

    private static let backgroundLimitMessage = "バックグラウンドの時間制限で中断しました。アプリを開いたまま再度書き出してください"

    @MainActor
    private func finishSucceeded(outputURL: URL, saved: Bool, photoError: Error?) {
        currentPipeline = nil
        lastOutputURL = outputURL
        progress = 1
        savedToPhotos = saved
        state = .finished
        isRunning = false
        if let photoError {
            statusText = "書き出し完了(写真への保存に失敗: \(photoError.localizedDescription))"
        } else if saved {
            statusText = "書き出し完了・写真に保存しました"
        } else {
            statusText = "書き出し完了"
        }
        if AppLifecycle.shared.isInBackground {
            Self.postLocalNotification(title: "書き出し完了",
                                       body: saved ? "動画を書き出して写真に保存しました" : "動画の書き出しが完了しました")
        }
        endBackgroundWork(success: true)
    }

    @MainActor
    private func finishCancelled(outputURL: URL?) {
        currentPipeline = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        isRunning = false
        if expiredInBackground {
            state = .failed(Self.backgroundLimitMessage)
            statusText = Self.backgroundLimitMessage
            if AppLifecycle.shared.isInBackground {
                Self.postLocalNotification(title: "書き出しが中断されました",
                                           body: "アプリを開いたまま再度書き出してください")
            }
        } else {
            state = .cancelled
            statusText = continuedTaskExpired ? "システムにより書き出しが停止されました" : "書き出しをキャンセルしました"
        }
        endBackgroundWork(success: false)
    }

    @MainActor
    private func finishFailed(_ message: String, outputURL: URL?) {
        currentPipeline = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        isRunning = false
        // iOS 26 未満でバックグラウンド中に失敗した場合は、時間制限 / GPU 制限による中断とみなす
        let backgroundInterrupted = expiredInBackground
            || (AppLifecycle.shared.isInBackground && continuedTask == nil)
        let finalMessage = backgroundInterrupted ? Self.backgroundLimitMessage : message
        state = .failed(finalMessage)
        statusText = finalMessage
        if AppLifecycle.shared.isInBackground {
            Self.postLocalNotification(title: "書き出しに失敗しました", body: finalMessage)
        }
        endBackgroundWork(success: false)
    }

    // MARK: - Progress

    /// パイプラインのキューから呼ばれる。UI 更新は 0.15 秒ごとに間引く。
    private func pipelineReportedProgress(_ value: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        progressLock.lock()
        let shouldReport = value >= 1 || now - lastProgressReport >= 0.15
        if shouldReport {
            lastProgressReport = now
        }
        progressLock.unlock()
        guard shouldReport else { return }
        let clamped = min(max(value, 0), 1)
        exportOnMain { [weak self] in
            self?.applyProgress(clamped)
        }
    }

    @MainActor
    private func applyProgress(_ value: Double) {
        guard isRunning, state == .exporting, !cancelRequested else { return }
        progress = value
        statusText = "書き出し中… \(Int((value * 100).rounded(.down)))%"
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = 1000
            task.progress.completedUnitCount = Int64(value * 1000)
        }
        #endif
    }

    // MARK: - Background execution

    @MainActor
    private func beginBackgroundWork() {
        if let existing = backgroundTaskID {
            UIApplication.shared.endBackgroundTask(existing)
            backgroundTaskID = nil
        }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "VideoExport") {
            ExportManager.shared.backgroundTimeExpired()
        }
        backgroundTaskID = (identifier == .invalid) ? nil : identifier
    }

    /// beginBackgroundTask の時間切れ(メインスレッドで呼ばれる)
    private func backgroundTimeExpired() {
        exportOnMain { [weak self] in
            self?.handleBackgroundTimeExpired()
        }
    }

    @MainActor
    private func handleBackgroundTimeExpired() {
        // iOS 26 で BGContinuedProcessingTask が動いていれば書き出しは継続できる。
        // それ以外(iOS 26 未満など)は約 30 秒の猶予しかないため、ここで安全に中断する。
        if continuedTask == nil && isRunning {
            cancelOnMain(dueToBackgroundLimit: true)
        }
        if let id = backgroundTaskID {
            UIApplication.shared.endBackgroundTask(id)
            backgroundTaskID = nil
        }
    }

    @MainActor
    private func endBackgroundWork(success: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            if success {
                task.progress.totalUnitCount = 1000
                task.progress.completedUnitCount = 1000
            }
            task.setTaskCompleted(success: success)
        }
        #endif
        continuedTask = nil
        if let id = backgroundTaskID {
            UIApplication.shared.endBackgroundTask(id)
            backgroundTaskID = nil
        }
    }

    @MainActor
    private func submitContinuedProcessingRequest() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let request = BGContinuedProcessingTaskRequest(identifier: AppLifecycle.exportTaskIdentifier,
                                                           title: "動画を書き出し中",
                                                           subtitle: "書き出しが終わるまでお待ちください")
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // submit に失敗しても beginBackgroundTask のフォールバックで続行する
            }
        }
        #endif
    }

    #if compiler(>=6.2)
    /// AppLifecycle に登録した起動ハンドラから呼ばれる(任意スレッド)
    @available(iOS 26.0, *)
    func attachContinuedProcessingTask(_ task: BGContinuedProcessingTask) {
        task.expirationHandler = {
            ExportManager.shared.continuedProcessingTaskExpired()
        }
        exportOnMain { [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            guard self.isRunning else {
                // 書き出しがすでに終わっている
                task.setTaskCompleted(success: self.state == .finished)
                return
            }
            if let previous = self.continuedTask as? BGContinuedProcessingTask, previous !== task {
                previous.setTaskCompleted(success: false)
            }
            self.continuedTask = task
            task.progress.totalUnitCount = 1000
            task.progress.completedUnitCount = Int64(min(max(self.progress, 0), 1) * 1000)
        }
    }
    #endif

    /// BGContinuedProcessingTask の期限切れ(ユーザー停止 / システム)→ 書き出しをキャンセル
    private func continuedProcessingTaskExpired() {
        exportOnMain { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            self.continuedTaskExpired = true
            self.cancelOnMain(dueToBackgroundLimit: false)
        }
    }

    // MARK: - Notifications

    @MainActor
    private func requestNotificationAuthorizationIfNeeded() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "export-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Files / Photos

    static func exportsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = try exportsDirectory().appendingPathComponent("VideoEditor_\(formatter.string(from: Date())).mp4")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    private static func saveVideoToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportManagerError.photosAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

// MARK: - Reader → Writer pipeline

enum ExportPipelineError: LocalizedError {
    case noVideoTrack
    case cannotAddReaderOutput
    case cannotAddWriterInput
    case readerFailed
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "映像トラックがありません"
        case .cannotAddReaderOutput: return "読み込みの設定に失敗しました"
        case .cannotAddWriterInput: return "書き出しの設定に失敗しました"
        case .readerFailed: return "映像の読み込みに失敗しました"
        case .writerFailed: return "ファイルの書き込みに失敗しました"
        }
    }
}

/// requestMediaDataWhenReady のブロック内で使う完了フラグ(各キュー内でのみ触る)
private final class ExportPumpState {
    var finished = false
}

/// 1 回分の書き出し処理(AVAssetReader → AVAssetWriter)
final class ExportPipeline {
    enum Outcome {
        case completed
        case cancelled
        case failed(Error)
    }

    private let built: BuiltComposition
    private let outputURL: URL
    private let videoBitrate: Int
    private let preferHEVC: Bool
    private let frameRate: Int
    private let onProgress: (Double) -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var activeReader: AVAssetReader?

    private let videoQueue = DispatchQueue(label: "com.personal.videoeditor.export.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.personal.videoeditor.export.audio", qos: .userInitiated)

    init(built: BuiltComposition, outputURL: URL, videoBitrate: Int, preferHEVC: Bool, frameRate: Int,
         onProgress: @escaping (Double) -> Void) {
        self.built = built
        self.outputURL = outputURL
        self.videoBitrate = videoBitrate
        self.preferHEVC = preferHEVC
        self.frameRate = frameRate
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// どのスレッドからでも呼べる。読み込みを止め、各ループが終了したら writer をキャンセルする。
    func cancel() {
        lock.lock()
        cancelled = true
        let reader = activeReader
        lock.unlock()
        reader?.cancelReading()
    }

    func run() async -> Outcome {
        do {
            return try await runThrowing()
        } catch {
            return isCancelled ? .cancelled : .failed(error)
        }
    }

    // MARK: Settings

    private static var readerAudioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static var writerAudioSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: StorageEstimator.audioBitrate,
            AVChannelLayoutKey: layoutData
        ]
    }

    private func videoSettings(hevc: Bool) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: max(1, frameRate * 2)
        ]
        if !hevc {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let width = max(2, Int(built.renderSize.width.rounded()))
        let height = max(2, Int(built.renderSize.height.rounded()))
        let codec: AVVideoCodecType = hevc ? .hevc : .h264
        return [
            AVVideoCodecKey: codec.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    // MARK: Run

    private func runThrowing() async throws -> Outcome {
        if isCancelled { return .cancelled }

        let asset: AVAsset = built.composition
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let audioTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw ExportPipelineError.noVideoTrack }

        let durationSeconds = built.duration.seconds
        let validDuration = durationSeconds.isFinite && durationSeconds > 0

        // Reader
        let reader = try AVAssetReader(asset: asset)
        if validDuration {
            reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        }

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportPipelineError.cannotAddReaderOutput }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: Self.readerAudioSettings)
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ExportPipelineError.cannotAddReaderOutput }
            reader.add(output)
            audioOutput = output
        }

        // Writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var settings = videoSettings(hevc: preferHEVC)
        if preferHEVC && !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings = videoSettings(hevc: false)
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportPipelineError.cannotAddWriterInput }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.writerAudioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportPipelineError.cannotAddWriterInput }
            writer.add(input)
            audioInput = input
        }

        // Start
        lock.lock()
        if cancelled {
            lock.unlock()
            return .cancelled
        }
        activeReader = reader
        lock.unlock()

        guard reader.startReading() else {
            throw reader.error ?? ExportPipelineError.readerFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ExportPipelineError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        pump(input: videoInput, output: videoOutput, reader: reader, writer: writer, queue: videoQueue,
             progressDuration: validDuration ? durationSeconds : nil) {
            group.leave()
        }
        if let audioInput, let audioOutput {
            group.enter()
            pump(input: audioInput, output: audioOutput, reader: reader, writer: writer, queue: audioQueue,
                 progressDuration: nil) {
                group.leave()
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                continuation.resume()
            }
        }

        lock.lock()
        activeReader = nil
        lock.unlock()

        if isCancelled {
            reader.cancelReading()
            if writer.status == .writing {
                writer.cancelWriting()
            }
            return .cancelled
        }
        if reader.status == .failed {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            throw reader.error ?? ExportPipelineError.readerFailed
        }
        if writer.status == .failed {
            reader.cancelReading()
            throw writer.error ?? ExportPipelineError.writerFailed
        }
        if reader.status == .cancelled || writer.status == .cancelled {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            return .cancelled
        }
        guard writer.status == .writing else {
            throw writer.error ?? ExportPipelineError.writerFailed
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .completed {
            onProgress(1)
            return .completed
        }
        if isCancelled { return .cancelled }
        throw writer.error ?? ExportPipelineError.writerFailed
    }

    /// 1 トラック分のサンプルを reader から writer へ流す。終了時に completion を 1 回だけ呼ぶ。
    private func pump(input: AVAssetWriterInput,
                      output: AVAssetReaderOutput,
                      reader: AVAssetReader,
                      writer: AVAssetWriter,
                      queue: DispatchQueue,
                      progressDuration: Double?,
                      completion: @escaping () -> Void) {
        let pumpState = ExportPumpState()
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            if pumpState.finished { return }

            func finish(markFinished: Bool) {
                if markFinished && writer.status == .writing {
                    input.markAsFinished()
                }
                pumpState.finished = true
                completion()
            }

            while input.isReadyForMoreMediaData {
                let cancelledNow = self?.isCancelled ?? true
                if cancelledNow || writer.status != .writing {
                    finish(markFinished: false)
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    // 読み終わり(completed)なら入力を閉じる。失敗・キャンセルなら閉じずに終了
                    finish(markFinished: reader.status == .completed)
                    return
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if !input.append(sample) {
                    finish(markFinished: false)
                    return
                }
                if let progressDuration, progressDuration > 0, time.isValid {
                    let seconds = time.seconds
                    if seconds.isFinite {
                        self?.onProgress(min(max(seconds / progressDuration, 0), 1))
                    }
                }
            }
        }
    }
}
