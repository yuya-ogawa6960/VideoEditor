import SwiftUI

/// 広告の同意を見直す(ヨーロッパ・イギリスなど、必要な地域だけ表示)
struct AdPrivacySection: View {
    @State private var ads = AdsManager.shared

    var body: some View {
        if ads.privacyOptionsRequired {
            Section {
                Button("広告の同意を変更") {
                    Task { await AdsManager.shared.presentPrivacyOptions() }
                }
            }
        }
    }
}
