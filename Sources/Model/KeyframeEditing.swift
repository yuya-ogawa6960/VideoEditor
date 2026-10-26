import Foundation

// =====================================================================
// キーフレームの付いた部品(テキスト・モザイク・オーバーレイ)を、プレビュー上の
// ジェスチャーで直すときの書き込み。
//
// キーフレームがあると描画は基本の値(center / scale / rotation)を見ない
// (TextRenderer / MosaicModels / OverlayRenderer)。そのため配置を変えるときは
// 基本の値ではなく、再生位置のキーフレームに書く。決まりは EditorKeyframePanel の
// addAtPlayhead と同じ: 0.05 秒以内にキーがあれば id・イージングを引き継いで置き換え、
// 無ければ追加する。
// =====================================================================

enum KeyframeEditing {

    /// この幅(秒)以内のキーは「同じ時刻」とみなして置き換える(addAtPlayhead と同じ)
    static let sameTimeTolerance = 0.05

    /// ジェスチャーで変えた配置 value を、ジェスチャー開始時のキーフレーム列 startKeyframes に書いて返す。
    /// - 位置は時刻 time(部品の開始からの相対秒)のキーへ。
    /// - 大きさ・角度は、全キーで同じ値(トラッキングや顔モザイクの結果。scale 1・rotation 0 など)なら
    ///   start からの差分を全キーにかけて動きの形を保つ(キーは増やさない)。
    ///   キーごとに違う(アニメーションしている)なら時刻 time のキーだけに書く。
    /// start は time での補間値(ジェスチャーの始まりの値)。何度呼んでも同じ結果になるので、
    /// ジェスチャー中は毎回 startKeyframes から作り直して渡す。
    static func applying(_ value: KeyframeInterpolator.Value,
                         from start: KeyframeInterpolator.Value,
                         at time: Double,
                         to startKeyframes: [Keyframe]) -> [Keyframe] {
        var keyframes = startKeyframes.sorted { $0.time < $1.time }
        guard !keyframes.isEmpty else { return keyframes }

        let centerChanged = abs(value.center.x - start.center.x) > 1e-9 || abs(value.center.y - start.center.y) > 1e-9
        let scaleRatio = value.scale / max(start.scale, 0.001)
        let scaleChanged = abs(scaleRatio - 1) > 1e-9
        let rotationDelta = value.rotation - start.rotation
        let rotationChanged = abs(rotationDelta) > 1e-9

        // 大きさ・角度が全キーで同じなら、差分を全キーへ
        let uniformScale = isUniform(keyframes.map { $0.scale })
        if uniformScale, scaleChanged {
            for i in keyframes.indices {
                keyframes[i].scale = keyframes[i].scale * scaleRatio
            }
        }
        let uniformRotation = isUniform(keyframes.map { $0.rotation })
        if uniformRotation, rotationChanged {
            for i in keyframes.indices {
                keyframes[i].rotation = normalizedDegrees(keyframes[i].rotation + rotationDelta)
            }
        }

        // 位置(と、キーごとに違う大きさ・角度)は時刻 time のキーへ。近くにあれば置き換え、無ければ追加。
        // 全キーにかけただけなら、キーは増やさない(イージングの形を変えない)
        let needsKey = centerChanged || (scaleChanged && !uniformScale) || (rotationChanged && !uniformRotation)
        guard needsKey else { return keyframes }
        var key = Keyframe(time: time,
                           center: value.center,
                           scale: value.scale,
                           rotation: value.rotation,
                           opacity: value.opacity)
        if let i = keyframes.firstIndex(where: { abs($0.time - time) < sameTimeTolerance }) {
            key.id = keyframes[i].id
            key.easing = keyframes[i].easing
            keyframes.remove(at: i)
        }
        keyframes.append(key)
        keyframes.sort { $0.time < $1.time }
        return keyframes
    }

    /// -180 ... 180 に収める
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func isUniform(_ values: [Double]) -> Bool {
        guard let first = values.first else { return true }
        return values.allSatisfy { abs($0 - first) < 1e-6 }
    }
}
