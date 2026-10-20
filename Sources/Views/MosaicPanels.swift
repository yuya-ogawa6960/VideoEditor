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

            EditorSliderRow(title: "強さ",
                            value: style.strength,
                            range: 0...1,
                            display: "\(Int((style.wrappedValue.strength * 100).rounded()))%")
            EditorSliderRow(title: "幅",
                            value: $clip.widthRatio,
                            range: 0.05...1,
                            display: "\(Int((clip.widthRatio * 100).rounded()))%")
            EditorSliderRow(title: "高さ",
                            value: style.heightRatio,
                            range: 0.05...1,
                            display: "\(Int((style.wrappedValue.heightRatio * 100).rounded()))%")

            Button("リセット") {
                var reset = MosaicStyle()
                reset.kind = style.wrappedValue.kind
                clip.mosaic = reset
                clip.widthRatio = 0.3
                clip.scale = 1
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
