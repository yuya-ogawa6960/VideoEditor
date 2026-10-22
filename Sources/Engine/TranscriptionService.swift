import Foundation
import AVFoundation
import Speech
import Observation
import UIKit

// =====================================================================
// 自動文字起こし
//
// エンジンは AppSettings.shared.transcriptionEngine で切り替える:
// - Apple(端末内)
//   - iOS 26 以降: SpeechAnalyzer + SpeechTranscriber(句読点付き・単語ごとの時刻)で
//     クリップ全体を一度に認識する。モデル未導入なら自動ダウンロード、失敗時は従来方式へ。
//   - iOS 18〜25: SFSpeechRecognizer(addsPunctuation)で ≤50 秒のチャンクに分けて認識。
// - Whisper(端末内): WhisperTranscriber(WhisperKit)。初回にモデルをダウンロードする。
// - クラウドAI: CloudTranscriber(OpenAI)。API キーが必要。
//
// どの経路でも「クリップ全体の時刻付きトークン列」を作ってから
// SubtitleSegmenter で文・文節単位に区切る(チャンク境界で文が切れない)。
// セグメンタは各字幕に単語タイミング(cue.words)も付ける。
// 最後に設定が有効なら SubtitlePolisher(LLM)で句読点・フィラー・分割を仕上げる。
//
// 画面ロック対策:
// - iOS 26+: 1 回の実行全体を ContinuedProcessing(BGContinuedProcessingTask)で包む。動いている間は
//   ロック中もアプリが止められないので、クラウド・AI 仕上げはバックグラウンドでも待たずに進める
//   (Whisper は GPU / Neural Engine を使うので、これまでどおりフォアグラウンドに戻るまで待つ)。
//   進捗はシステムの表示(ロック画面など)にも出す。システム/利用者が止めたら、以降はフォアグラウンド待ちに戻る。
// - 併せて(継続処理が使えない iOS / 状況でも)beginBackgroundTask で包み、ロック直後も送信中のリクエストが
//   終わるまで(約 30 秒)動けるようにする(時間切れで終了しても、フォアグラウンドに戻るたびに取り直す)。
// - クラウドは全ピースを先に切り出して背景 URLSession(CloudBackgroundUploader)にまとめて預けるので、
//   アプリが止められても送信は続く。アプリごと終了したときは、次に字幕画面を開いたときに
//   cues(fromPendingJob:snapshot:language:) で取り込める。
// - 継続処理も背景送信も無いときは、クラウド・Whisper・AI 仕上げはバックグラウンド中は新しい処理を始めず、
//   フォアグラウンドに戻ると続きから再開する(待っている間は状態表示を「一時停止中」にする)。
//   継続処理か背景送信が動いているあいだのロック中は「ロック中も処理を続けています」と表示する。
// =====================================================================

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja-JP"
    case english = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .japanese: return String(localized: "日本語")
        case .english: return String(localized: "英語")
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
    /// 前回の文字起こし結果を、今のプロジェクトに取り込めない
    case pendingResultUnusable(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "音声認識の権限がありません。設定アプリでこのアプリの「音声認識」を許可してください。")
        case .recognizerUnavailable(let language):
            return String(localized: "\(language)の音声認識器が利用できません。ネットワーク接続や端末の言語設定を確認してください。")
        case .alreadyRunning:
            return String(localized: "文字起こしはすでに実行中です。")
        case .noAudioClips:
            return String(localized: "文字起こしできる音声がありません(すべてのクリップが無音またはミュートです)。")
        case .audioExportFailed(let detail):
            return String(localized: "音声の切り出しに失敗しました: \(detail)")
        case .recognitionFailed(let detail):
            return String(localized: "音声認識に失敗しました: \(detail)")
        case .pendingResultUnusable(let detail):
            return detail
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

/// 文字起こし 1 回分の beginBackgroundTask。
/// 時間切れで終了したあとも、アプリがフォアグラウンドに戻るたびに取り直す(2 回目以降の画面ロックでも猶予を得るため)。
/// 同時に持つタスクは 1 つだけ。実行の終わりに finish() を 1 回呼ぶ(以降は取り直さない)
private final class TranscriptionBackgroundTask: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier?
    /// 実行が終わったか(finish 後は取り直さない)
    private var finished = false
    /// フォアグラウンド復帰の監視(メインアクターからだけ触る)
    private var foregroundObserver: NSObjectProtocol?

    /// 実行の開始時に呼ぶ。バックグラウンドタスクを始め、フォアグラウンドに戻るたびに取り直す監視を登録する
    @MainActor
    func begin() {
        renewIfNeeded()
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            // queue: .main なのでメインスレッドで呼ばれる
            guard let self else { return }
            MainActor.assumeIsolated {
                self.renewIfNeeded()
            }
        }
    }

    /// バックグラウンドタスクが無いときだけ始める(時間切れで終了したあとにフォアグラウンドへ戻ったときなど)。
    /// すでにあるときは何もしない(上書きすると前のタスクを終了できなくなり、アプリが強制終了される)
    @MainActor
    func renewIfNeeded() {
        lock.lock()
        let skip = finished || identifier != nil
        lock.unlock()
        if skip { return }
        let id = UIApplication.shared.beginBackgroundTask(withName: "Transcription") {
            // 時間切れ(メインスレッドで同期的に呼ばれる)。ここで終了しないとアプリが強制終了される。
            // 処理そのものは止めない(バックグラウンド中は各エンジンがフォアグラウンドに戻るまで待つ)
            MainActor.assumeIsolated {
                self.end()
            }
        }
        guard id != .invalid else { return }
        lock.lock()
        identifier = id
        lock.unlock()
    }

    /// 実行の終わりに 1 回呼ぶ。監視を外し、バックグラウンドタスクを終了する
    @MainActor
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        end()
    }

    /// 今のバックグラウンドタスクを終了する(時間切れ・実行の終わり)。何度呼んでもよい
    @MainActor
    func end() {
        lock.lock()
        let id = identifier
        identifier = nil
        lock.unlock()
        if let id {
            UIApplication.shared.endBackgroundTask(id)
        }
    }
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

/// 投げっぱなしの Task から届く状態表示の順番づけ。next() は通知を作った順の番号、
/// claim(_:) はそれまでに反映した番号より新しいときだけ true(古い通知を捨てる)。スレッドセーフ
/// 準備中の状態文を受け付ける間だけ true。準備が終わったあとに遅れて届いた状態文で、次の表示を上書きしないため
private final class PhaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func end() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

/// Whisper の読み込みが始まった時刻(どのスレッドからでも読める)
private final class LoadClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Date?

    func start() {
        lock.lock()
        if startedAt == nil { startedAt = Date() }
        lock.unlock()
    }

    /// 読み込みが始まってからの秒数(まだなら nil)
    var elapsed: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt.map { Date().timeIntervalSince($0) }
    }
}

private final class StatusSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private var applied = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        issued += 1
        return issued
    }

    func claim(_ sequence: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > applied else { return false }
        applied = sequence
        return true
    }
}

/// Whisper 1 回の実行(全クリップ)の進捗の集計。
/// - ピース番号/全ピース数は WhisperTranscriber の約 5 分のピース単位(まだ始めていないクリップは見込み数)
/// - 全体の進み具合は音声の長さの比
/// - 残り時間は、完了したピースの「音声 1 秒あたりの推論秒」から見積もる(最初のピースが終わってから表示)
/// スレッドセーフ(WhisperTranscriber の進捗は任意のスレッドから届く)
private final class WhisperRunState: @unchecked Sendable {
    struct Display {
        let overall: Double
        let text: String
        let sequence: Int
    }

    private let lock = NSLock()
    private let clipSeconds: [Double]
    private let estimatedPieces: [Int]
    private let sequence = StatusSequence()
    /// 完了したクリップの集計
    private var finishedAudio = 0.0
    private var finishedActive = 0.0
    private var finishedPieces = 0
    /// 認識中のクリップの最新の進捗
    private var current: WhisperTranscriptionProgress?

    init(clipSeconds: [Double]) {
        self.clipSeconds = clipSeconds
        self.estimatedPieces = clipSeconds.map { WhisperTranscriber.estimatedPieceCount(seconds: $0) }
    }

    func claim(_ value: Int) -> Bool {
        sequence.claim(value)
    }

    /// clipIndex のクリップの進捗を反映し、表示する全体の進捗と状態文を返す(progress が nil なら開始前)
    func update(clipIndex: Int, progress: WhisperTranscriptionProgress?) -> Display {
        lock.lock()
        defer { lock.unlock() }
        if let progress { current = progress }
        let p = progress ?? current

        let index = min(max(clipIndex, 0), max(clipSeconds.count - 1, 0))
        let later = clipSeconds.isEmpty ? [] : Array((index + 1)..<clipSeconds.count)
        let laterPieces = later.reduce(0) { $0 + estimatedPieces[$1] }
        let laterAudio = later.reduce(0.0) { $0 + clipSeconds[$1] }
        let clipEstimatePieces = clipSeconds.isEmpty ? 1 : estimatedPieces[index]
        let clipEstimateAudio = clipSeconds.isEmpty ? 0 : clipSeconds[index]

        let currentTotalPieces = max(1, p?.totalPieces ?? clipEstimatePieces)
        let currentCompleted = p?.completedPieces ?? 0
        let totalPieces = finishedPieces + currentTotalPieces + laterPieces
        let pieceNumber = finishedPieces + min(currentCompleted + 1, currentTotalPieces)

        let currentAudio = (p?.totalAudioSeconds ?? 0) > 0 ? (p?.totalAudioSeconds ?? 0) : clipEstimateAudio
        let totalAudio = finishedAudio + currentAudio + laterAudio
        let doneInClip = p.map { $0.fraction * $0.totalAudioSeconds } ?? 0
        let overall = totalAudio > 0 ? min(max((finishedAudio + doneInClip) / totalAudio, 0), 1) : 0

        var text = TranscriptionService.whisperStatusPrefix
            + " \(pieceNumber)/\(totalPieces) ・ 約\(Int(overall * 100))%"

        // 残り時間(完了したピースが 1 つ以上あるときだけ)
        let processed = finishedAudio + (p?.processedAudioSeconds ?? 0)
        let active = finishedActive + (p?.activeSeconds ?? 0)
        if processed > 0, active > 0 {
            let secondsPerAudioSecond = active / processed
            let remaining = max(0, secondsPerAudioSecond * max(0, totalAudio - processed) - (p?.currentPieceElapsed ?? 0))
            text += " ・ " + Self.remainingText(remaining)
        }

        return Display(overall: overall, text: text, sequence: sequence.next())
    }

    /// clipIndex のクリップが終わったら呼ぶ(最新の進捗を完了分として積む)
    func finishClip(clipIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        let index = min(max(clipIndex, 0), max(clipSeconds.count - 1, 0))
        if let p = current {
            finishedAudio += p.totalAudioSeconds
            finishedActive += p.activeSeconds
            finishedPieces += p.completedPieces
        } else if !clipSeconds.isEmpty {
            // 進捗が届かなかった(音声が空だったなど)
            finishedAudio += clipSeconds[index]
            finishedPieces += estimatedPieces[index]
        }
        current = nil
    }

    /// 「残り約 6分」「残り約 1時間5分」「残り1分未満」
    private static func remainingText(_ seconds: Double) -> String {
        if seconds < 60 { return String(localized: "残り1分未満") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 60 {
            return "残り約 \(minutes / 60)時間\(minutes % 60)分"
        }
        return String(localized: "残り約 \(minutes)分")
    }
}

@Observable
final class TranscriptionService {
    private(set) var isRunning: Bool = false
    private(set) var progress: Double = 0
    /// Whisper のモデルを準備(ダウンロード・読み込み)している間は true。進み具合は % ではなく「準備中」として見せる
    private(set) var isPreparingModel: Bool = false
    /// Whisper の準備が switchOfferDelay を過ぎたら true。画面に「Apple 音声認識で今すぐ作る」を出す
    private(set) var canSwitchToApple: Bool = false
    private(set) var statusText: String = ""

    /// Whisper の準備がこれより長くかかったら、Apple 音声認識への切り替えを出す
    private static let switchOfferDelay: UInt64 = 60_000_000_000

    /// SFSpeech 経路の 1チャンクの最大長(秒)
    private static let chunkLength: Double = 50

    /// バックグラウンド待ちの間の状態表示
    private static let pausedStatusText = String(localized: "画面がロックされたため一時停止中。アプリに戻ると続きから再開します")
    /// 継続処理か背景送信が動いているあいだのロック中の状態表示
    private static let lockedStatusText = String(localized: "ロック中も処理を続けています")

    /// 「一時停止中」「ロック中も…」のどちらかを表示しているか
    private static func isInterruptionStatus(_ text: String) -> Bool {
        text == pausedStatusText || text == lockedStatusText
    }

    private let lock = NSLock()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var currentTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var runningWork: Task<[SubtitleCue], Error>?
    /// この回の Whisper の準備(switchToAppleSpeech で待つのをやめるために持つ。lock で保護)
    @ObservationIgnored private var whisperPrepareTask: Task<Void, Error>?
    @ObservationIgnored private var switchToAppleRequested = false
    /// 「一時停止中」「ロック中も…」を表示する直前の状態表示(再開したら戻す)。メインアクターからだけ触る
    @ObservationIgnored private var statusBeforePause: String?
    /// 実行中の継続処理(lock で保護)
    @ObservationIgnored private var continuedHandleStorage: ContinuedProcessingHandle?
    /// 状態表示の切り替えに使う、実行中の reporter(メインアクターからだけ触る)
    @ObservationIgnored private var activeReporters: [BackgroundPauseReporter] = []
    /// アプリがバックグラウンドにいるか(この実行の間だけ通知で更新する。メインアクターからだけ触る)
    @ObservationIgnored private var appInBackground = false
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lifecycleGeneration = 0

    init() {}

    // MARK: - 公開 API

    func requestAuthorization() async -> Bool {
        // Apple 以外のエンジンは iOS の音声認識権限を使わない
        guard AppSettings.shared.transcriptionEngine == .apple else { return true }
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

        // 画面ロック・アプリ切り替えの直後も、送信中のリクエストが終わるまで(約 30 秒)動けるようにする。
        // 時間切れで終了しても、フォアグラウンドに戻るたびに取り直す(willEnterForeground の監視はこの実行の間だけ)。
        // 継続処理が使えるときも併せて持つ(継続処理の開始が遅れた間・使えなかったときの代わり)。
        // 監視の解除と終了は成功・失敗・キャンセルのどの場合も defer で(メインアクターで)行う
        let backgroundTask = TranscriptionBackgroundTask()
        await backgroundTask.begin()

        // 画面ロックなどでバックグラウンド待ちになったら状態表示を「一時停止中」にし、再開したら元に戻す。
        // reporter はクラウド・AI 仕上げ用(継続処理が動いている間はバックグラウンドでも待たない)、
        // whisperReporter は Whisper 用(常にフォアグラウンドに戻るまで待つ)
        let reporter = makePauseReporter()
        let whisperReporter = makePauseReporter()

        // iOS 26+: ロック中も続けられるよう継続処理を始める(使えなければ nil。beginBackgroundTask だけで動く)
        let subtitle = Self.continuedProcessingSubtitle(for: snapshot)
        let handle = await beginContinuedProcessing(subtitle: subtitle, reporter: reporter)
        let lifecycleToken = await startObservingLifecycle(reporters: [reporter, whisperReporter])
        var succeeded = false
        defer {
            handle?.finish(success: succeeded)
            if let handle {
                clearContinuedHandle(handle)
            }
            Task { @MainActor in
                backgroundTask.finish()
                self.stopObservingLifecycle(generation: lifecycleToken)
            }
        }

        await updateUI(running: true, progress: 0, status: String(localized: "準備中…"))

        let work = Task<[SubtitleCue], Error> {
            try await self.performTranscription(snapshot: snapshot, language: language, removeFillers: removeFillers,
                                                pauseReporter: reporter, whisperReporter: whisperReporter)
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
            succeeded = true
            finishRun()
            await updateUI(running: false, progress: 1, status: String(localized: "完了(\(cues.count)件)"))
            return cues
        } catch {
            finishRun()
            let cancelled = error is CancellationError
            await updateUI(running: false, progress: 0,
                           status: cancelled ? String(localized: "キャンセルしました") : String(localized: "失敗しました"))
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

    /// Whisper の準備を待たずに、この回だけ Apple 音声認識で作る。モデルの読み込みは裏で続け、次回に使う。
    /// 画面のボタンから(メインスレッドで)呼ぶ。2 度押しされないよう、ボタンはすぐ消す
    func switchToAppleSpeech() {
        canSwitchToApple = false
        lock.lock()
        let task = whisperPrepareTask
        if task != nil { switchToAppleRequested = true }
        lock.unlock()
        task?.cancel()
    }

    /// 前回(アプリの終了などで)取り込めなかったクラウド文字起こしのジョブから、出力タイムライン秒の字幕を作り直す。
    /// - まだ送信中のジョブなら残りを待つ(キャンセルしても待つのをやめるだけで、ジョブの送信は続く)。
    /// - 時刻は今のプロジェクト(snapshot)のクリップ配置・トリミング・速度で出力タイムラインに直す。
    ///   今のトリミング範囲の外のトークンと、プロジェクトに無いクリップの結果は捨てる。
    /// - 字幕の区切り方はジョブの言語(無ければ language)。AI 仕上げが有効なら仕上げてから返す。
    /// 実行中は isRunning / progress / statusText が変わり、cancel() で止められる。
    /// 取り込みが済んだら呼び出し側で CloudBackgroundUploader.shared.discard(jobID:) すること
    func cues(fromPendingJob job: CloudJobManifest, snapshot: ProjectSnapshot,
              language: TranscriptionLanguage, removeFillers: Bool = true) async throws -> [SubtitleCue] {
        lock.lock()
        if busy {
            lock.unlock()
            throw TranscriptionError.alreadyRunning
        }
        busy = true
        cancelRequested = false
        lock.unlock()

        await updateUI(running: true, progress: 0, status: String(localized: "前回の文字起こし結果を取り込み中…"))

        let work = Task<[SubtitleCue], Error> {
            try await self.rebuildCues(fromPendingJob: job, snapshot: snapshot, language: language,
                                       removeFillers: removeFillers)
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
            await updateUI(running: false, progress: 1, status: String(localized: "取り込みました(\(cues.count)件)"))
            return cues
        } catch {
            finishRun()
            let cancelled = error is CancellationError
            await updateUI(running: false, progress: 0,
                           status: cancelled ? String(localized: "キャンセルしました") : String(localized: "取り込めませんでした"))
            throw error
        }
    }

    // MARK: - 本体

    private func performTranscription(snapshot: ProjectSnapshot,
                                      language: TranscriptionLanguage,
                                      removeFillers: Bool,
                                      pauseReporter: BackgroundPauseReporter,
                                      whisperReporter: BackgroundPauseReporter) async throws -> [SubtitleCue] {
        let settings = AppSettings.shared
        let requestedEngine = settings.transcriptionEngine

        // エンジンごとの前提条件
        switch requestedEngine {
        case .apple:
            if SFSpeechRecognizer.authorizationStatus() != .authorized {
                let granted = await requestAuthorization()
                guard granted else { throw TranscriptionError.notAuthorized }
            }
        case .whisper:
            guard WhisperTranscriber.isAvailable else { throw WhisperTranscriberError.unavailable }
        case .cloud:
            guard settings.isCloudConfigured else { throw CloudTranscriptionError.missingAPIKey }
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

        // Whisper: モデルの準備(ダウンロード・読み込み)。字幕の画面を開いたときに先読みしていれば、すぐ終わる。
        // 状態文は「Whisperモデルをダウンロード中 45%」→「Whisperモデルを読み込み中… — 経過 20秒」。
        // 投げっぱなしの Task は順不同・遅れて届くことがあるので、番号が新しく、まだ準備の段階のときだけ書き換える
        // (文の書き出しでは見分けない。訳文では「Whisperモデル」で始まらないため)
        var whisperRun: WhisperRunState? = nil
        // 準備が長くて「Apple 音声認識で今すぐ作る」が押されたら、この回だけ Apple 音声認識で作る
        var switchedToApple = false
        if requestedEngine == .whisper {
            await updateUI(status: String(localized: "Whisperモデルを確認中…"))
            await MainActor.run { self.isPreparingModel = true }
            let prepareSequence = StatusSequence()
            let preparePhase = PhaseFlag()
            defer { preparePhase.end() }
            switchedToApple = try await prepareWhisperOrSwitch(model: settings.whisperModel) { [weak self] _, status in
                guard let self else { return }
                let seq = prepareSequence.next()
                Task {
                    // 準備の進み具合は状態文(「ダウンロード中 45%」など)で見せ、全体の % には入れない
                    // (入れると、読み込みの間ずっと「100%」のまま止まって見えた)
                    await self.applyRunningStatus(status, progress: nil, prefix: "",
                                                  isCurrent: { preparePhase.isActive && prepareSequence.claim(seq) })
                }
            }
            preparePhase.end()
            await MainActor.run {
                self.isPreparingModel = false
                self.canSwitchToApple = false
            }
            try checkCancelled()
            if switchedToApple {
                if SFSpeechRecognizer.authorizationStatus() != .authorized {
                    let granted = await Self.requestSpeechAuthorization()
                    guard granted else { throw TranscriptionError.notAuthorized }
                }
                try checkCancelled()
                await updateUI(progress: 0, status: String(localized: "Apple 音声認識で字幕を作っています…"))
            } else {
                whisperRun = WhisperRunState(clipSeconds: jobs.map { $0.clip.trimmedDuration })
                await updateUI(progress: 0, status: TranscriptionService.whisperStatusPrefix + "…")
            }
        }
        let engine: TranscriptionEngine = switchedToApple ? .apple : requestedEngine
        // 使い終わってもすぐには解放しない(すぐ作り直すときに読み込み直さないよう、しばらく置いてから解放する)
        if engine == .whisper { WhisperTranscriber.shared.beginUse() }
        defer {
            if engine == .whisper { WhisperTranscriber.shared.endUse() }
        }

        // 従来の認識器は必要になったときだけ作る
        var legacyRecognizer: SFSpeechRecognizer?

        var cues: [SubtitleCue] = []

        // クラウド: 全クリップの音声を先に切り出し、背景 URLSession にまとめて預ける(ロック中・アプリが止められた後も
        // 送信が続く)。作業フォルダを作れないなど使えないとき(nil)は、クリップごとの従来の経路
        var cloudTokens: [[TimedToken]]? = nil
        if engine == .cloud {
            cloudTokens = try await recognizeAllClipsWithCloud(jobs: jobs, language: language, apiKey: settings.cloudCredential,
                                                               quality: settings.cloudQuality,
                                                               pauseReporter: pauseReporter)
            try checkCancelled()
        }

        for (jobIndex, job) in jobs.enumerated() {
            try checkCancelled()

            // 元素材上の秒で揃えたトークン列
            var sourceTokens: [TimedToken]? = nil

            switch engine {
            case .apple:
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
            case .whisper:
                // Whisper は継続処理中でもバックグラウンドでは推論しない(フォアグラウンドに戻るまで待つ)
                let run = whisperRun ?? WhisperRunState(clipSeconds: jobs.map { $0.clip.trimmedDuration })
                whisperRun = run
                sourceTokens = try await recognizeClipWithWhisper(job: job, clipIndex: jobIndex, language: language,
                                                                  run: run, pauseReporter: whisperReporter)
                run.finishClip(clipIndex: jobIndex)
            case .cloud:
                if let cloudTokens {
                    sourceTokens = jobIndex < cloudTokens.count ? cloudTokens[jobIndex] : []
                } else {
                    sourceTokens = try await recognizeClipWithCloud(job: job, language: language, apiKey: settings.cloudCredential,
                                                                    quality: settings.cloudQuality,
                                                                    clipIndex: jobIndex, clipCount: jobs.count,
                                                                    doneUnits: doneUnits, totalUnits: totalUnits,
                                                                    pauseReporter: pauseReporter)
                }
            }
            doneUnits += job.chunks.count
            try checkCancelled()

            // 元素材時刻 → 出力タイムライン時刻 に変換してから文単位に区切る
            let timelineTokens = Self.mapToTimeline(sourceTokens ?? [], job: job)
            var segmenter = SubtitleSegmenter(language: language, removeFillers: removeFillers)
            segmenter.hardEnd = job.clipTimelineEnd
            cues.append(contentsOf: segmenter.segment(timelineTokens))

            // まとめて送った経路は、送信の進捗ですでに 1 まで進めている。
            // Whisper は音声の長さの比で進めている(ピースの完了通知で反映済み)
            if cloudTokens == nil, engine != .whisper {
                await updateUI(progress: Double(doneUnits) / Double(totalUnits), status: nil)
            }
        }

        let result = Self.finalize(cues)

        // AI 仕上げ(句読点・フィラー・分割)。失敗しても result はそのまま返る。
        // 継続処理が動いている間は pauseReporter.allowsBackgroundWork が true なので、ロック中でも待たずに進む
        return try await polishIfEnabled(result, language: language, settings: settings, pauseReporter: pauseReporter)
    }

    /// AI 仕上げが有効なら仕上げて並べ直す(失敗した部分は入力のまま)
    private func polishIfEnabled(_ cues: [SubtitleCue], language: TranscriptionLanguage, settings: AppSettings,
                                 pauseReporter: BackgroundPauseReporter) async throws -> [SubtitleCue] {
        guard settings.polishSubtitles, !cues.isEmpty else { return cues }
        let polishEngine = SubtitlePolisher.resolveEngine(settings: settings)
        guard polishEngine != .none else { return cues }
        try checkCancelled()
        await updateUI(progress: 1, status: String(localized: "AIで字幕を仕上げ中(\(SubtitlePolisher.displayName(of: polishEngine)))…"))
        let polished = await SubtitlePolisher.polish(cues, language: language, settings: settings,
                                                     pauseReporter: pauseReporter)
        try checkCancelled()
        return Self.finalize(polished)
    }

    // MARK: - 前回のクラウド文字起こしの取り込み

    private func rebuildCues(fromPendingJob job: CloudJobManifest, snapshot: ProjectSnapshot,
                             language: TranscriptionLanguage, removeFillers: Bool) async throws -> [SubtitleCue] {
        let uploader = CloudBackgroundUploader.shared
        let jobLanguage = job.localeIdentifier.flatMap { TranscriptionLanguage(rawValue: $0) } ?? language

        // まだ送信中なら残りを待つ(すでにそろっていればすぐに返る)
        let results: [Int: Data]
        do {
            results = try await uploader.waitForCompletion(jobID: job.id, cancelsTasksOnCancellation: false) { [weak self] done, total in
                guard let self else { return }
                let value = total > 0 ? Double(done) / Double(total) : 0
                let text = done < total
                    ? String(localized: "前回の文字起こしの残りを待っています \(done)/\(total)")
                    : String(localized: "前回の文字起こし結果を取り込み中…")
                // 後続の段階(AI 仕上げなど)に進んだあとに遅れて届いた通知では書き換えない
                Task { await self.applyRunningStatus(text, progress: value, prefix: String(localized: "前回の文字起こし")) }
            }
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
        try checkCancelled()

        let latest = uploader.job(withID: job.id) ?? job
        let perClip = try CloudTranscriber.tokensByClipOrder(job: latest, results: results)

        // 今のプロジェクトのクリップ配置で出力タイムラインに直す
        let placements = Self.clipPlacements(for: snapshot)
        var cues: [SubtitleCue] = []
        var matchedClips = 0
        for info in latest.clips {
            guard info.order >= 0, info.order < perClip.count,
                  let placement = placements[info.clipID] else { continue }
            matchedClips += 1
            let clip = placement.clip
            // 今のトリミング範囲から外れたトークンは捨てる(残りは mapToTimeline が範囲内に収める)
            let inside = perClip[info.order].filter { $0.end >= clip.startTime && $0.start <= clip.endTime }
            let timelineTokens = Self.mapToTimeline(inside, job: placement)
            var segmenter = SubtitleSegmenter(language: jobLanguage, removeFillers: removeFillers)
            segmenter.hardEnd = placement.clipTimelineEnd
            cues.append(contentsOf: segmenter.segment(timelineTokens))
        }
        guard matchedClips > 0 else {
            throw TranscriptionError.pendingResultUnusable(String(localized: "このプロジェクトには、前回の文字起こしに使ったクリップがありません。"))
        }

        let result = Self.finalize(cues)
        await updateUI(progress: 1, status: nil)
        return try await polishIfEnabled(result, language: jobLanguage, settings: AppSettings.shared,
                                         pauseReporter: makePauseReporter())
    }

    /// プロジェクトの全クリップの出力タイムライン上の配置(クリップ ID → ClipJob。chunks は使わない)
    private static func clipPlacements(for snapshot: ProjectSnapshot) -> [UUID: ClipJob] {
        var result: [UUID: ClipJob] = [:]
        // 開始位置はトランジションの重なりを引いた、再生・書き出しと同じ配置
        let layout = CompositionBuilder.timelineLayout(for: snapshot)
        var timelineStart = 0.0
        for (i, clip) in snapshot.clips.enumerated() {
            let start = i < layout.count ? layout[i].start : timelineStart
            result[clip.id] = ClipJob(clip: clip, clipTimelineStart: start, chunks: [])
            timelineStart += clip.outputDuration
        }
        return result
    }

    // MARK: - Whisper(端末内)/ クラウドAI

    /// Whisper の状態文の先頭(applyRunningStatus の prefix にも使う)
    fileprivate static let whisperStatusPrefix = String(localized: "文字起こし中(Whisper)")

    /// クリップ全体を WhisperKit で認識し、元素材上の秒のトークン列を返す。
    /// 状態文は「文字起こし中(Whisper) 3/7 ・ 約12% ・ 残り約 6分」(認識中のピース番号/全ピース数。
    /// 単位は WhisperTranscriber の約 5 分のピースで、SFSpeech 用の 50 秒チャンク数ではない)
    private func recognizeClipWithWhisper(job: ClipJob, clipIndex: Int, language: TranscriptionLanguage,
                                          run: WhisperRunState,
                                          pauseReporter: BackgroundPauseReporter) async throws -> [TimedToken] {
        let clip = job.clip
        let initial = run.update(clipIndex: clipIndex, progress: nil)
        _ = run.claim(initial.sequence)
        await updateUI(progress: initial.overall, status: initial.text)
        do {
            return try await WhisperTranscriber.shared.transcribe(sourceURL: clip.url, start: clip.startTime, end: clip.endTime,
                                                                   language: language.languageCode,
                                                                   pauseReporter: pauseReporter) { [weak self] update in
                guard let self else { return }
                let state = run.update(clipIndex: clipIndex, progress: update)
                // 投げっぱなしの Task は順不同に届くことがあるので、番号が新しいときだけ書き換える
                Task {
                    await self.applyRunningStatus(state.text, progress: state.overall,
                                                  prefix: TranscriptionService.whisperStatusPrefix,
                                                  isCurrent: { run.claim(state.sequence) })
                }
            }
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    /// クリップ全体をクラウド(OpenAI)で認識し、元素材上の秒のトークン列を返す。
    /// 状態表示は「文字起こし中(クラウドAI・速度優先) 3/12」(完了ピース数/全ピース数。複数クリップならクリップ番号も)
    private func recognizeClipWithCloud(job: ClipJob, language: TranscriptionLanguage, apiKey: String,
                                        quality: CloudTranscriptionQuality, clipIndex: Int, clipCount: Int,
                                        doneUnits: Int, totalUnits: Int,
                                        pauseReporter: BackgroundPauseReporter) async throws -> [TimedToken] {
        let clip = job.clip
        let label = String(localized: "文字起こし中(クラウドAI・\(quality.shortName))")
        let clipPrefix = clipCount > 1 ? String(localized: "\(label) クリップ\(clipIndex + 1)/\(clipCount)") : label
        let separator = clipCount > 1 ? "・" : " "
        await updateUI(progress: Double(doneUnits) / Double(totalUnits), status: clipPrefix + "…")
        let unitCount = Double(job.chunks.count)
        do {
            return try await CloudTranscriber.shared.transcribe(
                sourceURL: clip.url, start: clip.startTime, end: clip.endTime,
                language: language.languageCode, apiKey: apiKey, quality: quality,
                pauseReporter: pauseReporter,
                progress: { [weak self] fraction in
                    guard let self else { return }
                    let value = (Double(doneUnits) + fraction * unitCount) / Double(totalUnits)
                    Task { await self.updateUI(progress: value, status: nil) }
                },
                pieceProgress: { [weak self] completed, total in
                    guard let self else { return }
                    let text = clipPrefix + separator + "\(completed)/\(total)"
                    // 投げっぱなしの Task は後続の状態更新(次のクリップ・AI仕上げ・完了など)より遅れて届くことがあるので、
                    // まだこのクリップの表示中のときだけ書き換える
                    Task {
                        await self.applyRunningStatus(text, progress: nil, prefix: clipPrefix)
                    }
                })
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    /// 全クリップをまとめてクラウド(OpenAI)で認識し、jobs と同じ順に元素材上の秒のトークン列を返す
    /// (CloudTranscriber.transcribeClips: 全ピースを先に切り出して背景 URLSession に預ける)。
    /// 作業フォルダを作れないなど、この経路を使えないときは nil(呼び出し側はクリップごとの従来の経路へ)。
    /// 状態表示は「文字起こし中(クラウドAI・速度優先) 音声を準備中 3/12」→「文字起こし中(クラウドAI・速度優先) 5/12」
    private func recognizeAllClipsWithCloud(jobs: [ClipJob], language: TranscriptionLanguage, apiKey: String,
                                            quality: CloudTranscriptionQuality,
                                            pauseReporter: BackgroundPauseReporter) async throws -> [[TimedToken]]? {
        let label = String(localized: "文字起こし中(クラウドAI・\(quality.shortName))")
        await updateUI(progress: 0, status: label + "…")
        let sources: [CloudTranscriber.ClipSource] = jobs.map { job in
            CloudTranscriber.ClipSource(clipID: job.clip.id, name: job.clip.name, sourceURL: job.clip.url,
                                        sourceStart: job.clip.startTime, sourceEnd: job.clip.endTime,
                                        speed: job.clip.speed, timelineStart: job.clipTimelineStart,
                                        timelineEnd: job.clipTimelineEnd)
        }
        do {
            return try await CloudTranscriber.shared.transcribeClips(
                sources, language: language.languageCode, localeIdentifier: language.rawValue,
                apiKey: apiKey, quality: quality, pauseReporter: pauseReporter) { [weak self] update in
                    guard let self else { return }
                    let text = TranscriptionService.cloudBatchStatus(label: label, update: update)
                    let value = TranscriptionService.cloudBatchProgress(update)
                    Task {
                        await self.applyRunningStatus(text, progress: value, prefix: label)
                    }
                }
        } catch let error as CloudBackgroundUploaderError {
            if case .unavailable(_) = error { return nil }
            throw error
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private static func cloudBatchStatus(label: String, update: CloudTranscriber.BatchProgress) -> String {
        let counts = "\(update.completed)/\(update.total)"
        switch update.phase {
        case .preparing:
            return label + String(localized: " 音声を準備中 ") + counts
        case .transcribing:
            return label + " " + counts
        }
    }

    /// 切り出しを全体の 1 割、送信・認識を 9 割として数える
    private static func cloudBatchProgress(_ update: CloudTranscriber.BatchProgress) -> Double {
        let fraction = update.fraction
        switch update.phase {
        case .preparing:
            return fraction * 0.1
        case .transcribing:
            return 0.1 + fraction * 0.9
        }
    }

    /// 投げっぱなしの Task から届く進捗の表示。まだ prefix で始まる表示のとき(後続の段階に進んでいないとき)だけ書き換える。
    /// 「一時停止中」「ロック中も…」の表示中は、戻したときに出す文言だけを最新にする。progress は戻さない(大きいときだけ進める)
    /// isCurrent を渡したときは、メインアクター上でそれが true を返したときだけ書き換える(古い通知を捨てる)
    private func applyRunningStatus(_ text: String, progress value: Double?, prefix: String,
                                    isCurrent: (() -> Bool)? = nil) async {
        let handle = continuedHandle
        await MainActor.run {
            guard self.isRunning else { return }
            if let isCurrent, !isCurrent() { return }
            var applied = false
            if self.statusText.hasPrefix(prefix) {
                self.statusText = text
                applied = true
            } else if TranscriptionService.isInterruptionStatus(self.statusText),
                      let saved = self.statusBeforePause, saved.hasPrefix(prefix) {
                self.statusBeforePause = text
                applied = true
            }
            guard applied else { return }
            if let value {
                self.progress = max(self.progress, min(max(value, 0), 1))
            }
            handle?.update(completed: self.progress, subtitle: text)
        }
    }

    private static func makeJobs(for snapshot: ProjectSnapshot) -> [ClipJob] {
        var jobs: [ClipJob] = []
        // 各クリップの開始位置は、再生・書き出しと同じ配置(トランジションの重なりを引いたもの)を使う。
        // 以前は長さを足すだけだったので、トランジションのたびに字幕が重なりの分だけ遅れ、
        // カットしてクリップが多いほど後半の字幕がどんどん遅れていた(1.12.47 まで)
        let layout = CompositionBuilder.timelineLayout(for: snapshot)
        var timelineStart = 0.0
        for (index, clip) in snapshot.clips.enumerated() {
            let clipStart = index < layout.count ? layout[index].start : timelineStart
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

    /// 元素材上の秒 → 出力タイムライン上の秒(トリミング・速度・速度カーブを反映)
    private static func mapToTimeline(_ tokens: [TimedToken], job: ClipJob) -> [TimedToken] {
        let clip = job.clip
        func convert(_ source: Double) -> Double {
            job.clipTimelineStart + clip.outputOffset(atSourceTime: source)
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
            throw TranscriptionError.audioExportFailed(String(localized: "音声トラックがありません"))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExportFailed(String(localized: "書き出しセッションを作成できません"))
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
                await updateUI(status: String(localized: "音声認識モデルをダウンロード中…"))
                try await request.downloadAndInstall()
            }
        } catch {
            if isCancelRequested || Task.isCancelled || error is CancellationError { throw CancellationError() }
            return nil
        }
        try checkCancelled()

        let clip = job.clip
        await updateUI(progress: Double(doneUnits) / Double(totalUnits),
                       status: String(localized: "文字起こし中 \(doneUnits + 1)/\(totalUnits)"))

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
                           status: String(localized: "文字起こし中 \(unit + 1)/\(totalUnits)"))

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
                sorted[i].words = SubtitleSegmenter.clampWords(sorted[i].words, start: sorted[i].start, end: sorted[i].end)
            }
        }
        return sorted
    }

    // MARK: - 状態管理

    /// Whisper のモデルを準備する。待っている間に switchToAppleSpeech が呼ばれたら、待つのをやめて true を返す
    /// (読み込みは WhisperTranscriber が裏で最後まで続け、次回に使う)。switchOfferDelay を過ぎたら切り替えのボタンを出す
    private func prepareWhisperOrSwitch(model: String,
                                        progress: @escaping (Double, String) -> Void) async throws -> Bool {
        // 数え始めるのは読み込みに入ってから(ダウンロード中に待つのをやめると、ダウンロードが捨てられるため)
        let loadClock = LoadClock()
        let task = Task<Void, Error> {
            try await WhisperTranscriber.shared.prepare(model: model,
                                                        onLoadStart: { loadClock.start() },
                                                        progress: progress)
        }
        lock.lock()
        switchToAppleRequested = false
        whisperPrepareTask = task
        lock.unlock()
        let offer = Task { [weak self] in
            let delay = Double(Self.switchOfferDelay) / 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let elapsed = loadClock.elapsed, elapsed >= delay { break }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 準備が終わった直後に遅れて届いたときは出さない(終わった側が先に cancel している)
                guard !Task.isCancelled else { return }
                self?.canSwitchToApple = true
            }
        }
        defer {
            offer.cancel()
            lock.lock()
            whisperPrepareTask = nil
            lock.unlock()
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return false
        } catch {
            lock.lock()
            let switching = switchToAppleRequested && !cancelRequested
            lock.unlock()
            if switching && !Task.isCancelled {
                Analytics.shared.track("whisper_switch_apple")
                return true
            }
            throw error
        }
    }

    /// iOS の音声認識の許可を求める(設定のエンジンに関係なく。Whisper から切り替えたとき用)
    private static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
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

    /// 状態表示を更新する。実行中に「一時停止中」「ロック中も…」を表示しているときは、
    /// status は戻したときに出す文言として覚えておく(running を指定したとき=開始・終了は常に書き換える)。
    /// 継続処理が動いていれば、進捗と状態をシステムの表示にも渡す
    private func updateUI(running: Bool? = nil, progress: Double? = nil, status: String? = nil) async {
        let handle = continuedHandle
        await MainActor.run {
            if let running {
                self.isRunning = running
                if !running {
                    self.isPreparingModel = false
                    self.canSwitchToApple = false
                }
            }
            if let progress { self.progress = min(max(progress, 0), 1) }
            if let status {
                if running == nil, self.isRunning, TranscriptionService.isInterruptionStatus(self.statusText) {
                    self.statusBeforePause = status
                } else {
                    self.statusText = status
                    self.statusBeforePause = nil
                }
            }
            if self.isRunning, let handle, progress != nil || status != nil {
                handle.update(completed: self.progress, subtitle: status)
            }
        }
    }

    /// 状態表示の「一時停止中」「ロック中も処理を続けています」を今の状態に合わせる。
    /// - どれかの reporter がフォアグラウンド待ち中 → 一時停止中
    /// - バックグラウンドにいて、継続処理か背景送信が動いている → ロック中も処理を続けています
    /// - それ以外 → 元の表示に戻す
    /// 通知は順不同に届くので、通知の中身ではなくメインアクター上で今の状態を読み直す。
    /// 実行中のときだけ書き換える(完了・失敗の表示を上書きしない)
    @MainActor
    private func refreshInterruptionStatus() {
        guard isRunning else { return }
        let paused = activeReporters.contains { $0.isPaused }
        let desired: String?
        if paused {
            desired = TranscriptionService.pausedStatusText
        } else if appInBackground, keepsWorkingInBackground {
            desired = TranscriptionService.lockedStatusText
        } else {
            desired = nil
        }
        let showingInterruption = TranscriptionService.isInterruptionStatus(statusText)
        if let desired {
            if !showingInterruption {
                statusBeforePause = statusText
            }
            if statusText != desired {
                statusText = desired
            }
        } else if showingInterruption {
            statusText = statusBeforePause ?? String(localized: "文字起こし中…")
            statusBeforePause = nil
        }
    }

    /// 継続処理(期限切れでないもの)か、このプロセスの背景送信が動いているか
    private var keepsWorkingInBackground: Bool {
        if let handle = continuedHandle, !handle.wasExpired {
            return true
        }
        return CloudBackgroundUploader.shared.hasActiveUploads
    }

    private func makePauseReporter() -> BackgroundPauseReporter {
        BackgroundPauseReporter { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshInterruptionStatus()
            }
        }
    }

    /// この実行の間だけ、バックグラウンドへの出入りを監視して状態表示を切り替える。返す番号は stopObservingLifecycle に渡す
    @MainActor
    private func startObservingLifecycle(reporters: [BackgroundPauseReporter]) -> Int {
        removeLifecycleObservers()
        lifecycleGeneration += 1
        activeReporters = reporters
        appInBackground = UIApplication.shared.applicationState == .background
        let center = NotificationCenter.default
        let enter = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            // queue: .main なのでメインスレッドで呼ばれる
            guard let self else { return }
            MainActor.assumeIsolated {
                self.appInBackground = true
                self.refreshInterruptionStatus()
            }
        }
        let leave = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.appInBackground = false
                self.refreshInterruptionStatus()
            }
        }
        lifecycleObservers = [enter, leave]
        return lifecycleGeneration
    }

    /// startObservingLifecycle の監視を外す(その後に別の実行が始めた監視は外さない)
    @MainActor
    private func stopObservingLifecycle(generation: Int) {
        guard generation == lifecycleGeneration else { return }
        removeLifecycleObservers()
        activeReporters = []
        appInBackground = false
    }

    @MainActor
    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []
    }

    // MARK: - 継続処理(iOS 26+)

    private var continuedHandle: ContinuedProcessingHandle? {
        lock.lock()
        defer { lock.unlock() }
        return continuedHandleStorage
    }

    /// 実行の終わりに呼ぶ(その後に別の実行が始めた継続処理は外さない)
    private func clearContinuedHandle(_ handle: ContinuedProcessingHandle) {
        lock.lock()
        if continuedHandleStorage === handle {
            continuedHandleStorage = nil
        }
        lock.unlock()
    }

    /// 継続処理を始める(ユーザー操作の直後、アプリが前面にある間に呼ぶ)。使えなければ nil。
    /// 動いている間は reporter.allowsBackgroundWork を true にする(クラウド・AI 仕上げがロック中も待たない)。
    /// システムまたは利用者が止めたら false に戻す(以降はフォアグラウンド待ち。処理そのものは止めない)
    private func beginContinuedProcessing(subtitle: String,
                                          reporter: BackgroundPauseReporter) async -> ContinuedProcessingHandle? {
        let started: ContinuedProcessingHandle? = await MainActor.run {
            ContinuedProcessing.begin(kind: .transcribe, title: String(localized: "文字起こし"), subtitle: subtitle, wantsGPU: false)
        }
        guard let handle = started else { return nil }
        reporter.allowsBackgroundWork = true
        handle.onExpire = { [weak self] in
            reporter.allowsBackgroundWork = false
            guard let self else { return }
            Task { @MainActor in
                self.refreshInterruptionStatus()
            }
        }
        lock.lock()
        continuedHandleStorage = handle
        lock.unlock()
        return handle
    }

    /// システムの表示(ロック画面など)に出すサブタイトル。例:「クラウドAI・クリップ 2 本(12:34)」
    private static func continuedProcessingSubtitle(for snapshot: ProjectSnapshot) -> String {
        let jobs = makeJobs(for: snapshot)
        var seconds = 0.0
        for job in jobs {
            seconds += job.clip.trimmedDuration
        }
        let totalSeconds = Int(seconds.rounded())
        let length = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        let engineName = AppSettings.shared.transcriptionEngine.shortName
        return String(localized: "\(engineName)・クリップ \(jobs.count) 本(\(length))")
    }
}
