import SwiftUI
import AuthenticationServices

/// 「設定」と「文字起こしとAI仕上げ」の画面の、アカウントとポイントの欄(1 行。押すと「アカウントとポイント」の画面へ)
struct AccountPointsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                AccountPointsView()
            } label: {
                HStack {
                    Text("アカウントとポイント")
                    Spacer()
                    AccountPointsSummaryLabel()
                        .loadingPointsIfNeeded()
                        .labelStyle(.titleOnly)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
