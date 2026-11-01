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
    /// メインと一緒に音を鳴らすアングル(nil ならメインの音だけ)。音が二重に聞こえるかで、ずれを耳で確かめる
    private(set) var listeningAngle: Int?
    /// listeningAngle と一緒に鳴らす素材(0 = メイン。別のアングルの音で合わせたときはそのアングル)
    private(set) var listeningReference: Int = 0

    @ObservationIgnored private var urls: [URL] = []
    /// アングル素材上の時刻 = offset + rate × メインの元素材上の時刻(メインは offset 0・rate 1)
    @ObservationIgnored private var offsets: [Double] = []
    @ObservationIgnored private var rates: [Double] = []
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
    /// これ以上ずれたらアングルを合わせ直す(秒)。耳で確かめている間は細かく合わせる
    private var driftTolerance: Double { listeningAngle == nil ? 0.08 : 0.02 }
    /// ずれを確かめる間隔(秒)
    private var syncCheckInterval: Double { listeningAngle == nil ? 0.5 : 0.25 }

    deinit {
        if let timeObserver, let main = players.first {
            main.removeTimeObserver(timeObserver)
        }
    }

    // MARK: 準備・終了

    /// クリップの素材で用意する。アングルが同じなら、ずれ・範囲だけ入れ替える
    func configure(clip: Clip) {
        offsets = [0] + clip.multicam.angles.map(\.offset)
        rates = [1] + clip.multicam.angles.map(\.rate)
        durations = [clip.duration] + clip.multicam.angles.map(\.duration)
        range = clip.startTime...max(clip.startTime, clip.endTime)
        rate = Float(min(max(clip.speed, 0.25), 4))
        let newURLs = [clip.url] + clip.multicam.angles.map(\.url)
        if newURLs == urls {
            if isPlaying {
                // 再生中にずれを変えたら、予約中のものも含めて次の確認ですぐ合わせ直す
                syncHoldUntil = Array(repeating: 0, count: syncHoldUntil.count)
                lastSyncCheck = 0
            } else {
                alignAnglesToMain()
            }
            return
        }
        pause()
        removeTimeObserver()
        urls = newURLs
        listeningAngle = nil
        listeningReference = 0
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
        listeningAngle = nil
        listeningReference = 0
    }

    /// アングル n(1 から)の音も、reference(0 = メイン)と一緒に鳴らす。nil ならメインの音だけ
    func setListening(_ n: Int?, reference: Int = 0) {
        if let n, n >= 1, n < players.count {
            listeningAngle = n
            listeningReference = (reference >= 0 && reference < players.count && reference != n) ? reference : 0
        } else {
            listeningAngle = nil
            listeningReference = 0
        }
        for (index, player) in players.enumerated() {
            player.isMuted = !(index == listeningReference || index == listeningAngle)
        }
        // 細かく合わせ直すのを、次の確認からすぐ始める
        if isPlaying {
            syncHoldUntil = Array(repeating: 0, count: syncHoldUntil.count)
            lastSyncCheck = 0
        }
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

        guard now - lastSyncCheck > syncCheckInterval else { return }
        lastSyncCheck = now
        for index in players.indices.dropFirst() where index < syncHoldUntil.count {
            guard now >= syncHoldUntil[index] else { continue }
            let player = players[index]
            let local = angleTime(index, atMain: seconds)
            // アングルの映像が終わったら止める
            if local >= durations[index] - 0.05 {
                if player.timeControlStatus != .paused { player.pause() }
                continue
            }
            // まだアングルの映像が始まっていない: 始まる時刻に動き出すよう予約し直す
            // (予約した後は syncHoldUntil で始まるまで待つので、ここに来るのはずれを変えたときか、メインが遅れたとき)
            if local < 0 {
                startAngle(index, mainTimeAtHost: seconds + Self.startLead * Double(rate),
                           host: Self.hostTime(after: Self.startLead))
                continue
            }
            let current = player.currentTime().seconds
            if player.timeControlStatus == .paused || !current.isFinite
                || abs(current - local) > driftTolerance {
                startAngle(index, mainTimeAtHost: seconds + Self.startLead * Double(rate),
                           host: Self.hostTime(after: Self.startLead))
            }
        }
    }

    /// アングルを、host の時刻にメインが mainTimeAtHost にいるのに合わせて動かす
    private func startAngle(_ index: Int, mainTimeAtHost: Double, host: CMTime) {
        let player = players[index]
        guard player.currentItem != nil, index < offsets.count, index < syncHoldUntil.count else { return }
        let localAtHost = angleTime(index, atMain: mainTimeAtHost)
        guard localAtHost < durations[index] - 0.05 else {
            player.pause()
            seekAngle(index, mainTime: mainTimeAtHost)
            return
        }
        // 時計のずれの補正があるアングルは、その分だけ速さを変えて動かす
        let angleRate = Float(Double(rate) * angleRateFactor(index))
        // アングルの映像が host より後に始まるなら、始まる時刻まで待たせて頭から動かす
        let wait = max(0, -localAtHost) / Double(angleRate)
        let now = CFAbsoluteTimeGetCurrent()
        if player.currentItem?.status == .readyToPlay {
            let startHost = wait > 0
                ? CMTimeAdd(host, CMTime(seconds: wait, preferredTimescale: 1_000_000_000))
                : host
            syncHoldUntil[index] = now + Self.startLead + wait + 0.4
            player.setRate(angleRate, time: CMTime(seconds: max(0, localAtHost), preferredTimescale: 600),
                           atHostTime: startHost)
        } else if wait <= 0 {
            syncHoldUntil[index] = now + 0.5
            player.seek(to: CMTime(seconds: localAtHost, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            player.playImmediately(atRate: angleRate)
        } else {
            // 読み込み中で予約できない: 止めて待ち、次の確認でもう一度予約する
            syncHoldUntil[index] = now + 0.5
            player.pause()
            seekAngle(index, mainTime: mainTimeAtHost)
        }
    }

    /// 止めているアングルをメインの位置に合わせる(素材の外なら端のコマ)
    private func seekAngle(_ index: Int, mainTime: Double) {
        guard index < players.count, index < offsets.count else { return }
        let player = players[index]
        guard player.currentItem != nil else { return }
        let target = min(max(angleTime(index, atMain: mainTime), 0), max(0, durations[index] - 0.04))
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

    /// メインの元素材上の時刻 t に対応する、素材 index(0 = メイン)上の時刻
    private func angleTime(_ index: Int, atMain t: Double) -> Double {
        let offset = index < offsets.count ? offsets[index] : 0
        return offset + angleRateFactor(index) * t
    }

    private func angleRateFactor(_ index: Int) -> Double {
        guard index < rates.count, rates[index].isFinite, rates[index] > 0 else { return 1 }
        return rates[index]
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
    /// 画面に使える高さ(小さい iPhone では PGM とマスを小さくして、下の一覧の場所を残す)
    let availableHeight: CGFloat
    let onCut: (Int) -> Void

    /// 切替点の判定の余裕(秒)。シークの丸めで再生位置が切替点のわずかに手前になっても、切り替えたあとのアングルとして扱う
    static let switchTolerance = 0.002

    private var multicam: MulticamInfo { clip.multicam }
    private var sourceCount: Int { multicam.angles.count + 1 }
    private var activeAngle: Int { multicam.angleIndex(at: switcher.sourceTime + Self.switchTolerance) }
    private var isCompact: Bool { availableHeight < 640 }
    private var programHeight: CGFloat { min(210, max(120, availableHeight * 0.3)) }
    private var tileHeight: CGFloat { min(sourceCount <= 2 ? 110 : 88, max(60, availableHeight * 0.14)) }

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
                if let listening = switcher.listeningAngle {
                    Text("\(Self.label(switcher.listeningReference))と\(Self.label(listening))の音を一緒に鳴らしています。音が二重に聞こえたら、ずれています。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                } else if !isCompact {
                    Text("再生しながら、使いたい映像のマスをタップします。止めた状態でタップすると、その位置から切り替わります。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 10)
        // 文字を大きくしても下の一覧が隠れないよう上限を決める
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    // MARK: PGM

    private var programMonitor: some View {
        let active = activeAngle
        // 書き出しと同じく、アングルの映像が無い位置・読めないアングルはメインを見せる
        let shown = hasFootage(active) ? active : 0
        return ZStack {
            Color.black
            // 全部のプレイヤーを重ねて、映すものだけ見せる(差し替えずに出すので、切り替えたコマから見える)
            ForEach(Array(switcher.players.enumerated()), id: \.offset) { index, player in
                PreviewPlayerLayerView(player: player)
                    .opacity(index == shown ? 1 : 0)
            }
            if shown != active {
                Text(unreadableAngles.contains(active)
                     ? String(localized: "\(Self.label(active))を読み込めないため、メインの映像になります")
                     : String(localized: "この位置は\(Self.label(active))の映像がないため、メインの映像になります"))
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: programHeight)
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

            if !multicam.angles.isEmpty {
                listenMenu
            }

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

    /// どの音を鳴らすか(メインだけ / メイン+アングル)
    private var listenMenu: some View {
        Menu {
            Button {
                switcher.setListening(nil)
            } label: {
                if switcher.listeningAngle == nil {
                    Label("メインの音だけ", systemImage: "checkmark")
                } else {
                    Text("メインの音だけ")
                }
            }
            ForEach(1..<sourceCount, id: \.self) { n in
                Button {
                    switcher.setListening(n)
                } label: {
                    if switcher.listeningAngle == n {
                        Label(String(localized: "メイン+\(Self.label(n))"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "メイン+\(Self.label(n))"))
                    }
                }
            }
        } label: {
            Image(systemName: switcher.listeningAngle == nil ? "speaker.wave.2" : "speaker.wave.3.fill")
                .foregroundStyle(switcher.listeningAngle == nil ? Color.accentColor : Color.orange)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("鳴らす音")
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

    /// 1 段に並べる。3 つまでは幅いっぱいに分け、4 つ以上は横にスクロールする
    @ViewBuilder
    private var sourceGrid: some View {
        let active = activeAngle
        if sourceCount <= 3 {
            HStack(spacing: 8) {
                ForEach(0..<sourceCount, id: \.self) { n in
                    tileButton(n, isActive: n == active)
                }
            }
            .padding(.horizontal, 16)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<sourceCount, id: \.self) { n in
                        tileButton(n, isActive: n == active)
                            .frame(width: tileHeight * 1.45)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func tileButton(_ n: Int, isActive: Bool) -> some View {
        Button {
            onCut(n)
        } label: {
            tile(n, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.label(n))
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
        .frame(height: tileHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.color(n))
                    .frame(width: 8, height: 8)
                Text(Self.label(n))
                    .font(.caption2.bold())
                if n > 0 && switcher.listeningAngle == n {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                }
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
        return hasFootage(n) ? nil : String(localized: "この位置は映像なし")
    }

    /// いまの位置にこの素材(0 = メイン)の映像があるか。書き出しはアングルの素材の長さの外をメインで埋める
    private func hasFootage(_ n: Int) -> Bool {
        guard n > 0 else { return true }
        guard n <= multicam.angles.count, !unreadableAngles.contains(n) else { return false }
        let angle = multicam.angles[n - 1]
        let local = angle.angleTime(atMain: switcher.sourceTime)
        return local >= 0 && local < angle.duration
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
