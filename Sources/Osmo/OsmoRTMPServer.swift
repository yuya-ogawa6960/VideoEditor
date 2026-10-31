// =====================================================================
// iPhone の中の小さな RTMP サーバー(実験中・開発者向け)
//
// Osmo Pocket が RTMP で送ってくる映像(H.264 / HEVC)と音(AAC)を TCP 1935 で受ける。
// カメラは iPhone のインターネット共有(ホットスポット)に入り、rtmp://172.20.10.1:1935/live/videomania へ送る
// (Bluetooth で頼む: OsmoRTMPLink.swift、または DJI Mimo の「ライブ配信」→「RTMP」に URL を入れる)。
//
// 作り:
// - Network.framework の NWListener で 1935 を待つ。配信してくる相手は 1 台だけ(新しい相手が配信を始めたら古いほうを切る)
// - ハンドシェイク C0/C1/C2 ↔ S0/S1/S2。C1 に Flash 方式のダイジェストがあれば同じ方式(HMAC-SHA256)で S1/S2 を作る。
//   無ければ単純な方式(S2 = C1 のこだま)
// - チャンクの組み立て: fmt 0〜3、1〜3 バイトのチャンク ID、拡張タイムスタンプ(続きの塊で省く送り手にも合わせる)、
//   Set Chunk Size・Abort・Window Ack Size・Acknowledgement・Ping、集約メッセージ(type 22)
// - AMF0 の命令: connect → _result、releaseStream / FCPublish、createStream → _result、
//   publish → onStatus NetStream.Publish.Start、FCUnpublish / deleteStream
// - @setDataFrame onMetaData(幅・高さ・fps・ビットレート)
// - 映像: 旧来の FLV(コーデック ID 7 = AVC、12 = HEVC の非公式な拡張)と Enhanced RTMP(hvc1 / avc1 の FourCC)。
//   設定(AVCDecoderConfigurationRecord / HEVCDecoderConfigurationRecord)からパラメーターセットと NAL の長さの幅を読む
// - 音: AAC(AudioSpecificConfig と生のフレーム。ADTS の頭が付いていても受ける)、Enhanced RTMP の mp4a
//
// チャンクと AMF0 の読み方・Pocket 4 Pro の受け方は OpenPocketCine
// (https://github.com/erik-sutton95/OpenPocketCine、commit d2851068d2176fb9ef7d498a05453e2397c4fe83 の
//  Sources/OpenPocketViewCore/RTMPIngest.swift と ios/OpenPocketCine/MultiviewRTMPServer.swift)を参考に、この app 用に書き直したもの。
// Copyright 2026 Erik Sutton and OpenPocketCine contributors. Apache License 2.0
// (docs/licenses/OpenCine-LICENSE.txt と同じ本文、docs/licenses/OpenPocketCine-NOTICE.txt)。
// 変更点: 拡張タイムスタンプの続きの塊・Abort・集約メッセージ・AMF0 の型を増やした・Flash 方式のハンドシェイク・
//         音・メタデータ・Annex-B で届く設定やフレームにも合わせた。大きなメッセージでも配列を何度も写さない組み立てにした。
// ハンドシェイクの鍵の文字列と 32 バイトは、RTMP の公開された実装(nginx-rtmp-module、FFmpeg、librtmp など)で広く使われている値。
//
// 実機ではまだ一度も試していない。docs/OsmoPocket.md の「RTMP で受ける」を参照。
// =====================================================================

#if OSMO_LIVE
import CryptoKit
import Darwin
import Foundation
import Network

// MARK: - AMF0

/// AMF0 の値(RTMP の命令とメタデータ)
indirect enum OsmoAMF: Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object([String: OsmoAMF])
    case array([OsmoAMF])
    case date(Double)
    case null
    case undefined

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var number: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var object: [String: OsmoAMF]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// ログ用の短い文
    var summary: String {
        switch self {
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s
        case .object(let o): return "{" + o.keys.sorted().map { "\($0): \(o[$0]!.summary)" }.joined(separator: ", ") + "}"
        case .array(let a): return "[" + a.map(\.summary).joined(separator: ", ") + "]"
        case .date(let d): return "date(\(d))"
        case .null: return "null"
        case .undefined: return "undefined"
        }
    }
}

enum OsmoAMF0 {
    enum Failure: Error {
        case truncated
        case unsupported(UInt8)
        case tooDeep
    }

    static func encode(_ values: [OsmoAMF]) -> [UInt8] {
        var out: [UInt8] = []
        for value in values { write(value, into: &out) }
        return out
    }

    private static func write(_ value: OsmoAMF, into out: inout [UInt8]) {
        switch value {
        case .number(let n):
            out.append(0x00)
            out += be64(n.bitPattern)
        case .bool(let b):
            out.append(0x01)
            out.append(b ? 1 : 0)
        case .string(let s):
            let bytes = Array(s.utf8)
            if bytes.count > 0xFFFF {
                out.append(0x0C)
                out += OsmoRTMPBytes.be32(UInt32(bytes.count))
            } else {
                out.append(0x02)
                out += [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
            }
            out += bytes
        case .object(let object):
            out.append(0x03)
            for key in object.keys.sorted() {
                let k = Array(key.utf8.prefix(0xFFFF))
                out += [UInt8(k.count >> 8), UInt8(k.count & 0xFF)]
                out += k
                write(object[key]!, into: &out)
            }
            out += [0x00, 0x00, 0x09]
        case .array(let array):
            out.append(0x0A)
            out += OsmoRTMPBytes.be32(UInt32(array.count))
            for item in array { write(item, into: &out) }
        case .date(let d):
            out.append(0x0B)
            out += be64(d.bitPattern)
            out += [0x00, 0x00]
        case .null:
            out.append(0x05)
        case .undefined:
            out.append(0x06)
        }
    }

    private static func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: v >> (UInt64(7 - $0) * 8)) }
    }

    /// 読めたところまでの値を返す(途中で壊れていても、それまでの値は使う)
    static func decode(_ data: [UInt8]) -> [OsmoAMF] {
        var reader = Reader(data)
        var out: [OsmoAMF] = []
        while reader.remaining > 0 {
            guard let value = try? readValue(&reader, depth: 0) else { break }
            out.append(value)
        }
        return out
    }

    private struct Reader {
        let d: [UInt8]
        var i = 0

        init(_ d: [UInt8]) { self.d = d }

        var remaining: Int { d.count - i }

        func peek(_ offset: Int = 0) -> UInt8? {
            i + offset < d.count ? d[i + offset] : nil
        }

        mutating func u8() throws -> UInt8 {
            guard i < d.count else { throw Failure.truncated }
            defer { i += 1 }
            return d[i]
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, i + n <= d.count else { throw Failure.truncated }
            defer { i += n }
            return Array(d[i..<(i + n)])
        }

        mutating func u16() throws -> Int {
            let b = try bytes(2)
            return Int(b[0]) << 8 | Int(b[1])
        }

        mutating func u32() throws -> Int {
            let b = try bytes(4)
            return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        }

        mutating func double() throws -> Double {
            let b = try bytes(8)
            return Double(bitPattern: b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }

        mutating func shortString() throws -> String {
            let n = try u16()
            return String(decoding: try bytes(n), as: UTF8.self)
        }

        mutating func longString() throws -> String {
            let n = try u32()
            return String(decoding: try bytes(n), as: UTF8.self)
        }
    }

    private static func readValue(_ r: inout Reader, depth: Int) throws -> OsmoAMF {
        guard depth < 16 else { throw Failure.tooDeep }
        let marker = try r.u8()
        switch marker {
        case 0x00: return .number(try r.double())
        case 0x01: return .bool(try r.u8() != 0)
        case 0x02: return .string(try r.shortString())
        case 0x03: return .object(try properties(&r, depth: depth))
        case 0x05, 0x0D: return .null
        case 0x06: return .undefined
        case 0x07:
            _ = try r.u16()  // 参照(使わない)
            return .null
        case 0x08:
            _ = try r.u32()  // ECMA 配列の数(当てにしない)
            return .object(try properties(&r, depth: depth))
        case 0x0A:
            let n = try r.u32()
            guard n <= 4096 else { throw Failure.tooDeep }
            var array: [OsmoAMF] = []
            for _ in 0..<n { array.append(try readValue(&r, depth: depth + 1)) }
            return .array(array)
        case 0x0B:
            let d = try r.double()
            _ = try r.bytes(2)
            return .date(d)
        case 0x0C, 0x0F: return .string(try r.longString())
        case 0x10:
            _ = try r.shortString()  // 型の名前
            return .object(try properties(&r, depth: depth))
        default:
            throw Failure.unsupported(marker)
        }
    }

    /// 名前と値の並び。空の名前 + 0x09 で終わる(ECMA 配列で終わりの印が無い送り手はデータの終わりまで)
    private static func properties(_ r: inout Reader, depth: Int) throws -> [String: OsmoAMF] {
        var object: [String: OsmoAMF] = [:]
        while r.remaining > 0 {
            if r.remaining >= 3, r.peek(0) == 0, r.peek(1) == 0, r.peek(2) == 0x09 {
                r.i += 3
                break
            }
            let key = try r.shortString()
            if key.isEmpty, r.peek() == 0x09 {
                r.i += 1
                break
            }
            guard object.count < 256 else { throw Failure.tooDeep }
            object[key] = try readValue(&r, depth: depth + 1)
        }
        return object
    }
}

// MARK: - バイト列

enum OsmoRTMPBytes {
    static func be24(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
    }

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// 符号付き 24 ビット(FLV の composition time)
    static func si24(_ b: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: be24(b, i) << 8) >> 8
    }

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    static func hex(_ bytes: [UInt8], limit: Int = 16) -> String {
        if bytes.isEmpty { return "-" }
        let head = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? head + "…" : head
    }
}

// MARK: - チャンク

struct OsmoRTMPMessage {
    var type: UInt8
    var streamId: UInt32
    var timestamp: UInt32
    var payload: [UInt8]
}

/// RTMP のチャンクをメッセージに組み立てる
struct OsmoRTMPChunkParser {
    enum Failure: Error {
        case tooLarge(Int)
        case tooManyStreams
        case malformed(String)
    }

    /// チャンク ID ごとの前回のヘッダー(fmt 1〜3 は前回の値を使う)
    private struct State {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var type: UInt8 = 0
        var streamId: UInt32 = 0
        var extended = false
        var extendedValue: UInt32 = 0
        var inProgress = false
    }

    private enum Step {
        case message(OsmoRTMPMessage)
        case consumed
        case needMore
    }

    /// 1 つのメッセージの上限(1080p のキーフレームは多くて数百 KB)
    static let maxMessageBytes = 16 * 1024 * 1024
    private var states: [Int: State] = [:]
    /// 組み立て中の中身。State とは別に持つ(大きなメッセージで配列を写さないため)
    private var payloads: [Int: [UInt8]] = [:]
    private var buffer: [UInt8] = []
    private var index = 0
    private(set) var chunkSize = 128
    /// 途中のメッセージに新しいヘッダーが来て捨てた数(診断用)
    private(set) var droppedPartials = 0

    mutating func push(_ bytes: [UInt8]) throws -> [OsmoRTMPMessage] {
        if index >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            index = 0
        } else if index > 262_144 {
            buffer.removeFirst(index)
            index = 0
        }
        buffer.append(contentsOf: bytes)
        var out: [OsmoRTMPMessage] = []
        loop: while true {
            switch try next() {
            case .needMore:
                break loop
            case .consumed:
                continue
            case .message(let message):
                // Set Chunk Size と Abort はすぐ効かせる(同じ受信の残りに関わる)
                if message.type == 1, message.payload.count >= 4 {
                    let n = Int(OsmoRTMPBytes.be32(message.payload, 0) & 0x7FFF_FFFF)
                    chunkSize = min(max(n, 1), 0xFF_FFFF)
                } else if message.type == 2, message.payload.count >= 4 {
                    let id = Int(OsmoRTMPBytes.be32(message.payload, 0))
                    payloads[id] = nil
                    states[id]?.inProgress = false
                }
                out.append(message)
            }
        }
        return out
    }

    private mutating func next() throws -> Step {
        let n = buffer.count
        var c = index
        guard c < n else { return .needMore }
        let first = buffer[c]
        c += 1
        let fmt = Int(first >> 6)
        var csid = Int(first & 0x3F)
        if csid == 0 {
            guard c + 1 <= n else { return .needMore }
            csid = 64 + Int(buffer[c])
            c += 1
        } else if csid == 1 {
            guard c + 2 <= n else { return .needMore }
            csid = 64 + Int(buffer[c]) + Int(buffer[c + 1]) * 256
            c += 2
        }
        let headerLength = [11, 7, 3, 0][fmt]
        guard c + headerLength <= n else { return .needMore }
        let known = states[csid] != nil
        if !known {
            guard states.count < 256 else { throw Failure.tooManyStreams }
            // 長さの分からない fmt 2・3 から始まるのは壊れている
            guard fmt <= 1 else { throw Failure.malformed("chunk stream \(csid) starts with fmt \(fmt)") }
        }
        var st = states[csid] ?? State()
        let continuing = st.inProgress && fmt == 3
        var stamp: UInt32 = 0
        var length = st.length
        var type = st.type
        var streamId = st.streamId
        if fmt <= 2 { stamp = OsmoRTMPBytes.be24(buffer, c) }
        if fmt <= 1 {
            length = Int(OsmoRTMPBytes.be24(buffer, c + 3))
            type = buffer[c + 6]
        }
        if fmt == 0 { streamId = OsmoRTMPBytes.le32(buffer, c + 7) }
        c += headerLength
        var extended = st.extended
        if fmt <= 2 { extended = stamp == 0xFF_FFFF }
        var extendedValue = st.extendedValue
        if extended {
            guard c + 4 <= n else { return .needMore }
            let value = OsmoRTMPBytes.be32(buffer, c)
            if continuing {
                // 続きの塊で拡張タイムスタンプを繰り返す送り手と、繰り返さない送り手がある。同じ値なら読み飛ばす
                if value == st.extendedValue { c += 4 }
            } else {
                extendedValue = value
                c += 4
            }
        }
        guard length <= Self.maxMessageBytes else { throw Failure.tooLarge(length) }
        let have = continuing ? (payloads[csid]?.count ?? 0) : 0
        let take = min(chunkSize, max(0, length - have))
        guard c + take <= n else { return .needMore }

        // ここから確定(足りないときは上で戻っているので、状態はまだ変えていない)
        if !continuing {
            if st.inProgress { droppedPartials += 1 }
            switch fmt {
            case 0:
                st.timestamp = extended ? extendedValue : stamp
                // 仕様: fmt 0 のあとの fmt 3 は、fmt 0 の時刻を差分として使う
                st.delta = st.timestamp
            case 1, 2:
                st.delta = extended ? extendedValue : stamp
                st.timestamp &+= st.delta
            default:
                st.timestamp &+= st.delta
            }
            st.length = length
            st.type = type
            st.streamId = streamId
            st.extended = extended
            st.extendedValue = extendedValue
            st.inProgress = true
            var fresh: [UInt8] = []
            fresh.reserveCapacity(min(length, 1 << 20))
            payloads[csid] = fresh
        }
        if take > 0 {
            payloads[csid, default: []].append(contentsOf: buffer[c..<(c + take)])
        }
        c += take
        index = c
        if have + take >= length {
            st.inProgress = false
            states[csid] = st
            let payload = payloads.removeValue(forKey: csid) ?? []
            return .message(OsmoRTMPMessage(type: st.type, streamId: st.streamId, timestamp: st.timestamp,
                                            payload: payload))
        }
        states[csid] = st
        return .consumed
    }

    /// 送るメッセージを 1 つのチャンク列にする(時刻はいつも 0)
    static func encode(type: UInt8, streamId: UInt32, csid: UInt8, payload: [UInt8], chunkSize: Int) -> [UInt8] {
        let n = payload.count
        var out: [UInt8] = [csid & 0x3F, 0, 0, 0,
                            UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), type,
                            UInt8(streamId & 0xFF), UInt8((streamId >> 8) & 0xFF),
                            UInt8((streamId >> 16) & 0xFF), UInt8((streamId >> 24) & 0xFF)]
        var i = 0
        while i < n {
            if i > 0 { out.append(0xC0 | (csid & 0x3F)) }
            let end = min(i + max(chunkSize, 1), n)
            out += payload[i..<end]
            i = end
        }
        return out
    }
}

// MARK: - ハンドシェイク

enum OsmoRTMPHandshake {
    /// Flash 方式のダイジェストの鍵(RTMP の公開された実装で共通の値)
    private static let keyTail: [UInt8] = [
        0xF0, 0xEE, 0xC2, 0x4A, 0x80, 0x68, 0xBE, 0xE8, 0x2E, 0x00, 0xD0, 0xD1, 0x02, 0x9E, 0x7E, 0x57,
        0x6E, 0xEC, 0x5D, 0x2D, 0x29, 0x80, 0x6F, 0xAB, 0x93, 0xB8, 0xE6, 0x36, 0xCF, 0xEB, 0x31, 0xAE,
    ]
    private static let playerKey: [UInt8] = Array("Genuine Adobe Flash Player 001".utf8) + keyTail
    private static let serverKey: [UInt8] = Array("Genuine Adobe Flash Media Server 001".utf8) + keyTail

    private static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// ダイジェストの位置。方式 0 は 8〜11 バイト目、方式 1 は 772〜775 バイト目の和から決まる
    private static func digestOffset(_ b: [UInt8], scheme: Int) -> Int {
        let base = scheme == 0 ? 8 : 772
        let sum = Int(b[base]) + Int(b[base + 1]) + Int(b[base + 2]) + Int(b[base + 3])
        return sum % 728 + base + 4
    }

    private static func withoutDigest(_ b: [UInt8], at offset: Int) -> [UInt8] {
        Array(b[0..<offset]) + Array(b[(offset + 32)...])
    }

    /// C1 の中のクライアントのダイジェスト。見つからなければ nil(単純なハンドシェイク)
    private static func clientDigest(_ c1: [UInt8]) -> (scheme: Int, digest: [UInt8])? {
        guard c1.count == 1536, c1[4..<8] != [0, 0, 0, 0] else { return nil }
        let key = Array(playerKey.prefix(30))
        for scheme in [0, 1] {
            let offset = digestOffset(c1, scheme: scheme)
            let expected = hmac(key, withoutDigest(c1, at: offset))
            if Array(c1[offset..<(offset + 32)]) == expected { return (scheme, expected) }
        }
        return nil
    }

    struct Reply {
        var s1: [UInt8]
        var s2: [UInt8]
        var digest: Bool
    }

    static func serverReply(c1: [UInt8]) -> Reply {
        var s1 = (0..<1536).map { _ in UInt8.random(in: 0...255) }
        s1.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        if let client = clientDigest(c1) {
            // 送り手が Flash 方式なら、同じ方式で答える(答えないと切る送り手がある)
            s1.replaceSubrange(4..<8, with: [0x0D, 0x0E, 0x0A, 0x0D])
            let offset = digestOffset(s1, scheme: client.scheme)
            let digest = hmac(Array(serverKey.prefix(36)), withoutDigest(s1, at: offset))
            s1.replaceSubrange(offset..<(offset + 32), with: digest)
            var s2 = (0..<1536).map { _ in UInt8.random(in: 0...255) }
            let tempKey = hmac(serverKey, client.digest)
            let signature = hmac(tempKey, Array(s2[0..<1504]))
            s2.replaceSubrange(1504..<1536, with: signature)
            return Reply(s1: s1, s2: s2, digest: true)
        }
        s1.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        return Reply(s1: s1, s2: c1, digest: false)
    }
}

// MARK: - FLV の中身(映像・音)

struct OsmoRTMPVideoFrame: Sendable {
    var codec: OsmoVideoCodec
    /// FLV の frame type が「キーフレーム」
    var isKey: Bool
    /// 長さ・開始コードを外した NAL
    var nals: [[UInt8]]
    /// 復号の時刻(カメラが付けたミリ秒。32 ビットの一周を足したもの)
    var timestampMs: Int64
    /// 表示の時刻 − 復号の時刻(ミリ秒。B フレームのときだけ 0 以外)
    var compositionMs: Int32
}

enum OsmoRTMPEvent: Sendable {
    case publishStarted(app: String, key: String, from: String)
    case metadata([String: OsmoAMF])
    case videoConfig(codec: OsmoVideoCodec, parameterSets: [[UInt8]])
    case video(OsmoRTMPVideoFrame)
    /// AAC の AudioSpecificConfig
    case audioConfig([UInt8])
    /// 生の AAC 1 フレーム
    case audio([UInt8], timestampMs: Int64)
    case unsupported(String)
    case publishEnded(String)
}

/// 映像・音のメッセージ(FLV のタグの中身)を読む
struct OsmoFLVDemuxer {
    private var nalLengthSize = 4
    private var lastRawTimestamp: UInt32?
    private var wraps: Int64 = 0
    private var warned: Set<String> = []
    private var audioConfigured = false

    /// 32 ビットのミリ秒の一周(約 49 日)をまたいでも増え続ける時刻にする
    private mutating func time(_ raw: UInt32) -> Int64 {
        if let last = lastRawTimestamp, raw < last, last - raw > 0x8000_0000 { wraps += 1 }
        lastRawTimestamp = raw
        return wraps * 0x1_0000_0000 + Int64(raw)
    }

    private mutating func warnOnce(_ what: String) -> [OsmoRTMPEvent] {
        guard warned.insert(what).inserted else { return [] }
        return [.unsupported(what)]
    }

    mutating func video(_ p: [UInt8], timestamp raw: UInt32) -> [OsmoRTMPEvent] {
        let t = time(raw)
        guard let b0 = p.first else { return [] }
        var codec = OsmoVideoCodec.avc
        var packetType = 0
        var cts: Int32 = 0
        var bodyStart = 0
        var isKey = false
        if b0 & 0x80 != 0 {
            // Enhanced RTMP: [1 IsExHeader][3 FrameType][4 PacketType][FourCC]
            let frameType = (b0 >> 4) & 0x07
            packetType = Int(b0 & 0x0F)
            guard frameType != 5, p.count >= 5 else { return [] }  // 5 = 命令だけのフレーム
            let fourCC = String(decoding: p[1..<5], as: UTF8.self)
            switch fourCC {
            case "hvc1", "hev1": codec = .hevc
            case "avc1", "avc3": codec = .avc
            default: return warnOnce("video \(fourCC)")
            }
            isKey = frameType == 1
            switch packetType {
            case 0:  // SequenceStart
                bodyStart = 5
            case 1:  // CodedFrames(composition time 付き)
                guard p.count >= 8 else { return [] }
                cts = OsmoRTMPBytes.si24(p, 5)
                bodyStart = 8
            case 3:  // CodedFramesX(composition time なし)
                bodyStart = 5
                packetType = 1
            case 2:  // SequenceEnd
                return []
            default:
                return warnOnce("enhanced video packet type \(packetType)")
            }
        } else {
            // 旧来: [4 FrameType][4 CodecID][AVCPacketType][CompositionTime SI24]
            let frameType = b0 >> 4
            let codecId = b0 & 0x0F
            guard frameType != 5 else { return [] }
            switch codecId {
            case 7: codec = .avc
            case 12: codec = .hevc  // FLV の HEVC(非公式だが広く使われている)
            default: return warnOnce("video codec id \(codecId)")
            }
            guard p.count >= 5 else { return [] }
            packetType = Int(p[1])
            cts = OsmoRTMPBytes.si24(p, 2)
            bodyStart = 5
            isKey = frameType == 1
        }
        let body = Array(p[bodyStart...])
        if packetType == 0 {
            guard let config = Self.parseConfig(body, codec: codec), !config.parameterSets.isEmpty else {
                return warnOnce("unreadable \(codec.rawValue) decoder configuration")
            }
            nalLengthSize = config.nalLengthSize
            return [.videoConfig(codec: codec, parameterSets: config.parameterSets)]
        }
        guard packetType == 1 else { return [] }
        let nals = splitNALs(body)
        guard !nals.isEmpty else { return warnOnce("unreadable \(codec.rawValue) frame") }
        return [.video(OsmoRTMPVideoFrame(codec: codec, isKey: isKey, nals: nals, timestampMs: t, compositionMs: cts))]
    }

    struct Config {
        var parameterSets: [[UInt8]]
        var nalLengthSize: Int
    }

    /// AVCDecoderConfigurationRecord / HEVCDecoderConfigurationRecord(Annex-B で送る送り手にも合わせる)
    static func parseConfig(_ d: [UInt8], codec: OsmoVideoCodec) -> Config? {
        if d.starts(with: [0, 0, 0, 1]) || d.starts(with: [0, 0, 1]) {
            let sets = OsmoNAL.nalUnits(d).filter { OsmoNAL.isParameterSet($0, codec: codec) }
            return Config(parameterSets: sets, nalLengthSize: 4)
        }
        guard d.first == 1 else { return nil }
        var sets: [[UInt8]] = []
        var i = 0
        func readNAL() -> [UInt8]? {
            guard i + 2 <= d.count else { return nil }
            let n = Int(d[i]) << 8 | Int(d[i + 1])
            i += 2
            guard n > 0, i + n <= d.count else { return nil }
            defer { i += n }
            return Array(d[i..<(i + n)])
        }
        switch codec {
        case .avc:
            guard d.count >= 7 else { return nil }
            let lengthSize = Int(d[4] & 0x03) + 1
            let spsCount = Int(d[5] & 0x1F)
            i = 6
            for _ in 0..<spsCount {
                guard let nal = readNAL() else { return nil }
                sets.append(nal)
            }
            guard i < d.count else { return nil }
            let ppsCount = Int(d[i])
            i += 1
            for _ in 0..<ppsCount {
                guard let nal = readNAL() else { return nil }
                sets.append(nal)
            }
            return Config(parameterSets: sets.filter { OsmoNAL.isParameterSet($0, codec: .avc) },
                          nalLengthSize: lengthSize)
        case .hevc:
            guard d.count >= 23 else { return nil }
            let lengthSize = Int(d[21] & 0x03) + 1
            let arrays = Int(d[22])
            i = 23
            for _ in 0..<arrays {
                guard i + 3 <= d.count else { return nil }
                let count = Int(d[i + 1]) << 8 | Int(d[i + 2])
                i += 3
                for _ in 0..<count {
                    guard let nal = readNAL() else { return nil }
                    sets.append(nal)
                }
            }
            // SEI などは除き、VPS/SPS/PPS だけ
            return Config(parameterSets: sets.filter { OsmoNAL.isParameterSet($0, codec: .hevc) },
                          nalLengthSize: lengthSize)
        }
    }

    /// 長さ付きの NAL を分ける。読めなければ Annex-B として読む
    private func splitNALs(_ d: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        let size = nalLengthSize
        var ok = true
        while i < d.count {
            guard i + size <= d.count else { ok = false; break }
            var n = 0
            for k in 0..<size { n = n << 8 | Int(d[i + k]) }
            i += size
            if n == 0 { continue }
            guard i + n <= d.count else { ok = false; break }
            out.append(Array(d[i..<(i + n)]))
            i += n
        }
        if ok { return out }
        if d.starts(with: [0, 0, 0, 1]) || d.starts(with: [0, 0, 1]) { return OsmoNAL.nalUnits(d) }
        return []
    }

    mutating func audio(_ p: [UInt8], timestamp raw: UInt32) -> [OsmoRTMPEvent] {
        let t = time(raw)
        guard let b0 = p.first else { return [] }
        let format = b0 >> 4
        var isConfig = false
        var bodyStart = 0
        if format == 10 {
            // AAC: [SoundFormat 4|rate 2|size 1|type 1][AACPacketType]
            guard p.count >= 2 else { return [] }
            isConfig = p[1] == 0
            bodyStart = 2
        } else if format == 9 {
            // Enhanced RTMP の音: [9][AudioPacketType 4][FourCC]
            guard p.count >= 5 else { return [] }
            let fourCC = String(decoding: p[1..<5], as: UTF8.self)
            guard fourCC == "mp4a" else { return warnOnce("audio \(fourCC)") }
            let packetType = b0 & 0x0F
            guard packetType <= 1 else { return [] }
            isConfig = packetType == 0
            bodyStart = 5
        } else {
            return warnOnce("audio format \(format)")
        }
        if isConfig {
            guard p.count >= bodyStart + 2 else { return [] }
            audioConfigured = true
            return [.audioConfig(Array(p[bodyStart...]))]
        }
        var frame = Array(p[bodyStart...])
        var events: [OsmoRTMPEvent] = []
        // ADTS の頭が付いていたら外す(AudioSpecificConfig が届いていなければ ADTS から作る)
        if frame.count >= 7, frame[0] == 0xFF, frame[1] & 0xF0 == 0xF0 {
            let header = (frame[1] & 0x01) == 1 ? 7 : 9
            if !audioConfigured {
                let objectType = ((frame[2] >> 6) & 0x03) + 1
                let rate = (frame[2] >> 2) & 0x0F
                let channels = ((frame[2] & 0x01) << 2) | (frame[3] >> 6)
                events.append(.audioConfig([(objectType << 3) | (rate >> 1), ((rate & 0x01) << 7) | (channels << 3)]))
                audioConfigured = true
            }
            guard frame.count > header else { return events }
            frame = Array(frame[header...])
        }
        guard audioConfigured, !frame.isEmpty else { return events }
        events.append(.audio(frame, timestampMs: t))
        return events
    }
}

// MARK: - 1 本の TCP 接続

private final class OsmoRTMPPeer {
    let connection: NWConnection
    let address: String
    let openedAt = Date()
    private(set) var lastDataAt = Date()
    private(set) var isPublishing = false
    var onEvent: ((OsmoRTMPPeer, OsmoRTMPEvent) -> Void)?
    var onClose: ((OsmoRTMPPeer, String) -> Void)?
    var onLog: ((String) -> Void)?

    private let q: DispatchQueue
    /// 0: C0+C1 待ち、1: C2 待ち、2: チャンク
    private var stage = 0
    private var handshake: [UInt8] = []
    private var parser = OsmoRTMPChunkParser()
    private var demuxer = OsmoFLVDemuxer()
    private var received: UInt32 = 0
    private var lastAck: UInt32 = 0
    private var peerWindow: UInt32 = 2_500_000
    private var outChunkSize = 128
    private var nextStreamId: UInt32 = 0
    private var app = ""
    private var key = ""
    private var closed = false
    private var loggedTypes: Set<UInt8> = []

    init(connection: NWConnection, address: String, queue: DispatchQueue) {
        self.connection = connection
        self.address = address
        self.q = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.close("TCP failed \(error.localizedDescription)")
            case .waiting(let error): self?.onLog?("rtmp: peer waiting \(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: q)
        receive()
    }

    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(self, reason)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastDataAt = Date()
                do {
                    try self.consume([UInt8](data))
                } catch {
                    self.close("protocol error \(error)")
                    return
                }
            }
            if isComplete {
                self.close("peer closed the connection")
            } else if let error {
                self.close("receive error \(error.localizedDescription)")
            } else {
                self.receive()
            }
        }
    }

    // MARK: 受ける

    private func consume(_ bytes: [UInt8]) throws {
        received &+= UInt32(truncatingIfNeeded: bytes.count)
        var rest = bytes
        if stage < 2 {
            handshake += rest
            rest = []
            if stage == 0 {
                guard handshake.count >= 1537 else { return }
                if handshake[0] != 3 { onLog?("rtmp: C0 version \(handshake[0]) (answering as 3)") }
                let reply = OsmoRTMPHandshake.serverReply(c1: Array(handshake[1..<1537]))
                send([3] + reply.s1 + reply.s2)
                onLog?("rtmp: handshake \(reply.digest ? "with digest" : "simple") from \(address)")
                handshake.removeFirst(1537)
                stage = 1
            }
            guard handshake.count >= 1536 else { return }
            rest = Array(handshake[1536...])
            handshake = []
            stage = 2
        }
        if !rest.isEmpty {
            for message in try parser.push(rest) { handle(message) }
        }
        // 相手の窓の半分ごとに受け取った量を返す(返さないと送るのを止める送り手がある)
        if received &- lastAck >= max(peerWindow / 2, 65_536) {
            sendMessage(type: 3, payload: OsmoRTMPBytes.be32(received))
            lastAck = received
        }
    }

    private func handle(_ m: OsmoRTMPMessage) {
        switch m.type {
        case 1, 2, 3:
            break  // Set Chunk Size と Abort は組み立てで済ませた。3 は相手からの受領
        case 4:
            // User Control。Ping(6)には Pong(7)
            if m.payload.count >= 6, m.payload[0] == 0, m.payload[1] == 6 {
                sendMessage(type: 4, payload: [0, 7] + Array(m.payload[2..<6]))
            }
        case 5:
            if m.payload.count >= 4 { peerWindow = max(OsmoRTMPBytes.be32(m.payload, 0), 1) }
        case 6:
            break
        case 8:
            emit(demuxer.audio(m.payload, timestamp: m.timestamp))
        case 9:
            emit(demuxer.video(m.payload, timestamp: m.timestamp))
        case 15, 18:
            let payload = m.type == 15 && m.payload.first == 0 ? Array(m.payload.dropFirst()) : m.payload
            handleData(payload)
        case 17, 20:
            let payload = m.type == 17 && m.payload.first == 0 ? Array(m.payload.dropFirst()) : m.payload
            handleCommand(payload, streamId: m.streamId)
        case 22:
            handleAggregate(m)
        default:
            if loggedTypes.insert(m.type).inserted { onLog?("rtmp: ignoring message type \(m.type)") }
        }
    }

    private func emit(_ events: [OsmoRTMPEvent]) {
        for event in events { onEvent?(self, event) }
    }

    private func handleData(_ payload: [UInt8]) {
        let values = OsmoAMF0.decode(payload)
        let names = values.compactMap(\.string)
        guard names.contains("onMetaData") || names.contains("@setDataFrame") || names.isEmpty else { return }
        if let metadata = values.compactMap(\.object).first {
            onEvent?(self, .metadata(metadata))
        }
    }

    private func handleCommand(_ payload: [UInt8], streamId: UInt32) {
        let values = OsmoAMF0.decode(payload)
        guard let name = values.first?.string else { return }
        let tx = values.count > 1 ? (values[1].number ?? 0) : 0
        switch name {
        case "connect":
            let info = values.count > 2 ? (values[2].object ?? [:]) : [:]
            app = info["app"]?.string ?? ""
            let encoding = info["objectEncoding"]?.number ?? 0
            onLog?("rtmp: connect app=\(app) flashVer=\(info["flashVer"]?.string ?? "-") tcUrl=\(info["tcUrl"]?.string ?? "-")")
            sendMessage(type: 5, payload: OsmoRTMPBytes.be32(2_500_000))
            sendMessage(type: 6, payload: OsmoRTMPBytes.be32(2_500_000) + [2])
            sendMessage(type: 1, payload: OsmoRTMPBytes.be32(4096))
            outChunkSize = 4096
            sendCommand([
                .string("_result"), .number(tx),
                .object(["fmsVer": .string("FMS/3,5,7,7009"), "capabilities": .number(31), "mode": .number(1)]),
                .object([
                    "level": .string("status"), "code": .string("NetConnection.Connect.Success"),
                    "description": .string("Connection succeeded."), "objectEncoding": .number(encoding),
                ]),
            ])
        case "releaseStream", "FCPublish", "FCUnpublish", "_checkbw":
            sendCommand([.string("_result"), .number(tx), .null, .undefined])
            if name == "FCPublish" {
                let stream = values.count > 3 ? (values[3].string ?? "") : ""
                sendCommand([.string("onFCPublish"), .number(0), .null,
                             .object(["code": .string("NetStream.Publish.Start"), "description": .string(stream)])])
            }
        case "createStream":
            nextStreamId += 1
            sendCommand([.string("_result"), .number(tx), .null, .number(Double(nextStreamId))])
        case "publish":
            key = values.count > 3 ? (values[3].string ?? "") : ""
            let sid = streamId != 0 ? streamId : max(nextStreamId, 1)
            sendMessage(type: 4, payload: [0, 0] + OsmoRTMPBytes.be32(sid))  // Stream Begin
            sendCommand([
                .string("onStatus"), .number(0), .null,
                .object([
                    "level": .string("status"), "code": .string("NetStream.Publish.Start"),
                    "description": .string("Start publishing"), "details": .string(key),
                ]),
            ], streamId: sid, csid: 5)
            isPublishing = true
            demuxer = OsmoFLVDemuxer()
            onEvent?(self, .publishStarted(app: app, key: key, from: address))
        case "deleteStream", "closeStream":
            close("publisher sent \(name)")
        case "getStreamLength":
            sendCommand([.string("_result"), .number(tx), .null, .number(0)])
        case "play", "play2":
            close("playback is not supported")
        default:
            onLog?("rtmp: command \(name) (tx \(Int(tx)))")
            if tx > 0 { sendCommand([.string("_result"), .number(tx), .null, .null]) }
        }
    }

    /// 集約メッセージ: 中身は FLV のタグの並び `[type][size u24][ts u24][ts 上位 u8][stream u24][data][前のタグの長さ u32]`
    private func handleAggregate(_ m: OsmoRTMPMessage) {
        let d = m.payload
        var i = 0
        var firstStamp: UInt32?
        while i + 11 <= d.count {
            let type = d[i]
            let size = Int(OsmoRTMPBytes.be24(d, i + 1))
            let stamp = OsmoRTMPBytes.be24(d, i + 4) | UInt32(d[i + 7]) << 24
            i += 11
            guard i + size <= d.count else { break }
            let body = Array(d[i..<(i + size)])
            i += size + 4
            let base = firstStamp ?? stamp
            firstStamp = base
            guard type == 8 || type == 9 || type == 18 else { continue }
            handle(OsmoRTMPMessage(type: type, streamId: m.streamId, timestamp: m.timestamp &+ (stamp &- base), payload: body))
        }
    }

    // MARK: 送る

    private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.close("send error \(error.localizedDescription)") }
        })
    }

    /// 制御のメッセージ(チャンク ID 2、メッセージのストリーム 0)
    private func sendMessage(type: UInt8, payload: [UInt8]) {
        send(OsmoRTMPChunkParser.encode(type: type, streamId: 0, csid: 2, payload: payload, chunkSize: outChunkSize))
        // Set Chunk Size は送ったあとから効く(このメッセージ自体は前の大きさで送る)
    }

    private func sendCommand(_ values: [OsmoAMF], streamId: UInt32 = 0, csid: UInt8 = 3) {
        send(OsmoRTMPChunkParser.encode(type: 20, streamId: streamId, csid: csid, payload: OsmoAMF0.encode(values),
                                        chunkSize: outChunkSize))
    }
}

// MARK: - サーバー

final class OsmoRTMPServer: @unchecked Sendable {
    enum ListenerState: Equatable {
        case starting
        case ready
        case failed(String)
        case stopped
    }

    static let port: UInt16 = 1935
    static let appName = "live"
    static let streamKey = "videomania"
    /// iPhone のインターネット共有での iPhone 自身の住所(いつもこの値)
    static let defaultHotspotAddress = "172.20.10.1"

    /// サーバーのキューの上で呼ぶ
    var onEvent: (@Sendable (OsmoRTMPEvent) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onListenerState: (@Sendable (ListenerState) -> Void)?

    let q = DispatchQueue(label: "videomania.osmo.rtmp", qos: .userInitiated)
    // ---- 以下は q の上だけで触る ----
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: OsmoRTMPPeer] = [:]
    private var publisher: ObjectIdentifier?
    private var watchdog: DispatchSourceTimer?
    private var stopped = false

    func start() throws {
        try q.sync {
            stopped = false
            try startListenerOnQueue()
            startWatchdogOnQueue()
        }
    }

    /// アプリが前面に戻ったとき。待ち受けが止まっていたら開き直す
    func restartIfNeeded() {
        q.async { [self] in
            guard !stopped else { return }
            if let state = listener?.state {
                switch state {
                case .ready, .setup, .waiting:
                    return
                default:
                    break
                }
            }
            log("rtmp: restarting the listener")
            try? startListenerOnQueue()
        }
    }

    func stop() {
        q.sync {
            stopped = true
            watchdog?.cancel()
            watchdog = nil
            listener?.cancel()
            listener = nil
            for peer in Array(peers.values) { peer.close("receiver stopped") }
            peers.removeAll()
            publisher = nil
        }
    }

    private func log(_ s: String) {
        onLog?(s)
    }

    private func startListenerOnQueue() throws {
        listener?.cancel()
        listener = nil
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let next = try NWListener(using: parameters, on: port)
        next.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("rtmp: listening on TCP \(Self.port)")
                self.onListenerState?(.ready)
            case .failed(let error):
                self.log("rtmp: listener failed \(error.localizedDescription)")
                self.onListenerState?(.failed(error.localizedDescription))
            case .waiting(let error):
                self.log("rtmp: listener waiting \(error.localizedDescription) - ローカルネットワークの許可を確認")
            case .cancelled:
                self.onListenerState?(.stopped)
            default:
                break
            }
        }
        next.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = next
        onListenerState?(.starting)
        next.start(queue: q)
    }

    /// 5 秒ごと: 黙った接続と、配信を始めない接続を閉じる
    private func startWatchdogOnQueue() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for peer in Array(self.peers.values) {
                if now.timeIntervalSince(peer.lastDataAt) > 20 {
                    peer.close("no data for 20 s")
                } else if !peer.isPublishing, now.timeIntervalSince(peer.openedAt) > 30 {
                    peer.close("did not publish within 30 s")
                }
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func accept(_ connection: NWConnection) {
        let address: String
        if case .hostPort(let host, _) = connection.endpoint {
            address = "\(host)"
        } else {
            address = "\(connection.endpoint)"
        }
        guard peers.count < 4 else {
            log("rtmp: too many connections, refusing \(address)")
            connection.cancel()
            return
        }
        let peer = OsmoRTMPPeer(connection: connection, address: address, queue: q)
        peer.onLog = { [weak self] in self?.log($0) }
        peer.onEvent = { [weak self] peer, event in self?.peerEvent(peer, event) }
        peer.onClose = { [weak self] peer, reason in self?.peerClosed(peer, reason) }
        peers[ObjectIdentifier(peer)] = peer
        log("rtmp: connection from \(address)")
        peer.start()
    }

    private func peerEvent(_ peer: OsmoRTMPPeer, _ event: OsmoRTMPEvent) {
        let id = ObjectIdentifier(peer)
        if case .publishStarted = event {
            // カメラがつなぎ直したときは新しいほうを使う
            if let old = publisher, old != id, let oldPeer = peers[old] {
                oldPeer.close("replaced by a new publisher")
            }
            publisher = id
        }
        guard publisher == id else { return }
        onEvent?(event)
    }

    private func peerClosed(_ peer: OsmoRTMPPeer, _ reason: String) {
        let id = ObjectIdentifier(peer)
        peers.removeValue(forKey: id)
        log("rtmp: closed \(peer.address) (\(reason))")
        if publisher == id {
            publisher = nil
            onEvent?(.publishEnded(reason))
        }
    }

    /// インターネット共有の住所(bridge で始まるインターフェース)。カメラがまだ入っていないと無いことがある
    static func hotspotIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    /// カメラに渡す URL
    static func streamURL() -> String {
        "rtmp://\(hotspotIPv4() ?? defaultHotspotAddress):\(port)/\(appName)/\(streamKey)"
    }
}
#endif
