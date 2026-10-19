import SwiftUI
import UIKit
import AVFoundation
import Observation

// =====================================================================
// 第4弾: AI 台本
//   テーマ・長さ・口調から ScriptWriter.write で台本(時刻つきの行)を作り、
//   行を直してから「読み上げて挿入」(TextToSpeech → ナレーション)/「字幕として挿入」(SubtitleCue)。
//   「字幕から構成案」は ScriptWriter.outline でチャプターのマーカーを追加する。
// =====================================================================

struct ScriptWriterSheetView: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// ナレーションを追加したときに呼ぶ(最後に追加した ID)
    let onNarrationAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var topic = ""
    @State private var durationSeconds: Double = 60
    @State private var tone: ScriptTone = .friendly
    @State private var lines: [ScriptLine] = []
    @State private var analysis = EditorAnalysisRunner()
    @State private var errorText: String?
    @State private var infoText: String?

    // 読み上げ
    @State private var language = "ja-JP"
    @State private var voices: [(id: String, name: String)] = []
    @State private var voiceID: String?
    @State private var rate: Float = 0.5
    @State private var pitch: Float = 1.0
    @State private var replaceSubtitles = false

    private let durationOptions: [Double] = [30, 60, 90, 120, 180]

    private var currentVoiceName: String {
        guard let voiceID, let voice = voices.first(where: { $0.id == voiceID }) else { return "標準の声" }
        return voice.name
    }

    /// ScriptWriter と同じ判定(「AI 仕上げ: 使わない」でも使えるエンジンがあれば使う)
    private var engineName: String {
        ScriptWriter.engineDisplayName(settings: AppSettings.shared)
    }

    private var hasEngine: Bool {
        ScriptWriter.isAvailable(settings: AppSettings.shared)
    }

    private var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nonEmptyLines: [ScriptLine] {
        lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time < $1.time }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    inputSection
                    actionSection
                    linesSection
                    if !lines.isEmpty {
                        narrationSection
                        subtitleSection
                    }
                }
                if let progress = analysis.progress {
                    ClipFXProgressOverlay(progress: progress) {
                        analysis.cancel()
                    }
                }
            }
            .navigationTitle("AI台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        analysis.cancel()
                        dismiss()
                    }
                }
            }
            .alert("お知らせ", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            let total = project.totalDuration
            if total > 5 {
                durationSeconds = min(600, max(10, (total / 5).rounded() * 5))
            }
            reloadVoices()
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { errorText != nil },
            set: { newValue in
                if !newValue { errorText = nil }
            }
        )
    }

    // MARK: 入力

    private var inputSection: some View {
        Section {
            TextField("例: 京都の紅葉を巡る 1 日(見どころと移動のコツ)", text: $topic, axis: .vertical)
                .lineLimit(1...4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("長さ")
                    Spacer()
                    Text(MediaTimeText.precise(durationSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if project.totalDuration > 1 {
                            EditorChip(title: "動画の長さ",
                                       isSelected: abs(durationSeconds - project.totalDuration) < 0.5) {
                                durationSeconds = project.totalDuration
                            }
                        }
                        ForEach(durationOptions, id: \.self) { option in
                            EditorChip(title: "\(Int(option)) 秒",
                                       isSelected: abs(durationSeconds - option) < 0.5) {
                                durationSeconds = option
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Slider(value: $durationSeconds, in: 10...600, step: 5)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("口調")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScriptTone.allCases) { option in
                            EditorChip(title: option.displayName, isSelected: tone == option) {
                                tone = option
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            NavigationLink {
                TranscriptionSettingsView()
            } label: {
                HStack {
                    Label("AI の設定", systemImage: "gearshape")
                    Spacer()
                    Text(engineName)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("テーマ")
        } footer: {
            if hasEngine {
                Text("いまの AI: \(engineName)。字幕やマーカーがあれば、それも参考にして台本を作ります。")
            } else {
                Text("台本の作成には Apple Intelligence(iOS 26 以降)か OpenAI の API キーが必要です。「AI の設定」から設定してください。")
            }
        }
    }

    // MARK: 作成

    private var actionSection: some View {
        Section {
            Button {
                write()
            } label: {
                Label(lines.isEmpty ? "台本を作る" : "台本を作り直す", systemImage: "text.badge.star")
            }
            .disabled(trimmedTopic.isEmpty || analysis.isRunning)

            Button {
                outline()
            } label: {
                Label("字幕から構成案(チャプター)を作る", systemImage: "list.bullet.indent")
            }
            .disabled(project.subtitles.isEmpty || analysis.isRunning)

            if let infoText {
                Text(infoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("「字幕から構成案」は、いまある字幕を読んで章の区切りを提案し、チャプターのマーカーとして追加します。")
        }
    }

    // MARK: 台本の行

    private var linesSection: some View {
        Section {
            if lines.isEmpty {
                Text("台本はまだありません。テーマを入れて「台本を作る」を押してください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($lines) { $line in
                    lineRow($line)
                }
                .onDelete { offsets in
                    lines.remove(atOffsets: offsets)
                }
                Button {
                    addLine()
                } label: {
                    Label("行を追加", systemImage: "plus")
                }
            }
        } header: {
            HStack {
                Text("台本(\(lines.count) 行)")
                Spacer()
                if !lines.isEmpty {
                    Button("並べ替え") {
                        lines.sort { $0.time < $1.time }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        } footer: {
            if !lines.isEmpty {
                Text("時刻は出力タイムライン上の目安です。左にスワイプで削除できます。")
            }
        }
    }

    private func lineRow(_ line: Binding<ScriptLine>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(MediaTimeText.precise(line.wrappedValue.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: line.time, in: 0...3600, step: 1)
                    .labelsHidden()
                Spacer()
                Button {
                    player.seek(to: line.wrappedValue.time)
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("この時刻へ移動")
            }
            TextField("セリフ", text: line.text, axis: .vertical)
                .lineLimit(1...5)
        }
        .padding(.vertical, 2)
    }

    private func addLine() {
        let last = lines.map { $0.time }.max() ?? 0
        let time = lines.isEmpty ? 0 : last + 5
        lines.append(ScriptLine(time: time, text: ""))
    }

    // MARK: 挿入(ナレーション)

    private var narrationSection: some View {
        Section {
            HStack(spacing: 8) {
                EditorChip(title: "日本語", isSelected: language == "ja-JP") {
                    language = "ja-JP"
                    reloadVoices()
                }
                EditorChip(title: "English", isSelected: language == "en-US") {
                    language = "en-US"
                    reloadVoices()
                }
                Spacer()
            }

            HStack {
                Text("声")
                Spacer()
                Menu {
                    Button("標準の声") { voiceID = nil }
                    ForEach(voices, id: \.id) { voice in
                        Button(voice.name) { voiceID = voice.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentVoiceName)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("速さ")
                    Spacer()
                    Text(String(format: "%.2f", rate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rate, in: 0.3...0.7)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("高さ")
                    Spacer()
                    Text(String(format: "%.2f", pitch))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pitch, in: 0.6...1.6)
            }

            Button {
                insertNarration()
            } label: {
                Label("読み上げて挿入(ナレーション)", systemImage: "waveform.badge.plus")
            }
            .disabled(nonEmptyLines.isEmpty || analysis.isRunning)
        } header: {
            Text("読み上げ")
        } footer: {
            Text("各行をその時刻に読み上げたナレーションとして追加します。前の行と重なるときは後ろへずらします。")
        }
    }

    private func reloadVoices() {
        voices = TextToSpeech.availableVoices(language: language)
        if let voiceID, !voices.contains(where: { $0.id == voiceID }) {
            self.voiceID = nil
        }
    }

    private func insertNarration() {
        let items = nonEmptyLines
        guard !items.isEmpty else { return }
        let chosenVoice = voiceID
        let chosenRate = rate
        let chosenPitch = pitch
        errorText = nil
        infoText = nil
        player.pause()
        analysis.run(title: "読み上げを作成中") { report in
            var created: [NarrationClip] = []
            let total = Double(items.count)
            for (i, line) in items.enumerated() {
                if Task.isCancelled { break }
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = try await TextToSpeech.render(text: text,
                                                        voiceIdentifier: chosenVoice,
                                                        rate: chosenRate,
                                                        pitch: chosenPitch)
                let asset = AVURLAsset(url: url)
                let loaded = try? await asset.load(.duration)
                let seconds: Double = loaded?.seconds ?? 1
                let duration: Double = (seconds.isFinite && seconds > 0) ? seconds : 1
                let name = "台本: " + String(text.prefix(12))
                created.append(NarrationClip(url: url, name: name, start: max(0, line.time), duration: duration))
                report(Double(i + 1) / total)
            }
            if Task.isCancelled {
                for clip in created {
                    try? FileManager.default.removeItem(at: clip.url)
                }
                return
            }
            guard !created.isEmpty else { return }

            // 前の行と重なるときは後ろへずらす
            var adjusted = created
            var cursor: Double = 0
            for i in adjusted.indices {
                if adjusted[i].start < cursor {
                    adjusted[i].start = cursor
                }
                cursor = adjusted[i].end + 0.2
            }

            history.record(project)
            project.narration.append(contentsOf: adjusted)
            project.sortNarration()
            infoText = "\(adjusted.count) 件のナレーションを追加しました。「音量」「音声効果」で調整できます。"
            if let last = adjusted.last {
                onNarrationAdded(last.id)
            }
        } onError: { error in
            errorText = "読み上げを作成できませんでした。\n\(error.localizedDescription)"
        }
    }

    // MARK: 挿入(字幕)

    private var subtitleSection: some View {
        Section {
            Toggle("既存の字幕を置き換える", isOn: $replaceSubtitles)
                .disabled(project.subtitles.isEmpty)
            Button {
                insertSubtitles()
            } label: {
                Label("字幕として挿入", systemImage: "captions.bubble")
            }
            .disabled(nonEmptyLines.isEmpty || analysis.isRunning)
        } header: {
            Text("字幕")
        } footer: {
            Text("各行をその時刻からの字幕にします。長さは文字数から見積もり、次の行と重ならないようにします。")
        }
    }

    private func insertSubtitles() {
        let items = nonEmptyLines
        guard !items.isEmpty else { return }
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(items.count)
        for (i, line) in items.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start: Double = max(0, line.time)
            let characters = Double(text.count)
            let estimated: Double = max(1.5, min(8, characters * 0.22))
            var end: Double = start + estimated
            if i + 1 < items.count {
                let nextStart: Double = max(start + 0.6, items[i + 1].time)
                end = min(end, nextStart - 0.1)
            }
            cues.append(SubtitleCue(start: start, end: max(start + 0.5, end), text: text))
        }
        let withWords = SubtitleWordTiming.fillingMissing(cues)
        history.record(project)
        if replaceSubtitles {
            project.subtitles = withWords
        } else {
            project.subtitles.append(contentsOf: withWords)
        }
        project.sortSubtitles()
        infoText = "\(withWords.count) 件の字幕を追加しました。「自動字幕」でタイミングや文を直せます。"
    }

    // MARK: AI 呼び出し

    private func write() {
        let theme = trimmedTopic
        guard !theme.isEmpty else { return }
        let seconds = durationSeconds
        let chosenTone = tone
        let subtitles = project.subtitles
        let markers = project.markers
        errorText = nil
        infoText = nil
        analysis.run(title: "台本を作成中", indeterminate: true) { _ in
            let result = try await ScriptWriter.write(topic: theme,
                                                      durationSeconds: seconds,
                                                      tone: chosenTone,
                                                      subtitles: subtitles,
                                                      markers: markers,
                                                      settings: AppSettings.shared)
            if Task.isCancelled { return }
            lines = result.sorted { $0.time < $1.time }
            if lines.isEmpty {
                infoText = "台本を作れませんでした。テーマをもう少し具体的にしてお試しください。"
            } else {
                infoText = "\(lines.count) 行の台本ができました。内容と時刻を直してから挿入できます。"
            }
        } onError: { error in
            errorText = "台本を作成できませんでした。\n\(error.localizedDescription)"
        }
    }

    private func outline() {
        let subtitles = project.subtitles
        guard !subtitles.isEmpty else { return }
        errorText = nil
        infoText = nil
        analysis.run(title: "構成案を作成中", indeterminate: true) { _ in
            let suggested = try await ScriptWriter.outline(from: subtitles, settings: AppSettings.shared)
            if Task.isCancelled { return }
            guard !suggested.isEmpty else {
                infoText = "構成案を作れませんでした。字幕がもう少し長いとうまくいきます。"
                return
            }
            history.record(project)
            var markers = project.markers
            var added = 0
            for item in suggested {
                var marker = item
                marker.kind = .chapter
                if markers.contains(where: { $0.kind == .chapter && abs($0.time - marker.time) < 0.5 }) {
                    continue
                }
                markers.append(marker)
                added += 1
            }
            project.markers = markers
            project.sortMarkers()
            infoText = "\(added) 個のチャプターを追加しました。マーカーを選ぶと名前を直せます。"
        } onError: { error in
            errorText = "構成案を作成できませんでした。\n\(error.localizedDescription)"
        }
    }
}
