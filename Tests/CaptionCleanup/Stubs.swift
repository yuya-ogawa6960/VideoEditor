import Foundation

// =====================================================================
// アプリの型のうち、CaptionCleanup / CaptionIssueCheck が使う最小限の代わり。
// 本物は Sources/Model/Models.swift・Phase3Models.swift・Engine/SubtitleSegmenter.swift にあり、SwiftUI などに依存するので
// Linux の swiftc ではそのまま使えない。ここでは同じ名前・同じ形だけをそろえる(run.sh がこのファイルと本物の
// CaptionCleanup.swift・CaptionIssues.swift をいっしょにコンパイルする)
// =====================================================================

struct SubtitleWord: Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct SubtitleCue: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var translatedText: String? = nil
    var words: [SubtitleWord] = []
    var bilingual: Bool = false
    var doubtfulWords: [String] = []
    var issueDismissed: Bool = false

    var duration: Double { max(0, end - start) }
}

struct TimedToken: Equatable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double?

    init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = max(start, end)
        self.confidence = confidence
    }
}

enum SubtitleSegmenter {
    /// CaptionIssueCheck.minorWords が参照する(内容はここでは使わない)
    static let japaneseBreakParticles: Set<String> = ["が", "を", "に", "は", "の"]

    /// 本物(Sources/Engine/SubtitleSegmenter.swift)と同じ計算
    static func clampWords(_ words: [SubtitleWord], start: Double, end: Double) -> [SubtitleWord] {
        guard !words.isEmpty else { return words }
        let hi = max(start, end)
        return words.map { word in
            let s = min(max(word.start, start), hi)
            let e = min(max(word.end, s), hi)
            return SubtitleWord(text: word.text, start: s, end: e)
        }
    }
}
