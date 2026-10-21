import Foundation

// =====================================================================
// SRT / WebVTT 字幕ファイルの読み書き。
// 出力タイムライン上の秒(SubtitleCue.start / end)と相互変換する。
// =====================================================================

enum SRTCodecError: LocalizedError {
    case empty
    case noCuesFound
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "ファイルが空です。")
        case .noCuesFound:
            return String(localized: "字幕が見つかりませんでした。SRT 形式(番号・時間・テキスト)のファイルを選んでください。")
        case .invalidEncoding:
            return String(localized: "ファイルの文字コードを読み取れませんでした。UTF-8 で保存されたファイルを選んでください。")
        }
    }
}

enum SRTCodec {

    // MARK: - 書き出し

    /// SRT 形式の文字列を作る。
    /// - useTranslation: 原文の代わりに英訳(translatedText)を使う(無ければ原文)
    /// - bilingual: 原文の行 + 英訳の行(useTranslation より優先)
    static func encode(_ cues: [SubtitleCue], useTranslation: Bool = false, bilingual: Bool = false) -> String {
        var output = ""
        var index = 1
        for cue in sortedValidCues(cues) {
            let lines = textLines(for: cue, useTranslation: useTranslation, bilingual: bilingual)
            if lines.isEmpty { continue }
            output += "\(index)\n"
            output += "\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
            output += lines.joined(separator: "\n")
            output += "\n\n"
            index += 1
        }
        return output
    }

    /// WebVTT 形式の文字列を作る
    static func encodeWebVTT(_ cues: [SubtitleCue], useTranslation: Bool) -> String {
        var output = "WEBVTT\n\n"
        var index = 1
        for cue in sortedValidCues(cues) {
            let lines = textLines(for: cue, useTranslation: useTranslation, bilingual: false)
            if lines.isEmpty { continue }
            output += "\(index)\n"
            output += "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n"
            output += lines.joined(separator: "\n")
            output += "\n\n"
            index += 1
        }
        return output
    }

    /// 一時ディレクトリに UTF-8(BOM なし)で書き出し、その URL を返す
    static func writeTemporaryFile(_ text: String, fileName: String) throws -> URL {
        let safeName = fileName.isEmpty ? "subtitles.srt" : fileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 読み込み

    /// SRT / WebVTT の文字列を解析する。
    /// CRLF/LF、BOM、ミリ秒の "." と ","、番号の欠落、HTML タグに寛容。
    static func decode(_ text: String) throws -> [SubtitleCue] {
        var normalized = text
        if normalized.hasPrefix("\u{FEFF}") {
            normalized.removeFirst()
        }
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SRTCodecError.empty
        }

        let lines = normalized.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard let timing = parseTimingLine(line) else {
                // 番号行・空行・"WEBVTT" ヘッダなどは読み飛ばす
                i += 1
                continue
            }
            let start = timing.start
            let end = timing.end
            // 時間行の次からテキスト行(空行まで)
            var textLines: [String] = []
            var j = i + 1
            while j < lines.count {
                let raw = lines[j]
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { break }
                // 次のキューの時間行に直接続いている場合はそこで区切る
                if parseTimingLine(raw.trimmingCharacters(in: .whitespaces)) != nil { break }
                let cleaned = stripTags(raw).trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { textLines.append(cleaned) }
                j += 1
            }
            let joined = textLines.joined(separator: "\n")
            if !joined.isEmpty && end > start {
                cues.append(SubtitleCue(start: start, end: end, text: joined))
            }
            i = j
        }

        guard !cues.isEmpty else {
            throw SRTCodecError.noCuesFound
        }
        cues.sort { $0.start < $1.start }
        return cues
    }

    /// Data から文字コードを推定して decode する(UTF-8 → UTF-16 → Shift_JIS の順に試す)
    static func decode(data: Data) throws -> [SubtitleCue] {
        if let s = String(data: data, encoding: .utf8) {
            return try decode(s)
        }
        if let s = String(data: data, encoding: .utf16) {
            return try decode(s)
        }
        if let s = String(data: data, encoding: .shiftJIS) {
            return try decode(s)
        }
        throw SRTCodecError.invalidEncoding
    }

    // MARK: - 内部ヘルパー

    private static func sortedValidCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues
            .filter { $0.end > $0.start && $0.start.isFinite && $0.end.isFinite }
            .sorted { $0.start < $1.start }
    }

    private static func textLines(for cue: SubtitleCue, useTranslation: Bool, bilingual: Bool) -> [String] {
        let original = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = (cue.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if bilingual {
            return [original, translated].filter { !$0.isEmpty }
        }
        if useTranslation {
            if !translated.isEmpty { return [translated] }
            return original.isEmpty ? [] : [original]
        }
        return original.isEmpty ? [] : [original]
    }

    /// 秒 → "HH:MM:SS,mmm"(separator = "," or ".")
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let totalMillis = Int((safe * 1000).rounded())
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis % 3_600_000) / 60_000
        let secs = (totalMillis % 60_000) / 1000
        let millis = totalMillis % 1000
        let hms = String(format: "%02d:%02d:%02d", hours, minutes, secs)
        let ms = String(format: "%03d", millis)
        return hms + separator + ms
    }

    /// "HH:MM:SS,mmm --> HH:MM:SS,mmm" を解析(WebVTT の位置指定などが後ろに付いていても可)
    private static func parseTimingLine(_ line: String) -> (start: Double, end: Double)? {
        guard line.contains("-->") else { return nil }
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        // 終了時刻の後ろに "position:..." などが付く場合は最初のトークンだけ使う
        let endRaw = parts[1].trimmingCharacters(in: .whitespaces)
        let endText = endRaw.components(separatedBy: .whitespaces).first ?? endRaw
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }
        return (start: start, end: end)
    }

    /// "HH:MM:SS,mmm" / "MM:SS.mmm" / "SS.mmm" などを秒に変換
    private static func parseTimestamp(_ text: String) -> Double? {
        let unified = text.replacingOccurrences(of: ",", with: ".")
        let pieces = unified.components(separatedBy: ":")
        guard !pieces.isEmpty, pieces.count <= 3 else { return nil }
        var values: [Double] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let v = Double(trimmed), v.isFinite, v >= 0 else { return nil }
            values.append(v)
        }
        switch values.count {
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        case 2: return values[0] * 60 + values[1]
        case 1: return values[0]
        default: return nil
        }
    }

    /// <b>, <i>, <font ...>, {\an8} などのタグを取り除く
    private static func stripTags(_ text: String) -> String {
        var result = ""
        var insideAngle = false
        var insideBrace = false
        for ch in text {
            if insideAngle {
                if ch == ">" { insideAngle = false }
                continue
            }
            if insideBrace {
                if ch == "}" { insideBrace = false }
                continue
            }
            if ch == "<" {
                insideAngle = true
                continue
            }
            if ch == "{" {
                insideBrace = true
                continue
            }
            result.append(ch)
        }
        // 閉じられなかったタグは元のテキストを尊重する
        if insideAngle || insideBrace, result.isEmpty { return text }
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
