// =====================================================================
// カメラの Wi-Fi の上の DUML データリンク(UDP 9004)。命令とライブビューの両方が通る(実験中・開発者向け)
//
// 手順は OpenPocketCine の資料(handbook/protocol/duml-transport.md・live-view.md、Apache 2.0)と
// OpenCine の Sources/OpenCineDJIApple/DjiAppleDatalink.swift を参考に、ライブビューに要る部分だけを
// この app 用に書き直したもの(再接続の細かい修復・ジンバル・メディア一覧などは入れていない)。
//
// 順番:
//  1. TCP 192.168.2.1:7001 に SetPairingPIN を 1 回書く(「つつく」)。このソケットは閉じない(閉じるとカメラが切る)
//  2. UDP 192.168.2.1:9004 に 40 バイトのハンドシェイク。返事(pktType 0x00)と 34 バイトのテレメトリーを待つ
//  3. 登録(0x00/0x81・0x00/0x88)と状態の購読(0x00/0x99)。そのあと 0x02/0x68 と 0x09/0xA8 でライブビュー開始
//  4. 窓 ACK(pktType 0x04)を 25ms ごと、登録を 1 秒ごとに送り続ける(登録が 8〜10 秒止まると映像が止まる)
// - UDP のローカルポートは 9004 にしない(電話側は空いている番号。9004 にすると映像だけ来なくなった報告がある)
// - iOS はモバイル通信を既定の経路にしたままなので、カメラの 192.168.2.x に結びつけて送る
// - 実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import Foundation
import Network

/// 一度だけ true を返す(続きを 2 回 resume しないため)
final class OsmoOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class OsmoDatalink: @unchecked Sendable {
    // コールバックはすべて `q`(このクラスの直列キュー)の上で呼ぶ
    var onAccessUnit: (@Sendable ([UInt8]) -> Void)?
    var onFrame: (@Sendable (OsmoDuml.Frame) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private let q = DispatchQueue(label: "videomania.osmo.datalink")
    private let localIPv4: String
    private var poke: NWConnection?
    private var udp: NWConnection?
    private var ackTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var closed = false

    // ---- 以下は q の上だけで触る ----
    private var sessionId: UInt16 = 0
    private var baseSeq: UInt16 = 0
    private var udpSeq: UInt16 = 0
    private var dumlSeq: UInt16 = 0xA000
    private var cmdCounter: UInt8 = 0
    private var handshakeAcked = false
    private var initialSequence: UInt16?
    private var videoCursor: UInt16 = 0
    private var sawVideo = false
    private var ackedCursor: UInt16 = 0
    private var sawAcked = false
    private var extraCursor: UInt16 = 0
    private var sawExtra = false
    private var acceptingVideo = false
    private var depacketizer = OsmoVideoDepacketizer()

    // 画面の診断用(q で更新、stats() で読む)
    private var datagrams = 0
    private var videoPackets = 0
    private var accessUnits = 0
    private var lastAccessUnitAt: Date?

    struct Stats {
        var datagrams = 0
        var videoPackets = 0
        var accessUnits = 0
        var droppedIncomplete = 0
        var lastAccessUnitAt: Date?
    }

    init(localIPv4: String) {
        self.localIPv4 = localIPv4
    }

    func stats() -> Stats {
        q.sync {
            Stats(datagrams: datagrams, videoPackets: videoPackets, accessUnits: accessUnits,
                  droppedIncomplete: depacketizer.droppedIncomplete, lastAccessUnitAt: lastAccessUnitAt)
        }
    }

    private func log(_ s: String) {
        onLog?(s)
    }

    // MARK: 開く

    func open() async throws {
        try await openPoke()
        try await openUDP()
        try await handshake()
        q.sync {
            sendAckOnQueue()
            sendDumlOnQueue(OsmoCommands.appDeviceInfo())
            sendDumlOnQueue(OsmoCommands.appPresence())
            // OpenCine の登録と同じ並び(ジンバルの初期化 0x03/0xDA も送っている)
            sendDumlOnQueue(OsmoDuml.Frame(sender: OsmoDuml.senderApp, receiver: OsmoCommands.rx(type: 0x03, id: 0),
                                           seq: 0, flags: OsmoDuml.flagRequest, cmdSet: 0x03, cmdId: 0xDA,
                                           payload: [0x05, 0xFF, 0xFF, 0xFF, 0xFF]))
            sendAckOnQueue()
            var subId = OsmoCommands.firstSubId
            for key in OsmoCommands.subscriptionKeys {
                sendDumlOnQueue(OsmoCommands.subscribe(key: key, subId: subId))
                subId += 1
            }
            sendAckOnQueue()
            // 映像はハンドシェイクの直後から届く(Mimo では DHCP の 17ms 後)。ここから受け取る
            depacketizer.reset()
            acceptingVideo = true
            startTimersOnQueue()
        }
        log("datalink: registered + subscribed")
    }

    /// ライブビュー開始(= キーフレームの要求)。何度も続けて送らないこと(呼ぶ側で数秒あける)
    func enableLiveView(prepare: Bool) {
        q.async { [self] in
            guard !closed else { return }
            if prepare { sendDumlOnQueue(OsmoCommands.liveViewPrepare()) }
            sendDumlOnQueue(OsmoCommands.liveViewEnable())
            log("datalink: sent 0x09/0xA8 (prepare=\(prepare))")
        }
    }

    /// 登録だけを送り直す(映像が止まったとき。ハンドシェイクは要らない)
    func reRegister() {
        q.async { [self] in
            guard !closed, handshakeAcked else { return }
            sendDumlOnQueue(OsmoCommands.appDeviceInfo())
            sendDumlOnQueue(OsmoCommands.appPresence())
            sendAckOnQueue()
        }
    }

    func close() {
        q.sync {
            closed = true
            acceptingVideo = false
            ackTimer?.cancel(); ackTimer = nil
            keepaliveTimer?.cancel(); keepaliveTimer = nil
            udp?.cancel(); udp = nil
            poke?.cancel(); poke = nil
        }
    }

    // MARK: 接続

    /// カメラの Wi-Fi(192.168.2.x)に結びつけ、モバイル通信を使わない
    private func parameters(_ base: NWParameters) -> NWParameters {
        base.prohibitedInterfaceTypes = [.cellular]
        base.allowLocalEndpointReuse = true
        base.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(localIPv4), port: .any)
        return base
    }

    private func openPoke() async throws {
        for attempt in 1...4 {
            try Task.checkCancellation()
            let tcp = NWConnection(host: NWEndpoint.Host(OsmoWiFi.cameraHost), port: 7001,
                                   using: parameters(.tcp))
            q.sync { poke = tcp }
            do {
                // 初回は「ローカルネットワーク」の許可のダイアログが出るので長めに待つ
                try await waitReady(tcp, timeout: attempt == 1 ? 30 : 3)
                tcp.send(content: Data(OsmoDuml.encode(OsmoCommands.setPairingPin())), completion: .idempotent)
                try await Task.sleep(for: .milliseconds(400))
                if case .ready = tcp.state {
                    Self.drain(tcp)
                    log("datalink: TCP 7001 poke ready")
                    return
                }
                log("datalink: TCP 7001 not ready after write (\(tcp.state))")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("datalink: TCP 7001 attempt \(attempt) failed (\(error.localizedDescription))")
            }
            tcp.cancel()
            q.sync { poke = nil }
            try await Task.sleep(for: .milliseconds(350))
        }
        // OpenPocketCine も、つつきに失敗しても UDP を試す
        log("datalink: TCP 7001 poke failed, trying UDP anyway")
    }

    /// カメラは 7001 に 1 秒 3 回ほど書いてくる。読まないと受信の窓が埋まる(中身は使わない)
    private static func drain(_ tcp: NWConnection) {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, complete, error in
            guard !complete, error == nil else { return }
            drain(tcp)
        }
    }

    private func openUDP() async throws {
        let conn = NWConnection(host: NWEndpoint.Host(OsmoWiFi.cameraHost), port: 9004, using: parameters(.udp))
        q.sync { udp = conn }
        try await waitReady(conn, timeout: 30)
        armReceive(conn)
        log("datalink: UDP 9004 ready (local \(localIPv4))")
    }

    private func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
        let once = OsmoOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                if once.claim() { cont.resume(with: result) }
            }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(e))
                case .cancelled: finish(.failure(CancellationError()))
                case .waiting(let e):
                    // ローカルネットワークを拒否されていると、失敗せずに待ち続ける
                    self?.log("datalink: waiting (\(e.localizedDescription)) - ローカルネットワークの許可を確認")
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(OsmoError.datalink("接続が \(Int(timeout)) 秒で準備できませんでした(ローカルネットワークの許可が「オフ」の可能性)")))
            }
        }
    }

    // MARK: ハンドシェイク

    private func handshake() async throws {
        q.sync {
            sessionId = UInt16.random(in: 0x1000...0xFFFE)
            baseSeq = UInt16.random(in: 0x1000...0xF000) & 0xFFF8  // 8 の倍数、接続ごとに変える
            udpSeq = 0
            dumlSeq = 0xA000
            cmdCounter = 0
            handshakeAcked = false
            initialSequence = nil
        }
        for send in 1...20 {
            try Task.checkCancellation()
            q.sync {
                let pkt = OsmoTransport.handshakeDatagram(sessionId: sessionId, seq: udpSeq, baseSeq: baseSeq)
                udp?.send(content: Data(pkt), completion: .idempotent)
                udpSeq &+= 8
            }
            if send == 1 { log("datalink: handshake sent") }
            // 返事は数十 ms で来る。1 回あたり 350ms まで待つ
            for _ in 0..<18 {
                if q.sync(execute: { handshakeAcked && initialSequence != nil }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if q.sync(execute: { handshakeAcked && initialSequence != nil }) { break }
        }
        // 返事だけでなく最初のテレメトリー(命令番号の窓)が来てから命令を送る(先に送ると映像の開始が遅れた報告がある)
        let deadline = Date().addingTimeInterval(5)
        while !q.sync(execute: { handshakeAcked && initialSequence != nil }) {
            guard Date() < deadline else {
                let acked = q.sync { handshakeAcked }
                throw OsmoError.datalink(acked ? "ハンドシェイクの返事は来たがテレメトリーが来ない"
                                               : "カメラがハンドシェイクに答えない(UDP 9004)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let session = q.sync { () -> UInt16 in
            if let initial = initialSequence { udpSeq = initial }
            return sessionId
        }
        log(String(format: "datalink: handshake acked session=%04X", session))
    }

    // MARK: 送る(q の上)

    private func sendDumlOnQueue(_ frame: OsmoDuml.Frame) {
        guard let udp else { return }
        cmdCounter &+= 1
        var f = frame
        f.seq = dumlSeq
        dumlSeq &+= 1
        let routing = OsmoTransport.routingHeader(seq: udpSeq, cmdCounter: cmdCounter)
        let duml = OsmoDuml.encode(f)
        let pkt = OsmoTransport.transportHeader(pktType: OsmoTransport.PktType.command.rawValue,
                                                payloadLen: routing.count + duml.count,
                                                sessionId: sessionId, seq: udpSeq) + routing + duml
        udpSeq &+= 8
        udp.send(content: Data(pkt), completion: .idempotent)
    }

    private func sendAckOnQueue() {
        guard let udp else { return }
        let payload = OsmoTransport.ackPayload(
            video: videoCursor,
            acked: sawAcked ? ackedCursor : baseSeq,
            extra: sawExtra ? extraCursor : baseSeq)
        let pkt = OsmoTransport.transportHeader(pktType: OsmoTransport.PktType.ack.rawValue,
                                                payloadLen: payload.count, sessionId: sessionId, seq: 0) + payload
        udp.send(content: Data(pkt), completion: .idempotent)
    }

    private func startTimersOnQueue() {
        let ack = DispatchSource.makeTimerSource(queue: q)
        ack.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        ack.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.sendAckOnQueue()
        }
        ack.resume()
        ackTimer = ack

        let keep = DispatchSource.makeTimerSource(queue: q)
        keep.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        keep.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            // Mimo は 0x00/0x88(全文)と 0x00/0x81 を毎秒送っている。止めると 8〜10 秒で映像が止まる
            self.sendDumlOnQueue(OsmoCommands.appDeviceInfo())
            self.sendDumlOnQueue(OsmoCommands.appPresence())
        }
        keep.resume()
        keepaliveTimer = keep
    }

    // MARK: 受ける(q の上)

    private func armReceive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            switch conn.state {
            case .cancelled, .failed: return
            default: break
            }
            // 先に次の受信を仕掛けてから処理する(逆にすると映像が最初の塊で止まった報告がある)
            if error != nil {
                self.q.asyncAfter(deadline: .now() + .milliseconds(40)) { self.armReceive(conn) }
            } else {
                self.armReceive(conn)
            }
            if let data, !data.isEmpty { self.ingest([UInt8](data)) }
        }
    }

    private func ingest(_ d: [UInt8]) {
        guard !closed, d.count >= 8 else { return }
        datagrams += 1
        switch d[6] {
        case OsmoTransport.PktType.handshake.rawValue:
            handshakeAcked = true
        case OsmoTransport.PktType.telemetry.rawValue:
            if initialSequence == nil, let s = OsmoTransport.initialCommandSequence(fromTelemetry: d) {
                initialSequence = s
            }
            if let w = OsmoTransport.telemetryWindows(d) {
                if !sawVideo { videoCursor = w.video }
                if !sawAcked || w.acked == ackedCursor || OsmoTransport.isForward(w.acked, from: ackedCursor) {
                    ackedCursor = w.acked
                    sawAcked = true
                }
                extraCursor = w.extra
                sawExtra = true
            }
        case OsmoTransport.PktType.ackedData.rawValue:
            if let s = OsmoTransport.transportSeq(d),
               !sawAcked || OsmoTransport.isForward(s, from: ackedCursor) {
                ackedCursor = s
                sawAcked = true
            }
        case OsmoTransport.PktType.video.rawValue:
            if let s = OsmoTransport.transportSeq(d) {
                videoCursor = s
                sawVideo = true
            }
            guard acceptingVideo else { return }
            videoPackets += 1
            if let au = depacketizer.feed(d) {
                accessUnits += 1
                lastAccessUnitAt = Date()
                onAccessUnit?(au)
            }
            return
        default:
            break
        }
        for frame in OsmoDuml.scanFrames(d) { onFrame?(frame) }
    }
}
#endif
