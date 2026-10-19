import SwiftUI
import Observation
import UIKit

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

/// GIF 書き出しの範囲の決め方
fileprivate enum ExportGIFRange: String, CaseIterable, Identifiable {
    case whole, marker, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whole: return "全体"
        case .marker: return "マーカー区間"
        case .custom: return "開始〜終了"
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
    @State private var saveToPhotos: Bool = true
    @State private var isSavingToPhotos: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String?
    @State private var showAdvanced: Bool = false

    // 縦横同時 / 比較
    @State private var dualExport: Bool = false
    @State private var compareTarget: ExportRecord?
    @State private var comparePlayer: PlayerController?

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
    @State private var gifError: String?

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
                extrasSection
                historySection
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
                            initialRecordID: record.id)
            }
            .onAppear {
                recomputeEstimate()
            }
            .onDisappear {
                gifTask?.cancel()
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
            VStack(alignment: .leading, spacing: 6) {
                Text("組み込み + 保存したプリセット(長押しで名前変更・削除)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ExportPresetBar(project: project, isDisabled: exporter.isRunning)
            }

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
            LabeledContent("長さ", value: exportDurationString(timelineDuration))
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

    /// 出力タイムラインの長さ(トランジションの重なりを反映)
    private var timelineDuration: Double {
        let total = CompositionBuilder.totalDuration(for: project.snapshot())
        return total.isFinite ? max(0, total) : 0
    }

    /// 縦横同時のときは 2 本分の空き容量が必要
    private var dualStorageOK: Bool {
        guard dualExport, let estimate else { return true }
        return estimate.availableBytes >= estimate.requiredBytes * 2
    }

    private var disabledReason: String? {
        if project.isEmpty { return "動画を追加してください。" }
        if exporter.isRunning { return nil }
        if let estimate, !estimate.canExport { return "空き容量が不足しているため書き出せません。" }
        if !dualStorageOK { return "縦横同時の書き出しには 2 本分の空き容量が必要です。" }
        return nil
    }

    private var canStart: Bool {
        guard !project.isEmpty, !exporter.isRunning else { return false }
        guard let estimate else { return false }
        return estimate.canExport && dualStorageOK
    }

    /// 直前の出力が動画か(音声のみ書き出しのときは「写真に保存」を出さない)
    private var lastOutputIsVideo: Bool {
        guard let url = exporter.lastOutputURL else { return false }
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
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
                        Label(dualExport ? "縦横を同時に書き出し" : "書き出しを開始",
                              systemImage: dualExport ? "rectangle.portrait.and.arrow.right" : "square.and.arrow.up.on.square")
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
                Label(exporter.savedToPhotos ? "書き出しが完了し、写真に保存しました"
                      : (lastOutputIsVideo ? "書き出しが完了しました" : "音声の書き出しが完了しました"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                if !exporter.savedToPhotos && lastOutputIsVideo {
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
        let snapshot = project.snapshot()
        if dualExport {
            exporter.startDual(snapshot: snapshot, saveToPhotos: saveToPhotos)
        } else {
            exporter.start(snapshot: snapshot, saveToPhotos: saveToPhotos)
        }
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
        guard let range = gifRange else { return "範囲が正しくありません(0.1 秒以上の区間を指定してください)" }
        let length = range.end - range.start
        var text = "\(exportDurationString(range.start)) 〜 \(exportDurationString(range.end))(\(String(format: "%.1f", length)) 秒)"
        if length > 15 {
            text += " ・ 長いと容量が大きくなります"
        }
        return text
    }

    private var extrasSection: some View {
        Section {
            Toggle("縦横を同時に書き出し", isOn: $dualExport)
                .disabled(exporter.isRunning)

            Button {
                exporter.startAudioOnly(snapshot: project.snapshot())
            } label: {
                Label("音声のみ書き出し(m4a)", systemImage: "waveform")
            }
            .disabled(project.isEmpty || exporter.isRunning)

            Button {
                withAnimation {
                    showGIFPanel.toggle()
                }
            } label: {
                HStack {
                    Label("GIFで書き出し", systemImage: "photo.stack")
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
        } header: {
            Text("その他の書き出し")
        } footer: {
            Text("「縦横を同時に書き出し」をオンにすると、16:9(横)と 9:16(縦)を続けて書き出します(2 本分の空き容量が必要)。チャプター一覧は「マーカー」のチャプターから作り、YouTube の概要欄に貼り付けられます。")
        }
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
                Text("マーカーがありません。編集画面の「マーカー」で区間の始まりに目印を付けてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("開始マーカー", selection: $gifMarkerID) {
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
                Text("\(fps) fps").tag(fps)
            }
        }
        Picker("幅", selection: $gifMaxWidth) {
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
                Label("GIFを作成", systemImage: "sparkles")
            }
            .disabled(project.isEmpty || gifRange == nil)
        }

        if let url = gifURL {
            ShareLink(item: url) {
                Label("GIFを共有・保存", systemImage: "square.and.arrow.up")
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
                    gifError = "GIF を作成できませんでした: \(error.localizedDescription)"
                }
            }
            gifTask = nil
        }
    }

    private func copyChapterList() {
        UIPasteboard.general.string = project.chapterListText()
        alertTitle = "コピーしました"
        alertMessage = "チャプター一覧をクリップボードにコピーしました。YouTube の概要欄などに貼り付けてください。"
    }

    // MARK: 書き出し履歴

    private var historySection: some View {
        Section {
            if exporter.history.isEmpty {
                Text("まだ書き出し履歴がありません。書き出すとここに並び、共有や「比較」ができます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(exporter.history) { record in
                    historyRow(record)
                }
                .onDelete { offsets in
                    let records = exporter.history
                    for index in offsets where index < records.count {
                        exporter.deleteRecord(records[index])
                    }
                }
            }
        } header: {
            Text("書き出し履歴")
        } footer: {
            Text("最新 20 件まで残ります。左にスワイプで削除(書き出したファイルも削除されます)。")
        }
    }

    private func historyRow(_ record: ExportRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
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
                Button {
                    openCompare(record)
                } label: {
                    Label("比較を開く", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
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
