import Foundation
import SwiftUI

// =====================================================================
// 映像エフェクト(CapCut の「エフェクト」)。
// タイムライン上に開始・長さを持つ部品として置き、その間の画面全体
// (メイン映像 + オーバーレイ。テキスト・キャプションより下)にかける。
// 描画は Engine/VideoEffectRenderer.swift、パネルは Views/VideoEffectPanel.swift。
// =====================================================================

/// エフェクトの分類(選ぶ画面の見出し)
enum VideoEffectCategory: String, CaseIterable, Identifiable {
    case motion, retro, light, blur, color, screen
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .motion: return String(localized: "動き")
        case .retro: return String(localized: "レトロ")
        case .light: return String(localized: "光")
        case .blur: return String(localized: "ぼかし")
        case .color: return String(localized: "色")
        case .screen: return String(localized: "画面")
        }
    }

    var types: [VideoEffectType] {
        VideoEffectType.allCases.filter { $0.category == self }
    }
}

/// エフェクトの種類(rawValue は保存に使うので変えない)
enum VideoEffectType: String, CaseIterable, Identifiable {
    case shake
    case zoomPulse
    case beatShake
    case vhs
    case rgbSplit
    case noise
    case filmScratch
    case lightLeak
    case lensFlare
    case sparkles
    case blur
    case zoomBlur
    case motionBlur
    case neonGlow
    case monoToColor
    case strobe
    case vignette
    case fisheye
    case mirror
    case split2
    case split4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shake: return String(localized: "揺れ")
        case .zoomPulse: return String(localized: "ズームパルス")
        case .beatShake: return String(localized: "ビート揺れ")
        case .vhs: return String(localized: "VHS")
        case .rgbSplit: return String(localized: "グリッチ")
        case .noise: return String(localized: "ノイズ")
        case .filmScratch: return String(localized: "フィルム傷")
        case .lightLeak: return String(localized: "光漏れ")
        case .lensFlare: return String(localized: "レンズフレア")
        case .sparkles: return String(localized: "キラキラ")
        case .blur: return String(localized: "ぼかし")
        case .zoomBlur: return String(localized: "ズームブラー")
        case .motionBlur: return String(localized: "モーションブラー")
        case .neonGlow: return String(localized: "ネオン")
        case .monoToColor: return String(localized: "白黒→カラー")
        case .strobe: return String(localized: "ストロボ")
        case .vignette: return String(localized: "ビネット")
        case .fisheye: return String(localized: "魚眼")
        case .mirror: return String(localized: "ミラー")
        case .split2: return String(localized: "2分割")
        case .split4: return String(localized: "4分割")
        }
    }

    var systemImage: String {
        switch self {
        case .shake: return "iphone.radiowaves.left.and.right"
        case .zoomPulse: return "plus.magnifyingglass"
        case .beatShake: return "waveform.path"
        case .vhs: return "tv"
        case .rgbSplit: return "square.stack.3d.forward.dottedline"
        case .noise: return "circle.dotted"
        case .filmScratch: return "film"
        case .lightLeak: return "sun.haze"
        case .lensFlare: return "sun.max"
        case .sparkles: return "sparkles"
        case .blur: return "drop"
        case .zoomBlur: return "scope"
        case .motionBlur: return "wind"
        case .neonGlow: return "lightbulb.max"
        case .monoToColor: return "circle.lefthalf.filled"
        case .strobe: return "bolt"
        case .vignette: return "circle.dashed"
        case .fisheye: return "eye"
        case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .split2: return "rectangle.split.1x2"
        case .split4: return "rectangle.split.2x2"
        }
    }

    var category: VideoEffectCategory {
        switch self {
        case .shake, .zoomPulse, .beatShake, .fisheye: return .motion
        case .vhs, .rgbSplit, .noise, .filmScratch: return .retro
        case .lightLeak, .lensFlare, .sparkles, .neonGlow, .strobe: return .light
        case .blur, .zoomBlur, .motionBlur: return .blur
        case .monoToColor, .vignette: return .color
        case .mirror, .split2, .split4: return .screen
        }
    }

    /// 強さのスライダーを出すか(画面の分割・ミラーは強さが無い)
    var usesIntensity: Bool {
        switch self {
        case .mirror, .split2, .split4: return false
        default: return true
        }
    }

    /// 追加したときの強さ
    var defaultIntensity: Double {
        switch self {
        case .blur, .motionBlur, .zoomBlur: return 0.5
        case .strobe, .noise: return 0.5
        default: return 0.6
        }
    }
}

/// タイムライン上の映像エフェクト 1 件
struct VideoEffectClip: Identifiable, Equatable {
    var id = UUID()
    var type: VideoEffectType
    /// 出力タイムライン上の開始秒
    var start: Double
    var duration: Double = 3
    /// 強さ(0 ... 1)
    var intensity: Double = 0.6

    var end: Double { start + duration }

    func contains(timelineTime t: Double) -> Bool {
        t >= start && t < end
    }
}

// MARK: - 保存(ProjectStore の project.json。省略可能な項目として持つ)

struct StoredVideoEffect: Codable {
    var id: UUID
    var type: String
    var start: Double
    var duration: Double
    var intensity: Double?

    init(_ e: VideoEffectClip) {
        id = e.id
        type = e.type.rawValue
        start = e.start
        duration = e.duration
        intensity = e.intensity
    }

    /// 知らない種類(新しい版で保存したもの)は読み飛ばす
    var value: VideoEffectClip? {
        guard let kind = VideoEffectType(rawValue: type) else { return nil }
        return VideoEffectClip(id: id, type: kind, start: start, duration: max(0.1, duration),
                               intensity: min(max(intensity ?? kind.defaultIntensity, 0), 1))
    }
}

// MARK: - プロジェクトの操作

extension EditorProject {
    func videoEffectBinding(id: UUID) -> Binding<VideoEffectClip>? {
        guard let initial = videoEffects.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.videoEffects.first(where: { $0.id == id }) ?? initial },
            set: { [weak self] newValue in
                guard let self, let i = self.videoEffects.firstIndex(where: { $0.id == id }) else { return }
                self.videoEffects[i] = newValue
            }
        )
    }

    func removeVideoEffect(id: UUID) { videoEffects.removeAll { $0.id == id } }
    func sortVideoEffects() { videoEffects.sort { $0.start < $1.start } }
}
