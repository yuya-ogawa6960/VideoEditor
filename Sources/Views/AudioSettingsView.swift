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
                Button {
                    isImporterPresented = true
                } label: {
                    Label("BGMを選ぶ(ファイル)", systemImage: "music.note.list")
                }
                .disabled(isImporting)
            }

            if isImporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("読み込み中…")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("最後の2秒でだんだん小さくする", isOn: $project.audio.bgmFadeOut)
                .disabled(project.audio.bgmURL == nil)
        } header: {
            Text("BGM")
        } footer: {
            Text("「ファイル」アプリに保存した音楽ファイル(MP3 / M4A / WAV / AIFF など)を使えます。Apple Music の曲(DRM保護)は使用できません。BGMは動画の長さに合わせて繰り返されます。")
        }
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
            Text("ボリューム")
        }
    }

    // MARK: 処理

    private func percentText(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = "もう一度「BGMを選ぶ」から曲を選び直してください。\n\n詳細: " + error.localizedDescription
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
                errorMessage = "端末の空き容量を確かめて、もう一度選んでください。Apple Music の曲は使えないので、「ファイル」アプリに保存した曲を選んでください。\n\n詳細: " + error.localizedDescription
            }
        }
    }

    private func removeBGM() {
        project.audio.bgmURL = nil
        project.audio.bgmName = nil
    }
}
