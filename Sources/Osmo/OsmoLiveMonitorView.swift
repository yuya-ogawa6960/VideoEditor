// =====================================================================
// 「Osmo Pocket ライブビュー(実験)」の画面。開発者モードのときだけ「設定」から開ける
//
// 編集画面の「追加」→「Osmo Pocket で撮る(実験)」からも開ける(onUse で録画をプロジェクトに入れる)。
//
// 開発者向けの画面なので、文字は翻訳の対象にしない(Text(verbatim:))。
// ただし録画まわり(OsmoRecordingSections)は編集画面から使うので翻訳する。
// 実機ではまだ一度も試していない。docs/OsmoPocket.md の「実機で確かめること」を参照。
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import SwiftUI
import UIKit

struct OsmoLiveMonitorView: View {
    /// 「プロジェクトに入れる」。nil(「設定」から開いたとき)はボタンを出さない
    var onUse: ((URL) -> Void)? = nil

    @State private var monitor = OsmoLiveMonitor()
    @State private var showsLog = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // private な @State があっても外から OsmoLiveMonitorView { url in … } / OsmoLiveMonitorView() で作れるように
    init(onUse: ((URL) -> Void)? = nil) {
        self.onUse = onUse
    }

    var body: some View {
        List {
            Section {
                OsmoVideoLayerView(layer: monitor.decoder.displayLayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .overlay {
                        if monitor.phase != .live {
                            Text(verbatim: monitor.phase.label)
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    .listRowInsets(EdgeInsets())
            }

            OsmoRecordingSections(monitor: monitor, onUse: onUse)

            Section {
                LabeledContent { Text(verbatim: monitor.phase.label) } label: { Text(verbatim: "状態") }
                if let name = monitor.connectedName {
                    LabeledContent { Text(verbatim: name) } label: { Text(verbatim: "カメラ") }
                }
                LabeledContent { Text(verbatim: "\(monitor.codec) \(monitor.resolution)") } label: { Text(verbatim: "映像") }
                LabeledContent {
                    Text(verbatim: String(format: "%.0f fps / 復号 %d", monitor.fps, monitor.decodedFrames))
                        .monospacedDigit()
                } label: { Text(verbatim: "表示") }
                LabeledContent {
                    Text(verbatim: "pkt \(monitor.stats.videoPackets) / AU \(monitor.stats.accessUnits) / 欠け \(monitor.stats.droppedIncomplete)")
                        .monospacedDigit()
                } label: { Text(verbatim: "受信") }
            }

            Section {
                if monitor.phase == .idle || isFailed {
                    Button { monitor.startScan() } label: { Text(verbatim: "カメラを探す") }
                } else {
                    Button(role: .destructive) { monitor.stop() } label: { Text(verbatim: "切断") }
                }
            } footer: {
                Text(verbatim: "カメラの電源を入れ、近くに置いてください。初回はカメラの画面で接続を許可します。iPhone はカメラの Wi-Fi に入るので、そのあいだインターネットはモバイル通信になります。")
            }

            if monitor.phase == .scanning {
                Section {
                    if monitor.sightings.isEmpty {
                        HStack {
                            ProgressView()
                            Text(verbatim: "探しています…")
                        }
                    }
                    ForEach(monitor.sightings) { s in
                        Button { monitor.connect(s) } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: s.name)
                                Text(verbatim: "\(s.modelName)  RSSI \(s.rssi)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(verbatim: "見つかったカメラ")
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsLog) {
                    Text(verbatim: monitor.logText.isEmpty ? "—" : monitor.logText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    ShareLink(item: monitor.logText) { Text(verbatim: "ログを共有") }
                } label: {
                    Text(verbatim: "ログ(\(monitor.logLines.count) 行)")
                }
            } footer: {
                Text(verbatim: "実験中の機能です。DJI の公式な方法ではなく、カメラのファームウェアの更新で動かなくなることがあります。")
            }
        }
        .navigationTitle(Text(verbatim: "Osmo ライブビュー(実験)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 編集画面から全画面で開いたときだけ「閉じる」を出す(録画中は押せない)
            if onUse != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .disabled(monitor.streamRecordingState != .idle)
                }
            }
        }
        .onAppear { OsmoStreamRecorder.cleanUpTemporaryFiles() }
        .onChange(of: scenePhase) { _, newPhase in
            // 裏に回ると映像が止まるので、そこまでをファイルとして閉じる
            if newPhase == .background { monitor.stopStreamRecording() }
        }
        .onDisappear {
            monitor.stop()
            // 選ばずに閉じた録画は残さない(録画中に閉じたものは次に開いたとき 10 分以上前なら消す)
            monitor.discardFinishedStreamRecording()
        }
    }

    private var isFailed: Bool {
        if case .failed = monitor.phase { return true }
        return false
    }
}

/// AVSampleBufferDisplayLayer を SwiftUI に置く
private struct OsmoVideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.hosted = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        var hosted: CALayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
#endif
