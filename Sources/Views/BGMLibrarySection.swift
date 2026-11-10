import SwiftUI
import Observation
import AVFoundation

// =====================================================================
// 「用意された曲」: サーバーから配る BGM(BGMCatalog.swift)を雰囲気で絞り込み、
// 試聴(ストリーミング)→「ダウンロード」→「使う」で BGM にする。
// 使った曲は読み込んだ曲と同じく MediaStore.mediaDirectory にコピーされる(名前 = 曲名 + ".mp3")。
// 動画より短い曲は CompositionBuilder がくり返して、終わりをフェードアウトする。
// =====================================================================

/// 試聴の再生(AVPlayer。ダウンロード前はストリーミング)
@MainActor @Observable
final class BGMPreviewPlayer {
    /// 再生中の曲の id
    var playingID: String?
    /// 読み込み中(まだ音が出ていない)曲の id
    var loadingID: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func toggle(_ track: BGMTrack, url: URL) {
        if playingID == track.id || loadingID == track.id {
            stop()
            return
        }
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadingID = track.id
        let id = track.id
        // 鳴り始めたら「再生中」、読めなければ止める
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            let failed = p.currentItem?.status == .failed
            Task { @MainActor in
                guard let self, self.player === p else { return }
                if failed {
                    self.stop()
                } else if status == .playing {
                    self.loadingID = nil
                    self.playingID = id
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingID = nil
        loadingID = nil
    }
}

struct BGMLibrarySection: View {
    @Bindable var project: EditorProject
    /// 試聴の再生(画面全体で持つ。Section の onDisappear は行ごとに働き、スクロールで行が見えなくなるたびに試聴が止まっていた)
    let player: BGMPreviewPlayer

    @State private var store = BGMTrackStore.shared
    @State private var mood: BGMMood? = nil
    @State private var errorMessage: String?
    @State private var trackToDelete: BGMTrack?

    private var visibleTracks: [BGMTrack] {
        guard let mood else { return store.tracks }
        return store.tracks.filter { $0.mood == mood.rawValue }
    }

    /// 一覧にある雰囲気だけチップに出す
    private var moods: [BGMMood] {
        let present = Set(store.tracks.map(\.mood))
        return BGMMood.allCases.filter { present.contains($0.rawValue) }
    }

    var body: some View {
        Section {
            if store.tracks.isEmpty {
                emptyState
            } else {
                moodChips
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                ForEach(visibleTracks) { track in
                    row(track)
                }
            }
        } header: {
            Text("用意された曲")
        } footer: {
            Text("AI で作った曲と、著作権の切れたクラシックの録音です。どの動画にも使えます。試聴は通信を使います(ダウンロードの大きさは曲ごとに出ています)")
        }
        .alert("曲を使えませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("ダウンロードした曲を消しますか？", isPresented: Binding(
            get: { trackToDelete != nil },
            set: { if !$0 { trackToDelete = nil } }
        ), titleVisibility: .visible, presenting: trackToDelete) { track in
            Button("消す", role: .destructive) {
                if player.playingID == track.id { player.stop() }
                store.delete(track)
            }
        } message: { _ in
            Text("BGM に使った動画からは消えません。もう一度使うときは、またダウンロードします")
        }
    }

    // MARK: 一覧がまだ無いとき

    @ViewBuilder
    private var emptyState: some View {
        if store.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("曲の一覧を読み込み中…")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.loadError ?? String(localized: "曲の一覧を読み込めませんでした。通信できる場所で、もう一度試してください。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("もう一度読み込む") {
                    Task { await store.loadCatalog() }
                }
            }
        }
    }

    // MARK: 絞り込み

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: String(localized: "すべて"), symbol: "music.note.list", selected: mood == nil) { mood = nil }
                ForEach(moods) { m in
                    chip(title: m.title, symbol: m.symbolName, selected: mood == m) { mood = m }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? BrandStyle.coral : Color(uiColor: .secondarySystemFill),
                            in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 行

    private func row(_ track: BGMTrack) -> some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(track, url: store.previewURL(track))
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if player.loadingID == track.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: player.playingID == track.id ? "stop.fill" : "play.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("試聴"))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.localizedName)
                    .font(.body)
                Text(detail(track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing(track)
        }
        .contextMenu {
            if store.downloaded.contains(track.id) {
                Button(role: .destructive) {
                    trackToDelete = track
                } label: {
                    Label("ダウンロードを消す", systemImage: "trash")
                }
            }
        }
    }

    private func detail(_ track: BGMTrack) -> String {
        let seconds = Int(track.duration.rounded())
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        var parts = [length]
        if track.bpm > 0 { parts.append("\(Int(track.bpm)) BPM") }
        if let moodTitle = track.moodKind?.title { parts.append(moodTitle) }
        if let credit = track.localizedCredit { parts.append(credit) }
        // まだダウンロードしていない曲は大きさも出す(クラシックは 20MB を超える曲もある)
        if let bytes = track.bytes, bytes > 0, !store.downloaded.contains(track.id) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: "・")
    }

    @ViewBuilder
    private func trailing(_ track: BGMTrack) -> some View {
        if store.downloading.contains(track.id) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("ダウンロード中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if store.downloaded.contains(track.id) {
            if project.audio.bgmName == track.name {
                Label("使用中", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BrandStyle.coral)
            } else {
                Button {
                    use(track)
                } label: {
                    Text("使う")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(BrandStyle.coral, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button {
                download(track)
            } label: {
                Label("ダウンロード", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(BrandStyle.coral, lineWidth: 1.5))
                    .foregroundStyle(BrandStyle.coral)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: ダウンロード・使う

    private func download(_ track: BGMTrack) {
        Task {
            do {
                try await store.download(track)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "曲をダウンロードできませんでした。通信できる場所で、もう一度試してください。")
            }
        }
    }

    private func use(_ track: BGMTrack) {
        player.stop()
        do {
            let localURL = try store.copyForProject(track)
            project.audio.bgmURL = localURL
            project.audio.bgmName = track.name
            project.audio.bgmSourceStart = 0
        } catch {
            errorMessage = String(localized: "空き容量を確かめて、もう一度試してください。\n\n詳細: ") + error.localizedDescription
        }
    }
}
