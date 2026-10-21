import SwiftUI
import AVFoundation
import UIKit

// =====================================================================
// 比較画面。
// A = 現在の編集内容(CompositionBuilder.build で作るプレビュー合成)
// B = 書き出し履歴(ExportManager.shared.history)から選んだ以前の書き出しファイル
// 2 つの AVPlayer を同期させて再生し、並べて表示またはスワイプ分割で見比べる。
// 音声は A / B / ミュートを切り替え、ラウドネスは LoudnessAnalyzer で両方を測る。
// =====================================================================

// MARK: - 表示モード・音声

enum CompareLayout: String, CaseIterable, Identifiable {
    case split, sideBySide
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .split: return String(localized: "スワイプで比較")
        case .sideBySide: return String(localized: "並べて表示")
        }
    }
}

enum CompareAudioSource: String, CaseIterable, Identifiable {
    case a, b, mute
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .a: return String(localized: "A 現在")
        case .b: return String(localized: "B 前回")
        case .mute: return String(localized: "ミュート")
        }
    }
}

private enum CompareViewError: LocalizedError {
    case cannotExportAudio

    var errorDescription: String? {
        switch self {
        case .cannotExportAudio: return String(localized: "現在の編集の音声を取り出せませんでした")
        }
    }
}

// MARK: - 2 プレイヤー同期

/// 2 つの AVPlayer(A: 現在の編集、B: 前回の書き出し)を同期して動かす。メインスレッドから使う。
@Observable
final class CompareSyncController {
    let playerA = AVPlayer()
    let playerB = AVPlayer()

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isBuilding: Bool = false
    /// 幅 / 高さ
    private(set) var renderAspect: CGFloat = 16.0 / 9.0
    private(set) var errorMessage: String?
    private(set) var exportError: String?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSyncCheck: CFAbsoluteTime = 0
    @ObservationIgnored private var buildGeneration = 0
    @ObservationIgnored private var pendingSeeks = 0
    /// A / B の項目が再生できなくなったこと(.failed / 途中で再生できなくなった)の監視
    @ObservationIgnored private var failureWatchA: PlayerItemFailureWatch?
    @ObservationIgnored private var failureWatchB: PlayerItemFailureWatch?

    init() {
        playerA.actionAtItemEnd = .pause
        playerB.actionAtItemEnd = .pause
        playerA.automaticallyWaitsToMinimizeStalling = false
        playerB.automaticallyWaitsToMinimizeStalling = false
    }

    deinit {
        if let timeObserver {
            playerA.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: 開始・終了

    func start() {
        guard timeObserver == nil else { return }
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = playerA.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.tick(time)
        }
    }

    func stop() {
        playerA.pause()
        playerB.pause()
        isPlaying = false
        if let timeObserver {
            playerA.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    // MARK: 読み込み

    /// A: 現在の編集内容をプレビュー用に合成して読み込む
    @MainActor
    func loadCurrentTimeline(snapshot: ProjectSnapshot) async {
        buildGeneration += 1
        let generation = buildGeneration
        isBuilding = true
        errorMessage = nil

        let size = CompositionBuilder.renderSize(for: snapshot, purpose: .preview)
        if size.width > 0, size.height > 0 {
            renderAspect = size.width / size.height
        }

        guard !snapshot.isEmpty else {
            failureWatchA = nil
            playerA.replaceCurrentItem(with: nil)
            duration = 0
            currentTime = 0
            isBuilding = false
            errorMessage = String(localized: "現在の編集にクリップがありません")
            return
        }

        do {
            let built = try await CompositionBuilder.build(snapshot, purpose: .preview)
            guard generation == buildGeneration else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            installA(item)
            let seconds = built.duration.seconds
            duration = (seconds.isFinite && seconds > 0) ? seconds : 0
            if built.renderSize.width > 0, built.renderSize.height > 0 {
                renderAspect = built.renderSize.width / built.renderSize.height
            }
        } catch {
            guard generation == buildGeneration else { return }
            errorMessage = String(localized: "現在の編集のプレビューを作成できませんでした: \(error.localizedDescription)")
        }
        isBuilding = false
    }

    private func installA(_ item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        // 合成のエラーやメディアサービスのリセットで再生できなくなったら、止めて知らせる
        failureWatchA = PlayerItemFailureWatch(item: item) { [weak self] failedItem, _ in
            guard let self, self.playerA.currentItem === failedItem else { return }
            self.playerA.pause()
            self.playerB.pause()
            self.isPlaying = false
            self.errorMessage = String(localized: "現在の編集を再生できませんでした。比較画面を開き直してください")
        }
        playerA.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.playerB.pause()
            self.isPlaying = false
        }
        currentTime = 0
    }

    /// B: 書き出したファイルを読み込む
    func loadExport(url: URL?) {
        exportError = nil
        failureWatchB = nil
        guard let url else {
            playerB.replaceCurrentItem(with: nil)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            playerB.replaceCurrentItem(with: nil)
            exportError = String(localized: "書き出したファイルが見つかりません(削除された可能性があります)")
            return
        }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        // ファイルが壊れている・メディアサービスのリセットなどで再生できなくなったら知らせる
        failureWatchB = PlayerItemFailureWatch(item: item) { [weak self] failedItem, _ in
            guard let self, self.playerB.currentItem === failedItem else { return }
            self.playerB.pause()
            self.exportError = String(localized: "前回の書き出しを再生できませんでした")
        }
        playerB.replaceCurrentItem(with: item)
        let t = CMTime(seconds: currentTime, preferredTimescale: 600)
        playerB.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying {
            playerB.play()
        }
    }

    // MARK: 再生

    func play() {
        guard playerA.currentItem != nil else { return }
        // マナーモードでも音が出るカテゴリで再生する(書き出し後の広告などでカテゴリが変わっていることがある)
        AudioSessionSetup.ensurePlayback()
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        isPlaying = true
        lastSyncCheck = 0
        playerA.play()
        if playerB.currentItem != nil {
            playerB.play()
        }
    }

    func pause() {
        playerA.pause()
        playerB.pause()
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double) {
        let safe = seconds.isFinite ? seconds : 0
        let target = duration > 0 ? min(max(0, safe), duration) : max(0, safe)
        currentTime = target
        let t = CMTime(seconds: target, preferredTimescale: 600)
        if playerA.currentItem != nil {
            pendingSeeks += 1
            playerA.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingSeeks = max(0, self.pendingSeeks - 1)
                }
            }
        }
        if playerB.currentItem != nil {
            playerB.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func setAudio(_ source: CompareAudioSource) {
        playerA.isMuted = (source != .a)
        playerB.isMuted = (source != .b)
    }

    // MARK: 同期

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if pendingSeeks == 0, seconds.isFinite {
            let clamped = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
            if abs(clamped - currentTime) > 0.0001 {
                currentTime = clamped
            }
        }
        let playing = playerA.currentItem != nil && playerA.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            if !playing {
                playerB.pause()
            }
        }
        guard playing, playerB.currentItem != nil, seconds.isFinite else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSyncCheck > 0.5 else { return }
        lastSyncCheck = now

        let timeB = playerB.currentTime().seconds
        if timeB.isFinite, abs(timeB - seconds) > 0.12 {
            // ずれが大きければ B を A に合わせる
            playerB.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if playerB.timeControlStatus == .paused {
                playerB.play()
            }
        } else if playerB.timeControlStatus == .paused, playerB.status == .readyToPlay {
            playerB.play()
        }
    }
}

// MARK: - 比較画面

struct CompareView: View {
    let project: EditorProject
    let player: PlayerController
    /// 最初に選んでおく書き出し履歴(nil なら最新)
    var initialRecordID: UUID? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var sync = CompareSyncController()
    @State private var selectedRecordID: UUID?
    @State private var layout: CompareLayout = .split
    @State private var splitPosition: Double = 0.5
    @State private var audioSource: CompareAudioSource = .a
    @State private var wasPlayingBeforeScrub = false

    @State private var loudnessA: LoudnessMeasurement?
    @State private var loudnessB: LoudnessMeasurement?
    @State private var isMeasuring = false
    @State private var measureError: String?
    @State private var measureTask: Task<Void, Never>?

    private var exporter: ExportManager { ExportManager.shared }

    private var currentRecord: ExportRecord? {
        guard let id = selectedRecordID else { return nil }
        return exporter.history.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                compareArea
                transportBar
                Form {
                    recordSection
                    displaySection
                    loudnessSection
                    returnSection
                }
            }
            .navigationTitle("前回と比較")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                await setup()
            }
            .onChange(of: selectedRecordID) {
                loudnessB = nil
                measureError = nil
                sync.loadExport(url: currentRecord?.url)
            }
            .onChange(of: audioSource) {
                sync.setAudio(audioSource)
            }
            .onDisappear {
                measureTask?.cancel()
                sync.stop()
            }
        }
    }

    // MARK: 準備

    private func setup() async {
        player.pause()
        if selectedRecordID == nil {
            let history = exporter.history
            if let initialRecordID, history.contains(where: { $0.id == initialRecordID }) {
                selectedRecordID = initialRecordID
            } else {
                selectedRecordID = history.first?.id
            }
        }
        sync.start()
        sync.setAudio(audioSource)
        await sync.loadCurrentTimeline(snapshot: project.snapshot())
        sync.loadExport(url: currentRecord?.url)
        // 編集画面の再生位置から始める
        let start = min(max(0, player.currentTime), max(0, sync.duration))
        if start > 0 {
            sync.seek(to: start)
        }
    }

    // MARK: 映像

    @ViewBuilder
    private var compareArea: some View {
        let aspect = sync.renderAspect
        ZStack {
            Color.black
            switch layout {
            case .split:
                splitView(aspect: aspect)
            case .sideBySide:
                if aspect >= 1 {
                    VStack(spacing: 2) {
                        labeledPlayer(sync.playerA, label: String(localized: "A 現在の編集"), aspect: aspect)
                        labeledPlayer(sync.playerB, label: String(localized: "B 前回の書き出し"), aspect: aspect)
                    }
                } else {
                    HStack(spacing: 2) {
                        labeledPlayer(sync.playerA, label: String(localized: "A 現在"), aspect: aspect)
                        labeledPlayer(sync.playerB, label: String(localized: "B 前回"), aspect: aspect)
                    }
                }
            }
            if sync.isBuilding {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
            if let message = sync.errorMessage ?? sync.exportError {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .background(Color.black)
    }

    private func labeledPlayer(_ avPlayer: AVPlayer, label: String, aspect: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            PreviewPlayerLayerView(player: avPlayer)
                .aspectRatio(aspect, contentMode: .fit)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitView(aspect: CGFloat) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = width * CGFloat(splitPosition)
            ZStack(alignment: .topLeading) {
                PreviewPlayerLayerView(player: sync.playerB)
                PreviewPlayerLayerView(player: sync.playerA)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: x)
                    }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: x - 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.black)
                    )
                    .shadow(radius: 2)
                    .position(x: x, y: geo.size.height / 2)
                HStack {
                    Text("A 現在")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: Capsule())
                    Spacer()
                    Text("B 前回")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
                .padding(6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = Double(value.location.x / width)
                        splitPosition = min(max(p, 0.02), 0.98)
                    }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    // MARK: 再生操作

    private var scrubBinding: Binding<Double> {
        Binding<Double>(
            get: { sync.currentTime },
            set: { sync.seek(to: $0) }
        )
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button {
                sync.togglePlay()
            } label: {
                Image(systemName: sync.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 32)
            }
            .disabled(sync.duration <= 0)

            Text("\(MediaTimeText.precise(sync.currentTime)) / \(MediaTimeText.precise(sync.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            Slider(value: scrubBinding, in: 0...max(sync.duration, 0.01)) { editing in
                if editing {
                    wasPlayingBeforeScrub = sync.isPlaying
                    sync.pause()
                } else if wasPlayingBeforeScrub {
                    sync.play()
                }
            }
            .disabled(sync.duration <= 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: 書き出し履歴

    private var recordSection: some View {
        Section {
            if exporter.history.isEmpty {
                Text("まだ書き出した動画がありません。先に「書き出し」をすると、その動画といまの編集を見比べられます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("見比べる動画", selection: $selectedRecordID) {
                    ForEach(exporter.history) { record in
                        Text(recordLabel(record))
                            .tag(record.id as UUID?)
                    }
                }
                if let record = currentRecord {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("前回の書き出し: \(record.date.formatted(date: .long, time: .shortened))")
                            .font(.subheadline.weight(.semibold))
                        Text("\(record.canvasDescription) ・ \(MediaTimeText.mmss(record.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(record.url.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text("B: 前回の書き出し")
        }
    }

    private func recordLabel(_ record: ExportRecord) -> String {
        "\(record.date.formatted(date: .numeric, time: .shortened)) \(record.canvasDescription)"
    }

    // MARK: 表示

    private var displaySection: some View {
        Section {
            Picker("表示", selection: $layout) {
                ForEach(CompareLayout.allCases) { l in
                    Text(l.displayName).tag(l)
                }
            }
            .pickerStyle(.segmented)

            if layout == .split {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("分割位置")
                        Spacer()
                        Text("\(Int((splitPosition * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $splitPosition, in: 0.02...0.98)
                }
            }

            Picker("音声", selection: $audioSource) {
                ForEach(CompareAudioSource.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("表示と音声")
        } footer: {
            Text("A はいまの編集(プレビュー画質)、B は選んだ書き出し済みの動画です。再生や位置の移動は両方に同時に反映されます。")
        }
    }

    // MARK: ラウドネス

    private var loudnessSection: some View {
        Section {
            loudnessRow(title: String(localized: "A 現在の編集"), measurement: loudnessA)
            loudnessRow(title: String(localized: "B 前回の書き出し"), measurement: loudnessB)
            if let a = loudnessA, let b = loudnessB, a.isValid, b.isValid {
                LabeledContent("くらべると", value: loudnessDiffText(a: a, b: b))
            }
            if isMeasuring {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("測定中…(長い動画は時間がかかります)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    measureLoudness()
                } label: {
                    Label(loudnessA == nil && loudnessB == nil ? String(localized: "音の大きさを測る") : String(localized: "もう一度測る"), systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(project.isEmpty && currentRecord == nil)
            }
            if let measureError {
                Text(measureError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("音の大きさ")
        } footer: {
            Text("YouTube などのネット動画で聞きやすい大きさかを「小さめ / ちょうどいい / 大きすぎ」で表示します。A はいまの編集の音を一時的に書き出して測ります。")
        }
    }

    private func loudnessRow(title: String, measurement: LoudnessMeasurement?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let m = measurement {
                if m.isValid {
                    Text(loudnessWord(m))
                        .font(.caption)
                        .foregroundStyle(loudnessColor(m))
                } else {
                    Text("測れませんでした(音がありません)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("まだ測っていません")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 音の大きさを 小さめ / ちょうどいい / 大きすぎ で表す(ネット動画の目安 -16〜-14 LUFS 付近を「ちょうどいい」)
    private func loudnessWord(_ m: LoudnessMeasurement) -> String {
        let lufs: Double = Double(m.integratedLUFS)
        let peak: Double = Double(m.peakDBFS)
        var word: String
        if lufs < -18 {
            word = String(localized: "小さめ")
        } else if lufs > -12 {
            word = String(localized: "大きすぎ")
        } else {
            word = String(localized: "ちょうどいい")
        }
        if peak > -1 {
            word += String(localized: "・音割れに注意")
        }
        return word
    }

    private func loudnessColor(_ m: LoudnessMeasurement) -> Color {
        let lufs: Double = Double(m.integratedLUFS)
        let peak: Double = Double(m.peakDBFS)
        if lufs > -12 || peak > -1 { return Color.red }
        if lufs < -18 { return Color.orange }
        return Color.green
    }

    private func loudnessDiffText(a: LoudnessMeasurement, b: LoudnessMeasurement) -> String {
        let diff: Double = Double(a.integratedLUFS) - Double(b.integratedLUFS)
        if abs(diff) < 1 {
            return String(localized: "ほぼ同じ")
        }
        let amount: String = abs(diff) < 3 ? String(localized: "少し") : String(localized: "かなり")
        return diff > 0 ? String(localized: "A(いま)のほうが") + amount + String(localized: "大きい") : String(localized: "B(前回)のほうが") + amount + String(localized: "大きい")
    }

    private func measureLoudness() {
        guard measureTask == nil else { return }
        isMeasuring = true
        measureError = nil
        let snapshot = project.snapshot()
        let exportURL = currentRecord?.url
        measureTask = Task { @MainActor in
            var firstError: String?
            if !snapshot.isEmpty {
                do {
                    let tempURL = try await CompareView.renderTimelineAudio(snapshot: snapshot)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    let result = try await LoudnessAnalyzer.measure(url: tempURL)
                    if !Task.isCancelled { loudnessA = result }
                } catch {
                    if !Task.isCancelled { firstError = String(localized: "A(いまの編集)を測れませんでした。もう一度「もう一度測る」を押してください。(詳細: ") + error.localizedDescription + ")" }
                }
            }
            if let exportURL, !Task.isCancelled {
                do {
                    let result = try await LoudnessAnalyzer.measure(url: exportURL)
                    if !Task.isCancelled { loudnessB = result }
                } catch {
                    if !Task.isCancelled, firstError == nil { firstError = String(localized: "B(前回の動画)を測れませんでした。別の書き出しを選んで測り直してください。(詳細: ") + error.localizedDescription + ")" }
                }
            }
            if !Task.isCancelled {
                measureError = firstError
            }
            isMeasuring = false
            measureTask = nil
        }
    }

    /// 現在の編集内容の音声だけを一時ファイル(m4a)に書き出す(ラウドネス測定用)
    private static func renderTimelineAudio(snapshot: ProjectSnapshot) async throws -> URL {
        let built = try await CompositionBuilder.build(snapshot, purpose: .preview)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CompareViewError.cannotExportAudio
        }
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compare_\(UUID().uuidString).m4a")
        try await session.export(to: url, as: .m4a)
        return url
    }

    // MARK: 編集画面へ

    private var returnSection: some View {
        Section {
            Button {
                let t = sync.currentTime
                sync.pause()
                player.seek(to: t)
                dismiss()
            } label: {
                Label("この位置で編集画面に戻る", systemImage: "arrow.uturn.backward")
            }
            .disabled(sync.duration <= 0)
        } footer: {
            Text("編集画面の再生位置を、いま比較している位置に合わせて閉じます。")
        }
    }
}
