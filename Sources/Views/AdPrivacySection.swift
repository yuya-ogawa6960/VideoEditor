import SwiftUI

/// プライバシー: 使い方の統計のオン・オフと、広告の同意の見直し(必要な地域だけ)
struct AdPrivacySection: View {
    @State private var ads = AdsManager.shared
    @AppStorage(Analytics.enabledKey) private var analyticsEnabled = true

    var body: some View {
        Section {
            Toggle("使い方の統計を送信(匿名)", isOn: $analyticsEnabled)
            if ads.privacyOptionsRequired {
                Button("広告の同意を変更") {
                    Task { await AdsManager.shared.presentPrivacyOptions() }
                }
            }
        } header: {
            Text("プライバシー")
        } footer: {
            Text("どの機能がどれだけ使われているかを、端末ごとのランダムな ID で送り、改善に役立てます。動画・文章・名前は送りません。")
        }
    }
}
