import Foundation
import Observation
import UIKit
import AVFoundation

// =====================================================================
// CapCut 風 UI のための共通定義(タイムライン担当と画面担当の両方が使う)。
// =====================================================================

/// タイムライン上で選ばれているもの
enum EditorSelection: Hashable {
    case clip(UUID)
    case subtitle(UUID)
    case bgm
    case overlay(UUID)
    case narration(UUID)
    case text(UUID)
    case drawing(UUID)
    case marker(UUID)

    var textID: UUID? {
        if case .text(let id) = self { return id }
        return nil
    }

    var drawingID: UUID? {
        if case .drawing(let id) = self { return id }
        return nil
    }

    var markerID: UUID? {
        if case .marker(let id) = self { return id }
        return nil
    }

    var overlayID: UUID? {
        if case .overlay(let id) = self { return id }
        return nil
    }

    var narrationID: UUID? {
        if case .narration(let id) = self { return id }
        return nil
    }

    var clipID: UUID? {
        if case .clip(let id) = self { return id }
        return nil
    }

    var subtitleID: UUID? {
        if case .subtitle(let id) = self { return id }
        return nil
    }
}

/// タイムラインの表示倍率など、画面間で共有する UI 状態
@Observable
final class TimelineState {
    /// 1 秒あたりのポイント数(ピンチで変わる)
    var pointsPerSecond: Double = 60
    static let minPointsPerSecond: Double = 8
    static let maxPointsPerSecond: Double = 400

    /// ユーザーがタイムラインを指でスクロール中か(再生位置の自動追従を止めるため)
    var isUserScrolling: Bool = false

    /// タイムラインで部品を動かしている最中か(移動・トリム・並べ替え。beginEdit から finishEdit まで。
    /// 取り消しでも finishEdit を通るので false に戻る)。画面側はこの間タイムラインの高さを固定する
    var isEditing: Bool = false

    /// 中だるみチェックの結果(目盛りの下に緑・黄・赤の帯で出す。空なら出さない)
    var pacing: [PacingSegment] = []
    /// 編集チェック(YouTuber・インフルエンサーが気をつける点)の結果
    var pacingChecks: [EditingCheck] = []

    /// クリップの複数選択モード中か(タップで選択を足したり外したりする)
    var isMultiSelecting: Bool = false
    /// 複数選択中のクリップ
    var multiSelectedClipIDs: Set<UUID> = []

    func beginMultiSelect(with clipID: UUID?) {
        multiSelectedClipIDs = clipID.map { [$0] } ?? []
        isMultiSelecting = true
    }

    func endMultiSelect() {
        isMultiSelecting = false
        multiSelectedClipIDs = []
    }

    func toggleMultiSelect(_ clipID: UUID) {
        if multiSelectedClipIDs.contains(clipID) {
            multiSelectedClipIDs.remove(clipID)
        } else {
            multiSelectedClipIDs.insert(clipID)
        }
    }

    /// 縮小できる下限をこれより小さくはしない(長い動画でも極端に潰れないように)
    static let absoluteMinPointsPerSecond: Double = 0.05

    func clampZoom() {
        pointsPerSecond = min(max(pointsPerSecond, Self.minPointsPerSecond), Self.maxPointsPerSecond)
    }

    /// 動画の長さと表示幅に応じた縮小の下限: min(8, 幅 × 0.8 ÷ 長さ)。
    /// 長い動画でも全体が画面の 8 割に収まるところまで縮小できる。
    static func dynamicMinPointsPerSecond(duration: Double, viewWidth: Double) -> Double {
        guard duration.isFinite, duration > 0.01, viewWidth.isFinite, viewWidth > 0 else {
            return minPointsPerSecond
        }
        let usable: Double = viewWidth * 0.8
        let fit: Double = usable / duration
        let limited: Double = min(minPointsPerSecond, fit)
        return max(absoluteMinPointsPerSecond, limited)
    }

    /// 動画の長さと表示幅を考慮して倍率を範囲内に収める
    func clampZoom(duration: Double, viewWidth: Double) {
        let lower = Self.dynamicMinPointsPerSecond(duration: duration, viewWidth: viewWidth)
        pointsPerSecond = min(max(pointsPerSecond, lower), Self.maxPointsPerSecond)
    }

    // MARK: - トリム中のプレビューのコマ

    /// V1 クリップの端をトリム中、動かしている端の元素材のコマ。PreviewView が再生位置の絵の上に重ねる。
    /// 共有プレイヤーはシークしない(currentTime がタイムラインの原点を決めているため)。nil なら何も重ねない。
    /// PreviewView は player しか受け取らず TimelineState を知らないので、実体は TimelineTrimPreview.shared に置く
    var trimPreviewImage: UIImage? {
        get { TimelineTrimPreview.shared.image }
        set { TimelineTrimPreview.shared.image = newValue }
    }

    /// コマ取りの間隔の下限(秒)と最大ピクセル。指に付いてくる速さと負荷の釣り合い
    private static let trimPreviewInterval: TimeInterval = 0.08
    private static let trimPreviewMaxPixel: CGFloat = 640

    @ObservationIgnored private var trimPreviewTask: Task<Void, Never>? = nil
    @ObservationIgnored private var trimPreviewGenerator: AVAssetImageGenerator? = nil
    @ObservationIgnored private var trimPreviewGeneratorPath: String = ""
    /// 今予約している(まだ始まっていなければ入れ替える)または最後に始めたコマ取りの開始時刻
    @ObservationIgnored private var trimPreviewSlot: TimeInterval = 0
    /// 最後に求めた(素材のパス, 元素材の秒)。同じ要求は出し直さない。nil なら片付け済み
    @ObservationIgnored private var trimPreviewRequested: (path: String, seconds: Double)? = nil

    /// 元素材 url の sourceSeconds 秒のコマを求める(トリムのドラッグ中に毎回呼ぶ)。
    /// 直前の要求は取り消し、trimPreviewInterval に 1 回までしか取り出さない。取れたら trimPreviewImage に入る。
    /// メインスレッドで呼ぶ
    func requestTrimPreview(url: URL, sourceSeconds: Double) {
        let path = url.path
        if let last = trimPreviewRequested, last.path == path, abs(last.seconds - sourceSeconds) < 0.0005 {
            return
        }
        trimPreviewRequested = (path, sourceSeconds)
        trimPreviewTask?.cancel()
        let generator = makeTrimPreviewGenerator(for: url)
        // 進行中の取り出しは捨てる(古い位置の絵が後から届かないように)
        generator.cancelAllCGImageGeneration()
        let now = Date.timeIntervalSinceReferenceDate
        // まだ始まっていない予約があればその枠に入れ替える。始まっていれば前回の開始から interval 空ける
        let start = now < trimPreviewSlot ? trimPreviewSlot : max(now, trimPreviewSlot + Self.trimPreviewInterval)
        trimPreviewSlot = start
        let wait = start - now
        let time = CMTime(seconds: max(0, sourceSeconds), preferredTimescale: 600)
        trimPreviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            if Task.isCancelled { return }
            guard let image = await TimelineState.trimPreviewFrame(generator, at: time), !Task.isCancelled else { return }
            await MainActor.run {
                // 片付けたあと・新しい要求のあとに遅れて届いたコマは出さない
                guard let self, !Task.isCancelled, self.trimPreviewRequested != nil else { return }
                self.trimPreviewImage = image
            }
        }
    }

    /// トリムが終わった(取り消しも含む)ので、コマ取りを止めて重ねた絵を消す。メインスレッドで呼ぶ
    func clearTrimPreview() {
        trimPreviewTask?.cancel()
        trimPreviewTask = nil
        trimPreviewGenerator?.cancelAllCGImageGeneration()
        trimPreviewGenerator = nil
        trimPreviewGeneratorPath = ""
        trimPreviewRequested = nil
        if trimPreviewImage != nil {
            trimPreviewImage = nil
        }
    }

    /// 素材ごとの生成器(同じ素材なら使い回す)。端のコマをほぼ正確に出すため許容は 1/30 秒
    private func makeTrimPreviewGenerator(for url: URL) -> AVAssetImageGenerator {
        if let generator = trimPreviewGenerator, trimPreviewGeneratorPath == url.path {
            return generator
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.trimPreviewMaxPixel, height: Self.trimPreviewMaxPixel)
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        trimPreviewGenerator = generator
        trimPreviewGeneratorPath = url.path
        return generator
    }

    private static func trimPreviewFrame(_ generator: AVAssetImageGenerator, at time: CMTime) async -> UIImage? {
        do {
            let result = try await generator.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }
}

/// トリム中にプレビューへ重ねる「動かしている端のコマ」の受け渡し口。
/// PreviewView は player しか受け取らず TimelineState を知らないので、ここを介して届ける。
/// 書くのは TimelineState(trimPreviewImage)だけ、読むのは PreviewView
@Observable
final class TimelineTrimPreview {
    static let shared = TimelineTrimPreview()
    /// nil なら何も重ねない
    fileprivate(set) var image: UIImage? = nil
}

/// 元に戻す / やり直す。
/// 編集操作の「直前」に `record(project)` を呼ぶ。スライダーのドラッグ中など連続する変更は、
/// ドラッグ開始時に 1 回だけ record する。
@Observable
final class EditorHistory {
    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []
    private let limit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 変更前の状態を保存する
    func record(_ project: EditorProject) {
        let snap = project.snapshot()
        if let last = undoStack.last, last == snap { return }
        undoStack.append(snap)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    func undo(_ project: EditorProject) {
        let current = project.snapshot()
        // 今と同じ状態の記録(パネルを開いただけで何も変えなかったときなど)は飛ばす
        while let last = undoStack.last, last == current {
            undoStack.removeLast()
        }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        project.restore(previous)
    }

    /// 直前の記録が今と同じ状態なら取り除く(パネルを開いて何も変えずに閉じたときなど)。やり直しの記録はそのまま
    func discardLastIfUnchanged(_ project: EditorProject) {
        guard let last = undoStack.last, last == project.snapshot() else { return }
        undoStack.removeLast()
    }

    func redo(_ project: EditorProject) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project.snapshot())
        project.restore(next)
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

extension EditorProject {
    /// スナップショットの内容でプロジェクトを置き換える
    func restore(_ snapshot: ProjectSnapshot) {
        restoreCount += 1
        clips = snapshot.clips
        subtitles = snapshot.subtitles
        subtitleStyle = snapshot.subtitleStyle
        audio = snapshot.audio
        canvas = snapshot.canvas
        documentary = snapshot.documentary
        titleCards = snapshot.titleCards
        lowerThirds = snapshot.lowerThirds
        overlays = snapshot.overlays
        narration = snapshot.narration
        textClips = snapshot.textClips
        drawings = snapshot.drawings
        markers = snapshot.markers
        watermark = snapshot.watermark
        cover = snapshot.cover
    }
}
