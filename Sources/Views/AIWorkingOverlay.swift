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
        if title.contains("文字起こし") || title.contains("聞") || title.contains("字幕") { return .listening }
        if title.contains("おまかせ") || title.contains("作成") || title.contains("編集") || title.contains("スライド") { return .editing }
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
            RobotWorkshop(task: task)
                .frame(height: 96)

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
private struct AIScanningFrame: View {
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

/// ロボットとフィルムの小さな作業場
private struct RobotWorkshop: View {
    let task: RobotTask

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 編集中は 2.4 秒ごとに「切る → つなぐ → 塗る」を順に
            let step = Int(t / 2.4) % 3
            let local = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
            HStack(alignment: .bottom, spacing: 10) {
                Robot(t: t, tool: toolName(step: step), working: true)
                    .frame(width: 70, height: 90)
                workArea(step: step, local: local, t: t)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
            }
        }
    }

    private func toolName(step: Int) -> String {
        switch task {
        case .looking: return "magnifyingglass"
        case .listening: return "headphones"
        case .editing:
            switch step {
            case 0: return "scissors"
            case 1: return "bandage.fill"
            default: return "paintbrush.pointed.fill"
            }
        }
    }

    @ViewBuilder
    private func workArea(step: Int, local: Double, t: Double) -> some View {
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

/// かわいいロボット(まばたき・アンテナの揺れ・道具を持つ腕の動き)
private struct Robot: View {
    let t: Double
    let tool: String
    let working: Bool

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

    private func eye(blink: Bool) -> some View {
        Capsule()
            .fill(Color(red: 0.15, green: 0.2, blue: 0.35))
            .frame(width: 7, height: blink ? 1.5 : 8)
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
