import SwiftUI
import UIKit

// =====================================================================
// 「書き出した動画の整理」
//
// Documents/Exports(「ファイル」アプリの「このiPhone内 › Video Mania」に出るフォルダ)の動画を
// 新しい順に並べ、要らないものを消す。
//   - 上に本数と合計の大きさ
//   - 行: サムネイル・名前・日付・長さ・大きさ。スワイプで削除。「共有」でそのまま送れる
//   - 右上のメニュー: 「選択して削除」(複数を選んで消す)、「古いものをまとめて削除」(7 日より前 / 30 日より前 / すべて)
//   - 消す前に本数と大きさを出して確認する。履歴に載っているものは履歴からも消える(ExportFileStore.delete)
// 「設定」の行と、書き出しが終わった画面の「書き出した動画を整理」から開く。
// =====================================================================

struct ExportFilesView: View {
    @State private var files: [ExportedFile] = []
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    /// 消そうとしているファイル(確認ダイアログを出す)
    @State private var pendingDeletion: [ExportedFile] = []
    /// 「古いものをまとめて削除」で対象が無かったとき
    @State private var showsNothingToDelete: Bool = false

    private var totalSizeText: String {
        ExportFileStore.sizeText(ExportFileStore.totalSize(of: files))
    }

    private var isSelecting: Bool { editMode == .active }

    var body: some View {
        List(selection: $selection) {
            Section {
                if files.isEmpty {
                    Text("書き出した動画はありません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        ExportFileRow(file: file)
                            .tag(file.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = [file]
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                ShareLink(item: file.url) {
                                    Label("共有", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    pendingDeletion = [file]
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("\(files.count) 本・合計 \(totalSizeText)")
            } footer: {
                Text("ここにある動画は「ファイル」アプリの「このiPhone内 › Video Mania › Exports」にも出ます。消すと元に戻せません")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("書き出した動画の整理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("キャンセル") {
                        selection = []
                        editMode = .inactive
                    }
                } else {
                    Menu {
                        Button {
                            selection = []
                            editMode = .active
                        } label: {
                            Label("選択して削除", systemImage: "checkmark.circle")
                        }
                        Menu {
                            Button("7 日より前") { prepareOldDeletion(days: 7) }
                            Button("30 日より前") { prepareOldDeletion(days: 30) }
                            Button("すべて", role: .destructive) { prepareOldDeletion(days: nil) }
                        } label: {
                            Label("古いものをまとめて削除", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(files.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .confirmationDialog(deletionTitle, isPresented: deletionPresented, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                let targets = pendingDeletion
                pendingDeletion = []
                ExportFileStore.delete(targets)
                selection = []
                editMode = .inactive
                reload()
            }
            Button("キャンセル", role: .cancel) {
                pendingDeletion = []
            }
        } message: {
            Text("消した動画は元に戻せません")
        }
        .alert("対象の動画はありません", isPresented: $showsNothingToDelete) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("この起動中に書き出した動画は消しません")
        }
        .onAppear { reload() }
    }

    /// 複数選択中の下のバー
    private var selectionBar: some View {
        let selected = files.filter { selection.contains($0.id) }
        let size = ExportFileStore.sizeText(ExportFileStore.totalSize(of: selected))
        return HStack(spacing: 12) {
            Button {
                if selection.count == files.count {
                    selection = []
                } else {
                    selection = Set(files.map(\.id))
                }
            } label: {
                Text(selection.count == files.count ? "選択を解除" : "すべて選択")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            Spacer()
            Button(role: .destructive) {
                pendingDeletion = selected
            } label: {
                Label("\(selected.count) 本を削除(\(size))", systemImage: "trash")
                    .font(.headline)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } })
    }

    /// 確認ダイアログの題(本数と大きさ)
    private var deletionTitle: String {
        let count = pendingDeletion.count
        let size = ExportFileStore.sizeText(ExportFileStore.totalSize(of: pendingDeletion))
        if count == 1, let file = pendingDeletion.first {
            return String(localized: "「\(file.name)」(\(size))を削除しますか?")
        }
        return String(localized: "\(count) 本(\(size))を削除しますか?")
    }

    /// 「古いものをまとめて削除」。days が nil なら(この起動中に書き出したもの以外)すべて
    private func prepareOldDeletion(days: Int?) {
        let targets = ExportFileStore.files(olderThanDays: days, in: files)
        if targets.isEmpty {
            showsNothingToDelete = true
        } else {
            pendingDeletion = targets
        }
    }

    private func reload() {
        files = ExportFileStore.listFiles()
        selection = selection.filter { id in files.contains { $0.id == id } }
    }
}

// MARK: - 1 行

private struct ExportFileRow: View {
    let file: ExportedFile

    @State private var thumbnail: UIImage?
    @State private var duration: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.date, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(Self.durationString(duration))
                        .monospacedDigit()
                    Text(verbatim: "·")
                    Text(ExportFileStore.sizeText(file.size))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("共有"))
        }
        .padding(.vertical, 2)
        .task(id: file.id) {
            if let cached = ExportThumbnailCache.shared.cached(file.url) {
                thumbnail = cached
            }
            let result = await ExportThumbnailCache.shared.load(file)
            if !Task.isCancelled {
                thumbnail = result.image
                duration = result.duration
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(Color(white: 0.2))
                Image(systemName: file.isVideo ? "film" : "waveform")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 秒 → "h:mm:ss" / "m:ss"
    private static func durationString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
