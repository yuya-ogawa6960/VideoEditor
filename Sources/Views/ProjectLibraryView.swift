import SwiftUI
import UIKit
import UniformTypeIdentifiers

// =====================================================================
// プロジェクト一覧(CapCut のホーム画面に相当)と、一覧 ⇄ 編集画面を切り替えるルート。
// プロジェクトの書き出し(.videomania パッケージ)/ 読み込みもここから行う(ProjectPackage)。
// =====================================================================

// MARK: - ルート

/// アプリのルート。プロジェクトを開いていなければ一覧、開いていれば編集画面(ContentView)
struct RootView: View {
    @State private var openProjectID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let projectID = openProjectID {
                ContentView(projectID: projectID, onClose: {
                    openProjectID = nil
                })
                .id(projectID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ProjectLibraryView(onOpen: { meta in
                    openProjectID = meta.id
                })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: openProjectID)
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンドに回ったら、まとめ書き待ちの保存をすぐに書き出す
            if phase == .background {
                ProjectStore.flushAll()
                ProjectLibrary.shared.flush()
            }
        }
    }
}

// MARK: - 一覧

struct ProjectLibraryView: View {
    let onOpen: (ProjectMeta) -> Void

    private let library = ProjectLibrary.shared

    /// 「新しいプロジェクト」で動画の置き場所を選ぶ
    @State private var isChoosingMediaMode = false
    @State private var renameTarget: ProjectMeta?
    @State private var renameText = ""
    @State private var isRenaming = false

    @State private var deleteTarget: ProjectMeta?
    @State private var isDeleting = false

    // パッケージの書き出し / 読み込み
    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var exportingMeta: ProjectMeta?
    @State private var exportProgress: Double = 0
    @State private var packageShareItem: PackageShareItem?
    @State private var alertTitle = ""
    @State private var alertMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(onOpen: @escaping (ProjectMeta) -> Void) {
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    newProjectButton

                    if library.projects.isEmpty {
                        emptyHint
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text("最近のプロジェクト")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(library.projects.count) 件")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        grid
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("プロジェクト")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("プロジェクト読み込み", systemImage: "square.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                    }
                    .disabled(isImporting || exportingMeta != nil)
                    .accessibilityLabel("プロジェクト読み込み")
                }
            }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: [.folder, .package, .item],
                          allowsMultipleSelection: false) { result in
                handlePackageImport(result)
            }
            .sheet(item: $packageShareItem) { item in
                PackageShareSheet(item: item)
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
            .overlay {
                if isImporting || exportingMeta != nil {
                    packageProgressOverlay
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("名前を変更", isPresented: $isRenaming) {
            TextField("プロジェクト名", text: $renameText)
            Button("キャンセル", role: .cancel) {
                renameTarget = nil
            }
            Button("保存") {
                if let target = renameTarget {
                    library.rename(id: target.id, to: renameText)
                }
                renameTarget = nil
            }
        } message: {
            Text("新しいプロジェクト名を入力してください。")
        }
        .confirmationDialog(deleteTitle, isPresented: $isDeleting, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let target = deleteTarget {
                    library.delete(id: target.id)
                }
                deleteTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("このプロジェクトの編集内容とサムネイルを削除します。元に戻せません。\n(読み込んだ動画や写真のファイルはほかのプロジェクトでも使うため残ります)")
        }
    }

    private var deleteTitle: String {
        String(localized: "「\(deleteTarget?.name ?? "")」を削除しますか?")
    }

    // MARK: 部品

    private var newProjectButton: some View {
        Button {
            isChoosingMediaMode = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                Text("新しいプロジェクト")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(FacetedBrandBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新しいプロジェクト")
        .confirmationDialog("動画の置き場所", isPresented: $isChoosingMediaMode, titleVisibility: .visible) {
            Button("写真ライブラリから参照(容量を使わない)") {
                createProject(mediaMode: .photoLibrary)
            }
            Button("アプリに取り込む(写真を消しても安心)") {
                createProject(mediaMode: .appCopy)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「写真ライブラリから参照」は動画をコピーしないので iPhone の容量を使いません。ただし写真アプリで動画を消すと、このプロジェクトでも使えなくなります。\n「アプリに取り込む」は動画をアプリ内にコピーします。あとから編集画面の「その他」で変えられます。")
        }
        .task {
            // どのプロジェクトからも使われなくなった動画を消して容量を空ける(1 日以上前に取り込んだものだけ)
            _ = await Task.detached(priority: .utility) {
                ProjectStore.cleanUpUnusedMedia()
            }.value
        }
    }

    private func createProject(mediaMode: ProjectMediaMode) {
        let meta = library.create(mediaMode: mediaMode)
        onOpen(meta)
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("まだプロジェクトがありません")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 上の「新しいプロジェクト」を押す")
                Text("2. 「動画・写真を追加」で素材を選ぶ")
                Text("3. 編集して「書き出し」で写真アプリに保存")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text("編集内容は自動で保存されるので、途中でやめても大丈夫です。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button {
                isImporterPresented = true
            } label: {
                Label("プロジェクト読み込み", systemImage: "square.and.arrow.down")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isImporting || exportingMeta != nil)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(library.projects) { meta in
                ProjectCardView(meta: meta,
                                thumbnailRevision: library.thumbnailRevision,
                                onOpen: { onOpen(meta) },
                                onRename: { beginRename(meta) },
                                onDuplicate: { _ = library.duplicate(id: meta.id) },
                                onExport: { exportPackage(meta) },
                                onDelete: { beginDelete(meta) })
            }
        }
    }

    private var packageProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                if let meta = exportingMeta {
                    ProgressView(value: min(max(exportProgress, 0), 1))
                    Text("「\(meta.name)」を送る準備中… \(Int((min(max(exportProgress, 0), 1) * 100).rounded()))%")
                        .font(.callout)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                    Text("プロジェクトを受け取り中…")
                        .font(.callout)
                }
            }
            .padding(20)
            .frame(width: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: 操作

    private func beginRename(_ meta: ProjectMeta) {
        renameTarget = meta
        renameText = meta.name
        isRenaming = true
    }

    private func beginDelete(_ meta: ProjectMeta) {
        deleteTarget = meta
        isDeleting = true
    }

    private func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }

    // MARK: パッケージの書き出し / 読み込み

    /// プロジェクトを <名前>.videomania(フォルダ形式)にまとめて共有シートへ
    private func exportPackage(_ meta: ProjectMeta) {
        guard exportingMeta == nil, !isImporting else { return }
        // まとめ書き待ちの保存があれば先に書く
        ProjectStore.flush(projectID: meta.id)
        exportingMeta = meta
        exportProgress = 0
        Task { @MainActor in
            do {
                let url = try await ProjectPackage.export(projectID: meta.id, progress: { value in
                    Task { @MainActor in
                        exportProgress = value
                    }
                })
                exportingMeta = nil
                packageShareItem = PackageShareItem(url: url, name: meta.name)
            } catch {
                exportingMeta = nil
                showAlert(String(localized: "送る準備ができませんでした"),
                          String(localized: "端末の空き容量を確かめて、もう一度「プロジェクト書き出し」を押してください。\n\n詳細: ") + error.localizedDescription)
            }
        }
    }

    private func handlePackageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showAlert(String(localized: "ファイルを開けませんでした"),
                      String(localized: "もう一度「プロジェクト読み込み」から選び直してください。\n\n詳細: ") + error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            Task { @MainActor in
                do {
                    let meta = try await ProjectPackage.importPackage(from: url)
                    isImporting = false
                    showAlert(String(localized: "受け取りました"), String(localized: "「\(meta.name)」を一覧に追加しました。タップすると開けます。"))
                } catch {
                    isImporting = false
                    showAlert(String(localized: "受け取れませんでした"), String(localized: "「プロジェクト書き出し」で作ったファイル(名前が .videomania で終わるもの)を選んでください。送る途中で壊れた場合は、送り直してもらってください。\n\n詳細: ") + error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - パッケージ共有

/// 書き出した .videomania の共有シートに渡す項目
private struct PackageShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

private struct PackageShareSheet: View {
    let item: PackageShareItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("「\(item.name)」を送る準備ができました")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("AirDrop や「ファイル」アプリで別の端末に送ってください。受け取った端末では、プロジェクト一覧の「プロジェクト読み込み」から開けます。素材の動画・写真も一緒に入るため、ファイルは大きめです。\nファイル名: \(item.url.lastPathComponent)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: item.url) {
                    Label("送る・ファイルに保存", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle("プロジェクト書き出し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - カード

private struct ProjectCardView: View {
    let meta: ProjectMeta
    let thumbnailRevision: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                ProjectThumbnailView(projectID: meta.id, reloadKey: reloadKey)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        durationBadge
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(meta.name) を開く")

            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, -8)
                .padding(.trailing, -8)
                .accessibilityLabel("その他の操作")
            }
        }
        .contextMenu {
            menuItems
        }
    }

    private var reloadKey: String {
        "\(thumbnailRevision)-\(meta.updatedAt.timeIntervalSinceReferenceDate)"
    }

    private var subtitle: String {
        let date = ProjectDateText.relative(meta.updatedAt)
        return date + String(localized: " ・ \(meta.clipCount) クリップ")
    }

    private var durationBadge: some View {
        Text(ProjectDurationText.mss(meta.duration))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
            .padding(6)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRename) {
            Label("名前を変更", systemImage: "pencil")
        }
        Button(action: onDuplicate) {
            Label("複製", systemImage: "plus.square.on.square")
        }
        Button(action: onExport) {
            Label("プロジェクト書き出し", systemImage: "shippingbox")
        }
        Button(role: .destructive, action: onDelete) {
            Label("削除", systemImage: "trash")
        }
    }
}

// MARK: - サムネイル

private struct ProjectThumbnailView: View {
    let projectID: UUID
    /// 変わるとファイルを読み直す
    let reloadKey: String

    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .clipped()
            .task(id: reloadKey) {
                image = ProjectStore.loadThumbnail(projectID: projectID)
            }
    }
}

// MARK: - 時間表示

private enum ProjectDurationText {
    /// m:ss
    static func mss(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

// MARK: - 日付表示

private enum ProjectDateText {
    /// 「今日 14:05」「昨日 9:30」「3日前」「2025/10/01」のような、わかりやすい日付
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return String(localized: "今日 ") + time
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨日 ") + time
        }
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let days: Int = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if days >= 2 && days < 7 {
            return String(localized: "\(days)日前")
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
