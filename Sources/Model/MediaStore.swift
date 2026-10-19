import Foundation
import AVFoundation
import UIKit
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO

// MARK: - エラー

enum MediaStoreError: LocalizedError {
    case noVideoTrack(String)
    case invalidDuration(String)
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let name):
            return "「\(name)」には映像トラックがありません。動画ファイルを選んでください。"
        case .invalidDuration(let name):
            return "「\(name)」の長さを読み取れませんでした。"
        case .unreadableImage(let name):
            return "「\(name)」を画像として読み込めませんでした。JPEG / PNG / HEIC などの写真を選んでください。"
        }
    }
}

// MARK: - 素材の保存・読み込み

enum MediaStore {
    /// Documents/Media(必要に応じて作成)
    static var mediaDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// mediaDirectory 内の重複しない保存先(UUID_元の名前)
    static func uniqueDestination(forFileName fileName: String) -> URL {
        let name = fileName.isEmpty ? "media.mov" : fileName
        return mediaDirectory.appendingPathComponent("\(UUID().uuidString)_\(name)")
    }

    /// 外部ファイル(セキュリティスコープ付きでも可)を mediaDirectory にコピー
    static func importExternalFile(_ url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let destination = uniqueDestination(forFileName: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// 一時ファイルなど(スコープ不要)を mediaDirectory にコピー
    static func copyIntoMediaDirectory(_ url: URL) throws -> URL {
        let destination = uniqueDestination(forFileName: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// 保存名から UUID 接頭辞と拡張子を除いた表示名
    static func displayName(for url: URL) -> String {
        displayName(for: url, fallback: "動画")
    }

    /// 保存名から UUID 接頭辞と拡張子を除いた表示名(空のときは fallback)
    static func displayName(for url: URL, fallback: String) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        // 先頭の "UUID(36文字)_" を取り除く
        if name.count > 37 {
            let prefix = String(name.prefix(36))
            let separatorIndex = name.index(name.startIndex, offsetBy: 36)
            if UUID(uuidString: prefix) != nil, name[separatorIndex] == "_" {
                name = String(name[name.index(after: separatorIndex)...])
            }
        }
        return name.isEmpty ? fallback : name
    }

    /// 拡張子から画像ファイルかどうかを判定(jpg / png / heic など)
    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private struct MediaStoreAssetInfo {
        let duration: Double
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let hasAudio: Bool
    }

    private static func loadInfo(for url: URL) async throws -> MediaStoreAssetInfo {
        let asset = AVURLAsset(url: url)
        let name = displayName(for: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaStoreError.noVideoTrack(name)
        }
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw MediaStoreError.invalidDuration(name)
        }
        return MediaStoreAssetInfo(duration: seconds,
                                   naturalSize: naturalSize,
                                   preferredTransform: transform,
                                   hasAudio: !audioTracks.isEmpty)
    }

    static func makeClip(from url: URL) async throws -> Clip {
        let info = try await loadInfo(for: url)
        let thumb = await thumbnail(for: url, at: min(0.1, info.duration / 2), maxPixel: 320)
        return Clip(url: url,
                    duration: info.duration,
                    naturalSize: info.naturalSize,
                    preferredTransform: info.preferredTransform,
                    hasAudio: info.hasAudio,
                    thumbnail: thumb,
                    name: displayName(for: url))
    }

    static func makeAngle(from url: URL) async throws -> CameraAngle {
        let info = try await loadInfo(for: url)
        let thumb = await thumbnail(for: url, at: min(0.1, info.duration / 2), maxPixel: 320)
        return CameraAngle(url: url,
                           duration: info.duration,
                           naturalSize: info.naturalSize,
                           preferredTransform: info.preferredTransform,
                           thumbnail: thumb,
                           name: displayName(for: url),
                           offset: 0)
    }

    static func thumbnail(for url: URL, at seconds: Double, maxPixel: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        do {
            let result = try await generator.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }

    // MARK: - オーバーレイ(Bロール / ワイプ / 写真)

    /// 写真オーバーレイの標準の長さ(秒)
    static let defaultImageOverlayDuration: Double = 4
    /// 写真の「素材の長さ」として使う十分大きい値(秒)
    static let imageSourceDuration: Double = 3600

    /// 動画ファイルからオーバーレイを作る(mediaDirectory 内のファイルを想定)
    static func makeOverlay(fromVideo url: URL) async throws -> OverlayClip {
        let info = try await loadInfo(for: url)
        var overlay = OverlayClip(url: url,
                                  isImage: false,
                                  name: displayName(for: url),
                                  naturalSize: info.naturalSize,
                                  preferredTransform: info.preferredTransform,
                                  sourceDuration: info.duration,
                                  start: 0,
                                  duration: info.duration)
        overlay.volume = 0
        return overlay
    }

    /// 画像ファイルからオーバーレイを作る。読めない場合は nil
    static func makeOverlay(fromImage url: URL) -> OverlayClip? {
        guard let size = imagePixelSize(of: url) else { return nil }
        var overlay = OverlayClip(url: url,
                                  isImage: true,
                                  name: displayName(for: url, fallback: "写真"),
                                  naturalSize: size,
                                  preferredTransform: .identity,
                                  sourceDuration: imageSourceDuration,
                                  start: 0,
                                  duration: defaultImageOverlayDuration)
        overlay.speed = 1
        overlay.volume = 0
        return overlay
    }

    /// makeOverlay(fromImage:) の throws 版(読めない場合は日本語のエラー)
    static func makeImageOverlay(from url: URL) throws -> OverlayClip {
        guard let overlay = makeOverlay(fromImage: url) else {
            throw MediaStoreError.unreadableImage(displayName(for: url, fallback: "写真"))
        }
        return overlay
    }

    /// 画像の表示上のピクセルサイズ(EXIF の向きを反映)。読めない場合は nil
    static func imagePixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // 5...8 は 90 度回転(幅と高さが入れ替わる)
        if orientation >= 5 && orientation <= 8 {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// 画像のサムネイル(向きを反映、長辺 maxPixel 以下に縮小)。読めない場合は nil
    static func makeImageClipThumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let maxSize = Int(max(1, maxPixel.rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 画像を長辺 maxPixel 以下に縮小して読み込む(コンポジタ用。向きを反映済み)
    static func loadImage(url: URL, maxPixel: CGFloat) -> CGImage? {
        makeImageClipThumbnail(url: url, maxPixel: maxPixel)?.cgImage
    }
}

// MARK: - PhotosPicker からの受け取り

/// PhotosPicker の動画を受け取る(受け取った一時ファイルを mediaDirectory にコピー)
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copied = try MediaStore.copyIntoMediaDirectory(received.file)
            return PickedMovie(url: copied)
        }
    }
}

/// PhotosPicker の写真を受け取る(受け取ったファイルを元の拡張子のまま mediaDirectory にコピー)
///
/// ファイルとして受け取れない場合は Data として受け取り jpg として保存する。
struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { photo in
            SentTransferredFile(photo.url)
        } importing: { received in
            let copied = try PickedPhoto.copyIntoMediaDirectory(received.file)
            return PickedPhoto(url: copied)
        }
        DataRepresentation(importedContentType: .image) { data in
            let written = try PickedPhoto.writeData(data, preferredExtension: "jpg")
            return PickedPhoto(url: written)
        }
    }

    /// 元の拡張子を保ってコピー(拡張子がない場合は jpg)
    private static func copyIntoMediaDirectory(_ file: URL) throws -> URL {
        let ext = file.pathExtension.isEmpty ? "jpg" : file.pathExtension
        var baseName = file.deletingPathExtension().lastPathComponent
        if baseName.isEmpty { baseName = "photo" }
        let destination = MediaStore.uniqueDestination(forFileName: "\(baseName).\(ext)")
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Data を mediaDirectory に書き出す
    private static func writeData(_ data: Data, preferredExtension: String) throws -> URL {
        let destination = MediaStore.uniqueDestination(forFileName: "photo.\(preferredExtension)")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

// MARK: - 時刻表示

enum MediaTimeText {
    /// mm:ss
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// m:ss.ss
    static func precise(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let s = max(0, seconds)
        let minutes = Int(s / 60)
        let rest = s - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    /// 短い秒数表示(例: 3.2秒)
    static func shortSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0秒" }
        if seconds >= 60 { return mmss(seconds) }
        return String(format: "%.1f秒", max(0, seconds))
    }
}
