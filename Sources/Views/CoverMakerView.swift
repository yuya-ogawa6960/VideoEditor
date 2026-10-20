import SwiftUI
import PhotosUI
import UIKit

// =====================================================================
// サムネ(カバー画像)作成画面。
// 動画の 1 コマ(または写真)を背景に、メモ風のカード(タイトル + 本文)を重ねて画像にする。
// 描画は CoverRenderer(別担当)。ここでは設定の編集・プレビュー・保存だけを行う。
// 設定は project.cover(CoverSettings)に保存され、プロジェクトと一緒に残る。
// =====================================================================

struct CoverMakerView: View {
    @Bindable var project: EditorProject

    @Environment(\.dismiss) private var dismiss

    // プレビュー
    @State private var preview: UIImage?
    @State private var isRendering = false
    @State private var renderTask: Task<Void, Never>?
    @State private var renderGeneration = 0
    @State private var renderError: String?

    // 背景
    @State private var photoItem: PhotosPickerItem?
    @State private var stripThumbnails: [UIImage?] = []
    @State private var stripTask: Task<Void, Never>?

    // カードのドラッグ
    @State private var dragStartCenter: NormalizedPoint?

    // 保存・共有
    @State private var isSaving = false
    @State private var isPreparingShare = false
    @State private var shareURL: URL?
    @State private var alertTitle = ""
    @State private var alertMessage: String?

    /// プレビューの描画幅(px)
    private let previewWidth: CGFloat = 1280
    /// 保存する画像の最大幅(px)
    private let outputWidth: CGFloat = 1920
    private let stripCount = 8

    /// 出力タイムラインの長さ(トランジションの重なりを反映)
    private var duration: Double {
        let total = CompositionBuilder.totalDuration(for: project.snapshot())
        return total.isFinite ? max(0, total) : 0
    }

    private var canRender: Bool {
        !project.isEmpty || project.cover.imageURL != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewArea
                Form {
                    backgroundSection
                    textSection
                    cardSection
                    fontSection
                    outputSection
                }
            }
            .navigationTitle("サムネ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear {
                loadStrip()
                scheduleRender(delay: 0)
            }
            .onChange(of: project.cover) {
                shareURL = nil
                scheduleRender()
            }
            .onChange(of: project.clips) {
                loadStrip()
                shareURL = nil
                scheduleRender()
            }
            .onChange(of: photoItem) {
                handlePhotoPick()
            }
            .onDisappear {
                renderTask?.cancel()
                stripTask?.cancel()
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

    // MARK: - プレビュー

    private var previewAspect: CGFloat {
        if let preview, preview.size.width > 0, preview.size.height > 0 {
            return preview.size.width / preview.size.height
        }
        let size = previewSize(for: project.snapshot())
        return size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    private var previewArea: some View {
        ZStack {
            Color.black
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
            } else if canRender {
                ProgressView()
                    .tint(.white)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                    Text("動画を追加するか、写真を選んでください")
                        .font(.footnote)
                }
                .foregroundStyle(Color.white.opacity(0.7))
            }
            cardGuide
            if isRendering, preview != nil {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .padding(8)
                    }
                    Spacer()
                }
            }
            if let renderError {
                VStack {
                    Spacer()
                    Text(renderError)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
        }
        .aspectRatio(previewAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 320)
        .overlay {
            dragOverlay
        }
        .clipped()
    }

    /// カードのおおよその位置を示す枠(描画の待ち時間中も位置が分かるように)
    private var cardGuide: some View {
        GeometryReader { geo in
            let size = geo.size
            let width = size.width * CGFloat(project.cover.memoWidthRatio)
            let height = width * 0.72
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(dragStartCenter == nil ? 0.35 : 0.9),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .frame(width: width, height: height)
                .rotationEffect(.degrees(project.cover.memoRotation))
                .position(project.cover.memoCenter.point(in: size))
        }
        .allowsHitTesting(false)
    }

    private var dragOverlay: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStartCenter == nil {
                                dragStartCenter = project.cover.memoCenter
                            }
                            guard let origin = dragStartCenter,
                                  geo.size.width > 0, geo.size.height > 0 else { return }
                            let dx = Double(value.translation.width / geo.size.width)
                            let dy = Double(value.translation.height / geo.size.height)
                            project.cover.memoCenter = NormalizedPoint(
                                x: min(max(origin.x + dx, 0.05), 0.95),
                                y: min(max(origin.y + dy, 0.05), 0.95))
                        }
                        .onEnded { _ in
                            dragStartCenter = nil
                        }
                )
        }
    }

    // MARK: - 背景

    private var backgroundSection: some View {
        Section {
            if let imageURL = project.cover.imageURL {
                HStack(spacing: 12) {
                    if let thumb = MediaStore.makeImageClipThumbnail(url: imageURL, maxPixel: 120) {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("写真を背景にしています")
                        .font(.subheadline)
                    Spacer()
                    Button("動画のコマに戻す") {
                        project.cover.imageURL = nil
                    }
                    .buttonStyle(.borderless)
                    .disabled(project.isEmpty)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("コマの時刻")
                        Spacer()
                        Text(MediaTimeText.precise(project.cover.frameTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $project.cover.frameTime, in: 0...max(duration, 0.01))
                        .disabled(project.isEmpty)
                    if !stripThumbnails.isEmpty {
                        thumbnailStrip
                    }
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("写真を選ぶ", systemImage: "photo")
            }
        } header: {
            Text("背景")
        } footer: {
            Text("動画の 1 コマ、または写真ライブラリの写真を背景にします。")
        }
    }

    private var thumbnailStrip: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<stripCount, id: \.self) { i in
                        ZStack {
                            Color(white: 0.2)
                            if i < stripThumbnails.count, let image = stripThumbnails[i] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: width / CGFloat(stripCount), height: 44)
                        .clipped()
                    }
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 48)
                    .offset(x: indicatorX(width: width) - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = min(max(Double(value.location.x / width), 0), 1)
                        project.cover.frameTime = p * duration
                    }
            )
        }
        .frame(height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func indicatorX(width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let p = min(max(project.cover.frameTime / duration, 0), 1)
        return CGFloat(p) * width
    }

    // MARK: - 文字

    private var textSection: some View {
        Section {
            TextField("タイトル(例: 夏の旅行 Vlog)", text: $project.cover.title)
            TextField("メモ(改行で箇条書き)", text: $project.cover.memoText, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("文字")
        } footer: {
            Text("タイトルは画面の左上に大きく、メモはカードの中に表示されます。")
        }
    }

    // MARK: - カード

    private var cardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("紙の種類")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MemoPaper.allCases) { paper in
                            let selected = project.cover.paper == paper
                            Button {
                                project.cover.paper = paper
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(paperColor(paper))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                                    Text(paper.displayName)
                                        .font(.subheadline.weight(selected ? .semibold : .regular))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                                )
                                .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("カードの幅")
                    Spacer()
                    Text("\(Int((project.cover.memoWidthRatio * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.cover.memoWidthRatio, in: 0.2...0.8)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("傾き")
                    Spacer()
                    Text(String(format: "%.0f°", project.cover.memoRotation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $project.cover.memoRotation, in: -20...20, step: 1)
            }

            HStack {
                Button("位置を中央に") {
                    project.cover.memoCenter = NormalizedPoint(x: 0.5, y: 0.5)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("右側に") {
                    project.cover.memoCenter = NormalizedPoint(x: 0.72, y: 0.5)
                    project.cover.memoRotation = -4
                }
                .buttonStyle(.borderless)
            }

            Toggle("動画と同じ色味(フィルタ)にする", isOn: $project.cover.applyLook)
        } header: {
            Text("メモ風カード")
        } footer: {
            Text("カードはプレビューを指でドラッグして動かせます。")
        }
    }

    private func paperColor(_ paper: MemoPaper) -> Color {
        switch paper {
        case .yellow: return Color(red: 1.0, green: 0.93, blue: 0.55)
        case .white: return Color(white: 0.97)
        case .kraft: return Color(red: 0.80, green: 0.66, blue: 0.47)
        case .dark: return Color(red: 0.17, green: 0.20, blue: 0.19)
        case .pink: return Color(red: 1.0, green: 0.78, blue: 0.84)
        }
    }

    // MARK: - フォント

    private var fontBinding: Binding<String> {
        Binding<String>(
            get: { project.cover.fontName ?? "" },
            set: { project.cover.fontName = $0.isEmpty ? nil : $0 }
        )
    }

    private var fontSection: some View {
        let options = SubtitleFontCatalog.options(including: project.cover.fontName)
        return Section {
            Picker("フォント", selection: fontBinding) {
                ForEach(options) { option in
                    SubtitleFontCatalog.label(for: option)
                        .tag(option.id)
                }
            }
        } header: {
            Text("フォント")
        } footer: {
            Text("「ファイル」から読み込んだフォント(.ttf / .otf)は、テキスト編集のフォント読み込みから追加できます。")
        }
    }

    // MARK: - 保存・共有

    private var outputSection: some View {
        Section {
            Button {
                saveToPhotos()
            } label: {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("保存中…")
                    }
                } else {
                    Label("写真に保存", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(isSaving || !canRender)

            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("送る・ファイルに保存", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    prepareShare()
                } label: {
                    if isPreparingShare {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("画像を作成中…")
                        }
                    } else {
                        Label("送るための画像を作る", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isPreparingShare || !canRender)
            }
        } header: {
            Text("保存・送る")
        } footer: {
            Text("「書き出し」で選んだ画面比率で、幅 \(Int(outputWidth)) px の画像(JPEG)を作ります。YouTube のサムネイルなどに使えます。")
        }
    }

    // MARK: - 描画

    private func previewSize(for snapshot: ProjectSnapshot) -> CGSize {
        sizeForWidth(previewWidth, snapshot: snapshot)
    }

    private func outputSize(for snapshot: ProjectSnapshot) -> CGSize {
        let export = CompositionBuilder.renderSize(for: snapshot, purpose: .export)
        let width = (export.width > 0) ? min(outputWidth, export.width) : outputWidth
        return sizeForWidth(width, snapshot: snapshot)
    }

    private func sizeForWidth(_ width: CGFloat, snapshot: ProjectSnapshot) -> CGSize {
        let export = CompositionBuilder.renderSize(for: snapshot, purpose: .export)
        let aspect: CGFloat = (export.width > 0 && export.height > 0) ? export.width / export.height : 16.0 / 9.0
        var height = (width / aspect).rounded(.down)
        if height.truncatingRemainder(dividingBy: 2) != 0 { height -= 1 }
        return CGSize(width: width, height: max(2, height))
    }

    private func scheduleRender(delay: Double = 0.35) {
        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        guard canRender else {
            preview = nil
            isRendering = false
            return
        }
        let snapshot = project.snapshot()
        let cover = project.cover
        let size = previewSize(for: snapshot)
        isRendering = true
        renderTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled { return }
            do {
                let image = try await CoverRenderer.render(snapshot: snapshot, cover: cover, size: size)
                if Task.isCancelled || generation != renderGeneration { return }
                preview = image
                renderError = nil
            } catch {
                if Task.isCancelled || generation != renderGeneration { return }
                renderError = "プレビューを作れませんでした。背景のコマや写真を選び直してください。(詳細: " + error.localizedDescription + ")"
            }
            isRendering = false
        }
    }

    private func loadStrip() {
        stripTask?.cancel()
        let snapshot = project.snapshot()
        let total = CompositionBuilder.totalDuration(for: snapshot)
        guard !snapshot.clips.isEmpty, total.isFinite, total > 0 else {
            stripThumbnails = []
            return
        }
        let count = stripCount
        stripThumbnails = Array(repeating: nil, count: count)
        stripTask = Task { @MainActor in
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = total * (Double(i) + 0.5) / Double(count)
                let image = await CoverMakerView.frameThumbnail(snapshot: snapshot, timelineTime: t)
                if Task.isCancelled { return }
                if i < stripThumbnails.count {
                    stripThumbnails[i] = image
                }
            }
        }
    }

    /// 出力タイムライン上の時刻にあたるクリップの元素材からサムネイルを作る(トランジションの重なりは無視)
    private static func frameThumbnail(snapshot: ProjectSnapshot, timelineTime: Double) async -> UIImage? {
        var t = 0.0
        let lastID = snapshot.clips.last?.id
        for clip in snapshot.clips {
            let end = t + clip.outputDuration
            if timelineTime < end || clip.id == lastID {
                let local = max(0, min(timelineTime - t, clip.outputDuration))
                if let still = clip.stillImageURL {
                    return MediaStore.makeImageClipThumbnail(url: still, maxPixel: 160)
                }
                let sourceTime = clip.startTime + local * clip.speed
                return await MediaStore.thumbnail(for: clip.url, at: sourceTime, maxPixel: 160)
            }
            t = end
        }
        return nil
    }

    // MARK: - 写真の選択

    private func handlePhotoPick() {
        guard let item = photoItem else { return }
        Task { @MainActor in
            do {
                if let picked = try await item.loadTransferable(type: PickedPhoto.self) {
                    project.cover.imageURL = picked.url
                } else {
                    alertTitle = "写真を読み込めませんでした"
                    alertMessage = "別の写真を選んでください(この写真は読み込めない形式です)。"
                }
            } catch {
                alertTitle = "写真を読み込めませんでした"
                alertMessage = "もう一度「写真を選ぶ」から選び直してください。\n\n詳細: " + error.localizedDescription
            }
            photoItem = nil
        }
    }

    // MARK: - 保存・共有の処理

    private func saveToPhotos() {
        guard !isSaving, canRender else { return }
        isSaving = true
        let snapshot = project.snapshot()
        let cover = project.cover
        let size = outputSize(for: snapshot)
        Task { @MainActor in
            do {
                let image = try await CoverRenderer.render(snapshot: snapshot, cover: cover, size: size)
                try await CoverRenderer.saveToPhotos(image)
                alertTitle = "保存しました"
                alertMessage = "表紙の画像を写真アプリに保存しました。"
            } catch {
                alertTitle = "保存できませんでした"
                alertMessage = "設定アプリでこのアプリの「写真」への追加を許可してから、もう一度「写真に保存」を押してください。\n\n詳細: " + error.localizedDescription
            }
            isSaving = false
        }
    }

    private func prepareShare() {
        guard !isPreparingShare, canRender else { return }
        isPreparingShare = true
        let snapshot = project.snapshot()
        let cover = project.cover
        let size = outputSize(for: snapshot)
        Task { @MainActor in
            do {
                let image = try await CoverRenderer.render(snapshot: snapshot, cover: cover, size: size)
                guard let data = image.jpegData(compressionQuality: 0.92) else {
                    throw CoverMakerError.cannotEncode
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cover_\(formatter.string(from: Date())).jpg")
                try data.write(to: url, options: .atomic)
                shareURL = url
            } catch {
                alertTitle = "画像を作れませんでした"
                alertMessage = "端末の空き容量を確かめて、もう一度お試しください。\n\n詳細: " + error.localizedDescription
            }
            isPreparingShare = false
        }
    }
}

private enum CoverMakerError: LocalizedError {
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .cannotEncode: return "画像を JPEG に変換できませんでした"
        }
    }
}
