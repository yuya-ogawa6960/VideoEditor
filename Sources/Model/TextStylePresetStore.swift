import Foundation
import Observation

// =====================================================================
// テキストの「スタイル」のコピー・貼り付けと、名前を付けて保存したスタイル(マイスタイル)。
// スタイル = 文字の内容・位置・時間・トラッキングを除いた見た目
// (フォント・太字・文字サイズ・色・縁取り・影・背景・字間・行ぞろえ・デザイン・アニメーション)。
// コピーした内容はアプリを閉じるまで。保存したスタイルは Application Support/text_styles.json に残す。
// 保存形式は ProjectStore.swift の StoredTextStyle を使う。呼び出しはメインスレッドから。書き込みは裏で行う。
// 字幕(キャプション)は CaptionTemplate を使う別物なので対象外。
// =====================================================================

/// テキスト 1 つぶんのスタイル
struct TextLook: Equatable {
    var style: TextStyle
    var template: TextTemplate
    var animIn: TextAnimationType
    var animInDuration: Double
    var animOut: TextAnimationType
    var animOutDuration: Double

    init(from clip: TextClip) {
        style = clip.style
        template = clip.template
        animIn = clip.animIn
        animInDuration = clip.animInDuration
        animOut = clip.animOut
        animOutDuration = clip.animOutDuration
    }

    init(style: TextStyle, template: TextTemplate, animIn: TextAnimationType, animInDuration: Double,
         animOut: TextAnimationType, animOutDuration: Double) {
        self.style = style
        self.template = template
        self.animIn = animIn
        self.animInDuration = animInDuration
        self.animOut = animOut
        self.animOutDuration = animOutDuration
    }

    /// 文字・位置・時間・キーフレームはそのままに、見た目だけを写す
    func apply(to clip: inout TextClip) {
        clip.style = style
        clip.template = template
        clip.animIn = animIn
        clip.animInDuration = animInDuration
        clip.animOut = animOut
        clip.animOutDuration = animOutDuration
    }
}

/// 名前を付けて保存したスタイル
struct SavedTextStyle: Identifiable, Equatable {
    let id: UUID
    var name: String
    var look: TextLook
    let createdAt: Date
}

private struct StoredSavedTextStyle: Codable {
    var id: UUID
    var name: String
    var style: StoredTextStyle
    var template: String
    var animIn: String
    var animInDuration: Double
    var animOut: String
    var animOutDuration: Double
    var createdAt: Date

    init(_ s: SavedTextStyle) {
        id = s.id
        name = s.name
        style = StoredTextStyle(s.look.style)
        template = s.look.template.rawValue
        animIn = s.look.animIn.rawValue
        animInDuration = s.look.animInDuration
        animOut = s.look.animOut.rawValue
        animOutDuration = s.look.animOutDuration
        createdAt = s.createdAt
    }

    var value: SavedTextStyle {
        let look = TextLook(style: style.value,
                            template: TextTemplate(rawValue: template) ?? .plain,
                            animIn: TextAnimationType(rawValue: animIn) ?? .none,
                            animInDuration: animInDuration,
                            animOut: TextAnimationType(rawValue: animOut) ?? .none,
                            animOutDuration: animOutDuration)
        return SavedTextStyle(id: id, name: name, look: look, createdAt: createdAt)
    }
}

private struct TextStylePresetFile: Codable {
    var version = 1
    var styles: [StoredSavedTextStyle]
}

@MainActor
@Observable
final class TextStylePresetStore {
    static let shared = TextStylePresetStore()

    /// コピーしたスタイル(アプリを閉じるまで)
    private(set) var clipboard: TextLook?
    /// 保存したスタイル(保存順)
    private(set) var saved: [SavedTextStyle] = []

    private let queue = DispatchQueue(label: "TextStylePresetStore.write", qos: .utility)

    static var fileURL: URL {
        AppDirectories.applicationSupport.appendingPathComponent("text_styles.json")
    }

    private init() {
        reload()
    }

    var hasClipboard: Bool { clipboard != nil }

    // MARK: - コピー

    func copy(_ look: TextLook) {
        clipboard = look
    }

    // MARK: - 保存 / 名前の変更 / 削除

    /// 新しいスタイルとして保存する。名前が空なら「マイスタイル N」、重複すれば番号を付ける
    @discardableResult
    func save(name: String, look: TextLook) -> SavedTextStyle {
        let style = SavedTextStyle(id: UUID(), name: uniqueName(for: name, excluding: nil), look: look, createdAt: Date())
        saved.append(style)
        write()
        return style
    }

    func rename(id: UUID, to newName: String) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, saved[i].name != trimmed else { return }
        saved[i].name = uniqueName(for: trimmed, excluding: id)
        write()
    }

    func delete(id: UUID) {
        let before = saved.count
        saved.removeAll { $0.id == id }
        if saved.count != before { write() }
    }

    /// 保存ダイアログに最初から入れておく名前(「マイスタイル 1」「マイスタイル 2」…)
    var nextDefaultName: String {
        uniqueName(for: "", excluding: nil)
    }

    // MARK: - 読み込み / 書き込み

    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(TextStylePresetFile.self, from: data) else {
            saved = []
            return
        }
        saved = file.styles.map { $0.value }
    }

    private func write() {
        let file = TextStylePresetFile(styles: saved.map { StoredSavedTextStyle($0) })
        let url = Self.fileURL
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
            } catch {
                print("TextStylePresetStore: write failed: \(error)")
            }
        }
    }

    // MARK: - 名前

    private func uniqueName(for name: String, excluding id: UUID?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(saved.filter { $0.id != id }.map { $0.name })
        var base = trimmed
        if base.isEmpty {
            var n = saved.count + 1
            base = String(localized: "マイスタイル \(n)")
            while existing.contains(base) {
                n += 1
                base = String(localized: "マイスタイル \(n)")
            }
            return base
        }
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") {
            n += 1
        }
        return "\(base) \(n)"
    }
}
