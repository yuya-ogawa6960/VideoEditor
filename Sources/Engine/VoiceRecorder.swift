import Foundation
import AVFoundation
import Observation

// =====================================================================
// ナレーション録音(AVAudioRecorder)
// - AAC / m4a / 48 kHz / モノラル を MediaStore.mediaDirectory に保存
// - 録音中は AVAudioSession を .playAndRecord(+スピーカー出力)にし、停止後 .playback に戻す
// - 50 ms ごとに averagePower を 0...1 の level に変換
// - 電話・Siri・エンコードエラーなどで止められたら、録音を終えて onInterrupted で知らせる
// - 出力先(イヤホンの抜き差し・Bluetooth)が変わるたびに headphoneConnected を更新
// メインスレッドから呼ぶこと(SwiftUI のボタン操作からの利用を想定)。
// Info.plist に NSMicrophoneUsageDescription が必要。
// =====================================================================

enum VoiceRecorderError: LocalizedError {
    case permissionDenied
    case alreadyRecording
    case sessionFailed(String)
    case recorderFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "マイクの使用が許可されていません。設定アプリでこのアプリの「マイク」を許可してください。")
        case .alreadyRecording:
            return String(localized: "すでに録音中です。")
        case .sessionFailed(let detail):
            return String(localized: "オーディオセッションを開始できませんでした: \(detail)")
        case .recorderFailed(let detail):
            return String(localized: "録音を開始できませんでした: \(detail)")
        }
    }
}

@Observable
final class VoiceRecorder {
    private(set) var isRecording: Bool = false
    /// 入力レベル(0...1、約 -60 dB ... 0 dB を線形にマップ)
    private(set) var level: Float = 0
    /// 録音経過秒
    private(set) var elapsed: Double = 0
    /// 直近に録音したファイル
    private(set) var lastRecordingURL: URL?
    /// イヤホン・ヘッドホンが出力先につながっているか(出力先が変わるたびに更新する)
    private(set) var headphoneConnected: Bool = VoiceRecorder.isHeadphoneConnected

    /// 録音中に、stop() を呼ぶ前にシステム側で止められたとき(電話・Siri・アラーム・エンコードエラーなど)に呼ばれる。
    /// 呼ばれた時点で録音は停止済み。引数は保存したファイル(残っていなければ nil)。メインスレッドで呼ばれる
    @ObservationIgnored var onInterrupted: ((URL?) -> Void)?

    /// レベル更新間隔(秒)
    private static let meterInterval: TimeInterval = 0.05
    /// level = 0 とみなす dB
    private static let meterFloorDB: Float = -60

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    /// AVAudioRecorder の delegate(AVAudioRecorder.delegate は weak なのでここで保持する)
    private let delegateProxy = RecorderDelegateProxy()

    init() {
        delegateProxy.owner = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began else { return }
            // 電話などで中断されたら録音を終了し(ファイルはそのまま残す)、ここまでの録音を知らせる
            guard self.isRecording else { return }
            let url = self.stop()
            self.onInterrupted?(url)
        }
        // イヤホンの抜き差し・Bluetooth の接続 / 切断を追う(理由は問わず、いまの出力先を読み直す)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.refreshHeadphoneConnected()
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        timer?.invalidate()
        recorder?.delegate = nil
        recorder?.stop()
    }

    // MARK: - 権限

    var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// マイク権限を要求する(未決定ならダイアログ表示)
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - 録音

    /// 録音を開始し、保存先 URL を返す(ファイル名: UUID_ナレーション yyyy-MM-dd HH.mm.ss.m4a)
    @discardableResult
    func start() throws -> URL {
        guard !isRecording else { throw VoiceRecorderError.alreadyRecording }
        guard hasPermission else { throw VoiceRecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            // Bluetooth イヤホンにも再生音を出せるようにする(マイクは本体のまま)
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            throw VoiceRecorderError.sessionFailed(error.localizedDescription)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fileName = "ナレーション \(formatter.string(from: Date())).m4a"
        let url = MediaStore.uniqueDestination(forFileName: fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            restorePlaybackSession()
            throw VoiceRecorderError.recorderFailed(error.localizedDescription)
        }
        newRecorder.isMeteringEnabled = true
        // エンコードエラーなどで録音機が自分で止まったことを知るため
        newRecorder.delegate = delegateProxy
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            newRecorder.delegate = nil
            restorePlaybackSession()
            throw VoiceRecorderError.recorderFailed(String(localized: "録音デバイスを開始できません"))
        }

        recorder = newRecorder
        isRecording = true
        level = 0
        elapsed = 0
        lastRecordingURL = url
        refreshHeadphoneConnected()
        startMeterTimer()
        return url
    }

    /// 録音を停止し、保存したファイルの URL を返す(録音していなければ nil)
    @discardableResult
    func stop() -> URL? {
        guard let current = recorder else { return nil }
        stopMeterTimer()
        // システムに止められた録音機の currentTime は 0 になることがあるので、メーターで測った値を下回らせない
        elapsed = max(elapsed, current.currentTime)
        // こちらから止めるときは delegate の「止まった」通知を受けない(予期しない停止と区別するため)
        current.delegate = nil
        current.stop()
        recorder = nil
        isRecording = false
        level = 0
        restorePlaybackSession()

        let url = current.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastRecordingURL = nil
            return nil
        }
        lastRecordingURL = url
        return url
    }

    /// 録音を中止してファイルを削除する
    func cancel() {
        guard let url = stop() else { return }
        try? FileManager.default.removeItem(at: url)
        lastRecordingURL = nil
    }

    // MARK: - 内部

    /// 録音機が stop() を呼ぶ前に止まった(エンコードエラー・空き容量不足など)。録音を終えて知らせる
    fileprivate func recorderDidStopUnexpectedly(_ stopped: AVAudioRecorder) {
        guard isRecording, recorder === stopped else { return }
        let url = stop()
        onInterrupted?(url)
    }

    private func refreshHeadphoneConnected() {
        let connected = Self.isHeadphoneConnected
        if headphoneConnected != connected {
            headphoneConnected = connected
        }
    }

    private func startMeterTimer() {
        stopMeterTimer()
        let t = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            self?.updateMeter()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopMeterTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)   // -160 ... 0 dB
        let floorDB = Self.meterFloorDB
        let normalized = (db - floorDB) / (0 - floorDB)
        level = min(max(normalized, 0), 1)
        elapsed = recorder.currentTime
    }

    /// イヤホン・ヘッドホン(有線 / Bluetooth / USB / AirPlay)が出力先につながっているか。
    /// つながっていないときにタイムラインを鳴らすと、スピーカーの音がマイクに入ってしまう。
    static var isHeadphoneConnected: Bool {
        let kinds: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                                                .usbAudio, .carAudio, .airPlay]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { kinds.contains($0.portType) }
    }

    /// 再生用カテゴリに戻す(プレイヤーの再生を妨げないよう非アクティブ化はしない)
    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }
}

/// AVAudioRecorder の delegate を受けて VoiceRecorder に渡す(VoiceRecorder は NSObject ではないため)
private final class RecorderDelegateProxy: NSObject, AVAudioRecorderDelegate {
    weak var owner: VoiceRecorder?

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // VoiceRecorder.stop() は delegate を外してから止めるので、ここに来るのはシステム側で止まったとき
        notifyStopped(recorder)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        notifyStopped(recorder)
    }

    private func notifyStopped(_ recorder: AVAudioRecorder) {
        // delegate がどのスレッドで呼ばれるかは決まっていないので、メインスレッドで処理する
        DispatchQueue.main.async { [weak self] in
            self?.owner?.recorderDidStopUnexpectedly(recorder)
        }
    }
}
