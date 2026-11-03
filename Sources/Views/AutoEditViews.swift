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
    /// 置き換えが終わった後に呼ぶ(サムネイルの読み直しなど)。話の整理をした結果の一言があれば渡す
    let onApplied: (String?) -> Void

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
    /// オーダー(やりたいことを文章で)と、読み取った内容
    @State private var orderText = ""
    @State private var orderSummary: [String] = []
    @State private var isReadingOrder = false
    /// 最後に読み取ったオーダー(同じ文のままなら、手で変えた項目を読み取りで上書きしない)
    @State private var lastReadOrder = ""
    @FocusState private var orderFocused: Bool
    /// 入力欄に見せている入力例の番号(数秒ごとに進む)
    @State private var exampleIndex = 0

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        hero
                        orderSection
                        styleSection
                        lengthSection
                        bgmSection
                        abilitiesSection
                        highlightsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(white: 0.07).ignoresSafeArea())
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
                Text(buildConfirmMessage)
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

    /// いちばん上: 作業するロボットと、素材 → 完成の長さ(選ぶたびに右側が変わる)
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            RobotWorkshop(clip: .workshop)
                .padding(.horizontal, -4)
            Text("AI におまかせ")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("スタイルと長さを選ぶだけ。見どころ探しからカット・BGM 合わせまで AI が仕上げます")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            AutoEditCompressionView(source: sourceTotal, target: settings.targetDuration,
                                    styleName: settings.style.displayName)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: BrandStyle.Radius.sheet, style: .continuous)
                .fill(LinearGradient(colors: [BrandStyle.green.opacity(0.35), BrandStyle.blue.opacity(0.35),
                                              BrandStyle.navy.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BrandStyle.Radius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// オーダー: やりたいことを文章で書く(入力例が入れ替わりで出る)。「動画を作る」で読み取って設定に入れる
    private var orderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("AI にオーダー", systemImage: "text.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("下の項目は自由に変えられます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $orderText)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(minHeight: 92)
                    .focused($orderFocused)
                if orderText.isEmpty {
                    // 入力例をパッと入れ替えて見せる(ここを押しても入力欄に入る)
                    Text(currentExample)
                        .font(.body)
                        .foregroundStyle(Color.white.opacity(0.42))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .id(exampleIndex)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                        .allowsHitTesting(false)
                }
            }
            .padding(10)
            .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous)
                    .strokeBorder(orderFocused ? AnyShapeStyle(BrandStyle.gradient) : AnyShapeStyle(Color.white.opacity(0.1)),
                                  lineWidth: orderFocused ? 2 : 1)
            )
            HStack(spacing: 12) {
                if orderText.isEmpty {
                    Button {
                        orderText = currentExample
                    } label: {
                        Label("この例を使う", systemImage: "text.insert")
                    }
                } else {
                    Button {
                        readOrder(thenBuild: false)
                    } label: {
                        Label("読み取る", systemImage: "wand.and.rays")
                    }
                    .disabled(isReadingOrder)
                    Button(role: .destructive) {
                        orderText = ""
                        orderSummary = []
                    } label: {
                        Label("消す", systemImage: "xmark.circle")
                    }
                }
                Spacer()
                if isReadingOrder {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            if !orderSummary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI が読み取った内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(orderSummary, id: \.self) { item in
                                Label(item, systemImage: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(BrandStyle.gradient, in: Capsule())
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 入力例を数秒ごとに入れ替える(入力中・入力済みのときは止める)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                if Task.isCancelled { break }
                if orderText.isEmpty {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        exampleIndex += 1
                    }
                }
            }
        }
    }

    private var currentExample: String {
        let examples = AutoEditOrder.examples
        guard !examples.isEmpty else { return "" }
        return examples[exampleIndex % examples.count]
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AutoEditStepHeader(number: 1, title: String(localized: "どんな動画にする?"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AutoEditStyle.allCases) { style in
                        AutoEditStyleCard(style: style, isSelected: settings.style == style) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                settings.style = style
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
    }

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AutoEditStepHeader(number: 2, title: String(localized: "長さは?"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(durationOptions, id: \.self) { option in
                        EditorChip(title: autoEditSeconds(option),
                                   isSelected: abs(settings.targetDuration - option) < 0.5) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                settings.targetDuration = option
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text(lengthCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 長さの下の一言(何を選ぶのか)
    private var lengthCaption: String {
        let target = settings.targetDuration
        if target <= 0 { return String(localized: "素材をすべて使い、間だけ詰めます") }
        if target >= sourceTotal { return String(localized: "素材より長いので、ほぼすべて使います") }
        return String(localized: "\(MediaTimeText.precise(sourceTotal)) の素材から、いちばん良い \(autoEditSeconds(target)) を選びます")
    }

    private var bgmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AutoEditStepHeader(number: 3, title: String(localized: "音楽"))
            if let name = project.audio.bgmName, project.audio.bgmURL != nil {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(BrandStyle.gradient, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        isBGMImporterPresented = true
                    } label: {
                        Text("別の曲に変更")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            } else {
                Button {
                    isBGMImporterPresented = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .background(BrandStyle.surfaceStrong, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BGMを選ぶ")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("曲を入れると、ビートに合わせて切り替えます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// AI がやること(タップでオン・オフ)。前は「詳細」に畳んでいたスイッチを、何をするかが見える形で並べる
    private var abilitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("AI がやること", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("タップでオン・オフ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                AutoEditAbilityTile(icon: "face.smiling", title: String(localized: "顔が映っている場面を優先"),
                                    isOn: $settings.preferFaces)
                AutoEditAbilityTile(icon: "waveform", title: String(localized: "話している場面を優先"),
                                    isOn: $settings.preferSpeech)
                AutoEditAbilityTile(icon: "scissors", title: String(localized: "話していない所を切る"),
                                    detail: String(localized: "声の無い間と「えー」「あのー」を詰めます"),
                                    isOn: $settings.cutNonSpeech)
                AutoEditAbilityTile(icon: "arrow.uturn.backward", title: String(localized: "言い直しは最後だけ残す"),
                                    detail: String(localized: "同じ出だしをすぐ話し直した所は、前の回を切ります"),
                                    isOn: $settings.cutRetakes)
                AutoEditAbilityTile(icon: "magnifyingglass", title: String(localized: "調べ物の場面を切る"),
                                    detail: String(localized: "黙って手元を見ている 2 秒以上の所を切ります。切った所にはマーカーが付きます"),
                                    isOn: $settings.cutLookups)
                AutoEditAbilityTile(icon: "square.on.square", title: String(localized: "トランジションを入れる"),
                                    isOn: $settings.addTransitions)
                AutoEditAbilityTile(icon: "camera.filters", title: String(localized: "スタイルに合った色味にする"),
                                    isOn: $settings.applyLook)
                AutoEditAbilityTile(icon: "textformat", title: String(localized: "最初にタイトルを入れる"),
                                    isOn: $settings.addTitleCard)
                if project.audio.bgmURL != nil {
                    AutoEditAbilityTile(icon: "metronome", title: String(localized: "BGM のビートに合わせて切り替える"),
                                        isOn: $settings.useBGMBeats)
                }
            }
            if settings.addTitleCard {
                TextField("タイトル", text: $settings.titleText)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            }
        }
    }

    /// 先に見どころを見てみる(探した見どころは「動画を作る」でそのまま使う)
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                analyzeHighlights()
            } label: {
                Label(highlights == nil ? String(localized: "見どころを先に見てみる") : String(localized: "もう一度探す"),
                      systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(project.isEmpty || analysis.isRunning)

            if let highlights {
                if highlights.isEmpty {
                    Text("見どころは見つかりませんでした")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // 一覧は閉じておく(開くと長くなるため)。行を押すとその場面へ移る
                    DisclosureGroup(isExpanded: $showsHighlights) {
                        VStack(spacing: 10) {
                            ForEach(highlights) { segment in
                                highlightRow(segment)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(String(localized: "\(highlights.count) 件の見どころ"))
                            .font(.subheadline)
                    }
                    .padding(12)
                    .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                }
            }
        }
    }

    /// スイッチの下に一行の説明を付ける
    private func talkCleanupToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>, footer: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// 画面下に固定した「動画を作る」(オーダーがあれば、先に読み取って設定に入れてから確かめる)
    private var buildBar: some View {
        VStack(spacing: 6) {
            Button {
                let order = orderText.trimmingCharacters(in: .whitespacesAndNewlines)
                if order.isEmpty || order == lastReadOrder {
                    showBuildConfirm = true
                } else {
                    readOrder(thenBuild: true)
                }
            } label: {
                HStack(spacing: 8) {
                    if isReadingOrder {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .symbolEffect(.pulse, options: .repeating, isActive: !project.isEmpty && !analysis.isRunning)
                    }
                    Text(isReadingOrder ? String(localized: "オーダーを読み取り中") : String(localized: "動画を作る"))
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(BrandProminentButtonStyle())
            .disabled(project.isEmpty || analysis.isRunning || isReadingOrder)
            Text("できあがりは「元に戻す」でいつでも戻せます")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    /// オーダーの文章を読み取って設定に入れる。thenBuild なら続けて作る前の確認を出す
    private func readOrder(thenBuild: Bool) {
        let order = orderText
        guard !isReadingOrder else { return }
        orderFocused = false
        isReadingOrder = true
        Task { @MainActor in
            let result = await AutoEditOrder.interpret(order, current: settings)
            isReadingOrder = false
            lastReadOrder = order.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasBGM = project.audio.bgmURL != nil
            let beatsLabel = String(localized: "BGM のビートに合わせて切り替える")
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                settings = result.settings
                if !hasBGM { settings.useBGMBeats = false }
                // 曲が無いときはビートの項目を出さない(使えないので)
                orderSummary = hasBGM ? result.summary : result.summary.filter { $0 != beatsLabel }
            }
            if thenBuild {
                showBuildConfirm = true
            }
        }
    }

    /// 作る前の確認に出す一言(オーダーから読み取った内容があれば並べる)
    private var buildConfirmMessage: String {
        let base = String(localized: "クリップの並びや色味が置き換わります。「元に戻す」で戻せます。")
        guard !orderSummary.isEmpty else { return base }
        return orderSummary.joined(separator: "・") + "\n\n" + base
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
        let cleanup = TalkCleanupOptions(settings: current)
        analysis.run(title: String(localized: "自動編集を作成中")) { report in
            let result = try await AutoEditor.build(snapshot: snapshot,
                                                    settings: current,
                                                    highlights: chosen,
                                                    progress: { fraction in
                                                        report(cleanup.isEnabled ? 0.8 * fraction : fraction)
                                                    })
            if Task.isCancelled { return }
            // 話の整理(声の無い所・言い直し・調べ物)。「全部使う」でも同じようにかける。
            // 整理に失敗しても作った動画はそのまま使う(途中で止めたときだけ何もしない)
            var plan = TalkCleanupPlan()
            if cleanup.isEnabled {
                do {
                    plan = try await TalkCleanup.plan(snapshot: result, subtitles: result.subtitles, options: cleanup) { fraction in
                        report(0.8 + 0.2 * fraction)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    plan = TalkCleanupPlan()
                }
                if Task.isCancelled { return }
            }
            history.record(project)
            project.restore(result)
            if !plan.isEmpty {
                TalkCleanup.apply(plan, to: project)
            }
            player.seek(to: 0)
            dismiss()
            onApplied(plan.summaryText)
        } onError: { error in
            errorText = String(localized: "もう一度「動画を作る」を押してください。続くときは、長さを変えるかクリップを減らしてお試しください。\n\n詳細: ") + error.localizedDescription
        }
    }
}

// MARK: - おまかせ編集の部品

/// 手順の見出し(番号の丸 + 一言)
private struct AutoEditStepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(BrandStyle.gradient, in: Circle())
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
        }
    }
}

/// 素材 → 完成 の長さを 2 本の帯で見せる(長さ・スタイルを選ぶたびに下の帯が伸び縮みする)
private struct AutoEditCompressionView: View {
    let source: Double
    let target: Double
    let styleName: String

    private var ratio: Double {
        guard target > 0, source > 0, target < source else { return 1 }
        return max(0.06, target / source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("素材")
                Spacer()
                Text(MediaTimeText.precise(source))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.7))
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(height: 8)
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("完成")
                Text(verbatim: "・\(styleName)")
                Spacer()
                Text(autoEditSeconds(target))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.top, 4)
            GeometryReader { geo in
                Capsule()
                    .fill(BrandStyle.gradient)
                    .frame(width: max(12, geo.size.width * CGFloat(ratio)))
            }
            .frame(height: 8)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: ratio)
    }
}

/// スタイルの見本カード(見本 + 名前 + 一言)
private struct AutoEditStyleCard: View {
    let style: AutoEditStyle
    let isSelected: Bool
    let action: () -> Void

    private static let width: CGFloat = 104

    private var tagline: String {
        switch style {
        case .documentary: return String(localized: "章立てで、じっくり見せる")
        case .vlog: return String(localized: "旅の空気をテンポよく")
        case .short: return String(localized: "見どころだけを速いテンポで")
        case .family: return String(localized: "笑顔の場面をやさしくつなぐ")
        case .howto: return String(localized: "手順がわかる解説に")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                AutoEditStylePreview(style: style)
                    .frame(width: Self.width, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(BrandStyle.gradient) : AnyShapeStyle(Color.white.opacity(0.1)),
                                          lineWidth: isSelected ? 3 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, BrandStyle.green)
                                .padding(6)
                        }
                    }
                Text(style.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(tagline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.width, alignment: .leading)
            .scaleEffect(isSelected ? 1 : 0.94)
            .opacity(isSelected ? 1 : 0.8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// AI がやることの 1 項目(タップでオン・オフ)
private struct AutoEditAbilityTile: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isOn.toggle()
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(isOn ? AnyShapeStyle(BrandStyle.gradient) : AnyShapeStyle(BrandStyle.surfaceStrong), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? BrandStyle.green : Color.white.opacity(0.3))
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BrandStyle.surface, in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous)
                    .strokeBorder(isOn ? BrandStyle.green.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
        // 話の整理(TalkCleanup.swift)は、話を優先するテンプレだけにかける(風景中心のテンプレを刻まないように)
        let cleanup = chosenSettings.preferSpeech ? TalkCleanupOptions(settings: chosenSettings) : TalkCleanupOptions(cutNonSpeech: false, cutRetakes: false, cutLookups: false)
        let buildShare: Double = (finish == nil && !cleanup.isEnabled) ? 1 : 0.7
        analysis.run(title: String(localized: "テンプレートを適用中")) { report in
            let result = try await AutoEditor.build(snapshot: snapshot,
                                                    settings: chosenSettings,
                                                    highlights: nil,
                                                    progress: { fraction in
                                                        report(buildShare * fraction)
                                                    })
            if Task.isCancelled { return }
            history.record(project)
            project.restore(result)
            if let finish {
                // リール風の仕上げ(無音カット・寄り引き・フラッシュ・キャプションの見た目など)。
                // 途中で止めたら、適用前に戻す(履歴は上で 1 回だけ記録済み)
                do {
                    _ = try await ReelFinisher.apply(finish, to: project) { fraction in
                        report(0.7 + (cleanup.isEnabled ? 0.2 : 0.3) * fraction)
                    }
                } catch {
                    project.restore(snapshot)
                    throw error
                }
            }
            var cleanupNote: String?
            if cleanup.isEnabled {
                // 仕上げのあとに話の整理。途中で止めたら適用前に戻し、ほかの失敗はそのまま使う
                do {
                    let current = project.snapshot()
                    // 仕上げが無いときは、組み立ての続き(buildShare)から進める
                    let base = finish == nil ? buildShare : 0.9
                    let plan = try await TalkCleanup.plan(snapshot: current, subtitles: current.subtitles, options: cleanup) { fraction in
                        report(base + (1 - base) * fraction)
                    }
                    if Task.isCancelled {
                        project.restore(snapshot)
                        return
                    }
                    if !plan.isEmpty {
                        TalkCleanup.apply(plan, to: project)
                        cleanupNote = plan.summaryText
                    }
                } catch is CancellationError {
                    project.restore(snapshot)
                    throw CancellationError()
                } catch {
                    cleanupNote = nil
                }
            }
            player.seek(to: 0)
            if finish != nil && project.subtitles.isEmpty {
                message = String(localized: "「\(name)」を適用しました。「自動字幕」で字幕を入れると、このテンプレの見た目で出ます。")
            } else {
                message = String(localized: "「\(name)」を適用しました")
            }
            if let cleanupNote {
                message = (message ?? "") + "\n" + cleanupNote
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
