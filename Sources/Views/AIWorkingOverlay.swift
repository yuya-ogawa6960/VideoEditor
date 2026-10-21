import SwiftUI
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
    @ObservationIgnored private let context = CIContext(options: [.cacheIntermediates: false])

    /// 解析中のコマを渡す(間引いて縮小し、メインスレッドで表示に反映)
    func post(_ buffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard now - lastPost > 0.33 else {
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

/// 解析中のカード(AI が見ている映像 + ロボット + 進み具合)
struct AIWorkingCard: View {
    let progress: ClipFXProgress
    let onCancel: (() -> Void)?

    @State private var peek = AnalysisPeek.shared

    var body: some View {
        let task = RobotTask.from(title: progress.title)
        VStack(spacing: 14) {
            if let frame = peek.frame {
                AIScanningFrame(image: frame)
                    .frame(height: 150)
            }
            RobotWorkshop(task: task, monitorFrame: peek.frame)
                .frame(height: 84)

            if let fraction = progress.fraction {
                let clamped = min(max(fraction, 0), 1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(BrandStyle.gradient)
                            .frame(width: max(8, geo.size.width * clamped))
                    }
                }
                .frame(height: 8)
                Text("\(progress.title) \(Int((clamped * 100).rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
            } else {
                Text(progress.title)
                    .font(.callout)
            }
            NativeAdCard()
            Label(BackgroundWorkNote.analysis,
                  systemImage: BackgroundWorkNote.canContinueInBackground ? "lock.open" : "exclamationmark.triangle")
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

/// 3 体の小さなロボットの作業場。
/// 左 = フィルムを一生懸命運ぶ係 / 中 = 切ってつなぐ(塗る)係 / 右 = モニターで確認して指示を出す係
struct RobotWorkshop: View {
    let task: RobotTask
    /// 右のロボットのモニターに映すコマ(いま AI が見ている映像)。nil なら流れるフィルム
    var monitorFrame: CGImage? = nil

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 編集中は 2.4 秒ごとに「切る → つなぐ → 塗る」を順に
            let step = Int(t / 2.4) % 3
            let local = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
            HStack(alignment: .bottom, spacing: 4) {
                CarrierRobot(t: t)
                    .frame(width: 96, height: 84)
                EditorRobot(t: t, task: task, step: step, local: local)
                    .frame(width: 100, height: 84)
                DirectorRobot(t: t, task: task, frame: monitorFrame)
                    .frame(width: 64, height: 84)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// フィルムを運ぶロボット(レールの上を右へ左へ。フィルムを両手で頭の上に掲げて小走り)
private struct CarrierRobot: View {
    let t: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(0, w - 44)
            let phase = (t / 3.2).truncatingRemainder(dividingBy: 2)   // 0→1 右へ、1→2 左へ
            let goingRight = phase < 1
            let x = CGFloat(goingRight ? phase : 2 - phase) * span
            let hop = CGFloat(abs(sin(t * 7))) * 3
            ZStack(alignment: .bottomLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: w, height: 3)
                    .offset(y: -3)
                VStack(spacing: -3) {
                    FilmStrip(offset: 0, split: nil, joined: false, paint: 0)
                        .frame(width: 40, height: 16)
                        .rotationEffect(.degrees(sin(t * 7) * 6))
                    Robot(t: t, tool: nil, working: false, scale: 0.6, armsUp: true)
                }
                .scaleEffect(x: goingRight ? 1 : -1, y: 1)
                .offset(x: x, y: -hop)
            }
        }
    }
}

/// 切ってつなぐロボット(作業台のフィルムを、切る → テープでつなぐ → 塗る)
private struct EditorRobot: View {
    let t: Double
    let task: RobotTask
    let step: Int
    let local: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Robot(t: t + 0.7, tool: toolName, working: true, scale: 0.62)
            workArea
                .frame(width: 50, height: 32)
                .padding(.bottom, 8)
        }
    }

    private var toolName: String {
        switch task {
        case .looking: return "magnifyingglass"
        case .listening: return "pencil"
        case .editing:
            switch step {
            case 0: return "scissors"
            case 1: return "bandage.fill"
            default: return "paintbrush.pointed.fill"
            }
        }
    }

    @ViewBuilder
    private var workArea: some View {
        switch task {
        case .looking:
            FilmStrip(offset: CGFloat(t * 18), split: nil, joined: false, paint: 0)
        case .listening:
            SoundWave(t: t)
        case .editing:
            switch step {
            case 0: FilmStrip(offset: 0, split: CGFloat(min(1, local * 1.6)), joined: false, paint: 0)
            case 1: FilmStrip(offset: 0, split: CGFloat(max(0, 1 - local * 1.6)), joined: local > 0.6, paint: 0)
            default: FilmStrip(offset: 0, split: nil, joined: false, paint: CGFloat(min(1, local * 1.3)))
            }
        }
    }
}

/// モニターで確認して指示を出すロボット(メガホンを振る。ときどき「!」)
private struct DirectorRobot: View {
    let t: Double
    let task: RobotTask
    let frame: CGImage?

    var body: some View {
        let shout = t.truncatingRemainder(dividingBy: 2.4) < 0.7
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.1))
                if let frame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    FilmStrip(offset: CGFloat(t * 18), split: nil, joined: false, paint: 0)
                        .padding(3)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 1)
                    .offset(y: CGFloat(sin(t * 2)) * 10)
            }
            .frame(width: 46, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4), lineWidth: 1))
            Robot(t: t + 1.4, tool: directorTool, working: true, scale: 0.6)
        }
        .overlay(alignment: .topTrailing) {
            if shout {
                Text(verbatim: "!")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(red: 0.15, green: 0.2, blue: 0.35))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white, in: Capsule())
                    .offset(x: 6, y: 22)
                    .transition(.opacity)
            }
        }
    }

    private var directorTool: String {
        switch task {
        case .looking: return "magnifyingglass"
        case .listening: return "headphones"
        case .editing: return "megaphone.fill"
        }
    }
}

/// かわいいロボット(まばたき・アンテナの揺れ・道具を持つ腕の動き)。scale で小さくできる
private struct Robot: View {
    let t: Double
    var tool: String? = nil
    var working: Bool = true
    var scale: CGFloat = 1
    /// 両手を上げてものを掲げる(運ぶ係)
    var armsUp: Bool = false

    var body: some View {
        let bob = CGFloat(sin(t * 4)) * 2
        let blink = (t.truncatingRemainder(dividingBy: 3.0)) < 0.12
        let armAngle = Angle.degrees(working ? sin(t * 8) * 18 - 20 : -10)
        ZStack {
            // アンテナ
            VStack(spacing: 0) {
                Circle().fill(BrandStyle.orange).frame(width: 8, height: 8)
                    .offset(x: CGFloat(sin(t * 3)) * 2)
                Rectangle().fill(Color.white.opacity(0.8)).frame(width: 2, height: 8)
            }
            .offset(y: -38 + bob)
            // 頭
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.92))
                .frame(width: 46, height: 34)
                .overlay(
                    HStack(spacing: 10) {
                        eye(blink: blink)
                        eye(blink: blink)
                    }
                    .offset(y: -2)
                )
                .overlay(
                    Capsule().fill(BrandStyle.pink.opacity(0.8)).frame(width: 12, height: 4).offset(y: 9)
                )
                .offset(y: -14 + bob)
            // 体
            RoundedRectangle(cornerRadius: 8)
                .fill(BrandStyle.gradient)
                .frame(width: 38, height: 30)
                .overlay(Circle().fill(Color.white.opacity(0.85)).frame(width: 8, height: 8))
                .offset(y: 20 + bob / 2)
            if armsUp {
                // 両手を上げる
                Capsule().fill(Color(white: 0.85)).frame(width: 6, height: 22)
                    .rotationEffect(.degrees(-20), anchor: .bottom)
                    .offset(x: -22, y: 4 + bob / 2)
                Capsule().fill(Color(white: 0.85)).frame(width: 6, height: 22)
                    .rotationEffect(.degrees(20), anchor: .bottom)
                    .offset(x: 22, y: 4 + bob / 2)
            } else if let tool {
                // 道具を持つ腕
                HStack(spacing: 0) {
                    Capsule().fill(Color(white: 0.85)).frame(width: 18, height: 6)
                    Image(systemName: tool)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .rotationEffect(armAngle, anchor: .leading)
                .offset(x: 30, y: 16 + bob / 2)
            }
        }
        .frame(width: 70, height: 90)
        .scaleEffect(scale)
        .frame(width: 70 * scale, height: 90 * scale)
    }

    private func eye(blink: Bool) -> some View {
        Capsule()
            .fill(Color(red: 0.15, green: 0.2, blue: 0.35))
            .frame(width: 7, height: blink ? 1.5 : 8)
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
