import Foundation
import AVFoundation
import CoreGraphics
import Observation

/// プレビュー再生を管理する。プロジェクトの変更ごとに(0.3 秒デバウンスして)AVPlayerItem を作り直す。
/// UI から(メインスレッドで)呼ばれる前提。状態の更新はすべてメインスレッドで行う。
@Observable
final class PlayerController {
    let player: AVPlayer

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

    init() {
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTick(time)
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
                self.errorMessage = "プレビューを作成できませんでした: \(error.localizedDescription)"
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
    }

    private func install(_ built: BuiltComposition) {
        let resumeTime = scrubTarget ?? currentTime
        let shouldPlay = isPlaying

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral

        removeEndObserver()
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.isPlaying = false
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
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
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

    func play() {
        guard player.currentItem != nil else { return }
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
