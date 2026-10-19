import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// メイン画面(CapCut 風:上部バー/プレビュー/再生操作/タイムライン/下部ツールバー)
struct ContentView: View {
    /// 編集するプロジェクト(ProjectLibrary の ID)。保存先はこの ID のフォルダ
    let projectID: UUID
    /// 一覧へ戻るときに呼ぶ(保存を終えてから呼ばれる)
    let onClose: () -> Void

    @State private var project = EditorProject()
    @State private var didRestore = false
    /// 開いた直後に復元した内容。復元による最初の変化は保存しない(保存済みの内容と同じ)
    @State private var restoredSnapshot: ProjectSnapshot?
    /// 開いてから 1 回でも編集したか(一覧の更新日時を動かすかどうか)
    @State private var isDirty = false
    @State private var player = PlayerController()
    @State private var history = EditorHistory()
    @State private var timeline = TimelineState()
    @State private var selection: EditorSelection?

    @State private var activePanel: EditorPanel?
    @State private var activeSheet: EditorSheet?

    @State private var pickerItems: [PhotosPickerItem] = []
    /// 「オーバーレイ」で選んだ動画・写真
    @State private var overlayPickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importDone = 0
    @State private var importTotal = 0

    @State private var alertMessage: String?
    @State private var showClearProjectConfirm = false
    @State private var showSilenceCutConfirm = false
    @State private var showNormalizeConfirm = false
    /// 無音カット・音量そろえの進捗(nil なら実行中でない)
    @State private var audioToolProgress: AudioToolProgress?
    @State private var audioToolTask: Task<Void, Never>?
    @State private var isKeyboardVisible = false

    init(projectID: UUID, onClose: @escaping () -> Void) {
        self.projectID = projectID
        self.onClose = onClose
    }

    enum EditorSheet: Identifiable, Hashable {
        case clipDetail(UUID)
        case multicam(UUID)
        case subtitles
        case audio
        case export

        var id: String {
            switch self {
            case .clipDetail(let clipID): return "detail-\(clipID.uuidString)"
            case .multicam(let clipID): return "multicam-\(clipID.uuidString)"
            case .subtitles: return "subtitles"
            case .audio: return "audio"
            case .export: return "export"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ExportProgressBanner()
                if project.isEmpty {
                    emptyState
                } else {
                    editor
                }
            }

            if isImporting {
                importOverlay
            }

            if let progress = audioToolProgress {
                AudioToolProgressOverlay(progress: progress) {
                    audioToolTask?.cancel()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            pickerItems = []
            Task { await importItems(items) }
        }
        .onChange(of: overlayPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            overlayPickerItems = []
            Task { await importOverlayItems(items) }
        }
        .onChange(of: project.snapshot()) { _, newSnapshot in
            player.update(with: newSnapshot)
            if let restored = restoredSnapshot {
                // 開いた直後の復元による変化は保存しない(内容は保存済みのものと同じ)
                restoredSnapshot = nil
                if restored == newSnapshot { return }
            }
            persist(newSnapshot)
        }
        .onChange(of: selectionExists) { _, exists in
            if !exists {
                selection = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            if let panel = activePanel, !panel.isCompatible(with: newValue) {
                activePanel = nil
            }
        }
        .onChange(of: project.isEmpty) { _, isEmpty in
            if isEmpty {
                activePanel = nil
                selection = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onAppear {
            if !didRestore {
                didRestore = true
                if let saved = ProjectStore.load(projectID: projectID) {
                    project.restore(saved)
                    restoredSnapshot = project.snapshot()
                    if !saved.isEmpty {
                        Task { await reloadThumbnails() }
                    }
                }
            }
            player.update(with: project.snapshot())
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .confirmationDialog("このプロジェクトを空にしますか?",
                            isPresented: $showClearProjectConfirm,
                            titleVisibility: .visible) {
            Button("編集中の内容をすべて削除", role: .destructive) {
                clearProject()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このプロジェクトのクリップ・字幕・BGM・オーバーレイ・ナレーションはすべて消え、元に戻せません。プロジェクト自体は一覧に残ります。")
        }
        .alert("お知らせ", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - 上部バー

    private var topBar: some View {
        HStack(spacing: 18) {
            Menu {
                Button {
                    closeProject()
                } label: {
                    Label("プロジェクト一覧へ戻る", systemImage: "square.grid.2x2")
                }
                Button(role: .destructive) {
                    showClearProjectConfirm = true
                } label: {
                    Label("このプロジェクトを空にする", systemImage: "trash")
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("閉じる")

            Spacer()

            Button {
                EditorHaptics.tap()
                activePanel = nil
                history.undo(project)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(history.canUndo ? 1 : 0.3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!history.canUndo)
            .accessibilityLabel("元に戻す")

            Button {
                EditorHaptics.tap()
                activePanel = nil
                history.redo(project)
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(history.canRedo ? 1 : 0.3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!history.canRedo)
            .accessibilityLabel("やり直す")

            Spacer()

            Button {
                EditorHaptics.tap()
                player.pause()
                activePanel = nil
                activeSheet = .export
            } label: {
                Text("書き出し")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .opacity(project.isEmpty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(project.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    // MARK: - 空の状態

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "film")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("動画を追加して編集を始めましょう")
                .foregroundStyle(.secondary)
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .videos,
                         preferredItemEncoding: .current) {
                Label("動画を追加", systemImage: "plus.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.accentColor, in: Capsule())
            }
            .disabled(isImporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 編集画面

    private var editor: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                PreviewView(player: player)
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: max(100, geo.size.height * 0.45))
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.togglePlay()
                    }
                    .layoutPriority(1)

                if !isKeyboardVisible {
                    transportRow
                        .padding(.horizontal, 16)
                        .frame(height: 44)

                    TimelineView(project: project, player: player, history: history,
                                 timeline: timeline, selection: $selection)
                        .frame(height: TimelineView.totalHeight)
                        .overlay(alignment: .trailing) {
                            addClipButton
                                .padding(.trailing, 8)
                        }
                }

                Spacer(minLength: 0)

                bottomArea
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var transportRow: some View {
        ZStack {
            HStack {
                Text("\(EditorTimeFormat.short(player.currentTime)) / \(EditorTimeFormat.short(player.duration))")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
            }

            Button {
                EditorHaptics.tap()
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.duration <= 0)
            .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
        }
    }

    private var addClipButton: some View {
        PhotosPicker(selection: $pickerItems,
                     maxSelectionCount: nil,
                     selectionBehavior: .ordered,
                     matching: .videos,
                     preferredItemEncoding: .current) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: Color.black.opacity(0.4), radius: 4)
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .accessibilityLabel("動画を追加")
    }

    // MARK: - 下部(ツールバー or パネル)

    private var bottomArea: some View {
        ZStack(alignment: .bottom) {
            if let panel = activePanel {
                EditorPanelContainer(title: panel.title, height: panel.height, onClose: {
                    activePanel = nil
                }) {
                    panelContent(panel)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                EditorToolbar(items: toolbarItems,
                              onBack: backAction,
                              pickerItems: $pickerItems,
                              overlayPickerItems: $overlayPickerItems)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: activePanel)
        .confirmationDialog("無音部分を自動で詰めます(全クリップ)",
                            isPresented: $showSilenceCutConfirm,
                            titleVisibility: .visible) {
            Button("無音カットを実行") {
                startSilenceCut()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("音声のあるクリップごとに 0.6 秒以上の無音を検出し、その部分を取り除いてクリップを分割します。「元に戻す」で戻せます。")
        }
        .confirmationDialog("全クリップとナレーションの音量をそろえます",
                            isPresented: $showNormalizeConfirm,
                            titleVisibility: .visible) {
            Button("音量そろえを実行") {
                startNormalize(clipIDs: project.clips.map { $0.id },
                               narrationIDs: project.narration.map { $0.id })
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("各クリップとナレーションのラウドネスを測り、-16 LUFS を目安に音量をそろえます。「元に戻す」で戻せます。")
        }
    }

    /// 選択中なら「←」で選択解除
    private var backAction: (() -> Void)? {
        guard selection != nil else { return nil }
        return { selection = nil }
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .speed(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorSpeedPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .volume(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorVolumePanel(project: project, clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .filter(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorFilterPanel(project: project, clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .textEdit(let cueID):
            if let cue = project.subtitleBinding(id: cueID) {
                EditorTextEditPanel(cue: cue)
            } else {
                EditorMissingPanelContent()
            }
        case .subtitleStyle:
            EditorSubtitleStylePanel(project: project)
        case .aspect:
            EditorAspectPanel(project: project)
        case .bgmVolume:
            EditorBGMVolumePanel(project: project)
        case .documentary:
            EditorDocumentaryPanel(project: project)
        case .titleCard(let cardID):
            EditorTitleCardPanel(project: project,
                                 player: player,
                                 card: titleCardBinding(id: cardID),
                                 onSelect: { id in activePanel = .titleCard(id) },
                                 onDelete: { id in deleteTitleCard(id) })
        case .lowerThird(let itemID):
            EditorLowerThirdPanel(project: project,
                                  player: player,
                                  item: lowerThirdBinding(id: itemID),
                                  onSelect: { id in activePanel = .lowerThird(id) },
                                  onDelete: { id in deleteLowerThird(id) })
        case .jlCut(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorJLCutPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .colorAdjust(let clipID):
            if let clip = project.clipBinding(id: clipID) {
                EditorColorAdjustPanel(clip: clip)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayPlacement(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayPlacementPanel(project: project, overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayKenBurns(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayKenBurnsPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayVolume(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayVolumePanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlaySpeed(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlaySpeedPanel(overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .overlayFilter(let overlayID):
            if let overlay = project.overlayBinding(id: overlayID) {
                EditorOverlayFilterPanel(project: project, overlay: overlay)
            } else {
                EditorMissingPanelContent()
            }
        case .narrationVolume(let narrationID):
            if let narration = project.narrationBinding(id: narrationID) {
                EditorNarrationVolumePanel(narration: narration)
            } else {
                EditorMissingPanelContent()
            }
        case .narrationRecord:
            EditorNarrationRecordPanel(project: project,
                                       player: player,
                                       history: history,
                                       onRecorded: { id in selection = .narration(id) })
        }
    }

    // MARK: - 章タイトル / テロップ の Binding

    /// 指定 ID の章タイトルへの Binding(見つからなければ nil)。
    /// 途中で消えても落ちないよう、見つからない場合は最後に見た値を返す
    private func titleCardBinding(id: UUID) -> Binding<TitleCard>? {
        guard let initial = project.titleCards.first(where: { $0.id == id }) else { return nil }
        let project = self.project
        return Binding<TitleCard>(
            get: { project.titleCards.first(where: { $0.id == id }) ?? initial },
            set: { newValue in
                guard let i = project.titleCards.firstIndex(where: { $0.id == id }) else { return }
                project.titleCards[i] = newValue
            }
        )
    }

    /// 指定 ID のテロップへの Binding(見つからなければ nil)
    private func lowerThirdBinding(id: UUID) -> Binding<LowerThird>? {
        guard let initial = project.lowerThirds.first(where: { $0.id == id }) else { return nil }
        let project = self.project
        return Binding<LowerThird>(
            get: { project.lowerThirds.first(where: { $0.id == id }) ?? initial },
            set: { newValue in
                guard let i = project.lowerThirds.firstIndex(where: { $0.id == id }) else { return }
                project.lowerThirds[i] = newValue
            }
        )
    }

    // MARK: - ツールバー項目

    private var toolbarItems: [EditorToolItem] {
        guard let current = selection else { return rootItems }
        switch current {
        case .clip(let clipID):
            return clipItems(clipID)
        case .subtitle(let cueID):
            return subtitleItems(cueID)
        case .bgm:
            return bgmItems
        case .overlay(let overlayID):
            return overlayItems(overlayID)
        case .narration(let narrationID):
            return narrationItems(narrationID)
        }
    }

    /// 音声トラックを持つクリップがあるか(無音カット・音量そろえの有効条件)
    private var hasAudioClips: Bool {
        project.clips.contains(where: { $0.hasAudio })
    }

    private var rootItems: [EditorToolItem] {
        let target = clipIDAtPlayhead
        return [
            EditorToolItem("編集", systemImage: "scissors", enabled: target != nil) {
                if let target {
                    selection = .clip(target)
                }
            },
            EditorToolItem("音声", systemImage: "music.note") {
                history.record(project)
                activeSheet = .audio
            },
            EditorToolItem("テキスト", systemImage: "textformat") {
                addSubtitleAtPlayhead()
            },
            EditorToolItem("ドキュメンタリー", systemImage: "film.stack") {
                openPanel(.documentary)
            },
            EditorToolItem("章タイトル", systemImage: "text.below.photo") {
                addTitleCardAtPlayhead()
            },
            EditorToolItem("テロップ", systemImage: "person.text.rectangle") {
                addLowerThirdAtPlayhead()
            },
            EditorToolItem.addOverlay("オーバーレイ", systemImage: "photo.on.rectangle", enabled: !isImporting),
            EditorToolItem("ナレーション", systemImage: "mic") {
                openPanel(.narrationRecord)
            },
            EditorToolItem("無音カット", systemImage: "waveform.slash", enabled: hasAudioClips) {
                showSilenceCutConfirm = true
            },
            EditorToolItem("音量そろえ", systemImage: "speaker.wave.2",
                           enabled: hasAudioClips || !project.narration.isEmpty) {
                showNormalizeConfirm = true
            },
            EditorToolItem("自動字幕", systemImage: "captions.bubble") {
                history.record(project)
                activeSheet = .subtitles
            },
            EditorToolItem("フィルタ", systemImage: "camera.filters", enabled: target != nil) {
                if let target {
                    selection = .clip(target)
                    openPanel(.filter(target))
                }
            },
            EditorToolItem("比率", systemImage: "aspectratio") {
                openPanel(.aspect)
            },
            EditorToolItem.addMedia("追加", systemImage: "plus.rectangle.on.rectangle", enabled: !isImporting)
        ]
    }

    private func clipItems(_ clipID: UUID) -> [EditorToolItem] {
        [
            EditorToolItem("分割", systemImage: "square.split.2x1") {
                splitClip(clipID)
            },
            EditorToolItem("速度", systemImage: "speedometer") {
                openPanel(.speed(clipID))
            },
            EditorToolItem("音量", systemImage: "speaker.wave.2") {
                openPanel(.volume(clipID))
            },
            EditorToolItem("フィルタ", systemImage: "camera.filters") {
                openPanel(.filter(clipID))
            },
            EditorToolItem("色調整", systemImage: "circle.lefthalf.filled") {
                openPanel(.colorAdjust(clipID))
            },
            EditorToolItem("Jカット/Lカット", systemImage: "waveform.path") {
                openPanel(.jlCut(clipID))
            },
            EditorToolItem("複製", systemImage: "plus.square.on.square") {
                history.record(project)
                project.duplicateClip(id: clipID)
            },
            EditorToolItem("削除", systemImage: "trash", destructive: true) {
                history.record(project)
                selection = nil
                project.removeClip(id: clipID)
            },
            EditorToolItem("マルチカメラ", systemImage: "camera.on.rectangle") {
                history.record(project)
                activeSheet = .multicam(clipID)
            },
            EditorToolItem("詳細", systemImage: "slider.horizontal.3") {
                history.record(project)
                activeSheet = .clipDetail(clipID)
            }
        ]
    }

    private func overlayItems(_ overlayID: UUID) -> [EditorToolItem] {
        let isImage = project.overlays.first(where: { $0.id == overlayID })?.isImage ?? false
        var items: [EditorToolItem] = [
            EditorToolItem("配置", systemImage: "rectangle.on.rectangle") {
                openPanel(.overlayPlacement(overlayID))
            },
            EditorToolItem("ケン・バーンズ", systemImage: "arrow.up.left.and.arrow.down.right") {
                openPanel(.overlayKenBurns(overlayID))
            }
        ]
        if !isImage {
            items.append(EditorToolItem("音量", systemImage: "speaker.wave.2") {
                openPanel(.overlayVolume(overlayID))
            })
            items.append(EditorToolItem("速度", systemImage: "speedometer") {
                openPanel(.overlaySpeed(overlayID))
            })
        }
        items.append(EditorToolItem("フィルタ", systemImage: "camera.filters") {
            openPanel(.overlayFilter(overlayID))
        })
        items.append(EditorToolItem("複製", systemImage: "plus.square.on.square") {
            duplicateOverlay(overlayID)
        })
        items.append(EditorToolItem("削除", systemImage: "trash", destructive: true) {
            history.record(project)
            selection = nil
            project.removeOverlay(id: overlayID)
        })
        return items
    }

    private func narrationItems(_ narrationID: UUID) -> [EditorToolItem] {
        [
            EditorToolItem("音量", systemImage: "speaker.wave.2") {
                openPanel(.narrationVolume(narrationID))
            },
            EditorToolItem("音量そろえ", systemImage: "waveform") {
                startNormalize(clipIDs: [], narrationIDs: [narrationID])
            },
            EditorToolItem("削除", systemImage: "trash", destructive: true) {
                history.record(project)
                selection = nil
                project.removeNarration(id: narrationID)
            }
        ]
    }

    private func subtitleItems(_ cueID: UUID) -> [EditorToolItem] {
        [
            EditorToolItem("テキスト編集", systemImage: "pencil") {
                openPanel(.textEdit(cueID))
            },
            EditorToolItem("スタイル", systemImage: "textformat.size") {
                openPanel(.subtitleStyle)
            },
            EditorToolItem("削除", systemImage: "trash", destructive: true) {
                history.record(project)
                selection = nil
                project.removeSubtitle(id: cueID)
            },
            EditorToolItem("自動字幕", systemImage: "captions.bubble") {
                history.record(project)
                activeSheet = .subtitles
            }
        ]
    }

    private var bgmItems: [EditorToolItem] {
        [
            EditorToolItem("音量", systemImage: "speaker.wave.2") {
                openPanel(.bgmVolume)
            },
            EditorToolItem("置き換え", systemImage: "arrow.triangle.2.circlepath") {
                history.record(project)
                activeSheet = .audio
            },
            EditorToolItem("削除", systemImage: "trash", destructive: true) {
                history.record(project)
                selection = nil
                project.audio.bgmURL = nil
                project.audio.bgmName = nil
            }
        ]
    }

    // MARK: - シート

    @ViewBuilder
    private func sheetContent(for sheet: EditorSheet) -> some View {
        switch sheet {
        case .clipDetail(let clipID):
            NavigationStack {
                ClipEditorView(project: project, player: player, clipID: clipID)
            }
        case .multicam(let clipID):
            NavigationStack {
                MulticamEditorView(project: project, player: player, clipID: clipID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了") { activeSheet = nil }
                        }
                    }
            }
        case .subtitles:
            SubtitleEditorView(project: project, player: player)
        case .audio:
            AudioSettingsView(project: project)
        case .export:
            ExportView(project: project)
        }
    }

    private var importOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: Double(importDone), total: Double(max(importTotal, 1)))
                Text("読み込み中… \(importDone)/\(importTotal)")
                    .font(.callout)
                    .monospacedDigit()
            }
            .padding(20)
            .frame(width: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { alertMessage != nil },
            set: { newValue in
                if !newValue { alertMessage = nil }
            }
        )
    }

    // MARK: - 状態

    /// 選択中の対象がまだ存在するか(削除・元に戻すで消えたら選択解除する)
    private var selectionExists: Bool {
        guard let current = selection else { return true }
        switch current {
        case .clip(let clipID):
            return project.index(of: clipID) != nil
        case .subtitle(let cueID):
            return project.subtitles.contains(where: { $0.id == cueID })
        case .bgm:
            return project.audio.bgmURL != nil
        case .overlay(let overlayID):
            return project.overlays.contains(where: { $0.id == overlayID })
        case .narration(let narrationID):
            return project.narration.contains(where: { $0.id == narrationID })
        }
    }

    /// 再生位置にあるクリップ
    private var clipIDAtPlayhead: UUID? {
        guard let location = project.locate(timelineTime: player.currentTime),
              location.index < project.clips.count else { return nil }
        return project.clips[location.index].id
    }

    // MARK: - 操作

    /// パネルを開く。開く直前の状態を 1 回だけ記録し、パネル内の変更を 1 回の「元に戻す」で戻せるようにする
    private func openPanel(_ panel: EditorPanel) {
        history.record(project)
        activePanel = panel
    }

    private func addSubtitleAtPlayhead() {
        history.record(project)
        let cue = project.addSubtitle(at: player.currentTime)
        selection = .subtitle(cue.id)
    }

    // MARK: 章タイトル / テロップ

    /// 再生位置に章タイトルを追加して編集パネルを開く
    private func addTitleCardAtPlayhead() {
        history.record(project)
        let n = project.titleCards.count + 1
        let card = TitleCard(start: max(0, player.currentTime),
                             heading: "第\(n)章",
                             title: "タイトル")
        project.titleCards.append(card)
        selection = nil
        activePanel = .titleCard(card.id)
    }

    /// 再生位置にテロップ(ネームプレート)を追加して編集パネルを開く
    private func addLowerThirdAtPlayhead() {
        history.record(project)
        let item = LowerThird(kind: .nameplate,
                              start: max(0, player.currentTime),
                              primary: "名前",
                              secondary: "肩書き")
        project.lowerThirds.append(item)
        selection = nil
        activePanel = .lowerThird(item.id)
    }

    /// 章タイトルを削除。残りがあれば次のカードの編集に切り替え、なければパネルを閉じる
    private func deleteTitleCard(_ cardID: UUID) {
        history.record(project)
        project.titleCards.removeAll { $0.id == cardID }
        if let next = project.titleCards.sorted(by: { $0.start < $1.start }).first {
            activePanel = .titleCard(next.id)
        } else {
            activePanel = nil
        }
    }

    /// テロップを削除。残りがあれば次のテロップの編集に切り替え、なければパネルを閉じる
    private func deleteLowerThird(_ itemID: UUID) {
        history.record(project)
        project.lowerThirds.removeAll { $0.id == itemID }
        if let next = project.lowerThirds.sorted(by: { $0.start < $1.start }).first {
            activePanel = .lowerThird(next.id)
        } else {
            activePanel = nil
        }
    }

    // MARK: オーバーレイ

    /// 選択中のオーバーレイを複製して直後に置き、複製を選択する
    private func duplicateOverlay(_ overlayID: UUID) {
        guard let i = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return }
        history.record(project)
        let original = project.overlays[i]
        var copy = original.duplicated()
        copy.start = original.end
        project.overlays.insert(copy, at: i + 1)
        project.sortOverlays()
        selection = .overlay(copy.id)
    }

    /// PhotosPicker で選んだ動画・写真をオーバーレイとして再生位置に追加する
    @MainActor
    private func importOverlayItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importTotal = items.count
        importDone = 0
        var failures: [String] = []
        var recorded = false
        var lastAdded: UUID?
        for item in items {
            do {
                var overlay: OverlayClip?
                let looksLikeMovie = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                if looksLikeMovie, let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    var video = try await MediaStore.makeOverlay(fromVideo: movie.url)
                    OverlayPreset.bRollFull.apply(to: &video)
                    overlay = video
                } else if let photo = try await item.loadTransferable(type: PickedPhoto.self) {
                    var image = try MediaStore.makeImageOverlay(from: photo.url)
                    image.duration = 4
                    image.kenBurns = KenBurns.zoomIn
                    overlay = image
                } else if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    // 種類が判定できなかった場合の保険
                    var video = try await MediaStore.makeOverlay(fromVideo: movie.url)
                    OverlayPreset.bRollFull.apply(to: &video)
                    overlay = video
                }
                guard var added = overlay else {
                    failures.append("動画・写真のデータを取得できませんでした。")
                    importDone += 1
                    continue
                }
                added.start = max(0, player.currentTime)
                if !recorded {
                    history.record(project)
                    recorded = true
                }
                project.overlays.append(added)
                project.sortOverlays()
                lastAdded = added.id
            } catch {
                failures.append(error.localizedDescription)
            }
            importDone += 1
        }
        isImporting = false
        if let lastAdded {
            selection = .overlay(lastAdded)
            // 履歴は追加前に記録済みなので openPanel は使わない
            activePanel = .overlayPlacement(lastAdded)
        }
        if !failures.isEmpty {
            alertMessage = "\(failures.count)件の素材を読み込めませんでした。\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: 無音カット

    private func startSilenceCut() {
        audioToolTask?.cancel()
        audioToolTask = Task { @MainActor in
            await runSilenceCut()
            audioToolTask = nil
        }
    }

    /// 音声のある(ミュートでない)全クリップから無音部分を取り除き、残す範囲ごとにクリップを分割する
    @MainActor
    private func runSilenceCut() async {
        let targets = project.clips.filter { $0.hasAudio && !$0.isMuted }
        guard !targets.isEmpty else {
            alertMessage = "音声のあるクリップがありません。"
            return
        }
        player.pause()
        audioToolProgress = AudioToolProgress(title: "無音を検出中", done: 0, total: targets.count)

        var kept: [UUID: [(start: Double, end: Double)]] = [:]
        var failures: [String] = []
        var cancelled = false
        for (i, clip) in targets.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                kept[clip.id] = try await AudioAnalysis.keptRanges(for: clip)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failures.append("\(clip.name): \(error.localizedDescription)")
            }
            audioToolProgress?.done = i + 1
        }
        audioToolProgress = nil
        if cancelled {
            alertMessage = "無音カットをキャンセルしました。"
            return
        }

        // 残す範囲ごとにクリップを組み立て直す(最初の範囲は元の ID を保つ)
        let tolerance = 0.01
        var newClips: [Clip] = []
        var removedCount = 0
        var removedOutputSeconds = 0.0
        for clip in project.clips {
            guard let ranges = kept[clip.id], !ranges.isEmpty else {
                newClips.append(clip)
                continue
            }
            var gaps = max(0, ranges.count - 1)
            if let first = ranges.first, first.start > clip.startTime + tolerance { gaps += 1 }
            if let last = ranges.last, last.end < clip.endTime - tolerance { gaps += 1 }
            guard gaps > 0 else {
                newClips.append(clip)
                continue
            }
            let keptSource = ranges.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            removedOutputSeconds += max(0, clip.trimmedDuration - keptSource) / max(clip.speed, 0.01)
            removedCount += gaps
            for (j, range) in ranges.enumerated() {
                var piece = (j == 0) ? clip : clip.duplicated()
                piece.startTime = range.start
                piece.endTime = range.end
                newClips.append(piece)
            }
        }

        guard removedCount > 0 else {
            var message = "無音部分は見つかりませんでした。"
            if !failures.isEmpty {
                message += "\n解析できなかったクリップ:\n" + failures.joined(separator: "\n")
            }
            alertMessage = message
            return
        }

        history.record(project)
        project.clips = newClips
        var message = "\(removedCount) か所、合計 \(String(format: "%.1f", removedOutputSeconds)) 秒を削除しました。"
        if !failures.isEmpty {
            message += "\n解析できなかったクリップ:\n" + failures.joined(separator: "\n")
        }
        alertMessage = message
    }

    // MARK: 音量そろえ

    private func startNormalize(clipIDs: [UUID], narrationIDs: [UUID]) {
        audioToolTask?.cancel()
        audioToolTask = Task { @MainActor in
            await runNormalize(clipIDs: clipIDs, narrationIDs: narrationIDs)
            audioToolTask = nil
        }
    }

    /// 指定したクリップ・ナレーションのラウドネスを測り、-16 LUFS を目安にゲインを設定する
    @MainActor
    private func runNormalize(clipIDs: [UUID], narrationIDs: [UUID]) async {
        let clipTargets = project.clips.filter { clipIDs.contains($0.id) && $0.hasAudio }
        let narrationTargets = project.narration.filter { narrationIDs.contains($0.id) }
        let total = clipTargets.count + narrationTargets.count
        guard total > 0 else {
            alertMessage = "音声のあるクリップやナレーションがありません。"
            return
        }
        player.pause()
        audioToolProgress = AudioToolProgress(title: "音量を測定中", done: 0, total: total)

        var clipGains: [UUID: Float] = [:]
        var narrationGains: [UUID: Float] = [:]
        var failures: [String] = []
        var cancelled = false
        var done = 0

        for clip in clipTargets {
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                let measurement = try await LoudnessAnalyzer.measure(url: clip.url,
                                                                     start: clip.startTime,
                                                                     end: clip.endTime)
                clipGains[clip.id] = LoudnessAnalyzer.normalizationGain(for: measurement)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failures.append("\(clip.name): \(error.localizedDescription)")
            }
            done += 1
            audioToolProgress?.done = done
        }

        if !cancelled {
            for item in narrationTargets {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                do {
                    let measurement = try await LoudnessAnalyzer.measure(url: item.url,
                                                                         start: item.sourceStart,
                                                                         end: item.sourceEnd)
                    narrationGains[item.id] = LoudnessAnalyzer.normalizationGain(for: measurement)
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
                done += 1
                audioToolProgress?.done = done
            }
        }

        audioToolProgress = nil
        if cancelled {
            alertMessage = "音量そろえをキャンセルしました。"
            return
        }
        guard !clipGains.isEmpty || !narrationGains.isEmpty else {
            alertMessage = "音量を測定できませんでした。\n" + failures.joined(separator: "\n")
            return
        }

        history.record(project)
        var clips = project.clips
        for i in clips.indices {
            if let gain = clipGains[clips[i].id] {
                clips[i].audio.gain = gain
            }
        }
        project.clips = clips
        var narration = project.narration
        for i in narration.indices {
            if let gain = narrationGains[narration[i].id] {
                narration[i].gain = gain
            }
        }
        project.narration = narration

        let count = clipGains.count + narrationGains.count
        var message = "\(count) 件の音量をそろえました(目安 -16 LUFS)。"
        if !failures.isEmpty {
            message += "\n測定できなかった素材:\n" + failures.joined(separator: "\n")
        }
        alertMessage = message
    }

    private func splitClip(_ clipID: UUID) {
        guard let location = project.locate(timelineTime: player.currentTime),
              location.index < project.clips.count else { return }
        let clip = project.clips[location.index]
        guard clip.id == clipID else {
            alertMessage = "再生位置(中央の白い線)を選択中のクリップの上に合わせてから分割してください。"
            return
        }
        let minimum = 0.2
        guard location.sourceTime > clip.startTime + minimum,
              location.sourceTime < clip.endTime - minimum else {
            alertMessage = "クリップの端に近すぎるため分割できません。端から0.2秒以上離れた位置で分割してください。"
            return
        }
        history.record(project)
        project.splitClip(id: clipID, atSourceTime: location.sourceTime)
    }

    // MARK: 保存 / プロジェクトの切り替え

    /// 変更内容を保存し、一覧のメタデータとサムネイルを更新する(書き込みはまとめて行われる)
    private func persist(_ snapshot: ProjectSnapshot) {
        isDirty = true
        ProjectStore.scheduleSave(snapshot, projectID: projectID)
        ProjectLibrary.shared.touch(id: projectID,
                                    duration: snapshot.totalDuration,
                                    clipCount: snapshot.clips.count)
        if let image = snapshot.clips.first?.thumbnail {
            ProjectStore.scheduleThumbnail(image, projectID: projectID)
        } else if snapshot.clips.isEmpty {
            ProjectStore.deleteThumbnail(projectID: projectID)
        }
    }

    /// いま保存してからプロジェクト一覧へ戻る
    private func closeProject() {
        player.pause()
        activePanel = nil
        activeSheet = nil
        selection = nil
        let snapshot = project.snapshot()
        ProjectStore.saveNow(snapshot, projectID: projectID)
        if snapshot.clips.isEmpty {
            ProjectStore.deleteThumbnail(projectID: projectID)
        } else if let image = snapshot.clips.first?.thumbnail {
            ProjectStore.saveThumbnail(image, projectID: projectID)
        }
        if isDirty {
            ProjectLibrary.shared.touch(id: projectID,
                                        duration: snapshot.totalDuration,
                                        clipCount: snapshot.clips.count)
        }
        ProjectLibrary.shared.flush()
        onClose()
    }

    /// このプロジェクトの内容をすべて消す(一覧からは消さない)。空になった内容は onChange 経由で保存される
    private func clearProject() {
        player.pause()
        activePanel = nil
        activeSheet = nil
        selection = nil
        project.restore(ProjectSnapshot(clips: [],
                                        subtitles: [],
                                        subtitleStyle: SubtitleStyle(),
                                        audio: AudioSettings(),
                                        canvas: CanvasSettings()))
        history.clear()
        player.seek(to: 0)
    }

    /// 復元したクリップのサムネイルを読み直す(保存ファイルには画像を含めないため)
    @MainActor
    private func reloadThumbnails() async {
        for clip in project.clips where clip.thumbnail == nil {
            let image = await MediaStore.thumbnail(for: clip.url, at: clip.startTime, maxPixel: 240)
            if let i = project.index(of: clip.id) {
                project.clips[i].thumbnail = image
            }
        }
    }

    @MainActor
    private func importItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importTotal = items.count
        importDone = 0
        var failures: [String] = []
        var recorded = false
        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    let clip = try await MediaStore.makeClip(from: movie.url)
                    if !recorded {
                        history.record(project)
                        recorded = true
                    }
                    project.clips.append(clip)
                } else {
                    failures.append("動画データを取得できませんでした。")
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            importDone += 1
        }
        isImporting = false
        if !failures.isEmpty {
            alertMessage = "\(failures.count)件の動画を読み込めませんでした。\n" + failures.joined(separator: "\n")
        }
    }
}
