import Foundation
import AVFoundation
import UIKit
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - エラー

enum MediaStoreError: LocalizedError {
    case noVideoTrack(String)
    case invalidDuration(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let name):
            return "「\(name)」には映像トラックがありません。動画ファイルを選んでください。"
        case .invalidDuration(let name):
            return "「\(name)」の長さを読み取れませんでした。"
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
        var name = url.deletingPathExtension().lastPathComponent
        // 先頭の "UUID(36文字)_" を取り除く
        if name.count > 37 {
            let prefix = String(name.prefix(36))
            let separatorIndex = name.index(name.startIndex, offsetBy: 36)
            if UUID(uuidString: prefix) != nil, name[separatorIndex] == "_" {
                name = String(name[name.index(after: separatorIndex)...])
            }
        }
        return name.isEmpty ? "動画" : name
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
