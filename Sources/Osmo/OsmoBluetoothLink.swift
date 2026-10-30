// =====================================================================
// Osmo カメラとの Bluetooth(BLE)。探す・つなぐ・ペアリング・DUML の読み書き(実験中・開発者向け)
//
// 手順は OpenCine(Apache 2.0、Sources/OpenCineDJIApple/DjiAppleBluetoothLink.swift)と
// OpenPocketCine の資料(handbook/protocol/ble.md)を参考に、この app 用に書き直したもの。
// docs/licenses/OpenCine-NOTICE.txt を参照。
//
// - サービス fff0、通知 fff4、書き込み fff5(返事なしで書く。続けて書くと落ちるので約 120ms あける)
// - Pocket 3 は広告に製造者データを入れないので、絞り込まずに探して名前でも見分ける
// - 実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import CoreBluetooth
import Foundation

/// 見つかったカメラ
struct OsmoSighting: Identifiable, Equatable {
    let id: UUID  // CoreBluetooth は MAC アドレスを隠すので、iOS が振る識別子
    let name: String
    /// 広告から読めた機種(Pocket 3 = 0x20、Pocket 4 = 0x21、Pocket 4 Pro = 0x22)
    let modelId: Int?
    let rssi: Int

    var modelName: String {
        switch modelId {
        case 0x20: return "Osmo Pocket 3"
        case 0x21: return "Osmo Pocket 4"
        case 0x22: return "Osmo Pocket 4 Pro"
        case let id?: return String(format: "DJI 0x%04X", id)
        case nil: return "DJI(機種不明)"
        }
    }
}

enum OsmoError: LocalizedError {
    case bluetoothUnavailable(String)
    case gone
    case noService
    case timeout(String)
    case refused(String)
    case wifi(String)
    case datalink(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let s): return "Bluetooth が使えません(\(s))"
        case .gone: return "カメラとの接続が切れました"
        case .noService: return "カメラに DUML のサービス(fff0)がありません"
        case .timeout(let s): return "時間切れ: \(s)"
        case .refused(let s): return "カメラが断りました: \(s)"
        case .wifi(let s): return "Wi-Fi: \(s)"
        case .datalink(let s): return "データリンク: \(s)"
        }
    }
}

@MainActor
final class OsmoBluetoothLink: NSObject {
    private static let serviceUUID = CBUUID(string: "FFF0")
    private static let fff4UUID = CBUUID(string: "FFF4")
    private static let fff5UUID = CBUUID(string: "FFF5")
    /// DJI の Bluetooth 会社 ID(リトルエンディアンで AA 08 / AA F7)
    private static let djiCompanyIds: Set<Int> = [0x08AA, 0xF7AA, 0xE5C0]

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var sightings: [UUID: OsmoSighting] = [:]
    private var connected: CBPeripheral?
    private var fff4: CBCharacteristic?
    private var fff5: CBCharacteristic?
    private var fff4Settled = false
    private var fff5Settled = false
    private var pairingArmed = false
    private var assemblers: [CBUUID: OsmoNotificationAssembler] = [:]

    private var scanContinuation: AsyncStream<OsmoSighting>.Continuation?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var connectDeadline: DispatchWorkItem?

    private var writeQueue: [Data] = []
    private var writing = false

    private struct Waiter {
        let match: (OsmoDuml.Frame) -> Bool
        let continuation: CheckedContinuation<OsmoDuml.Frame, Error>
    }
    private var waiters: [UUID: Waiter] = [:]
    /// 待つ前に届いた返事(ペアリングの許可が先に来ることがある)
    private var unclaimed: [OsmoDuml.Frame] = []

    /// 画面のログ用
    var log: (String) -> Void = { _ in }

    override init() {
        super.init()
        // デリゲートはメインキュー(MainActor.assumeIsolated で受ける)
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isPoweredOn: Bool { central.state == .poweredOn }

    /// 初回は Bluetooth の許可のダイアログが出る。出ているあいだは待ち続ける
    func waitUntilPoweredOn(timeout: TimeInterval = 10) async throws {
        var deadline = Date().addingTimeInterval(timeout)
        while !isPoweredOn {
            if central.state == .unauthorized || CBManager.authorization == .denied {
                throw OsmoError.bluetoothUnavailable("設定アプリで Video Mania の Bluetooth を許可してください")
            }
            if CBManager.authorization == .notDetermined { deadline = Date().addingTimeInterval(timeout) }
            if central.state == .poweredOff { throw OsmoError.bluetoothUnavailable("Bluetooth がオフです") }
            if Date() > deadline { throw OsmoError.bluetoothUnavailable("state=\(central.state.rawValue)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: 探す

    func scan() -> AsyncStream<OsmoSighting> {
        peripherals.removeAll()
        sightings.removeAll()
        return AsyncStream { continuation in
            self.scanContinuation?.finish()
            self.scanContinuation = continuation
            // 絞り込まない(Pocket 3 は製造者データを出さない)。最初の広告は名前が無いことが多いので重複も受ける
            self.central.scanForPeripherals(withServices: nil,
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            self.log("ble: scan start")
        }
    }

    func stopScan() {
        if central.state == .poweredOn { central.stopScan() }
        scanContinuation?.finish()
        scanContinuation = nil
    }

    // MARK: つなぐ

    /// GATT につなぎ、fff4/fff5 の通知を有効にして、fff4 に 01 00 を書く(ペアリングの準備)まで待つ
    func connect(_ id: UUID) async throws {
        guard let p = peripherals[id] else { throw OsmoError.gone }
        disconnect()
        connected = p
        p.delegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyContinuation = c
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.readyContinuation != nil else { return }
                    self.central.cancelPeripheralConnection(p)
                    self.finishConnect(OsmoError.timeout("Bluetooth の接続(10 秒)"))
                }
            }
            connectDeadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
            central.connect(p, options: nil)
        }
    }

    func disconnect() {
        writeQueue.removeAll()
        assemblers.removeAll()
        unclaimed.removeAll()
        finishConnect(OsmoError.gone)
        failWaiters(OsmoError.gone)
        if let p = connected { central.cancelPeripheralConnection(p) }
        connected = nil
        fff4 = nil
        fff5 = nil
        fff4Settled = false
        fff5Settled = false
        pairingArmed = false
    }

    private func finishConnect(_ error: Error?) {
        connectDeadline?.cancel()
        connectDeadline = nil
        guard let c = readyContinuation else { return }
        readyContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: 送る・待つ

    /// fff5 に返事なしで書く。続けて書くと落ちるので 120ms ずつあける
    func send(_ frame: OsmoDuml.Frame) {
        if !(frame.cmdSet == 0 && frame.cmdId == 0x2B) {
            log(String(format: "ble: send 0x%02X/0x%02X %dB", frame.cmdSet, frame.cmdId, frame.payload.count))
        }
        writeQueue.append(Data(OsmoDuml.encode(frame)))
        pumpWrites()
    }

    private func pumpWrites() {
        guard !writing, !writeQueue.isEmpty, let fff5, let p = connected else { return }
        writing = true
        p.writeValue(writeQueue.removeFirst(), for: fff5, type: .withoutResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                self?.writing = false
                self?.pumpWrites()
            }
        }
    }

    /// `matching` に合うフレームが届くまで待つ(すでに届いていればそれを返す)
    func waitForFrame(timeout: TimeInterval, label: String,
                      matching: @escaping (OsmoDuml.Frame) -> Bool) async throws -> OsmoDuml.Frame {
        if let i = unclaimed.firstIndex(where: matching) { return unclaimed.remove(at: i) }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = Waiter(match: matching, continuation: continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let w = self.waiters.removeValue(forKey: id) else { return }
                    w.continuation.resume(throwing: OsmoError.timeout(label))
                }
            }
        }
    }

    /// 送ってから、同じ cmdSet/cmdId の返事を待つ
    func request(_ frame: OsmoDuml.Frame, timeout: TimeInterval, label: String) async throws -> OsmoDuml.Frame {
        let set = frame.cmdSet, cmd = frame.cmdId
        // 返事(flags の 0x80 が立つ)だけを待つ。前の同じ命令の遅れた返事は先に捨てる
        let isReply: (OsmoDuml.Frame) -> Bool = { $0.cmdSet == set && $0.cmdId == cmd && $0.flags & 0x80 != 0 }
        unclaimed.removeAll(where: isReply)
        // 返事は MainActor が空くまで届かず、先に届いても unclaimed に残るので、送ってから待ってよい
        send(frame)
        return try await waitForFrame(timeout: timeout, label: label, matching: isReply)
    }

    /// アプリのペアリング(Bluetooth の「ペアリング」とは別。カメラが app の識別子を覚える)。
    /// つないだあとに呼ぶ。初回はカメラの画面での許可を待つ(`onAwaitingApproval` が呼ばれる)
    func pairApp(onAwaitingApproval: () -> Void) async throws {
        send(OsmoCommands.sessionWake())
        let pin = try await request(OsmoCommands.setPairingPin(), timeout: 90, label: "SetPairingPIN")
        let result = pin.payload.count >= 2 ? pin.payload[1] : 0xFF
        log("pair: reply \(Self.hex(pin.payload))")
        switch result {
        case 0x01:
            log("pair: already paired")
        case 0x02:
            onAwaitingApproval()
            _ = try await waitForFrame(timeout: 90, label: "カメラでの許可") {
                $0.cmdSet == 0x07 && $0.cmdId == 0x46
            }
            log("pair: approved on camera")
        case 0x06:
            throw OsmoError.refused("ペアリングを後回しにされました(00 06)。数秒待ってもう一度")
        default:
            log(String(format: "pair: unknown result %02X, continuing", result))
        }
    }

    private func failWaiters(_ error: Error) {
        let all = waiters
        waiters.removeAll()
        for w in all.values { w.continuation.resume(throwing: error) }
    }

    private func deliver(_ frame: OsmoDuml.Frame) {
        if !(frame.cmdSet == 0 && frame.cmdId == 0x2B) {
            log(String(format: "ble: recv 0x%02X/0x%02X flags=%02X %@", frame.cmdSet, frame.cmdId,
                       frame.flags, Self.hex(frame.payload)))
        }
        // 初回の許可(カメラの画面で OK)は 0x07/0x46 の「要求」として届く。すぐ返事をする
        if frame.cmdSet == 0x07, frame.cmdId == 0x46, frame.flags & 0x80 == 0 {
            send(OsmoCommands.pairApprovalAck(seq: frame.seq))
        }
        if let entry = waiters.first(where: { $0.value.match(frame) }) {
            waiters.removeValue(forKey: entry.key)
            entry.value.continuation.resume(returning: frame)
            return
        }
        unclaimed.append(frame)
        if unclaimed.count > 32 { unclaimed.removeFirst(unclaimed.count - 32) }
    }

    static func hex(_ bytes: [UInt8], limit: Int = 24) -> String {
        if bytes.isEmpty { return "-" }
        let head = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? head + "…" : head
    }

    // MARK: 見分ける

    fileprivate func classify(_ p: CBPeripheral, _ adv: [String: Any], rssi: Int) -> OsmoSighting? {
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        var modelId: Int?
        var isDji = false
        if let mfr = adv[CBAdvertisementDataManufacturerDataKey] as? Data, mfr.count >= 2 {
            let company = Int(mfr[mfr.startIndex]) | (Int(mfr[mfr.startIndex + 1]) << 8)
            if Self.djiCompanyIds.contains(company) {
                isDji = true
                modelId = Self.decodeModelId([UInt8](mfr.dropFirst(2)))
            }
        }
        let lower = name?.lowercased() ?? ""
        let nameLooksDji = ["osmo", "pocket", "dji"].contains { lower.contains($0) }
        guard isDji || nameLooksDji else { return nil }
        return OsmoSighting(id: p.identifier, name: name ?? "DJI camera", modelId: modelId, rssi: rssi)
    }

    /// 広告の製造者データ(会社 ID を除いたもの)から機種を読む(OpenCine BleAdvert.swift と同じ規則)。
    /// 新しい形式(5 バイト目の bit 2)は 10〜11 バイト目が製品番号で、それを旧来の機種番号に置き換える
    static func decodeModelId(_ p: [UInt8]) -> Int? {
        let productToModel: [Int: Int] = [145: 0x0020, 219: 0x0021, 218: 0x0022]
        if p.count >= 12, (p[5] & 0x04) != 0 {
            let product = Int(p[10]) | (Int(p[11]) << 8)
            if let mapped = productToModel[product] { return mapped }
        }
        guard p.count >= 2 else { return nil }
        let legacy = Int(p[0]) | (Int(p[1]) << 8)
        return legacy == 0 ? nil : legacy
    }

    // MARK: デリゲートの処理(MainActor)

    fileprivate func handleDiscover(_ p: CBPeripheral, _ adv: [String: Any], rssi: Int) {
        guard let sighting = classify(p, adv, rssi: rssi) else { return }
        peripherals[p.identifier] = p
        if let last = sightings[p.identifier], last.name == sighting.name, last.modelId == sighting.modelId {
            return
        }
        sightings[p.identifier] = sighting
        scanContinuation?.yield(sighting)
    }

    fileprivate func handleConnected(_ p: CBPeripheral) {
        guard p === connected else { return }
        stopScan()
        log("ble: connected, discovering fff0")
        p.discoverServices([Self.serviceUUID])
    }

    fileprivate func handleDisconnected(_ p: CBPeripheral, error: Error?) {
        guard p === connected else { return }
        log("ble: disconnected \(error?.localizedDescription ?? "")")
        finishConnect(error ?? OsmoError.gone)
        failWaiters(OsmoError.gone)
        connected = nil
    }

    fileprivate func handleServices(_ p: CBPeripheral, error: Error?) {
        guard p === connected else { return }
        if let error { finishConnect(error); return }
        guard let svc = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finishConnect(OsmoError.noService)
            return
        }
        p.discoverCharacteristics([Self.fff4UUID, Self.fff5UUID], for: svc)
    }

    fileprivate func handleCharacteristics(_ p: CBPeripheral, service: CBService, error: Error?) {
        guard p === connected else { return }
        if let error { finishConnect(error); return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.fff4UUID { fff4 = c; requestNotify(c, on: p) }
            if c.uuid == Self.fff5UUID { fff5 = c; requestNotify(c, on: p) }
        }
        if fff4 == nil || fff5 == nil { finishConnect(OsmoError.noService) }
    }

    private func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral) {
        if c.properties.contains(.notify) || c.properties.contains(.indicate) {
            p.setNotifyValue(true, for: c)
        } else if c.uuid == Self.fff4UUID {
            fff4Settled = true
        } else {
            fff5Settled = true
        }
    }

    fileprivate func handleNotifyState(_ p: CBPeripheral, characteristic: CBCharacteristic) {
        guard p === connected else { return }
        if characteristic.uuid == Self.fff4UUID { fff4Settled = true }
        if characteristic.uuid == Self.fff5UUID { fff5Settled = true }
        // 両方の通知の設定が終わってから fff4 に 01 00 を書く(ペアリングの準備)
        guard !pairingArmed, fff4Settled, fff5Settled, let fff4, fff4.isNotifying else { return }
        pairingArmed = true
        p.writeValue(Data([0x01, 0x00]), for: fff4, type: .withResponse)
    }

    fileprivate func handleWrite(_ p: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard p === connected, characteristic.uuid == Self.fff4UUID else { return }
        log("ble: pairing armed \(error?.localizedDescription ?? "ok")")
        finishConnect(error)
        pumpWrites()
    }

    fileprivate func handleValue(_ p: CBPeripheral, characteristic: CBCharacteristic) {
        guard p === connected, let value = characteristic.value else { return }
        guard characteristic.uuid == Self.fff4UUID || characteristic.uuid == Self.fff5UUID else { return }
        var assembler = assemblers[characteristic.uuid] ?? OsmoNotificationAssembler()
        let frames = assembler.append([UInt8](value))
        assemblers[characteristic.uuid] = assembler
        for frame in frames { deliver(frame) }
    }
}

extension OsmoBluetoothLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state.rawValue
        MainActor.assumeIsolated { self.log("ble: state=\(state)") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { self.handleDiscover(peripheral, advertisementData, rssi: RSSI.intValue) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.handleDisconnected(peripheral, error: error) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.handleDisconnected(peripheral, error: error) }
    }
}

extension OsmoBluetoothLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { self.handleServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated { self.handleCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { self.handleNotifyState(peripheral, characteristic: characteristic) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { self.handleWrite(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { self.handleValue(peripheral, characteristic: characteristic) }
    }
}
#endif
