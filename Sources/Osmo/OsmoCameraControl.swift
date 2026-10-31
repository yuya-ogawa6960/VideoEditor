// =====================================================================
// OsmoCameraControl: Osmo Pocket 本体の SD カードへの録画を始める・止める(実験中・開発者向け)
//
// 命令と状態の読み方は OpenCine(https://github.com/erik-sutton95/OpenCine, commit dd77b69e)の
//   - Sources/OpenCineDJI/Commands.swift          recordStart / recordStop(`0x02/0x02` `[01]` / `[00]`)
//   - Sources/OpenCineDJI/CameraStatus+DJIWire.swift  CameraStatusDecoder の `0x02/0x80`(録画中ビット 0x80)
//   - Sources/OpenCineDJIApple/DjiAppleControlExchange.swift  命令はデータリンク(UDP)で送る・状態は約 1 秒遅れる
// と、OpenPocketCine の資料(handbook: protocol/commands.md、devices/pocket-4-pro/slow-motion.md、
// devices/pocket-3/media.md)による。
// Copyright 2026 Erik Sutton and OpenCine contributors. Apache License 2.0
// (docs/licenses/OpenCine-LICENSE.txt と docs/licenses/OpenCine-NOTICE.txt)。
// 変更点: この app 用に書き直し。録画の開始・停止と `0x02/0x80` の録画状態・経過・残り時間だけ。
//         写真・タイムラプス(Pocket 3 は 0x02/0x01)・モード切替は入れていない。
//
// DJI の公式 SDK や資料は使っていない(リバースエンジニアリングされた公開情報のみ)。
// **実機ではまだ一度も試していない**。docs/OsmoPocket.md の「録画の操作(調査)」を参照。
// =====================================================================

#if OSMO_LIVE
import Foundation
import Observation

@MainActor
@Observable
final class OsmoCameraControl {
    enum RecordingState: Equatable {
        /// まだ `0x02/0x80` が届いていない
        case unknown
        case idle
        case recording

        var label: String {
            switch self {
            case .unknown: return "録画状態: 不明"
            case .idle: return "停止中"
            case .recording: return "録画中"
            }
        }
    }

    /// カメラが `0x02/0x80` で知らせた録画状態(送った命令ではなく、カメラの報告だけで決める)
    private(set) var recordingState: RecordingState = .unknown
    /// 録画の経過秒(`0x02/0x80` の 29〜30 バイト目)。録画していないときの値は未確認
    private(set) var elapsedSeconds: Int?
    /// 残りの録画可能秒(`0x02/0x80` の 17〜20 バイト目)
    private(set) var remainingSeconds: Int?
    /// 撮影モードの生の値(`0x02/0x80` の 57 バイト目)。0x01 = Video。録画命令は Video 系のモード用
    private(set) var shootingModeRaw: UInt8?
    /// 命令を送ってから、カメラの返事か状態の変化を待っているあいだ true
    private(set) var isBusy = false
    /// 直近の結果(画面に出す短い文)
    private(set) var lastMessage: String?

    /// 録画状態が変わったとき(カメラの報告による)。true = 録画中
    @ObservationIgnored var onRecordingChanged: ((Bool) -> Void)?
    @ObservationIgnored var onLog: ((String) -> Void)?

    @ObservationIgnored private weak var link: OsmoDatalink?
    @ObservationIgnored private var pending: Task<Void, Never>?
    private struct Reply {
        var start: Bool
        var payload: [UInt8]
    }
    @ObservationIgnored private var lastReply: Reply?
    /// いま待っている命令(返事には開始・停止の区別が無いので、送った側で覚える)
    @ObservationIgnored private var pendingStart: Bool?

    /// データリンクが開いたら渡す(OsmoLiveMonitor が呼ぶ)
    func attach(_ link: OsmoDatalink) {
        self.link = link
    }

    /// 切断したら呼ぶ
    func detach() {
        pending?.cancel(); pending = nil
        link = nil
        isBusy = false
        recordingState = .unknown
        elapsedSeconds = nil
        remainingSeconds = nil
        shootingModeRaw = nil
        lastReply = nil
        pendingStart = nil
    }

    var isConnected: Bool { link != nil }

    // MARK: 録画

    /// `0x02/0x02` `[01]`。トグルではない(録画中に送るとカメラは `DF` を返す)
    func startRecording() { send(start: true) }

    /// `0x02/0x02` `[00]`
    func stopRecording() { send(start: false) }

    static func recordFrame(start: Bool) -> OsmoDuml.Frame {
        // 受け手はカメラ 0x01、flags 0x40(要求)。seq はデータリンクが送るときに振り直す
        .init(sender: OsmoDuml.senderApp, receiver: OsmoDuml.rxCamera, seq: 0,
              flags: OsmoDuml.flagRequest, cmdSet: 0x02, cmdId: 0x02, payload: [start ? 0x01 : 0x00])
    }

    private func send(start: Bool) {
        guard let link else {
            lastMessage = "カメラにつながっていません"
            return
        }
        guard !isBusy else { return }
        if let mode = shootingModeRaw, mode != 0x01 {
            // Video 以外(写真・タイムラプスなど)では別の命令のことがある。送るが記録しておく
            log(String(format: "record: shooting mode 0x%02X is not Video (0x01); 0x02/0x02 may be rejected", mode))
        }
        isBusy = true
        lastReply = nil
        pendingStart = start
        lastMessage = start ? "録画開始を送りました…" : "録画停止を送りました…"
        let want: RecordingState = start ? .recording : .idle
        log("record: send 0x02/0x02 [\(start ? "01" : "00")]")
        link.sendCommand(Self.recordFrame(start: start))

        pending?.cancel()
        pending = Task { [weak self] in
            // カメラの状態(0x02/0x80)は返事より約 1 秒遅れる。最長 4 秒待つ
            for tick in 1...20 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                if self.recordingState == want {
                    self.finish(start ? "録画中(カメラが報告)" : "停止しました(カメラが報告)")
                    return
                }
                if let r = self.lastReply, r.start == start, r.payload.first.map({ $0 != 0x00 }) == true {
                    // 0x00 以外 = 断られた(DF など)。録画中に開始を送っても DF
                    self.finish(String(format: "カメラが断りました(%@)", OsmoBluetoothLink.hex(r.payload)))
                    return
                }
                // Mimo も返事が無いと送り直していた(OpenPocketCine の Pocket 4 Pro の記録)。1.5 秒で 1 回だけ
                if tick == 8, self.lastReply == nil, let link = self.link {
                    self.log("record: no reply yet, resend once")
                    link.sendCommand(Self.recordFrame(start: start))
                }
            }
            guard let self, !Task.isCancelled else { return }
            if let r = self.lastReply, r.start == start {
                self.finish("返事は来ましたが、録画状態の報告が変わりません(\(OsmoBluetoothLink.hex(r.payload)))。カメラ本体で確認してください")
            } else {
                self.finish("カメラから返事がありません。カメラ本体で確認してください")
            }
        }
    }

    private func finish(_ message: String) {
        isBusy = false
        pendingStart = nil
        lastMessage = message
        log("record: \(message)")
    }

    // MARK: 受ける

    /// データリンクから届いたフレームのうち、録画に関係するものだけを先に選ぶ(データリンクのキューの上で呼んでよい)
    nonisolated static func isRelevant(_ frame: OsmoDuml.Frame) -> Bool {
        frame.cmdSet == 0x02 && (frame.cmdId == 0x80 || frame.cmdId == 0x02)
    }

    /// `isRelevant` を通ったフレーム(MainActor で呼ぶ)
    func handle(_ frame: OsmoDuml.Frame) {
        guard frame.cmdSet == 0x02 else { return }
        switch frame.cmdId {
        case 0x02 where frame.flags & 0x80 != 0:
            // 録画命令の返事。`00` = 受け付けた、`DF` = 断った(録画中にもう一度開始など)
            if let start = pendingStart { lastReply = Reply(start: start, payload: frame.payload) }
            log("record: reply 0x02/0x02 \(OsmoBluetoothLink.hex(frame.payload))")
        case 0x80:
            applyStatus(frame.payload)
        default:
            break
        }
    }

    /// `0x02/0x80`(カメラから勝手に届く状態)。u32-LE の flags の bit 7(0x80)= 録画中、
    /// bit 30 = 再生中。@17 u32 残り秒、@29 u16 経過秒、@57 撮影モード(OpenCine の CameraStatusDecoder と同じ位置)
    private func applyStatus(_ p: [UInt8]) {
        guard p.count >= 13 else { return }
        func u32(_ i: Int) -> UInt32 {
            UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
        }
        let flags = u32(0)
        let recording = (flags & 0x0000_0080) != 0
        let newState: RecordingState = recording ? .recording : .idle
        if p.count >= 21 {
            let remain = Int(u32(17))
            if (0...86_400).contains(remain) { remainingSeconds = remain }
        }
        if p.count >= 31 {
            elapsedSeconds = Int(UInt16(p[29]) | UInt16(p[30]) << 8)
        }
        if p.count >= 58 { shootingModeRaw = p[57] }
        if newState != recordingState {
            let first = recordingState == .unknown
            recordingState = newState
            log(String(format: "record: camera reports %@ (flags %08X)", recording ? "RECORDING" : "idle", flags))
            if !first || recording { onRecordingChanged?(recording) }
        }
    }

    private func log(_ s: String) { onLog?(s) }
}
#endif
