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

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let resultText {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("録音したナレーションは再生位置からタイムラインに追加されます。追加後は「音量」や「音量そろえ」で調整できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .onDisappear {
            // パネルが閉じられたら録音を終えて追加しておく(録音を失わないため)
            if recorder.isRecording {
                finishRecording()
            }
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
        .accessibilityLabel(recorder.isRecording ? "録音を停止" : "録音を開始")
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
        let granted = await recorder.requestPermission()
        guard granted else {
            errorMessage = VoiceRecorderError.permissionDenied.localizedDescription
            return
        }
        player.pause()
        playheadAtStart = max(0, player.currentTime)
        do {
            try recorder.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if playWhileRecording {
            player.play()
        }
    }

    /// 録音を止めてナレーションとして追加する
    private func finishRecording() {
        let startedWithPlayback = playWhileRecording
        guard let url = recorder.stop() else {
            if startedWithPlayback { player.pause() }
            errorMessage = "録音ファイルを保存できませんでした。"
            return
        }
        if startedWithPlayback {
            player.pause()
        }
        let duration = recorder.elapsed
        guard duration >= 0.2 else {
            try? FileManager.default.removeItem(at: url)
            errorMessage = "録音が短すぎたため追加しませんでした。"
            return
        }

        history.record(project)
        let clip = NarrationClip(url: url,
                                 name: MediaStore.displayName(for: url, fallback: "ナレーション"),
                                 start: playheadAtStart,
                                 duration: duration)
        project.narration.append(clip)
        project.sortNarration()
        resultText = "\(MediaTimeText.precise(playheadAtStart)) に \(String(format: "%.1f", duration)) 秒のナレーションを追加しました。"
        onRecorded(clip.id)
    }
}

// MARK: - ナレーションの音量

struct EditorNarrationVolumePanel: View {
    @Binding var narration: NarrationClip

    private var gainText: String {
        let db = LoudnessAnalyzer.decibels(fromGain: narration.gain)
        guard db.isFinite else { return "—" }
        if abs(db) < 0.05 { return "なし" }
        return db > 0 ? "少し大きく" : "少し小さく"
    }

    private var hasGain: Bool { abs(narration.gain - 1) > 0.001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(narration.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(MediaTimeText.precise(narration.start)) – \(MediaTimeText.precise(narration.end))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            EditorSliderRow(title: "ボリューム",
                            value: $narration.volume,
                            range: 0...1,
                            display: "\(Int((narration.volume * 100).rounded()))%")
            HStack {
                Spacer()
                EditorChip(title: "リセット", isSelected: false) {
                    narration.volume = 1
                }
            }

            HStack {
                Text("自動で整えた分: \(gainText)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                EditorChip(title: "自動調整を取り消す", isSelected: false) {
                    narration.gain = 1
                }
                .disabled(!hasGain)
                .opacity(hasGain ? 1 : 0.4)
            }

            Text("ツールバーの「音量そろえ」や「聞きやすくする」で、このナレーションの音量を自動で整えられます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}
