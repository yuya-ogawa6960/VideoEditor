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
                .frame(height: 84)

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

// MARK: - ロボット(Gemini で作った粘土の画像パーツを組み合わせて動かす)

/// 動きをなめらかにする小さな関数(急に始まったり止まったり、パッと切り替わったりしないように)
private enum RobotMotion {
    /// 0...1 を、ゆっくり始まってゆっくり止まる 0...1 にする
    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// x が a から b まで進む間の 0...1(外側は 0 か 1)
    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        return min(max((x - a) / (b - a), 0), 1)
    }

    /// 0 から出て 1 まで上がり、また 0 に戻る山。x が 0...1 の外では 0(ふわっと出てふわっと消える)
    static func bump(_ x: Double, rise: Double, fall: Double) -> Double {
        guard x > 0, x < 1 else { return 0 }
        return smooth(ramp(x, 0, rise)) * (1 - smooth(ramp(x, 1 - fall, 1)))
    }

    /// まばたき: 約 3.6 秒ごとに 0.28 秒、ゆっくり閉じて開く
    static func blink(_ t: Double) -> Double {
        bump(((t + 1.3).truncatingRemainder(dividingBy: 3.6)) / 0.28, rise: 0.45, fall: 0.45)
    }
}

/// 3 体の小さなロボットの作業場(幅 260)。
/// 左 = フィルムを運ぶ係 / 中 = 切ってつなぐ(塗る)係 / 右 = モニターで確認して指示を出す係
/// 動きはどれもゆっくり・なめらかに(速く細かく震えたり、パッと切り替わったりすると不自然に見える)
struct RobotWorkshop: View {
    let task: RobotTask
    /// 右のロボットのモニターに映すコマ(いま AI が見ている映像)。nil なら流れるフィルム
    var monitorFrame: CGImage? = nil

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 編集中は 3.6 秒ごとに「切る → つなぐ → 塗る」。道具は持ち替える間にふわっと入れ替わる
            let cycle = 3.6
            let step = Int(t / cycle) % 3
            let local = (t.truncatingRemainder(dividingBy: cycle)) / cycle
            HStack(alignment: .bottom, spacing: 4) {
                CarrierRobot(t: t)
                    .frame(width: 92, height: 84)
                EditorRobot(t: t, task: task, step: step, local: local)
                    .frame(width: 96, height: 84)
                DirectorRobot(t: t, task: task, frame: monitorFrame)
                    .frame(width: 64, height: 84)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// フィルムを運ぶロボット。右へ運んで台に置き、くるっと向きを変えて手を下ろして戻り、左でまた次のフィルムを受け取る。
/// 走っている間だけ小さく弾み、端ではひと休みする
private struct CarrierRobot: View {
    let t: Double

    private static let scale: CGFloat = 0.6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let m = Self.motion(t: t)
            ZStack(alignment: .bottomLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: w, height: 3)
                    .offset(y: -3)
                Robot(pose: m.pose, scale: Self.scale, width: 72)
                    .scaleEffect(x: m.facing, y: 1)
                    .offset(x: CGFloat(m.travel) * max(0, w - 72 * Self.scale), y: -m.hop)
            }
        }
    }

    /// 1 往復 6.4 秒: 0〜0.42 右へ運ぶ / 0.42〜0.5 置いて向きを変える / 0.5〜0.92 左へ戻る / 0.92〜1 受け取って向きを変える
    private static func motion(t: Double) -> (pose: RobotPose, travel: Double, hop: CGFloat, facing: CGFloat) {
        let p = (t / 6.4).truncatingRemainder(dividingBy: 1)
        let goingRight = p < 0.5
        let travel = goingRight
            ? RobotMotion.smooth(RobotMotion.ramp(p, 0, 0.42))
            : 1 - RobotMotion.smooth(RobotMotion.ramp(p, 0.5, 0.92))
        // 走っている速さ(0...1)。走り出しと止まる前はゆっくり
        let moving = goingRight
            ? RobotMotion.bump(RobotMotion.ramp(p, 0, 0.42), rise: 0.3, fall: 0.3)
            : RobotMotion.bump(RobotMotion.ramp(p, 0.5, 0.92), rise: 0.3, fall: 0.3)
        // 向き: 端で止まったときに、くるっと回って向きを変える(横幅が一度つぶれる)
        let turnAtRight = RobotMotion.smooth(RobotMotion.ramp(p, 0.44, 0.5))
        let turnAtLeft = RobotMotion.smooth(RobotMotion.ramp(p, 0.94, 1.0))
        let facing = cos(Double.pi * (turnAtRight - turnAtLeft))
        let facingScale = CGFloat(facing >= 0 ? max(facing, 0.04) : min(facing, -0.04))
        // フィルム: 右端で置く(ふわっと消える)、左端で受け取る(ふわっと出る)。腕もそれに合わせて下ろす・上げる
        let holding = goingRight
            ? 1 - RobotMotion.smooth(RobotMotion.ramp(p, 0.42, 0.47))
            : RobotMotion.smooth(RobotMotion.ramp(p, 0.95, 1.0))
        // 歩くリズム(1 秒に約 2.6 歩)。着地は柔らかく
        let stride = sin(t * 2 * Double.pi * 1.3)
        let hop = CGFloat(pow(abs(stride), 1.6) * moving) * 2.4
        let swing = stride * 14 * moving
        let raised = RobotMotion.smooth(holding)
        var pose = RobotPose()
        pose.leftArm = 100 + swing * (1 - holding) - 38 * raised
        pose.rightArm = 80 - swing * (1 - holding) + 38 * raised
        pose.holdFilm = holding
        pose.tilt = stride * 3 * moving
        pose.step = t * 1.3
        pose.moving = moving
        pose.happy = moving < 0.05 && p > 0.4 && p < 0.56
        pose.bob = CGFloat(sin(t * 1.6)) * 1.2
        pose.blink = RobotMotion.blink(t)
        pose.antenna = CGFloat(sin(t * 1.3)) * 1.5
        return (pose, travel, hop, facingScale)
    }
}

/// 切ってつなぐロボット(作業台のフィルムを、切る → テープでつなぐ → 塗る。道具はその都度ゆっくり持ち替える)
private struct EditorRobot: View {
    let t: Double
    let task: RobotTask
    let step: Int
    let local: Double

    var body: some View {
        // 作業はゆっくり進む(0.15〜0.8 の間)。切り替わりの前後は手を止めている
        let progress = RobotMotion.smooth(RobotMotion.ramp(local, 0.15, 0.8))
        HStack(alignment: .bottom, spacing: -18) {
            Robot(pose: Self.pose(t: t, task: task, step: step, local: local), scale: 0.6)
            workArea(progress: progress)
                .frame(width: 50, height: 32)
                .padding(.bottom, 10)
        }
    }

    private static func pose(t: Double, task: RobotTask, step: Int, local: Double) -> RobotPose {
        // 道具の見え方: 作業の切り替わりでいったん腕を下ろして持ち替える(編集中だけ)
        let presence = task == .editing ? RobotMotion.bump(local, rise: 0.12, fall: 0.1) : 1
        let tempo = 0.92
        let sway = sin((t + 0.7) * 2.9 * tempo)
        var pose = RobotPose()
        pose.leftArm = 95
        pose.rightArm = -24 + sway * 9 + 40 * (1 - presence)
        switch task {
        case .looking: pose.tool = .magnifier
        case .listening: pose.tool = .pencil
        case .editing: pose.tool = ([.scissors, .tape, .brush] as [RobotToolKind])[step]
        }
        pose.toolPresence = presence
        pose.look = 1.5
        pose.bob = CGFloat(sin((t + 0.7) * 1.6 * tempo)) * 1.2
        pose.blink = RobotMotion.blink((t + 0.7) * tempo)
        pose.antenna = CGFloat(sin(t * 1.3 * tempo)) * 1.5
        return pose
    }

    @ViewBuilder
    private func workArea(progress: Double) -> some View {
        switch task {
        case .looking:
            FilmStrip(offset: CGFloat(t * 12), split: nil, joined: false, paint: 0)
        case .listening:
            SoundWave(t: t)
        case .editing:
            switch step {
            case 0: FilmStrip(offset: 0, split: CGFloat(progress), joined: false, paint: 0)
            case 1: FilmStrip(offset: 0, split: CGFloat(1 - progress), joined: local > 0.8, paint: 0)
            default: FilmStrip(offset: 0, split: nil, joined: true, paint: CGFloat(progress))
            }
        }
    }
}

/// モニターで確認して指示を出すロボット(ときどきメガホンを上げて「!」。ふわっと出てふわっと消える)
private struct DirectorRobot: View {
    let t: Double
    let task: RobotTask
    let frame: CGImage?

    var body: some View {
        let m = Self.pose(t: t, task: task)
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.1))
                if let frame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    FilmStrip(offset: CGFloat(t * 12), split: nil, joined: false, paint: 0)
                        .padding(3)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 1)
                    .offset(y: CGFloat(sin(t * 1.4)) * 10)
            }
            .frame(width: 46, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4), lineWidth: 1))
            if task == .listening {
                // 聞く係は、ヘッドホンで手を耳に当てた 1 枚絵(ゆっくり息をして、少し左右に揺れる)
                Image("robot_hero_listening")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 92 * 0.6)
                    .rotationEffect(.degrees(sin(t * 1.1) * 2), anchor: .bottom)
                    .offset(x: 2, y: m.pose.bob * 0.6)
            } else {
                Robot(pose: m.pose, scale: 0.6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if task == .editing {
                Text(verbatim: "!")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(red: 0.15, green: 0.2, blue: 0.35))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white, in: Capsule())
                    .scaleEffect(0.6 + 0.4 * CGFloat(m.shout))
                    .opacity(m.shout)
                    .offset(x: 6, y: 22 - CGFloat(m.shout) * 3)
            }
        }
    }

    private static func pose(t: Double, task: RobotTask) -> (pose: RobotPose, shout: Double) {
        // 4.8 秒に 1 回、1.2 秒ほど「!」。その間はメガホンを上げる
        let sp = (t / 4.8).truncatingRemainder(dividingBy: 1)
        let shout = task == .editing ? RobotMotion.bump(RobotMotion.ramp(sp, 0.55, 0.8), rise: 0.25, fall: 0.35) : 0
        let tempo = 1.08
        let sway = sin((t + 1.4) * 2.9 * tempo)
        var pose = RobotPose()
        pose.leftArm = 100
        switch task {
        case .editing:
            pose.tool = .megaphone
            pose.rightArm = -18 + sway * 6 - 24 * shout
        case .looking:
            pose.tool = .magnifier
            pose.rightArm = -18 + sway * 6
        case .listening:
            pose.headphones = true
            pose.rightArm = 80 + sway * 4
        }
        pose.shout = shout
        pose.happy = shout > 0.5
        pose.look = 1.5
        pose.bob = CGFloat(sin((t + 1.4) * 1.6 * tempo)) * 1.2
        pose.blink = RobotMotion.blink((t + 1.4) * tempo)
        pose.antenna = CGFloat(sin(t * 1.3 * tempo)) * 1.5
        return (pose, shout)
    }
}

/// ロボットの道具(Gemini で作った粘土の画像パーツ)
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
        case .tape: return (CGSize(width: 22, height: 15), UnitPoint(x: 0.45, y: 0.55), 0)
        }
    }
}

/// ロボットの姿勢(1 コマ分の描画パラメータ)
private struct RobotPose {
    /// 体の上下(息をするような動き)
    var bob: CGFloat = 0
    /// まばたき(0 = 開く、1 = 閉じる)
    var blink: Double = 0
    /// にっこり顔にする(フィルムを渡すとき、「!」のときなど)
    var happy = false
    /// 目線の横ずれ(右を見ると +)
    var look: CGFloat = 0
    /// アンテナの先の横揺れ
    var antenna: CGFloat = 0
    /// 腕の角度(度。0 = 右、90 = 下、-90 = 上)
    var leftArm: Double = 100
    var rightArm: Double = 80
    /// 右手に持つ道具
    var tool: RobotToolKind? = nil
    /// 道具の見え方(0...1)。持ち替える間は薄く小さく、腕も下ろす
    var toolPresence: Double = 1
    /// メガホンの音(0...1)
    var shout: Double = 0
    /// 胸の前にフィルムを持っている度合い(0...1)
    var holdFilm: Double = 0
    /// 持っているフィルムの傾き(度)
    var tilt: Double = 0
    /// 歩く位相(秒 × 歩く速さ)。nil なら止まっている
    var step: Double? = nil
    /// 歩いている速さ(0...1)
    var moving: Double = 0
    /// ヘッドホンをつける
    var headphones = false
}

/// 画像パーツの大きさと位置(72 × 92 のロボット座標。ブラウザの試作 robot_rig.html と同じ数字)
private enum RobotRig {
    static let faceSize = CGSize(width: 50, height: 44)
    static let faceCenter = CGPoint(x: 36, y: 30)
    static let antennaSize = CGSize(width: 14, height: 17)
    /// アンテナの根元(頭の上の右寄り)。ここを軸に揺れる
    static let antennaFoot = CGPoint(x: 44, y: 12)
    static let antennaTilt = 18.0
    static let torsoSize = CGSize(width: 34, height: 35)
    static let torsoCenter = CGPoint(x: 36, y: 64)
    static let legSize = CGSize(width: 14, height: 15.5)
    static let legY: CGFloat = 84
    static let legLeftX: CGFloat = 28.5
    static let legRightX: CGFloat = 43.5
    /// 腕の画像は「肩が上・手が下」。肩(画像の上端中央)を軸に回す
    static let armSize = CGSize(width: 11, height: 22.5)
    static let armY: CGFloat = 52
    static let armLeftX: CGFloat = 21
    static let armRightX: CGFloat = 51
    static let armPivot = UnitPoint(x: 0.5, y: 0.03)
    /// 手(青い球)の中心の、画像の縦方向の位置(割合)
    static let armHandY: CGFloat = 0.747
    static let filmSize = CGSize(width: 32, height: 21)
    static let filmCenter = CGPoint(x: 36, y: 66)
    static let headphonesSize = CGSize(width: 56, height: 46)
    static let headphonesCenter = CGPoint(x: 36, y: 28)
}

/// 粘土のロボット(画像パーツを組み合わせて動かす)。72 × 92 の座標で組む(道具は右へはみ出すので、既定の幅は 100)
private struct Robot: View {
    let pose: RobotPose
    var scale: CGFloat = 1
    var width: CGFloat = 100

    var body: some View {
        let hb = pose.bob
        let bb = pose.bob / 2
        let steps = Self.steps(pose)
        let hand = Self.hand(x: RobotRig.armRightX, y: RobotRig.armY + bb, angle: pose.rightArm)
        ZStack {
            // アンテナ(根元を軸にゆっくり揺れる)
            part("robot_antenna", RobotRig.antennaSize)
                .rotationEffect(.degrees(RobotRig.antennaTilt + Double(pose.antenna) * 4), anchor: UnitPoint(x: 0.5, y: 1))
                .position(x: RobotRig.antennaFoot.x, y: RobotRig.antennaFoot.y + hb - RobotRig.antennaSize.height / 2)
            // 脚(歩くときは交互に上がる)
            part("robot_leg", RobotRig.legSize)
                .position(x: RobotRig.legLeftX, y: RobotRig.legY - steps.left)
            part("robot_leg", RobotRig.legSize)
                .scaleEffect(x: -1, y: 1)
                .position(x: RobotRig.legRightX, y: RobotRig.legY - steps.right)
            // 胴
            part("robot_torso", RobotRig.torsoSize)
                .position(x: RobotRig.torsoCenter.x, y: RobotRig.torsoCenter.y + bb)
            // 胸の前のフィルム
            if pose.holdFilm > 0.01 {
                part("robot_film", RobotRig.filmSize)
                    .rotationEffect(.degrees(pose.tilt))
                    .opacity(pose.holdFilm)
                    .position(x: RobotRig.filmCenter.x, y: RobotRig.filmCenter.y + bb)
            }
            // 腕(肩を軸に回す)
            arm("robot_arm_a", x: RobotRig.armLeftX, y: RobotRig.armY + bb, angle: pose.leftArm, mirrored: false)
            arm("robot_arm_b", x: RobotRig.armRightX, y: RobotRig.armY + bb, angle: pose.rightArm, mirrored: true)
            // 右手の道具(手に入る点を手の中心に合わせ、腕の向きへ回す)
            if let kind = pose.tool, pose.toolPresence > 0.01 {
                let spec = kind.spec
                let k = CGFloat(0.7 + 0.3 * pose.toolPresence)
                let size = CGSize(width: spec.size.width * k, height: spec.size.height * k)
                part(kind.image, size)
                    .rotationEffect(.degrees(pose.rightArm - spec.direction), anchor: spec.grip)
                    .opacity(pose.toolPresence)
                    .position(x: hand.x + (0.5 - spec.grip.x) * size.width,
                              y: hand.y + (0.5 - spec.grip.y) * size.height)
            }
            // 顔(まばたき・にっこり)
            part(faceImage, RobotRig.faceSize)
                .position(x: RobotRig.faceCenter.x + pose.look * 0.3, y: RobotRig.faceCenter.y + hb)
            if pose.headphones {
                part("robot_headphones", RobotRig.headphonesSize)
                    .position(x: RobotRig.headphonesCenter.x, y: RobotRig.headphonesCenter.y + hb)
            }
        }
        .frame(width: width, height: 92)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width * scale, height: 92 * scale)
    }

    private var faceImage: String {
        if pose.happy { return "robot_face_happy" }
        return pose.blink > 0.5 ? "robot_face_closed" : "robot_face_open"
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

    /// 歩くときの脚の上がり(左・右)
    private static func steps(_ pose: RobotPose) -> (left: CGFloat, right: CGFloat) {
        guard let step = pose.step else { return (0, 0) }
        let s = sin(step * 2 * Double.pi)
        return (CGFloat(max(0, s) * 3 * pose.moving), CGFloat(max(0, -s) * 3 * pose.moving))
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
                .frame(height: 84)
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

/// フィルム(コマが並んだ帯)。split = 真ん中で切れて離れる量 0...1、joined = テープでつなぐ、paint = 左から塗る量 0...1
private struct FilmStrip: View {
    let offset: CGFloat
    let split: CGFloat?
    let joined: Bool
    let paint: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let gap = (split ?? 0) * 16
            ZStack {
                HStack(spacing: gap) {
                    strip(width: w / 2 - gap / 2, height: h * 0.7, phase: offset)
                    strip(width: w / 2 - gap / 2, height: h * 0.7, phase: offset + w / 2)
                }
                if let split, split > 0.05 {
                    // 切り口のきらきら
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                        .opacity(Double(split))
                }
                if joined {
                    // つなぎ目のテープ
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 1, green: 0.85, blue: 0.4).opacity(0.9))
                        .frame(width: 14, height: h * 0.8)
                        .rotationEffect(.degrees(-8))
                }
                if paint > 0 {
                    // ペンキで塗る(ブランドの色)
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(BrandStyle.gradient)
                            .opacity(0.75)
                            .frame(width: max(0, w * paint), height: h * 0.7)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: w, height: h)
        }
    }

    private func strip(width: CGFloat, height: CGFloat, phase: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15))
            // コマ
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.8), Color(red: 0.3, green: 0.45, blue: 0.3)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 18, height: height * 0.55)
                        .offset(x: -(phase.truncatingRemainder(dividingBy: 22)))
                        .id(i)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            // 穴
            VStack {
                perforations(width: width)
                Spacer()
                perforations(width: width)
            }
            .padding(.vertical, 2)
        }
        .frame(width: max(0, width), height: height)
    }

    private func perforations(width: CGFloat) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<Int(max(1, width / 9)), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.6)).frame(width: 4, height: 3)
            }
        }
        .frame(width: width)
        .clipped()
    }
}

/// 聞いているときの音の波
private struct SoundWave: View {
    let t: Double
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<14, id: \.self) { i in
                let v = (sin(t * 6 + Double(i) * 0.7) + 1) / 2
                Capsule()
                    .fill(BrandStyle.gradient)
                    .frame(width: 5, height: 8 + CGFloat(v) * 40)
            }
        }
    }
}
