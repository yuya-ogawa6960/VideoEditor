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

    /// 写真ライブラリの動画を、読み出し用の URL として取り出す(コピーしない)。
    /// 見つからない・許可がない・1 本のファイルでない(スローモーションなど)ときは nil
    static func resolve(assetID: String) async -> URL? {
        lock.lock()
        let cached: URL? = urlByID[assetID]
        lock.unlock()
        if let cached, FileManager.default.isReadableFile(atPath: cached.path) {
            return cached
        }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject, asset.mediaType == .video else { return nil }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { result, _, _ in
                continuation.resume(returning: result)
            }
        }
        guard let urlAsset = avAsset as? AVURLAsset else { return nil }
        let url = urlAsset.url
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        register(id: assetID, url: url)
        return url
    }

    /// "photos:<id>" の一覧を取り直す。取り直せなかった名前を返す
    static func prepare(references: [String]) async -> [String] {
        var missing: [String] = []
        for name in references {
            guard let id = assetID(fromReference: name) else { continue }
            if await resolve(assetID: id) == nil {
                missing.append(name)
            }
        }
        return missing
    }

    /// project.json の中の "photos:<id>"(重複なし)
    static func references(inProjectFileData data: Data) -> [String] {
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
