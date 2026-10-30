// =====================================================================
// 「Osmo → iPhone に録画(配信のしくみ・実験)」の画面。開発者モードのときだけ「設定」から開ける
//
// 開発者向けの画面なので、文字は翻訳の対象にしない(Text(verbatim:))。
// 実機ではまだ一度も試していない。docs/OsmoPocket.md の「iPhone に録画」を参照。
// =====================================================================

#if OSMO_LIVE
import SwiftUI
import UIKit

struct OsmoLivestreamView: View {
    @State private var session = OsmoLivestreamSession()
    @State private var showsLog = false
    @State private var savedMessage: String?

    var body: some View {
        List {
            Section {
                OsmoVideoLayerView(layer: session.decoder.displayLayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .overlay(alignment: .topLeading) {
                        if session.isRecording {
                            Label { Text(verbatim: "録画中") } icon: { Image(systemName: "record.circle.fill") }
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Color.red, in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay {
                        if session.phase != .streaming {
                            Text(verbatim: session.phase.label)
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    .listRowInsets(EdgeInsets())
            }

            if session.phase == .streaming || session.phase == .waitingForStream {
                Section {
                    if session.isRecording {
                        Button(role: .destructive) {
                            Task { await session.stopRecording() }
                        } label: {
                            Label { Text(verbatim: "録画を止める") } icon: { Image(systemName: "stop.circle") }
                        }
                        if let start = session.recordingStartedAt {
                            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                .monospacedDigit()
                        }
                    } else {
                        Button {
                            Task { await session.startRecording() }
                        } label: {
                            Label { Text(verbatim: "iPhone に録画") } icon: { Image(systemName: "record.circle") }
                        }
                        .disabled(session.phase != .streaming)
                    }
                } footer: {
                    Text(verbatim: "カメラ本体には保存されません。iPhone の「ファイル」→ このiPhone内 → Video Mania → Osmo に保存されます。")
                }
            }

            Section {
                LabeledContent { Text(verbatim: session.phase.label) } label: { Text(verbatim: "状態") }
                LabeledContent { Text(verbatim: "\(session.codec) \(session.resolution)") } label: { Text(verbatim: "映像") }
                LabeledContent {
                    Text(verbatim: String(format: "%.1f Mbps / 映像 %d / 音声 %d", session.measuredMbps,
                                          session.videoFrames, session.audioFrames))
                        .monospacedDigit()
                } label: { Text(verbatim: "受信") }
            }

            Section {
                TextField(text: $session.ssid) { Text(verbatim: "Wi-Fi の名前") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(text: $session.password) { Text(verbatim: "パスワード") }
                Picker(selection: $session.targetIP) {
                    ForEach(session.targets) { t in
                        Text(verbatim: "\(t.label) \(t.ip)").tag(t.ip)
                    }
                    if session.targets.isEmpty {
                        Text(verbatim: "見つかりません").tag("")
                    }
                } label: {
                    Text(verbatim: "iPhone のアドレス")
                }
                Button { session.refreshTargets() } label: { Text(verbatim: "アドレスを読み直す") }
            } header: {
                Text(verbatim: "カメラをつなぐ Wi-Fi")
            } footer: {
                Text(verbatim: "カメラと iPhone を同じネットワークにします。家の Wi-Fi の名前とパスワード、または iPhone のインターネット共有の名前とパスワードを入れてください。インターネット共有は「互換性を優先」をオンにしてください(カメラは 5GHz や WPA3 に入れないことがあります)。")
            }
            .disabled(session.phase.isRunning)

            Section {
                Picker(selection: $session.quality) {
                    ForEach(OsmoLivestreamSession.Quality.allCases) { q in
                        Text(verbatim: q.label).tag(q)
                    }
                } label: { Text(verbatim: "画質") }
                Picker(selection: $session.fps) {
                    Text(verbatim: "25 fps").tag(25)
                    Text(verbatim: "30 fps").tag(30)
                } label: { Text(verbatim: "フレームレート") }
                Picker(selection: $session.bitrateMbps) {
                    ForEach([3, 6, 10, 16, 20], id: \.self) { m in
                        Text(verbatim: "\(m) Mbps").tag(m)
                    }
                } label: { Text(verbatim: "ビットレート") }
            } header: {
                Text(verbatim: "画質")
            } footer: {
                Text(verbatim: "DJI の公式の選択肢は 1080p・30fps まで(Pocket 4 は 3 / 6 Mbps)。2.7K・4K は試しの値で、カメラに断られる可能性が高いです。")
            }
            .disabled(session.phase.isRunning)

            Section {
                if session.phase.isRunning {
                    Button(role: .destructive) {
                        Task { await session.stop() }
                    } label: { Text(verbatim: "配信を止めて切断") }
                } else {
                    Button { session.startScan() } label: { Text(verbatim: "カメラを探す") }
                }
            }

            if session.phase == .scanning {
                Section {
                    if session.sightings.isEmpty {
                        HStack {
                            ProgressView()
                            Text(verbatim: "探しています…")
                        }
                    }
                    ForEach(session.sightings) { s in
                        Button { session.connect(s) } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: s.name)
                                Text(verbatim: "\(s.modelName)  RSSI \(s.rssi)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(verbatim: "見つかったカメラ(タップで配信を始める)")
                }
            }

            if !session.recordings.isEmpty {
                Section {
                    ForEach(session.recordings, id: \.self) { url in
                        HStack {
                            Text(verbatim: url.lastPathComponent)
                                .font(.footnote)
                                .lineLimit(1)
                            Spacer()
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                            if url.pathExtension == "mov" {
                                Button {
                                    Task {
                                        let ok = await session.saveToPhotos(url)
                                        savedMessage = ok ? "写真に保存しました" : "写真に保存できませんでした"
                                    }
                                } label: { Image(systemName: "photo.badge.arrow.down") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { session.delete(url) } label: { Text(verbatim: "削除") }
                        }
                    }
                } header: {
                    Text(verbatim: "iPhone に録画したもの")
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsLog) {
                    Text(verbatim: session.logText.isEmpty ? "—" : session.logText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    ShareLink(item: session.logText) { Text(verbatim: "ログを共有") }
                } label: {
                    Text(verbatim: "ログ(\(session.logLines.count) 行)")
                }
            } footer: {
                Text(verbatim: "実験中の機能です。DJI の公式な方法ではなく、カメラのファームウェアの更新で動かなくなることがあります。配信中は画面を開いたままにしてください。")
            }
        }
        .navigationTitle(Text(verbatim: "Osmo → iPhone に録画(実験)"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(Text(verbatim: savedMessage ?? ""), isPresented: Binding(
            get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button(role: .cancel) {} label: { Text(verbatim: "OK") }
        }
        .onAppear {
            // 配信を受けているあいだに画面が消えるとアプリが止まり、映像が途切れる
            UIApplication.shared.isIdleTimerDisabled = true
            session.refreshRecordings()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await session.stop() }
        }
    }
}
#endif
