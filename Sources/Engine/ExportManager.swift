import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import UIKit
import Photos
import UserNotifications
import Observation

// =====================================================================
// 動画の書き出し。
//
// パイプライン: AVAssetReader(合成) → AVAssetWriter(.mp4 / .mov)
//   映像: AVAssetReaderVideoCompositionOutput(32BGRA, カスタムコンポジタ) → H.264 / HEVC
//         (preserveHDR + HEVC のときは HLG 10bit を試し、失敗したら SDR に自動で戻す)
//   音声: AVAssetReaderAudioMixOutput(LPCM, .spectral) → AAC 48kHz 2ch(canvas.audioBitrateKbps)
//   書き出し後に出力ファイルを開き直し、長さと映像トラックの有無を検証する。
//
// バックグラウンド:
//   - 書き出し全体を UIApplication.beginBackgroundTask で包む。
//   - iOS 26 以降は ContinuedProcessing.begin(kind: .export) で BGContinuedProcessingTask も開始し、
//     システム UI(ロック画面)に進捗を出しつつ、ロック中・バックグラウンドでも書き出しを続ける。
//     GPU の使用が許可されれば、その間は AppLifecycle.shared.backgroundGPUAllowed が true になり、
//     バックグラウンドでも合成に GPU を使う(許可がなければ CPU)。停止されたら書き出しをキャンセルする。
//   - 継続処理が使えない場合(iOS 26 未満・開始できなかった等)、バックグラウンドに移ってから
//     iOS が許すのは約 30 秒だけ。長い書き出しは
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
        case .noOutput: return String(localized: "書き出したファイルがありません")
        case .photosAccessDenied: return String(localized: "写真ライブラリへの保存が許可されていません。設定アプリから許可してください")
        }
    }
}

/// 書き出し履歴の 1 件(Documents/Exports/history.json に保存)
struct ExportRecord: Identifiable, Equatable, Codable {
    let id: UUID
    /// Exports フォルダ内のファイル名(コンテナのパスが変わっても追えるよう名前だけ保存する)
    let fileName: String
    let date: Date
    /// 長さ(秒)
    let duration: Double
    /// 例: 「16:9 横 1080p 30fps」
    let canvasDescription: String

    var url: URL {
        let directory = (try? ExportManager.exportsDirectory()) ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(fileName)
    }
}

@Observable
final class ExportManager {
    static let shared = ExportManager()

    enum State: Equatable {
        case idle, preparing, exporting, finished, failed(String), cancelled
    }

    private(set) var state: State = .idle {
        didSet {
            // 書き出しが終わったら全画面広告(前の広告から間があいているときだけ)
            if state == .finished, oldValue != .finished {
                Task { @MainActor in AdsManager.shared.showInterstitial(.exportFinished) }
            }
        }
    }
    /// 0...1
    private(set) var progress: Double = 0
    private(set) var isRunning: Bool = false
    private(set) var lastOutputURL: URL?
    private(set) var savedToPhotos: Bool = false
    /// ユーザー向けの状態表示(日本語)
    private(set) var statusText: String = String(localized: "待機中")
    /// 書き出し履歴(新しい順、最大 20 件。ファイルが無くなったものは除く)
    private(set) var history: [ExportRecord] = []

    private static let historyLimit = 20

    /// 縦横同時書き出しなどで続けて行う 1 本分
    private struct ExportJob {
        let snapshot: ProjectSnapshot
        let saveToPhotos: Bool
        let label: String
    }

    // 以下はメインスレッドからのみ触る
    @ObservationIgnored private var currentPipeline: ExportPipeline?
    @ObservationIgnored private var currentAudioSession: AVAssetExportSession?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var expiredInBackground = false
    @ObservationIgnored private var continuedTaskExpired = false
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier?
    /// iOS 26+ の継続処理(ロック中も書き出しを続ける)。使えないときは nil
    @ObservationIgnored private var continuedHandle: ContinuedProcessingHandle?
    /// 縦横同時書き出しの全体進捗用(終わった本数 / 全体の本数)
    @ObservationIgnored private var jobsCompleted = 0
    @ObservationIgnored private var jobsTotal = 1
    @ObservationIgnored private var didRequestNotificationAuthorization = false
    /// 続けて書き出す予定(縦横同時)
    @ObservationIgnored private var queuedJobs: [ExportJob] = []
    /// 状態表示の先頭に付ける「(1/2 横 16:9)」など
    @ObservationIgnored private var jobLabel: String = ""

    // 進捗の間引き(任意スレッドから)
    private let progressLock = NSLock()
    @ObservationIgnored private var lastProgressReport: CFAbsoluteTime = 0

    private init() {
        loadHistory()
    }

    // MARK: - Public API

    func start(snapshot: ProjectSnapshot, saveToPhotos: Bool) {
        Analytics.shared.track("export_start", Self.analyticsParams(snapshot, dual: false, saveToPhotos: saveToPhotos))
        exportOnMain { [weak self] in
            guard let self, !self.isRunning else { return }
            self.queuedJobs = []
            self.jobLabel = ""
            self.jobsCompleted = 0
            self.jobsTotal = 1
            self.startOnMain(snapshot: snapshot, saveToPhotos: saveToPhotos)
        }
    }

    /// 横 16:9 → 縦 9:16(ぼかし背景)の順に 2 本続けて書き出す
    func startDual(snapshot: ProjectSnapshot, saveToPhotos: Bool = false) {
        Analytics.shared.track("export_start", Self.analyticsParams(snapshot, dual: true, saveToPhotos: saveToPhotos))
        exportOnMain { [weak self] in
            self?.startDualOnMain(snapshot: snapshot, saveToPhotos: saveToPhotos)
        }
    }

    /// 音声だけを m4a に書き出す
    func startAudioOnly(snapshot: ProjectSnapshot) {
        exportOnMain { [weak self] in
            self?.startAudioOnlyOnMain(snapshot: snapshot)
        }
    }

    /// 履歴から削除する(書き出したファイルも削除)
    func deleteRecord(_ record: ExportRecord) {
        exportOnMain { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: record.url)
            self.history.removeAll { $0.id == record.id }
            if let last = self.lastOutputURL, last.path == record.url.path {
                self.lastOutputURL = nil
            }
            self.saveHistory()
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
            self.statusText = String(localized: "写真に保存しました")
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
            let message = String(localized: "書き出すクリップがありません")
            state = .failed(message)
            statusText = message
            return
        }

        // 空き容量チェック
        let estimate = StorageEstimator.estimate(for: snapshot)
        guard estimate.canExport else {
            let message = String(localized: "空き容量が不足しています(必要: \(StorageEstimator.formatBytes(estimate.requiredBytes)) / 空き: \(StorageEstimator.formatBytes(estimate.availableBytes)))")
            state = .failed(message)
            statusText = message
            return
        }

        isRunning = true
        state = .preparing
        progress = 0
        savedToPhotos = false
        lastOutputURL = nil
        statusText = jobLabel + String(localized: "書き出しの準備中…")
        cancelRequested = false
        expiredInBackground = false
        continuedTaskExpired = false
        currentPipeline = nil
        currentAudioSession = nil
        progressLock.lock()
        lastProgressReport = 0
        progressLock.unlock()

        requestNotificationAuthorizationIfNeeded()
        if saveToPhotos {
            // 許可ダイアログはフォアグラウンドでしか出せないので、先に聞いておく
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
        beginBackgroundWork()
        beginContinuedProcessing(title: jobsTotal > 1 ? String(localized: "動画を書き出し中(\(jobsTotal) 本)") : String(localized: "動画を書き出し中"),
                                 wantsGPU: true)

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runExport(snapshot: snapshot, saveToPhotos: saveToPhotos)
        }
    }

    @MainActor
    private func startDualOnMain(snapshot: ProjectSnapshot, saveToPhotos: Bool) {
        guard !isRunning else { return }
        guard !snapshot.isEmpty, snapshot.totalDuration > 0 else {
            let message = String(localized: "書き出すクリップがありません")
            state = .failed(message)
            statusText = message
            return
        }
        var landscape = snapshot
        landscape.canvas.aspect = .landscape16x9
        var portrait = snapshot
        portrait.canvas.aspect = .portrait9x16
        portrait.canvas.scaling = .fitBlur

        // 空き容量は 2 本分で確認する(作業用マージンは 1 回分)
        let first = StorageEstimator.estimate(for: landscape)
        let second = StorageEstimator.estimate(for: portrait)
        let required = first.requiredBytes + second.estimatedOutputBytes
        guard first.availableBytes >= required else {
            let message = String(localized: "空き容量が不足しています(2 本分で必要: \(StorageEstimator.formatBytes(required)) / 空き: \(StorageEstimator.formatBytes(first.availableBytes)))")
            state = .failed(message)
            statusText = message
            return
        }

        queuedJobs = [ExportJob(snapshot: portrait, saveToPhotos: saveToPhotos, label: String(localized: "(2/2 縦 9:16)"))]
        jobLabel = String(localized: "(1/2 横 16:9)")
        jobsCompleted = 0
        jobsTotal = 2
        startOnMain(snapshot: landscape, saveToPhotos: saveToPhotos)
        if !isRunning {
            // 1 本目を始められなかった(容量不足など)
            queuedJobs = []
            jobLabel = ""
        }
    }

    @MainActor
    private func startAudioOnlyOnMain(snapshot: ProjectSnapshot) {
        guard !isRunning else { return }
        guard !snapshot.isEmpty, snapshot.totalDuration > 0 else {
            let message = String(localized: "書き出すクリップがありません")
            state = .failed(message)
            statusText = message
            return
        }
        queuedJobs = []
        jobLabel = ""
        jobsCompleted = 0
        jobsTotal = 1
        isRunning = true
        state = .preparing
        progress = 0
        savedToPhotos = false
        lastOutputURL = nil
        statusText = String(localized: "音声の書き出しを準備中…")
        cancelRequested = false
        expiredInBackground = false
        continuedTaskExpired = false
        currentPipeline = nil
        currentAudioSession = nil
        progressLock.lock()
        lastProgressReport = 0
        progressLock.unlock()

        beginBackgroundWork()
        beginContinuedProcessing(title: String(localized: "音声を書き出し中"), wantsGPU: false)

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runAudioExport(snapshot: snapshot)
        }
    }

    @MainActor
    private func cancelOnMain(dueToBackgroundLimit: Bool) {
        guard isRunning else { return }
        if dueToBackgroundLimit {
            expiredInBackground = true
        }
        cancelRequested = true
        queuedJobs = []
        statusText = String(localized: "キャンセルしています…")
        currentPipeline?.cancel()
        currentAudioSession?.cancelExport()
    }

    // MARK: - Export flow (background)

    private func runExport(snapshot: ProjectSnapshot, saveToPhotos: Bool) async {
        let canvas = snapshot.canvas
        let outputURL: URL
        do {
            outputURL = try Self.makeOutputURL(fileExtension: StorageEstimator.fileExtension(for: snapshot))
        } catch {
            let message = String(localized: "書き出し先フォルダを作成できませんでした: \(error.localizedDescription)")
            await MainActor.run { self.finishFailed(message, outputURL: nil) }
            return
        }

        // 字幕を焼き込まない設定なら、書き出し用の構成からだけ字幕を外す(章タイトル・テロップは残る)
        var buildSnapshot = snapshot
        if !canvas.burnInSubtitles {
            buildSnapshot.subtitles = []
        }

        let built: BuiltComposition
        do {
            built = try await CompositionBuilder.build(buildSnapshot, purpose: .export)
        } catch {
            let message = String(localized: "映像の構成に失敗しました: \(error.localizedDescription)")
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
                                      frameRate: max(1, canvas.frameRate),
                                      audioBitrate: StorageEstimator.audioBitrate(for: snapshot),
                                      fileType: Self.fileType(for: canvas.fileFormat),
                                      preserveHDR: canvas.preserveHDR,
                                      onProgress: { [weak self] value in
                                          self?.pipelineReportedProgress(value)
                                      })

        let proceed: Bool = await MainActor.run {
            if self.cancelRequested { return false }
            self.currentPipeline = pipeline
            self.state = .exporting
            self.statusText = self.jobLabel + "書き出し中… 0%"
            return true
        }
        guard proceed else {
            await MainActor.run { self.finishCancelled(outputURL: outputURL) }
            return
        }

        let outcome = await pipeline.run()

        switch outcome {
        case .completed:
            let fellBackToSDR = pipeline.didFallBackToSDR

            // 書き出したファイルを開き直して検証(長さ・映像トラック)。失敗してもファイルは残す
            if let problem = await Self.verifyOutput(outputURL, expectedDuration: built.duration.seconds) {
                await MainActor.run { self.finishVerificationFailed(problem, outputURL: outputURL) }
                return
            }

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
            let durationSeconds = built.duration.seconds
            let description = Self.canvasDescription(for: snapshot, renderSize: built.renderSize)
            await MainActor.run {
                self.finishSucceeded(outputURL: outputURL, saved: savedResult, photoError: photoErrorResult,
                                     fellBackToSDR: fellBackToSDR,
                                     duration: durationSeconds, canvasDescription: description)
            }
        case .cancelled:
            await MainActor.run { self.finishCancelled(outputURL: outputURL) }
        case .failed(let error):
            let message = String(localized: "書き出しに失敗しました: \(error.localizedDescription)")
            await MainActor.run { self.finishFailed(message, outputURL: outputURL) }
        }
    }

    // MARK: - Audio-only export (background)

    private func runAudioExport(snapshot: ProjectSnapshot) async {
        let outputURL: URL
        do {
            outputURL = try Self.makeOutputURL(fileExtension: "m4a")
        } catch {
            let message = String(localized: "書き出し先フォルダを作成できませんでした: \(error.localizedDescription)")
            await MainActor.run { self.finishFailed(message, outputURL: nil) }
            return
        }

        let built: BuiltComposition
        do {
            built = try await CompositionBuilder.build(snapshot, purpose: .preview)
        } catch {
            let message = String(localized: "音声の構成に失敗しました: \(error.localizedDescription)")
            await MainActor.run {
                if self.cancelRequested {
                    self.finishCancelled(outputURL: outputURL)
                } else {
                    self.finishFailed(message, outputURL: outputURL)
                }
            }
            return
        }

        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            await MainActor.run { self.finishFailed(String(localized: "音声の書き出しを準備できませんでした"), outputURL: outputURL) }
            return
        }
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        let durationSeconds = built.duration.seconds
        if durationSeconds.isFinite && durationSeconds > 0 {
            session.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        }

        let proceed: Bool = await MainActor.run {
            if self.cancelRequested { return false }
            self.currentAudioSession = session
            self.state = .exporting
            self.statusText = "音声を書き出し中… 0%"
            return true
        }
        guard proceed else {
            await MainActor.run { self.finishCancelled(outputURL: outputURL) }
            return
        }

        // 進捗(0.2 秒ごとに読む)
        let monitor = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }
                let value = Double(session.progress)
                self?.pipelineReportedProgress(value)
            }
        }

        do {
            try await session.export(to: outputURL, as: .m4a)
            monitor.cancel()
            await MainActor.run {
                self.currentAudioSession = nil
                if self.cancelRequested {
                    self.finishCancelled(outputURL: outputURL)
                } else {
                    self.finishSucceeded(outputURL: outputURL, saved: false, photoError: nil,
                                         duration: durationSeconds, canvasDescription: String(localized: "音声のみ(m4a)"),
                                         audioOnly: true)
                }
            }
        } catch {
            monitor.cancel()
            let cancelled = error is CancellationError
            await MainActor.run {
                self.currentAudioSession = nil
                if self.cancelRequested || cancelled {
                    self.finishCancelled(outputURL: outputURL)
                } else {
                    self.finishFailed(String(localized: "音声の書き出しに失敗しました: \(error.localizedDescription)"), outputURL: outputURL)
                }
            }
        }
    }

    /// 履歴に表示する出力の説明(例: 「16:9 横 1080p 30fps」)
    private static func canvasDescription(for snapshot: ProjectSnapshot, renderSize: CGSize) -> String {
        let aspect: String
        switch snapshot.canvas.aspect {
        case .original: aspect = String(localized: "元の比率")
        case .portrait9x16: aspect = String(localized: "9:16 縦")
        case .landscape16x9: aspect = String(localized: "16:9 横")
        case .square: aspect = "1:1"
        case .portrait4x5: aspect = String(localized: "4:5 縦")
        }
        let shortSide = Int(min(renderSize.width, renderSize.height).rounded())
        let codec = StorageEstimator.usesHEVC(for: snapshot) ? "HEVC" : "H.264"
        return "\(aspect) \(shortSide)p \(snapshot.canvas.frameRate)fps \(codec)"
    }

    // MARK: - History

    private static func historyURL() throws -> URL {
        try exportsDirectory().appendingPathComponent("history.json")
    }

    private func loadHistory() {
        guard let url = try? Self.historyURL(),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([ExportRecord].self, from: data) else { return }
        history = records.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func saveHistory() {
        guard let url = try? Self.historyURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @MainActor
    private func appendHistory(url: URL, duration: Double, canvasDescription: String) {
        let record = ExportRecord(id: UUID(),
                                  fileName: url.lastPathComponent,
                                  date: Date(),
                                  duration: duration.isFinite ? max(0, duration) : 0,
                                  canvasDescription: canvasDescription)
        var updated = history.filter { $0.fileName != record.fileName && FileManager.default.fileExists(atPath: $0.url.path) }
        updated.insert(record, at: 0)
        if updated.count > Self.historyLimit {
            updated = Array(updated.prefix(Self.historyLimit))
        }
        history = updated
        saveHistory()
    }

    /// 出力ファイルを AVURLAsset で開き、長さ(許容 0.5 秒)と映像トラックの有無を確認する。問題があれば日本語の説明を返す
    private static func verifyOutput(_ url: URL, expectedDuration: Double) async -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return String(localized: "書き出した動画のファイルが見つかりません")
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                return String(localized: "書き出した動画に映像トラックがありません")
            }
            let actual = duration.seconds
            guard actual.isFinite else {
                return String(localized: "書き出した動画の長さを読み取れませんでした")
            }
            if expectedDuration.isFinite, expectedDuration > 0, abs(actual - expectedDuration) > 0.5 {
                return String(format: "書き出した動画の長さが一致しません(出力 %.1f 秒 / 想定 %.1f 秒)", actual, expectedDuration)
            }
            return nil
        } catch {
            return String(localized: "書き出した動画を確認できませんでした: \(error.localizedDescription)")
        }
    }

    private static func fileType(for format: ExportFileFormat) -> AVFileType {
        switch format {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    // MARK: - Finish (main)

    private static let backgroundLimitMessage = String(localized: "バックグラウンドの時間制限で中断しました。アプリを開いたまま再度書き出してください")
    private static let sdrFallbackNote = String(localized: "HDRで書き出せなかったためSDRで書き出しました")

    /// 統計に送る書き出しの条件(個人情報は含まない)
    private static func analyticsParams(_ snapshot: ProjectSnapshot, dual: Bool, saveToPhotos: Bool) -> [String: String] {
        let seconds = CompositionBuilder.totalDuration(for: snapshot)
        return [
            "length": Analytics.durationBucket(seconds),
            "clips": String(min(snapshot.clips.count, 99)),
            "aspect": String(describing: snapshot.canvas.aspect),
            "dual": dual ? "1" : "0",
            "photos": saveToPhotos ? "1" : "0",
            "captions": snapshot.subtitles.isEmpty ? "0" : "1",
            "look": String(describing: snapshot.documentary.look),
            "transitions": String(min(snapshot.clips.filter { $0.transition.isActive }.count, 99)),
        ]
    }

    @MainActor
    private func finishSucceeded(outputURL: URL, saved: Bool, photoError: Error?, fellBackToSDR: Bool = false,
                                 duration: Double, canvasDescription: String, audioOnly: Bool = false) {
        Analytics.shared.track("export_done", ["length": Analytics.durationBucket(duration),
                                               "saved": saved ? "1" : "0",
                                               "sdr_fallback": fellBackToSDR ? "1" : "0",
                                               "audio_only": audioOnly ? "1" : "0"])
        currentPipeline = nil
        currentAudioSession = nil
        lastOutputURL = outputURL
        appendHistory(url: outputURL, duration: duration, canvasDescription: canvasDescription)

        if (cancelRequested || continuedTaskExpired) && jobsCompleted + 1 < jobsTotal {
            // 縦横同時の 1 本目の検証・写真への保存中にキャンセル / 停止された(cancelOnMain が残りを消している)。
            // 書き出せた 1 本目は残し、2 本目は中止したことを伝える
            finishStoppedAfterFirstJob(saved: saved, photoError: photoError, fellBackToSDR: fellBackToSDR)
            return
        }

        if !queuedJobs.isEmpty {
            // 縦横同時: 続けて次の 1 本を書き出す(バックグラウンド処理・継続処理は続行したまま)
            let next = queuedJobs.removeFirst()
            isRunning = false
            jobLabel = next.label
            jobsCompleted += 1
            startOnMain(snapshot: next.snapshot, saveToPhotos: next.saveToPhotos)
            if !isRunning {
                // 次の 1 本を始められなかった(容量不足など)。バックグラウンド処理を終える
                queuedJobs = []
                jobLabel = ""
                endBackgroundWork(success: false)
            }
            return
        }

        let label = jobLabel
        jobLabel = ""
        progress = 1
        savedToPhotos = saved
        state = .finished
        isRunning = false
        let doneText = audioOnly ? String(localized: "音声の書き出し完了") : String(localized: "書き出し完了")
        if let photoError {
            statusText = String(localized: "\(doneText)(写真への保存に失敗: \(photoError.localizedDescription))")
        } else if saved {
            statusText = label.isEmpty ? String(localized: "\(doneText)・写真に保存しました") : String(localized: "2 本とも書き出して写真に保存しました")
        } else {
            statusText = label.isEmpty ? doneText : String(localized: "2 本とも書き出しました")
        }
        if fellBackToSDR {
            statusText += "(\(Self.sdrFallbackNote))"
        }
        if AppLifecycle.shared.isInBackground {
            Self.postLocalNotification(title: doneText,
                                       body: saved ? String(localized: "動画を書き出して写真に保存しました")
                                           : (audioOnly ? String(localized: "音声の書き出しが完了しました") : String(localized: "動画の書き出しが完了しました")))
        }
        endBackgroundWork(success: true)
    }

    /// 縦横同時で 1 本目は書き出せたが、その直後にキャンセル / 停止されて 2 本目を始めなかった
    @MainActor
    private func finishStoppedAfterFirstJob(saved: Bool, photoError: Error?, fellBackToSDR: Bool) {
        queuedJobs = []
        jobLabel = ""
        progress = 1
        savedToPhotos = saved
        state = .finished
        isRunning = false
        let reason: String
        if continuedTaskExpired {
            reason = String(localized: "ロック画面またはシステムにより停止されたため")
        } else if expiredInBackground {
            reason = String(localized: "バックグラウンドの時間制限のため")
        } else {
            reason = String(localized: "キャンセルしたため")
        }
        var text = saved ? String(localized: "1 本目のみ書き出して写真に保存しました") : String(localized: "1 本目のみ書き出しました")
        text += String(localized: "(\(reason)、2 本目は中止)")
        if let photoError {
            text += String(localized: "(写真への保存に失敗: \(photoError.localizedDescription))")
        }
        if fellBackToSDR {
            text += "(\(Self.sdrFallbackNote))"
        }
        statusText = text
        if (continuedTaskExpired || expiredInBackground) && AppLifecycle.shared.isInBackground {
            Self.postLocalNotification(title: String(localized: "書き出しが停止されました"),
                                       body: String(localized: "1 本目のみ書き出しました。アプリを開いて 2 本目を書き出してください"))
        }
        endBackgroundWork(success: false)
    }

    /// 書き出し自体は終わったが検証に通らなかった。ファイルは残し、lastOutputURL からたどれるようにする
    @MainActor
    private func finishVerificationFailed(_ message: String, outputURL: URL) {
        currentPipeline = nil
        currentAudioSession = nil
        queuedJobs = []
        jobLabel = ""
        lastOutputURL = outputURL
        isRunning = false
        state = .failed(message)
        statusText = message
        if AppLifecycle.shared.isInBackground {
            Self.postLocalNotification(title: String(localized: "書き出しに問題があります"), body: message)
        }
        endBackgroundWork(success: false)
    }

    @MainActor
    private func finishCancelled(outputURL: URL?) {
        Analytics.shared.track("export_cancelled", ["background_limit": expiredInBackground ? "1" : "0",
                                                    "system_stop": continuedTaskExpired ? "1" : "0"])
        currentPipeline = nil
        currentAudioSession = nil
        queuedJobs = []
        jobLabel = ""
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        isRunning = false
        if expiredInBackground {
            state = .failed(Self.backgroundLimitMessage)
            statusText = Self.backgroundLimitMessage
            if AppLifecycle.shared.isInBackground {
                Self.postLocalNotification(title: String(localized: "書き出しが中断されました"),
                                           body: String(localized: "アプリを開いたまま再度書き出してください"))
            }
        } else {
            state = .cancelled
            statusText = continuedTaskExpired ? String(localized: "ロック画面またはシステムにより書き出しが停止されました") : String(localized: "書き出しをキャンセルしました")
            if continuedTaskExpired && AppLifecycle.shared.isInBackground {
                Self.postLocalNotification(title: String(localized: "書き出しが停止されました"),
                                           body: String(localized: "アプリを開いて再度書き出してください"))
            }
        }
        endBackgroundWork(success: false)
    }

    @MainActor
    private func finishFailed(_ message: String, outputURL: URL?) {
        // 失敗の内容は固定の分類だけ送る(メッセージ本文は送らない)
        let kind = message.contains("空き容量") ? "disk" : (message.contains("HDR") ? "hdr" : "other")
        Analytics.shared.track("export_failed", ["kind": kind])
        currentPipeline = nil
        currentAudioSession = nil
        queuedJobs = []
        jobLabel = ""
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        isRunning = false
        // 継続処理なしでバックグラウンド中に失敗した場合は、時間制限 / GPU 制限による中断とみなす
        let continuing = continuedHandle?.isActive ?? false
        let backgroundInterrupted = expiredInBackground
            || (AppLifecycle.shared.isInBackground && !continuing)
        let finalMessage = backgroundInterrupted ? Self.backgroundLimitMessage : message
        state = .failed(finalMessage)
        statusText = finalMessage
        if AppLifecycle.shared.isInBackground {
            Self.postLocalNotification(title: String(localized: "書き出しに失敗しました"), body: finalMessage)
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
        let percent = Int((value * 100).rounded(.down))
        statusText = currentAudioSession != nil ? "音声を書き出し中… \(percent)%" : jobLabel + "書き出し中… \(percent)%"
        if let handle = continuedHandle {
            // 縦横同時のときは 2 本分を通した進捗にする
            let overall = (Double(jobsCompleted) + value) / Double(max(1, jobsTotal))
            handle.update(completed: overall, subtitle: statusText)
        }
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
        // iOS 26 で継続処理(BGContinuedProcessingTask)が動いていれば書き出しは続けられる。
        // それ以外(iOS 26 未満・継続処理を開始できなかった等)は約 30 秒の猶予しかないため、ここで安全に中断する。
        let continuing = continuedHandle?.isActive ?? false
        if !continuing && isRunning {
            cancelOnMain(dueToBackgroundLimit: true)
        }
        if let id = backgroundTaskID {
            UIApplication.shared.endBackgroundTask(id)
            backgroundTaskID = nil
        }
    }

    @MainActor
    private func endBackgroundWork(success: Bool) {
        if let handle = continuedHandle {
            continuedHandle = nil
            handle.finish(success: success)
        }
        if let id = backgroundTaskID {
            UIApplication.shared.endBackgroundTask(id)
            backgroundTaskID = nil
        }
    }

    /// iOS 26+ の継続処理を始める(ユーザー操作の直後、アプリが前面にある間に呼ばれる)。
    /// 縦横同時の 2 本目は 1 本目の継続処理をそのまま使う(バックグラウンドからは開始できないため)。
    /// 使えないときは何もしない(beginBackgroundTask のフォールバックで続行。理由は ContinuedProcessing.lastDiagnostic)。
    @MainActor
    private func beginContinuedProcessing(title: String, wantsGPU: Bool) {
        guard continuedHandle == nil, jobsCompleted == 0 else { return }
        guard let handle = ContinuedProcessing.begin(kind: .export, title: title,
                                                     subtitle: String(localized: "書き出しの準備中…"), wantsGPU: wantsGPU) else {
            return
        }
        handle.onExpire = { [weak self] in
            self?.continuedProcessingTaskExpired()
        }
        continuedHandle = handle
    }

    /// 継続処理の期限切れ(ロック画面などからのユーザー停止 / システム)→ 書き出しをキャンセル
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

    private static func makeOutputURL(fileExtension: String = "mp4") throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ext = fileExtension.isEmpty ? "mp4" : fileExtension
        let url = try exportsDirectory().appendingPathComponent("VideoEditor_\(formatter.string(from: Date())).\(ext)")
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
    /// HDR(HLG 10bit)の設定が受け付けられなかった(SDR で再試行する)
    case hdrUnavailable

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "映像トラックがありません")
        case .cannotAddReaderOutput: return String(localized: "読み込みの設定に失敗しました")
        case .cannotAddWriterInput: return String(localized: "書き出しの設定に失敗しました")
        case .readerFailed: return String(localized: "映像の読み込みに失敗しました")
        case .writerFailed: return String(localized: "ファイルの書き込みに失敗しました")
        case .hdrUnavailable: return String(localized: "HDR(HLG 10bit)では書き出せませんでした")
        }
    }
}

/// 1 トラック分の流し込みの状態。完了の通知はどのスレッドからでも 1 回だけ
/// (キャンセル時は、入力が「受け取れる状態」にならなくても外から終わらせられる)
private final class ExportPumpState {
    private let lock = NSLock()
    private var done = false
    private var completion: (() -> Void)?

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    /// 初回だけ completion を呼ぶ。呼んだら true
    @discardableResult
    func finishOnce() -> Bool {
        lock.lock()
        if done {
            lock.unlock()
            return false
        }
        done = true
        let handler = completion
        completion = nil
        lock.unlock()
        handler?()
        return true
    }
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
    private let audioBitrate: Int
    private let fileType: AVFileType
    private let preserveHDR: Bool
    private let onProgress: (Double) -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var activeReader: AVAssetReader?
    /// 流し込み中のトラック(キャンセル時に待たずに終わらせる)
    private var activePumps: [ExportPumpState] = []
    private var fellBackToSDR = false

    private let videoQueue = DispatchQueue(label: "com.personal.videoeditor.export.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.personal.videoeditor.export.audio", qos: .userInitiated)

    init(built: BuiltComposition,
         outputURL: URL,
         videoBitrate: Int,
         preferHEVC: Bool,
         frameRate: Int,
         audioBitrate: Int = StorageEstimator.audioBitrate,
         fileType: AVFileType = .mp4,
         preserveHDR: Bool = false,
         onProgress: @escaping (Double) -> Void) {
        self.built = built
        self.outputURL = outputURL
        self.videoBitrate = videoBitrate
        self.preferHEVC = preferHEVC
        self.frameRate = frameRate
        self.audioBitrate = max(32_000, audioBitrate)
        self.fileType = fileType
        self.preserveHDR = preserveHDR
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// HDR を試みたが受け付けられず、SDR で書き出したか
    var didFallBackToSDR: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fellBackToSDR
    }

    /// どのスレッドからでも呼べる。読み込みを止め、各ループが終了したら writer をキャンセルする。
    func cancel() {
        lock.lock()
        cancelled = true
        let reader = activeReader
        let pumps = activePumps
        lock.unlock()
        reader?.cancelReading()
        // 入力が「次を受け取れる状態」にならないと流し込みのブロックが呼ばれず、キャンセルに気づけない
        // (最後のほうは音声と映像の足並みをそろえる待ちで止まりやすい)。ここで各トラックを終わらせる
        for pump in pumps {
            pump.finishOnce()
        }
    }

    func run() async -> Outcome {
        do {
            if preserveHDR && preferHEVC {
                // HLG 10bit を試す。設定が通らない・途中で失敗した場合は SDR でやり直す
                do {
                    return try await runThrowing(hdr: true)
                } catch {
                    if isCancelled { return .cancelled }
                    lock.lock()
                    fellBackToSDR = true
                    activeReader = nil
                    lock.unlock()
                    try? FileManager.default.removeItem(at: outputURL)
                    onProgress(0)
                }
            }
            return try await runThrowing(hdr: false)
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

    private var writerAudioSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitrate,
            AVChannelLayoutKey: layoutData
        ]
    }

    /// 映像の出力設定。hdr のときは HEVC Main10 + HLG(BT.2020)の色情報を付ける
    private func videoSettings(hevc: Bool, hdr: Bool) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: max(1, frameRate * 2)
        ]
        if !hevc {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if hdr {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        let width = max(2, Int(built.renderSize.width.rounded()))
        let height = max(2, Int(built.renderSize.height.rounded()))
        let codec: AVVideoCodecType = hevc ? .hevc : .h264
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        if hevc && hdr {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        return settings
    }

    // MARK: Run

    private func runThrowing(hdr: Bool) async throws -> Outcome {
        if isCancelled { return .cancelled }

        let asset: AVAsset = built.composition
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let audioTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw ExportPipelineError.noVideoTrack }

        let durationSeconds = built.duration.seconds
        let validDuration = durationSeconds.isFinite && durationSeconds > 0

        // Writer(HDR の設定が通るかを先に確かめる。ファイルは startWriting まで作られない)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        var settings = videoSettings(hevc: preferHEVC, hdr: hdr)
        if hdr {
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw ExportPipelineError.hdrUnavailable
            }
        } else if preferHEVC && !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings = videoSettings(hevc: false, hdr: false)
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw hdr ? ExportPipelineError.hdrUnavailable : ExportPipelineError.cannotAddWriterInput
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerAudioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportPipelineError.cannotAddWriterInput }
            writer.add(input)
            audioInput = input
        }

        // Reader
        let reader = try AVAssetReader(asset: asset)
        if validDuration {
            reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        }

        let readerPixelFormat: OSType = hdr
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw hdr ? ExportPipelineError.hdrUnavailable : ExportPipelineError.cannotAddReaderOutput
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if audioInput != nil {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: Self.readerAudioSettings)
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ExportPipelineError.cannotAddReaderOutput }
            reader.add(output)
            audioOutput = output
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
        activePumps = []
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
        let pumpState = ExportPumpState(completion: completion)
        lock.lock()
        activePumps.append(pumpState)
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled {
            pumpState.finishOnce()
            return
        }
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            if pumpState.finished { return }

            func finish(markFinished: Bool) {
                if pumpState.finished { return }
                if markFinished && writer.status == .writing {
                    input.markAsFinished()
                }
                pumpState.finishOnce()
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
