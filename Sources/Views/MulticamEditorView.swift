import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

/// マルチカメラ編集(別アングルの追加・同期・ライブ切替)
struct MulticamEditorView: View {
    let project: EditorProject
    let player: PlayerController
    let clipID: UUID

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isAddingAngles = false
    @State private var syncingAngleIDs: Set<UUID> = []
    @State private var errorMessage: String?
    /// 「切替をすべて消去」の確認
    @State private var isClearSwitchesPresented = false
    /// 切替に使われているアングルを消す前の確認(消すアングル)
    @State private var pendingDeleteAngleID: UUID?
    /// 読み込めなかったアングル(合成ではメインの映像になる)
    @State private var unreadableAngleIDs: Set<UUID> = []
    /// 最後に押した切替(押したことが画面で分かるように出す)
    @State private var lastSwitchNote: String?

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
        // 再生位置がこのクリップの外だとボタンが効かないので、開いたらクリップの先頭へ移す
        .onAppear { moveIntoClipIfNeeded() }
        .task(id: angleIDs) { await checkAngles() }
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
        .confirmationDialog("切替をすべて消去しますか?",
                            isPresented: $isClearSwitchesPresented,
                            titleVisibility: .visible) {
            Button("すべて消去", role: .destructive) {
                clearSwitches()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("\(switchTotal) 件の切替点を消します。")
        }
        .confirmationDialog("このアングルを削除しますか?",
                            isPresented: Binding(get: { pendingDeleteAngleID != nil },
                                                 set: { if !$0 { pendingDeleteAngleID = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDeleteAngleID) { id in
            Button("削除", role: .destructive) {
                deleteAngle(id: id)
            }
            Button("キャンセル", role: .cancel) { }
        } message: { id in
            Text(String(localized: "このアングルへの切替 \(switchCount(usingAngle: id)) 件も消えます。"))
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

        VStack(spacing: 0) {
            // ライブ切替はリストの外に置く(リストの行の中の横スクロールに置いたボタンは、タップが届かないことがあった)
            liveSwitchPanel(clip: clip, isInClip: isInClip, currentSourceTime: currentSourceTime, clipStart: clipStart)
            Divider()
            List {
                // アングル一覧
                Section {
                    ForEach(Array(clip.multicam.angles.enumerated()), id: \.element.id) { index, angle in
                        angleRow(angle: angle, number: index + 1, clip: clip)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    requestDeleteAngle(id: angle.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }

                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: nil,
                                 selectionBehavior: .ordered,
                                 matching: .videos,
                                 preferredItemEncoding: .current,
                                 photoLibrary: .shared()) {
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
                    Text("「自動で合わせる」は音でそろえます。手で直すときは、+ にするとアングルの映像が先に進みます。")
                }

                // 切替一覧
                Section {
                    if clip.multicam.switches.isEmpty {
                        Text("切替はまだありません")
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
                            isClearSwitchesPresented = true
                        } label: {
                            Label("切替をすべて消去", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("切替点")
                }
            }
        }
    }

    // MARK: - ライブ切替

    private func liveSwitchPanel(clip: Clip, isInClip: Bool, currentSourceTime: Double?, clipStart: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewView(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.black)

            HStack(spacing: 16) {
                Button {
                    if !isInClip {
                        player.seek(to: clipStart)
                    }
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)

                VStack(alignment: .leading, spacing: 2) {
                    Text(MediaTimeText.mmss(player.currentTime))
                        .monospacedDigit()
                    if let sourceTime = currentSourceTime {
                        Text("現在: \(angleLabel(clip.multicam.angleIndex(at: sourceTime + Self.switchTolerance), clip: clip))")
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
            .padding(.horizontal, 16)

            if clip.multicam.angles.isEmpty {
                Text("別のカメラの動画を「アングルを追加」で入れると、再生しながら切り替えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0...clip.multicam.angles.count, id: \.self) { n in
                            let isCurrent = currentSourceTime.map {
                                clip.multicam.angleIndex(at: $0 + Self.switchTolerance) == n
                            } ?? false
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
                            // 外にいるときも押せるようにして、押したら理由を出す(灰色で黙って効かないのを避ける)
                            .opacity(isInClip ? 1 : 0.5)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }

                Text("再生中にボタンをタップすると、その時点からアングルが切り替わります。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if let note = lastSwitchNote {
                    Label(note, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 16)
                }
                if let warning = coverageWarning(clip: clip, sourceTime: currentSourceTime) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// 切替点の判定の余裕(秒)。シークの丸めで再生位置が切替点のわずかに手前になっても、切り替えたあとのアングルとして扱う
    private static let switchTolerance = 0.002

    // MARK: - 行

    private func angleRow(angle: CameraAngle, number: Int, clip: Clip) -> some View {
        let isSyncing = syncingAngleIDs.contains(angle.id)
        // 写真ライブラリからいま読み出せないアングル(プロジェクトには残してある)
        let isUnavailable = ProjectStore.isUnavailablePhotoURL(angle.url)
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
                .disabled(isSyncing || !clip.hasAudio || isUnavailable)

                Spacer()

                offsetButton("-0.1", delta: -0.1, angleID: angle.id)
                offsetButton("-0.01", delta: -0.01, angleID: angle.id)
                offsetButton("+0.01", delta: 0.01, angleID: angle.id)
                offsetButton("+0.1", delta: 0.1, angleID: angle.id)
            }

            Slider(value: offsetBinding(angleID: angle.id), in: -10...10)
            if !isUnavailable && unreadableAngleIDs.contains(angle.id) {
                Text("この動画を読み込めないため、このアングルの区間はメインの映像になります。削除して「アングルを追加」から入れ直してください。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if isUnavailable {
                Text("写真ライブラリからこの動画を読み出せないため、このアングルの区間はメインの映像になります。写真へのアクセスを許可してプロジェクトを開き直すと戻ります。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
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

    /// いまの切替点の数(「切替をすべて消去」の確認用)
    private var switchTotal: Int {
        guard let i = project.index(of: clipID) else { return 0 }
        return project.clips[i].multicam.switches.count
    }

    /// このアングルを消すと一緒に消える切替の数(アングル番号は 1 から)
    private func switchCount(usingAngle id: UUID) -> Int {
        guard let i = project.index(of: clipID),
              let angleIndex = project.clips[i].multicam.angles.firstIndex(where: { $0.id == id }) else { return 0 }
        let number = angleIndex + 1
        return project.clips[i].multicam.switches.filter { $0.angle == number }.count
    }

    /// 切替に使われているアングルは、切替も消えることを確かめてから削除する
    private func requestDeleteAngle(id: UUID) {
        if switchCount(usingAngle: id) > 0 {
            pendingDeleteAngleID = id
        } else {
            deleteAngle(id: id)
        }
    }

    private func insertSwitch(angle n: Int) {
        guard let clipIndex = project.index(of: clipID),
              let location = project.locate(timelineTime: player.currentTime),
              location.index == clipIndex else {
            errorMessage = String(localized: "「先頭へ」で再生位置をこのクリップに移してから切り替えてください。")
            return
        }
        // いま映っているコマの頭を切替点にする。止めた位置の秒はコマの途中のことが多く、そのコマはメインのまま残っていた
        let fps = Double(min(max(project.canvas.frameRate, 1), 120))
        let frameHead = (player.currentTime * fps + 1e-6).rounded(.down) / fps
        let clipStartSource = project.clips[clipIndex].startTime
        var time = location.sourceTime
        if let headSource = project.sourceTime(timelineTime: frameHead, inClip: clipID) {
            time = min(location.sourceTime, max(clipStartSource, headSource))
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lastSwitchNote = String(localized: "\(MediaTimeText.precise(time)) から\(angleLabel(n, clip: project.clips[clipIndex]))に切り替えました")
        updateClip { clip in
            guard n >= 0, n <= clip.multicam.angles.count else { return }
            clip.multicam.switches.removeAll { abs($0.time - time) < 0.1 }
            clip.multicam.switches.append(AngleSwitch(time: time, angle: n))
            clip.multicam.sortSwitches()
        }
    }

    /// いまの位置で選ばれているアングルの映像が出せないときの説明(出せるなら nil)
    private func coverageWarning(clip: Clip, sourceTime: Double?) -> String? {
        guard let t = sourceTime else { return nil }
        let n = clip.multicam.angleIndex(at: t + Self.switchTolerance)
        guard n > 0, n <= clip.multicam.angles.count else { return nil }
        let angle = clip.multicam.angles[n - 1]
        if unreadableAngleIDs.contains(angle.id) || ProjectStore.isUnavailablePhotoURL(angle.url) {
            return String(localized: "アングル\(n)の動画を読み込めないため、メインの映像が出ています。")
        }
        let angleTime = t + angle.offset
        if angleTime < 0 || angleTime > angle.duration {
            let offsetText = String(format: "%+.2f", angle.offset)
            return String(localized: "この位置にはアングル\(n)の映像がないため、メインの映像が出ています(ずれ \(offsetText) 秒)。ずれを直してください。")
        }
        return nil
    }

    private var angleIDs: [UUID] {
        guard let i = project.index(of: clipID) else { return [] }
        return project.clips[i].multicam.angles.map(\.id)
    }

    /// アングルの動画が読めるかを確かめる(読めないと合成で黙ってメインになる)
    private func checkAngles() async {
        guard let i = project.index(of: clipID) else { return }
        var unreadable: Set<UUID> = []
        for angle in project.clips[i].multicam.angles where !ProjectStore.isUnavailablePhotoURL(angle.url) {
            let tracks = try? await AVURLAsset(url: angle.url).loadTracks(withMediaType: .video)
            if tracks?.isEmpty ?? true {
                unreadable.insert(angle.id)
            }
        }
        if Task.isCancelled { return }
        unreadableAngleIDs = unreadable
    }

    private func moveIntoClipIfNeeded() {
        guard let clipIndex = project.index(of: clipID),
              project.locate(timelineTime: player.currentTime)?.index != clipIndex else { return }
        let starts = project.clipStartTimes()
        guard clipIndex < starts.count else { return }
        player.seek(to: starts[clipIndex])
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
                errorMessage = String(localized: "両方の動画に同じ音が無いと自動では合わせられません。±ボタンで手で合わせてください。\n\n詳細: ") + error.localizedDescription
            }
            syncingAngleIDs.remove(angleID)
        }
    }

    private func addAngles(_ items: [PhotosPickerItem]) async {
        isAddingAngles = true
        var failures: [String] = []
        for item in items {
            do {
                // スローモーション・iCloud にしかない動画なども受け取れるよう、メインの取り込みと同じ手順で読む
                let url = try await MovieImporter.importMovie(item)
                let angle = try await MediaStore.makeAngle(from: url)
                guard project.index(of: clipID) != nil else { break }
                updateClip { clip in
                    clip.multicam.angles.append(angle)
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
