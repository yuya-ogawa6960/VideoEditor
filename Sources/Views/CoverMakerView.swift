import SwiftUI
import PhotosUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

// =====================================================================
// サムネイル(カバー画像)作成画面。
// 動画の 1 コマ(または写真)を背景に、メモ風のカード(タイトル + 本文)を重ねて画像にする。
// 描画は CoverRenderer(別担当)。ここでは設定の編集・プレビュー・保存・共有だけを行う。
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
    @State private var alertTitle = ""
    @State private var alertMessage: String?
    /// アラートに「設定を開く」を出すか(写真の追加が許可されていないときだけ)
    @State private var alertOffersSettings = false
    /// Google Fonts を探す画面
    @State private var showsFontBrowser = false

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
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // 画面の高さの半分ほどを使って大きく見せる(横向き・キーボード表示中でも下の設定が見えるように割合で決める)
                    previewArea(maxHeight: max(120, geo.size.height * 0.5))
                    Form {
                        Group {
                            backgroundSection
                            textSection
                            cardSection
                            fontSection
                            outputSection
                        }
                        .listRowBackground(Color(white: 0.11))
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color(white: 0.07))
                }
            }
            .navigationTitle("サムネイル")
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
                scheduleRender()
            }
            .onChange(of: project.clips) {
                loadStrip()
                scheduleRender()
            }
            .onChange(of: photoItem) {
                handlePhotoPick()
            }
            .onDisappear {
                renderTask?.cancel()
                stripTask?.cancel()
            }
            // 「フォントを追加」。入れたフォントをそのまま選ぶ
            .sheet(isPresented: $showsFontBrowser) {
                GoogleFontsBrowser { name in
                    project.cover.fontName = name
                }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                if alertOffersSettings {
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - プレビュー

    private var previewAspect: CGFloat {
        if let preview, preview.size.width > 0, preview.size.height > 0 {
            return preview.size.width / preview.size.height
        }
        let size = previewSize(for: project.snapshot())
        return size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    private func previewArea(maxHeight: CGFloat) -> some View {
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
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 32))
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
        .frame(maxHeight: maxHeight)
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
                if !stripThumbnails.isEmpty {
                    thumbnailStrip
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("写真を選ぶ", systemImage: "photo")
            }
        } header: {
            Text("背景")
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
                        .frame(width: width / CGFloat(stripCount), height: 56)
                        .clipped()
                    }
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3, height: 60)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: min(max(indicatorX(width: width) - 1.5, 0), width - 3))
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
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("コマ")
        .accessibilityValue(MediaTimeText.precise(project.cover.frameTime))
        .accessibilityAdjustableAction { direction in
            let step = duration / Double(stripCount)
            switch direction {
            case .increment: project.cover.frameTime = min(duration, project.cover.frameTime + step)
            case .decrement: project.cover.frameTime = max(0, project.cover.frameTime - step)
            @unknown default: break
            }
        }
    }

    private func indicatorX(width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let p = min(max(project.cover.frameTime / duration, 0), 1)
        return CGFloat(p) * width
    }

    // MARK: - 文字

    private var textSection: some View {
        Section {
            TextField("タイトル", text: $project.cover.title)
            TextField("メモ", text: $project.cover.memoText, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("文字")
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
                                .padding(.vertical, 7)
                                .background(BrandStyle.surface,
                                            in: RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous))
                                .brandSelected(selected, cornerRadius: BrandStyle.Radius.chip)
                                .foregroundStyle(Color.white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 1)
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

            Toggle("動画と同じ色味", isOn: $project.cover.applyLook)
        } header: {
            Text("カード")
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
            // 一覧画面で、各フォントの名前をそのフォントで表示する(メニュー形式だとフォントが反映されない)
            .pickerStyle(.navigationLink)

            // Google Fonts から入れる(入れたフォントはそのまま選ばれる)
            Button {
                showsFontBrowser = true
            } label: {
                Label("フォントを追加", systemImage: "plus")
            }
        } header: {
            Text("フォント")
        }
    }

    // MARK: - 保存・共有

    private var outputSection: some View {
        let snapshot = project.snapshot()
        return Section {
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

            // 1 回押すだけで共有シートが開く。画像は送り先を選んだときに描く(CoverShareItem)
            ShareLink(item: CoverShareItem(snapshot: snapshot, cover: project.cover, size: outputSize(for: snapshot)),
                      preview: SharePreview(String(localized: "サムネイル"), image: Image(uiImage: preview ?? UIImage()))) {
                Label("共有", systemImage: "square.and.arrow.up")
            }
            .disabled(preview == nil)
        } header: {
            Text("保存・共有")
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
                renderError = String(localized: "プレビューを作れませんでした。背景のコマや写真を選び直してください。")
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
                    showAlert(title: String(localized: "写真を読み込めませんでした"),
                              message: String(localized: "この写真は読み込めません。別の写真を選んでください。"))
                }
            } catch {
                showAlert(title: String(localized: "写真を読み込めませんでした"),
                          message: String(localized: "もう一度「写真を選ぶ」から選び直してください。\n\n詳細: ") + error.localizedDescription)
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
                showAlert(title: String(localized: "保存しました"),
                          message: String(localized: "サムネイルを写真に保存しました。"))
            } catch CoverRendererError.photosAccessDenied {
                showAlert(title: String(localized: "保存できませんでした"),
                          message: String(localized: "「設定を開く」→「写真」で写真の追加を許可してから、もう一度「写真に保存」を押してください。\n\n詳細: ")
                              + CoverRendererError.photosAccessDenied.localizedDescription,
                          offersSettings: true)
            } catch {
                // 画像の作成や写真ライブラリ側の失敗。許可の問題ではないので「設定を開く」は出さない
                showAlert(title: String(localized: "保存できませんでした"),
                          message: String(localized: "もう一度「写真に保存」を押してください。\n\n詳細: ") + error.localizedDescription)
            }
            isSaving = false
        }
    }

    private func showAlert(title: String, message: String, offersSettings: Bool = false) {
        alertTitle = title
        alertOffersSettings = offersSettings
        alertMessage = message
    }
}

/// 共有シートに渡すサムネイル。送り先を選んだときに CoverRenderer で描いて JPEG にする(ボタン 1 回で共有できるように)
private struct CoverShareItem: Transferable {
    let snapshot: ProjectSnapshot
    let cover: CoverSettings
    let size: CGSize

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { item in
            let image = try await CoverRenderer.render(snapshot: item.snapshot, cover: item.cover, size: item.size)
            guard let data = image.jpegData(compressionQuality: 0.92) else {
                throw CoverMakerError.cannotEncode
            }
            return data
        }
        .suggestedFileName("cover.jpg")
    }
}

private enum CoverMakerError: LocalizedError {
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .cannotEncode: return String(localized: "画像を JPEG に変換できませんでした")
        }
    }
}
