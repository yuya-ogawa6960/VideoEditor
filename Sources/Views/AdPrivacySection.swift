import SwiftUI

/// 「設定」のプライバシーと広告: 使い方の統計のオン・オフと、広告の同意の見直し(必要な地域だけ)
struct AdPrivacySection: View {
    @State private var ads = AdsManager.shared
    @AppStorage(Analytics.enabledKey) private var analyticsEnabled = false

    var body: some View {
        Section {
            Toggle("使い方の統計を送信(匿名)", isOn: $analyticsEnabled)
            if ads.privacyOptionsRequired {
                Button("広告の同意を変更") {
                    Task { await AdsManager.shared.presentPrivacyOptions() }
                }
            }
            Link(destination: CloudAIGateway.privacyPolicyURL) {
                Label("プライバシーポリシー", systemImage: "hand.raised")
            }
            Link(destination: CloudAIGateway.supportURL) {
                Label("サポート", systemImage: "questionmark.circle")
            }
        } header: {
            Text("プライバシーと広告")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("使った機能・動作の重さ・異常終了の情報を、機種・OS・言語とともに、端末ごとのランダムな ID で送ります。動画・文章・名前は送りません。")
                // 送った統計の削除を頼むときに使う(問い合わせフォームに書いてもらう)
                Text("端末 ID(削除の依頼に使います): \(Analytics.shared.installID)")
                    .textSelection(.enabled)
            }
        }
    }
}
