import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

/// マルチカメラ編集(別アングルの追加・同期・スイッチャーでの切替)
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
    /// メインと各アングルを並べて同時に再生する
    @State private var switcher = MulticamSwitcherController()
    /// 編集画面の合成の作り直しを止めているか(開いている間は止め、閉じたら 1 回だけ作り直す)
    @State private var holdsInteraction = false

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
        .onAppear { setUpSwitcher() }
        .onDisappear { tearDownSwitcher() }
        // アングルの追加・削除・ずれの変更をスイッチャーに伝える
        .onChange(of: switcherSource) { _, _ in
            if let i = project.index(of: clipID) {
                switcher.configure(clip: project.clips[i])
            }
        }
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
        GeometryReader { geo in
            VStack(spacing: 0) {
                // スイッチャーはリストの外に置く(リストの行の中に置いたボタンは、タップが届かないことがあった)
                MulticamSwitcherPanel(switcher: switcher,
                                      clip: clip,
                                      unreadableAngles: unreadableAngleNumbers(clip: clip),
                                      availableHeight: geo.size.height,
                                      onCut: { insertSwitch(angle: $0) })
                    .background(Color(uiColor: .systemGroupedBackground))
                Divider()
                angleAndSwitchList(clip: clip)
            }
        }
    }

    /// アングル一覧と切替点の一覧
    private func angleAndSwitchList(clip: Clip) -> some View {
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
                        switchRow(item, clip: clip)
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

    private func switchRow(_ item: AngleSwitch, clip: Clip) -> some View {
        let inRange = item.time >= clip.startTime && item.time <= clip.endTime
        return Button {
            if inRange {
                switcher.seek(to: item.time)
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

    /// スイッチャーの再生位置から、アングル n に切り替える
    private func insertSwitch(angle n: Int) {
        guard let clipIndex = project.index(of: clipID) else { return }
        let clip = project.clips[clipIndex]
        guard n >= 0, n <= clip.multicam.angles.count else { return }
        let time = min(max(switcher.sourceTime, clip.startTime), clip.endTime)
        // いま使っている映像のマスは、押しても切替点を増やさない
        if clip.multicam.angleIndex(at: time + MulticamSwitcherPanel.switchTolerance) == n {
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        // クリップの最後のコマでは切り替えても映らない(合成が出力 0.02 秒以下の区間を捨てる)ので、理由を出して止める。
        // 速度カーブも含めて出力の秒で見る
        let fps = Double(min(max(project.canvas.frameRate, 1), 120))
        let outputRemaining = clip.outputDuration - clip.outputOffset(atSourceTime: time)
        guard outputRemaining > max(1 / fps, 0.021), clip.endTime - time > 0.021 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            errorMessage = String(localized: "クリップの最後なので切り替えられません。帯をなぞって位置を戻してから切り替えてください。")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        updateClip { clip in
            clip.multicam.switches.removeAll { abs($0.time - time) < 0.1 }
            clip.multicam.switches.append(AngleSwitch(time: time, angle: n))
            clip.multicam.sortSwitches()
        }
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

    /// スイッチャーが使う素材の内容(変わったら用意し直す)
    private var switcherSource: [CameraAngle] {
        guard let i = project.index(of: clipID) else { return [] }
        return project.clips[i].multicam.angles
    }

    private func unreadableAngleNumbers(clip: Clip) -> Set<Int> {
        var numbers: Set<Int> = []
        for (index, angle) in clip.multicam.angles.enumerated()
        where unreadableAngleIDs.contains(angle.id) || ProjectStore.isUnavailablePhotoURL(angle.url) {
            numbers.insert(index + 1)
        }
        return numbers
    }

    /// 開いたとき: 編集画面のプレビューを止めて、スイッチャーをいまの位置(クリップの外なら先頭)から用意する
    private func setUpSwitcher() {
        guard let clipIndex = project.index(of: clipID) else { return }
        player.pause()
        if !holdsInteraction {
            holdsInteraction = true
            // 切り替えるたびに編集画面の合成を作り直さない(閉じたときに 1 回だけ作り直す)
            player.beginInteraction()
        }
        let clip = project.clips[clipIndex]
        var start = clip.startTime
        if let location = project.locate(timelineTime: player.currentTime), location.index == clipIndex {
            start = location.sourceTime
        }
        switcher.configure(clip: clip)
        switcher.seek(to: start)
    }

    /// 閉じたとき: スイッチャーを止め、編集画面の再生位置をスイッチャーで止めた位置に合わせる
    private func tearDownSwitcher() {
        let sourceTime = switcher.sourceTime
        switcher.stop()
        if let clipIndex = project.index(of: clipID) {
            let starts = project.clipStartTimes()
            if clipIndex < starts.count {
                let clip = project.clips[clipIndex]
                player.seek(to: starts[clipIndex] + clip.outputOffset(atSourceTime: sourceTime))
            }
        }
        if holdsInteraction {
            holdsInteraction = false
            player.endInteraction()
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
