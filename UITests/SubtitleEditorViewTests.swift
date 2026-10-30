import XCTest
import SwiftUI
@testable import VideoEditor

/// キャプションの一覧(SubtitleEditorView)。要確認の行(赤い背景と「!」・理由)が出ていて、3 秒以内に落ち着くこと
@MainActor
final class SubtitleEditorViewTests: SnapshotTestCase {
    private func project() -> EditorProject {
        let project = EditorProject()
        // id を固定する(描き直しのたびに同じ並び・同じ絵になるように)
        func cue(_ n: Int, _ start: Double, _ end: Double, _ text: String, doubtful: [String] = []) -> SubtitleCue {
            SubtitleCue(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                        start: start, end: end, text: text, doubtfulWords: doubtful)
        }
        project.subtitles = [
            cue(1, 0.0, 2.4, "今日は編集のコツを紹介します"),
            cue(2, 2.4, 4.8, "まずは素材を並べます", doubtful: ["素材"]),
            cue(3, 4.8, 7.0, "まずは素材を並べます"),
            cue(4, 7.0, 7.6, "テンポよく切っていくのがだいじです"),
            cue(5, 7.6, 7.8, "はい"),
            cue(6, 7.8, 10.0, "ああああああああ"),
            cue(7, 10.0, 12.5, "最後に字幕を入れて書き出します"),
            cue(8, 12.5, 15.0, "ご視聴ありがとうございました"),
        ]
        return project
    }

    private var layout: SnapshotLayout {
        SnapshotLayout(size: CGSize(width: 402, height: 1600),
                       safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
                       minimumWait: 1.0)
    }

    /// 要確認の判定(この並びで 6 行が要確認になること。判定が変わったら画像より先にここで気づく)
    func testFixtureHasFlaggedRows() {
        let issues = CaptionIssueCheck.issues(in: project().subtitles)
        XCTAssertEqual(issues.count, 6, "要確認の行の数が変わりました: \(issues)")
    }

    /// 一覧(タップで再生位置へ・鉛筆で編集)
    func testCaptionListWithFlaggedRows() {
        let view = SubtitleEditorView(project: project(), player: PlayerController())
        guard let shot = SnapshotTester.assertSnapshot(view, named: "caption-list", layout: layout) else { return }
        assertFlaggedRowsVisible(shot)
    }

    /// 「キャプションを一覧で直す」から開いたとき(その場で直すモード)
    func testInlineCaptionListWithFlaggedRows() {
        let view = SubtitleEditorView(project: project(), player: PlayerController(), initialSection: .list)
        guard let shot = SnapshotTester.assertSnapshot(view, named: "caption-list-inline", layout: layout) else { return }
        assertFlaggedRowsVisible(shot)
    }

    private func assertFlaggedRowsVisible(_ shot: RenderedSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        // 赤い背景の行(赤 0.22 を重ねた色)と赤い「!」・理由の文字
        let red = shot.pixels.count { PixelBuffer.isReddish($0, margin: 25) }
        XCTAssertGreaterThan(red, 20_000, "要確認の行の赤い背景が見えません(赤い画素 \(red))", file: file, line: line)
    }
}
