import Foundation
import UIKit
import Observation
import AppTrackingTransparency
import GoogleMobileAds
import UserMessagingPlatform

// =====================================================================
// 広告(Google AdMob)
//   - インタースティシャル(全画面): 書き出し開始・書き出し完了・AI の解析の開始と完了・プロジェクトを閉じたとき。
//     出しすぎないよう、前の広告から minimumInterval 秒あける。
//     書き出しの開始・完了は書き出し画面(ExportView)だけが出す(裏で終わった書き出しや、許可の確認の上に重ねない)
//   - ネイティブ: NativeAdCard(処理中の画面・AI 処理中のカード・書き出し完了画面)
//     完成画面では、ネイティブ広告が届いてから枠を出す(届かないときに空の箱を残さない。共有ボタンは広告より上)
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

    /// TestFlight(サンドボックスのレシート)かデバッグビルド → テスト広告(どのスレッドからでも読める)
    nonisolated static var usesTestAds: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private var interstitialUnit: String { Self.usesTestAds ? Self.testInterstitialUnit : Self.liveInterstitialUnit }
    private var rewardedUnit: String { Self.usesTestAds ? Self.testRewardedUnit : Self.liveRewardedUnit }

    /// リワード広告(見てポイント)を使えるか
    nonisolated static var hasRewarded: Bool { usesTestAds || !liveRewardedUnit.isEmpty }

    /// AdMob SDK の開始まで終わったか(広告の読み込み・表示は true になってから。同意が取れる前には読み込まない)
    private(set) var isStarted = false
    /// リワード広告の準備ができているか(ボタンの有効・無効に使う)
    private(set) var isRewardedReady = false
    private(set) var isShowing = false
    /// 広告の同意を見直すボタンが必要な地域か(設定画面に「広告の同意を変更」を出す)
    private(set) var privacyOptionsRequired = false

    /// 広告の同意を見直す画面を出す
    func presentPrivacyOptions() async {
        try? await ConsentForm.presentPrivacyOptionsForm(from: Self.topViewController())
    }

    @ObservationIgnored private var interstitial: InterstitialAd?
    @ObservationIgnored private var rewarded: RewardedAd?
    @ObservationIgnored private var lastShown: Date = .distantPast
    @ObservationIgnored private var earnedReward = false
    @ObservationIgnored private var rewardContinuation: CheckedContinuation<Bool, Never>?
    /// start() の途中か(2 回目以降の呼び出しを重ねないため。終わったら、うまくいかなくても false に戻す)
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isObservingActivation = false
    @ObservationIgnored private var isRequestingTracking = false
    @ObservationIgnored private var isLoadingInterstitial = false
    @ObservationIgnored private var isLoadingRewarded = false
    /// 続けて読み込みに失敗した回数(読み込み直すまでの間隔に使う)
    @ObservationIgnored private var interstitialFailures = 0
    @ObservationIgnored private var rewardedFailures = 0
    /// 読み込み直しの予定がすでにあるか(前面に戻ったときの読み込みなどが失敗しても、予定を重ねないため)
    @ObservationIgnored private var isInterstitialRetryScheduled = false
    @ObservationIgnored private var isRewardedRetryScheduled = false
    /// サポート用の情報に出す、最後の読み込みの結果
    @ObservationIgnored private var interstitialStatus = AdsManager.notLoadedText
    @ObservationIgnored private var rewardedStatus = AdsManager.notLoadedText
    @ObservationIgnored private var startStatus = String(localized: "未完了")

    /// 「まだ読み込んでいない」(サポート用の情報で共通)
    nonisolated static let notLoadedText = String(localized: "まだ読み込んでいない")

    /// 読み込みの結果の文(サポート用の情報で共通)
    nonisolated static func loadResultText(success: Bool, error: String?) -> String {
        success ? String(localized: "読み込み成功") : String(localized: "読み込み失敗: ") + (error ?? String(localized: "広告がありません"))
    }

    /// サポート用の情報(広告がどこで止まっているかを見るため)
    func diagnosticSummary() -> String {
        let consent = ConsentInformation.shared
        let yes = String(localized: "はい")
        let no = String(localized: "いいえ")
        let att: String
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .notDetermined: att = String(localized: "未確認")
        case .restricted: att = String(localized: "制限あり")
        case .denied: att = String(localized: "許可しない")
        case .authorized: att = String(localized: "許可")
        @unknown default: att = String(localized: "不明")
        }
        let ready = String(localized: "準備済み")
        return [
            String(localized: "広告の準備: ") + (isStarted ? String(localized: "完了") : startStatus),
            String(localized: "テスト広告: ") + (Self.usesTestAds ? yes : no),
            String(localized: "広告の同意: ") + (consent.canRequestAds ? String(localized: "読み込める") : String(localized: "読み込めない"))
                + " (\(consent.consentStatus.rawValue))",
            String(localized: "トラッキング: ") + att,
            String(localized: "全画面広告: ") + (interstitial != nil ? ready : interstitialStatus),
            String(localized: "リワード広告: ") + (rewarded != nil ? ready : rewardedStatus),
            String(localized: "ネイティブ広告: ") + NativeAdProvider.shared.diagnostic,
            String(localized: "バナー広告: ") + (BannerAds.isAvailable ? BannerAds.lastStatus : String(localized: "本番用の広告ユニットなし")),
        ].joined(separator: "\n")
    }

    /// バナー広告などに渡す、いま前面にある画面
    static func presentingViewController() -> UIViewController? {
        topViewController()
    }

    /// 起動後、画面が出てから呼ぶ(トラッキングの許可を聞いてから SDK を始める)。
    /// 同意情報が取れず SDK を始められなかったときは、次に前面に来たとき(appDidBecomeActive)にやり直す
    func start() async {
        observeActivationIfNeeded()
        guard !isStarted, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        // 1) 広告の同意(ヨーロッパ・イギリスなど、必要な地域だけ同意画面が出る)
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: Self.topViewController())
        } catch {
            // 同意情報を取れなくても、前回の同意で広告を出せるなら続ける
        }
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        // 広告を出せない(同意情報を取れなかった・同意がまだ)ときは、ここでやめて前面に戻ったときにやり直す
        guard ConsentInformation.shared.canRequestAds else {
            startStatus = String(localized: "同意待ち")
            return
        }
        // 2) トラッキングの確認
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            // 確認はアプリが .active(前面で操作できる状態)のときしか出ないので、そうなるまで待つ
            await waitUntilActive()
            // 取り消されたときは、ここでやめる(次に前面に来たとき appDidBecomeActive からやり直す)
            guard !Task.isCancelled else { return }
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        // 年齢制限 4+ に合わせて、広告は全年齢向け(G)だけにする
        MobileAds.shared.requestConfiguration.maxAdContentRating = .general
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            MobileAds.shared.start { _ in continuation.resume() }
        }
        // ここから広告を読み込み・表示できる
        isStarted = true
        loadInterstitial()
        loadRewarded()
        NativeAdProvider.shared.preload()
    }

    /// アプリが .active になるまで待つ(すでに .active ならすぐ戻る)
    private func waitUntilActive() async {
        while UIApplication.shared.applicationState != .active {
            // 呼び出し元(画面の .task)が取り消されると、通知の待ち受けがすぐ終わって空回りするので抜ける
            if Task.isCancelled { return }
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                break
            }
        }
    }

    /// 前面に来たとき(.active になったとき)に、うまくいかなかったことをやり直すための通知を受け取る
    private func observeActivationIfNeeded() {
        guard !isObservingActivation else { return }
        isObservingActivation = true
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        guard isStarted else {
            // 同意情報が取れずに SDK を始められていなければ、始めからやり直す(途中なら何もしない)
            Task { await self.start() }
            return
        }
        // 読み込めていない広告を読み込み直す(読み込み済み・読み込み中のものはそのまま)
        if !isShowing {
            loadInterstitial()
            loadRewarded()
            NativeAdProvider.shared.preload()
        }
        // 起動直後などでトラッキングの確認が出なかった(まだ決まっていない)ときは、もう一度聞く
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined, !isRequestingTracking, !isShowing {
            isRequestingTracking = true
            Task {
                _ = await ATTrackingManager.requestTrackingAuthorization()
                self.isRequestingTracking = false
            }
        }
    }

    /// 読み込みに失敗したあと、読み込み直すまでの間隔(15 秒から倍々にのばし、最大 5 分)
    nonisolated static func retryDelay(failures: Int) -> Duration {
        let seconds: Int = min(300, 15 << min(max(failures, 1) - 1, 5))
        return .seconds(seconds)
    }

    // MARK: インタースティシャル

    private func loadInterstitial() {
        guard isStarted, interstitial == nil, !isLoadingInterstitial else { return }
        isLoadingInterstitial = true
        InterstitialAd.load(with: interstitialUnit, request: Request()) { [weak self] ad, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingInterstitial = false
                self.interstitialStatus = AdsManager.loadResultText(success: ad != nil, error: message)
                self.interstitial = ad
                ad?.fullScreenContentDelegate = self
                if ad != nil {
                    self.interstitialFailures = 0
                } else {
                    // 電波が弱いときなど。間をあけて読み込み直す(予定がすでにあれば重ねない)
                    self.interstitialFailures += 1
                    if !self.isInterstitialRetryScheduled {
                        self.isInterstitialRetryScheduled = true
                        let delay = AdsManager.retryDelay(failures: self.interstitialFailures)
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: delay)
                            self?.isInterstitialRetryScheduled = false
                            self?.loadInterstitial()
                        }
                    }
                }
            }
        }
    }

    /// その場面で全画面広告を出す(準備できていない・前の広告から間がない・トラッキングの確認が出ているときは何もしない)
    func showInterstitial(_ placement: AdPlacement) {
        guard isStarted, !isShowing, !isRequestingTracking, let ad = interstitial else { return }
        guard Date().timeIntervalSince(lastShown) >= Self.minimumInterval else { return }
        guard let root = Self.topViewController() else { return }
        isShowing = true
        lastShown = Date()
        interstitial = nil
        ad.present(from: root)
    }

    // MARK: リワード

    private func loadRewarded() {
        guard isStarted, Self.hasRewarded, rewarded == nil, !isLoadingRewarded else { return }
        isRewardedReady = false
        isLoadingRewarded = true
        RewardedAd.load(with: rewardedUnit, request: Request()) { [weak self] ad, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingRewarded = false
                self.rewardedStatus = AdsManager.loadResultText(success: ad != nil, error: message)
                self.rewarded = ad
                ad?.fullScreenContentDelegate = self
                self.isRewardedReady = ad != nil
                if ad != nil {
                    self.rewardedFailures = 0
                } else {
                    // 電波が弱いときなど。間をあけて読み込み直す(予定がすでにあれば重ねない)
                    self.rewardedFailures += 1
                    if !self.isRewardedRetryScheduled {
                        self.isRewardedRetryScheduled = true
                        let delay = AdsManager.retryDelay(failures: self.rewardedFailures)
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: delay)
                            self?.isRewardedRetryScheduled = false
                            self?.loadRewarded()
                        }
                    }
                }
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
        // 広告の動画で音の設定(カテゴリ)が変わっていることがあるので、再生用(マナーモードでも鳴る)に戻す
        AudioSessionSetup.ensurePlayback()
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
