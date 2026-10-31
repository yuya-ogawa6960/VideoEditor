import Foundation
import AVFoundation
import UIKit

// =====================================================================
// 書き出した動画(Documents/Exports)の整理。
//
// 書き出したファイルは Documents/Exports に置くので、「ファイル」アプリの「このiPhone内 › Video Mania」に
// そのまま出る(UIFileSharingEnabled)。そこがいっぱいになるので、アプリの中から消せるようにする。
//   - ExportedFile: Exports フォルダの 1 ファイル(名前・日付・大きさ)
//   - ExportFileStore: 一覧・合計・削除(履歴に載っているものは ExportManager.deleteRecord で履歴ごと消す)
//   - ExportAutoCleanup: 「書き出した動画を自動で消す」の設定(しない / 7 日後 / 30 日後 / 90 日後)。
//     起動時に runAutomaticCleanup() を呼ぶ。選んだ日数より新しいものと、この起動中に書き出したものは消さない
//   - ExportThumbnailCache: 一覧のサムネイル(AVAssetImageGenerator。作ったものは覚えておく)
// 新しい書き出しの保存先は変えない(ExportManager.exportsDirectory のまま)。
// =====================================================================

/// Exports フォルダの 1 ファイル
struct ExportedFile: Identifiable, Hashable {
    let url: URL
    /// 書き出した日時(ファイルの作成日。取れなければ更新日)
    let date: Date
    /// 大きさ(バイト)
    let size: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// 動画か(音声だけの m4a はサムネイルを作らない)
    var isVideo: Bool { ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }
}

/// 「書き出した動画を自動で消す」の選択肢(値は日数。0 は消さない)
enum ExportAutoCleanup: Int, CaseIterable, Identifiable {
    case never = 0
    case days7 = 7
    case days30 = 30
    case days90 = 90

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .never: return String(localized: "しない")
        case .days7: return String(localized: "7 日後")
        case .days30: return String(localized: "30 日後")
        case .days90: return String(localized: "90 日後")
        }
    }
}

enum ExportFileStore {
    /// この起動中に書き出したファイルのパス(自動削除で消さないため)
    @MainActor private static var sessionExportedPaths: Set<String> = []

    /// 書き出しが終わったら呼ぶ(ExportManager.finishSucceeded)
    @MainActor
    static func noteExported(_ url: URL) {
        sessionExportedPaths.insert(url.standardizedFileURL.path)
    }

    @MainActor
    static func wasExportedThisSession(_ url: URL) -> Bool {
        sessionExportedPaths.contains(url.standardizedFileURL.path)
    }

    /// 書き出しで作るファイルの拡張子(ExportFileFormat の mp4 / mov と、音声だけの m4a)
    private static let exportedExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a"]

    /// Exports フォルダのファイルを新しい順に返す(history.json などの隠しファイル・履歴ファイルは除く)
    static func listFiles() -> [ExportedFile] {
        guard let directory = try? ExportManager.exportsDirectory() else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        var files: [ExportedFile] = []
        for url in urls {
            guard url.lastPathComponent != "history.json" else { continue }
            // 書き出しで作る形式(動画 / 音声だけ)以外は一覧に出さない・消さない
            guard Self.exportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let date = values.creationDate ?? values.contentModificationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)
            files.append(ExportedFile(url: url, date: date, size: size))
        }
        return files.sorted { $0.date > $1.date }
    }

    /// 合計の大きさ(バイト)
    static func totalSize(of files: [ExportedFile]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// 表示用の大きさ(例: 1.2 GB)
    static func sizeText(_ bytes: Int64) -> String {
        StorageEstimator.formatBytes(bytes)
    }

    /// 「設定」の行に出す合計の大きさ
    static func totalSizeText() -> String {
        sizeText(totalSize(of: listFiles()))
    }

    /// ファイルを消す。書き出し履歴に載っているものは履歴ごと消す(ExportManager.deleteRecord)
    @MainActor
    static func delete(_ files: [ExportedFile]) {
        let exporter = ExportManager.shared
        for file in files {
            if let record = exporter.history.first(where: { $0.fileName == file.url.lastPathComponent }) {
                exporter.deleteRecord(record)
            } else {
                try? FileManager.default.removeItem(at: file.url)
            }
            ExportThumbnailCache.shared.remove(file.url)
        }
    }

    /// 指定した日数より前に書き出したもの(days が nil ならすべて)。この起動中に書き出したものは含めない
    @MainActor
    static func files(olderThanDays days: Int?, in files: [ExportedFile]) -> [ExportedFile] {
        let cutoff: Date? = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        return files.filter { file in
            if wasExportedThisSession(file.url) { return false }
            guard let cutoff else { return true }
            return file.date < cutoff
        }
    }

    /// 起動時の自動削除。設定(AppSettings.exportAutoCleanupDays)が 0 なら何もしない
    @MainActor
    static func runAutomaticCleanup() {
        let days = AppSettings.shared.exportAutoCleanupDays
        guard days > 0 else { return }
        let targets = files(olderThanDays: days, in: listFiles())
        guard !targets.isEmpty else { return }
        delete(targets)
    }
}

/// 一覧のサムネイル(作ったものは覚えておく。メモリが足りなくなれば自動で捨てられる)
final class ExportThumbnailCache {
    static let shared = ExportThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }

    /// サムネイルと長さ(秒)。音声だけのファイルはサムネイルが nil
    func load(_ file: ExportedFile) async -> (image: UIImage?, duration: Double) {
        let asset = AVURLAsset(url: file.url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        if let image = cached(file.url) {
            return (image, duration)
        }
        guard file.isVideo else { return (nil, duration) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        // 最初のコマは黒いことがあるので少し進めたところ(長さが短ければ先頭)
        let seconds = duration.isFinite && duration > 1 ? min(0.5, duration / 2) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return (nil, duration) }
        let image = UIImage(cgImage: result.image)
        cache.setObject(image, forKey: file.url.path as NSString)
        return (image, duration)
    }
}
