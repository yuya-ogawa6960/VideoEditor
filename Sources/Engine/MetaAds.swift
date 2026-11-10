import Foundation
import UIKit
import StoreKit
#if canImport(FacebookCore)
import FacebookCore
#endif

// =====================================================================
// MetaAds: Instagram / Facebook の広告の効果測定(Meta SDK)
//   - 送るのは「アプリを開いた(初回はインストールの通知も)」「前回の利用時間と間隔」「初めての購入(金額・通貨)」。
//     SDK が端末ごとに作るランダムな ID と端末の情報も一緒に送られる。編集の内容や動画は送らない
//   - GitHub の Secret META_APP_ID / META_CLIENT_TOKEN が無いビルドでは何もしない
//   - SDK は起動時には始めない。広告の同意(UMP)と追跡の確認(ATT)が終わってから、AdsManager が startAfterConsent を呼ぶ
//   - GDPR の対象地域(UMP が保存する IABTCF_gdprApplies が 1。ヨーロッパ・イギリスなど)では始めず、購入も送らない
//     (Meta 向けの同意を取っていないため)
//   - 広告識別子は、追跡の許可(ATT)があるときだけ SDK が使う(iOS 17 以降は SDK が ATT を直接読む)
//   - Info.plist の自動ログの false は、SDK 18 では Meta のダッシュボードの設定に負ける。自動ログを止めるには、
//     オーナーがダッシュボードで「アプリイベントの自動ログ」と「アプリ内購入の自動ログ」の 2 つをオフにする必要がある。
//     オンのままだと、SDK が更新や復元を含む購入も自動で送る。実際の値はサポート用の情報(AdsManager.diagnosticSummary)で見られる
// =====================================================================
enum MetaAds {
    private static let loggedKey = "metaAds.loggedPurchases"
    /// この端末の購入が承認待ちになった時刻(UserDefaults)
    private static let pendingKey = "metaAds.pendingPurchaseDate"
    /// SDK を始めたか
    private static var isStarted = false
    /// SDK を始める前に届いた購入(始めたあとに送る)
    private static var heldPurchase: Transaction?

    /// Info.plist に App ID が入っているビルドか
    static var isConfigured: Bool {
        let id = Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String ?? ""
        let token = Bundle.main.object(forInfoDictionaryKey: "FacebookClientToken") as? String ?? ""
        return !id.isEmpty && !id.hasPrefix("$(") && !token.isEmpty && !token.hasPrefix("$(")
    }

    /// GDPR の対象地域か(UMP が保存する値。同意の情報をまだ取れていないときは false)
    private static var gdprApplies: Bool {
        UserDefaults.standard.integer(forKey: "IABTCF_gdprApplies") == 1
    }

    /// 端末の地域がヨーロッパ・イギリスか(UMP の答えを取れなかったときの予備の判定。同意が無いまま始めないために使う)
    static var isInConsentRegion: Bool {
        let regions: Set<String> = ["AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT",
                                    "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO",
                                    "GB", "CH"]
        return regions.contains(Locale.current.region?.identifier ?? "")
    }

    #if canImport(FacebookCore)
    /// SDK が実際に使う自動ログの設定(サポート用の情報に出す)。Meta のダッシュボードの設定が Info.plist より優先される。
    /// SDK を始める前は設定に関係なく true が返るので nil にする
    static var autoLogEnabled: Bool? {
        isStarted ? Settings.shared.isAutoLogAppEventsEnabled : nil
    }
    #endif

    /// SDK を始めて、最初の activateApp を送る(何度呼んでも 1 回だけ)。
    /// 広告の同意(UMP)と追跡の確認(ATT)が終わったあとに AdsManager から呼ぶ。先に ATT の答えが出ていれば、
    /// インストールの通知と、そのあとの購入にも広告識別子が付く(SDK は最初に読んだ広告識別子をアプリを閉じるまで使い続ける)
    @MainActor
    static func startAfterConsent() {
        #if canImport(FacebookCore)
        guard isConfigured, !isStarted, !gdprApplies else { return }
        isStarted = true
        ApplicationDelegate.shared.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            // あとから GDPR の対象地域とわかったら、もう送らない
            guard !MetaAds.gdprApplies else { return }
            AppEvents.shared.activateApp()
        }
        // いま前面にいなければ、次に前面に来たときに上の通知から送られる
        if UIApplication.shared.applicationState == .active {
            AppEvents.shared.activateApp()
        }
        if let held = heldPurchase {
            heldPurchase = nil
            sendPurchase(held)
        }
        #endif
    }

    /// 購入画面で買い終わったときに呼ぶ。ここを通るのは、この端末で買った分だけ(自動更新・復元・別の端末の購入は通らない)
    static func logFirstPurchase(_ transaction: Transaction) {
        guard Date().timeIntervalSince(transaction.purchaseDate) < 600 else { return }
        sendPurchase(transaction)
    }

    /// 購入が承認待ち(Ask to Buy など)になったときに呼ぶ。承認されると購入画面を通らず Transaction.updates で届くので、印を残す
    static func notePendingPurchase() {
        guard isConfigured else { return }
        UserDefaults.standard.set(Date(), forKey: pendingKey)
    }

    /// Transaction.updates で届いた購入のうち、この端末で承認待ちになっていたものだけを送る。
    /// 印が無いものは、別の端末の購入や自動更新なので送らない。承認はあとの起動で届くこともあるので 600 秒の制限は使わない
    static func logApprovedPurchase(_ transaction: Transaction) {
        guard transaction.id == transaction.originalID,
              let pendingDate = UserDefaults.standard.object(forKey: pendingKey) as? Date else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        // 1 週間より前の印は、断られたまま残ったものとみなす
        guard Date().timeIntervalSince(pendingDate) < 7 * 24 * 60 * 60 else { return }
        sendPurchase(transaction)
    }

    /// 購入を 1 回だけ送る(初めての有料の購入だけ。ファミリー共有・TestFlight のサンドボックス・GDPR の対象地域は送らない)
    private static func sendPurchase(_ transaction: Transaction) {
        #if canImport(FacebookCore)
        guard isConfigured, !gdprApplies, transaction.id == transaction.originalID,
              transaction.ownershipType == .purchased,
              transaction.environment == .production,
              let price = transaction.price, price > 0,
              let currency = transaction.currency?.identifier else { return }
        guard isStarted else {
            heldPurchase = transaction
            return
        }
        let defaults = UserDefaults.standard
        var logged = defaults.stringArray(forKey: loggedKey) ?? []
        let id = String(transaction.id)
        guard !logged.contains(id) else { return }
        logged.append(id)
        defaults.set(logged, forKey: loggedKey)
        AppEvents.shared.logPurchase(amount: NSDecimalNumber(decimal: price).doubleValue, currency: currency)
        #endif
    }
}
