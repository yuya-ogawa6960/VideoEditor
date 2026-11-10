import Foundation
import Photos
import AVFoundation

// =====================================================================
// 写真ライブラリの動画を、アプリにコピーせずに参照して使う。
//
// プロジェクトの「動画の置き場所」が「写真ライブラリから参照」のとき、取り込んだ動画は
// コピーせず、project.json には "photos:<PHAsset の localIdentifier>" と保存する。
// 写真ライブラリが渡す読み出し用の URL は起動中だけ有効なので、プロジェクトを開くたびに
// PHAsset から取り直す(prepare)。スローモーションなど 1 本のファイルでない動画は参照できないため、
// 呼び出し側でアプリにコピーする。
// =====================================================================

/// プロジェクトごとの「動画の置き場所」
enum ProjectMediaMode: String, Codable {
    /// 写真ライブラリの動画をそのまま使う(iPhone の容量を使わない)
    case photoLibrary
    /// 動画をアプリ内にコピーする(写真アプリで消しても編集を続けられる)
    case appCopy

    var displayName: String {
        switch self {
        case .photoLibrary: return String(localized: "写真ライブラリから参照")
        case .appCopy: return String(localized: "アプリに取り込む")
        }
    }
}

enum PhotoMediaResolver {
    static let prefix = "photos:"

    private static let lock = NSLock()
    private static var urlByID: [String: URL] = [:]
    private static var idByPath: [String: String] = [:]

    static func isReference(_ name: String) -> Bool {
        name.hasPrefix(prefix)
    }

    static func assetID(fromReference name: String) -> String? {
        guard isReference(name) else { return nil }
        return String(name.dropFirst(prefix.count))
    }

    /// 保存用の名前。写真ライブラリを参照している URL なら "photos:<id>"、それ以外は nil
    static func reference(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = idByPath[url.standardizedFileURL.path] else { return nil }
        return prefix + id
    }

    /// 取り直し済みの URL("photos:<id>" から)
    static func cachedURL(forReference name: String) -> URL? {
        guard let id = assetID(fromReference: name) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return urlByID[id]
    }

    private static func register(id: String, url: URL) {
        lock.lock()
        urlByID[id] = url
        idByPath[url.standardizedFileURL.path] = id
        lock.unlock()
    }

    /// 取り直せなかった理由(開いたときのお知らせを出し分ける)
    enum ResolveFailure: Error {
        /// 写真ライブラリに見つからない・1 本のファイルでない(スローモーションなど)・読み出せない
        case notFound
        /// 写真へのアクセスが許可されていない(「選択した写真のみ」で含まれていないときも)
        case noAccess
        /// iCloud からダウンロードできない(通信できない)
        case network
        /// キャンセルされた
        case cancelled
    }

    /// 写真ライブラリの動画を、読み出し用の URL として取り出す(コピーしない)。
    /// 見つからない・許可がない・1 本のファイルでない(スローモーションなど)・キャンセルされたときは nil。
    /// onProgress には iCloud からのダウンロードの進み具合が届く
    static func resolve(assetID: String, onProgress: MovieImporter.ProgressHandler? = nil) async -> URL? {
        if case .success(let url) = await resolveDetailed(assetID: assetID, onProgress: onProgress) {
            return url
        }
        return nil
    }

    /// resolve と同じ。取り直せなかったときは理由を返す。
    /// expectedDuration(保存してあるクリップの素材の長さ)を渡すと、写真アプリで編集されて長さが変わった動画は
    /// 編集前の版(.original)を取り直し、そちらの長さが合えばそれを使う(取り込んだときの版で開く。
    /// 前は編集後の版に黙って差し替わり、スロー再生になったり、カット・キャプションがずれたりしていた)
    static func resolveDetailed(assetID: String, expectedDuration: Double? = nil,
                                onProgress: MovieImporter.ProgressHandler? = nil) async -> Result<URL, ResolveFailure> {
        lock.lock()
        let cached: URL? = urlByID[assetID]
        lock.unlock()
        if let cached, FileManager.default.isReadableFile(atPath: cached.path) {
            return .success(cached)
        }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return .failure(.noAccess) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else {
            // 「選択した写真のみ」のときは、許可した写真に入っていなければ見つからない
            return .failure(status == .limited ? .noAccess : .notFound)
        }
        guard asset.mediaType == .video else { return .failure(.notFound) }

        var result = await requestFileURL(for: asset, version: .current, onProgress: onProgress)
        if case .success(let current) = result, let expectedDuration, expectedDuration > 0,
           let currentDuration = await fileDuration(current),
           abs(currentDuration - expectedDuration) > durationTolerance(expectedDuration) {
            // 写真アプリで編集(トリミングなど)されて長さが変わった: 編集前の版の長さが合えば、そちらを使う
            if case .success(let original) = await requestFileURL(for: asset, version: .original, onProgress: onProgress),
               let originalDuration = await fileDuration(original),
               abs(originalDuration - expectedDuration) <= durationTolerance(expectedDuration) {
                result = .success(original)
            }
        }
        if case .success(let url) = result {
            register(id: assetID, url: url)
        }
        return result
    }

    /// 長さが「同じ」とみなす幅(0.1 秒か、長さの 1% の大きいほう)
    private static func durationTolerance(_ expected: Double) -> Double {
        max(0.1, expected * 0.01)
    }

    /// 動画ファイルの長さ(秒)。読めなければ nil
    private static func fileDuration(_ url: URL) async -> Double? {
        guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// 指定した版を読み出し用のファイル URL として取り出す(キャンセルされたら iCloud からのダウンロードも止める)
    private static func requestFileURL(for asset: PHAsset, version: PHVideoRequestOptionsVersion,
                                       onProgress: MovieImporter.ProgressHandler?) async -> Result<URL, ResolveFailure> {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = version
        options.deliveryMode = .highQualityFormat
        let avAsset: AVAsset
        do {
            avAsset = try await MovieImporter.requestAVAsset(forVideo: asset, options: options, onProgress: onProgress)
        } catch {
            if error is CancellationError || Task.isCancelled { return .failure(.cancelled) }
            return .failure(MovieImporter.isNetworkError(error) ? .network : .notFound)
        }
        guard let urlAsset = avAsset as? AVURLAsset else { return .failure(.notFound) }
        let url = urlAsset.url
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return .failure(.notFound) }
        return .success(url)
    }

    /// prepareDetailed の進み具合(何本目まで済んだか・全体の本数・いまの 1 本の iCloud からのダウンロード 0...1)。メインスレッドで呼ばれる
    typealias PrepareProgress = @MainActor @Sendable (_ done: Int, _ total: Int, _ fraction: Double) -> Void

    /// prepareDetailed の結果
    struct PrepareResult {
        /// 写真ライブラリに見つからない・アクセスが許可されていない・読み出せない
        var missing: [String] = []
        /// iCloud からダウンロードできなかった(通信できない)
        var offline: [String] = []
        /// 写真アプリで編集されて長さが変わり、編集前の版でも合わなかった(編集後の版で開いている)
        var changed: [String] = []
        /// キャンセルされた
        var cancelled = false

        /// 取り直せなかった名前(見つからない + 通信できない)
        var failed: [String] { missing + offline }
    }

    /// "photos:<id>" の一覧を取り直す。取り直せなかった名前を返す
    static func prepare(references: [String]) async -> [String] {
        await prepareDetailed(references: references).failed
    }

    /// "photos:<id>" の一覧を取り直し、取り直せなかった理由ごとに分けて返す。
    /// expectedDurations: 名前 → 保存してある素材の長さ(写真アプリで編集された動画を、取り込んだときの版で開くため)
    static func prepareDetailed(references: [String], expectedDurations: [String: Double] = [:],
                                onProgress: PrepareProgress? = nil) async -> PrepareResult {
        var result = PrepareResult()
        let total = references.count
        for (index, name) in references.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            if let onProgress {
                await onProgress(index, total, 0)
            }
            guard let id = assetID(fromReference: name) else { continue }
            var perItem: MovieImporter.ProgressHandler? = nil
            if let onProgress {
                let done = index
                perItem = { @MainActor fraction in onProgress(done, total, fraction) }
            }
            let expected: Double? = expectedDurations[name]
            switch await resolveDetailed(assetID: id, expectedDuration: expected, onProgress: perItem) {
            case .success(let url):
                if let expected, expected > 0, let actual = await fileDuration(url),
                   abs(actual - expected) > durationTolerance(expected) {
                    result.changed.append(name)
                }
            case .failure(.network):
                result.offline.append(name)
            case .failure(.cancelled):
                result.cancelled = true
            case .failure:
                result.missing.append(name)
            }
            if result.cancelled { break }
        }
        if let onProgress {
            await onProgress(total, total, 0)
        }
        return result
    }

    /// project.json の中の "photos:<id>"(重複なし)。
    /// 素材の項目(クリップ・アングル・オーバーレイの file)だけを見る。テキストやキャプションの文が "photos:" で始まっても数えない
    /// (前は文字で探していたので、写真を使っていないプロジェクトでも写真のフルアクセスを求め、「見つからない動画」と出続けていた)
    static func references(inProjectFileData data: Data) -> [String] {
        ProjectStore.photoReferences(inProjectFileData: data)
    }

    /// 文字で探す古いやり方(保存ファイルを読めないときの控え。いまは使っていない)
    private static func referencesByText(inProjectFileData data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        // JSONEncoder は "/" を "\/" と書くので、取り出したあとで戻す
        guard let regex = try? NSRegularExpression(pattern: "\"photos:([^\"]+)\"") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let id = text[r].replacingOccurrences(of: "\\/", with: "/")
            let name = prefix + id
            if !result.contains(name) {
                result.append(name)
            }
        }
        return result
    }

    /// パッケージに入れるときのファイル名("photos:<id>" はファイル名に使えないため)
    static func packageFileName(forReference name: String, url: URL) -> String {
        let id = assetID(fromReference: name) ?? name
        let safe = id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        return "Photo_" + String(safe.prefix(40)) + "." + ext
    }
}
