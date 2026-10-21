import SwiftUI
import AuthenticationServices

/// 「文字起こしの方式」画面の、アカウントとポイントの欄
struct AccountPointsSection: View {
    @State private var account = AccountService.shared
    @State private var ads = AdsManager.shared
    @State private var isWatchingAd = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

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
                    } else if account.isRefreshing || account.lastError == nil {
                        ProgressView()
                    } else {
                        // 取得に失敗した(通信できない・サーバーが止まっている)ときは、回り続けずにやり直せるように
                        Button("再読み込み") {
                            Task { await account.refresh() }
                        }
                    }
                }
                Button {
                    Task { await account.claimDaily() }
                } label: {
                    Label(account.dailyAvailable ? String(localized: "今日のボーナスを受け取る(+20)") : String(localized: "今日のボーナスは受け取り済み"),
                          systemImage: "gift")
                }
                .disabled(!account.dailyAvailable)

                // 広告を見てポイント(リワード広告)
                if account.adRewardLimit > 0, AdsManager.hasRewarded {
                    Button {
                        watchAd()
                    } label: {
                        Label(account.adRewardsRemaining > 0
                              ? String(localized: "広告を見て +\(account.adRewardPoints) ポイント(今日あと \(account.adRewardsRemaining) 回)")
                              : String(localized: "今日の広告のポイントは受け取り済み"),
                              systemImage: "play.rectangle")
                    }
                    .disabled(account.adRewardsRemaining == 0 || !ads.isRewardedReady || isWatchingAd)
                    if AdsManager.usesTestAds {
                        Text("テスト配信中のため、テスト用の広告が出ます。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("クラウド AI", selection: Binding(get: { account.source }, set: { account.source = $0 })) {
                    ForEach(CloudAISource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Button("サインアウト", role: .destructive) {
                    account.signOut()
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("アカウントを削除")
                    }
                }
                .disabled(isDeleting)
                .confirmationDialog("アカウントを削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("削除する", role: .destructive) {
                        isDeleting = true
                        Task { @MainActor in
                            _ = await account.deleteAccount()
                            isDeleting = false
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("ポイントと利用の記録がサーバーから削除され、元に戻せません。プロジェクトや動画はこの iPhone に残ります。")
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

    private func watchAd() {
        isWatchingAd = true
        Task { @MainActor in
            let earned = await AdsManager.shared.showRewarded(userIdentifier: account.userID)
            if earned {
                await account.claimAdReward()
            }
            isWatchingAd = false
        }
    }
}
