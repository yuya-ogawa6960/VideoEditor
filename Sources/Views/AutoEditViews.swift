import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Observation

// =====================================================================
// 第4弾: ワンタップ編集
//   - AutoEditSheetView           : おまかせ編集(スタイル・長さ・BGM・タイトル・ハイライト解析 → AutoEditor.build)
//   - EditorAutoEditTemplatePanel : テンプレート一覧(AutoEditor.templates → いまのクリップに適用)
//   - SlideshowSheetView          : 写真からスライドショー(AutoEditor.slideshow)
// 作成した ProjectSnapshot は history.record の後に project.restore で置き換える(「元に戻す」で戻せる)。
// =====================================================================

private func autoEditPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func autoEditSeconds(_ value: Double) -> String {
    if value <= 0 { return "全部使う" }
    if value >= 60, value.truncatingRemainder(dividingBy: 60) == 0 {
        return "\(Int(value / 60)) 分"
    }
    return "\(Int(value.rounded())) 秒"
}

private func autoEditStyleDescription(_ style: AutoEditStyle) -> String {
    switch style {
    case .documentary: return "落ち着いたテンポ。黒へのフェードや重なるトランジション、ドキュメンタリー風の色味。話している場面を優先します。"
    case .vlog: return "重なるトランジションでテンポよく。暖かいシネマ調の色味。BGM のビートに合わせて切り替えます。"
    case .short: return "15〜30 秒向け。短いカットをズームでつなぎ、鮮やかな色味にします。"
    case .family: return "顔が映っている場面を優先し、やさしい色味でまとめます。"
    case .howto: return "説明している場面を優先し、カットはシンプルに。字幕と相性のよい構成です。"
    }
}

// MARK: - おまかせ編集

struct AutoEditSheetView: View {
    @Bindable var project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// 置き換えが終わった後に呼ぶ(サムネイルの読み直しなど)
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var settings = AutoEditSettings()
    @State private var highlights: [HighlightSegment]? = nil
    @State private var analysis = EditorAnalysisRunner()
    @State private var errorText: String?
    @State private var showBuildConfirm = false
    @State private var isBGMImporterPresented = false

    private static let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
    private let durationOptions: [Double] = [0, 15, 30, 60, 180, 300, 600, 1200, 1800]

    private var sourceTotal: Double { project.totalDuration }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    styleSection
                    lengthSection
                    bgmSection
                    titleSection
                    optionSection
                    highlightSection
                    buildSection
                }
                if let progress = analysis.progress {
                    ClipFXProgressOverlay(progress: progress) {
                        analysis.cancel()
                    }
                }
            }
            .navigationTitle("おまかせ編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        analysis.cancel()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $isBGMImporterPresented,
                          allowedContentTypes: AutoEditSheetView.audioTypes,
                          allowsMultipleSelection: false) { result in
                handleBGMImport(result)
            }
            .confirmationDialog("いまのプロジェクトを自動編集で作り直しますか?",
                                isPresented: $showBuildConfirm,
                                titleVisibility: .visible) {
                Button("作成する") {
                    build()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("クリップの並びや長さ、トランジション、色味などが置き換わります。「元に戻す」で戻せます。")
            }
            .alert("お知らせ", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if settings.titleText.isEmpty, let first = project.clips.first {
                settings.titleText = first.name
            }
            if project.audio.bgmURL == nil {
                settings.useBGMBeats = false
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { errorText != nil },
            set: { newValue in
                if !newValue { errorText = nil }
            }
        )
    }

    // MARK: セクション

    private var styleSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AutoEditStyle.allCases) { style in
                        EditorVisualTile(title: style.displayName, isSelected: settings.style == style) {
                            settings.style = style
                        } preview: {
                            AutoEditStylePreview(style: style)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text(autoEditStyleDescription(settings.style))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("スタイル")
        }
    }

    private var lengthSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(durationOptions, id: \.self) { option in
                        EditorChip(title: autoEditSeconds(option),
                                   isSelected: abs(settings.targetDuration - option) < 0.5) {
                            settings.targetDuration = option
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if settings.targetDuration > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("目標の長さ")
                        Spacer()
                        Text(autoEditSeconds(settings.targetDuration))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.targetDuration, in: 10...1800, step: 10)
                }
            }
        } header: {
            Text("長さ")
        } footer: {
            Text("元の素材の合計は \(MediaTimeText.precise(sourceTotal)) です。目標より短くするときは、見どころを選んで残します。")
        }
    }

    private var bgmSection: some View {
        Section {
            if let name = project.audio.bgmName, project.audio.bgmURL != nil {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(Color.accentColor)
                    Text(name)
                        .lineLimit(2)
                    Spacer()
                }
                Button {
                    isBGMImporterPresented = true
                } label: {
                    Label("別の曲に変更", systemImage: "arrow.triangle.2.circlepath")
                }
                Toggle("BGM のビートに合わせて切り替える", isOn: $settings.useBGMBeats)
            } else {
                Button {
                    isBGMImporterPresented = true
                } label: {
                    Label("BGMを選ぶ(ファイル)", systemImage: "music.note.list")
                }
                Text("BGM を選ぶと、曲のビートに合わせてカットを切り替えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("BGM")
        }
    }

    private var titleSection: some View {
        Section {
            Toggle("最初にタイトルを入れる", isOn: $settings.addTitleCard)
            if settings.addTitleCard {
                TextField("タイトル", text: $settings.titleText)
            }
        } header: {
            Text("タイトル")
        }
    }

    private var optionSection: some View {
        Section {
            Toggle("トランジションを入れる", isOn: $settings.addTransitions)
            Toggle("スタイルに合った色味にする", isOn: $settings.applyLook)
            Toggle("顔が映っている場面を優先", isOn: $settings.preferFaces)
            Toggle("話している場面を優先", isOn: $settings.preferSpeech)
        } header: {
            Text("オプション")
        }
    }

    private var highlightSection: some View {
        Section {
            Button {
                analyzeHighlights()
            } label: {
                Label(highlights == nil ? "見どころを探す" : "もう一度探す", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(project.isEmpty || analysis.isRunning)

            if let highlights {
                if highlights.isEmpty {
                    Text("見どころを見つけられませんでした。「作成」では全体から均等に選びます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(highlights) { segment in
                        highlightRow(segment)
                    }
                }
            }
        } header: {
            Text("見どころ" + (highlights.map { " (\($0.count))" } ?? ""))
        } footer: {
            Text("音の大きさ・話し声・動き・顔から見どころを点数づけします。探さずに「作成」しても、作成するときに自動で探します。")
        }
    }

    private func clipName(for clipID: UUID) -> String {
        project.clips.first(where: { $0.id == clipID })?.name ?? "クリップ"
    }

    private func highlightRow(_ segment: HighlightSegment) -> some View {
        Button {
            seek(to: segment)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(clipName(for: segment.clipID))
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(MediaTimeText.precise(segment.start)) – \(MediaTimeText.precise(segment.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ProgressView(value: min(max(segment.score, 0), 1))
                        .tint(scoreColor(segment.score))
                    Text(autoEditPercent(segment.score))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                if !segment.reason.isEmpty {
                    Text(segment.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.7 { return .green }
        if score >= 0.4 { return .yellow }
        return .gray
    }

    private var buildSection: some View {
        Section {
            Button {
                showBuildConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Label("作成", systemImage: "wand.and.stars")
                        .font(.headline)
                    Spacer()
                }
            }
            .disabled(project.isEmpty || analysis.isRunning)
        } footer: {
            Text("いまのプロジェクトのクリップから自動で編集を組み立て、プロジェクトを置き換えます。「元に戻す」で戻せます。")
        }
    }

    // MARK: 処理

    private func handleBGMImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = "もう一度「BGMを選ぶ」から曲を選び直してください。\n\n詳細: " + error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let localURL = try MediaStore.importExternalFile(url)
                history.record(project)
                project.audio.bgmURL = localURL
                project.audio.bgmName = url.deletingPathExtension().lastPathComponent
                settings.useBGMBeats = true
            } catch {
                errorText = "端末の空き容量を確かめて、もう一度曲を選んでください(Apple Music の曲は使えません)。\n\n詳細: " + error.localizedDescription
            }
        }
    }

    /// 再生位置をそのハイライトの先頭(出力タイムライン上)へ動かす
    private func seek(to segment: HighlightSegment) {
        guard let clip = project.clips.first(where: { $0.id == segment.clipID }),
              let range = ClipFXTimeline.range(of: segment.clipID, in: project) else { return }
        let offset = ClipFXTimeline.outputOffset(sourceTime: segment.start, clip: clip)
        player.seek(to: min(range.lowerBound + offset, range.upperBound))
    }

    private func analyzeHighlights() {
        let snapshot = project.snapshot()
        let current = settings
        analysis.run(title: "見どころを探しています") { report in
            let found = try await HighlightAnalyzer.analyze(snapshot: snapshot, settings: current, progress: report)
            if Task.isCancelled { return }
            highlights = found.sorted { $0.start < $1.start }
        } onError: { error in
            errorText = "見どころを探せませんでした。このまま「作成」を押すと、全体から均等に選んで作ります。\n\n詳細: " + error.localizedDescription
        }
    }

    private func build() {
        let snapshot = project.snapshot()
        let current = settings
        let chosen = highlights
        player.pause()
        analysis.run(title: "自動編集を作成中") { report in
            let result = try await AutoEditor.build(snapshot: snapshot,
                                                    settings: current,
                                                    highlights: chosen,
                                                    progress: report)
            if Task.isCancelled { return }
            history.record(project)
            project.restore(result)
            player.seek(to: 0)
            dismiss()
            onApplied()
        } onError: { error in
            errorText = "もう一度「作成」を押してください。続くときは、目標の長さを変えるかクリップを減らしてお試しください。\n\n詳細: " + error.localizedDescription
        }
    }
}

// MARK: - テンプレート(下部パネル)

struct EditorAutoEditTemplatePanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let analysis: EditorAnalysisRunner
    /// 置き換えが終わった後に呼ぶ
    let onApplied: () -> Void

    @State private var pending: AutoEditor.Template?
    @State private var errorText: String?
    @State private var message: String?

    private var confirmIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { pending != nil },
            set: { newValue in
                if !newValue { pending = nil }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("いまのクリップから、決まった型でワンタップで編集します。長さに合わせて見どころを選び、トランジションと色味も整えます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if project.isEmpty {
                Text("クリップを追加してから使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(AutoEditor.templates) { template in
                    templateRow(template)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .confirmationDialog("「\(pending?.name ?? "")」を適用しますか?",
                            isPresented: confirmIsPresented,
                            titleVisibility: .visible) {
            Button("適用する") {
                if let template = pending {
                    pending = nil
                    apply(template)
                }
            }
            Button("キャンセル", role: .cancel) {
                pending = nil
            }
        } message: {
            Text("クリップの並びや長さ、トランジション、色味が置き換わります。「元に戻す」で戻せます。")
        }
    }

    private func summary(_ template: AutoEditor.Template) -> String {
        var parts: [String] = [template.settings.style.displayName]
        parts.append(autoEditSeconds(template.settings.targetDuration))
        if let kind = template.kind {
            parts.append(kind.displayName)
        }
        return parts.joined(separator: " ・ ")
    }

    private func templateRow(_ template: AutoEditor.Template) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.subheadline.weight(.semibold))
                    Text(template.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary(template))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                EditorPillButton(title: "適用", systemImage: "wand.and.stars", prominent: true) {
                    pending = template
                }
                .disabled(analysis.isRunning)
                .opacity(analysis.isRunning ? 0.5 : 1)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func apply(_ template: AutoEditor.Template) {
        errorText = nil
        message = nil
        player.pause()
        let snapshot = project.snapshot()
        var settings = template.settings
        if project.audio.bgmURL == nil {
            settings.useBGMBeats = false
        }
        if settings.addTitleCard, settings.titleText.isEmpty, let first = project.clips.first {
            settings.titleText = first.name
        }
        let chosenSettings = settings
        let name = template.name
        analysis.run(title: "テンプレートを適用中") { report in
            let result = try await AutoEditor.build(snapshot: snapshot,
                                                    settings: chosenSettings,
                                                    highlights: nil,
                                                    progress: report)
            if Task.isCancelled { return }
            history.record(project)
            project.restore(result)
            player.seek(to: 0)
            message = "「\(name)」を適用しました。「元に戻す」で戻せます。"
            onApplied()
        } onError: { error in
            errorText = "もう一度「適用」を押してください。続くときは別のテンプレートをお試しください。\n\n詳細: " + error.localizedDescription
        }
    }
}

// MARK: - スライドショー

struct SlideshowSheetView: View {
    /// 選んだ写真(アプリ内にコピー済み)
    let images: [URL]
    @Bindable var project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case replace, append
        var id: String { rawValue }
        var title: String { self == .replace ? "置き換える" : "末尾に追加" }
    }

    @State private var perImageSeconds: Double = 3
    @State private var settings: AutoEditSettings = {
        var s = AutoEditSettings()
        s.style = .family
        s.targetDuration = 0
        s.addTitleCard = false
        s.useBGMBeats = false
        return s
    }()
    @State private var useProjectBGM = true
    @State private var mode: Mode = .replace
    @State private var analysis = EditorAnalysisRunner()
    @State private var errorText: String?
    @State private var thumbnails: [URL: UIImage] = [:]

    private var estimatedTotal: Double {
        Double(images.count) * perImageSeconds
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    photosSection
                    timingSection
                    styleSection
                    bgmSection
                    if !project.isEmpty {
                        modeSection
                    }
                    createSection
                }
                if let progress = analysis.progress {
                    ClipFXProgressOverlay(progress: progress) {
                        analysis.cancel()
                    }
                }
            }
            .navigationTitle("スライドショー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        analysis.cancel()
                        dismiss()
                    }
                }
            }
            .alert("お知らせ", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadThumbnails()
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding<Bool>(
            get: { errorText != nil },
            set: { newValue in
                if !newValue { errorText = nil }
            }
        )
    }

    // MARK: セクション

    private var photosSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images, id: \.self) { url in
                        ZStack {
                            Color.white.opacity(0.08)
                            if let image = thumbnails[url] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("写真(\(images.count) 枚)")
        }
    }

    private var timingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("1 枚あたり")
                    Spacer()
                    Text(String(format: "%.1f 秒", perImageSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $perImageSeconds, in: 1.5...8, step: 0.5)
            }
            Toggle("トランジションを入れる", isOn: $settings.addTransitions)
        } header: {
            Text("時間")
        } footer: {
            Text("全体で約 \(MediaTimeText.precise(estimatedTotal)) になります。写真はズームイン / ズームアウトを交互に繰り返してゆっくり動きます。")
        }
    }

    private var styleSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AutoEditStyle.allCases) { style in
                        EditorVisualTile(title: style.displayName, isSelected: settings.style == style) {
                            settings.style = style
                        } preview: {
                            AutoEditStylePreview(style: style)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Toggle("スタイルに合った色味にする", isOn: $settings.applyLook)
            Toggle("最初にタイトルを入れる", isOn: $settings.addTitleCard)
            if settings.addTitleCard {
                TextField("タイトル", text: $settings.titleText)
            }
        } header: {
            Text("スタイル")
        }
    }

    private var bgmSection: some View {
        Section {
            if let name = project.audio.bgmName, project.audio.bgmURL != nil {
                Toggle(isOn: $useProjectBGM) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("プロジェクトの BGM を使う")
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("BGM はまだありません。作成したあと、編集画面の「BGM」から追加できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("BGM")
        }
    }

    private var modeSection: some View {
        Section {
            Picker("いまのプロジェクト", selection: $mode) {
                ForEach(Mode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("いまのクリップ")
        } footer: {
            Text(mode == .replace
                 ? "いまのクリップ・字幕などを消してスライドショーに置き換えます(「元に戻す」で戻せます)。"
                 : "いまのクリップの後ろにスライドショーの写真を追加します。")
        }
    }

    private var createSection: some View {
        Section {
            Button {
                create()
            } label: {
                HStack {
                    Spacer()
                    Label("スライドショーを作成", systemImage: "photo.stack")
                        .font(.headline)
                    Spacer()
                }
            }
            .disabled(images.isEmpty || analysis.isRunning)
        }
    }

    // MARK: 処理

    @MainActor
    private func loadThumbnails() async {
        for url in images.prefix(40) {
            if Task.isCancelled { return }
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                MediaStore.makeImageClipThumbnail(url: url, maxPixel: 128)
            }.value
            if let image {
                thumbnails[url] = image
            }
        }
    }

    private func create() {
        let urls = images
        let seconds = perImageSeconds
        let chosenSettings = settings
        let bgm: URL? = useProjectBGM ? project.audio.bgmURL : nil
        let chosenMode = mode
        player.pause()
        analysis.run(title: "スライドショーを作成中", indeterminate: true) { _ in
            let result = try await AutoEditor.slideshow(images: urls,
                                                        perImageSeconds: seconds,
                                                        settings: chosenSettings,
                                                        bgm: bgm)
            if Task.isCancelled { return }
            guard !result.clips.isEmpty else {
                errorText = "写真を選び直してから、もう一度「スライドショーを作成」を押してください(写真を読み込めませんでした)。"
                return
            }
            history.record(project)
            if chosenMode == .replace || project.isEmpty {
                project.restore(result)
                player.seek(to: 0)
            } else {
                project.clips.append(contentsOf: result.clips)
                if project.audio.bgmURL == nil, result.audio.bgmURL != nil {
                    project.audio = result.audio
                }
            }
            dismiss()
            onApplied()
        } onError: { error in
            errorText = "写真の枚数を減らすか選び直して、もう一度お試しください。\n\n詳細: " + error.localizedDescription
        }
    }
}
