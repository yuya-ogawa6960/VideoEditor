import SwiftUI
import UIKit
import CoreImage
import CoreVideo
import Observation

// =====================================================================
// 解析中の表示: いま AI が見ているコマ(AnalysisPeek)と、ロボットがフィルムを
// 運んで・切って・確かめるアニメーション(コマ画像のくり返し)。
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

/// 作業カードの「キャンセル」の上に出す、もう 1 つのボタン(字幕の「Apple 音声認識で今すぐ作る」など)
struct WorkingCardAction {
    let title: String
    let systemImage: String
    /// ボタンの下に出す小さな補足(nil なら出さない)
    let footnote: String?
    let action: () -> Void
}

/// 作業中のカード(AI が見ている映像 + ロボット + 進み具合)。解析・AI 処理・書き出しで共通
struct AIWorkingCard: View {
    let title: String
    let fraction: Double?
    /// 進み具合の下に出す補足(残り時間・状態など)
    let detail: String?
    /// 裏で続くかどうかの注意書きとそのアイコン
    let note: String
    let noteIcon: String
    /// カードの中に小さな広告を入れる(上に大きな広告を出せないときだけ)
    let inlineAd: Bool
    /// 上に出すコマ(nil なら解析中に AI が見ているコマ)と、その上の札の文
    let peekImage: CGImage?
    let peekLabel: String?
    /// 真ん中で動くロボット(作業の種類ごと)
    let robot: RobotAnimation
    /// キャンセルの上に出すもう 1 つのボタン(nil なら出さない)
    let secondaryAction: WorkingCardAction?
    let onCancel: (() -> Void)?

    @State private var peek = AnalysisPeek.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 解析・AI 処理(ClipFXProgress)用
    init(progress: ClipFXProgress, inlineAd: Bool = true, onCancel: (() -> Void)?) {
        title = progress.title
        fraction = progress.fraction
        detail = nil
        note = BackgroundWorkNote.analysis
        noteIcon = BackgroundWorkNote.canContinueInBackground ? "lock.open" : "exclamationmark.triangle"
        self.inlineAd = inlineAd
        peekImage = nil
        peekLabel = nil
        robot = progress.robot
        secondaryAction = nil
        self.onCancel = onCancel
    }

    /// 書き出し・字幕の自動作成など、タイトルと進み具合を直接渡す
    init(title: String, fraction: Double?, detail: String? = nil,
         note: String, noteIcon: String, inlineAd: Bool = true,
         peekImage: CGImage? = nil, peekLabel: String? = nil,
         robot: RobotAnimation = .workshop, secondaryAction: WorkingCardAction? = nil,
         onCancel: (() -> Void)?) {
        self.title = title
        self.fraction = fraction
        self.detail = detail
        self.note = note
        self.noteIcon = noteIcon
        self.inlineAd = inlineAd
        self.peekImage = peekImage
        self.peekLabel = peekLabel
        self.robot = robot
        self.secondaryAction = secondaryAction
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 14) {
            if let frame = peekImage ?? peek.frame {
                AIScanningFrame(image: frame, label: peekLabel ?? String(localized: "AI が見ています"))
                    .frame(height: 150)
            }
            RobotWorkshop(clip: robot)

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
                // 動きを減らす設定ではロボットが止まるので、動いていることをくるくるで見せる
                if reduceMotion {
                    ProgressView()
                }
                Text(title)
                    .font(.callout)
            }
            if let detail {
                Text(detail.replacingOccurrences(of: " ・ ", with: "\n"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if inlineAd {
                NativeAdCard()
            }
            Label(note, systemImage: noteIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let secondaryAction {
                VStack(spacing: 6) {
                    Button {
                        EditorHaptics.tap()
                        secondaryAction.action()
                    } label: {
                        Label(secondaryAction.title, systemImage: secondaryAction.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(BrandStyle.gradient, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if let footnote = secondaryAction.footnote {
                        Text(footnote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
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
        .animation(reduceMotion ? nil : .spring(duration: 0.45), value: secondaryAction != nil)
        .onDisappear { AnalysisPeek.shared.clear() }
    }
}

/// 1 枚絵のロボット(フィルムを抱えて歩く係など)をゆっくり上下に浮かせる。動画が無いときの画面などに
struct FloatingRobot: View {
    let name: String
    var height: CGFloat = 150

    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            // 動きを減らす設定では浮かせない(途中で設定が変わっても止まる)
            .offset(y: reduceMotion ? 0 : (up ? -6 : 6))
            .onAppear {
                guard !reduceMotion else { return }
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
    /// 左下の札の文
    var label: String = String(localized: "AI が見ています")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 動きを減らす設定では時計を止める(走査線は出さず、赤い点も点滅させない)
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
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
                    if !reduceMotion {
                        LinearGradient(colors: [BrandStyle.coral.opacity(0), BrandStyle.coral.opacity(0.75), BrandStyle.coral.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 26)
                            .offset(y: CGFloat(phase) * (geo.size.height - 26))
                            .blendMode(.screen)
                    }
                    // 四隅の枠
                    CornerBrackets()
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .padding(8)
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                            .opacity(reduceMotion || Int(t * 2) % 2 == 0 ? 1 : 0.3)
                        Text(label)
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

// MARK: - ロボット(コマ画像のくり返し再生)

/// ロボットのアニメーション(ChatGPT で作った背景透明 PNG の連番)。
/// メモリを使わないよう、いま見せる 1 枚だけをファイルから読み込む。
/// - workshop: 720 × 218 を 1 秒 12 コマで 60 枚(5 秒でくり返し)。Resources/RobotAnimation/robot_anim_000.png …
///   左 = フィルムを運ぶ係 / 中 = はさみで切る係 / 右 = 虫めがねで確かめる係。解析・AI 処理・書き出し中に出す
/// - subtitles: 514 × 330 を 1 秒 12 コマで 72 枚(6 秒でくり返し)。Resources/RobotSubtitleAnimation/robot_sub_000.png …
///   ヘッドフォンで聞く → 両手で打ち込む → 聞き直す → 打ち込む → にっこりうなずく。字幕の自動作成中に出す
/// - modelDownload: 554 × 326 を 60 枚(5 秒)。ポストに届いた手紙を受け取って抱える。Whisper のモデルのダウンロード中
/// - modelLoading: 158 × 255 を 60 枚(5 秒)。マニュアルを両手で支えて読み、うなずく。Whisper のモデルの読み込み中
/// - consensus: 652 × 249 を 288 枚(24 秒)。3 体が ◯・△・✕ の札を一斉に上げて判定する。中だるみ・編集チェック中
/// - importing: 274 × 335 を 60 枚(5 秒)。雲から落ちてくるフィルムを受け止めて缶にしまう。動画の取り込み中
/// - emptyProjects: 292 × 254 を 48 枚(4 秒)。カメラの横で手を振って誘う。プロジェクト一覧が空のとき
/// - exportComplete: 344 × 318 を 30 枚(2.5 秒、1 回だけ)。リールを掲げて紙吹雪でバンザイ。書き出し完了
/// - subtitlesComplete: 235 × 254 を 24 枚(2 秒、1 回だけ)。字幕の吹き出しを掲げてサムズアップ。字幕の自動作成が完了
struct RobotAnimation: Sendable, Equatable {
    /// コマのファイル名の頭(<prefix>_000.png … と <prefix>_poster.png)
    let prefix: String
    let frameCount: Int
    let fps: Double
    /// コマの大きさ(縦横比に使う)
    let size: CGSize
    /// カードの中での高さ(nil なら幅いっぱいに縦横比どおり。決めたときはその高さに収める)
    let height: CGFloat?
    /// くり返すか。false なら 1 回だけ再生して最後のコマ(= poster)で止まる
    var loops: Bool = true

    static let workshop = RobotAnimation(prefix: "robot_anim", frameCount: 60, fps: 12,
                                         size: CGSize(width: 720, height: 218), height: nil)
    static let subtitles = RobotAnimation(prefix: "robot_sub", frameCount: 72, fps: 12,
                                          size: CGSize(width: 514, height: 330), height: 130)
    static let modelDownload = RobotAnimation(prefix: "robot_mail", frameCount: 60, fps: 12,
                                              size: CGSize(width: 554, height: 326), height: 150)
    static let modelLoading = RobotAnimation(prefix: "robot_load", frameCount: 60, fps: 12,
                                             size: CGSize(width: 158, height: 255), height: 130)
    static let consensus = RobotAnimation(prefix: "robot_judge", frameCount: 288, fps: 12,
                                          size: CGSize(width: 652, height: 249), height: nil)
    static let importing = RobotAnimation(prefix: "robot_import", frameCount: 60, fps: 12,
                                          size: CGSize(width: 274, height: 335), height: 150)
    static let emptyProjects = RobotAnimation(prefix: "robot_empty", frameCount: 48, fps: 12,
                                              size: CGSize(width: 292, height: 254), height: 170)
    static let exportComplete = RobotAnimation(prefix: "robot_export_done", frameCount: 30, fps: 12,
                                               size: CGSize(width: 344, height: 318), height: 160, loops: false)
    static let subtitlesComplete = RobotAnimation(prefix: "robot_sub_done", frameCount: 24, fps: 12,
                                                  size: CGSize(width: 235, height: 254), height: 150, loops: false)

    /// その時刻に見せるコマの番号
    func frameIndex(at date: Date) -> Int {
        let n = Int(floor(date.timeIntervalSinceReferenceDate * fps)) % frameCount
        return n < 0 ? n + frameCount : n
    }

    func image(_ index: Int) -> UIImage? {
        Self.load(prefix + String(format: "_%03d", index))
    }

    /// 動きを減らす設定のときに見せる 1 枚
    var poster: UIImage? { Self.load(prefix + "_poster") }

    private static func load(_ name: String) -> UIImage? {
        // UIImage(named:) はキャッシュに残るので、ファイルから直接読む
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// 作業中のロボット(コマの縦横比のまま幅いっぱいに。高さが決まっていればその高さに収める)
struct RobotWorkshop: View {
    var clip: RobotAnimation = .workshop

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1 回だけ再生するアニメーションの再生開始時刻と、再生し終えたか
    @State private var startedAt: Date?
    @State private var finished = false

    var body: some View {
        // Group だと .task が中の枝ごとに付き、最後のコマに切り替わるたびに再生がやり直されるので ZStack で包む
        ZStack {
            // 1 回だけのものは、再生し終えたら最後のコマ(poster と同じ)で止める
            if reduceMotion || finished {
                frame(clip.poster)
            } else {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / clip.fps)) { context in
                    frame(clip.image(frameIndex(at: context.date)))
                }
            }
        }
        .task(id: clip.prefix) {
            guard !clip.loops else { return }
            startedAt = Date()
            finished = false
            let seconds = Double(clip.frameCount) / max(clip.fps, 1)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { finished = true }
        }
        .aspectRatio(clip.size, contentMode: .fit)
        // 高さを決めておく(上限だけだと、高さを決めずに測られたときに絵がはみ出す)
        .frame(height: clip.height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func frameIndex(at date: Date) -> Int {
        if clip.loops { return clip.frameIndex(at: date) }
        let start = startedAt ?? date
        return min(max(Int(date.timeIntervalSince(start) * clip.fps), 0), clip.frameCount - 1)
    }

    @ViewBuilder
    private func frame(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}

/// 字幕の自動作成中の表示(見どころ探しなどと同じ作業カードを、画面全体を暗くした上に出す)。
/// 上には、いま読み取っている位置のコマを元素材から取り出して見せる(進み具合から作品の時刻を求め、1 秒以上動いたら取り直す)
struct TranscriptionWorkingOverlay: View {
    let project: EditorProject
    /// nil のときは % を出さない(モデルの準備中など)
    let fraction: Double?
    let status: String
    /// nil のときはキャンセルボタンを出さない(キャンセルを押して止まるのを待っている間)
    let onCancel: (() -> Void)?
    /// Whisper の準備が長いとき、この回だけ Apple 音声認識で作る(nil ならボタンを出さない)
    var onSwitchToApple: (() -> Void)? = nil
    /// 真ん中のロボット(字幕を打つ係。モデルのダウンロード中・読み込み中はそれぞれ別のロボット)
    var robot: RobotAnimation = .subtitles

    @State private var frame: CGImage?
    @State private var lastTime: Double = -10

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            WorkingCardWithAd { inlineAd in
                AIWorkingCard(title: String(localized: "字幕を作っています"),
                              fraction: fraction,
                              detail: status.isEmpty ? nil : status,
                              note: BackgroundWorkNote.transcription,
                              noteIcon: BackgroundWorkNote.canContinueInBackground ? "lock.open" : "exclamationmark.triangle",
                              inlineAd: inlineAd,
                              peekImage: frame,
                              peekLabel: String(localized: "AI が聞いています"),
                              robot: robot,
                              secondaryAction: onSwitchToApple.map { action in
                                  WorkingCardAction(title: String(localized: "Apple 音声認識で今すぐ作る"),
                                                    systemImage: "bolt.fill",
                                                    footnote: String(localized: "Whisper の準備は裏で続け、次から使います。"),
                                                    action: action)
                              },
                              onCancel: onCancel)
            }
        }
        .task(id: Int((min(max(fraction ?? 0, 0), 1) * 100).rounded())) {
            await reload()
        }
    }

    private func reload() async {
        let total = CompositionBuilder.totalDuration(for: project.snapshot())
        let time = min(max(fraction ?? 0, 0), 1) * total
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

