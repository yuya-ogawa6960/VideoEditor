import SwiftUI
import AVFoundation
import Vision

// =====================================================================
// モザイク / ぼかし の編集パネルと、顔に自動でかける処理。
// モザイクは TextClip(mosaic != nil)なので、位置はプレビューのドラッグ・ピンチ、
// 動きへの追従は「トラッキング」パネル(テキストと共通)で行う。
// =====================================================================

struct EditorMosaicPanel: View {
    @Binding var clip: TextClip
    /// 再生位置を知るのに使う(キーフレームのあるモザイクは、基本の値ではなく再生位置のキーに書くため)。無ければ先頭(0 秒)のキーに書く
    var player: PlayerController? = nil

    private var style: Binding<MosaicStyle> {
        Binding(
            get: { clip.mosaic ?? MosaicStyle() },
            set: { clip.mosaic = $0 }
        )
    }

    /// キーフレームがあるか(顔モザイク・トラッキング)。あると描画は基本の値(center / scale / rotation)を見ない(MosaicModels)
    private var isKeyed: Bool { !clip.keyframes.isEmpty }

    /// 基本の値(キーフレームを見ない配置)
    private var baseValue: KeyframeInterpolator.Value {
        KeyframeInterpolator.Value(center: clip.center, scale: clip.scale, rotation: clip.rotation, opacity: clip.opacity)
    }

    /// キーを書く時刻 = 再生位置の、モザイクの先頭からの相対秒(範囲内に丸める。EditorTextPlacementPanel・プレビューの操作と同じ)
    private var keyTime: Double {
        let now = player?.currentTime ?? clip.start
        return min(max(now - clip.start, 0), max(clip.duration, 0))
    }

    /// 見せる配置。キーフレームがあれば再生位置の補間値(プレビューの枠と同じ)、無ければ基本の値
    private var shownValue: KeyframeInterpolator.Value {
        guard isKeyed else { return baseValue }
        return KeyframeInterpolator.value(at: keyTime, keyframes: clip.keyframes, fallback: baseValue)
    }

    var body: some View {
        let shown = shownValue
        VStack(alignment: .leading, spacing: 14) {
            Picker("かけ方", selection: style.kind) {
                ForEach(MosaicKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Picker("形", selection: style.shape) {
                ForEach(MosaicShape.allCases) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            EditorSliderRow(title: String(localized: "強さ"),
                            value: style.strength,
                            range: 0...1,
                            display: "\(Int((style.wrappedValue.strength * 100).rounded()))%")
            // 回転はプレビューの枠の上のつまみか 2 本指。ここは 0° に戻すだけ
            HStack(spacing: 8) {
                if isKeyed {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                Text(String(localized: "回転 \(Int(shown.rotation.rounded()))°"))
                    .font(.caption)
                    .monospacedDigit()
                Spacer()
                if Int(shown.rotation.rounded()) != 0 {
                    EditorChip(title: "0°", isSelected: false) { updatePlacement { $0.rotation = 0 } }
                }
            }

            Button("リセット") {
                var reset = MosaicStyle()
                reset.kind = style.wrappedValue.kind
                clip.mosaic = reset
                clip.widthRatio = 0.3
                updatePlacement {
                    $0.scale = 1
                    $0.rotation = 0
                }
            }
            .font(.system(size: 14))
            .frame(minHeight: 44)
        }
    }

    /// 大きさ・回転を直す。キーフレームが無ければ基本の値に書く。
    /// あれば基本の値は変えず、再生位置のキーへ書く(プレビューの操作・EditorTextPlacementPanel と同じ KeyframeEditing:
    /// 全キーで同じ値(顔モザイク・トラッキングは rotation 0・scale 1)なら差分を全キーにかけ、キーごとに違えば再生位置のキーを置き換え / 追加)
    private func updatePlacement(_ change: (inout KeyframeInterpolator.Value) -> Void) {
        let time = keyTime
        let start = shownValue
        var value = start
        change(&value)
        guard isKeyed else {
            clip.center = value.center
            clip.scale = value.scale
            clip.rotation = value.rotation
            return
        }
        // 書く時刻と再生位置がずれないように、再生中なら止める(プレビューの操作と同じ)
        if let player, player.isPlaying { player.pause() }
        clip.keyframes = KeyframeEditing.applying(value, from: start, at: time, to: clip.keyframes)
    }
}

// MARK: - 顔に自動でかける

/// 再生位置のコマから顔を見つける(キャンバス正規化座標、左上原点)
enum MosaicFaceFinder {
    struct Face {
        /// キャンバス上の顔の範囲
        var canvasRect: NormalizedRect
        /// 元素材上の顔の範囲(トラッキング用)
        var sourceRect: NormalizedRect
    }

    /// clip の元素材上 sourceTime のコマから顔を探す
    static func findFaces(in clip: Clip, sourceTime: Double, canvasSize: CGSize,
                          scaling: ScalingMode) async throws -> [Face] {
        let asset = AVURLAsset(url: clip.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
        let image: CGImage = try await generator.image(at: time).image

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        let observations: [VNFaceObservation] = request.results ?? []

        let clipRect = PreviewTrackingMath.clipRect(clipSize: clip.displaySize, canvasSize: canvasSize, scaling: scaling)
        var faces: [Face] = []
        for observation in observations {
            let box = observation.boundingBox
            // Vision は左下原点 → 左上原点の正規化座標
            let source = NormalizedRect(x: Double(box.minX),
                                        y: Double(1 - box.maxY),
                                        width: Double(box.width),
                                        height: Double(box.height))
            let a = PreviewTrackingMath.canvasPoint(fromSource: NormalizedPoint(x: source.x, y: source.y),
                                                    clipRect: clipRect, canvasSize: canvasSize)
            let b = PreviewTrackingMath.canvasPoint(fromSource: NormalizedPoint(x: source.x + source.width,
                                                                                y: source.y + source.height),
                                                    clipRect: clipRect, canvasSize: canvasSize)
            let canvas = NormalizedRect(x: a.x, y: a.y, width: max(0.01, b.x - a.x), height: max(0.01, b.y - a.y))
            faces.append(Face(canvasRect: canvas, sourceRect: source))
        }
        return faces
    }
}

// MARK: - 中だるみ・編集チェック

/// 中だるみ・編集チェックの結果(編集チェックの項目と、黄・赤の区間の理由と直し方。タップでその位置へ移動)
struct EditorPacingPanel: View {
    let timeline: TimelineState
    let player: PlayerController
    let onRerun: () -> Void
    let onFix: (EditingCheck.Fix) -> Void

    @AppStorage("pacing.sensitivity") private var sensitivityRaw: String = PacingSensitivity.normal.rawValue
    @AppStorage("pacing.useAI") private var useAI: Bool = false
    @AppStorage("pacing.platform") private var platformRaw: String = TargetPlatform.youtube.rawValue

    private func seconds(_ level: PacingLevel) -> Int {
        Int(timeline.pacing.filter { $0.level == level }.reduce(0) { $0 + ($1.end - $1.start) })
    }

    /// いまの設定(投稿先・厳しさ・AI)の 1 行
    private var settingsText: String {
        let platform = TargetPlatform(rawValue: platformRaw) ?? .youtube
        let sensitivity = PacingSensitivity(rawValue: sensitivityRaw) ?? .normal
        var text = platform.displayName + "・" + sensitivity.displayName
        if useAI { text += "・AI" }
        return text
    }

    var body: some View {
        let issues: [PacingSegment] = timeline.pacing.filter { $0.level != .good }
        VStack(alignment: .leading, spacing: 10) {
            // 結果のまとめ。投稿先・厳しさ・AI は ⚙ の中。変えても「再チェック」を押すまでは走らない
            HStack(spacing: 12) {
                summary(.good)
                summary(.loose)
                summary(.dull)
                Spacer()
                settingsMenu
                EditorChip(title: String(localized: "再チェック"), isSelected: false) { onRerun() }
            }
            Text(settingsText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !timeline.pacingChecks.isEmpty {
                Text("編集チェック")
                    .font(.headline)
                    .padding(.top, 4)
                ForEach(timeline.pacingChecks) { check in
                    checkRow(check)
                }
            }

            Text("中だるみ")
                .font(.headline)
                .padding(.top, 4)
            if issues.isEmpty {
                Text(timeline.pacing.isEmpty ? String(localized: "まだチェックしていません。") : String(localized: "中だるみしそうな所は見つかりませんでした。"))
                    .font(.callout)
            }
            ForEach(issues) { segment in
                Button {
                    player.seek(to: segment.start)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(TimelinePacingStrip.color(for: segment.level)).frame(width: 10, height: 10)
                            Text("\(EditorTimeFormat.short(segment.start)) 〜 \(EditorTimeFormat.short(segment.end))")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                            Text(segment.level.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(segment.reasons, id: \.self) { reason in
                            Text("・" + reason).font(.caption)
                        }
                        ForEach(segment.suggestions, id: \.self) { tip in
                            Text("→ " + tip).font(.caption).foregroundStyle(BrandStyle.coral)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// ⚙: 投稿先(場所ごとに基準が変わる)・厳しさ・AI と「帯を消す」
    private var settingsMenu: some View {
        Menu {
            Picker(String(localized: "投稿先"), selection: $platformRaw) {
                ForEach(TargetPlatform.allCases) { platform in
                    Text(platform.displayName).tag(platform.rawValue)
                }
            }
            Picker(String(localized: "厳しさ"), selection: $sensitivityRaw) {
                ForEach(PacingSensitivity.allCases) { level in
                    Text(level.displayName).tag(level.rawValue)
                }
            }
            Toggle(String(localized: "AI で話の中身も見る"), isOn: $useAI)
            Divider()
            Button(role: .destructive) {
                timeline.pacing = []
                timeline.pacingChecks = []
            } label: {
                Label("帯を消す", systemImage: "eraser")
            }
            .disabled(timeline.pacing.isEmpty && timeline.pacingChecks.isEmpty)
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("チェックの設定")
    }

    private func checkRow(_ check: EditingCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(TimelinePacingStrip.color(for: check.level)).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.subheadline.weight(.semibold))
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = check.fix, let title = check.fixTitle {
                    Button(title) { onFix(fix) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandStyle.coral)
                        .frame(minHeight: 32)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func summary(_ level: PacingLevel) -> some View {
        HStack(spacing: 4) {
            Circle().fill(TimelinePacingStrip.color(for: level)).frame(width: 9, height: 9)
            Text("\(seconds(level))秒").font(.caption.monospacedDigit())
        }
        .accessibilityLabel("\(level.title) \(seconds(level))秒")
    }
}
