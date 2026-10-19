import SwiftUI
import Observation

// MARK: - プリセット

fileprivate enum ExportViewPreset: String, CaseIterable, Identifiable {
    case snsShort, youtube, longHigh, uhd4k

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snsShort: return "SNSショート"
        case .youtube: return "YouTube横"
        case .longHigh: return "長尺・高画質"
        case .uhd4k: return "4K高画質"
        }
    }

    var detail: String {
        switch self {
        case .snsShort: return "9:16・1080p・30fps・軽量"
        case .youtube: return "16:9・1080p・30fps・標準"
        case .longHigh: return "元のまま・1080p・30fps・高画質"
        case .uhd4k: return "元のまま・4K・30fps・高画質"
        }
    }

    var systemImage: String {
        switch self {
        case .snsShort: return "iphone"
        case .youtube: return "play.rectangle"
        case .longHigh: return "film"
        case .uhd4k: return "sparkles.tv"
        }
    }

    var aspect: CanvasAspect {
        switch self {
        case .snsShort: return .portrait9x16
        case .youtube: return .landscape16x9
        case .longHigh, .uhd4k: return .original
        }
    }

    var resolution: ResolutionCap {
        switch self {
        case .uhd4k: return .uhd4k
        default: return .fhd1080
        }
    }

    var quality: ExportQuality {
        switch self {
        case .snsShort: return .small
        case .youtube: return .standard
        case .longHigh, .uhd4k: return .high
        }
    }

    var frameRate: Int { 30 }

    /// 現在のキャンバス設定に適用(スケーリングはユーザーの選択を維持)
    func apply(to canvas: CanvasSettings) -> CanvasSettings {
        var c = canvas
        c.aspect = aspect
        c.resolution = resolution
        c.quality = quality
        c.frameRate = frameRate
        return c
    }

    func matches(_ canvas: CanvasSettings) -> Bool {
        canvas.aspect == aspect && canvas.resolution == resolution
            && canvas.quality == quality && canvas.frameRate == frameRate
    }
}

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

// MARK: - 書き出し画面

struct ExportView: View {
    @Bindable var project: EditorProject

    @Environment(\.dismiss) private var dismiss

    @State private var estimate: StorageEstimate?
    @State private var saveToPhotos: Bool = true
    @State private var isSavingToPhotos: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String?
    @State private var showAdvanced: Bool = false

    private var exporter: ExportManager { ExportManager.shared }

    /// 選べるフレームレート(23.976 / 29.97 はそれぞれ 24 / 30 に丸める)
    private let frameRates: [Int] = [24, 25, 30, 50, 60]
    /// 選べる音声ビットレート(kbps)
    private let audioBitrates: [Int] = [128, 192, 256, 320]

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                customSection
                advancedSection
                infoSection
                storageSection
                exportSection
            }
            .navigationTitle("書き出し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear {
                recomputeEstimate()
            }
            .onChange(of: project.snapshot()) {
                recomputeEstimate()
            }
            .onChange(of: exporter.state) {
                recomputeEstimate()
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: プリセット

    private var presetSection: some View {
        Section {
            ForEach(ExportViewPreset.allCases) { preset in
                Button {
                    project.canvas = preset.apply(to: project.canvas)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.systemImage)
                            .frame(width: 26)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .foregroundStyle(Color.primary)
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        if preset.matches(project.canvas) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(exporter.isRunning)
            }
        } header: {
            Text("プリセット")
        } footer: {
            if !ExportViewPreset.allCases.contains(where: { $0.matches(project.canvas) }) {
                Text("カスタム設定")
            }
        }
    }

    // MARK: 個別設定

    private var customSection: some View {
        Section {
            Picker("画面比率", selection: $project.canvas.aspect) {
                ForEach(CanvasAspect.allCases) { a in
                    Text(a.displayName).tag(a)
                }
            }
            Picker("はみ出し・余白", selection: $project.canvas.scaling) {
                ForEach(ScalingMode.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
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
            Text("出力設定")
        }
        .disabled(exporter.isRunning)
    }

    // MARK: 詳細設定

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

    /// HDR を維持できるコーデックか(H.264 は 8bit のみ)
    private var hdrAvailable: Bool {
        project.canvas.codec != .h264
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("詳細設定", isExpanded: $showAdvanced) {
                Picker("コーデック", selection: $project.canvas.codec) {
                    ForEach(ExportCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }

                Toggle("ビットレートを手動で指定", isOn: manualBitrateBinding)

                if let mbps = project.canvas.bitrateMbps {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("映像ビットレート")
                            Spacer()
                            Text("\(Int(mbps.rounded())) Mbps")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: bitrateSliderBinding, in: 2...100, step: 1)
                        HStack {
                            Text("2")
                            Spacer()
                            Text("100 Mbps")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("映像ビットレート", value: "自動(約 \(autoBitrateMbps) Mbps)")
                }

                Picker("音声ビットレート", selection: $project.canvas.audioBitrateKbps) {
                    ForEach(audioBitrates, id: \.self) { kbps in
                        Text("\(kbps) kbps").tag(kbps)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ファイル形式")
                    Picker("ファイル形式", selection: $project.canvas.fileFormat) {
                        ForEach(ExportFileFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("フレームレート")
                    Picker("フレームレート", selection: $project.canvas.frameRate) {
                        ForEach(frameRates, id: \.self) { fps in
                            Text("\(fps)").tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("23.976 fps / 29.97 fps の素材はそれぞれ 24 / 30 fps に丸めて書き出します。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("HDR を維持", isOn: $project.canvas.preserveHDR)
                    .disabled(!hdrAvailable)

                Toggle("字幕を映像に焼き込む", isOn: $project.canvas.burnInSubtitles)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("HDR の維持はコーデックが HEVC または自動のときだけ選べます。素材が HDR でない場合や端末が対応していない場合は SDR で書き出します。")
                Text("字幕の焼き込みをオフにすると、字幕は映像に入りません(SRT として別に書き出す用途向け)。")
            }
        }
        .disabled(exporter.isRunning)
        .onChange(of: project.canvas.codec) { _, codec in
            if codec == .h264, project.canvas.preserveHDR {
                project.canvas.preserveHDR = false
            }
        }
    }

    // MARK: 情報

    private var infoSection: some View {
        let snapshot = project.snapshot()
        let size = CompositionBuilder.renderSize(for: snapshot, purpose: .export)
        return Section {
            LabeledContent("出力サイズ", value: "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
            LabeledContent("長さ", value: exportDurationString(snapshot.totalDuration))
            LabeledContent("クリップ数", value: "\(snapshot.clips.count)")
        } header: {
            Text("出力内容")
        }
    }

    // MARK: ストレージ

    private var storageSection: some View {
        Section {
            if let estimate {
                LabeledContent("推定サイズ", value: StorageEstimator.formatBytes(estimate.estimatedOutputBytes))
                LabeledContent("必要空き容量", value: StorageEstimator.formatBytes(estimate.requiredBytes))
                LabeledContent("現在の空き容量", value: StorageEstimator.formatBytes(estimate.availableBytes))
                if estimate.canExport {
                    Label("空き容量は十分です", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("空き容量が不足しています", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Color.red)
                        Text("あと \(StorageEstimator.formatBytes(estimate.shortfallBytes)) 必要です。不要な写真・動画・アプリを削除するか、解像度や画質を下げてください。")
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("計算中…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("ストレージ")
        }
    }

    // MARK: 書き出し

    private var disabledReason: String? {
        if project.isEmpty { return "動画を追加してください。" }
        if exporter.isRunning { return nil }
        if let estimate, !estimate.canExport { return "空き容量が不足しているため書き出せません。" }
        return nil
    }

    private var canStart: Bool {
        guard !project.isEmpty, !exporter.isRunning else { return false }
        guard let estimate else { return false }
        return estimate.canExport
    }

    private var exportSection: some View {
        Section {
            Toggle("写真に保存", isOn: $saveToPhotos)
                .disabled(exporter.isRunning)

            if exporter.isRunning {
                runningView
            } else {
                Button {
                    startExport()
                } label: {
                    HStack {
                        Spacer()
                        Label("書き出しを開始", systemImage: "square.and.arrow.up.on.square")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(!canStart)

                if let reason = disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }

                resultView
            }
        } header: {
            Text("書き出し")
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: min(max(exporter.progress, 0), 1))
            HStack {
                Text(verbatim: "\(Int((min(max(exporter.progress, 0), 1) * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
                Text(exporter.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("キャンセル", role: .destructive) {
                    exporter.cancel()
                }
                .buttonStyle(.borderless)
            }
            Text("ホームに戻っても書き出しは続きます(iOS 26以降。iOS 18〜25は約30秒まで)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var resultView: some View {
        switch exporter.state {
        case .finished:
            VStack(alignment: .leading, spacing: 8) {
                Label(exporter.savedToPhotos ? "書き出しが完了し、写真に保存しました" : "書き出しが完了しました",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                if !exporter.savedToPhotos {
                    Button {
                        saveToPhotosLibrary()
                    } label: {
                        if isSavingToPhotos {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("保存中…")
                            }
                        } else {
                            Label("写真に保存", systemImage: "photo.on.rectangle")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSavingToPhotos || exporter.lastOutputURL == nil)
                }
                if let url = exporter.lastOutputURL {
                    ShareLink(item: url) {
                        Label("共有・ファイルに保存", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
        case .cancelled:
            Text("書き出しをキャンセルしました")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: 処理

    private func recomputeEstimate() {
        estimate = StorageEstimator.estimate(for: project.snapshot())
    }

    private func startExport() {
        recomputeEstimate()
        guard canStart else { return }
        exporter.start(snapshot: project.snapshot(), saveToPhotos: saveToPhotos)
    }

    private func saveToPhotosLibrary() {
        guard !isSavingToPhotos else { return }
        isSavingToPhotos = true
        Task { @MainActor in
            do {
                try await exporter.saveLastOutputToPhotos()
                isSavingToPhotos = false
                alertTitle = "保存しました"
                alertMessage = "動画を写真アプリに保存しました。"
            } catch {
                isSavingToPhotos = false
                alertTitle = "写真に保存できませんでした"
                alertMessage = error.localizedDescription
            }
        }
    }
}
