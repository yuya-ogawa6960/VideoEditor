import Foundation
import AVFoundation
import UIKit
import Observation

// =====================================================================
// カメラ録画(AVCaptureSession + AVCaptureMovieFileOutput)
// - 1080p(30fps / 60fps)で一時フォルダ(CameraRecorder.temporaryDirectory)に .mov を保存する。
//   「使う」で呼ばれた側が Media フォルダへ取り込んで、一時ファイルを消す
// - 前後カメラの切り替え・ライト(後ろカメラ)・タップでピント・向きに合わせた回転
// - セッションの操作はすべて sessionQueue で行い、状態の更新はメインスレッドで行う
// - 電話・ほかのアプリのカメラ使用などで中断されたら isInterrupted を立て、録画中なら録画を終えて onFinished で知らせる
// メインスレッドから呼ぶこと(SwiftUI のボタン操作からの利用を想定)。
// Info.plist に NSCameraUsageDescription と NSMicrophoneUsageDescription が必要。
// =====================================================================

enum CameraRecorderError: LocalizedError {
    case permissionDenied
    case cameraUnavailable
    case sessionFailed(String)
    case recorderFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "カメラの使用が許可されていません。設定アプリでこのアプリの「カメラ」を許可してください。")
        case .cameraUnavailable:
            return String(localized: "この端末ではカメラを使えません。")
        case .sessionFailed(let detail):
            return String(localized: "カメラを開始できませんでした: \(detail)")
        case .recorderFailed(let detail):
            return String(localized: "録画を開始できませんでした: \(detail)")
        }
    }
}

@Observable
final class CameraRecorder {
    /// カメラが動いている(プレビューが出ている)
    private(set) var isRunning: Bool = false
    /// 録画中
    private(set) var isRecording: Bool = false
    /// 録画の経過秒
    private(set) var elapsed: Double = 0
    /// いま使っているカメラ(前 / 後ろ)
    private(set) var position: AVCaptureDevice.Position = .back
    /// いまのカメラにライトがあるか(前カメラは無い)
    private(set) var hasTorch: Bool = false
    private(set) var isTorchOn: Bool = false
    /// 電話・ほかのアプリのカメラ使用などで止められている間 true
    private(set) var isInterrupted: Bool = false
    private(set) var frameRate: CameraFrameRate = .fps30
    /// 直近に録画したファイル
    private(set) var lastRecordingURL: URL?
    /// カメラを開始できなかったときの説明
    private(set) var startErrorMessage: String?
    /// いま撮ると動画がどちら向きで保存されるか(端末の持ち方から決まる。90 / 270 なら縦、0 / 180 なら横)
    private(set) var captureRotationAngle: CGFloat = 90

    /// 縦向きに持っている(撮った動画が縦になる)
    var isPortraitCapture: Bool {
        captureRotationAngle == 90 || captureRotationAngle == 270
    }

    /// 録画が終わったときに呼ばれる(stop でも中断でも)。url は保存したファイル(使えなければ nil)。メインスレッドで呼ばれる
    @ObservationIgnored var onFinished: ((URL?, Error?) -> Void)?

    /// プレビュー(CameraPreviewView)がつなぐセッション
    @ObservationIgnored let session = AVCaptureSession()

    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "VideoEditor.CameraRecorder.session")
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    /// sessionQueue でだけ触る
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var audioInput: AVCaptureDeviceInput?
    @ObservationIgnored private var isConfigured = false
    /// メインスレッドでだけ触る(回転の計算とピント合わせに使う)
    @ObservationIgnored private var activeDevice: AVCaptureDevice?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// AVCaptureMovieFileOutput の delegate(CameraRecorder は NSObject ではないためここで受ける)
    private let delegateProxy = MovieOutputDelegateProxy()

    /// 録画の一時フォルダ(取り込んだら消す。残っていても次に開いたときに片づける)
    static var temporaryDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CameraRecordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() {
        delegateProxy.owner = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: .main) { [weak self] _ in
            self?.isInterrupted = true
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: .main) { [weak self] _ in
            self?.isInterrupted = false
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: .main) { [weak self] notification in
            guard let self else { return }
            // メディアサービスが再起動したときは、動いていたセッションを立て直す
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset, self.isRunning {
                let session = self.session
                self.sessionQueue.async {
                    if !session.isRunning { session.startRunning() }
                }
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
        rotationObservations.removeAll()
        let session = self.session
        let output = self.movieOutput
        sessionQueue.async {
            if output.isRecording { output.stopRecording() }
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - 権限

    static var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// カメラの権限を要求する(未決定ならダイアログ表示)。マイクは断られても録画はできる(音なし)ので、聞くだけ
    func requestPermissions() async -> Bool {
        let camera: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera = true
        case .notDetermined:
            camera = await AVCaptureDevice.requestAccess(for: .video)
        default:
            camera = false
        }
        guard camera else { return false }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return true
    }

    // MARK: - 開始 / 停止

    /// カメラを開始する(権限は先に requestPermissions で取っておく)。失敗したら startErrorMessage に説明が入る
    func start(position: AVCaptureDevice.Position, frameRate: CameraFrameRate) {
        guard !isRunning else { return }
        guard Self.cameraAuthorized else {
            startErrorMessage = CameraRecorderError.permissionDenied.errorDescription
            return
        }
        self.position = position
        self.frameRate = frameRate
        startErrorMessage = nil
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var failure: String?
            var device: AVCaptureDevice?
            do {
                device = try self.configureIfNeeded(position: position, frameRate: frameRate)
            } catch {
                failure = error.localizedDescription
            }
            if failure == nil {
                session.startRunning()
                if !session.isRunning {
                    failure = CameraRecorderError.sessionFailed(String(localized: "カメラが応答しません")).errorDescription
                }
            }
            let torch = device?.hasTorch ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let failure {
                    self.isRunning = false
                    self.startErrorMessage = failure
                    return
                }
                self.isRunning = true
                self.hasTorch = torch
                self.isTorchOn = false
                self.activeDevice = device
                self.applyPreviewSettings()
                self.rebuildRotationCoordinator()
            }
        }
    }

    /// カメラを止める(録画中なら録画も止める。シートを閉じるときに呼ぶ)
    func stop() {
        stopTimer()
        rotationObservations.removeAll()
        rotationCoordinator = nil
        isRunning = false
        isRecording = false
        isTorchOn = false
        let session = self.session
        let output = self.movieOutput
        sessionQueue.async { [weak self] in
            if output.isRecording { output.stopRecording() }
            if session.isRunning { session.stopRunning() }
            self?.turnOffTorchOnQueue()
            DispatchQueue.main.async {
                Self.restorePlaybackSession()
            }
        }
    }

    // MARK: - カメラの設定

    /// 前 / 後ろを切り替える(録画中は切り替えない)
    func switchCamera() {
        guard isRunning, !isRecording else { return }
        let next: AVCaptureDevice.Position = (position == .back) ? .front : .back
        let frameRate = self.frameRate
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.turnOffTorchOnQueue()
            session.beginConfiguration()
            let device = self.replaceVideoInput(position: next, frameRate: frameRate)
            session.commitConfiguration()
            let torch = device?.hasTorch ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if device != nil {
                    self.position = next
                }
                self.hasTorch = torch
                self.isTorchOn = false
                self.activeDevice = device ?? self.activeDevice
                self.applyPreviewSettings()
                self.rebuildRotationCoordinator()
            }
        }
    }

    /// フレームレートを変える(録画中は変えない)
    func setFrameRate(_ rate: CameraFrameRate) {
        guard rate != frameRate, !isRecording else { return }
        frameRate = rate
        guard isRunning else { return }
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            session.beginConfiguration()
            Self.applyFrameRate(rate, to: device)
            session.commitConfiguration()
        }
    }

    /// ライトのオン / オフ(後ろカメラだけ)
    func toggleTorch() {
        guard isRunning, hasTorch else { return }
        let turnOn = !isTorchOn
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device, device.hasTorch else { return }
            var result = false
            do {
                try device.lockForConfiguration()
                if turnOn, device.isTorchModeSupported(.on), device.isTorchAvailable {
                    device.torchMode = .on
                    result = true
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                result = false
            }
            DispatchQueue.main.async { [weak self] in
                self?.isTorchOn = result
            }
        }
    }

    /// プレビューの座標(タップした位置)にピントと露出を合わせる
    func focus(atLayerPoint point: CGPoint) {
        guard isRunning, let previewLayer else { return }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                // ピントを合わせられない機種(前カメラなど)では何もしない
            }
        }
    }

    // MARK: - プレビュー

    /// プレビューの層をつなぐ(CameraPreviewView の makeUIView から)
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspect
        applyPreviewSettings()
        rebuildRotationCoordinator()
    }

    /// 前カメラのプレビューだけ鏡にする(録画は鏡にしない)
    private func applyPreviewSettings() {
        guard let connection = previewLayer?.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
        if let coordinator = rotationCoordinator {
            applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        } else if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// 端末の持ち方からプレビューと録画の回転を決める(カメラを切り替えるたびに作り直す)
    private func rebuildRotationCoordinator() {
        rotationObservations.removeAll()
        guard let device = activeDevice else {
            rotationCoordinator = nil
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { [weak self] in
                    self?.applyPreviewRotation(angle)
                }
            }
        )
        rotationObservations.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async { [weak self] in
                    self?.captureRotationAngle = angle
                }
            }
        )
    }

    // MARK: - 録画

    /// 録画を始める(ファイル名: カメラ yyyy-MM-dd HH.mm.ss.mov)。始まったら isRecording が true になる
    func startRecording() {
        guard isRunning, !isRecording, !movieOutput.isRecording else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Self.temporaryDirectory.appendingPathComponent("カメラ \(formatter.string(from: Date())).mov")
        let angle = captureRotationAngle
        let output = self.movieOutput
        let proxy = self.delegateProxy
        elapsed = 0
        lastRecordingURL = nil
        sessionQueue.async {
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            try? FileManager.default.removeItem(at: url)
            output.startRecording(to: url, recordingDelegate: proxy)
        }
    }

    /// 録画を止める。保存できたら onFinished に URL が渡る
    func stopRecording() {
        guard isRecording || movieOutput.isRecording else { return }
        let output = self.movieOutput
        sessionQueue.async {
            if output.isRecording { output.stopRecording() }
        }
    }

    /// 直近の録画ファイルを消す(撮り直し)
    func discardLastRecording() {
        guard let url = lastRecordingURL else { return }
        try? FileManager.default.removeItem(at: url)
        lastRecordingURL = nil
    }

    /// 取り込まれなかった古い一時ファイルを消す(次に開いたときの片づけ)。
    /// 直前に撮った動画はまだプロジェクトへコピー中のことがあるので、10 分より古いものだけ消す
    static func cleanUpTemporaryFiles() {
        let dir = temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-10 * 60)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified < limit else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - delegate から(メインスレッド)

    fileprivate func recordingDidStart() {
        isRecording = true
        elapsed = 0
        startTimer()
    }

    fileprivate func recordingDidFinish(url: URL, error: Error?) {
        stopTimer()
        isRecording = false
        // 中断などで止まっても、ファイルが書き終わっていれば使える
        var usable = true
        if let error {
            let info = (error as NSError).userInfo
            usable = (info[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        if usable, FileManager.default.fileExists(atPath: url.path) {
            let seconds = CMTimeGetSeconds(movieOutput.recordedDuration)
            if seconds.isFinite { elapsed = max(elapsed, seconds) }
            lastRecordingURL = url
            onFinished?(url, nil)
        } else {
            try? FileManager.default.removeItem(at: url)
            lastRecordingURL = nil
            onFinished?(nil, error)
        }
    }

    // MARK: - 内部(sessionQueue)

    /// 初回だけ入力・出力をそろえる。使うカメラを返す
    private func configureIfNeeded(position: AVCaptureDevice.Position, frameRate: CameraFrameRate) throws -> AVCaptureDevice? {
        if isConfigured {
            return videoInput?.device
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        guard let device = replaceVideoInput(position: position, frameRate: frameRate)
                ?? replaceVideoInput(position: position == .back ? .front : .back, frameRate: frameRate) else {
            throw CameraRecorderError.cameraUnavailable
        }
        // マイク(断られていれば付かない。音なしで録画できる)
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        guard session.canAddOutput(movieOutput) else {
            throw CameraRecorderError.sessionFailed(String(localized: "録画の出力を用意できません"))
        }
        session.addOutput(movieOutput)
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        isConfigured = true
        return device
    }

    /// 映像の入力を position のカメラに付け替える(beginConfiguration の中で呼ぶ)。付けられなければ nil
    private func replaceVideoInput(position: AVCaptureDevice.Position, frameRate: CameraFrameRate) -> AVCaptureDevice? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let old = videoInput
        if let old {
            session.removeInput(old)
            videoInput = nil
        }
        guard session.canAddInput(input) else {
            // 元に戻す
            if let old, session.canAddInput(old) {
                session.addInput(old)
                videoInput = old
            }
            return nil
        }
        session.addInput(input)
        videoInput = input
        Self.applyFrameRate(frameRate, to: device)
        return device
    }

    /// 1080p のまま fps を合わせる。60fps は対応する形式があるときだけ(無ければそのまま)
    private static func applyFrameRate(_ rate: CameraFrameRate, to device: AVCaptureDevice) {
        let fps = Double(rate.rawValue)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if !supports(fps: fps, format: device.activeFormat) {
                let candidate = device.formats.first { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    guard dims.width == 1920, dims.height == 1080 else { return false }
                    // 8 bit(HDR でない)の形式に限る
                    guard CMFormatDescriptionGetMediaSubType(format.formatDescription)
                            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
                    return supports(fps: fps, format: format)
                }
                guard let candidate else { return }
                device.activeFormat = candidate
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rawValue))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            // 設定できなければ既定のまま
        }
    }

    private static func supports(fps: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
    }

    private func turnOffTorchOnQueue() {
        guard let device = videoInput?.device, device.hasTorch, device.torchMode != .off else { return }
        if (try? device.lockForConfiguration()) != nil {
            device.torchMode = .off
            device.unlockForConfiguration()
        }
    }

    // MARK: - 内部(メインスレッド)

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            let seconds = CMTimeGetSeconds(self.movieOutput.recordedDuration)
            if seconds.isFinite { self.elapsed = seconds }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 再生用カテゴリに戻す(AVCaptureSession が録画用に変えたものを、プレイヤーの再生に戻す。VoiceRecorder と同じ)
    private static func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }
}

/// AVCaptureMovieFileOutput の delegate を受けて CameraRecorder に渡す(CameraRecorder は NSObject ではないため)
private final class MovieOutputDelegateProxy: NSObject, AVCaptureFileOutputRecordingDelegate {
    weak var owner: CameraRecorder?

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { [weak self] in
            self?.owner?.recordingDidStart()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // delegate がどのスレッドで呼ばれるかは決まっていないので、メインスレッドで処理する
        DispatchQueue.main.async { [weak self] in
            self?.owner?.recordingDidFinish(url: outputFileURL, error: error)
        }
    }
}
