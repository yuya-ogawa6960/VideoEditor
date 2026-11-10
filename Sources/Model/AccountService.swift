import Foundation
import Observation
import AuthenticationServices
import StoreKit
import UIKit

// =====================================================================
// アカウントとポイント(server/ の Cloudflare Workers と話す)。
//
// - 「Apple でサインイン」の identityToken をサーバーに送り、セッショントークン(30 日)を受け取る。
//   トークンは Keychain に保存する
// - クラウドの AI(文字起こし・字幕の整え・翻訳・台本)は、ポイントを使う設定のとき
//   OpenAI ではなくこのサーバーに送る(CloudAIGateway)。サーバーがポイントを引いて OpenAI を呼ぶ
// =====================================================================

/// クラウド AI をどちらで使うか
enum CloudAISource: String, CaseIterable, Identifiable {
    /// Video Mania のポイントで使う(サインインが必要)
    case points
    /// 自分の OpenAI API キーで使う
    case ownKey

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .points: return String(localized: "ポイントで使う")
        case .ownKey: return String(localized: "自分の OpenAI キーで使う")
        }
    }
}

/// 購入の記録をサーバーに送った結果
enum SubscriptionSyncResult {
    case synced
    /// サインインしていない・送るものがない
    case skipped
    /// 購入がほかのアカウントに結びついている(毎月のポイントはそちらに付く)
    case ownedByOtherAccount
    case failed
}

enum AccountError: LocalizedError {
    case notConfigured
    /// サーバーがエラーを返した(見せる文・HTTP ステータス・server/src/index.js の code)
    case server(String, status: Int, code: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "ポイントのサーバーがまだ用意されていません。")
        case .server(let message, _, _): return message
        case .invalidResponse: return String(localized: "サーバーの応答を読めませんでした。時間をおいてお試しください。")
        }
    }

    /// 今日のボーナスはもう受け取っている(409)
    var isAlreadyClaimed: Bool {
        if case .server(_, let status, let code) = self { return code == "already_claimed" || status == 409 }
        return false
    }
}

@Observable
final class AccountService {
    static let shared = AccountService()

    /// サーバーの URL(Info.plist の VMServerURL。空ならポイントの機能は使えない)
    static let serverURL: URL? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "VMServerURL") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), let url = URL(string: trimmed) else { return nil }
        return url
    }()

    private static let tokenKey = "vm.sessionToken"
    private static let sourceKey = "vm.cloudAISource"
    /// 送れなかった試用(50pt)の返金(サーバーの trialID)。次に残高を取り直すときに送る
    private static let pendingTrialRefundsKey = "vm.pendingTrialRefunds"
    /// セッションの残りがこれより短くなったら、サーバーで延ばしてもらう(/v1/me が新しいトークンを返す)
    private static let sessionRenewSeconds: Double = 7 * 86400
    /// 「Apple でサインイン」の利用者 ID(やめられていないかを確かめるのに使う)
    private static let appleUserIDKey = "vm.appleUserID"

    /// 残りポイント(わからないときは nil)
    private(set) var points: Int?
    /// 今日の毎日ボーナスがまだ受け取れるか
    private(set) var dailyAvailable = false
    /// サーバーのポイントの値段(/v1/me の prices。キーは server/src/index.js の POINTS)
    private(set) var prices: [String: Int] = [:]
    /// 毎日ボーナスのポイント(サーバーの値を取る前はサーバーの既定と同じ 10)
    var dailyPoints: Int { prices["daily"] ?? 10 }

    func price(_ key: String, default value: Int) -> Int {
        prices[key] ?? value
    }

    /// クラウドの読み上げで何文字が 1pt か(サーバーの値。既定は 10 文字 = 1 文字 0.1pt)
    var speechCharsPerPoint: Int { max(1, price("speechCharsPerPoint", default: 10)) }

    /// クラウドの読み上げで chars 文字を読んだときの目安のポイント。
    /// サーバーは端数を次の読み上げに持ち越すので、何回に分けても合計の文字数で決まる(ここでは切り上げで多めに見積もる)
    func speechPoints(forCharacters chars: Int) -> Int {
        guard chars > 0 else { return 0 }
        let per = speechCharsPerPoint
        return (chars + per - 1) / per
    }
    /// サーバー上の利用者 ID
    private(set) var userID: String?
    /// リワード広告のサーバー側検証で Google に渡す ID(/v1/me の rewardID。アカウントの ID そのものは渡さない)
    private(set) var rewardID: String?
    /// リワード広告に渡す ID(古いサーバーで rewardID が無いときは利用者 ID)
    var adUserIdentifier: String? { rewardID ?? userID }
    /// テスト版(TestFlight・App Review)の証明。Apple が署名した AppTransaction を、テスト広告のポイントを
    /// 受け取るときにサーバーへ送る(サーバーは署名と environment を確かめる。本番版の証明では付かない)
    private var appTransactionJWS: String?
    /// 今日すでに広告でもらった回数 / 1 日の上限 / 1 回のポイント
    private(set) var adRewardsToday = 0
    private(set) var adRewardLimit = 0
    private(set) var adRewardPoints = 0
    var adRewardsRemaining: Int { max(0, adRewardLimit - adRewardsToday) }
    private(set) var isWorking = false
    /// 残りポイントを取り直している途中か
    private(set) var isRefreshing = false
    /// 毎日ボーナス / 広告のポイントを受け取っている途中か(ボタンを無効にして、二度押しで 409 の赤い文が出ないように)
    private(set) var isClaimingDaily = false
    private(set) var isClaimingAd = false
    /// Google の声(クラウドの読み上げ)がサーバーで使えるか(/v1/me の googleTTS。わかるまでは true)
    private(set) var googleVoicesAvailable: Bool = true
    var lastError: String?

    /// クラウド AI をどちらで使うか
    var source: CloudAISource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey) }
    }

    /// セッショントークン(バックグラウンドの送信からも読むので lock で守る)
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cachedToken: String
    private(set) var isSignedIn: Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let token = KeychainStore.get(Self.tokenKey) ?? ""
        cachedToken = token
        isSignedIn = !token.isEmpty
        source = CloudAISource(rawValue: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "") ?? .points

        let center = NotificationCenter.default
        // 設定 → Apple アカウント で「Apple でサインイン」をやめられたら、すぐにサインアウトする
        let revoked = center.addObserver(forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
                                         object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AccountService.shared.signOut()
            }
        }
        // アプリが前面に戻るたびに、Apple でのサインインがまだ有効かを確かめる
        let didBecomeActive = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                 object: nil, queue: .main) { _ in
            Task { @MainActor in
                await AccountService.shared.verifyAppleCredential()
            }
        }
        observers = [revoked, didBecomeActive]
    }

    var isAvailable: Bool { Self.serverURL != nil }

    /// クラウド AI をポイントで使う状態か(サインイン済み・サーバーあり・ポイントを選んでいる)
    var usesPoints: Bool {
        lock.lock(); defer { lock.unlock() }
        return Self.serverURL != nil && !cachedToken.isEmpty && source == .points
    }

    var sessionToken: String {
        lock.lock(); defer { lock.unlock() }
        return cachedToken
    }

    private func setToken(_ token: String) {
        lock.lock()
        cachedToken = token
        lock.unlock()
        if token.isEmpty {
            KeychainStore.delete(Self.tokenKey)
        } else {
            _ = KeychainStore.set(token, for: Self.tokenKey)
        }
        isSignedIn = !token.isEmpty
    }

    // MARK: - サインイン

    /// SignInWithAppleButton の結果を受け取ってサーバーにログインする
    @MainActor
    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        lastError = nil
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            lastError = String(localized: "Apple でのサインインに失敗しました: \(error.localizedDescription)")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let identityToken = String(data: data, encoding: .utf8) else {
                lastError = String(localized: "Apple のサインイン情報を読めませんでした。")
                return
            }
            // 認可コード(5 分で失効)。サーバーが Apple の refresh_token に替えて保存し、アカウント削除のときに失効させる
            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            await signIn(identityToken: identityToken, appleUserID: credential.user, authorizationCode: authorizationCode)
        }
    }

    /// Apple の identityToken(と認可コード)をサーバーに送り、セッショントークンを受け取る
    @MainActor
    func signIn(identityToken: String, appleUserID: String, authorizationCode: String? = nil) async {
        isWorking = true
        defer { isWorking = false }
        do {
            var payload: [String: Any] = ["identityToken": identityToken]
            if let authorizationCode, !authorizationCode.isEmpty {
                payload["authorizationCode"] = authorizationCode
            }
            let body = try JSONSerialization.data(withJSONObject: payload)
            let json = try await request("v1/auth/apple", method: "POST", body: body, authorized: false)
            guard let token = json["token"] as? String else { throw AccountError.invalidResponse }
            setToken(token)
            // 起動時・前面に戻ったときに、Apple でのサインインがやめられていないかを確かめるため
            _ = KeychainStore.set(appleUserID, for: Self.appleUserIDKey)
            points = json["points"] as? Int
            dailyAvailable = (json["dailyAvailable"] as? Bool) ?? false
            if let flag = json["googleTTS"] as? Bool { googleVoicesAvailable = flag }
            // 自分の OpenAI キーを選んでいた人(キーが入っている)は、サインインし直してもその選択を残す
            if source != .ownKey || AppSettings.shared.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                source = .points
            }
            // 値段・広告の回数・利用者 ID を取り直す(取る前は「今日のボーナス」の数や「広告を見る」の行が違って見える)
            await refresh()
            // 先に買ったプランがあれば、このアカウントで毎月のポイントを受け取る
            Task { await PlanStore.shared.refresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func signOut() {
        setToken("")
        KeychainStore.delete(Self.appleUserIDKey)
        points = nil
        dailyAvailable = false
        userID = nil
        rewardID = nil
        adRewardsToday = 0
        adRewardLimit = 0
    }

    /// クラウド AI の送信がサーバーから 401(ログインの期限切れ)を受け取ったときに呼ぶ。
    /// sentToken はその送信に使ったセッショントークン。今のトークンと違えば(その間にサインインし直していれば)何もしない。
    /// nil(背景セッションの送信など、送ったトークンがわからないとき)は、今のトークンでサーバーに聞き直す。
    /// 今のトークンも 401 なら request がサインアウトする(その間にサインインし直していれば、そのまま)
    @MainActor
    func handleSessionExpired(sentToken: String?) {
        guard isSignedIn else { return }
        guard let sentToken else {
            Task { await refresh() }
            return
        }
        if sentToken != sessionToken { return }
        signOut()
    }

    /// 「Apple でサインイン」がまだ有効かを確かめ、やめられていた(または見つからない)ならサインアウトする。
    /// セッショントークンの期限(30 日)が過ぎていてもサインアウトする(送っても 401 になるだけなので)。
    /// 起動時(VideoEditorApp)と、アプリが前面に戻るたびに呼ぶ
    @MainActor
    func verifyAppleCredential() async {
        guard isSignedIn else { return }
        if let exp = (Self.sessionClaims(sessionToken)?["exp"] as? NSNumber)?.doubleValue {
            let now = Date().timeIntervalSince1970
            if exp < now {
                // 使わないまま期限が切れた。黙ってサインアウトすると、ポイントが消えたように見えるので知らせる
                signOut()
                lastError = Self.sessionExpiredNotice
                Self.presentSessionExpiredNotice()
                return
            }
            // 残りが短ければ延ばしてもらう(使っている間は切れない)
            if exp - now < Self.sessionRenewSeconds {
                await refresh()
            }
        }
        guard isSignedIn else { return }
        let token = sessionToken
        let claims = Self.sessionClaims(token)
        // 利用者 ID を保存する前のバージョンでサインインした人は、トークンの sub("apple:…")から取る
        var appleUserID = KeychainStore.get(Self.appleUserIDKey) ?? ""
        if appleUserID.isEmpty, let sub = claims?["sub"] as? String, sub.hasPrefix("apple:") {
            appleUserID = String(sub.dropFirst("apple:".count))
        }
        guard !appleUserID.isEmpty else { return }
        guard let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleUserID) else { return }
        // 確かめている間にサインアウト・サインインし直していれば何もしない
        guard isSignedIn, token == sessionToken else { return }
        if state == .revoked || state == .notFound {
            signOut()
        }
    }

    /// ログインの期限が切れてサインアウトしたときの文
    private static var sessionExpiredNotice: String {
        String(localized: "ログインの期限が切れました。もう一度 Apple でサインインしてください(ポイントとプランはそのまま残っています)。")
    }

    /// ログインの期限が切れたことを 1 回だけ知らせる(「サインインする」で「アカウントとポイント」を開く)
    @MainActor
    private static func presentSessionExpiredNotice() {
        Task { @MainActor in
            // 起動直後のほかの確認(統計・トラッキング)と重ならないよう、少し待ってから出す
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !AccountService.shared.isSignedIn, let presenter = AdsManager.presentingViewController() else { return }
            let alert = UIAlertController(title: String(localized: "ログインの期限が切れました"),
                                          message: Self.sessionExpiredNotice, preferredStyle: .alert)
            let signIn = UIAlertAction(title: String(localized: "サインインする"), style: .default) { _ in
                Task { @MainActor in AccountPointsPresenter.present() }
            }
            alert.addAction(signIn)
            alert.addAction(UIAlertAction(title: String(localized: "閉じる"), style: .cancel))
            alert.preferredAction = signIn
            presenter.present(alert, animated: true)
        }
    }

    /// セッショントークン("vm1.<base64url の JSON>.<署名>")の中身(sub・exp)。読めなければ nil
    private static func sessionClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "vm1" else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - ポイント

    @MainActor
    func refresh() async {
        guard isSignedIn, isAvailable else { return }
        isRefreshing = true
        // 前の失敗のエラーは、取り直すときに消す(成功したら赤い文が残らないように)
        lastError = nil
        defer { isRefreshing = false }
        do {
            let json = try await request("v1/me", method: "GET", body: nil, authorized: true)
            // 期限が近いセッションには、サーバーが新しいトークンを返す(差し替えて、使っている間は切れないようにする)
            if let renewed = json["token"] as? String, !renewed.isEmpty {
                setToken(renewed)
            }
            points = json["points"] as? Int
            dailyAvailable = (json["dailyAvailable"] as? Bool) ?? false
            if let serverPrices = json["prices"] as? [String: Int] { prices = serverPrices }
            if let flag = json["googleTTS"] as? Bool { googleVoicesAvailable = flag }
            applyAdState(json)
        } catch {
            lastError = error.localizedDescription
            return
        }
        await retryPendingTrialRefunds()
    }

    @MainActor
    func claimDaily() async {
        // 二度押し(前の受け取りがまだ終わっていない)は無視する
        guard !isClaimingDaily else { return }
        isClaimingDaily = true
        defer { isClaimingDaily = false }
        lastError = nil
        do {
            let json = try await request("v1/points/daily", method: "POST", body: Data("{}".utf8), authorized: true)
            points = json["points"] as? Int
            dailyAvailable = false
        } catch {
            // 「受け取り済み」(409。ほかの端末で受け取った後など)は失敗ではないので、赤い文は出さず残高と状態だけ合わせる
            let message: String? = (error as? AccountError)?.isAlreadyClaimed == true ? nil : error.localizedDescription
            await refresh()
            // refresh は前のエラーを消すので、受け取りの失敗はその後に入れる
            if let message { lastError = message }
        }
    }

    private func applyAdState(_ json: [String: Any]) {
        if let id = json["id"] as? String { userID = id }
        if let id = json["rewardID"] as? String, !id.isEmpty { rewardID = id }
        if let n = json["adRewardsToday"] as? Int { adRewardsToday = n }
        if let n = json["adRewardLimit"] as? Int { adRewardLimit = n }
        if let n = json["adRewardPoints"] as? Int { adRewardPoints = n }
    }

    /// アカウントを削除する(サーバーのポイント・履歴を消してからサインアウト)
    @MainActor
    func deleteAccount() async -> Bool {
        lastError = nil
        do {
            _ = try await request("v1/me", method: "DELETE", body: nil, authorized: true)
            signOut()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// リワード広告を最後まで見たあとに呼ぶ。テスト期間はサーバーがここでポイントを足し、
    /// 本番は AdMob のサーバー側検証で足されるので、少し待って残高を取り直す
    @MainActor
    func claimAdReward() async {
        // 二度押し(前の受け取りがまだ終わっていない)は無視する
        guard !isClaimingAd else { return }
        isClaimingAd = true
        defer { isClaimingAd = false }
        lastError = nil
        do {
            let json = try await request("v1/ads/claim", method: "POST", body: await adClaimBody(), authorized: true)
            if let value = json["points"] as? Int { points = value }
            applyAdState(json)
            if (json["pending"] as? Bool) == true {
                let before = points ?? 0
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                // SSV(AdMob のサーバー側検証)がまだ届いていない。refresh は lastError を消すので、その後に入れる
                if (json["granted"] as? Bool) == false, (points ?? 0) <= before {
                    lastError = String(localized: "ポイントの反映を確認中です。しばらくして残高を更新してください")
                }
            }
        } catch {
            let message = error.localizedDescription
            await refresh()
            // refresh は前のエラーを消すので、受け取りの失敗はその後に入れる
            lastError = message
        }
    }

    /// アプリ内課金の購入の記録(StoreKit の JWS)をサーバーに送り、毎月のポイントを受け取る。
    /// サインインしていないときは何もしない(サインインしたあとに PlanStore がもう一度送る)
    @MainActor
    func syncSubscriptions(_ signedTransactions: [String]) async -> SubscriptionSyncResult {
        guard isSignedIn, isAvailable, !signedTransactions.isEmpty else { return .skipped }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["transactions": signedTransactions])
            let json = try await request("v1/subscription/sync", method: "POST", body: body, authorized: true)
            if let value = json["points"] as? Int { points = value }
            let rejected = json["rejected"] as? [String] ?? []
            return rejected.contains("owned_by_other") ? .ownedByOtherAccount : .synced
        } catch {
            return .failed
        }
    }

    /// 広告のポイントを受け取るときの本文。テスト版なら Apple の証明(AppTransaction)を添える
    private func adClaimBody() async -> Data {
        guard AdsManager.usesTestAds else { return Data("{}".utf8) }
        if appTransactionJWS == nil, let result = try? await AppTransaction.shared {
            appTransactionJWS = result.jwsRepresentation
        }
        guard let appTransactionJWS,
              let data = try? JSONSerialization.data(withJSONObject: ["appTransaction": appTransactionJWS]) else {
            return Data("{}".utf8)
        }
        return data
    }

    /// 有料プランの機能を 1 回だけポイントで使う(無料プラン向け。サーバーが PlanFeature.trialPoints を引く。PlanTrial)。
    /// 返り値はサーバーの trialID(結果が出なかったときに refundFeatureTrial で返す。古いサーバーでは nil)
    @MainActor
    @discardableResult
    func spendForFeature(_ feature: PlanFeature) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: ["feature": feature.rawValue])
        let json = try await request("v1/points/feature", method: "POST", body: body, authorized: true)
        if let value = json["points"] as? Int { points = value }
        return json["trialID"] as? String
    }

    /// 試用のポイントを返す(結果が出なかった・キャンセルした・失敗した)。
    /// 通信できなければ覚えておき、次に残高を取り直すとき(refresh)に送る
    @MainActor
    func refundFeatureTrial(_ trialID: String) async {
        guard await sendTrialRefund(trialID) == false else { return }
        var queued = UserDefaults.standard.stringArray(forKey: Self.pendingTrialRefundsKey) ?? []
        if !queued.contains(trialID) { queued.append(trialID) }
        UserDefaults.standard.set(Array(queued.suffix(20)), forKey: Self.pendingTrialRefundsKey)
    }

    /// 送れた・送っても意味が無い(サーバーが断った)なら true、通信できなかったなら false
    @MainActor
    private func sendTrialRefund(_ trialID: String) async -> Bool {
        guard isSignedIn, isAvailable,
              let body = try? JSONSerialization.data(withJSONObject: ["trialID": trialID]) else { return false }
        do {
            let json = try await request("v1/points/feature/refund", method: "POST", body: body, authorized: true)
            if let value = json["points"] as? Int { points = value }
            return true
        } catch let error as AccountError {
            // 見つからない・時間切れなど、サーバーが断ったものは送り直さない
            if case .server(_, let status, _) = error, (400..<500).contains(status) { return true }
            return false
        } catch {
            return false
        }
    }

    /// 前に送れなかった試用の返金を送り直す
    @MainActor
    private func retryPendingTrialRefunds() async {
        let queued = UserDefaults.standard.stringArray(forKey: Self.pendingTrialRefundsKey) ?? []
        guard !queued.isEmpty else { return }
        var remaining: [String] = []
        for trialID in queued {
            let sent = await sendTrialRefund(trialID)
            if !sent { remaining.append(trialID) }
        }
        UserDefaults.standard.set(remaining, forKey: Self.pendingTrialRefundsKey)
    }

    /// AI を使ったあとの応答ヘッダ(X-VM-Points)で残りを更新する
    func updatePoints(from response: URLResponse?) {
        guard let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "x-vm-points"),
              let number = Int(value) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.points = number
        }
    }

    private func request(_ path: String, method: String, body: Data?, authorized: Bool) async throws -> [String: Any] {
        guard let base = Self.serverURL else { throw AccountError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        // TestFlight のテスト広告(サーバー側検証が来ない)を見分けるため
        if AdsManager.usesTestAds {
            request.setValue("1", forHTTPHeaderField: "x-vm-test-build")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, authorized {
            await MainActor.run { self.signOut() }
        }
        guard (200..<300).contains(status) else {
            // サーバーの文は日本語だけなので、知っている code は端末の言語の文にする(CloudAIErrorBody)
            let body = CloudAIErrorBody(data: data)
            let detail = body.displayMessage
            let message = detail.isEmpty ? String(localized: "サーバーでエラーが起きました(\(status))") : detail
            throw AccountError.server(message, status: status, code: body.code)
        }
        return json
    }
}

/// クラウド AI のエラー応答(OpenAI 形式 {error:{message,code}}。サーバーも同じ形で type が "videomania")を読む。
/// サーバーの文は日本語だけなので、知っている code は端末の言語の文にして見せる
struct CloudAIErrorBody {
    private(set) var message = ""
    private(set) var code = ""
    /// Video Mania のサーバーが返したエラーか(OpenAI のエラーではない)
    private(set) var fromServer = false

    /// JSON でなければ message は空
    init(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let error = object["error"] as? [String: Any] {
            message = (error["message"] as? String) ?? ""
            code = (error["code"] as? String) ?? ""
            fromServer = (error["type"] as? String) == "videomania"
        } else if let error = object["error"] as? String {
            message = error
            code = (object["code"] as? String) ?? ""
        }
    }

    /// 利用者に見せる文(読めなければ空)
    var displayMessage: String {
        if fromServer, let localized = CloudAIGateway.localizedServerMessage(code: code) { return localized }
        return message
    }
}

/// クラウド AI の宛先と認証(ポイントを使う設定ならサーバー、そうでなければ OpenAI)
enum CloudAIGateway {
    private static let openAITranscriptions = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let openAIChat = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let openAISpeech = URL(string: "https://api.openai.com/v1/audio/speech")!

    static var usesPoints: Bool { AccountService.shared.usesPoints }

    /// ポイントで使う設定か(サーバーがあり「ポイントで使う」を選んでいる。サインインしていなくても true)。
    /// 認証が無いときの案内を「サインイン」にするか「API キー」にするかを決める(usesPoints はサインイン済みのときだけ true)
    static var prefersPoints: Bool {
        AccountService.serverURL != nil && AccountService.shared.source == .points
    }

    static var transcriptionsURL: URL {
        if usesPoints, let base = AccountService.serverURL {
            return base.appendingPathComponent("v1/audio/transcriptions")
        }
        return openAITranscriptions
    }

    static var chatURL: URL {
        if usesPoints, let base = AccountService.serverURL {
            return base.appendingPathComponent("v1/chat/completions")
        }
        return openAIChat
    }

    /// クラウドの声(読み上げ)
    static var speechURL: URL {
        if usesPoints, let base = AccountService.serverURL {
            return base.appendingPathComponent("v1/audio/speech")
        }
        return openAISpeech
    }

    /// Authorization: Bearer に入れる値(セッショントークン、または利用者の OpenAI キー)
    static var credential: String {
        usesPoints ? AccountService.shared.sessionToken : AppSettings.shared.openAIKey
    }

    // MARK: - 案内文(サインイン・ポイントは「アカウントとポイント」、API キーは「文字起こしとAI仕上げ」の画面)

    /// ログインの期限切れ(サーバーの 401。サインアウト済み)
    static var sessionExpiredMessage: String {
        String(localized: "ログインの期限が切れました。「アカウントとポイント」でもう一度 Apple でサインインしてください。")
    }

    /// ポイント不足(402)
    static var insufficientPointsMessage: String {
        String(localized: "ポイントが足りません。「アカウントとポイント」でポイントを増やしてください。")
    }

    /// 自分の OpenAI キーが正しくない(OpenAI の 401)
    static var invalidAPIKeyMessage: String {
        String(localized: "APIキーが正しくありません。「文字起こしとAI仕上げ」で OpenAI の API キーを確認してください。")
    }

    /// 認証が無い(ポイントで使う設定ならサインイン、そうでなければ API キーの入力を案内する)
    static var notConfiguredMessage: String {
        prefersPoints
            ? String(localized: "クラウドAIを使うには、「アカウントとポイント」で Apple でサインインしてください。")
            : String(localized: "OpenAI の API キーが設定されていません。「文字起こしとAI仕上げ」でキーを入力してください。")
    }

    /// 使える AI が無い(Apple Intelligence が使えず、サインインも API キーも無い)
    static var noEngineMessage: String {
        prefersPoints
            ? String(localized: "この端末では Apple Intelligence が使えません。「アカウントとポイント」で Apple でサインインすると、ポイントで AI を使えます。")
            : String(localized: "この端末では Apple Intelligence が使えません。「文字起こしとAI仕上げ」で OpenAI の API キーを設定すると使えます。")
    }

    /// サーバーのエラーの code(server/src/index.js)を、端末の言語の文にする。知らない code は nil(サーバーの文を使う)
    static func localizedServerMessage(code: String) -> String? {
        switch code {
        case "google_not_configured":
            return String(localized: "Google の声はまだ使えません。")
        case "unauthorized":
            return sessionExpiredMessage
        case "insufficient_points":
            return insufficientPointsMessage
        case "upstream_auth":
            return String(localized: "AI のサービスの設定に問題があります(サーバー側)。ポイントは戻しました。時間をおいてお試しください。")
        case "upstream_unreachable":
            return String(localized: "AI のサービスにつながりませんでした。時間をおいてお試しください。")
        case "already_claimed":
            return String(localized: "今日のボーナスは受け取り済み")
        case "invalid_apple_token":
            return String(localized: "Apple でのサインインを確認できませんでした。もう一度お試しください。")
        default:
            return nil
        }
    }
}

// MARK: - 送信前の同意・ポリシーの URL

extension CloudAIGateway {
    /// 「続ける」を押したら true(UserDefaults)
    static let consentKey = "cloudAI.consent"
    /// Info.plist に VMServerURL が無いビルドで使う、ポリシー・サポートのページの置き場所
    private static let fallbackServer = URL(string: "https://videomania-api.yuya-ogawa0906.workers.dev")!

    /// プライバシーポリシーの URL(サーバーの /privacy)
    static var privacyPolicyURL: URL {
        (AccountService.serverURL ?? fallbackServer).appendingPathComponent("privacy")
    }

    /// 利用規約と特定商取引法に基づく表記の URL(サーバーの /terms)
    static var termsURL: URL {
        (AccountService.serverURL ?? fallbackServer).appendingPathComponent("terms")
    }

    /// サポートページの URL(サーバーの /support)
    static var supportURL: URL {
        (AccountService.serverURL ?? fallbackServer).appendingPathComponent("support")
    }

    /// OpenAI / Google に文章や音声を送る前の、1 回だけの確認。承諾済みなら即 true。
    /// 「続ける」で承諾を保存して true、「キャンセル」で false。「プライバシーポリシー」は開くだけで、確認は出たまま
    @MainActor
    static func ensureConsent() async -> Bool {
        if UserDefaults.standard.bool(forKey: consentKey) { return true }
        guard AdsManager.presentingViewController() != nil else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            presentConsentAlert(continuation)
        }
    }

    /// 同意の確認を最前面に出す。「プライバシーポリシー」はアラートが閉じてしまうので、出し直してから Safari を開く
    /// (ボタンの handler はアラートが閉じたあと、まだ前面が .foregroundActive のうちに呼ばれる。Safari を開いたあとに
    /// 出し直すと presentingViewController() が nil になって false で終わってしまう)
    @MainActor
    private static func presentConsentAlert(_ continuation: CheckedContinuation<Bool, Never>) {
        guard let presenter = AdsManager.presentingViewController() else {
            continuation.resume(returning: false)
            return
        }
        let alert = UIAlertController(
            title: String(localized: "クラウド AI に送ります"),
            message: String(localized: "音声と文章を米国の OpenAI に送ります(Google の声を選んだときは、文章を Google にも送ります)。開発者のサーバーには保存しません。OpenAI は送った内容を不正利用の確認のため最大 30 日保管することがありますが、AI の学習には使いません。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "プライバシーポリシー"), style: .default) { _ in
            presentConsentAlert(continuation)
            UIApplication.shared.open(privacyPolicyURL)
        })
        alert.addAction(UIAlertAction(title: String(localized: "キャンセル"), style: .cancel) { _ in
            continuation.resume(returning: false)
        })
        let proceed = UIAlertAction(title: String(localized: "続ける"), style: .default) { _ in
            UserDefaults.standard.set(true, forKey: consentKey)
            continuation.resume(returning: true)
        }
        alert.addAction(proceed)
        alert.preferredAction = proceed
        presenter.present(alert, animated: true)
    }
}

extension CloudAIGateway {
    /// ポイントで使う前の確認(「約 N pt を使います(いま M pt)」)。「使う」で true、「キャンセル」や出せないときは false。
    /// 足りないときは、途中で止まることと、止まるまでにできた分は残ることも書く
    @MainActor
    static func confirmPoints(_ points: Int, title: String, detail: String? = nil) async -> Bool {
        guard let presenter = AdsManager.presentingViewController() else { return false }
        var lines: [String] = []
        if let detail, !detail.isEmpty { lines.append(detail) }
        if let have = AccountService.shared.points {
            lines.append(String(localized: "約 \(points)pt を使います(いま \(have)pt)。"))
            if have < points {
                lines.append(String(localized: "ポイントが足りないため、途中で止まります。止まるまでにできた分は残ります。"))
            }
        } else {
            lines.append(String(localized: "約 \(points)pt を使います。"))
        }
        // いちばん上に出ている画面から出す(シートの上でも出せるように)
        var top: UIViewController = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        // ほかの確認が出ているときは重ねられないので、使わない扱いにする(答えを待ったまま止まらないように)
        if top is UIAlertController { return false }
        let host = top
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: title, message: lines.joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "キャンセル"), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            let use = UIAlertAction(title: String(localized: "使う"), style: .default) { _ in
                continuation.resume(returning: true)
            }
            alert.addAction(use)
            alert.preferredAction = use
            host.present(alert, animated: true)
            // 出せなかったとき(画面の切り替え中など)はボタンが押されないので、ここで終える
            if alert.presentingViewController == nil {
                continuation.resume(returning: false)
            }
        }
    }
}

/// クラウド AI のエラーに対して利用者ができること(画面がボタンと行き先を選ぶのに使う。CloudAIGateway.recovery(for:))
enum CloudAIRecovery {
    /// 「アカウントとポイント」で Apple でサインイン
    case signIn
    /// 「アカウントとポイント」でポイントを増やす
    case points
    /// 「文字起こしとAI仕上げ」で OpenAI の API キーを入力・確認
    case apiKey
    /// 案内する操作は無い(通信エラーなど)
    case none
}

extension CloudAIGateway {
    /// エラーから回復手段を決める。知らないエラーは .none
    static func recovery(for error: Error) -> CloudAIRecovery {
        // 認証が無いとき(ポイントで使う設定ならサインイン、そうでなければ API キー)
        let notConfigured: CloudAIRecovery = prefersPoints ? .signIn : .apiKey
        switch error {
        case let speech as CloudTextToSpeechError:
            switch speech {
            case .notConfigured: return notConfigured
            case .sessionExpired, .googleNeedsPoints: return .signIn
            case .insufficientPoints: return .points
            case .upstreamAuth: return .apiKey
            case .server: return .none
            }
        case let transcription as CloudTranscriptionError:
            switch transcription {
            case .missingAPIKey, .invalidAPIKey: return notConfigured
            // 402 は Video Mania のポイント不足(背景セッションの記録から戻したエラーも status で見分ける)
            case .server(let status, _): return status == 402 ? .points : .none
            default: return .none
            }
        case let script as ScriptWriterError:
            switch script {
            case .noEngine: return notConfigured
            case .sessionExpired: return .signIn
            case .insufficientPoints: return .points
            case .invalidAPIKey: return .apiKey
            default: return .none
            }
        case let polisher as SubtitlePolisherError:
            switch polisher {
            case .noEngine, .notConfigured: return notConfigured
            case .sessionExpired: return .signIn
            case .insufficientPoints: return .points
            case .invalidAPIKey: return .apiKey
            case .failed: return .none
            }
        case let account as AccountError:
            switch account {
            case .server(_, let status, let code):
                if code == "unauthorized" || status == 401 { return .signIn }
                if code == "insufficient_points" || status == 402 { return .points }
                return .none
            default: return .none
            }
        default:
            return .none
        }
    }
}
