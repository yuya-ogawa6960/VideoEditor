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
                // 承認待ち(Ask to Buy など)は、承認されると Transaction.updates で届く。この端末で買ったことを Meta の計測のために覚えておく
                if case .success(.pending) = result {
                    MetaAds.notePendingPurchase()
                }
                guard case .success(.success(let verification)) = result else { return }
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    // Meta への購入の送信は、買った端末のここからだけ(PlanStore.refresh は別の端末の購入や起動でも動くので使わない)
                    await MainActor.run { MetaAds.logFirstPurchase(transaction) }
                }
                // 購入画面は先に閉じ、サーバーへの送信(毎月のポイント)は裏で待つ。
                // 送れなかったときは PlanStore が前面に戻ったとき・「アカウントとポイント」を開いたときに送り直す
                dismiss()
                await PlanStore.shared.refresh()
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

/// 無料プランで有料の機能を 1 回だけポイントで使う(PlanFeature.allowsTrial)。確認を出し、サーバーでポイントを引いてから実行する。
/// 引いたポイントは、結果を使ったときだけ確定する(commit)。見つからない・キャンセル・失敗のときは返す(refund)。
/// パネルで使う機能(画質補正・背景を消す)は、✓ で何か変えて閉じたら確定、✕ や何も変えずに閉じたら返す(settle)。
/// すでに付けた効果を直す・外すときは、ツールバーの項目(EditorToolItem.freeToAdjust)がポイントを使わずに開く
@MainActor
enum PlanTrial {
    /// ポイントを引いている途中(確認が閉じたあとにもう一度押されて、二重に引かないように)
    private static var isSpending = false
    /// ポイントを引いて、結果がまだ決まっていない試用(機能 → サーバーの trialID)
    private static var pending: [PlanFeature: String] = [:]

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
        // 結果を使わなかったときは返すことを、払う前に伝える
        let fullMessage = canSpend
            ? message + "\n" + String(localized: "結果を使わなかったとき(見つからない・キャンセル・失敗)は、ポイントを戻します。")
            : message
        let alert = UIAlertController(title: String(localized: "「\(feature.displayName)」は \(plan) の機能です"),
                                      message: fullMessage, preferredStyle: .alert)
        if canSpend {
            let use = UIAlertAction(title: String(localized: "\(cost)pt で使う"), style: .default) { _ in
                Task { @MainActor in
                    guard !isSpending else { return }
                    isSpending = true
                    defer { isSpending = false }
                    do {
                        let trialID = try await account.spendForFeature(feature)
                        if let trialID { pending[feature] = trialID }
                        run()
                    } catch {
                        showFailure(error, feature: feature)
                    }
                }
            }
            alert.addAction(use)
            alert.preferredAction = use
        } else if account.isAvailable {
            // サインインしていない: その場で「アカウントとポイント」を開き、サインインしたらこの確認に戻る
            let signIn = UIAlertAction(title: String(localized: "サインインする"), style: .default) { _ in
                Task { @MainActor in
                    AccountPointsPresenter.present(onSignedIn: { offer(feature, run: run) })
                }
            }
            alert.addAction(signIn)
            alert.preferredAction = signIn
        }
        alert.addAction(UIAlertAction(title: String(localized: "プランを見る"), style: .default) { _ in
            Task { @MainActor in PlanPaywall.present(for: feature) }
        })
        alert.addAction(UIAlertAction(title: String(localized: "キャンセル"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// 試用の結果を使った(適用した)。もう返さない
    static func commit(_ feature: PlanFeature) {
        pending[feature] = nil
    }

    /// 試用の結果が出なかった(見つからない・キャンセル・失敗)。払ったポイントを返す。返す試用があれば true
    @discardableResult
    static func refund(_ feature: PlanFeature) -> Bool {
        guard let trialID = pending.removeValue(forKey: feature) else { return false }
        Task { @MainActor in
            await AccountService.shared.refundFeatureTrial(trialID)
        }
        return true
    }

    /// パネルで使う試用(画質補正・背景を消す)を閉じたとき。applied(✓ で何か変えて閉じた)なら確定、そうでなければ返す。
    /// 返したら true
    @discardableResult
    static func settle(panel: EditorPanel, applied: @autoclosure () -> Bool) -> Bool {
        guard let feature = trialFeature(for: panel), pending[feature] != nil else { return false }
        if applied() {
            commit(feature)
            return false
        }
        return refund(feature)
    }

    /// パネルで使う試用の機能
    private static func trialFeature(for panel: EditorPanel) -> PlanFeature? {
        switch panel {
        case .enhance: return .aiQuality
        case .backgroundRemoval, .overlayBackgroundRemoval: return .backgroundRemoval
        default: return nil
        }
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
                    String(localized: "Standard \(PlanTerms.terms(for: .standard).monthlyPoints.formatted())pt・Pro \(PlanTerms.terms(for: .pro).monthlyPoints.formatted())pt(Apple でサインインしたアカウントに付きます。翌月に繰り越しません)"))
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
