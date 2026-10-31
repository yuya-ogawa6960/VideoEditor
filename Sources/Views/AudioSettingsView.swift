import SwiftUI
import Observation
import UniformTypeIdentifiers

struct AudioSettingsView: View {
    @Bindable var project: EditorProject

    @Environment(\.dismiss) private var dismiss

    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    private static let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]

    var body: some View {
        NavigationStack {
            Form {
                bgmSection
                // アプリが作る曲(BGMLibrarySection.swift)
                BGMLibrarySection(project: project)
                volumeSection
            }
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
                    Text(name)
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
                project.audio.bgmURL = localURL
                project.audio.bgmName = url.deletingPathExtension().lastPathComponent
            } catch {
                errorMessage = String(localized: "空き容量を確かめて、もう一度選んでください。Apple Music の曲は使えません。\n\n詳細: ") + error.localizedDescription
            }
        }
    }

    private func removeBGM() {
        project.audio.bgmURL = nil
        project.audio.bgmName = nil
    }
}
