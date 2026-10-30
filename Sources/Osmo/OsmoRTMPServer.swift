// =====================================================================
// iPhone の中で動く小さな RTMP サーバー(受け取り専用、実験中・開発者向け)
//
// Osmo Pocket の「配信」は、カメラが自分で Wi-Fi に入り、指定した RTMP サーバーへ映像と音声を送る。
// その送り先を iPhone にして、カメラ本体に残さずに iPhone に録画するためのもの。
//
// - 1 台のカメラから 1 本だけ受ける(publish のみ。再生は扱わない)
// - ハンドシェイクは単純な形(S2 = C1 のこだま)。暗号化(RTMPS / RTMPE)は扱わない
// - 映像: FLV の H.264(codec 7)・HEVC(codec 12)と Enhanced RTMP(hvc1 / avc1)
// - 音声: AAC
// - 仕様: Adobe RTMP 1.0、FLV 10.1、Enhanced RTMP v1(veovera/enhanced-rtmp)。この app で一から書いたもの
// - 実機のカメラとはまだ一度も試していない(ffmpeg から送る試験は docs/OsmoPocket.md を参照)
// =====================================================================

#if OSMO_LIVE
import Foundation
import Network

final class OsmoRTMPServer: @unchecked Sendable {
    enum Event {
        case log(String)
        case connected(String)
        case publishing(String)
        case metadata(String)
        /// パラメーターセット(HEVC は VPS/SPS/PPS、H.264 は SPS/PPS)と NAL の長さのバイト数
        case videoConfig(codec: OsmoVideoCodec, parameterSets: [[UInt8]], nalLengthSize: Int)
        /// `data` は長さ付きの NAL を並べたもの。時刻はミリ秒
        case videoFrame(data: [UInt8], dts: Int64, pts: Int64, keyframe: Bool)
        case audioConfig(asc: [UInt8])
        case audioFrame(data: [UInt8], timestamp: Int64)
        case disconnected(String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    static let port: UInt16 = 1935

    private let q = DispatchQueue(label: "videomania.osmo.rtmp")
    private var listener: NWListener?
    private var connection: NWConnection?

    // ---- 以下は q の上だけで触る ----
    private enum Stage { case c0c1, c2, chunks }
    private var stage: Stage = .c0c1
    private var buf: [UInt8] = []
    private var pos = 0
    private var inChunkSize = 128
    private var outChunkSize = 128
    private var peerWindow: UInt32 = 2_500_000
    private var received: UInt64 = 0
    private var lastAck: UInt64 = 0
    private var warnedVideo = false
    private var warnedAudio = false

    private struct ChunkStream {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var typeId: UInt8 = 0
        var streamId: UInt32 = 0
        var extended = false
        var payload: [UInt8] = []
    }
    private var chunkStreams: [UInt32: ChunkStream] = [:]

    // MARK: 開始・終了

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            self?.emit(.log("rtmp: listener \(state)"))
        }
        listener = l
        l.start(queue: q)
    }

    func stop() {
        q.sync {
            listener?.cancel(); listener = nil
            connection?.cancel(); connection = nil
        }
    }

    private func emit(_ e: Event) { onEvent?(e) }

    private func accept(_ conn: NWConnection) {
        // 1 本だけ。新しい接続が来たら古いほうを切る(カメラの再接続)
        connection?.cancel()
        connection = conn
        stage = .c0c1
        buf = []; pos = 0
        inChunkSize = 128; outChunkSize = 128
        received = 0; lastAck = 0
        chunkStreams = [:]
        let peer = "\(conn.endpoint)"
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready: self.emit(.connected(peer))
            case .failed(let e): self.emit(.disconnected(e.localizedDescription))
            case .cancelled: break
            default: break
            }
        }
        conn.start(queue: q)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                self.received += UInt64(data.count)
                self.process()
                self.sendAckIfNeeded()
            }
            if complete || error != nil {
                self.emit(.disconnected(error?.localizedDescription ?? "closed by camera"))
                conn.cancel()
                if self.connection === conn { self.connection = nil }
                return
            }
            self.receive(conn)
        }
    }

    // MARK: 受けたバイトの処理

    private func process() {
        loop: while true {
            switch stage {
            case .c0c1:
                guard buf.count - pos >= 1 + 1536 else { break loop }
                let c1 = Array(buf[(pos + 1)..<(pos + 1537)])
                pos += 1537
                var s1 = [UInt8](repeating: 0, count: 1536)
                for i in 8..<1536 { s1[i] = UInt8.random(in: 0...255) }
                // S0 + S1 + S2(S2 は C1 のこだま)
                send([0x03] + s1 + c1)
                stage = .c2
            case .c2:
                guard buf.count - pos >= 1536 else { break loop }
                pos += 1536
                stage = .chunks
                emit(.log("rtmp: handshake done"))
            case .chunks:
                if !parseChunk() { break loop }
            }
        }
        if pos > 0 && pos >= buf.count / 2 {
            buf.removeFirst(pos)
            pos = 0
        }
    }

    private func u24(_ i: Int) -> UInt32 { UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]) }
    private func u32be(_ i: Int) -> UInt32 {
        UInt32(buf[i]) << 24 | UInt32(buf[i + 1]) << 16 | UInt32(buf[i + 2]) << 8 | UInt32(buf[i + 3])
    }
    private func u32le(_ i: Int) -> UInt32 {
        UInt32(buf[i]) | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]) << 16 | UInt32(buf[i + 3]) << 24
    }

    /// チャンクを 1 つ読む。足りなければ何も変えずに false
    private func parseChunk() -> Bool {
        let avail = buf.count
        var i = pos
        guard i < avail else { return false }
        let b0 = buf[i]; i += 1
        let fmt = Int(b0 >> 6)
        var csid = UInt32(b0 & 0x3F)
        if csid == 0 {
            guard i < avail else { return false }
            csid = 64 + UInt32(buf[i]); i += 1
        } else if csid == 1 {
            guard i + 1 < avail else { return false }
            csid = 64 + UInt32(buf[i]) + UInt32(buf[i + 1]) * 256; i += 2
        }
        var cs = chunkStreams[csid] ?? ChunkStream()
        let headerSize = [11, 7, 3, 0][fmt]
        guard i + headerSize <= avail else { return false }
        var tsField: UInt32 = 0
        if fmt <= 2 { tsField = u24(i) }
        if fmt <= 1 {
            cs.length = Int(u24(i + 3))
            cs.typeId = buf[i + 6]
        }
        if fmt == 0 { cs.streamId = u32le(i + 7) }
        i += headerSize
        let hasExtended = fmt <= 2 ? tsField == 0xFFFFFF : cs.extended
        var extended: UInt32?
        if hasExtended {
            guard i + 4 <= avail else { return false }
            extended = u32be(i); i += 4
        }
        // 途中で新しいメッセージが始まったら、読みかけは捨てる
        if fmt <= 2, !cs.payload.isEmpty { cs.payload = [] }
        let startsMessage = cs.payload.isEmpty
        let value = extended ?? tsField
        if fmt <= 2 { cs.extended = tsField == 0xFFFFFF }
        switch fmt {
        case 0: cs.timestamp = value; cs.delta = value
        case 1, 2: cs.delta = value; cs.timestamp &+= value
        default: if startsMessage { cs.timestamp &+= cs.delta }
        }
        guard cs.length >= 0, cs.length <= 16 * 1024 * 1024 else {
            emit(.log("rtmp: bad message length \(cs.length), closing"))
            connection?.cancel()
            return false
        }
        let take = min(inChunkSize, cs.length - cs.payload.count)
        guard i + take <= avail else { return false }
        cs.payload.append(contentsOf: buf[i..<(i + take)])
        i += take
        pos = i
        if cs.payload.count >= cs.length {
            let message = cs.payload
            cs.payload = []
            chunkStreams[csid] = cs
            handleMessage(type: cs.typeId, streamId: cs.streamId, timestamp: cs.timestamp, payload: message)
        } else {
            chunkStreams[csid] = cs
        }
        return true
    }

    private func sendAckIfNeeded() {
        guard peerWindow > 0, received - lastAck >= UInt64(peerWindow) else { return }
        lastAck = received
        let n = UInt32(truncatingIfNeeded: received)
        sendMessage(csid: 2, type: 3, streamId: 0, payload: Self.be32(n))
    }

    // MARK: メッセージ

    private func handleMessage(type: UInt8, streamId: UInt32, timestamp: UInt32, payload p: [UInt8]) {
        switch type {
        case 1:  // Set Chunk Size
            if p.count >= 4 {
                let size = Int((UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])) & 0x7FFF_FFFF)
                inChunkSize = max(1, min(size, 16 * 1024 * 1024))
                emit(.log("rtmp: peer chunk size \(inChunkSize)"))
            }
        case 2:  // Abort
            if p.count >= 4 {
                let id = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
                chunkStreams[id]?.payload = []
            }
        case 4:  // User Control。Ping(6)には Pong(7)で答える
            if p.count >= 6, p[0] == 0, p[1] == 6 {
                sendMessage(csid: 2, type: 4, streamId: 0, payload: [0, 7] + Array(p[2..<6]))
            }
        case 5:  // Window Acknowledgement Size
            if p.count >= 4 {
                peerWindow = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
            }
        case 8:
            handleAudio(p, timestamp: Int64(timestamp))
        case 9:
            handleVideo(p, timestamp: Int64(timestamp))
        case 18:  // データ(AMF0)。@setDataFrame onMetaData
            emit(.metadata(OsmoAMF.decode(p).map(\.description).joined(separator: " ")))
        case 15:
            if !p.isEmpty { emit(.metadata(OsmoAMF.decode(Array(p.dropFirst())).map(\.description).joined(separator: " "))) }
        case 20:
            handleCommand(OsmoAMF.decode(p), streamId: streamId)
        case 17:  // AMF3 の命令(先頭 1 バイトを飛ばすと AMF0)
            if !p.isEmpty { handleCommand(OsmoAMF.decode(Array(p.dropFirst())), streamId: streamId) }
        default:
            break
        }
    }

    private func handleCommand(_ values: [OsmoAMF], streamId: UInt32) {
        guard case .string(let name)? = values.first else { return }
        let txid: Double
        if values.count > 1, case .number(let n) = values[1] { txid = n } else { txid = 0 }
        emit(.log("rtmp: command \(name)"))
        switch name {
        case "connect":
            sendMessage(csid: 2, type: 5, streamId: 0, payload: Self.be32(2_500_000))
            sendMessage(csid: 2, type: 6, streamId: 0, payload: Self.be32(2_500_000) + [2])
            sendMessage(csid: 2, type: 1, streamId: 0, payload: Self.be32(4096))
            outChunkSize = 4096
            sendCommand(streamId: 0, [
                .string("_result"), .number(txid),
                .object([("fmsVer", .string("FMS/3,0,1,123")), ("capabilities", .number(31))]),
                .object([("level", .string("status")), ("code", .string("NetConnection.Connect.Success")),
                         ("description", .string("Connection succeeded.")), ("objectEncoding", .number(0))]),
            ])
        case "releaseStream", "FCPublish":
            sendCommand(streamId: 0, [.string("_result"), .number(txid), .null, .undefined])
        case "createStream":
            sendCommand(streamId: 0, [.string("_result"), .number(txid), .null, .number(1)])
        case "publish":
            var streamName = ""
            if values.count > 3, case .string(let s) = values[3] { streamName = s }
            sendCommand(streamId: streamId == 0 ? 1 : streamId, [
                .string("onStatus"), .number(0), .null,
                .object([("level", .string("status")), ("code", .string("NetStream.Publish.Start")),
                         ("description", .string("Start publishing"))]),
            ])
            emit(.publishing(streamName))
        case "FCUnpublish", "deleteStream", "closeStream":
            emit(.log("rtmp: camera ended the stream (\(name))"))
        default:
            break
        }
    }

    // MARK: 映像・音声(FLV のタグの中身)

    private func handleVideo(_ p: [UInt8], timestamp: Int64) {
        guard let b = p.first else { return }
        if b & 0x80 != 0 {
            // Enhanced RTMP: [IsExHeader|FrameType(3)|PacketType(4)][FourCC(4)] …
            guard p.count >= 5 else { return }
            let frameType = (b >> 4) & 0x07
            let packetType = b & 0x0F
            let fourcc = String(decoding: p[1..<5], as: UTF8.self)
            let codec: OsmoVideoCodec
            switch fourcc {
            case "hvc1": codec = .hevc
            case "avc1": codec = .avc
            default:
                if !warnedVideo { warnedVideo = true; emit(.log("rtmp: unsupported video \(fourcc)")) }
                return
            }
            switch packetType {
            case 0: videoConfig(codec, Array(p[5...]))
            case 1:
                guard p.count >= 8 else { return }
                let cts = Self.si24(p[5], p[6], p[7])
                emit(.videoFrame(data: Array(p[8...]), dts: timestamp, pts: timestamp + cts, keyframe: frameType == 1))
            case 3:
                emit(.videoFrame(data: Array(p[5...]), dts: timestamp, pts: timestamp, keyframe: frameType == 1))
            default:
                break
            }
            return
        }
        // 従来の FLV: [FrameType(4)|CodecID(4)][AVCPacketType][CompositionTime(SI24)] …
        let frameType = b >> 4
        let codecId = b & 0x0F
        guard codecId == 7 || codecId == 12 else {
            if !warnedVideo { warnedVideo = true; emit(.log("rtmp: unsupported video codec id \(codecId)")) }
            return
        }
        guard p.count >= 5 else { return }
        let codec: OsmoVideoCodec = codecId == 7 ? .avc : .hevc
        let cts = Self.si24(p[2], p[3], p[4])
        switch p[1] {
        case 0: videoConfig(codec, Array(p[5...]))
        case 1: emit(.videoFrame(data: Array(p[5...]), dts: timestamp, pts: timestamp + cts, keyframe: frameType == 1))
        default: break
        }
    }

    private func videoConfig(_ codec: OsmoVideoCodec, _ record: [UInt8]) {
        guard let parsed = codec == .avc ? Self.parseAVCC(record) : Self.parseHVCC(record) else {
            emit(.log("rtmp: could not read the \(codec.rawValue) config record (\(record.count) B)"))
            return
        }
        emit(.videoConfig(codec: codec, parameterSets: parsed.sets, nalLengthSize: parsed.nalLengthSize))
    }

    private func handleAudio(_ p: [UInt8], timestamp: Int64) {
        guard p.count >= 2 else { return }
        let format = p[0] >> 4
        guard format == 10 else {
            if !warnedAudio { warnedAudio = true; emit(.log("rtmp: unsupported audio format \(format)")) }
            return
        }
        if p[1] == 0 {
            emit(.audioConfig(asc: Array(p[2...])))
        } else {
            emit(.audioFrame(data: Array(p[2...]), timestamp: timestamp))
        }
    }

    static func si24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int64 {
        var v = Int64(a) << 16 | Int64(b) << 8 | Int64(c)
        if v & 0x80_0000 != 0 { v -= 0x100_0000 }
        return v
    }

    /// AVCDecoderConfigurationRecord → SPS/PPS
    static func parseAVCC(_ r: [UInt8]) -> (sets: [[UInt8]], nalLengthSize: Int)? {
        guard r.count >= 7, r[0] == 1 else { return nil }
        let lengthSize = Int(r[4] & 0x03) + 1
        var i = 5
        var sets: [[UInt8]] = []
        let numSPS = Int(r[i] & 0x1F); i += 1
        for _ in 0..<numSPS {
            guard i + 2 <= r.count else { return nil }
            let n = Int(r[i]) << 8 | Int(r[i + 1]); i += 2
            guard i + n <= r.count else { return nil }
            sets.append(Array(r[i..<(i + n)])); i += n
        }
        guard i < r.count else { return nil }
        let numPPS = Int(r[i]); i += 1
        for _ in 0..<numPPS {
            guard i + 2 <= r.count else { return nil }
            let n = Int(r[i]) << 8 | Int(r[i + 1]); i += 2
            guard i + n <= r.count else { return nil }
            sets.append(Array(r[i..<(i + n)])); i += n
        }
        return sets.count >= 2 ? (sets, lengthSize) : nil
    }

    /// HEVCDecoderConfigurationRecord → VPS/SPS/PPS
    static func parseHVCC(_ r: [UInt8]) -> (sets: [[UInt8]], nalLengthSize: Int)? {
        guard r.count >= 23 else { return nil }
        let lengthSize = Int(r[21] & 0x03) + 1
        var i = 22
        let arrays = Int(r[i]); i += 1
        var sets: [[UInt8]] = []
        for _ in 0..<arrays {
            guard i + 3 <= r.count else { return nil }
            let type = Int(r[i] & 0x3F)
            let count = Int(r[i + 1]) << 8 | Int(r[i + 2]); i += 3
            for _ in 0..<count {
                guard i + 2 <= r.count else { return nil }
                let n = Int(r[i]) << 8 | Int(r[i + 1]); i += 2
                guard i + n <= r.count else { return nil }
                if (32...34).contains(type) { sets.append(Array(r[i..<(i + n)])) }
                i += n
            }
        }
        return sets.count >= 3 ? (sets, lengthSize) : nil
    }

    // MARK: 送る

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private func sendCommand(streamId: UInt32, _ values: [OsmoAMF]) {
        sendMessage(csid: streamId == 0 ? 3 : 5, type: 20, streamId: streamId,
                    payload: values.flatMap { $0.encoded })
    }

    /// 形式 0 の見出し + 本体。outChunkSize ごとに形式 3 の見出しで区切る
    private func sendMessage(csid: UInt8, type: UInt8, streamId: UInt32, payload: [UInt8]) {
        let len = payload.count
        var out: [UInt8] = [csid & 0x3F, 0, 0, 0,
                            UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF), type,
                            UInt8(streamId & 0xFF), UInt8((streamId >> 8) & 0xFF),
                            UInt8((streamId >> 16) & 0xFF), UInt8(streamId >> 24)]
        var i = 0
        while i < len {
            if i > 0 { out.append(0xC0 | (csid & 0x3F)) }
            let n = min(outChunkSize, len - i)
            out.append(contentsOf: payload[i..<(i + n)])
            i += n
        }
        send(out)
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .idempotent)
    }
}

/// AMF0 の値(命令に要る分だけ)
enum OsmoAMF: CustomStringConvertible {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object([(String, OsmoAMF)])
    case null
    case undefined
    case array([OsmoAMF])

    var encoded: [UInt8] {
        switch self {
        case .number(let d):
            let bits = d.bitPattern
            return [0x00] + (0..<8).map { UInt8((bits >> (56 - 8 * UInt64($0))) & 0xFF) }
        case .bool(let b): return [0x01, b ? 1 : 0]
        case .string(let s): return [0x02] + Self.shortString(s)
        case .object(let pairs):
            var out: [UInt8] = [0x03]
            for (k, v) in pairs { out += Self.shortString(k) + v.encoded }
            return out + [0, 0, 0x09]
        case .null: return [0x05]
        case .undefined: return [0x06]
        case .array(let items):
            let n = UInt32(items.count)
            return [0x0A, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
                + items.flatMap { $0.encoded }
        }
    }

    private static func shortString(_ s: String) -> [UInt8] {
        let b = Array(s.utf8.prefix(0xFFFF))
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }

    var description: String {
        switch self {
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): return String(b)
        case .string(let s): return s
        case .object(let pairs): return "{" + pairs.map { "\($0.0)=\($0.1.description)" }.joined(separator: ", ") + "}"
        case .null: return "null"
        case .undefined: return "undefined"
        case .array(let items): return "[" + items.map(\.description).joined(separator: ", ") + "]"
        }
    }

    /// 並んだ値をすべて読む(読めない型が来たらそこで止める)
    static func decode(_ bytes: [UInt8]) -> [OsmoAMF] {
        var i = 0
        var out: [OsmoAMF] = []
        while i < bytes.count, let v = readValue(bytes, &i) { out.append(v) }
        return out
    }

    private static func readValue(_ b: [UInt8], _ i: inout Int) -> OsmoAMF? {
        guard i < b.count else { return nil }
        let marker = b[i]; i += 1
        switch marker {
        case 0x00:
            guard i + 8 <= b.count else { return nil }
            var bits: UInt64 = 0
            for k in 0..<8 { bits = bits << 8 | UInt64(b[i + k]) }
            i += 8
            return .number(Double(bitPattern: bits))
        case 0x01:
            guard i < b.count else { return nil }
            defer { i += 1 }
            return .bool(b[i] != 0)
        case 0x02:
            return readShortString(b, &i).map { .string($0) }
        case 0x0C:
            guard i + 4 <= b.count else { return nil }
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]); i += 4
            guard n >= 0, i + n <= b.count else { return nil }
            defer { i += n }
            return .string(String(decoding: b[i..<(i + n)], as: UTF8.self))
        case 0x03:
            return readProperties(b, &i).map { .object($0) }
        case 0x08:
            guard i + 4 <= b.count else { return nil }
            i += 4  // 数は当てにならないので終わりの印まで読む
            return readProperties(b, &i).map { .object($0) }
        case 0x0A:
            guard i + 4 <= b.count else { return nil }
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]); i += 4
            var items: [OsmoAMF] = []
            for _ in 0..<max(0, min(n, 10_000)) {
                guard let v = readValue(b, &i) else { return nil }
                items.append(v)
            }
            return .array(items)
        case 0x05: return .null
        case 0x06: return .undefined
        case 0x0B:  // 日付: 8 + 2 バイト
            guard i + 10 <= b.count else { return nil }
            i += 10
            return .undefined
        default:
            return nil
        }
    }

    private static func readShortString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i + 2 <= b.count else { return nil }
        let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
        guard i + n <= b.count else { return nil }
        defer { i += n }
        return String(decoding: b[i..<(i + n)], as: UTF8.self)
    }

    private static func readProperties(_ b: [UInt8], _ i: inout Int) -> [(String, OsmoAMF)]? {
        var pairs: [(String, OsmoAMF)] = []
        while true {
            guard let key = readShortString(b, &i) else { return nil }
            if key.isEmpty, i < b.count, b[i] == 0x09 { i += 1; return pairs }
            guard let v = readValue(b, &i) else { return nil }
            pairs.append((key, v))
        }
    }
}
#endif
