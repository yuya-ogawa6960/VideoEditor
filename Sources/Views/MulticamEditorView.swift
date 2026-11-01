import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

/// マルチカメラ編集(別アングルの追加・音声での同期・スイッチャーでの切替)
struct MulticamEditorView: View {
    let project: EditorProject
    let player: PlayerController
    let clipID: UUID

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isAddingAngles = false
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

    // MARK: 音声同期の状態

    /// シートが開いているか(閉じたあとに同期の結果を書き込まない)
    @State private var isPresented = false
    /// 順番待ちのアングル(先頭から 1 本ずつ同期する)
    @State private var syncQueue: [UUID] = []
    @State private var syncTask: Task<Void, Never>?
    /// 同期の世代(やめる・閉じるで増やす。古い同期が、あとから状態を書き換えないように)
    @State private var syncGeneration = 0
    @State private var syncingAngleID: UUID?
    @State private var syncProgress: Double = 0
    @State private var syncDone = 0
    @State private var syncTotal = 0
    /// 候補から精査し直すときの、始めのずれ(アングルごと)
    @State private var syncStartingOffsets: [UUID: Double] = [:]
    /// 同期の結果のひとこと(アングルごと)
    @State private var syncNotes: [UUID: SyncNote] = [:]
    /// 直前に戻すための値(アングルごと)
    @State private var syncUndo: [UUID: AngleTiming] = [:]
    /// ほかの候補(メインの時刻での見かけのずれ。アングルごと)
    @State private var syncCandidates: [UUID: [Double]] = [:]
    /// 「確かめる」で再生する位置(メインの元素材上の秒。アングルごと)
    @State private var syncCheckTimes: [UUID: Double] = [:]
    /// 音声トラックがないと分かったアングル
    @State private var silentAngleIDs: Set<UUID> = []
    /// 「すべて音声で同期」で、手で直したアングルがあるときの確認
    @State private var pendingSyncAllIDs: [UUID] = []
    @State private var isResyncManualPresented = false
    /// 数値でずれを入力する
    @State private var isOffsetEntryPresented = false
    @State private var offsetEntryTargetID: UUID?
    @State private var offsetEntryText = ""

    var body: some View {
        mainContent
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

    /// 画面の中身と、音声同期の確認・入力
    private var mainContent: some View {
        Group {
            if let clipIndex = project.index(of: clipID) {
                content(clip: project.clips[clipIndex], clipIndex: clipIndex)
            } else {
                ContentUnavailableView("クリップが見つかりません", systemImage: "film")
            }
        }
        .confirmationDialog("手で直したアングルも同期し直しますか?",
                            isPresented: $isResyncManualPresented,
                            titleVisibility: .visible) {
            Button("すべて同期し直す") {
                let ids = pendingSyncAllIDs
                pendingSyncAllIDs = []
                enqueueSync(ids)
            }
            Button("手で直したものは残す") {
                let ids = pendingSyncAllIDs.filter { !isManual(angleID: $0) }
                pendingSyncAllIDs = []
                enqueueSync(ids)
            }
            Button("キャンセル", role: .cancel) {
                pendingSyncAllIDs = []
            }
        }
        .alert("ずれを入力", isPresented: $isOffsetEntryPresented) {
            TextField("例: 12.5 / -1:02.5", text: $offsetEntryText)
                .keyboardType(.numbersAndPunctuation)
            Button("決定") {
                applyOffsetEntry()
            }
            Button("キャンセル", role: .cancel) {
                offsetEntryTargetID = nil
            }
        } message: {
            Text("+ にするとアングルの映像が先に進みます。")
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
                angleSectionHeader(clip: clip)
            } footer: {
                Text("追加すると、音声で自動的に同期します。手で直すときは、+ にするとアングルの映像が先に進みます。")
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

    /// アングルの見出し(まとめて同期・進み具合・やめる)
    private func angleSectionHeader(clip: Clip) -> some View {
        HStack(spacing: 8) {
            Text("アングル")
            Spacer()
            if syncTask != nil {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: "\(min(syncDone + 1, max(syncTotal, 1)))/\(max(syncTotal, 1))")
                    .monospacedDigit()
                Button("キャンセル") {
                    cancelSync()
                }
                .buttonStyle(.borderless)
            } else if clip.multicam.angles.count >= 2 {
                Button {
                    requestSyncAll(clip: clip)
                } label: {
                    Label("すべて音声で同期", systemImage: "waveform")
                }
                .buttonStyle(.borderless)
                .disabled(syncableAngleIDs(clip: clip).isEmpty)
            }
        }
        .textCase(nil)
    }

    // MARK: - 行

    private func angleRow(angle: CameraAngle, number: Int, clip: Clip) -> some View {
        // 写真ライブラリからいま読み出せないアングル(プロジェクトには残してある)
        let isUnavailable = ProjectStore.isUnavailablePhotoURL(angle.url)
        let isUnreadable = !isUnavailable && unreadableAngleIDs.contains(angle.id)
        let isSilent = angle.hasAudio == false || silentAngleIDs.contains(angle.id)
        let isSyncing = syncingAngleID == angle.id
        let isQueued = syncQueue.contains(angle.id)
        let center = clipCenter(clip)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
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
                    HStack(spacing: 6) {
                        Text("アングル\(number)")
                            .font(.headline)
                        syncBadge(angle: angle, isSyncing: isSyncing, isQueued: isQueued)
                    }
                    Text(angle.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("ずれ \(AudioSyncCore.formatOffset(angle.localOffset(atMain: center))) 秒")
                        .font(.caption)
                        .monospacedDigit()
                    if angle.rate != 1 {
                        Text("時計のずれを補正(1時間で \(AudioSyncCore.formatOffset((angle.rate - 1) * 3600)) 秒)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Button {
                    enqueueSync([angle.id])
                } label: {
                    Label("音声で同期", systemImage: "waveform")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncing || isQueued || !canSync(angle: angle, clip: clip))

                Spacer()

                frameButton(-1, angleID: angle.id)
                frameButton(1, angleID: angle.id)
                adjustMenu(angle: angle, number: number, clip: clip)
            }

            if isSyncing {
                ProgressView(value: min(max(syncProgress, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                if let note = syncNotes[angle.id] {
                    noteRow(note, angle: angle, number: number, clip: clip)
                }
                if let candidates = syncCandidates[angle.id], !candidates.isEmpty {
                    candidateRow(candidates, angleID: angle.id)
                }
            }

            if isUnreadable {
                Text("この動画を読み込めないため、このアングルの区間はメインの映像になります。削除して「アングルを追加」から入れ直してください。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if isUnavailable {
                Text("写真ライブラリからこの動画を読み出せないため、このアングルの区間はメインの映像になります。写真へのアクセスを許可してプロジェクトを開き直すと戻ります。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if isSilent && !isUnavailable && !isUnreadable {
                Text("このアングルには音がないため、音声で同期できません。±1コマで合わせてください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !clip.hasAudio {
                Text("メインに音がありません。1つのアングルを手で合わせると、ほかのアングルはその音で同期できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func syncBadge(angle: CameraAngle, isSyncing: Bool, isQueued: Bool) -> some View {
        if isSyncing {
            badge(String(localized: "同期中"), color: .accentColor)
        } else if isQueued {
            badge(String(localized: "待機中"), color: .secondary)
        } else {
            switch angle.syncState {
            case .synced:
                badge(String(localized: "同期OK"), color: .green)
            case .needsCheck:
                badge(String(localized: "要確認"), color: .orange)
            case .manual:
                badge(String(localized: "手動"), color: .blue)
            case .stale:
                badge(String(localized: "素材変更"), color: .red)
            case nil:
                if angle.offset == 0 && angle.rate == 1 {
                    badge(String(localized: "未同期"), color: .secondary)
                } else {
                    badge(String(localized: "手動"), color: .blue)
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    /// 1 コマずつ動かす(長押しで続けて動く)
    private func frameButton(_ frames: Int, angleID: UUID) -> some View {
        Button {
            nudge(angleID: angleID, by: Double(frames) / projectFrameRate)
        } label: {
            Text(frames < 0 ? LocalizedStringKey("−1コマ") : LocalizedStringKey("+1コマ"))
                .font(.caption2)
                .monospacedDigit()
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(frames < 0 ? String(localized: "1コマ前へずらす") : String(localized: "1コマ先へずらす"))
    }

    /// ずれの細かい調整(秒単位・数値入力・元に戻す・時計の補正をやめる・耳で確かめる)
    private func adjustMenu(angle: CameraAngle, number: Int, clip: Clip) -> some View {
        Menu {
            Button("+0.1秒") { nudge(angleID: angle.id, by: 0.1) }
            Button("−0.1秒") { nudge(angleID: angle.id, by: -0.1) }
            Button("+1秒") { nudge(angleID: angle.id, by: 1) }
            Button("−1秒") { nudge(angleID: angle.id, by: -1) }
            Button {
                beginOffsetEntry(angle: angle, clip: clip)
            } label: {
                Label("数値で入力…", systemImage: "keyboard")
            }
            Button {
                checkByEar(angleNumber: number, angleID: angle.id, clip: clip)
            } label: {
                Label("耳で確かめる", systemImage: "ear")
            }
            if syncUndo[angle.id] != nil {
                Button {
                    undoTiming(angleID: angle.id)
                } label: {
                    Label("直前に戻す", systemImage: "arrow.uturn.backward")
                }
            }
            if angle.rate != 1 {
                Button {
                    removeDriftCorrection(angleID: angle.id, clip: clip)
                } label: {
                    Label("時計の補正をやめる", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        // リストの行の中では、スタイルを決めないと行全体がメニューを開くボタンになる
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("ずれの調整")
    }

    private func noteRow(_ note: SyncNote, angle: CameraAngle, number: Int, clip: Clip) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.symbol)
                .foregroundStyle(note.color)
            Text(note.text)
                .font(.caption)
                .foregroundStyle(note.kind == .failure ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if note.kind == .success || note.kind == .warning {
                if syncUndo[angle.id] != nil {
                    Button("元に戻す") {
                        undoTiming(angleID: angle.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Button("確かめる") {
                    checkByEar(angleNumber: number, angleID: angle.id, clip: clip)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    /// ほかの候補(タップするとそのずれから精査し直す)
    private func candidateRow(_ candidates: [Double], angleID: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("ほかの候補")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(Array(candidates.prefix(3).enumerated()), id: \.offset) { _, value in
                    Button(AudioSyncCore.formatOffset(value)) {
                        trySyncCandidate(value, angleID: angleID)
                    }
                    .font(.caption2.monospacedDigit())
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
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

    /// アングルの動画が読めるか(読めないと合成で黙ってメインになる)と、音声トラックがあるかを確かめる
    private func checkAngles() async {
        guard let i = project.index(of: clipID) else { return }
        var unreadable: Set<UUID> = []
        var silent: Set<UUID> = []
        for angle in project.clips[i].multicam.angles where !ProjectStore.isUnavailablePhotoURL(angle.url) {
            let asset = AVURLAsset(url: angle.url)
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            if tracks?.isEmpty ?? true {
                unreadable.insert(angle.id)
            }
            // 古いプロジェクトのアングルは、音声トラックの有無をここで調べる
            if angle.hasAudio == nil, let audio = try? await asset.loadTracks(withMediaType: .audio), audio.isEmpty {
                silent.insert(angle.id)
            }
        }
        if Task.isCancelled { return }
        unreadableAngleIDs = unreadable
        silentAngleIDs.formUnion(silent)
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
        isPresented = true
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

    /// 閉じたとき: 同期を止め、スイッチャーを止め、編集画面の再生位置をスイッチャーで止めた位置に合わせる
    private func tearDownSwitcher() {
        isPresented = false
        cancelSync()
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
        if syncingAngleID == id {
            // 解析を止めて(世代も進む)、残りの順番待ちを続ける
            let rest = syncQueue.filter { $0 != id }
            var starts = syncStartingOffsets
            starts[id] = nil
            cancelSync()
            syncStartingOffsets = starts
            enqueueSync(rest)
        } else if let k = syncQueue.firstIndex(of: id) {
            syncQueue.remove(at: k)
            syncStartingOffsets[id] = nil
            syncTotal = max(syncTotal - 1, 1)
        }
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

    // MARK: - 手で合わせる

    private var projectFrameRate: Double {
        Double(min(max(project.canvas.frameRate, 1), 120))
    }

    private func clipCenter(_ clip: Clip) -> Double {
        (clip.startTime + clip.endTime) / 2
    }

    private func currentAngle(_ angleID: UUID) -> CameraAngle? {
        guard let i = project.index(of: clipID) else { return nil }
        return project.clips[i].multicam.angles.first(where: { $0.id == angleID })
    }

    /// 手で決めた対応を書き込む(このクリップだけ。直前の値を「直前に戻す」用に残す)
    private func setManualTiming(angleID: UUID, offset: Double, rate: Double) {
        guard let angle = currentAngle(angleID) else { return }
        dequeueSync(angleID)
        syncUndo[angleID] = AngleTiming(angle)
        syncNotes[angleID] = nil
        syncCandidates[angleID] = nil
        let roundedOffset = Self.roundedOffset(offset)
        updateClip { clip in
            guard let i = clip.multicam.angles.firstIndex(where: { $0.id == angleID }) else { return }
            clip.multicam.angles[i].offset = roundedOffset
            clip.multicam.angles[i].rate = rate
            // 別のアングルの音で合わせた値を手で直したときも、経由元は残す(耳で確かめるときに、その音と比べる)
            clip.multicam.angles[i].syncState = .manual
        }
    }

    private func nudge(angleID: UUID, by delta: Double) {
        guard let angle = currentAngle(angleID) else { return }
        setManualTiming(angleID: angleID, offset: angle.offset + delta, rate: angle.rate)
    }

    /// 時計の補正をやめる(クリップの中央での見かけのずれを、そのまま一定のずれにする)
    private func removeDriftCorrection(angleID: UUID, clip: Clip) {
        guard let angle = currentAngle(angleID) else { return }
        setManualTiming(angleID: angleID, offset: angle.localOffset(atMain: clipCenter(clip)), rate: 1)
    }

    private func beginOffsetEntry(angle: CameraAngle, clip: Clip) {
        offsetEntryTargetID = angle.id
        offsetEntryText = AudioSyncCore.formatOffset(angle.localOffset(atMain: clipCenter(clip)))
        isOffsetEntryPresented = true
    }

    /// 入力されたずれ(クリップの中央での見かけのずれ)にする
    private func applyOffsetEntry() {
        guard let angleID = offsetEntryTargetID else { return }
        offsetEntryTargetID = nil
        guard let value = AudioSyncCore.parseOffset(offsetEntryText) else {
            errorMessage = String(localized: "ずれを読み取れませんでした。例: 12.5 / -1:02.5")
            return
        }
        guard let i = project.index(of: clipID), let angle = currentAngle(angleID) else { return }
        let center = clipCenter(project.clips[i])
        setManualTiming(angleID: angleID, offset: value - (angle.rate - 1) * center, rate: angle.rate)
    }

    private func undoTiming(angleID: UUID) {
        guard let previous = syncUndo[angleID], let angle = currentAngle(angleID) else { return }
        dequeueSync(angleID)
        applyAngleTiming(angleID: angleID, before: AngleTiming(angle), after: previous)
        syncUndo[angleID] = nil
        syncCandidates[angleID] = nil
        syncNotes[angleID] = SyncNote(kind: .info, text: String(localized: "元に戻しました"))
    }

    /// メインと、そのアングルの音を一緒に鳴らして、よく一致した位置の少し前から再生する
    private func checkByEar(angleNumber: Int, angleID: UUID, clip: Clip) {
        // 別のアングルの音で合わせたもの(メインに音がないときなど)は、そのアングルの音と比べる
        var reference = 0
        if let referenceID = clip.multicam.angles.first(where: { $0.id == angleID })?.syncReferenceID,
           let r = clip.multicam.angles.firstIndex(where: { $0.id == referenceID }) {
            reference = r + 1
        }
        switcher.setListening(angleNumber, reference: reference)
        let target = syncCheckTimes[angleID] ?? clipCenter(clip)
        switcher.seek(to: max(clip.startTime, target - 1.5))
        switcher.play()
    }

    /// 対応を書き込む。分割で同じアングルを持つほかのクリップ(同じ素材で、書き込む前の値が同じもの)にも書く。
    /// 書いたほかのクリップの数を返す
    @discardableResult
    private func applyAngleTiming(angleID: UUID, before: AngleTiming, after: AngleTiming) -> Int {
        guard let targetIndex = project.index(of: clipID) else { return 0 }
        var clips = project.clips
        guard let target = clips[targetIndex].multicam.angles.first(where: { $0.id == angleID }) else { return 0 }
        let mainURL = clips[targetIndex].url
        let offset = Self.roundedOffset(after.offset)
        var others = 0
        for c in clips.indices {
            guard let a = clips[c].multicam.angles.firstIndex(where: { $0.id == angleID }) else { continue }
            if c != targetIndex {
                let angle = clips[c].multicam.angles[a]
                guard clips[c].url == mainURL, angle.url == target.url,
                      angle.offset == before.offset, angle.rate == before.rate else { continue }
                others += 1
            }
            clips[c].multicam.angles[a].offset = offset
            clips[c].multicam.angles[a].rate = after.rate
            clips[c].multicam.angles[a].syncState = after.syncState
            clips[c].multicam.angles[a].syncReferenceID = after.syncReferenceID
        }
        project.clips = clips
        return others
    }

    /// ずれは 0.1 ミリ秒単位で持つ
    private static func roundedOffset(_ offset: Double) -> Double {
        (offset * 10_000).rounded() / 10_000
    }

    // MARK: - 音声で同期

    /// 手で合わせたアングル(古いプロジェクトで、ずれが 0 でないものも含む)
    private func isManual(_ angle: CameraAngle) -> Bool {
        angle.syncState == .manual || (angle.syncState == nil && (angle.offset != 0 || angle.rate != 1))
    }

    private func isManual(angleID: UUID) -> Bool {
        currentAngle(angleID).map { isManual($0) } ?? false
    }

    /// 音声で同期できるか(メインに音がないときは、合わせ済みで音のあるほかのアングルを経由する)
    private func canSync(angle: CameraAngle, clip: Clip) -> Bool {
        if ProjectStore.isUnavailablePhotoURL(angle.url) || unreadableAngleIDs.contains(angle.id) { return false }
        if angle.hasAudio == false || silentAngleIDs.contains(angle.id) { return false }
        if clip.hasAudio { return true }
        return !referenceAngles(for: angle, in: clip).isEmpty
    }

    private func syncableAngleIDs(clip: Clip) -> [UUID] {
        clip.multicam.angles.filter { canSync(angle: $0, clip: clip) }.map(\.id)
    }

    /// 経由に使えるほかのアングル(音があり、合わせ済みのもの。同期OK → 手動 → 要確認 の順)
    private func referenceAngles(for angle: CameraAngle, in clip: Clip) -> [CameraAngle] {
        func rank(_ a: CameraAngle) -> Int? {
            switch a.syncState {
            case .synced: return 0
            case .manual: return 1
            case .needsCheck: return 2
            case .stale: return nil
            case nil: return (a.offset != 0 || a.rate != 1) ? 1 : nil
            }
        }
        var ranked: [(rank: Int, angle: CameraAngle)] = []
        for other in clip.multicam.angles where other.id != angle.id {
            guard other.hasAudio != false, !silentAngleIDs.contains(other.id),
                  !unreadableAngleIDs.contains(other.id), !ProjectStore.isUnavailablePhotoURL(other.url),
                  !referenceChainReaches(angle.id, from: other, in: clip),
                  let r = rank(other) else { continue }
            ranked.append((r, other))
        }
        return ranked.sorted { $0.rank < $1.rank }.map { $0.angle }
    }

    /// other の経由元をたどると angleID に戻るか(経由の輪を作らない)
    private func referenceChainReaches(_ angleID: UUID, from other: CameraAngle, in clip: Clip) -> Bool {
        var current = other.syncReferenceID
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted {
            if id == angleID { return true }
            current = clip.multicam.angles.first(where: { $0.id == id })?.syncReferenceID
        }
        return false
    }

    private func requestSyncAll(clip: Clip) {
        let ids = syncableAngleIDs(clip: clip)
        guard !ids.isEmpty else { return }
        let hasManual = clip.multicam.angles.contains { ids.contains($0.id) && isManual($0) }
        if hasManual {
            pendingSyncAllIDs = ids
            isResyncManualPresented = true
        } else {
            enqueueSync(ids)
        }
    }

    private func trySyncCandidate(_ offset: Double, angleID: UUID) {
        syncStartingOffsets[angleID] = offset
        enqueueSync([angleID])
    }

    /// 順番待ちに入れる(1 本ずつ同期する)
    private func enqueueSync(_ ids: [UUID]) {
        guard isPresented else { return }
        var added = 0
        for id in ids where id != syncingAngleID && !syncQueue.contains(id) {
            syncQueue.append(id)
            syncNotes[id] = nil
            added += 1
        }
        guard added > 0 else { return }
        if syncTask == nil {
            syncDone = 0
            syncTotal = syncQueue.count
            let generation = syncGeneration
            syncTask = Task { await runSyncQueue(generation: generation) }
        } else {
            syncTotal += added
        }
    }

    /// 手で直したアングルは順番待ちから外す(待っている間に直した値を、あとの自動同期で上書きしない)
    private func dequeueSync(_ angleID: UUID) {
        guard let k = syncQueue.firstIndex(of: angleID) else { return }
        syncQueue.remove(at: k)
        syncTotal = max(syncTotal - 1, syncDone + 1)
        syncStartingOffsets[angleID] = nil
    }

    private func cancelSync() {
        syncGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        syncQueue = []
        syncingAngleID = nil
        syncStartingOffsets = [:]
    }

    private func runSyncQueue(generation: Int) async {
        while !Task.isCancelled, generation == syncGeneration, isPresented, !syncQueue.isEmpty {
            let angleID = syncQueue.removeFirst()
            syncingAngleID = angleID
            syncProgress = 0
            await syncAngle(angleID, generation: generation)
            guard generation == syncGeneration else { return }
            syncingAngleID = nil
            syncDone += 1
        }
        guard generation == syncGeneration else { return }
        syncQueue = []
        syncingAngleID = nil
        syncTask = nil
    }

    private func syncAngle(_ angleID: UUID, generation: Int) async {
        guard let clipIndex = project.index(of: clipID) else { return }
        let clip = project.clips[clipIndex]
        guard let angle = clip.multicam.angles.first(where: { $0.id == angleID }) else { return }
        let before = AngleTiming(angle)
        let focus = clip.startTime...max(clip.startTime + 0.1, clip.endTime)
        let startingOffset = syncStartingOffsets.removeValue(forKey: angleID)
        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in
                if generation == syncGeneration && syncingAngleID == angleID {
                    syncProgress = value
                }
            }
        }

        var outcome: SyncOutcome? = nil
        var failure: Error? = nil
        do {
            let result = try await AudioSync.analyze(referenceURL: clip.url, angleURL: angle.url, focus: focus,
                                                     startingOffset: startingOffset, progress: progress)
            outcome = SyncOutcome(timing: AngleTiming(offset: result.offset, rate: result.rate,
                                                      syncState: result.confidence == .high ? .synced : .needsCheck,
                                                      syncReferenceID: nil),
                                  result: result, referenceNumber: nil, checkTime: result.checkTime)
        } catch {
            failure = error
        }
        guard !Task.isCancelled, generation == syncGeneration, isPresented else {
            trackSync(result: "cancel", angle: angle, outcome: nil)
            return
        }
        // メインと合わないとき(メインに音がない・重ならないなど)は、合わせ済みのほかのアングルの音で試す
        if outcome == nil, Self.canTryOtherAngle(failure) {
            outcome = await syncViaOtherAngle(angle: angle, clip: clip, focus: focus, progress: progress)
            guard !Task.isCancelled, generation == syncGeneration, isPresented else {
                trackSync(result: "cancel", angle: angle, outcome: nil)
                return
            }
        }
        guard let outcome else {
            reportSyncFailure(failure, angleID: angleID)
            trackSync(result: "fail", angle: angle, outcome: nil)
            return
        }
        if applySyncOutcome(outcome, angle: angle, before: before, clip: clip) {
            trackSync(result: outcome.timing.syncState == .synced ? "high" : "medium", angle: angle, outcome: outcome)
        } else {
            trackSync(result: "skipped", angle: angle, outcome: outcome)
        }
    }

    private static func canTryOtherAngle(_ error: Error?) -> Bool {
        guard let error = error as? AudioSyncError else { return false }
        switch error {
        case .weakCorrelation, .noOverlap, .referenceHasNoAudio, .tooShort:
            return true
        case .angleHasNoAudio, .readFailed:
            return false
        }
    }

    /// ほかのアングルの音で合わせ、その対応とつなぐ
    private func syncViaOtherAngle(angle: CameraAngle, clip: Clip, focus: ClosedRange<Double>,
                                   progress: @escaping @Sendable (Double) -> Void) async -> SyncOutcome? {
        for reference in referenceAngles(for: angle, in: clip) {
            if Task.isCancelled { return nil }
            let a = reference.angleTime(atMain: focus.lowerBound)
            let b = reference.angleTime(atMain: focus.upperBound)
            guard let result = try? await AudioSync.analyze(referenceURL: reference.url, angleURL: angle.url,
                                                            focus: min(a, b)...max(a, b), progress: progress) else { continue }
            let composed = AudioSyncCore.compose(parent: (reference.offset, reference.rate),
                                                 child: (result.offset, result.rate))
            guard composed.offset.isFinite, composed.rate >= 0.995, composed.rate <= 1.005 else { continue }
            let number = (clip.multicam.angles.firstIndex(where: { $0.id == reference.id }) ?? 0) + 1
            let checkTime = result.checkTime.map { reference.mainTime(atAngle: $0) }
            let timing = AngleTiming(offset: composed.offset, rate: composed.rate,
                                     syncState: .needsCheck, syncReferenceID: reference.id)
            return SyncOutcome(timing: timing, result: result, referenceNumber: number, checkTime: checkTime)
        }
        return nil
    }

    /// 結果を書き込んだら true(アングルが消えた・同期の間に手で直されたときは書かない)
    @discardableResult
    private func applySyncOutcome(_ outcome: SyncOutcome, angle: CameraAngle, before: AngleTiming, clip: Clip) -> Bool {
        guard let current = currentAngle(angle.id), current.url == angle.url else { return false }
        if current.offset != before.offset || current.rate != before.rate {
            // 同期している間に手で直された: 手で直した値を残し、自動の結果は候補として出す
            let apparent = outcome.timing.offset + (outcome.timing.rate - 1) * clipCenter(clip)
            syncCandidates[angle.id] = [apparent]
            syncNotes[angle.id] = SyncNote(kind: .info,
                                           text: String(localized: "手で直したので、自動の結果は使いませんでした"))
            return false
        }
        syncUndo[angle.id] = before
        let others = applyAngleTiming(angleID: angle.id, before: before, after: outcome.timing)
        syncCandidates[angle.id] = outcome.referenceNumber == nil ? outcome.result.candidates : []
        if let checkTime = outcome.checkTime {
            syncCheckTimes[angle.id] = checkTime
        }
        var lines: [String] = []
        if let n = outcome.referenceNumber {
            lines.append(String(localized: "アングル\(n)の音で同期しました。確かめてください"))
        } else if outcome.timing.syncState == .synced {
            lines.append(String(localized: "同期しました"))
        } else {
            lines.append(String(localized: "同期しましたが、確かめてください"))
        }
        if outcome.result.driftApplied {
            lines.append(String(localized: "時計のずれも補正しました"))
        }
        if others > 0 {
            lines.append(String(localized: "分割したほかの \(others) クリップにも反映しました"))
        }
        let isSure = outcome.timing.syncState == .synced
        syncNotes[angle.id] = SyncNote(kind: isSure ? .success : .warning, text: lines.joined(separator: "\n"))
        UINotificationFeedbackGenerator().notificationOccurred(isSure ? .success : .warning)
        return true
    }

    private func reportSyncFailure(_ error: Error?, angleID: UUID) {
        var text = String(localized: "同期できませんでした")
        var candidates: [Double] = []
        if let error = error as? AudioSyncError {
            switch error {
            case .angleHasNoAudio:
                text = String(localized: "このアングルには音がありません")
                silentAngleIDs.insert(angleID)
            case .referenceHasNoAudio:
                text = String(localized: "メインに音がありません。1つのアングルを手で合わせると、ほかのアングルはその音で同期できます")
            case .weakCorrelation(let found):
                candidates = found
                text = found.isEmpty
                    ? String(localized: "同じ音が見つかりません。±1コマや数値で合わせてください")
                    : String(localized: "同じ音が見つかりません。下の候補を試すか、手で合わせてください")
            case .noOverlap:
                text = String(localized: "2つの音声に重なる部分がありません")
            case .tooShort:
                text = String(localized: "音が短すぎて同期できません")
            case .readFailed:
                text = String(localized: "音声を読み込めませんでした")
            }
        }
        syncNotes[angleID] = SyncNote(kind: .failure, text: text)
        syncCandidates[angleID] = candidates
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func trackSync(result: String, angle: CameraAngle, outcome: SyncOutcome?) {
        Analytics.shared.track("multicam_sync", [
            "result": result,
            "drift": (outcome?.result.driftApplied ?? false) ? "1" : "0",
            "via": outcome?.referenceNumber == nil ? "main" : "angle",
            "length": Analytics.durationBucket(angle.duration),
        ])
    }

    private func addAngles(_ items: [PhotosPickerItem]) async {
        isAddingAngles = true
        var failures: [String] = []
        var addedIDs: [UUID] = []
        for item in items {
            do {
                // スローモーション・iCloud にしかない動画なども受け取れるよう、メインの取り込みと同じ手順で読む
                let url = try await MovieImporter.importMovie(item)
                let angle = try await MediaStore.makeAngle(from: url)
                guard project.index(of: clipID) != nil else { break }
                updateClip { clip in
                    clip.multicam.angles.append(angle)
                }
                addedIDs.append(angle.id)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isAddingAngles = false
        if !failures.isEmpty {
            errorMessage = String(localized: "もう一度「アングルを追加」から選び直してください。\(failures.count)件の動画を追加できませんでした。\n") + failures.joined(separator: "\n")
        }
        // 追加したアングルは、すぐ音声で同期する
        if let i = project.index(of: clipID) {
            let clip = project.clips[i]
            let ids = clip.multicam.angles.filter { addedIDs.contains($0.id) && canSync(angle: $0, clip: clip) }.map(\.id)
            enqueueSync(ids)
        }
    }
}

// MARK: - 音声同期の小さな型

/// アングルの時刻の対応(直前に戻す用)
private struct AngleTiming: Equatable {
    var offset: Double
    var rate: Double
    var syncState: AngleSyncState?
    var syncReferenceID: UUID?

    init(offset: Double, rate: Double, syncState: AngleSyncState?, syncReferenceID: UUID?) {
        self.offset = offset
        self.rate = rate
        self.syncState = syncState
        self.syncReferenceID = syncReferenceID
    }

    init(_ angle: CameraAngle) {
        self.init(offset: angle.offset, rate: angle.rate,
                  syncState: angle.syncState, syncReferenceID: angle.syncReferenceID)
    }
}

/// 同期の結果
private struct SyncOutcome {
    var timing: AngleTiming
    var result: AudioSyncResult
    /// 別のアングルの音で合わせたときの、そのアングルの番号(1 から)
    var referenceNumber: Int?
    /// 耳で確かめる位置(メインの元素材上の秒)
    var checkTime: Double?
}

/// 同期のあとに行に出すひとこと
private struct SyncNote: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case failure
        case info
    }

    var kind: Kind
    var text: String

    var symbol: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        switch kind {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        case .info: return .secondary
        }
    }
}
