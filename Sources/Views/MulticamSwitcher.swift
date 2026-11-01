import SwiftUI
import AVFoundation

// マルチカメラのスイッチャー。
// メインの元動画(音あり・時計役)と各アングル(無音)を同時に再生し、映っているマスをタップして切り替える。
// 大きい画面(PGM)は合成を作り直さず、選ばれているアングルのプレイヤーをそのまま見せる(切り替えが即座に見える)。
// 色・効果は「完了」で閉じたあとの編集画面のプレビューに出る。

// MARK: - 同時再生

/// メインの元動画と各アングルを同期して動かす。メインスレッドから使う。
@Observable
final class MulticamSwitcherController {
    /// 0 = メインの元動画、1 以上 = アングル
    private(set) var players: [AVPlayer] = []
    /// メインの元素材上の再生位置(秒)
    private(set) var sourceTime: Double = 0
    private(set) var isPlaying: Bool = false

    @ObservationIgnored private var urls: [URL] = []
    /// アングル素材上の時刻 = メインの元素材上の時刻 + offset(メインは 0)
    @ObservationIgnored private var offsets: [Double] = []
    @ObservationIgnored private var durations: [Double] = []
    /// 再生するメインの元素材上の範囲(クリップのトリミング範囲)
    @ObservationIgnored private var range: ClosedRange<Double> = 0...0
    @ObservationIgnored private var rate: Float = 1
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var lastSyncCheck: CFAbsoluteTime = 0
    /// アングルごとの、合わせ直しの結果を待つ期限(この時刻までは合わせ直さない)
    @ObservationIgnored private var syncHoldUntil: [CFAbsoluteTime] = []
    @ObservationIgnored private var pendingSeeks = 0
    /// 再生を始めた時刻(動き出すまでの間に「止まった」と見なさないため)
    @ObservationIgnored private var playStartedAt: CFAbsoluteTime = 0

    /// 合わせ直しで、何秒先から一斉に動かすか(準備の間に止まって見えないよう少し先にする)
    private static let startLead: Double = 0.25
    /// これ以上ずれたらアングルを合わせ直す(秒)
    private static let driftTolerance: Double = 0.08

    deinit {
        if let timeObserver, let main = players.first {
            main.removeTimeObserver(timeObserver)
        }
    }

    // MARK: 準備・終了

    /// クリップの素材で用意する。アングルが同じなら、ずれ・範囲だけ入れ替える
    func configure(clip: Clip) {
        offsets = [0] + clip.multicam.angles.map(\.offset)
        durations = [clip.duration] + clip.multicam.angles.map(\.duration)
        range = clip.startTime...max(clip.startTime, clip.endTime)
        rate = Float(min(max(clip.speed, 0.25), 4))
        let newURLs = [clip.url] + clip.multicam.angles.map(\.url)
        if newURLs == urls {
            if !isPlaying { alignAnglesToMain() }
            return
        }
        pause()
        removeTimeObserver()
        urls = newURLs
        syncHoldUntil = Array(repeating: 0, count: newURLs.count)
        players = newURLs.enumerated().map { index, url in
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .spectral
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            // 音はメインだけ(切り替えのタイミングを耳で合わせられるように)
            player.isMuted = index != 0
            return player
        }
        if let main = players.first {
            timeObserver = main.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                        queue: .main) { [weak self] time in
                self?.tick(time)
            }
        }
        seek(to: sourceTime)
    }

    /// 止めて、デコーダーを手放す
    func stop() {
        pause()
        removeTimeObserver()
        for player in players {
            player.replaceCurrentItem(with: nil)
        }
        players = []
        urls = []
    }

    private func removeTimeObserver() {
        if let timeObserver, let main = players.first {
            main.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    // MARK: 再生

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let main = players.first else { return }
        // マナーモードでも音が出るカテゴリで再生する
        AudioSessionSetup.ensurePlayback()
        if sourceTime >= range.upperBound - 0.05 {
            seek(to: range.lowerBound)
        }
        isPlaying = true
        playStartedAt = CFAbsoluteTimeGetCurrent()
        lastSyncCheck = playStartedAt
        let start = sourceTime
        guard main.currentItem?.status == .readyToPlay else {
            main.playImmediately(atRate: rate)
            return
        }
        // メインもアングルも同じ時刻(少し先)から一斉に動かす
        let host = Self.hostTime(after: Self.startLead)
        main.setRate(rate, time: CMTime(seconds: start, preferredTimescale: 600), atHostTime: host)
        for index in players.indices.dropFirst() {
            startAngle(index, mainTimeAtHost: start, host: host)
        }
    }

    func pause() {
        for player in players {
            player.pause()
        }
        isPlaying = false
        alignAnglesToMain()
    }

    /// メインの元素材上の時刻へ移る(再生中なら止める)
    func seek(to seconds: Double) {
        if isPlaying {
            for player in players {
                player.pause()
            }
            isPlaying = false
        }
        let safe = seconds.isFinite ? seconds : range.lowerBound
        let target = min(max(safe, range.lowerBound), range.upperBound)
        sourceTime = target
        guard let main = players.first else { return }
        pendingSeeks += 1
        main.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                  toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingSeeks = max(0, self.pendingSeeks - 1)
            }
        }
        for index in players.indices.dropFirst() {
            seekAngle(index, mainTime: target)
        }
    }

    // MARK: 同期

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite, let main = players.first else { return }
        if pendingSeeks == 0 {
            let clamped = min(max(seconds, range.lowerBound), range.upperBound)
            if abs(clamped - sourceTime) > 0.0001 {
                sourceTime = clamped
            }
        }
        guard isPlaying else { return }
        // クリップの終わり、または元動画の終わりで止める
        if seconds >= range.upperBound - 0.01 {
            pause()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        // 元動画の終わりなどでメインが止まったら、全部止める
        if main.timeControlStatus == .paused && pendingSeeks == 0 && now - playStartedAt > 1 {
            pause()
            return
        }
        guard main.timeControlStatus == .playing else { return }

        guard now - lastSyncCheck > 0.5 else { return }
        lastSyncCheck = now
        for index in players.indices.dropFirst() where index < syncHoldUntil.count {
            guard now >= syncHoldUntil[index] else { continue }
            let player = players[index]
            guard hasFootage(index, at: seconds + Self.startLead * Double(rate)) else {
                if player.timeControlStatus != .paused { player.pause() }
                continue
            }
            let current = player.currentTime().seconds
            let target = seconds + offsets[index]
            if player.timeControlStatus == .paused || !current.isFinite
                || abs(current - target) > Self.driftTolerance {
                startAngle(index, mainTimeAtHost: seconds + Self.startLead * Double(rate),
                           host: Self.hostTime(after: Self.startLead))
            }
        }
    }

    /// アングルを、host の時刻にメインが mainTimeAtHost にいるのに合わせて動かす
    private func startAngle(_ index: Int, mainTimeAtHost: Double, host: CMTime) {
        let player = players[index]
        guard player.currentItem != nil, index < offsets.count else { return }
        guard hasFootage(index, at: mainTimeAtHost) else {
            player.pause()
            seekAngle(index, mainTime: mainTimeAtHost)
            return
        }
        if index < syncHoldUntil.count {
            syncHoldUntil[index] = CFAbsoluteTimeGetCurrent() + Self.startLead + 0.4
        }
        let target = mainTimeAtHost + offsets[index]
        if player.currentItem?.status == .readyToPlay {
            player.setRate(rate, time: CMTime(seconds: target, preferredTimescale: 600), atHostTime: host)
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            player.playImmediately(atRate: rate)
        }
    }

    /// 止めているアングルをメインの位置に合わせる(素材の外なら端のコマ)
    private func seekAngle(_ index: Int, mainTime: Double) {
        guard index < players.count, index < offsets.count else { return }
        let player = players[index]
        guard player.currentItem != nil else { return }
        let target = min(max(mainTime + offsets[index], 0), max(0, durations[index] - 0.04))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func alignAnglesToMain() {
        guard let main = players.first else { return }
        let mainTime = main.currentTime().seconds
        let t = mainTime.isFinite && pendingSeeks == 0 ? mainTime : sourceTime
        for index in players.indices.dropFirst() {
            seekAngle(index, mainTime: t)
        }
    }

    /// メインの元素材上の時刻 t に、この素材(0 = メイン)の映像があるか
    private func hasFootage(_ index: Int, at t: Double) -> Bool {
        guard index < offsets.count, index < durations.count else { return false }
        let local = t + offsets[index]
        return local >= 0 && local < durations[index] - 0.05
    }

    private static func hostTime(after seconds: Double) -> CMTime {
        CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                  CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}

// MARK: - 画面

/// スイッチャーの上半分(PGM・再生・切替の帯・各アングルのマス)
struct MulticamSwitcherPanel: View {
    let switcher: MulticamSwitcherController
    let clip: Clip
    /// 読み込めないアングルの番号(1 から)
    let unreadableAngles: Set<Int>
    let onCut: (Int) -> Void

    /// 切替点の判定の余裕(秒)。シークの丸めで再生位置が切替点のわずかに手前になっても、切り替えたあとのアングルとして扱う
    static let switchTolerance = 0.002

    private var multicam: MulticamInfo { clip.multicam }
    private var sourceCount: Int { multicam.angles.count + 1 }
    private var activeAngle: Int { multicam.angleIndex(at: switcher.sourceTime + Self.switchTolerance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            programMonitor
            transport
                .padding(.horizontal, 16)
            switchStrip
                .frame(height: 22)
                .padding(.horizontal, 16)
            if multicam.angles.isEmpty {
                Text("別のカメラの動画を「アングルを追加」で入れると、並べて再生しながら切り替えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                sourceGrid
                    .padding(.horizontal, 16)
                Text("再生しながら、使いたい映像のマスをタップします。止めた状態でタップすると、その位置から切り替わります。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: PGM

    private var programMonitor: some View {
        let active = activeAngle
        return ZStack {
            Color.black
            // 全部のプレイヤーを重ねて、選ばれているものだけ見せる(差し替えずに出すので、切り替えたコマから見える)
            ForEach(Array(switcher.players.enumerated()), id: \.offset) { index, player in
                PreviewPlayerLayerView(player: player)
                    .opacity(index == active ? 1 : 0)
            }
            if let message = unavailableMessage(for: active) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Text("PGM")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                Text(Self.label(active))
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    // MARK: 再生

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                switcher.togglePlay()
            } label: {
                Image(systemName: switcher.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(switcher.isPlaying ? String(localized: "一時停止") : String(localized: "再生"))

            Text(verbatim: "\(MediaTimeText.mmss(max(0, switcher.sourceTime - clip.startTime))) / \(MediaTimeText.mmss(max(0, clip.endTime - clip.startTime)))")
                .font(.callout)
                .monospacedDigit()

            Spacer()

            Button {
                switcher.seek(to: clip.startTime)
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("先頭へ")
        }
    }

    // MARK: 切替の帯(色 = アングル。ドラッグで位置を移す)

    private var switchStrip: some View {
        GeometryReader { geo in
            let lower = clip.startTime
            let length = max(clip.endTime - clip.startTime, 0.01)
            let runs = Self.runs(multicam: multicam, start: clip.startTime, end: clip.endTime)
            let playheadX = CGFloat((switcher.sourceTime - lower) / length) * geo.size.width
            ZStack(alignment: .leading) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    Rectangle()
                        .fill(Self.color(run.angle))
                        .frame(width: max(1, CGFloat((run.end - run.start) / length) * geo.size.width))
                        .offset(x: CGFloat((run.start - lower) / length) * geo.size.width)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: min(max(0, playheadX - 1), max(0, geo.size.width - 2)))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                        switcher.seek(to: lower + Double(ratio) * length)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("切替の帯")
        .accessibilityValue(Self.label(activeAngle))
    }

    // MARK: 各アングルのマス

    private var sourceGrid: some View {
        let columnCount = sourceCount <= 2 ? 2 : 3
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
        let active = activeAngle
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(0..<sourceCount, id: \.self) { n in
                Button {
                    onCut(n)
                } label: {
                    tile(n, isActive: n == active)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.label(n))
                .accessibilityAddTraits(n == active ? .isSelected : [])
            }
        }
    }

    private func tile(_ n: Int, isActive: Bool) -> some View {
        ZStack {
            Color.black
            if n < switcher.players.count {
                PreviewPlayerLayerView(player: switcher.players[n])
                    .allowsHitTesting(false)
            }
            if let message = unavailableMessage(for: n) {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(4)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: sourceCount <= 2 ? 110 : 88)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.color(n))
                    .frame(width: 8, height: 8)
                Text(Self.label(n))
                    .font(.caption2.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.red : Color.white.opacity(0.15), lineWidth: isActive ? 4 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// この素材(0 = メイン)の映像がいまの位置で出せないときの説明
    private func unavailableMessage(for n: Int) -> String? {
        guard n > 0, n <= multicam.angles.count else { return nil }
        if unreadableAngles.contains(n) {
            return String(localized: "読み込めません")
        }
        let angle = multicam.angles[n - 1]
        let local = switcher.sourceTime + angle.offset
        if local < 0 || local > angle.duration {
            return String(localized: "この位置は映像なし")
        }
        return nil
    }

    // MARK: 共通

    static func label(_ n: Int) -> String {
        n <= 0 ? String(localized: "メイン") : String(localized: "アングル\(n)")
    }

    static func color(_ n: Int) -> Color {
        let palette: [Color] = [.gray, .blue, .green, .orange, .purple, .pink, .teal, .yellow]
        return palette[max(0, n) % palette.count]
    }

    /// 元素材上の範囲 [start, end) をアングル番号ごとの区間に分ける(CompositionBuilder と同じ区切り方)
    static func runs(multicam: MulticamInfo, start: Double, end: Double) -> [(start: Double, end: Double, angle: Int)] {
        guard end > start else { return [] }
        var result: [(start: Double, end: Double, angle: Int)] = []
        var current = multicam.angleIndex(at: start)
        var runStart = start
        for sw in multicam.switches.sorted(by: { $0.time < $1.time }) where sw.time > start && sw.time < end {
            let angle = min(max(sw.angle, 0), multicam.angles.count)
            if angle != current {
                result.append((start: runStart, end: sw.time, angle: current))
                runStart = sw.time
                current = angle
            }
        }
        result.append((start: runStart, end: end, angle: current))
        return result
    }
}
