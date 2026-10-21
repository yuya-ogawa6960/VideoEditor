import Foundation
import UIKit
import Observation
import AppTrackingTransparency
import GoogleMobileAds

// =====================================================================
// 広告(Google AdMob)
//   - インタースティシャル(全画面): 書き出し開始・書き出し完了・AI の解析の開始と完了・プロジェクトを閉じたとき。
//     出しすぎないよう、前の広告から minimumInterval 秒あける
//   - ネイティブ: NativeAdCard(処理中の画面・AI 処理中のカード・書き出し完了画面)
//   - リワード: 「広告を見て +ポイント」。見終わったら AccountService.claimAdReward() でサーバーに伝える
//     (本番は AdMob のサーバー側検証(SSV)でサーバーが直接ポイントを足す。userIdentifier に利用者 ID を渡す)
//   - TestFlight / デバッグでは Google のテスト用広告を出す(自分の本番広告を見たり押したりしないため)
// =====================================================================

enum AdPlacement: String {
    case exportStart, exportFinished, analysisStart, analysisFinished, projectClosed
}

@MainActor
@Observable
final class AdsManager: NSObject {
    static let shared = AdsManager()

    // 本番の広告ユニット(AdMob「Video Mania」)
    private static let liveInterstitialUnit = "ca-app-pub-5816286661245536/1383318055"
    /// 本番のリワード広告ユニット(AdMob で作ったら入れる。空のあいだ本番ではボタンを出さない)
    private static let liveRewardedUnit = "ca-app-pub-5816286661245536/4003023795"
    // Google のテスト用広告ユニット
    private static let testInterstitialUnit = "ca-app-pub-3940256099942544/4411468910"
    private static let testRewardedUnit = "ca-app-pub-3940256099942544/1712485313"

    /// インタースティシャルどうしの最短間隔(秒)
    static let minimumInterval: TimeInterval = 120

    /// TestFlight(サンドボックスのレシート)かデバッグビルド → テスト広告
    static var usesTestAds: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private var interstitialUnit: String { Self.usesTestAds ? Self.testInterstitialUnit : Self.liveInterstitialUnit }
    private var rewardedUnit: String { Self.usesTestAds ? Self.testRewardedUnit : Self.liveRewardedUnit }

    /// リワード広告(見てポイント)を使えるか
    static var hasRewarded: Bool { usesTestAds || !liveRewardedUnit.isEmpty }

    private(set) var isStarted = false
    /// リワード広告の準備ができているか(ボタンの有効・無効に使う)
    private(set) var isRewardedReady = false
    private(set) var isShowing = false

    @ObservationIgnored private var interstitial: InterstitialAd?
    @ObservationIgnored private var rewarded: RewardedAd?
    @ObservationIgnored private var lastShown: Date = .distantPast
    @ObservationIgnored private var earnedReward = false
    @ObservationIgnored private var rewardContinuation: CheckedContinuation<Bool, Never>?

    /// 起動後、画面が出てから 1 回呼ぶ(トラッキングの許可を聞いてから SDK を始める)
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            // 起動直後は確認が出ないことがあるので少し待つ
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            MobileAds.shared.start { _ in continuation.resume() }
        }
        loadInterstitial()
        loadRewarded()
        NativeAdProvider.shared.preload()
    }

    // MARK: インタースティシャル

    private func loadInterstitial() {
        InterstitialAd.load(with: interstitialUnit, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let self else { return }
                self.interstitial = ad
                ad?.fullScreenContentDelegate = self
            }
        }
    }

    /// その場面で全画面広告を出す(準備できていない・前の広告から間がないときは何もしない)
    func showInterstitial(_ placement: AdPlacement) {
        guard isStarted, !isShowing, let ad = interstitial else { return }
        guard Date().timeIntervalSince(lastShown) >= Self.minimumInterval else { return }
        guard let root = Self.topViewController() else { return }
        isShowing = true
        lastShown = Date()
        interstitial = nil
        ad.present(from: root)
    }

    // MARK: リワード

    private func loadRewarded() {
        isRewardedReady = false
        guard Self.hasRewarded else { return }
        RewardedAd.load(with: rewardedUnit, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let self else { return }
                self.rewarded = ad
                ad?.fullScreenContentDelegate = self
                self.isRewardedReady = ad != nil
            }
        }
    }

    /// リワード広告を出し、最後まで見て報酬がもらえたら true
    func showRewarded(userIdentifier: String?) async -> Bool {
        guard isStarted, !isShowing, let ad = rewarded, let root = Self.topViewController() else { return false }
        if let userIdentifier, !userIdentifier.isEmpty {
            let options = ServerSideVerificationOptions()
            options.userIdentifier = userIdentifier
            ad.serverSideVerificationOptions = options
        }
        isShowing = true
        earnedReward = false
        rewarded = nil
        isRewardedReady = false
        return await withCheckedContinuation { continuation in
            rewardContinuation = continuation
            ad.present(from: root) { [weak self] in
                Task { @MainActor in self?.earnedReward = true }
            }
        }
    }

    // MARK: 共通

    private func didFinishPresenting(_ ad: FullScreenPresentingAd) {
        isShowing = false
        lastShown = Date()
        if ad is RewardedAd {
            let earned = earnedReward
            rewardContinuation?.resume(returning: earned)
            rewardContinuation = nil
            loadRewarded()
        } else {
            loadInterstitial()
        }
    }

    /// いちばん上に出ている画面(シートの上にも出せるように)
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

extension AdsManager: FullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.didFinishPresenting(ad) }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in self.didFinishPresenting(ad) }
    }
}
