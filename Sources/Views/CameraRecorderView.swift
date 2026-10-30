import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Combine

// =====================================================================
// 「カメラで撮る」(全画面のシート・黒)。CameraRecorder で 1080p を録画し、TeleprompterOverlay を重ねる。
//   前後の切り替え・ライト・タップでピント・3 / 5 / 10 秒のカウントダウン(タップで飛ばせる)・30 / 60fps。
//   止めると 「使う」「撮り直す」の確認。「使う」は onUse に一時ファイルを渡す
//   (呼んだ側が「ファイル」からの追加と同じ道で Media フォルダへ取り込み、一時ファイルを消す)。
//   aspect はプロジェクトの比率(9:16 なら縦に、16:9 なら横に持つよう案内する。動画の向きは持ち方で決まる)。
// =====================================================================

struct CameraRecorderView: View {
    /// プロジェクトの比率(持ち方の案内に使う)
    let aspect: CanvasAspect
    /// 「使う」で呼ぶ(撮った動画の一時ファイル。呼ばれた側が取り込んで消す)
    let onUse: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = CameraRecorder()
    @State private var phase: Phase = .starting
    @State private var countdownRemaining = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var showScriptSheet = false
    @State private var errorMessage: String?
    /// タップでピントを合わせた位置(少しのあいだ枠を出す)
    @State private var focusPoint: CGPoint?
    @State private var focusHideTask: Task<Void, Never>?
    @State private var reviewPlayer: AVPlayer?
    /// 「使う」で渡した(閉じるときに一時ファイルを消さない)
    @State private var didUse = false
    /// 開始してしばらく経ってもプレビューが出ず、失敗の説明も無い(原因がわからない)
    @State private var startTimedOut = false
    @State private var startWatchTask: Task<Void, Never>?

    @AppStorage(TeleprompterSettingsKey.script) private var script = ""
    @AppStorage(TeleprompterSettingsKey.countdown) private var countdown: CameraCountdown = .three
    @AppStorage(TeleprompterSettingsKey.frameRate) private var frameRate: CameraFrameRate = .fps30
    @AppStorage(TeleprompterSettingsKey.usesFrontCamera) private var usesFrontCamera = false

    private enum Phase: Equatable {
        /// 権限を確かめている
        case starting
        /// カメラが許可されていない
        case denied
        /// プレビュー(録画中も含む)
        case live
        /// カウントダウン中
        case countdown
        /// 撮った動画の確認
        case review(URL)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .starting:
                ProgressView()
                    .tint(.white)
            case .denied:
                deniedView
            case .live, .countdown:
                liveView
            case .review(let url):
                reviewView(url)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await startCamera()
        }
        .onDisappear {
            closeCamera()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 画面を離れたらカウントダウンはやめる(録画中はセッションの中断で止まり、onFinished に来る)
            if newPhase != .active { cancelCountdown() }
        }
        .onChange(of: recorder.position) { _, position in
            usesFrontCamera = (position == .front)
        }
        // 使い方の統計: カメラ画面がどこまで進んだか(開いた → 動いた / 失敗 / 時間切れ → 閉じた)。原因を追うため
        .onChange(of: recorder.isRunning) { _, running in
            if running {
                startWatchTask?.cancel()
                startWatchTask = nil
                startTimedOut = false
                Analytics.shared.track("camera", ["step": "running",
                                                  "position": recorder.position == .front ? "front" : "back",
                                                  "fps": String(recorder.frameRate.rawValue)])
            }
        }
        .onChange(of: recorder.startErrorCode) { _, code in
            if let code {
                startWatchTask?.cancel()
                startWatchTask = nil
                Analytics.shared.track("camera", ["step": "failed", "code": code])
            }
        }
        .sheet(isPresented: $showScriptSheet) {
            TeleprompterScriptSheet()
        }
        .alert("お知らせ", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 開始 / 終了

    private func startCamera() async {
        Analytics.shared.track("camera", ["step": "open"])
        CameraRecorder.cleanUpTemporaryFiles()
        guard await recorder.requestPermissions() else {
            Analytics.shared.track("camera", ["step": "denied"])
            phase = .denied
            return
        }
        recorder.onFinished = { url, error in
            handleFinished(url: url, error: error)
        }
        recorder.start(position: usesFrontCamera ? .front : .back, frameRate: frameRate)
        phase = .live
        // 8 秒たってもプレビューが出ず、失敗の説明も無ければ、閉じてやり直せるように案内する
        startWatchTask?.cancel()
        startWatchTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !recorder.isRunning, recorder.startErrorCode == nil else { return }
            startTimedOut = true
            Analytics.shared.track("camera", ["step": "timeout"])
        }
    }

    private func closeCamera() {
        Analytics.shared.track("camera", ["step": "close", "used": didUse ? "1" : "0"])
        startWatchTask?.cancel()
        startWatchTask = nil
        cancelCountdown()
        focusHideTask?.cancel()
        recorder.onFinished = nil
        reviewPlayer?.pause()
        reviewPlayer = nil
        recorder.stop()
        if !didUse {
            recorder.discardLastRecording()
        }
        IdleTimerGuard.set(false, for: "camera")
    }

    // MARK: - プレビュー

    private var liveView: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(recorder: recorder)
                    .overlay {
                        if let focusPoint {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.yellow, lineWidth: 1.5)
                                .frame(width: 72, height: 72)
                                .position(focusPoint)
                                .allowsHitTesting(false)
                        }
                    }
                    .onTapGesture { location in
                        guard phase == .live, recorder.isRunning else { return }
                        recorder.focus(atLayerPoint: location)
                        showFocusMark(at: location)
                    }
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    TeleprompterOverlay(script: script, isScrolling: recorder.isRecording) {
                        showScriptSheet = true
                    }
                    .frame(height: script.isEmpty ? nil : geo.size.height * 0.36)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    Spacer(minLength: 0)
                    bottomBar
                }

                if recorder.isInterrupted {
                    statusCard(String(localized: "カメラを使えません(電話やほかのアプリが使っています)"))
                }
                if let message = recorder.startErrorMessage {
                    VStack(spacing: 12) {
                        statusCard(message)
                        Button("閉じる") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                } else if startTimedOut, !recorder.isRunning {
                    VStack(spacing: 12) {
                        statusCard(String(localized: "カメラが開きません。いったん閉じて、もう一度お試しください"))
                        Button("閉じる") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                if phase == .countdown {
                    countdownOverlay
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            roundButton("xmark", label: String(localized: "閉じる")) {
                dismiss()
            }
            .disabled(recorder.isRecording)
            Spacer()
            Menu {
                Picker("カウントダウン", selection: $countdown) {
                    ForEach(CameraCountdown.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
            } label: {
                pill(countdown == .none ? String(localized: "カウントなし") : countdown.displayName, systemImage: "timer")
            }
            .disabled(recorder.isRecording || phase == .countdown)
            Menu {
                Picker("画質", selection: Binding(get: { frameRate }, set: { rate in
                    frameRate = rate
                    recorder.setFrameRate(rate)
                })) {
                    ForEach(CameraFrameRate.allCases) { item in
                        Text(verbatim: item.displayName).tag(item)
                    }
                }
            } label: {
                pill(frameRate.shortName, systemImage: nil)
            }
            .disabled(recorder.isRecording || phase == .countdown)
            if recorder.hasTorch {
                roundButton(recorder.isTorchOn ? "bolt.fill" : "bolt.slash", label: String(localized: "ライト")) {
                    recorder.toggleTorch()
                }
            }
            roundButton("arrow.triangle.2.circlepath.camera", label: String(localized: "カメラを切り替え")) {
                recorder.switchCamera()
            }
            .disabled(recorder.isRecording || phase == .countdown)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let hint = framingHint {
                Text(hint)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }
            HStack(spacing: 6) {
                if recorder.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                }
                Text(verbatim: MediaTimeText.mmss(recorder.elapsed))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: Capsule())
            recordButton
        }
        .padding(.bottom, 24)
    }

    private var recordButton: some View {
        Button {
            EditorHaptics.tap()
            if recorder.isRecording {
                recorder.stopRecording()
            } else {
                beginCountdown()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 80, height: 80)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 8 : 33, style: .continuous)
                    .fill(Color.red)
                    .frame(width: recorder.isRecording ? 34 : 66, height: recorder.isRecording ? 34 : 66)
                    .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!recorder.isRunning || phase == .countdown || recorder.isInterrupted)
        .accessibilityLabel(recorder.isRecording ? String(localized: "録画を止める") : String(localized: "録画"))
    }

    /// プロジェクトの比率と持ち方が合っていないときの案内
    private var framingHint: String? {
        guard recorder.isRunning else { return nil }
        switch aspect {
        case .landscape16x9:
            return recorder.isPortraitCapture ? String(localized: "横向きに持つと 16:9 で撮れます") : nil
        case .portrait9x16, .portrait4x5:
            return recorder.isPortraitCapture ? nil : String(localized: "縦向きに持つと 9:16 で撮れます")
        case .square, .original:
            return nil
        }
    }

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Text(verbatim: "\(countdownRemaining)")
                    .font(.system(size: 140, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.25), value: countdownRemaining)
                Text("タップですぐ撮る")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Button("やめる") {
                    cancelCountdown()
                }
                .foregroundStyle(.white)
                .padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            skipCountdown()
        }
    }

    private func statusCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 32)
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func pill(_ text: String, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.black.opacity(0.45), in: Capsule())
    }

    private func showFocusMark(at point: CGPoint) {
        focusPoint = point
        focusHideTask?.cancel()
        focusHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { focusPoint = nil }
        }
    }

    // MARK: - カウントダウン / 録画

    private func beginCountdown() {
        guard recorder.isRunning, !recorder.isRecording, phase == .live else { return }
        let seconds = countdown.rawValue
        guard seconds > 0 else {
            startRecording()
            return
        }
        countdownRemaining = seconds
        phase = .countdown
        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                countdownRemaining = remaining
                EditorHaptics.tap()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                remaining -= 1
            }
            if Task.isCancelled { return }
            countdownTask = nil
            startRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if phase == .countdown { phase = .live }
    }

    /// カウントダウンの途中で(数字をタップして)すぐ撮り始める
    private func skipCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        startRecording()
    }

    private func startRecording() {
        phase = .live
        guard recorder.isRunning, !recorder.isRecording else { return }
        // 録画中は画面の自動ロックを止める
        IdleTimerGuard.set(true, for: "camera")
        recorder.startRecording()
    }

    /// 録画が終わった(止めた・中断された)。ファイルがあれば確認へ、無ければお知らせ
    private func handleFinished(url: URL?, error: Error?) {
        IdleTimerGuard.set(false, for: "camera")
        guard let url else {
            errorMessage = error?.localizedDescription ?? String(localized: "録画を保存できませんでした。")
            phase = .live
            return
        }
        // 確認のあいだはカメラを止める(再生用のオーディオに戻す)。撮り直すときにまた開く
        recorder.stop()
        let player = AVPlayer(url: url)
        reviewPlayer = player
        phase = .review(url)
        player.play()
    }

    // MARK: - 確認

    private func reviewView(_ url: URL) -> some View {
        VStack(spacing: 0) {
            if let reviewPlayer {
                VideoPlayer(player: reviewPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime,
                                                                    object: reviewPlayer.currentItem)) { _ in
                        reviewPlayer.seek(to: .zero)
                        reviewPlayer.play()
                    }
            }
            Text(verbatim: MediaTimeText.mmss(recorder.elapsed))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            HStack(spacing: 16) {
                Button {
                    retake()
                } label: {
                    Label("撮り直す", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(BrandStyle.surfaceStrong, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    use(url)
                } label: {
                    Label("使う", systemImage: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(BrandStyle.gradient, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    private func retake() {
        reviewPlayer?.pause()
        reviewPlayer = nil
        recorder.discardLastRecording()
        phase = .live
        recorder.start(position: usesFrontCamera ? .front : .back, frameRate: frameRate)
    }

    private func use(_ url: URL) {
        didUse = true
        reviewPlayer?.pause()
        reviewPlayer = nil
        Analytics.shared.track("camera_record_use")
        onUse(url)
        dismiss()
    }

    // MARK: - 権限なし

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("カメラの使用が許可されていません")
                .font(.headline)
                .foregroundStyle(.white)
            Text("設定アプリでこのアプリの「カメラ」を許可してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("設定を開く") {
                openSystemSettings()
            }
            .buttonStyle(.borderedProminent)
            Button("閉じる") {
                dismiss()
            }
            .foregroundStyle(.white)
        }
        .padding(32)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - プレビューの層

/// AVCaptureVideoPreviewLayer を SwiftUI に置く(CameraRecorder.attachPreviewLayer でセッションにつなぐ)
struct CameraPreviewView: UIViewRepresentable {
    let recorder: CameraRecorder

    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.backgroundColor = .black
        recorder.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewHostView, context: Context) {}
}

final class CameraPreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass で指定しているので必ず AVCaptureVideoPreviewLayer
        layer as! AVCaptureVideoPreviewLayer
    }
}
