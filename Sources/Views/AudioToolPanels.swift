import SwiftUI
import UIKit
import AVFoundation
import Observation

// =====================================================================
// 音声ツールのための下部パネルと進捗表示
//   - EditorNarrationRecordPanel : ナレーションの録音(ルートツールバーの「ナレーション」)
//   - EditorNarrationVolumePanel : ナレーション 1 件の音量
//   - AudioToolProgress / AudioToolProgressOverlay : 無音カット・音量そろえの進捗
// =====================================================================

// MARK: - 進捗

/// 無音カット・音量そろえなど、クリップを順に解析する処理の進み具合
struct AudioToolProgress: Equatable {
    /// 例: 「無音を検出中」
    var title: String
    var done: Int
    var total: Int
}

/// 画面全体を覆う進捗表示(キャンセルつき)
struct AudioToolProgressOverlay: View {
    let progress: AudioToolProgress
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("\(progress.title) \(min(progress.done + 1, max(progress.total, 1)))/\(progress.total)")
                    .font(.callout)
                    .monospacedDigit()
                Button {
                    EditorHaptics.tap()
                    onCancel()
                } label: {
                    Text("キャンセル")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(width: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - ナレーション録音

struct EditorNarrationRecordPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// 録音したナレーションを追加したあとに呼ばれる(選択に使う)
    let onRecorded: (UUID) -> Void

    @State private var recorder = VoiceRecorder()
    /// 録音中にタイムラインを再生する(映像に合わせて話せる)
    @State private var playWhileRecording = false
    /// 録音を始めたときの再生位置(ナレーションの開始位置)
    @State private var playheadAtStart: Double = 0
    @State private var errorMessage: String?
    @State private var resultText: String?
    /// 録音中、イヤホンがないので音を出さずに再生している
    @State private var isMonitorMuted = false
    /// マイクの使用が拒否されている(設定アプリを開くボタンを出す)
    @State private var micDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if recorder.isRecording {
                    Label("録音中", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Text("再生位置 \(EditorTimeFormat.short(player.currentTime)) から録音します")
                        .font(.subheadline)
                }
                Spacer()
                Text(MediaTimeText.precise(recorder.isRecording ? recorder.elapsed : 0))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(recorder.isRecording ? Color.white : Color.secondary)
            }

            levelMeter

            HStack {
                Spacer()
                recordButton
                Spacer()
            }

            Toggle("録音しながら再生する", isOn: $playWhileRecording)
                .font(.subheadline)
                .tint(.accentColor)
                .disabled(recorder.isRecording)
            if playWhileRecording {
                Label(recorder.isRecording && isMonitorMuted
                      ? String(localized: "イヤホンがないため、音を出さずに再生しています")
                      : String(localized: "イヤホンをしているときだけ音が聞こえます(スピーカーの音がマイクに入るのを防ぐため)"),
                      systemImage: "headphones")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if micDenied {
                    // 一度拒否すると許可のダイアログは二度と出ないので、設定アプリへの入り口を出す
                    Button("設定を開く") {
                        openSystemSettings()
                    }
                    .font(.caption.weight(.semibold))
                }
            } else if let resultText {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .onChange(of: recorder.headphoneConnected) { _, connected in
            // 録音中にイヤホンをつないだ / 外したら、音を出すかを切り替える(イヤホンのときだけ音を出す)。
            // 外したときは AVPlayer が自分で止まるので、ここで再生し直さない
            guard recorder.isRecording, playWhileRecording else { return }
            isMonitorMuted = !connected
            player.player.isMuted = isMonitorMuted
        }
        .onDisappear {
            // パネルが閉じられたら録音を終えて追加しておく(録音を失わないため)
            if recorder.isRecording {
                finishRecording()
            }
            // 自動ロックの抑止を必ず解除し、中断の通知も外す(録音機とパネルの循環参照を切る)
            IdleTimerGuard.set(false, for: "recording")
            recorder.onInterrupted = nil
        }
    }

    /// 入力レベルのバー
    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(recorder.level > 0.85 ? Color.red : Color.green)
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(recorder.level, 0), 1))))
            }
        }
        .frame(height: 8)
        .opacity(recorder.isRecording ? 1 : 0.4)
        .animation(.linear(duration: 0.05), value: recorder.level)
    }

    /// 大きな録音 / 停止ボタン
    private var recordButton: some View {
        Button {
            EditorHaptics.tap()
            toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 3)
                    .frame(width: 72, height: 72)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 58, height: 58)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? String(localized: "録音を停止") : String(localized: "録音を開始"))
    }

    // MARK: 操作

    private func toggleRecording() {
        if recorder.isRecording {
            finishRecording()
        } else {
            Task { @MainActor in
                await beginRecording()
            }
        }
    }

    @MainActor
    private func beginRecording() async {
        errorMessage = nil
        resultText = nil
        micDenied = false
        let granted = await recorder.requestPermission()
        guard granted else {
            errorMessage = VoiceRecorderError.permissionDenied.localizedDescription
            micDenied = AVAudioApplication.shared.recordPermission == .denied
            return
        }
        player.pause()
        playheadAtStart = max(0, player.currentTime)
        // 電話・Siri・エラーなどで録音が止められたら、そこまでをナレーションとして追加する
        recorder.onInterrupted = { url in
            completeRecording(url: url, interrupted: true)
        }
        do {
            try recorder.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // 録音中は画面の自動ロックを止める(ロックでアプリが止まると録音も止まるため)
        IdleTimerGuard.set(true, for: "recording")
        if playWhileRecording {
            // イヤホンがないときは音を出さない(スピーカーの音がマイクに入るため)
            isMonitorMuted = !VoiceRecorder.isHeadphoneConnected
            player.player.isMuted = isMonitorMuted
            player.play()
        }
    }

    /// 録音中の再生を止め、音を戻し、録音を始めた位置にバーを戻す
    private func stopPlaybackAndRewind(startedWithPlayback: Bool) {
        if startedWithPlayback { player.pause() }
        player.player.isMuted = false
        isMonitorMuted = false
        player.seek(to: playheadAtStart)
    }

    /// 録音を止めてナレーションとして追加する
    private func finishRecording() {
        completeRecording(url: recorder.stop(), interrupted: false)
    }

    /// 止まった録音をナレーションとして追加する。
    /// interrupted: 電話・Siri・エラーなどでシステム側に止められた(VoiceRecorder が stop() 済みで url を渡してくる)
    private func completeRecording(url: URL?, interrupted: Bool) {
        IdleTimerGuard.set(false, for: "recording")
        let startedWithPlayback = playWhileRecording
        guard let url else {
            stopPlaybackAndRewind(startedWithPlayback: startedWithPlayback)
            errorMessage = String(localized: "録音ファイルを保存できませんでした。")
            return
        }
        stopPlaybackAndRewind(startedWithPlayback: startedWithPlayback)
        // 長さは保存したファイルから測る(止められた録音機の経過秒は当てにならないため)
        let duration = Self.recordedDuration(of: url, fallback: recorder.elapsed)
        guard duration >= 0.2 else {
            try? FileManager.default.removeItem(at: url)
            errorMessage = interrupted
                ? String(localized: "録音が中断されました。短すぎたため追加しませんでした。")
                : String(localized: "録音が短すぎたため追加しませんでした。")
            return
        }

        history.record(project)
        let clip = NarrationClip(url: url,
                                 name: MediaStore.displayName(for: url, fallback: String(localized: "ナレーション")),
                                 start: playheadAtStart,
                                 duration: duration)
        project.narration.append(clip)
        project.sortNarration()
        if interrupted {
            resultText = String(localized: "録音が中断されたため、ここまでを追加しました。")
        } else {
            resultText = "\(MediaTimeText.precise(playheadAtStart)) に \(String(format: "%.1f", duration)) 秒のナレーションを追加しました。"
        }
        onRecorded(clip.id)
    }

    /// 録音ファイルの長さ(秒)。読めなければ fallback(録音中に測った経過秒)を返す
    private static func recordedDuration(of url: URL, fallback: Double) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return fallback }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return fallback }
        return Double(file.length) / sampleRate
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - ナレーションの音量

struct EditorNarrationVolumePanel: View {
    @Binding var narration: NarrationClip

    private var gainText: String {
        let db = LoudnessAnalyzer.decibels(fromGain: narration.gain)
        guard db.isFinite else { return "—" }
        if abs(db) < 0.05 { return String(localized: "なし") }
        return db > 0 ? String(localized: "少し大きく") : String(localized: "少し小さく")
    }

    private var hasGain: Bool { abs(narration.gain - 1) > 0.001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSliderRow(title: String(localized: "ボリューム"),
                            value: $narration.volume,
                            range: 0...1,
                            display: "\(Int((narration.volume * 100).rounded()))%")
            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    narration.volume = 1
                }
            }

            HStack {
                Text("自動で整えた分: \(gainText)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                EditorChip(title: String(localized: "自動調整を取り消す"), isSelected: false) {
                    narration.gain = 1
                }
                .disabled(!hasGain)
                .opacity(hasGain ? 1 : 0.4)
            }
        }
        .padding(.top, 6)
    }
}
