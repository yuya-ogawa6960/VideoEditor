import SwiftUI

/// 「設定」のプライバシーと広告: 使い方の統計のオン・オフと、広告の同意の見直し(必要な地域だけ)
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
            Text("プライバシーと広告")
        } footer: {
            Text("使った機能を端末ごとのランダムな ID で送ります。動画・文章・名前は送りません。")
        }
    }
}
