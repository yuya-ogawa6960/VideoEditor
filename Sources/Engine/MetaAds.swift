import Foundation
import UIKit
import StoreKit
import AppTrackingTransparency
#if canImport(FacebookCore)
import FacebookCore
#endif

// =====================================================================
// MetaAds: Instagram / Facebook の広告の効果測定(Meta SDK)
//   - 送るのは「アプリを開いた」と「初めての購入」だけ。編集の内容や動画は送らない
//   - GitHub の Secret META_APP_ID / META_CLIENT_TOKEN が無いビルドでは何もしない
//   - 広告識別子は、追跡の許可(ATT。AdsManager が聞く)があるときだけ SDK が使う
//   - Meta 側で「自動ログ」は切ってあり(Info.plist)、ここで送るものだけが送られる
// =====================================================================
enum MetaAds {
    private static let loggedKey = "metaAds.loggedPurchases"

    /// Info.plist に App ID が入っているビルドか
    static var isConfigured: Bool {
        let id = Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String ?? ""
        let token = Bundle.main.object(forInfoDictionaryKey: "FacebookClientToken") as? String ?? ""
        return !id.isEmpty && !id.hasPrefix("$(") && !token.isEmpty && !token.hasPrefix("$(")
    }

    /// 起動時に 1 回
    static func start(_ application: UIApplication, launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        #if canImport(FacebookCore)
        guard isConfigured else { return }
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
        syncTrackingPermission()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            // iPhone の設定で追跡の許可を変えて戻ってきたときにも追いつく
            MetaAds.syncTrackingPermission()
            AppEvents.shared.activateApp()
        }
        #endif
    }

    /// 追跡の許可(ATT)の結果を SDK に伝える。SDK 17 からは SDK が自分では見ないので、
    /// 起動時と、AdsManager が許可を聞き終えたあとに呼ぶ。許可があるときだけ広告識別子を使った計測になる
    static func syncTrackingPermission() {
        #if canImport(FacebookCore)
        guard isConfigured else { return }
        Settings.shared.isAdvertiserTrackingEnabled = ATTrackingManager.trackingAuthorizationStatus == .authorized
        #endif
    }

    /// 新しく始めた購入を 1 回だけ送る(自動更新や、別の端末での復元は送らない)
    static func logFirstPurchase(_ transaction: Transaction) {
        #if canImport(FacebookCore)
        guard isConfigured, transaction.id == transaction.originalID,
              Date().timeIntervalSince(transaction.purchaseDate) < 600,
              let price = transaction.price, price > 0,
              let currency = transaction.currency?.identifier else { return }
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
