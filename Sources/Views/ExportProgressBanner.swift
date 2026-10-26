import SwiftUI
import Observation

/// 書き出し中に表示される小さなバナー(メイン画面上部に配置)。
/// 終わった直後は結果(写真に保存した・終わった・書き出せなかった)を数秒だけ残し、前面で終わっても気づけるようにする。
/// 本体をタップすると onOpen(書き出し画面を開くなど)。■ は確認してから止める
struct ExportProgressBanner: View {
    /// 本体をタップしたとき(書き出し画面を開くなど)。nil なら本体は押せない
    var onOpen: (() -> Void)? = nil

    /// ■ を押したあとの確認(すぐには止めない)
    @State private var confirmStop = false
    /// 終わった直後に数秒だけ出す結果(nil なら出さない)
    @State private var result: ExportManager.State?

    var body: some View {
        let exporter = ExportManager.shared
        let running = exporter.isRunning
        let progress = min(max(exporter.progress, 0), 1)
        // 書き出していないときも呼んで、次の書き出しで計測し直せるようにする
        let remaining = ExportTimeEstimator.shared.remainingText(isRunning: running, progress: progress)
        ZStack {
            // 何も出していないときも部品を置いておく(中身が空だと .onChange・.task が付かない)
            Color.clear.frame(width: 0, height: 0)
            if running {
                runningBanner(progress: progress, remaining: remaining)
            } else if let result {
                resultBanner(result, savedToPhotos: exporter.savedToPhotos)
            }
        }
        .onChange(of: running) { wasRunning, isRunning in
            if isRunning {
                result = nil
            } else if wasRunning {
                // 終わった直後は結果を数秒だけ残す(自分で止めたときは出さない)
                switch exporter.state {
                case .finished, .failed: result = exporter.state
                default: result = nil
                }
            }
        }
        .task(id: result) {
            guard result != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { result = nil }
        }
        .confirmationDialog("書き出しを止めますか?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("止める", role: .destructive) {
                exporter.cancel()
            }
            Button("続ける", role: .cancel) {}
        }
    }

    /// 書き出し中(進み具合 + 止めるボタン)
    private func runningBanner(progress: Double, remaining: String?) -> some View {
        HStack(spacing: 10) {
            openable {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(verbatim: "書き出し中 \(Int((progress * 100).rounded()))%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                            if let remaining {
                                Text(remaining)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 150)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            Button {
                confirmStop = true
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("書き出しを止める")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 6, y: 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 終わった直後の結果(本当の結果にもとづく。写真に保存できなかったときは「保存しました」と言わない)
    private func resultBanner(_ state: ExportManager.State, savedToPhotos: Bool) -> some View {
        let failed: Bool
        if case .failed = state {
            failed = true
        } else {
            failed = false
        }
        let text: String
        if failed {
            text = String(localized: "書き出せませんでした")
        } else if savedToPhotos {
            text = String(localized: "写真に保存しました")
        } else {
            text = String(localized: "書き出しが終わりました")
        }
        return openable {
            HStack(spacing: 8) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(failed ? Color.orange : Color.green)
                Text(text)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 6, y: 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 本体。onOpen があれば押せるボタンにする
    @ViewBuilder
    private func openable<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let onOpen {
            Button(action: onOpen) {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

// MARK: - 残り時間の見積もり

/// 書き出しの残り時間を、開始(最初に見た)時刻と進み具合から見積もる。
/// ExportManager には手を入れず、書き出し画面とバナーの両方から同じ計測を使う。
@MainActor
final class ExportTimeEstimator {
    static let shared = ExportTimeEstimator()

    private var startDate: Date?
    private var startProgress: Double = 0
    private var lastProgress: Double = 0

    private init() {}

    /// 「残り 約3分」などの文言。書き出し中でなければ nil
    func remainingText(isRunning: Bool, progress: Double, now: Date = Date()) -> String? {
        guard isRunning else {
            startDate = nil
            lastProgress = 0
            return nil
        }
        let p: Double = min(max(progress, 0), 1)
        // 初回、または進捗が大きく戻った(縦横同時の 2 本目など)ら計測し直す
        let dropped: Bool = p + 0.05 < lastProgress
        if startDate == nil || dropped {
            startDate = now
            startProgress = p
        }
        lastProgress = p
        guard let start = startDate else { return nil }
        let elapsed: Double = now.timeIntervalSince(start)
        let done: Double = p - startProgress
        guard elapsed >= 3, done >= 0.02 else { return String(localized: "残り時間を計算中") }
        let rate: Double = done / elapsed
        guard rate > 0 else { return String(localized: "残り時間を計算中") }
        let left: Double = (1 - p) / rate
        return Self.format(left)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return String(localized: "残り時間を計算中") }
        if seconds < 10 {
            return String(localized: "まもなく完了")
        }
        if seconds < 60 {
            let tens: Int = Int((seconds / 10).rounded(.up)) * 10
            return String(localized: "残り 約\(tens)秒")
        }
        let minutes: Int = Int((seconds / 60).rounded())
        if minutes < 60 {
            return String(localized: "残り 約\(minutes)分")
        }
        let hours: Int = minutes / 60
        let rest: Int = minutes % 60
        if rest == 0 {
            return String(localized: "残り 約\(hours)時間")
        }
        return String(localized: "残り 約\(hours)時間\(rest)分")
    }
}

// MARK: - 画面ロック・ホームに戻ったときの案内(OS ごと)

/// 長い処理の最中に出す「ロック・ホームに戻っても大丈夫か」の案内。
/// iOS 26 以降はロック中も続けられる(継続処理)。それより前は約 30 秒で止まる。
enum BackgroundWorkNote {
    static var canContinueInBackground: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    static var export: String {
        if canContinueInBackground {
            return String(localized: "ホームに戻ったり画面をロックしても、\n書き出しは続きます。")
        }
        return String(localized: "書き出しが終わるまで、\nこのアプリを開いたままにしてください。\nホームに戻ると約30秒で止まります。\n画面は自動でロックされません。")
    }

    static var transcription: String {
        if canContinueInBackground {
            return String(localized: "ホームに戻ったり画面をロックしても、\n文字起こしは続きます。")
        }
        return String(localized: "終わるまで、この画面を\n開いたままにしてください。\nホームに戻ると約30秒で一時停止します。\n画面は自動でロックされません。")
    }

    /// 見どころ探し・おまかせ編集などの解析(EditorAnalysisRunner)
    static var analysis: String {
        if canContinueInBackground {
            return String(localized: "ホームに戻ったり画面をロックしても、\nこの処理は続きます。")
        }
        return String(localized: "終わるまで、このアプリを\n開いたままにしてください。\nホームに戻ると約30秒で止まります。\n画面は自動でロックされません。")
    }
}
