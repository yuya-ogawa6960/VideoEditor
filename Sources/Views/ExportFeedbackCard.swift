import SwiftUI

// =====================================================================
// 書き出しが終わったときの、ひとことの感想(使い勝手の計測)。
// 「使いやすかった / 迷った」を 1 タップで聞き、迷ったときだけ理由を選んでもらう(任意)。
// しつこくならないよう、1 回目と 3 回に 1 回、前に答えてから 7 日以上あいたときだけ出す。
// 送るのは評価と理由の種類だけ(使い方の統計と同じく匿名・設定で止められる)。
// =====================================================================

enum ExportFeedback {
    private static let countKey = "feedback.exportCount"
    private static let askedAtCountKey = "feedback.askedAtCount"
    private static let answeredAtKey = "feedback.answeredAt"
    private static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// 書き出しが終わった(ExportManager から)
    static func noteExportFinished() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
    }

    /// 今回の書き出しで聞くか(聞くと決めたら、同じ回ではもう聞かない)
    static func shouldAsk() -> Bool {
        let defaults = UserDefaults.standard
        guard Analytics.shared.isEnabled else { return false }
        let count = defaults.integer(forKey: countKey)
        guard count >= 1, count == 1 || count % 3 == 1 else { return false }
        guard defaults.integer(forKey: askedAtCountKey) != count else { return false }
        let answeredAt = defaults.double(forKey: answeredAtKey)
        if answeredAt > 0, Date().timeIntervalSince1970 - answeredAt < interval { return false }
        defaults.set(count, forKey: askedAtCountKey)
        return true
    }

    static func send(rating: String, reason: String? = nil) {
        var params = ["rating": rating]
        if let reason { params["reason"] = reason }
        Analytics.shared.track("feedback", params)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: answeredAtKey)
    }
}

struct ExportFeedbackCard: View {
    private enum Step {
        case hidden, asking, reasons, thanks, closed
    }

    @State private var step: Step
    /// 聞いていたときの高さ。答えたあと・× のあとも同じ高さを少し保ってからたたむ(下の広告がボタンの位置に上がってこないように)
    @State private var keptHeight: CGFloat = 0

    init() {
        // 何も描かない View では onAppear が呼ばれないので、ここで決める(同じ回は 2 度目以降 false)
        _step = State(initialValue: ExportFeedback.shouldAsk() ? .asking : .hidden)
    }

    private let reasons: [FeedbackReason] = [
        FeedbackReason(key: "captions", title: String(localized: "字幕")),
        FeedbackReason(key: "editing", title: String(localized: "編集")),
        FeedbackReason(key: "export", title: String(localized: "書き出し")),
        FeedbackReason(key: "slow", title: String(localized: "動作が重い")),
        FeedbackReason(key: "other", title: String(localized: "その他")),
    ]

    var body: some View {
        Group {
            switch step {
            case .hidden:
                EmptyView()
            case .asking:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("使い心地はどうでしたか?")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            withAnimation { step = .closed }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("閉じる")
                    }
                    HStack(spacing: 10) {
                        Button {
                            ExportFeedback.send(rating: "good")
                            withAnimation { step = .thanks }
                        } label: {
                            Label("使いやすかった", systemImage: "hand.thumbsup")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            withAnimation { step = .reasons }
                        } label: {
                            Label("迷った", systemImage: "hand.thumbsdown")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keptHeight = max(keptHeight, $0) }
            case .reasons:
                VStack(alignment: .leading, spacing: 10) {
                    Text("どこで迷いましたか?")
                        .font(.subheadline.weight(.semibold))
                    FlowChips(reasons: reasons) { key in
                        ExportFeedback.send(rating: "bad", reason: key)
                        withAnimation { step = .thanks }
                    }
                    Button("答えずに送る") {
                        ExportFeedback.send(rating: "bad")
                        withAnimation { step = .thanks }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keptHeight = max(keptHeight, $0) }
            case .thanks:
                // 聞いていたときと同じ高さのまま出す(下の広告が、押したボタンの位置に上がってこないように)
                Label("ありがとうございました", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, minHeight: keptHeight, alignment: .topLeading)
            case .closed:
                // × のあとも同じ高さを少し保つ
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: keptHeight)
            }
        }
        .task(id: step) {
            // 答えたあと・× のあとは 2 秒おいてからたたむ
            guard step == .thanks || step == .closed else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { step = .hidden }
        }
    }
}

/// 迷った理由(key は統計に送る種類。title は画面の文字)
private struct FeedbackReason: Identifiable {
    let key: String
    let title: String
    var id: String { key }
}

/// 理由の選択肢(入りきらなければ 2 行に分けて並べる)
private struct FlowChips: View {
    let reasons: [FeedbackReason]
    let onPick: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { chips(in: 0..<3) }
                HStack(spacing: 8) { chips(in: 3..<reasons.count) }
            }
        }
    }

    private var chips: some View {
        chips(in: 0..<reasons.count)
    }

    private func chips(in range: Range<Int>) -> some View {
        ForEach(Array(reasons[range])) { reason in
            Button {
                onPick(reason.key)
            } label: {
                // .bordered の余白と合わせて、押せる高さを 44 にする
                Text(reason.title)
                    .frame(minHeight: 30)
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
        }
    }
}
