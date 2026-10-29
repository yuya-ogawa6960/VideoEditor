import SwiftUI
import Translation

// =====================================================================
// 吹き替え(下部パネル。AI グループの「吹き替え」から開く)
//   言語 → 声 → 元の音声(そのまま / 小さく / 消す)→ キャプションを訳文で出すか → 「吹き替えを作成」
//   訳 → 読み上げ → ナレーションとして配置 は DubbingRenderer.swift。進み具合とキャンセルは EditorAnalysisRunner
// =====================================================================

struct EditorDubbingPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let analysis: EditorAnalysisRunner

    @State private var target: TranscriptionLanguage = .english
    /// クラウドの声(nil なら端末の声)
    @State private var cloudVoice: CloudVoice?
    /// 端末の声(nil ならその言語のいちばん良い声)
    @State private var deviceVoiceID: String?
    @State private var voices: [(id: String, name: String)] = []
    @State private var originalAudio: DubbingOriginalAudio = .lower
    @State private var showTranslation = true
    /// 訳が無いキャプションを AI で訳す(オフなら Apple の翻訳。端末内・無料)
    @State private var useAITranslation = false
    @State private var translator = DubbingAppleTranslator()
    /// ポイントを使うときの確認(目安のポイント)
    @State private var pendingPoints: Int?
    @State private var errorText: String?
    @State private var recovery: CloudAIRecovery = .none
    @State private var showsAccount = false
    @State private var resultText: String?
    @State private var didSetDefaults = false

    private var source: TranscriptionLanguage {
        target == .english ? .japanese : .english
    }

    private var lines: [DubbingLine] {
        DubbingRenderer.plan(cues: project.subtitles, target: target)
    }

    private var missingCount: Int {
        lines.filter { $0.text == nil }.count
    }

    private var choice: TTSVoiceChoice {
        if let cloudVoice { return .cloud(cloudVoice) }
        return .device(deviceVoiceID ?? DubbingRenderer.bestDeviceVoiceID(for: target))
    }

    private var googleVoicesAvailable: Bool {
        AccountService.shared.googleVoicesAvailable && target == .japanese
    }

    private var aiEngine: SubtitlePolisher.ResolvedEngine {
        SubtitlePolisher.resolveExplicitEngine(settings: AppSettings.shared)
    }

    /// AI 翻訳を使うか(使えるときだけ)
    private var translatesWithAI: Bool {
        useAITranslation && aiEngine != .none && missingCount > 0
    }

    /// 使う見込みのポイント(ポイントを使わないなら 0)
    private var estimatedPoints: Int {
        var total = 0
        if translatesWithAI, aiEngine == .cloud, CloudAIGateway.usesPoints {
            total += SubtitlePolisher.estimatedPoints(lineCount: missingCount)
        }
        // Google の声はポイントでだけ使える
        if let cloudVoice, cloudVoice.isGoogle || CloudAIGateway.prefersPoints {
            total += DubbingRenderer.estimatedSpeechPoints(lines: lines)
        }
        return total
    }

    private var currentVoiceName: String {
        if let cloudVoice { return cloudVoice.displayName }
        guard let deviceVoiceID, let voice = voices.first(where: { $0.id == deviceVoiceID }) else {
            return String(localized: "標準の声")
        }
        return voice.name
    }

    private var needsAccount: Bool {
        switch recovery {
        case .signIn, .points: return true
        default: return false
        }
    }

    private var canStart: Bool {
        !analysis.isRunning && !lines.isEmpty
    }

    private var startTitle: String {
        let points = estimatedPoints
        if points > 0 { return String(localized: "吹き替えを作成 ・ \(points)pt") }
        return String(localized: "吹き替えを作成")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if project.subtitles.isEmpty {
                Text("先にキャプションを作成してください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                languageSection
                voiceSection
                originalAudioSection

                Toggle(isOn: $showTranslation) {
                    Text("キャプションを訳文で表示")
                        .font(.subheadline)
                }
                .tint(.accentColor)

                if missingCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("訳が無いキャプション \(missingCount) 件を先に訳します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if aiEngine != .none {
                            Toggle(isOn: $useAITranslation) {
                                Text("AIで自然に訳す")
                                    .font(.subheadline)
                            }
                            .tint(.accentColor)
                        }
                    }
                }

                startSection
            }
        }
        .padding(.top, 6)
        .onAppear {
            guard !didSetDefaults else { return }
            didSetDefaults = true
            // ふだんは話している言語の反対(日本語のキャプションなら英語)
            target = DubbingRenderer.spokenLanguage(of: project.subtitles) == .english ? .japanese : .english
            reloadVoices()
        }
        .translationTask(translator.configuration) { session in
            await translator.perform(session: session)
        }
        .confirmationDialog(String(localized: "約 \(pendingPoints ?? 0)pt 使います"),
                            isPresented: Binding(get: { pendingPoints != nil },
                                                 set: { if !$0 { pendingPoints = nil } }),
                            titleVisibility: .visible) {
            Button("作成する") {
                pendingPoints = nil
                run()
            }
            Button("キャンセル", role: .cancel) {
                pendingPoints = nil
            }
        } message: {
            Text("キャプション 1 件ごとに声を作ります。「標準」の声ならポイントは使いません。")
        }
        .sheet(isPresented: $showsAccount) {
            AccountPointsSheet()
        }
    }

    // MARK: 言語

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "吹き替える言語"))
            HStack(spacing: 8) {
                ForEach([TranscriptionLanguage.english, .japanese]) { language in
                    EditorChip(title: language.displayName, isSelected: target == language) {
                        guard target != language else { return }
                        target = language
                        deviceVoiceID = nil
                        // Google の声は日本語だけ
                        if cloudVoice?.isGoogle == true, language != .japanese { cloudVoice = .alloy }
                        reloadVoices()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 声

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EditorSectionTitle(title: String(localized: "声"))
                Spacer()
                Menu {
                    if cloudVoice == nil {
                        Button(String(localized: "標準の声")) { deviceVoiceID = nil }
                        ForEach(voices, id: \.id) { voice in
                            Button(voice.name) { deviceVoiceID = voice.id }
                        }
                    } else {
                        ForEach(cloudVoice?.isGoogle == true && googleVoicesAvailable ? CloudVoice.googleVoices : CloudVoice.openAIVoices) { voice in
                            Button(voice.displayName) { cloudVoice = voice }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentVoiceName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            HStack(spacing: 8) {
                EditorChip(title: String(localized: "標準"), isSelected: cloudVoice == nil) {
                    cloudVoice = nil
                }
                EditorChip(title: String(localized: "AIボイス"), isSelected: cloudVoice.map { !$0.isGoogle } ?? false) {
                    if cloudVoice == nil || cloudVoice?.isGoogle == true { cloudVoice = .alloy }
                }
                if googleVoicesAvailable {
                    EditorChip(title: String(localized: "AIボイス 日本語"), isSelected: cloudVoice?.isGoogle ?? false) {
                        if cloudVoice?.isGoogle != true { cloudVoice = .googleAoede }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 元の音声

    private var originalAudioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "オリジナル音声"))
            HStack(spacing: 8) {
                ForEach(DubbingOriginalAudio.allCases) { mode in
                    EditorChip(title: mode.displayName, isSelected: originalAudio == mode) {
                        originalAudio = mode
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 作成

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                start()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.mic")
                    Text(startTitle)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(BrandStyle.coral, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.45)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if needsAccount {
                    EditorPillButton(title: String(localized: "アカウントとポイント"), systemImage: "person.crop.circle") {
                        showsAccount = true
                    }
                }
            } else if let resultText {
                Label(resultText, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reloadVoices() {
        voices = TextToSpeech.availableVoices(language: target.rawValue)
        if let deviceVoiceID, !voices.contains(where: { $0.id == deviceVoiceID }) {
            self.deviceVoiceID = nil
        }
    }

    /// クラウドに送るときは初回の確認、ポイントを使うときは目安を確かめてから始める
    private func start() {
        guard canStart else { return }
        errorText = nil
        recovery = .none
        resultText = nil
        let sendsToCloud = choice.isCloud || (translatesWithAI && aiEngine == .cloud)
        let points = estimatedPoints
        Task { @MainActor in
            if sendsToCloud {
                guard await CloudAIGateway.ensureConsent() else { return }
            }
            if points > 0 {
                pendingPoints = points
            } else {
                run()
            }
        }
    }

    private func run() {
        guard !analysis.isRunning else { return }
        player.pause()
        let initialLines = lines
        guard !initialLines.isEmpty else { return }
        let chosenTarget = target
        let chosenSource = source
        let chosenChoice = choice
        let withAI = translatesWithAI
        let chosenAudio = originalAudio
        let chosenShowTranslation = showTranslation
        let translator = self.translator

        analysis.run(title: String(localized: "吹き替えを作成中")) { report in
            var planned = initialLines
            // 1. 訳
            var translations: [UUID: String] = [:]
            let missing = planned.filter { $0.text == nil }
            if !missing.isEmpty {
                report(0.02)
                if withAI {
                    let ids = Set(missing.map(\.cueID))
                    let cues = project.subtitles.filter { ids.contains($0.id) }
                    let result = await SubtitlePolisher.translate(cues, from: chosenSource,
                                                                  toEnglish: chosenTarget == .english,
                                                                  settings: AppSettings.shared, userInitiated: true)
                    try Task.checkCancellation()
                    guard let result else {
                        if let error = SubtitlePolisher.lastError { throw error }
                        throw DubbingError.nothingToSpeak
                    }
                    for cue in result {
                        let text = (cue.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        // 訳せなかった字幕には前の(別の言語の)訳が残っているので、言語で確かめる
                        if ids.contains(cue.id), !text.isEmpty, DubbingRenderer.isWritten(text, in: chosenTarget) {
                            translations[cue.id] = text
                        }
                    }
                } else {
                    translations = try await translator.translate(missing.map { (id: $0.cueID, text: $0.source) },
                                                                  source: chosenSource.languageCode,
                                                                  target: chosenTarget.languageCode)
                }
                try Task.checkCancellation()
                for i in planned.indices where planned[i].text == nil {
                    planned[i].text = translations[planned[i].cueID]
                }
            }
            report(0.3)

            // 2. 読み上げ(1 件ずつ)
            let speakable = planned.filter { !($0.text ?? "").isEmpty }
            guard !speakable.isEmpty else { throw DubbingError.nothingToSpeak }
            var created: [NarrationClip] = []
            var failure: Error?
            for (i, line) in speakable.enumerated() {
                do {
                    try Task.checkCancellation()
                    let text = line.text ?? ""
                    let spoken = try await DubbingRenderer.speak(line, text: text, choice: chosenChoice, language: chosenTarget)
                    // 次のキャプションにかかる分は切る(最後はそのまま)
                    let duration = line.isLast ? spoken.duration : min(spoken.duration, line.slot)
                    let name = String(localized: "吹き替え: ") + String(text.prefix(12))
                    created.append(NarrationClip(url: spoken.url, name: name, start: line.start, duration: duration))
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        for clip in created { try? FileManager.default.removeItem(at: clip.url) }
                        throw CancellationError()
                    }
                    // 作れた分は残す(クラウドの声はポイントを使っているため)
                    failure = error
                    break
                }
                report(0.3 + 0.68 * Double(i + 1) / Double(speakable.count))
            }
            guard !created.isEmpty else { throw failure ?? DubbingError.nothingToSpeak }

            // 3. 反映(履歴は 1 回)
            history.record(project)
            let replaced = DubbingRenderer.apply(clips: created, translations: translations,
                                                 originalAudio: chosenAudio, showTranslation: chosenShowTranslation,
                                                 to: project)
            player.seek(to: 0)
            var message = String(localized: "\(created.count) 件の吹き替えを追加しました。")
            if replaced > 0 {
                message += String(localized: "前の吹き替えは置き換えました。")
            }
            resultText = message
            if let failure {
                showError(failure, partial: true)
            }
        } onError: { error in
            showError(error, partial: false)
        }
    }

    private func showError(_ error: Error, partial: Bool) {
        let prefix = partial
            ? String(localized: "途中で止まりました: ")
            : String(localized: "吹き替えを作成できませんでした: ")
        if error is CloudAIModerationError {
            errorText = error.localizedDescription
            recovery = .none
        } else {
            errorText = prefix + error.localizedDescription
            recovery = CloudAIGateway.recovery(for: error)
        }
    }
}
