import SwiftUI

// =====================================================================
// 「設定」(プロジェクト一覧の右上の歯車から開く)
//
// - アカウントとポイント(AccountPointsView)
// - 文字起こしとAI仕上げ(TranscriptionSettingsView)、用語の登録、読み方の登録
// - プライバシーと広告(使い方の統計・広告の同意の見直し。AdPrivacySection)
// - サポート用の情報(ロック中の継続・バックグラウンド送信・広告の状態)。デバッグ・TestFlight のビルドだけ
// プロジェクトを開かなくても、広告の同意や統計の送信を変えられるようにここに置く。
// =====================================================================

struct AppSettingsView: View {
    // 用語・読み方の登録の件数
    @State private var termCount: Int = 0
    @State private var readingCount: Int = 0

    // サポート用の情報(ロック中の継続・バックグラウンド送信・広告)
    @State private var diagnosticBundleID: String = ""
    @State private var diagnosticContinued: String = ""
    @State private var diagnosticUploads: String = ""
    @State private var diagnosticAds: String = ""
    @State private var showsDiagnostics: Bool = false

    init() {}

    var body: some View {
        Form {
            // ポイントのサーバーが無いビルド(準備中)では出さない
            if AccountService.shared.isAvailable {
                AccountPointsSection()
            }
            Section {
                NavigationLink {
                    TranscriptionSettingsView()
                } label: {
                    Text("文字起こしとAI仕上げ")
                }
                NavigationLink {
                    CaptionTermListView()
                } label: {
                    LabeledContent("用語の登録") {
                        Text(verbatim: "\(termCount)")
                            .monospacedDigit()
                    }
                }
                NavigationLink {
                    ReadingListView()
                } label: {
                    LabeledContent("読み方の登録") {
                        Text(verbatim: "\(readingCount)")
                            .monospacedDigit()
                    }
                }
            }
            AdPrivacySection()
            // 開発・テスト用の情報なので、製品版では出さない
            if Self.showsDiagnosticsSection {
                diagnosticsSection
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            termCount = CaptionTermDictionary.load().count
            readingCount = ReadingDictionary.load().count
            if Self.showsDiagnosticsSection {
                refreshDiagnostics()
            }
        }
    }

    // MARK: - サポート用の情報

    /// デバッグビルドか TestFlight(テスト広告を出すビルドと同じ判定)
    private static var showsDiagnosticsSection: Bool { AdsManager.usesTestAds }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("サポート用の情報", isExpanded: $showsDiagnostics) {
                diagnosticRow(title: String(localized: "実行時のバンドル ID"), value: diagnosticBundleID, monospaced: true)
                // TestFlight で広告のポイントを受け取るには、この ID をサーバーの TEST_AD_USERS に入れる
                diagnosticRow(title: String(localized: "アカウント ID"), value: AccountService.shared.userID ?? "", monospaced: true)
                diagnosticRow(title: String(localized: "ロック中の継続"), value: diagnosticContinued, monospaced: false)
                diagnosticRow(title: String(localized: "バックグラウンド送信(クラウドAI)"), value: diagnosticUploads, monospaced: false)
                diagnosticRow(title: String(localized: "広告の状態"), value: diagnosticAds, monospaced: true)
                Button {
                    refreshDiagnostics()
                } label: {
                    Label("情報を更新", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func diagnosticRow(title: String, value: String, monospaced: Bool) -> some View {
        let valueFont: Font = monospaced ? Font.system(.footnote, design: .monospaced) : Font.footnote
        let valueText: String = value.isEmpty ? "—" : value
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
            Text(valueText)
                .font(valueFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func refreshDiagnostics() {
        diagnosticBundleID = ContinuedProcessing.runtimeBundleIdentifier
        diagnosticContinued = ContinuedProcessing.lastDiagnostic
        diagnosticUploads = CloudBackgroundUploader.shared.diagnosticSummary()
        diagnosticAds = AdsManager.shared.diagnosticSummary()
    }
}
