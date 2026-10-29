import Foundation
import Observation

// =====================================================================
// クリップの「調整」(見た目)のコピー・貼り付け。
// 1 本のクリップで決めた色味を、ほかのクリップにそのまま写すために使う。
// コピーした内容はアプリを閉じるまで覚えておく(ファイルには保存しない)。
// 「カラープリセット」パネルの「全クリップに適用」はプリセット・強さ・明るさ・コントラスト・彩度だけを写すが、
// こちらは HSL・LUT・露出なども含めた調整すべてを写す。
// =====================================================================

/// クリップ 1 本ぶんの調整(カラープリセット・強さ・カラー補正・HSL・LUT)。オーバーレイにも使える
struct ClipLook: Equatable {
    var preset: FilterPreset
    /// 0 ... 1
    var intensity: Double
    /// 明るさ・コントラスト・彩度・露出・色温度・ハイライト・シャドウ・シャープ
    var adjustments: ColorAdjustments
    /// 8 帯の HSL
    var hsl: HSLAdjustment
    /// 読み込んだ LUT のファイル名(MediaStore.mediaDirectory/LUTs 内。全プロジェクト共通なので名前だけ持てばよい)
    var lutFileName: String?
    var lutIntensity: Double

    init(from clip: Clip) {
        self.init(filter: clip.filter)
    }

    init(from overlay: OverlayClip) {
        self.init(filter: overlay.filter)
    }

    init(filter: FilterSettings) {
        preset = filter.preset
        intensity = filter.intensity
        adjustments = filter.adjustments
        hsl = filter.hsl
        lutFileName = filter.lutFileName
        lutIntensity = filter.lutIntensity
    }

    /// この調整を反映した FilterSettings
    var filter: FilterSettings {
        var f = FilterSettings()
        f.preset = preset
        f.intensity = intensity
        f.adjustments = adjustments
        f.hsl = hsl
        f.lutFileName = lutFileName
        f.lutIntensity = lutIntensity
        return f
    }

    /// 何も調整していない(初期値のまま)か
    var isIdentity: Bool { filter.isIdentity }

    func apply(to clip: inout Clip) {
        clip.filter = filter
    }

    func apply(to overlay: inout OverlayClip) {
        overlay.filter = filter
    }
}

/// コピーした調整の置き場所(アプリ全体で 1 つ)。メインスレッドから使う
@MainActor
@Observable
final class LookClipboard {
    static let shared = LookClipboard()

    /// コピーした調整。まだ何もコピーしていなければ nil
    private(set) var look: ClipLook?

    var hasLook: Bool { look != nil }

    private init() {}

    func copy(_ look: ClipLook) {
        self.look = look
    }

    func clear() {
        look = nil
    }
}
