import Foundation
import Observation
import Security

// =====================================================================
// アプリ設定(文字起こしエンジン・AI 仕上げ)
//
// - 設定値は UserDefaults に保存
// - API キーは Keychain(KeychainStore)に保存。UserDefaults には書かない
// - `AppSettings.shared` は @Observable。どのスレッドからも読める(NSLock で保護)
// =====================================================================

// MARK: - 文字起こしエンジン

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple
    case whisper
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple 音声認識(端末内・高速)"
        case .whisper: return "OpenAI Whisper(端末内・高精度)"
        case .cloud: return "クラウドAI(最高精度・ポイントかAPIキー)"
        }
    }

    /// 進捗表示などで使う短い名前
    var shortName: String {
        switch self {
        case .apple: return "Apple 音声認識"
        case .whisper: return "OpenAI Whisper"
        case .cloud: return "クラウドAI"
        }
    }

    var summary: String {
        switch self {
        case .apple:
            return "iOS 標準の音声認識を使います。通信不要で速く、追加のダウンロードもほぼ不要です。精度は標準的で、固有名詞や早口の会話では誤認識が増えます。"
        case .whisper:
            return "OpenAI Whisper を端末内で実行します(WhisperKit)。日本語でも精度が高く、音声が端末の外に出ません。初回にモデルのダウンロード(150MB〜1.6GB)が必要で、処理には時間がかかります。"
        case .cloud:
            return "OpenAI の音声認識(速度優先: whisper-1 / 精度優先: gpt-4o-transcribe 系)をクラウドで実行します。高精度で端末の負荷も小さい反面、音声を OpenAI のサーバーへ送信し、API 利用料(目安 約0.9円/分)がかかります。"
        }
    }

    var pros: [String] {
        switch self {
        case .apple: return ["無料・通信不要", "処理が速い", "設定不要ですぐ使える"]
        case .whisper: return ["高精度(特に日本語の句読点・漢字変換)", "通信不要・無料", "音声を外部に送らない"]
        case .cloud: return ["最高精度", "長い動画でも速く、端末が熱くならない", "AI 仕上げも同じキーで使える"]
        }
    }

    var cons: [String] {
        switch self {
        case .apple: return ["精度は標準的", "固有名詞・専門用語に弱い"]
        case .whisper: return ["モデルのダウンロードが必要(150MB〜1.6GB)", "処理が遅い(動画の長さの 0.3〜1 倍程度)", "電池を使い、端末が熱くなることがある"]
        case .cloud: return ["OpenAI API キーが必要(従量課金)", "音声データを OpenAI へ送信する", "通信環境が必要"]
        }
    }
}

// MARK: - クラウドプロバイダ

enum CloudProvider: String, CaseIterable, Identifiable {
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        }
    }
}

// MARK: - クラウド文字起こしの方式

enum CloudTranscriptionQuality: String, CaseIterable, Identifiable {
    /// whisper-1(単語時刻付き)。応答が速い
    case fast
    /// gpt-4o-transcribe 系(話者分離対応モデル)。使えなければ whisper-1 に切り替え
    case accurate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "速度優先(おすすめ)"
        case .accurate: return "精度優先(遅い)"
        }
    }

    /// 進捗表示などで使う短い名前
    var shortName: String {
        switch self {
        case .fast: return "速度優先"
        case .accurate: return "精度優先"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "whisper-1 で認識します。応答が速く、単語ごとの時刻も付くので字幕のタイミングが正確です。長い動画でも短時間で終わります。料金の目安は 約0.9円/分($0.006/分)。"
        case .accurate:
            return "gpt-4o-transcribe 系(話者分離対応モデル)で認識します。聞き取りにくい音声や固有名詞で誤認識が少し減ることがありますが、処理にかなり時間がかかります。料金の目安は速度優先とほぼ同じです。"
        }
    }
}

// MARK: - AI 仕上げエンジン

enum PolishEngine: String, CaseIterable, Identifiable {
    /// iOS 26+ の端末内モデル(Apple Intelligence)が使えればそれ、なければ API キーがあるときクラウド、どちらも無ければ何もしない
    case auto
    case onDevice
    case cloud
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自動"
        case .onDevice: return "端末内(Apple Intelligence)"
        case .cloud: return "クラウド(OpenAI)"
        case .none: return "使わない"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "端末内 AI が使えればそれを、なければ API キーがあるときだけクラウドを使います。"
        case .onDevice: return "iOS 26 以降で Apple Intelligence が有効な端末でのみ動作します。通信不要・無料。"
        case .cloud: return "OpenAI(gpt-4o-mini)で仕上げます。字幕テキストを送信し、わずかな利用料がかかります。"
        case .none: return "音声認識の結果をそのまま使います。"
        }
    }
}

// MARK: - Whisper モデル

struct WhisperModelOption: Identifiable, Hashable {
    /// WhisperKit のモデル名(argmaxinc/whisperkit-coreml 内のフォルダ名)
    let id: String
    let displayName: String
    let sizeHint: String
    let detail: String

    static let all: [WhisperModelOption] = [
        WhisperModelOption(id: "openai_whisper-base",
                           displayName: "base",
                           sizeHint: "約150MB",
                           detail: "最も軽く速い。精度は低め(短い確認用)"),
        WhisperModelOption(id: "openai_whisper-small",
                           displayName: "small",
                           sizeHint: "約500MB",
                           detail: "速さと精度のバランス型"),
        WhisperModelOption(id: "openai_whisper-large-v3-v20240930_turbo",
                           displayName: "large-v3 turbo",
                           sizeHint: "約1.6GB",
                           detail: "最高精度。iPhone 15 Pro 以降を推奨(メモリを多く使う)"),
    ]

    static func option(for id: String) -> WhisperModelOption? {
        all.first { $0.id == id }
    }
}

// MARK: - Keychain

/// 小さな文字列(API キーなど)を Keychain に保存する
enum KeychainStore {
    private static let service: String = (Bundle.main.bundleIdentifier ?? "com.personal.videoeditor") + ".secure"

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = baseQuery(for: key)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func get(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }
}

// MARK: - AppSettings

@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_turbo"

    private enum Keys {
        static let engine = "transcription.engine"
        static let whisperModel = "transcription.whisperModel"
        static let cloudProvider = "transcription.cloudProvider"
        static let cloudQuality = "transcription.cloudQuality"
        static let polish = "transcription.polishSubtitles"
        static let polishEngine = "transcription.polishEngine"
        /// Keychain のアカウント名
        static let openAIKey = "openai.apiKey"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    @ObservationIgnored private var storedEngine: TranscriptionEngine
    @ObservationIgnored private var storedWhisperModel: String
    @ObservationIgnored private var storedCloudProvider: CloudProvider
    @ObservationIgnored private var storedCloudQuality: CloudTranscriptionQuality
    @ObservationIgnored private var storedPolish: Bool
    @ObservationIgnored private var storedPolishEngine: PolishEngine
    @ObservationIgnored private var cachedOpenAIKey: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedEngine = TranscriptionEngine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        let model = defaults.string(forKey: Keys.whisperModel) ?? AppSettings.defaultWhisperModel
        storedWhisperModel = model.isEmpty ? AppSettings.defaultWhisperModel : model
        storedCloudProvider = CloudProvider(rawValue: defaults.string(forKey: Keys.cloudProvider) ?? "") ?? .openAI
        storedCloudQuality = CloudTranscriptionQuality(rawValue: defaults.string(forKey: Keys.cloudQuality) ?? "") ?? .fast
        storedPolish = defaults.object(forKey: Keys.polish) == nil ? true : defaults.bool(forKey: Keys.polish)
        storedPolishEngine = PolishEngine(rawValue: defaults.string(forKey: Keys.polishEngine) ?? "") ?? .auto
        cachedOpenAIKey = KeychainStore.get(Keys.openAIKey) ?? ""
    }

    // MARK: 文字起こしエンジン

    var transcriptionEngine: TranscriptionEngine {
        get {
            access(keyPath: \.transcriptionEngine)
            lock.lock(); defer { lock.unlock() }
            return storedEngine
        }
        set {
            withMutation(keyPath: \.transcriptionEngine) {
                lock.lock(); storedEngine = newValue; lock.unlock()
                defaults.set(newValue.rawValue, forKey: Keys.engine)
            }
        }
    }

    /// WhisperKit のモデル名
    var whisperModel: String {
        get {
            access(keyPath: \.whisperModel)
            lock.lock(); defer { lock.unlock() }
            return storedWhisperModel
        }
        set {
            let value = newValue.isEmpty ? AppSettings.defaultWhisperModel : newValue
            withMutation(keyPath: \.whisperModel) {
                lock.lock(); storedWhisperModel = value; lock.unlock()
                defaults.set(value, forKey: Keys.whisperModel)
            }
        }
    }

    var cloudProvider: CloudProvider {
        get {
            access(keyPath: \.cloudProvider)
            lock.lock(); defer { lock.unlock() }
            return storedCloudProvider
        }
        set {
            withMutation(keyPath: \.cloudProvider) {
                lock.lock(); storedCloudProvider = newValue; lock.unlock()
                defaults.set(newValue.rawValue, forKey: Keys.cloudProvider)
            }
        }
    }

    /// クラウド文字起こしの方式(速度優先 / 精度優先)
    var cloudQuality: CloudTranscriptionQuality {
        get {
            access(keyPath: \.cloudQuality)
            lock.lock(); defer { lock.unlock() }
            return storedCloudQuality
        }
        set {
            withMutation(keyPath: \.cloudQuality) {
                lock.lock(); storedCloudQuality = newValue; lock.unlock()
                defaults.set(newValue.rawValue, forKey: Keys.cloudQuality)
            }
        }
    }

    // MARK: AI 仕上げ

    var polishSubtitles: Bool {
        get {
            access(keyPath: \.polishSubtitles)
            lock.lock(); defer { lock.unlock() }
            return storedPolish
        }
        set {
            withMutation(keyPath: \.polishSubtitles) {
                lock.lock(); storedPolish = newValue; lock.unlock()
                defaults.set(newValue, forKey: Keys.polish)
            }
        }
    }

    var polishEngine: PolishEngine {
        get {
            access(keyPath: \.polishEngine)
            lock.lock(); defer { lock.unlock() }
            return storedPolishEngine
        }
        set {
            withMutation(keyPath: \.polishEngine) {
                lock.lock(); storedPolishEngine = newValue; lock.unlock()
                defaults.set(newValue.rawValue, forKey: Keys.polishEngine)
            }
        }
    }

    // MARK: API キー(Keychain)

    /// OpenAI API キー。空文字で削除。ログや UserDefaults には出さないこと
    var openAIKey: String {
        get {
            access(keyPath: \.openAIKey)
            lock.lock(); defer { lock.unlock() }
            return cachedOpenAIKey
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            withMutation(keyPath: \.openAIKey) {
                lock.lock(); cachedOpenAIKey = trimmed; lock.unlock()
                if trimmed.isEmpty {
                    KeychainStore.delete(Keys.openAIKey)
                } else {
                    KeychainStore.set(trimmed, for: Keys.openAIKey)
                }
            }
        }
    }

    var hasOpenAIKey: Bool { !openAIKey.isEmpty }

    /// 表示用: 末尾 4 文字だけ見せる("sk-…abcd")
    var openAIKeyHint: String {
        let key = openAIKey
        guard !key.isEmpty else { return "" }
        let suffix = String(key.suffix(4))
        return "sk-…" + suffix
    }

    /// クラウド文字起こし・クラウド仕上げが使える状態か(ポイントで使う設定のときはサインイン済みなら可)
    var isCloudConfigured: Bool {
        switch cloudProvider {
        case .openAI: return hasCloudCredential
        }
    }

    /// クラウド AI に送る認証(ポイントを使うならセッショントークン、そうでなければ OpenAI キー)
    var cloudCredential: String { CloudAIGateway.credential }

    var hasCloudCredential: Bool { !cloudCredential.isEmpty }
}
