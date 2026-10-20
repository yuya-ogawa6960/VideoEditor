import Foundation
import CoreText

// =====================================================================
// アプリに同梱しているフォント(Google Fonts の SIL Open Font License / Apache License 2.0 のもの)。
// ファイルは Sources/Resources/Fonts。ライセンス文は同じフォルダの OFL.txt / LICENSE-APACHE.txt。
// 起動時に registerAll() でこのアプリ内だけに登録する。
// =====================================================================

enum BundledFonts {
    struct Entry {
        /// PostScript 名(UIFont(name:) で使う名前)
        let name: String
        let label: String
    }

    /// 日本語(かわいい・ポップ・手書き)
    static let japanese: [Entry] = [
        Entry(name: "HachiMaruPop-Regular", label: "はちまるポップ"),
        Entry(name: "YuseiMagic-Regular", label: "油性マジック"),
        Entry(name: "MochiyPopOne-Regular", label: "もっちりポップ"),
        Entry(name: "KiwiMaru-Medium", label: "キウイ丸"),
        Entry(name: "ZenMaruGothic-Bold", label: "Zen丸ゴシック"),
        Entry(name: "RoundedMplus1c-Bold", label: "M PLUS Rounded"),
        Entry(name: "KosugiMaru-Regular", label: "小杉丸ゴシック"),
        Entry(name: "Yomogi-Regular", label: "よもぎ(手書き)"),
        Entry(name: "KleeOne-SemiBold", label: "クレー(手書き)"),
        Entry(name: "ZenKurenaido-Regular", label: "Zen紅道(筆)"),
        Entry(name: "PottaOne-Regular", label: "ポッタ(筆ポップ)"),
        Entry(name: "RocknRollOne-Regular", label: "ロックンロール"),
        Entry(name: "DelaGothicOne-Regular", label: "デラゴシック(極太)"),
        Entry(name: "DotGothic16-Regular", label: "ドットゴシック")
    ]

    /// 英語(かわいい・丸い・手書き)
    static let english: [Entry] = [
        Entry(name: "Pacifico-Regular", label: "Pacifico"),
        Entry(name: "Fredoka-SemiBold", label: "Fredoka"),
        Entry(name: "Baloo2-Bold", label: "Baloo 2"),
        Entry(name: "Quicksand-Bold", label: "Quicksand"),
        Entry(name: "Comfortaa-Bold", label: "Comfortaa"),
        Entry(name: "Sniglet-ExtraBold", label: "Sniglet"),
        Entry(name: "Chewy-Regular", label: "Chewy"),
        Entry(name: "BubblegumSans-Regular", label: "Bubblegum Sans"),
        Entry(name: "Lobster-Regular", label: "Lobster"),
        Entry(name: "Caveat-Bold", label: "Caveat"),
        Entry(name: "PatrickHand-Regular", label: "Patrick Hand"),
        Entry(name: "GochiHand-Regular", label: "Gochi Hand"),
        Entry(name: "IndieFlower-Regular", label: "Indie Flower"),
        Entry(name: "AmaticSC-Bold", label: "Amatic SC")
    ]

    static var all: [Entry] { japanese + english }

    private static let lock = NSLock()
    private static var registered = false

    /// 同梱フォントをこのアプリ内に登録する(何度呼んでも 1 回だけ)
    static func registerAll() {
        lock.lock()
        if registered {
            lock.unlock()
            return
        }
        registered = true
        lock.unlock()
        let urls: [URL] = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
