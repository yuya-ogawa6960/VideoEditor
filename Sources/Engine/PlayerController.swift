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

    @ObservationIgnored private var lastSnapshot: ProjectSnapshot?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var generation: Int = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeeks: Int = 0

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

    /// スナップショットからプレビュー用の合成を作り直す(デバウンス約 0.3 秒、再生位置は維持)
    func update(with snapshot: ProjectSnapshot) {
        if let lastSnapshot, lastSnapshot == snapshot { return }
        lastSnapshot = snapshot

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

    private func clearPlayer() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        duration = 0
        currentTime = 0
        isPlaying = false
        isRebuilding = false
        errorMessage = nil
    }

    private func install(_ built: BuiltComposition) {
        let resumeTime = currentTime
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

        let target = min(max(0, resumeTime), max(0, duration - 0.05))
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
        if pendingSeeks == 0 {
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

    // MARK: - Transport

    func play() {
        guard player.currentItem != nil else { return }
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

    func seek(to seconds: Double) {
        let safe = seconds.isFinite ? seconds : 0
        let target = duration > 0 ? min(max(0, safe), duration) : max(0, safe)
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
}
