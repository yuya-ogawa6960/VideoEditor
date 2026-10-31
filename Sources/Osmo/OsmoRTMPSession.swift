// =====================================================================
// 高画質モード(RTMP)の全体: iPhone の中の RTMP サーバー + Bluetooth の頼みごと + 表示 + 録画(実験中・開発者向け)
//
// 流れ:
//   1. OsmoRTMPServer で TCP 1935 を待つ(iPhone のインターネット共有の 172.20.10.1)
//   2a. OsmoRTMPLink でカメラに Bluetooth で頼む(インターネット共有に入る → RTMP の URL へ配信)
//   2b. または DJI Mimo の「ライブ配信」→「RTMP」に同じ URL を入れて、Mimo から始めてもらう(Bluetooth の命令は送らない)
//   3. 届いた映像は OsmoVideoDecoder で表示し、録画中は OsmoStreamRecorder でそのまま .mp4 に書く
//      (カメラの AAC があればそれを入れる。無ければ iPhone のマイク)
// UDP のライブビュー(OsmoLiveMonitor)とは同時に使えない(iPhone がカメラの Wi-Fi に入るか、カメラが iPhone に入るかの違い)。
// OsmoLiveMonitor.stop() がこちらも止める。実機ではまだ一度も試していない。docs/OsmoPocket.md の「RTMP で受ける」を参照。
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import Foundation
import Observation
import UIKit

/// サーバーのキューの上で、届いた映像・音を表示と録画に回す
final class OsmoRTMPPipeline: @unchecked Sendable {
    struct Counters {
        var frames = 0
        var bytes = 0
        var lastFrameAt: Date?
    }

    private let decoder: OsmoVideoDecoder
    private let recorder: OsmoStreamRecorder
    private let lock = NSLock()
    private var counters = Counters()
    // ---- サーバーのキューの上だけで触る ----
    private var parameterSets: [[UInt8]] = []

    init(decoder: OsmoVideoDecoder, recorder: OsmoStreamRecorder) {
        self.decoder = decoder
        self.recorder = recorder
    }

    /// 1 秒ごとに画面が読む(読んだら数を 0 に戻す。最後の絵の時刻は残す)
    func takeCounters() -> Counters {
        lock.lock()
        defer { lock.unlock() }
        let c = counters
        counters.frames = 0
        counters.bytes = 0
        return c
    }

    func handle(_ event: OsmoRTMPEvent) {
        switch event {
        case .publishStarted:
            // 新しい配信: パラメーターセットと時刻の基準を取り直す
            parameterSets = []
            recorder.resetCameraClock()
            decoder.reset()
        case .videoConfig(_, let sets):
            parameterSets = sets
        case .video(let frame):
            video(frame)
        case .audioConfig(let asc):
            recorder.setCameraAudioFormat(OsmoStreamRecorder.makeAACFormat(audioSpecificConfig: asc))
        case .audio(let frame, let timestampMs):
            recorder.observeCameraAudio(frame, timestampMs: timestampMs)
            lock.lock()
            counters.bytes += frame.count
            lock.unlock()
        case .metadata, .unsupported, .publishEnded:
            break
        }
    }

    /// 長さ付きの NAL を Annex-B の 1 枚にする。キーフレームにはパラメーターセットを前に付ける
    /// (OsmoVideoDecoder と OsmoStreamRecorder はライブビューと同じく Annex-B の中のパラメーターセットで形式を知る)
    private func video(_ frame: OsmoRTMPVideoFrame) {
        let random = frame.isKey || frame.nals.contains { OsmoNAL.isRandomAccess($0, codec: frame.codec) }
        var au: [UInt8] = []
        let size = frame.nals.reduce(0) { $0 + $1.count + 4 }
        au.reserveCapacity(size + (random ? parameterSets.reduce(0) { $0 + $1.count + 4 } : 0))
        if random {
            for set in parameterSets {
                au += [0, 0, 0, 1]
                au += set
            }
        }
        for nal in frame.nals {
            au += [0, 0, 0, 1]
            au += nal
        }
        decoder.decode(accessUnit: au, codecHint: frame.codec)
        recorder.observe(accessUnit: au, timestampMs: frame.timestampMs, compositionMs: frame.compositionMs,
                         codec: frame.codec)
        lock.lock()
        counters.frames += 1
        counters.bytes += size
        counters.lastFrameAt = Date()
        lock.unlock()
    }
}

@MainActor
@Observable
final class OsmoRTMPSession {
    enum Status: Equatable {
        case idle
        case startingServer
        /// Bluetooth でカメラに頼んでいる(今の段階)
        case bluetooth(String)
        /// サーバーは待っている。カメラからの配信を待つ
        case waitingForStream
        /// カメラが配信を始めた
        case receiving
        case failed(String)
    }

    enum RecordingState: Equatable {
        case idle
        /// 次のキーフレーム待ち
        case preparing
        case recording(Date)
        case finishing
    }

    private(set) var status: Status = .idle
    /// Bluetooth で頼んだ(false = DJI Mimo から配信してもらう)
    private(set) var usesBluetooth = false
    private(set) var streamURL: String = OsmoRTMPServer.streamURL()
    private(set) var cameraName: String?
    // 受信の数字
    private(set) var width = 0
    private(set) var height = 0
    private(set) var fps: Double = 0
    private(set) var megabitsPerSecond: Double = 0
    private(set) var codecName = "—"
    private(set) var hasCameraAudio = false
    /// 受信中に映像が 3 秒より長く止まっている
    private(set) var isStalled = false
    /// 対応していない形式が届いた など
    private(set) var notice: String?
    // 録画
    private(set) var recordingState: RecordingState = .idle
    private(set) var finishedRecording: URL?
    private(set) var recordingMessage: String?

    let decoder = OsmoVideoDecoder()
    let recorder = OsmoStreamRecorder()
    /// ログ(OsmoLiveMonitor のログに入れる)
    @ObservationIgnored var onLog: ((String) -> Void)?
    @ObservationIgnored private var server: OsmoRTMPServer?
    @ObservationIgnored private var pipeline: OsmoRTMPPipeline?
    @ObservationIgnored private var link: OsmoRTMPLink?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var listenerReady = false
    @ObservationIgnored private var listenerFailed = false

    init() {
        decoder.onLog = { [weak self] in self?.log($0) }
        decoder.onFrame = { [weak self] w, h in
            guard let self else { return }
            if self.width != w { self.width = w }
            if self.height != h { self.height = h }
        }
        recorder.onLog = { [weak self] in self?.log($0) }
        recorder.onStarted = { [weak self] in
            self?.recordingState = .recording(Date())
        }
        recorder.onNeedsKeyframe = { [weak self] reason in
            // RTMP にはキーフレームを頼む命令が無い。カメラの次のキーフレームを待つ
            self?.log("recorder: waiting for the next keyframe (\(reason))")
        }
        recorder.onFinished = { [weak self] url, message in
            guard let self else { return }
            self.recordingState = .idle
            self.finishedRecording = url
            self.recordingMessage = message
        }
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// 受信・Bluetooth のどちらかが動いている
    var isActive: Bool { status != .idle && !isFailed }

    /// 画面の「状態」
    var statusText: String {
        switch status {
        case .idle:
            return String(localized: "待機中")
        case .startingServer:
            return String(localized: "カメラ接続中")
        case .bluetooth(let step):
            return String(localized: "カメラ接続中(\(step))")
        case .waitingForStream:
            return String(localized: "カメラ接続中(映像を待っています)")
        case .receiving:
            guard width > 0 else { return String(localized: "受信中(最初の映像を待っています)") }
            let size = "\(width)×\(height)"
            let rate = String(format: "%.0f", fps)
            let mbps = String(format: "%.1f", megabitsPerSecond)
            return String(localized: "受信中 \(size) \(rate)fps \(mbps)Mbps")
        case .failed(let message):
            return String(localized: "うまくいきませんでした: \(message)")
        }
    }

    // MARK: 始める・止める

    /// Bluetooth でカメラに頼んで、iPhone のインターネット共有から RTMP で送ってもらう
    func startWithBluetooth(ssid: String, password: String, model: OsmoRTMPModel, quality: OsmoRTMPQuality) {
        stop()
        usesBluetooth = true
        guard startReceiver() else { return }
        let link = OsmoRTMPLink()
        link.log = { [weak self] in self?.log($0) }
        self.link = link
        let url = streamURL
        status = .bluetooth(String(localized: "受信の準備をしています…"))
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.waitForListener()
                try await link.start(ssid: ssid, password: password, url: url, model: model, quality: quality) { [weak self] step in
                    guard let self, self.status != .receiving else { return }
                    self.status = .bluetooth(step)
                }
                try Task.checkCancellation()
                self.cameraName = link.cameraName
                if self.status != .receiving { self.status = .waitingForStream }
                // 1 分たっても配信が来なければ知らせる(待ち受けは続ける。あとから届けば受信中になる)
                try await Task.sleep(for: .seconds(60))
                if self.status == .waitingForStream {
                    self.status = .failed(String(localized: "カメラから映像が届きません。カメラがこの iPhone のインターネット共有に入っているか確かめてください"))
                }
            } catch is CancellationError {
                // 止めた
            } catch {
                // 止めたあとに Bluetooth の待ちが「切れた」で終わったものは知らせない
                if Task.isCancelled { return }
                self.log("rtmp: setup failed \(error.localizedDescription)")
                if self.status != .receiving {
                    self.status = .failed(error.localizedDescription)
                }
                link.disconnect()
            }
        }
    }

    /// 受信だけ始める(DJI Mimo から配信してもらうとき)
    func startReceiverOnly() {
        stop()
        usesBluetooth = false
        guard startReceiver() else { return }
        status = .waitingForStream
        log("rtmp: waiting for a publisher at \(streamURL) (start the stream from DJI Mimo)")
    }

    func stop() {
        guard server != nil || link != nil || setupTask != nil || status != .idle else { return }
        setupTask?.cancel()
        setupTask = nil
        if let link {
            Task { await link.stopStream() }
            self.link = nil
        }
        // 録画中なら、そこまでをファイルとして閉じる
        stopRecording()
        server?.stop()
        server = nil
        pipeline = nil
        tickTask?.cancel()
        tickTask = nil
        decoder.reset()
        removeObservers()
        endBackgroundTask()
        IdleTimerGuard.set(false, for: "osmo-rtmp")
        listenerReady = false
        listenerFailed = false
        status = .idle
        cameraName = nil
        width = 0
        height = 0
        fps = 0
        megabitsPerSecond = 0
        codecName = "—"
        hasCameraAudio = false
        isStalled = false
        notice = nil
    }

    private func startReceiver() -> Bool {
        streamURL = OsmoRTMPServer.streamURL()
        status = .startingServer
        notice = nil
        let server = OsmoRTMPServer()
        let pipeline = OsmoRTMPPipeline(decoder: decoder, recorder: recorder)
        server.onLog = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        server.onListenerState = { [weak self] state in
            Task { @MainActor in self?.listenerChanged(state) }
        }
        server.onEvent = { [weak self] event in
            // 映像と音はサーバーのキューのまま表示・録画へ。数字は 1 秒ごとにまとめて読む
            pipeline.handle(event)
            switch event {
            case .video, .audio:
                return
            default:
                Task { @MainActor in self?.handle(event) }
            }
        }
        do {
            try server.start()
        } catch {
            log("rtmp: cannot listen \(error.localizedDescription)")
            status = .failed(String(localized: "受信の準備ができませんでした(\(error.localizedDescription))"))
            return false
        }
        self.server = server
        self.pipeline = pipeline
        startTick()
        observeLifecycle()
        // 長く録るので、そのあいだは画面を自動で消さない
        IdleTimerGuard.set(true, for: "osmo-rtmp")
        return true
    }

    /// 待ち受けが始まるまで(最長 5 秒)待つ
    private func waitForListener() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !listenerReady {
            if listenerFailed { throw OsmoRTMPLink.Failure.refused(String(localized: "受信の準備ができませんでした")) }
            if Date() > deadline { break }  // 準備中のままでも先に進む(カメラがつなぐまでに間に合えばよい)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func listenerChanged(_ state: OsmoRTMPServer.ListenerState) {
        switch state {
        case .ready:
            listenerReady = true
            if listenerFailed {
                listenerFailed = false
                if isFailed { status = .waitingForStream }
            }
        case .failed(let message):
            listenerReady = false
            listenerFailed = true
            if status != .receiving {
                status = .failed(String(localized: "受信の準備ができませんでした(\(message))"))
            }
        case .starting, .stopped:
            break
        }
    }

    private func handle(_ event: OsmoRTMPEvent) {
        switch event {
        case .publishStarted(let app, let key, let from):
            log("rtmp: publish app=\(app) key=\(key) from \(from)")
            status = .receiving
            hasCameraAudio = false
            width = 0
            height = 0
            notice = nil
        case .metadata(let metadata):
            let keys = ["width", "height", "framerate", "videoframerate", "videodatarate", "videocodecid",
                        "audiocodecid", "audiosamplerate", "encoder"]
            let summary = keys.compactMap { key in metadata[key].map { "\(key)=\($0.summary)" } }.joined(separator: " ")
            log("rtmp: metadata \(summary)")
        case .videoConfig(let codec, let sets):
            codecName = codec.rawValue
            log("rtmp: video \(codec.rawValue), \(sets.count) parameter sets")
        case .audioConfig(let asc):
            hasCameraAudio = OsmoStreamRecorder.makeAACFormat(audioSpecificConfig: asc) != nil
            log("rtmp: audio AAC config \(OsmoRTMPBytes.hex(asc))\(hasCameraAudio ? "" : " (unsupported)")")
        case .unsupported(let what):
            log("rtmp: unsupported \(what)")
            if what.hasPrefix("video") {
                notice = String(localized: "この映像の形式には対応していません(\(what))")
            }
        case .publishEnded(let reason):
            log("rtmp: publish ended (\(reason))")
            // 録画中なら、そこまでをファイルとして閉じる(カメラがつなぎ直したら、もう一度録画を押す)
            stopRecording()
            if status == .receiving { status = .waitingForStream }
        case .video, .audio:
            break
        }
    }

    /// 1 秒ごとに数字を更新する
    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let pipeline = self.pipeline else { return }
                let c = pipeline.takeCounters()
                self.fps = Double(c.frames)
                self.megabitsPerSecond = Double(c.bytes) * 8 / 1_000_000
                let name = self.decoder.codecName
                if name != "—", name != self.codecName { self.codecName = name }
                let stalled = self.status == .receiving
                    && (c.lastFrameAt.map { Date().timeIntervalSince($0) > 3 } ?? false)
                if stalled != self.isStalled { self.isStalled = stalled }
            }
        }
    }

    // MARK: 録画

    /// 録画を始める(受信中だけ)。次のキーフレームから書く。カメラの音があればそれを使う
    func startRecording(microphone: Bool) {
        guard status == .receiving, recordingState == .idle, finishedRecording == nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = OsmoStreamRecorder.directory.appendingPathComponent("Osmo RTMP \(formatter.string(from: Date())).mp4")
        recordingMessage = nil
        recordingState = .preparing
        let useMicrophone = microphone && !hasCameraAudio
        log("recorder: start RTMP (camera audio \(hasCameraAudio ? "yes" : "no"), mic \(useMicrophone ? "on" : "off"))")
        recorder.start(url: url, microphone: useMicrophone, cameraAudio: true)
    }

    func stopRecording() {
        switch recordingState {
        case .preparing, .recording:
            recordingState = .finishing
            recorder.stop()
        case .idle, .finishing:
            break
        }
    }

    /// 「プロジェクトに入れる」: ファイルを渡す(このあとは取り込み側が消す)
    func takeFinishedRecording() -> URL? {
        let url = finishedRecording
        finishedRecording = nil
        recordingMessage = nil
        return url
    }

    /// 「破棄」
    func discardFinishedRecording() {
        if let url = finishedRecording { try? FileManager.default.removeItem(at: url) }
        finishedRecording = nil
        recordingMessage = nil
    }

    // MARK: アプリが裏に回ったとき

    private func observeLifecycle() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func didEnterBackground() {
        // 裏では映像が止まるので、録画はここまでで閉じる
        stopRecording()
        // DJI Mimo に切り替えて配信を始めるあいだ、待ち受けを少しだけ続ける(iOS が許すのは 30 秒ほど)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "osmo-rtmp") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        log("rtmp: app in background, keeping the receiver for a short while")
    }

    private func willEnterForeground() {
        endBackgroundTask()
        server?.restartIfNeeded()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func log(_ line: String) {
        onLog?(line)
    }
}
#endif
