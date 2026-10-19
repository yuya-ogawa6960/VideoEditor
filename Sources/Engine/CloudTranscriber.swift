import Foundation
import AVFoundation
import NaturalLanguage

// =====================================================================
// クラウド音声認識(OpenAI Audio Transcriptions API)
//
// - 音声は 16kHz モノラル AAC(m4a、約 32kbps)にして ≤10 分 / ≤20MB ごとに送る
// - まず primaryModel(gpt-4o-transcribe 系、セグメント時刻付き JSON)を試し、
//   4xx の「モデル/パラメータ非対応」エラーなら fallbackModel(whisper-1、単語時刻付き)へ切り替える。
//   切り替えは同じ実行の中で記憶し、二重アップロードを繰り返さない
// - 単語時刻があればそれを、無ければセグメント内で文字数比に均等配分、
//   それも無ければ本文全体をピースの長さに均等配分する
// - API キーはログに出さない
// =====================================================================

enum CloudTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(String)
    case offline
    case timedOut
    case network(String)
    case fileTooLarge
    case server(status: Int, message: String)
    case badResponse
    case noAudio

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI の API キーが設定されていません。文字起こし設定でキーを入力してください。"
        case .invalidAPIKey:
            return "APIキーが正しくありません。文字起こし設定で OpenAI の API キーを確認してください。"
        case .rateLimited(let detail):
            return detail.isEmpty ? "利用上限です。しばらく待ってからもう一度お試しください。"
                                  : "利用上限です。\(detail)"
        case .offline:
            return "インターネットに接続されていません。通信環境を確認してください。"
        case .timedOut:
            return "サーバーの応答がタイムアウトしました。通信環境を確認してもう一度お試しください。"
        case .network(let detail):
            return "通信エラー: \(detail)"
        case .fileTooLarge:
            return "音声ファイルが大きすぎて送信できません。"
        case .server(let status, let message):
            return "OpenAI サーバーがエラーを返しました(\(status)): \(message)"
        case .badResponse:
            return "サーバーの応答を読み取れませんでした。"
        case .noAudio:
            return "送信できる音声がありません。"
        }
    }
}

final class CloudTranscriber {
    static let shared = CloudTranscriber()

    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// 最初に試すモデル。gpt-4o-transcribe 系で時刻付き(diarized_json)を返せるもの
    static var primaryModel = "gpt-4o-transcribe-diarize"
    /// primary が 4xx(モデル/パラメータ非対応)のときに使うモデル(verbose_json + 単語時刻)
    static var fallbackModel = "whisper-1"

    /// 1 ピースの最大長(秒)とサイズ(バイト)
    static let maxPieceSeconds: Double = 600
    static let maxPieceBytes: Int64 = 20 * 1024 * 1024

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - 公開 API

    /// 音声ファイル全体を認識し、ファイル先頭からの秒のトークン列を返す。language は "ja" / "en"
    func transcribe(audioURL: URL, language: String, apiKey: String? = nil,
                    progress: @escaping (Double) -> Void) async throws -> [TimedToken] {
        try await transcribe(sourceURL: audioURL, start: 0, end: nil, language: language,
                             apiKey: apiKey, progress: progress)
    }

    /// 元素材 sourceURL の start〜end(秒。end が nil なら末尾まで)を認識し、元素材上の秒のトークン列を返す
    func transcribe(sourceURL: URL, start: Double, end: Double?, language: String, apiKey: String? = nil,
                    progress: @escaping (Double) -> Void) async throws -> [TimedToken] {
        let key = (apiKey ?? AppSettings.shared.openAIKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }

        let asset = AVURLAsset(url: sourceURL)
        let assetDuration = try await asset.load(.duration).seconds
        let rangeStart = max(0, start)
        var rangeEnd = end ?? assetDuration
        if assetDuration.isFinite, assetDuration > 0 { rangeEnd = min(rangeEnd, assetDuration) }
        guard rangeEnd.isFinite, rangeEnd > rangeStart + 0.05 else { throw CloudTranscriptionError.noAudio }

        var queue = Self.pieces(start: rangeStart, end: rangeEnd)
        guard !queue.isEmpty else { throw CloudTranscriptionError.noAudio }
        let totalDuration = max(0.001, rangeEnd - rangeStart)
        var doneDuration = 0.0
        var useFallback = false
        var tokens: [TimedToken] = []
        progress(0)

        while !queue.isEmpty {
            try Task.checkCancellation()
            let piece = queue.removeFirst()
            let pieceLength = piece.end - piece.start

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cloud-\(UUID().uuidString).m4a")
            let extracted: TranscriptionAudioExtractor.Output
            do {
                extracted = try await TranscriptionAudioExtractor.extract(from: sourceURL, start: piece.start, end: piece.end,
                                                                          to: tempURL, format: .m4a16kMono)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }

            if extracted.fileSize > Self.maxPieceBytes {
                try? FileManager.default.removeItem(at: tempURL)
                guard pieceLength > 20 else { throw CloudTranscriptionError.fileTooLarge }
                let mid = (piece.start + piece.end) / 2
                queue.insert(PieceRange(start: mid, end: piece.end), at: 0)
                queue.insert(PieceRange(start: piece.start, end: mid), at: 0)
                continue
            }

            let fileData: Data
            do {
                fileData = try Data(contentsOf: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw CloudTranscriptionError.network(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: tempURL)
            try Task.checkCancellation()
            progress(min(1, (doneDuration + pieceLength * 0.2) / totalDuration))

            let outcome = try await transcribePiece(fileData: fileData, language: language, apiKey: key,
                                                    useFallback: useFallback)
            useFallback = outcome.usedFallback
            try Task.checkCancellation()

            let pieceTokens = Self.makeTokens(from: outcome.parsed, pieceDuration: extracted.duration, language: language)
            let offset = extracted.startOffset
            tokens.append(contentsOf: pieceTokens.map {
                TimedToken(text: $0.text, start: offset + $0.start, end: offset + $0.end)
            })

            doneDuration += pieceLength
            progress(min(1, doneDuration / totalDuration))
        }

        tokens.sort { $0.start < $1.start }
        return tokens
    }

    // MARK: - ピース分割

    struct PieceRange {
        let start: Double
        let end: Double
    }

    private static func pieces(start: Double, end: Double) -> [PieceRange] {
        var result: [PieceRange] = []
        var s = start
        while s < end - 0.05 {
            var e = min(s + maxPieceSeconds, end)
            // 残りが 30 秒未満ならこのピースに含める(ピースが長くなりすぎない範囲で)
            if end - e < 30, end - s <= maxPieceSeconds * 1.1 { e = end }
            result.append(PieceRange(start: s, end: e))
            s = e
        }
        return result
    }

    // MARK: - リクエスト

    private enum ModelKind {
        case whisper   // verbose_json + 単語/セグメント時刻
        case diarize   // diarized_json(セグメント時刻)
        case plain     // json(本文のみ)
    }

    private static func kind(of model: String) -> ModelKind {
        if model.hasPrefix("whisper") { return .whisper }
        if model.contains("diarize") { return .diarize }
        return .plain
    }

    private struct PieceOutcome {
        let parsed: ParsedTranscription
        let usedFallback: Bool
    }

    private func transcribePiece(fileData: Data, language: String, apiKey: String,
                                 useFallback: Bool) async throws -> PieceOutcome {
        var model = useFallback ? Self.fallbackModel : Self.primaryModel
        var fallbackUsed = useFallback
        var attempt = 0

        while true {
            try Task.checkCancellation()
            attempt += 1
            let (status, data) = try await send(fileData: fileData, model: model, language: language, apiKey: apiKey)

            if (200..<300).contains(status) {
                let parsed = try Self.parse(data)
                return PieceOutcome(parsed: parsed, usedFallback: fallbackUsed)
            }

            let apiError = Self.apiError(from: data)
            switch status {
            case 401:
                throw CloudTranscriptionError.invalidAPIKey
            case 413:
                throw CloudTranscriptionError.fileTooLarge
            case 429:
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                    continue
                }
                let detail: String
                if apiError.code.contains("insufficient_quota") || apiError.message.lowercased().contains("quota") {
                    detail = "OpenAI の残高(クレジット)が不足している可能性があります。"
                } else {
                    detail = "しばらく待ってからもう一度お試しください。"
                }
                throw CloudTranscriptionError.rateLimited(detail)
            case 400, 404, 415, 422:
                if !fallbackUsed, model != Self.fallbackModel, Self.isModelCompatibilityError(apiError) {
                    // モデルが使えない/形式非対応 → フォールバックへ(以降のピースもこちら)
                    model = Self.fallbackModel
                    fallbackUsed = true
                    attempt = 0
                    continue
                }
                throw CloudTranscriptionError.server(status: status, message: apiError.message.isEmpty ? "リクエストが拒否されました" : apiError.message)
            case 500...599:
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                throw CloudTranscriptionError.server(status: status, message: apiError.message.isEmpty ? "一時的な障害です" : apiError.message)
            default:
                throw CloudTranscriptionError.server(status: status, message: apiError.message.isEmpty ? "不明なエラー" : apiError.message)
            }
        }
    }

    /// multipart POST。(HTTP ステータス, 本文)を返す。通信エラーは CloudTranscriptionError に変換
    private func send(fileData: Data, model: String, language: String, apiKey: String) async throws -> (Int, Data) {
        var body = MultipartBody()
        body.addField("model", model)
        body.addField("language", language)
        switch Self.kind(of: model) {
        case .whisper:
            body.addField("response_format", "verbose_json")
            body.addField("timestamp_granularities[]", "word")
            body.addField("timestamp_granularities[]", "segment")
            body.addField("temperature", "0")
        case .diarize:
            body.addField("response_format", "diarized_json")
            body.addField("chunking_strategy", "auto")
        case .plain:
            body.addField("response_format", "json")
            body.addField("chunking_strategy", "auto")
        }
        body.addFile(name: "file", filename: "audio.m4a", mimeType: "audio/m4a", fileData: fileData)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        do {
            let (data, response) = try await session.upload(for: request, from: body.finished())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                throw CloudTranscriptionError.offline
            case .timedOut:
                throw CloudTranscriptionError.timedOut
            default:
                throw CloudTranscriptionError.network(error.localizedDescription)
            }
        } catch {
            if error is CancellationError { throw error }
            throw CloudTranscriptionError.network(error.localizedDescription)
        }
    }

    // MARK: - エラー応答

    private struct APIError {
        var message: String = ""
        var type: String = ""
        var param: String = ""
        var code: String = ""
    }

    private static func apiError(from data: Data) -> APIError {
        var result = APIError()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8) {
                result.message = String(text.prefix(200))
            }
            return result
        }
        if let error = root["error"] as? [String: Any] {
            result.message = error["message"] as? String ?? ""
            result.type = error["type"] as? String ?? ""
            result.param = error["param"] as? String ?? ""
            result.code = error["code"] as? String ?? ""
        } else if let message = root["message"] as? String {
            result.message = message
        }
        return result
    }

    /// 「モデルが無い / このモデルでは response_format 等が使えない」系の 4xx か
    private static func isModelCompatibilityError(_ error: APIError) -> Bool {
        let code = error.code.lowercased()
        let param = error.param.lowercased()
        let message = error.message.lowercased()
        if code.contains("model_not_found") || code.contains("unsupported") || code.contains("invalid_value") { return true }
        if ["model", "response_format", "chunking_strategy", "timestamp_granularities", "timestamp_granularities[]", "language"].contains(param) { return true }
        if message.contains("response_format") || message.contains("chunking_strategy") { return true }
        if message.contains("not supported") || message.contains("unsupported") || message.contains("does not support") { return true }
        if message.contains("model") && (message.contains("does not exist") || message.contains("not found") || message.contains("do not have access") || message.contains("invalid")) { return true }
        return false
    }

    // MARK: - 応答の解析

    fileprivate struct RawWord {
        let text: String
        let start: Double
        let end: Double
    }

    fileprivate struct RawSegment {
        let text: String
        let start: Double
        let end: Double
    }

    fileprivate struct ParsedTranscription {
        var text: String
        var duration: Double?
        var words: [RawWord]
        var segments: [RawSegment]
    }

    private static func parse(_ data: Data) throws -> ParsedTranscription {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return ParsedTranscription(text: text, duration: nil, words: [], segments: [])
            }
            throw CloudTranscriptionError.badResponse
        }
        let text = (root["text"] as? String) ?? ""
        let duration = number(root["duration"])

        var words: [RawWord] = []
        if let rawWords = root["words"] as? [[String: Any]] {
            for raw in rawWords {
                guard let word = raw["word"] as? String,
                      let start = number(raw["start"]), let end = number(raw["end"]) else { continue }
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                words.append(RawWord(text: trimmed, start: start, end: max(start, end)))
            }
        }

        var segments: [RawSegment] = []
        if let rawSegments = root["segments"] as? [[String: Any]] {
            for raw in rawSegments {
                guard let segmentText = raw["text"] as? String,
                      let start = number(raw["start"]), let end = number(raw["end"]) else { continue }
                let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                segments.append(RawSegment(text: trimmed, start: start, end: max(start, end)))
            }
        }
        words.sort { $0.start < $1.start }
        segments.sort { $0.start < $1.start }
        return ParsedTranscription(text: text, duration: duration, words: words, segments: segments)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    // MARK: - トークン化(ピース先頭からの秒)

    private static func makeTokens(from parsed: ParsedTranscription, pieceDuration: Double, language: String) -> [TimedToken] {
        if !parsed.words.isEmpty {
            if parsed.segments.isEmpty {
                return parsed.words.map { TimedToken(text: $0.text, start: $0.start, end: $0.end) }
            }
            return alignedTokens(words: parsed.words, segments: parsed.segments, language: language)
        }
        if !parsed.segments.isEmpty {
            var result: [TimedToken] = []
            for segment in parsed.segments {
                result.append(contentsOf: TranscriptionTokenUtilities.distributeEvenly(
                    text: segment.text, start: segment.start, end: segment.end, language: language))
            }
            return result
        }
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let duration = parsed.duration ?? pieceDuration
        return TranscriptionTokenUtilities.distributeEvenly(text: text, start: 0, end: max(0.5, duration), language: language)
    }

    /// 単語(句読点なし)にセグメント本文の句読点を貼り付ける(whisper-1 の verbose_json 用)
    private static func alignedTokens(words: [RawWord], segments: [RawSegment], language: String) -> [TimedToken] {
        var result: [TimedToken] = []
        var wordIndex = 0
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            var segmentWords: [RawWord] = []
            while wordIndex < words.count {
                let word = words[wordIndex]
                let mid = (word.start + word.end) / 2
                if isLast || mid < segment.end + 0.02 {
                    segmentWords.append(word)
                    wordIndex += 1
                } else {
                    break
                }
            }
            if segmentWords.isEmpty {
                result.append(contentsOf: TranscriptionTokenUtilities.distributeEvenly(
                    text: segment.text, start: segment.start, end: segment.end, language: language))
            } else {
                result.append(contentsOf: attachPunctuation(segmentText: segment.text, words: segmentWords))
            }
        }
        while wordIndex < words.count {
            let word = words[wordIndex]
            result.append(TimedToken(text: word.text, start: word.start, end: word.end))
            wordIndex += 1
        }
        return result
    }

    private static let openingMarks: Set<Unicode.Scalar> = [
        "「", "『", "（", "(", "“", "‘", "【", "〔", "[", "〈", "《", "｢",
    ]

    private static func isPunctuationScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .otherPunctuation, .openPunctuation, .closePunctuation, .dashPunctuation,
             .initialPunctuation, .finalPunctuation, .connectorPunctuation,
             .otherSymbol, .mathSymbol, .currencySymbol, .modifierSymbol:
            return true
        default:
            return false
        }
    }

    private static func scalarEquals(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if a == b { return true }
        return String(a).lowercased() == String(b).lowercased()
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ core: [Unicode.Scalar]) -> Bool {
        guard !core.isEmpty, index >= 0, index + core.count <= scalars.count else { return false }
        for k in 0..<core.count where !scalarEquals(scalars[index + k], core[k]) {
            return false
        }
        return true
    }

    private static func search(_ scalars: [Unicode.Scalar], from: Int, _ core: [Unicode.Scalar], limit: Int) -> Int? {
        guard !core.isEmpty else { return nil }
        var i = max(0, from)
        let maxStart = min(scalars.count - core.count, from + limit)
        while i <= maxStart {
            if matches(scalars, at: i, core) { return i }
            i += 1
        }
        return nil
    }

    private static func attachPunctuation(segmentText: String, words: [RawWord]) -> [TimedToken] {
        let scalars = Array(segmentText.unicodeScalars)
        var cursor = 0
        var out: [TimedToken] = []
        var mismatches = 0

        for word in words {
            let core = Array(word.text.unicodeScalars).filter { !$0.properties.isWhitespace }
            var text = String(String.UnicodeScalarView(core))

            while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
            var prefix = String.UnicodeScalarView()
            var probe = cursor
            while probe < scalars.count, openingMarks.contains(scalars[probe]) {
                prefix.append(scalars[probe])
                probe += 1
            }

            var matchedAt: Int? = nil
            if matches(scalars, at: probe, core) {
                matchedAt = probe
            } else if let found = search(scalars, from: cursor, core, limit: 12) {
                matchedAt = found
                prefix = String.UnicodeScalarView()
                mismatches += 1
            } else {
                mismatches += 1
            }

            if let at = matchedAt {
                var end = at + core.count
                var suffix = String.UnicodeScalarView()
                while end < scalars.count, isPunctuationScalar(scalars[end]), !openingMarks.contains(scalars[end]) {
                    suffix.append(scalars[end])
                    end += 1
                }
                text = String(prefix) + String(String.UnicodeScalarView(core)) + String(suffix)
                cursor = end
            }

            if !text.isEmpty {
                out.append(TimedToken(text: text, start: word.start, end: word.end))
            }
        }

        if mismatches * 2 > words.count {
            // ずれが大きい → 句読点なしの単語をそのまま返す
            return words.map { TimedToken(text: $0.text, start: $0.start, end: $0.end) }
        }
        return out
    }
}

// MARK: - multipart/form-data

private struct MultipartBody {
    let boundary = "VideoManiaBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private(set) var data = Data()

    mutating func addField(_ name: String, _ value: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, fileData: Data) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        appendString("\r\n")
    }

    func finished() -> Data {
        var result = data
        if let tail = "--\(boundary)--\r\n".data(using: .utf8) {
            result.append(tail)
        }
        return result
    }

    private mutating func appendString(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            data.append(encoded)
        }
    }
}

// MARK: - 共通ユーティリティ(時刻の均等配分)

enum TranscriptionTokenUtilities {
    /// NLTokenizer の単語に直後の句読点・記号を付けた断片列。language は "ja" / "en" など
    static func wordPieces(_ text: String, language: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(language.lowercased().hasPrefix("ja") ? .japanese : .english)
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard !ranges.isEmpty else { return [] }
        var pieces: [String] = []
        for (i, range) in ranges.enumerated() {
            let lower = (i == 0) ? text.startIndex : range.lowerBound
            let upper = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : text.endIndex
            guard lower < upper else { continue }
            let piece = String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces
    }

    /// text を単語断片に分け、start〜end を文字数比で配分したトークン列を返す
    static func distributeEvenly(text: String, start: Double, end: Double, language: String) -> [TimedToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let safeEnd = max(start, end)
        let pieces = wordPieces(trimmed, language: language)
        guard !pieces.isEmpty else { return [TimedToken(text: trimmed, start: start, end: safeEnd)] }
        let weights = pieces.map { Double(max(1, $0.count)) }
        let total = max(1, weights.reduce(0, +))
        let span = safeEnd - start
        var cursor = start
        var result: [TimedToken] = []
        result.reserveCapacity(pieces.count)
        for (i, piece) in pieces.enumerated() {
            let pieceEnd = (i == pieces.count - 1) ? safeEnd : min(safeEnd, cursor + span * weights[i] / total)
            result.append(TimedToken(text: piece, start: cursor, end: pieceEnd))
            cursor = pieceEnd
        }
        return result
    }
}
