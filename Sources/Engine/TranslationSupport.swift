import Foundation
import SwiftUI
import NaturalLanguage
import Translation

// =====================================================================
// 字幕翻訳(Apple Translation フレームワーク、端末内処理)
// 使い方: 画面に一度だけ `.subtitleTranslation(project:request:onFinish:)` を付け、
// `request = TranslationRequest(source: .japanese, targetIsEnglish: true)` をセットする。
//
// 字幕は文・文節単位なので基本は 1 件ずつ翻訳するが、
// 「文末記号で終わらない字幕 + それに続く字幕」が 1 つの文を成している場合は
// 連結して 1 回で翻訳し、訳文を文字数比で各字幕に配分する(英語は単語境界、
// 日本語は 、。や文節境界で切る)。
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
            return String(localized: "翻訳元と翻訳先の言語が同じです。")
        case .noSubtitles:
            return String(localized: "翻訳する字幕がありません。")
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

// MARK: - 文のグループ化と訳文の配分(純粋ロジック)

/// 連続する字幕が 1 文を成すかどうかの判定と、訳文の配分
enum SubtitleTranslationGrouping {

    /// 1 グループ = 1 回の翻訳単位(字幕 index の並び)
    struct Group {
        var indices: [Int]
        var texts: [String]
    }

    /// 1 グループに入れる最大字幕数
    static let maxCuesPerGroup = 5
    /// 1 グループの最大文字数(原文)
    static let maxCharactersPerGroup = 160
    /// この間隔(秒)を超えて離れている字幕は別の文とみなす
    static let maxGap: Double = 1.0

    /// 文末記号で終わらない字幕を次の字幕と同じグループにする
    static func makeGroups(_ cues: [SubtitleCue]) -> [Group] {
        // 開始時刻順に処理するが、index は元配列のまま保持する
        let order = cues.indices.sorted { cues[$0].start < cues[$1].start }
        var groups: [Group] = []
        var current: Group? = nil
        var currentChars = 0
        var previousCue: SubtitleCue? = nil

        for index in order {
            let cue = cues[index]
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if var group = current, let prev = previousCue {
                let continues = !SubtitleSegmenter.endsWithSentencePunctuation(prev.text)
                    && (cue.start - prev.end) <= maxGap
                    && group.indices.count < maxCuesPerGroup
                    && currentChars + text.count <= maxCharactersPerGroup
                if continues {
                    group.indices.append(index)
                    group.texts.append(text)
                    current = group
                    currentChars += text.count
                    previousCue = cue
                    continue
                }
                groups.append(group)
            }
            current = Group(indices: [index], texts: [text])
            currentChars = text.count
            previousCue = cue
        }
        if let group = current { groups.append(group) }
        return groups
    }

    /// 原文の連結(日本語は空白なし、英語は空白区切り)
    static func joinedSource(_ texts: [String], language: TranscriptionLanguage) -> String {
        if language == .english {
            return texts.joined(separator: " ")
        }
        var result = ""
        for text in texts {
            if let prev = result.last, let next = text.first, prev.isASCII, next.isASCII,
               (prev.isLetter || prev.isNumber), (next.isLetter || next.isNumber) {
                result.append(" ")
            }
            result.append(text)
        }
        return result
    }

    /// 訳文を weights(原文の文字数)の比で分割する。
    /// 英語: 単語境界で切る。日本語: 、。などの句読点 → 文節(単語)境界 → 文字 の順で近い位置を選ぶ
    static func distribute(_ translation: String, weights: [Int], targetIsEnglish: Bool) -> [String] {
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = weights.count
        guard count > 1 else { return [text] }
        guard !text.isEmpty else { return Array(repeating: "", count: count) }

        let scalars = Array(text.unicodeScalars)
        let total = scalars.count
        guard total >= count else {
            // 配分できないほど短い → 先頭に全文
            return [text] + Array(repeating: "", count: count - 1)
        }

        // 候補位置(この位置の直前で切る)
        var punctuationBreaks: [Int] = []
        var wordBreaks: [Int] = []
        if targetIsEnglish {
            for (i, s) in scalars.enumerated() where s.properties.isWhitespace && i > 0 {
                wordBreaks.append(i)
                let before = scalars[i - 1]
                if before == "," || before == ";" || before == ":" || before == "." || before == "!" || before == "?" || before == "—" || before == "–" {
                    punctuationBreaks.append(i)
                }
            }
        } else {
            for i in 1..<total {
                let before = scalars[i - 1]
                if before == "、" || before == "。" || before == "，" || before == "！" || before == "？" || before == "," || before == "." {
                    punctuationBreaks.append(i)
                }
            }
            let view = text.unicodeScalars
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.setLanguage(.japanese)
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let hi = view.distance(from: view.startIndex, to: range.upperBound)
                if hi > 0, hi < total { wordBreaks.append(hi) }
                return true
            }
        }

        let weightSum = max(1, weights.reduce(0) { $0 + max(1, $1) })
        var cuts: [Int] = []
        var cumulative = 0
        var previousCut = 0
        for k in 0..<(count - 1) {
            cumulative += max(1, weights[k])
            let desired = Double(total) * Double(cumulative) / Double(weightSum)
            let remainingPieces = count - 1 - k
            // 後続の各断片に最低 1 スカラーは残す
            let minCut = previousCut + 1
            let maxCut = total - remainingPieces
            guard minCut <= maxCut else { break }
            let tolerance = max(2.0, Double(total) / Double(count) * 0.35)

            func pick(_ candidates: [Int], within: Double?) -> Int? {
                var best: Int? = nil
                var bestDistance = Double.infinity
                for c in candidates where c >= minCut && c <= maxCut {
                    let d = abs(Double(c) - desired)
                    if let within, d > within { continue }
                    if d < bestDistance {
                        bestDistance = d
                        best = c
                    }
                }
                return best
            }

            let chosen = pick(punctuationBreaks, within: tolerance)
                ?? pick(wordBreaks, within: nil)
                ?? min(max(Int(desired.rounded()), minCut), maxCut)
            cuts.append(chosen)
            previousCut = chosen
        }

        var pieces: [String] = []
        var lo = 0
        for cut in cuts {
            pieces.append(substring(scalars, lo, cut))
            lo = cut
        }
        pieces.append(substring(scalars, lo, total))
        while pieces.count < count { pieces.append("") }

        // 空の断片ができた場合は前の断片に寄せる(表示上は原文にフォールバックする)
        return pieces
    }

    private static func substring(_ scalars: [Unicode.Scalar], _ lo: Int, _ hi: Int) -> String {
        guard lo < hi, lo >= 0, hi <= scalars.count else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lo..<hi])
        return String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ViewModifier

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
        guard let pending else { return }

        let cues: [SubtitleCue] = await MainActor.run { project.subtitles }
        let groups = SubtitleTranslationGrouping.makeGroups(cues)

        // clientIdentifier = グループ番号
        var items: [TranslationSession.Request] = []
        for (groupIndex, group) in groups.enumerated() {
            let sourceText = SubtitleTranslationGrouping.joinedSource(group.texts, language: pending.source)
            guard !sourceText.isEmpty else { continue }
            items.append(TranslationSession.Request(sourceText: sourceText, clientIdentifier: String(groupIndex)))
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

            var translatedByGroup: [Int: String] = [:]
            var index = 0
            while index < items.count {
                let end = min(index + batchSize, items.count)
                let batch = Array(items[index..<end])
                let responses = try await session.translations(from: batch)
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let groupIndex = Int(identifier) else { continue }
                    translatedByGroup[groupIndex] = response.targetText
                }
                index = end
            }

            // グループの訳文を各字幕に配分(字幕 ID で突き合わせる)
            var translatedByID: [UUID: String] = [:]
            for (groupIndex, group) in groups.enumerated() {
                guard let translation = translatedByGroup[groupIndex] else { continue }
                let weights = group.texts.map { max(1, $0.count) }
                let pieces = SubtitleTranslationGrouping.distribute(translation, weights: weights,
                                                                    targetIsEnglish: pending.targetIsEnglish)
                for (k, cueIndex) in group.indices.enumerated() where cueIndex < cues.count {
                    let piece = k < pieces.count ? pieces[k] : ""
                    translatedByID[cues[cueIndex].id] = piece
                }
            }

            let result = translatedByID
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
