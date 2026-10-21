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

// MARK: - ロボット

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
        pose.open = (sin(t * 5) + 1) / 2
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
            Robot(pose: m.pose, scale: 0.6)
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
        pose.look = 1.5
        pose.bob = CGFloat(sin((t + 1.4) * 1.6 * tempo)) * 1.2
        pose.blink = RobotMotion.blink((t + 1.4) * tempo)
        pose.antenna = CGFloat(sin(t * 1.3 * tempo)) * 1.5
        return (pose, shout)
    }
}

/// ロボットの道具
private enum RobotToolKind {
    case magnifier, scissors, tape, brush, megaphone, pencil
}

/// ロボットの姿勢(1 コマ分の描画パラメータ)
private struct RobotPose {
    /// 体の上下(息をするような動き)
    var bob: CGFloat = 0
    /// まばたき(0 = 開く、1 = 閉じる)
    var blink: Double = 0
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
    /// はさみの開き(0...1)
    var open: Double = 0.5
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

/// かわいいロボット。72 × 92 の座標で描く(道具は右へはみ出すので、既定の幅は 100)
private struct Robot: View {
    let pose: RobotPose
    var scale: CGFloat = 1
    var width: CGFloat = 100

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            RobotPainter.draw(pose, in: context)
        }
        .frame(width: width * scale, height: 92 * scale)
    }
}

/// ロボットを 1 コマ描く(Canvas)。頭 = 白い丸角 + 黒いバイザーに光る目、体 = ブランドのグラデーション、胸にハート
private enum RobotPainter {
    static let green = Color(red: 0.24, green: 0.79, blue: 0.49)
    static let blue = Color(red: 0.18, green: 0.55, blue: 0.91)
    static let cyan = Color(red: 0.62, green: 0.91, blue: 1.0)
    static let navy = Color(red: 0.12, green: 0.14, blue: 0.20)
    static let gray = Color(red: 0.79, green: 0.81, blue: 0.85)
    static let hand = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let dark = Color(red: 0.23, green: 0.25, blue: 0.29)
    static let steel = Color(red: 0.56, green: 0.58, blue: 0.64)
    static let light = Color(red: 0.90, green: 0.91, blue: 0.94)
    static let blush = Color(red: 1, green: 0.47, blue: 0.63).opacity(0.55)
    static let phones = Color(red: 0.17, green: 0.18, blue: 0.23)

    static func draw(_ pose: RobotPose, in c: GraphicsContext) {
        let hb = pose.bob
        let bb = pose.bob / 2
        // 足(歩くときは交互に上がる)
        var stepL: CGFloat = 0
        var stepR: CGFloat = 0
        if let step = pose.step {
            let s = sin(step * 2 * Double.pi)
            stepL = CGFloat(max(0, s) * 3 * pose.moving)
            stepR = CGFloat(max(0, -s) * 3 * pose.moving)
        }
        rrect(c, 22, 78 - stepL, 12, 6, 3, dark)
        rrect(c, 38, 78 - stepR, 12, 6, 3, dark)
        // アンテナ
        let ax = 36 + pose.antenna
        var stem = Path()
        stem.move(to: CGPoint(x: 36, y: 12 + hb))
        stem.addLine(to: CGPoint(x: ax, y: 4 + hb))
        c.stroke(stem, with: .color(Color.white.opacity(0.85)), lineWidth: 2)
        circle(c, ax, 3 + hb, 6, fill: Color(red: 1, green: 0.63, blue: 0.24).opacity(0.28))
        circle(c, ax, 3 + hb, 3.6, fill: Color(red: 1, green: 0.64, blue: 0.24))
        // 首・体・胸のハート
        rrect(c, 33, 46 + bb, 6, 6, 1.5, Color(red: 0.72, green: 0.75, blue: 0.79))
        c.fill(Path(roundedRect: CGRect(x: 18, y: 50 + bb, width: 36, height: 26), cornerRadius: 11),
               with: .linearGradient(Gradient(colors: [green, blue]),
                                     startPoint: CGPoint(x: 0, y: 50 + bb),
                                     endPoint: CGPoint(x: 0, y: 76 + bb)))
        heart(c, 36, 61 + bb, Color.white.opacity(0.92))
        // 腕と手
        let hl = limb(c, 19, 56 + bb, length: 14, width: 6, angle: pose.leftArm, color: gray)
        circle(c, hl.x, hl.y, 4.2, fill: hand)
        let hr = limb(c, 53, 56 + bb, length: 14, width: 6, angle: pose.rightArm, color: gray)
        circle(c, hr.x, hr.y, 4.2, fill: hand)
        // 胸の前のフィルム
        if pose.holdFilm > 0.01 {
            var k = c
            k.opacity = pose.holdFilm
            film(k, 19, 58 + bb, 34, 13, tilt: pose.tilt)
        }
        // 右手の道具(手の位置を原点に、腕の向きへ回す)
        if let kind = pose.tool, pose.toolPresence > 0.01 {
            var k = c
            k.translateBy(x: hr.x, y: hr.y)
            k.rotate(by: .degrees(pose.rightArm))
            tool(k, kind, presence: pose.toolPresence, open: pose.open, shout: pose.shout)
        }
        // 頭(白い丸角)とバイザー
        rrect(c, 12, 10 + hb, 48, 36, 14, Color(red: 0.96, green: 0.96, blue: 0.97))
        ellipse(c, 30, 16 + hb, 10, 3, Color.white.opacity(0.5))
        rrect(c, 19, 16 + hb, 34, 23, 10, navy)
        // 光る目(まばたきで細くなる)とハイライト
        let ry = CGFloat(6 * (1 - 0.9 * pose.blink))
        let look = pose.look
        for ex in [28.5, 43.5] as [CGFloat] {
            ellipse(c, ex + look, 27.5 + hb, 4.6 + 2.5, ry + 2.5, cyan.opacity(0.28))
            ellipse(c, ex + look, 27.5 + hb, 4.6, ry, cyan)
        }
        if pose.blink < 0.5 {
            circle(c, 26.8 + look, 25.2 + hb, 1.5, fill: Color.white.opacity(0.95))
            circle(c, 41.8 + look, 25.2 + hb, 1.5, fill: Color.white.opacity(0.95))
        }
        // 笑った口
        arc(c, 36 + look * 0.5, 33 + hb, 3.4, from: 20, to: 160, color: cyan, lineWidth: 1.8)
        // ほっぺ
        circle(c, 16.5, 37.5 + hb, 2.4, fill: blush)
        circle(c, 55.5, 37.5 + hb, 2.4, fill: blush)
        // ヘッドホン
        if pose.headphones {
            arc(c, 36, 28 + hb, 26, from: 200, to: 340, color: phones, lineWidth: 3)
            rrect(c, 7, 21 + hb, 9, 14, 3.5, phones)
            rrect(c, 56, 21 + hb, 9, 14, 3.5, phones)
            circle(c, 11.5, 28 + hb, 2.4, stroke: cyan, lineWidth: 1.4)
            circle(c, 60.5, 28 + hb, 2.4, stroke: cyan, lineWidth: 1.4)
        }
    }

    /// 道具。原点 = 手、+x = 腕の向き
    private static func tool(_ c: GraphicsContext, _ kind: RobotToolKind, presence: Double, open: Double, shout: Double) {
        var k = c
        k.opacity = presence
        let s = CGFloat(0.7 + 0.3 * presence)
        k.scaleBy(x: s, y: s)
        switch kind {
        case .magnifier:
            limb(k, 0, 0, length: 9, width: 4, angle: 0, color: steel)
            circle(k, 16, 0, 7, fill: Color(red: 0.67, green: 0.88, blue: 1).opacity(0.35), stroke: .white, lineWidth: 2.5)
            circle(k, 13.5, -2.5, 1.6, fill: Color.white.opacity(0.85))
        case .scissors:
            let a = 6 + 12 * open
            circle(k, 2.5, -3.5, 2.8, stroke: light, lineWidth: 1.8)
            circle(k, 2.5, 3.5, 2.8, stroke: light, lineWidth: 1.8)
            limb(k, 6, 0, length: 12, width: 3.4, angle: -a, color: light)
            limb(k, 6, 0, length: 12, width: 3.4, angle: a, color: light)
            circle(k, 6, 0, 1.6, fill: Color(red: 0.36, green: 0.38, blue: 0.44))
        case .tape:
            rrect(k, 2, -4, 14, 8, 2.5, Color(red: 0.96, green: 0.85, blue: 0.56))
            rrect(k, 2, -1.5, 14, 3, 1, Color(red: 0.91, green: 0.72, blue: 0.29))
        case .brush:
            limb(k, 0, 0, length: 12, width: 4, angle: 0, color: Color(red: 0.85, green: 0.63, blue: 0.40))
            rrect(k, 12, -2.6, 3, 5.2, 0.8, Color(red: 0.76, green: 0.78, blue: 0.82))
            rrect(k, 15, -3, 8, 6, 2, Color(red: 0.96, green: 0.96, blue: 0.96))
            rrect(k, 20, -3, 3, 6, 1.5, Color(red: 1, green: 0.42, blue: 0.60))
        case .megaphone:
            rrect(k, 0, -1.6, 5, 3.2, 1, steel)
            polygon(k, [CGPoint(x: 5, y: -2.6), CGPoint(x: 17, y: -7.5), CGPoint(x: 17, y: 7.5), CGPoint(x: 5, y: 2.6)],
                    Color(red: 1, green: 0.44, blue: 0.38))
            rrect(k, 16.5, -8, 2.5, 16, 1.2, Color(red: 1, green: 0.85, blue: 0.83))
            if shout > 0.01 {
                for r in [5.0, 9.0] {
                    arc(k, 19, 0, r, from: -50, to: 50, color: Color.white.opacity(0.8 * shout), lineWidth: 1.4)
                }
            }
        case .pencil:
            rrect(k, -2, -2.2, 3, 4.4, 1, Color(red: 1, green: 0.56, blue: 0.69))
            rrect(k, 1, -2.2, 11, 4.4, 0.5, Color(red: 0.96, green: 0.77, blue: 0.26))
            polygon(k, [CGPoint(x: 12, y: -2.2), CGPoint(x: 17, y: 0), CGPoint(x: 12, y: 2.2)], Color(red: 0.91, green: 0.79, blue: 0.63))
            polygon(k, [CGPoint(x: 15.2, y: -0.8), CGPoint(x: 17, y: 0), CGPoint(x: 15.2, y: 0.8)], dark)
        }
    }

    /// 運んでいるフィルム(ブランド色のコマと送り穴)
    private static func film(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, tilt: Double) {
        var k = c
        k.translateBy(x: x + w / 2, y: y + h / 2)
        k.rotate(by: .degrees(tilt))
        k.translateBy(x: -w / 2, y: -h / 2)
        rrect(k, 0, 0, w, h, 2, Color(red: 0.16, green: 0.18, blue: 0.22))
        k.fill(Path(roundedRect: CGRect(x: 2, y: 3, width: w - 4, height: h - 6), cornerRadius: 1),
               with: .linearGradient(Gradient(colors: [green, blue]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
        let hole = Color(red: 0.60, green: 0.63, blue: 0.68)
        var i: CGFloat = 3
        while i < w - 2 {
            rrect(k, i, 0.8, 2.4, 1.6, 0.5, hole)
            rrect(k, i, h - 2.4, 2.4, 1.6, 0.5, hole)
            i += 5
        }
    }

    // MARK: 描く部品

    private static func rrect(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: Color) {
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(color))
    }

    private static func circle(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat,
                               fill: Color? = nil, stroke: Color? = nil, lineWidth: CGFloat = 1) {
        let path = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        if let fill { c.fill(path, with: .color(fill)) }
        if let stroke { c.stroke(path, with: .color(stroke), lineWidth: lineWidth) }
    }

    private static func ellipse(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color) {
        let ry = max(0.2, ry)
        c.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)), with: .color(color))
    }

    /// (x, y) から角度 angle(度。0 = 右、90 = 下)へ長さ length のカプセル。先端の位置を返す
    @discardableResult
    private static func limb(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, length: CGFloat, width w: CGFloat,
                             angle: Double, color: Color) -> CGPoint {
        var k = c
        k.translateBy(x: x, y: y)
        k.rotate(by: .degrees(angle))
        rrect(k, -w / 2, -w / 2, length + w, w, w / 2, color)
        let r = angle * Double.pi / 180
        return CGPoint(x: x + length * CGFloat(cos(r)), y: y + length * CGFloat(sin(r)))
    }

    private static func polygon(_ c: GraphicsContext, _ points: [CGPoint], _ color: Color) {
        guard let first = points.first else { return }
        var p = Path()
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        c.fill(p, with: .color(color))
    }

    private static func arc(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, from: Double, to: Double,
                            color: Color, lineWidth: CGFloat) {
        var p = Path()
        p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private static func heart(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y + 3.6))
        p.addCurve(to: CGPoint(x: x, y: y - 2), control1: CGPoint(x: x - 5, y: y - 0.5), control2: CGPoint(x: x - 3.6, y: y - 4.6))
        p.addCurve(to: CGPoint(x: x, y: y + 3.6), control1: CGPoint(x: x + 3.6, y: y - 4.6), control2: CGPoint(x: x + 5, y: y - 0.5))
        c.fill(p, with: .color(color))
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
