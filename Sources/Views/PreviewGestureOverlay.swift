import SwiftUI
import UIKit
import AVFoundation
import ImageIO

// =====================================================================
// プレビューの上に重ねる透明なレイヤー。
// 選択中のテキスト(ステッカー・モザイク)/オーバーレイに点線の枠を出し、
//   ドラッグ   → 中心位置(枠の上で。映像の中央から 8 pt 以内は吸い付き、細い線で示す)
//   ピンチ     → 大きさ(テキスト: scale / オーバーレイ: 枠の幅、縦横比を保つ)
//   回転       → 角度(6° 未満は無視。0 / ±90 / 180 の 4° 以内は吸い付く)
// を直接変えられる。ピンチと回転は選択中ならプレビューのどこで始めてもよい(小さな部品でもつまめる)。
// 履歴はジェスチャーの開始時に 1 回だけ記録し、書き込みは 1 秒間に 30 回まで(最後の値は必ず書く)。
// 点線の枠の部分だけがタッチを受け取り、それ以外はプレビューのタップ(再生/停止)に通す。
// キーフレームのある部品は、枠を再生位置の配置(描画と同じ補間値)で出し、
// ジェスチャーの結果は基本の値ではなく、ジェスチャーを始めた時刻のキーフレームに書く(KeyframeEditing)。
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

/// キーフレームのある部品のジェスチャー開始時の状態。
/// time はキーを書く時刻(部品の開始からの相対秒)、value はその時刻の補間値、keyframes は開始時の列
struct PreviewKeyedStart {
    var time: Double
    var value: KeyframeInterpolator.Value
    var keyframes: [Keyframe]
}

/// ジェスチャー中の状態(再描画を起こさないよう class で持つ)
final class PreviewGestureSession {
    var isActive = false
    var dragActive = false
    var magnifyActive = false
    var rotateActive = false
    /// player.beginInteraction() を呼んで、まだ endInteraction() していない
    var interactionOpen = false

    // ジェスチャー開始時(または別のジェスチャーが終わった時)の値。キーフレームがあれば再生位置の補間値
    var startCenter = NormalizedPoint.center
    var startScale = 1.0
    var startRotation = 0.0
    var startFrame = NormalizedRect.full
    // モザイクの幅・高さ(キーフレームのあるモザイクは、ピンチでこちらを変える)
    var startWidthRatio = 0.3
    var startHeightRatio = 0.22
    // マスク用(短辺比率)
    var startMaskWidth = 0.6
    var startMaskHeight = 0.6
    /// キーフレームのある部品なら、キーを書く時刻と開始時の列(無ければ nil = 基本の値に書く)
    var keyed: PreviewKeyedStart? = nil
    /// 2 本指の回転が 6° を超えて「本当に回している」と分かったか(それまでは無視する)
    var rotateUnlocked = false
    /// いま吸い付いている角度(nil = 吸い付いていない)。吸い付いた瞬間だけ振動させるために持つ
    var snappedRotation: Double? = nil

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
    // モザイクの四隅のハンドル・回転のつまみ(ドラッグの始まりの状態)
    @State private var mosaicHandleStart: MosaicHandleStart? = nil
    @State private var mosaicKnobStart: MosaicHandleStart? = nil
    /// マスクの四隅の●をドラッグし始めたときの中心と幅・高さ(短辺比)
    @State private var maskHandleStart: (center: NormalizedPoint, width: Double, height: Double)? = nil
    @State private var maskKnobActive = false
    /// テキスト/オーバーレイの枠のドラッグが続いている間 true(キャンセル時も自動で false に戻る)
    @GestureState private var gestureLive = false
    /// プレビュー全体のピンチ・回転が続いている間 true(同上)
    @GestureState private var previewPinchLive = false
    /// ドラッグ中、中心が映像の中央に吸い付いているか(x = 縦線、y = 横線を出す)
    @State private var snapGuide: (x: Bool, y: Bool) = (false, false)
    /// 「ドラッグで移動・2本指で拡大/回転」の案内を出し終えたか(初回だけ出す)
    @AppStorage("ux15.previewGestureCoachShown") private var coachShown = false

    /// 1 秒間に 30 回まで
    private static let minWriteInterval: CFAbsoluteTime = 1.0 / 30.0
    /// 点線の枠の隅に出す印の大きさ(14 pt 以上)
    private static let badgeIconSize: CGFloat = 14
    /// 2 本指の回転はこの角度(度)未満なら無視する(ピンチのつもりで傾かないように)
    private static let rotationDeadZone = 6.0
    /// 0 / ±90 / 180 からこの角度(度)以内なら吸い付く
    private static let rotationSnap = 4.0
    /// 中心が映像の中央からこの距離(pt)以内なら吸い付く
    private static let centerSnapDistance: CGFloat = 8

    /// 枠のドラッグかプレビュー全体のピンチ・回転が続いている
    private var isGestureLive: Bool { gestureLive || previewPinchLive }

    /// 選択中のテキスト/オーバーレイをプレビューのどこでもピンチ・回転できる状態か
    private var hasPinchTarget: Bool {
        rectSelection == nil && maskTarget == nil && (selection?.textID != nil || selection?.overlayID != nil)
    }

    /// モザイクの四隅の●・回転のつまみをドラッグ中(この間はプレビュー全体のピンチ・回転を受けない。
    /// ●に置いた指から始まった 2 本指が、幅・高さと scale・角度を同時に書かないように)
    private var mosaicHandleActive: Bool {
        mosaicHandleStart != nil || mosaicKnobStart != nil
    }

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
                    snapGuides(size: size)
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
            // 選択中はプレビューのどこで始めてもピンチ・回転できる(枠の上で始めた分もここで受ける)
            .simultaneousGesture(previewPinchGesture(size: size).updating($previewPinchLive) { _, state, _ in
                state = true
            }, including: hasPinchTarget ? .all : .subviews)
        }
        .onChange(of: isGestureLive) { _, live in
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
        clearSnapGuides()
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
        guard !overlay.keyframes.isEmpty else { return (base, overlay.rotation) }
        let fallback = KeyframeInterpolator.Value(center: NormalizedPoint(x: overlay.frame.midX, y: overlay.frame.midY),
                                                  scale: 1, rotation: overlay.rotation, opacity: overlay.opacity)
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
                // オーバーレイのマスクはそのオーバーレイの枠の中で考える(キーフレームがあれば再生位置の枠)
                let overlay = overlayBinding.wrappedValue
                let container = Self.placedOverlayRect(overlay, at: frameTime(for: overlay.keyframes), in: size).rect
                maskFrame(maskBinding, container: container)
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
                // モザイクと同じ: 四隅の●で大きさ、上のつまみで回転(枠と一緒に回る)
                .overlay {
                    maskHandles(binding, frame: frameSize, short: short, container: container)
                }
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

    /// マスクの枠に重ねるハンドル。四角・角丸・楕円は四隅の●で幅・高さ、どの形も上のつまみで回転
    private func maskHandles(_ binding: Binding<MaskSettings>, frame: CGSize, short: CGFloat,
                             container: CGRect) -> some View {
        let mask = binding.wrappedValue
        let knobDistance: CGFloat = 30
        let showsCorners = mask.shape != .linear && mask.shape != .mirror
        return ZStack {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.white)
                        .frame(width: 28, height: 28)
                        .shadow(color: Color.black.opacity(0.5), radius: 2)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1.5, height: knobDistance - 14)
            }
            .frame(width: 44, height: 44 + knobDistance, alignment: .top)
            .contentShape(Rectangle())
            .offset(y: -frame.height / 2 - knobDistance - 8)
            .gesture(maskKnobGesture(binding, frame: frame, knobDistance: knobDistance + 8))

            if maskKnobActive {
                Text(verbatim: "\(Int(mask.rotation.rounded()))°")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .rotationEffect(.degrees(-mask.rotation))
                    .offset(y: -frame.height / 2 - knobDistance - 48)
                    .allowsHitTesting(false)
            }

            if showsCorners {
                ForEach(MosaicCorner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.5), radius: 2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .offset(x: corner.sx * frame.width / 2, y: corner.sy * frame.height / 2)
                        .gesture(maskCornerGesture(binding, corner: corner, short: short, container: container))
                }
            }
        }
    }

    /// 四隅の●: 向かいの角を動かさずに幅・高さを変える(モザイクと同じ計算。大きさは短辺比、中心は container 比)
    private func maskCornerGesture(_ binding: Binding<MaskSettings>, corner: MosaicCorner, short: CGFloat,
                                   container: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                var mask = binding.wrappedValue
                if maskHandleStart == nil {
                    history.record(project)
                    openInteraction()
                    maskHandleStart = (mask.center, mask.width, mask.height)
                }
                guard let start = maskHandleStart else { return }
                // 指の動きを、マスクの向きに合わせた軸(枠の縦横)へ直す
                let r = CGFloat(mask.rotation * Double.pi / 180)
                let dx = value.translation.width
                let dy = value.translation.height
                let lx = dx * cos(r) + dy * sin(r)
                let ly = -dx * sin(r) + dy * cos(r)
                let w0 = CGFloat(start.width) * short
                let h0 = CGFloat(start.height) * short
                let minSide: CGFloat = 24
                let w = max(minSide, w0 + corner.sx * lx)
                let h = max(minSide, h0 + corner.sy * ly)
                // 向かいの角を動かさない: 中心を枠の軸で (Δw/2, Δh/2) ずらし、画面の向きに戻す
                let sx = corner.sx * (w - w0) / 2
                let sy = corner.sy * (h - h0) / 2
                let shiftX = sx * cos(r) - sy * sin(r)
                let shiftY = sx * sin(r) + sy * cos(r)
                let base = max(short, 1)
                mask.width = min(max(Double(w / base), 0.05), 3)
                mask.height = min(max(Double(h / base), 0.05), 3)
                mask.center = NormalizedPoint(x: min(max(start.center.x + Double(shiftX / max(container.width, 1)), -0.25), 1.25),
                                              y: min(max(start.center.y + Double(shiftY / max(container.height, 1)), -0.25), 1.25))
                binding.wrappedValue = mask
            }
            .onEnded { _ in
                maskHandleStart = nil
                closeInteraction()
            }
    }

    /// 上のつまみ: 中心のまわりに回す(0° / 90° / 180° の近くは吸い付く)
    private func maskKnobGesture(_ binding: Binding<MaskSettings>, frame: CGSize, knobDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                var mask = binding.wrappedValue
                if !maskKnobActive {
                    history.record(project)
                    openInteraction()
                    maskKnobActive = true
                    session.startRotation = mask.rotation
                }
                let r0 = CGFloat(session.startRotation * Double.pi / 180)
                let length = frame.height / 2 + knobDistance
                let knob = CGPoint(x: length * sin(r0), y: -length * cos(r0))
                let v = CGPoint(x: knob.x + value.translation.width, y: knob.y + value.translation.height)
                var degrees = atan2(Double(v.y), Double(v.x)) * 180 / Double.pi + 90
                if degrees > 180 { degrees -= 360 }
                if degrees < -180 { degrees += 360 }
                for snap in [-180.0, -90.0, 0.0, 90.0, 180.0] where abs(degrees - snap) < 4 {
                    degrees = snap == 180 ? -180 : snap
                }
                mask.rotation = degrees
                binding.wrappedValue = mask
            }
            .onEnded { _ in
                maskKnobActive = false
                closeInteraction()
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
        // モザイクは実際の範囲(clip はキーフレーム反映済みなので、キーフレームを外して計算する)
        if let mosaic = clip.mosaic {
            let w: CGFloat = size.width * CGFloat(clip.widthRatio) * CGFloat(clip.scale)
            let h: CGFloat = size.height * CGFloat(mosaic.heightRatio) * CGFloat(clip.scale)
            let c = clip.center.point(in: size)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }
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
            if isGestureLive {
                proxy()
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)
            }
            RoundedRectangle(cornerRadius: 4)
                .stroke(style: StrokeStyle(lineWidth: isGestureLive ? 2 : 1.5, dash: [6, 4]))
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
        // キーフレームがあれば再生位置の配置(描画と同じ補間値)で枠を出す
        let placed = Self.placedText(clip, at: frameTime(for: clip.keyframes))
        let rect = Self.estimatedRect(for: placed, in: size)
        let frameSize = CGSize(width: max(rect.width, 28), height: max(rect.height, 28))
        return dashedFrame(width: rect.width, height: rect.height, badge: "arrow.up.and.down.and.arrow.left.and.right") {
            textProxy(placed, size: size)
        }
        .overlay {
            if clip.isMosaic {
                mosaicHandles(binding, placed: placed, size: size, frame: frameSize)
            }
        }
        // パネルの「±15°」などで回したときも、映像からはみ出さないようにする
        .onChange(of: clip.rotation) { _, _ in
            guard binding.wrappedValue.isMosaic else { return }
            var fitted = binding.wrappedValue
            fitted.keepMosaicInside(size)
            if fitted.scale != binding.wrappedValue.scale || fitted.center != binding.wrappedValue.center {
                binding.wrappedValue = fitted
            }
        }
        // 枠で受けるのはドラッグだけ(ピンチ・回転はプレビュー全体で受ける)
        .gesture(textDragGesture(binding, size: size).updating($gestureLive) { _, state, _ in
            state = true
        })
        // 選択中の枠のタップは下(再生/停止や選択解除)に通さない
        .gesture(TapGesture().onEnded { }, including: onSelect != nil ? .gesture : .none)
        .rotationEffect(.degrees(placed.rotation))
        .position(x: rect.midX, y: rect.midY)
    }

    private func overlayFrame(_ binding: Binding<OverlayClip>, size: CGSize) -> some View {
        let overlay = binding.wrappedValue
        // キーフレームがあれば再生位置の枠と角度(描画と同じ補間値)
        let placed = Self.placedOverlayRect(overlay, at: frameTime(for: overlay.keyframes), in: size)
        let rect = placed.rect
        return dashedFrame(width: rect.width, height: rect.height, badge: "arrow.up.and.down.and.arrow.left.and.right") {
            overlayProxy(overlay)
        }
        .gesture(overlayDragGesture(binding, size: size).updating($gestureLive) { _, state, _ in
            state = true
        })
        .gesture(TapGesture().onEnded { }, including: onSelect != nil ? .gesture : .none)
        // 枠と代わりの絵もオーバーレイと同じ向きに回す(描画と同じく時計回りが正)
        .rotationEffect(.degrees(placed.rotation))
        .position(x: rect.midX, y: rect.midY)
        .task(id: overlay.url) {
            proxyImage = nil
            let image = await PreviewProxyThumbnails.shared.image(for: overlay)
            if Task.isCancelled { return }
            proxyImage = image
        }
    }

    // MARK: - モザイクのハンドル(四隅で大きさ、上のつまみで回転)

    private enum MosaicCorner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var sx: CGFloat { self == .topLeft || self == .bottomLeft ? -1 : 1 }
        var sy: CGFloat { self == .topLeft || self == .topRight ? -1 : 1 }
    }

    /// 四隅の●・回転のつまみをドラッグし始めたときの状態(center・scale・rotation は再生位置の配置)
    private struct MosaicHandleStart {
        var center: NormalizedPoint
        var scale: Double
        var rotation: Double
        /// 幅・高さ(画面比、scale 込み)
        var width: Double
        var height: Double
        /// キーフレームがあれば、書く時刻と開始時の列
        var keyed: PreviewKeyedStart?
    }

    private func makeMosaicHandleStart(_ clip: TextClip) -> MosaicHandleStart {
        let keyed = keyedStart(for: clip)
        pauseIfKeyed(keyed)
        let placed = keyed?.value ?? Self.baseValue(clip)
        return MosaicHandleStart(center: placed.center,
                                 scale: placed.scale,
                                 rotation: placed.rotation,
                                 width: clip.widthRatio * placed.scale,
                                 height: (clip.mosaic?.heightRatio ?? 0.22) * placed.scale,
                                 keyed: keyed)
    }

    /// 枠の中に重ねる(枠と一緒に回転する)。四隅の●で幅・高さ、上のつまみで回転。placed は再生位置の配置
    private func mosaicHandles(_ binding: Binding<TextClip>, placed: TextClip, size: CGSize, frame: CGSize) -> some View {
        let knobDistance: CGFloat = 30
        return ZStack {
            // 回転のつまみ(上辺の中央から線で伸びる)
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.white)
                        .frame(width: 28, height: 28)
                        .shadow(color: Color.black.opacity(0.5), radius: 2)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1.5, height: knobDistance - 14)
            }
            .frame(width: 44, height: 44 + knobDistance, alignment: .top)
            .contentShape(Rectangle())
            .offset(y: -frame.height / 2 - knobDistance - 8)
            .gesture(mosaicKnobGesture(binding, size: size, frame: frame, knobDistance: knobDistance + 8))

            if mosaicKnobStart != nil {
                Text(verbatim: "\(Int(placed.rotation.rounded()))°")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .rotationEffect(.degrees(-placed.rotation))
                    .offset(y: -frame.height / 2 - knobDistance - 48)
                    .allowsHitTesting(false)
            }

            // 四隅の●(ドラッグで幅・高さ。向かいの角は動かない)
            ForEach(MosaicCorner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.5), radius: 2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .offset(x: corner.sx * frame.width / 2, y: corner.sy * frame.height / 2)
                    .gesture(mosaicCornerGesture(binding, corner: corner, size: size))
            }
        }
    }

    private func mosaicCornerGesture(_ binding: Binding<TextClip>, corner: MosaicCorner, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                var clip = binding.wrappedValue
                if mosaicHandleStart == nil {
                    // 枠のドラッグやプレビュー全体のピンチが進んでいる間は●を始めない(同じ値を 2 か所から書かない)
                    guard !session.isActive else { return }
                    history.record(project)
                    openInteraction()
                    mosaicHandleStart = makeMosaicHandleStart(clip)
                }
                guard let start = mosaicHandleStart else { return }
                // 指の動きを、モザイクの向きに合わせた軸(枠の縦横)へ直す
                let r = CGFloat(start.rotation * Double.pi / 180)
                let dx = value.translation.width
                let dy = value.translation.height
                let lx = dx * cos(r) + dy * sin(r)
                let ly = -dx * sin(r) + dy * cos(r)
                let w0 = CGFloat(start.width) * size.width
                let h0 = CGFloat(start.height) * size.height
                let minSide: CGFloat = 24
                let w = max(minSide, w0 + corner.sx * lx)
                let h = max(minSide, h0 + corner.sy * ly)
                // 向かいの角を動かさない: 中心を枠の軸で (Δw/2, Δh/2) ずらし、画面の向きに戻す
                let sx = corner.sx * (w - w0) / 2
                let sy = corner.sy * (h - h0) / 2
                let shiftX = sx * cos(r) - sy * sin(r)
                let shiftY = sx * sin(r) + sy * cos(r)
                let scale = max(start.scale, 0.01)
                clip.widthRatio = min(max(Double(w / max(size.width, 1)) / scale, 0.02), 3)
                clip.mosaic?.heightRatio = min(max(Double(h / max(size.height, 1)) / scale, 0.02), 3)
                let center = NormalizedPoint(x: start.center.x + Double(shiftX / max(size.width, 1)),
                                             y: start.center.y + Double(shiftY / max(size.height, 1)))
                // 位置を書く(キーフレームがあれば再生位置のキーへ)。回転した枠が映像からはみ出さないようにする
                writePlacement(center: center, scale: start.scale, rotation: start.rotation,
                               keyed: start.keyed, to: &clip, size: size)
                binding.wrappedValue = clip
            }
            .onEnded { _ in
                // 始めなかった(ピンチ中だった)●は、ピンチが開いた作り直しの停止を閉じない
                guard mosaicHandleStart != nil else { return }
                mosaicHandleStart = nil
                closeInteraction()
            }
    }

    private func mosaicKnobGesture(_ binding: Binding<TextClip>, size: CGSize, frame: CGSize,
                                   knobDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                var clip = binding.wrappedValue
                if mosaicKnobStart == nil {
                    // 枠のドラッグやプレビュー全体のピンチが進んでいる間はつまみを始めない
                    guard !session.isActive else { return }
                    history.record(project)
                    openInteraction()
                    mosaicKnobStart = makeMosaicHandleStart(clip)
                }
                guard let start = mosaicKnobStart else { return }
                // つまみの最初の位置(中心からのベクトル、画面の向き)に指の動きを足して角度にする
                let r0 = CGFloat(start.rotation * Double.pi / 180)
                let length = frame.height / 2 + knobDistance
                let knob = CGPoint(x: length * sin(r0), y: -length * cos(r0))
                let v = CGPoint(x: knob.x + value.translation.width, y: knob.y + value.translation.height)
                var degrees = atan2(Double(v.y), Double(v.x)) * 180 / Double.pi + 90
                if degrees > 180 { degrees -= 360 }
                if degrees < -180 { degrees += 360 }
                // 0° / 90° / 180° の近くは吸い付く
                for snap in [-180.0, -90.0, 0.0, 90.0, 180.0] where abs(degrees - snap) < 4 {
                    degrees = snap == 180 ? -180 : snap
                }
                // 角度を書く(キーフレームがあれば再生位置のキーへ)。回すと外接する範囲が広がるので、
                // 映像からはみ出す分は縮めて内側へ寄せる
                writePlacement(center: start.center, scale: start.scale, rotation: degrees,
                               keyed: start.keyed, to: &clip, size: size)
                binding.wrappedValue = clip
            }
            .onEnded { _ in
                guard mosaicKnobStart != nil else { return }
                mosaicKnobStart = nil
                closeInteraction()
            }
    }

    // MARK: - キーフレームのある部品(枠は再生位置の配置、書き込みは始めた時刻のキーへ)

    /// 枠を出す時刻(再生位置)。キーフレームの無い部品は基本の値をそのまま使うので再生位置を読まない(再描画を減らす)
    private func frameTime(for keyframes: [Keyframe]) -> Double {
        guard !keyframes.isEmpty, let player else { return 0 }
        return player.currentTime
    }

    /// キーを書く時刻 = 再生位置の、部品の先頭からの相対秒(範囲内に丸める。EditorKeyframePanel と同じ)
    private func keyTime(start: Double, duration: Double) -> Double {
        let now: Double = player?.currentTime ?? start
        return min(max(now - start, 0), max(duration, 0))
    }

    /// 基本の値(キーフレームを見ない配置)
    private static func baseValue(_ clip: TextClip) -> KeyframeInterpolator.Value {
        KeyframeInterpolator.Value(center: clip.center, scale: clip.scale, rotation: clip.rotation, opacity: clip.opacity)
    }

    private static func baseValue(_ overlay: OverlayClip) -> KeyframeInterpolator.Value {
        KeyframeInterpolator.Value(center: NormalizedPoint(x: overlay.frame.midX, y: overlay.frame.midY),
                                   scale: 1, rotation: overlay.rotation, opacity: overlay.opacity)
    }

    /// キーフレームのある部品なら、ジェスチャーを始めた再生位置のキーの時刻と補間値(無ければ nil)
    private func keyedStart(for clip: TextClip) -> PreviewKeyedStart? {
        guard !clip.keyframes.isEmpty else { return nil }
        let time = keyTime(start: clip.start, duration: clip.duration)
        let value = KeyframeInterpolator.value(at: time, keyframes: clip.keyframes, fallback: Self.baseValue(clip))
        return PreviewKeyedStart(time: time, value: value, keyframes: clip.keyframes)
    }

    private func keyedStart(for overlay: OverlayClip) -> PreviewKeyedStart? {
        guard !overlay.keyframes.isEmpty else { return nil }
        let time = keyTime(start: overlay.start, duration: overlay.duration)
        let value = KeyframeInterpolator.value(at: time, keyframes: overlay.keyframes, fallback: Self.baseValue(overlay))
        return PreviewKeyedStart(time: time, value: value, keyframes: overlay.keyframes)
    }

    /// 別のジェスチャーが終わったあと、キーの時刻はそのままに補間値と列を今の状態に合わせ直す
    private func reseeded(_ keyed: PreviewKeyedStart?, keyframes: [Keyframe],
                          fallback: KeyframeInterpolator.Value) -> PreviewKeyedStart? {
        guard let keyed, !keyframes.isEmpty else { return nil }
        let value = KeyframeInterpolator.value(at: keyed.time, keyframes: keyframes, fallback: fallback)
        return PreviewKeyedStart(time: keyed.time, value: value, keyframes: keyframes)
    }

    /// キーフレームを書き換えるときは再生を止める(枠と書き込み先の時刻がずれないように)
    private func pauseIfKeyed(_ keyed: PreviewKeyedStart?) {
        guard keyed != nil else { return }
        player?.pause()
    }

    /// 位置・大きさ(scale)・角度をテキスト/モザイクに書く。
    /// キーフレームがあれば(keyed)基本の値は変えず、ジェスチャーを始めた時刻のキーに書く(KeyframeEditing)
    private func writePlacement(center: NormalizedPoint, scale: Double, rotation: Double,
                                keyed: PreviewKeyedStart?, to clip: inout TextClip, size: CGSize) {
        if let keyed {
            let value = KeyframeInterpolator.Value(center: center, scale: scale, rotation: rotation,
                                                   opacity: keyed.value.opacity)
            clip.keyframes = KeyframeEditing.applying(value, from: keyed.value, at: keyed.time, to: keyed.keyframes)
        } else {
            clip.center = center
            clip.scale = scale
            clip.rotation = rotation
            // モザイクは、回転した枠が映像からはみ出さないようにする(テキストはそのまま)
            if clip.isMosaic { clip.keepMosaicInside(size) }
        }
    }

    // MARK: - 吸い付き(中央の位置・0 / 90 / 180 度)

    /// 中央に吸い付いている間の細い線(縦 = x、横 = y)
    @ViewBuilder
    private func snapGuides(size: CGSize) -> some View {
        if snapGuide.x {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: 1, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
                .allowsHitTesting(false)
        }
        if snapGuide.y {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: size.height / 2)
                .allowsHitTesting(false)
        }
    }

    /// ドラッグの始まりで、すでに中央にある軸は「吸い付き済み」にしておく(始めた瞬間に振動させない)
    private func seedSnapGuides(size: CGSize) {
        let c = session.startCenter
        snapGuide = (abs(CGFloat(c.x - 0.5)) * size.width <= Self.centerSnapDistance,
                     abs(CGFloat(c.y - 0.5)) * size.height <= Self.centerSnapDistance)
    }

    private func clearSnapGuides() {
        if snapGuide.x || snapGuide.y {
            snapGuide = (false, false)
        }
    }

    /// ドラッグ中、中心が映像の中央(0.5)から 8 pt 以内なら縦・横それぞれ別に吸い付ける。
    /// 吸い付いている軸は細い線で示し、吸い付いた瞬間に 1 回だけ振動する
    private func snappedCenter(_ center: NormalizedPoint, size: CGSize) -> NormalizedPoint {
        guard session.dragActive else { return center }
        var c = center
        let snapX = abs(CGFloat(c.x - 0.5)) * size.width <= Self.centerSnapDistance
        let snapY = abs(CGFloat(c.y - 0.5)) * size.height <= Self.centerSnapDistance
        if snapX { c.x = 0.5 }
        if snapY { c.y = 0.5 }
        if (snapX && !snapGuide.x) || (snapY && !snapGuide.y) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        if snapGuide.x != snapX || snapGuide.y != snapY {
            snapGuide = (snapX, snapY)
        }
        return c
    }

    /// ちょうど 0 / ±90 / 180 にあるならその角度(吸い付き済みとして扱う)
    private static func snapTarget(near rotation: Double) -> Double? {
        let r = KeyframeEditing.normalizedDegrees(rotation)
        return [-180.0, -90.0, 0.0, 90.0, 180.0].first { abs(r - $0) < 0.001 }
    }

    /// 2 本指の回転の角度を決める。6° 未満は無視し(一度超えたら以後は指に付いてくる)、
    /// 0 / ±90 / 180 の 4° 以内は吸い付く(吸い付いた瞬間に 1 回だけ振動)
    private func rotationWithSnap(start: Double, delta: Double) -> Double {
        if !session.rotateUnlocked {
            if abs(delta) < Self.rotationDeadZone { return KeyframeEditing.normalizedDegrees(start) }
            session.rotateUnlocked = true
        }
        var rotation = KeyframeEditing.normalizedDegrees(start + delta)
        var snapped: Double? = nil
        for target in [-180.0, -90.0, 0.0, 90.0, 180.0] where abs(rotation - target) < Self.rotationSnap {
            rotation = target == 180 ? -180 : target
            snapped = rotation
        }
        if let snapped, snapped != session.snappedRotation {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        session.snappedRotation = snapped
        return rotation
    }

    // MARK: - プレビュー全体のピンチ・回転(選択中のテキスト/オーバーレイ)

    /// 選択中の部品の大きさ・角度を、プレビューのどこで始めた 2 本指でも変えられるようにする
    private func previewPinchGesture(size: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                // ●・つまみのドラッグ中に始まった 2 本指は無視する(そのドラッグが終わるまで)
                guard !mosaicHandleActive else { return }
                beginSelectedIfNeeded()
                session.magnifyActive = true
                session.rawMagnify = value.magnification
                applySelected(size: size, force: false)
            }
            .onEnded { _ in
                guard !mosaicHandleActive else { return }
                applySelected(size: size, force: true)
                endSelectedGesture {
                    session.rawMagnify = 1
                    session.baseMagnify = 1
                    session.magnifyActive = false
                }
            }

        let rotate = RotateGesture()
            .onChanged { value in
                guard !mosaicHandleActive else { return }
                beginSelectedIfNeeded()
                session.rotateActive = true
                session.rawRotate = value.rotation.degrees
                applySelected(size: size, force: false)
            }
            .onEnded { _ in
                guard !mosaicHandleActive else { return }
                applySelected(size: size, force: true)
                endSelectedGesture {
                    session.rawRotate = 0
                    session.baseRotate = 0
                    session.rotateActive = false
                    // 次にひねるときも 6° を超えてから付いてくる
                    session.rotateUnlocked = false
                }
            }

        return magnify.simultaneously(with: rotate)
    }

    private func beginSelectedIfNeeded() {
        if let id = selection?.textID, let binding = project.textClipBinding(id: id) {
            beginIfNeeded(text: binding.wrappedValue)
        } else if let id = selection?.overlayID, let binding = project.overlayBinding(id: id) {
            beginIfNeeded(overlay: binding.wrappedValue)
        }
    }

    private func applySelected(size: CGSize, force: Bool) {
        guard session.isActive else { return }
        if let id = selection?.textID, let binding = project.textClipBinding(id: id) {
            applyText(binding, size: size, force: force)
        } else if let id = selection?.overlayID, let binding = project.overlayBinding(id: id) {
            applyOverlay(binding, size: size, force: force)
        }
    }

    private func endSelectedGesture(cleanup: () -> Void) {
        if let id = selection?.textID, let binding = project.textClipBinding(id: id) {
            endGesture(text: binding.wrappedValue, cleanup: cleanup)
        } else if let id = selection?.overlayID, let binding = project.overlayBinding(id: id) {
            endGesture(overlay: binding.wrappedValue, cleanup: cleanup)
        } else {
            // 部品が消えた・選択が外れた: 状態だけ片付ける
            cleanup()
            finishInteractionIfNeeded()
        }
    }

    // MARK: - テキストのジェスチャー

    private func beginIfNeeded(text clip: TextClip) {
        guard !session.isActive else { return }
        history.record(project)
        let keyed = keyedStart(for: clip)
        pauseIfKeyed(keyed)
        seedStart(text: clip, keyed: keyed)
        session.resetDeltas()
        session.resetFlags()
        session.lastWrite = 0
        session.rotateUnlocked = false
        session.snappedRotation = Self.snapTarget(near: session.startRotation)
        session.isActive = true
        openInteraction()
    }

    /// 開始値を clip の配置に合わせる(キーフレームがあれば、書く時刻の補間値)
    private func seedStart(text clip: TextClip, keyed: PreviewKeyedStart?) {
        let placed = keyed?.value ?? Self.baseValue(clip)
        session.startCenter = placed.center
        session.startScale = placed.scale
        session.startRotation = placed.rotation
        session.startWidthRatio = clip.widthRatio
        session.startHeightRatio = clip.mosaic?.heightRatio ?? 0.22
        session.keyed = keyed
    }

    private func endGesture(text clip: TextClip, cleanup: () -> Void) {
        seedStart(text: clip, keyed: reseeded(session.keyed, keyframes: clip.keyframes, fallback: Self.baseValue(clip)))
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
            clearSnapGuides()
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
        let center = snappedCenter(NormalizedPoint(x: min(max(cx, -0.25), 1.25), y: min(max(cy, -0.25), 1.25)), size: size)
        var scale = min(max(session.startScale * Double(session.effectiveMagnify), 0.2), 6)
        let rotation = rotationWithSnap(start: session.startRotation, delta: session.effectiveRotate)
        if session.keyed != nil, clip.isMosaic {
            // キーフレームのあるモザイクの大きさは幅・高さの比率で持ち、キーの scale は変えない
            // (顔モザイクのキーは scale 1 のまま。ContentView の顔モザイクと同じ持ち方)
            let m = Double(session.effectiveMagnify)
            clip.widthRatio = min(max(session.startWidthRatio * m, 0.02), 3)
            clip.mosaic?.heightRatio = min(max(session.startHeightRatio * m, 0.02), 3)
            scale = session.startScale
        }
        writePlacement(center: center, scale: scale, rotation: rotation, keyed: session.keyed, to: &clip, size: size)
        binding.wrappedValue = clip
    }

    /// 枠のドラッグ(位置)。ピンチ・回転は previewPinchGesture がプレビュー全体で受ける
    private func textDragGesture(_ binding: Binding<TextClip>, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                beginIfNeeded(text: binding.wrappedValue)
                if !session.dragActive {
                    session.dragActive = true
                    seedSnapGuides(size: size)
                }
                session.rawDrag = value.translation
                applyText(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyText(binding, size: size, force: true)
                endGesture(text: binding.wrappedValue) {
                    session.rawDrag = .zero
                    session.baseDrag = .zero
                    session.dragActive = false
                    clearSnapGuides()
                }
            }
    }

    // MARK: - オーバーレイのジェスチャー

    private func beginIfNeeded(overlay: OverlayClip) {
        guard !session.isActive else { return }
        history.record(project)
        let keyed = keyedStart(for: overlay)
        pauseIfKeyed(keyed)
        seedStart(overlay: overlay, keyed: keyed)
        session.resetDeltas()
        session.resetFlags()
        session.lastWrite = 0
        session.rotateUnlocked = false
        session.snappedRotation = Self.snapTarget(near: session.startRotation)
        session.isActive = true
        openInteraction()
    }

    /// 開始値をオーバーレイの配置に合わせる(キーフレームがあれば、書く時刻の補間値)
    private func seedStart(overlay: OverlayClip, keyed: PreviewKeyedStart?) {
        let placed = keyed?.value ?? Self.baseValue(overlay)
        session.startFrame = overlay.frame
        session.startCenter = placed.center
        session.startScale = placed.scale
        session.startRotation = placed.rotation
        session.keyed = keyed
    }

    private func endGesture(overlay: OverlayClip, cleanup: () -> Void) {
        seedStart(overlay: overlay,
                  keyed: reseeded(session.keyed, keyframes: overlay.keyframes, fallback: Self.baseValue(overlay)))
        session.rebase()
        cleanup()
        if !session.anyActive {
            session.isActive = false
            clearSnapGuides()
            closeInteraction()
        }
    }

    private func applyOverlay(_ binding: Binding<OverlayClip>, size: CGSize, force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - session.lastWrite < Self.minWriteInterval { return }
        session.lastWrite = now

        var overlay = binding.wrappedValue
        let d = session.effectiveDrag
        let cx = session.startCenter.x + Double(d.width / max(size.width, 1))
        let cy = session.startCenter.y + Double(d.height / max(size.height, 1))
        let rotation = rotationWithSnap(start: session.startRotation, delta: session.effectiveRotate)
        if let keyed = session.keyed {
            // キーフレームがあるとき: 枠(基本の値)は変えず、位置・大きさ・角度を始めた時刻のキーに書く
            let center = snappedCenter(NormalizedPoint(x: min(max(cx, -0.25), 1.25), y: min(max(cy, -0.25), 1.25)), size: size)
            let scale = min(max(session.startScale * Double(session.effectiveMagnify), 0.05), 6)
            let value = KeyframeInterpolator.Value(center: center, scale: scale, rotation: rotation,
                                                   opacity: keyed.value.opacity)
            overlay.keyframes = KeyframeEditing.applying(value, from: keyed.value, at: keyed.time, to: keyed.keyframes)
        } else {
            let f = session.startFrame
            var w = min(max(f.width * Double(session.effectiveMagnify), 0.05), 1)
            var h = f.width > 0 ? f.height * (w / f.width) : f.height
            if h > 1 {
                w = min(1, w / h)
                h = 1
            }
            let center = snappedCenter(NormalizedPoint(x: cx, y: cy), size: size)
            overlay.frame = NormalizedRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h).clamped()
            overlay.rotation = rotation
        }
        binding.wrappedValue = overlay
    }

    /// 枠のドラッグ(位置)。ピンチ・回転は previewPinchGesture がプレビュー全体で受ける
    private func overlayDragGesture(_ binding: Binding<OverlayClip>, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                beginIfNeeded(overlay: binding.wrappedValue)
                if !session.dragActive {
                    session.dragActive = true
                    seedSnapGuides(size: size)
                }
                session.rawDrag = value.translation
                applyOverlay(binding, size: size, force: false)
            }
            .onEnded { _ in
                applyOverlay(binding, size: size, force: true)
                endGesture(overlay: binding.wrappedValue) {
                    session.rawDrag = .zero
                    session.baseDrag = .zero
                    session.dragActive = false
                    clearSnapGuides()
                }
            }
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
