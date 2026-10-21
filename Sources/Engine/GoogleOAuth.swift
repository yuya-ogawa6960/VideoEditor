import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

// =====================================================================
// Google のログイン(OAuth 2.0 の認可コード + PKCE)。Google フォトから写真・動画を選んで取り込む
// (GooglePhotosPicker)ためだけに使う。
//
// - クライアント ID は Info.plist の GoogleOAuthClientID(project.yml の GOOGLE_OAUTH_CLIENT_ID)。
//   空・"$(" のままなら isConfigured は false(画面は「準備中」)
// - iOS 用の OAuth クライアントなのでクライアントシークレットはない。PKCE(S256)で守る
// - リダイレクト URI は「逆順のクライアント ID」のスキーム:
//   "<prefix>.apps.googleusercontent.com" → "com.googleusercontent.apps.<prefix>:/oauth2redirect"
//   ASWebAuthenticationSession がこのスキームを受け取るので、Info.plist の URL スキームの登録は要らない
// - 権限は photospicker.mediaitems.readonly だけ(利用者が Google フォトで選んだものだけを読める)
// - リフレッシュトークンは Keychain(KeychainStore の "vm.google.refreshToken")。
//   アクセストークン(1 時間)はメモリにだけ置き、切れたら取り直す
// - Keychain はアプリを削除しても残るので、入れ直したあと最初の 1 回だけ(UserDefaults の目印がないとき)
//   前のリフレッシュトークンを消す(入れ直したらログアウトした状態から始める)
// - invalid_grant(取り消された・期限切れ)ならトークンを消して、もう一度ログインしてもらう
// =====================================================================

enum GoogleOAuthError: LocalizedError {
    case notConfigured
    /// 利用者がログイン画面を閉じた・許可しなかった(メッセージは出さない)
    case cancelled
    /// ログインし直す必要がある(トークンが取り消された・期限切れ)
    case signInRequired
    /// Google フォトの権限にチェックが入っていなかった
    case scopeNotGranted
    case noWindow
    case offline
    case timedOut
    case network
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Google フォトから直接取り込む機能は準備中です。")
        case .cancelled:
            return String(localized: "ログインをやめました。")
        case .signInRequired:
            return String(localized: "Google のログインの期限が切れました。もう一度ログインしてください。")
        case .scopeNotGranted:
            return String(localized: "Google フォトの写真・動画を選ぶ許可がありませんでした。もう一度ログインして、許可にチェックを入れてください。")
        case .noWindow:
            return String(localized: "ログイン画面を開けませんでした。もう一度お試しください。")
        case .offline:
            return String(localized: "インターネットにつながっていません。通信できる所でもう一度お試しください。")
        case .timedOut:
            return String(localized: "通信に時間がかかりすぎました。通信の良い所でもう一度お試しください。")
        case .network:
            return String(localized: "Google につながりませんでした。時間をおいてもう一度お試しください。")
        case .server(let detail):
            return String(localized: "Google でエラーが起きました(\(detail))。時間をおいてもう一度お試しください。")
        case .invalidResponse:
            return String(localized: "Google の応答を読めませんでした。もう一度お試しください。")
        }
    }
}

enum GoogleOAuth {
    /// Google フォトの Picker API の権限(選んだものだけを読める)
    static let scope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"

    private static let refreshTokenKey = "vm.google.refreshToken"
    /// この端末に入れてから、Keychain に残った前のリフレッシュトークンを消したかの目印(UserDefaults。アプリの削除で消える)
    private static let installCheckedKey = "vm.google.installChecked"
    private static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeBase = "https://oauth2.googleapis.com/revoke"

    /// アクセストークン(メモリにだけ置く)と、その期限(少し早めにしてある)
    @MainActor private static var accessToken: String?
    @MainActor private static var accessTokenExpiry = Date.distantPast
    /// 取り直しを同時に何回も送らないように
    @MainActor private static var refreshTask: Task<String, Error>?
    /// ログイン画面(終わるまで強く持っておく)
    @MainActor private static var webSession: ASWebAuthenticationSession?
    @MainActor private static var anchorProvider: GoogleAuthAnchorProvider?
    /// この起動で入れ直しの確認を済ませたか(UserDefaults を毎回読まないように)
    @MainActor private static var installChecked = false

    // MARK: - 設定

    /// Info.plist の GoogleOAuthClientID(空・"$(" のまま・読めなければ nil)
    static var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    /// リダイレクトのスキーム("com.googleusercontent.apps.<prefix>")。クライアント ID の形が違えば nil
    static var redirectScheme: String? {
        guard let id = clientID else { return nil }
        let suffix = ".apps.googleusercontent.com"
        guard id.hasSuffix(suffix) else { return nil }
        let prefix = String(id.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "com.googleusercontent.apps." + prefix
    }

    /// Google フォトから直接取り込む機能が使えるか(クライアント ID が入っているか)
    static var isConfigured: Bool {
        clientID != nil && redirectScheme != nil
    }

    /// ログイン済みか(リフレッシュトークンがあるか、まだ使えるアクセストークンがある)
    @MainActor
    static var isSignedIn: Bool {
        clearTokenLeftFromPreviousInstall()
        if let token = accessToken, !token.isEmpty, Date() < accessTokenExpiry { return true }
        return !(KeychainStore.get(refreshTokenKey) ?? "").isEmpty
    }

    /// Keychain はアプリを削除しても残るので、入れ直したあと最初の 1 回だけ前のリフレッシュトークンを消す。
    /// UserDefaults はアプリの削除で消えるので、目印がなければ入れたばかりとわかる。
    /// トークンを読む・保存する前(isSignedIn / validAccessToken / signIn)に呼ぶ
    @MainActor
    private static func clearTokenLeftFromPreviousInstall() {
        guard !installChecked else { return }
        installChecked = true
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: installCheckedKey) else { return }
        KeychainStore.delete(refreshTokenKey)
        defaults.set(true, forKey: installCheckedKey)
    }

    // MARK: - ログイン

    /// Google のログイン画面を出し、許可されたらトークンを保存する。
    /// 利用者が閉じた・許可しなかったときは GoogleOAuthError.cancelled を投げる
    @MainActor
    static func signIn() async throws {
        // 保存する前に済ませる(あとで確認したときに、新しいトークンを消してしまわないように)
        clearTokenLeftFromPreviousInstall()
        guard let clientID = clientID, let scheme = redirectScheme else { throw GoogleOAuthError.notConfigured }
        let redirectURI = scheme + ":/oauth2redirect"
        let verifier = randomURLSafeString(byteCount: 32)
        let state = randomURLSafeString(byteCount: 16)
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw GoogleOAuthError.invalidResponse }

        let callback = try await authenticate(url: url, callbackScheme: scheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error") {
            // 「キャンセル」「許可しない」を押した
            if error == "access_denied" { throw GoogleOAuthError.cancelled }
            throw GoogleOAuthError.server(error)
        }
        guard value("state") == state, let code = value("code"), !code.isEmpty else {
            throw GoogleOAuthError.invalidResponse
        }
        let json = try await postForm(tokenURL, [
            ("code", code),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ])
        _ = try store(tokenResponse: json, requireScope: true)
    }

    /// ログアウト(端末のトークンを消し、Google 側の許可も取り消す。取り消しは届かなくてもよい)
    @MainActor
    static func signOut() {
        let stored = KeychainStore.get(refreshTokenKey) ?? accessToken
        forgetTokens()
        guard let token = stored, !token.isEmpty else { return }
        Task.detached(priority: .utility) {
            await revoke(token)
        }
    }

    /// 端末のトークンだけを消す(ログインし直してもらうとき)
    @MainActor
    static func forgetTokens() {
        KeychainStore.delete(refreshTokenKey)
        accessToken = nil
        accessTokenExpiry = .distantPast
        refreshTask = nil
    }

    // MARK: - アクセストークン

    /// 使えるアクセストークン。切れていれば(forceRefresh なら必ず)リフレッシュトークンで取り直す。
    /// ログインし直す必要があれば GoogleOAuthError.signInRequired を投げる
    @MainActor
    static func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        clearTokenLeftFromPreviousInstall()
        if !forceRefresh, let token = accessToken, !token.isEmpty, Date() < accessTokenExpiry {
            return token
        }
        if let running = refreshTask {
            return try await running.value
        }
        guard let clientID = clientID else { throw GoogleOAuthError.notConfigured }
        guard let refreshToken = KeychainStore.get(refreshTokenKey), !refreshToken.isEmpty else {
            accessToken = nil
            accessTokenExpiry = .distantPast
            throw GoogleOAuthError.signInRequired
        }
        let task = Task<String, Error> { @MainActor in
            do {
                let json = try await postForm(tokenURL, [
                    ("client_id", clientID),
                    ("refresh_token", refreshToken),
                    ("grant_type", "refresh_token"),
                ])
                return try store(tokenResponse: json, requireScope: false)
            } catch GoogleOAuthError.signInRequired {
                // invalid_grant: 許可が取り消された・期限が切れた。もう一度ログインしてもらう
                KeychainStore.delete(refreshTokenKey)
                accessToken = nil
                accessTokenExpiry = .distantPast
                throw GoogleOAuthError.signInRequired
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// トークンの応答を保存し、アクセストークンを返す
    @MainActor
    private static func store(tokenResponse json: [String: Any], requireScope: Bool) throws -> String {
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw GoogleOAuthError.invalidResponse
        }
        if requireScope, let granted = json["scope"] as? String {
            let scopes = granted.split(separator: " ").map { String($0) }
            if !scopes.contains(scope) {
                // 権限のチェックを外してログインした。もらったトークンは使わずに取り消す
                Task.detached(priority: .utility) {
                    await revoke(token)
                }
                throw GoogleOAuthError.scopeNotGranted
            }
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        accessToken = token
        accessTokenExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
        // iOS のアプリにはログインのたびにリフレッシュトークンが返る。取り直しの応答には入っていないので、そのときは前のものを使い続ける
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
            KeychainStore.set(refresh, for: refreshTokenKey)
        }
        return token
    }

    // MARK: - ログイン画面

    @MainActor
    private static func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard let window = keyWindow() else { throw GoogleOAuthError.noWindow }
        let provider = GoogleAuthAnchorProvider(anchor: window)
        defer {
            webSession = nil
            anchorProvider = nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let once = GoogleOnceContinuation(continuation)
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callbackURL, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        once.resume(.failure(GoogleOAuthError.cancelled))
                    } else {
                        once.resume(.failure(GoogleOAuthError.server(error.localizedDescription)))
                    }
                } else if let callbackURL {
                    once.resume(.success(callbackURL))
                } else {
                    once.resume(.failure(GoogleOAuthError.invalidResponse))
                }
            }
            session.presentationContextProvider = provider
            // Safari のログイン状態を使う(Google にすでにログインしていれば、パスワードを入れ直さなくてよい)
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            anchorProvider = provider
            if !session.start() {
                once.resume(.failure(GoogleOAuthError.noWindow))
            }
        }
    }

    /// ログイン画面を出す土台のウィンドウ(前面のシーンのキーウィンドウ)
    @MainActor
    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty ? scenes : active).flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    // MARK: - 通信

    /// フォーム形式で POST し、JSON を返す。invalid_grant は GoogleOAuthError.signInRequired にする
    private static func postForm(_ url: URL, _ fields: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = fields.map { percentEncode($0.0) + "=" + percentEncode($0.1) }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw mappedNetworkError(error)
        }
        let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = json["error"] as? String ?? ""
            if code == "invalid_grant" { throw GoogleOAuthError.signInRequired }
            let detail = (json["error_description"] as? String) ?? code
            throw GoogleOAuthError.server(detail.isEmpty ? "HTTP " + String(status) : detail)
        }
        return json
    }

    /// Google 側の許可を取り消す(届かなくてもよい)
    private static func revoke(_ token: String) async {
        guard let url = URL(string: revokeBase + "?token=" + percentEncode(token)) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 通信のエラーを、利用者に見せる文のあるエラーにする(キャンセルは CancellationError のまま)
    static func mappedNetworkError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is GoogleOAuthError { return error }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return GoogleOAuthError.offline
        case .timedOut:
            return GoogleOAuthError.timedOut
        default:
            return GoogleOAuthError.network
        }
    }

    /// URL のクエリ・フォームの値に使えるように、英数字と -._~ 以外をすべて % で書き換える
    static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? text
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - PKCE

    /// 推測できないランダムな文字列(base64url、= なし)
    private static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        return base64URL(Data(bytes))
    }

    /// code_challenge = base64url(SHA256(code_verifier))
    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// ログイン画面を出すウィンドウを ASWebAuthenticationSession に渡す
private final class GoogleAuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// 続き(continuation)を 1 回だけ再開する(完了の知らせと開始の失敗が両方来ても落ちないように)
final class GoogleOnceContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
