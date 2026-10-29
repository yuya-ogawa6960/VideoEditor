import Foundation
import CoreGraphics

// =====================================================================
// メインクリップのキーフレームと、なめらかスロー(コマを作って足した動画)のデータ。
//
// キーフレーム(Clip.keyframes):
//   時刻は「元素材上の秒」(Clip.sourceTime(atOutputOffset:) と同じ。逆再生でも順方向の素材の秒)。
//   素材の位置に付いているので、先頭を切る・分割する・無音カット・速度を変えるときにずらす必要がない
//   (分割した両方に同じキーが残り、範囲の外のキーも前後の補間に使われるので動きが途切れない)。
//   値: center = キャンバス上の中心の位置(0.5, 0.5 で動かさない。左上が 0)、scale = 大きさ(1 = そのまま)、
//   rotation = 度(時計回りが正)、opacity = 不透明度。配置のあとにキャンバスの中心まわりでかける
//   (モーション・クロップのズーム・位置はその前に素材へかかるので、両方を掛け合わせた動きになる)。
//
// なめらかスロー(Clip.flowSlow):
//   前後のコマの動き(Vision のオプティカルフロー)から間のコマを作り、コマ数を factor 倍にした動画を
//   トリミング範囲(少し余白つき)だけ作っておく(FlowSlowRenderer.swift)。ファイルの 0 秒 = 元素材の sourceStart 秒。
//   範囲・長さは元の素材と同じなので、トリミング・速度カーブはそのまま使える。映像だけ差し替え、音声は元の素材。
// =====================================================================

/// なめらかスロー(コマを足した動画)の設定と作成済みファイル
struct FlowSlowMotion: Equatable {
    /// 使う(作成済みファイルがトリミング範囲を含むときだけ効く)
    var enabled: Bool = false
    /// コマを足した動画(映像のみ。mediaDirectory 内)
    var fileURL: URL? = nil
    /// ファイルの 0 秒にあたる元素材上の秒
    var sourceStart: Double = 0
    /// ファイルの終わりにあたる元素材上の秒
    var sourceEnd: Double = 0
    /// コマを何倍にしたか
    var factor: Int = 1
    /// 作ったときのいちばん遅い速度(これより遅くしたら作り直しをすすめる)
    var slowestSpeed: Double = 1
}

/// コンポジタに渡すメインクリップのキーフレーム(プレーンデータ)
struct ClipKeyframeTrack {
    /// 時刻順
    let keyframes: [Keyframe]
    /// トリミング範囲(元素材上の秒)
    let startTime: Double
    let endTime: Double
    /// 逆再生ファイルを使っている(コンポジタの元素材の秒を順方向に直す)
    let isReversed: Bool
    /// 静止画など、速度区間が無いときの速さ
    let speed: Double

    init?(clip: Clip, reversedActive: Bool) {
        guard !clip.keyframes.isEmpty else { return nil }
        keyframes = clip.keyframes.sorted { $0.time < $1.time }
        startTime = clip.startTime
        endTime = clip.endTime
        isReversed = reversedActive
        speed = max(clip.speed, 0.01)
    }

    /// コンポジタの元素材上の秒(VideoCompositorClipLayer.sourceTime。無ければ nil)と、層の先頭からの出力秒 → キーの時刻
    func keyTime(sourceTime: Double?, localTime: Double) -> Double {
        if let s = sourceTime {
            return isReversed ? startTime + endTime - s : s
        }
        return startTime + max(0, localTime) * speed
    }

    func value(sourceTime: Double?, localTime: Double) -> KeyframeInterpolator.Value {
        KeyframeInterpolator.value(at: keyTime(sourceTime: sourceTime, localTime: localTime),
                                   keyframes: keyframes,
                                   fallback: ClipKeyframeTrack.identity)
    }

    /// 動かさないときの値
    static let identity = KeyframeInterpolator.Value(center: .center, scale: 1, rotation: 0, opacity: 1)
}

extension Clip {
    /// いちばん遅い速度(速度カーブなら曲線の最小、等速なら speed)
    var slowestSpeed: Double {
        if speedCurve.enabled {
            var lowest = 10.0
            for i in 0...64 {
                lowest = min(lowest, speedCurve.speed(at: Double(i) / 64))
            }
            return lowest
        }
        return speed
    }

    /// スローの部分がある(なめらかスローを使える)
    var hasSlowPart: Bool { !isStill && slowestSpeed < 0.95 }

    /// 作成済みのなめらかスローの動画が、いまのトリミング範囲に使えるか(ファイルの有無は見ない)
    var flowSlowCoversRange: Bool {
        guard flowSlow.fileURL != nil else { return false }
        return startTime >= flowSlow.sourceStart - 0.05 && endTime <= flowSlow.sourceEnd + 0.05
    }

    /// CompositionBuilder が映像に使うなめらかスローの動画と、その 0 秒にあたる元素材上の秒。
    /// 使わない(切っている・範囲が足りない・逆再生・マルチカム・静止画・ファイルが無い)なら nil
    var activeFlowSlow: (url: URL, offset: Double)? {
        guard flowSlow.enabled, let url = flowSlow.fileURL, !isStill, flowSlowCoversRange else { return nil }
        if isReversed && reversedURL != nil { return nil }
        if multicam.isActive { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url: url, offset: flowSlow.sourceStart)
    }

    /// 元素材上の秒 sourceTime でのキーフレームの補間値(キーが無ければ動かさない値)
    func keyframeValue(atSourceTime sourceTime: Double) -> KeyframeInterpolator.Value {
        KeyframeInterpolator.value(at: sourceTime, keyframes: keyframes, fallback: ClipKeyframeTrack.identity)
    }

    /// トリミング範囲の中のキーフレーム(時刻順。少し外まで含める)
    var visibleKeyframes: [Keyframe] {
        keyframes.filter { $0.time >= startTime - 0.05 && $0.time <= endTime + 0.05 }
            .sorted { $0.time < $1.time }
    }
}

// MARK: - 保存形式(ProjectStore の StoredClip から使う。項目はすべて省略可能)

/// なめらかスロー。ファイルが消えていれば作っていない状態に戻す
struct StoredFlowSlow: Codable {
    var enabled: Bool?
    var file: String?
    var sourceStart: Double?
    var sourceEnd: Double?
    var factor: Int?
    var slowestSpeed: Double?

    /// 何も作っていない・使っていないなら nil(保存しない)
    static func make(_ f: FlowSlowMotion) -> StoredFlowSlow? {
        guard f.enabled || f.fileURL != nil else { return nil }
        var s = StoredFlowSlow()
        s.enabled = f.enabled
        s.file = f.fileURL?.lastPathComponent
        s.sourceStart = f.sourceStart
        s.sourceEnd = f.sourceEnd
        s.factor = f.factor
        s.slowestSpeed = f.slowestSpeed
        return s
    }

    var value: FlowSlowMotion {
        var f = FlowSlowMotion()
        guard let file, let url = ProjectStore.resolveMedia(file) else { return f }
        let start = sourceStart ?? 0
        let end = sourceEnd ?? 0
        guard start.isFinite, end.isFinite, end > start else { return f }
        f.enabled = enabled ?? false
        f.fileURL = url
        f.sourceStart = start
        f.sourceEnd = end
        f.factor = min(max(factor ?? 2, 1), 16)
        let slowest = slowestSpeed ?? 0.5
        f.slowestSpeed = slowest.isFinite ? min(max(slowest, 0.01), 10) : 0.5
        return f
    }
}
