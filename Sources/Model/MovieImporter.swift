import Foundation
import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// =====================================================================
// 写真アプリからの動画の取り込みを、失敗しにくくする。
//
// 実機で「Cannot import PickedMovie ... contains no compatible representations」
// が出た。スローモーション・シネマティック・iCloud にしかない動画などは、
// .movie の FileRepresentation だけでは受け取れないことがあるため、次の順に試す。
//   1. いくつかの動画形式で Transferable として受け取る
//   2. 写真ライブラリから PHAsset として取り出す(iCloud からのダウンロード込み)
//      スローモーションなど複数の素材でできた動画は 1 本の .mov に書き出す
// =====================================================================

/// .movie 以外の形式でも受け取れる動画
struct PickedAnyMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .quickTimeMovie) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mov"))
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mp4"))
        }
        FileRepresentation(importedContentType: .video) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mov"))
        }
        FileRepresentation(importedContentType: .audiovisualContent) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mov"))
        }
    }
}

enum MovieImporterError: LocalizedError {
    case unsupported
    case noLibraryAccess
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "この動画は読み込めませんでした。写真アプリで動画を開き、iCloud から本体にダウンロードしてからもう一度お試しください。")
        case .noLibraryAccess:
            return String(localized: "写真ライブラリへのアクセスが許可されていません。設定アプリの「Video Mania」→「写真」で「フルアクセス」を選んでください。")
        case .exportFailed(let detail):
            return String(localized: "動画の変換に失敗しました(\(detail))。")
        }
    }
}

enum MovieImporter {

    /// 受け取った一時ファイルをアプリ内の素材フォルダへコピーする
    static func copyIntoMedia(_ file: URL, fallbackExtension: String) throws -> URL {
        var name = file.lastPathComponent
        if (name as NSString).pathExtension.isEmpty {
            name += "." + fallbackExtension
        }
        let destination = MediaStore.uniqueDestination(forFileName: name)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// PhotosPickerItem から動画を取り出し、アプリ内の素材フォルダの URL を返す
    static func importMovie(_ item: PhotosPickerItem) async throws -> URL {
        // 1. 既存の形式
        if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
            return movie.url
        }
        // 2. ほかの動画形式
        if let movie = try? await item.loadTransferable(type: PickedAnyMovie.self) {
            return movie.url
        }
        // 3. 写真ライブラリから直接
        if let identifier = item.itemIdentifier {
            return try await importFromLibrary(localIdentifier: identifier)
        }
        throw MovieImporterError.unsupported
    }

    // MARK: - 写真ライブラリから

    private static func importFromLibrary(localIdentifier: String) async throws -> URL {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw MovieImporterError.noLibraryAccess
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject, asset.mediaType == .video else {
            throw MovieImporterError.unsupported
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? MovieImporterError.unsupported)
                }
            }
        }

        // 普通の動画ファイルならそのままコピー
        if let urlAsset = avAsset as? AVURLAsset {
            return try copyIntoMedia(urlAsset.url, fallbackExtension: "mov")
        }

        // スローモーションなど(AVComposition)は 1 本の .mov に書き出す
        let baseName = "Imported_\(UUID().uuidString.prefix(8)).mov"
        let destination = MediaStore.uniqueDestination(forFileName: baseName)
        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MovieImporterError.exportFailed(String(localized: "書き出しを開始できません"))
        }
        do {
            try await session.export(to: destination, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw MovieImporterError.exportFailed(error.localizedDescription)
        }
        return destination
    }
}
