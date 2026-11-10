import SwiftUI
import Observation
import UniformTypeIdentifiers
import AVFoundation

struct AudioSettingsView: View {
    @Bindable var project: EditorProject

    @Environment(\.dismiss) private var dismiss

    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    /// 「用意された曲」の試聴(シートを閉じたときに止める)
    @State private var bgmPreview = BGMPreviewPlayer()
    /// いまの BGM の長さ(秒。曲の開始位置のスライダーに使う)
    @State private var bgmDuration: Double = 0

    private static let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]

    var body: some View {
        NavigationStack {
            Form {
                bgmSection
                // 音量は曲の一覧の上に置く(前は 183 曲の一覧の下で、長くスクロールしないと出てこなかった)
                volumeSection
                // アプリが作る曲(BGMLibrarySection.swift)
                BGMLibrarySection(project: project, player: bgmPreview)
            }
            // 曲の一覧の読み込みと試聴の停止は、行ごとではなく画面全体で(BGMLibrarySection.swift)
            .task { await BGMTrackStore.shared.loadCatalog() }
            .task(id: project.audio.bgmURL) { await loadBGMDuration() }
            .onDisappear { bgmPreview.stop() }
            .navigationTitle("BGM・音量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: AudioSettingsView.audioTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("BGMを読み込めませんでした", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: BGM

    private var bgmSection: some View {
        Section {
            if let name = project.audio.bgmName, project.audio.bgmURL != nil {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(Color.accentColor)
                    Text(BGMTrack.displayName(forStoredName: name))
                        .lineLimit(2)
                    Spacer()
                    Button(role: .destructive) {
                        removeBGM()
                    } label: {
                        Text("削除")
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    isImporterPresented = true
                } label: {
                    Label("別の曲に変更", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isImporting)
            } else {
                // 曲が無いときは、いちばん目立つ大きなボタンにする
                Button {
                    isImporterPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 20, weight: .semibold))
                        Text("曲を選ぶ")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(BrandStyle.coral, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .disabled(isImporting)
            }

            if isImporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("読み込み中…")
                        .foregroundStyle(.secondary)
                }
            }

            if project.audio.bgmURL != nil {
                // 曲のどこから使うか(長いクラシックの有名な部分から始めるなど。0 = 頭から)
                if bgmDuration > 3 {
                    bgmStartRow
                }
                // 最初のフェードインと最後のフェードアウト(0 = しない。AudioFadePanels.swift)
                AudioFadeSliderRow(title: String(localized: "フェードイン"),
                                   value: $project.audio.bgmFadeIn,
                                   range: 0...5,
                                   compact: false)
                AudioFadeSliderRow(title: String(localized: "フェードアウト"),
                                   value: bgmFadeOutSecondsBinding,
                                   range: 0...5,
                                   compact: false)
            }
        } header: {
            Text("BGM")
        } footer: {
            Text("Apple Music の曲は使えません")
        }
    }

    /// 曲の開始位置(曲の中の秒)。動画が曲より長いときは、2 回目から曲の頭に戻ってくり返す
    private var bgmStartRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("曲の開始位置")
                Spacer()
                Text(Self.timeText(min(project.audio.bgmSourceStart, max(0, bgmDuration - 1))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $project.audio.bgmSourceStart, in: 0...max(1, bgmDuration - 1), step: 1)
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func loadBGMDuration() async {
        guard let url = project.audio.bgmURL else {
            bgmDuration = 0
            return
        }
        let loaded = try? await AVURLAsset(url: url).load(.duration)
        let seconds = loaded.map { CMTimeGetSeconds($0) } ?? 0
        bgmDuration = (seconds.isFinite && seconds > 0) ? seconds : 0
    }

    /// フェードアウトの秒数(0 = しない)。bgmFadeOut のオン/オフはそのまま残す
    private var bgmFadeOutSecondsBinding: Binding<Double> {
        Binding(
            get: { project.audio.bgmFadeOut ? project.audio.bgmFadeOutSeconds : 0 },
            set: { newValue in
                project.audio.bgmFadeOut = newValue > 0.05
                if newValue > 0.05 { project.audio.bgmFadeOutSeconds = newValue }
            })
    }

    // MARK: 音量

    private var volumeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("BGM音量")
                    Spacer()
                    Text(percentText(project.audio.bgmVolume))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.audio.bgmVolume, in: 0...1)
            }
            .disabled(project.audio.bgmURL == nil)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("元の音声の音量")
                    Spacer()
                    Text(percentText(project.audio.originalVolume))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.audio.originalVolume, in: 0...1)
            }
        } header: {
            Text("音量")
        }
    }

    // MARK: 処理

    private func percentText(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = String(localized: "もう一度「曲を選ぶ」から選び直してください。\n\n詳細: ") + error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                isImporting = false
            }
            do {
                let localURL = try MediaStore.importExternalFile(url)
                let name = url.deletingPathExtension().lastPathComponent
                // 読み込めない形式(MIDI・保護された曲・壊れたファイルなど)は使わずに知らせる(前はエラーにならず無音になった)
                Task { @MainActor in
                    isImporting = true
                    let usable = await AudioFileCheck.isUsableAudio(localURL)
                    isImporting = false
                    if usable {
                        project.audio.bgmURL = localURL
                        project.audio.bgmName = name
                        project.audio.bgmSourceStart = 0
                    } else {
                        try? FileManager.default.removeItem(at: localURL)
                        errorMessage = String(localized: "この形式の音声は BGM に使えません。MP3・M4A・WAV などの曲を選んでください。")
                    }
                }
            } catch {
                errorMessage = String(localized: "空き容量を確かめて、もう一度選んでください。Apple Music の曲は使えません。\n\n詳細: ") + error.localizedDescription
            }
        }
    }

    private func removeBGM() {
        project.audio.bgmURL = nil
        project.audio.bgmName = nil
        project.audio.bgmSourceStart = 0
    }
}
