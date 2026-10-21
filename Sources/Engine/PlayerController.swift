import Foundation
import AVFoundation
import CoreGraphics
import Observation

/// プレビュー再生を管理する。プロジェクトの変更ごとに(0.3 秒デバウンスして)AVPlayerItem を作り直す。
/// UI から(メインスレッドで)呼ばれる前提。状態の更新はすべてメインスレッドで行う。
@Observable
final class PlayerController {
    /// メディアサービスのリセット後に作り直すので var(SwiftUI は player.player を読むと新しいものを受け取る)
    private(set) var player: AVPlayer

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isRebuilding: Bool = false
    private(set) var renderSize: CGSize = CGSize(width: 720, height: 1280)
    private(set) var errorMessage: String?

    /// 最後に合成を作ったスナップショットの「描画に関係する部分」(マーカー・表紙・クリップ名は除く)
    @ObservationIgnored private var lastSnapshot: ProjectSnapshot?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var generation: Int = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeeks: Int = 0

    /// ドラッグ中のシーク(追いかけシーク)の目標。nil ならスクラブしていない
    @ObservationIgnored private var scrubTarget: Double?
    /// 追いかけシークが実行中か(実行中は新しいシークを出さず、完了時に目標が動いていれば出し直す)
    @ObservationIgnored private var scrubSeekInFlight: Bool = false
    /// beginInteraction / endInteraction の入れ子の深さ。0 より大きい間は合成を作り直さない
    @ObservationIgnored private var interactionDepth: Int = 0
    /// 操作中に届いた最新のスナップショット(endInteraction で 1 回だけ反映する)
    @ObservationIgnored private var pendingSnapshot: ProjectSnapshot?
    /// 区間の繰り返し再生(トランジション選択中など)。nil なら通常再生
    @ObservationIgnored private var loopRange: ClosedRange<Double>?
    /// update(with:) が最後に受け取ったスナップショット(元のまま)。再生できなくなったときの作り直しに使う
    @ObservationIgnored private var latestSnapshot: ProjectSnapshot?
    /// いまの項目が再生できなくなったこと(.failed / 途中で再生できなくなった)の監視
    @ObservationIgnored private var itemFailureWatch: PlayerItemFailureWatch?
    /// 再生できなくなって自動で作り直した世代(同じ世代では 1 回だけ自動で作り直す)
    @ObservationIgnored private var autoRetryGeneration: Int?
    /// いまの項目が再生できなくなったと知らされたか(途中で止まったときは item.status が .readyToPlay のままのことがある)
    @ObservationIgnored private var currentItemFailed = false
    @ObservationIgnored private var resetObserver: NSObjectProtocol?

    init() {
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        installTimeObserver()
        // メディアサービスがリセットされる(mediaserverd の再起動)と、それまでの AVPlayer は使えなくなる
        resetObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.recreatePlayer()
        }
    }

    deinit {
        rebuildTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTick(time)
        }
    }

    // MARK: - Rebuild

    /// 描画結果に影響しない値(マーカー・表紙・クリップ名)を取り除いた比較用のスナップショット
    static func renderProjection(of snapshot: ProjectSnapshot) -> ProjectSnapshot {
        var projected = snapshot
        projected.markers = []
        projected.cover = CoverSettings()
        if projected.clips.contains(where: { !$0.name.isEmpty }) {
            for i in projected.clips.indices {
                projected.clips[i].name = ""
            }
        }
        return projected
    }

    /// スナップショットからプレビュー用の合成を作り直す(デバウンス約 0.3 秒、再生位置は維持)。
    /// 描画に関係しない変更(マーカー・表紙・クリップ名)は無視する。
    /// beginInteraction() 〜 endInteraction() の間は作り直さず、終了時に 1 回だけ反映する。
    func update(with snapshot: ProjectSnapshot) {
        latestSnapshot = snapshot
        let projected = PlayerController.renderProjection(of: snapshot)
        if interactionDepth > 0 {
            if let lastSnapshot, lastSnapshot == projected {
                pendingSnapshot = nil
            } else {
                pendingSnapshot = snapshot
            }
            return
        }
        pendingSnapshot = nil
        if let lastSnapshot, lastSnapshot == projected { return }
        lastSnapshot = projected

        rebuildTask?.cancel()
        generation += 1
        let currentGeneration = generation

        renderSize = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)

        if snapshot.isEmpty {
            rebuildTask = nil
            clearPlayer()
            return
        }

        isRebuilding = true
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            do {
                let built = try await CompositionBuilder.build(snapshot, purpose: .preview)
                if Task.isCancelled { return }
                guard let self, self.generation == currentGeneration else { return }
                self.install(built)
            } catch {
                if Task.isCancelled { return }
                guard let self, self.generation == currentGeneration else { return }
                self.isRebuilding = false
                self.errorMessage = String(localized: "プレビューを作成できませんでした: \(error.localizedDescription)")
            }
        }
    }

    /// トリム・並べ替え・移動などの連続操作の開始。終わるまで合成の作り直しを止める(入れ子可)
    func beginInteraction() {
        interactionDepth += 1
    }

    /// 連続操作の終了。最後の 1 つが終わったら、操作中に届いた変更を 1 回だけ反映する
    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        guard interactionDepth == 0, let pending = pendingSnapshot else { return }
        pendingSnapshot = nil
        update(with: pending)
    }

    private func clearPlayer() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        duration = 0
        currentTime = 0
        isPlaying = false
        isRebuilding = false
        errorMessage = nil
        scrubTarget = nil
        currentItemFailed = false
    }

    private func install(_ built: BuiltComposition) {
        let resumeTime = scrubTarget ?? currentTime
        let shouldPlay = isPlaying

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral

        removeEndObserver()
        // 合成のエラー・素材の消失・メディアサービスのリセットなどで再生できなくなったら作り直す
        itemFailureWatch = PlayerItemFailureWatch(item: item) { [weak self] failedItem, error in
            self?.handleItemFailure(failedItem, error: error)
        }
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let range = self.loopRange {
                // 繰り返し区間が作品の終わりまで続くときは、終わりで頭に戻す
                self.seek(to: range.lowerBound)
                self.player.play()
                self.isPlaying = true
            } else {
                self.isPlaying = false
            }
        }

        let seconds = built.duration.seconds
        duration = (seconds.isFinite && seconds > 0) ? seconds : 0
        renderSize = built.renderSize

        let upper = max(0, duration - 0.05)
        let target = min(max(0, resumeTime), upper)
        currentTime = target
        if target > 0 {
            pendingSeeks += 1
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingSeeks = max(0, self.pendingSeeks - 1)
                }
            }
        }
        if shouldPlay {
            player.play()
            isPlaying = true
        }
        isRebuilding = false
        errorMessage = nil
        currentItemFailed = false
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        itemFailureWatch = nil
    }

    // MARK: - 再生できなくなったときの立て直し

    /// 最後に受け取ったスナップショットから、内容が同じでも合成を作り直す(再生位置は維持)
    private func rebuildFromLatestSnapshot() {
        guard let snapshot = latestSnapshot else { return }
        lastSnapshot = nil
        update(with: snapshot)
    }

    /// いまの項目が再生できなくなったとき(status が .failed / 途中で再生できなくなった)。
    /// 1 回だけ自動で作り直し、作り直したものも失敗したらエラーを表示する
    private func handleItemFailure(_ item: AVPlayerItem, error: Error?) {
        guard item === player.currentItem else { return }
        currentItemFailed = true
        player.pause()
        isPlaying = false
        if autoRetryGeneration != generation, latestSnapshot != nil {
            if (error as? AVError)?.code == .mediaServicesWereReset || player.status == .failed {
                // メディアサービスのリセットは通知より先にここへ届くことがある。AVPlayer ごと作り直す
                recreatePlayer()
            } else {
                rebuildFromLatestSnapshot()
            }
            autoRetryGeneration = generation
            return
        }
        if let error {
            errorMessage = String(localized: "プレビューを再生できませんでした: \(error.localizedDescription)")
        } else {
            errorMessage = String(localized: "プレビューを再生できませんでした")
        }
    }

    /// メディアサービスのリセット後は、それまでの AVPlayer / AVPlayerItem が使えなくなる。
    /// 新しい AVPlayer を作り、最後のスナップショットから合成を作り直す(再生は勝手に再開しない)
    private func recreatePlayer() {
        rebuildTask?.cancel()
        rebuildTask = nil
        let wasMuted = player.isMuted
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)

        let newPlayer = AVPlayer()
        newPlayer.actionAtItemEnd = .pause
        // 録音中(イヤホンなし)のモニター用ミュートを引き継ぐ
        newPlayer.isMuted = wasMuted
        player = newPlayer
        installTimeObserver()

        pendingSeeks = 0
        scrubSeekInFlight = false
        scrubTarget = nil
        loopRange = nil
        isPlaying = false
        isRebuilding = false
        // リセット後はカテゴリが既定に戻っているので、再生用にし直す
        AudioSessionSetup.ensurePlayback()
        rebuildFromLatestSnapshot()
    }

    // MARK: - Time

    private func handleTick(_ time: CMTime) {
        if pendingSeeks == 0 && scrubTarget == nil {
            let seconds = time.seconds
            if seconds.isFinite {
                let clamped = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
                if abs(clamped - currentTime) > 0.0001 {
                    currentTime = clamped
                }
            }
        }
        let playing = player.currentItem != nil && player.timeControlStatus != .paused
        if let range = loopRange, playing, pendingSeeks == 0, scrubTarget == nil,
           currentTime >= range.upperBound || currentTime < range.lowerBound - 0.05 {
            seek(to: range.lowerBound)
        }
        if playing != isPlaying {
            isPlaying = playing
        }
    }

    private func clampedTime(_ seconds: Double) -> Double {
        let safe = seconds.isFinite ? seconds : 0
        if duration > 0 {
            return min(max(0, safe), duration)
        }
        return max(0, safe)
    }

    // MARK: - Transport

    /// 再生できなくなったままなら立て直す(AVPlayer ごと壊れていれば作り直す)。立て直したら true
    private func recoverIfFailed() -> Bool {
        if player.status == .failed {
            recreatePlayer()
            autoRetryGeneration = generation
            return true
        }
        if currentItemFailed || player.currentItem?.status == .failed {
            rebuildFromLatestSnapshot()
            autoRetryGeneration = generation
            return true
        }
        return false
    }

    func play() {
        guard player.currentItem != nil else { return }
        // 再生できなくなった項目のままなら作り直す(できあがったら、もう一度再生を押せば再生できる)
        if recoverIfFailed() { return }
        // マナーモードでも音が出るカテゴリで再生する
        AudioSessionSetup.ensurePlayback()
        scrubTarget = nil
        if duration > 0 && currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// 区間を繰り返し再生する(頭から再生を始める)
    func startLoop(_ range: ClosedRange<Double>) {
        let lower = clampedTime(range.lowerBound)
        let upper = max(lower + 0.2, clampedTime(range.upperBound))
        let newRange = lower...upper
        let changed = loopRange != newRange
        loopRange = newRange
        guard player.currentItem != nil else { return }
        if recoverIfFailed() { return }
        if changed || !isPlaying || currentTime < lower || currentTime > upper {
            seek(to: lower)
        }
        // マナーモードでも音が出るカテゴリで再生する(広告のあとなどでカテゴリが変わっていることがある)
        AudioSessionSetup.ensurePlayback()
        player.play()
        isPlaying = true
    }

    /// 繰り返し再生をやめて一時停止する
    func stopLoop() {
        guard loopRange != nil else { return }
        loopRange = nil
        pause()
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// 正確なシーク(前後の許容誤差 0)
    func seek(to seconds: Double) {
        let target = clampedTime(seconds)
        scrubTarget = nil
        currentTime = target
        guard player.currentItem != nil else { return }
        pendingSeeks += 1
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingSeeks = max(0, self.pendingSeeks - 1)
            }
        }
    }

    // MARK: - Scrub(ドラッグ中の追いかけシーク)

    /// ドラッグ中に呼ぶ。目標を記録し、シークが実行中でなければ許容誤差 0.1 秒でシークする。
    /// 実行中のシークが終わった時点で目標が動いていれば、最新の目標へシークし直す(要求はまとめられる)。
    func scrub(to seconds: Double) {
        let target = clampedTime(seconds)
        currentTime = target
        scrubTarget = target
        guard player.currentItem != nil else { return }
        if !scrubSeekInFlight {
            performChaseSeek(to: target)
        }
    }

    /// ドラッグの終了。最終位置へ正確にシークする
    func endScrub(at seconds: Double) {
        scrubTarget = nil
        seek(to: seconds)
    }

    private func performChaseSeek(to target: Double) {
        scrubSeekInFlight = true
        pendingSeeks += 1
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingSeeks = max(0, self.pendingSeeks - 1)
                self.scrubSeekInFlight = false
                guard let next = self.scrubTarget, self.player.currentItem != nil else { return }
                if abs(next - target) > 0.0005 {
                    self.performChaseSeek(to: next)
                }
            }
        }
    }
}

/// AVPlayerItem が再生できなくなったこと(status が .failed / 途中で再生できなくなった)を、
/// メインスレッドで 1 回だけ知らせる。破棄すると監視をやめる。
/// PlayerController と比較画面(CompareSyncController)で使う
final class PlayerItemFailureWatch {
    private let onFail: (AVPlayerItem, Error?) -> Void
    private var statusObservation: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?
    private var reported = false

    init(item: AVPlayerItem, onFail: @escaping (AVPlayerItem, Error?) -> Void) {
        self.onFail = onFail
        // status の KVO はどのスレッドで届くか決まっていないので、メインスレッドに移してから知らせる
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.report(observed, error: observed.error)
            }
        }
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                              object: item, queue: .main) { [weak self, weak item] notification in
            guard let item else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.report(item, error: error)
        }
    }

    deinit {
        statusObservation?.invalidate()
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
    }

    private func report(_ item: AVPlayerItem, error: Error?) {
        guard !reported else { return }
        reported = true
        onFail(item, error)
    }
}
