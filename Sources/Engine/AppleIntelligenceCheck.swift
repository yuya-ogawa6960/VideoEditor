import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// =====================================================================
// Apple Intelligence(端末内の AI)が使えるか、使えないならその理由。
// 対応している iPhone でも、オフになっているときや、iPhone の言語と Siri の言語が違うときは使えない
// (iOS はどちらも「オンになっていない」と返す)。そうなったら、アプリを使っている間に一度だけ言語の注意を知らせる
// (RootView のお知らせ)。使えるようになったら記録を消し、また使えなくなったらもう一度知らせる。
// =====================================================================

enum AppleIntelligenceCheck {
    enum State: Equatable {
        case available
        /// この端末は対応していない
        case deviceNotEligible
        /// 対応しているが、オフ・言語の設定で使えない
        case notEnabled
        /// 対応していて、モデルを準備中
        case modelNotReady
        /// iOS 26 より前、またはそれ以外の理由
        case unavailable
    }

    static var state: State {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            if case .available = availability { return .available }
            if case .unavailable(let reason) = availability {
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unavailable
                }
            }
            return .unavailable
        }
        #endif
        return .unavailable
    }

    // MARK: - 言語の注意のお知らせ

    /// 「今後表示しない」を選んだ
    private static let suppressedKey = "appleIntelligence.languageNotice.suppressed"
    /// 今回使えなくなってから、もう知らせた(使えるようになったら消す)
    private static let shownKey = "appleIntelligence.languageNotice.shown"

    /// 言語の注意を知らせるか。対応している端末で「オンになっていない」と返され、まだ知らせていないときだけ。
    /// 使えるときは記録を消す(また使えなくなったら知らせる)
    static func shouldShowLanguageNotice() -> Bool {
        let defaults = UserDefaults.standard
        let current = state
        if current == .available {
            defaults.removeObject(forKey: shownKey)
            return false
        }
        guard current == .notEnabled else { return false }
        return !defaults.bool(forKey: suppressedKey) && !defaults.bool(forKey: shownKey)
    }

    /// 知らせた(今回使えない間は、もう出さない)
    static func markLanguageNoticeShown() {
        UserDefaults.standard.set(true, forKey: shownKey)
    }

    /// 今後表示しない
    static func suppressLanguageNotice() {
        UserDefaults.standard.set(true, forKey: suppressedKey)
        UserDefaults.standard.set(true, forKey: shownKey)
    }
}
