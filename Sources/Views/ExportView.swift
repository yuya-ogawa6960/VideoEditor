import SwiftUI
import Observation
import UIKit
import AVFoundation

// MARK: - 画質のプリセット

/// 書き出し画面で選ぶ画質。比率は編集画面と新規作成で決めるので、ここでは変えない
fileprivate enum ExportViewPreset: String, CaseIterable, Identifiable {
    case sns, uhd4k, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sns: return String(localized: "SNS")
        case .uhd4k: return String(localized: "4K")
        case .light: return String(localized: "軽量")
        }
    }

    var systemImage: String {
        switch self {
        case .sns: return "paperplane.fill"
        case .uhd4k: return "sparkles.tv"
        case .light: return "leaf.fill"
        }
    }

    var resolution: ResolutionCap {
        switch self {
        case .uhd4k: return .uhd4k
        case .sns, .light: return .fhd1080
        }
    }

    var quality: ExportQuality {
        switch self {
        case .sns, .uhd4k: return .high
        case .light: return .small
        }
    }

    var frameRate: Int { 30 }

    /// 画質だけを変える(比率・収め方・コーデックなどはそのまま。ビットレートは自動に戻す)
    func apply(to canvas: CanvasSettings) -> CanvasSettings {
        var c = canvas
        c.resolution = resolution
        c.quality = quality
        c.frameRate = frameRate
        c.bitrateMbps = nil
        return c
    }

    func matches(_ canvas: CanvasSettings) -> Bool {
        canvas.resolution == resolution && canvas.quality == quality
            && canvas.frameRate == frameRate && canvas.bitrateMbps == nil
    }
}

/// 表の行の色(編集画面の暗いパネルとそろえる)
fileprivate let exportFormBackground = Color(white: 0.07)
fileprivate let exportRowBackground = Color(white: 0.11)

/// 秒 → "h:mm:ss" / "m:ss"
fileprivate func exportDurationString(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

/// GIF 書き出しの範囲の決め方
fileprivate enum ExportGIFRange: String, CaseIterable, Identifiable {
    case whole, marker, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whole: return String(localized: "全体")
        case .marker: return String(localized: "マーカーの区間")
        case .custom: return String(localized: "開始〜終了")
        }
    }
}

// MARK: - 書き出し画面

struct ExportView: View {
    @Bindable var project: EditorProject
    /// 編集画面のプレーヤー(「比較を開く」で使う。省略時は比較画面用に内部で用意する)
    var player: PlayerController? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var estimate: StorageEstimate?
    /// 書き出し中に作っている映像(コンポジタが流すコマ)
    @State private var peek = AnalysisPeek.shared
    @State private var saveToPhotos: Bool = true
    @State private var isSavingToPhotos: Bool = false
    /// 「TikTok に投稿」で写真への保存・TikTok を開いている途中
    @State private var isPostingToTikTok: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String?
    @State private var alertOffersSettings: Bool = false
    /// 「詳細設定」を開いているか
    @State private var showAdvanced: Bool = false

    // 比較
    @State private var compareTarget: ExportRecord?
    @State private var comparePlayer: PlayerController?
    /// 履歴から消そうとしている書き出し(ファイルも消えるので、確認してから消す)
    @State private var historyToDelete: [ExportRecord] = []

    // GIF
    @State private var showGIFPanel: Bool = false
    @State private var gifRangeMode: ExportGIFRange = .whole
    @State private var gifMarkerID: UUID?
    @State private var gifStartText: String = "0"
    @State private var gifEndText: String = ""
    @State private var gifFPS: Int = 12
    @State private var gifMaxWidth: Int = 480
    @State private var gifProgress: Double = 0
    @State private var gifTask: Task<Void, Never>?
    @State private var gifURL: URL?
    // SNS パック(まとめて書き出し)
    @State private var packLandscape = true
    @State private var packPortrait = true
    @State private var packCover = true
    @State private var packSRT = true
    @State private var packChapters = true
    @State private var packFiles: [URL] = []
    @State private var packMessage: String?
    @State private var gifError: String?

    private var exporter: ExportManager { ExportManager.shared }

    /// 選べるフレームレート(23.976 / 29.97 はそれぞれ 24 / 30 に丸める)
    private let frameRates: [Int] = [24, 25, 30, 50, 60]
    /// 選べる音声ビットレート(kbps)
    private let audioBitrates: [Int] = [128, 192, 256, 320]

    var body: some View {
        ZStack {
            mainContent
            if exporter.isRunning {
                // 書き出し中は、AI 処理と同じカード(作っている映像 + ロボット + 進み具合)を上に重ねる
                exportingOverlay
            }
        }
    }

    private var exportingOverlay: some View {
        let progress = min(max(exporter.progress, 0), 1)
        let remaining = ExportTimeEstimator.shared.remainingText(isRunning: exporter.isRunning, progress: progress)
        // 残り時間と状態は行を分ける(幅まかせの改行で途中から次の行に落ちないように)
        let detail = [remaining, exporter.statusText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            WorkingCardWithAd { inlineAd in
                AIWorkingCard(title: String(localized: "書き出しています"),
                              fraction: progress,
                              detail: detail.isEmpty ? nil : detail,
                              note: BackgroundWorkNote.export,
                              noteIcon: BackgroundWorkNote.canContinueInBackground ? "lock.open" : "exclamationmark.triangle",
                              inlineAd: inlineAd,
                              showsScanning: false,
                              onCancel: { exporter.cancel() })
            }
        }
    }

    private var mainContent: some View {
        NavigationStack {
            Form {
                resultSection
                summarySection
                presetSection
                advancedToggleSection
                if showAdvanced {
                    savedPresetSection
                    customSection
                    advancedSection
                    infoSection
                }
                moreSection
                historySection
            }
            .scrollContentBackground(.hidden)
            .background(exportFormBackground)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    bottomBar
                    // 書き出しボタンの下にバナー広告(届く前から同じ高さで場所を取るので、ボタンは動かない。届かなければ閉じる。BannerAdView.swift)
                    BannerAdSlot()
                }
                // 広告の横・下(ホームバーの所)に、後ろの表がすけて見えないように塗る
                .background(Color.black.ignoresSafeArea(edges: .bottom))
            }
            .navigationTitle("書き出し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $compareTarget) { record in
                CompareView(project: project,
                            player: player ?? comparePlayer ?? PlayerController(),
                            initialRecordID: record.id,
                            onReturnToEditor: {
                                // 「この位置で編集画面に戻る」は比較と書き出しの両方を閉じる
                                compareTarget = nil
                                dismiss()
                            })
            }
            .onAppear {
                applyRecommendedPresetIfNeeded()
                recomputeEstimate()
            }
            .onDisappear {
                gifTask?.cancel()
            }
            .onChange(of: project.snapshot()) {
                recomputeEstimate()
            }
            .onChange(of: exporter.state) { oldValue, newValue in
                recomputeEstimate()
                // 書き出しが終わったら全画面広告(前の広告から間があいているときだけ)。
                // この画面が見えているときだけ出す(閉じて編集に戻ったあとは出さない。比較画面を開いている間も出さない)
                if newValue == .finished, oldValue != .finished, compareTarget == nil {
                    AdsManager.shared.showInterstitial(.exportFinished)
                }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                if alertOffersSettings {
                    Button("設定を開く") {
                        openSystemSettings()
                    }
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
            .confirmationDialog("書き出した動画を削除しますか?",
                                isPresented: Binding(
                                    get: { !historyToDelete.isEmpty },
                                    set: { if !$0 { historyToDelete = [] } }
                                ),
                                titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    for record in historyToDelete {
                        exporter.deleteRecord(record)
                    }
                    historyToDelete = []
                }
                Button("キャンセル", role: .cancel) {
                    historyToDelete = []
                }
            } message: {
                Text("書き出したファイルも消えます。写真アプリに保存したものは残ります。")
            }
        }
    }

    // MARK: 画質

    /// 開いたとき、画質(解像度・画質・fps・ビットレート)が作ったときの初期値のままなら、
    /// SNS 向けの画質にそろえる(比率には触らない)。詳細設定で解像度や画質を選んだプロジェクトは変えない
    private func applyRecommendedPresetIfNeeded() {
        guard !exporter.isRunning else { return }
        let canvas = project.canvas
        let defaults = CanvasSettings()
        guard canvas.resolution == defaults.resolution, canvas.quality == defaults.quality,
              canvas.frameRate == defaults.frameRate, canvas.bitrateMbps == nil else { return }
        guard !ExportViewPreset.allCases.contains(where: { $0.matches(canvas) }) else { return }
        project.canvas = ExportViewPreset.sns.apply(to: canvas)
    }

    private var presetSection: some View {
        Section {
            HStack(spacing: 10) {
                ForEach(ExportViewPreset.allCases) { preset in
                    presetTile(preset)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } footer: {
            if !ExportViewPreset.allCases.contains(where: { $0.matches(project.canvas) }) {
                Text("詳細設定の値で書き出します")
            }
        }
    }

    private func presetTile(_ preset: ExportViewPreset) -> some View {
        let selected = preset.matches(project.canvas)
        return Button {
            EditorHaptics.tap()
            project.canvas = preset.apply(to: project.canvas)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: preset.systemImage)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                Text(preset.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(selected ? BrandStyle.surfaceStrong : BrandStyle.surface,
                        in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card))
            .brandSelected(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exporter.isRunning)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 作品の見本・長さ・大きさ

    private var outputSize: CGSize {
        CompositionBuilder.renderSize(for: project.snapshot(), purpose: .export)
    }

    /// 出力の幅 / 高さ
    private var outputAspect: CGFloat {
        let size = outputSize
        guard size.width > 0, size.height > 0 else { return 9.0 / 16.0 }
        return size.width / size.height
    }

    private var summaryLine: String {
        var text = exportDurationString(timelineDuration)
        if let estimate {
            text += String(localized: "・約 ") + StorageEstimator.formatBytes(estimate.estimatedOutputBytes)
        }
        return text
    }

    private var summarySection: some View {
        Section {
            // 書き終わったあとは、上の完成した動画を見せるので出さない
            if exporter.isRunning || exporter.state != .finished {
                VStack(spacing: 10) {
                    ExportPosterView(project: project, aspect: outputAspect)
                    Text(summaryLine)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Toggle("写真に保存", isOn: $saveToPhotos)
                .disabled(exporter.isRunning)
        }
        .listRowBackground(exportRowBackground)
    }

    private func shortfallText(_ estimate: StorageEstimate) -> String {
        String(localized: "空き容量が足りません。あと ") + StorageEstimator.formatBytes(estimate.shortfallBytes)
            + String(localized: " 空けるか「軽量」を選んでください")
    }

    // MARK: 詳細設定

    private var advancedToggleSection: some View {
        Section {
            Button {
                withAnimation {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Label("詳細設定", systemImage: "slider.horizontal.3")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(exportRowBackground)
    }

    private var savedPresetSection: some View {
        Section {
            ExportPresetBar(project: project, isDisabled: exporter.isRunning)
        } header: {
            Text("保存した設定")
        }
        .listRowBackground(exportRowBackground)
    }

    /// 比率と収め方は編集画面で決めるので、ここでは解像度と画質だけ
    private var customSection: some View {
        Section {
            Picker("解像度", selection: $project.canvas.resolution) {
                ForEach(ResolutionCap.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            Picker("画質", selection: $project.canvas.quality) {
                ForEach(ExportQuality.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }
        } header: {
            Text("画質")
        }
        .listRowBackground(exportRowBackground)
        .disabled(exporter.isRunning)
    }

    /// 画質・解像度・コーデックから自動で決まる映像ビットレート(Mbps)。
    /// 書き出しエンジン(StorageEstimator.videoBitrate)と同じ計算を、手動指定なしの状態で行う
    private var autoBitrateMbps: Int {
        var snapshot = project.snapshot()
        snapshot.canvas.bitrateMbps = nil
        let bps = Double(StorageEstimator.videoBitrate(for: snapshot))
        let mbps = (bps / 1_000_000).rounded()
        return Int(min(max(mbps, 2), 100))
    }

    /// 手動ビットレートのオン / オフ(nil = 自動)
    private var manualBitrateBinding: Binding<Bool> {
        Binding<Bool>(
            get: { project.canvas.bitrateMbps != nil },
            set: { manual in
                if manual {
                    if project.canvas.bitrateMbps == nil {
                        project.canvas.bitrateMbps = Double(autoBitrateMbps)
                    }
                } else {
                    project.canvas.bitrateMbps = nil
                }
            }
        )
    }

    private var bitrateSliderBinding: Binding<Double> {
        Binding<Double>(
            get: { min(max(project.canvas.bitrateMbps ?? Double(autoBitrateMbps), 2), 100) },
            set: { newValue in
                project.canvas.bitrateMbps = min(max(newValue.rounded(), 2), 100)
            }
        )
    }

    /// HDR を維持できるコーデックか(H.264 は 8bit のみ)。「HDR を残す」は今は隠している(下の advancedSection を参照)
    private var hdrAvailable: Bool {
        project.canvas.codec != .h264
    }

    private var advancedSection: some View {
        Section {
            Picker("コーデック", selection: $project.canvas.codec) {
                ForEach(ExportCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }

            Toggle("ビットレートを指定", isOn: manualBitrateBinding)

            if let mbps = project.canvas.bitrateMbps {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("ビットレート")
                        Spacer()
                        Text("\(Int(mbps.rounded())) Mbps")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: bitrateSliderBinding, in: 2...100, step: 1)
                    HStack {
                        Text("小さい")
                        Spacer()
                        Text("きれい")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("ビットレート", value: String(localized: "自動・約 \(autoBitrateMbps) Mbps"))
            }

            Picker("音質", selection: $project.canvas.audioBitrateKbps) {
                ForEach(audioBitrates, id: \.self) { kbps in
                    Text(audioQualityLabel(kbps)).tag(kbps)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("形式")
                Picker("形式", selection: $project.canvas.fileFormat) {
                    ForEach(ExportFileFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                Text("迷ったら MP4")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("フレームレート")
                Picker("フレームレート", selection: $project.canvas.frameRate) {
                    ForEach(frameRates, id: \.self) { fps in
                        Text("\(fps)").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                Text("ふつうは 30。動きが速いなら 60")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 「HDR(明るさの幅が広い映像)を残す」のトグルとその説明は隠している。
            // 合成(VideoCompositor)が 8bit SDR のため、HDR の印だけ付いた SDR の映像になってしまう。
            // 本当の HDR 合成ができるまで、ExportManager でも preserveHDR を常にオフにして書き出す

            Toggle("キャプションを映像に入れる", isOn: $project.canvas.burnInSubtitles)
        } header: {
            Text("ファイルの細かい設定")
        }
        .listRowBackground(exportRowBackground)
        .disabled(exporter.isRunning)
        .onChange(of: project.canvas.codec) { _, codec in
            if codec == .h264, project.canvas.preserveHDR {
                project.canvas.preserveHDR = false
            }
        }
    }

    private func audioQualityLabel(_ kbps: Int) -> String {
        let word: String
        switch kbps {
        case ..<160: word = String(localized: "ふつう")
        case ..<224: word = String(localized: "標準")
        case ..<288: word = String(localized: "高音質")
        default: word = String(localized: "最高音質")
        }
        return word + " \(kbps) kbps"
    }

    // MARK: 情報

    private var infoSection: some View {
        let snapshot = project.snapshot()
        let size = CompositionBuilder.renderSize(for: snapshot, purpose: .export)
        return Section {
            LabeledContent("出力サイズ", value: "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
            LabeledContent("長さ", value: exportDurationString(timelineDuration))
            LabeledContent("クリップ数", value: "\(snapshot.clips.count)")
            if let estimate {
                LabeledContent("ファイルの大きさ", value: StorageEstimator.formatBytes(estimate.estimatedOutputBytes))
                LabeledContent("作業に必要な空き", value: StorageEstimator.formatBytes(estimate.requiredBytes))
                LabeledContent("いまの空き容量", value: StorageEstimator.formatBytes(estimate.availableBytes))
            }
        } header: {
            Text("くわしい情報")
        }
        .listRowBackground(exportRowBackground)
    }

    // MARK: その他の書き出し・履歴

    private var moreSection: some View {
        Section {
            NavigationLink {
                extrasPage
            } label: {
                Label("その他の書き出し", systemImage: "ellipsis.circle")
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
        .listRowBackground(exportRowBackground)
    }

    private var extrasPage: some View {
        Form {
            if exporter.isRunning {
                Section {
                    runningLine
                }
                .listRowBackground(exportRowBackground)
            }
            packSection
            extrasSection
        }
        .scrollContentBackground(.hidden)
        .background(exportFormBackground)
        .navigationTitle("その他の書き出し")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 下の書き出しボタン(常に表示)

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if exporter.isRunning {
                runningLine
            } else if isFinishedWithOutput, let url = exporter.lastOutputURL {
                // 書き出しが終わったら、下のボタンは「共有」1 つにする(同じ形のボタンが上下に 2 つ並ばないように)
                ShareLink(item: url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(BrandProminentButtonStyle())
                if lastOutputIsVideo, TikTokShare.isAvailable {
                    // TikTok に直接送る(写真に保存した動画を渡す。まだなら先に保存する)
                    Button {
                        postToTikTok()
                    } label: {
                        if isPostingToTikTok {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("TikTok を開いています…")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Label("TikTok に投稿", systemImage: "music.note")
                                .font(.headline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPostingToTikTok || isSavingToPhotos)
                }
                Button("もう一度書き出す") {
                    startExport()
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(!canStart)
            } else {
                Button {
                    startExport()
                } label: {
                    Text("書き出す")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(BrandProminentButtonStyle())
                .disabled(!canStart)

                if let reason = disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: 書き出し

    /// 出力タイムラインの長さ(トランジションの重なりを反映)
    private var timelineDuration: Double {
        let total = CompositionBuilder.totalDuration(for: project.snapshot())
        return total.isFinite ? max(0, total) : 0
    }

    private var disabledReason: String? {
        if project.isEmpty { return String(localized: "動画を追加すると書き出せます") }
        if exporter.isRunning { return nil }
        if let estimate, !estimate.canExport { return shortfallText(estimate) }
        return nil
    }

    private var canStart: Bool {
        guard !project.isEmpty, !exporter.isRunning else { return false }
        guard let estimate else { return false }
        return estimate.canExport
    }

    /// 書き出しが終わって、共有できるファイルがある
    private var isFinishedWithOutput: Bool {
        if case .finished = exporter.state { return exporter.lastOutputURL != nil }
        return false
    }

    /// 直前の出力が動画か(音声のみ書き出しのときは「写真に保存」を出さない)
    private var lastOutputIsVideo: Bool {
        guard let url = exporter.lastOutputURL else { return false }
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// 書き出し中の 1 行(カードの下に隠れる場所用)
    private var runningLine: some View {
        let progress = min(max(exporter.progress, 0), 1)
        return HStack(spacing: 10) {
            ProgressView(value: progress)
            Text(verbatim: "\(Int((progress * 100).rounded()))%")
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 4)
    }

    /// 書き出しの結果(完了・失敗・中止)。いちばん上に出す
    @ViewBuilder
    private var resultSection: some View {
        if !exporter.isRunning {
            switch exporter.state {
            case .finished, .failed, .cancelled:
                Section {
                    resultView
                }
                .listRowBackground(exportRowBackground)
            default:
                EmptyView()
            }
        }
    }

    private var finishedText: String {
        if exporter.savedToPhotos { return String(localized: "保存しました") }
        return lastOutputIsVideo ? String(localized: "できました") : String(localized: "音声ができました")
    }

    @ViewBuilder
    private var resultView: some View {
        switch exporter.state {
        case .finished:
            VStack(spacing: 14) {
                // 完成した動画を大きく見せる(音声だけのときはロボットのバンザイ)
                if let url = exporter.lastOutputURL, lastOutputIsVideo {
                    FinishedVideoPreview(url: url)
                } else {
                    RobotWorkshop(clip: .exportComplete)
                }
                HStack(spacing: 6) {
                    if lastOutputIsVideo {
                        RobotWorkshop(clip: .exportCompleteSmall)
                            .frame(width: 52)
                    }
                    Label(finishedText, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.green)
                }
                if !exporter.savedToPhotos && lastOutputIsVideo {
                    photoSaveFallback
                }
                // 共有ボタンは画面の下(bottomBar)。感想と広告はここ。広告は届いてから場所を取る(届かなければ何も出さない)
                ExportFeedbackCard()
                    .frame(maxWidth: .infinity, alignment: .leading)
                NativeAdCard(reservesSpace: false)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("書き出せませんでした", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                Text(failureAction(for: message))
                    .font(.subheadline)
                Text("詳細: " + message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .cancelled:
            Text("止めました")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// 「写真に保存」がオフだった・保存できなかったときの、保存し直すボタン
    private var photoSaveFallback: some View {
        VStack(spacing: 4) {
            if let photoError = exporter.photoSaveError {
                // 「写真に保存」がオンだったのに保存できなかった(許可していない・空き容量など)
                Label("写真に保存できませんでした", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.orange)
                Text(photoError)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                if exporter.photoSaveNeedsPermission {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("設定を開く", systemImage: "gear")
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                }
            }
            Button {
                saveToPhotosLibrary()
            } label: {
                if isSavingToPhotos {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("保存中…")
                    }
                } else {
                    Label(exporter.photoSaveError == nil ? String(localized: "写真に保存") : String(localized: "もう一度写真に保存"),
                          systemImage: "photo.on.rectangle")
                }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(isSavingToPhotos || exporter.lastOutputURL == nil)
        }
    }

    /// 失敗理由から「次にすること」を先に伝える
    private func failureAction(for message: String) -> String {
        if message.contains("空き容量") {
            return String(localized: "不要な写真・動画・アプリを削除して空きを増やすか、画質を下げてから、もう一度「書き出す」を押してください。")
        }
        if message.contains("写真") {
            return String(localized: "設定アプリでこのアプリの「写真」を許可してから、もう一度お試しください。")
        }
        if message.contains("クリップがありません") {
            return String(localized: "編集画面で動画を追加してから書き出してください。")
        }
        return String(localized: "もう一度「書き出す」を押してください。続くときは、解像度や画質を下げるか、アプリを開き直してからお試しください。")
    }

    // MARK: 処理

    private func recomputeEstimate() {
        estimate = StorageEstimator.estimate(for: project.snapshot())
    }

    private func startExport() {
        recomputeEstimate()
        guard canStart else { return }
        let snapshot = project.snapshot()
        let wantsPhotos = saveToPhotos
        exporter.start(snapshot: snapshot, saveToPhotos: wantsPhotos)
        // 書き出しは広告の間も続く。初回は通知・写真の許可の確認(ExportManager が開始時に聞く)が出ることがあるので、
        // 出るかもしれないときは全画面広告を出さない(システムの確認の上に重ねない)
        Task { @MainActor in
            let mayPrompt = await ExportManager.permissionPromptMayAppear(saveToPhotos: wantsPhotos)
            guard !mayPrompt, exporter.isRunning else { return }
            AdsManager.shared.showInterstitial(.exportStart)
        }
    }

    private func saveToPhotosLibrary() {
        guard !isSavingToPhotos else { return }
        isSavingToPhotos = true
        Task { @MainActor in
            do {
                try await exporter.saveLastOutputToPhotos()
                isSavingToPhotos = false
                showAlert(title: String(localized: "保存しました"), message: String(localized: "動画を写真アプリに保存しました。"))
            } catch {
                isSavingToPhotos = false
                if (error as? ExportManagerError) == .photosAccessDenied {
                    showAlert(title: String(localized: "写真に保存できませんでした"),
                              message: String(localized: "「設定を開く」→「写真」で写真の追加を許可してから、もう一度「写真に保存」を押してください。\n\n詳細: ") + error.localizedDescription,
                              offersSettings: true)
                } else {
                    // 許可の問題ではない(空き容量・写真ライブラリ側の失敗など)ので「設定を開く」は出さない
                    showAlert(title: String(localized: "写真に保存できませんでした"),
                              message: String(localized: "もう一度「写真に保存」を押してください。\n\n詳細: ") + error.localizedDescription)
                }
            }
        }
    }

    /// 書き出した動画を TikTok に送る。Share Kit は写真ライブラリの動画しか受け取らないので、まだなら先に写真に保存する
    private func postToTikTok() {
        guard !isPostingToTikTok, let url = exporter.lastOutputURL else { return }
        isPostingToTikTok = true
        Task { @MainActor in
            var assetID = exporter.photoAssetIdentifier(for: url)
            if assetID == nil {
                do {
                    try await exporter.saveLastOutputToPhotos()
                } catch {
                    isPostingToTikTok = false
                    showAlert(title: String(localized: "TikTok に送れませんでした"),
                              message: String(localized: "TikTok に送るには、先に写真アプリへの保存が必要です。\n\n詳細: ") + error.localizedDescription,
                              offersSettings: (error as? ExportManagerError) == .photosAccessDenied)
                    return
                }
                assetID = exporter.photoAssetIdentifier(for: url)
            }
            guard let assetID else {
                isPostingToTikTok = false
                showAlert(title: String(localized: "TikTok に送れませんでした"),
                          message: String(localized: "写真アプリに保存した動画が見つかりませんでした。「写真に保存」を押してから、もう一度お試しください。"))
                return
            }
            Analytics.shared.track("tiktok_share_start")
            TikTokShare.share(localIdentifiers: [assetID]) { outcome in
                isPostingToTikTok = false
                switch outcome {
                case .success:
                    Analytics.shared.track("tiktok_share_done")
                case .cancelled, .notInstalled:
                    // やめたとき・TikTok が無いとき(SDK が App Store の案内を出す)は何も言わない
                    break
                case .failed(let message):
                    showAlert(title: String(localized: "TikTok に送れませんでした"), message: message)
                }
            }
            // TikTok に切り替わったら、結果を待たずにボタンを戻す(戻り先が開けないときも押し直せるように)
            try? await Task.sleep(for: .seconds(2))
            isPostingToTikTok = false
        }
    }

    private func showAlert(title: String, message: String, offersSettings: Bool = false) {
        alertTitle = title
        alertOffersSettings = offersSettings
        alertMessage = message
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: その他の書き出し(縦横同時・音声のみ・GIF・チャプター)

    private var hasChapters: Bool {
        project.markers.contains { $0.kind == .chapter }
    }

    /// GIF の範囲に使えるマーカー(ビートは除く)
    private var gifMarkers: [TimelineMarker] {
        project.markers.filter { $0.kind != .beat }.sorted { $0.time < $1.time }
    }

    private var gifRange: (start: Double, end: Double)? {
        let total = timelineDuration
        guard total > 0 else { return nil }
        switch gifRangeMode {
        case .whole:
            return (0, total)
        case .marker:
            let markers = gifMarkers
            guard let id = gifMarkerID ?? markers.first?.id,
                  let i = markers.firstIndex(where: { $0.id == id }) else { return nil }
            let start = min(max(0, markers[i].time), total)
            let end = (i + 1 < markers.count) ? min(max(0, markers[i + 1].time), total) : total
            return end - start > 0.1 ? (start, end) : nil
        case .custom:
            guard let s = Double(gifStartText.trimmingCharacters(in: .whitespaces)),
                  let e = Double(gifEndText.trimmingCharacters(in: .whitespaces)) else { return nil }
            let start = min(max(0, s), total)
            let end = min(max(0, e), total)
            return end - start > 0.1 ? (start, end) : nil
        }
    }

    private var gifRangeText: String {
        guard let range = gifRange else { return String(localized: "開始と終了を 0.1 秒以上あけて入力してください") }
        let length = range.end - range.start
        var text = "\(exportDurationString(range.start)) 〜 \(exportDurationString(range.end))(\(String(format: "%.1f", length)) 秒)"
        if length > 15 {
            text += String(localized: " ・ 長いとファイルが大きくなります")
        }
        return text
    }

    /// キャプションファイル・チャプター一覧は、中身があるときだけ数える
    private var packHasSelection: Bool {
        packLandscape || packPortrait || packCover
            || (packSRT && !project.subtitles.isEmpty) || (packChapters && hasChapters)
    }

    /// 1 回で、縦動画・横動画・サムネ・キャプションファイル・チャプター一覧をまとめて作る(縦横を同時に作るのもここ)
    private var packSection: some View {
        Section {
            Toggle("縦 9:16", isOn: $packPortrait)
            Toggle("横 16:9", isOn: $packLandscape)
            Toggle("サムネ", isOn: $packCover)
            if !project.subtitles.isEmpty {
                Toggle("キャプションファイル", isOn: $packSRT)
            }
            if hasChapters {
                Toggle("チャプター一覧", isOn: $packChapters)
            }
            Button {
                makePack()
            } label: {
                Label("SNS パックを作る", systemImage: "shippingbox")
            }
            .disabled(project.isEmpty || exporter.isRunning || !packHasSelection)
            if let packMessage {
                Text(packMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !packFiles.isEmpty {
                ShareLink(items: packFiles) {
                    Label("ファイルを送る", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("SNS パック")
        }
        .listRowBackground(exportRowBackground)
    }

    private func makePack() {
        let snapshot = project.snapshot()
        let wantCover = packCover
        let wantSRT = packSRT && !snapshot.subtitles.isEmpty
        let wantChapters = packChapters && hasChapters
        let landscape = packLandscape
        let portrait = packPortrait
        let save = saveToPhotos
        // サムネは選んだ向きごとに作る。動画を選んでいなければ、いまの作品の向きで 1 枚
        var coverSizes: [(name: String, size: CGSize)] = []
        if portrait { coverSizes.append((name: "thumbnail_vertical.jpg", size: CGSize(width: 1080, height: 1920))) }
        if landscape { coverSizes.append((name: "thumbnail.jpg", size: CGSize(width: 1280, height: 720))) }
        if coverSizes.isEmpty {
            let size = outputAspect < 1 ? CGSize(width: 1080, height: 1920) : CGSize(width: 1280, height: 720)
            coverSizes.append((name: "thumbnail.jpg", size: size))
        }
        let covers = coverSizes
        // 縦と横の両方を作るときは 2 本分の空きが要る
        recomputeEstimate()
        let videoCount: Int64 = (landscape ? 1 : 0) + (portrait ? 1 : 0)
        if videoCount > 0, let estimate, estimate.availableBytes < estimate.requiredBytes * videoCount {
            let need = max(0, estimate.requiredBytes * videoCount - estimate.availableBytes)
            packMessage = String(localized: "空き容量が足りません。あと ") + StorageEstimator.formatBytes(need) + String(localized: " 空けてください")
            return
        }
        packFiles = []
        packMessage = String(localized: "作成中…")
        Task { @MainActor in
            var files: [URL] = []
            do {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let dir = try ExportManager.exportsDirectory()
                    .appendingPathComponent("Pack_\(formatter.string(from: Date()))", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if wantCover {
                    for cover in covers {
                        let image = try await CoverRenderer.render(snapshot: snapshot, cover: snapshot.cover,
                                                                   size: cover.size)
                        if let data = image.jpegData(compressionQuality: 0.9) {
                            let url = dir.appendingPathComponent(cover.name)
                            try data.write(to: url, options: .atomic)
                            files.append(url)
                        }
                    }
                }
                if wantSRT {
                    let text = SRTCodec.encode(snapshot.subtitles, useTranslation: false, bilingual: false)
                    let url = dir.appendingPathComponent("subtitles.srt")
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    files.append(url)
                }
                if wantChapters {
                    let url = dir.appendingPathComponent("chapters.txt")
                    try project.chapterListText().write(to: url, atomically: true, encoding: .utf8)
                    files.append(url)
                }
            } catch {
                packMessage = String(localized: "ファイルを作れませんでした: \(error.localizedDescription)")
            }
            packFiles = files
            if landscape && portrait {
                exporter.startDual(snapshot: snapshot, saveToPhotos: save)
            } else if landscape {
                var adjusted = snapshot
                adjusted.canvas.aspect = .landscape16x9
                exporter.start(snapshot: adjusted, saveToPhotos: save)
            } else if portrait {
                var adjusted = snapshot
                adjusted.canvas.aspect = .portrait9x16
                adjusted.canvas.scaling = .fitBlur
                exporter.start(snapshot: adjusted, saveToPhotos: save)
            }
            if !files.isEmpty {
                packMessage = (landscape || portrait)
                    ? String(localized: "\(files.count) 個のファイルができました。動画は書き出し中です。")
                    : String(localized: "\(files.count) 個のファイルができました。")
            } else if landscape || portrait {
                packMessage = nil
            }
        }
    }

    private var extrasSection: some View {
        Section {
            Button {
                exporter.startAudioOnly(snapshot: project.snapshot())
            } label: {
                Label("音声だけ書き出す", systemImage: "waveform")
            }
            .disabled(project.isEmpty || exporter.isRunning)

            Button {
                withAnimation {
                    showGIFPanel.toggle()
                }
            } label: {
                HStack {
                    Label("GIFで書き出す", systemImage: "photo.stack")
                    Spacer()
                    Image(systemName: showGIFPanel ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(project.isEmpty)

            if showGIFPanel {
                gifPanel
            }

            Button {
                copyChapterList()
            } label: {
                Label("チャプター一覧をコピー", systemImage: "list.number")
            }
            .disabled(!hasChapters)

            if exporter.state == .finished, !exporter.isRunning, let url = exporter.lastOutputURL, !lastOutputIsVideo {
                ShareLink(item: url) {
                    Label("書き出した音声を送る・保存", systemImage: "square.and.arrow.up")
                }
            }
        }
        .listRowBackground(exportRowBackground)
    }

    @ViewBuilder
    private var gifPanel: some View {
        Picker("範囲", selection: $gifRangeMode) {
            ForEach(ExportGIFRange.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: gifRangeMode) {
            if gifRangeMode == .marker, gifMarkerID == nil {
                gifMarkerID = gifMarkers.first?.id
            }
            if gifRangeMode == .custom, gifEndText.isEmpty {
                gifEndText = String(format: "%.1f", min(timelineDuration, 5))
            }
        }

        switch gifRangeMode {
        case .whole:
            EmptyView()
        case .marker:
            if gifMarkers.isEmpty {
                Text("マーカーがありません。編集画面の「マーカー」で区間の始まりにマーカーを付けてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("始まりのマーカー", selection: $gifMarkerID) {
                    ForEach(gifMarkers) { marker in
                        Text("\(exportDurationString(marker.time)) \(marker.name.isEmpty ? marker.kind.displayName : marker.name)")
                            .tag(marker.id as UUID?)
                    }
                }
            }
        case .custom:
            HStack {
                Text("開始(秒)")
                Spacer()
                TextField("0", text: $gifStartText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            HStack {
                Text("終了(秒)")
                Spacer()
                TextField(String(format: "%.1f", timelineDuration), text: $gifEndText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
        }

        Text(gifRangeText)
            .font(.caption)
            .foregroundStyle(gifRange == nil ? Color.red : Color.secondary)

        Picker("フレームレート", selection: $gifFPS) {
            ForEach([8, 10, 12, 15], id: \.self) { fps in
                Text("\(fps) コマ/秒").tag(fps)
            }
        }
        Picker("横幅", selection: $gifMaxWidth) {
            ForEach([320, 480, 640], id: \.self) { width in
                Text("\(width) px").tag(width)
            }
        }

        if gifTask != nil {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(max(gifProgress, 0), 1))
                HStack {
                    Text("GIF を作成中… \(Int((min(max(gifProgress, 0), 1) * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("キャンセル", role: .destructive) {
                        gifTask?.cancel()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        } else {
            Button {
                startGIFExport()
            } label: {
                Label("GIFを作る", systemImage: "sparkles")
            }
            .disabled(project.isEmpty || gifRange == nil)
        }

        if let url = gifURL {
            ShareLink(item: url) {
                Label("GIFを送る・保存", systemImage: "square.and.arrow.up")
            }
        }
        if let gifError {
            Text(gifError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func startGIFExport() {
        guard gifTask == nil, let range = gifRange else { return }
        // 前に作った GIF は消す(tmp に溜まらないように。GIFExporter でも作る前にフォルダを空にする)
        if let old = gifURL {
            try? FileManager.default.removeItem(at: old)
        }
        gifURL = nil
        gifError = nil
        gifProgress = 0
        let snapshot = project.snapshot()
        let fps = gifFPS
        let width = CGFloat(gifMaxWidth)
        gifTask = Task { @MainActor in
            do {
                let url = try await GIFExporter.export(snapshot: snapshot,
                                                       start: range.start,
                                                       end: range.end,
                                                       fps: fps,
                                                       maxWidth: width,
                                                       progress: { value in
                                                           Task { @MainActor in
                                                               gifProgress = value
                                                           }
                                                       })
                if !Task.isCancelled {
                    gifURL = url
                }
            } catch is CancellationError {
                // キャンセル時は何もしない
            } catch {
                if !Task.isCancelled {
                    gifError = String(localized: "範囲を短くするか横幅を小さくして、もう一度「GIFを作る」を押してください。(詳細: ") + error.localizedDescription + ")"
                }
            }
            gifTask = nil
        }
    }

    private func copyChapterList() {
        UIPasteboard.general.string = project.chapterListText()
        showAlert(title: String(localized: "コピーしました"),
                  message: String(localized: "チャプター一覧をコピーしました。YouTube の概要欄などに貼り付けてください。"))
    }

    // MARK: 書き出し履歴

    /// 1 本目を書き出すまでは出さない。消すときは確認ダイアログで注意を出す
    @ViewBuilder
    private var historySection: some View {
        if !exporter.history.isEmpty {
            Section {
                ForEach(exporter.history) { record in
                    historyRow(record)
                }
                .onDelete { offsets in
                    // ファイルも消えるので、すぐには消さず確認してから(historyToDelete → confirmationDialog)
                    let records = exporter.history
                    historyToDelete = offsets.filter { $0 < records.count }.map { records[$0] }
                }
            } header: {
                Text("書き出した動画")
            }
            .listRowBackground(exportRowBackground)
        }
    }

    private func historyRow(_ record: ExportRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(exportDurationString(record.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(record.canvasDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                ShareLink(item: record.url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                Button {
                    openCompare(record)
                } label: {
                    Label("前回と比較", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(project.isEmpty)
                Spacer()
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func openCompare(_ record: ExportRecord) {
        if player == nil, comparePlayer == nil {
            comparePlayer = PlayerController()
        }
        compareTarget = record
    }
}

// MARK: - 書き出す前の見本(作品の形のまま、最初のコマ)

private struct ExportPosterView: View {
    let project: EditorProject
    /// 出力の幅 / 高さ
    let aspect: CGFloat

    @State private var image: UIImage?

    private var boxSize: CGSize {
        let a = max(aspect, 0.1)
        if a < 1 {
            return CGSize(width: 220 * a, height: 220)
        }
        let width = min(280, 200 * a)
        return CGSize(width: width, height: width / a)
    }

    var body: some View {
        let size = boxSize
        RoundedRectangle(cornerRadius: BrandStyle.Radius.card)
            .fill(BrandStyle.surface)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card))
            .accessibilityHidden(true)
            .task(id: project.clips.first?.id) {
                await load()
            }
    }

    private func load() async {
        guard let location = project.locate(timelineTime: 0), location.index < project.clips.count else {
            image = nil
            return
        }
        let clip = project.clips[location.index]
        image = await DocumentaryPreviewSource.frame(clip: clip, sourceTime: location.sourceTime)
    }
}

// MARK: - 完成した動画(くり返し再生。タップで音のオン / オフ)

private struct FinishedVideoPreview: View {
    let url: URL

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    /// 幅 / 高さ(読み込むまでは縦)
    @State private var aspect: CGFloat = 9.0 / 16.0
    @State private var isMuted = true

    private var boxSize: CGSize {
        let a = max(aspect, 0.1)
        if a < 1 {
            return CGSize(width: 320 * a, height: 320)
        }
        let width: CGFloat = 300
        return CGSize(width: width, height: width / a)
    }

    var body: some View {
        let size = boxSize
        ZStack(alignment: .bottomTrailing) {
            Color.black
            if let player {
                PreviewPlayerLayerView(player: player)
            }
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.5), in: Circle())
                .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card))
        .contentShape(Rectangle())
        .onTapGesture {
            isMuted.toggle()
            player?.isMuted = isMuted
        }
        .accessibilityElement()
        .accessibilityLabel(isMuted ? Text("音を出す") : Text("音を消す"))
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity)
        .task(id: url) {
            await load()
        }
        .onAppear { player?.play() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        player?.pause()
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let info = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: info.0).applying(info.1)
            let w = abs(rect.width)
            let h = abs(rect.height)
            if w > 0, h > 0 { aspect = w / h }
        }
        guard !Task.isCancelled else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = isMuted
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
        player = queue
        queue.play()
    }
}
