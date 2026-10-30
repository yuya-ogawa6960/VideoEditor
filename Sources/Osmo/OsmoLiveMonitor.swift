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
        try await bluetooth.pairApp { phase = .awaitingApproval }

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
        link.onAccessUnit = { au in decoder.decode(accessUnit: au) }
        link.onLog = { [weak self] s in Task { @MainActor in self?.appendLog(s) } }
        datalink = link
        try await link.open()
        try Task.checkCancellation()
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
            }
        }
    }

    /// 0x09/0xA8 をもう一度。毎秒送るとキーフレームが届かなくなるので 6 秒以上あける
    private func requestKeyframe(reason: String) {
        guard let link = datalink, Date().timeIntervalSince(lastEnableAt) > 6 else { return }
        lastEnableAt = Date()
        appendLog("keyframe request (\(reason))")
        link.enableLiveView(prepare: false)
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
