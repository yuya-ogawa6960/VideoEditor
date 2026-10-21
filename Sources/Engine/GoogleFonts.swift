import Foundation
import CoreText
import CoreGraphics
import SwiftUI

// =====================================================================
// Google Fonts(約 1,900 種類。どれもオープンなライセンスで、動画に使ってよい)をアプリの中で探して入れる。
//
// - 一覧: https://fonts.google.com/metadata/fonts(1 週間キャッシュ)
// - 見本: CSS API に text= を付けると、その文字だけの小さなフォントが取れる。
//         登録はせず、その場で CTFont を作って見本の表示にだけ使う
// - 追加: CSS API(ブラウザ以外から呼ぶと .ttf の URL が返る)から通常と太字をダウンロードし、
//         MediaTools.importFont で「読み込んだフォント」として保存・登録する
// =====================================================================

struct GoogleFontFamily: Identifiable, Hashable {
    let family: String
    let category: String
    let japanese: Bool
    let popularity: Int
    /// "400", "700", "400i" など
    let weights: [String]

    var id: String { family }

    var categoryName: String {
        switch category {
        case "Sans Serif": return japanese ? "ゴシック" : "サンセリフ"
        case "Serif": return japanese ? "明朝" : "セリフ"
        case "Display": return "デザイン"
        case "Handwriting": return "手書き"
        case "Monospace": return "等幅"
        default: return category
        }
    }
}

enum GoogleFontsError: LocalizedError {
    case network
    case notFound

    var errorDescription: String? {
        switch self {
        case .network: return "フォントの一覧を取得できませんでした。通信できる所でもう一度お試しください。"
        case .notFound: return "このフォントのファイルが見つかりませんでした。"
        }
    }
}

enum GoogleFontsService {
    private static let metadataURL = URL(string: "https://fonts.google.com/metadata/fonts")!
    private static let cssBase = "https://fonts.googleapis.com/css2"
    private static let displayNamesKey = "gfonts.displayNames"

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("google-fonts-metadata.json")
    }

    // MARK: - 一覧

    static func loadCatalog() async throws -> [GoogleFontFamily] {
        let fm = FileManager.default
        var data: Data? = nil
        if let values = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate,
           Date().timeIntervalSince(modified) < 7 * 86400 {
            data = try? Data(contentsOf: cacheURL)
        }
        if data == nil {
            do {
                let (fetched, response) = try await URLSession.shared.data(from: metadataURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleFontsError.network }
                data = fetched
                try? fetched.write(to: cacheURL, options: .atomic)
            } catch {
                // 古いキャッシュがあればそれを使う
                if fm.fileExists(atPath: cacheURL.path) {
                    data = try? Data(contentsOf: cacheURL)
                } else {
                    throw GoogleFontsError.network
                }
            }
        }
        guard var raw = data else { throw GoogleFontsError.network }
        // 先頭に ")]}'" が付くことがある
        if let brace = raw.firstIndex(of: UInt8(ascii: "{")) {
            raw = raw[brace...]
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
              let list = json["familyMetadataList"] as? [[String: Any]] else { throw GoogleFontsError.network }
        var result: [GoogleFontFamily] = []
        for item in list {
            guard let family = item["family"] as? String else { continue }
            let subsets = item["subsets"] as? [String] ?? []
            let fonts = item["fonts"] as? [String: Any] ?? [:]
            result.append(GoogleFontFamily(family: family,
                                           category: item["category"] as? String ?? "",
                                           japanese: subsets.contains("japanese"),
                                           popularity: item["popularity"] as? Int ?? 9999,
                                           weights: Array(fonts.keys)))
        }
        return result.sorted { $0.popularity < $1.popularity }
    }

    // MARK: - 見本

    private static let previewLock = NSLock()
    private static var previewCache: [String: CTFont] = [:]

    /// 見本の文字だけを含む小さなフォント(登録しない)
    static func previewFont(for family: GoogleFontFamily, text: String, size: CGFloat) async -> CTFont? {
        let key = family.family + "|" + text
        previewLock.lock()
        if let cached = previewCache[key] {
            previewLock.unlock()
            return CTFontCreateCopyWithAttributes(cached, size, nil, nil)
        }
        previewLock.unlock()
        guard let url = await fontFileURL(family: family.family, weight: nil, text: text),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return nil }
        let font = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        previewLock.lock()
        if previewCache.count > 300 { previewCache.removeAll() }
        previewCache[key] = font
        previewLock.unlock()
        return font
    }

    // MARK: - 追加

    /// 通常(400)と、あれば太字(700)を入れる。入れた PostScript 名を返す(先頭が通常)
    static func install(_ family: GoogleFontFamily) async throws -> [String] {
        var weights: [String?] = []
        if family.weights.contains("400") { weights.append("400") } else { weights.append(nil) }
        if family.weights.contains("700") { weights.append("700") }
        var names: [String] = []
        for weight in weights {
            guard let url = await fontFileURL(family: family.family, weight: weight, text: nil) else { continue }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let safe = family.family.replacingOccurrences(of: " ", with: "")
            let suffix = weight == "700" ? "-Bold" : "-Regular"
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(safe + suffix + ".ttf")
            try data.write(to: temp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temp) }
            let name = try MediaTools.importFont(from: temp)
            names.append(name)
            rememberDisplayName(postScript: name, display: family.family + (weight == "700" ? "(太字)" : ""))
        }
        guard !names.isEmpty else { throw GoogleFontsError.notFound }
        return names
    }

    /// CSS API から .ttf の URL を取り出す
    private static func fontFileURL(family: String, weight: String?, text: String?) async -> URL? {
        var components = URLComponents(string: cssBase)!
        var familyParam = family
        if let weight { familyParam += ":wght@" + weight }
        var items = [URLQueryItem(name: "family", value: familyParam)]
        if let text { items.append(URLQueryItem(name: "text", value: text)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        // ブラウザ以外として呼ぶと、分割されていない .ttf の URL が返る
        request.setValue("VideoMania", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let css = String(data: data, encoding: .utf8),
              let start = css.range(of: "url("),
              let end = css.range(of: ")", range: start.upperBound..<css.endIndex) else { return nil }
        return URL(string: String(css[start.upperBound..<end.lowerBound]))
    }

    // MARK: - 表示名

    private static func rememberDisplayName(postScript: String, display: String) {
        var map = UserDefaults.standard.dictionary(forKey: displayNamesKey) as? [String: String] ?? [:]
        map[postScript] = display
        UserDefaults.standard.set(map, forKey: displayNamesKey)
    }

    /// Google Fonts から入れたフォントの表示名(なければ nil)
    static func displayName(forPostScript name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: displayNamesKey) as? [String: String])?[name]
    }

    static func installedFamilies() -> Set<String> {
        let map = UserDefaults.standard.dictionary(forKey: displayNamesKey) as? [String: String] ?? [:]
        return Set(map.values.map { $0.replacingOccurrences(of: "(太字)", with: "") })
    }
}
