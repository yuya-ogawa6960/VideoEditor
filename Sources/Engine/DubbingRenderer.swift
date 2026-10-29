import Foundation
import AVFoundation
import Observation
import Translation

// =====================================================================
// 吹き替え(AI ダビング): キャプションを訳して、訳文を読み上げた声をキャプションの時刻に置く。
//   1. 訳が無い(または別の言語の訳しか無い)キャプションを訳す
//      - 「AIで自然に訳す」: SubtitlePolisher.translate(userInitiated)(Apple Intelligence / ポイント / API キー)
//      - それ以外: Apple の翻訳(端末内・無料。DubbingAppleTranslator を画面に付けて使う)
//   2. 1 件ずつ TextToSpeech.render で声にする。次のキャプションまでに収まるよう、文字数から話す速さを
//      少しだけ上げる(最大 1.35 倍)。端末の声は無料なので、はみ出したら 1 回だけ速めに作り直す
//   3. NarrationClip としてキャプションの開始時刻に置く(次のキャプションにかかる分は切る)
//   4. 元の音声(クリップの音)をそのまま / 小さく / 消す、キャプションの表示を訳文にする
// 作った音声ファイルは「<UUID>_vmdub.<拡張子>」にして、やり直したときに前の吹き替えを見分けて置き換える。
// =====================================================================

/// 元の音声(クリップの音)をどうするか
enum DubbingOriginalAudio: String, CaseIterable, Identifiable {
    case keep, lower, mute
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .keep: return String(localized: "そのまま")
        case .lower: return String(localized: "小さく")
        case .mute: return String(localized: "消す")
        }
    }
}

enum DubbingError: LocalizedError {
    case noCaptions
    case nothingToSpeak

    var errorDescription: String? {
        switch self {
        case .noCaptions: return String(localized: "先にキャプションを作成してください")
        case .nothingToSpeak: return String(localized: "読み上げる訳文がありませんでした")
        }
    }
}

/// 1 件分の吹き替え
struct DubbingLine {
    let cueID: UUID
    /// 出力タイムライン上の開始秒
    let start: Double
    /// 次のキャプションが始まるまでの秒(最後は少し余裕を見る)
    let slot: Double
    /// 最後のキャプションか(切らない)
    let isLast: Bool
    /// 原文
    let source: String
    /// 読み上げる文(訳文。訳がまだ無ければ nil)
    var text: String?
}

@MainActor
enum DubbingRenderer {

    /// 吹き替えで作った音声ファイルの名前の印
    static let fileMarker = "vmdub"
    /// 元の音声を「小さく」したときの音量
    static let loweredVolume: Float = 0.2

    // MARK: - 言語

    /// ひらがな・カタカナ・漢字を含むか(日本語の文か)
    nonisolated static func looksJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    /// キャプションの言語(日本語らしい文が半分以上なら日本語)
    static func spokenLanguage(of cues: [SubtitleCue]) -> TranscriptionLanguage {
        let texts = cues.map { $0.text }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return .japanese }
        let japanese = texts.filter { looksJapanese($0) }.count
        return japanese * 2 >= texts.count ? .japanese : .english
    }

    /// 文が target の言語で書かれているか
    nonisolated static func isWritten(_ text: String, in target: TranscriptionLanguage) -> Bool {
        looksJapanese(text) == (target == .japanese)
    }

    // MARK: - 計画

    /// キャプションから吹き替えの行を作る。原文がすでに target の言語ならそのまま、合う訳があればそれを使う
    static func plan(cues: [SubtitleCue], target: TranscriptionLanguage) -> [DubbingLine] {
        let sorted = cues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var lines: [DubbingLine] = []
        for (i, cue) in sorted.enumerated() {
            let source = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = (cue.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var text: String? = nil
            if isWritten(source, in: target) {
                text = source
            } else if !translated.isEmpty, isWritten(translated, in: target) {
                text = translated
            }
            let isLast = i == sorted.count - 1
            let slot: Double
            if isLast {
                slot = cue.duration + 2
            } else {
                slot = max(0.4, sorted[i + 1].start - cue.start)
            }
            lines.append(DubbingLine(cueID: cue.id, start: max(0, cue.start), slot: slot, isLast: isLast,
                                     source: source, text: text))
        }
        return lines
    }

    // MARK: - ポイントの目安

    /// クラウドの声で lines を読み上げたときの目安のポイント。
    /// サーバーは端数を持ち越すので、1 件ずつ読んでも全部の文字数の合計で決まる
    static func estimatedSpeechPoints(lines: [DubbingLine]) -> Int {
        let chars = lines.reduce(0) { $0 + ($1.text ?? $1.source).count }
        return AccountService.shared.speechPoints(forCharacters: chars)
    }

    // MARK: - 声

    /// 端末の声で、その言語のいちばん品質の高い声(自分の声・おもしろ声は除く)
    nonisolated static func bestDeviceVoiceID(for language: TranscriptionLanguage) -> String? {
        let code = language.languageCode
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.lowercased().hasPrefix(code)
                && !voice.voiceTraits.contains(.isPersonalVoice)
                && !voice.voiceTraits.contains(.isNoveltyVoice)
        }
        let best = voices.max { a, b in a.quality.rawValue < b.quality.rawValue }
        return best?.identifier ?? AVSpeechSynthesisVoice(language: language.rawValue)?.identifier
    }

    /// 文字数から見た、slot に収めるための話す速さ(TextToSpeech.render の rate。0.5 = ふつう、最大 1.35 倍)
    nonisolated static func fittedRate(text: String, language: TranscriptionLanguage, slot: Double) -> Float {
        let perSecond = language == .japanese ? 7.5 : 15.0
        let natural = Double(text.count) / perSecond
        let factor = min(1.35, max(1.0, natural / max(slot, 0.4)))
        return Float(0.5 * factor)
    }

    /// 1 件を声にする。端末の声ではみ出したら、1 回だけ速めに作り直す。
    /// 返す URL は「<UUID>_vmdub.<拡張子>」に名前を変えたもの
    static func speak(_ line: DubbingLine, text: String, choice: TTSVoiceChoice,
                      language: TranscriptionLanguage) async throws -> (url: URL, duration: Double) {
        var rate = fittedRate(text: text, language: language, slot: line.slot)
        var url = try await TextToSpeech.render(choice: choice, text: text, rate: rate, pitch: 1, instructions: nil)
        var duration = await audioDuration(of: url)
        if !choice.isCloud, !line.isLast, duration > line.slot + 0.25, rate < 0.62 {
            try Task.checkCancellation()
            rate = min(0.62, rate * Float(duration / max(line.slot, 0.4)))
            let retry = try await TextToSpeech.render(choice: choice, text: text, rate: rate, pitch: 1, instructions: nil)
            try? FileManager.default.removeItem(at: url)
            url = retry
            duration = await audioDuration(of: url)
        }
        return (markAsDub(url), duration)
    }

    private static func audioDuration(of url: URL) async -> Double {
        let loaded = try? await AVURLAsset(url: url).load(.duration)
        let seconds = loaded?.seconds ?? 1
        return (seconds.isFinite && seconds > 0) ? seconds : 1
    }

    /// 吹き替えの印の付いた名前に変える(変えられなければ元のまま)
    private static func markAsDub(_ url: URL) -> URL {
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let destination = MediaStore.uniqueDestination(forFileName: "\(fileMarker).\(ext)")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    /// 吹き替えで作ったナレーションか
    static func isDubbing(_ clip: NarrationClip) -> Bool {
        clip.url.deletingPathExtension().lastPathComponent.hasSuffix("_" + fileMarker)
    }

    // MARK: - 反映

    /// 作った声と訳をプロジェクトに入れる(呼ぶ側で履歴を 1 回記録してから呼ぶ)。前の吹き替えは置き換える。
    /// 戻り値は置き換えた前の吹き替えの数
    @discardableResult
    static func apply(clips newClips: [NarrationClip], translations: [UUID: String],
                      originalAudio: DubbingOriginalAudio, showTranslation: Bool,
                      to project: EditorProject) -> Int {
        // 訳(訳が無かったキャプションだけに入れる)
        for i in project.subtitles.indices {
            if let text = translations[project.subtitles[i].id], !text.isEmpty {
                project.subtitles[i].translatedText = text
            }
        }
        // 前の吹き替えを外して、新しいものを置く
        let before = project.narration.count
        project.narration.removeAll { isDubbing($0) }
        let replaced = before - project.narration.count
        project.narration.append(contentsOf: newClips)
        project.sortNarration()

        // 元の音声
        for i in project.clips.indices where project.clips[i].hasAudio {
            switch originalAudio {
            case .keep:
                break
            case .lower:
                project.clips[i].audio.volume = min(project.clips[i].audio.volume, loweredVolume)
            case .mute:
                project.clips[i].isMuted = true
            }
        }

        // キャプションを訳文で出す(原文と訳の 2 行の字幕も訳文だけにする)
        if showTranslation {
            project.subtitleStyle.displayMode = .translated
            for i in project.subtitles.indices where project.subtitles[i].bilingual {
                project.subtitles[i].bilingual = false
            }
        }
        return replaced
    }
}

// MARK: - Apple の翻訳(端末内)

/// Apple の翻訳(Translation フレームワーク)を async で呼べるようにする。
/// 画面に `.translationTask(translator.configuration) { session in await translator.perform(session: session) }` を付けて使う
@MainActor
@Observable
final class DubbingAppleTranslator {
    var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var pending: [(id: UUID, text: String)] = []
    @ObservationIgnored private var continuation: CheckedContinuation<[UUID: String], Error>?

    /// 1 回の translations(from:) に渡す最大件数
    private let batchSize = 50

    /// items を source → target に訳す(言語は "ja" / "en")。結果はキャプションの ID ごと
    func translate(_ items: [(id: UUID, text: String)], source: String, target: String) async throws -> [UUID: String] {
        guard !items.isEmpty else { return [:] }
        finish(.failure(CancellationError()))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UUID: String], Error>) in
                self.continuation = cont
                self.pending = items
                let sourceLanguage = Locale.Language(identifier: source)
                let targetLanguage = Locale.Language(identifier: target)
                if var existing = self.configuration, existing.source == sourceLanguage, existing.target == targetLanguage {
                    // 同じ言語の組み合わせの再実行は invalidate() で translationTask を動かし直す
                    existing.invalidate()
                    self.configuration = existing
                } else {
                    self.configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
            }
        }
    }

    /// translationTask から呼ぶ
    func perform(session: TranslationSession) async {
        // 表示したときなどにも呼ばれるので、頼まれていなければ何もしない
        guard continuation != nil else { return }
        let items = pending
        do {
            // 言語データが未ダウンロードならここでダウンロードの確認が出る
            try await session.prepareTranslation()
            var result: [UUID: String] = [:]
            var index = 0
            while index < items.count {
                let end = min(index + batchSize, items.count)
                var requests: [TranslationSession.Request] = []
                for k in index..<end {
                    requests.append(TranslationSession.Request(sourceText: items[k].text, clientIdentifier: String(k)))
                }
                let responses = try await session.translations(from: requests)
                for response in responses {
                    guard let identifier = response.clientIdentifier, let k = Int(identifier), k < items.count else { continue }
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { result[items[k].id] = text }
                }
                index = end
            }
            finish(.success(result))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<[UUID: String], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        pending = []
        cont.resume(with: result)
    }
}
