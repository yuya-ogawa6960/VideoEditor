import SwiftUI
import AuthenticationServices
import StoreKit

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
    @State private var plans = PlanStore.shared
    @State private var showPlans = false
    @State private var showManageSubscriptions = false

    var body: some View {
        Form {
            planSection
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
        .refreshable {
            await account.refresh()
            await plans.refresh()
        }
        .task {
            await account.refresh()
            // 購入の記録をサーバーに送れていなければ送り直す(毎月のポイントが付くように)
            await plans.retrySyncIfNeeded()
        }
        .sheet(isPresented: $showPlans) {
            PlanPaywallView()
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        // サブスクリプションの管理を閉じたら、解約(自動更新のオフ)などを読み直す
        .onChange(of: showManageSubscriptions) { _, isShown in
            if !isShown {
                Task { await plans.refresh() }
            }
        }
        .alert("アカウントを削除しました", isPresented: $showDeleted) {
            Button("OK") {}
        } message: {
            if plans.isPaid {
                Text("ポイントと記録はサーバーから消えました。有料プランは解約されていません。止めるときは「サブスクリプションを管理」から解約してください。")
            } else {
                Text("ポイントと記録はサーバーから消えました。")
            }
        }
    }

    // MARK: プラン

    /// いまのプランと、プランを見る・変える・解約(Apple のサブスクリプションの管理)
    private var planSection: some View {
        Section {
            HStack {
                Label(plans.tier.displayName, systemImage: plans.isPaid ? "crown.fill" : "person.crop.circle")
                    .foregroundStyle(plans.isPaid ? BrandStyle.coral : Color.primary)
                Spacer()
                if plans.isPaid, let date = plans.expiresAt {
                    // 自動更新をオフにした(解約した)ときは、更新しないことがわかるように「○月○日まで」と出す
                    if plans.willAutoRenew {
                        Text("次の更新 \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(date.formatted(date: .abbreviated, time: .omitted)) まで(自動更新オフ)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button(plans.isPaid ? String(localized: "プランを変える") : String(localized: "プランを見る")) {
                showPlans = true
            }
            if plans.isPaid {
                Button("サブスクリプションを管理") {
                    showManageSubscriptions = true
                }
            }
        } header: {
            Text("プラン")
        } footer: {
            if plans.ownedByOtherAccount {
                Text("このプランは別のアカウントで購入されたため、毎月のポイントはそちらのアカウントに付きます。")
                    .foregroundStyle(.orange)
            } else if plans.isPaid {
                Text("毎月 \(PlanTerms.terms(for: plans.tier).monthlyPoints.formatted())pt が付きます(サインインが必要です)。使い切れなかった分は翌月に繰り越しません。")
            } else {
                Text("有料プランでは、高い画質・長い動画で書き出せ、王冠の付いた機能が使え、全画面広告が出ず(Pro は広告がいっさい出ません)、毎月ポイントが付きます。")
            }
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
                Text("名前やメールアドレスは受け取りません。クラウド AI を使うとき、音声と文章は米国の OpenAI に送られます(Google の声を選んだときは、文章を Google にも送ります)。")
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

            if account.adRewardLimit > 0, AdsManager.hasRewarded, plans.terms.showsAds {
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
            if !plans.isPaid {
                Text("ポイントは、クラウド AI(文字起こし・翻訳・AI台本・クラウドの声など)と、王冠の付いた一部の機能(1 回 \(PlanFeature.trialPoints)pt)に使えます。有料プランに入ると、毎月ポイントが付きます。")
            }
        }
    }

    /// 使うポイント(サーバーの値)
    private var pricesSection: some View {
        Section {
            priceRow(String(localized: "クラウド文字起こし"), String(localized: "1分 \(account.price("transcribePerMinute", default: 10))pt"))
            priceRow(String(localized: "AI 仕上げ・翻訳・台本"), String(localized: "80行ごと \(account.price("chat", default: 20))pt"))
            priceRow(String(localized: "クラウドの読み上げ"), String(localized: "\(account.speechCharsPerPoint)文字 1pt"))
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
                if plans.isPaid {
                    Button("サブスクリプションを管理") {
                        showManageSubscriptions = true
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                if plans.isPaid {
                    // 有料プランは Apple の自動更新サブスクリプションなので、アカウントを消しても請求は止まらない
                    Text("ポイントと利用の記録がサーバーから削除され、元に戻せません。プロジェクトや動画はこの iPhone に残ります。\n有料プランは解約されません。解約しない限り Apple からの請求が続きます。解約は「サブスクリプションを管理」から。")
                } else {
                    Text("ポイントと利用の記録がサーバーから削除され、元に戻せません。プロジェクトや動画はこの iPhone に残ります。")
                }
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
            // Google に渡すのはリワード広告用の ID(アカウントの ID そのものは渡さない)
            let earned = await AdsManager.shared.showRewarded(userIdentifier: account.adUserIdentifier)
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

/// SwiftUI のシートを持たない場所(王冠の機能の試用の確認・ログインの期限切れの知らせ)から「アカウントとポイント」を出す。
/// 閉じたときにサインインしていれば onSignedIn を呼ぶ(試用の確認に戻るため)
@MainActor
enum AccountPointsPresenter {
    static func present(onSignedIn: (() -> Void)? = nil) {
        guard let presenter = AdsManager.presentingViewController() else { return }
        let sheet = AccountPointsSheet()
            .onDisappear {
                guard let onSignedIn, AccountService.shared.isSignedIn else { return }
                // 閉じるアニメーションが終わってから次の確認を出す
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    onSignedIn()
                }
            }
        presenter.present(UIHostingController(rootView: sheet), animated: true)
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
