import SwiftUI

/// 1クリップの情報(NavigationStack 内で表示する)。
/// 編集の操作(トリミング・速度・ミュート・カラー・マルチカメラ・複製・削除)は、
/// ツールバーとパネルにそろえたのでここには置かない。ツールバーからの入口もやめた
struct ClipEditorView: View {
    let project: EditorProject
    let player: PlayerController
    let clipID: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let clip = project.clips.first(where: { $0.id == clipID }) {
                Form {
                    Section("情報") {
                        LabeledContent("名前", value: clip.name)
                        LabeledContent("元の長さ", value: MediaTimeText.precise(clip.duration))
                        LabeledContent("長さ", value: MediaTimeText.precise(clip.outputDuration))
                    }
                }
            } else {
                ContentUnavailableView("クリップが見つかりません", systemImage: "film")
            }
        }
        .navigationTitle("クリップ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") { dismiss() }
            }
        }
        .onChange(of: project.index(of: clipID) == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }
}
