// =====================================================================
// Osmo のライブビュー(UDP pktType 0x02)を 1 枚ずつの Annex-B に組み立てる(実験中・開発者向け)
//
// OpenCine(https://github.com/erik-sutton95/OpenCine, commit dd77b69e)の
// Sources/OpenCineDJI/HevcDepacketizer.swift・Hevc+DJI.swift と Sources/OpenCineMedia/Hevc.swift・Avc.swift
// を移植・簡略化したもの。Copyright 2026 Erik Sutton and OpenCine contributors. Apache License 2.0
// (docs/licenses/OpenCine-LICENSE.txt)。変更点: 型名の変更、診断用の数え方を簡略化。
//
// 1 パケット = [8B 運び用ヘッダー][12B 断片ヘッダー][映像のバイト]。
// 1 枚 = DJI の 16 バイトのヘッダー(00 00 01 ff + 長さ u32le + 8 バイト)+ Annex-B。
// 実機ではまだ一度も試していない。
// =====================================================================

#if OSMO_LIVE
import Foundation

struct OsmoVideoDepacketizer {
    private static let maxEncodedBytes = 4 * 1024 * 1024
    private var sizedMode = false
    private var expectedSize: Int?
    private var sizedBuffer: [UInt8] = []
    private var lastSizedSequence: UInt16?
    // 長さの書いていない古い形(断片番号で区切る)
    private var currentFrame: UInt8?
    private var buffer: [UInt8] = []
    private var lastPosition: Int?
    private var corrupt = false
    /// 断片が欠けて捨てた枚数(画面の診断用)
    private(set) var droppedIncomplete = 0

    /// 1 枚そろったら Annex-B(DJI のヘッダーを外したもの)を返す
    mutating func feed(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count > 20, packet[6] == OsmoTransport.PktType.video.rawValue else { return nil }
        let body = packet[20...]
        let marker = body.starts(with: [0, 0, 1, 0xff])
        let declared = Self.declaredSize(body)
        let nonzeroDeclaration = marker && body.count >= 16
            && body.dropFirst(4).prefix(4).contains(where: { $0 != 0 })
        if sizedMode || nonzeroDeclaration {
            if !sizedMode {
                sizedMode = true
                buffer.removeAll(keepingCapacity: false)
            }
            return feedSized(packet, body: body, marker: marker, declared: declared)
        }
        return feedLegacy(packet)
    }

    mutating func reset() {
        self = OsmoVideoDepacketizer()
    }

    private static func declaredSize(_ body: ArraySlice<UInt8>) -> Int? {
        guard body.count >= 16, body.starts(with: [0, 0, 1, 0xff]) else { return nil }
        let s = body.startIndex
        let count = UInt32(body[s + 4]) | (UInt32(body[s + 5]) << 8)
            | (UInt32(body[s + 6]) << 16) | (UInt32(body[s + 7]) << 24)
        guard count > 0, count <= UInt32(maxEncodedBytes) else { return nil }
        return Int(count) + 16
    }

    private mutating func feedSized(_ packet: [UInt8], body: ArraySlice<UInt8>, marker: Bool,
                                    declared: Int?) -> [UInt8]? {
        let sequence = UInt16(packet[4]) | (UInt16(packet[5]) << 8)
        if sequence == lastSizedSequence { return nil }  // UDP の重複
        if marker {
            if expectedSize != nil { droppedIncomplete += 1 }
            sizedBuffer.removeAll(keepingCapacity: true)
            expectedSize = declared
            lastSizedSequence = nil
        }
        guard let expected = expectedSize else { return nil }
        // 映像のパケット番号は 8 ずつ進む。飛んだらこの 1 枚は捨てる
        if let last = lastSizedSequence, sequence != last &+ 8 {
            droppedIncomplete += 1
            expectedSize = nil
            sizedBuffer.removeAll(keepingCapacity: true)
            lastSizedSequence = sequence
            return nil
        }
        lastSizedSequence = sequence
        guard body.count <= expected - sizedBuffer.count else {
            droppedIncomplete += 1
            expectedSize = nil
            sizedBuffer.removeAll(keepingCapacity: true)
            return nil
        }
        sizedBuffer.append(contentsOf: body)
        guard sizedBuffer.count == expected else { return nil }
        let accessUnit = Array(sizedBuffer.dropFirst(16))
        sizedBuffer.removeAll(keepingCapacity: true)
        expectedSize = nil
        return accessUnit
    }

    private mutating func feedLegacy(_ packet: [UInt8]) -> [UInt8]? {
        let frameNo = packet[16]
        let position = Int(packet[18]) * 2 + Int(packet[17] >> 7)
        var completed: [UInt8]?
        if let cur = currentFrame, cur != frameNo {
            if !buffer.isEmpty {
                if corrupt { droppedIncomplete += 1 } else { completed = OsmoNAL.stripDjiMarker(buffer) }
            }
            buffer.removeAll(keepingCapacity: true)
            corrupt = false
            lastPosition = nil
        }
        currentFrame = frameNo
        if let last = lastPosition {
            if position == last { return completed }
            if position < last {
                if !buffer.isEmpty {
                    if corrupt { droppedIncomplete += 1 } else { completed = OsmoNAL.stripDjiMarker(buffer) }
                }
                buffer.removeAll(keepingCapacity: true)
                corrupt = false
            } else if position != last + 1 {
                corrupt = true
            }
        }
        lastPosition = position
        if packet.count - 20 <= Self.maxEncodedBytes + 16 - buffer.count {
            buffer.append(contentsOf: packet[20...])
        } else {
            corrupt = true
        }
        return completed
    }
}

enum OsmoVideoCodec: String {
    case hevc = "HEVC"
    case avc = "H.264"
}

/// Annex-B の NAL を分ける・種類を見る
enum OsmoNAL {
    static func hevcType(_ b: UInt8) -> Int { Int((b >> 1) & 0x3F) }
    static func avcType(_ b: UInt8) -> Int { Int(b & 0x1F) }

    /// DJI の `00 00 01 ff …`(HEVC の NAL 種類 63)を飛ばして、最初の普通の NAL から返す
    static func stripDjiMarker(_ annexB: [UInt8]) -> [UInt8] {
        var i = 0
        while i + 4 <= annexB.count {
            if annexB[i] == 0, annexB[i + 1] == 0, annexB[i + 2] == 1 {
                if hevcType(annexB[i + 3]) != 63 { return Array(annexB[i...]) }
                i += 3
            } else {
                i += 1
            }
        }
        return annexB
    }

    /// 開始コードを除いた NAL の範囲。Nano の DJI 独自 SEI(06 F0 19 … 80)は中身に 00 00 01 を含むので長さで飛ばす
    static func nalRanges(_ annexB: [UInt8]) -> [Range<Int>] {
        var starts: [Int] = []
        var privateMetadata: Set<Int> = []
        var i = 0
        while i + 3 <= annexB.count {
            if annexB[i] == 0, annexB[i + 1] == 0, annexB[i + 2] == 1 {
                starts.append(i + 3)
                if i + 32 <= annexB.count, annexB[i + 3] == 6, annexB[i + 4] == 0xF0,
                    annexB[i + 5] == 25, annexB[i + 31] == 0x80 {
                    privateMetadata.insert(i + 3)
                    i += 32
                } else {
                    i += 3
                }
            } else {
                i += 1
            }
        }
        var nals: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            if privateMetadata.contains(s) { continue }
            var e = (k + 1 < starts.count) ? starts[k + 1] - 3 : annexB.count
            while e > s && annexB[e - 1] == 0 { e -= 1 }
            if e > s { nals.append(s..<e) }
        }
        return nals
    }

    static func nalUnits(_ annexB: [UInt8]) -> [[UInt8]] {
        nalRanges(annexB).map { Array(annexB[$0]) }
    }

    /// 符号化方式はパラメーターセットでだけ決める(HEVC VPS/SPS/PPS = 0x40/0x42/0x44、AVC SPS/PPS = 0x67/0x68 系)。
    /// 前の GOP の残り(TRAIL など)や 0x28 だけで決めると間違える
    static func detectCodec(_ nals: [[UInt8]]) -> OsmoVideoCodec? {
        for nal in nals {
            guard let b = nal.first else { continue }
            // 0x28 は HEVC の IDR_N_LP でもあり AVC の PPS(nal_ref_idc=1)でもあるので使わない
            switch b {
            case 0x40, 0x42, 0x44: return .hevc
            case 0x67, 0x68: return .avc
            default: break
            }
        }
        return nil
    }

    static func isParameterSet(_ nal: [UInt8], codec: OsmoVideoCodec) -> Bool {
        guard let b = nal.first else { return false }
        switch codec {
        case .hevc: return (32...34).contains(hevcType(b))
        case .avc: return [7, 8].contains(avcType(b))
        }
    }

    /// 単独で表示できる絵(HEVC IRAP 16〜21、AVC IDR 5)。Pocket 4 は BLA(16)のことが多い
    static func isRandomAccess(_ nal: [UInt8], codec: OsmoVideoCodec) -> Bool {
        guard let b = nal.first else { return false }
        switch codec {
        case .hevc: return (16...21).contains(hevcType(b))
        case .avc: return avcType(b) == 5
        }
    }

    /// 絵のデータ(VCL)か。SEI や AUD は VideoToolbox に渡さない
    static func isPicture(_ nal: [UInt8], codec: OsmoVideoCodec) -> Bool {
        guard let b = nal.first else { return false }
        switch codec {
        case .hevc: return hevcType(b) <= 31
        case .avc: return (1...5).contains(avcType(b))
        }
    }
}
#endif
