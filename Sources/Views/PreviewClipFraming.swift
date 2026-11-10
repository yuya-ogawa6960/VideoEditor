import SwiftUI
import UIKit

// =====================================================================
// 選んだクリップの「映す範囲」をプレビューで直接決める(前の人の頭を外す・寄せる など)。
//   ドラッグ → 映す位置をずらす / ピンチ → ズーム(1〜4 倍)
// プレビューの外側(上下・左右の黒帯)で始めても動かせる。動かしている間と「位置・クロップ」のパネルを
// 開いている間は、映像の外にクリップの元の絵を薄く出して、どこが切れているか見えるようにする。
//
// 値は ClipGeometry に書く。映す範囲 W(回転・反転後の元の絵の 0...1、左上原点)を
//   crop   = W を含む、W と同じ縦横比のいちばん大きい窓
//   zoom   = crop の幅 ÷ W の幅
//   offset = crop の中での W の中心(-0.5...0.5)
// に分ける(「拡大」(fill)で作品と素材の縦横比が違うときも、ズームしないまま横にずらせる)。
// 動かしている間は合成を作り直さず(player.beginInteraction)、player.setLiveGeometry でいまのコマに入れる。
// 座標: このモディファイアはプレビューの置き場所いっぱいに広がり、映像(作品の縦横比でアスペクトフィット)はその中央
// =====================================================================

enum ClipFramingMath {
    /// 回転(90 度単位)後の元の絵の大きさ(ピクセル)
    static func sourceSize(of clip: Clip) -> CGSize {
        let size = clip.displaySize
        let turns = ((clip.geometry.rotationQuarterTurns % 4) + 4) % 4
        return turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    /// いまの geometry で映っている範囲(GeometryMath.applyClipGeometry と同じ計算)。
    /// 「拡大」で縦横比が違えば、キャンバスに入る真ん中の部分
    static func visibleWindow(_ g: ClipGeometry, source: CGSize, canvasAspect: Double,
                              scaling: ScalingMode) -> NormalizedRect {
        let c = g.crop.clamped()
        let z = min(max(g.zoom, 1), 8)
        let half = 1 / (2 * z)
        let ox = min(max(g.offsetX, -0.5), 0.5)
        let oy = min(max(g.offsetY, -0.5), 0.5)
        let cx = c.x + c.width * min(max(0.5 + ox, half), 1 - half)
        let cy = c.y + c.height * min(max(0.5 + oy, half), 1 - half)
        var w = c.width / z
        var h = c.height / z
        if scaling == .fill, source.width > 0, source.height > 0, canvasAspect > 0 {
            let aspect = (w * Double(source.width)) / (h * Double(source.height))
            if aspect > canvasAspect {
                w *= canvasAspect / aspect
            } else {
                h *= aspect / canvasAspect
            }
        }
        return NormalizedRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// window と同じ縦横比で、元の絵に入るいちばん大きい窓の幅・高さ(0...1)
    static func largestWindow(like window: NormalizedRect) -> (width: Double, height: Double) {
        guard window.width > 0, window.height > 0 else { return (1, 1) }
        let ratio = window.width / window.height
        return ratio >= 1 ? (1, 1 / ratio) : (ratio, 1)
    }

    /// start を 1/magnify 倍(1〜4 倍のズームの範囲)にして中心を shift だけ動かした窓。元の絵からはみ出さない
    static func moved(_ start: NormalizedRect, magnify: Double, shift: CGVector) -> NormalizedRect {
        let big = largestWindow(like: start)
        let w = min(max(start.width / max(magnify, 0.01), big.width / 4), big.width)
        let h = w * start.height / max(start.width, 0.0001)
        let cx = min(max(start.midX + Double(shift.dx), w / 2), 1 - w / 2)
        let cy = min(max(start.midY + Double(shift.dy), h / 2), 1 - h / 2)
        return NormalizedRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// V2 と並べて画面の一部に置いたクリップの、置き場所の縦横比(画面全体なら canvasAspect)
    static func paneAspect(_ g: ClipGeometry, canvasAspect: Double) -> Double {
        guard !g.canvasFrame.isFull, g.canvasFrame.height > 0.001 else { return canvasAspect }
        return canvasAspect * g.canvasFrame.width / g.canvasFrame.height
    }

    /// 画面の一部に置いたクリップは、その枠を埋める
    static func paneScaling(_ g: ClipGeometry, scaling: ScalingMode) -> ScalingMode {
        g.canvasFrame.isFull ? scaling : .fill
    }

    /// 画面の一部に置いたクリップの置き場所(プレビューの座標。canvas は作品全体の場所)
    static func paneRect(_ g: ClipGeometry, canvas: CGRect) -> CGRect {
        guard !g.canvasFrame.isFull else { return canvas }
        let f = g.canvasFrame
        return CGRect(x: canvas.minX + CGFloat(f.x) * canvas.width,
                      y: canvas.minY + CGFloat(f.y) * canvas.height,
                      width: CGFloat(f.width) * canvas.width,
                      height: CGFloat(f.height) * canvas.height)
    }

    /// 映す範囲 window を crop・zoom・offset に分けて書く(回転・反転はそのまま)
    static func geometry(for window: NormalizedRect, base: ClipGeometry) -> ClipGeometry {
        var out = base
        let big = largestWindow(like: window)
        if big.width > 0.999, big.height > 0.999 {
            out.crop = .full
        } else {
            let cx = min(max(window.midX, big.width / 2), 1 - big.width / 2)
            let cy = min(max(window.midY, big.height / 2), 1 - big.height / 2)
            out.crop = NormalizedRect(x: cx - big.width / 2, y: cy - big.height / 2, width: big.width, height: big.height)
        }
        let zoom = out.crop.width / max(window.width, 0.0001)
        if zoom < 1.005 {
            out.zoom = 1
            out.offsetX = 0
            out.offsetY = 0
        } else {
            out.zoom = min(zoom, 4)
            out.offsetX = min(max((window.midX - out.crop.x) / out.crop.width - 0.5, -0.5), 0.5)
            out.offsetY = min(max((window.midY - out.crop.y) / out.crop.height - 0.5, -0.5), 0.5)
        }
        return out
    }

    /// 作品の縦横比でアスペクトフィットした映像の場所(置き場所 container の中央)
    static func canvasRect(in container: CGSize, canvasAspect: Double) -> CGRect {
        guard container.width > 0, container.height > 0, canvasAspect > 0 else { return .zero }
        let aspect = CGFloat(canvasAspect)
        var size = CGSize(width: container.width, height: container.width / aspect)
        if size.height > container.height {
            size = CGSize(width: container.height * aspect, height: container.height)
        }
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// クリップのキーフレーム(再生位置の値)で、映像をキャンバスの中心まわりに動かす変換
    /// (プレビューの座標。ClipKeyframeRenderer と同じ 大きさ → 回転 → 位置 の順)
    static func keyframeTransform(_ value: KeyframeInterpolator.Value, canvas: CGRect) -> CGAffineTransform {
        guard !ClipKeyframeRenderer.isStill(value) else { return .identity }
        let scale = CGFloat(value.scale.isFinite ? min(max(value.scale, 0.01), 20) : 1)
        let angle = CGFloat((value.rotation.isFinite ? value.rotation : 0) * Double.pi / 180)
        let dx = CGFloat(value.center.x - 0.5) * canvas.width
        let dy = CGFloat(value.center.y - 0.5) * canvas.height
        var t = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(rotationAngle: angle))
        t = t.concatenating(CGAffineTransform(translationX: canvas.midX + dx, y: canvas.midY + dy))
        return t
    }

    /// 元の絵ぜんたいの表示位置(window が canvas に「黒帯」なら収まる・「拡大」なら埋まるように置いたとき)
    static func sourceRect(window: NormalizedRect, source: CGSize, canvas: CGRect, scaling: ScalingMode) -> CGRect {
        let winW = CGFloat(window.width) * source.width
        let winH = CGFloat(window.height) * source.height
        guard winW > 0, winH > 0 else { return canvas }
        let sx = canvas.width / winW
        let sy = canvas.height / winH
        let scale = scaling == .fill ? max(sx, sy) : min(sx, sy)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: canvas.midX - CGFloat(window.midX) * width,
                      y: canvas.midY - CGFloat(window.midY) * height,
                      width: width, height: height)
    }
}

/// ジェスチャー中の状態(再描画を起こさないよう class で持つ)
final class ClipFramingSession {
    var isActive = false
    var clipID: UUID?
    var startWindow = NormalizedRect.full
    var baseGeometry = ClipGeometry()
    var source = CGSize(width: 1, height: 1)
    var scaling: ScalingMode = .fit
    /// 指の動きで動かした窓の中心(元の絵の比率。動いた分をその時のズームで足していく。ピンチ中の指の動きは足さない)
    var shift = CGVector.zero
    var lastTranslation: CGSize?
    var magnify: CGFloat = 1
    var lastWrite: CFAbsoluteTime = 0
    /// 再生位置のクリップのキーフレームの拡大と回転(絵はこの倍率・向きで動くので、指の動きを戻すのに使う)
    var keyScale: CGFloat = 1
    var keyRotation: Double = 0
    /// この操作で履歴を記録したか(映す位置が初めて変わったときに記録する)
    var historyRecorded = false
}

extension View {
    /// 選んだクリップの映す範囲を、プレビュー(と外側の黒帯)のドラッグ・ピンチで変えられるようにする
    func clipFraming(project: EditorProject, history: EditorHistory, player: PlayerController,
                     clipID: UUID?, showsSourceAlways: Bool) -> some View {
        modifier(ClipFramingModifier(project: project, history: history, player: player,
                                     clipID: clipID, showsSourceAlways: showsSourceAlways))
    }
}

struct ClipFramingModifier: ViewModifier {
    let project: EditorProject
    let history: EditorHistory
    let player: PlayerController
    /// 動かすクリップ(nil なら何もしない)
    let clipID: UUID?
    /// 「位置・クロップ」のパネルを開いている(映像の外の元の絵をずっと出す)
    let showsSourceAlways: Bool

    @State private var session = ClipFramingSession()
    /// 動かしている途中(と離してから少しの間)。映像の外に元の絵を出す
    @State private var isAdjusting = false
    /// 映像の外に出す元の絵(再生位置のコマ)
    @State private var sourceImage: UIImage?
    @GestureState private var gestureLive = false
    /// 「ドラッグで映す位置・2本指でズーム」の案内を出し終えたか(初回だけ)
    @AppStorage("vm.clipFramingCoachShown") private var coachShown = false

    /// 1 秒間に 30 回まで
    private static let minWriteInterval: CFAbsoluteTime = 1.0 / 30.0

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black
                content
                sourceLayer(size: size)
                if clipID != nil, !coachShown {
                    coachMark
                        .frame(width: size.width, height: size.height, alignment: .bottom)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(framingGesture(size: size).updating($gestureLive) { _, state, _ in
                state = true
            }, including: clipID != nil ? .all : .subviews)
        }
        .onChange(of: gestureLive) { _, live in
            // キャンセルで onEnded が来ないときも、合成の作り直しの停止を必ず解く
            if !live { finish() }
        }
        .onChange(of: clipID) { _, _ in
            finish()
            sourceImage = nil
        }
        .onDisappear { finish() }
    }

    // MARK: - 映像の外の元の絵

    private var showsSource: Bool { clipID != nil && (isAdjusting || showsSourceAlways) }

    @ViewBuilder
    private func sourceLayer(size: CGSize) -> some View {
        if showsSource, let clipID, let i = project.index(of: clipID) {
            let clip = project.clips[i]
            let source = ClipFramingMath.sourceSize(of: clip)
            let aspect = ClipFramingMath.paneAspect(clip.geometry, canvasAspect: canvasAspect)
            let scaling = ClipFramingMath.paneScaling(clip.geometry, scaling: project.canvas.scaling)
            let window = ClipFramingMath.visibleWindow(clip.geometry, source: source, canvasAspect: aspect, scaling: scaling)
            let canvas = ClipFramingMath.paneRect(clip.geometry,
                                                  canvas: ClipFramingMath.canvasRect(in: size, canvasAspect: canvasAspect))
            let rect = ClipFramingMath.sourceRect(window: window, source: source, canvas: canvas, scaling: scaling)
            let turns = ((clip.geometry.rotationQuarterTurns % 4) + 4) % 4
            // クリップのキーフレームで拡大・移動・回転していれば、元の絵も同じだけ動かす(合成と同じ。前はずれた位置に出ていた)
            let keyValue = clip.keyframes.isEmpty
                ? ClipKeyframeTrack.identity
                : clip.keyframeValue(atSourceTime: project.sourceTime(timelineTime: player.currentTime, inClip: clip.id) ?? clip.startTime)
            let keyTransform = ClipFramingMath.keyframeTransform(keyValue,
                                                                 canvas: ClipFramingMath.canvasRect(in: size, canvasAspect: canvasAspect))
            // 映っている部分(ここには元の絵を重ねない。黒帯は作品の外でも中でも薄く出す)
            let shown = CGRect(x: rect.minX + CGFloat(window.x) * rect.width,
                               y: rect.minY + CGFloat(window.y) * rect.height,
                               width: CGFloat(window.width) * rect.width,
                               height: CGFloat(window.height) * rect.height).intersection(canvas)
            ZStack(alignment: .topLeading) {
                if let sourceImage {
                    // 向き反映済みのコマを、回転 → 反転の順に合わせる(合成と同じ)
                    Image(uiImage: sourceImage)
                        .resizable()
                        .frame(width: turns % 2 == 1 ? rect.height : rect.width,
                               height: turns % 2 == 1 ? rect.width : rect.height)
                        .rotationEffect(.degrees(Double(turns) * 90))
                        .scaleEffect(x: clip.geometry.flipHorizontal ? -1 : 1, y: clip.geometry.flipVertical ? -1 : 1)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(0.4)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .mask {
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: size))
                                if !shown.isNull { path.addRect(shown) }
                            }
                            .fill(style: FillStyle(eoFill: true))
                        }
                        .transformEffect(keyTransform)
                }
                // 書き出される範囲の縁
                Rectangle()
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    .frame(width: canvas.width, height: canvas.height)
                    .position(x: canvas.midX, y: canvas.midY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
            .task(id: sourceKey(clip)) {
                await loadSourceImage(clip)
            }
        }
    }

    /// 元の絵を読み直す目安(クリップと、再生位置の元素材の時刻を 0.5 秒単位で)
    private func sourceKey(_ clip: Clip) -> String {
        let time = ghostSourceTime(clip)
        return "\(clip.id.uuidString)-\(Int((time * 2).rounded()))"
    }

    /// 再生位置で映っているコマの、元の動画(順再生のファイル)の時刻。逆再生のクリップは前後を入れ替える
    private func ghostSourceTime(_ clip: Clip) -> Double {
        var time = project.sourceTime(timelineTime: player.currentTime, inClip: clip.id) ?? clip.startTime
        if clip.isReversed, clip.reversedURL != nil {
            time = clip.startTime + clip.endTime - time
        }
        return time
    }

    private func loadSourceImage(_ clip: Clip) async {
        let image: UIImage?
        if let still = clip.stillImageURL {
            image = await Task.detached(priority: .userInitiated) {
                PreviewProxyThumbnails.loadPhoto(still)
            }.value
        } else {
            image = await PreviewProxyThumbnails.loadVideoFrame(clip.url, at: ghostSourceTime(clip))
        }
        if Task.isCancelled { return }
        if let image { sourceImage = image }
    }

    // MARK: - 初回の案内

    private var coachMark: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 15, weight: .semibold))
            Text("ドラッグで映す位置・2本指でズーム")
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

    // MARK: - ジェスチャー

    private var canvasAspect: Double {
        let size = player.renderSize
        guard size.width > 0, size.height > 0 else { return 9.0 / 16.0 }
        return Double(size.width / size.height)
    }

    private func framingGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .simultaneously(with: MagnifyGesture())
            .onChanged { value in
                guard let clipID else { return }
                if !session.isActive {
                    guard begin(clipID) else { return }
                }
                let pinching = value.second != nil
                if let magnification = value.second?.magnification {
                    session.magnify = magnification
                }
                if let translation = value.first?.translation {
                    let last = session.lastTranslation ?? (pinching ? translation : .zero)
                    if !pinching {
                        // いまのズームでの元の絵の表示の大きさで、指の動き(pt)を比率に直す(絵が指に付いてくるように、窓は逆に動く)
                        let current = ClipFramingMath.moved(session.startWindow, magnify: Double(session.magnify),
                                                            shift: session.shift)
                        let canvas = ClipFramingMath.paneRect(session.baseGeometry,
                                                              canvas: ClipFramingMath.canvasRect(in: size, canvasAspect: canvasAspect))
                        let full = ClipFramingMath.sourceRect(window: current, source: session.source,
                                                              canvas: canvas, scaling: session.scaling)
                        if full.width > 0, full.height > 0 {
                            // クリップのキーフレームで拡大・回転していると、絵はその倍率・向きで動くので、
                            // 指の動きを向きと倍率で戻してから比率にする(前は指より速く・斜めに動いていた)
                            let ddx = translation.width - last.width
                            let ddy = translation.height - last.height
                            let r = CGFloat(session.keyRotation * Double.pi / 180)
                            let k = max(session.keyScale, 0.01)
                            let lx = (ddx * cos(r) + ddy * sin(r)) / k
                            let ly = (-ddx * sin(r) + ddy * cos(r)) / k
                            session.shift.dx -= lx / full.width
                            session.shift.dy -= ly / full.height
                        }
                    }
                    session.lastTranslation = translation
                }
                apply(size: size, force: false)
            }
            .onEnded { _ in
                apply(size: size, force: true)
                finish()
            }
    }

    /// 始める(履歴を 1 回だけ残し、合成の作り直しを止める)。再生位置がクリップの外なら、クリップの頭へ動かす
    private func begin(_ clipID: UUID) -> Bool {
        guard let i = project.index(of: clipID) else { return false }
        let clip = project.clips[i]
        if project.sourceTime(timelineTime: player.currentTime, inClip: clipID) == nil {
            let starts = project.clipStartTimes()
            if i < starts.count { player.seek(to: starts[i] + 0.05) }
        }
        // 履歴は映す位置が初めて変わる直前に記録する(apply)。触れただけ・黒帯で動かなかったときは記録せず、「やり直す」も消さない
        session.historyRecorded = false
        session.isActive = true
        session.clipID = clipID
        session.source = ClipFramingMath.sourceSize(of: clip)
        session.scaling = ClipFramingMath.paneScaling(clip.geometry, scaling: project.canvas.scaling)
        session.baseGeometry = clip.geometry
        session.startWindow = ClipFramingMath.visibleWindow(clip.geometry, source: session.source,
                                                            canvasAspect: ClipFramingMath.paneAspect(clip.geometry, canvasAspect: canvasAspect),
                                                            scaling: session.scaling)
        session.shift = .zero
        session.lastTranslation = nil
        session.magnify = 1
        session.lastWrite = 0
        // 再生位置のキーフレームの拡大・回転(キーが無ければ 1 倍・0°)
        let keyTime = project.sourceTime(timelineTime: player.currentTime, inClip: clipID) ?? clip.startTime
        let keyValue = clip.keyframes.isEmpty ? ClipKeyframeTrack.identity : clip.keyframeValue(atSourceTime: keyTime)
        session.keyScale = CGFloat(keyValue.scale.isFinite ? min(max(keyValue.scale, 0.01), 20) : 1)
        session.keyRotation = keyValue.rotation.isFinite ? keyValue.rotation : 0
        coachShown = true
        player.beginInteraction(cancelPendingRebuild: true)
        withAnimation(.easeOut(duration: 0.15)) { isAdjusting = true }
        return true
    }

    private func apply(size: CGSize, force: Bool) {
        guard session.isActive, let clipID = session.clipID, let i = project.index(of: clipID) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - session.lastWrite >= Self.minWriteInterval else { return }
        session.lastWrite = now

        let window = ClipFramingMath.moved(session.startWindow, magnify: Double(session.magnify), shift: session.shift)
        // 端を越えて動かした分は捨てる(戻すときに、すぐ動き出すように)
        session.shift = CGVector(dx: window.midX - session.startWindow.midX, dy: window.midY - session.startWindow.midY)
        let geometry = ClipFramingMath.geometry(for: window, base: session.baseGeometry)
        if project.clips[i].geometry != geometry {
            if !session.historyRecorded {
                history.record(project)
                session.historyRecorded = true
            }
            project.clips[i].geometry = geometry
            player.setLiveGeometry(geometry, for: clipID)
        }
    }

    private func finish() {
        guard session.isActive else { return }
        session.isActive = false
        session.lastTranslation = nil
        player.endInteraction()
        // 離してから少しの間だけ、映像の外の絵を残す
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !session.isActive {
                withAnimation(.easeOut(duration: 0.3)) { isAdjusting = false }
            }
        }
    }
}
