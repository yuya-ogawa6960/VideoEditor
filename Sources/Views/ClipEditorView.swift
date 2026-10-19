import SwiftUI
import UIKit

/// 1クリップの編集画面(NavigationStack 内で表示する)
struct ClipEditorView: View {
    let project: EditorProject
    let player: PlayerController
    let clipID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var startThumbnail: UIImage?
    @State private var showDeleteConfirm = false

    private let speedPresets: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    private let minimumGap: Double = 0.2

    var body: some View {
        Group {
            if let clip = project.clipBinding(id: clipID) {
                editorForm(clip)
            } else {
                ContentUnavailableView("クリップが見つかりません", systemImage: "film")
            }
        }
        .navigationTitle("クリップ編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") { dismiss() }
            }
        }
        .onChange(of: project.index(of: clipID) == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }

    // MARK: - フォーム

    @ViewBuilder
    private func editorForm(_ clip: Binding<Clip>) -> some View {
        let current = clip.wrappedValue
        let upper = max(current.duration, 0.01)
        let thumbKey = Int((current.startTime * 10).rounded())
        let clipURL = current.url
        let startTime = current.startTime

        Form {
            Section("情報") {
                LabeledContent("名前", value: current.name)
                LabeledContent("元の長さ", value: MediaTimeText.precise(current.duration))
                LabeledContent("サイズ",
                               value: "\(Int(current.displaySize.width)) × \(Int(current.displaySize.height))")
            }

            // トリミング
            Section("トリミング") {
                HStack(alignment: .top, spacing: 12) {
                    trimThumbnail(startThumbnail ?? current.thumbnail)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("開始 \(MediaTimeText.precise(current.startTime))")
                        Text("終了 \(MediaTimeText.precise(current.endTime))")
                        Text("長さ \(MediaTimeText.precise(current.trimmedDuration))")
                        Text("出力 \(MediaTimeText.precise(current.outputDuration))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
                .task(id: thumbKey) {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { return }
                    let image = await MediaStore.thumbnail(for: clipURL, at: startTime, maxPixel: 240)
                    if !Task.isCancelled, let image {
                        startThumbnail = image
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("開始位置")
                        .font(.caption)
                    Slider(value: startBinding(clip), in: 0...upper)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("終了位置")
                        .font(.caption)
                    Slider(value: endBinding(clip), in: 0...upper)
                }
                Button("トリミングをリセット") {
                    var updated = clip.wrappedValue
                    updated.startTime = 0
                    updated.endTime = updated.duration
                    clip.wrappedValue = updated
                }
                .disabled(!current.isTrimmed)
            }

            // 速度
            Section("速度") {
                HStack(spacing: 6) {
                    ForEach(speedPresets, id: \.self) { preset in
                        Button {
                            clip.wrappedValue.speed = preset
                        } label: {
                            Text(String(format: "%gx", preset))
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(abs(current.speed - preset) < 0.001 ? Color.accentColor : Color.gray)
                    }
                }
                HStack {
                    Slider(value: clip.speed, in: 0.25...4, step: 0.05)
                    Text(String(format: "%.2fx", current.speed))
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }

            // 音声
            Section("音声") {
                Toggle("ミュート", isOn: clip.isMuted)
                    .disabled(!current.hasAudio)
                if !current.hasAudio {
                    Text("このクリップには音声がありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // フィルタ
            Section("フィルタ") {
                FilterPickerView(filter: clip.filter,
                                 sourceImage: current.thumbnail,
                                 onApplyToAll: {
                                     project.applyFilterToAllClips(clip.wrappedValue.filter)
                                 })
            }

            // マルチカメラ
            Section("マルチカメラ") {
                NavigationLink {
                    MulticamEditorView(project: project, player: player, clipID: clipID)
                } label: {
                    HStack {
                        Label("マルチカメラ編集", systemImage: "camera.on.rectangle")
                        Spacer()
                        Text(current.multicam.isActive ? "\(current.multicam.angles.count)アングル" : "未設定")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    project.duplicateClip(id: clipID)
                } label: {
                    Label("複製", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("このクリップを削除しますか?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                project.removeClip(id: clipID)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func trimThumbnail(_ image: UIImage?) -> some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - トリミング用 Binding

    private func startBinding(_ clip: Binding<Clip>) -> Binding<Double> {
        let gap = minimumGap
        return Binding<Double>(
            get: { clip.wrappedValue.startTime },
            set: { newValue in
                var updated = clip.wrappedValue
                updated.startTime = max(0, min(newValue, updated.endTime - gap))
                clip.wrappedValue = updated
            }
        )
    }

    private func endBinding(_ clip: Binding<Clip>) -> Binding<Double> {
        let gap = minimumGap
        return Binding<Double>(
            get: { clip.wrappedValue.endTime },
            set: { newValue in
                var updated = clip.wrappedValue
                updated.endTime = min(updated.duration, max(newValue, updated.startTime + gap))
                clip.wrappedValue = updated
            }
        )
    }
}
