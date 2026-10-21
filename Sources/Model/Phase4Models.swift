import Foundation
import CoreGraphics

// =====================================================================
// 第4弾の共通データ定義(契約)。
// マスク、自動リフレーム、手ぶれ補正、画質補正、3D ズーム、ワンタップ編集、AI 台本。
// 解析結果(リフレーム・手ぶれ)は「元素材上の秒」でサンプリングして保持する。
// =====================================================================

// MARK: - マスク

enum MaskShape: String, CaseIterable, Identifiable {
    case none, circle, rectangle, linear, mirror, roundedRectangle, star, heart
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .circle: return "円"
        case .rectangle: return "四角"
        case .linear: return "直線(片側)"
        case .mirror: return "帯(両側)"
        case .roundedRectangle: return "角丸四角"
        case .star: return "星"
        case .heart: return "ハート"
        }
    }
}

struct MaskSettings: Equatable {
    var shape: MaskShape = .none
    var center: NormalizedPoint = .center
    /// 画面の短辺に対する幅・高さの比率
    var width: Double = 0.6
    var height: Double = 0.6
    /// 度
    var rotation: Double = 0
    /// ぼかし幅(短辺比率 0 ... 0.3)
    var feather: Double = 0.05
    var inverted: Bool = false
    /// 角丸四角の半径(短辺比率)
    var cornerRadius: Double = 0.08
    var isActive: Bool { shape != .none }
}

// MARK: - 自動リフレーム(人物追尾)

struct ReframeSample: Equatable {
    /// 元素材上の秒
    var time: Double
    /// 注目点(0...1、左上原点)
    var center: NormalizedPoint
    /// 検出の確からしさ 0...1
    var confidence: Double
}

struct ReframeTrack: Equatable {
    var enabled: Bool = false
    /// time 昇順
    var samples: [ReframeSample] = []
    /// なめらかさ 0...1(大きいほどゆっくり追う)
    var smoothing: Double = 0.7
    /// 被写体をどれだけ大きく映すか 1 ... 2
    var zoom: Double = 1
    var isActive: Bool { enabled && samples.count >= 2 }

    /// 元素材上の時刻での注目点(線形補間)。サンプルが無ければ中央
    func center(at time: Double) -> NormalizedPoint {
        guard let first = samples.first else { return .center }
        if time <= first.time { return first.center }
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            if time <= b.time {
                let span = max(b.time - a.time, 1e-6)
                let u = (time - a.time) / span
                return NormalizedPoint(x: a.center.x + (b.center.x - a.center.x) * u, y: a.center.y + (b.center.y - a.center.y) * u)
            }
        }
        return samples.last!.center
    }
}

// MARK: - 手ぶれ補正

struct StabilizationSample: Equatable {
    /// 元素材上の秒
    var time: Double
    /// このフレームに加える補正(画面幅・高さに対する比率、度)
    var dx: Double
    var dy: Double
    var rotation: Double
}

struct StabilizationTrack: Equatable {
    var enabled: Bool = false
    var samples: [StabilizationSample] = []
    /// 補正の強さ 0...1
    var strength: Double = 0.8
    /// 端の黒を隠すための拡大 1.0 ... 1.3
    var cropZoom: Double = 1.1
    var isActive: Bool { enabled && samples.count >= 2 }

    func sample(at time: Double) -> StabilizationSample? {
        guard let first = samples.first else { return nil }
        if time <= first.time { return first }
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            if time <= b.time {
                let span = max(b.time - a.time, 1e-6)
                let u = (time - a.time) / span
                return StabilizationSample(time: time, dx: a.dx + (b.dx - a.dx) * u, dy: a.dy + (b.dy - a.dy) * u, rotation: a.rotation + (b.rotation - a.rotation) * u)
            }
        }
        return samples.last
    }
}

// MARK: - 画質補正

struct ClipEnhancements: Equatable {
    /// 映像のノイズ除去 0...1
    var denoise: Double = 0
    /// 美肌(顔のなめらかさ) 0...1
    var retouch: Double = 0
    /// 簡易高画質化(輪郭強調つき拡大) 0...1
    var sharpenUpscale: Double = 0
    var isIdentity: Bool { denoise == 0 && retouch == 0 && sharpenUpscale == 0 }
}

// MARK: - 3D ズーム(写真の奥行き)

struct DepthParallax: Equatable {
    var enabled: Bool = false
    /// 視差の強さ 0...1
    var strength: Double = 0.5
    /// 動きの向き
    var direction: ParallaxDirection = .zoomIn
}

enum ParallaxDirection: String, CaseIterable, Identifiable {
    case zoomIn, zoomOut, panLeft, panRight
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .zoomIn: return "ズームイン"
        case .zoomOut: return "ズームアウト"
        case .panLeft: return "左へ"
        case .panRight: return "右へ"
        }
    }
}

// MARK: - ワンタップ編集・テンプレート

enum AutoEditStyle: String, CaseIterable, Identifiable {
    case documentary, vlog, short, family, howto
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .documentary: return "ドキュメンタリー"
        case .vlog: return "Vlog・旅行"
        case .short: return "ショート(テンポ重視)"
        case .family: return "家族の記録"
        case .howto: return "解説・紹介"
        }
    }
}

struct AutoEditSettings: Equatable {
    var style: AutoEditStyle = .documentary
    /// 目標の長さ(秒)。0 = 全部使う
    var targetDuration: Double = 60
    var useBGMBeats: Bool = true
    /// 最初にタイトルを入れる(ふだんはオフ)
    var addTitleCard: Bool = false
    var titleText: String = ""
    var addTransitions: Bool = true
    var applyLook: Bool = true
    var preferFaces: Bool = true
    var preferSpeech: Bool = true
}

/// 自動ハイライトの候補
struct HighlightSegment: Identifiable, Equatable {
    var id = UUID()
    var clipID: UUID
    /// 元素材上の秒
    var start: Double
    var end: Double
    /// 0...1
    var score: Double
    var reason: String
}

// MARK: - AI 台本

enum ScriptTone: String, CaseIterable, Identifiable {
    case calm, friendly, energetic, formal
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .calm: return "落ち着いた"
        case .friendly: return "親しみやすい"
        case .energetic: return "元気"
        case .formal: return "丁寧"
        }
    }
}

struct ScriptLine: Identifiable, Equatable {
    var id = UUID()
    /// 出力タイムライン上の秒(目安)
    var time: Double
    var text: String
}
