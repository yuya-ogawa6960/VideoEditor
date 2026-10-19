import Foundation
import CoreGraphics

/// 書き出しに必要な空き容量の見積もり結果
struct StorageEstimate {
    let estimatedOutputBytes: Int64
    /// 出力 + 作業用マージン
    let requiredBytes: Int64
    let availableBytes: Int64

    var canExport: Bool { availableBytes >= requiredBytes }
    var shortfallBytes: Int64 { max(0, requiredBytes - availableBytes) }
}

enum StorageEstimator {
    /// AAC 音声ビットレート(bps)
    static let audioBitrate: Int = 192_000
    /// 作業用の安全マージン(200 MB)
    static let safetyMarginBytes: Int64 = 200 * 1024 * 1024

    /// 端末の空き容量(重要な用途向けに利用可能な容量)
    static func availableBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return Int64(capacity)
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    /// 書き出しサイズ(短辺 2160 以上なら HEVC)
    static func exportRenderSize(for snapshot: ProjectSnapshot) -> CGSize {
        CompositionBuilder.renderSize(for: snapshot, purpose: .export)
    }

    /// 短辺が 2160 以上(4K)なら HEVC で書き出す
    static func usesHEVC(for snapshot: ProjectSnapshot) -> Bool {
        let size = exportRenderSize(for: snapshot)
        return min(size.width, size.height) >= 2159.5
    }

    /// 映像ビットレート(bps)。画質設定の 1080p 基準値を書き出し画素数に比例させて換算する。
    static func videoBitrate(for snapshot: ProjectSnapshot) -> Int {
        let size = exportRenderSize(for: snapshot)
        let pixels = max(1, Double(size.width) * Double(size.height))
        let reference = 1920.0 * 1080.0
        var bitrate = snapshot.canvas.quality.videoBitrateAt1080p * (pixels / reference)
        bitrate = min(max(bitrate, 1_000_000), 120_000_000)
        if usesHEVC(for: snapshot) {
            bitrate *= 0.7
        }
        return Int(bitrate.rounded())
    }

    static func estimate(for snapshot: ProjectSnapshot) -> StorageEstimate {
        let duration = max(0, snapshot.totalDuration)
        let totalBitrate = Double(videoBitrate(for: snapshot) + audioBitrate)
        let estimated = totalBitrate * duration / 8.0 * 1.05
        let estimatedBytes = Int64(estimated.rounded(.up))
        let required = Int64((Double(estimatedBytes) * 1.2).rounded(.up)) + safetyMarginBytes
        return StorageEstimate(estimatedOutputBytes: estimatedBytes,
                               requiredBytes: required,
                               availableBytes: availableBytes())
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
