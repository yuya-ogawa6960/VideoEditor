import SwiftUI
import StoreKit

// =====================================================================
// プランの画面(Standard / Pro の購入)。StoreKit の SubscriptionStoreView が、値段・期間・購入・復元・
// 利用規約とプライバシーポリシーへのリンクを App Store の決まりどおりに出す。上に、何が変わるかを並べる。
// 「アカウントとポイント」・書き出し(画質・長さ)・有料の機能(王冠の付いたボタンなど。PlanPaywall.present)から開く
// =====================================================================

struct PlanPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    /// 押された有料の機能(上に「○○は Standard で使えます」を出す)
    var feature: PlanFeature? = nil

    var body: some View {
        NavigationStack {
            SubscriptionStoreView(productIDs: PlanStore.productIDs) {
                PlanMarketingHeader(feature: feature)
            }
            .storeButton(.visible, for: .restorePurchases)
            .subscriptionStorePolicyDestination(url: CloudAIGateway.termsURL, for: .termsOfService)
            .subscriptionStorePolicyDestination(url: CloudAIGateway.privacyPolicyURL, for: .privacyPolicy)
            .onInAppPurchaseCompletion { _, result in
                guard case .success(.success(let verification)) = result else { return }
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await PlanStore.shared.refresh()
                dismiss()
            }
            .navigationTitle("プラン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

/// SwiftUI のシートを持たない場所(ツールバーの王冠の付いたボタン・クラウド AI の確認・カメラ)からプランの画面を出す
@MainActor
enum PlanPaywall {
    static func present(for feature: PlanFeature? = nil) {
        guard let presenter = AdsManager.presentingViewController() else { return }
        presenter.present(UIHostingController(rootView: PlanPaywallView(feature: feature)), animated: true)
    }
}

/// 無料プランで有料の機能を 1 回だけポイントで使う(PlanFeature.allowsTrial)。確認を出し、サーバーでポイントを引いてから実行する
@MainActor
enum PlanTrial {
    /// ポイントを引いている途中(確認が閉じたあとにもう一度押されて、二重に引かないように)
    private static var isSpending = false

    static func offer(_ feature: PlanFeature, run: @escaping () -> Void) {
        guard !isSpending, let presenter = AdsManager.presentingViewController() else { return }
        let account = AccountService.shared
        let cost = PlanFeature.trialPoints
        let plan = feature.requiredTier.displayName
        let canSpend = account.isSignedIn && account.isAvailable
        let message: String
        if !canSpend {
            message = String(localized: "サインインすると 1 回 \(cost)pt で使えます(「アカウントとポイント」から)。\(plan) なら何回でも使えます。")
        } else if let have = account.points {
            message = String(localized: "1 回 \(cost)pt で使えます(いま \(have)pt)。\(plan) なら何回でも使えます。")
        } else {
            message = String(localized: "1 回 \(cost)pt で使えます。\(plan) なら何回でも使えます。")
        }
        let alert = UIAlertController(title: String(localized: "「\(feature.displayName)」は \(plan) の機能です"),
                                      message: message, preferredStyle: .alert)
        if canSpend {
            let use = UIAlertAction(title: String(localized: "\(cost)pt で使う"), style: .default) { _ in
                Task { @MainActor in
                    guard !isSpending else { return }
                    isSpending = true
                    defer { isSpending = false }
                    do {
                        try await account.spendForFeature(feature)
                        run()
                    } catch {
                        showFailure(error, feature: feature)
                    }
                }
            }
            alert.addAction(use)
            alert.preferredAction = use
        }
        alert.addAction(UIAlertAction(title: String(localized: "プランを見る"), style: .default) { _ in
            Task { @MainActor in PlanPaywall.present(for: feature) }
        })
        alert.addAction(UIAlertAction(title: String(localized: "キャンセル"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// ポイントを引けなかった(足りない・通信エラーなど)。実行はしない
    private static func showFailure(_ error: Error, feature: PlanFeature) {
        guard let presenter = AdsManager.presentingViewController() else { return }
        let alert = UIAlertController(title: String(localized: "ポイントで使えませんでした"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "プランを見る"), style: .default) { _ in
            Task { @MainActor in PlanPaywall.present(for: feature) }
        })
        alert.addAction(UIAlertAction(title: String(localized: "閉じる"), style: .cancel))
        presenter.present(alert, animated: true)
    }
}

/// 購入ボタンの上: 有料プランで変わること。ほかのアプリにない機能(言いよどみカット・編集チェック・吹き替え など)を目立たせる
private struct PlanMarketingHeader: View {
    var feature: PlanFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(BrandStyle.coral)
                if let feature {
                    Text("「\(feature.displayName)」は \(feature.requiredTier.displayName) で使えます")
                        .font(.title3.weight(.bold))
                } else {
                    Text("もっと自由に、もっときれいに")
                        .font(.title2.weight(.bold))
                }
                Text("Standard で有料の機能がすべて使えます。Pro はさらに 4K・長さの制限なし・マルチカメラと、毎月のポイントが多くなります。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                row("wand.and.stars",
                    String(localized: "ほかのアプリにない AI 編集"),
                    String(localized: "言いよどみカット・編集チェック・被写体フラッシュ・画質補正"))
                row("person.and.background.dotted",
                    String(localized: "プロの仕上げ"),
                    String(localized: "背景を消す・クロマキー・LUT・音声効果・音量そろえ・モザイク・テレプロンプター"))
                row("sparkles.tv",
                    String(localized: "きれいに、長く書き出せる"),
                    String(localized: "Standard 1080p・10 分まで/Pro 4K・長さの制限なし(無料は 720p・5 分まで)"))
                row("nosign", String(localized: "広告が減る・出ない"), String(localized: "Standard は全画面広告なし/Pro は広告がいっさい出ない"))
                row("star.circle.fill",
                    String(localized: "毎月ポイントが付く"),
                    String(localized: "Standard \(PlanTerms.terms(for: .standard).monthlyPoints.formatted())pt・Pro \(PlanTerms.terms(for: .pro).monthlyPoints.formatted())pt(翌月に繰り越しません)"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(BrandStyle.coral)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
