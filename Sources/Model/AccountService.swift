import Foundation
import Observation
import AuthenticationServices
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
    /// 「Apple でサインイン」の利用者 ID(やめられていないかを確かめるのに使う)
    private static let appleUserIDKey = "vm.appleUserID"

    /// 残りポイント(わからないときは nil)
    private(set) var points: Int?
    /// 今日の毎日ボーナスがまだ受け取れるか
    private(set) var dailyAvailable = false
    /// サーバーのポイントの値段(/v1/me の prices。キーは server/src/index.js の POINTS)
    private(set) var prices: [String: Int] = [:]
    /// 毎日ボーナスのポイント
    var dailyPoints: Int { prices["daily"] ?? 20 }

    func price(_ key: String, default value: Int) -> Int {
        prices[key] ?? value
    }
    /// サーバー上の利用者 ID(リワード広告のサーバー側検証に渡す)
    private(set) var userID: String?
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
            isWorking = true
            defer { isWorking = false }
            do {
                let body = try JSONSerialization.data(withJSONObject: ["identityToken": identityToken])
                let json = try await request("v1/auth/apple", method: "POST", body: body, authorized: false)
                guard let token = json["token"] as? String else { throw AccountError.invalidResponse }
                setToken(token)
                // 起動時・前面に戻ったときに、Apple でのサインインがやめられていないかを確かめるため
                _ = KeychainStore.set(credential.user, for: Self.appleUserIDKey)
                points = json["points"] as? Int
                dailyAvailable = (json["dailyAvailable"] as? Bool) ?? false
                source = .points
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    @MainActor
    func signOut() {
        setToken("")
        KeychainStore.delete(Self.appleUserIDKey)
        points = nil
        dailyAvailable = false
        userID = nil
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
        let token = sessionToken
        let claims = Self.sessionClaims(token)
        if let exp = (claims?["exp"] as? NSNumber)?.doubleValue, exp < Date().timeIntervalSince1970 {
            signOut()
            return
        }
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
            points = json["points"] as? Int
            dailyAvailable = (json["dailyAvailable"] as? Bool) ?? false
            if let serverPrices = json["prices"] as? [String: Int] { prices = serverPrices }
            applyAdState(json)
        } catch {
            lastError = error.localizedDescription
        }
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
            let json = try await request("v1/ads/claim", method: "POST", body: Data("{}".utf8), authorized: true)
            if let value = json["points"] as? Int { points = value }
            applyAdState(json)
            if (json["pending"] as? Bool) == true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
            }
        } catch {
            let message = error.localizedDescription
            await refresh()
            // refresh は前のエラーを消すので、受け取りの失敗はその後に入れる
            lastError = message
        }
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
