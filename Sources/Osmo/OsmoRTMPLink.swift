// =====================================================================
// Osmo Pocket に「iPhone のインターネット共有に入って、この RTMP の URL へ配信して」と Bluetooth で頼む(実験中・開発者向け)
//
// 命令の並びとバイト列は、DJI Mimo の通信を記録した次の資料にあるものだけを使う(推測のバイトは送らない):
//  - OpenPocketCine handbook devices/pocket-3/livestream.md(https://github.com/erik-sutton95/OpenPocketCine、
//    main を 2026-10-31 に参照、Apache License 2.0):
//      0x02/0xE1 [1A](受け手 08)→ 0x07/0x47 Wi-Fi 名・パスワード(受け手 07、返事 00 00)
//      → 0x08/0x78 設定(受け手 08、返事 00)→ 0x02/0x8E 開始 [01 01 1A 00 01 01](受け手 08、返事 00)
//      終わりは 0x02/0x8E [01 01 1A 00 01 02]。
//      Pocket 3 の設定は版 00: `00 [本体の長さ u16le] [9 バイトの設定] [URL の長さ u16le] [URL]`(本体 = 9 + 2 + URL)。
//      1080p/25/Auto で Mimo が送った 9 バイトは `0A 70 17 02 01 02 00 00 00`
//  - OpenPocketCine handbook protocol/ble.md「Experimental livestream provisioning」(Apache 2.0):
//      Pocket 4 Pro も同じ命令。設定は版 01: `01 [本体の長さ u16le] [9 バイト] [JSON の長さ u16le] [JSON]`(本体は先頭 3 バイトを除く)。
//      JSON は rtmpAddress / codec / EnhancedRTMP / supportStopLive / watermark / orientation
//  - OpenPocketCine commit 137433b776c27c8ec5066c7f40a1ee3a86441981(2026-09-23)の
//    Sources/OpenPocketViewCore/MulticamCommands.swift(Apache 2.0、Copyright 2026 Erik Sutton and OpenPocketCine contributors):
//      版 01 の JSON の中身(codec "HEVC"、EnhancedRTMP false、supportStopLive false、watermark 0、orientation "landscape")、
//      9 バイトは Pocket 3 と同じ値、JSON はキーを並べて「/」をエスケープしない。
//      Wi-Fi に入る返事(OpenCine MulticamJoinPolicy、Apache 2.0): 00 00 / 00 00 00 = 成功、01 FF = 5 秒待ってやり直す(最大 3 回)、
//      返事は 45 秒まで待つ
//  - node-osmo(https://github.com/datagutt/node-osmo、MIT License、Copyright (c) 2024 Thomas Lekanger)src/message.ts と
//    Osmosis の osmosis_cmds.kt(MIT、djictl の移植): 版 00 の 9 バイトの読み方
//      [解像度 480p=47 / 720p=04 / 1080p=0A][ビットレート kbps u16le][02][..][fps 25=02 / 30=03][00 00 00]、2.7K / 4K の値は無い
//  - lib-osmo-ble(https://github.com/yigitkonur/lib-osmo-ble、MIT License、Copyright (c) 2026 Yigit Konur)PROTOCOL.md:
//      Pocket 3 での確認(命令は fff5 に書く、0x07/0x47 の成功は 00 00)
// MIT のプロジェクトのコードは写していない(バイトの並びという事実だけを使った)。
//
// Pocket 3 の「1080p・30fps・高いビットレート」は、Mimo が送った 9 バイトのうち node-osmo の読み方でビットレートと fps に
// あたるバイトだけを変えたもの(Mimo の記録そのものではない)。Pocket 4 / 4 Pro は記録された 9 バイト(1080p・25fps・6000kbps)
// をそのまま送る(版 01 でほかの値を送った記録は無い)。
// Wi-Fi のパスワードはログに出さない(長さだけ)。実機ではまだ一度も試していない。
// =====================================================================

#if OSMO_LIVE
import Foundation

/// カメラの機種(設定の形式が違う)
enum OsmoRTMPModel: String, CaseIterable, Identifiable {
    /// Bluetooth の広告と名前から決める(分からなければ Pocket 3)
    case automatic
    /// 版 00(URL をそのまま)
    case pocket3
    /// 版 01(JSON)。Pocket 4 Pro で記録された形
    case pocket4

    var id: String { rawValue }
}

/// Pocket 3 の画質(Pocket 4 は記録された 1080p・25fps・6Mbps だけ)
enum OsmoRTMPQuality: String, CaseIterable, Identifiable {
    case fps30mbps20
    case fps30mbps16
    case fps30mbps10
    /// Mimo が送った 9 バイトそのもの
    case mimo25mbps6

    var id: String { rawValue }

    var fps: Int { self == .mimo25mbps6 ? 25 : 30 }

    var bitrateKbps: Int {
        switch self {
        case .fps30mbps20: return 20_000
        case .fps30mbps16: return 16_000
        case .fps30mbps10: return 10_000
        case .mimo25mbps6: return 6_000
        }
    }

    /// 画面の選択肢(数字だけなので翻訳しない)
    var label: String { "1080p \(fps)fps \(bitrateKbps / 1000)Mbps" }
}

/// RTMP 配信の DUML 命令(BLE の fff5 に書く)
enum OsmoRTMPCommands {
    /// ライブ配信の受け手(DM36x)
    static let rxLive: UInt8 = 0x08
    /// Mimo が 1080p/25/Auto で送った 9 バイト(OpenPocketCine の記録)
    static let mimoPreset1080p25: [UInt8] = [0x0A, 0x70, 0x17, 0x02, 0x01, 0x02, 0x00, 0x00, 0x00]
    /// DUML の 1 フレームは 1023 バイトまで。URL はそれより十分短くする
    static let maxURLBytes = 200

    private static func frame(receiver: UInt8, seq: UInt16, set: UInt8, cmd: UInt8, payload: [UInt8]) -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: receiver, seq: seq, flags: OsmoDuml.flagRequest,
              cmdSet: set, cmdId: cmd, payload: payload)
    }

    private static func u16le(_ n: Int) -> [UInt8] {
        [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)]
    }

    /// `0x02/0xE1` [1A] ライブ配信のモードに入る
    static func prepareLivestream() -> OsmoDuml.Frame {
        frame(receiver: rxLive, seq: 0x8C12, set: 0x02, cmd: 0xE1, payload: [0x1A])
    }

    /// `0x07/0x47` この Wi-Fi に入る。`[長さ][名前][長さ][パスワード]`
    static func joinWiFi(ssid: String, password: String) -> OsmoDuml.Frame {
        frame(receiver: OsmoDuml.rxWifi, seq: 0x8C19, set: 0x07, cmd: 0x47,
              payload: OsmoDuml.packString(ssid) + OsmoDuml.packString(password))
    }

    /// Pocket 3 の 9 バイト。Mimo の記録をもとに、ビットレート(1〜2 バイト目)と fps(5 バイト目)だけを変える
    static func pocket3Preset(_ quality: OsmoRTMPQuality) -> [UInt8] {
        var preset = mimoPreset1080p25
        let kbps = min(max(quality.bitrateKbps, 1), 0xFFFF)
        preset[1] = UInt8(kbps & 0xFF)
        preset[2] = UInt8((kbps >> 8) & 0xFF)
        preset[5] = quality.fps == 30 ? 0x03 : 0x02
        return preset
    }

    /// `0x08/0x78` 版 00(Pocket 3)
    static func configurePocket3(url: String, quality: OsmoRTMPQuality) -> OsmoDuml.Frame {
        let u = Array(url.utf8)
        let body = 9 + 2 + u.count
        let payload: [UInt8] = [0x00] + u16le(body) + pocket3Preset(quality) + u16le(u.count) + u
        return frame(receiver: rxLive, seq: 0x8C2C, set: 0x08, cmd: 0x78, payload: payload)
    }

    /// `0x08/0x78` 版 01(Pocket 4 / 4 Pro)。JSON が作れなければ nil
    static func configurePocket4(url: String) -> OsmoDuml.Frame? {
        let json: [String: Any] = [
            "codec": "HEVC", "EnhancedRTMP": false, "supportStopLive": false,
            "watermark": 0, "rtmpAddress": url, "orientation": "landscape",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        let j = [UInt8](data)
        let body = j.count + 11
        let payload: [UInt8] = [0x01] + u16le(body) + mimoPreset1080p25 + u16le(j.count) + j
        return frame(receiver: rxLive, seq: 0x8C2C, set: 0x08, cmd: 0x78, payload: payload)
    }

    /// `0x02/0x8E` [01 01 1A 00 01 01] 配信を始める
    static func startLivestream() -> OsmoDuml.Frame {
        frame(receiver: rxLive, seq: 0x8C2D, set: 0x02, cmd: 0x8E, payload: [0x01, 0x01, 0x1A, 0x00, 0x01, 0x01])
    }

    /// `0x02/0x8E` [01 01 1A 00 01 02] 配信を終える
    static func stopLivestream() -> OsmoDuml.Frame {
        frame(receiver: rxLive, seq: 0xEAC8, set: 0x02, cmd: 0x8E, payload: [0x01, 0x01, 0x1A, 0x00, 0x01, 0x02])
    }
}

/// インターネット共有の名前とパスワード(Keychain。この端末だけ・ロック解除後)
enum OsmoRTMPHotspotStore {
    private static let ssidKey = "osmo.rtmp.hotspot.ssid"
    private static let passwordKey = "osmo.rtmp.hotspot.password"

    static func load() -> (ssid: String, password: String) {
        (KeychainStore.get(ssidKey) ?? "", KeychainStore.get(passwordKey) ?? "")
    }

    static func save(ssid: String, password: String) {
        KeychainStore.set(ssid, for: ssidKey)
        KeychainStore.set(password, for: passwordKey)
    }

    static func clear() {
        KeychainStore.delete(ssidKey)
        KeychainStore.delete(passwordKey)
    }

    static var hasSaved: Bool { KeychainStore.get(passwordKey) != nil }
}

@MainActor
final class OsmoRTMPLink {
    enum Failure: LocalizedError {
        case noCamera
        case badInput(String)
        case refused(String)
        case wifi(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: return String(localized: "カメラが見つかりませんでした。電源を入れて近くに置いてください")
            case .badInput(let s), .refused(let s), .wifi(let s): return s
            }
        }
    }

    /// 画面のログ用(パスワードは渡さない)
    var log: (String) -> Void = { _ in }
    private(set) var cameraName: String?
    private let bluetooth = OsmoBluetoothLink()
    private var keepaliveTask: Task<Void, Never>?
    /// 開始の命令を送った(止めるときに終わりの命令を送る)
    private var sentStart = false
    /// 配信が始まったあとは、カメラが送り続ける状態のフレームをログに出さない
    private var quiet = false

    init() {
        bluetooth.log = { [weak self] line in
            guard let self else { return }
            if self.quiet, line.hasPrefix("ble: recv"), !line.hasPrefix("ble: recv 0x02/0x8E") { return }
            self.log(line)
        }
    }

    /// Bluetooth でつなぎ、ペアリングして、ホットスポット・RTMP の URL・画質を送り、配信を始めてもらう。
    /// progress は画面に出す今の段階(MainActor)
    func start(ssid: String, password: String, url: String, model: OsmoRTMPModel, quality: OsmoRTMPQuality,
               progress: @escaping (String) -> Void) async throws {
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            throw Failure.badInput(String(localized: "インターネット共有の名前を確かめてください"))
        }
        guard (8...63).contains(password.utf8.count) else {
            throw Failure.badInput(String(localized: "パスワードは 8〜63 文字です"))
        }
        guard url.utf8.count <= OsmoRTMPCommands.maxURLBytes else {
            throw Failure.badInput("URL too long")
        }
        sentStart = false
        quiet = false

        progress(String(localized: "Bluetooth を準備しています…"))
        try await bluetooth.waitUntilPoweredOn()

        progress(String(localized: "カメラを探しています…"))
        let sighting = try await findCamera()
        cameraName = sighting.name
        let format = resolve(model, sighting)
        log("rtmp: camera \(sighting.name) \(sighting.modelName) -> config \(format == .pocket4 ? "v01 JSON (Pocket 4)" : "v00 URL (Pocket 3)")")

        progress(String(localized: "Bluetooth で接続中…"))
        try await bluetooth.connect(sighting.id)
        startKeepalive()

        // アプリのペアリング(OsmoLiveMonitor と同じ手順)
        progress(String(localized: "ペアリング中…"))
        bluetooth.send(OsmoCommands.sessionWake())
        let pin = try await bluetooth.request(OsmoCommands.setPairingPin(), timeout: 90, label: "SetPairingPIN")
        let result = pin.payload.count >= 2 ? pin.payload[1] : 0xFF
        log("rtmp: pair reply \(OsmoBluetoothLink.hex(pin.payload))")
        switch result {
        case 0x01:
            break
        case 0x02:
            progress(String(localized: "カメラの画面で接続を許可してください"))
            _ = try await bluetooth.waitForFrame(timeout: 90, label: "カメラでの許可") {
                $0.cmdSet == 0x07 && $0.cmdId == 0x46
            }
        case 0x06:
            throw Failure.refused(String(localized: "ペアリングを後回しにされました。数秒待ってもう一度試してください"))
        default:
            log(String(format: "rtmp: unknown pairing result %02X, continuing", result))
        }
        try await Task.sleep(for: .milliseconds(300))

        // 1. ライブ配信のモードに入る
        progress(String(localized: "ライブ配信の準備をしています…"))
        let prepared = try await requestReply(OsmoRTMPCommands.prepareLivestream(), timeout: 15, label: "0x02/0xE1")
        log("rtmp: prepare reply \(OsmoBluetoothLink.hex(prepared.payload))")
        guard prepared.payload.first == 0x00 else {
            throw Failure.refused(String(localized: "ライブ配信の準備を断られました(\(OsmoBluetoothLink.hex(prepared.payload)))"))
        }
        try await Task.sleep(for: .seconds(1))

        // 2. iPhone のインターネット共有に入る
        progress(String(localized: "カメラをインターネット共有につないでいます…"))
        try await joinWiFi(ssid: ssid, password: password)

        // 3. RTMP の URL と画質
        progress(String(localized: "配信の設定を送っています…"))
        let configure: OsmoDuml.Frame
        if format == .pocket4 {
            guard let made = OsmoRTMPCommands.configurePocket4(url: url) else { throw Failure.badInput("JSON") }
            configure = made
        } else {
            configure = OsmoRTMPCommands.configurePocket3(url: url, quality: quality)
            log("rtmp: Pocket 3 preset \(OsmoBluetoothLink.hex(OsmoRTMPCommands.pocket3Preset(quality)))")
        }
        log("rtmp: configure url \(url)")
        let configured = try await requestReply(configure, timeout: 10, label: "0x08/0x78")
        log("rtmp: configure reply \(OsmoBluetoothLink.hex(configured.payload))")
        guard configured.payload.first == 0x00 else {
            throw Failure.refused(String(localized: "配信の設定を断られました(\(OsmoBluetoothLink.hex(configured.payload)))。画質を下げるか、機種を選び直してください"))
        }

        // 4. 配信を始める(返事が無くても、映像が届けばよい)
        progress(String(localized: "配信を始めています…"))
        sentStart = true
        do {
            let started = try await requestReply(OsmoRTMPCommands.startLivestream(), timeout: 10, label: "0x02/0x8E")
            log("rtmp: start reply \(OsmoBluetoothLink.hex(started.payload))")
        } catch OsmoError.timeout {
            log("rtmp: no reply to start, waiting for the RTMP connection anyway")
        }
        quiet = true
    }

    /// 配信を終えてもらい、Bluetooth を切る
    func stopStream() async {
        if sentStart {
            bluetooth.send(OsmoRTMPCommands.stopLivestream())
            log("rtmp: sent stop")
            sentStart = false
            // 書き込みは 120ms ずつ。送り終わるのを待ってから切る
            try? await Task.sleep(for: .milliseconds(800))
        }
        disconnect()
    }

    func disconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        bluetooth.stopScan()
        bluetooth.disconnect()
        quiet = false
    }

    // MARK: 中身

    /// 送ってから、同じ命令の返事(flags に 0x80)を待つ
    private func requestReply(_ frame: OsmoDuml.Frame, timeout: TimeInterval, label: String) async throws -> OsmoDuml.Frame {
        let set = frame.cmdSet
        let cmd = frame.cmdId
        bluetooth.send(frame)
        return try await bluetooth.waitForFrame(timeout: timeout, label: label) {
            $0.cmdSet == set && $0.cmdId == cmd && ($0.flags & 0x80) != 0
        }
    }

    /// 0x07/0x47。01 FF は Wi-Fi の切り替え中なので 5 秒待ってやり直す(最大 3 回)
    private func joinWiFi(ssid: String, password: String) async throws {
        for attempt in 1...3 {
            log("rtmp: join hotspot #\(attempt) (name \(ssid.utf8.count) bytes, password \(password.utf8.count) chars)")
            let reply: OsmoDuml.Frame
            do {
                reply = try await requestReply(OsmoRTMPCommands.joinWiFi(ssid: ssid, password: password),
                                               timeout: 45, label: "0x07/0x47")
            } catch OsmoError.timeout {
                throw Failure.wifi(String(localized: "カメラがインターネット共有に入れませんでした。名前とパスワード、「互換性を優先」がオンかを確かめてください"))
            }
            let p = reply.payload
            log("rtmp: join reply \(OsmoBluetoothLink.hex(p))")
            if p == [0, 0] || p == [0, 0, 0] { return }
            if p == [0x01, 0xFF], attempt < 3 {
                try await Task.sleep(for: .seconds(5))
                continue
            }
            throw Failure.wifi(String(localized: "カメラがインターネット共有に入れませんでした(\(OsmoBluetoothLink.hex(p)))"))
        }
    }

    /// 20 秒まで探す。最初に見つかってから 3 秒待ち、Pocket らしいもののうち電波のいちばん強いものを選ぶ
    private func findCamera() async throws -> OsmoSighting {
        let bluetooth = self.bluetooth
        var found: [UUID: OsmoSighting] = [:]
        let stream = bluetooth.scan()
        let overall = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            bluetooth.stopScan()
        }
        var settle: Task<Void, Never>?
        for await sighting in stream {
            found[sighting.id] = sighting
            if settle == nil {
                settle = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    bluetooth.stopScan()
                }
            }
        }
        overall.cancel()
        settle?.cancel()
        bluetooth.stopScan()
        try Task.checkCancellation()
        let all = Array(found.values)
        let pockets = all.filter { s in
            if let id = s.modelId, (0x20...0x22).contains(id) { return true }
            return s.name.lowercased().contains("pocket")
        }
        let candidates = pockets.isEmpty ? all : pockets
        guard let best = candidates.max(by: { $0.rssi < $1.rssi }) else { throw Failure.noCamera }
        return best
    }

    /// 設定の形式を決める。Pocket 3 は広告に機種を入れないので、分からなければ Pocket 3
    private func resolve(_ model: OsmoRTMPModel, _ s: OsmoSighting) -> OsmoRTMPModel {
        switch model {
        case .pocket3, .pocket4:
            return model
        case .automatic:
            if let id = s.modelId {
                if id == 0x21 || id == 0x22 { return .pocket4 }
                if id == 0x20 { return .pocket3 }
            }
            let name = s.name.lowercased().replacingOccurrences(of: " ", with: "")
            return name.contains("pocket4") ? .pocket4 : .pocket3
        }
    }

    /// BLE をつないでいるあいだ 1 秒ごとに 0x00/0x2B を送る(OsmoLiveMonitor と同じ)
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
}
#endif
