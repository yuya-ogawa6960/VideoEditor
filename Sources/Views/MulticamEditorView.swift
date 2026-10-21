import SwiftUI
import PhotosUI
import UIKit

/// マルチカメラ編集(別アングルの追加・同期・ライブ切替)
struct MulticamEditorView: View {
    let project: EditorProject
    let player: PlayerController
    let clipID: UUID

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isAddingAngles = false
    @State private var syncingAngleIDs: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let clipIndex = project.index(of: clipID) {
                content(clip: project.clips[clipIndex], clipIndex: clipIndex)
            } else {
                ContentUnavailableView("クリップが見つかりません", systemImage: "film")
            }
        }
        .navigationTitle("マルチカメラ")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            pickerItems = []
            Task { await addAngles(items) }
        }
        .alert("うまくいきませんでした", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 画面本体

    @ViewBuilder
    private func content(clip: Clip, clipIndex: Int) -> some View {
        let location = project.locate(timelineTime: player.currentTime)
        let isInClip = location?.index == clipIndex
        let currentSourceTime: Double? = isInClip ? location?.sourceTime : nil
        let starts = project.clipStartTimes()
        let clipStart = clipIndex < starts.count ? starts[clipIndex] : 0

        List {
            // ライブ切替
            Section {
                PreviewView(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.black)

                HStack(spacing: 16) {
                    Button {
                        if !isInClip {
                            player.seek(to: clipStart)
                        }
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 32)
                    }
                    .buttonStyle(.borderless)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(MediaTimeText.mmss(player.currentTime))
                            .monospacedDigit()
                        if let sourceTime = currentSourceTime {
                            Text("現在: \(angleLabel(clip.multicam.angleIndex(at: sourceTime), clip: clip))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("再生位置がこのクリップの外です")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    if !isInClip {
                        Button("先頭へ") {
                            player.seek(to: clipStart)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if clip.multicam.angles.isEmpty {
                    Text("同じ場面を別のカメラで撮った動画を「アングルを追加」で入れると、再生しながらボタンで切り替えられます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0...clip.multicam.angles.count, id: \.self) { n in
                                let isCurrent = currentSourceTime.map { clip.multicam.angleIndex(at: $0) == n } ?? false
                                Button {
                                    insertSwitch(angle: n)
                                } label: {
                                    Text(n == 0 ? String(localized: "メイン") : String(localized: "アングル\(n)"))
                                        .font(.callout.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(isCurrent ? Color.red : Color.blue)
                                .disabled(!isInClip)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("ライブ切替")
            } footer: {
                Text("再生中にボタンをタップすると、その時点からアングルが切り替わります。")
            }

            // アングル一覧
            Section {
                ForEach(Array(clip.multicam.angles.enumerated()), id: \.element.id) { index, angle in
                    angleRow(angle: angle, number: index + 1, clip: clip)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteAngle(id: angle.id)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }

                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: nil,
                             selectionBehavior: .ordered,
                             matching: .videos,
                             preferredItemEncoding: .current) {
                    HStack {
                        Label("アングルを追加", systemImage: "plus.circle")
                        if isAddingAngles {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isAddingAngles)
            } header: {
                Text("アングル")
            } footer: {
                Text("「ずれ」は、別のカメラの映像とメインの映像のタイミングの差です。まず「自動で合わせる」を押すと、音を聞き比べて自動でそろえます。手で直すときは、口の動きと声が合うまで ±ボタンで調整します(+ にするとアングルの映像が先に進みます)。")
            }

            // 切替一覧
            Section {
                if clip.multicam.switches.isEmpty {
                    Text("切替はまだありません(最初はメインを使用)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clip.multicam.switches) { item in
                        switchRow(item, clip: clip, clipStart: clipStart)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteSwitch(id: item.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }
                    Button(role: .destructive) {
                        clearSwitches()
                    } label: {
                        Label("切替をすべて消去", systemImage: "trash")
                    }
                }
            } header: {
                Text("切替点")
            }
        }
    }

    // MARK: - 行

    private func angleRow(angle: CameraAngle, number: Int, clip: Clip) -> some View {
        let isSyncing = syncingAngleIDs.contains(angle.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let image = angle.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "video")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text("アングル\(number)")
                        .font(.headline)
                    Text(angle.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(String(format: "ずれ %+.2f 秒", angle.offset))
                        .font(.caption)
                        .monospacedDigit()
                }

                Spacer()

                Button(role: .destructive) {
                    deleteAngle(id: angle.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("このアングルを削除")
            }

            HStack(spacing: 6) {
                Button {
                    autoSync(angleID: angle.id)
                } label: {
                    HStack(spacing: 4) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "waveform")
                        }
                        Text("自動で合わせる")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isSyncing || !clip.hasAudio)

                Spacer()

                offsetButton("-0.1", delta: -0.1, angleID: angle.id)
                offsetButton("-0.01", delta: -0.01, angleID: angle.id)
                offsetButton("+0.01", delta: 0.01, angleID: angle.id)
                offsetButton("+0.1", delta: 0.1, angleID: angle.id)
            }

            Slider(value: offsetBinding(angleID: angle.id), in: -10...10)
            if !clip.hasAudio {
                Text("メインの動画に音がないため、自動で合わせられません。±ボタンで合わせてください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func offsetButton(_ title: String, delta: Double, angleID: UUID) -> some View {
        Button {
            adjustOffset(angleID: angleID, by: delta)
        } label: {
            Text(title)
                .font(.caption2)
                .monospacedDigit()
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("ずれを " + title + String(localized: " 秒"))
    }

    private func switchRow(_ item: AngleSwitch, clip: Clip, clipStart: Double) -> some View {
        let inRange = item.time >= clip.startTime && item.time <= clip.endTime
        let timelineTime = clipStart + (item.time - clip.startTime) / max(clip.speed, 0.01)
        return Button {
            if inRange {
                player.seek(to: timelineTime)
            }
        } label: {
            HStack {
                Text(MediaTimeText.precise(item.time))
                    .monospacedDigit()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(angleLabel(item.angle, clip: clip))
                Spacer()
                if !inRange {
                    Text("範囲外")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func angleLabel(_ n: Int, clip: Clip) -> String {
        if n <= 0 { return String(localized: "メイン") }
        if n <= clip.multicam.angles.count {
            return String(localized: "アングル\(n)")
        }
        return String(localized: "不明なアングル")
    }

    private var errorIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue { errorMessage = nil }
            }
        )
    }

    // MARK: - 編集操作

    private func updateClip(_ change: (inout Clip) -> Void) {
        guard let i = project.index(of: clipID) else { return }
        var clip = project.clips[i]
        change(&clip)
        project.clips[i] = clip
    }

    private func insertSwitch(angle n: Int) {
        guard let clipIndex = project.index(of: clipID),
              let location = project.locate(timelineTime: player.currentTime),
              location.index == clipIndex else {
            errorMessage = String(localized: "「先頭へ」を押して再生位置をこのクリップの中に移してから、切り替えボタンを押してください。")
            return
        }
        let time = location.sourceTime
        updateClip { clip in
            guard n >= 0, n <= clip.multicam.angles.count else { return }
            clip.multicam.switches.removeAll { abs($0.time - time) < 0.1 }
            clip.multicam.switches.append(AngleSwitch(time: time, angle: n))
            clip.multicam.sortSwitches()
        }
    }

    private func deleteSwitch(id: UUID) {
        updateClip { clip in
            clip.multicam.switches.removeAll { $0.id == id }
        }
    }

    private func clearSwitches() {
        updateClip { clip in
            clip.multicam.switches.removeAll()
        }
    }

    private func deleteAngle(id: UUID) {
        updateClip { clip in
            guard let i = clip.multicam.angles.firstIndex(where: { $0.id == id }) else { return }
            let number = i + 1
            clip.multicam.angles.remove(at: i)
            clip.multicam.switches.removeAll { $0.angle == number }
            for j in clip.multicam.switches.indices where clip.multicam.switches[j].angle > number {
                clip.multicam.switches[j].angle -= 1
            }
            clip.multicam.sortSwitches()
        }
    }

    private func setOffset(_ offset: Double, angleID: UUID) {
        let rounded = (offset * 1000).rounded() / 1000
        updateClip { clip in
            guard let i = clip.multicam.angles.firstIndex(where: { $0.id == angleID }) else { return }
            clip.multicam.angles[i].offset = rounded
        }
    }

    private func adjustOffset(angleID: UUID, by delta: Double) {
        guard let i = project.index(of: clipID),
              let angle = project.clips[i].multicam.angles.first(where: { $0.id == angleID }) else { return }
        setOffset(angle.offset + delta, angleID: angleID)
    }

    private func offsetBinding(angleID: UUID) -> Binding<Double> {
        Binding<Double>(
            get: {
                guard let i = project.index(of: clipID),
                      let angle = project.clips[i].multicam.angles.first(where: { $0.id == angleID }) else { return 0 }
                return min(max(angle.offset, -10), 10)
            },
            set: { newValue in
                setOffset(newValue, angleID: angleID)
            }
        )
    }

    private func autoSync(angleID: UUID) {
        guard let i = project.index(of: clipID),
              let angle = project.clips[i].multicam.angles.first(where: { $0.id == angleID }) else { return }
        let mainURL = project.clips[i].url
        let angleURL = angle.url
        syncingAngleIDs.insert(angleID)
        Task {
            do {
                let offset = try await AudioSync.estimateOffset(mainURL: mainURL, angleURL: angleURL)
                setOffset(offset, angleID: angleID)
            } catch {
                errorMessage = String(localized: "±ボタンで、口の動きと声が合うまで手で調整してください(両方の動画に同じ音が入っていないと自動では合わせられません)。\n\n詳細: ") + error.localizedDescription
            }
            syncingAngleIDs.remove(angleID)
        }
    }

    private func addAngles(_ items: [PhotosPickerItem]) async {
        isAddingAngles = true
        var failures: [String] = []
        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    let angle = try await MediaStore.makeAngle(from: movie.url)
                    guard project.index(of: clipID) != nil else { break }
                    updateClip { clip in
                        clip.multicam.angles.append(angle)
                    }
                } else {
                    failures.append(String(localized: "動画データを取得できませんでした。"))
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isAddingAngles = false
        if !failures.isEmpty {
            errorMessage = String(localized: "もう一度「アングルを追加」から選び直してください。\(failures.count)件の動画を追加できませんでした。\n") + failures.joined(separator: "\n")
        }
    }
}
