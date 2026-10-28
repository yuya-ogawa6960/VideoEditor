import SwiftUI
import AuthenticationServices

// =====================================================================
// 「アカウントとポイント」の画面。
// サインイン前: 何ができるかを 1 行で伝えて Apple でサインイン。
// サインイン後: 残りのポイントを大きく出し、増やす方法(毎日のボーナス・広告)、使うポイント、
// AI の使い方(ポイント / 自分のキー)、サインアウト・削除を、上から使う順に並べる。
// プロジェクト一覧の左上と「設定」、「文字起こしとAI仕上げ」の画面から開く。シートで出すときは AccountPointsSheet。
// =====================================================================

struct AccountPointsView: View {
    @State private var account = AccountService.shared
    @State private var ads = AdsManager.shared
    @State private var isWatchingAd = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    /// 削除が終わった(サインイン前の画面に戻るだけでは、消えたのかわからないので知らせる)
    @State private var showDeleted = false

    var body: some View {
        Form {
            if !account.isAvailable {
                Section {
                    Text("ポイントで AI を使う機能は準備中です。今は自分の OpenAI キーで使えます。")
                        .foregroundStyle(.secondary)
                }
            } else if account.isSignedIn {
                balanceSection
                earnSection
                pricesSection
                sourceSection
                accountSection
            } else {
                signInSection
            }
            if let message = account.lastError {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("アカウントとポイント")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await account.refresh() }
        .task { await account.refresh() }
        .alert("アカウントを削除しました", isPresented: $showDeleted) {
            Button("OK") {}
        } message: {
            Text("ポイントと記録はサーバーから消えました。")
        }
    }

    // MARK: サインイン前

    private var signInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(BrandStyle.coral)
                Text("ポイントでクラウド AI を使う")
                    .font(.title3.weight(.bold))
                Text("文字起こし・AI 仕上げ・読み上げを、自分の API キーなしで使えます。はじめてのサインインで \(AccountPrices.signup)pt もらえます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                Task { await account.handleAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .disabled(account.isWorking)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("名前やメールアドレスは受け取りません。クラウド AI を使うとき、音声と文章は OpenAI(Google の声は Google)に送られます。")
                Link("プライバシーポリシー", destination: CloudAIGateway.privacyPolicyURL)
            }
        }
    }

    // MARK: サインイン後

    /// 残りのポイント(大きく)
    private var balanceSection: some View {
        Section {
            VStack(spacing: 4) {
                if let points = account.points {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(points.formatted())
                            .font(.system(size: 48, weight: .bold).monospacedDigit())
                        Text(verbatim: "pt")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else if account.isRefreshing || account.lastError == nil {
                    ProgressView()
                        .frame(height: 70)
                } else {
                    Button("再読み込み") {
                        Task { await account.refresh() }
                    }
                    .frame(height: 70)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    /// ポイントを増やす(毎日のボーナス・広告)
    private var earnSection: some View {
        Section {
            Button {
                claimDaily()
            } label: {
                HStack {
                    Label("今日のボーナス", systemImage: "gift")
                    Spacer()
                    if account.isClaimingDaily {
                        ProgressView()
                    } else if account.dailyAvailable {
                        Text(verbatim: "+\(account.dailyPoints)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(BrandStyle.coral)
                    } else {
                        Label("受け取り済み", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!account.dailyAvailable || account.isClaimingDaily)

            if account.adRewardLimit > 0, AdsManager.hasRewarded {
                Button {
                    watchAd()
                } label: {
                    HStack {
                        Label("広告を見る", systemImage: "play.rectangle")
                        Spacer()
                        if isWatchingAd || account.isClaimingAd {
                            ProgressView()
                        } else if account.adRewardsRemaining == 0 {
                            Label("今日は終わり", systemImage: "checkmark")
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if !ads.isRewardedReady {
                            // 広告をまだ読み込めていない(押せない理由がわかるように)
                            Text("準備中")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("+\(account.adRewardPoints)・あと \(account.adRewardsRemaining) 回")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(account.adRewardsRemaining == 0 || !ads.isRewardedReady || isWatchingAd || account.isClaimingAd)
            }
        } header: {
            Text("ポイントを増やす")
        } footer: {
            Text("ポイントは無料です。購入はできません。")
        }
    }

    /// 使うポイント(サーバーの値)
    private var pricesSection: some View {
        Section {
            priceRow(String(localized: "クラウド文字起こし"), String(localized: "1分 \(account.price("transcribePerMinute", default: 10))pt"))
            priceRow(String(localized: "AI 仕上げ・翻訳・台本"), String(localized: "80行ごと \(account.price("chat", default: 20))pt"))
            priceRow(String(localized: "クラウドの読み上げ"), String(localized: "1,000文字 \(account.price("speechPerThousandChars", default: 50))pt"))
        } header: {
            Text("使うポイント")
        } footer: {
            Text("iPhone の中で動く AI(Apple の文字起こし・Whisper・端末の声など)はポイントを使いません。")
        }
    }

    private func priceRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// AI の使い方(ポイント / 自分のキー)
    private var sourceSection: some View {
        Section {
            Picker("クラウド AI", selection: Binding(get: { account.source }, set: { account.source = $0 })) {
                ForEach(CloudAISource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("クラウド AI の使い方")
        }
    }

    private var accountSection: some View {
        Section {
            Button("サインアウト") {
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
                        let deleted = await account.deleteAccount()
                        isDeleting = false
                        if deleted { showDeleted = true }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("ポイントと利用の記録がサーバーから削除され、元に戻せません。プロジェクトや動画はこの iPhone に残ります。")
            }
        }
    }

    private func claimDaily() {
        // 受け取っている途中(account.isClaimingDaily)の二度押しは無視する。AccountService 側でも止めている
        guard !account.isClaimingDaily else { return }
        Task { @MainActor in
            await account.claimDaily()
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

/// シート表示用(NavigationStack と「完了」ボタン付き)。
/// 字幕・台本・読み上げなどで、サインインやポイントが要るエラーから「アカウントとポイント」を開くときに使う
struct AccountPointsSheet: View {
    @Environment(\.dismiss) private var dismiss

    init() {}

    var body: some View {
        NavigationStack {
            AccountPointsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// サーバーからまだ値をもらっていないときの目安
enum AccountPrices {
    static let signup = 100
}

/// 一覧・設定に置く 1 行(残りのポイント、またはサインイン)。押すと「アカウントとポイント」の画面へ
struct AccountPointsSummaryLabel: View {
    @State private var account = AccountService.shared
    /// サインイン前は文字を出さず星のアイコンだけにする(一覧の左上。登録が要るように見せない)
    private let iconOnlyWhenSignedOut: Bool

    init(iconOnlyWhenSignedOut: Bool = false) {
        self.iconOnlyWhenSignedOut = iconOnlyWhenSignedOut
    }

    var body: some View {
        if account.isSignedIn, let points = account.points {
            Label {
                Text(verbatim: "\(points.formatted())pt")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "star.circle.fill")
                    .foregroundStyle(BrandStyle.coral)
            }
        } else if account.isSignedIn {
            Label("ポイント", systemImage: "star.circle.fill")
        } else if iconOnlyWhenSignedOut {
            Image(systemName: "star.circle")
                .font(.title3)
                .foregroundStyle(BrandStyle.coral)
                .accessibilityLabel("サインイン")
        } else {
            Label("サインイン", systemImage: "person.crop.circle")
        }
    }
}

extension AccountPointsSummaryLabel {
    /// まだ残りを知らないときだけ取りに行く(一覧を開いたとき)
    func loadingPointsIfNeeded() -> some View {
        task {
            let account = AccountService.shared
            if account.isSignedIn, account.points == nil { await account.refresh() }
        }
    }
}
