import XCTest
import SwiftUI
import PhotosUI
@testable import VideoEditor

/// iPhone Duo を開いたときの右の列(EditorToolbar の .vertical)。
/// グループを開いたとき「‹ 戻る」が時刻・電池の場所(上の余白)に隠れず、列の中に見えていること。
///
/// 戻るボタンだけを見分けられるよう、グループの中の項目は「削除」扱い(赤い文字)にしてある。
/// 白い画素 = 戻るボタン(‹ とグループ名)だけ
@MainActor
final class EditorToolbarTests: SnapshotTestCase {
    /// 右の列の上で空けておく時刻・電池の場所(ContentView と同じ値)
    private var statusAllowance: CGFloat { ContentView.sideColumnStatusAllowance }

    private static let groupID = "group-編集"

    private func items() -> [EditorToolItem] {
        let children: [EditorToolItem] = [
            ("分割", "scissors"), ("速度", "speedometer"), ("音量", "speaker.wave.2"),
            ("切り抜き", "crop"), ("回転", "rotate.right"), ("反転", "arrow.left.and.right.righttriangle.left.righttriangle.right"),
            ("フィルタ", "camera.filters"), ("調整", "slider.horizontal.3"), ("複製", "plus.square.on.square"),
            ("置き換え", "arrow.triangle.2.circlepath"), ("逆再生", "backward"), ("フリーズ", "snowflake"),
            ("削除", "trash"),
        ].map { title, icon in
            EditorToolItem(title, systemImage: icon, destructive: true, action: {})
        }
        return [
            .group("編集", systemImage: "scissors", id: Self.groupID, items: children),
            EditorToolItem("テキスト", systemImage: "textformat", action: {}),
            .more([EditorToolItem("書き出し", systemImage: "square.and.arrow.up", action: {})]),
            .settings([EditorToolItem("比率", systemImage: "aspectratio", action: {})]),
        ]
    }

    private func column(width: CGFloat) -> some View {
        EditorToolbar(items: items(),
                      onBack: {},
                      onDisabledTap: { _ in },
                      groupPath: .constant([Self.groupID]),
                      pickerItems: .constant([]),
                      overlayPickerItems: .constant([]),
                      replacePickerItem: .constant(nil),
                      extractAudioPickerItem: .constant(nil),
                      slideshowPickerItems: .constant([]),
                      axis: .vertical)
            .frame(width: width)
    }

    func testVerticalGroup72pt() {
        check(width: 72, name: "vertical-group-72")
    }

    func testVerticalGroup107pt() {
        check(width: 107, name: "vertical-group-107")
    }

    private func check(width: CGFloat, name: String, file: StaticString = #filePath, line: UInt = #line) {
        let layout = SnapshotLayout(size: CGSize(width: width, height: 760),
                                    safeArea: EdgeInsets(top: statusAllowance, leading: 0, bottom: 20, trailing: 0))
        guard let shot = SnapshotTester.render(column(width: width), named: name, layout: layout, file: file, line: line) else { return }

        let safe = shot.safeRect
        // 1. 戻るボタン(白)が見える
        guard let back = shot.pixels.boundingBox(where: { PixelBuffer.isWhite($0) }) else {
            XCTFail("\(name): 「‹ 戻る」が見えません(白い画素がありません)", file: file, line: line)
            SnapshotTester.compare(shot, named: name, file: file, line: line)
            return
        }
        // 2. 時刻・電池の場所(上の余白)にも、下の余白にもはみ出していない
        XCTAssertGreaterThanOrEqual(back.minY, safe.minY,
                                    "\(name): 「‹ 戻る」が時刻・電池の場所に入っています(上端 \(back.minY)pt < \(safe.minY)pt)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(back.maxY, safe.maxY + 0.5,
                                 "\(name): 「‹ 戻る」が列の下にはみ出しています(下端 \(back.maxY)pt > \(safe.maxY)pt)",
                                 file: file, line: line)
        // 3. 横も列の中に収まっている(72pt でも切れない)
        XCTAssertGreaterThanOrEqual(back.minX, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(back.maxX, width + 0.5, file: file, line: line)
        // 4. ‹ だけでなく、グループ名も出ている(ある程度の大きさがある)
        XCTAssertGreaterThanOrEqual(back.height, 20, "\(name): 戻るボタンが小さすぎます(\(back.height)pt)", file: file, line: line)
        // 5. 上の余白には何も描かない(背景だけ)
        let statusBand = CGRect(x: 0, y: 0, width: width, height: safe.minY)
        let drawnInStatus = shot.pixels.count(in: statusBand) { c in
            PixelBuffer.isWhite(c, threshold: 120) || PixelBuffer.isReddish(c, margin: 60)
        }
        XCTAssertEqual(drawnInStatus, 0, "\(name): 時刻・電池の場所に項目が描かれています", file: file, line: line)
        // 6. 項目(赤)も見えている
        XCTAssertGreaterThan(shot.pixels.count(in: safe) { PixelBuffer.isReddish($0, margin: 60) }, 0,
                             "\(name): グループの項目が見えません", file: file, line: line)

        SnapshotTester.compare(shot, named: name, file: file, line: line)
    }
}
