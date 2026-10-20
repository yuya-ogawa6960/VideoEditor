import SwiftUI
import AuthenticationServices

/// 「文字起こしの方式」画面の、アカウントとポイントの欄
struct AccountPointsSection: View {
    @State private var account = AccountService.shared

    var body: some View {
        Section {
            if !account.isAvailable {
                Text("ポイントで AI を使う機能は準備中です。今は自分の OpenAI キーで使えます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if account.isSignedIn {
                HStack {
                    Label("ポイント", systemImage: "star.circle.fill")
                    Spacer()
                    if let points = account.points {
                        Text("\(points)")
                            .font(.title3.monospacedDigit().weight(.bold))
                    } else {
                        ProgressView()
                    }
                }
                Button {
                    Task { await account.claimDaily() }
                } label: {
                    Label(account.dailyAvailable ? "今日のボーナスを受け取る(+20)" : "今日のボーナスは受け取り済み",
                          systemImage: "gift")
                }
                .disabled(!account.dailyAvailable)

                Picker("クラウド AI", selection: Binding(get: { account.source }, set: { account.source = $0 })) {
                    ForEach(CloudAISource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Button("サインアウト", role: .destructive) {
                    account.signOut()
                }
            } else {
                Text("サインインすると、自分の OpenAI キーがなくてもポイントでクラウド AI(高精度の文字起こし・字幕の整え・翻訳・台本)を使えます。はじめてのサインインで 100 ポイント、毎日 20 ポイントもらえます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = []
                } onCompletion: { result in
                    Task { await account.handleAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .disabled(account.isWorking)
            }
            if let message = account.lastError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("アカウントとポイント")
        } footer: {
            if account.isSignedIn {
                Text("使うポイント: クラウドの文字起こし 1 分 = 5、字幕の整え・翻訳・台本 1 回 = 2。端末内の AI(Whisper・Apple Intelligence・中だるみチェックなど)はポイントなしで使えます。")
            }
        }
        .task {
            await account.refresh()
        }
    }
}
