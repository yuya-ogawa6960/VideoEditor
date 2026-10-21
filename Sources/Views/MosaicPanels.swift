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

    private var style: Binding<MosaicStyle> {
        Binding(
            get: { clip.mosaic ?? MosaicStyle() },
            set: { clip.mosaic = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("位置と大きさは、プレビューのモザイクをドラッグ・2本指で調整できます。動く人や物には「トラッキング」で追いかけさせられます。")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

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
            EditorSliderRow(title: String(localized: "幅"),
                            value: $clip.widthRatio,
                            range: 0.05...1,
                            display: "\(Int((clip.widthRatio * 100).rounded()))%")
            EditorSliderRow(title: String(localized: "高さ"),
                            value: style.heightRatio,
                            range: 0.05...1,
                            display: "\(Int((style.wrappedValue.heightRatio * 100).rounded()))%")

            Button("リセット") {
                var reset = MosaicStyle()
                reset.kind = style.wrappedValue.kind
                clip.mosaic = reset
                clip.widthRatio = 0.3
                clip.scale = 1
                clip.rotation = 0
            }
            .font(.system(size: 14))
            .frame(minHeight: 44)
        }
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

    var body: some View {
        let issues: [PacingSegment] = timeline.pacing.filter { $0.level != .good }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                summary(.good)
                summary(.loose)
                summary(.dull)
                Spacer()
                EditorChip(title: String(localized: "もう一度"), isSelected: false) { onRerun() }
                EditorChip(title: String(localized: "帯を消す"), isSelected: false) {
                    timeline.pacing = []
                    timeline.pacingChecks = []
                }
            }

            // 投稿先(場所ごとに基準が変わる)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TargetPlatform.allCases) { platform in
                        EditorChip(title: platform.displayName, isSelected: platformRaw == platform.rawValue) {
                            platformRaw = platform.rawValue
                            onRerun()
                        }
                    }
                }
            }
            Text("投稿先を選ぶと、その場所で評価されやすい基準(比率・長さ・つかみ・字幕・終了画面など)でチェックします。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("厳しさ", selection: $sensitivityRaw) {
                ForEach(PacingSensitivity.allCases) { level in
                    Text(level.displayName).tag(level.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Toggle("AI で話の中身も見る(字幕が必要)", isOn: $useAI)
                .font(.subheadline)
            Text("景色のきれいさ・表情・笑い声や自然の音などの雰囲気、場面の切り替わり、話の速さや間も見て判定しています。厳しさや AI を変えたら「もう一度」を押してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
