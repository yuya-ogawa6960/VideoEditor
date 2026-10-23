import SwiftUI
import UniformTypeIdentifiers

// =====================================================================
// ほかのアプリ(写真・ファイルなど)からドラッグ&ドロップで動画・写真を受け取る。
//
// - 編集画面のタイムラインに落とす: 落とした位置のクリップの切れ目に差し込む
// - 編集画面のプレビューに落とす: 再生位置からオーバーレイとして重ねる
// - プロジェクト一覧に落とす: 新しいプロジェクトを作って取り込む
//
// 受け取ったファイルは一時フォルダに "<NNN>-<元の名前>" でコピーし、
// 「ファイル」アプリ・Google フォトと同じ取り込み(importLocalFiles)に渡す(取り込み後に一時ファイルは消える)。
// =====================================================================

enum MediaDrop {
    /// 受け取る種類
    static let types: [UTType] = [.movie, .image]

    /// ドロップされた項目を一時フォルダにコピーする(落とした順。読めなかったものは飛ばす)
    static func loadFiles(from providers: [NSItemProvider]) async -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [URL] = []
        for (index, provider) in providers.enumerated() {
            if Task.isCancelled { break }
            guard let type = preferredType(of: provider) else { continue }
            if let url = await copyFile(from: provider, type: type, number: index + 1, into: folder) {
                result.append(url)
            }
        }
        return result
    }

    /// 前回までのドロップの一時フォルダを消す(起動時。取り込みのあとに空のフォルダが残るため)
    static func cleanUpTemporaryFolders() {
        let temp = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: temp.path) else { return }
        for name in names where name.hasPrefix("Drop-") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// 取り込まなかった一時ファイルを消す
    static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 動画として読めるなら動画、だめなら写真(Live Photos などは写真になる)
    private static func preferredType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if let movie = types.first(where: { $0.conforms(to: .movie) }) { return movie }
        return types.first(where: { $0.conforms(to: .image) })
    }

    private static func copyFile(from provider: NSItemProvider, type: UTType, number: Int,
                                 into folder: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            // 渡される URL は、この中でしか読めない一時ファイル。すぐにコピーする
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let suggested = provider.suggestedName ?? ""
                var base = suggested.isEmpty ? url.deletingPathExtension().lastPathComponent : suggested
                base = base.replacingOccurrences(of: "/", with: "-")
                var ext = url.pathExtension
                if ext.isEmpty {
                    ext = type.preferredFilenameExtension ?? (type.conforms(to: .movie) ? "mov" : "jpg")
                }
                if base.lowercased().hasSuffix("." + ext.lowercased()) {
                    base = String(base.dropLast(ext.count + 1))
                }
                let destination = folder.appendingPathComponent(String(format: "%03d-", number) + base + "." + ext)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 一覧に落とした動画・写真を、そのために作ったプロジェクトの編集画面へ渡す
@MainActor
enum DroppedMediaHandoff {
    private static var pending: (projectID: UUID, urls: [URL])?

    static func set(_ urls: [URL], for projectID: UUID) {
        if let old = pending { MediaDrop.remove(old.urls) }
        pending = (projectID, urls)
    }

    /// このプロジェクトに渡すものがあれば受け取る(一度だけ)
    static func take(for projectID: UUID) -> [URL]? {
        guard let item = pending, item.projectID == projectID else { return nil }
        pending = nil
        return item.urls
    }

    /// 取り込まずに閉じたときは一時ファイルを消す
    static func discard(for projectID: UUID) {
        guard let item = pending, item.projectID == projectID else { return }
        pending = nil
        MediaDrop.remove(item.urls)
    }
}

/// ドラッグ中に落とせる場所を示す枠
struct MediaDropHighlight: View {
    let title: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(BrandStyle.coral, lineWidth: 2)
            .background(BrandStyle.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
            }
            .padding(4)
            .allowsHitTesting(false)
    }
}
