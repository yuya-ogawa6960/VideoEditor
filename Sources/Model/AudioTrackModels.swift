import Foundation

// =====================================================================
// 音声トラック関連のモデル(ナレーション・クリップ音声設定)
// ※ まだ ProjectSnapshot には組み込まれていない(組み込みは別途)
// =====================================================================

// MARK: - ナレーション

/// 出力タイムライン上に置くナレーション(録音・音声ファイル)
struct NarrationClip: Identifiable, Equatable {
    var id = UUID()
    /// アプリ内(MediaStore.mediaDirectory)の音声ファイル
    var url: URL
    var name: String
    /// 出力タイムライン上の開始秒
    var start: Double
    /// 音声ファイル上の再生開始秒
    var sourceStart: Double = 0
    /// 再生する長さ(秒)。タイムライン上の長さと同じ(速度変更なし)
    var duration: Double
    /// ユーザー音量 0...1
    var volume: Float = 1
    /// 正規化で求めたゲイン(線形)
    var gain: Float = 1
    var effects = AudioEffects()
    /// フェードイン・フェードアウト(秒、0〜3。0 = なし)
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// レシピで作った効果音なら、その id(ファイルが消えても作り直せる)
    var soundRecipeID: String? = nil

    /// 出力タイムライン上の終了秒
    var end: Double { start + duration }
    /// 音声ファイル上の終了秒
    var sourceEnd: Double { sourceStart + duration }
    /// ミックス時に使う実効音量(volume × gain)
    var effectiveVolume: Float { volume * gain }

    func contains(timelineTime: Double) -> Bool {
        timelineTime >= start && timelineTime < end
    }

    /// 出力タイムライン時刻 → 音声ファイル上の時刻(範囲外は nil)
    func sourceTime(at timelineTime: Double) -> Double? {
        guard contains(timelineTime: timelineTime) else { return nil }
        return sourceStart + (timelineTime - start)
    }
}

// MARK: - クリップごとの音声設定

/// クリップの音声に関する追加設定(音量・ゲイン・J カット・L カット)
struct ClipAudioSettings: Equatable {
    /// 正規化ゲイン(線形、1 = 変更なし)
    var gain: Float = 1
    /// ユーザーが決めるクリップ音量(0...2、1 = 変更なし)。ミックス時は gain と掛け合わせる
    var volume: Float = 1
    /// J カット: このクリップの映像より何秒早く音声を始めるか。
    /// 音声は元素材の (startTime - audioLeadIn) から取る。
    var audioLeadIn: Double = 0
    /// L カット: このクリップの映像が終わった後、何秒音声を続けるか。
    /// 音声は元素材の endTime を越えて (endTime + audioTailOut) まで取る。
    var audioTailOut: Double = 0
    /// イコライザー・ピッチ・ボイスプリセット(Phase3Models.swift)
    var effects = AudioEffects()

    var isIdentity: Bool { gain == 1 && volume == 1 && audioLeadIn == 0 && audioTailOut == 0 }
    var hasSplitEdit: Bool { audioLeadIn > 0 || audioTailOut > 0 }
}
