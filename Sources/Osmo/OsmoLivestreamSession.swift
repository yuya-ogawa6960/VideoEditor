// =====================================================================
// Osmo Pocket の「配信」のしくみで、カメラ本体に残さずに iPhone に録画する(開発者モード専用の実験)
//
// 流れ:
//   iPhone の中で RTMP サーバーを立てる(ポート 1935)
//   → BLE でペアリング → 配信モード(0x02/0xE1 1A)→ カメラを Wi-Fi に入れる(0x07/0x47)
//   → 配信の設定(0x08/0x78。送り先 = rtmp://<iPhone の IP>:1935/live/osmo、画質)→ 開始(0x02/0x8E 1A=01)
//   → カメラが iPhone に映像と音声を送ってくる → 画面に出し、「録画」で書類/Osmo に保存
//
// カメラと iPhone は同じネットワークにいる必要がある(家の Wi-Fi、または iPhone のインターネット共有)。
// DJI の公式の選択肢は 1080p まで。2.7K / 4K は録画の設定の値を当てた実験で、断られる可能性が高い。
// **実機ではまだ一度も試していない。**
// =====================================================================

#if OSMO_LIVE
import Foundation
import Observation
import Photos

@MainActor
@Observable
final class OsmoLivestreamSession {
    enum Quality: String, CaseIterable, Identifiable {
        case p720, p1080, k27, k4
        var id: String { rawValue }

        var label: String {
            switch self {
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .k27: return "2.7K(実験)"
            case .k4: return "4K(実験)"
            }
        }

        /// 配信の設定の解像度の値。720p `04`・1080p `0A` は node-osmo、2.7K `2D`・4K `10` は録画の設定の値からの推測
        var resolutionByte: UInt8 {
            switch self {
            case .p720: return 0x04
            case .p1080: return 0x0A
            case .k27: return 0x2D
            case .k4: return 0x10
            }
        }

        var isExperimental: Bool { self == .k27 || self == .k4 }
    }

    enum Phase: Equatable {
        case idle, scanning, connectingBluetooth, pairing, awaitingApproval
        case preparing, joiningNetwork, configuring, waitingForStream, streaming
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "待機中"
            case .scanning: return "カメラを探しています…"
            case .connectingBluetooth: return "Bluetooth で接続中…"
            case .pairing: return "ペアリング中…"
            case .awaitingApproval: return "カメラの画面で接続を許可してください"
            case .preparing: return "配信モードに切り替え中…(15 秒ほど)"
            case .joiningNetwork: return "カメラを Wi-Fi に接続中…"
            case .configuring: return "配信の設定を送っています…"
            case .waitingForStream: return "カメラからの映像を待っています…"
            case .streaming: return "受信中"
            case .failed(let s): return "失敗: \(s)"
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle, .scanning, .failed: return false
            default: return true
            }
        }
    }

    struct Target: Hashable, Identifiable {
        let label: String
        let ip: String
        var id: String { ip }
    }

    // 設定(SSID は UserDefaults、パスワードは Keychain)
    var ssid: String
    var password: String
    var quality: Quality = .p1080
    var fps: Int = 30
    var bitrateMbps: Int = 10
    var targetIP: String = ""

    private(set) var targets: [Target] = []
    private(set) var phase: Phase = .idle
    private(set) var sightings: [OsmoSighting] = []
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var recordings: [URL] = []
    private(set) var logLines: [String] = []
    private(set) var codec = "—"
    private(set) var resolution = "—"
    private(set) var videoFrames = 0
    private(set) var audioFrames = 0
    private(set) var measuredMbps: Double = 0

    let decoder = OsmoVideoDecoder()
    private let bluetooth = OsmoBluetoothLink()
    private let server = OsmoRTMPServer()
    private let recorder = OsmoRTMPRecorder()
    private let counters = OsmoStreamCounters()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var keepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var serverRunning = false
    @ObservationIgnored private var bluetoothConnected = false

    private static let ssidKey = "osmo.stream.ssid"
    private static let passwordKey = "osmo.stream.password"

    init() {
        ssid = UserDefaults.standard.string(forKey: Self.ssidKey) ?? ""
        password = KeychainStore.get(Self.passwordKey) ?? ""
        bluetooth.log = { [weak self] in self?.appendLog($0) }
        decoder.onLog = { [weak self] in self?.appendLog($0) }
        decoder.onFrame = { [weak self] width, height in
            guard let self else { return }
            let text = "\(width)×\(height)"
            if self.resolution != text { self.resolution = text }
        }
        let log: @Sendable (String) -> Void = { [weak self] s in Task { @MainActor in self?.appendLog(s) } }
        recorder.onLog = log
        wireServer()
        refreshTargets()
        refreshRecordings()
    }

    // MARK: RTMP サーバーから届くもの(RTMP のキューの上)

    private func wireServer() {
        let decoder = self.decoder
        let recorder = self.recorder
        let counters = self.counters
        server.onEvent = { [weak self] event in
            switch event {
            case .videoConfig(let codec, let sets, let nalLengthSize):
                counters.setNalLengthSize(nalLengthSize)
                recorder.setVideoConfig(codec: codec, parameterSets: sets, nalLengthSize: nalLengthSize)
                decoder.decode(accessUnit: sets.flatMap { [0, 0, 0, 1] + $0 })
                Task { @MainActor in
                    self?.codec = codec.rawValue
                    self?.appendLog("stream: \(codec.rawValue) config (\(sets.map { $0.count }) B)")
                }
            case .videoFrame(let data, let dts, let pts, let keyframe):
                counters.addVideo(bytes: data.count)
                recorder.appendVideo(data: data, dts: dts, pts: pts, keyframe: keyframe)
                decoder.decode(accessUnit: OsmoRTMPRecorder.annexB(fromLengthPrefixed: data,
                                                                    nalLengthSize: counters.nalLengthSize))
            case .audioConfig(let asc):
                recorder.setAudioConfig(asc)
                Task { @MainActor in self?.appendLog("stream: AAC config \(OsmoBluetoothLink.hex(asc))") }
            case .audioFrame(let data, let timestamp):
                counters.addAudio(bytes: data.count)
                recorder.appendAudio(data: data, timestamp: timestamp)
            case .log(let s):
                Task { @MainActor in self?.appendLog(s) }
            case .connected(let peer):
                Task { @MainActor in self?.appendLog("rtmp: camera connected from \(peer)") }
            case .publishing(let name):
                Task { @MainActor in
                    self?.appendLog("rtmp: publishing \(name)")
                    self?.phase = .streaming
                }
            case .metadata(let text):
                Task { @MainActor in self?.appendLog("rtmp: metadata \(String(text.prefix(300)))") }
            case .disconnected(let reason):
                Task { @MainActor in
                    guard let self else { return }
                    self.appendLog("rtmp: disconnected (\(reason))")
                    if self.phase == .streaming { self.phase = .waitingForStream }
                }
            }
        }
    }

    // MARK: 探す・つなぐ

    func refreshTargets() {
        targets = OsmoWiFi.streamTargetAddresses().map { Target(label: $0.label, ip: $0.ip) }
        if !targets.contains(where: { $0.ip == targetIP }) { targetIP = targets.first?.ip ?? "" }
    }

    func startScan() {
        guard !phase.isRunning else { return }
        sightings = []
        phase = .scanning
        refreshTargets()
        scanTask?.cancel()
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

    func connect(_ sighting: OsmoSighting) {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty else {
            phase = .failed("カメラをつなぐ Wi-Fi の名前とパスワードを入れてください")
            return
        }
        guard !targetIP.isEmpty else {
            phase = .failed("iPhone の Wi-Fi かインターネット共有をオンにしてください(送り先のアドレスがありません)")
            return
        }
        // 次回のために覚えておく(パスワードは Keychain)
        UserDefaults.standard.set(name, forKey: Self.ssidKey)
        KeychainStore.set(password, for: Self.passwordKey)
        scanTask?.cancel()
        bluetooth.stopScan()
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(sighting, ssid: name)
            } catch is CancellationError {
                self.appendLog("cancelled")
            } catch {
                self.appendLog("error: \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
                await self.teardown(sendStop: true)
            }
        }
    }

    private func run(_ sighting: OsmoSighting, ssid: String) async throws {
        // 1. 受け口を先に開く(初回は「ローカルネットワーク」の許可が出る)
        if !serverRunning {
            try server.start()
            serverRunning = true
        }
        let url = "rtmp://\(targetIP):\(OsmoRTMPServer.port)/live/osmo"
        appendLog("rtmp: listening, camera will send to \(url)")

        // 2. Bluetooth とペアリング
        phase = .connectingBluetooth
        try await bluetooth.connect(sighting.id)
        bluetoothConnected = true
        startKeepalive()
        phase = .pairing
        try await bluetooth.pairApp { phase = .awaitingApproval }

        // 3. 前の配信を止めてから、配信モードへ
        phase = .preparing
        if let r = try? await bluetooth.request(OsmoCommands.livestream(start: false), timeout: 3, label: "前の配信を止める") {
            appendLog("stream: stop previous → \(OsmoBluetoothLink.hex(r.payload))")
        }
        let mode = try await bluetooth.request(OsmoCommands.enterLivestreamMode(), timeout: 25, label: "配信モード")
        appendLog("stream: livestream mode → \(OsmoBluetoothLink.hex(mode.payload))")

        // 4. カメラを Wi-Fi に入れる
        phase = .joiningNetwork
        let join = try await bluetooth.request(OsmoCommands.joinNetwork(ssid: ssid, password: password),
                                               timeout: 45, label: "カメラの Wi-Fi 接続")
        appendLog("stream: join \(ssid) → \(OsmoBluetoothLink.hex(join.payload))")
        guard join.payload.first == 0x00 else {
            throw OsmoError.refused("カメラが Wi-Fi に入れませんでした(\(OsmoBluetoothLink.hex(join.payload)))。"
                                    + "名前とパスワード、WPA2 かどうか、インターネット共有なら「互換性を優先」がオンかを確かめてください")
        }

        // 5. 配信の設定(版 00 → だめなら版 01)
        phase = .configuring
        let preset = OsmoCommands.livestreamPreset(resolution: quality.resolutionByte,
                                                   bitrateKbps: bitrateMbps * 1000, fps: fps)
        appendLog("stream: preset \(OsmoBluetoothLink.hex(preset)) (\(quality.label) \(fps)fps \(bitrateMbps)Mbps)")
        var config = try await bluetooth.request(OsmoCommands.configureLivestreamV0(preset: preset, url: url),
                                                 timeout: 15, label: "配信の設定")
        appendLog("stream: configure v0 → \(OsmoBluetoothLink.hex(config.payload))")
        if config.payload.first != 0x00 {
            config = try await bluetooth.request(OsmoCommands.configureLivestreamV1(preset: preset, url: url, hevc: true),
                                                 timeout: 15, label: "配信の設定(版 01)")
            appendLog("stream: configure v1 → \(OsmoBluetoothLink.hex(config.payload))")
            guard config.payload.first == 0x00 else {
                let hint = quality.isExperimental ? "この画質はカメラが対応していない可能性が高いです。1080p で試してください" : "ログを送ってください"
                throw OsmoError.refused("配信の設定を断られました(\(OsmoBluetoothLink.hex(config.payload)))。\(hint)")
            }
        }

        // 6. 開始
        if let r = try? await bluetooth.request(OsmoCommands.livestream(start: true), timeout: 10, label: "配信開始") {
            appendLog("stream: start → \(OsmoBluetoothLink.hex(r.payload))")
        } else {
            appendLog("stream: start sent (no reply)")
        }
        if phase != .streaming { phase = .waitingForStream }
        startStats()
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.bluetooth.send(OsmoCommands.sessionKeepalive())
            }
        }
    }

    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var lastBytes = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let s = self.counters.snapshot()
                self.videoFrames = s.videoFrames
                self.audioFrames = s.audioFrames
                self.measuredMbps = Double(s.bytes - lastBytes) * 8 / 1_000_000
                lastBytes = s.bytes
            }
        }
    }

    // MARK: 録画

    func startRecording() async {
        guard !isRecording else { return }
        if await recorder.start() {
            isRecording = true
            recordingStartedAt = Date()
        } else {
            appendLog("recorder: まだ映像の形式が届いていません。映像が出てから押してください")
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordingStartedAt = nil
        if let url = await recorder.stop() {
            appendLog("saved \(url.lastPathComponent)")
        }
        refreshRecordings()
    }

    func refreshRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: OsmoRTMPRecorder.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recordings = files
            .filter { $0.pathExtension == "mov" || $0.pathExtension == "aac" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshRecordings()
    }

    /// 写真アプリに保存(書き込みだけの許可)
    func saveToPhotos(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            return true
        } catch {
            appendLog("photos: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: 止める

    func stop() async {
        scanTask?.cancel(); scanTask = nil
        connectTask?.cancel(); connectTask = nil
        bluetooth.stopScan()
        await teardown(sendStop: true)
        phase = .idle
    }

    private func teardown(sendStop: Bool) async {
        if isRecording { await stopRecording() }
        statsTask?.cancel(); statsTask = nil
        if sendStop && bluetoothConnected {
            // 配信を止めて、普通の動画モードに戻す(BLE の書き込みは 120ms ずつ出ていく)
            bluetooth.send(OsmoCommands.livestream(start: false))
            bluetooth.send(OsmoCommands.enterVideoMode())
            try? await Task.sleep(for: .milliseconds(600))
        }
        keepaliveTask?.cancel(); keepaliveTask = nil
        bluetooth.disconnect()
        bluetoothConnected = false
        if serverRunning {
            server.stop()
            serverRunning = false
        }
        decoder.reset()
        counters.reset()
        codec = "—"
        resolution = "—"
        measuredMbps = 0
    }

    private func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("\(stamp) \(line)")
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    /// 不具合の報告用。Wi-Fi のパスワードはログに出していない
    var logText: String { logLines.joined(separator: "\n") }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// RTMP のキューで数え、画面が 1 秒ごとに読む
final class OsmoStreamCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var nal = 4
    private var video = 0
    private var audio = 0
    private var total = 0

    var nalLengthSize: Int { lock.lock(); defer { lock.unlock() }; return nal }

    func setNalLengthSize(_ n: Int) { lock.lock(); nal = n; lock.unlock() }
    func addVideo(bytes: Int) { lock.lock(); video += 1; total += bytes; lock.unlock() }
    func addAudio(bytes: Int) { lock.lock(); audio += 1; total += bytes; lock.unlock() }
    func reset() { lock.lock(); nal = 4; video = 0; audio = 0; total = 0; lock.unlock() }

    func snapshot() -> (videoFrames: Int, audioFrames: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (video, audio, total)
    }
}
#endif
