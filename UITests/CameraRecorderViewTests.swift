import XCTest
import SwiftUI
import AVFoundation
@testable import VideoEditor

/// カメラ画面(CameraRecorderView)のプレビュー中の並び。本物のカメラは使わない:
/// シミュレータにはカメラが無いので、権限を与えておくと CameraRecorder は「この端末ではカメラを使えません」で
/// 開始に失敗し、プレビュー(live)の画面に説明を重ねた決まった状態になる。この状態で
///   - 縦持ち(iPhone)
///   - 縦横とも regular の横持ち(iPhone Duo を開いたとき: 左にプレビュー、右に台本と操作)
/// を描き、3 秒以内に落ち着くこと・見た目が変わっていないことを確かめる。
/// 権限はワークフローが `xcrun simctl privacy … grant camera / microphone` で先に与える(無ければスキップ)
@MainActor
final class CameraRecorderViewTests: SnapshotTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("カメラの権限がありません。先に `xcrun simctl privacy booted grant camera com.yuyaogawa6960.videomania` を実行してください(権限のダイアログでテストが止まらないよう、ここでは聞きません)")
        }
        guard AVAudioApplication.shared.recordPermission != .undetermined else {
            throw XCTSkip("マイクの権限が未決定です。先に `xcrun simctl privacy booted grant microphone com.yuyaogawa6960.videomania` を実行してください")
        }
        TestFixtures.resetTeleprompterDefaults(script: TestFixtures.longScript)
    }

    private func camera() -> some View {
        CameraRecorderView(aspect: .portrait9x16, onUse: { _ in })
    }

    /// iPhone の縦持ち(時刻・ホームバーの余白つき)
    func testLivePortrait() {
        let layout = SnapshotLayout(size: CGSize(width: 402, height: 874),
                                    safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
                                    minimumWait: 1.5,
                                    horizontalSizeClass: .compact,
                                    verticalSizeClass: .regular)
        SnapshotTester.assertSnapshot(camera(), named: "live-portrait", layout: layout)
    }

    /// 縦横とも regular の横持ち(左にプレビュー、右に台本と操作)
    func testLiveRegularLandscape() {
        let layout = SnapshotLayout(size: CGSize(width: 1180, height: 820),
                                    safeArea: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
                                    minimumWait: 1.5,
                                    horizontalSizeClass: .regular,
                                    verticalSizeClass: .regular)
        guard let shot = SnapshotTester.assertSnapshot(camera(), named: "live-regular-landscape", layout: layout) else { return }
        // 右側(プレビューの 58% より右)に台本と操作が出ている(白い文字・ボタンがある)
        let right = CGRect(x: 1180 * 0.6, y: 0, width: 1180 * 0.4, height: 820)
        XCTAssertGreaterThan(shot.pixels.count(in: right) { PixelBuffer.isWhite($0) }, 500,
                             "右側に台本と操作が出ていません(左右に分かれていない?)")
    }
}
