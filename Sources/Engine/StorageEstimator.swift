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
    /// AAC 音声ビットレートの既定値(bps)。プロジェクトごとの値は audioBitrate(for:)
    static let audioBitrate: Int = 192_000
    /// 手動ビットレートの範囲(Mbps)
    static let manualBitrateRangeMbps: ClosedRange<Double> = 1...200
    /// 音声ビットレートの範囲(kbps)
    static let audioBitrateRangeKbps: ClosedRange<Int> = 32...320
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

    /// 書き出しサイズ
    static func exportRenderSize(for snapshot: ProjectSnapshot) -> CGSize {
        CompositionBuilder.renderSize(for: snapshot, purpose: .export)
    }

    /// 実際に使うコーデック(.auto は短辺 2160 以上なら HEVC、それ以外は H.264)
    static func resolvedCodec(for snapshot: ProjectSnapshot) -> ExportCodec {
        switch snapshot.canvas.codec {
        case .h264:
            return .h264
        case .hevc:
            return .hevc
        case .auto:
            let size = exportRenderSize(for: snapshot)
            return min(size.width, size.height) >= 2159.5 ? .hevc : .h264
        }
    }

    /// HEVC で書き出すか(canvas.codec を反映)
    static func usesHEVC(for snapshot: ProjectSnapshot) -> Bool {
        resolvedCodec(for: snapshot) == .hevc
    }

    /// 映像ビットレート(bps)。canvas.bitrateMbps があればそれを 1...200 Mbps に収めて使う。
    /// なければ画質設定の 1080p 基準値を書き出し画素数に比例させて換算する。
    static func videoBitrate(for snapshot: ProjectSnapshot) -> Int {
        if let manual = snapshot.canvas.bitrateMbps, manual.isFinite, manual > 0 {
            let mbps = min(max(manual, manualBitrateRangeMbps.lowerBound), manualBitrateRangeMbps.upperBound)
            return Int((mbps * 1_000_000).rounded())
        }
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

    /// 音声ビットレート(bps)。canvas.audioBitrateKbps を 32...320 kbps に収める
    static func audioBitrate(for snapshot: ProjectSnapshot) -> Int {
        let kbps = min(max(snapshot.canvas.audioBitrateKbps, audioBitrateRangeKbps.lowerBound),
                       audioBitrateRangeKbps.upperBound)
        return kbps * 1000
    }

    /// 出力ファイルの拡張子("mp4" / "mov")
    static func fileExtension(for snapshot: ProjectSnapshot) -> String {
        snapshot.canvas.fileFormat.rawValue
    }

    static func estimate(for snapshot: ProjectSnapshot) -> StorageEstimate {
        let duration = max(0, snapshot.totalDuration)
        let totalBitrate = Double(videoBitrate(for: snapshot) + audioBitrate(for: snapshot))
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
