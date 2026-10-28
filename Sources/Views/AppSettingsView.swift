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
    /// バージョンの行を 5 回タップすると、サポート用の情報を出す(製品版では隠しておく)
    @State private var versionTaps: Int = 0
    @State private var revealsDiagnostics: Bool = false
    /// iPhone Duo を開いたとき、編集画面のツールを右の列(時刻などが出る列)に縦に並べる(編集画面の「設定」からも切り替えられる)
    @AppStorage("editor.toolbarOnSide") private var toolbarOnSide = false

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
            Section {
                Toggle("Duo を開いたときはツールを右に", isOn: $toolbarOnSide)
            }
            AdPrivacySection()
            Section {
                Button {
                    versionTaps += 1
                    if versionTaps >= 5 {
                        revealsDiagnostics = true
                        refreshDiagnostics()
                    }
                } label: {
                    LabeledContent("バージョン") {
                        Text(verbatim: Self.versionText)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            // 開発・テスト用の情報。審査員にも見えないよう、バージョンを 5 回タップしたときだけ出す
            if showsDiagnosticsSection {
                diagnosticsSection
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            termCount = CaptionTermDictionary.load().count
            readingCount = ReadingDictionary.load().count
        }
    }

    // MARK: - サポート用の情報

    private static var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var showsDiagnosticsSection: Bool { revealsDiagnostics }

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
