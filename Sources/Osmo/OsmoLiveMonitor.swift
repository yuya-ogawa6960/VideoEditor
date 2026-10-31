// =====================================================================
// OsmoLiveMonitor: DJI Osmo Pocket のライブビューを Video Mania の中で見る実験(開発者モード専用)
//
// 流れ(docs/OsmoPocket.md に詳しく):
//   BLE で探す → GATT 接続 → アプリのペアリング(0x07/0x45、初回はカメラの画面で許可)
//   → カメラの Wi-Fi 名・パスワードを BLE で読む(0x07/0x07・0x07/0x0E)
//   → NEHotspotConfiguration で iPhone をカメラの Wi-Fi に入れる(192.168.2.x)
//   → UDP 9004 のデータリンク → 0x09/0xA8 でライブビュー開始 → VideoToolbox で表示
//
// DJI は Osmo Pocket の SDK を出していない。ここの手順はすべて OpenPocketCine / OpenCine
// (Apache 2.0)などが公開しているリバースエンジニアリングの結果による。
// **実機ではまだ一度も試していない**(CI に実機は無い)。
// =====================================================================

#if OSMO_LIVE
import Foundation
import Observation

@MainActor
@Observable
final class OsmoLiveMonitor {
    enum Phase: Equatable {
        case idle
        case scanning
        case connectingBluetooth
        case pairing
        case awaitingApproval
        case readingWiFi
        case joiningWiFi
        case openingDatalink
        case live
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "待機中"
            case .scanning: return "カメラを探しています…"
            case .connectingBluetooth: return "Bluetooth で接続中…"
            case .pairing: return "ペアリング中…"
            case .awaitingApproval: return "カメラの画面で接続を許可してください"
            case .readingWiFi: return "カメラの Wi-Fi 情報を読んでいます…"
            case .joiningWiFi: return "カメラの Wi-Fi に接続中…"
            case .openingDatalink: return "映像の通信を開いています…"
            case .live: return "ライブビュー"
            case .failed(let s): return "失敗: \(s)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .idle, .scanning, .live, .failed: return false
            default: return true
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var sightings: [OsmoSighting] = []
    private(set) var connectedName: String?
    private(set) var logLines: [String] = []
    // 診断
    private(set) var resolution: String = "—"
    private(set) var codec: String = "—"
    private(set) var decodedFrames = 0
    private(set) var stats = OsmoDatalink.Stats()
    private(set) var fps: Double = 0

    let decoder = OsmoVideoDecoder()
    /// カメラ本体の録画(OsmoCameraControl.swift)。データリンクが開いているあいだだけ使える
    let camera = OsmoCameraControl()

    /// iPhone 側の録画(受けた映像をそのまま .mp4 に書く。OsmoStreamRecorder.swift)
    enum StreamRecordingState: Equatable {
        case idle
        /// マイクの準備・最初のキーフレーム待ち
        case preparing
        /// 書いている(最初のキーフレームを書いた時刻)
        case recording(Date)
        case finishing
    }
    private(set) var streamRecordingState: StreamRecordingState = .idle
    /// 録画中に映像が 2 秒より長く止まっている
    private(set) var streamRecordingStalled = false
    /// 録り終えたファイル(「プロジェクトに入れる」「写真に保存」「破棄」を待つ)
    private(set) var finishedStreamRecording: URL?
    /// 録画について知らせること(保存できなかった など)
    private(set) var streamRecordingMessage: String?
    let streamRecorder = OsmoStreamRecorder()
    private let bluetooth = OsmoBluetoothLink()
    @ObservationIgnored private var datalink: OsmoDatalink?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var bleKeepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var joinedSSID: String?
    @ObservationIgnored private var lastEnableAt: Date = .distantPast
    @ObservationIgnored private var lastFrameAt: Date?
    @ObservationIgnored private var framesThisSecond = 0

    init() {
        bluetooth.log = { [weak self] in self?.appendLog($0) }
        decoder.onLog = { [weak self] in self?.appendLog($0) }
        camera.onLog = { [weak self] in self?.appendLog($0) }
        decoder.onFrame = { [weak self] width, height in
            guard let self else { return }
            self.decodedFrames += 1
            self.framesThisSecond += 1
            self.lastFrameAt = Date()
            let text = "\(width)×\(height)"
            if self.resolution != text { self.resolution = text }
            if self.phase != .live { self.phase = .live }
        }
        decoder.onNeedsKeyframe = { [weak self] reason in
            self?.requestKeyframe(reason: reason)
        }
        streamRecorder.onLog = { [weak self] in self?.appendLog($0) }
        streamRecorder.onStarted = { [weak self] in
            self?.streamRecordingState = .recording(Date())
        }
        streamRecorder.onNeedsKeyframe = { [weak self] reason in
            // 録画を始めるときは 1 回だけすぐ頼む(毎秒は送らない)
            self?.requestKeyframe(reason: reason, minimumInterval: 2)
        }
        streamRecorder.onFinished = { [weak self] url, message in
            guard let self else { return }
            self.streamRecordingState = .idle
            self.streamRecordingStalled = false
            self.finishedStreamRecording = url
            self.streamRecordingMessage = message
        }
    }

    // MARK: 探す

    func startScan() {
        stop()
        sightings = []
        phase = .scanning
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bluetooth.waitUntilPoweredOn()
            } catch {
                self.phase = .failed(error.localizedDescription)
                return
            }
            for await sighting in self.bluetooth.scan() {
                if let i = self.sightings.firstIndex(where: { $0.id == sighting.id }) {
                    self.sightings[i] = sighting
                } else {
                    self.sightings.append(sighting)
                    self.appendLog("found \(sighting.name) \(sighting.modelName)")
                }
            }
        }
    }

    // MARK: つなぐ

    func connect(_ sighting: OsmoSighting) {
        scanTask?.cancel()
        bluetooth.stopScan()
        connectTask?.cancel()
        connectedName = sighting.name
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(sighting)
            } catch is CancellationError {
                self.appendLog("cancelled")
            } catch {
                self.appendLog("error: \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
                self.teardown()
            }
        }
    }

    private func run(_ sighting: OsmoSighting) async throws {
        // 1. Bluetooth
        phase = .connectingBluetooth
        try await bluetooth.connect(sighting.id)
        startBLEKeepalive()

        // 2. アプリのペアリング(Bluetooth の「ペアリング」とは別。カメラが app の識別子を覚える)
        phase = .pairing
        bluetooth.send(OsmoCommands.sessionWake())
        let pin = try await bluetooth.request(OsmoCommands.setPairingPin(), timeout: 90, label: "SetPairingPIN")
        let result = pin.payload.count >= 2 ? pin.payload[1] : 0xFF
        appendLog(String(format: "pair: reply %@", OsmoBluetoothLink.hex(pin.payload)))
        switch result {
        case 0x01:
            appendLog("pair: already paired")
        case 0x02:
            phase = .awaitingApproval
            _ = try await bluetooth.waitForFrame(timeout: 90, label: "カメラでの許可") {
                $0.cmdSet == 0x07 && $0.cmdId == 0x46
            }
            appendLog("pair: approved on camera")
        case 0x06:
            throw OsmoError.refused("ペアリングを後回しにされました(00 06)。数秒待ってもう一度")
        default:
            appendLog(String(format: "pair: unknown result %02X, continuing", result))
        }

        // 3. カメラの Wi-Fi を起こして、名前とパスワードを読む
        phase = .readingWiFi
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await bluetooth.request(OsmoCommands.wakeAccessPoint(), timeout: 2, label: "0x53/0x10")
        } catch OsmoError.timeout {
            appendLog("wifi: 0x53/0x10 no reply (Pocket 3 often silent) - continuing")
        }
        try await Task.sleep(for: .milliseconds(600))
        let advertised = sighting.name.trimmingCharacters(in: .whitespaces)
        var ssid = try await readWiFiString(OsmoCommands.getWifiSsid, label: "GetWifiSsid")
        if ssid.isEmpty {
            // Pocket の BLE 名は Wi-Fi 名と同じ(OpenPocketCine の観察)
            appendLog("wifi: GetWifiSsid empty, using BLE name \(advertised)")
            ssid = advertised
        }
        let password = try await readWiFiString(OsmoCommands.getWifiPassword, label: "GetWifiPassword")
        guard !ssid.isEmpty, !password.isEmpty else {
            throw OsmoError.wifi("カメラが Wi-Fi の名前かパスワードを返しませんでした")
        }
        appendLog("wifi: ssid \(ssid) (password \(password.count) chars)")

        // 4. iPhone をカメラの Wi-Fi に入れる
        phase = .joiningWiFi
        try await OsmoWiFi.join(ssid: ssid, passphrase: password) { [weak self] in self?.appendLog($0) }
        joinedSSID = ssid
        guard let localIP = OsmoWiFi.cameraLocalIPv4() else { throw OsmoError.wifi("192.168.2.x がありません") }
        appendLog("wifi: joined, local \(localIP)")

        // 5. データリンクとライブビュー
        phase = .openingDatalink
        let link = OsmoDatalink(localIPv4: localIP)
        let decoder = self.decoder
        let streamRecorder = self.streamRecorder
        link.onAccessUnit = { au in
            decoder.decode(accessUnit: au)
            streamRecorder.observe(accessUnit: au)
        }
        link.onLog = { [weak self] s in Task { @MainActor in self?.appendLog(s) } }
        let camera = self.camera
        link.onFrame = { frame in
            guard OsmoCameraControl.isRelevant(frame) else { return }
            Task { @MainActor in camera.handle(frame) }
        }
        datalink = link
        try await link.open()
        try Task.checkCancellation()
        camera.attach(link)
        lastEnableAt = Date()
        link.enableLiveView(prepare: true)
        startWatchdog()
    }

    /// Wi-Fi 系の返事 `[status][len][utf8]`。空や 0xE0 台は数回やり直す
    private func readWiFiString(_ make: () -> OsmoDuml.Frame, label: String) async throws -> String {
        for attempt in 1...3 {
            do {
                let reply = try await bluetooth.request(make(), timeout: 4, label: label)
                let value = OsmoDuml.unpackStatusString(reply.payload)
                if !value.isEmpty { return value }
                appendLog("\(label): empty (\(OsmoBluetoothLink.hex(reply.payload))) #\(attempt)")
            } catch OsmoError.timeout {
                appendLog("\(label): timeout #\(attempt)")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return ""
    }

    /// BLE をつないでいるあいだ 1 秒ごとに 0x00/0x2B を送る(OpenPocketCine と同じ)
    private func startBLEKeepalive() {
        bleKeepaliveTask?.cancel()
        bleKeepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.bluetooth.send(OsmoCommands.sessionKeepalive())
            }
        }
    }

    /// 1 秒ごとに数字を更新し、映像が止まったら登録を送り直してキーフレームを頼む
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let link = self.datalink else { return }
                self.stats = link.stats()
                self.fps = Double(self.framesThisSecond)
                self.framesThisSecond = 0
                self.codec = self.decoder.codecName
                let since = Date().timeIntervalSince(self.lastFrameAt ?? self.lastEnableAt)
                if since > 5 {
                    // 登録が切れると映像だけ止まる(テレメトリーは続く)。登録を送り直す
                    link.reRegister()
                    self.requestKeyframe(reason: "no picture for \(Int(since)) s")
                }
                self.checkStreamRecording()
            }
        }
    }

    /// 0x09/0xA8 をもう一度。毎秒送るとキーフレームが届かなくなるので、ふだんは 6 秒以上あける
    private func requestKeyframe(reason: String, minimumInterval: TimeInterval = 6) {
        guard let link = datalink, Date().timeIntervalSince(lastEnableAt) > minimumInterval else { return }
        lastEnableAt = Date()
        appendLog("keyframe request (\(reason))")
        link.enableLiveView(prepare: false)
    }

    // MARK: iPhone に録画

    /// 録画を始める(ライブビューが出ているときだけ)。最初のキーフレームから書く
    func startStreamRecording(microphone: Bool) {
        guard phase == .live, streamRecordingState == .idle, finishedStreamRecording == nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = OsmoStreamRecorder.directory.appendingPathComponent("Osmo \(formatter.string(from: Date())).mp4")
        streamRecordingMessage = nil
        streamRecordingStalled = false
        streamRecordingState = .preparing
        appendLog("recorder: start (mic \(microphone ? "on" : "off"))")
        streamRecorder.start(url: url, microphone: microphone)
    }

    /// 録画を止める。ファイルを閉じたら finishedStreamRecording に入る
    func stopStreamRecording() {
        switch streamRecordingState {
        case .preparing, .recording:
            streamRecordingState = .finishing
            streamRecorder.stop()
        case .idle, .finishing:
            break
        }
    }

    /// 「プロジェクトに入れる」: ファイルを渡す(このあとは取り込み側が消す)
    func takeFinishedStreamRecording() -> URL? {
        let url = finishedStreamRecording
        finishedStreamRecording = nil
        streamRecordingMessage = nil
        return url
    }

    /// 「破棄」
    func discardFinishedStreamRecording() {
        if let url = finishedStreamRecording { try? FileManager.default.removeItem(at: url) }
        finishedStreamRecording = nil
        streamRecordingMessage = nil
    }

    /// 1 秒ごと: 止まっていないか見る。止まっていたらキーフレームを頼む(届けば次のキーフレームから書き直す)
    private func checkStreamRecording() {
        guard streamRecordingState != .idle, streamRecordingState != .finishing else {
            if streamRecordingStalled { streamRecordingStalled = false }
            return
        }
        let s = streamRecorder.snapshot()
        let stalled = (s.secondsSinceLastFrame ?? 0) > OsmoStreamRecorder.stallSeconds
        if stalled != streamRecordingStalled { streamRecordingStalled = stalled }
        if stalled {
            requestKeyframe(reason: "recording stalled", minimumInterval: 3)
        } else if let waiting = s.secondsWaitingForKeyframe, waiting > 3 {
            requestKeyframe(reason: "recording waits for keyframe")
        }
    }

    // MARK: 止める

    func stop() {
        scanTask?.cancel(); scanTask = nil
        connectTask?.cancel(); connectTask = nil
        bluetooth.stopScan()
        teardown()
        phase = .idle
    }

    private func teardown() {
        watchdogTask?.cancel(); watchdogTask = nil
        bleKeepaliveTask?.cancel(); bleKeepaliveTask = nil
        // 録画中に切れたら、そこまでをファイルとして閉じる
        stopStreamRecording()
        camera.detach()
        datalink?.close(); datalink = nil
        decoder.reset()
        bluetooth.disconnect()
        if let ssid = joinedSSID {
            // 元の Wi-Fi に戻す
            OsmoWiFi.leave(ssid: ssid)
            joinedSSID = nil
        }
        connectedName = nil
        lastFrameAt = nil
        resolution = "—"
        codec = "—"
        fps = 0
    }

    private func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("\(stamp) \(line)")
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    /// 不具合の報告用。Wi-Fi のパスワードはログに出していない(文字数だけ)
    var logText: String { logLines.joined(separator: "\n") }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
#endif
