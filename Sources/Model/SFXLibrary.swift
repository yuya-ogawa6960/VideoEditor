import Foundation

// =====================================================================
// 同梱の効果音(SFXCatalog)のファイルを探す。
// ファイルはアプリに入れてある Resources/SFX/se_<id>.m4a(書き出しやコピーはしない)。
// タイムラインにはナレーション(NarrationClip)として置き、保存データにはファイル名(se_<id>.m4a)だけが残る。
// アプリを更新すると置き場所が変わるので、開き直すときは SoundEffectLibrary.generatedURL(fileName:) が名前から探し直す。
// =====================================================================

enum SFXLibrary {
    static let filePrefix = "se_"

    static func fileName(for id: String) -> String {
        "\(filePrefix)\(id).m4a"
    }

    /// 同梱の効果音のファイル名か
    static func isBundledName(_ fileName: String) -> Bool {
        fileName.hasPrefix(filePrefix) && fileName.hasSuffix(".m4a") && fileName.count > filePrefix.count + 4
    }

    /// 効果音のファイル(アプリに入っていなければ nil)
    static func url(for item: SFXItem) -> URL? {
        url(forFileName: fileName(for: item.id))
    }

    /// 保存データのファイル名 → アプリに入っているファイル(なければ nil)
    static func url(forFileName fileName: String) -> URL? {
        guard isBundledName(fileName) else { return nil }
        let base = String(fileName.dropLast(4))
        return Bundle.main.url(forResource: base, withExtension: "m4a")
            ?? Bundle.main.url(forResource: base, withExtension: "m4a", subdirectory: "SFX")
    }

    /// ファイルがアプリに入っている効果音だけ(最初に一度だけ調べる)
    static let available: [SFXItem] = SFXCatalog.all.filter { url(for: $0) != nil }

    static func items(in category: SFXCategory) -> [SFXItem] {
        available.filter { $0.category == category }
    }

    /// 名前で探す(表示中の言語の名前と日本語の名前の両方。ひらがな・カタカナ、大文字・小文字、全角・半角は区別しない)
    static func search(_ text: String) -> [SFXItem] {
        let query = normalized(text)
        guard !query.isEmpty else { return [] }
        return available.filter { item in
            normalized(item.name).contains(query) || normalized(item.nameKey).contains(query)
        }
    }

    private static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}
