import XCTest
import SwiftUI
import UIKit

// =====================================================================
// 最小のスナップショット補助(外部パッケージなし)
//
// SwiftUI の画面をシミュレータの窓(UIWindow)に載せ、
//   1. 描き直しが落ち着く(2 回続けて同じ絵になる)まで待つ。settleTimeout(既定 3 秒)を超えたら
//      「描き直しが止まらない」(レイアウトの無限ループ)として失敗。
//      あわせて別スレッドからメインスレッドの応答を見張り、settleTimeout のあいだ応答が無ければ固まりとして失敗
//      (完全に固まって戻ってこないときは xcodebuild が 1 分で打ち切る)。
//   2. 落ち着いた絵を PNG にして参照画像(UITests/__Snapshots__/<テストファイル名>/<名前>.png)と見比べる。
//      画素ごとの差が perPixel 以下なら同じ、違う画素の割合が maxDifferentFraction 以下なら合格。
//
// 参照画像が無いときは記録して合格にする(初回。ワークフローがそのままコミットする)。
// 環境変数 SNAPSHOT_RECORD=1(xcodebuild には TEST_RUNNER_SNAPSHOT_RECORD=1)で全部を記録し直す。
// 失敗したときの実際の絵・参照・差分は SNAPSHOT_ARTIFACTS(無ければ一時フォルダ)に書き出し、xcresult にも添付する。
// =====================================================================

/// 1 枚のスナップショットの条件
struct SnapshotLayout {
    /// 描く大きさ(pt)
    var size: CGSize
    /// 時刻・電池などが出る場所として空ける余白(セーフエリア)。機種に関係なく固定で与える
    var safeArea: EdgeInsets = EdgeInsets()
    /// 比べ始める前に最低限待つ時間(非同期で状態が変わる画面のため)
    var minimumWait: TimeInterval = 0.3
    /// 画面が落ち着くのを待つ上限。超えたら「描き直しが止まらない」として失敗
    var settleTimeout: TimeInterval = 3
    /// 横・縦のサイズクラス(nil なら窓のまま)
    var horizontalSizeClass: UserInterfaceSizeClass? = nil
    var verticalSizeClass: UserInterfaceSizeClass? = nil
    /// 絵の倍率(参照画像と同じにする。機種の倍率に依らないよう固定)
    var scale: CGFloat = 2

    init(size: CGSize,
         safeArea: EdgeInsets = EdgeInsets(),
         minimumWait: TimeInterval = 0.3,
         settleTimeout: TimeInterval = 3,
         horizontalSizeClass: UserInterfaceSizeClass? = nil,
         verticalSizeClass: UserInterfaceSizeClass? = nil) {
        self.size = size
        self.safeArea = safeArea
        self.minimumWait = minimumWait
        self.settleTimeout = settleTimeout
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
    }
}

/// 参照画像との違いをどこまで許すか
struct SnapshotTolerance {
    /// 1 画素の各チャンネル(0〜255)の差がこれ以下なら同じ画素とみなす(文字の縁のにじみなど)
    var perPixel: Int = 24
    /// 違う画素の割合がこれ以下なら合格(0.005 = 0.5%)
    var maxDifferentFraction: Double = 0.005

    init(perPixel: Int = 24, maxDifferentFraction: Double = 0.005) {
        self.perPixel = perPixel
        self.maxDifferentFraction = maxDifferentFraction
    }
}

/// 描いた絵の画素(RGBA、各 8 bit)
struct PixelBuffer: Equatable {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init?(image: UIImage, scale: CGFloat) {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.width = width
        self.height = height
        self.scale = scale
        self.bytes = bytes
    }

    /// 画素(px)の RGB(範囲外は黒)
    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0) }
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// 白に近い画素(RGB がどれも threshold 以上)
    static func isWhite(_ c: (r: Int, g: Int, b: Int), threshold: Int = 200) -> Bool {
        min(c.r, min(c.g, c.b)) >= threshold
    }

    /// 赤みのある画素(赤が緑・青より margin 以上強い)
    static func isReddish(_ c: (r: Int, g: Int, b: Int), margin: Int = 25) -> Bool {
        c.r >= c.g + margin && c.r >= c.b + margin
    }

    /// pt 単位の長方形を px の範囲に
    private func pixelRange(_ rect: CGRect) -> (x: Range<Int>, y: Range<Int>)? {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0..<x1, y0..<y1)
    }

    /// pt 単位の長方形の中で、条件に合う画素の数(rect が nil なら全体)
    func count(in rect: CGRect? = nil, where matches: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
        let full = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        guard let range = pixelRange(rect ?? full) else { return 0 }
        var n = 0
        for y in range.y {
            for x in range.x where matches(rgb(x: x, y: y)) {
                n += 1
            }
        }
        return n
    }

    /// 条件に合う画素をすべて囲む長方形(pt)。無ければ nil
    func boundingBox(where matches: ((r: Int, g: Int, b: Int)) -> Bool) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where matches(rgb(x: x, y: y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}

/// 落ち着いた画面の絵(参照画像との比較のあとで、位置の確かめなどに使える)
struct RenderedSnapshot {
    let image: UIImage
    let pixels: PixelBuffer
    let layout: SnapshotLayout

    /// セーフエリアの内側(pt)
    var safeRect: CGRect {
        CGRect(x: layout.safeArea.leading,
               y: layout.safeArea.top,
               width: layout.size.width - layout.safeArea.leading - layout.safeArea.trailing,
               height: layout.size.height - layout.safeArea.top - layout.safeArea.bottom)
    }
}

/// スナップショットのテストの土台(アニメーションを止め、固まったときの打ち切り時間を決める)
@MainActor
class SnapshotTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        // 完全に固まったとき(メインスレッドが戻ってこない)の打ち切り。xcodebuild に -test-timeouts-enabled YES が要る
        executionTimeAllowance = 60
        UIView.setAnimationsEnabled(false)
    }
}

@MainActor
enum SnapshotTester {
    // MARK: - 置き場所

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// 参照画像を全部記録し直す(TEST_RUNNER_SNAPSHOT_RECORD=1)
    static var isRecording: Bool { environment["SNAPSHOT_RECORD"] == "1" }

    /// 失敗したときの絵を書き出すフォルダ(TEST_RUNNER_SNAPSHOT_ARTIFACTS。無ければ一時フォルダ)
    static var artifactsDirectory: URL {
        if let path = environment["SNAPSHOT_ARTIFACTS"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VideoEditorUITests", isDirectory: true)
    }

    /// 参照画像のフォルダ: <テストファイルのフォルダ>/__Snapshots__/<テストファイル名>/
    static func snapshotsDirectory(for file: StaticString) -> URL {
        let fileURL = URL(fileURLWithPath: "\(file)")
        let base = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(base, isDirectory: true)
    }

    // MARK: - 描く

    /// 画面を窓に載せ、落ち着くまで待って絵にする(参照画像とは比べない)。
    /// 落ち着かない・固まったときは失敗を記録して nil
    @discardableResult
    static func render<Content: View>(_ content: Content,
                                      named name: String,
                                      layout: SnapshotLayout,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) -> RenderedSnapshot? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window: UIWindow = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: layout.size)
        window.backgroundColor = .black
        window.overrideUserInterfaceStyle = .dark

        let hosting = UIHostingController(rootView: wrap(content, layout: layout))
        // 窓(機種)のセーフエリアは使わず、layout.safeArea だけを使う(機種が違っても同じ絵になるように)
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        window.setNeedsLayout()
        window.layoutIfNeeded()

        let watchdog = MainThreadWatchdog(limit: layout.settleTimeout, name: name)
        watchdog.start()
        defer { watchdog.stop() }

        // 最低限待つ(.task や DispatchQueue.main.asyncAfter で状態が変わる画面のため)
        pump(for: layout.minimumWait)

        // 2 回続けて同じ絵になるまで待つ
        let start = Date()
        var previous: PixelBuffer?
        var settledImage: UIImage?
        var settledPixels: PixelBuffer?
        var renders = 0
        while Date().timeIntervalSince(start) < layout.settleTimeout {
            pump(for: 0.1)
            let image = snapshotImage(of: window, scale: layout.scale)
            renders += 1
            guard let pixels = PixelBuffer(image: image, scale: layout.scale) else {
                XCTFail("\(name): 絵を画素に変換できませんでした", file: file, line: line)
                return nil
            }
            if let previous, previous == pixels {
                settledImage = image
                settledPixels = pixels
                break
            }
            previous = pixels
        }
        let blocked = watchdog.maximumGap
        guard let image = settledImage, let pixels = settledPixels else {
            let message = "\(name): \(String(format: "%.1f", layout.settleTimeout)) 秒たっても描き直しが止まりません(\(renders) 回描いて毎回違う絵)。"
                + "レイアウトの無限ループ(onGeometryChange → @State → 余白 → 高さ… の循環)か、止まらないアニメーションです。"
                + " メインスレッドの最長停止: \(String(format: "%.2f", blocked)) 秒"
            XCTFail(message, file: file, line: line)
            if let previous {
                writeArtifact(previous, name: "\(name).unsettled")
            }
            return nil
        }
        if blocked >= layout.settleTimeout {
            XCTFail("\(name): メインスレッドが \(String(format: "%.1f", blocked)) 秒応答しませんでした(固まり)", file: file, line: line)
        }
        return RenderedSnapshot(image: image, pixels: pixels, layout: layout)
    }

    /// 参照画像と比べる。無ければ記録して合格(初回)。落ち着いた絵を返す(失敗しても絵が取れていれば返す)
    @discardableResult
    static func assertSnapshot<Content: View>(_ content: Content,
                                              named name: String,
                                              layout: SnapshotLayout,
                                              tolerance: SnapshotTolerance = SnapshotTolerance(),
                                              file: StaticString = #filePath,
                                              line: UInt = #line) -> RenderedSnapshot? {
        guard let rendered = render(content, named: name, layout: layout, file: file, line: line) else { return nil }
        compare(rendered, named: name, tolerance: tolerance, file: file, line: line)
        return rendered
    }

    /// 取った絵を参照画像と比べる(render の結果に対して)
    static func compare(_ rendered: RenderedSnapshot,
                        named name: String,
                        tolerance: SnapshotTolerance = SnapshotTolerance(),
                        file: StaticString = #filePath,
                        line: UInt = #line) {
        let directory = snapshotsDirectory(for: file)
        let referenceURL = directory.appendingPathComponent("\(name).png")
        guard let actualPNG = rendered.image.pngData() else {
            XCTFail("\(name): PNG にできませんでした", file: file, line: line)
            return
        }

        let exists = FileManager.default.fileExists(atPath: referenceURL.path)
        if isRecording || !exists {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try actualPNG.write(to: referenceURL)
            } catch {
                XCTFail("\(name): 参照画像を書けませんでした: \(error)", file: file, line: line)
                return
            }
            writeArtifact(actualPNG, name: "\(name).recorded")
            attach(rendered.image, name: "\(name) (recorded)")
            let relative = relativePath(referenceURL)
            if isRecording {
                print("::notice::スナップショットを記録し直しました: \(relative)")
            } else {
                print("::warning::参照画像が無かったので記録しました(このテストは合格扱い): \(relative)。中身を確かめてコミットしてください")
            }
            return
        }

        guard let referenceData = try? Data(contentsOf: referenceURL),
              let referenceImage = UIImage(data: referenceData, scale: rendered.layout.scale),
              let reference = PixelBuffer(image: referenceImage, scale: rendered.layout.scale) else {
            XCTFail("\(name): 参照画像を読めませんでした: \(referenceURL.path)", file: file, line: line)
            return
        }
        let actual = rendered.pixels
        guard reference.width == actual.width, reference.height == actual.height else {
            writeFailure(actual: actualPNG, reference: referenceData, diff: nil, name: name)
            attach(rendered.image, name: "\(name) (actual)")
            attach(referenceImage, name: "\(name) (reference)")
            XCTFail("\(name): 大きさが違います(参照 \(reference.width)×\(reference.height)px、実際 \(actual.width)×\(actual.height)px)。"
                    + " 記録し直すなら TEST_RUNNER_SNAPSHOT_RECORD=1", file: file, line: line)
            return
        }

        let result = diff(actual: actual, reference: reference, perPixel: tolerance.perPixel)
        let fraction = Double(result.differentPixels) / Double(max(1, actual.width * actual.height))
        if fraction > tolerance.maxDifferentFraction {
            let diffImage = result.image
            writeFailure(actual: actualPNG, reference: referenceData, diff: diffImage?.pngData(), name: name)
            attach(rendered.image, name: "\(name) (actual)")
            attach(referenceImage, name: "\(name) (reference)")
            if let diffImage { attach(diffImage, name: "\(name) (diff)") }
            XCTFail("\(name): 参照画像と違います(違う画素 \(String(format: "%.2f", fraction * 100))% > 許容 \(String(format: "%.2f", tolerance.maxDifferentFraction * 100))%)。"
                    + " 実際・参照・差分: \(artifactsDirectory.path)/\(name).*.png。見た目の変更が正しければ TEST_RUNNER_SNAPSHOT_RECORD=1 で記録し直す",
                    file: file, line: line)
        }
    }

    // MARK: - 中身

    /// セーフエリアとサイズクラスを与えた画面
    private static func wrap<Content: View>(_ content: Content, layout: SnapshotLayout) -> AnyView {
        var view = AnyView(
            content
                .safeAreaPadding(layout.safeArea)
                .frame(width: layout.size.width, height: layout.size.height)
                .preferredColorScheme(.dark)
        )
        if let h = layout.horizontalSizeClass {
            view = AnyView(view.environment(\.horizontalSizeClass, h))
        }
        if let v = layout.verticalSizeClass {
            view = AnyView(view.environment(\.verticalSizeClass, v))
        }
        return view
    }

    /// メインの RunLoop を回して描き直し・非同期の処理を進める
    private static func pump(for seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        repeat {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        } while Date() < until
    }

    /// 窓の絵(Core Animation の層をそのまま描く。画面の外にはみ出す大きさでも描ける)
    private static func snapshotImage(of window: UIWindow, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(window.bounds)
            window.layer.render(in: context.cgContext)
        }
    }

    private struct DiffResult {
        let differentPixels: Int
        let image: UIImage?
    }

    /// 画素ごとの差。違う画素は赤、同じ画素は暗くした実際の絵
    private static func diff(actual: PixelBuffer, reference: PixelBuffer, perPixel: Int) -> DiffResult {
        let width = actual.width
        let height = actual.height
        var output = [UInt8](repeating: 255, count: width * height * 4)
        var different = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let dr = abs(Int(actual.bytes[i]) - Int(reference.bytes[i]))
            let dg = abs(Int(actual.bytes[i + 1]) - Int(reference.bytes[i + 1]))
            let db = abs(Int(actual.bytes[i + 2]) - Int(reference.bytes[i + 2]))
            if max(dr, max(dg, db)) > perPixel {
                different += 1
                output[i] = 255
                output[i + 1] = 0
                output[i + 2] = 0
            } else {
                output[i] = actual.bytes[i] / 3
                output[i + 1] = actual.bytes[i + 1] / 3
                output[i + 2] = actual.bytes[i + 2] / 3
            }
            output[i + 3] = 255
        }
        let image: UIImage? = output.withUnsafeMutableBytes { raw -> UIImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = context.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
        return DiffResult(differentPixels: different, image: image)
    }

    // MARK: - 書き出し・添付

    private static func writeFailure(actual: Data, reference: Data, diff: Data?, name: String) {
        writeArtifact(actual, name: "\(name).actual")
        writeArtifact(reference, name: "\(name).reference")
        if let diff { writeArtifact(diff, name: "\(name).diff") }
    }

    private static func writeArtifact(_ pixels: PixelBuffer, name: String) {
        guard let data = pixels.bytes.withUnsafeBytes({ raw -> Data? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: UnsafeMutableRawPointer(mutating: base),
                                          width: pixels.width,
                                          height: pixels.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: pixels.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = context.makeImage() else { return nil }
            return UIImage(cgImage: cg).pngData()
        }) else { return }
        writeArtifact(data, name: name)
    }

    private static func writeArtifact(_ data: Data, name: String) {
        let directory = artifactsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        } catch {
            print("スナップショットの書き出しに失敗: \(error)")
        }
    }

    private static func attach(_ image: UIImage, name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// リポジトリの中の相対パス(UITests/ から)。見つからなければそのまま
    private static func relativePath(_ url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/UITests/") {
            return String(path[range.lowerBound...].dropFirst())
        }
        return path
    }
}

// MARK: - メインスレッドの見張り

/// 別スレッドからメインスレッドに短い仕事を投げ続け、いちばん長く応答が無かった時間を測る。
/// limit を超えたらその場で失敗を記録する(メインが固まったままでも記録は残る)
final class MainThreadWatchdog: @unchecked Sendable {
    private let limit: TimeInterval
    private let name: String
    private let lock = NSLock()
    private var lastPong = Date()
    private var maxGap: TimeInterval = 0
    private var reported = false
    private var timer: DispatchSourceTimer?

    init(limit: TimeInterval, name: String) {
        self.limit = limit
        self.name = name
    }

    var maximumGap: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(maxGap, Date().timeIntervalSince(lastPong))
    }

    func start() {
        lock.lock()
        lastPong = Date()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let gap = Date().timeIntervalSince(self.lastPong)
            if gap > self.maxGap { self.maxGap = gap }
            let shouldReport = gap >= self.limit && !self.reported
            if shouldReport { self.reported = true }
            self.lock.unlock()
            if shouldReport {
                let message = "\(self.name): メインスレッドが \(String(format: "%.1f", gap)) 秒応答していません(レイアウトの無限ループか固まり)"
                FileHandle.standardError.write(Data(("::error::" + message + "\n").utf8))
                XCTFail(message)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.lastPong = Date()
                self.lock.unlock()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
