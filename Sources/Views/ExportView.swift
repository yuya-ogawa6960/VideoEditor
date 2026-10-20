import SwiftUI
import Observation
import UIKit

// MARK: - プリセット(使いみち別)

fileprivate enum ExportViewPreset: String, CaseIterable, Identifiable {
    case snsShort, youtube, longHigh, uhd4k

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snsShort: return "SNS(縦動画)"
        case .youtube: return "YouTube(横動画)"
        case .longHigh: return "きれいに残す"
        case .uhd4k: return "4K(いちばんきれい)"
        }
    }

    var detail: String {
        switch self {
        case .snsShort: return "TikTok・Instagram・ショート向け。縦長で軽め"
        case .youtube: return "横長のふつうの動画。画質と大きさのバランスが良い"
        case .longHigh: return "元の形のまま高画質。保存用や長い動画に"
        case .uhd4k: return "細かいところまでくっきり。ファイルは大きめ"
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
        case .marker: return "目印の区間"
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
    @State private var alertOffersSettings: Bool = false
    /// 「詳細設定」を開いているか
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
                resultSection
                presetSection
                summarySection
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
            .safeAreaInset(edge: .bottom) {
                bottomBar
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
                if alertOffersSettings {
                    Button("設定を開く") {
                        openSystemSettings()
                    }
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: プリセット(使いみち)

    /// 素材の向きから選ぶおすすめ(縦の素材なら SNS、横なら YouTube)
    private var recommendedPreset: ExportViewPreset {
        switch project.canvas.aspect {
        case .portrait9x16, .portrait4x5:
            return .snsShort
        case .landscape16x9:
            return .youtube
        default:
            break
        }
        if let size = project.clips.first?.displaySize, size.width > 0, size.height > 0 {
            return size.height > size.width ? .snsShort : .youtube
        }
        return .snsShort
    }

    private var presetSection: some View {
        let recommended = recommendedPreset
        return Section {
            ForEach(ExportViewPreset.allCases) { preset in
                presetRow(preset, isRecommended: preset == recommended)
            }
        } header: {
            Text("どこで使いますか?")
        } footer: {
            if !ExportViewPreset.allCases.contains(where: { $0.matches(project.canvas) }) {
                Text("いまは「詳細設定」で決めた設定で書き出します。上から選ぶと、その使いみちに合わせて設定し直します。")
            }
        }
    }

    private func presetRow(_ preset: ExportViewPreset, isRecommended: Bool) -> some View {
        let selected = preset.matches(project.canvas)
        return Button {
            project.canvas = preset.apply(to: project.canvas)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.systemImage)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(preset.title)
                            .font(.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        if isRecommended {
                            Text("おすすめ")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exporter.isRunning)
    }

    // MARK: ひとことまとめ(サイズ・長さ・空き容量)

    private var orientationWord: String {
        let size = outputSize
        if size.width > size.height { return "横" }
        if size.width < size.height { return "縦" }
        return "正方形"
    }

    private var outputSize: CGSize {
        CompositionBuilder.renderSize(for: project.snapshot(), purpose: .export)
    }

    private var summaryLine: String {
        let size = outputSize
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        var text = orientationWord + " \(w)×\(h)・長さ " + exportDurationString(timelineDuration)
        if let estimate {
            let bytes: Int64 = dualExport ? estimate.estimatedOutputBytes * 2 : estimate.estimatedOutputBytes
            text += "・約 " + StorageEstimator.formatBytes(bytes)
        }
        return text
    }

    private var summarySection: some View {
        Section {
            Label(summaryLine, systemImage: "film.stack")
                .font(.subheadline)

            if let estimate {
                if estimate.canExport && dualStorageOK {
                    Label("空き容量は足りています(空き " + StorageEstimator.formatBytes(estimate.availableBytes) + ")",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("空き容量が足りません", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Color.red)
                        Text(shortfallText(estimate))
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("容量を計算中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("写真アプリにも保存", isOn: $saveToPhotos)
                .disabled(exporter.isRunning)
        } header: {
            Text("書き出す内容")
        }
    }

    private func shortfallText(_ estimate: StorageEstimate) -> String {
        let need: Int64
        if dualExport {
            need = max(0, estimate.requiredBytes * 2 - estimate.availableBytes)
        } else {
            need = estimate.shortfallBytes
        }
        return "不要な写真・動画・アプリを削除して、あと " + StorageEstimator.formatBytes(need) + " 空けてください。画質を下げる(「SNS」を選ぶなど)と小さくなります。"
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
        } footer: {
            if !showAdvanced {
                Text("画面の形・細かさ・画質などを自分で決めたいときに開きます。ふつうは上の使いみちを選ぶだけで大丈夫です。")
            }
        }
    }

    private var savedPresetSection: some View {
        Section {
            ExportPresetBar(project: project, isDisabled: exporter.isRunning)
        } header: {
            Text("保存した設定")
        } footer: {
            Text("よく使う設定を保存して呼び出せます(長押しで名前変更・削除)。")
        }
    }

    private var customSection: some View {
        Section {
            Picker("画面の形", selection: $project.canvas.aspect) {
                ForEach(CanvasAspect.allCases) { a in
                    Text(a.displayName).tag(a)
                }
            }
            Picker("形が合わないとき", selection: $project.canvas.scaling) {
                ForEach(ScalingMode.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            Picker("細かさ(解像度)", selection: $project.canvas.resolution) {
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
            Text("画面と画質")
        } footer: {
            Text("「形が合わないとき」は、素材と画面の形が違うときに、黒帯・ぼかし背景で全体を見せるか、はみ出す部分を切るかを選びます。解像度は数字が大きいほどきれいで、ファイルも大きくなります。")
        }
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

    /// HDR を維持できるコーデックか(H.264 は 8bit のみ)
    private var hdrAvailable: Bool {
        project.canvas.codec != .h264
    }

    private var advancedSection: some View {
        Section {
            Picker("保存形式(コーデック)", selection: $project.canvas.codec) {
                ForEach(ExportCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }

            Toggle("データ量を自分で決める", isOn: manualBitrateBinding)

            if let mbps = project.canvas.bitrateMbps {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("映像のデータ量")
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
                LabeledContent("映像のデータ量", value: "自動(約 \(autoBitrateMbps) Mbps)")
            }

            Picker("音質", selection: $project.canvas.audioBitrateKbps) {
                ForEach(audioBitrates, id: \.self) { kbps in
                    Text(audioQualityLabel(kbps)).tag(kbps)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ファイルの種類")
                Picker("ファイルの種類", selection: $project.canvas.fileFormat) {
                    ForEach(ExportFileFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                Text("MP4 はほとんどの機器・サービスで使えます。迷ったら MP4。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("なめらかさ(1秒のコマ数)")
                Picker("なめらかさ", selection: $project.canvas.frameRate) {
                    ForEach(frameRates, id: \.self) { fps in
                        Text("\(fps)").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                Text("ふつうは 30。動きの速い映像は 60 でなめらかになります(ファイルは大きめ)。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("HDR(明るさの幅が広い映像)を残す", isOn: $project.canvas.preserveHDR)
                .disabled(!hdrAvailable)

            Toggle("字幕を映像に入れる", isOn: $project.canvas.burnInSubtitles)
        } header: {
            Text("ファイルの細かい設定")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("保存形式は迷ったら「自動」。HEVC は小さくきれい、H.264 は古い機器でも再生しやすい形式です。")
                Text("HDR は保存形式が「自動」か HEVC のときだけ選べます。素材が HDR でないときは通常の映像で書き出します。")
                Text("「字幕を映像に入れる」をオフにすると、字幕は動画に入りません(字幕ファイルを別に使うとき向け)。")
            }
        }
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
        case ..<160: word = "ふつう"
        case ..<224: word = "標準"
        case ..<288: word = "高音質"
        default: word = "最高音質"
        }
        return word + "(\(kbps) kbps)"
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
                LabeledContent("ファイルの大きさ(目安)", value: StorageEstimator.formatBytes(estimate.estimatedOutputBytes))
                LabeledContent("作業に必要な空き", value: StorageEstimator.formatBytes(estimate.requiredBytes))
                LabeledContent("いまの空き容量", value: StorageEstimator.formatBytes(estimate.availableBytes))
            }
        } header: {
            Text("書き出す内容のくわしい情報")
        }
    }

    // MARK: その他の書き出し・履歴

    private var moreSection: some View {
        Section {
            NavigationLink {
                extrasPage
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("その他の書き出し", systemImage: "ellipsis.circle")
                    Text(dualExport ? "縦横を同時に書き出す: オン" : "縦横同時・音声だけ・GIF・チャプター一覧")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var extrasPage: some View {
        Form {
            if exporter.isRunning {
                Section {
                    runningView
                }
            }
            extrasSection
        }
        .navigationTitle("その他の書き出し")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 下の書き出しボタン(常に表示)

    private var exportButtonTitle: String {
        let base = dualExport ? "縦横を同時に書き出す" : "書き出す"
        var parts: [String] = []
        if let estimate {
            let bytes: Int64 = dualExport ? estimate.estimatedOutputBytes * 2 : estimate.estimatedOutputBytes
            parts.append("約 " + StorageEstimator.formatBytes(bytes))
        }
        parts.append(saveToPhotos ? "写真に保存" : "ファイルのみ")
        return base + "(" + parts.joined(separator: "・") + ")"
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if exporter.isRunning {
                runningView
            } else {
                Button {
                    startExport()
                } label: {
                    Text(exportButtonTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
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

    /// 縦横同時のときは 2 本分の空き容量が必要
    private var dualStorageOK: Bool {
        guard dualExport, let estimate else { return true }
        return estimate.availableBytes >= estimate.requiredBytes * 2
    }

    private var disabledReason: String? {
        if project.isEmpty { return "編集画面で動画を追加すると書き出せます。" }
        if exporter.isRunning { return nil }
        if let estimate, !estimate.canExport { return "空き容量を増やすか、画質を下げると書き出せます。" }
        if !dualStorageOK { return "縦横同時は 2 本分の空きが必要です。空きを増やすか「その他の書き出し」でオフにしてください。" }
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

    private var runningView: some View {
        let progress = min(max(exporter.progress, 0), 1)
        let remaining = ExportTimeEstimator.shared.remainingText(isRunning: exporter.isRunning, progress: progress)
        return VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(Int((progress * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
                VStack(alignment: .leading, spacing: 2) {
                    if let remaining {
                        Text(remaining)
                            .font(.subheadline.monospacedDigit())
                    }
                    Text(exporter.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("止める", role: .destructive) {
                    exporter.cancel()
                }
                .buttonStyle(.bordered)
            }
            Label(BackgroundWorkNote.export, systemImage: "lock.open")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch exporter.state {
        case .finished:
            VStack(alignment: .leading, spacing: 10) {
                Label(exporter.savedToPhotos ? "書き出して、写真アプリに保存しました"
                      : (lastOutputIsVideo ? "書き出しが終わりました" : "音声の書き出しが終わりました"),
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
                    .frame(minHeight: 44)
                    .disabled(isSavingToPhotos || exporter.lastOutputURL == nil)
                }
                if let url = exporter.lastOutputURL {
                    ShareLink(item: url) {
                        Label("送る・ファイルに保存", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                }
            }
            .padding(.vertical, 4)
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
            Text("書き出しを止めました。もう一度書き出すときは下のボタンを押してください。")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// 失敗理由から「次にすること」を先に伝える
    private func failureAction(for message: String) -> String {
        if message.contains("空き容量") {
            return "不要な写真・動画・アプリを削除して空きを増やすか、画質を下げてから、もう一度「書き出す」を押してください。"
        }
        if message.contains("写真") {
            return "設定アプリでこのアプリの「写真」を許可してから、もう一度お試しください。"
        }
        if message.contains("クリップがありません") {
            return "編集画面で動画を追加してから書き出してください。"
        }
        return "もう一度「書き出す」を押してください。続くときは、解像度や画質を下げるか、アプリを開き直してからお試しください。"
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
                showAlert(title: "保存しました", message: "動画を写真アプリに保存しました。")
            } catch {
                isSavingToPhotos = false
                showAlert(title: "写真に保存できませんでした",
                          message: "「設定を開く」→「写真」で写真の追加を許可してから、もう一度「写真に保存」を押してください。\n\n詳細: " + error.localizedDescription,
                          offersSettings: true)
            }
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
        guard let range = gifRange else { return "開始と終了を 0.1 秒以上あけて入力してください" }
        let length = range.end - range.start
        var text = "\(exportDurationString(range.start)) 〜 \(exportDurationString(range.end))(\(String(format: "%.1f", length)) 秒)"
        if length > 15 {
            text += " ・ 長いとファイルが大きくなります"
        }
        return text
    }

    private var extrasSection: some View {
        Section {
            Toggle("縦横を同時に書き出す", isOn: $dualExport)
                .disabled(exporter.isRunning)

            Button {
                exporter.startAudioOnly(snapshot: project.snapshot())
            } label: {
                Label("音声だけ書き出す(m4a)", systemImage: "waveform")
            }
            .disabled(project.isEmpty || exporter.isRunning)

            Button {
                withAnimation {
                    showGIFPanel.toggle()
                }
            } label: {
                HStack {
                    Label("GIF(短い動くイラスト)で書き出す", systemImage: "photo.stack")
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
        } header: {
            Text("その他の書き出し")
        } footer: {
            Text("「縦横を同時に書き出す」をオンにすると、前の画面の書き出しボタンで 16:9(横)と 9:16(縦)を続けて作ります(2 本分の空き容量が必要)。チャプター一覧は「目印」のチャプターから作り、YouTube の概要欄に貼り付けられます。")
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
                Text("目印がありません。編集画面の「目印」で区間の始まりに目印を付けてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("始まりの目印", selection: $gifMarkerID) {
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

        Picker("なめらかさ", selection: $gifFPS) {
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
                    Button("止める", role: .destructive) {
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
                    gifError = "範囲を短くするか横幅を小さくして、もう一度「GIFを作る」を押してください。(詳細: " + error.localizedDescription + ")"
                }
            }
            gifTask = nil
        }
    }

    private func copyChapterList() {
        UIPasteboard.general.string = project.chapterListText()
        showAlert(title: "コピーしました",
                  message: "チャプター一覧をコピーしました。YouTube の概要欄などに貼り付けてください。")
    }

    // MARK: 書き出し履歴

    private var historySection: some View {
        Section {
            if exporter.history.isEmpty {
                Text("まだ書き出した動画はありません。書き出すとここに並び、送ったり「前回と比較」したりできます。")
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
            Text("書き出した動画")
        } footer: {
            Text("新しい 20 本まで残ります。左にスワイプで削除(書き出したファイルも消えます。写真アプリに保存したものは残ります)。")
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
                    Label("送る", systemImage: "square.and.arrow.up")
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
