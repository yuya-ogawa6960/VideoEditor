import Foundation
import SwiftUI
import Translation

// =====================================================================
// 字幕翻訳(Apple Translation フレームワーク、端末内処理)
// 使い方: 画面に一度だけ `.subtitleTranslation(project:request:onFinish:)` を付け、
// `request = TranslationRequest(source: .japanese, targetIsEnglish: true)` をセットする。
// =====================================================================

struct TranslationRequest: Equatable {
    let id: UUID
    let source: TranscriptionLanguage
    let targetIsEnglish: Bool

    init(source: TranscriptionLanguage, targetIsEnglish: Bool = true) {
        self.id = UUID()
        self.source = source
        self.targetIsEnglish = targetIsEnglish
    }
}

enum SubtitleTranslationError: LocalizedError {
    case sameLanguage
    case noSubtitles

    var errorDescription: String? {
        switch self {
        case .sameLanguage:
            return "翻訳元と翻訳先の言語が同じです。"
        case .noSubtitles:
            return "翻訳する字幕がありません。"
        }
    }
}

extension View {
    /// Attach once. When `request` becomes non-nil, translates every `project.subtitles[i].text`
    /// into `translatedText`, then sets `request = nil` and calls onFinish (on the main actor).
    func subtitleTranslation(project: EditorProject, request: Binding<TranslationRequest?>,
                             onFinish: @escaping (Result<Int, Error>) -> Void) -> some View {
        modifier(SubtitleTranslationModifier(project: project, request: request, onFinish: onFinish))
    }
}

private struct SubtitleTranslationModifier: ViewModifier {
    var project: EditorProject
    @Binding var request: TranslationRequest?
    let onFinish: (Result<Int, Error>) -> Void

    @State private var configuration: TranslationSession.Configuration?

    /// 1回の translations(from:) に渡す最大件数
    private let batchSize = 50

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, newValue in
                if let newValue { start(newValue) }
            }
            .onAppear {
                if let request { start(request) }
            }
            .translationTask(configuration) { session in
                await runTranslation(session: session)
            }
    }

    private func start(_ newRequest: TranslationRequest) {
        let sourceCode = newRequest.source.languageCode
        let targetCode = newRequest.targetIsEnglish ? "en" : "ja"
        guard sourceCode != targetCode else {
            request = nil
            onFinish(.failure(SubtitleTranslationError.sameLanguage))
            return
        }
        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetCode)
        if var existing = configuration, existing.source == source, existing.target == target {
            // 同じ言語ペアの再実行は invalidate() で translationTask を再起動させる
            existing.invalidate()
            configuration = existing
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func runTranslation(session: TranslationSession) async {
        // translationTask は表示時などにも呼ばれうるので、要求がなければ何もしない
        let pending: TranslationRequest? = await MainActor.run { request }
        guard pending != nil else { return }

        let cues: [SubtitleCue] = await MainActor.run { project.subtitles }
        let items: [TranslationSession.Request] = cues.compactMap { cue in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranslationSession.Request(sourceText: text, clientIdentifier: cue.id.uuidString)
        }

        guard !items.isEmpty else {
            await MainActor.run {
                request = nil
                onFinish(.failure(SubtitleTranslationError.noSubtitles))
            }
            return
        }

        do {
            // 言語データが未ダウンロードならここでダウンロードの確認が表示される
            try await session.prepareTranslation()

            var translated: [UUID: String] = [:]
            var index = 0
            while index < items.count {
                let end = min(index + batchSize, items.count)
                let batch = Array(items[index..<end])
                let responses = try await session.translations(from: batch)
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let id = UUID(uuidString: identifier) else { continue }
                    translated[id] = response.targetText
                }
                index = end
            }

            let result = translated
            await MainActor.run {
                var count = 0
                for i in project.subtitles.indices {
                    if let text = result[project.subtitles[i].id] {
                        project.subtitles[i].translatedText = text
                        count += 1
                    }
                }
                request = nil
                onFinish(.success(count))
            }
        } catch {
            await MainActor.run {
                request = nil
                onFinish(.failure(error))
            }
        }
    }
}
