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
    if value <= 0 { return String(localized: "全部使う") }
    if value >= 60, value.truncatingRemainder(dividingBy: 60) == 0 {
        return String(localized: "\(Int(value / 60)) 分")
    }
    return String(localized: "\(Int(value.rounded())) 秒")
}

/// BGM に選べる音声ファイルの種類
private let autoEditAudioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]

// MARK: - おまかせ編集

struct AutoEditSheetView: View {
    @Bindable var project: EditorProject
    let player: PlayerController
    let history: EditorHistory
    /// 置き換えが終わった後に呼ぶ(サムネイルの読み直しなど)
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 初期値はショート向け(30 秒・テンポよく)
    @State private var settings: AutoEditSettings = {
        var s = AutoEditSettings()
        s.style = .short
        s.targetDuration = 30
        return s
    }()
    @State private var highlights: [HighlightSegment]? = nil
    /// タイトル・オプション・見どころをまとめた「詳細」を開いているか
    @State private var showsMore = false
    /// 見つけた見どころの一覧を開いているか(閉じておくと長くならない)
    @State private var showsHighlights = false
    @State private var analysis = EditorAnalysisRunner()
    @State private var errorText: String?
    @State private var showBuildConfirm = false
    @State private var isBGMImporterPresented = false

    private var sourceTotal: Double { project.totalDuration }

    /// 縦の作品か(書き出しの大きさで見る)
    private var isVerticalProject: Bool {
        let size = CompositionBuilder.renderSize(for: project.snapshot(), purpose: .export)
        return size.height > size.width
    }

    /// 長さの選択肢。縦の作品はショートの長さだけ。0 = 全部使う
    private var durationOptions: [Double] {
        isVerticalProject ? [15, 30, 60, 0] : [15, 30, 60, 180, 600, 1800, 0]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    styleSection
                    lengthSection
                    bgmSection
                    moreSection
                }
                .safeAreaInset(edge: .bottom) {
                    buildBar
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
            // 作成中はスワイプで閉じられないようにする(閉じたあとに結果がプロジェクトに入らないように)
            .interactiveDismissDisabled(analysis.isRunning)
            .fileImporter(isPresented: $isBGMImporterPresented,
                          allowedContentTypes: autoEditAudioTypes,
                          allowsMultipleSelection: false) { result in
                handleBGMImport(result)
            }
            .confirmationDialog("いまのプロジェクトを作り直しますか?",
                                isPresented: $showBuildConfirm,
                                titleVisibility: .visible) {
                Button("動画を作る") {
                    build()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("クリップの並びや色味が置き換わります。「元に戻す」で戻せます。")
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
        // 閉じたら途中の作成を止める(閉じたあとにプロジェクトを置き換えないように)
        .onDisappear {
            analysis.cancel()
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
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
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
        } header: {
            Text("長さ")
        } footer: {
            Text("素材 \(MediaTimeText.precise(sourceTotal))")
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
                    Label("BGMを選ぶ", systemImage: "music.note.list")
                }
            }
        } header: {
            Text("BGM")
        }
    }

    /// タイトル・オプション・見どころ(ふだんは畳んでおく)
    private var moreSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsMore) {
                Toggle("最初にタイトルを入れる", isOn: $settings.addTitleCard)
                if settings.addTitleCard {
                    TextField("タイトル", text: $settings.titleText)
                }
                Toggle("トランジションを入れる", isOn: $settings.addTransitions)
                Toggle("スタイルに合った色味にする", isOn: $settings.applyLook)
                Toggle("顔が映っている場面を優先", isOn: $settings.preferFaces)
                Toggle("話している場面を優先", isOn: $settings.preferSpeech)

                Button {
                    analyzeHighlights()
                } label: {
                    Label(highlights == nil ? String(localized: "見どころを探す") : String(localized: "もう一度探す"), systemImage: "sparkle.magnifyingglass")
                }
                .disabled(project.isEmpty || analysis.isRunning)

                if let highlights {
                    if highlights.isEmpty {
                        Text("見どころは見つかりませんでした")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        // 一覧は閉じておく(開くと長くなるため)。行を押すとその場面へ移る
                        DisclosureGroup(isExpanded: $showsHighlights) {
                            ForEach(highlights) { segment in
                                highlightRow(segment)
                            }
                        } label: {
                            Text(String(localized: "\(highlights.count) 件の見どころ"))
                        }
                    }
                }
            } label: {
                Text("詳細")
            }
        }
    }

    private func clipName(for clipID: UUID) -> String {
        project.clips.first(where: { $0.id == clipID })?.name ?? String(localized: "クリップ")
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

    /// 画面下に固定した「動画を作る」(書き出し画面の「書き出す」と同じ形。ExportView.swift)
    private var buildBar: some View {
        Button {
            showBuildConfirm = true
        } label: {
            Label("動画を作る", systemImage: "wand.and.stars")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(BrandProminentButtonStyle())
        .disabled(project.isEmpty || analysis.isRunning)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: 処理

    private func handleBGMImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = String(localized: "もう一度「BGMを選ぶ」から曲を選び直してください。\n\n詳細: ") + error.localizedDescription
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
                errorText = String(localized: "端末の空き容量を確かめて、もう一度曲を選んでください(Apple Music の曲は使えません)。\n\n詳細: ") + error.localizedDescription
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
        analysis.run(title: String(localized: "見どころを探しています")) { report in
            let found = try await HighlightAnalyzer.analyze(snapshot: snapshot, settings: current, progress: report)
            if Task.isCancelled { return }
            highlights = found.sorted { $0.start < $1.start }
        } onError: { error in
            errorText = String(localized: "見どころを探せませんでした。このまま「動画を作る」を押すと、全体から均等に選んで作ります。\n\n詳細: ") + error.localizedDescription
        }
    }

    private func build() {
        let snapshot = project.snapshot()
        let current = settings
        let chosen = highlights
        player.pause()
        analysis.run(title: String(localized: "自動編集を作成中")) { report in
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
            errorText = String(localized: "もう一度「動画を作る」を押してください。続くときは、長さを変えるかクリップを減らしてお試しください。\n\n詳細: ") + error.localizedDescription
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
        VStack(alignment: .leading, spacing: 10) {
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
            Text("クリップの並びや色味が置き換わります。「元に戻す」で戻せます。")
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.subheadline.weight(.semibold))
                Text(summary(template))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            EditorPillButton(title: String(localized: "適用"), systemImage: "wand.and.stars", prominent: true) {
                pending = template
            }
            .disabled(analysis.isRunning)
            .opacity(analysis.isRunning ? 0.5 : 1)
        }
        .padding(10)
        .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
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
        let finish = template.finish
        analysis.run(title: String(localized: "テンプレートを適用中")) { report in
            let result = try await AutoEditor.build(snapshot: snapshot,
                                                    settings: chosenSettings,
                                                    highlights: nil,
                                                    progress: { fraction in
                                                        report(finish == nil ? fraction : 0.7 * fraction)
                                                    })
            if Task.isCancelled { return }
            history.record(project)
            project.restore(result)
            if let finish {
                // リール風の仕上げ(無音カット・寄り引き・フラッシュ・キャプションの見た目など)。
                // 途中で止めたら、適用前に戻す(履歴は上で 1 回だけ記録済み)
                do {
                    _ = try await ReelFinisher.apply(finish, to: project) { fraction in
                        report(0.7 + 0.3 * fraction)
                    }
                } catch {
                    project.restore(snapshot)
                    throw error
                }
            }
            player.seek(to: 0)
            if finish != nil && project.subtitles.isEmpty {
                message = String(localized: "「\(name)」を適用しました。「キャプションを作成」で字幕を入れると、このテンプレの見た目で出ます。")
            } else {
                message = String(localized: "「\(name)」を適用しました")
            }
            onApplied()
        } onError: { error in
            errorText = String(localized: "もう一度「適用」を押してください。続くときは別のテンプレートをお試しください。\n\n詳細: ") + error.localizedDescription
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
        var title: String { self == .replace ? String(localized: "置き換える") : String(localized: "末尾に追加") }
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
    /// この画面で選んだ BGM(プロジェクトに BGM がないとき)
    @State private var pickedBGM: URL?
    @State private var pickedBGMName: String?
    @State private var isBGMImporterPresented = false
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
                }
                .safeAreaInset(edge: .bottom) {
                    createBar
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
            // 作成中はスワイプで閉じられないようにする(閉じたあとに結果がプロジェクトに入らないように)
            .interactiveDismissDisabled(analysis.isRunning)
            .fileImporter(isPresented: $isBGMImporterPresented,
                          allowedContentTypes: autoEditAudioTypes,
                          allowsMultipleSelection: false) { result in
                handleBGMImport(result)
            }
            .alert("お知らせ", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // クリップがあるプロジェクトでは、消さずに後ろへ足すのを既定にする
            if !project.isEmpty {
                mode = .append
            }
            await loadThumbnails()
        }
        // 閉じたら途中の作成を止める(閉じたあとにプロジェクトを置き換えないように)
        .onDisappear {
            analysis.cancel()
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
                        .frame(width: 48, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("写真 \(images.count) 枚")
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
            Text("全体 約 \(MediaTimeText.precise(estimatedTotal))")
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
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
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
            } else if let name = pickedBGMName, pickedBGM != nil {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(Color.accentColor)
                    Text(name)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        pickedBGM = nil
                        pickedBGMName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("BGMを外す")
                }
                Button {
                    isBGMImporterPresented = true
                } label: {
                    Label("別の曲に変更", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                Button {
                    isBGMImporterPresented = true
                } label: {
                    Label("BGMを選ぶ", systemImage: "music.note.list")
                }
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
            if mode == .replace {
                Text("いまのクリップとキャプションは消えます。「元に戻す」で戻せます。")
            }
        }
    }

    /// 画面下に固定した「スライドショーを作成」(書き出し画面の「書き出す」と同じ形。ExportView.swift)
    private var createBar: some View {
        Button {
            create()
        } label: {
            Label("スライドショーを作成", systemImage: "photo.stack")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(BrandProminentButtonStyle())
        .disabled(images.isEmpty || analysis.isRunning)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: 処理

    private func handleBGMImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = String(localized: "もう一度「BGMを選ぶ」から曲を選び直してください。\n\n詳細: ") + error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                pickedBGM = try MediaStore.importExternalFile(url)
                pickedBGMName = url.deletingPathExtension().lastPathComponent
            } catch {
                errorText = String(localized: "端末の空き容量を確かめて、もう一度曲を選んでください(Apple Music の曲は使えません)。\n\n詳細: ") + error.localizedDescription
            }
        }
    }

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
        let bgm: URL?
        var bgmName: String? = nil
        if project.audio.bgmURL != nil {
            bgm = useProjectBGM ? project.audio.bgmURL : nil
        } else {
            bgm = pickedBGM
            bgmName = pickedBGMName
        }
        let chosenBGMName = bgmName
        let chosenMode = mode
        // 置き換えるときも、いまの画面比率と書き出し設定を引き継ぐ(空のプロジェクトなら縦 9:16)
        let canvas: CanvasSettings? = project.isEmpty ? nil : project.canvas
        player.pause()
        analysis.run(title: String(localized: "スライドショーを作成中"), indeterminate: true) { _ in
            var result = try await AutoEditor.slideshow(images: urls,
                                                        perImageSeconds: seconds,
                                                        settings: chosenSettings,
                                                        bgm: bgm,
                                                        canvas: canvas)
            if Task.isCancelled { return }
            if let chosenBGMName, result.audio.bgmURL != nil {
                result.audio.bgmName = chosenBGMName
            }
            guard !result.clips.isEmpty else {
                errorText = String(localized: "写真を読み込めませんでした。選び直してから、もう一度「スライドショーを作成」を押してください。")
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
            errorText = String(localized: "写真の枚数を減らすか選び直して、もう一度お試しください。\n\n詳細: ") + error.localizedDescription
        }
    }
}
