import SwiftUI

// =====================================================================
// SNS の表示ガイド(セーフゾーン)。
// TikTok / Instagram Reels / YouTube Shorts に投稿したとき、右のボタン・下のキャプションと
// ユーザー名・上のタブ・下の進行バーが映像のどこに重なるかをプレビューに出す。
// プレビューだけの表示で、書き出しには影響しない。プロジェクトにも保存しない(選択は @AppStorage "safeZoneGuide")。
// 範囲はすべて 9:16 の画面に対する比率(0 ... 1、左上が原点)。
// =====================================================================

/// 投稿先の UI が重なる範囲の種類
enum SafeZoneRegionKind {
    /// 右の列(いいね・コメント・シェアなどのボタン)
    case rightColumn
    /// 下の塊(ユーザー名・キャプション・音楽名)
    case bottomBlock
    /// 上のバー(タブ・検索)
    case topBar
    /// 下のバー(進行バー・ナビゲーション)
    case bottomBar
}

/// 隠れる範囲 1 つ
struct SafeZoneRegion: Identifiable {
    let id: String
    /// 投稿先の名前(TikTok など。薄く書き込む)
    let platform: String
    let kind: SafeZoneRegionKind
    /// 9:16 の画面に対する比率の四角(左上が原点)
    let rect: CGRect
    /// ラベルを重ねないための並び順(TikTok 0 / Reels 1 / Shorts 2)
    let platformIndex: Int

    /// プレビューの大きさに合わせた四角
    func rect(in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width,
               y: rect.minY * size.height,
               width: rect.width * size.width,
               height: rect.height * size.height)
    }
}

/// 表示ガイドの選択(なし / 投稿先ごと / すべて)
enum SafeZoneGuide: String, CaseIterable, Identifiable {
    case none, tiktok, reels, shorts, all

    var id: String { rawValue }

    /// 表示名(投稿先の名前は訳さない)
    var title: String {
        switch self {
        case .none: return String(localized: "なし")
        case .tiktok: return "TikTok"
        case .reels: return "Reels"
        case .shorts: return "Shorts"
        case .all: return String(localized: "すべて")
        }
    }

    var isOn: Bool { self != SafeZoneGuide.none }

    /// 次の選択(ツールバーのボタンをタップするたびに順に切り替える)
    var next: SafeZoneGuide {
        switch self {
        case .none: return .tiktok
        case .tiktok: return .reels
        case .reels: return .shorts
        case .shorts: return .all
        case .all: return .none
        }
    }

    /// 隠れる範囲
    var regions: [SafeZoneRegion] {
        switch self {
        case .none: return []
        case .tiktok: return Self.tiktokRegions
        case .reels: return Self.reelsRegions
        case .shorts: return Self.shortsRegions
        case .all: return Self.tiktokRegions + Self.reelsRegions + Self.shortsRegions
        }
    }

    /// 隠れない範囲(上のバーの下から下の塊の上まで、右の列の左まで)。何も出さないときは nil
    var safeRect: CGRect? {
        let regions = self.regions
        guard !regions.isEmpty else { return nil }
        var right: CGFloat = 1
        var top: CGFloat = 0
        var bottom: CGFloat = 1
        for region in regions {
            switch region.kind {
            case .rightColumn: right = min(right, region.rect.minX)
            case .topBar: top = max(top, region.rect.maxY)
            case .bottomBlock, .bottomBar: bottom = min(bottom, region.rect.minY)
            }
        }
        guard right > 0, bottom > top else { return nil }
        return CGRect(x: 0, y: top, width: right, height: bottom - top)
    }

    /// 点(画面に対する比率)が隠れる範囲に入っているか
    func covers(_ point: NormalizedPoint) -> Bool {
        let p = CGPoint(x: point.x, y: point.y)
        return regions.contains { $0.rect.contains(p) }
    }

    /// 中心が隠れる範囲にあるテキスト・ステッカーの数(モザイクは数えない。キーフレームの動きは見ない)
    func hiddenTextCount(in clips: [TextClip]) -> Int {
        guard isOn else { return 0 }
        var count = 0
        for clip in clips where !clip.isMosaic && covers(clip.center) {
            count += 1
        }
        return count
    }

    /// 9:16(縦)の画面か。ガイドの範囲は 9:16 で測ったものなので、ほかの比率では出さない
    static func isPortrait9x16(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return abs(size.width / size.height - 9.0 / 16.0) < 0.02
    }

    // MARK: 範囲(9:16 に対する比率)

    private static func make(_ platform: String, index: Int, _ kind: SafeZoneRegionKind,
                             x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> SafeZoneRegion {
        SafeZoneRegion(id: "\(platform)-\(kind)", platform: platform, kind: kind,
                       rect: CGRect(x: x, y: y, width: w, height: h), platformIndex: index)
    }

    static let tiktokRegions: [SafeZoneRegion] = [
        make("TikTok", index: 0, .rightColumn, x: 0.84, y: 0.42, w: 0.16, h: 0.44),
        make("TikTok", index: 0, .bottomBlock, x: 0, y: 0.76, w: 0.84, h: 0.17),
        make("TikTok", index: 0, .topBar, x: 0, y: 0, w: 1, h: 0.08),
        make("TikTok", index: 0, .bottomBar, x: 0, y: 0.93, w: 1, h: 0.07),
    ]

    static let reelsRegions: [SafeZoneRegion] = [
        make("Reels", index: 1, .rightColumn, x: 0.86, y: 0.45, w: 0.14, h: 0.43),
        make("Reels", index: 1, .bottomBlock, x: 0, y: 0.80, w: 0.86, h: 0.15),
        make("Reels", index: 1, .topBar, x: 0, y: 0, w: 1, h: 0.07),
        make("Reels", index: 1, .bottomBar, x: 0, y: 0.95, w: 1, h: 0.05),
    ]

    static let shortsRegions: [SafeZoneRegion] = [
        make("Shorts", index: 2, .rightColumn, x: 0.85, y: 0.40, w: 0.15, h: 0.46),
        make("Shorts", index: 2, .bottomBlock, x: 0, y: 0.80, w: 0.85, h: 0.13),
        make("Shorts", index: 2, .topBar, x: 0, y: 0, w: 1, h: 0.09),
        make("Shorts", index: 2, .bottomBar, x: 0, y: 0.93, w: 1, h: 0.07),
    ]
}
