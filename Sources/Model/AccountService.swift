import Foundation
import Observation
import AuthenticationServices

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
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "ポイントのサーバーがまだ用意されていません。")
        case .server(let message): return message
        case .invalidResponse: return String(localized: "サーバーの応答を読めませんでした。時間をおいてお試しください。")
        }
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

    /// 残りポイント(わからないときは nil)
    private(set) var points: Int?
    /// 今日の毎日ボーナスがまだ受け取れるか
    private(set) var dailyAvailable = false
    /// サーバー上の利用者 ID(リワード広告のサーバー側検証に渡す)
    private(set) var userID: String?
    /// 今日すでに広告でもらった回数 / 1 日の上限 / 1 回のポイント
    private(set) var adRewardsToday = 0
    private(set) var adRewardLimit = 0
    private(set) var adRewardPoints = 0
    var adRewardsRemaining: Int { max(0, adRewardLimit - adRewardsToday) }
    private(set) var isWorking = false
    var lastError: String?

    /// クラウド AI をどちらで使うか
    var source: CloudAISource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey) }
    }

    /// セッショントークン(バックグラウンドの送信からも読むので lock で守る)
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cachedToken: String
    private(set) var isSignedIn: Bool

    private init() {
        let token = KeychainStore.get(Self.tokenKey) ?? ""
        cachedToken = token
        isSignedIn = !token.isEmpty
        source = CloudAISource(rawValue: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "") ?? .points
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
        points = nil
        dailyAvailable = false
        userID = nil
        adRewardsToday = 0
        adRewardLimit = 0
    }

    // MARK: - ポイント

    @MainActor
    func refresh() async {
        guard isSignedIn, isAvailable else { return }
        do {
            let json = try await request("v1/me", method: "GET", body: nil, authorized: true)
            points = json["points"] as? Int
            dailyAvailable = (json["dailyAvailable"] as? Bool) ?? false
            applyAdState(json)
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func claimDaily() async {
        lastError = nil
        do {
            let json = try await request("v1/points/daily", method: "POST", body: Data("{}".utf8), authorized: true)
            points = json["points"] as? Int
            dailyAvailable = false
        } catch {
            lastError = error.localizedDescription
            await refresh()
        }
    }

    private func applyAdState(_ json: [String: Any]) {
        if let id = json["id"] as? String { userID = id }
        if let n = json["adRewardsToday"] as? Int { adRewardsToday = n }
        if let n = json["adRewardLimit"] as? Int { adRewardLimit = n }
        if let n = json["adRewardPoints"] as? Int { adRewardPoints = n }
    }

    /// リワード広告を最後まで見たあとに呼ぶ。テスト期間はサーバーがここでポイントを足し、
    /// 本番は AdMob のサーバー側検証で足されるので、少し待って残高を取り直す
    @MainActor
    func claimAdReward() async {
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
            lastError = error.localizedDescription
            await refresh()
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
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, authorized {
            await MainActor.run { self.signOut() }
        }
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(localized: "サーバーでエラーが起きました(\(status))")
            throw AccountError.server(message)
        }
        return json
    }
}

/// クラウド AI の宛先と認証(ポイントを使う設定ならサーバー、そうでなければ OpenAI)
enum CloudAIGateway {
    private static let openAITranscriptions = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let openAIChat = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let openAISpeech = URL(string: "https://api.openai.com/v1/audio/speech")!

    static var usesPoints: Bool { AccountService.shared.usesPoints }

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
}
