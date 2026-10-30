import XCTest
import SwiftUI
@testable import VideoEditor

/// テレプロンプター(カメラ画面の台本)。長い台本でも 3 秒以内に描き終わり、見た目が変わっていないこと。
/// 1.12.76 で直した「文章の高さ → 余白 → 枠の高さ → …」の無限ループが戻ると、ここで「描き直しが止まりません」になる
@MainActor
final class TeleprompterOverlayTests: SnapshotTestCase {
    override func setUp() {
        super.setUp()
        TestFixtures.resetTeleprompterDefaults(script: TestFixtures.longScript)
    }

    private func overlay(script: String) -> some View {
        ZStack {
            Color.black
            TeleprompterOverlay(script: script, isScrolling: false, onEdit: {})
                .padding(12)
        }
    }

    /// iPhone の縦持ちでカメラ画面に出す大きさ(画面の高さの 36%)
    func testLongScriptPhonePortrait() {
        SnapshotTester.assertSnapshot(overlay(script: TestFixtures.longScript),
                                      named: "long-script-phone",
                                      layout: SnapshotLayout(size: CGSize(width: 402, height: 320)))
    }

    /// 狭く低い枠(横持ちの小さな iPhone など)
    func testLongScriptCompact() {
        SnapshotTester.assertSnapshot(overlay(script: TestFixtures.longScript),
                                      named: "long-script-compact",
                                      layout: SnapshotLayout(size: CGSize(width: 320, height: 180)))
    }

    /// iPhone Duo を開いたときの右側(縦に長い)
    func testLongScriptDuoColumn() {
        SnapshotTester.assertSnapshot(overlay(script: TestFixtures.longScript),
                                      named: "long-script-duo",
                                      layout: SnapshotLayout(size: CGSize(width: 480, height: 640)))
    }

    /// 台本が空のとき(「台本を入れる」だけ)
    func testEmptyScript() {
        SnapshotTester.assertSnapshot(overlay(script: ""),
                                      named: "empty-script",
                                      layout: SnapshotLayout(size: CGSize(width: 402, height: 120)))
    }

    /// 見張りそのものの確かめ: わざと描き直しが止まらない画面を渡すと、失敗として見つけられること
    func testRenderLoopDetectorCatchesFeedbackLoop() {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure("わざと無限ループさせた画面は「描き直しが止まりません」で失敗するはず", options: options) {
            SnapshotTester.render(FeedbackLoopView(),
                                  named: "feedback-loop-selftest",
                                  layout: SnapshotLayout(size: CGSize(width: 200, height: 200), settleTimeout: 1.5))
        }
    }
}

/// 自分の高さを測って @State に入れ、その分だけ余白を増やす(1.12.76 より前のテレプロンプターと同じ形の循環)
private struct FeedbackLoopView: View {
    @State private var measured: CGFloat = 0

    var body: some View {
        Color.black.overlay(alignment: .top) {
            Text(verbatim: "\(Int(measured))")
                .font(.largeTitle.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.top, measured.truncatingRemainder(dividingBy: 120))
                .padding(.bottom, measured)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
        }
    }
}
