import SwiftUI
import UIKit
import AVFoundation
import ImageIO

// =====================================================================
// プレビューの上に重ねる透明なレイヤー。
// 選択中のテキスト(ステッカー)/オーバーレイに点線の枠を出し、
//   ドラッグ   → 中心位置
//   ピンチ     → 大きさ(テキスト: scale / オーバーレイ: 枠の幅、縦横比を保つ)
//   回転       → 角度(テキストのみ)
// を直接変えられる。履歴はジェスチャーの開始時に 1 回だけ記録し、
// 書き込みは 1 秒間に 30 回まで(最後の値は必ず書く)。
// 点線の枠の部分だけがタッチを受け取り、それ以外はプレビューのタップ(再生/停止)に通す。
//
// 第4弾の追加モード:
//   maskTarget    → マスクパネルを開いている間、マスクの形を点線で出し、
//                   ドラッグで中心 / ピンチで大きさ / 回転で角度を変える
//   rectSelection → トラッキングの対象を囲む四角をドラッグで描く(完了時に正規化矩形を返す)
//
// 1.5 の追加:
//   onSelect を渡すと、プレビューのタップで「今の時刻に表示中」のテキスト・ステッカー・
//   オーバーレイを上にあるものから当たり判定して選ぶ。何も無い所のタップは、
//   未選択なら再生位置のクリップを選び、選択中なら選択を外す。
//   player を渡すと、ドラッグ・ピンチ・回転の間 player.beginInteraction() / endInteraction() で
//   合成の作り直しを止める(その間は映像が古いままなので、点線の枠に半透明の代わりの絵を描いて動きを見せる)。
//   初回だけ「ドラッグで移動・2本指で拡大/回転」の案内を出す。
// 座標: このビューはアスペクトフィット後の映像の表示領域にぴったり重なる前提
//   (NormalizedPoint / NormalizedRect は左上原点の 0...1)。
// =====================================================================

/// マスクの中心をプレビュー上で動かす対象
enum PreviewMaskTarget: Equatable {
    case clip(UUID)
    case overlay(UUID)
}

/// 四角の範囲選択(トラッキングの対象を囲む)。完了時にキャンバス正規化座標(左上原点)で返す
struct PreviewRectSelection {
    let onComplete: (NormalizedRect) -> Void
}

/// ジェスチャー中の状態(再描画を起こさないよう class で持つ)
final class PreviewGestureSession {
    var isActive = false
    var dragActive = false
    var magnifyActive = false
    var rotateActive = false
    /// player.beginInteraction() を呼んで、まだ endInteraction() していない
    var interactionOpen = false

    // ジェスチャー開始時(または別のジェスチャーが終わった時)の値
    var startCenter = NormalizedPoint.center
    var startScale = 1.0
    var startRotation = 0.0
    var startFrame = NormalizedRect.full
    // マスク用(短辺比率)
    var startMaskWidth = 0.6
    var startMaskHeight = 0.6

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

    func resetFlags() {
        dragActive = false
        magnifyActive = false
        rotateActive = false
    }

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
    /// 設定するとマスクの中心・大きさ・角度をプレビュー上で操作するモードになる
    var maskTarget: PreviewMaskTarget? = nil
    /// 設定すると四角の範囲選択モードになる(通常の枠は出さない)
    var rectSelection: PreviewRectSelection? = nil
    /// 渡すとジェスチャーの間 beginInteraction() / endInteraction() で合成の作り直しを止め、
    /// タップの当たり判定に再生位置を使う
    var player: PlayerController? = nil
    /// 渡すとプレビューのタップで選択を変える(nil を渡されたら選択解除)。
    /// nil のままならタップは下(プレビューの再生/停止)に通す
    var onSelect: ((EditorSelection?) -> Void)? = nil

    @State private var session = PreviewGestureSession()
    /// 範囲選択中の四角(ビュー座標)
    @State private var dragRect: CGRect? = nil
    /// 選択中のオーバーレイの代わりの絵(ドラッグ中に半透明で出す)
    @State private var proxyImage: UIImage? = nil
    /// テキスト/オーバーレイのジェスチャーが続いている間 true(キャンセル時も自動で false に戻る)
    @GestureState private var gestureLive = false
    /// 「ドラッグで移動・2本指で拡大/回転」の案内を出し終えたか(初回だけ出す)
    @AppStorage("ux15.previewGestureCoachShown") private var coachShown = false

    /// 1 秒間に 30 回まで
    private static let minWriteInterval: CFAbsoluteTime = 1.0 / 30.0
    /// 点線の枠の隅に出す印の大きさ(14 pt 以上)
    private static let badgeIconSize: CGFloat = 14

    init(project: EditorProject,
         history: EditorHistory,
         selection: EditorSelection?,
         maskTarget: PreviewMaskTarget? = nil,
         rectSelection: PreviewRectSelection? = nil,
         player: PlayerController? = nil,
         onSelect: ((EditorSelection?) -> Void)? = nil) {
        self.project = project
        self.history = history
        self.selection = selection
        self.maskTarget = maskTarget
        self.rectSelection = rectSelection
        self.player = player
        self.onSelect = onSelect
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if let rectSelection {
                    rectSelectionLayer(rectSelection, size: size)
                } else if let maskTarget {
                    maskLayer(maskTarget, size: size)
                } else {
                    if onSelect != nil {
                        tapCatcher(size: size)
                    }
                    if let id = selection?.textID, let binding = project.textClipBinding(id: id) {
                        textFrame(binding, size: size)
                    } else if let id = selection?.overlayID, let binding = project.overlayBinding(id: id) {
                        overlayFrame(binding, size: size)
                    }
                    if showsCoachMark {
                        coachMark
                            .frame(width: size.width, height: size.height, alignment: .bottom)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .onChange(of: gestureLive) { _, live in
            // ジェスチャーがキャンセルされて onEnded が来ない場合でも、作り直しの停止を必ず解く
            if !live {
                finishInteractionIfNeeded()
            }
        }
        .onDisappear {
            finishInteractionIfNeeded()
        }
    }

    // MARK: - 合成の作り直しの停止(player.beginInteraction / endInteraction)

    private func openInteraction() {
        if !coachShown {
            coachShown = true
        }
        guard !session.interactionOpen else { return }
        session.interactionOpen = true
        player?.beginInteraction()
    }

    private func closeInteraction() {
        guard session.interactionOpen else { return }
        session.interactionOpen = false
        player?.endInteraction()
    }

    /// 開始値・差分はそのまま残す(この後に onEnded が来ても正しい値で書ける)
    private func finishInteractionIfNeeded() {
        guard session.isActive || session.interactionOpen else { return }
        session.resetFlags()
        session.isActive = false
        closeInteraction()
    }

    // MARK: - 初回の案内

    private var showsCoachMark: Bool {
        guard !coachShown else { return false }
        return selection?.textID != nil || selection?.overlayID != nil
    }

    private var coachMark: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 15, weight: .semibold))
            Text("ドラッグで移動・2本指で拡大/回転")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7), in: Capsule())
        .padding(.bottom, 12)
        .allowsHitTesting(false)
        .transition(.opacity)
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.3)) {
                coachShown = true
            }
        }
    }

    // MARK: - タップで選択

    /// 全面でタップを受ける(ほぼ透明)。点線の枠はこの上にあるので枠のジェスチャーが優先される
    private func tapCatcher(size: CGSize) -> some View {
        Color.white.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(at: location, size: size)
            }
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        guard let onSelect else { return }
        let time: Double = player?.currentTime ?? 0
        if let hit = hitTest(at: location, size: size, time: time) {
            if hit != selection {
                UISelectionFeedbackGenerator().selectionChanged()
                onSelect(hit)
            }
            return
        }
        // 何も無い所: 選択中なら外す、未選択なら再生位置のクリップを選ぶ
        if selection != nil {
            onSelect(nil)
            return
        }
        guard let located = project.locate(timelineTime: time),
              located.index >= 0, located.index < project.clips.count else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect(.clip(project.clips[located.index].id))
    }

    /// 今の時刻に表示中のテキスト・ステッカー・オーバーレイを上から順に当たり判定する。
    /// 描画順はオーバーレイ(開始が早い順)→ テキスト(配列の順)なので、その逆順に調べる
    private func hitTest(at point: CGPoint, size: CGSize, time: Double) -> EditorSelection? {
        guard size.width > 0, size.height > 0 else { return nil }

        for clip in project.textClips.reversed() where clip.contains(timelineTime: time) {
            let placed = Self.placedText(clip, at: time)
            let rect = Self.estimatedRect(for: placed, in: size)
            if Self.hit(point, rect: rect, rotation: placed.rotation) {
                return .text(clip.id)
            }
        }

        let indexed: [(offset: Int, element: OverlayClip)] = Array(project.overlays.enumerated())
        let ordered = indexed.sorted { (a: (offset: Int, element: OverlayClip), b: (offset: Int, element: OverlayClip)) -> Bool in
            if a.element.start != b.element.start {
                return a.element.start < b.element.start
            }
            return a.offset < b.offset
        }
        for item in ordered.reversed() {
            let overlay = item.element
            guard overlay.contains(timelineTime: time) else { continue }
            guard overlay.effectiveOpacity(at: time) > 0.05 else { continue }
            let placed = Self.placedOverlayRect(overlay, at: time, in: size)
            if Self.hit(point, rect: placed.rect, rotation: placed.rotation) {
                return .overlay(overlay.id)
            }
        }
        return nil
    }

    /// キーフレームを反映したテキスト(位置・大きさ・角度)
    private static func placedText(_ clip: TextClip, at time: Double) -> TextClip {
        guard !clip.keyframes.isEmpty else { return clip }
        let fallback = KeyframeInterpolator.Value(center: clip.center, scale: clip.scale,
                                                  rotation: clip.rotation, opacity: clip.opacity)
        let local: Double = time - clip.start
        let value = KeyframeInterpolator.value(at: local, keyframes: clip.keyframes, fallback: fallback)
        var placed = clip
        placed.center = value.center
        placed.scale = value.scale
        placed.rotation = value.rotation
        return placed
    }

    /// キーフレームを反映したオーバーレイの枠(ビュー座標)と角度
    private static func placedOverlayRect(_ overlay: OverlayClip, at time: Double, in size: CGSize) -> (rect: CGRect, rotation: Double) {
        let base = overlay.frame.rect(in: size)
        guard !overlay.keyframes.isEmpty else { return (base, 0) }
        let fallback = KeyframeInterpolator.Value(center: NormalizedPoint(x: overlay.frame.midX, y: overlay.frame.midY),
                                                  scale: 1, rotation: 0, opacity: overlay.opacity)
        let local: Double = time - overlay.start
        let value = KeyframeInterpolator.value(at: local, keyframes: overlay.keyframes, fallback: fallback)
        let center = value.center.point(in: size)
        let scale = CGFloat(max(0.01, value.scale))
        let w: CGFloat = base.width * scale
        let h: CGFloat = base.height * scale
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        return (rect, value.rotation)
    }

    /// 回転した矩形の当たり判定(小さい物も指で押せるよう最低 44 pt に広げる)
    private static func hit(_ point: CGPoint, rect: CGRect, rotation: Double) -> Bool {
        let halfW: CGFloat = max(rect.width, 44) / 2
        let halfH: CGFloat = max(rect.height, 44) / 2
        let dx: CGFloat = point.x - rect.midX
        let dy: CGFloat = point.y - rect.midY
        let angle: Double = -rotation * Double.pi / 180
        let cosA = CGFloat(cos(angle))
        let sinA = CGFloat(sin(angle))
        let lx: CGFloat = dx * cosA - dy * sinA
        let ly: CGFloat = dx * sinA + dy * cosA
        return abs(lx) <= halfW && abs(ly) <= halfH
    }

    // MARK: - 範囲選択(トラッキング)

    private static func rect(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        let x0 = min(max(min(a.x, b.x), 0), size.width)
        let x1 = min(max(max(a.x, b.x), 0), size.width)
        let y0 = min(max(min(a.y, b.y), 0), size.height)
        let y1 = min(max(max(a.y, b.y), 0), size.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func rectSelectionLayer(_ selectionMode: PreviewRectSelection, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // 全面でタッチを受ける(ほぼ透明)
            Color.white.opacity(0.001)

            if let r = dragRect {
                Rectangle()
                    .fill(Color.yellow.opacity(0.15))
                    .overlay { Rectangle().stroke(Color.yellow, lineWidth: 2) }
                    .frame(width: max(r.width, 1), height: max(r.height, 1))
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }

            Text("追いかけたい対象を囲むようにドラッグ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    dragRect = Self.rect(from: value.startLocation, to: value.location, in: size)
                }
                .onEnded { value in
                    let r = Self.rect(from: value.startLocation, to: value.location, in: size)
                    dragRect = nil
                    guard r.width >= 8, r.height >= 8, size.width > 0, size.height > 0 else { return }
                    let normalized = NormalizedRect(x: Double(r.minX / size.width),
                                                    y: Double(r.minY / size.height),
                                                    width: Double(r.width / size.width),
                                                    height: Double(r.height / size.height)).clamped()
                    selectionMode.onComplete(normalized)
                }
        )
    }

    // MARK: - マスク

    @ViewBuilder
    private func maskLayer(_ target: PreviewMaskTarget, size: CGSize) -> some View {
        switch target {
        case .clip(let id):
            if let clipBinding = project.clipBinding(id: id) {
                let maskBinding = Binding<MaskSettings>(
                    get: { clipBinding.wrappedValue.mask },
                    set: { newValue in
                        var clip = clipBinding.wrappedValue
                        clip.mask = newValue
                        clipBinding.wrappedValue = clip
                    }
                )
                maskFrame(maskBinding, container: CGRect(origin: .zero, size: size))
            }
        case .overlay(let id):
            if let overlayBinding = project.overlayBinding(id: id) {
                let maskBinding = Binding<MaskSettings>(
                    get: { overlayBinding.wrappedValue.mask },
                    set: { newValue in
                        var overlay = overlayBinding.wrappedValue
                        overlay.mask = newValue
                        overlayBinding.wrappedValue = overlay
                    }
                )
                // オーバーレイのマスクはそのオーバーレイの枠の中で考える
                maskFrame(maskBinding, container: overlayBinding.wrappedValue.frame.rect(in: size))
            }
        }
    }

    /// マスクの点線の大きさ(ビュー座標)。直線・帯は横長のバーで表す
    private static func maskFrameSize(_ mask: MaskSettings, short: CGFloat) -> CGSize {
        switch mask.shape {
        case .linear:
            return CGSize(width: short * 1.6, height: 10)
        case .mirror:
            return CGSize(width: short * 1.6, height: max(CGFloat(mask.height) * short, 10))
        default:
            return CGSize(width: max(CGFloat(mask.width) * short, 24),
                          height: max(CGFloat(mask.height) * short, 24))
        }
    }

    /// マスクの形の点線(container はマスク座標の基準になる矩形、ビュー座標)
    @ViewBuilder
    private func maskFrame(_ binding: Binding<MaskSettings>, container: CGRect) -> some View {
        let mask = binding.wrappedValue
        if mask.shape != .none {
            let short = max(min(container.width, container.height), 1)
            let center = CGPoint(x: container.minX + CGFloat(mask.center.x) * container.width,
                                 y: container.minY + CGFloat(mask.center.y) * container.height)
            let frameSize = Self.maskFrameSize(mask, short: short)
            maskShapeView(mask, size: frameSize, short: short)
                .frame(width: frameSize.width, height: frameSize.height)
                .contentShape(Rectangle())
                .gesture(maskGesture(binding, container: container).updating($gestureLive) { _, state, _ in
                    state = true
                })
                .rotationEffect(.degrees(mask.rotation))
                .position(center)
        }
    }

    private var maskBadge: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: Self.badgeIconSize, weight: .bold))
            .foregroundStyle(.black)
            .padding(4)
            .background(Color.white.opacity(0.9), in: Circle())
    }

    @ViewBuilder
    private func maskShapeView(_ mask: MaskSettings, size: CGSize, short: CGFloat) -> some View {
        let style = StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        let tint = Color.white.opacity(0.9)
        switch mask.shape {
        case .circle:
            Ellipse()
                .stroke(style: style)
                .foregroundStyle(tint)
                .background { Ellipse().fill(Color.white.opacity(0.001)) }
                .overlay { maskBadge }
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: min(CGFloat(mask.cornerRadius) * short, min(size.width, size.height) / 2))
                .stroke(style: style)
                .foregroundStyle(tint)
                .background { Color.white.opacity(0.001) }
                .overlay { maskBadge }
        case .linear:
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .overlay { maskBadge }
        default:
            Rectangle()
                .stroke(style: style)
                .foregroundStyle(tint)
                .background { Color.white.opacity(0.001) }
                .overlay { maskBadge }
        }
    }

    private func beginIfNeeded(mask: MaskSettings) {
        guard !session.isActive else { return }
        history.record(project)
        session.startCenter = mask.center
        session.startMaskWidth = mask.width
        session.startMaskHeight = mask.height
        session.startRotation = mask.rotation
        session.resetDeltas()
        session.resetFlags()
        session.lastWrite = 0
        session.isActive = true
        openInteraction()
    }

    private func endGesture(mask: MaskSettings, cleanup: () -> Void) {
        session.startCenter = mask.center
        session.startMaskWidth = mask.width
        session.startMaskHeight = mask.height
        session.startRotation = mask.rotation
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
            closeInteraction()
        }
    }

    private func applyMask(_ binding: Binding<MaskSettings>, container: CGRect, force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - session.lastWrite < Self.minWriteInterval { return }
        session.lastWrite = now

        var mask = binding.wrappedValue
        let d = session.effectiveDrag
        let cx = session.startCenter.x + Double(d.width / max(container.width, 1))
        let cy = session.startCenter.y + Double(d.height / max(container.height, 1))
        mask.center = NormalizedPoint(x: min(max(cx, -0.25), 1.25), y: min(max(cy, -0.25), 1.25))
        let m = Double(session.effectiveMagnify)
        mask.width = min(max(session.startMaskWidth * m, 0.05), 3)
        mask.height = min(max(session.startMaskHeight * m, 0.05), 3)
        var rotation = (session.startRotation + session.effectiveRotate).truncatingRemainder(dividingBy: 360)
        if rotation > 180 { rotation -= 360 }
        if rotation < -180 { rotation += 360 }
        mask.rotation = rotation
        binding.wrappedValue = mask
    }

    private func maskGesture(_ binding: Binding<MaskSettings>, container: CGRect) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                beginIfNeeded(mask: binding.wrappedValue)
                session.dragActive = true
                session.rawDrag = value.translation
                applyMask(binding, container: container, force: false)
            }
            .onEnded { _ in
                applyMask(binding, container: container, force: true)
                endGesture(mask: binding.wrappedValue) {
                    session.rawDrag = .zero
                    session.baseDrag = .zero
                    session.dragActive = false
                }
            }

        let magnify = MagnifyGesture()
            .onChanged { value in
                beginIfNeeded(mask: binding.wrappedValue)
                session.magnifyActive = true
                session.rawMagnify = value.magnification
                applyMask(binding, container: container, force: false)
            }
            .onEnded { _ in
                applyMask(binding, container: container, force: true)
                endGesture(mask: binding.wrappedValue) {
                    session.rawMagnify = 1
                    session.baseMagnify = 1
                    session.magnifyActive = false
                }
            }

        let rotate = RotateGesture()
            .onChanged { value in
                beginIfNeeded(mask: binding.wrappedValue)
                session.rotateActive = true
                session.rawRotate = value.rotation.degrees
                applyMask(binding, container: container, force: false)
            }
            .onEnded { _ in
                applyMask(binding, container: container, force: true)
                endGesture(mask: binding.wrappedValue) {
                    session.rawRotate = 0
                    session.baseRotate = 0
                    session.rotateActive = false
                }
            }

        return drag.simultaneously(with: magnify).simultaneously(with: rotate)
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

    /// 点線の枠。ジェスチャー中は proxy(半透明の代わりの絵)を枠の中に出す
    private func dashedFrame<Proxy: View>(width: CGFloat, height: CGFloat, badge: String,
                                          @ViewBuilder proxy: () -> Proxy) -> some View {
        let w: CGFloat = max(width, 28)
        let h: CGFloat = max(height, 28)
        return ZStack {
            if gestureLive {
                proxy()
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)
            }
            RoundedRectangle(cornerRadius: 4)
                .stroke(style: StrokeStyle(lineWidth: gestureLive ? 2 : 1.5, dash: [6, 4]))
                .foregroundStyle(Color.white.opacity(0.9))
                .shadow(color: Color.black.opacity(0.5), radius: 1)
        }
        .background(Color.white.opacity(0.001))
        .overlay(alignment: .topLeading) {
            Image(systemName: badge)
                .font(.system(size: Self.badgeIconSize, weight: .bold))
                .foregroundStyle(.black)
                .padding(5)
                .background(Color.white.opacity(0.9), in: Circle())
                .offset(x: -12, y: -12)
                .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
    }

    /// テキストの代わりの絵(実際の描画はエンジン側なので近似)
    private func textProxy(_ clip: TextClip, size: CGSize) -> some View {
        let short: CGFloat = min(size.width, size.height)
        let base: CGFloat = CGFloat(clip.style.sizeRatio) * short
        let fontPx: CGFloat = max(base * CGFloat(clip.scale), 6)
        let color: Color = Color(hex: clip.style.colorHex) ?? .white
        let font: Font
        if let name = clip.style.fontName {
            font = Font.custom(name, size: fontPx)
        } else {
            font = Font.system(size: fontPx, weight: clip.style.bold ? .bold : .regular)
        }
        var background: Color = .clear
        if let hex = clip.style.backgroundColorHex, let bg = Color(hex: hex) {
            background = bg.opacity(clip.style.backgroundOpacity)
        }
        return Text(clip.text)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.3)
            .padding(2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: Color.black.opacity(0.6), radius: 2)
            .opacity(0.7)
    }

    /// オーバーレイの代わりの絵(素材のサムネイル。読み込み前は薄い四角)
    @ViewBuilder
    private func overlayProxy(_ overlay: OverlayClip) -> some View {
        if let image = proxyImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: overlay.fit == .fit ? .fit : .fill)
                .clipped()
                .opacity(0.6)
        } else {
            ZStack {
                Color.white.opacity(0.25)
                Image(systemName: overlay.isImage ? "photo" : "film")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }

    private func textFrame(_ binding: Binding<TextClip>, size: CGSize) -> some View {
        let clip = binding.wrappedValue
        let rect = Self.estimatedRect(for: clip, in: size)
        return dashedFrame(width: rect.width, height: rect.height, badge: "arrow.up.and.down.and.arrow.left.and.right") {
            textProxy(clip, size: size)
        }
        .gesture(textGesture(binding, size: size).updating($gestureLive) { _, state, _ in
            state = true
        })
        // 選択中の枠のタップは下(再生/停止や選択解除)に通さない
        .gesture(TapGesture().onEnded { }, including: onSelect != nil ? .gesture : .none)
        .rotationEffect(.degrees(clip.rotation))
        .position(x: rect.midX, y: rect.midY)
    }

    private func overlayFrame(_ binding: Binding<OverlayClip>, size: CGSize) -> some View {
        let overlay = binding.wrappedValue
        let rect = overlay.frame.rect(in: size)
        return dashedFrame(width: rect.width, height: rect.height, badge: "arrow.up.and.down.and.arrow.left.and.right") {
            overlayProxy(overlay)
        }
        .gesture(overlayGesture(binding, size: size).updating($gestureLive) { _, state, _ in
            state = true
        })
        .gesture(TapGesture().onEnded { }, including: onSelect != nil ? .gesture : .none)
        .position(x: rect.midX, y: rect.midY)
        .task(id: overlay.url) {
            proxyImage = nil
            let image = await PreviewProxyThumbnails.shared.image(for: overlay)
            if Task.isCancelled { return }
            proxyImage = image
        }
    }

    // MARK: - テキストのジェスチャー

    private func beginIfNeeded(text clip: TextClip) {
        guard !session.isActive else { return }
        history.record(project)
        session.startCenter = clip.center
        session.startScale = clip.scale
        session.startRotation = clip.rotation
        session.resetDeltas()
        session.resetFlags()
        session.lastWrite = 0
        session.isActive = true
        openInteraction()
    }

    private func endGesture(text clip: TextClip, cleanup: () -> Void) {
        session.startCenter = clip.center
        session.startScale = clip.scale
        session.startRotation = clip.rotation
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
            closeInteraction()
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
        session.resetFlags()
        session.lastWrite = 0
        session.isActive = true
        openInteraction()
    }

    private func endGesture(overlay: OverlayClip, cleanup: () -> Void) {
        session.startFrame = overlay.frame
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
            closeInteraction()
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

// MARK: - ドラッグ中の代わりの絵(オーバーレイ素材のサムネイル)

/// オーバーレイ素材の小さなサムネイル。URL ごとに覚えておく(数が増えたら捨てる)
@MainActor
final class PreviewProxyThumbnails {
    static let shared = PreviewProxyThumbnails()

    private var cache: [URL: UIImage] = [:]
    nonisolated private static let maxPixelSize: CGFloat = 480

    func image(for overlay: OverlayClip) async -> UIImage? {
        let url = overlay.url
        if let cached = cache[url] { return cached }
        let image: UIImage?
        if overlay.isImage {
            image = await Task.detached(priority: .userInitiated) {
                PreviewProxyThumbnails.loadPhoto(url)
            }.value
        } else {
            image = await PreviewProxyThumbnails.loadVideoFrame(url, at: overlay.sourceStart)
        }
        if let image {
            if cache.count >= 24 {
                cache.removeAll()
            }
            cache[url] = image
        }
        return image
    }

    nonisolated static func loadPhoto(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func loadVideoFrame(_ url: URL, at seconds: Double) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let result = try await generator.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }
}
