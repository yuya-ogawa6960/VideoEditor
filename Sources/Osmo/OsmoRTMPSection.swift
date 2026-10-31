// =====================================================================
// 「高画質モード(RTMP・最大 1080p)」の欄(実験中・開発者向け)。OsmoLiveMonitorView の中に置く
//
// - インターネット共有の名前とパスワード(Keychain に保存。ログには出さない)→「開始」で
//   カメラに Bluetooth で頼み、カメラから iPhone の中の RTMP サーバーへ送ってもらう(OsmoRTMPSession)
// - 「DJI Mimo から配信するとき」: Bluetooth の命令を使わず、URL を Mimo の「ライブ配信」→「RTMP」に入れてもらう
// - 録画は「iPhone に録画」と同じく、止めたら「プロジェクトに入れる」「写真に保存」「破棄」
// 編集画面から開くので、ここの文字は翻訳する。実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import Photos
import SwiftUI
import UIKit

struct OsmoRTMPSection: View {
    let monitor: OsmoLiveMonitor
    /// 「プロジェクトに入れる」。nil なら出さない
    var onUse: ((URL) -> Void)?

    @State private var ssid = ""
    @State private var password = ""
    @State private var loadedCredentials = false
    @State private var hasSavedCredentials = false
    @AppStorage("osmo.rtmp.model") private var modelRaw = OsmoRTMPModel.automatic.rawValue
    @AppStorage("osmo.rtmp.quality") private var qualityRaw = OsmoRTMPQuality.fps30mbps20.rawValue
    /// 「iPhone に録画」と同じ設定(カメラの音が無いときだけ使う)
    @AppStorage("osmo.recordMicrophone") private var recordMicrophone = true
    @State private var microphoneNote: String?
    @State private var photoMessage: String?
    @State private var isSavingToPhotos = false
    @State private var copiedURL = false
    @Environment(\.dismiss) private var dismiss

    init(monitor: OsmoLiveMonitor, onUse: ((URL) -> Void)? = nil) {
        self.monitor = monitor
        self.onUse = onUse
    }

    private var session: OsmoRTMPSession { monitor.rtmp }

    var body: some View {
        Section {
            mainRows
        } header: {
            Text("高画質モード(RTMP・最大 1080p)")
        } footer: {
            Text("カメラがこの iPhone のインターネット共有に入り、映像を直接送ります。ライブビューより高い画質で受けられます。RTMP では 4K は使えません(最大 1080p)。ライブビューとは同時に使えません。")
        }

        Section {
            mimoRows
        } header: {
            Text("DJI Mimo から配信するとき")
        } footer: {
            Text("Mimo で始めたら、すぐに Video Mania に戻ってください。裏にいるあいだは 30 秒ほどしか受けられません。配信を終えるときは Mimo の「ライブ配信を終了」も押してください。")
        }

        if session.isActive || session.finishedRecording != nil {
            Section {
                recordingRows
            } header: {
                Text("iPhone に録画(高画質モード)")
            } footer: {
                Text(recordingFooter)
            }
        }
    }

    // MARK: 開始・状態

    @ViewBuilder
    private var mainRows: some View {
        if session.isActive {
            OsmoRTMPVideoView(layer: session.decoder.displayLayer)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .overlay {
                    if session.width == 0 {
                        Text(session.statusText)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                .listRowInsets(EdgeInsets())
        }
        LabeledContent {
            Text(session.statusText)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        } label: {
            Text("状態")
        }
        .onAppear(perform: loadCredentials)
        if session.isStalled {
            Label("映像が止まっています", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if let notice = session.notice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if let name = session.cameraName {
            LabeledContent {
                Text(verbatim: name)
            } label: {
                Text("カメラ")
            }
        }
        if session.isActive {
            Button(role: .destructive) {
                session.stop()
            } label: {
                Label("停止", systemImage: "stop.circle")
            }
            .disabled(session.recordingState != .idle)
        } else {
            TextField("インターネット共有の名前", text: $ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("インターネット共有のパスワード", text: $password)
            Picker("カメラの機種", selection: $modelRaw) {
                Text("自動").tag(OsmoRTMPModel.automatic.rawValue)
                Text(verbatim: "Osmo Pocket 3").tag(OsmoRTMPModel.pocket3.rawValue)
                Text(verbatim: "Osmo Pocket 4 / 4 Pro").tag(OsmoRTMPModel.pocket4.rawValue)
            }
            if modelRaw != OsmoRTMPModel.pocket4.rawValue {
                Picker("画質(Pocket 3)", selection: $qualityRaw) {
                    ForEach(OsmoRTMPQuality.allCases) { quality in
                        Text(verbatim: quality.label).tag(quality.rawValue)
                    }
                }
            }
            Button {
                start()
            } label: {
                Label("開始", systemImage: "play.circle.fill")
            }
            .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.utf8.count < 8)
            Text("iPhone の「設定」→「インターネット共有」で「ほかの人の接続を許可」と「互換性を優先」をオンにしてください。名前とパスワードはその画面に出ています。Pocket 4 は DJI Mimo で記録された設定(1080p・25fps・6Mbps)で送ります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if hasSavedCredentials {
                Button("保存した名前とパスワードを消す", role: .destructive) {
                    OsmoRTMPHotspotStore.clear()
                    ssid = ""
                    password = ""
                    hasSavedCredentials = false
                }
            }
        }
    }

    private func loadCredentials() {
        guard !loadedCredentials else { return }
        loadedCredentials = true
        let saved = OsmoRTMPHotspotStore.load()
        if ssid.isEmpty { ssid = saved.ssid }
        if password.isEmpty { password = saved.password }
        hasSavedCredentials = OsmoRTMPHotspotStore.hasSaved
    }

    private func start() {
        let name = ssid.trimmingCharacters(in: .newlines)
        OsmoRTMPHotspotStore.save(ssid: name, password: password)
        hasSavedCredentials = true
        photoMessage = nil
        microphoneNote = nil
        // ライブビュー(カメラの Wi-Fi)とは同時に使えないので先に止める
        monitor.stop()
        session.startWithBluetooth(ssid: name, password: password,
                                   model: OsmoRTMPModel(rawValue: modelRaw) ?? .automatic,
                                   quality: OsmoRTMPQuality(rawValue: qualityRaw) ?? .fps30mbps20)
    }

    // MARK: DJI Mimo から

    @ViewBuilder
    private var mimoRows: some View {
        Text("DJI Mimo の『ライブ配信』→『RTMP』にこの URL を入れて開始")
        Text(verbatim: session.streamURL)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
        Button {
            UIPasteboard.general.string = session.streamURL
            copiedURL = true
        } label: {
            if copiedURL {
                Label("コピーしました", systemImage: "checkmark")
            } else {
                Label("URL をコピー", systemImage: "doc.on.doc")
            }
        }
        if !session.isActive {
            Button {
                photoMessage = nil
                microphoneNote = nil
                monitor.stop()
                session.startReceiverOnly()
            } label: {
                Label("受信だけ始める", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        Text("1. 先に「受信だけ始める」を押します。\n2. DJI Mimo で、カメラのネットワークにこの iPhone のインターネット共有を選び、上の URL を入れて配信を始めます。\n3. すぐに Video Mania に戻ると、映像が出ます。")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: 録画

    @ViewBuilder
    private var recordingRows: some View {
        if let url = session.finishedRecording {
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
                session.discardFinishedRecording()
            } label: {
                Label("破棄", systemImage: "trash")
            }
        } else {
            switch session.recordingState {
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
                .disabled(session.status != .receiving || session.width == 0)
                if session.hasCameraAudio {
                    Label("音はカメラのマイクから録ります", systemImage: "mic")
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("iPhone のマイクの音も録る", isOn: $recordMicrophone)
                }
            case .preparing:
                HStack {
                    ProgressView()
                    Text("次のキーフレームを待っています…")
                    Spacer()
                    Button("やめる") { session.stopRecording() }
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
                        session.stopRecording()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            case .finishing:
                HStack {
                    ProgressView()
                    Text("保存しています…")
                }
            }
        }
    }

    private var recordingFooter: String {
        let notes = [session.recordingMessage, microphoneNote, photoMessage].compactMap { $0 }
        if !notes.isEmpty { return notes.joined(separator: "\n") }
        if session.hasCameraAudio {
            return String(localized: "カメラから届いた映像と音を、作り直さずにそのまま保存します。")
        }
        return String(localized: "カメラから届いた映像を、作り直さずにそのまま保存します。カメラの音が届かないときは iPhone のマイクで録れます。")
    }

    private func startRecording() async {
        microphoneNote = nil
        photoMessage = nil
        var useMicrophone = recordMicrophone && !session.hasCameraAudio
        if useMicrophone {
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
        session.startRecording(microphone: useMicrophone)
    }

    /// カメラで撮るときと同じく、一時ファイルを渡して閉じる(取り込み側がコピーして消す)
    private func useRecording() {
        guard let onUse, let url = session.takeFinishedRecording() else { return }
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

    /// 経過時間 mm:ss
    private static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// 高画質モードの映像(AVSampleBufferDisplayLayer)を置く
private struct OsmoRTMPVideoView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.hosted = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    final class HostView: UIView {
        var hosted: CALayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
#endif
