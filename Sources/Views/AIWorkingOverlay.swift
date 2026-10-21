import SwiftUI
import UIKit
import CoreImage
import CoreVideo
import Observation

// =====================================================================
// 解析中の表示: いま AI が見ているコマ(AnalysisPeek)と、ロボットが動画を
// 切ったり・つないだり・ペンキで塗ったりするアニメーション。
// =====================================================================

/// 解析中に AI が見ているコマ(AnalysisFrameReader から 1 秒に 3 回まで届く)
@Observable
final class AnalysisPeek {
    static let shared = AnalysisPeek()

    private(set) var frame: CGImage?

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var lastPost: CFAbsoluteTime = 0
    /// 小さな見本を作るだけなので CPU で描く(書き出しの GPU と取り合わない・裏でも GPU を使わない)
    @ObservationIgnored private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    /// アプリが前面にあるか(裏に回っている間は見本を作らない)
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForeground(false)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForeground(true)
        })
    }

    private func setForeground(_ value: Bool) {
        lock.lock()
        isForeground = value
        lock.unlock()
    }

    /// 解析中のコマを渡す(間引いて縮小し、メインスレッドで表示に反映)
    func post(_ buffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard isForeground, now - lastPost > 0.33 else {
            lock.unlock()
            return
        }
        lastPost = now
        lock.unlock()
        let image = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return }
        let scale = min(1, 320 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.frame = cg
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.frame = nil
        }
    }
}

/// ロボットがすること
enum RobotTask {
    /// 動画を切る・つなぐ・塗るを順に
    case editing
    /// 虫めがねで見る(チェック・顔探し・追跡など)
    case looking
    /// ヘッドホンで聞く(文字起こしなど)
    case listening

    static func from(title: String) -> RobotTask {
        // タイトルの言葉から作業の種類を決める(日本語・英語・ポルトガル語・インドネシア語・スペイン語)
        let lower = title.lowercased()
        let listening = [String(localized: "文字起こし"), String(localized: "聞"), String(localized: "字幕"), "transcri", "caption", "subtitle", "legenda", "transkrip", "teks", "subtítul", "voz", "voice", "speech"]
        if listening.contains(where: { lower.contains($0) }) { return .listening }
        let editing = [String(localized: "おまかせ"), String(localized: "作成"), String(localized: "編集"), String(localized: "スライド"), "auto", "edit", "creat", "slideshow", "crear", "criar", "buat", "otomatis", "automát"]
        if editing.contains(where: { lower.contains($0) }) { return .editing }
        return .looking
    }
}

/// 作業中のカード(AI が見ている映像 + ロボット + 進み具合)。解析・AI 処理・書き出しで共通
struct AIWorkingCard: View {
    let title: String
    let fraction: Double?
    let task: RobotTask
    /// 進み具合の下に出す補足(残り時間・状態など)
    let detail: String?
    /// 裏で続くかどうかの注意書きとそのアイコン
    let note: String
    let noteIcon: String
    /// カードの中に小さな広告を入れる(上に大きな広告を出せないときだけ)
    let inlineAd: Bool
    let onCancel: (() -> Void)?

    @State private var peek = AnalysisPeek.shared

    /// 解析・AI 処理(ClipFXProgress)用
    init(progress: ClipFXProgress, inlineAd: Bool = true, onCancel: (() -> Void)?) {
        title = progress.title
        fraction = progress.fraction
        task = RobotTask.from(title: progress.title)
        detail = nil
        note = BackgroundWorkNote.analysis
        noteIcon = BackgroundWorkNote.canContinueInBackground ? "lock.open" : "exclamationmark.triangle"
        self.inlineAd = inlineAd
        self.onCancel = onCancel
    }

    /// 書き出しなど、タイトルと進み具合を直接渡す
    init(title: String, fraction: Double?, task: RobotTask, detail: String? = nil,
         note: String, noteIcon: String, inlineAd: Bool = true, onCancel: (() -> Void)?) {
        self.title = title
        self.fraction = fraction
        self.task = task
        self.detail = detail
        self.note = note
        self.noteIcon = noteIcon
        self.inlineAd = inlineAd
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 14) {
            if let frame = peek.frame {
                AIScanningFrame(image: frame)
                    .frame(height: 150)
            }
            RobotWorkshop(task: task, monitorFrame: peek.frame)

            if let fraction {
                let clamped = min(max(fraction, 0), 1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(BrandStyle.gradient)
                            .frame(width: max(8, geo.size.width * clamped))
                    }
                }
                .frame(height: 8)
                Text("\(title) \(Int((clamped * 100).rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
            } else {
                Text(title)
                    .font(.callout)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if inlineAd {
                NativeAdCard()
            }
            Label(note, systemImage: noteIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onCancel {
                Button {
                    EditorHaptics.tap()
                    onCancel()
                } label: {
                    Text("キャンセル")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onDisappear { AnalysisPeek.shared.clear() }
    }
}

/// 1 枚絵のロボット(フィルムを抱えて歩く係など)をゆっくり上下に浮かせる。動画が無いときの画面などに
struct FloatingRobot: View {
    let name: String
    var height: CGFloat = 150

    @State private var up = false

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .offset(y: up ? -6 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}

/// 作業中のカードの上に、画面に空きがあれば大きめのネイティブ広告を出す。空きが無ければカードだけ(中に小さな広告)
struct WorkingCardWithAd<Card: View>: View {
    @ViewBuilder let card: (_ inlineAd: Bool) -> Card

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 14) {
                NativeAdPanel()
                card(false)
            }
            card(true)
        }
    }
}

/// AI が見ているコマ + 上下に動く走査線と四隅の枠
struct AIScanningFrame: View {
    let image: CGImage

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 2.2) + 1) / 2
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    // 走査線
                    LinearGradient(colors: [BrandStyle.coral.opacity(0), BrandStyle.coral.opacity(0.75), BrandStyle.coral.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 26)
                        .offset(y: CGFloat(phase) * (geo.size.height - 26))
                        .blendMode(.screen)
                    // 四隅の枠
                    CornerBrackets()
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .padding(8)
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                            .opacity(Int(t * 2) % 2 == 0 ? 1 : 0.3)
                        Text("AI が見ています")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let l: CGFloat = 16
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

// MARK: - ロボット(Gemini で作った粘土の画像パーツ + 撮影機材を、ストップモーション風に動かす)
// 動きはブラウザの試作 robot_scene.html と同じ数字(キーフレーム・位置・大きさ)。

/// 動きをなめらかにする小さな関数
private enum RobotMotion {
    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        return min(max((x - a) / (b - a), 0), 1)
    }

    /// 0 から出て 1 まで上がり、また 0 に戻る山。x が 0...1 の外では 0
    static func bump(_ x: Double, rise: Double, fall: Double) -> Double {
        guard x > 0, x < 1 else { return 0 }
        return smooth(ramp(x, 0, rise)) * (1 - smooth(ramp(x, 1 - fall, 1)))
    }

    /// まばたき(約 3.6 秒ごとに 2 コマ閉じる)
    static func blink(_ t: Double) -> Bool {
        let phase = ((t + 1.3).truncatingRemainder(dividingBy: 3.6) + 3.6).truncatingRemainder(dividingBy: 3.6)
        return bump(phase / 0.28, rise: 0.45, fall: 0.45) > 0.5
    }

    /// 向きを変える: 途中で薄い板のようにつぶさず、1〜2 コマ小さく跳ねながらパッと裏返る
    static func turn(_ f: Double) -> (facing: CGFloat, squash: CGFloat, lift: CGFloat) {
        let turning = abs(f) < 0.9
        return (f >= 0 ? 1 : -1, turning ? 0.86 : 1, turning ? 1.6 : 0)
    }
}

/// キーフレームの列(ポーズ・トゥ・ポーズ)。各キーは「その時刻に、この値へ、この入り方で着く」
private struct RobotTrack {
    enum Ease { case hold, lin, io, out, easeIn, back }
    struct Key {
        let t: Double
        let v: Double
        let e: Ease
    }

    let cycle: Double
    let keys: [Key]

    init(_ cycle: Double, _ keys: [Key]) {
        self.cycle = cycle
        self.keys = keys
    }

    private static func ease(_ e: Ease, _ u: Double) -> Double {
        switch e {
        case .hold: return 0
        case .lin: return u
        case .io: return u * u * (3 - 2 * u)
        case .out: return 1 - pow(1 - u, 3)
        case .easeIn: return u * u * u
        case .back:
            let c1 = 1.7, c3 = c1 + 1
            return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
        }
    }

    func callAsFunction(_ time: Double) -> Double {
        var t = time.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        guard let last = keys.last else { return 0 }
        var prev = last
        var prevT = last.t - cycle
        for k in keys {
            if t < k.t {
                let span = k.t - prevT
                let u = span > 0 ? min(max((t - prevT) / span, 0), 1) : 1
                return prev.v + (k.v - prev.v) * Self.ease(k.e, u)
            }
            prev = k
            prevT = k.t
        }
        let first = keys[0]
        let span = first.t + cycle - prevT
        let u = span > 0 ? min(max((t - prevT) / span, 0), 1) : 1
        return prev.v + (first.v - prev.v) * Self.ease(first.e, u)
    }
}

/// キーを短く書く
private func rk(_ t: Double, _ v: Double, _ e: RobotTrack.Ease = .io) -> RobotTrack.Key {
    RobotTrack.Key(t: t, v: v, e: e)
}

/// ロボットの道具(右手に持つ画像パーツ)
private enum RobotToolKind {
    case magnifier, scissors, tape, brush, megaphone, pencil

    var image: String {
        switch self {
        case .magnifier: return "robot_magnifier"
        case .scissors: return "robot_scissors"
        case .tape: return "robot_tape"
        case .brush: return "robot_brush"
        case .megaphone: return "robot_megaphone"
        case .pencil: return "robot_pencil"
        }
    }

    /// 画像の大きさ(ロボット座標)、手に入る点(画像の中の割合)、画像の中で道具が向いている向き(度。0 = 右、90 = 下)。
    /// 持つときは「手に入る点」を手の中心に合わせ、向きが腕の向きと同じになるように回す
    var spec: (size: CGSize, grip: UnitPoint, direction: Double) {
        switch self {
        case .scissors: return (CGSize(width: 23, height: 24.5), UnitPoint(x: 0.74, y: 0.80), -125)
        case .magnifier: return (CGSize(width: 17, height: 23), UnitPoint(x: 0.80, y: 0.86), -125)
        case .megaphone: return (CGSize(width: 24, height: 23.5), UnitPoint(x: 0.74, y: 0.86), -150)
        case .brush: return (CGSize(width: 17, height: 22), UnitPoint(x: 0.22, y: 0.78), -52)
        case .pencil: return (CGSize(width: 15.5, height: 21), UnitPoint(x: 0.62, y: 0.40), 130)
        case .tape: return (CGSize(width: 22, height: 15), UnitPoint(x: 0.45, y: 0.55), 50)
        }
    }
}

/// ロボットの姿勢(1 コマ分)。置き場所はシーン座標(足の中心)、部品の角度はロボット座標
private struct RobotPose {
    var feetX: CGFloat = 0
    /// 床からの高さ(跳ねる・台に乗る)
    var lift: CGFloat = 0
    /// 1 = 右向き、-1 = 左向き
    var facing: CGFloat = 1
    /// 前かがみ(度)。向きに合わせて回す
    var lean: Double = 0
    var squashX: CGFloat = 1
    var squashY: CGFloat = 1

    var bob: CGFloat = 0
    var torsoTilt: Double = 0
    var headTilt: Double = 0
    var look: CGFloat = 0
    var blink = false
    var happy = false
    /// アンテナの傾き(度)
    var antenna: Double = 0
    /// 腕の角度(度。0 = 右、90 = 下、-90 = 上)
    var leftArm: Double = 100
    var rightArm: Double = 80
    /// 脚の上がり
    var legL: CGFloat = 0
    var legR: CGFloat = 0
    var tool: RobotToolKind? = nil
    var toolPresence: Double = 1
    /// 道具を手の中で回す量(度)。下ろした腕でメガホンを水平に持つときなど
    var toolRot: Double = 0
    var toolScale: CGFloat = 1
    /// 両手でフィルムのリールを持つ
    var carry = false
    var carryDX: CGFloat = 0
    var carryDY: CGFloat = 0
    var carryRot: Double = 0
    var headphones = false
}

/// 画像パーツの大きさと位置(72 × 92 のロボット座標)
private enum RobotRig {
    static let faceSize = CGSize(width: 50, height: 44)
    static let faceCenter = CGPoint(x: 36, y: 30)
    static let faceAnchor = UnitPoint(x: 0.5, y: 0.75)
    static let antennaSize = CGSize(width: 14, height: 17)
    static let antennaFoot = CGPoint(x: 44, y: 12)
    static let antennaTilt = 18.0
    static let torsoSize = CGSize(width: 34, height: 35)
    static let torsoCenter = CGPoint(x: 36, y: 64)
    static let torsoAnchor = UnitPoint(x: 0.5, y: 0.9)
    static let legSize = CGSize(width: 14, height: 15.5)
    static let legY: CGFloat = 84
    static let legLeftX: CGFloat = 28.5
    static let legRightX: CGFloat = 43.5
    static let armSize = CGSize(width: 11, height: 22.5)
    static let armY: CGFloat = 52
    static let armLeftX: CGFloat = 21
    static let armRightX: CGFloat = 51
    static let armPivot = UnitPoint(x: 0.5, y: 0.03)
    static let armHandY: CGFloat = 0.747
    static let reelSize = CGSize(width: 26, height: 26)
    static let reelCenter = CGPoint(x: 36, y: 66)
    static let headphonesSize = CGSize(width: 56, height: 46)
    static let headphonesCenter = CGPoint(x: 36, y: 28)
    /// 足の中心(回転・つぶれ・向きの軸)。枠は 100 × 92
    static let feet = UnitPoint(x: 0.36, y: 1.0)
}

/// 粘土のロボット 1 体(100 × 92 のロボット座標で組む。置き場所・向き・傾き・つぶれは RobotOnStage が付ける)
private struct Robot: View {
    let pose: RobotPose

    var body: some View {
        let hb = pose.bob
        let bb = pose.bob / 2
        let hand = Self.hand(x: RobotRig.armRightX, y: RobotRig.armY + bb, angle: pose.rightArm)
        ZStack {
            part("robot_antenna", RobotRig.antennaSize)
                .rotationEffect(.degrees(RobotRig.antennaTilt + pose.antenna), anchor: UnitPoint(x: 0.5, y: 1))
                .position(x: RobotRig.antennaFoot.x, y: RobotRig.antennaFoot.y + hb - RobotRig.antennaSize.height / 2)
            part("robot_leg", RobotRig.legSize)
                .position(x: RobotRig.legLeftX, y: RobotRig.legY - pose.legL)
            part("robot_leg", RobotRig.legSize)
                .scaleEffect(x: -1, y: 1)
                .position(x: RobotRig.legRightX, y: RobotRig.legY - pose.legR)
            part("robot_torso", RobotRig.torsoSize)
                .rotationEffect(.degrees(pose.torsoTilt), anchor: RobotRig.torsoAnchor)
                .position(x: RobotRig.torsoCenter.x, y: RobotRig.torsoCenter.y + bb)
            arm("robot_arm_a", x: RobotRig.armLeftX, y: RobotRig.armY + bb, angle: pose.leftArm, mirrored: false)
            arm("robot_arm_b", x: RobotRig.armRightX, y: RobotRig.armY + bb, angle: pose.rightArm, mirrored: true)
            if let kind = pose.tool, pose.toolPresence > 0.01 {
                let spec = kind.spec
                let k = CGFloat(0.7 + 0.3 * pose.toolPresence) * pose.toolScale
                let size = CGSize(width: spec.size.width * k, height: spec.size.height * k)
                part(kind.image, size)
                    .rotationEffect(.degrees(pose.rightArm - spec.direction + pose.toolRot), anchor: spec.grip)
                    .opacity(pose.toolPresence)
                    .position(x: hand.x + (0.5 - spec.grip.x) * size.width,
                              y: hand.y + (0.5 - spec.grip.y) * size.height)
            }
            if pose.carry {
                part("prop_reel", RobotRig.reelSize)
                    .rotationEffect(.degrees(pose.carryRot))
                    .position(x: RobotRig.reelCenter.x + pose.carryDX, y: RobotRig.reelCenter.y + bb + pose.carryDY)
            }
            part(faceImage, RobotRig.faceSize)
                .rotationEffect(.degrees(pose.headTilt), anchor: RobotRig.faceAnchor)
                .position(x: RobotRig.faceCenter.x + pose.look, y: RobotRig.faceCenter.y + hb)
            if pose.headphones {
                part("robot_headphones", RobotRig.headphonesSize)
                    .rotationEffect(.degrees(pose.headTilt), anchor: RobotRig.faceAnchor)
                    .position(x: RobotRig.headphonesCenter.x, y: RobotRig.headphonesCenter.y + hb)
            }
        }
        .frame(width: 100, height: 92)
    }

    private var faceImage: String {
        if pose.happy { return "robot_face_happy" }
        return pose.blink ? "robot_face_closed" : "robot_face_open"
    }

    private func part(_ name: String, _ size: CGSize) -> some View {
        Image(name)
            .resizable()
            .frame(width: size.width, height: size.height)
    }

    private func arm(_ name: String, x: CGFloat, y: CGFloat, angle: Double, mirrored: Bool) -> some View {
        part(name, RobotRig.armSize)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .rotationEffect(.degrees(angle - 90), anchor: RobotRig.armPivot)
            .position(x: x, y: y + (0.5 - RobotRig.armPivot.y) * RobotRig.armSize.height)
    }

    /// 肩 (x, y) から角度 angle の腕の、手の中心
    private static func hand(x: CGFloat, y: CGFloat, angle: Double) -> CGPoint {
        let length = RobotRig.armSize.height * (RobotRig.armHandY - RobotRig.armPivot.y)
        let r = angle * Double.pi / 180
        return CGPoint(x: x + length * CGFloat(cos(r)), y: y + length * CGFloat(sin(r)))
    }
}

/// シーンの寸法(座標は 260 × 110。上の 38 は空きなので切り落として 72 だけ見せる)
private enum RobotStage {
    static let width: CGFloat = 260
    static let height: CGFloat = 110
    static let topCrop: CGFloat = 38
    static var visibleHeight: CGFloat { height - topCrop }
    static let floorY: CGFloat = 104
    static let scale: CGFloat = 0.6
    /// コマ送り(1 秒 12 コマ)
    static let fps = 12.0
    static func quant(_ t: Double) -> Double { floor(t * fps) / fps }
}

/// ロボットをシーンに置く(足を軸に、向き・つぶれ・前かがみ・縮尺を付けて、足の位置に置く)
private struct RobotOnStage: View {
    let pose: RobotPose

    var body: some View {
        Robot(pose: pose)
            .scaleEffect(x: pose.facing * pose.squashX, y: pose.squashY, anchor: RobotRig.feet)
            .rotationEffect(.degrees(pose.lean * Double(pose.facing)), anchor: RobotRig.feet)
            .scaleEffect(RobotStage.scale, anchor: RobotRig.feet)
            // 枠は 100 × 92、足は (36, 92) → 枠の中心は足から (+14, -46)
            .position(x: pose.feetX + 14, y: RobotStage.floorY - pose.lift - 46)
    }
}

/// 振り付け。時間は各ロボットの周期の中の秒(コマ送り済み)
private enum RobotChoreo {
    // ---- 運ぶ係: 機材ケースからリールを取り、机まで運んで置き、戻る。周期 10 秒
    static let carrierCycle = 10.0
    static let carrierX = RobotTrack(carrierCycle, [rk(0.0, 30, .hold), rk(2.2, 30, .hold), rk(5.2, 88, .lin), rk(6.6, 88, .hold), rk(8.8, 30, .lin)])
    static let carrierPick = RobotTrack(carrierCycle, [rk(0.6, 0, .hold), rk(1.1, 1, .io), rk(1.5, 1, .hold), rk(1.9, 0, .out)])
    static let carrierCrouch = RobotTrack(carrierCycle, [rk(2.0, 0, .hold), rk(2.15, 1, .io), rk(2.3, 0, .out), rk(6.4, 0, .hold), rk(6.55, 1, .io), rk(6.7, 0, .out)])
    static let carrierHas = RobotTrack(carrierCycle, [rk(1.4, 0, .hold), rk(1.5, 1, .hold), rk(5.6, 1, .hold), rk(5.7, 0, .hold)])
    static let carrierPut = RobotTrack(carrierCycle, [rk(5.2, 0, .hold), rk(5.5, 1, .io), rk(5.9, 1, .hold), rk(6.2, 0, .out)])
    static let carrierTurn = RobotTrack(carrierCycle, [rk(0.0, -1, .hold), rk(1.9, -1, .hold), rk(2.2, 1, .io), rk(6.2, 1, .hold), rk(6.5, -1, .io)])
    static let carrierCheer = RobotTrack(carrierCycle, [rk(5.9, 0, .hold), rk(6.0, 1, .hold), rk(6.9, 1, .hold), rk(7.0, 0, .hold)])

    static func carrier(_ t: Double) -> RobotPose {
        let frame = 1 / RobotStage.fps
        let pick = carrierPick(t)
        let has = carrierHas(t) > 0.5
        let put = carrierPut(t)
        let walking = (t > 2.2 && t < 5.2) || (t > 6.6 && t < 8.8)
        let stepPhase = t * 3
        let s = walking ? sin(stepPhase * Double.pi * 2) : 0
        let hop = walking ? pow(abs(sin(stepPhase * Double.pi)), 1.5) * 3.4 : 0
        let land = walking && abs(sin(stepPhase * Double.pi)) < 0.25
        let crouch = carrierCrouch(t)
        let turn = RobotMotion.turn(carrierTurn(t))
        var p = RobotPose()
        p.feetX = CGFloat(carrierX(t))
        p.lift = CGFloat(hop) * RobotStage.scale + turn.lift
        p.facing = turn.facing
        p.lean = walking ? 7 : (pick * 10 + put * 6)
        p.torsoTilt = pick * 12 + put * 6
        let squash: CGFloat = land ? 1.06 : (walking && hop > 2.6 ? 0.96 : 1 + CGFloat(crouch) * 0.08)
        p.squashX = turn.squash * squash
        p.squashY = land ? 0.93 : (walking && hop > 2.6 ? 1.05 : 1 - CGFloat(crouch) * 0.1)
        p.legL = walking ? CGFloat(max(0, s) * 4) : 0
        p.legR = walking ? CGFloat(max(0, -s) * 4) : 0
        if has {
            p.leftArm = 62 - put * 20
            p.rightArm = 118 - put * 20
        } else if pick > 0.3 {
            p.leftArm = 20 + pick * 40
            p.rightArm = 160 - pick * 40
        } else {
            p.leftArm = walking ? 100 + s * 18 : 100
            p.rightArm = walking ? 80 - s * 18 : 80
        }
        p.carry = has
        p.carryDX = CGFloat(put * 20)
        p.carryDY = CGFloat(pick * 10 - put * 6)
        p.carryRot = walking ? s * 3 : 0
        p.bob = walking ? CGFloat(-hop * 0.3) : CGFloat(pick * 6)
        // 頭とアンテナは体より 1〜2 コマ遅れてついてくる
        p.headTilt = carrierPick(t - frame) * 14 + carrierPut(t - frame) * 8 - (walking ? 3 : 0)
        p.antenna = walking ? -s * 6 - 8 : -(carrierPick(t - 2 * frame) + carrierPut(t - 2 * frame)) * 10
        p.blink = RobotMotion.blink(t)
        p.happy = carrierCheer(t) > 0.5
        return p
    }

    // ---- 切ってつなぐ係: 机の奥の台に立つ。フィルムを見る → はさみ(構えて 3 回チョキチョキ。フィルムが切れて離れる) → うなずく
    //      → テープ(2 回押す。フィルムがつながる) → ルーペで確認 → にっこり。周期 8 秒
    static let editorCycle = 8.0
    static let editorX: CGFloat = 132
    static let editorLift: CGFloat = 6
    static let editorPresence = RobotTrack(editorCycle, [rk(0.2, 0, .hold), rk(0.5, 1, .out), rk(2.8, 1, .hold), rk(3.0, 0, .easeIn), rk(3.3, 1, .out), rk(5.0, 1, .hold), rk(5.2, 0, .easeIn), rk(5.5, 1, .out), rk(7.7, 1, .hold), rk(7.9, 0, .easeIn)])
    static let editorArm = RobotTrack(editorCycle, [rk(0.0, 60, .hold), rk(0.5, 50, .out), rk(0.9, 15, .back), rk(1.0, 38, .out), rk(1.1, 18, .hold), rk(1.25, 38, .out), rk(1.35, 18, .hold), rk(1.5, 38, .out), rk(1.6, 22, .hold), rk(2.2, 50, .io), rk(2.9, 50, .hold),
                                                    rk(3.3, 40, .out), rk(3.6, 62, .easeIn), rk(3.8, 44, .out), rk(4.1, 62, .easeIn), rk(4.3, 44, .out), rk(5.0, 50, .io),
                                                    rk(5.5, 28, .out), rk(6.2, 40, .io), rk(6.9, 28, .io), rk(7.6, 50, .io)])
    static let editorHead = RobotTrack(editorCycle, [rk(0.0, 6, .hold), rk(0.5, 10, .io), rk(1.0, 4, .out), rk(1.6, 6, .io), rk(2.2, -4, .io), rk(2.5, 4, .io), rk(2.8, 0, .io), rk(3.3, 8, .io), rk(5.0, 6, .io), rk(5.5, 10, .io), rk(6.2, 2, .io), rk(6.9, 10, .io), rk(7.4, 0, .io)])
    static let editorHappy = RobotTrack(editorCycle, [rk(7.3, 0, .hold), rk(7.4, 1, .hold), rk(8.0, 0, .hold)])
    static let editorLean = RobotTrack(editorCycle, [rk(0.0, 4, .hold), rk(0.9, 8, .io), rk(2.2, 2, .io), rk(3.3, 6, .io), rk(5.0, 2, .io), rk(5.5, 9, .io), rk(7.3, 0, .io)])
    /// 机のフィルム: 切っている間に離れ、テープでつながる
    static let filmGap = RobotTrack(editorCycle, [rk(0.0, 0, .hold), rk(1.0, 0, .hold), rk(1.1, 1.5, .out), rk(1.35, 3, .out), rk(1.6, 4.5, .out), rk(3.6, 4.5, .hold), rk(3.8, 0, .easeIn)])
    static func filmPatched(_ t: Double) -> Bool { t >= 3.8 && t < 7.9 }
    static let lookingArm = RobotTrack(6, [rk(0, 40, .hold), rk(1.2, 55, .io), rk(2.4, 30, .io), rk(3.0, 30, .hold), rk(3.4, 22, .back), rk(4.6, 50, .io), rk(5.6, 40, .io)])
    static let writingArm = RobotTrack(4, [rk(0, 50, .hold), rk(0.3, 56, .io), rk(0.5, 48, .io), rk(0.7, 56, .io), rk(0.9, 49, .io), rk(1.1, 56, .io), rk(1.3, 50, .io), rk(2.4, 50, .hold), rk(2.9, 15, .back), rk(3.6, 50, .io)])

    static func editor(_ t: Double, task: RobotTask) -> RobotPose {
        var p = RobotPose()
        p.feetX = editorX
        p.lift = editorLift
        p.lean = editorLean(t)
        p.headTilt = editorHead(t)
        p.look = 1.5
        p.blink = RobotMotion.blink(t + 0.7)
        p.happy = editorHappy(t) > 0.5
        p.antenna = -editorLean(t) * 1.2
        p.leftArm = 95
        p.toolScale = 1.3
        switch task {
        case .editing:
            // はさみは切っている間だけ刃がカチカチ動く。持ち替える間は腕を少し下ろす
            let snip = (t > 0.95 && t < 1.65) ? (Int(floor(t * RobotStage.fps)) % 2 == 1 ? 14.0 : -14.0) : 0
            let presence = editorPresence(t)
            p.rightArm = editorArm(t) + 25 * (1 - presence)
            p.tool = t < 3.0 ? RobotToolKind.scissors : (t < 5.2 ? RobotToolKind.tape : RobotToolKind.magnifier)
            p.toolPresence = presence
            p.toolRot = snip
            p.bob = CGFloat(editorLean(t) * 0.3)
        case .looking:
            // ルーペでフィルムをなめるように見る。止まって、ぐっと近づく
            let a = lookingArm(t)
            p.rightArm = a
            p.tool = .magnifier
            p.headTilt = 8 + (a - 40) * 0.2
            p.lean = 6 + (a < 28 ? 5 : 0)
        case .listening:
            // 鉛筆で書き取る(小さく手が動く)。ときどき顔を上げる
            let w = writingArm(t)
            p.rightArm = w
            p.tool = .pencil
            p.headTilt = w > 35 ? 10 : -4
        }
        return p
    }

    // ---- 監督: モニターを見てうなずく → スタッフの方へ向き直る → 構えて(反動) メガホンを上げて叫ぶ(のけぞる)
    //      → 下ろす → モニターへ向き直る → モニターに顔を近づける。周期 7 秒
    static let directorCycle = 7.0
    static let directorX: CGFloat = 200
    static let directorFace = RobotTrack(directorCycle, [rk(0.0, 1, .hold), rk(1.55, 1, .hold), rk(1.8, -1, .io), rk(3.75, -1, .hold), rk(4.0, 1, .io)])
    static let directorArm = RobotTrack(directorCycle, [rk(0.0, 80, .hold), rk(1.8, 80, .hold), rk(2.0, 115, .io), rk(2.25, -40, .back), rk(3.4, -40, .hold), rk(3.75, 80, .io)])
    static let directorLean = RobotTrack(directorCycle, [rk(0.0, 3, .hold), rk(0.4, 6, .io), rk(1.4, 3, .io), rk(1.8, 3, .hold), rk(2.0, 9, .io), rk(2.25, -8, .out), rk(3.4, -8, .hold), rk(3.75, 3, .io), rk(4.6, 3, .hold), rk(5.0, 10, .io), rk(5.8, 10, .hold), rk(6.2, 3, .io)])
    static let directorHead = RobotTrack(directorCycle, [rk(0.0, 4, .hold), rk(0.5, 8, .io), rk(0.8, 2, .io), rk(1.1, 8, .io), rk(1.4, 4, .io), rk(2.25, -6, .out), rk(3.75, 4, .io), rk(5.0, 10, .io), rk(6.2, 4, .io)])
    static let directorShout = RobotTrack(directorCycle, [rk(2.25, 0, .hold), rk(2.3, 1, .hold), rk(3.4, 1, .hold), rk(3.45, 0, .hold)])
    static let peerArm = RobotTrack(5, [rk(0, 95, .hold), rk(0.6, -20, .back), rk(2.6, -20, .hold), rk(3.2, -35, .io), rk(4.2, -20, .io), rk(4.7, 95, .io)])
    static let peerLean = RobotTrack(5, [rk(0, 2, .hold), rk(0.6, 10, .io), rk(2.6, 10, .hold), rk(3.2, 16, .io), rk(4.2, 10, .io), rk(4.7, 2, .io)])
    static let earArm = RobotTrack(6, [rk(0, 80, .hold), rk(1.0, -60, .back), rk(4.5, -60, .hold), rk(5.2, 80, .io)])
    static let beat = RobotTrack(2, [rk(0, -4, .io), rk(1, 4, .io)])

    static func isShouting(_ t: Double, task: RobotTask) -> Bool {
        task == .editing && directorShout(t) > 0.5
    }

    static func director(_ t: Double, task: RobotTask) -> RobotPose {
        var p = RobotPose()
        p.feetX = directorX
        p.look = 1.5
        p.blink = RobotMotion.blink(t + 1.4)
        p.leftArm = 100
        switch task {
        case .editing:
            let shouting = isShouting(t, task: task)
            let turn = RobotMotion.turn(directorFace(t))
            let arm = directorArm(t)
            p.facing = turn.facing
            p.squashX = turn.squash
            p.lift = turn.lift
            p.rightArm = arm
            p.tool = .megaphone
            // 下ろしているときはメガホンを水平に持つ(床に向けてぶら下げない)。上げると腕の向きに向く
            p.toolRot = -max(arm, 0) * 0.95
            p.toolScale = 1.3 * (shouting ? (Int(floor(t * RobotStage.fps)) % 2 == 1 ? 1.12 : 1.0) : 1)
            p.lean = directorLean(t)
            p.headTilt = directorHead(t)
            p.antenna = -p.lean * 1.2
            p.happy = shouting
        case .looking:
            // ルーペをモニターにかざして、近づいたり離れたり(下ろしているときはルーペを立てて持つ)
            let a = peerArm(t)
            let lean = peerLean(t)
            p.rightArm = a
            p.tool = .magnifier
            p.toolRot = -max(a, 0) * 1.6
            p.toolScale = 1.3
            p.lean = lean
            p.headTilt = lean * 0.8
            p.antenna = -lean * 1.2
        case .listening:
            // ヘッドホンをして、手を耳に当てて拍子をとる
            let b = beat(t)
            p.rightArm = earArm(t)
            p.headphones = true
            p.lean = b
            p.headTilt = b * 1.5
        }
        return p
    }
}

/// 3 体の小さなロボットの作業場(幅 260・高さ 72)。粘土アニメのように 1 秒 12 コマで動く。
/// 左 = 機材ケースからフィルムのリールを運んで机に置く係 / 中 = 机でフィルムを切ってつなぐ係 / 右 = モニターを見て指示を出す監督
struct RobotWorkshop: View {
    let task: RobotTask
    /// 監督のモニターに映すコマ(いま AI が見ている映像)
    var monitorFrame: CGImage? = nil

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / RobotStage.fps)) { context in
            let t = RobotStage.quant(context.date.timeIntervalSinceReferenceDate)
            RobotStageView(t: t, task: task, frame: monitorFrame)
        }
        .frame(width: RobotStage.width, height: RobotStage.height)
        // 上の空きを切り落とす
        .frame(width: RobotStage.width, height: RobotStage.visibleHeight, alignment: .bottom)
        .clipped()
    }
}

private struct RobotStageView: View {
    let t: Double
    let task: RobotTask
    let frame: CGImage?

    var body: some View {
        let carrierT = t.truncatingRemainder(dividingBy: RobotChoreo.carrierCycle)
        let editorT = t.truncatingRemainder(dividingBy: RobotChoreo.editorCycle)
        let directorT = t.truncatingRemainder(dividingBy: RobotChoreo.directorCycle)
        let carrier = RobotChoreo.carrier(carrierT)
        let shouting = RobotChoreo.isShouting(directorT, task: task)
        var editor = RobotChoreo.editor(editorT, task: task)
        if shouting {
            // 監督が叫ぶと、切ってつなぐ係は顔を上げてそちらを見る
            editor.look = 3
            editor.headTilt = -8
        }
        let director = RobotChoreo.director(directorT, task: task)
        let reelOnDesk = carrierT > 5.6 && carrierT < 9.9
        let gap: CGFloat = task == .editing ? CGFloat(RobotChoreo.filmGap(editorT)) : 0
        let patched = task == .editing && RobotChoreo.filmPatched(editorT)
        return ZStack {
            // 奥の機材: 機材ケース、三脚のカメラ、モニター(画面に AI が見ているコマ)
            prop("prop_case", 30, 25, x: 20, y: 92)
            prop("prop_camera", 26, 34, x: 246, y: 86)
            prop("prop_monitor", 36, 36, x: 232, y: 72)
            Group {
                if let frame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [BrandStyle.green, BrandStyle.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(0.9)
                }
            }
            .frame(width: 18.4, height: 14.4)
            .clipShape(RoundedRectangle(cornerRadius: 1))
            .position(x: 232.6, y: 66.6)
            prop("prop_splicer", 20, 17, x: 172, y: 84)
            // 机の奥の台に立つ係と、監督
            RobotOnStage(pose: editor)
            RobotOnStage(pose: director)
            // 机(手前)。その上にリール・テープ・フィルム
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.79, green: 0.54, blue: 0.36))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(red: 0.61, green: 0.39, blue: 0.25)).frame(height: 2)
                }
                .frame(width: 84, height: 12)
                .position(x: 134, y: 98)
            if reelOnDesk {
                prop("prop_reel", 15, 15, x: 102, y: 86)
            }
            prop("prop_tape", 11, 8, x: 118, y: 90)
            filmHalf(left: true)
                .position(x: 148 - gap / 2, y: 90)
            filmHalf(left: false)
                .position(x: 148 + gap / 2, y: 90)
            if patched {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.95, green: 0.85, blue: 0.54).opacity(0.95))
                    .frame(width: 4, height: 9)
                    .rotationEffect(.degrees(-8))
                    .position(x: 148, y: 90)
            }
            // 運ぶ係(いちばん手前)
            RobotOnStage(pose: carrier)
            if shouting {
                Text(verbatim: "!")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(red: 0.15, green: 0.2, blue: 0.35))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white, in: Capsule())
                    .position(x: 167, y: 56.5 - CGFloat(Int(floor(t * RobotStage.fps)) % 2))
            }
        }
        .frame(width: RobotStage.width, height: RobotStage.height)
    }

    private func prop(_ name: String, _ w: CGFloat, _ h: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(name)
            .resizable()
            .frame(width: w, height: h)
            .position(x: x, y: y)
    }

    /// 机のフィルムの左半分 / 右半分(はさみで切ると離れる)
    private func filmHalf(left: Bool) -> some View {
        Image("prop_filmcurve")
            .resizable()
            .frame(width: 32, height: 12)
            .mask {
                HStack(spacing: 0) {
                    if left {
                        Rectangle()
                        Color.clear
                    } else {
                        Color.clear
                        Rectangle()
                    }
                }
            }
    }
}

/// 字幕の自動作成中: いま読み取っている位置のコマ + ロボット。
/// 進み具合(0...1)から作品の時刻を求め、そこのコマを元素材から取り出す(1 秒以上動いたら取り直す)
struct TranscriptionPeekView: View {
    let project: EditorProject
    let fraction: Double

    @State private var frame: CGImage?
    @State private var lastTime: Double = -10

    var body: some View {
        VStack(spacing: 10) {
            if let frame {
                AIScanningFrame(image: frame)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
            }
            RobotWorkshop(task: .listening, monitorFrame: frame)
        }
        .task(id: Int((min(max(fraction, 0), 1) * 100).rounded())) {
            await reload()
        }
    }

    private func reload() async {
        let total = CompositionBuilder.totalDuration(for: project.snapshot())
        let time = min(max(fraction, 0), 1) * total
        guard frame == nil || abs(time - lastTime) >= 1 else { return }
        guard let location = project.locate(timelineTime: time), location.index < project.clips.count else { return }
        let clip = project.clips[location.index]
        lastTime = time
        if let image = await DocumentaryPreviewSource.frame(clip: clip, sourceTime: location.sourceTime),
           let cg = image.cgImage {
            frame = cg
        }
    }
}

