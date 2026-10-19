import SwiftUI
import Observation
import UniformTypeIdentifiers
import NaturalLanguage
import UIKit

// MARK: - ヘルパー

/// 秒 → "m:ss.s"
fileprivate func subtitleTimeString(_ seconds: Double) -> String {
    let s = max(0, seconds.isFinite ? seconds : 0)
    let tenths = Int((s * 10).rounded())
    let minutes = tenths / 600
    let secs = (tenths % 600) / 10
    let frac = tenths % 10
    return String(format: "%d:%02d.%d", minutes, secs, frac)
}

/// SwiftUI の Color → "#RRGGBB"(0...1 に丸めてから変換)
fileprivate func subtitleHexString(from color: Color) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    func component(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", component(r), component(g), component(b))
}

// MARK: - スタイルプリセット

/// 「スタイル」セクションのチップで選ぶプリセット。SubtitleStyle に存在する項目だけを設定する
fileprivate enum SubtitleStylePreset: String, CaseIterable, Identifiable {
    case standard, netflix, youtube, cinema, pop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "標準"
        case .netflix: return "Netflix風"
        case .youtube: return "YouTube風"
        case .cinema: return "シネマ"
        case .pop: return "ポップ"
        }
    }

    var position: SubtitlePosition { .bottom }

    var color: SubtitleColor {
        switch self {
        case .pop: return .yellow
        default: return .white
        }
    }

    var sizeRatio: CGFloat {
        switch self {
        case .standard: return 0.045
        case .netflix: return 0.042
        case .youtube: return 0.05
        case .cinema: return 0.038
        case .pop: return 0.055
        }
    }

    var hasBackground: Bool {
        switch self {
        case .standard, .youtube, .pop: return true
        case .netflix, .cinema: return false
        }
    }

    /// displayMode は触らず、見た目の項目だけ上書きする
    func apply(to style: inout SubtitleStyle) {
        style.position = position
        style.color = color
        style.sizeRatio = sizeRatio
        style.hasBackground = hasBackground
    }

    /// 現在のスタイルがこのプリセットと一致しているか(チップの選択表示用)
    func matches(_ style: SubtitleStyle) -> Bool {
        style.position == position
            && style.color == color
            && style.hasBackground == hasBackground
            && abs(style.sizeRatio - sizeRatio) < 0.0005
    }
}

// MARK: - 字幕エディタ

struct SubtitleEditorView: View {
    @Bindable var project: EditorProject
    let player: PlayerController

    @Environment(\.dismiss) private var dismiss

    @State private var transcriber = TranscriptionService()
    @State private var selectedLanguage: TranscriptionLanguage = .japanese
    @State private var replaceExisting: Bool = true
    @State private var transcriptionTask: Task<Void, Never>?

    @State private var translationRequest: TranslationRequest?

    @State private var editingCueID: UUID?

    @State private var alertTitle: String = ""
    @State private var alertMessage: String?

    // 字幕ファイル(SRT)の書き出し・読み込み
    @State private var exportUseTranslation: Bool = false
    @State private var exportBilingual: Bool = false
    @State private var exportURL: URL?
    @State private var isImporterPresented: Bool = false
    @State private var pendingImportedCues: [SubtitleCue] = []
    @State private var isImportChoicePresented: Bool = false

    // 字幕一覧の一括操作
    @State private var isDeleteAllPresented: Bool = false
    @State private var showsShiftTool: Bool = false
    @State private var appliedShift: Double = 0

    private var isTranscribing: Bool {
        transcriptionTask != nil || transcriber.isRunning
    }

    private var isTranslating: Bool {
        translationRequest != nil
    }

    private var currentCueID: UUID? {
        let t = player.currentTime
        return project.subtitles.first(where: { t >= $0.start && t < $0.end })?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewHeader
                Form {
                    transcriptionSection
                    translationSection
                    subtitleFileSection
                    styleSection
                    cueListSection
                }
            }
            .navigationTitle("字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .navigationDestination(item: $editingCueID) { cueID in
                SubtitleCueEditView(project: project, player: player, cueID: cueID)
            }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: SubtitleEditorView.subtitleFileTypes,
                          allowsMultipleSelection: false) { result in
                handleSubtitleFileImport(result)
            }
            .confirmationDialog("読み込んだ字幕(\(pendingImportedCues.count) 件)をどうしますか?",
                                isPresented: $isImportChoicePresented,
                                titleVisibility: .visible) {
                Button("既存の字幕を置き換え") {
                    applyImportedCues(replace: true)
                }
                Button("既存の字幕に追加") {
                    applyImportedCues(replace: false)
                }
                Button("キャンセル", role: .cancel) {
                    pendingImportedCues = []
                }
            }
            .confirmationDialog("すべての字幕(\(project.subtitles.count) 件)を削除しますか?",
                                isPresented: $isDeleteAllPresented,
                                titleVisibility: .visible) {
                Button("全部削除", role: .destructive) {
                    project.subtitles.removeAll()
                    exportURL = nil
                    appliedShift = 0
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("この操作は取り消せません。")
            }
        }
        .subtitleTranslation(project: project, request: $translationRequest, onFinish: { result in
            switch result {
            case .success(let count):
                showAlert(title: "翻訳完了",
                          message: "\(count) 件の字幕を翻訳しました。表示を「英訳」または「両方」にすると映像に表示されます。")
            case .failure(let error):
                showAlert(title: "翻訳エラー", message: error.localizedDescription)
            }
        })
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        .onDisappear {
            cancelTranscription()
        }
    }

    // MARK: プレビュー

    private var previewHeader: some View {
        VStack(spacing: 6) {
            PreviewView(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.black)
            HStack(spacing: 16) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 32)
                }
                Text("\(subtitleTimeString(player.currentTime)) / \(subtitleTimeString(player.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 4)
    }

    // MARK: 自動文字起こし

    private var transcriptionSection: some View {
        Section {
            Picker("言語", selection: $selectedLanguage) {
                ForEach(TranscriptionLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .disabled(isTranscribing)

            Picker("既存の字幕", selection: $replaceExisting) {
                Text("置き換え").tag(true)
                Text("追加").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(isTranscribing)

            if isTranscribing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(transcriber.progress, 0), 1))
                    Text(transcriber.statusText.isEmpty ? "準備中…" : transcriber.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("キャンセル", role: .destructive) {
                    cancelTranscription()
                }
            } else {
                Button {
                    startTranscription()
                } label: {
                    Label("文字起こしを開始", systemImage: "waveform")
                }
                .disabled(project.isEmpty || isTranslating)
            }

            NavigationLink {
                TranscriptionSettingsView()
            } label: {
                HStack {
                    Label("文字起こしの方式とAI仕上げ", systemImage: "gearshape")
                    Spacer()
                    Text(AppSettings.shared.transcriptionEngine.shortName)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isTranscribing)
        } header: {
            Text("自動文字起こし")
        } footer: {
            Text(transcriptionFooterText)
        }
    }

    private var transcriptionFooterText: String {
        let settings = AppSettings.shared
        let polish = settings.polishSubtitles
            ? SubtitlePolisher.displayName(of: SubtitlePolisher.resolveEngine(settings: settings))
            : "オフ"
        return "今の方式: " + settings.transcriptionEngine.displayName + "。AI仕上げ: " + polish + "。方式は設定から変えられます。"
    }

    private func startTranscription() {
        guard transcriptionTask == nil else { return }
        let snapshot = project.snapshot()
        let language = selectedLanguage
        let replace = replaceExisting
        transcriptionTask = Task { @MainActor in
            let authorized = await transcriber.requestAuthorization()
            guard authorized else {
                transcriptionTask = nil
                showAlert(title: "音声認識を利用できません",
                          message: "音声認識が許可されていません。設定アプリでこのアプリの音声認識を許可してください。")
                return
            }
            if Task.isCancelled {
                transcriptionTask = nil
                return
            }
            do {
                let transcribed = try await transcriber.transcribe(snapshot: snapshot, language: language)
                // カラオケ風テンプレート用に、単語タイミングが無い字幕へ文字数比例のタイミングを付ける
                let cues = SubtitleWordTiming.fillingMissing(transcribed)
                if Task.isCancelled {
                    transcriptionTask = nil
                    return
                }
                if replace {
                    project.subtitles = cues
                } else {
                    project.subtitles.append(contentsOf: cues)
                }
                project.sortSubtitles()
                transcriptionTask = nil
                if cues.isEmpty {
                    showAlert(title: "文字起こし完了", message: "音声が検出されませんでした。")
                }
            } catch is CancellationError {
                transcriptionTask = nil
            } catch {
                let cancelled = Task.isCancelled
                transcriptionTask = nil
                if !cancelled {
                    showAlert(title: "文字起こしエラー", message: error.localizedDescription)
                }
            }
        }
    }

    private func cancelTranscription() {
        if transcriber.isRunning {
            transcriber.cancel()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    // MARK: 翻訳

    private var translationSection: some View {
        Section {
            if isTranslating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("翻訳中…")
                        .foregroundStyle(.secondary)
                }
            } else if selectedLanguage == .english {
                Button {
                    translationRequest = TranslationRequest(source: selectedLanguage, targetIsEnglish: false)
                } label: {
                    Label("日本語に翻訳", systemImage: "globe")
                }
                .disabled(project.subtitles.isEmpty || isTranscribing)
            } else {
                Button {
                    translationRequest = TranslationRequest(source: selectedLanguage, targetIsEnglish: true)
                } label: {
                    Label("英語に翻訳", systemImage: "globe")
                }
                .disabled(project.subtitles.isEmpty || isTranscribing)
            }
        } header: {
            Text("翻訳")
        } footer: {
            Text("原文の言語は「自動文字起こし」の言語設定を使います。初回は翻訳用の言語データのダウンロードを求められることがあります。")
        }
    }

    // MARK: 字幕ファイル(SRT)

    private static let subtitleFileTypes: [UTType] = {
        var types: [UTType] = []
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
        types.append(.plainText)
        types.append(.text)
        return types
    }()

    private var hasAnyTranslation: Bool {
        project.subtitles.contains { cue in
            guard let t = cue.translatedText else { return false }
            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var subtitleFileSection: some View {
        Section {
            Toggle("英訳を使う", isOn: $exportUseTranslation)
                .disabled(!hasAnyTranslation || exportBilingual)
                .onChange(of: exportUseTranslation) { _, _ in exportURL = nil }
            Toggle("2言語(原文+英訳)", isOn: $exportBilingual)
                .disabled(!hasAnyTranslation)
                .onChange(of: exportBilingual) { _, _ in exportURL = nil }

            if let url = exportURL {
                ShareLink(item: url) {
                    Label("SRTを共有・保存", systemImage: "square.and.arrow.up")
                }
                Button {
                    exportURL = nil
                } label: {
                    Label("書き出しをやり直す", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.secondary)
            } else {
                Button {
                    exportSRT()
                } label: {
                    Label("SRTを書き出し", systemImage: "doc.text")
                }
                .disabled(project.subtitles.isEmpty)
            }

            Button {
                isImporterPresented = true
            } label: {
                Label("SRTを読み込み", systemImage: "square.and.arrow.down")
            }
            .disabled(isTranscribing || isTranslating)
        } header: {
            Text("字幕ファイル")
        } footer: {
            Text("SRT 形式で書き出して他のアプリで使ったり、SRT / WebVTT ファイルを読み込んで字幕を取り込めます。")
        }
    }

    private func exportSRT() {
        guard !project.subtitles.isEmpty else { return }
        let text = SRTCodec.encode(project.subtitles,
                                   useTranslation: exportUseTranslation,
                                   bilingual: exportBilingual)
        let baseName = project.clips.first.map { $0.name } ?? "subtitles"
        let suffix: String
        if exportBilingual {
            suffix = "_ja_en"
        } else if exportUseTranslation {
            suffix = "_en"
        } else {
            suffix = ""
        }
        let fileName = sanitizedFileName(baseName) + suffix + ".srt"
        do {
            exportURL = try SRTCodec.writeTemporaryFile(text, fileName: fileName)
        } catch {
            showAlert(title: "書き出しエラー", message: error.localizedDescription)
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = ""
        for scalar in name.unicodeScalars {
            if forbidden.contains(scalar) {
                cleaned.append("_")
            } else {
                cleaned.append(Character(scalar))
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "subtitles" : cleaned
    }

    private func handleSubtitleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showAlert(title: "読み込みエラー", message: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let decoded = try SRTCodec.decode(data: data)
                let cues = SubtitleWordTiming.fillingMissing(decoded)
                if project.subtitles.isEmpty {
                    pendingImportedCues = cues
                    applyImportedCues(replace: true)
                } else {
                    pendingImportedCues = cues
                    isImportChoicePresented = true
                }
            } catch {
                showAlert(title: "字幕ファイルを読み込めませんでした", message: error.localizedDescription)
            }
        }
    }

    private func applyImportedCues(replace: Bool) {
        let cues = pendingImportedCues
        pendingImportedCues = []
        guard !cues.isEmpty else { return }
        if replace {
            project.subtitles = cues
        } else {
            project.subtitles.append(contentsOf: cues)
        }
        project.sortSubtitles()
        exportURL = nil
        appliedShift = 0
        let verb = replace ? "読み込みました" : "追加しました"
        showAlert(title: "読み込み完了", message: "\(cues.count) 件の字幕を" + verb + "。")
    }

    // MARK: スタイル

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SubtitleStylePreset.allCases) { preset in
                    let selected = preset.matches(project.subtitleStyle)
                    Button {
                        var style = project.subtitleStyle
                        preset.apply(to: &style)
                        project.subtitleStyle = style
                    } label: {
                        Text(preset.displayName)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var templateChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CaptionTemplate.allCases) { template in
                    let selected = project.subtitleStyle.template == template
                    Button {
                        project.subtitleStyle.template = template
                    } label: {
                        Text(template.displayName)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var highlightColorBinding: Binding<Color> {
        Binding<Color>(
            get: { Color(hex: project.subtitleStyle.highlightColorHex) ?? Color.yellow },
            set: { project.subtitleStyle.highlightColorHex = subtitleHexString(from: $0) }
        )
    }

    private var subtitleFontBinding: Binding<String> {
        Binding<String>(
            get: { project.subtitleStyle.fontName ?? "" },
            set: { project.subtitleStyle.fontName = $0.isEmpty ? nil : $0 }
        )
    }

    private var hasAnyWordTiming: Bool {
        project.subtitles.contains { !$0.words.isEmpty }
    }

    private var styleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("プリセット")
                presetChips
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("テンプレート")
                templateChips
                if project.subtitleStyle.template != .plain, !project.subtitles.isEmpty, !hasAnyWordTiming {
                    Text("このテンプレートは単語ごとのタイミングを使います。字幕一覧のメニューから「単語タイミングを作り直す」を実行してください。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ColorPicker("ハイライト色", selection: highlightColorBinding, supportsOpacity: false)

            Picker("フォント", selection: subtitleFontBinding) {
                ForEach(SubtitleFontCatalog.options(including: project.subtitleStyle.fontName)) { option in
                    SubtitleFontCatalog.label(for: option)
                        .tag(option.id)
                }
            }

            Picker("位置", selection: $project.subtitleStyle.position) {
                ForEach(SubtitlePosition.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Picker("文字色", selection: $project.subtitleStyle.color) {
                ForEach(SubtitleColor.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("文字サイズ")
                    Spacer()
                    Text("\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.subtitleStyle.sizeRatio, in: 0.03...0.10)
            }

            Toggle("背景を付ける", isOn: $project.subtitleStyle.hasBackground)

            Picker("表示", selection: $project.subtitleStyle.displayMode) {
                ForEach(SubtitleDisplayMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("スタイル")
        }
    }

    // MARK: 字幕一覧

    private var cueListSection: some View {
        Section {
            Button {
                let cue = project.addSubtitle(at: player.currentTime)
                editingCueID = cue.id
            } label: {
                Label("再生位置に追加", systemImage: "plus.bubble")
            }

            if showsShiftTool && !project.subtitles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper("タイミングを一括ずらす",
                            onIncrement: { shiftAllCues(by: 0.1) },
                            onDecrement: { shiftAllCues(by: -0.1) })
                    HStack {
                        Text(appliedShiftText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("閉じる") {
                            showsShiftTool = false
                            appliedShift = 0
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }

            if project.subtitles.isEmpty {
                Text("字幕はまだありません。「再生位置に追加」または自動文字起こしで作成できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let highlightedID = currentCueID
                ForEach(project.subtitles) { cue in
                    cueRow(cue, isCurrent: cue.id == highlightedID)
                }
                .onDelete { offsets in
                    project.subtitles.remove(atOffsets: offsets)
                }
            }
        } header: {
            HStack {
                Text("字幕一覧(\(project.subtitles.count))")
                Spacer()
                if !project.subtitles.isEmpty {
                    Menu {
                        Button {
                            appliedShift = 0
                            showsShiftTool = true
                        } label: {
                            Label("タイミングを一括ずらす", systemImage: "arrow.left.and.right")
                        }
                        Button {
                            regenerateWordTimings()
                        } label: {
                            Label("単語タイミングを作り直す", systemImage: "textformat.abc.dottedunderline")
                        }
                        Button(role: .destructive) {
                            isDeleteAllPresented = true
                        } label: {
                            Label("全部削除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                    }
                    .textCase(nil)
                }
            }
        }
    }

    private var appliedShiftText: String {
        let rounded = (appliedShift * 10).rounded() / 10
        if abs(rounded) < 0.05 {
            return "±0.1 秒ずつ全字幕を前後に動かします"
        }
        let sign = rounded > 0 ? "+" : ""
        let amount = String(format: "%.1f", rounded)
        return "合計 " + sign + amount + " 秒ずらしました"
    }

    /// 全字幕を delta 秒ずらす。先頭の字幕が 0 秒より前にならないよう delta を丸める
    private func shiftAllCues(by delta: Double) {
        guard !project.subtitles.isEmpty else { return }
        var effective = delta
        if delta < 0 {
            let minStart = project.subtitles.map { $0.start }.min() ?? 0
            effective = max(delta, -minStart)
        }
        guard abs(effective) > 0.0001 else { return }
        var cues = project.subtitles
        for i in cues.indices {
            let oldStart = cues[i].start
            let oldEnd = cues[i].end
            let newStart = max(0, oldStart + effective)
            let newEnd = max(newStart + 0.2, oldEnd + effective)
            cues[i].start = newStart
            cues[i].end = newEnd
            cues[i].words = SubtitleWordTiming.rescaled(cues[i].words,
                                                        oldStart: oldStart, oldEnd: oldEnd,
                                                        newStart: newStart, newEnd: newEnd)
        }
        project.subtitles = cues
        project.sortSubtitles()
        appliedShift += effective
        exportURL = nil
    }

    /// 全字幕に、文字数に比例した単語タイミングを付け直す(カラオケ風テンプレート用)
    private func regenerateWordTimings() {
        guard !project.subtitles.isEmpty else { return }
        var cues = project.subtitles
        for i in cues.indices {
            cues[i].words = SubtitleWordTiming.distribute(cue: cues[i])
        }
        project.subtitles = cues
        showAlert(title: "単語タイミングを更新しました",
                  message: "\(cues.count) 件の字幕に、文字数に応じた単語タイミングを付けました。カラオケ風などのテンプレートで単語ごとに色が変わります。")
    }

    private func cueRow(_ cue: SubtitleCue, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                player.seek(to: cue.start)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(subtitleTimeString(cue.start)) – \(subtitleTimeString(cue.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    Text(cue.text.isEmpty ? "(空)" : cue.text)
                        .foregroundStyle(Color.primary)
                        .lineLimit(3)
                    if let translated = cue.translatedText, !translated.isEmpty {
                        Text(translated)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button {
                editingCueID = cue.id
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }
}

// MARK: - 字幕1件の編集画面

struct SubtitleCueEditView: View {
    let project: EditorProject
    let player: PlayerController
    let cueID: UUID

    @Environment(\.dismiss) private var dismiss

    private let minimumLength: Double = 0.2

    var body: some View {
        Group {
            if let binding = project.subtitleBinding(id: cueID) {
                editor(binding)
            } else {
                Text("この字幕は削除されました。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("字幕を編集")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editor(_ cue: Binding<SubtitleCue>) -> some View {
        Form {
            Section {
                TextField("字幕のテキスト", text: cue.text, axis: .vertical)
                    .lineLimit(1...6)
            } header: {
                Text("テキスト")
            }

            Section {
                TextField("翻訳(任意)", text: Binding(
                    get: { cue.wrappedValue.translatedText ?? "" },
                    set: { newValue in
                        var c = cue.wrappedValue
                        c.translatedText = newValue.isEmpty ? nil : newValue
                        cue.wrappedValue = c
                    }
                ), axis: .vertical)
                .lineLimit(1...6)
            } header: {
                Text("翻訳")
            }

            Section {
                Stepper("開始 " + subtitleTimeString(cue.wrappedValue.start),
                        onIncrement: { setStart(cue, cue.wrappedValue.start + 0.1) },
                        onDecrement: { setStart(cue, cue.wrappedValue.start - 0.1) })
                HStack {
                    Button("再生位置にする") {
                        setStart(cue, player.currentTime)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("ここへ移動") {
                        player.seek(to: cue.wrappedValue.start)
                    }
                    .buttonStyle(.borderless)
                }

                Stepper("終了 " + subtitleTimeString(cue.wrappedValue.end),
                        onIncrement: { setEnd(cue, cue.wrappedValue.end + 0.1) },
                        onDecrement: { setEnd(cue, cue.wrappedValue.end - 0.1) })
                HStack {
                    Button("再生位置にする") {
                        setEnd(cue, player.currentTime)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("ここへ移動") {
                        player.seek(to: max(cue.wrappedValue.start, cue.wrappedValue.end - 0.1))
                    }
                    .buttonStyle(.borderless)
                }

                Text("長さ \(String(format: "%.1f", cue.wrappedValue.duration)) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("タイミング")
            } footer: {
                Text("現在の再生位置: \(subtitleTimeString(player.currentTime))")
            }

            Section {
                Button(role: .destructive) {
                    project.removeSubtitle(id: cueID)
                    dismiss()
                } label: {
                    Label("この字幕を削除", systemImage: "trash")
                }
            }
        }
        .onChange(of: cue.wrappedValue.text) { _, _ in
            // 文字を変えたら単語タイミングを付け直す(単語を使うテンプレートのとき、または元々付いていたとき)
            var c = cue.wrappedValue
            guard !c.words.isEmpty || project.subtitleStyle.template != .plain else { return }
            c.words = SubtitleWordTiming.distribute(cue: c)
            cue.wrappedValue = c
        }
    }

    private func setStart(_ cue: Binding<SubtitleCue>, _ value: Double) {
        var c = cue.wrappedValue
        let oldStart = c.start
        let oldEnd = c.end
        c.start = max(0, value)
        if c.end < c.start + minimumLength {
            c.end = c.start + minimumLength
        }
        c.words = SubtitleWordTiming.rescaled(c.words, oldStart: oldStart, oldEnd: oldEnd,
                                              newStart: c.start, newEnd: c.end)
        cue.wrappedValue = c
        project.sortSubtitles()
    }

    private func setEnd(_ cue: Binding<SubtitleCue>, _ value: Double) {
        var c = cue.wrappedValue
        let oldStart = c.start
        let oldEnd = c.end
        c.end = max(value, c.start + minimumLength)
        c.words = SubtitleWordTiming.rescaled(c.words, oldStart: oldStart, oldEnd: oldEnd,
                                              newStart: c.start, newEnd: c.end)
        cue.wrappedValue = c
        project.sortSubtitles()
    }
}

// MARK: - 単語タイミング

/// 字幕の単語タイミング(カラオケ風・単語ごとのテンプレート用)。
/// 音声認識から単語の時刻が取れないため、文字数に比例して cue の区間を分配する。
enum SubtitleWordTiming {
    /// cue の区間を、単語の文字数に比例して分配したタイミングを返す
    static func distribute(cue: SubtitleCue) -> [SubtitleWord] {
        distribute(text: cue.text, start: cue.start, end: cue.end)
    }

    static func distribute(text: String, start: Double, end: Double) -> [SubtitleWord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, end > start else { return [] }
        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        let span = end - start
        var result: [SubtitleWord] = []
        result.reserveCapacity(tokens.count)
        var cursor = start
        for (i, token) in tokens.enumerated() {
            let wordEnd = (i == tokens.count - 1) ? end : min(end, cursor + span * weights[i] / total)
            result.append(SubtitleWord(text: token, start: cursor, end: wordEnd))
            cursor = wordEnd
        }
        return result
    }

    /// words が空の cue にだけタイミングを付ける
    static func fillingMissing(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { cue in
            guard cue.words.isEmpty else { return cue }
            var c = cue
            c.words = distribute(cue: c)
            return c
        }
    }

    /// cue の開始・終了を変えたとき、単語の時刻を古い区間から新しい区間へ線形に写す
    static func rescaled(_ words: [SubtitleWord],
                         oldStart: Double, oldEnd: Double,
                         newStart: Double, newEnd: Double) -> [SubtitleWord] {
        guard !words.isEmpty else { return words }
        let oldSpan = oldEnd - oldStart
        let newSpan = newEnd - newStart
        guard oldSpan > 0.0001, newSpan > 0 else { return words }
        let scale = newSpan / oldSpan
        return words.map { word in
            SubtitleWord(text: word.text,
                         start: newStart + (word.start - oldStart) * scale,
                         end: newStart + (word.end - oldStart) * scale)
        }
    }

    /// NLTokenizer で単語に分ける。単語の後ろの句読点・記号は前の単語に付ける(日本語・英語とも)
    private static func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }

        var tokens: [String] = []
        for (i, range) in ranges.enumerated() {
            var token = ""
            if i == 0, range.lowerBound > text.startIndex {
                // 先頭の記号(「 など)は最初の単語に付ける
                let lead = text[text.startIndex..<range.lowerBound].filter { !$0.isWhitespace && !$0.isNewline }
                token += String(lead)
            }
            token += String(text[range])
            let gapEnd = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : text.endIndex
            if range.upperBound < gapEnd {
                let trail = text[range.upperBound..<gapEnd].filter { !$0.isWhitespace && !$0.isNewline }
                token += String(trail)
            }
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                tokens.append(cleaned)
            }
        }

        if tokens.isEmpty {
            // 分割できないときは空白区切り、それも無ければ全体を 1 語にする
            let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return parts.isEmpty ? [text] : parts
        }
        return tokens
    }
}

// MARK: - フォントの選択肢

/// 字幕・サムネで共通のフォント選択肢。id が空文字ならシステムフォント
enum SubtitleFontCatalog {
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let builtIn: [Option] = [
        Option(id: "", label: "システム(標準)"),
        Option(id: "HiraginoSans-W6", label: "ヒラギノ角ゴ W6"),
        Option(id: "HiraMinProN-W6", label: "ヒラギノ明朝 W6"),
        Option(id: "HiraMaruProN-W4", label: "ヒラギノ丸ゴ W4"),
        Option(id: "Noteworthy-Bold", label: "Noteworthy(ノート風)"),
        Option(id: "BradleyHandITCTT-Bold", label: "Bradley Hand(手書き風)"),
        Option(id: "Chalkduster", label: "Chalkduster(チョーク)"),
        Option(id: "MarkerFelt-Wide", label: "Marker Felt(マーカー)"),
        Option(id: "AvenirNext-Bold", label: "Avenir Next Bold"),
        Option(id: "Futura-Bold", label: "Futura Bold")
    ]

    /// 組み込み + 「ファイル」から読み込んだフォント(MediaTools)+ 現在選ばれている名前(一覧に無ければ追加)
    static func options(including current: String?) -> [Option] {
        var result = builtIn
        var known = Set(result.map { $0.id })
        for name in MediaTools.storedFontNames() where !known.contains(name) {
            result.append(Option(id: name, label: "\(name)(読み込み)"))
            known.insert(name)
        }
        if let current, !current.isEmpty, !known.contains(current) {
            result.append(Option(id: current, label: current))
        }
        return result
    }

    /// Picker 用のラベル(そのフォントで表示)
    static func label(for option: Option) -> some View {
        Group {
            if option.id.isEmpty {
                Text(option.label)
            } else {
                Text(option.label)
                    .font(.custom(option.id, size: 17))
            }
        }
    }
}
