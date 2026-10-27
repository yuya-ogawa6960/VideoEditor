import Foundation
import Observation

// =====================================================================
// 書き出しプリセット(ユーザー保存)。Documents/presets.json に保存する。
// 組み込みプリセット(builtIns)はファイルには保存しない。書き出し画面のチップには出さない(画質は書き出し画面のタイルで選ぶ)。
// プリセットは画質まわりだけを変え、比率と収め方(aspect / scaling)は上書きしない(比率は編集画面と新規作成で決める)。
// 保存形式は ProjectStore.swift の StoredCanvas / StoredSubtitleStyle / StoredDocumentary を使う。
// 呼び出しはメインスレッドから(@Observable の更新のため)。書き込みは裏で行う。
// =====================================================================

private struct StoredPreset: Codable {
    var id: UUID
    var name: String
    var canvas: StoredCanvas
    var subtitleStyle: StoredSubtitleStyle?
    var documentary: StoredDocumentary?

    init(_ p: ExportPreset) {
        id = p.id
        name = p.name
        canvas = StoredCanvas(p.canvas)
        subtitleStyle = p.subtitleStyle.map { StoredSubtitleStyle($0) }
        documentary = p.documentary.map { StoredDocumentary($0) }
    }

    var value: ExportPreset {
        ExportPreset(id: id, name: name, canvas: canvas.value,
                     subtitleStyle: subtitleStyle?.value,
                     documentary: documentary?.value)
    }
}

private struct PresetFile: Codable {
    var version = 1
    var presets: [StoredPreset]
}

@Observable
final class PresetStore {
    static let shared = PresetStore()

    /// ユーザーが保存したプリセット(保存順)。組み込みは含まない
    private(set) var presets: [ExportPreset] = []

    private let queue = DispatchQueue(label: "PresetStore.write", qos: .utility)

    static var fileURL: URL {
        let docs = StorageLocations.applicationSupport
        return docs.appendingPathComponent("presets.json")
    }

    private init() {
        reload()
    }

    // MARK: - 組み込みプリセット

    private static func makeBuiltIn(id: String, name: String, aspect: CanvasAspect, scaling: ScalingMode,
                                    resolution: ResolutionCap, quality: ExportQuality, frameRate: Int) -> ExportPreset {
        var canvas = CanvasSettings()
        canvas.aspect = aspect
        canvas.scaling = scaling
        canvas.resolution = resolution
        canvas.quality = quality
        canvas.frameRate = frameRate
        return ExportPreset(id: UUID(uuidString: id) ?? UUID(), name: name, canvas: canvas,
                            subtitleStyle: nil, documentary: nil)
    }

    /// 組み込みプリセット(ID は固定)
    static let builtIns: [ExportPreset] = [
        makeBuiltIn(id: "B1A7C2E0-0001-4000-8000-000000000001", name: "YouTube 4K30",
                    aspect: .landscape16x9, scaling: .fit, resolution: .uhd4k, quality: .high, frameRate: 30),
        makeBuiltIn(id: "B1A7C2E0-0001-4000-8000-000000000002", name: String(localized: "ショート 9:16 1080p30"),
                    aspect: .portrait9x16, scaling: .fitBlur, resolution: .fhd1080, quality: .high, frameRate: 30),
        makeBuiltIn(id: "B1A7C2E0-0001-4000-8000-000000000003", name: "Instagram 4:5",
                    aspect: .portrait4x5, scaling: .fitBlur, resolution: .fhd1080, quality: .standard, frameRate: 30),
        makeBuiltIn(id: "B1A7C2E0-0001-4000-8000-000000000004", name: String(localized: "長尺 高画質"),
                    aspect: .original, scaling: .fit, resolution: .uhd4k, quality: .high, frameRate: 30)
    ]

    /// 組み込み + ユーザー保存(表示用)
    var allPresets: [ExportPreset] { Self.builtIns + presets }

    func isBuiltIn(_ preset: ExportPreset) -> Bool { isBuiltIn(id: preset.id) }

    func isBuiltIn(id: UUID) -> Bool { Self.builtIns.contains { $0.id == id } }

    func preset(id: UUID) -> ExportPreset? {
        allPresets.first { $0.id == id }
    }

    // MARK: - 保存 / 変更 / 削除

    /// 現在の設定を新しいプリセットとして保存する。名前が空なら「プリセット N」、重複すれば番号を付ける
    @discardableResult
    func save(name: String, canvas: CanvasSettings, subtitleStyle: SubtitleStyle?, documentary: DocumentaryStyle?) -> ExportPreset {
        let preset = ExportPreset(id: UUID(), name: uniqueName(for: name, excluding: nil), canvas: canvas,
                                  subtitleStyle: subtitleStyle, documentary: documentary)
        presets.append(preset)
        write()
        return preset
    }

    /// ユーザー保存プリセットの名前を変える(組み込みは変更不可)
    func rename(id: UUID, to newName: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, presets[i].name != trimmed else { return }
        presets[i].name = uniqueName(for: trimmed, excluding: id)
        write()
    }

    func rename(_ preset: ExportPreset, to newName: String) {
        rename(id: preset.id, to: newName)
    }

    /// ユーザー保存プリセットを削除する(組み込みは削除不可)
    func delete(id: UUID) {
        let before = presets.count
        presets.removeAll { $0.id == id }
        if presets.count != before { write() }
    }

    func delete(_ preset: ExportPreset) {
        delete(id: preset.id)
    }

    /// ユーザー保存プリセットの内容を置き換える(同じ ID のもの。組み込みは変更不可)
    func update(_ preset: ExportPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var p = preset
        p.name = uniqueName(for: p.name, excluding: p.id)
        presets[i] = p
        write()
    }

    /// プリセットの内容をプロジェクトに反映する(比率と収め方はプロジェクトのまま。字幕スタイル・演出は含まれているときだけ)
    func apply(_ preset: ExportPreset, to project: EditorProject) {
        project.canvas = Self.keepingLayout(preset.canvas, of: project.canvas)
        if let style = preset.subtitleStyle {
            project.subtitleStyle = style
        }
        if let documentary = preset.documentary {
            project.documentary = documentary
        }
    }

    /// 出力設定がこのプリセットと一致しているか(選択表示用。比率と収め方は比べない)
    func matches(_ preset: ExportPreset, canvas: CanvasSettings) -> Bool {
        Self.keepingLayout(preset.canvas, of: canvas) == canvas
    }

    /// preset の設定に、current の比率と収め方を残したもの
    static func keepingLayout(_ preset: CanvasSettings, of current: CanvasSettings) -> CanvasSettings {
        var c = preset
        c.aspect = current.aspect
        c.scaling = current.scaling
        return c
    }

    // MARK: - 読み込み / 書き込み

    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(PresetFile.self, from: data) else {
            presets = []
            return
        }
        presets = file.presets.map { $0.value }
    }

    private func write() {
        let file = PresetFile(presets: presets.map { StoredPreset($0) })
        let url = Self.fileURL
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
            } catch {
                print("PresetStore: write failed: \(error)")
            }
        }
    }

    // MARK: - 名前

    private func uniqueName(for name: String, excluding id: UUID?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(allPresets.filter { $0.id != id }.map { $0.name })
        var base = trimmed
        if base.isEmpty {
            var n = presets.count + 1
            base = String(localized: "プリセット \(n)")
            while existing.contains(base) {
                n += 1
                base = String(localized: "プリセット \(n)")
            }
            return base
        }
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
