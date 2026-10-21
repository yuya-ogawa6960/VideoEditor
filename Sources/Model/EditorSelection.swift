import Foundation
import Observation

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
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project.snapshot())
        project.restore(previous)
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
