import Foundation
import Observation

// =====================================================================
// サーバーから配る BGM(Google Lyria で作った曲)。
// 一覧(catalog.json)と曲(files/<id>_1.mp3)はサーバーの /v1/bgm/... にある(server/src/bgm.js、R2 に置く)。
// 試聴はストリーミング、「ダウンロード」で Application Support/BGMTracks に保存し、「使う」で
// 読み込んだ曲と同じく MediaStore.mediaDirectory にコピーして BGM にする(ダウンロードを消してもプロジェクトは困らない)。
// 一覧は最後に読めたものを BGMTracks/catalog.json に残し、通信できないときもダウンロード済みの曲は使えるようにする。
// =====================================================================

/// 1 曲(catalog.json の tracks の 1 件。tools/bgm/make_catalog.py が作る)
struct BGMTrack: Codable, Identifiable, Hashable {
    let id: String
    /// 画面に出す名前
    let name: String
    /// BGMMood の rawValue(知らない雰囲気でも一覧には出す)
    let mood: String
    /// テンポ(クラシックなど決まらない曲は 0)
    let bpm: Double
    /// 長さ(秒)
    let duration: Double
    /// サーバー上のファイル名(files/ の下)。端末でも同じ名前で保存する
    let file: String
    let bytes: Int?
    /// 演奏者・出どころ(クラシックの録音。画面の曲名の下に出す)
    let credit: String?

    var moodKind: BGMMood? { BGMMood(rawValue: mood) }
}

private struct BGMCatalogFile: Codable {
    let version: Int
    let tracks: [BGMTrack]
}

@MainActor @Observable
final class BGMTrackStore {
    static let shared = BGMTrackStore()

    private(set) var tracks: [BGMTrack] = []
    private(set) var isLoading = false
    /// 一覧を読めなかったときの説明(一覧が 1 曲もないときだけ出す)
    private(set) var loadError: String?
    /// 端末に保存済みの曲の id
    private(set) var downloaded: Set<String> = []
    /// ダウンロード中の曲の id
    private(set) var downloading: Set<String> = []

    /// Info.plist に VMServerURL が無いビルドで使う置き場所
    private static let fallbackServer = URL(string: "https://videomania-api.yuya-ogawa0906.workers.dev")!

    static var baseURL: URL {
        (AccountService.serverURL ?? fallbackServer).appendingPathComponent("v1/bgm")
    }

    /// Application Support/BGMTracks(必要に応じて作成)
    static var directory: URL {
        let dir = StorageLocations.applicationSupport.appendingPathComponent("BGMTracks", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var cachedCatalogURL: URL { directory.appendingPathComponent("catalog.json") }

    init() {
        if let data = try? Data(contentsOf: Self.cachedCatalogURL),
           let catalog = try? JSONDecoder().decode(BGMCatalogFile.self, from: data) {
            tracks = catalog.tracks
        }
        refreshDownloaded()
    }

    func localURL(_ track: BGMTrack) -> URL {
        Self.directory.appendingPathComponent(track.file)
    }

    func remoteURL(_ track: BGMTrack) -> URL {
        Self.baseURL.appendingPathComponent("files").appendingPathComponent(track.file)
    }

    /// 試聴に使う URL(保存済みなら端末のファイル)
    func previewURL(_ track: BGMTrack) -> URL {
        downloaded.contains(track.id) ? localURL(track) : remoteURL(track)
    }

    private func refreshDownloaded() {
        downloaded = Set(tracks.filter { FileManager.default.fileExists(atPath: localURL($0).path) }.map(\.id))
    }

    /// サーバーから一覧を読み直す(画面を開くたび。失敗しても前の一覧はそのまま)
    func loadCatalog() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.baseURL.appendingPathComponent("catalog"))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 503 {
                throw BGMTrackError.notReady
            }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalog = try JSONDecoder().decode(BGMCatalogFile.self, from: data)
            tracks = catalog.tracks
            try? data.write(to: Self.cachedCatalogURL, options: .atomic)
            loadError = nil
            refreshDownloaded()
        } catch {
            if tracks.isEmpty {
                loadError = (error as? BGMTrackError)?.errorDescription
                    ?? String(localized: "曲の一覧を読み込めませんでした。通信できる場所で、もう一度試してください。")
            }
        }
    }

    /// 端末に保存する。終わったら downloaded に入る
    func download(_ track: BGMTrack) async throws {
        guard !downloading.contains(track.id), !downloaded.contains(track.id) else { return }
        downloading.insert(track.id)
        defer { downloading.remove(track.id) }
        let (temp, response) = try await URLSession.shared.download(from: remoteURL(track))
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BGMTrackError.downloadFailed
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        guard size > 10_000 else { throw BGMTrackError.downloadFailed }
        let destination = localURL(track)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        downloaded.insert(track.id)
    }

    /// 保存した曲を消す(すでに BGM に使ったプロジェクトは、自分のコピーを持っているので影響しない)
    func delete(_ track: BGMTrack) {
        try? FileManager.default.removeItem(at: localURL(track))
        downloaded.remove(track.id)
    }

    /// 保存済みの曲を、読み込んだ曲と同じ場所にコピーする(保存名 = UUID_曲名.mp3)
    func copyForProject(_ track: BGMTrack) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let named = tempDir.appendingPathComponent(track.name + "." + (track.file as NSString).pathExtension)
        try FileManager.default.copyItem(at: localURL(track), to: named)
        return try MediaStore.copyIntoMediaDirectory(named)
    }
}

enum BGMTrackError: LocalizedError {
    case notReady
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .notReady:
            return String(localized: "曲の配信を準備しています。しばらくしてから、もう一度試してください。")
        case .downloadFailed:
            return String(localized: "曲をダウンロードできませんでした。通信できる場所で、もう一度試してください。")
        }
    }
}
