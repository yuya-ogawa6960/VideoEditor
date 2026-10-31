// =====================================================================
// Osmo のライブビュー画面の録画まわり(実験中・開発者向け)
//
// - 「iPhone に録画(ライブビューの画質)」: 受けた映像を作り直さずに .mp4 に書く(OsmoStreamRecorder)。
//   止めたら「プロジェクトに入れる」「写真に保存」「破棄」。マイクの音も入れられる(既定はオン)
// - 「カメラ本体で録画」: カメラに録画の命令を送る(OsmoCameraControl)。ファイルはカメラの SD カードに残る
// 2 つは別々に動くので、同時に使える。
// - 「カメラの動画を取り込む」: カメラに保存された元のファイルを Wi-Fi で取り込む(OsmoMediaBrowser)。
//   カメラの録画を止めた直後は「今撮った動画を取り込む」で一番新しい動画をすぐに取り込める
// 編集画面から開くので、ここの文字は翻訳する。実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import Photos
import SwiftUI

struct OsmoRecordingSections: View {
    let monitor: OsmoLiveMonitor
    /// 「プロジェクトに入れる」。nil なら出さない
    var onUse: ((URL) -> Void)?

    /// 「iPhone のマイクの音も録る」(既定はオン)
    @AppStorage("osmo.recordMicrophone") private var recordMicrophone = true
    @State private var microphoneNote: String?
    @State private var photoMessage: String?
    @State private var isSavingToPhotos = false
    /// カメラの動画の画面(nil = 閉じている)
    @State private var mediaBrowserMode: OsmoMediaBrowserMode?
    /// 取り込み終えたファイル。カメラの動画の画面が閉じてから渡す(画面を 2 枚同時に閉じないように)
    @State private var pendingCameraFile: URL?
    @Environment(\.dismiss) private var dismiss

    init(monitor: OsmoLiveMonitor, onUse: ((URL) -> Void)? = nil) {
        self.monitor = monitor
        self.onUse = onUse
    }

    var body: some View {
        Section {
            phoneRows
        } header: {
            Text("iPhone に録画(ライブビューの画質)")
        } footer: {
            Text(phoneFooter)
        }

        if monitor.phase == .live || monitor.camera.isConnected {
            Section {
                cameraRows
            } header: {
                Text("カメラ本体で録画(SD カード・本来の画質)")
            } footer: {
                Text("カメラ本体で撮った動画はカメラに残ります。下の「カメラの動画を取り込む」で、本来の画質のまま取り込めます。")
            }
        }

        if onUse != nil, monitor.media.isAttached {
            Section {
                Button {
                    mediaBrowserMode = .browse
                } label: {
                    Label("カメラの動画を取り込む", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!canOpenMediaBrowser)
                .sheet(item: $mediaBrowserMode, onDismiss: handOverCameraFile) { mode in
                    NavigationStack {
                        OsmoMediaBrowserView(library: monitor.media, mode: mode) { url in
                            useCameraFile(url)
                        }
                    }
                }
            } header: {
                Text("カメラの動画を取り込む(本来の画質)")
            } footer: {
                Text(canOpenMediaBrowser
                     ? String(localized: "カメラに保存された動画を、カメラの Wi-Fi でそのままの画質で取り込みます。取り込むあいだ、ライブビューは止まります。")
                     : String(localized: "録画中は取り込めません。録画を止めてから開いてください。"))
            }
        }
    }

    /// カメラの動画の画面を開けるか(カメラ本体・iPhone のどちらかで録画中は開かない。再生モードにすると録画が止まるおそれがあるため)
    private var canOpenMediaBrowser: Bool {
        monitor.camera.recordingState != .recording && monitor.streamRecordingState == .idle
    }

    /// カメラから取り込んだファイルを渡して閉じる(取り込み側がコピーして消す)
    private func useCameraFile(_ url: URL) {
        pendingCameraFile = url
        mediaBrowserMode = nil
    }

    /// カメラの動画の画面が閉じたあと: 取り込み終えたファイルがあれば渡して、この画面も閉じる
    private func handOverCameraFile() {
        guard let url = pendingCameraFile else { return }
        pendingCameraFile = nil
        guard let onUse else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        onUse(url)
        dismiss()
    }

    // MARK: iPhone に録画

    @ViewBuilder
    private var phoneRows: some View {
        if let url = monitor.finishedStreamRecording {
            Label("録画しました", systemImage: "checkmark.circle.fill")
            if onUse != nil {
                Button {
                    useRecording()
                } label: {
                    Label("プロジェクトに入れる", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            Button {
                Task { await saveToPhotos(url) }
            } label: {
                Label("写真に保存", systemImage: "square.and.arrow.down")
            }
            .disabled(isSavingToPhotos)
            Button(role: .destructive) {
                photoMessage = nil
                monitor.discardFinishedStreamRecording()
            } label: {
                Label("破棄", systemImage: "trash")
            }
        } else {
            switch monitor.streamRecordingState {
            case .idle:
                Button {
                    Task { await startRecording() }
                } label: {
                    Label {
                        Text("録画")
                    } icon: {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(monitor.phase != .live)
                Toggle("iPhone のマイクの音も録る", isOn: $recordMicrophone)
            case .preparing:
                HStack {
                    ProgressView()
                    Text("録画の準備をしています…")
                    Spacer()
                    Button("やめる") { monitor.stopStreamRecording() }
                        .buttonStyle(.bordered)
                }
            case .recording(let startedAt):
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    SwiftUI.TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                        Text(verbatim: Self.clock(context.date.timeIntervalSince(startedAt)))
                            .monospacedDigit()
                    }
                    Spacer()
                    Button {
                        monitor.stopStreamRecording()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                if monitor.streamRecordingStalled {
                    Label("映像が止まっています。録画は続けています", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            case .finishing:
                HStack {
                    ProgressView()
                    Text("保存しています…")
                }
            }
        }
    }

    private var phoneFooter: String {
        let notes = [monitor.streamRecordingMessage, microphoneNote, photoMessage].compactMap { $0 }
        if !notes.isEmpty { return notes.joined(separator: "\n") }
        return String(localized: "ライブビューの映像(約 1280×720)をそのまま保存します。カメラ本体の録画と同時に使えます。")
    }

    private func startRecording() async {
        microphoneNote = nil
        photoMessage = nil
        var useMicrophone = recordMicrophone
        if useMicrophone {
            // カメラの画面と同じく、未決定なら聞く。断られても音なしで録れる
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                break
            case .undetermined:
                useMicrophone = await AVAudioApplication.requestRecordPermission()
            default:
                useMicrophone = false
            }
            if !useMicrophone {
                microphoneNote = String(localized: "マイクが許可されていないので、音なしで録ります。設定アプリで「マイク」を許可できます。")
            }
        }
        monitor.startStreamRecording(microphone: useMicrophone)
    }

    /// カメラで撮るときと同じく、一時ファイルを渡して閉じる(取り込み側がコピーして消す)
    private func useRecording() {
        guard let onUse, let url = monitor.takeFinishedStreamRecording() else { return }
        onUse(url)
        dismiss()
    }

    private func saveToPhotos(_ url: URL) async {
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            photoMessage = String(localized: "写真への保存が許可されていません")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            photoMessage = String(localized: "写真に保存しました")
        } catch {
            photoMessage = String(localized: "写真に保存できませんでした")
        }
    }

    // MARK: カメラ本体で録画

    @ViewBuilder
    private var cameraRows: some View {
        HStack(spacing: 10) {
            if monitor.camera.recordingState == .recording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
            }
            // 状態の文はカメラ操作の側(開発者向け・翻訳しない)
            Text(verbatim: monitor.camera.recordingState.label)
            if monitor.camera.recordingState == .recording, let seconds = monitor.camera.elapsedSeconds {
                Text(verbatim: Self.clock(Double(seconds)))
                    .monospacedDigit()
            }
            Spacer()
            if monitor.camera.isBusy {
                ProgressView()
            }
        }
        // 状態が分からないあいだは、始める・止めるの両方を出す
        if monitor.camera.recordingState != .recording {
            Button {
                monitor.camera.startRecording()
            } label: {
                Label("カメラで録画を始める", systemImage: "record.circle")
            }
            .disabled(monitor.camera.isBusy)
        }
        if monitor.camera.recordingState != .idle {
            Button(role: .destructive) {
                monitor.camera.stopRecording()
            } label: {
                Label("カメラの録画を止める", systemImage: "stop.circle")
            }
            .disabled(monitor.camera.isBusy)
        }
        if let message = monitor.camera.lastMessage {
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // 録画を止めた直後: 一番新しい動画をすぐに取り込む
        if onUse != nil, monitor.media.isAttached, monitor.camera.recordingState == .idle,
           monitor.camera.lastStoppedAt != nil {
            Button {
                mediaBrowserMode = .newest
            } label: {
                Label("今撮った動画を取り込む", systemImage: "square.and.arrow.down")
            }
            .disabled(!canOpenMediaBrowser)
        }
    }

    /// 経過時間 mm:ss
    private static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
#endif
