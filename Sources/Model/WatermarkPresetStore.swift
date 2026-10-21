import Foundation
import UIKit
import Observation

// =====================================================================
// 自分用のロゴ・透かし(最大 5 件)。何度も画像を探さなくて済むように、アプリ全体で持つ。
// 画像は Application Support/WatermarkPresets にコピーして保持し、使うときに Media フォルダへ
// コピーする(プロジェクトの保存・書き出しは Media フォルダの中のファイルしか扱わないため)。
// =====================================================================

@Observable
final class WatermarkPresetStore {
    static let shared = WatermarkPresetStore()
    static let maxCount = 5

    struct Preset: Codable, Identifiable, Equatable {
        var id = UUID()
        /// WatermarkPresets フォルダ内のファイル名(画像がないときは nil)
        var imageFile: String?
        var text: String
        var corner: String
        var opacity: Double
        var sizeRatio: Double
        var createdAt = Date()
    }

    private(set) var presets: [Preset] = []
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    @ObservationIgnored private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("WatermarkPresets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    var isFull: Bool { presets.count >= Self.maxCount }

    private var indexURL: URL { directory.appendingPathComponent("presets.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data) else { return }
        presets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func imageURL(of preset: Preset) -> URL? {
        guard let file = preset.imageFile else { return nil }
        let url = directory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnail(of preset: Preset) -> UIImage? {
        if let cached = thumbnails[preset.id] { return cached }
        guard let url = imageURL(of: preset),
              let image = MediaStore.makeImageClipThumbnail(url: url, maxPixel: 160) else { return nil }
        thumbnails[preset.id] = image
        return image
    }

    /// いまの設定を保存する(画像はコピー)。5 件あるときは保存しない
    @discardableResult
    func save(_ settings: WatermarkSettings) -> Preset? {
        guard !isFull else { return nil }
        var preset = Preset(imageFile: nil, text: settings.text, corner: settings.corner.rawValue,
                            opacity: settings.opacity, sizeRatio: settings.sizeRatio)
        if let source = settings.imageURL {
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let file = "\(preset.id.uuidString).\(ext)"
            let destination = directory.appendingPathComponent(file)
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                preset.imageFile = file
            }
        }
        presets.append(preset)
        persist()
        return preset
    }

    func remove(_ preset: Preset) {
        if let url = imageURL(of: preset) {
            try? FileManager.default.removeItem(at: url)
        }
        thumbnails[preset.id] = nil
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    /// 保存したロゴをプロジェクトで使う形にする(画像は Media フォルダへコピーし、オンにして返す)
    func settings(from preset: Preset) -> WatermarkSettings {
        var w = WatermarkSettings()
        w.enabled = true
        w.text = preset.text
        w.corner = WatermarkCorner(rawValue: preset.corner) ?? .bottomRight
        w.opacity = preset.opacity
        w.sizeRatio = preset.sizeRatio
        if let source = imageURL(of: preset) {
            let destination = MediaStore.uniqueDestination(forFileName: "watermark." + source.pathExtension)
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                w.imageURL = destination
            }
        }
        return w
    }
}
