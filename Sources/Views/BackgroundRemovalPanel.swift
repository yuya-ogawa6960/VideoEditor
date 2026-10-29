import SwiftUI
import UIKit
import AVFoundation

// =====================================================================
// 背景を消す / クロマキー のパネル(クリップの「モーション」、オーバーレイの「モーション」)。
//   - 自動で消す: 人物 / 被写体 を残して背景を消す(境界のぼかし)
//   - クロマキー: 緑 / 青 / 画面をタップして選んだ色 を消す(強さ・境界のぼかし・色かぶりを抑える)
//   - メインのクリップだけ: 消した部分を 透明(黒) / ぼかし / 単色 で埋める
// 色を選ぶコマは、効果をかける前の素材そのもの(合成後のコマだと、もう色が消えているため)。
// =====================================================================

struct EditorBackgroundRemovalControls: View {
    @Binding var settings: BackgroundRemoval
    /// オーバーレイ(消した部分は常に透明)
    let isOverlay: Bool
    /// 色を選ぶためのコマ(素材そのもの)
    let loadFrame: @MainActor () async -> UIImage?

    @State private var frameImage: UIImage? = nil
    @State private var isLoadingFrame = false
    @State private var didLoadFrame = false
    @State private var pickedPoint: NormalizedPoint? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(BackgroundRemovalMode.allCases) { mode in
                    EditorChip(title: mode.displayName, isSelected: settings.mode == mode) {
                        settings.mode = mode
                    }
                }
                Spacer(minLength: 0)
            }

            switch settings.mode {
            case .off:
                ClipFXHint(text: String(localized: "人物だけを残したり、グリーンバックの色を消したりできます。"))
            case .auto:
                autoControls
            case .chroma:
                chromaControls
            }

            if settings.isActive && !isOverlay {
                fillControls
            }

            if settings.isActive {
                ClipFXHint(text: isOverlay
                           ? String(localized: "消した部分は透明になり、下の映像が見えます。")
                           : String(localized: "人物を別の映像の上に重ねるときは、重ねた素材(オーバーレイ)で使います。"))
            }
        }
        .padding(.top, 6)
        .task(id: settings.mode) {
            guard settings.mode == .chroma, !didLoadFrame else { return }
            await reloadFrame()
        }
    }

    // MARK: 自動

    @ViewBuilder
    private var autoControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "残すもの"))
            HStack(spacing: 8) {
                ForEach(BackgroundRemovalTarget.allCases) { target in
                    EditorChip(title: target.displayName, isSelected: settings.target == target) {
                        settings.target = target
                    }
                }
                Spacer(minLength: 0)
            }
        }
        EditorSliderRow(title: String(localized: "境界のぼかし"),
                        value: $settings.edgeSoftness,
                        range: 0...1,
                        display: percent(settings.edgeSoftness))
        ClipFXHint(text: String(localized: "自動で消している間は、再生が少し重くなります。書き出しではよりきれいに切り抜きます。"))
    }

    // MARK: クロマキー

    @ViewBuilder
    private var chromaControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "消す色"))
            HStack(spacing: 8) {
                EditorChip(title: String(localized: "緑"), isSelected: settings.keyColor == .greenScreen) {
                    settings.keyColor = .greenScreen
                    pickedPoint = nil
                }
                EditorChip(title: String(localized: "青"), isSelected: settings.keyColor == .blueScreen) {
                    settings.keyColor = .blueScreen
                    pickedPoint = nil
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(swatch(settings.keyColor))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
        }

        framePicker

        EditorSliderRow(title: String(localized: "強さ"),
                        value: $settings.strength,
                        range: 0...1,
                        display: percent(settings.strength))
        EditorSliderRow(title: String(localized: "境界のぼかし"),
                        value: $settings.edgeSoftness,
                        range: 0...1,
                        display: percent(settings.edgeSoftness))
        EditorSliderRow(title: String(localized: "色かぶりを抑える"),
                        value: $settings.spill,
                        range: 0...1,
                        display: percent(settings.spill))
    }

    /// 素材のコマをタップして消す色を選ぶ
    private var framePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                EditorSectionTitle(title: String(localized: "画面をタップして色を選ぶ"))
                Spacer(minLength: 0)
                Button {
                    Task { await reloadFrame() }
                } label: {
                    Label("今の再生位置", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(isLoadingFrame)
            }
            ZStack {
                if let frameImage {
                    GeometryReader { geo in
                        let size = geo.size
                        Image(uiImage: frameImage)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in
                                guard size.width > 0, size.height > 0 else { return }
                                let point = NormalizedPoint(x: min(max(value.location.x / size.width, 0), 1),
                                                            y: min(max(value.location.y / size.height, 0), 1))
                                guard let color = BackgroundRemovalFrames.color(in: frameImage, at: point) else { return }
                                EditorHaptics.tap()
                                pickedPoint = point
                                settings.keyColor = color
                            })
                        if let p = pickedPoint {
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                                .background(Circle().fill(swatch(settings.keyColor)))
                                .frame(width: 22, height: 22)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .position(x: p.x * size.width, y: p.y * size.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .aspectRatio(frameImage.size.width / max(frameImage.size.height, 1), contentMode: .fit)
                } else if isLoadingFrame {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Text("画面を読み取れませんでした")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @MainActor
    private func reloadFrame() async {
        isLoadingFrame = true
        defer { isLoadingFrame = false }
        let image = await loadFrame()
        guard !Task.isCancelled else { return }
        frameImage = image
        pickedPoint = nil
        didLoadFrame = true
    }

    // MARK: メインのクリップ: 消した部分

    private var fillControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "消した部分"))
            HStack(spacing: 8) {
                ForEach(BackgroundRemovalFill.allCases) { fill in
                    EditorChip(title: fill.displayName, isSelected: settings.fill == fill) {
                        settings.fill = fill
                    }
                }
                Spacer(minLength: 0)
                if settings.fill == .color {
                    ColorPicker("", selection: fillColorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
    }

    private var fillColorBinding: Binding<Color> {
        Binding<Color>(
            get: { swatch(settings.fillColor) },
            set: { newValue in
                if let color = BackgroundRemovalColor(hex: EditorColorHex.hex(from: newValue)) {
                    settings.fillColor = color
                }
            }
        )
    }

    // MARK: 共通

    private func swatch(_ c: BackgroundRemovalColor) -> Color {
        let v = c.clamped()
        return Color(.sRGB, red: v.red, green: v.green, blue: v.blue, opacity: 1)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - クリップ / オーバーレイ用のパネル

struct EditorClipBackgroundRemovalPanel: View {
    @Binding var clip: Clip
    let project: EditorProject
    var player: PlayerController? = nil

    var body: some View {
        EditorBackgroundRemovalControls(settings: $clip.backgroundRemoval,
                                        isOverlay: false,
                                        loadFrame: { await loadFrame() })
    }

    /// 再生位置がこのクリップの中ならそのコマ、外ならクリップの先頭のコマ(素材そのもの)
    @MainActor
    private func loadFrame() async -> UIImage? {
        if let still = clip.stillImageURL {
            return BackgroundRemovalFrames.photo(url: still)
        }
        var seconds = clip.startTime
        if let player, let range = ClipFXTimeline.range(of: clip.id, in: project),
           player.currentTime >= range.lowerBound, player.currentTime <= range.upperBound {
            seconds = clip.startTime + (player.currentTime - range.lowerBound) * max(clip.speed, 0.01)
        }
        seconds = min(max(seconds, clip.startTime), max(clip.startTime, clip.endTime - 0.05))
        return await BackgroundRemovalFrames.videoFrame(url: clip.url, seconds: seconds)
    }
}

struct EditorOverlayBackgroundRemovalPanel: View {
    @Binding var overlay: OverlayClip
    var player: PlayerController? = nil

    var body: some View {
        EditorBackgroundRemovalControls(settings: $overlay.backgroundRemoval,
                                        isOverlay: true,
                                        loadFrame: { await loadFrame() })
    }

    @MainActor
    private func loadFrame() async -> UIImage? {
        if overlay.isImage {
            return BackgroundRemovalFrames.photo(url: overlay.url)
        }
        var local = 0.0
        if let player {
            local = min(max(player.currentTime - overlay.start, 0), max(0, overlay.duration))
        }
        let seconds = min(overlay.sourceStart + local * max(overlay.speed, 0.01),
                          max(overlay.sourceStart, overlay.sourceDuration - 0.05))
        return await BackgroundRemovalFrames.videoFrame(url: overlay.url, seconds: max(0, seconds))
    }
}

// MARK: - コマの読み込みと色の取り出し

enum BackgroundRemovalFrames {
    /// 動画の seconds 秒のコマ(向きを反映、長辺 640 まで)
    static func videoFrame(url: URL, seconds: Double) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = CMTime(seconds: max(0, seconds.isFinite ? seconds : 0), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }

    /// 写真(向きをそろえ、長辺 640 まで縮める)
    static func photo(url: URL) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = min(1, 640 / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// point(左上原点の 0...1)のまわりの平均の色(sRGB)
    static func color(in image: UIImage, at point: NormalizedPoint) -> BackgroundRemovalColor? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        let cx = Int((min(max(point.x, 0), 1) * Double(w - 1)).rounded())
        let cy = Int((min(max(point.y, 0), 1) * Double(h - 1)).rounded())
        let r = max(1, min(w, h) / 120)
        let x0 = max(0, cx - r)
        let y0 = max(0, cy - r)
        let x1 = min(w, cx + r + 1)
        let y1 = min(h, cy + r + 1)
        guard x1 > x0, y1 > y0,
              let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let alpha = Double(pixel[3]) / 255
        guard alpha > 0.01 else { return nil }
        return BackgroundRemovalColor(red: Double(pixel[0]) / 255 / alpha,
                                      green: Double(pixel[1]) / 255 / alpha,
                                      blue: Double(pixel[2]) / 255 / alpha).clamped()
    }
}
