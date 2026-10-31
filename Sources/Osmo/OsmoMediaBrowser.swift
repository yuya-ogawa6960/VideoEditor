// =====================================================================
// OsmoMediaBrowser: カメラ本体に保存された動画を、カメラの Wi-Fi で本来の画質のまま取り込む(実験中・開発者向け)
//
// 流れ(docs/OsmoPocket.md の「SD カードの動画を Wi-Fi で取り込む(調査)」に詳しく):
//   1. データリンク(UDP 9004)で 0x02/0x0C `01 01 00 01` を送り、カメラを再生モードにする
//      (できたかは 0x02/0x80 の bit 30 で見る。Pocket 3 は E0 を返すが、最新の 45 件は再生モードなしでも読める)
//   2. 0x00/0x26 で一覧を頼む(SD = 番号 1・カーソル 0x00000001 → きっかけ `4a040e10…` → 本体 = 番号 2・カーソル 0x40000001)
//   3. 0x00/0x27 の塊(先頭 10 バイトを外して届いた順につなぐ)を CompositePack として読む
//   4. GET http://192.168.2.1/v2?storage={0|1}&path=<DCIM/…/DJI_….MP4>(パスの / はそのまま)。Range で続きから取れる
//   5. 閉じたら 0x02/0x0C `01 01 00 00` で再生モードを抜け、0x09/0xA8 でライブビューに戻す
//
// 出どころ:
//   - OpenCine(https://github.com/erik-sutton95/OpenCine, commit dd77b69e)の
//     Sources/OpenCineDJI/MediaManifest+DJIWire.swift(一覧の命令・塊の組み立て・CompositePack の読み方)、
//     Sources/OpenCineCameraVocabulary/MediaManifest.swift(/v2 の URL と storage の決め方)、
//     Sources/OpenCineDJIApple/DjiAppleMediaService.swift(再生モード → 一覧の順番と待ち時間)、
//     Sources/OpenCineDJI/Commands.swift(enterPlayback / exitPlayback / mediaList / mediaListTrigger)
//     Copyright 2026 Erik Sutton and OpenCine contributors. Apache License 2.0
//     (docs/licenses/OpenCine-LICENSE.txt と docs/licenses/OpenCine-NOTICE.txt)
//   - OpenPocketCine handbook protocol/media.md(Apache 2.0)
//   - Osmosis(https://github.com/KonradIT/osmosis)MEDIA_PROTOCOL.md(MIT, Copyright 2026 Konrad Iturbe。
//     docs/licenses/Osmosis-LICENSE.txt)。Pocket 4 は本体の保存領域が storage 1、再生モードの確かめ方、待ち時間など
// 変更点: この app 用に書き直し。最新の 45 件(ページ送りなし)の動画だけ。削除・お気に入り・写真・プレビュー再生は入れていない。
//         ダウンロードは URLSession でファイルに直接書き、切れたら Range で続きから取る(この app で足した部分)。
//
// DJI の公式 SDK や資料は使っていない(リバースエンジニアリングされた公開情報のみ)。
// **実機ではまだ一度も試していない**。
// =====================================================================

#if OSMO_LIVE
import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - 一覧の 1 件

struct OsmoMediaFile: Identifiable, Equatable, Sendable {
    /// カメラの中のパス(拡張子つき)。例: DCIM/DJI_001/DJI_20261031123456_0012_D.MP4
    var path: String
    /// サムネイル(MISC/THM/…/<名前>.scr。中身は JPEG)
    var thumbPath: String
    /// /v2?storage= の値。0 = SD カード、1 = 本体の保存領域(Pocket 4 の 107GB など)
    var storage: Int
    /// storage が一覧の番号(1 = SD・2 = 本体)から分かったものか(false なら handle の bit からの推測)
    var storageKnown: Bool
    /// カメラの中の番号(削除などに使う。ここでは並べ替えの予備だけ)
    var handle: UInt32
    /// 一覧に書かれた大きさ(u32。0 は不明)。本当の長さは HTTP の応答で決める
    var sizeBytes: UInt64
    /// 長さ(秒。整数)
    var durationSeconds: Int
    /// 解像度の番号(0x10 = 3840×2160 など)
    var resolutionCode: UInt8?
    var fps: Int?

    var id: String { "\(storage):\(path)" }
    var filename: String { (path as NSString).lastPathComponent }
    var fileExtension: String { (filename as NSString).pathExtension.uppercased() }
    var isVideo: Bool { fileExtension == "MP4" || fileExtension == "MOV" }

    /// ファイル名の撮影日時 `DJI_<YYYYMMDDHHMMSS>_…`(カメラの時計のまま)
    var timestamp: String? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = Self.timestampRegex.firstMatch(in: filename, options: [], range: range),
              let captured = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[captured])
    }

    /// 撮影日時。カメラの時計(時差なし)のまま読むので、表示も GMT で行う
    var captureDate: Date? {
        guard let stamp = timestamp else { return nil }
        return Self.stampFormatter.date(from: stamp)
    }

    var dimensions: (width: Int, height: Int)? {
        resolutionCode.flatMap { OsmoMediaManifest.dimensions($0) }
    }

    private static let timestampRegex = try! NSRegularExpression(pattern: #"_(\d{14})_"#)
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    /// 新しい順(ファイル名の日時 → handle)
    static func newestFirst(_ a: OsmoMediaFile, _ b: OsmoMediaFile) -> Bool {
        let sa = a.timestamp ?? "", sb = b.timestamp ?? ""
        if sa != sb { return sa > sb }
        return a.handle > b.handle
    }
}

// MARK: - 命令(OpenCine の Commands / MediaListCommand と同じバイト列)

enum OsmoMediaCommands {
    /// 最新のページを頼むカーソル(SD・本体)
    static let newestSD: UInt32 = 0x0000_0001
    static let newestInternal: UInt32 = 0x4000_0001
    /// 一覧の番号(返事の塊の 4 バイト目に返ってくる)。1 = SD、2 = 本体
    static let sdCounter: UInt8 = 1
    static let internalCounter: UInt8 = 2

    /// `0x00/0x26` 一覧。@4 番号、@10–13 カーソル(u32-LE)、@14 = 0x2D(45 件)、@16 = 0x0D(全部)
    static let listTemplate: [UInt8] = [
        0x4A, 0x00, 0x2A, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x2D, 0x00, 0x0D, 0x01, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    /// 2 つの一覧のあいだに Mimo / Osmosis が送っているきっかけ
    static let triggerPayload: [UInt8] = [
        0x4A, 0x04, 0x0E, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ]

    static func list(counter: UInt8, cursor: UInt32) -> OsmoDuml.Frame {
        var payload = listTemplate
        payload[4] = counter
        payload[10] = UInt8(cursor & 0xFF)
        payload[11] = UInt8((cursor >> 8) & 0xFF)
        payload[12] = UInt8((cursor >> 16) & 0xFF)
        payload[13] = UInt8((cursor >> 24) & 0xFF)
        return .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxCamera, seq: 0,
                     flags: OsmoDuml.flagRequest, cmdSet: 0x00, cmdId: 0x26, payload: payload)
    }

    static func trigger() -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxCamera, seq: 0,
              flags: OsmoDuml.flagRequest, cmdSet: 0x00, cmdId: 0x26, payload: triggerPayload)
    }

    /// `0x02/0x0C` 再生モードに入る `01 01 00 01` / 抜ける `01 01 00 00`
    static func playback(enter: Bool) -> OsmoDuml.Frame {
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxCamera, seq: 0,
              flags: OsmoDuml.flagRequest, cmdSet: 0x02, cmdId: 0x0C,
              payload: [0x01, 0x01, 0x00, enter ? 0x01 : 0x00])
    }
}

// MARK: - 0x00/0x27 の塊を集める(データリンクのキューから呼ぶので、鍵をかける)

final class OsmoMediaChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var chunks: [UInt8: [UInt8]] = [:]
    private var counts: [UInt8: Int] = [:]
    private var started: Set<UInt8> = []
    private var dataCounters: Set<UInt8> = []
    private var ended: Set<UInt8> = []
    private var total = 0

    /// 集め始める(前の分は捨てる)
    func begin() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
        active = true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }

    /// 1 つの番号だけ捨てる(SD が空で返ってきたとき、もう一度頼む前に)
    func reset(counter: UInt8) {
        lock.lock(); defer { lock.unlock() }
        chunks[counter] = nil
        total = max(0, total - (counts.removeValue(forKey: counter) ?? 0))
        started.remove(counter)
        dataCounters.remove(counter)
        ended.remove(counter)
    }

    /// `0x00/0x27` だけを受け取る。中身は `[10 バイトの頭][塊]`。頭の @1 = 04 始まり / 01 データ / 03 終わり、@4 = 番号
    /// (`4A 01` で始まる別の通知もあるので、必ず命令の番号 0x00/0x27 で選ぶ)
    func ingest(_ frame: OsmoDuml.Frame) {
        guard frame.cmdSet == 0x00, frame.cmdId == 0x27 else { return }
        let p = frame.payload
        guard p.count >= 10, p[0] == 0x4A else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        let subtype = p[1]
        let counter = p[4]
        switch subtype {
        case 0x04:
            started.insert(counter)
        case 0x03:
            ended.insert(counter)
        case 0x01 where p.count > 10:
            dataCounters.insert(counter)
            chunks[counter, default: []].append(contentsOf: p[10...])
            counts[counter, default: 0] += 1
            total += 1
        default:
            break
        }
    }

    /// counter = nil なら全部の数
    func chunkCount(_ counter: UInt8?) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let counter else { return total }
        return counts[counter] ?? 0
    }

    func didEnd(_ counter: UInt8) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ended.contains(counter)
    }

    /// 返事が来た番号がすべて閉じたか(始まりだけでデータが無い = 空の保存先)
    var allObservedClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        let observed = started.union(dataCounters).union(ended)
        guard !observed.isEmpty else { return false }
        return observed.allSatisfy { ended.contains($0) || (started.contains($0) && !dataCounters.contains($0)) }
    }

    var hasResponse: Bool {
        lock.lock(); defer { lock.unlock() }
        return !started.isEmpty || !dataCounters.isEmpty || !ended.isEmpty
    }

    func bytes(counter: UInt8) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return chunks[counter] ?? []
    }

    /// 番号の順につないだもの(カメラが番号を返さなかったときの予備)
    func merged() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var out: [UInt8] = []
        for key in chunks.keys.sorted() { out.append(contentsOf: chunks[key] ?? []) }
        return out
    }

    private func clearLocked() {
        chunks = [:]
        counts = [:]
        started = []
        dataCounters = []
        ended = []
        total = 0
    }
}

// MARK: - CompositePack を読む(OpenCine の MediaManifest.decodeComposite を短くしたもの)

enum OsmoMediaManifest {
    static let videoExtensions: Set<String> = ["MP4", "MOV"]
    static let photoExtensions: Set<String> = ["JPG", "JPEG", "DNG", "HEIC", "TIF", "TIFF", "PANO"]
    static let proxyExtensions: Set<String> = ["LRF", "LRV", "XRF"]

    /// 解像度の番号(OpenCine の DJIRecordingObservations.dimensions と同じ表)
    static func dimensions(_ code: UInt8) -> (width: Int, height: Int)? {
        switch code {
        case 0x0A: return (1920, 1080)
        case 0x0C: return (1920, 1440)
        case 0x10: return (3840, 2160)
        case 0x2D: return (2688, 1512)
        case 0x42: return (1080, 1920)
        case 0x43: return (1512, 2688)
        case 0x5F: return (2688, 2016)
        case 0x67: return (3840, 2880)
        case 0x69: return (1080, 1080)
        case 0x6A: return (2160, 2160)
        case 0x6B: return (3072, 3072)
        case 0x6C: return (1728, 3072)
        case 0x7D: return (3840, 3840)
        default: return nil
        }
    }

    /// 先頭の u32-LE(このページの件数。Action 5 Pro などは 0)
    static func headerCount(_ b: [UInt8]) -> Int {
        guard b.count >= 4 else { return -1 }
        return Int(u32(b, 0))
    }

    /// 媒体パス(DCIM/…)の数
    static func recordCount(_ b: [UInt8]) -> Int {
        var paths = Set<String>()
        var i = 0
        while i < b.count {
            if let field = readPath(b, i, sub: 1, prefix: "DCIM/") {
                paths.insert(field.value)
                i = field.end
            } else {
                i += 1
            }
        }
        return paths.count
    }

    /// 件数が書かれていて、読めた数のほうが少ない = 塊の一部が届かなかった
    static func isIncomplete(_ b: [UInt8]) -> Bool {
        guard !b.isEmpty else { return false }
        let declared = headerCount(b)
        return (1...512).contains(declared) && recordCount(b) < declared
    }

    /// SD(番号 1)と本体(番号 2)の答えを読み、storage を付ける(OpenCine の decodeStores と同じ考え方)
    static func decodeStores(sd: [UInt8], internalStore: [UInt8], merged: [UInt8]) -> [OsmoMediaFile] {
        let sdFiles = sd.isEmpty ? [] : decode(sd)
        let inFiles = internalStore.isEmpty ? [] : decode(internalStore)
        if (sdFiles.isEmpty && inFiles.isEmpty)
            || (!sdFiles.isEmpty && !inFiles.isEmpty && Set(sdFiles.map(\.path)) == Set(inFiles.map(\.path))) {
            // 番号が返ってこなかった・両方が同じ一覧: handle の bit 0x40000000(立っていれば本体 = 1)で推測
            return decode(merged).map { (file: OsmoMediaFile) -> OsmoMediaFile in
                var f = file
                f.storage = (file.handle & 0x4000_0000) != 0 ? 1 : 0
                f.storageKnown = false
                return f
            }
        }
        let sdStamped: [OsmoMediaFile] = sdFiles.map { file in
            var f = file
            f.storage = 0
            f.storageKnown = true
            return f
        }
        let inStamped: [OsmoMediaFile] = inFiles.map { file in
            var f = file
            f.storage = 1
            f.storageKnown = true
            return f
        }
        return sdStamped + inStamped
    }

    /// 1 つの答えを読む。媒体パスの位置を区切りにして、その範囲の中だけで各項目を探す(隣の記録を読まないように)
    static func decode(_ b: [UInt8]) -> [OsmoMediaFile] {
        var anchors: [(pos: Int, end: Int, path: String)] = []
        var i = 0
        while i < b.count {
            if let field = readPath(b, i, sub: 1, prefix: "DCIM/") {
                anchors.append((i, field.end, field.value))
                i = field.end
            } else {
                i += 1
            }
        }
        var seen = Set<String>()
        var out: [OsmoMediaFile] = []
        for (k, anchor) in anchors.enumerated() {
            let lo = k > 0 ? anchors[k - 1].end : 0
            let hi = k + 1 < anchors.count ? anchors[k + 1].pos : b.count
            guard seen.insert(anchor.path).inserted else { continue }
            out.append(resolve(b, mediaDir: anchor.path, lo: lo, hi: hi))
        }
        return out
    }

    private static func resolve(_ b: [UInt8], mediaDir: String, lo: Int, hi: Int) -> OsmoMediaFile {
        let base = (mediaDir as NSString).lastPathComponent

        // サムネイルのパス(1a … 00 00 00 02 "MISC/…")
        var thumb: String?
        var t = lo
        while t < hi {
            if let field = readPath(b, t, sub: 2, prefix: "MISC/"), field.value.hasSuffix(base) {
                thumb = field.value
                break
            }
            t += 1
        }

        // 拡張子は 0d のファイル名の欄にだけある(パスには無い)。代理ファイル(.LRF など)の名前は使わない
        var ext = ""
        var n = lo
        while n < hi - 2 {
            if b[n] == 0x0D {
                let len = Int(b[n + 1])
                if len > base.utf8.count + 1, n + 2 + len <= b.count,
                   let value = String(bytes: b[(n + 2)..<(n + 2 + len)], encoding: .isoLatin1),
                   value.hasPrefix(base), value.dropFirst(base.count).first == "." {
                    let e = String(value.dropFirst(base.count + 1)).uppercased()
                    if !proxyExtensions.contains(e), videoExtensions.contains(e) || photoExtensions.contains(e) {
                        ext = e
                    }
                }
            }
            n += 1
        }

        // 印 `[03|00] [ff|fe] 19 06`。T = 19 06 の位置として、T-10 = handle、T-14 = 大きさ、T-6 = 秒、T-3 = 解像度
        var head = -1
        var m = max(lo, 8)
        while m < hi - 4 {
            if (b[m] == 0x03 || b[m] == 0x00), (b[m + 1] == 0xFF || b[m + 1] == 0xFE),
               b[m + 2] == 0x19, b[m + 3] == 0x06 {
                head = m - 8
                break
            }
            m += 1
        }
        let isVideo = videoExtensions.contains(ext)
        var handle: UInt32 = 0
        var size: UInt64 = 0
        var duration = 0
        var resolution: UInt8?
        var fps: Int?
        if head >= 4, head + 8 <= b.count {
            handle = u32(b, head)
            if isVideo {
                size = UInt64(u32(b, head - 4))
                duration = Int(b[head + 4]) | (Int(b[head + 5]) << 8)
                let code = b[head + 7]
                resolution = dimensions(code) != nil ? code : nil
                fps = fpsInRange(b, start: head, end: hi)
            }
        }
        let path = ext.isEmpty ? mediaDir : "\(mediaDir).\(ext)"
        let thumbPath = (thumb ?? mediaDir.replacingOccurrences(of: "DCIM/", with: "MISC/THM/", options: .anchored)) + ".scr"
        return OsmoMediaFile(path: path, thumbPath: thumbPath, storage: 0, storageKnown: false, handle: handle,
                             sizeBytes: size, durationSeconds: duration, resolutionCode: resolution, fps: fps)
    }

    /// `1a <全長> 00 00 00 <sub> <ascii>`(ascii = 全長 - 6 バイト)
    private static func readPath(_ b: [UInt8], _ i: Int, sub: UInt8, prefix: String) -> (value: String, end: Int)? {
        guard i + 6 <= b.count, b[i] == 0x1A, b[i + 2] == 0, b[i + 3] == 0, b[i + 4] == 0, b[i + 5] == sub else { return nil }
        let slen = Int(b[i + 1]) - 6
        guard slen >= prefix.utf8.count, i + 6 + slen <= b.count else { return nil }
        let raw = b[(i + 6)..<(i + 6 + slen)]
        guard raw.allSatisfy({ (0x20...0x7E).contains($0) }),
              let value = String(bytes: raw, encoding: .isoLatin1), value.hasPrefix(prefix) else { return nil }
        return (value, i + 6 + slen)
    }

    /// `<u32 分子><u32 分母>`(分母 1000 か 1001)。例 25000/1000 = 25fps
    private static func fpsInRange(_ b: [UInt8], start: Int, end: Int) -> Int? {
        var fps: Int?
        var i = max(0, start)
        let stop = min(end, b.count) - 8
        while i <= stop {
            let den = u32(b, i + 4)
            if den == 1000 || den == 1001 {
                let num = u32(b, i)
                if (20_000...250_000).contains(num) {
                    fps = Int((Double(num) / Double(den)).rounded())
                }
            }
            i += 1
        }
        return fps
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

// MARK: - HTTP(カメラの lighttpd。/v2 だけが答える)

enum OsmoMediaHTTP {
    /// `http://192.168.2.1/v2?storage=<0|1>&path=<パス>`。パスの / は %2F にしない(%2F だと 404 になった記録がある)
    static func url(storage: Int, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = OsmoWiFi.cameraHost
        c.path = "/v2"
        c.queryItems = [
            URLQueryItem(name: "storage", value: String(storage)),
            URLQueryItem(name: "path", value: path),
        ]
        return c.url
    }

    /// カメラの Wi-Fi だけを使う(モバイル通信に逃げない)。キャッシュしない
    static func configuration(requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.allowsCellularAccess = false
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        return c
    }

    /// サムネイル用(小さいので普通に Data で受ける)
    static let thumbnailSession = URLSession(configuration: configuration(requestTimeout: 8))

    /// `bytes 100-999/1000` → (100, 1000)。全長が `*` なら nil
    static func parseContentRange(_ value: String) -> (start: UInt64, total: UInt64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"),
              let start = UInt64(parts[0][..<dash]) else { return nil }
        return (start, UInt64(parts[1]))
    }
}

enum OsmoMediaError: LocalizedError {
    case notConnected
    case noAnswer
    case badResponse
    case httpStatus(Int)
    case notFound
    case noSpace
    case gaveUp

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "カメラにつながっていません")
        case .noAnswer: return String(localized: "カメラが一覧を返しませんでした。カメラの電源を入れ直してから、もう一度つないでください。")
        case .badResponse: return String(localized: "カメラから思わぬ返事が来ました")
        case .httpStatus(let code): return String(localized: "カメラがファイルを渡しませんでした(\(code))")
        case .notFound: return String(localized: "カメラにファイルが見つかりませんでした")
        case .noSpace: return String(localized: "iPhone の空き容量が足りません")
        case .gaveUp: return String(localized: "通信が何度も切れたので、やめました。もう一度タップすると続きから取り込みます。")
        }
    }
}

// MARK: - 1 回の GET。届いた分をそのままファイルの後ろに書く(メモリにためない)

final class OsmoMediaRangeRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        var status: Int
        /// 書き終えたときのファイルの大きさ
        var fileSize: UInt64
        /// ファイル全体の長さ(206 の Content-Range か、200 の Content-Length)
        var total: UInt64?
        var etag: String?
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let offset: UInt64
    private let onProgress: @Sendable (UInt64, UInt64?) -> Void
    private var handle: FileHandle?
    private var fileSize: UInt64 = 0
    private var status = 0
    private var total: UInt64?
    private var etag: String?
    private var checkedResponse = false
    private var failure: Error?
    private var cancelled = false
    private var lastReport = Date.distantPast
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Result, Error>?

    init(fileURL: URL, offset: UInt64, onProgress: @escaping @Sendable (UInt64, UInt64?) -> Void) {
        self.fileURL = fileURL
        self.offset = offset
        self.onProgress = onProgress
    }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                // セッションは代理(self)を強く持つ。終わったら finishTasksAndInvalidate で手放す
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let dataTask = session.dataTask(with: request)
                lock.lock()
                continuation = cont
                task = dataTask
                let alreadyCancelled = cancelled
                lock.unlock()
                dataTask.resume()
                if alreadyCancelled { dataTask.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    /// 最初の応答を見て、書き始める位置を決める(lock を持って呼ぶ)
    private func prepareLocked(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { throw OsmoMediaError.badResponse }
        status = http.statusCode
        etag = http.value(forHTTPHeaderField: "ETag")
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else { throw OsmoMediaError.badResponse }
        }
        let h = try FileHandle(forWritingTo: fileURL)
        switch status {
        case 206:
            // 頼んだ位置から来たかを Content-Range で確かめる
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = OsmoMediaHTTP.parseContentRange(value), range.start == offset else {
                try? h.close()
                throw OsmoMediaError.badResponse
            }
            total = range.total
            try h.truncate(atOffset: offset)
            fileSize = offset
        case 200:
            // Range を無視した(または If-Range が合わずファイル全体が来た)→ 最初から書き直す
            total = http.expectedContentLength > 0 ? UInt64(http.expectedContentLength) : nil
            try h.truncate(atOffset: 0)
            fileSize = 0
        default:
            try? h.close()
            throw OsmoMediaError.httpStatus(status)
        }
        handle = h
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failure != nil || cancelled {
            lock.unlock()
            return
        }
        if !checkedResponse {
            checkedResponse = true
            do {
                try prepareLocked(dataTask.response)
            } catch {
                failure = error
                lock.unlock()
                dataTask.cancel()
                return
            }
        }
        guard let h = handle else {
            lock.unlock()
            return
        }
        do {
            try h.write(contentsOf: data)
            fileSize += UInt64(data.count)
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
            return
        }
        var report: (UInt64, UInt64?)?
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 {
            lastReport = now
            report = (fileSize, total)
        }
        lock.unlock()
        if let report { onProgress(report.0, report.1) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if failure == nil, error == nil, !checkedResponse {
            // 中身が 0 バイトの応答
            checkedResponse = true
            do { try prepareLocked(task.response) } catch { failure = error }
        }
        if let h = handle {
            try? h.synchronize()
            try? h.close()
            handle = nil
        }
        let cont = continuation
        continuation = nil
        let result = Result(status: status, fileSize: fileSize, total: total, etag: etag)
        let outcome: Error?
        if cancelled {
            outcome = CancellationError()
        } else {
            outcome = failure ?? error
        }
        let size = fileSize
        let knownTotal = total
        lock.unlock()
        session.finishTasksAndInvalidate()
        onProgress(size, knownTotal)
        if let outcome {
            cont?.resume(throwing: outcome)
        } else {
            cont?.resume(returning: result)
        }
    }
}

// MARK: - 一覧と取り込み

@MainActor
@Observable
final class OsmoMediaLibrary {
    enum ListState: Equatable {
        case idle
        case loading(String)
        case loaded
        case failed(String)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(fileID: String, received: UInt64, total: UInt64?)
        case finished(URL)
        case failed(String)
    }

    private(set) var listState: ListState = .idle
    /// 動画だけ、新しい順
    private(set) var files: [OsmoMediaFile] = []
    private(set) var thumbnails: [String: UIImage] = [:]
    /// 一覧について知らせること(途中までしか読めなかった など)
    private(set) var listNote: String?
    private(set) var downloadState: DownloadState = .idle
    /// 直近の速さ(バイト/秒)
    private(set) var bytesPerSecond: Double?
    /// 再生モードを持っているあいだ true(ライブビューは止まる。監視のキーフレーム要求を止めるのに使う)
    private(set) var holdsPlayback = false

    @ObservationIgnored var onLog: ((String) -> Void)?
    /// 再生モードを抜けたあと(ライブビューに戻すため 0x09/0xA8 を送ってもらう)
    @ObservationIgnored var onReturnToLive: (() -> Void)?
    /// データリンクのキューから直接 0x00/0x27 を入れる(届いた順を崩さないため MainActor を通さない)
    let collector = OsmoMediaChunkCollector()

    @ObservationIgnored private weak var link: OsmoDatalink?
    @ObservationIgnored private var inPlayback = false
    @ObservationIgnored private var playbackReply: [UInt8]?
    @ObservationIgnored private var enteredPlayback = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken: UUID?
    @ObservationIgnored private var thumbTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    @ObservationIgnored private var speedSample: (at: Date, bytes: UInt64)?

    /// データリンクにつながっているか(画面に出すので見張る)
    private(set) var isAttached = false
    var isLoading: Bool {
        if case .loading = listState { return true }
        return false
    }
    var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    /// 取り込んだファイルを置く場所(取り込み側がコピーして消す。.part は続きから取るために残す)
    nonisolated static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OsmoMedia", isDirectory: true)
    }

    // MARK: つなぐ・切る

    func attach(_ link: OsmoDatalink) {
        self.link = link
        isAttached = true
    }

    /// 切断のとき(OsmoLiveMonitor.teardown が datalink.close の前に呼ぶ)
    func detach() {
        loadTask?.cancel(); loadTask = nil
        loadToken = nil
        thumbTask?.cancel(); thumbTask = nil
        downloadTask?.cancel()
        leaveTask?.cancel(); leaveTask = nil
        if (holdsPlayback || enteredPlayback), let link {
            // 抜ける命令だけ送っておく(届かなくても、データリンクが切れるとカメラは数秒で元に戻るとされる)
            link.sendCommand(OsmoMediaCommands.playback(enter: false))
        }
        collector.end()
        link = nil
        isAttached = false
        holdsPlayback = false
        enteredPlayback = false
        inPlayback = false
        playbackReply = nil
        if case .loading = listState { listState = .idle }
    }

    // MARK: 受ける

    /// データリンクのフレームのうち、ここで見るもの(0x02/0x80 の状態、0x02/0x0C の返事)
    nonisolated static func isRelevant(_ frame: OsmoDuml.Frame) -> Bool {
        frame.cmdSet == 0x02 && (frame.cmdId == 0x80 || frame.cmdId == 0x0C)
    }

    func handle(_ frame: OsmoDuml.Frame) {
        guard frame.cmdSet == 0x02 else { return }
        switch frame.cmdId {
        case 0x80:
            // u32-LE の bit 30(0x40000000)= 再生モード中。これだけが「入った」の印
            let p = frame.payload
            guard p.count >= 4 else { return }
            let flags = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            let now = (flags & 0x4000_0000) != 0
            if now != inPlayback {
                inPlayback = now
                log("media: camera reports playback \(now ? "ON" : "off")")
                if !now, holdsPlayback, isDownloading {
                    log("media: camera left playback during download")
                }
            }
        case 0x0C where frame.flags & 0x80 != 0:
            playbackReply = frame.payload
            log("media: reply 0x02/0x0C \(OsmoBluetoothLink.hex(frame.payload))")
        default:
            break
        }
    }

    // MARK: 一覧

    /// 一覧を読み直す(再生モードに入ってから最新の 45 件)
    func refresh() {
        guard loadTask == nil, !isDownloading else { return }
        leaveTask?.cancel(); leaveTask = nil
        let token = UUID()
        loadToken = token
        loadTask = Task { [weak self] in
            await self?.runLoad()
            // 途中で閉じて、また開いたとき(新しい読み込み)を消さない
            if let self, self.loadToken == token { self.loadTask = nil }
        }
    }

    private func runLoad() async {
        guard let link else {
            listState = .failed(OsmoMediaError.notConnected.localizedDescription)
            return
        }
        listNote = nil
        listState = .loading(String(localized: "カメラを再生モードにしています…"))
        let held = await enterPlayback(link)
        guard !Task.isCancelled else { return }
        if held {
            // 再生モードに入った直後は保存先がまだ読めないことがある(Osmosis の観察: 約 1.7 秒)
            try? await Task.sleep(for: .milliseconds(1700))
        }
        listState = .loading(String(localized: "カメラの動画の一覧を読んでいます…"))
        do {
            var page = try await queryNewestPage(link, retryEmptySD: held)
            if page.files.isEmpty, held, !Task.isCancelled {
                log("media: empty answer, ask again once")
                try await Task.sleep(for: .milliseconds(1500))
                page = try await queryNewestPage(link, retryEmptySD: false)
            }
            let videos = page.files.filter(\.isVideo).sorted(by: OsmoMediaFile.newestFirst)
            files = videos
            log("media: \(page.files.count) files, \(videos.count) videos\(page.incomplete ? " (incomplete)" : "")")
            if page.incomplete {
                listNote = String(localized: "一覧の一部が届きませんでした。古い動画が抜けているかもしれません。")
            }
            listState = .loaded
            loadThumbnails()
        } catch is CancellationError {
            if case .loading = listState { listState = .idle }
        } catch {
            log("media: list failed \(error.localizedDescription)")
            listState = .failed(error.localizedDescription)
        }
    }

    /// 再生モードに入る。返事は「受け取った」だけなので、0x02/0x80 の bit 30 で確かめる(Pocket 4 は 2 回目で入ることがある)
    private func enterPlayback(_ link: OsmoDatalink) async -> Bool {
        if inPlayback {
            holdsPlayback = true
            return true
        }
        holdsPlayback = true  // 入るあいだもライブビューのキーフレーム要求を止める
        enteredPlayback = true
        for attempt in 1...3 {
            playbackReply = nil
            log("media: send 0x02/0x0C enter #\(attempt)")
            link.sendCommand(OsmoMediaCommands.playback(enter: true))
            for _ in 0..<9 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
                if inPlayback {
                    log("media: playback confirmed (attempt \(attempt))")
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        if inPlayback { return true }
        // OpenCine と同じく、返事が 00 なら入ったものとして扱う(0x02/0x80 が届いていない場合)
        if let reply = playbackReply, reply.first == 0x00 {
            log("media: playback reply ok, bit 30 not seen")
            return true
        }
        // Pocket 3 は E0 を返して入らない。最新のページは再生モードなしでも読める
        log("media: playback not confirmed (\(playbackReply.map { OsmoBluetoothLink.hex($0) } ?? "no reply")); listing newest page anyway")
        holdsPlayback = false
        enteredPlayback = false
        return false
    }

    private struct Page {
        var files: [OsmoMediaFile]
        var incomplete: Bool
    }

    /// SD(番号 1)→ きっかけ → 本体(番号 2)の順に頼み、0x00/0x27 を集める。全体で 12 秒まで
    private func queryNewestPage(_ link: OsmoDatalink, retryEmptySD: Bool) async throws -> Page {
        collector.begin()
        defer { collector.end() }
        let deadline = Date().addingTimeInterval(12)
        link.sendCommand(OsmoMediaCommands.list(counter: OsmoMediaCommands.sdCounter, cursor: OsmoMediaCommands.newestSD))
        try await collect(counter: OsmoMediaCommands.sdCounter, floor: 0.8, idle: 1, deadline: deadline)
        link.sendCommand(OsmoMediaCommands.trigger())
        try await collect(counter: nil, floor: 0.4, idle: 0.2, deadline: deadline)
        link.sendCommand(OsmoMediaCommands.list(counter: OsmoMediaCommands.internalCounter, cursor: OsmoMediaCommands.newestInternal))
        try await collect(counter: OsmoMediaCommands.internalCounter, floor: 0.8, idle: 1, deadline: deadline)
        if retryEmptySD, collector.bytes(counter: OsmoMediaCommands.sdCounter).isEmpty, Date() < deadline {
            // SD がまだ準備できていなかったときのために 1 回だけ頼み直す(OpenCine と同じ)
            collector.reset(counter: OsmoMediaCommands.sdCounter)
            link.sendCommand(OsmoMediaCommands.list(counter: OsmoMediaCommands.sdCounter, cursor: OsmoMediaCommands.newestSD))
            try await collect(counter: OsmoMediaCommands.sdCounter, floor: 0.8, idle: 1, deadline: deadline)
            link.sendCommand(OsmoMediaCommands.trigger())
            try await collect(counter: OsmoMediaCommands.sdCounter, floor: 0.4, idle: 1, deadline: deadline)
        }
        // まだ流れている答えがあれば、終わりの印(4A 03)が来るまで待つ(2 つの保存先で 4.5 秒かかる機種がある)
        var lastCount = collector.chunkCount(nil)
        var lastChange = Date()
        while !collector.allObservedClosed, Date() < deadline, Date().timeIntervalSince(lastChange) < 1.5 {
            try await Task.sleep(for: .milliseconds(50))
            let count = collector.chunkCount(nil)
            if count != lastCount { lastCount = count; lastChange = Date() }
        }
        guard collector.hasResponse else { throw OsmoMediaError.noAnswer }
        let sd = collector.bytes(counter: OsmoMediaCommands.sdCounter)
        let internalBytes = collector.bytes(counter: OsmoMediaCommands.internalCounter)
        let merged = collector.merged()
        log("media: answer sd \(sd.count) B, internal \(internalBytes.count) B, all \(merged.count) B")
        let files = OsmoMediaManifest.decodeStores(sd: sd, internalStore: internalBytes, merged: merged)
        let incomplete = OsmoMediaManifest.isIncomplete(sd) || OsmoMediaManifest.isIncomplete(internalBytes)
        return Page(files: files, incomplete: incomplete)
    }

    /// 1 つの答えを待つ。終わりの印が来るか、floor 秒たって idle 秒新しい塊が来なければ次へ
    private func collect(counter: UInt8?, floor: TimeInterval, idle: TimeInterval, deadline: Date) async throws {
        let start = Date()
        var lastChange = start
        var lastCount = collector.chunkCount(counter)
        while true {
            try Task.checkCancellation()
            let now = Date()
            if now >= deadline { return }
            if let counter, now.timeIntervalSince(start) >= floor, collector.didEnd(counter) { return }
            try await Task.sleep(for: .milliseconds(50))
            let count = collector.chunkCount(counter)
            if count != lastCount {
                lastCount = count
                lastChange = Date()
            }
            let after = Date()
            if after.timeIntervalSince(start) >= floor, after.timeIntervalSince(lastChange) >= idle { return }
        }
    }

    // MARK: サムネイル

    private func loadThumbnails() {
        thumbTask?.cancel()
        let targets = Array(files.prefix(40))
        thumbTask = Task { [weak self] in
            for file in targets {
                guard !Task.isCancelled, let self else { return }
                if self.thumbnails[file.id] != nil { continue }
                // ダウンロード中は帯域をゆずる
                while self.isDownloading, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if let image = await Self.fetchThumbnail(file) {
                    self.thumbnails[file.id] = image
                }
            }
        }
    }

    nonisolated private static func fetchThumbnail(_ file: OsmoMediaFile) async -> UIImage? {
        for storage in [file.storage, file.storage == 0 ? 1 : 0] {
            guard let url = OsmoMediaHTTP.url(storage: storage, path: file.thumbPath) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let result = try? await OsmoMediaHTTP.thumbnailSession.data(for: request) else { return nil }
            guard (result.1 as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: result.0) else { continue }
            return await image.byPreparingThumbnail(ofSize: CGSize(width: 240, height: 135)) ?? image
        }
        return nil
    }

    // MARK: 取り込み

    /// 選んだ動画をダウンロードする(1 本ずつ)。途中のファイル(.part)があれば続きから
    func download(_ file: OsmoMediaFile) {
        guard downloadTask == nil, link != nil else { return }
        let part = Self.partURL(for: file)
        let already = Self.fileSize(part)
        if file.sizeBytes > 0 {
            let need = Int64(file.sizeBytes > already ? file.sizeBytes - already : 0) + 300_000_000
            if let free = Self.freeSpace(), free < need {
                downloadState = .failed(OsmoMediaError.noSpace.localizedDescription)
                return
            }
        }
        thumbTask?.cancel()
        bytesPerSecond = nil
        speedSample = nil
        downloadState = .downloading(fileID: file.id, received: already, total: file.sizeBytes > 0 ? file.sizeBytes : nil)
        IdleTimerGuard.set(true, for: "osmo-media")
        log("media: download \(file.path) storage \(file.storage)\(file.storageKnown ? "" : "?") from \(already) B")
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.performDownload(file)
                self.log("media: download done \(url.lastPathComponent) \(Self.fileSize(url)) B")
                self.downloadState = .finished(url)
            } catch is CancellationError {
                self.log("media: download cancelled (partial kept)")
                self.downloadState = .idle
            } catch {
                self.log("media: download failed \(error.localizedDescription)")
                self.downloadState = .failed(error.localizedDescription)
            }
            IdleTimerGuard.set(false, for: "osmo-media")
            self.downloadTask = nil
        }
    }

    /// 「やめる」。途中のファイルは残す(次に同じ動画をタップすると続きから)
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// 終わったファイルを受け取る(このあとは取り込み側が消す)
    func takeFinishedDownload() -> URL? {
        guard case .finished(let url) = downloadState else { return nil }
        downloadState = .idle
        return url
    }

    func clearDownloadMessage() {
        if case .failed = downloadState { downloadState = .idle }
    }

    private func performDownload(_ file: OsmoMediaFile) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let part = Self.partURL(for: file)
        let tagURL = part.appendingPathExtension("etag")
        var etag = try? String(contentsOf: tagURL, encoding: .utf8)
        var knownTotal: UInt64? = nil
        let storages = [file.storage, file.storage == 0 ? 1 : 0]
        var storageIndex = 0
        var failures = 0
        transfer: while true {
            try Task.checkCancellation()
            let offset = Self.fileSize(part)
            if let total = knownTotal, offset == total, total > 0 { break transfer }
            if let total = knownTotal, offset > total {
                // 長さが合わない(別のファイルの残り)→ 最初から
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: tagURL)
                etag = nil
                continue transfer
            }
            guard let url = OsmoMediaHTTP.url(storage: storages[storageIndex], path: file.path) else {
                throw OsmoMediaError.badResponse
            }
            var request = URLRequest(url: url)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                // ファイルが変わっていたら(ETag が違えば)全体が 200 で来るので、最初から書き直す
                if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-Range") }
            }
            let fileID = file.id
            let receiver = OsmoMediaRangeRequest(fileURL: part, offset: offset) { [weak self] received, total in
                Task { @MainActor in self?.applyProgress(fileID: fileID, received: received, total: total) }
            }
            do {
                // 20 秒なにも届かなければ切って、続きから頼み直す
                let result = try await receiver.run(request, configuration: OsmoMediaHTTP.configuration(requestTimeout: 20))
                if let tag = result.etag, !tag.isEmpty, tag != etag {
                    etag = tag
                    try? tag.write(to: tagURL, atomically: true, encoding: .utf8)
                }
                if let total = result.total { knownTotal = total }
                if knownTotal == nil {
                    // 長さを言わない応答(lighttpd ではふつう無い)。最後まで来たものとして扱う
                    log("media: no length in response, accept \(result.fileSize) B")
                    break transfer
                }
                if let total = knownTotal, result.fileSize == total { break transfer }
                // 途中で切れた(Osmo Nano では 760MB 付近で切れる記録がある)→ 続きから
                log("media: stream ended at \(result.fileSize) of \(knownTotal.map { String($0) } ?? "?"), resume")
                failures = result.fileSize > offset ? 1 : failures + 1
            } catch is CancellationError {
                throw CancellationError()
            } catch OsmoMediaError.httpStatus(let code) where code == 404 && offset == 0 {
                if storageIndex == 0 {
                    // 保存先の推測が外れた。もう一方の storage で試す
                    log("media: 404 on storage \(storages[0]), try storage \(storages[1])")
                    storageIndex = 1
                    continue transfer
                }
                throw OsmoMediaError.notFound
            } catch OsmoMediaError.httpStatus(let code) where code == 416 {
                // 頼んだ位置がファイルの外(残りが別のファイルのもの)→ 最初から
                log("media: 416, restart from 0")
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: tagURL)
                etag = nil
                failures += 1
            } catch {
                // 404 / 500 も長い転送の途中では一時的なことがある(Osmosis の観察)。間をおいて続きから
                let after = Self.fileSize(part)
                log("media: attempt failed at \(after) B: \(error.localizedDescription)")
                failures = after > offset ? 1 : failures + 1
            }
            if failures > 6 { throw OsmoMediaError.gaveUp }
            try await Task.sleep(for: .seconds(Double(min(8, 1 << min(failures, 3)))))
        }
        // 終わったら .part を元の名前に変える(同じ名前の古いファイルがあれば消す)
        let final = Self.directory.appendingPathComponent(Self.safeName(file))
        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
        try? fm.removeItem(at: tagURL)
        return final
    }

    private func applyProgress(fileID: String, received: UInt64, total: UInt64?) {
        guard case .downloading(let id, _, let oldTotal) = downloadState, id == fileID else { return }
        downloadState = .downloading(fileID: id, received: received, total: total ?? oldTotal)
        let now = Date()
        if let sample = speedSample {
            let dt = now.timeIntervalSince(sample.at)
            if dt >= 1 {
                if received >= sample.bytes {
                    bytesPerSecond = Double(received - sample.bytes) / dt
                }
                speedSample = (now, received)
            }
        } else {
            speedSample = (now, received)
        }
    }

    // MARK: 閉じる

    /// 画面を閉じたとき: 再生モードを抜けて、ライブビューに戻す
    func close() {
        loadTask?.cancel(); loadTask = nil
        loadToken = nil
        thumbTask?.cancel(); thumbTask = nil
        if case .loading = listState { listState = .idle }
        guard holdsPlayback || enteredPlayback else { return }
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            await self?.leavePlayback()
            self?.leaveTask = nil
        }
    }

    private func leavePlayback() async {
        guard let link else {
            holdsPlayback = false
            enteredPlayback = false
            return
        }
        for attempt in 1...3 {
            log("media: send 0x02/0x0C exit #\(attempt)")
            link.sendCommand(OsmoMediaCommands.playback(enter: false))
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if !inPlayback { break }
            }
            if !inPlayback { break }
        }
        if inPlayback { log("media: camera still reports playback") }
        try? await Task.sleep(for: .milliseconds(180))
        // 途中でまた開かれた(新しい読み込みが再生モードを持っている)ときは何もしない
        guard !Task.isCancelled else { return }
        holdsPlayback = false
        enteredPlayback = false
        guard self.link != nil else { return }
        onReturnToLive?()
    }

    // MARK: ファイル

    nonisolated static func safeName(_ file: OsmoMediaFile) -> String {
        let name = file.filename.replacingOccurrences(of: "/", with: "_")
        return name.isEmpty ? "Osmo.MP4" : name
    }

    nonisolated static func partURL(for file: OsmoMediaFile) -> URL {
        directory.appendingPathComponent(safeName(file) + ".part")
    }

    nonisolated static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    nonisolated static func freeSpace() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 2 日より前の残り(取り込まなかったファイル・途中のファイル)を消す
    nonisolated static func cleanUpOldFiles() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-2 * 24 * 3600)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < limit { try? fm.removeItem(at: item) }
        }
    }

    private func log(_ s: String) { onLog?(s) }
}

// MARK: - 画面

enum OsmoMediaBrowserMode: String, Identifiable {
    /// 一覧から選ぶ
    case browse
    /// 一番新しい動画をすぐに取り込む(カメラの録画を止めた直後)
    case newest

    var id: String { rawValue }
}

struct OsmoMediaBrowserView: View {
    let library: OsmoMediaLibrary
    let mode: OsmoMediaBrowserMode
    /// ダウンロードが終わったファイル(このあとは受け取った側が取り込んで消す)
    let onDownloaded: (URL) -> Void

    @State private var autoStarted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            statusSection
            downloadSection
            if library.listState == .loaded {
                Section {
                    if library.files.isEmpty {
                        Text("カメラに動画が見つかりませんでした")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.files) { file in
                        row(file)
                    }
                } header: {
                    Text("新しい順")
                } footer: {
                    Text("カメラに保存された元のファイルを、そのままの画質で取り込みます。大きいファイルは時間がかかるので、終わるまでこの画面を開いたままにしてください。")
                }
            }
        }
        .navigationTitle(Text("カメラの動画"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.refresh()
                } label: {
                    Label("読み直す", systemImage: "arrow.clockwise")
                }
                .disabled(library.isLoading || library.isDownloading)
            }
        }
        .interactiveDismissDisabled(library.isDownloading)
        .task {
            OsmoMediaLibrary.cleanUpOldFiles()
            library.clearDownloadMessage()
            // 開くたびに読み直す(閉じると再生モードを抜けているので、入り直してから取り込む)
            if !library.isLoading { library.refresh() }
        }
        .onChange(of: library.listState) { _, _ in
            startNewestIfNeeded()
        }
        .onChange(of: library.downloadState) { _, newState in
            if case .finished = newState, let url = library.takeFinishedDownload() {
                onDownloaded(url)
            }
        }
        .onDisappear {
            library.cancelDownload()
            library.close()
        }
    }

    // MARK: 部品

    @ViewBuilder
    private var statusSection: some View {
        switch library.listState {
        case .idle:
            EmptyView()
        case .loading(let message):
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(verbatim: message)
                }
            } footer: {
                Text("一覧を読むあいだ、カメラは再生モードになり、ライブビューは止まります。閉じると戻ります。")
            }
        case .loaded:
            if let note = library.listNote {
                Section {
                    Label {
                        Text(verbatim: note)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            Section {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
                Button("もう一度読む") { library.refresh() }
            }
        }
    }

    @ViewBuilder
    private var downloadSection: some View {
        switch library.downloadState {
        case .idle, .finished:
            EmptyView()
        case .downloading(let fileID, let received, let total):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: library.files.first(where: { $0.id == fileID })?.filename ?? "")
                        .font(.subheadline)
                    if let total, total > 0 {
                        ProgressView(value: Double(min(received, total)), total: Double(total))
                    } else {
                        ProgressView()
                    }
                    Text(verbatim: Self.progressText(received: received, total: total, speed: library.bytesPerSecond))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    library.cancelDownload()
                } label: {
                    Label("やめる", systemImage: "xmark.circle")
                }
            } header: {
                Text("取り込んでいます")
            } footer: {
                Text("やめても、もう一度タップすると続きから取り込みます。")
            }
        case .failed(let message):
            Section {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
            } footer: {
                Text("もう一度タップすると、続きから取り込みます。")
            }
        }
    }

    private func row(_ file: OsmoMediaFile) -> some View {
        Button {
            library.download(file)
        } label: {
            HStack(spacing: 12) {
                thumbnail(file)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.dateText(file))
                        .foregroundStyle(.primary)
                    Text(verbatim: Self.detailText(file))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if case .downloading(let id, _, _) = library.downloadState, id == file.id {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .disabled(library.isDownloading || library.isLoading)
    }

    private func thumbnail(_ file: OsmoMediaFile) -> some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image = library.thumbnails[file.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// 一番新しい動画を自動で取り込む(newest のときだけ、1 回だけ)
    private func startNewestIfNeeded() {
        guard mode == .newest, !autoStarted, library.listState == .loaded, !library.isDownloading,
              let newest = library.files.first else { return }
        autoStarted = true
        library.download(newest)
    }

    // MARK: 文字(数字だけなので翻訳しない)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)  // カメラの時計のまま
        f.setLocalizedDateFormatFromTemplate("MMMdHHmmss")
        return f
    }()

    static func dateText(_ file: OsmoMediaFile) -> String {
        guard let date = file.captureDate else { return file.filename }
        return dateFormatter.string(from: date)
    }

    static func detailText(_ file: OsmoMediaFile) -> String {
        var parts: [String] = []
        if file.durationSeconds > 0 {
            let s = file.durationSeconds
            parts.append(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                                   : String(format: "%d:%02d", s / 60, s % 60))
        }
        if let d = file.dimensions { parts.append("\(d.width)×\(d.height)") }
        if let fps = file.fps { parts.append("\(fps)fps") }
        if file.sizeBytes > 0 { parts.append(bytes(file.sizeBytes)) }
        return parts.isEmpty ? file.filename : parts.joined(separator: " · ")
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func progressText(received: UInt64, total: UInt64?, speed: Double?) -> String {
        var text = bytes(received)
        if let total, total > 0 { text += " / " + bytes(total) }
        if let speed, speed > 0 { text += "  " + bytes(UInt64(speed)) + "/s" }
        return text
    }
}
#endif
