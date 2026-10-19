import Foundation
import CoreGraphics
import UIKit

// =====================================================================
// おまかせ編集(ワンタップ編集)・テンプレート・スライドショー。
//
// build:
//   1. ハイライト(渡されなければ HighlightAnalyzer で解析)からスコア順に区間を選び、
//      targetDuration に収める(0 なら全クリップをそのまま使う)。各クリップから最低 1 件を
//      優先して拾い、足りなければ区間を前後に延ばす
//   2. スタイルに応じたトランジション、ルック(DocumentaryStyle / フィルタ)、BGM 音量、ダッキング
//   3. useBGMBeats かつ BGM があれば、カットの位置を近いビートに寄せる(BeatDetector)
//   4. addTitleCard なら先頭にタイトルカード
//   5. 字幕・マーカー・テキスト・オーバーレイなど出力タイムライン上の部品は、残った区間に
//      対応する新しい時刻へ移し替える(残らなかった部品は外す)
//   クリップの id は保つ(同じクリップから複数の区間を使うときは 2 つ目以降が duplicated())。
// slideshow:
//   写真を静止画クリップ(duration 3600、endTime = 1 枚の秒数)にし、ズームイン/アウトを交互に付ける。
// progress は 0...1(バックグラウンドのスレッドから呼ばれることがある)。
// =====================================================================

enum AutoEditorError: LocalizedError {
    case noClips
    case noImages
    case noMaterial

    var errorDescription: String? {
        switch self {
        case .noClips: return "クリップがありません。先に動画を追加してください"
        case .noImages: return "読み込める写真がありません"
        case .noMaterial: return "使える区間が見つかりませんでした。目標の長さを変えてお試しください"
        }
    }
}

enum AutoEditor {

    // MARK: - テンプレート

    struct Template: Identifiable {
        let id: String
        let name: String
        let description: String
        let settings: AutoEditSettings
        let kind: FormatKind?
    }

    static let templates: [Template] = [
        Template(id: "documentary60",
                 name: "ドキュメンタリー60秒",
                 description: "会話と表情を中心に 60 秒へ。ディゾルブと黒へのフェード、落ち着いた色味。",
                 settings: AutoEditSettings(style: .documentary, targetDuration: 60, useBGMBeats: false,
                                            addTitleCard: true, titleText: "", addTransitions: true,
                                            applyLook: true, preferFaces: true, preferSpeech: true),
                 kind: nil),
        Template(id: "vlog90",
                 name: "旅Vlog 90秒",
                 description: "動きのある場面を集めて 90 秒。BGM のビートに合わせてカット、暖かいシネマ調。",
                 settings: AutoEditSettings(style: .vlog, targetDuration: 90, useBGMBeats: true,
                                            addTitleCard: true, titleText: "", addTransitions: true,
                                            applyLook: true, preferFaces: true, preferSpeech: false),
                 kind: nil),
        Template(id: "short15",
                 name: "ショート15秒",
                 description: "いちばん動きのある 15 秒。ビートに合わせた短いカット、鮮やかな色。",
                 settings: AutoEditSettings(style: .short, targetDuration: 15, useBGMBeats: true,
                                            addTitleCard: false, titleText: "", addTransitions: true,
                                            applyLook: true, preferFaces: false, preferSpeech: false),
                 kind: nil),
        Template(id: "family",
                 name: "家族の1日",
                 description: "顔が映っている場面と会話を大切に 2 分へ。やわらかいディゾルブ。",
                 settings: AutoEditSettings(style: .family, targetDuration: 120, useBGMBeats: false,
                                            addTitleCard: true, titleText: "", addTransitions: true,
                                            applyLook: true, preferFaces: true, preferSpeech: true),
                 kind: nil),
        Template(id: "product",
                 name: "商品紹介",
                 description: "説明している場面を優先して 45 秒。色味はそのまま、短いディゾルブ。",
                 settings: AutoEditSettings(style: .howto, targetDuration: 45, useBGMBeats: false,
                                            addTitleCard: true, titleText: "", addTransitions: true,
                                            applyLook: true, preferFaces: false, preferSpeech: true),
                 kind: nil),
        Template(id: "interview",
                 name: "対談ダイジェスト",
                 description: "話している区間を文の切れ目で拾って 3 分のダイジェストに。BGM は会話中に下げる。",
                 settings: AutoEditSettings(style: .documentary, targetDuration: 180, useBGMBeats: false,
                                            addTitleCard: true, titleText: "", addTransitions: true,
                                            applyLook: true, preferFaces: true, preferSpeech: true),
                 kind: nil),
    ]

    // MARK: - 内部表現

    /// 新しいクリップ 1 つ分: 元クリップの番号と元素材上の範囲
    private struct Piece {
        var clipIndex: Int
        var start: Double
        var end: Double
        var speed: Double
        /// 新しい出力タイムライン上の開始(トランジションの重なりは考慮しない)
        var timelineStart: Double = 0

        var outputDuration: Double { max(0, end - start) / max(speed, 0.01) }
    }

    private struct Candidate {
        var piece: Piece
        var score: Double
    }

    // MARK: - おまかせ編集

    static func build(snapshot: ProjectSnapshot, settings: AutoEditSettings, highlights: [HighlightSegment]?,
                      progress: ((Double) -> Void)?) async throws -> ProjectSnapshot {
        guard !snapshot.clips.isEmpty else { throw AutoEditorError.noClips }
        progress?(0.02)

        var segments: [HighlightSegment] = highlights ?? []
        if highlights == nil, settings.targetDuration > 0 {
            segments = try await HighlightAnalyzer.analyze(snapshot: snapshot, settings: settings) { fraction in
                progress?(0.02 + 0.63 * fraction)
            }
        }
        try Task.checkCancellation()
        progress?(0.66)

        var pieces = plan(clips: snapshot.clips, settings: settings, highlights: segments)
        guard !pieces.isEmpty else { throw AutoEditorError.noMaterial }
        let transitions = transitionPlan(count: pieces.count, settings: settings)

        if settings.useBGMBeats, let bgmURL = snapshot.audio.bgmURL {
            var beats: [Double] = []
            do {
                beats = try await BeatDetector.detectBeats(url: bgmURL, start: 0, end: 3600, sensitivity: 0.5)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                beats = []
            }
            try Task.checkCancellation()
            if !beats.isEmpty {
                alignToBeats(&pieces, transitions: transitions, beats: beats, clips: snapshot.clips)
            }
        }
        progress?(0.85)
        layout(&pieces)

        // クリップ
        var newClips: [Clip] = []
        var usedOriginal = Set<Int>()
        for (i, piece) in pieces.enumerated() {
            let original = snapshot.clips[piece.clipIndex]
            var clip = usedOriginal.contains(piece.clipIndex) ? original.duplicated() : original
            usedOriginal.insert(piece.clipIndex)
            clip.startTime = piece.start
            clip.endTime = piece.end
            clip.transition = (i == pieces.count - 1) ? ClipTransition() : transitions[i]
            if settings.applyLook {
                applyClipLook(&clip, style: settings.style)
            }
            newClips.append(clip)
        }

        // 出力タイムライン上の部品を移し替える
        let mapper = TimeMapper(originals: snapshot.clips, pieces: pieces)
        var subtitles: [SubtitleCue] = []
        for cue in snapshot.subtitles {
            guard let range = mapper.mapRange(start: cue.start, end: cue.end) else { continue }
            var moved = cue
            let delta = range.start - cue.start
            moved.start = range.start
            moved.end = range.end
            var words: [SubtitleWord] = []
            for word in cue.words {
                var shifted = word
                shifted.start += delta
                shifted.end += delta
                if shifted.start >= range.start - 0.05 && shifted.end <= range.end + 0.05 {
                    words.append(shifted)
                }
            }
            moved.words = words
            subtitles.append(moved)
        }
        var markers: [TimelineMarker] = []
        for marker in snapshot.markers {
            guard let time = mapper.map(marker.time) else { continue }
            var moved = marker
            moved.time = time
            markers.append(moved)
        }
        var titleCards: [TitleCard] = []
        for card in snapshot.titleCards {
            guard let time = mapper.map(card.start) else { continue }
            var moved = card
            moved.start = time
            titleCards.append(moved)
        }
        var lowerThirds: [LowerThird] = []
        for item in snapshot.lowerThirds {
            guard let time = mapper.map(item.start) else { continue }
            var moved = item
            moved.start = time
            lowerThirds.append(moved)
        }
        var overlays: [OverlayClip] = []
        for item in snapshot.overlays {
            guard let time = mapper.map(item.start) else { continue }
            var moved = item
            moved.start = time
            overlays.append(moved)
        }
        var narration: [NarrationClip] = []
        for item in snapshot.narration {
            guard let time = mapper.map(item.start) else { continue }
            var moved = item
            moved.start = time
            narration.append(moved)
        }
        var textClips: [TextClip] = []
        for item in snapshot.textClips {
            guard let time = mapper.map(item.start) else { continue }
            var moved = item
            moved.start = time
            textClips.append(moved)
        }
        var drawings: [DrawingClip] = []
        for item in snapshot.drawings {
            guard let time = mapper.map(item.start) else { continue }
            var moved = item
            moved.start = time
            drawings.append(moved)
        }

        // 演出・音声
        var documentary = snapshot.documentary
        if settings.applyLook {
            documentary = lookStyle(base: documentary, style: settings.style)
        }
        if settings.preferSpeech && usesDucking(settings.style) {
            documentary.autoDucking = true
            documentary.duckingLevel = 0.3
        }
        var audio = snapshot.audio
        if audio.bgmURL != nil {
            audio.bgmVolume = bgmVolume(for: settings.style)
            audio.bgmFadeOut = true
        }
        if settings.addTitleCard {
            titleCards.insert(makeTitleCard(settings: settings), at: 0)
        }
        titleCards.sort { $0.start < $1.start }
        subtitles.sort { $0.start < $1.start }
        markers.sort { $0.time < $1.time }
        progress?(1)

        return ProjectSnapshot(clips: newClips,
                               subtitles: subtitles,
                               subtitleStyle: snapshot.subtitleStyle,
                               audio: audio,
                               canvas: snapshot.canvas,
                               documentary: documentary,
                               titleCards: titleCards,
                               lowerThirds: lowerThirds,
                               overlays: overlays,
                               narration: narration,
                               textClips: textClips,
                               drawings: drawings,
                               markers: markers,
                               watermark: snapshot.watermark,
                               cover: snapshot.cover)
    }

    // MARK: - スライドショー

    static func slideshow(images: [URL], perImageSeconds: Double, settings: AutoEditSettings,
                          bgm: URL?) async throws -> ProjectSnapshot {
        guard !images.isEmpty else { throw AutoEditorError.noImages }
        let perSafe: Double = perImageSeconds.isFinite ? perImageSeconds : 4
        let per = min(30, max(1, perSafe))

        var clips: [Clip] = []
        for (i, url) in images.enumerated() {
            try Task.checkCancellation()
            guard let size = MediaStore.imagePixelSize(of: url) else { continue }
            let thumb = MediaStore.makeImageClipThumbnail(url: url, maxPixel: 320)
            var clip = Clip(url: url,
                            duration: 3600,
                            naturalSize: size,
                            preferredTransform: .identity,
                            hasAudio: false,
                            thumbnail: thumb,
                            name: MediaStore.displayName(for: url, fallback: "写真"))
            clip.stillImageURL = url
            clip.startTime = 0
            clip.endTime = per
            clip.animation.inType = (i % 2 == 0) ? .zoomIn : .zoomOut
            clip.animation.inDuration = min(per, 6)
            clip.animation.outType = .none
            clips.append(clip)
        }
        guard !clips.isEmpty else { throw AutoEditorError.noImages }

        var pieces: [Piece] = []
        for i in clips.indices {
            pieces.append(Piece(clipIndex: i, start: 0, end: per, speed: 1))
        }
        let transitions = transitionPlan(count: pieces.count, settings: settings)

        if settings.useBGMBeats, let bgmURL = bgm {
            var beats: [Double] = []
            do {
                beats = try await BeatDetector.detectBeats(url: bgmURL, start: 0, end: 3600, sensitivity: 0.5)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                beats = []
            }
            if !beats.isEmpty {
                // ビートに寄せるときは 1 枚あたり 1.5 倍まで延ばしてよい
                var limits = clips
                for i in limits.indices { limits[i].endTime = per * 1.5 }
                alignToBeats(&pieces, transitions: transitions, beats: beats, clips: limits)
            }
        }
        try Task.checkCancellation()

        for i in clips.indices {
            clips[i].endTime = max(1, pieces[i].end)
            clips[i].transition = (i == clips.count - 1) ? ClipTransition() : transitions[i]
            clips[i].animation.inDuration = min(clips[i].endTime, 6)
            if settings.applyLook {
                applyClipLook(&clips[i], style: settings.style)
            }
        }

        var audio = AudioSettings()
        if let bgmURL = bgm {
            audio.bgmURL = bgmURL
            audio.bgmName = MediaStore.displayName(for: bgmURL, fallback: "BGM")
            audio.bgmVolume = 0.6
            audio.bgmFadeOut = true
        }
        var documentary = DocumentaryStyle()
        if settings.applyLook {
            documentary = lookStyle(base: documentary, style: settings.style)
        }
        var titleCards: [TitleCard] = []
        if settings.addTitleCard {
            titleCards.append(makeTitleCard(settings: settings))
        }

        return ProjectSnapshot(clips: clips,
                               subtitles: [],
                               subtitleStyle: SubtitleStyle(),
                               audio: audio,
                               canvas: CanvasSettings(),
                               documentary: documentary,
                               titleCards: titleCards,
                               lowerThirds: [],
                               overlays: [],
                               narration: [],
                               textClips: [],
                               drawings: [],
                               markers: [],
                               watermark: WatermarkSettings(),
                               cover: CoverSettings())
    }

    // MARK: - 区間の選択

    private static func plan(clips: [Clip], settings: AutoEditSettings, highlights: [HighlightSegment]) -> [Piece] {
        let target = settings.targetDuration
        if target <= 0 {
            var all: [Piece] = []
            for (i, clip) in clips.enumerated() where clip.trimmedDuration > 0.05 {
                all.append(Piece(clipIndex: i, start: clip.startTime, end: clip.endTime, speed: clip.speed))
            }
            return all
        }

        var indexByID: [UUID: Int] = [:]
        for (i, clip) in clips.enumerated() { indexByID[clip.id] = i }

        var candidates: [Candidate] = []
        for segment in highlights {
            guard let index = indexByID[segment.clipID] else { continue }
            let clip = clips[index]
            let s = max(clip.startTime, segment.start)
            let e = min(clip.endTime, segment.end)
            guard e - s >= 0.8 else { continue }
            candidates.append(Candidate(piece: Piece(clipIndex: index, start: s, end: e, speed: clip.speed),
                                        score: segment.score))
        }
        if candidates.isEmpty {
            return evenPlan(clips: clips, target: target)
        }
        candidates.sort { $0.score > $1.score }

        var chosen: [Piece] = []
        var total = 0.0
        var taken = [Bool](repeating: false, count: candidates.count)

        // 1) 各クリップから最高の 1 件(クリップ順)
        for index in clips.indices {
            if total >= target - 0.25 { break }
            var found: Int? = nil
            for ci in candidates.indices where !taken[ci] && candidates[ci].piece.clipIndex == index {
                found = ci
                break
            }
            guard let ci = found else { continue }
            var piece = candidates[ci].piece
            if total + piece.outputDuration > target {
                let allowed = target - total
                if allowed < 1.5 { continue }
                piece.end = piece.start + allowed * piece.speed
            }
            taken[ci] = true
            chosen.append(piece)
            total += piece.outputDuration
        }

        // 2) 残りをスコア順
        for ci in candidates.indices where !taken[ci] {
            if total >= target - 0.25 { break }
            var piece = candidates[ci].piece
            if overlaps(piece, chosen) { continue }
            if total + piece.outputDuration > target {
                let allowed = target - total
                if allowed < 1.5 { continue }
                piece.end = piece.start + allowed * piece.speed
            }
            taken[ci] = true
            chosen.append(piece)
            total += piece.outputDuration
        }

        chosen.sort { a, b in
            if a.clipIndex != b.clipIndex { return a.clipIndex < b.clipIndex }
            return a.start < b.start
        }

        // 3) 足りなければ前後に延ばす
        if total < target * 0.9 && !chosen.isEmpty {
            var remaining = target - total
            var passes = 0
            while remaining > 0.3 && passes < 3 {
                let share = remaining / Double(chosen.count)
                var gained = 0.0
                for i in chosen.indices {
                    let clip = clips[chosen[i].clipIndex]
                    var upper = clip.endTime
                    if i + 1 < chosen.count, chosen[i + 1].clipIndex == chosen[i].clipIndex {
                        upper = min(upper, chosen[i + 1].start - 0.05)
                    }
                    let wantSource = share * chosen[i].speed
                    let forward = min(wantSource, max(0, upper - chosen[i].end))
                    if forward > 0.01 {
                        chosen[i].end += forward
                        gained += forward / chosen[i].speed
                    }
                    var lower = clip.startTime
                    if i > 0, chosen[i - 1].clipIndex == chosen[i].clipIndex {
                        lower = max(lower, chosen[i - 1].end + 0.05)
                    }
                    let backward = min(max(0, wantSource - forward), max(0, chosen[i].start - lower))
                    if backward > 0.01 {
                        chosen[i].start -= backward
                        gained += backward / chosen[i].speed
                    }
                }
                if gained < 0.01 { break }
                remaining -= gained
                passes += 1
            }
        }
        return merged(chosen)
    }

    /// ハイライトが無いときの代替: 各クリップの真ん中から長さに比例して切り出す
    private static func evenPlan(clips: [Clip], target: Double) -> [Piece] {
        var totalOut = 0.0
        for clip in clips { totalOut += clip.outputDuration }
        guard totalOut > 0 else { return [] }
        var pieces: [Piece] = []
        if totalOut <= target {
            for (i, clip) in clips.enumerated() where clip.trimmedDuration > 0.05 {
                pieces.append(Piece(clipIndex: i, start: clip.startTime, end: clip.endTime, speed: clip.speed))
            }
            return pieces
        }
        for (i, clip) in clips.enumerated() {
            let out = clip.outputDuration
            let share = target * out / totalOut
            guard share >= 1.0 else { continue }
            let sourceLength = min(clip.trimmedDuration, share * clip.speed)
            let center = (clip.startTime + clip.endTime) / 2
            let s = max(clip.startTime, center - sourceLength / 2)
            let e = min(clip.endTime, s + sourceLength)
            guard e - s > 0.3 else { continue }
            pieces.append(Piece(clipIndex: i, start: s, end: e, speed: clip.speed))
        }
        return pieces
    }

    private static func overlaps(_ piece: Piece, _ others: [Piece]) -> Bool {
        for other in others where other.clipIndex == piece.clipIndex {
            if piece.start < other.end - 0.01 && piece.end > other.start + 0.01 { return true }
        }
        return false
    }

    /// 同じクリップで隣り合う(すき間 0.3 秒未満)区間をつなぐ
    private static func merged(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces {
            if var last = result.last, last.clipIndex == piece.clipIndex, piece.start - last.end < 0.3 {
                last.end = max(last.end, piece.end)
                result[result.count - 1] = last
            } else {
                result.append(piece)
            }
        }
        return result
    }

    /// 出力タイムライン上の開始(トランジションの重なりは考慮しない。EditorProject.clipStartTimes と同じ)
    private static func layout(_ pieces: inout [Piece]) {
        var cursor = 0.0
        for i in pieces.indices {
            pieces[i].timelineStart = cursor
            cursor += pieces[i].outputDuration
        }
    }

    // MARK: - トランジション・ビート

    private static func transitionPlan(count: Int, settings: AutoEditSettings) -> [ClipTransition] {
        guard settings.addTransitions else {
            return [ClipTransition](repeating: ClipTransition(), count: count)
        }
        var result: [ClipTransition] = []
        for i in 0..<count {
            let t: ClipTransition
            switch settings.style {
            case .documentary:
                t = (i % 4 == 3) ? ClipTransition(type: .fadeBlack, duration: 0.6)
                                 : ClipTransition(type: .dissolve, duration: 0.6)
            case .vlog:
                t = ClipTransition(type: .dissolve, duration: 0.4)
            case .short:
                t = (i % 3 == 2) ? ClipTransition(type: .zoomIn, duration: 0.25) : ClipTransition()
            case .family:
                t = ClipTransition(type: .dissolve, duration: 0.5)
            case .howto:
                t = ClipTransition(type: .dissolve, duration: 0.3)
            }
            result.append(t)
        }
        return result
    }

    /// 各カット(トランジションの中央)が近いビートに乗るよう、区間の終わりを前後させる
    private static func alignToBeats(_ pieces: inout [Piece], transitions: [ClipTransition], beats: [Double], clips: [Clip]) {
        guard pieces.count >= 2, !beats.isEmpty else { return }
        let sorted = beats.sorted()
        var cursor = 0.0
        for i in 0..<(pieces.count - 1) {
            let out = pieces[i].outputDuration
            let overlap: Double = (i < transitions.count && transitions[i].isActive) ? transitions[i].duration : 0
            let cutTime = cursor + out - overlap / 2
            let tolerance = min(0.5, out * 0.25)

            var nearest: Double? = nil
            var bestDistance = Double.greatestFiniteMagnitude
            for beat in sorted {
                let distance = abs(beat - cutTime)
                if distance < bestDistance {
                    bestDistance = distance
                    nearest = beat
                }
                if beat > cutTime + tolerance { break }
            }

            var newOut = out
            if let beat = nearest, bestDistance <= tolerance {
                let candidateOut = beat - cursor + overlap / 2
                let clip = clips[pieces[i].clipIndex]
                var limit = clip.endTime
                if pieces[i + 1].clipIndex == pieces[i].clipIndex {
                    limit = min(limit, pieces[i + 1].start)
                }
                let newEnd = pieces[i].start + candidateOut * pieces[i].speed
                if candidateOut >= 0.8 && newEnd <= limit + 1e-6 {
                    pieces[i].end = newEnd
                    newOut = candidateOut
                }
            }
            let effectiveOverlap = min(overlap, newOut * 0.5)
            cursor += newOut - effectiveOverlap
        }
    }

    // MARK: - ルック・音声・タイトル

    private static func lookStyle(base: DocumentaryStyle, style: AutoEditStyle) -> DocumentaryStyle {
        var d = base
        switch style {
        case .documentary:
            d.look = .documentary
            d.lookIntensity = 0.85
            d.letterbox = true
            d.filmGrain = 0.25
            d.vignette = 0.35
            d.fadeFromToBlack = true
        case .family:
            d.look = .documentary
            d.lookIntensity = 0.6
            d.letterbox = false
            d.filmGrain = 0.1
            d.vignette = 0.2
            d.fadeFromToBlack = true
        case .vlog:
            d.look = .cinematicWarm
            d.lookIntensity = 0.7
            d.letterbox = false
            d.filmGrain = 0.1
            d.vignette = 0.25
            d.fadeFromToBlack = true
        case .short:
            d.look = LookPreset.none
            d.letterbox = false
            d.filmGrain = 0
            d.vignette = 0
            d.fadeFromToBlack = false
        case .howto:
            d.look = LookPreset.none
            d.letterbox = false
            d.filmGrain = 0
            d.vignette = 0.1
            d.fadeFromToBlack = true
        }
        d.dipToBlackBetweenClips = false
        return d
    }

    private static func applyClipLook(_ clip: inout Clip, style: AutoEditStyle) {
        switch style {
        case .short:
            clip.filter.preset = .vivid
            clip.filter.intensity = 0.8
        case .documentary, .vlog, .family, .howto:
            break
        }
    }

    private static func usesDucking(_ style: AutoEditStyle) -> Bool {
        switch style {
        case .documentary, .howto, .family: return true
        case .vlog, .short: return false
        }
    }

    private static func bgmVolume(for style: AutoEditStyle) -> Float {
        switch style {
        case .short, .vlog: return 0.6
        case .documentary, .family, .howto: return 0.35
        }
    }

    private static func defaultTitle(for style: AutoEditStyle) -> String {
        switch style {
        case .documentary: return "ある日の記録"
        case .vlog: return "旅の記録"
        case .short: return "ハイライト"
        case .family: return "家族の1日"
        case .howto: return "ご紹介"
        }
    }

    private static func makeTitleCard(settings: AutoEditSettings) -> TitleCard {
        let text = settings.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = text.isEmpty ? defaultTitle(for: settings.style) : text
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日"
        let heading = formatter.string(from: Date())
        var card = TitleCard(start: 0, heading: heading, title: title)
        switch settings.style {
        case .documentary:
            card.duration = 3
            card.opaqueBackground = true
        case .family:
            card.duration = 2.5
            card.opaqueBackground = true
        case .vlog:
            card.duration = 2
            card.opaqueBackground = false
        case .short:
            card.duration = 1.2
            card.opaqueBackground = false
        case .howto:
            card.duration = 2.5
            card.opaqueBackground = true
        }
        return card
    }

    // MARK: - 時刻の移し替え

    /// 元の出力タイムライン上の時刻 → 新しい出力タイムライン上の時刻
    private struct TimeMapper {
        let originals: [Clip]
        let originalStarts: [Double]
        let pieces: [Piece]

        init(originals: [Clip], pieces: [Piece]) {
            self.originals = originals
            self.pieces = pieces
            var starts: [Double] = []
            var cursor = 0.0
            for clip in originals {
                starts.append(cursor)
                cursor += clip.outputDuration
            }
            originalStarts = starts
        }

        /// 元タイムラインの時刻 → (元クリップ番号, 元素材上の秒)
        private func locate(_ time: Double) -> (index: Int, source: Double)? {
            guard !originals.isEmpty else { return nil }
            for (i, clip) in originals.enumerated() {
                let start = originalStarts[i]
                let end = start + clip.outputDuration
                if time < end || i == originals.count - 1 {
                    let local = max(0, min(time - start, clip.outputDuration))
                    return (i, clip.startTime + local * clip.speed)
                }
            }
            return nil
        }

        private func pieceContaining(source: Double, clipIndex: Int) -> Piece? {
            for candidate in pieces where candidate.clipIndex == clipIndex {
                if source >= candidate.start - 1e-6 && source <= candidate.end + 1e-6 { return candidate }
            }
            return nil
        }

        func map(_ time: Double) -> Double? {
            guard let located = locate(time) else { return nil }
            guard let found = pieceContaining(source: located.source, clipIndex: located.index) else { return nil }
            return found.timelineStart + (located.source - found.start) / max(found.speed, 0.01)
        }

        /// 区間 [start, end] の移し替え。片側だけ残るときは残った区間の端に合わせる
        func mapRange(start: Double, end: Double) -> (start: Double, end: Double)? {
            let length = max(0, end - start)
            let mappedStart = map(start)
            let mappedEnd = map(max(start, end - 0.001))
            if let s = mappedStart, let e = mappedEnd, e > s + 0.05 {
                return (s, e)
            }
            if let s = mappedStart, let located = locate(start),
               let found = pieceContaining(source: located.source, clipIndex: located.index) {
                let pieceEnd = found.timelineStart + found.outputDuration
                if pieceEnd - s > 0.3 {
                    return (s, min(pieceEnd, s + length))
                }
            }
            if let e = mappedEnd, let located = locate(max(start, end - 0.001)),
               let found = pieceContaining(source: located.source, clipIndex: located.index) {
                let pieceStart = found.timelineStart
                if e - pieceStart > 0.3 {
                    return (max(pieceStart, e - length), e)
                }
            }
            return nil
        }
    }
}
