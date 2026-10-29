import SwiftUI

// =====================================================================
// メインクリップのキーフレームのパネル(クリップの「モーション」→「キーフレーム」)。
// 再生位置にキーを置き、位置・大きさ・回転・不透明度をスライダーで決める。
// キーが無い位置で値を変えると、その位置にキーが自動で入る(CapCut と同じ)。
// キーの時刻は元素材上の秒(ClipKeyframeModels.swift)。表示はクリップの先頭からの秒。
// =====================================================================

struct EditorClipKeyframePanel: View {
    let project: EditorProject
    let player: PlayerController
    @Binding var clip: Clip

    @State private var selectedID: UUID?

    /// 出力タイムライン上のクリップの範囲
    private var range: ClosedRange<Double> {
        ClipFXTimeline.range(of: clip.id, in: project) ?? 0...max(0, clip.outputDuration)
    }

    /// 再生位置の、クリップの先頭からの出力秒(範囲内に丸める)
    private func playheadOffset(in range: ClosedRange<Double>) -> Double {
        min(max(player.currentTime - range.lowerBound, 0), max(0, clip.outputDuration))
    }

    /// 再生位置の元素材上の秒
    private func playheadSource(in range: ClosedRange<Double>) -> Double {
        let source = clip.sourceTime(atOutputOffset: playheadOffset(in: range))
        return min(max(source, clip.startTime), clip.endTime)
    }

    /// キーのクリップ先頭からの出力秒
    private func offset(of key: Keyframe) -> Double {
        clip.outputOffset(atSourceTime: key.time)
    }

    /// 再生位置にあるキー(KeyframeEditing.sameTimeTolerance 秒以内。出力の秒で比べる)
    private func keyAtPlayhead(in range: ClosedRange<Double>) -> Keyframe? {
        let here = playheadOffset(in: range)
        return clip.visibleKeyframes.first { abs(offset(of: $0) - here) < KeyframeEditing.sameTimeTolerance }
    }

    var body: some View {
        let r = range
        let here = playheadOffset(in: r)
        let atPlayhead = keyAtPlayhead(in: r)
        let visible = clip.visibleKeyframes
        let previous = visible.last { offset(of: $0) < here - KeyframeEditing.sameTimeTolerance }
        let next = visible.first { offset(of: $0) > here + KeyframeEditing.sameTimeTolerance }
        let value = clip.keyframeValue(atSourceTime: atPlayhead?.time ?? playheadSource(in: r))

        VStack(alignment: .leading, spacing: 14) {
            // 前へ / 追加・削除 / 次へ(テキスト・オーバーレイのキーフレームと同じ並び)
            HStack(spacing: 6) {
                navigationButton(systemImage: "chevron.left", target: previous, range: r,
                                 label: String(localized: "前のキーフレーム"))
                Button {
                    EditorHaptics.tap()
                    if let atPlayhead {
                        clip.keyframes.removeAll { $0.id == atPlayhead.id }
                        if selectedID == atPlayhead.id { selectedID = nil }
                    } else {
                        addAtPlayhead(range: r)
                    }
                } label: {
                    Image(systemName: atPlayhead == nil ? "plus.diamond" : "diamond.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(atPlayhead == nil ? Color.white : BrandStyle.coral)
                        .frame(width: 52, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(atPlayhead == nil ? String(localized: "キーフレームを追加") : String(localized: "キーフレームを削除"))
                navigationButton(systemImage: "chevron.right", target: next, range: r,
                                 label: String(localized: "次のキーフレーム"))
                Text(verbatim: String(format: "%.2fs", here))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if !clip.keyframes.isEmpty {
                    Button(role: .destructive) {
                        EditorHaptics.tap()
                        clip.keyframes.removeAll()
                        selectedID = nil
                    } label: {
                        Text("すべて削除")
                            .font(.caption)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.red.opacity(0.85))
                }
            }

            if visible.isEmpty {
                Text("再生位置で値を変えると、キーフレームが自動で入ります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visible) { keyframe in
                            chip(keyframe, range: r, isCurrent: keyframe.id == atPlayhead?.id)
                        }
                    }
                }
            }

            // 値(キーがある位置ならそのキー、無い位置なら変えたときにキーを入れる)
            EditorSliderRow(title: String(localized: "横位置"),
                            value: valueBinding(range: r,
                                                get: { $0.center.x - 0.5 },
                                                set: { $0.center.x = min(max($1, -1), 1) + 0.5 }),
                            range: -1...1,
                            display: String(format: "%+.2f", value.center.x - 0.5))
            EditorSliderRow(title: String(localized: "縦位置"),
                            value: valueBinding(range: r,
                                                get: { $0.center.y - 0.5 },
                                                set: { $0.center.y = min(max($1, -1), 1) + 0.5 }),
                            range: -1...1,
                            display: String(format: "%+.2f", value.center.y - 0.5))
            EditorSliderRow(title: String(localized: "大きさ"),
                            value: valueBinding(range: r,
                                                get: { $0.scale },
                                                set: { $0.scale = min(max($1, 0.2), 4) }),
                            range: 0.2...4,
                            display: String(format: "%.2fx", value.scale))
            EditorSliderRow(title: String(localized: "回転"),
                            value: valueBinding(range: r,
                                                get: { $0.rotation },
                                                set: { $0.rotation = min(max($1, -180), 180) }),
                            range: -180...180,
                            display: String(format: "%.0f°", value.rotation))
            EditorSliderRow(title: String(localized: "不透明度"),
                            value: valueBinding(range: r,
                                                get: { $0.opacity },
                                                set: { $0.opacity = min(max($1, 0), 1) }),
                            range: 0...1,
                            display: "\(Int((value.opacity * 100).rounded()))%")

            if let atPlayhead {
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: String(localized: "イージング"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(KeyframeEasing.allCases) { easing in
                                EditorChip(title: easing.displayName, isSelected: atPlayhead.easing == easing) {
                                    setEasing(easing, for: atPlayhead.id)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                EditorChip(title: String(localized: "この位置を元に戻す"), isSelected: false) {
                    edit(range: r) { $0 = ClipKeyframeTrack.identity }
                }
                .disabled(clip.keyframes.isEmpty)
                .opacity(clip.keyframes.isEmpty ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }

    // MARK: 操作

    private func navigationButton(systemImage: String, target: Keyframe?, range: ClosedRange<Double>, label: String) -> some View {
        Button {
            guard let target else { return }
            EditorHaptics.tap()
            selectedID = target.id
            player.seek(to: range.lowerBound + offset(of: target))
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? Color.white.opacity(0.25) : Color.white)
        .disabled(target == nil)
        .accessibilityLabel(label)
    }

    /// キーの時刻のチップ(押すとその時刻へ移動する)
    private func chip(_ keyframe: Keyframe, range: ClosedRange<Double>, isCurrent: Bool) -> some View {
        let isSelected = isCurrent || keyframe.id == selectedID
        return Button {
            EditorHaptics.tap()
            selectedID = keyframe.id
            player.seek(to: range.lowerBound + offset(of: keyframe))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                Text(verbatim: String(format: "%.2fs", offset(of: keyframe)))
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.white.opacity(0.1), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// スライダー用: 再生位置の値を読み、変えたら再生位置のキーに書く
    private func valueBinding(range: ClosedRange<Double>,
                              get: @escaping (KeyframeInterpolator.Value) -> Double,
                              set: @escaping (inout KeyframeInterpolator.Value, Double) -> Void) -> Binding<Double> {
        Binding<Double>(
            get: {
                let time = keyAtPlayhead(in: range)?.time ?? playheadSource(in: range)
                return get(clip.keyframeValue(atSourceTime: time))
            },
            set: { newValue in
                edit(range: range) { set(&$0, newValue) }
            }
        )
    }

    /// 再生位置のキーの値を変える(無ければ、いまの補間値からキーを作る)
    private func edit(range: ClosedRange<Double>, _ change: (inout KeyframeInterpolator.Value) -> Void) {
        // 書く時刻と再生位置がずれないように、再生中なら止める
        if player.isPlaying { player.pause() }
        let existing = keyAtPlayhead(in: range)
        let time = existing?.time ?? playheadSource(in: range)
        var value = clip.keyframeValue(atSourceTime: time)
        change(&value)
        var key = Keyframe(time: time,
                           center: value.center,
                           scale: value.scale,
                           rotation: value.rotation,
                           opacity: value.opacity)
        var keys = clip.keyframes
        if let existing {
            key.id = existing.id
            key.easing = existing.easing
            keys.removeAll { $0.id == existing.id }
        }
        keys.append(key)
        keys.sort { $0.time < $1.time }
        clip.keyframes = keys
        selectedID = key.id
    }

    /// 再生位置に、いまの値のキーを置く
    private func addAtPlayhead(range: ClosedRange<Double>) {
        edit(range: range) { _ in }
    }

    private func setEasing(_ easing: KeyframeEasing, for id: UUID) {
        guard let i = clip.keyframes.firstIndex(where: { $0.id == id }) else { return }
        clip.keyframes[i].easing = easing
    }
}
