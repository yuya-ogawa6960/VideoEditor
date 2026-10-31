import SwiftUI
import Observation
import AVFoundation

// =====================================================================
// 「用意された曲」: アプリが合成する BGM を雰囲気で絞り込み、試聴して「使う」で動画の長さぶん作って BGM にする。
// 作った曲は読み込んだ曲と同じく MediaStore.mediaDirectory にコピーされる(名前 = 曲名 + ".m4a")。
// =====================================================================

/// 試聴の再生(AVAudioPlayer を持ち続ける)
@MainActor @Observable
final class BGMPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    /// 再生中のプリセット id
    var playingID: String?
    /// 試聴ファイルを作っている最中のプリセット id
    var loadingID: String?
    private var player: AVAudioPlayer?
    /// 作っている最中の試聴ファイル(プリセット id ごと)。同じ曲を何度押しても合成は 1 回だけにする
    @ObservationIgnored private var renders: [String: Task<URL, Error>] = [:]

    /// 試聴ファイルの URL。作っている最中ならその完成を待つ
    private func previewURL(for preset: BGMPreset) async throws -> URL {
        if let running = renders[preset.id] {
            return try await running.value
        }
        let task = Task<URL, Error> {
            try await BGMGenerator.previewURL(preset: preset)
        }
        renders[preset.id] = task
        defer { renders[preset.id] = nil }
        return try await task.value
    }

    func toggle(_ preset: BGMPreset) {
        if playingID == preset.id {
            stop()
            return
        }
        stop()
        loadingID = preset.id
        Task {
            do {
                let url = try await previewURL(for: preset)
                // 作っている間に別の曲を押されたら鳴らさない
                guard loadingID == preset.id else { return }
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                player = p
                playingID = preset.id
            } catch {
                // 試聴できないときは何もしない(「使う」は別で試せる)
            }
            if loadingID == preset.id { loadingID = nil }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        loadingID = nil
    }

    /// デリゲートはメインスレッド以外から呼ばれることがあるので nonisolated。状態にはメインアクターへ移ってから触る
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
                self.playingID = nil
            }
        }
    }
}

struct BGMLibrarySection: View {
    @Bindable var project: EditorProject

    @State private var mood: BGMMood? = nil
    @State private var player = BGMPreviewPlayer()
    /// 本番の曲を作っている最中のプリセット id
    @State private var renderingID: String?
    @State private var errorMessage: String?

    /// 作る曲の長さ(秒)。動画より長く、短い動画でも 30 秒。メモリのため 5 分まで
    static let maxSeconds: Double = 300

    var body: some View {
        Section {
            moodChips
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            ForEach(BGMLibrary.presets(mood: mood)) { preset in
                row(preset)
            }
        } header: {
            Text("用意された曲")
        } footer: {
            Text("アプリが作る曲なので、どの動画にも自由に使えます")
        }
        .alert("曲を作れませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear { player.stop() }
    }

    // MARK: 絞り込み

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: String(localized: "すべて"), symbol: "music.note.list", selected: mood == nil) { mood = nil }
                ForEach(BGMMood.allCases) { m in
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

    private func row(_ preset: BGMPreset) -> some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(preset)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if player.loadingID == preset.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: player.playingID == preset.id ? "stop.fill" : "play.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("試聴"))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: String.LocalizationValue(preset.name)))
                    .font(.body)
                Text("\(Int(preset.bpm)) BPM・\(preset.mood.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if renderingID == preset.id {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("作成中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    use(preset)
                } label: {
                    Text("使う")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(BrandStyle.coral, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderless)
                .disabled(renderingID != nil)
            }
        }
    }

    // MARK: 使う

    /// 動画の長さ(最低 30 秒)ぶん作って、読み込んだ曲と同じ場所にコピーして BGM にする
    private func use(_ preset: BGMPreset) {
        guard renderingID == nil else { return }
        player.stop()
        renderingID = preset.id
        let seconds = min(max(project.totalDuration, 30), BGMLibrarySection.maxSeconds)
        // 一時ファイルの名前が保存名になる(UUID_曲名.m4a)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgm-\(UUID().uuidString)", isDirectory: true)
        let tempURL = tempDir.appendingPathComponent(preset.name + ".m4a")
        Task {
            do {
                try await BGMGenerator.render(preset: preset, seconds: seconds, to: tempURL)
                let localURL = try MediaStore.copyIntoMediaDirectory(tempURL)
                try? FileManager.default.removeItem(at: tempDir)
                project.audio.bgmURL = localURL
                project.audio.bgmName = preset.name
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                errorMessage = String(localized: "空き容量を確かめて、もう一度試してください。\n\n詳細: ") + error.localizedDescription
            }
            renderingID = nil
        }
    }
}
