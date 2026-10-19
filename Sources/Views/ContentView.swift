import SwiftUI
import PhotosUI
import AVFoundation

struct ContentView: View {
    @State private var project = EditorProject()
    @State private var player = PlayerController()
    @State private var selection: UUID?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importDone = 0
    @State private var importTotal = 0
    @State private var alertMessage: String?
    @State private var activeSheet: ContentSheet?

    enum ContentSheet: Identifiable, Hashable {
        case editClip(UUID)
        case subtitles
        case audio
        case export

        var id: String {
            switch self {
            case .editClip(let clipID): return "edit-\(clipID.uuidString)"
            case .subtitles: return "subtitles"
            case .audio: return "audio"
            case .export: return "export"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if project.isEmpty {
                    emptyState
                } else {
                    editor
                }
            }
            .navigationTitle("動画エディタ")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ExportProgressBanner()
            }
            .overlay {
                if isImporting {
                    importOverlay
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
        .onChange(of: project.snapshot()) { _, newSnapshot in
            player.update(with: newSnapshot)
        }
        .onChange(of: project.clips.map { $0.id }) { _, ids in
            if let current = selection, !ids.contains(current) {
                selection = nil
            }
        }
        .onAppear {
            player.update(with: project.snapshot())
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .alert("お知らせ", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
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
        VStack(spacing: 8) {
            PreviewView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transportRow
                .padding(.horizontal)
            scrubber
                .padding(.horizontal)
            TimelineView(project: project, player: player, selection: $selection)
                .frame(height: 96)
            Divider()
            toolbarRow
                .padding(.bottom, 4)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 24) {
            Button {
                player.seek(to: max(0, player.currentTime - 5))
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.title2)
            }
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 36)
            }
            Button {
                player.seek(to: min(player.duration, player.currentTime + 5))
            } label: {
                Image(systemName: "goforward.5")
                    .font(.title2)
            }
            Spacer()
            Text("\(MediaTimeText.mmss(player.currentTime)) / \(MediaTimeText.mmss(player.duration))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }

    private var scrubber: some View {
        let upper = max(player.duration, 0.01)
        return Slider(
            value: Binding<Double>(
                get: { min(max(player.currentTime, 0), upper) },
                set: { newValue in player.seek(to: newValue) }
            ),
            in: 0...upper
        )
        .disabled(player.duration <= 0)
    }

    private var toolbarRow: some View {
        HStack(spacing: 0) {
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: nil,
                         selectionBehavior: .ordered,
                         matching: .videos,
                         preferredItemEncoding: .current) {
                toolLabel("追加", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(isImporting)

            toolButton("編集", systemImage: "slider.horizontal.3", disabled: editTargetID == nil) {
                if let clipID = editTargetID {
                    selection = clipID
                    activeSheet = .editClip(clipID)
                }
            }
            toolButton("分割", systemImage: "scissors") {
                splitAtPlayhead()
            }
            toolButton("字幕", systemImage: "captions.bubble") {
                activeSheet = .subtitles
            }
            toolButton("BGM", systemImage: "music.note") {
                activeSheet = .audio
            }
            toolButton("書き出し", systemImage: "square.and.arrow.up") {
                player.pause()
                activeSheet = .export
            }
        }
    }

    private func toolLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(height: 24)
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func toolButton(_ title: String, systemImage: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolLabel(title, systemImage: systemImage)
        }
        .disabled(disabled)
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

    // MARK: - シート

    @ViewBuilder
    private func sheetContent(for sheet: ContentSheet) -> some View {
        switch sheet {
        case .editClip(let clipID):
            NavigationStack {
                ClipEditorView(project: project, player: player, clipID: clipID)
            }
        case .subtitles:
            SubtitleEditorView(project: project, player: player)
        case .audio:
            AudioSettingsView(project: project)
        case .export:
            ExportView(project: project)
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

    // MARK: - 操作

    /// 編集対象:選択中のクリップ、なければ再生位置のクリップ
    private var editTargetID: UUID? {
        if let current = selection, project.index(of: current) != nil {
            return current
        }
        if let location = project.locate(timelineTime: player.currentTime),
           location.index < project.clips.count {
            return project.clips[location.index].id
        }
        return nil
    }

    private func splitAtPlayhead() {
        guard let location = project.locate(timelineTime: player.currentTime),
              location.index < project.clips.count else { return }
        let clip = project.clips[location.index]
        let succeeded = project.splitClip(id: clip.id, atSourceTime: location.sourceTime)
        if !succeeded {
            alertMessage = "クリップの端に近すぎるため分割できません。端から0.2秒以上離れた位置で分割してください。"
        }
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importTotal = items.count
        importDone = 0
        var failures: [String] = []
        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    let clip = try await MediaStore.makeClip(from: movie.url)
                    project.clips.append(clip)
                    if selection == nil {
                        selection = clip.id
                    }
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
