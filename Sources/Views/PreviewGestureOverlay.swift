import SwiftUI
import UIKit

// =====================================================================
// プレビューの上に重ねる透明なレイヤー。
// 選択中のテキスト(ステッカー)/オーバーレイに点線の枠を出し、
//   ドラッグ   → 中心位置
//   ピンチ     → 大きさ(テキスト: scale / オーバーレイ: 枠の幅、縦横比を保つ)
//   回転       → 角度(テキストのみ)
// を直接変えられる。履歴はジェスチャーの開始時に 1 回だけ記録し、
// 書き込みは 1 秒間に 30 回まで(最後の値は必ず書く)。
// 点線の枠の部分だけがタッチを受け取り、それ以外はプレビューのタップ(再生/停止)に通す。
// =====================================================================

/// ジェスチャー中の状態(再描画を起こさないよう class で持つ)
final class PreviewGestureSession {
    var isActive = false
    var dragActive = false
    var magnifyActive = false
    var rotateActive = false

    // ジェスチャー開始時(または別のジェスチャーが終わった時)の値
    var startCenter = NormalizedPoint.center
    var startScale = 1.0
    var startRotation = 0.0
    var startFrame = NormalizedRect.full

    // ジェスチャーの生の値と、その基準(別のジェスチャーが終わったときに合わせ直す)
    var rawDrag = CGSize.zero
    var rawMagnify: CGFloat = 1
    var rawRotate = 0.0
    var baseDrag = CGSize.zero
    var baseMagnify: CGFloat = 1
    var baseRotate = 0.0

    var lastWrite: CFAbsoluteTime = 0

    var effectiveDrag: CGSize {
        CGSize(width: rawDrag.width - baseDrag.width, height: rawDrag.height - baseDrag.height)
    }
    var effectiveMagnify: CGFloat { rawMagnify / max(baseMagnify, 0.001) }
    var effectiveRotate: Double { rawRotate - baseRotate }
    var anyActive: Bool { dragActive || magnifyActive || rotateActive }

    func resetDeltas() {
        rawDrag = .zero
        rawMagnify = 1
        rawRotate = 0
        baseDrag = .zero
        baseMagnify = 1
        baseRotate = 0
    }

    /// 生の値を基準にして、以後の変化を 0 からにする
    func rebase() {
        baseDrag = rawDrag
        baseMagnify = rawMagnify
        baseRotate = rawRotate
    }
}

struct PreviewGestureOverlay: View {
    let project: EditorProject
    let history: EditorHistory
    let selection: EditorSelection?

    @State private var session = PreviewGestureSession()

    /// 1 秒間に 30 回まで
    private static let minWriteInterval: CFAbsoluteTime = 1.0 / 30.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if let id = selection?.textID, let binding = project.textClipBinding(id: id) {
                    textFrame(binding, size: size)
                } else if let id = selection?.overlayID, let binding = project.overlayBinding(id: id) {
                    overlayFrame(binding, size: size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    // MARK: - 枠

    /// テキストの表示範囲のおおよその推定(描画はエンジン側なので近似)
    static func estimatedRect(for clip: TextClip, in size: CGSize) -> CGRect {
        let short = min(size.width, size.height)
        let fontPx = CGFloat(clip.style.sizeRatio) * short
        let lineCount = max(1, clip.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let lines = CGFloat(lineCount)
        var w: CGFloat
        var h: CGFloat
        if clip.isSticker {
            w = fontPx * 1.25
            h = fontPx * 1.25
        } else if clip.style.vertical {
            let charsPerLine = CGFloat(max(1, Int(ceil(Double(clip.text.count) / Double(lineCount)))))
            w = fontPx * CGFloat(clip.style.lineSpacing) * lines + fontPx * 0.4
            h = min(size.height, fontPx * charsPerLine * CGFloat(1 + max(0, clip.style.letterSpacing)) + fontPx * 0.4)
        } else {
            w = size.width * CGFloat(clip.widthRatio)
            h = fontPx * CGFloat(clip.style.lineSpacing) * lines + fontPx * 0.4
        }
        if clip.style.backgroundColorHex != nil {
            let pad = fontPx * CGFloat(clip.style.backgroundPadding) * 2
            w += pad
            h += pad
        }
        w *= CGFloat(clip.scale)
        h *= CGFloat(clip.scale)
        let c = clip.center.point(in: size)
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    private func dashedFrame(width: CGFloat, height: CGFloat, badge: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(Color.white.opacity(0.9))
            .background(Color.white.opacity(0.001))
            .overlay(alignment: .topLeading) {
                Image(systemName: badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(3)
                    .background(Color.white.opacity(0.9), in: Circle())
                    .offset(x: -8, y: -8)
                    .allowsHitTesting(false)
            }
            .frame(width: max(width, 28), height: max(height, 28))
            .contentShape(Rectangle())
    }

    private func textFrame(_ binding: Binding<TextClip>, size: CGSize) -> some View {
        let clip = binding.wrappedValue
        let rect = Self.estimatedRect(for: clip, in: size)
        return dashedFrame(width: rect.width, height: rect.height, badge: "arrow.up.and.down.and.arrow.left.and.right")
            .gesture(textGesture(binding, size: size))
            .rotationEffect(.degrees(clip.rotation))
            .position(x: rect.midX, y: rect.midY)
    }

    private func overlayFrame(_ binding: Binding<OverlayClip>, size: CGSize) -> some View {
        let overlay = binding.wrappedValue
        let rect = overlay.frame.rect(in: size)
        return dashedFrame(width: rect.width, height: rect.height, badge: "arrow.up.and.down.and.arrow.left.and.right")
            .gesture(overlayGesture(binding, size: size))
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - テキストのジェスチャー

    private func beginIfNeeded(text clip: TextClip) {
        guard !session.isActive else { return }
        history.record(project)
        session.startCenter = clip.center
        session.startScale = clip.scale
        session.startRotation = clip.rotation
        session.resetDeltas()
        session.lastWrite = 0
        session.isActive = true
    }

    private func endGesture(text clip: TextClip, cleanup: () -> Void) {
        session.startCenter = clip.center
        session.startScale = clip.scale
        session.startRotation = clip.rotation
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
        }
    }

    private func applyText(_ binding: Binding<TextClip>, size: CGSize, force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - session.lastWrite < Self.minWriteInterval { return }
        session.lastWrite = now

        var clip = binding.wrappedValue
        let d = session.effectiveDrag
        let cx = session.startCenter.x + Double(d.width / max(size.width, 1))
        let cy = session.startCenter.y + Double(d.height / max(size.height, 1))
        clip.center = NormalizedPoint(x: min(max(cx, -0.25), 1.25), y: min(max(cy, -0.25), 1.25))
        clip.scale = min(max(session.startScale * Double(session.effectiveMagnify), 0.2), 6)
        var rotation = (session.startRotation + session.effectiveRotate).truncatingRemainder(dividingBy: 360)
        if rotation > 180 { rotation -= 360 }
        if rotation < -180 { rotation += 360 }
        clip.rotation = rotation
        binding.wrappedValue = clip
    }

    private func textGesture(_ binding: Binding<TextClip>, size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                beginIfNeeded(text: binding.wrappedValue)
                session.dragActive = true
                session.rawDrag = value.translation
                applyText(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyText(binding, size: size, force: true)
                endGesture(text: binding.wrappedValue) {
                    session.rawDrag = .zero
                    session.baseDrag = .zero
                    session.dragActive = false
                }
            }

        let magnify = MagnifyGesture()
            .onChanged { value in
                beginIfNeeded(text: binding.wrappedValue)
                session.magnifyActive = true
                session.rawMagnify = value.magnification
                applyText(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyText(binding, size: size, force: true)
                endGesture(text: binding.wrappedValue) {
                    session.rawMagnify = 1
                    session.baseMagnify = 1
                    session.magnifyActive = false
                }
            }

        let rotate = RotateGesture()
            .onChanged { value in
                beginIfNeeded(text: binding.wrappedValue)
                session.rotateActive = true
                session.rawRotate = value.rotation.degrees
                applyText(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyText(binding, size: size, force: true)
                endGesture(text: binding.wrappedValue) {
                    session.rawRotate = 0
                    session.baseRotate = 0
                    session.rotateActive = false
                }
            }

        return drag.simultaneously(with: magnify).simultaneously(with: rotate)
    }

    // MARK: - オーバーレイのジェスチャー

    private func beginIfNeeded(overlay: OverlayClip) {
        guard !session.isActive else { return }
        history.record(project)
        session.startFrame = overlay.frame
        session.resetDeltas()
        session.lastWrite = 0
        session.isActive = true
    }

    private func endGesture(overlay: OverlayClip, cleanup: () -> Void) {
        session.startFrame = overlay.frame
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
        }
    }

    private func applyOverlay(_ binding: Binding<OverlayClip>, size: CGSize, force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - session.lastWrite < Self.minWriteInterval { return }
        session.lastWrite = now

        var overlay = binding.wrappedValue
        let f = session.startFrame
        let d = session.effectiveDrag
        var w = min(max(f.width * Double(session.effectiveMagnify), 0.05), 1)
        var h = f.width > 0 ? f.height * (w / f.width) : f.height
        if h > 1 {
            w = min(1, w / h)
            h = 1
        }
        let cx = f.midX + Double(d.width / max(size.width, 1))
        let cy = f.midY + Double(d.height / max(size.height, 1))
        overlay.frame = NormalizedRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).clamped()
        binding.wrappedValue = overlay
    }

    private func overlayGesture(_ binding: Binding<OverlayClip>, size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                beginIfNeeded(overlay: binding.wrappedValue)
                session.dragActive = true
                session.rawDrag = value.translation
                applyOverlay(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyOverlay(binding, size: size, force: true)
                endGesture(overlay: binding.wrappedValue) {
                    session.rawDrag = .zero
                    session.baseDrag = .zero
                    session.dragActive = false
                }
            }

        let magnify = MagnifyGesture()
            .onChanged { value in
                beginIfNeeded(overlay: binding.wrappedValue)
                session.magnifyActive = true
                session.rawMagnify = value.magnification
                applyOverlay(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyOverlay(binding, size: size, force: true)
                endGesture(overlay: binding.wrappedValue) {
                    session.rawMagnify = 1
                    session.baseMagnify = 1
                    session.magnifyActive = false
                }
            }

        return drag.simultaneously(with: magnify)
    }
}
