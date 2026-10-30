// =====================================================================
// DJI Osmo の DUML フレームと UDP データリンクのバイト列(実験中・開発者向け)
//
// OpenCine(https://github.com/erik-sutton95/OpenCine, commit dd77b69e)の
// Sources/OpenCineDJI/DumlFrame.swift・DumlTransport.swift・Commands.swift・
// DumlNotificationAssembler.swift から、ライブビューに要る部分だけを移植・簡略化したもの。
// Copyright 2026 Erik Sutton and OpenCine contributors. Apache License 2.0
// (docs/licenses/OpenCine-LICENSE.txt と docs/licenses/OpenCine-NOTICE.txt)。
// 変更点: 型名を Osmo* に変更、Pocket のライブビューに要らない命令(ジンバル・メディア・撮影設定など)を削除。
//
// DJI の公式 SDK や資料は使っていない(リバースエンジニアリングされた公開情報のみ)。
// 実機ではまだ一度も試していない。docs/OsmoPocket.md を参照。
// =====================================================================

#if OSMO_LIVE
import Foundation

/// DUML フレーム(BLE と UDP の両方で使う)。
/// `55 | len | ver/len-hi | crc8 | sender | receiver | seq:u16le | flags | set | cmd | payload | crc16:u16le`
enum OsmoDuml {
    /// アプリはいつも送信元 id 0 / type 2
    static let senderApp: UInt8 = 0x02
    static let rxCamera: UInt8 = 0x01
    static let rxWifi: UInt8 = 0x07
    static let rxSession: UInt8 = 0xF0
    static let rx1C: UInt8 = 0x1C

    static let flagRequest: UInt8 = 0x40
    static let flagResponse: UInt8 = 0xC0

    struct Frame: Equatable {
        var sender: UInt8
        var receiver: UInt8
        var seq: UInt16
        var flags: UInt8
        var cmdSet: UInt8
        var cmdId: UInt8
        var payload: [UInt8]
    }

    static func encode(_ f: Frame) -> [UInt8] {
        let total = 13 + f.payload.count
        var b: [UInt8] = []
        b.reserveCapacity(total)
        b.append(0x55)
        b.append(UInt8(total & 0xFF))
        b.append(UInt8((1 << 2) | ((total >> 8) & 0x03)))  // version 1 + 長さの上位ビット
        b.append(crc8(b[0..<3]))
        b.append(f.sender)
        b.append(f.receiver)
        b.append(UInt8(f.seq & 0xFF))
        b.append(UInt8((f.seq >> 8) & 0xFF))
        b.append(f.flags)
        b.append(f.cmdSet)
        b.append(f.cmdId)
        b.append(contentsOf: f.payload)
        let c = crc16(b[...])
        b.append(UInt8(c & 0xFF))
        b.append(UInt8((c >> 8) & 0xFF))
        return b
    }

    /// `[len:u8][utf8]`(Wi-Fi 系の命令の文字列)
    static func packString(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        return [UInt8(min(bytes.count, 255))] + bytes.prefix(255)
    }

    /// Wi-Fi 系の返事 `[status:1][len:1][utf8…]`。足りなければ空
    static func unpackStatusString(_ p: [UInt8]) -> String {
        guard p.count >= 2 else { return "" }
        let end = min(2 + Int(p[1]), p.count)
        return String(decoding: p[2..<end], as: UTF8.self)
    }

    /// CRC-8(反転、初期値 0x77、多項式 0x8C)。ヘッダーの 3 バイト
    static func crc8(_ data: ArraySlice<UInt8>) -> UInt8 {
        var c: UInt8 = 0x77
        for byte in data {
            c ^= byte
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        }
        return c
    }

    /// CRC-16(反転、初期値 0x3692、多項式 0x8408)。末尾の CRC を除くフレーム全体
    static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0x3692
        for byte in data {
            c ^= UInt16(byte)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
        }
        return c
    }

    /// `raw` の中の CRC が正しい DUML フレームをすべて取り出す(UDP の包みの中にあっても見つける)
    static func scanFrames(_ raw: [UInt8]) -> [Frame] {
        var out: [Frame] = []
        var i = 0
        let n = raw.count
        while i + 13 <= n {
            guard raw[i] == 0x55 else { i += 1; continue }
            let total = Int(raw[i + 1]) | ((Int(raw[i + 2]) & 0x03) << 8)
            guard raw[i + 2] >> 2 == 1, total >= 13, i + total <= n,
                crc8(raw[i..<(i + 3)]) == raw[i + 3]
            else { i += 1; continue }
            let end = i + total
            let got = UInt16(raw[end - 2]) | (UInt16(raw[end - 1]) << 8)
            guard crc16(raw[i..<(end - 2)]) == got else { i += 1; continue }
            out.append(Frame(
                sender: raw[i + 4], receiver: raw[i + 5],
                seq: UInt16(raw[i + 6]) | (UInt16(raw[i + 7]) << 8),
                flags: raw[i + 8], cmdSet: raw[i + 9], cmdId: raw[i + 10],
                payload: Array(raw[(i + 11)..<(end - 2)])))
            i = end
        }
        return out
    }
}

/// BLE の通知はフレームの区切りと一致しない。特性ごとにつなげてからフレームに分ける
struct OsmoNotificationAssembler {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> [OsmoDuml.Frame] {
        if pending.count + bytes.count > 4096 { pending.removeAll() }
        pending.append(contentsOf: bytes)
        var output: [OsmoDuml.Frame] = []
        while pending.count >= 4 {
            guard pending[0] == 0x55, pending[2] >> 2 == 1,
                OsmoDuml.crc8(pending[0..<3]) == pending[3]
            else { pending.removeFirst(); continue }
            let length = Int(pending[1]) | ((Int(pending[2]) & 3) << 8)
            guard length >= 13 else { pending.removeFirst(); continue }
            guard pending.count >= length else { break }
            if let frame = OsmoDuml.scanFrames(Array(pending.prefix(length))).first {
                output.append(frame)
                pending.removeFirst(length)
            } else {
                pending.removeFirst()
            }
        }
        return output
    }
}

/// UDP 9004 のデータリンク。1 つのデータグラムは `[8B 運び用ヘッダー][12B 経路ヘッダー][DUML]`
enum OsmoTransport {
    enum PktType: UInt8 {
        case handshake = 0x00
        case telemetry = 0x01
        case video = 0x02
        case ackedData = 0x03
        case ack = 0x04
        case command = 0x05
    }

    static func transportSeq(_ d: [UInt8]) -> UInt16? {
        guard d.count >= 6 else { return nil }
        return UInt16(d[4]) | (UInt16(d[5]) << 8)
    }

    static func isHandshake(_ d: [UInt8]) -> Bool {
        d.count >= 8 && d[6] == PktType.handshake.rawValue
    }

    /// `[u16le 0x8000|total][u16le session][u16le seq][u8 pktType][u8 xor]`
    static func transportHeader(pktType: UInt8, payloadLen: Int, sessionId: UInt16, seq: UInt16) -> [UInt8] {
        let w0 = 0x8000 | ((8 + payloadLen) & 0x3FFF)
        var b: [UInt8] = [
            UInt8(w0 & 0xFF), UInt8((w0 >> 8) & 0xFF),
            UInt8(sessionId & 0xFF), UInt8((sessionId >> 8) & 0xFF),
            UInt8(seq & 0xFF), UInt8((seq >> 8) & 0xFF),
            pktType,
        ]
        b.append(b.reduce(0, ^))
        return b
    }

    /// `[u16le seq-8][u16le seq][00 00 00 00][counter][01][00][00]`(seq は自分の送信番号)
    static func routingHeader(seq: UInt16, cmdCounter: UInt8) -> [UInt8] {
        let ack = seq &- 8
        return [
            UInt8(ack & 0xFF), UInt8((ack >> 8) & 0xFF),
            UInt8(seq & 0xFF), UInt8((seq >> 8) & 0xFF),
            0, 0, 0, 0, cmdCounter, 0x01, 0x00, 0x00,
        ]
    }

    /// 40 バイトのハンドシェイク本体。先頭 2 バイトは接続ごとに変える 8 の倍数
    static func handshakePayload(baseSeq: UInt16) -> [UInt8] {
        var p: [UInt8] = [
            0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x00,
            0x01, 0x90,
            0x01, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x14, 0x00, 0x64, 0x00, 0xC0, 0x05,
            0x14, 0x00,
            0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x01, 0x02,
        ]
        p[0] = UInt8(baseSeq & 0xFF)
        p[1] = UInt8((baseSeq >> 8) & 0xFF)
        return p
    }

    static func handshakeDatagram(sessionId: UInt16, seq: UInt16, baseSeq: UInt16) -> [UInt8] {
        let payload = handshakePayload(baseSeq: baseSeq)
        return transportHeader(pktType: PktType.handshake.rawValue, payloadLen: payload.count,
                               sessionId: sessionId, seq: seq) + payload
    }

    /// 34 バイトのテレメトリー(pktType 0x01)。8〜9 バイト目 + 8 が最初の命令番号
    static func initialCommandSequence(fromTelemetry d: [UInt8]) -> UInt16? {
        guard d.count == 34, d[6] == PktType.telemetry.rawValue else { return nil }
        return (UInt16(d[8]) | UInt16(d[9]) << 8) &+ 8
    }

    /// テレメトリーの中の 3 つの窓(映像・命令の返事・その他)。10/18/26 バイト目
    static func telemetryWindows(_ d: [UInt8]) -> (video: UInt16, acked: UInt16, extra: UInt16)? {
        guard d.count >= 34, d[6] == PktType.telemetry.rawValue else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(d[i]) | (UInt16(d[i + 1]) << 8) }
        return (u16(10), u16(18), u16(26))
    }

    /// 26 バイトの窓 ACK(pktType 0x04)。DJI Mimo は約 40 回/秒送る。止めると映像が止まる
    static func ackPayload(video: UInt16, acked: UInt16, extra: UInt16) -> [UInt8] {
        func grp(_ v: UInt16) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF), UInt8(v >> 8), 0, 0, 0, 0]
        }
        return grp(video) + grp(acked) + grp(extra) + [0, 0]
    }

    /// 番号は UInt16 で一周する。前に進む向き(半周未満)だけ受け入れる
    static func isForward(_ candidate: UInt16, from current: UInt16) -> Bool {
        let delta = candidate &- current
        return delta != 0 && delta < 0x8000
    }
}

/// ライブビューまでに使う命令だけ
enum OsmoCommands {
    /// カメラがペアリングの許可を覚えるときのアプリの識別子(Osmosis / OpenPocketCine と同じ値)
    static let defaultIdentifier = "284ae5b8d76b3375a04a6417ad71bea3"
    static let pairingToken = "osmo"

    static func rx(type: UInt8, id: UInt8) -> UInt8 { (id << 5) | type }

    // ---- BLE(fff5 に書く) ----

    /// `0x00/0x2B` ペアリング前の起こし
    static func sessionWake() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxSession, seq: 0x802B,
              flags: OsmoDuml.flagRequest, cmdSet: 0x00, cmdId: 0x2B, payload: [0x04, 0x00])
    }

    /// `0x00/0x2B` BLE をつないでいるあいだの約 1 秒ごとの合図
    static func sessionKeepalive() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxSession, seq: 0x802B,
              flags: OsmoDuml.flagRequest, cmdSet: 0x00, cmdId: 0x2B, payload: [0x01, 0x01])
    }

    /// `0x07/0x45` SetPairingPIN。返事 `00 01` = ペアリング済み、`00 02` = カメラの画面で許可
    static func setPairingPin(seq: UInt16 = 0x8092) -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxWifi, seq: seq,
              flags: OsmoDuml.flagRequest, cmdSet: 0x07, cmdId: 0x45,
              payload: OsmoDuml.packString(defaultIdentifier) + OsmoDuml.packString(pairingToken))
    }

    /// 初回の許可は `0x07/0x46` の「要求」として届く。この返事で答える
    static func pairApprovalAck(seq: UInt16) -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxWifi, seq: seq,
              flags: OsmoDuml.flagResponse, cmdSet: 0x07, cmdId: 0x46, payload: [0x00])
    }

    /// `0x53/0x10` カメラの Wi-Fi(アクセスポイント)を起こす
    static func wakeAccessPoint() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rx1C, seq: 0x8053,
              flags: OsmoDuml.flagRequest, cmdSet: 0x53, cmdId: 0x10, payload: [0, 0, 0, 0])
    }

    /// `0x07/0x07` カメラの Wi-Fi 名
    static func getWifiSsid() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxWifi, seq: 0x8007,
              flags: OsmoDuml.flagRequest, cmdSet: 0x07, cmdId: 0x07, payload: [])
    }

    /// `0x07/0x0E` カメラの Wi-Fi のパスワード(作らずに必ず読む)
    static func getWifiPassword() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxWifi, seq: 0x800E,
              flags: OsmoDuml.flagRequest, cmdSet: 0x07, cmdId: 0x0E, payload: [])
    }

    // ---- UDP データリンク(seq は送るときに振り直す) ----

    /// `0x00/0x81` アプリの機器情報
    static func appDeviceInfo() -> OsmoDuml.Frame {
        var b = [UInt8](repeating: 0, count: 62)
        b[1] = 0x41; b[2] = 0x50; b[3] = 0x50  // "\0APP"
        b[41] = 0x02
        b[50] = 0x02
        b[51] = 0x08
        return .init(sender: OsmoDuml.senderApp, receiver: rx(type: 0x08, id: 2), seq: 0,
                     flags: 0x80, cmdSet: 0x00, cmdId: 0x81, payload: b)
    }

    /// `0x00/0x88` アプリの登録。最後の登録から 8〜10 秒で映像が止まるので約 1 秒ごとに送る
    static func appPresence() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: rx(type: 0x08, id: 1), seq: 0,
              flags: OsmoDuml.flagRequest, cmdSet: 0x00, cmdId: 0x88,
              payload: [0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
    }

    /// `0x00/0x99` 状態の購読(ライブビューの開始前に要る。最小限のキーだけ)
    static func subscribe(key: String, subId: UInt32) -> OsmoDuml.Frame {
        let nb = Array(key.utf8)
        var p: [UInt8] = [0x02, 0x02, 0x00, 0x00]
        p += [UInt8(subId & 0xFF), UInt8((subId >> 8) & 0xFF), UInt8((subId >> 16) & 0xFF), UInt8(subId >> 24)]
        p += [0, 0, 0]
        p += [UInt8((nb.count + 6) & 0xFF), UInt8((nb.count + 6) >> 8)]
        p += [UInt8(nb.count & 0xFF), UInt8(nb.count >> 8)]
        p += nb
        p += [0, 0, 0, 0]
        return .init(sender: OsmoDuml.senderApp, receiver: rx(type: 0x08, id: 1), seq: 0,
                     flags: OsmoDuml.flagRequest, cmdSet: 0x00, cmdId: 0x99, payload: p)
    }

    static let subscriptionKeys = ["cam_status", "cam_video_param_v2", "cam_storage"]
    static let firstSubId: UInt32 = 0x69DF

    /// `0x02/0x68` 08。Pocket で最初のライブビュー開始の直前に Mimo が送っている
    static func liveViewPrepare() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxCamera, seq: 0,
              flags: OsmoDuml.flagRequest, cmdSet: 0x02, cmdId: 0x68, payload: [0x08])
    }

    /// `0x09/0xA8` ライブビュー開始(= キーフレームの要求)。Pocket は受け手 0x08。
    /// 毎秒送り直すとキーフレームが届かなくなる(黒い画面)。1 回だけ、止まったときに数秒あけて 1 回
    static func liveViewEnable() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: rx(type: 0x08, id: 0), seq: 0,
              flags: OsmoDuml.flagRequest, cmdSet: 0x09, cmdId: 0xA8,
              payload: [0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }
}
#endif
