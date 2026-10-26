import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

// =====================================================================
// CompositionBuilder: ProjectSnapshot → AVComposition + AVVideoComposition + AVAudioMix
//
// トラック構成:
//   映像: メイン A/B(偶数クリップ → A、奇数 → B。トランジションで隣と重なれる)
//         + マルチカムのアングル A/B + オーバーレイ動画(重なる分だけ増やす小さなプール)
//   音声: クリップ音声 A/B(偶数クリップ → A、奇数 → B。J/L カット・トランジションのクロスフェード)
//         + オーバーレイ音声(volume > 0 のみ) + ナレーション + BGM
//
// タイムライン: timelineLayout(for:) がトランジションの重なりを反映した各クリップの出力上の位置を返す。
//   クリップ N のトランジションは N と N+1 を duration だけ重ね(各クリップの半分まで)、全体は短くなる。
// 速度カーブ: トリミング範囲を等速の区間に分けて scaleTimeRange(音声も同じ)。
// 静止画・読めないクリップ: 黒のダミー映像(Caches に 1 回だけ生成)をトラックに入れて長さを確保し、
//   コンポジタは画像(静止画)または黒を描く。
// 逆再生: reversedURL を素材として使う(範囲は duration − endTime ... duration − startTime)。
// 音声エフェクト: AudioEffectsRenderer.cachedProcessedURL(for:effects:) が返す処理済みファイルを使う。
// 第4弾: 各層にマスク / 自動リフレーム / 手ぶれ補正 / 画質補正 / 3D ズームの設定をプレーン値で渡す。
//   速度区間に素材上の開始秒(sourceStart)を持たせ、コンポジタが出力時刻 → 元素材上の秒を求める。
// =====================================================================

enum RenderPurpose { case preview, export }

struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let renderSize: CGSize
    let duration: CMTime
}

/// 出力タイムライン上のクリップの位置(トランジションの重なりを反映した後の秒)
struct ClipPlacement {
    let clipID: UUID
    let start: Double
    let end: Double
    var duration: Double { max(0, end - start) }
}

enum CompositionBuilderError: LocalizedError {
    case noClips
    case noVideo
    case cannotCreateTrack

    var errorDescription: String? {
        switch self {
        case .noClips: return String(localized: "クリップがありません")
        case .noVideo: return String(localized: "再生できる映像トラックがありません")
        case .cannotCreateTrack: return String(localized: "合成トラックを作成できませんでした")
        }
    }
}

enum CompositionBuilder {

    /// 全ての CMTime はこの timescale で扱う
    static let timescale: CMTimeScale = 600

    /// オーバーレイ動画 / オーバーレイ音声 / ナレーションそれぞれのトラック数の上限
    private static let overlayVideoTrackLimit = 4
    private static let overlayAudioTrackLimit = 4
    private static let narrationTrackLimit = 4

    /// クリップ音声の最大音量(originalVolume × gain × クリップ音量 の上限)
    private static let maxClipVolume: Float = 4

    /// 速度カーブを等速区間に分ける数
    private static let speedCurveSegmentCount = 24

    // MARK: - renderSize

    /// Output pixel size (even integers). export: short side = canvas.resolution.maxShortSide;
    /// preview: short side = min(that, 720). Aspect = canvas.aspect.ratio, or for .original the first clip's
    /// displaySize ratio (9:16 if there are no clips).
    static func renderSize(for snapshot: ProjectSnapshot, purpose: RenderPurpose) -> CGSize {
        let maxShort = snapshot.canvas.resolution.maxShortSide
        let shortSide: CGFloat
        switch purpose {
        case .export: shortSide = maxShort
        case .preview: shortSide = min(maxShort, 720)
        }

        var ratio: CGFloat = 9.0 / 16.0
        if let r = snapshot.canvas.aspect.ratio {
            ratio = r
        } else if let first = snapshot.clips.first {
            let size = first.displaySize
            if size.width > 0, size.height > 0 {
                ratio = size.width / size.height
            }
        }
        if !ratio.isFinite || ratio <= 0 { ratio = 9.0 / 16.0 }

        let width: CGFloat
        let height: CGFloat
        if ratio >= 1 {
            height = shortSide
            width = shortSide * ratio
        } else {
            width = shortSide
            height = shortSide / ratio
        }
        return CGSize(width: compositionEven(width), height: compositionEven(height))
    }

    // MARK: - タイムラインの配置(トランジションの重なりを反映)

    /// クリップ N のトランジションで N と N+1 が重なる長さ(秒)。各クリップの出力長の半分まで
    static func transitionOverlap(from clip: Clip, to next: Clip) -> Double {
        guard clip.transition.isActive else { return 0 }
        let a = max(0, clip.outputDuration)
        let b = max(0, next.outputDuration)
        let d = min(clip.transition.duration, a / 2, b / 2)
        guard d.isFinite, d >= 0.05 else { return 0 }
        return d
    }

    /// 各クリップの出力タイムライン上の開始・終了(重なり反映後)。clips と同じ順・同じ数
    static func timelineLayout(for snapshot: ProjectSnapshot) -> [ClipPlacement] {
        var result: [ClipPlacement] = []
        result.reserveCapacity(snapshot.clips.count)
        var t = 0.0
        let clips = snapshot.clips
        for (i, clip) in clips.enumerated() {
            let out = max(0, clip.outputDuration.isFinite ? clip.outputDuration : 0)
            let start = t
            let end = start + out
            result.append(ClipPlacement(clipID: clip.id, start: start, end: end))
            var next = end
            if i + 1 < clips.count {
                next = end - transitionOverlap(from: clip, to: clips[i + 1])
            }
            t = max(start, next)
        }
        return result
    }

    /// 作品全体の長さ(秒、重なり反映後)
    static func totalDuration(for snapshot: ProjectSnapshot) -> Double {
        timelineLayout(for: snapshot).last?.end ?? 0
    }

    // MARK: - build

    /// 命令の材料(シーン情報が揃ってから VideoCompositorInstruction にする)
    private struct InstructionSpec {
        let range: CMTimeRange
        let layers: [VideoCompositorClipLayer]
        let transition: VideoCompositorTransition?
    }

    static func build(_ snapshot: ProjectSnapshot, purpose: RenderPurpose) async throws -> BuiltComposition {
        guard !snapshot.clips.isEmpty else { throw CompositionBuilderError.noClips }

        let size = renderSize(for: snapshot, purpose: purpose)
        let composition = AVMutableComposition()

        // メイン映像 A/B
        var mainTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CompositionBuilderError.cannotCreateTrack
            }
            mainTracks.append(track)
        }

        let layout = timelineLayout(for: snapshot)
        let clipOutputDurations = snapshot.clips.map { $0.outputDuration }

        // クリップ音声の A/B レーン(偶数クリップ → 0、奇数クリップ → 1)
        var clipLanes: [AudioLane?] = [nil, nil]
        var angleTracks: [AVMutableCompositionTrack] = []
        var nextAngleTrackIndex = 0
        var angleCache: [URL: CompositionAngleSource] = [:]
        var placeholder: CompositionAngleSource? = nil
        var placeholderLoaded = false
        var layers: [VideoCompositorClipLayer?] = Array(repeating: nil, count: snapshot.clips.count)
        var hardCutBoundaries: [Double] = []
        var pictureCount = 0

        for (clipIndex, clip) in snapshot.clips.enumerated() {
            let placement = layout[clipIndex]
            let outStart = compositionTime(placement.start, method: .roundHalfAwayFromZero)
            let outEnd = compositionTime(placement.end, method: .roundHalfAwayFromZero)
            guard outEnd > outStart else { continue }
            let outDuration = outEnd - outStart
            let track = mainTracks[clipIndex % 2]
            let overlapIn = clipIndex > 0 ? max(0, layout[clipIndex - 1].end - placement.start) : 0
            let overlapOut = clipIndex + 1 < layout.count ? max(0, placement.end - layout[clipIndex + 1].start) : 0
            if clipIndex > 0 && overlapIn <= 0.001 {
                hardCutBoundaries.append(placement.start)
            }

            // --- 静止画クリップ(映像ソース無し。黒のダミーで長さを確保)
            if let still = clip.stillImageURL {
                if !placeholderLoaded {
                    placeholderLoaded = true
                    placeholder = await loadPlaceholderSource()
                }
                let placeholderID = insertPlaceholder(placeholder, into: track, at: outStart, duration: outDuration)
                layers[clipIndex] = VideoCompositorClipLayer(clipID: clip.id,
                                                             trackID: nil,
                                                             placeholderTrackID: placeholderID,
                                                             transform: .identity,
                                                             angleSegments: [],
                                                             stillImageURL: still,
                                                             filter: clip.filter,
                                                             geometry: clip.geometry,
                                                             animation: clip.animation,
                                                             speedSegments: [],
                                                             smoothSlow: false,
                                                             start: placement.start,
                                                             end: placement.end,
                                                             mask: clip.mask,
                                                             reframe: ReframeTrack(),
                                                             stabilization: StabilizationTrack(),
                                                             enhance: clip.enhance,
                                                             parallax: clip.parallax,
                                                             reversedSourceDuration: nil)
                pictureCount += 1
                continue
            }

            // --- 映像ソース(逆再生なら逆再生済みファイル)
            let reversedActive = clip.isReversed && clip.reversedURL != nil
            let sourceURL = reversedActive ? (clip.reversedURL ?? clip.url) : clip.url
            let asset = AVURLAsset(url: sourceURL)
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard let sourceVideo = videoTracks.first,
                  let loaded = try? await sourceVideo.load(.timeRange, .preferredTransform) else {
                // 読めないクリップ: 黒
                if !placeholderLoaded {
                    placeholderLoaded = true
                    placeholder = await loadPlaceholderSource()
                }
                let placeholderID = insertPlaceholder(placeholder, into: track, at: outStart, duration: outDuration)
                layers[clipIndex] = blackLayer(for: clip, placeholderTrackID: placeholderID, placement: placement)
                continue
            }
            let (trackRange, mainTransform) = loaded

            // ソース範囲(秒)。逆再生ファイルのタイムラインは反転済み
            var srcStartSec = clip.startTime
            var srcEndSec = clip.endTime
            if reversedActive {
                srcStartSec = clip.duration - clip.endTime
                srcEndSec = clip.duration - clip.startTime
            }
            let trackStartSec = max(0, trackRange.start.seconds)
            let trackEndSec = trackRange.end.seconds
            srcStartSec = max(srcStartSec, trackStartSec)
            if trackEndSec.isFinite { srcEndSec = min(srcEndSec, trackEndSec) }

            let plan = speedPlan(clip: clip,
                                 sourceStart: srcStartSec,
                                 sourceEnd: srcEndSec,
                                 trackRange: trackRange,
                                 outStart: outStart,
                                 outDuration: outDuration)
            guard srcEndSec - srcStartSec > 0.01, !plan.isEmpty else {
                if !placeholderLoaded {
                    placeholderLoaded = true
                    placeholder = await loadPlaceholderSource()
                }
                let placeholderID = insertPlaceholder(placeholder, into: track, at: outStart, duration: outDuration)
                layers[clipIndex] = blackLayer(for: clip, placeholderTrackID: placeholderID, placement: placement)
                continue
            }

            // --- メイン映像(等速区間ごとに挿入して長さを合わせる)
            var insertedAny = false
            for segment in plan {
                if trackEnd(track) > segment.outRange.start { continue }
                compositionPad(track, to: segment.outRange.start)
                do {
                    try track.insertTimeRange(segment.sourceRange, of: sourceVideo, at: segment.outRange.start)
                } catch {
                    continue
                }
                if segment.outRange.duration != segment.sourceRange.duration {
                    track.scaleTimeRange(CMTimeRange(start: segment.outRange.start, duration: segment.sourceRange.duration),
                                         toDuration: segment.outRange.duration)
                }
                insertedAny = true
            }
            guard insertedAny else {
                if !placeholderLoaded {
                    placeholderLoaded = true
                    placeholder = await loadPlaceholderSource()
                }
                let placeholderID = insertPlaceholder(placeholder, into: track, at: outStart, duration: outDuration)
                layers[clipIndex] = blackLayer(for: clip, placeholderTrackID: placeholderID, placement: placement)
                continue
            }
            if trackEnd(track) < outEnd {
                compositionPad(track, to: outEnd)
            }

            // --- クリップ音声(マルチカムでもメインの音声。音量・ゲイン・J/L カット・速度・エフェクトを反映)
            if !clip.isMuted && clip.hasAudio {
                var audioAsset = asset
                if !clip.audio.effects.isIdentity,
                   let processed = AudioEffectsRenderer.cachedProcessedURL(for: sourceURL, effects: clip.audio.effects) {
                    audioAsset = AVURLAsset(url: processed)
                }
                let audioTracks = (try? await audioAsset.loadTracks(withMediaType: .audio)) ?? []
                if let sourceAudio = audioTracks.first,
                   let audioRange = try? await sourceAudio.load(.timeRange) {
                    let laneIndex = clipIndex % 2
                    if clipLanes[laneIndex] == nil,
                       let laneTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                        clipLanes[laneIndex] = AudioLane(track: laneTrack)
                    }
                    if let lane = clipLanes[laneIndex] {
                        let gain = clip.audio.gain.isFinite ? max(0, clip.audio.gain) : 1
                        let clipVolume = clip.audio.volume.isFinite ? max(0, clip.audio.volume) : 1
                        let volume = min(snapshot.audio.originalVolume * gain * clipVolume, maxClipVolume)
                        if clip.speedCurve.enabled || reversedActive {
                            insertSegmentedAudio(plan,
                                                 sourceAudio: sourceAudio,
                                                 audioRange: audioRange,
                                                 lane: lane,
                                                 volume: volume,
                                                 fadeIn: overlapIn,
                                                 fadeOut: overlapOut)
                        } else if let first = plan.first {
                            let speed = max(clip.speed, 0.01)
                            let previousOut = clipIndex > 0 ? clipOutputDurations[clipIndex - 1] : 0
                            let nextOut = clipIndex + 1 < clipOutputDurations.count ? clipOutputDurations[clipIndex + 1] : 0
                            if let audioPlacement = clipAudioPlacement(audioRange: audioRange,
                                                                       srcStart: first.sourceRange.start,
                                                                       srcEnd: first.sourceRange.end,
                                                                       speed: speed,
                                                                       leadIn: clip.audio.audioLeadIn,
                                                                       tailOut: clip.audio.audioTailOut,
                                                                       cursor: outStart,
                                                                       maxLeadTimeline: previousOut,
                                                                       maxTailTimeline: nextOut,
                                                                       laneEnd: lane.end) {
                                compositionPad(lane.track, to: audioPlacement.at)
                                do {
                                    try lane.track.insertTimeRange(audioPlacement.sourceRange, of: sourceAudio, at: audioPlacement.at)
                                    if audioPlacement.outDuration != audioPlacement.sourceRange.duration {
                                        lane.track.scaleTimeRange(CMTimeRange(start: audioPlacement.at,
                                                                              duration: audioPlacement.sourceRange.duration),
                                                                  toDuration: audioPlacement.outDuration)
                                    }
                                    lane.addSegment(at: audioPlacement.at,
                                                    duration: audioPlacement.outDuration,
                                                    volume: volume,
                                                    fadeIn: overlapIn,
                                                    fadeOut: overlapOut)
                                } catch {
                                    // 音声が入らなくても映像は続行
                                }
                            }
                        }
                    }
                }
            }

            // --- マルチカム(逆再生中は使わない)
            var segments: [VideoCompositorAngleSegment] = []
            if clip.multicam.isActive && !reversedActive {
                let runs = compositionAngleRuns(multicam: clip.multicam,
                                                sourceStart: srcStartSec,
                                                sourceEnd: srcEndSec)
                for run in runs where run.angle > 0 && run.angle <= clip.multicam.angles.count {
                    let angle = clip.multicam.angles[run.angle - 1]

                    var source = angleCache[angle.url]
                    if source == nil {
                        source = await loadAngleSource(angle)
                        if let source { angleCache[angle.url] = source }
                    }
                    guard let angleSource = source else { continue }

                    // アングル素材上の範囲(素材の長さに収める)
                    let rangeStartSec = max(run.start + angle.offset, angleSource.timeRange.start.seconds)
                    let rangeEndSec = min(run.end + angle.offset, angleSource.timeRange.end.seconds)
                    guard rangeEndSec - rangeStartSec > 0.02 else { continue }

                    // 出力タイムライン上の位置(速度カーブを考慮)
                    guard let outSSec = outputTime(forSource: rangeStartSec - angle.offset, plan: plan),
                          let outESec = outputTime(forSource: rangeEndSec - angle.offset, plan: plan) else { continue }
                    let segOutStart = compositionTime(outSSec, method: .roundHalfAwayFromZero)
                    var segOutEnd = compositionTime(outESec, method: .roundHalfAwayFromZero)
                    if segOutEnd > outEnd { segOutEnd = outEnd }
                    guard (segOutEnd - segOutStart).seconds > 0.02 else { continue }
                    let segOut = segOutEnd - segOutStart

                    let angleSrcStart = compositionTime(rangeStartSec, method: .roundTowardPositiveInfinity)
                    var angleSrcEnd = compositionTime(rangeEndSec, method: .roundTowardZero)
                    let angleTrackEnd = angleSource.timeRange.end.convertScale(timescale, method: .roundTowardZero)
                    if angleSrcEnd > angleTrackEnd { angleSrcEnd = angleTrackEnd }
                    guard angleSrcEnd > angleSrcStart else { continue }
                    let angleSrcDuration = angleSrcEnd - angleSrcStart

                    // A/B 交互のアングルトラックへ配置
                    let slot = nextAngleTrackIndex % 2
                    if angleTracks.count <= slot {
                        guard let newTrack = composition.addMutableTrack(withMediaType: .video,
                                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
                            continue
                        }
                        angleTracks.append(newTrack)
                    }
                    let angleTrack = angleTracks[slot]
                    if trackEnd(angleTrack) > segOutStart { continue }
                    compositionPad(angleTrack, to: segOutStart)
                    do {
                        try angleTrack.insertTimeRange(CMTimeRange(start: angleSrcStart, duration: angleSrcDuration),
                                                       of: angleSource.track, at: segOutStart)
                    } catch {
                        continue
                    }
                    if segOut != angleSrcDuration {
                        angleTrack.scaleTimeRange(CMTimeRange(start: segOutStart, duration: angleSrcDuration),
                                                  toDuration: segOut)
                    }
                    nextAngleTrackIndex += 1
                    segments.append(VideoCompositorAngleSegment(
                        timeRange: CMTimeRange(start: segOutStart, duration: segOut),
                        trackID: angleTrack.trackID,
                        transform: angleSource.transform))
                }
            }

            layers[clipIndex] = VideoCompositorClipLayer(
                clipID: clip.id,
                trackID: track.trackID,
                placeholderTrackID: nil,
                transform: mainTransform,
                angleSegments: segments,
                stillImageURL: nil,
                filter: clip.filter,
                geometry: clip.geometry,
                animation: clip.animation,
                speedSegments: plan.map {
                    VideoCompositorSpeedSegment(start: $0.outRange.start.seconds,
                                                end: $0.outRange.end.seconds,
                                                speed: $0.speed,
                                                sourceStart: $0.sourceRange.start.seconds)
                },
                smoothSlow: clip.speedCurve.enabled && clip.speedCurve.smoothSlow,
                start: placement.start,
                end: placement.end,
                mask: clip.mask,
                reframe: clip.reframe,
                stabilization: clip.stabilization,
                enhance: clip.enhance,
                parallax: DepthParallax(),
                reversedSourceDuration: reversedActive ? clip.duration : nil)
            pictureCount += 1
        }

        guard pictureCount > 0 else { throw CompositionBuilderError.noVideo }

        // --- 命令の区間(単独区間とトランジション区間を隙間なく並べる)
        var specs: [InstructionSpec] = []
        var cursor = CMTime.zero
        for i in 0..<layout.count {
            guard let layer = layers[i] else { continue }
            let placement = layout[i]
            var nextOverlap = 0.0
            var nextLayer: VideoCompositorClipLayer? = nil
            if i + 1 < layout.count, let candidate = layers[i + 1] {
                nextOverlap = max(0, placement.end - layout[i + 1].start)
                nextLayer = candidate
            }
            let soloEnd = compositionTime(placement.end - nextOverlap, method: .roundHalfAwayFromZero)
            if soloEnd > cursor {
                specs.append(InstructionSpec(range: CMTimeRange(start: cursor, end: soloEnd), layers: [layer], transition: nil))
                cursor = soloEnd
            }
            if nextOverlap > 0.001, let nextLayer {
                let transitionEnd = compositionTime(placement.end, method: .roundHalfAwayFromZero)
                if transitionEnd > cursor {
                    let transition = VideoCompositorTransition(type: snapshot.clips[i].transition.type,
                                                               start: layout[i + 1].start,
                                                               duration: nextOverlap)
                    specs.append(InstructionSpec(range: CMTimeRange(start: cursor, end: transitionEnd),
                                                 layers: [layer, nextLayer],
                                                 transition: transition))
                    cursor = transitionEnd
                }
            }
        }
        guard !specs.isEmpty, cursor > .zero else { throw CompositionBuilderError.noVideo }
        let totalDuration = cursor
        let totalSeconds = totalDuration.seconds

        // 何も入らなかった映像トラックは外す
        for track in mainTracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }

        // --- オーバーレイ(Bロール / ワイプ / 写真)
        var overlayLanes: [AudioLane] = []
        let overlayInfos = await insertOverlays(snapshot.overlays,
                                                into: composition,
                                                totalSeconds: totalSeconds,
                                                audioLanes: &overlayLanes)

        // --- ナレーション
        var narrationLanes: [AudioLane] = []
        let narrationRanges = await insertNarration(snapshot.narration,
                                                    into: composition,
                                                    totalSeconds: totalSeconds,
                                                    lanes: &narrationLanes)

        // --- ドキュメンタリー風の仕上げ(全命令で共通のプレーンデータ)
        let documentaryInfo = DocumentaryRenderInfo(
            style: snapshot.documentary,
            titleCards: snapshot.titleCards
                .filter { $0.duration > 0 && $0.end > 0 && $0.start < totalSeconds }
                .sorted { $0.start < $1.start },
            lowerThirds: snapshot.lowerThirds
                .filter { $0.duration > 0 && $0.end > 0 && $0.start < totalSeconds }
                .sorted { $0.start < $1.start },
            totalDuration: totalSeconds,
            clipBoundaries: hardCutBoundaries)

        // --- 字幕(表示行は事前計算)
        let subtitles: [VideoCompositorSubtitle] = snapshot.subtitles.compactMap { (cue: SubtitleCue) -> VideoCompositorSubtitle? in
            guard cue.end > cue.start, cue.end > 0, cue.start < totalSeconds else { return nil }
            let lines = cue.displayLines(mode: snapshot.subtitleStyle.displayMode)
            guard !lines.isEmpty else { return nil }
            return VideoCompositorSubtitle(start: cue.start, end: cue.end, lines: lines,
                                           words: cue.words, originalText: cue.text)
        }

        let scene = VideoCompositorScene(
            renderSize: size,
            scaling: snapshot.canvas.scaling,
            subtitles: subtitles,
            subtitleStyle: snapshot.subtitleStyle,
            // テキストはトラック(段)の順に重ねる(V の番号が小さい段から。上の段ほど上に重なる)
            textClips: Self.sortedByLane(snapshot.textClips
                .filter { $0.duration > 0 && $0.end > 0 && $0.start < totalSeconds },
                lanes: TimelineMetrics.textLanes(snapshot.textClips)),
            drawings: snapshot.drawings
                .filter { $0.duration > 0 && $0.end > 0 && $0.start < totalSeconds }
                .sorted { $0.start < $1.start },
            watermark: snapshot.watermark,
            documentary: documentaryInfo,
            postsFrames: purpose == .export,
            // オーバーレイもトラック(段)の順に重ねる(V2 → V3 …)
            mediaOverlays: Self.sortedOverlaysByLane(overlayInfos, lanes: TimelineMetrics.overlayLanes(snapshot.overlays)),
            totalDuration: totalSeconds)

        var instructions: [VideoCompositorInstruction] = specs.map {
            VideoCompositorInstruction(timeRange: $0.range, layers: $0.layers, transition: $0.transition, scene: scene)
        }

        // --- 音量(クリップ音声 / オーバーレイ音声 / ナレーション)
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        for lane in clipLanes.compactMap({ $0 }) {
            if lane.isEmpty {
                composition.removeTrack(lane.track)
            } else {
                audioParameters.append(lane.makeParameters())
            }
        }
        for lane in overlayLanes + narrationLanes {
            if lane.isEmpty {
                composition.removeTrack(lane.track)
            } else {
                audioParameters.append(lane.makeParameters())
            }
        }

        // --- BGM(ループして全体長に合わせる)
        if let bgmURL = snapshot.audio.bgmURL {
            let bgmAsset = AVURLAsset(url: bgmURL)
            if let bgmSource = (try? await bgmAsset.loadTracks(withMediaType: .audio))?.first,
               let bgmRange = try? await bgmSource.load(.timeRange) {
                let bgmStart = bgmRange.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
                let bgmEnd = bgmRange.end.convertScale(timescale, method: .roundTowardZero)
                let bgmLength = bgmEnd - bgmStart
                if bgmLength.seconds > 0.1,
                   let bgmTrack = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
                    var t = CMTime.zero
                    var ok = true
                    while t < totalDuration && ok {
                        let remaining = totalDuration - t
                        let chunk = remaining < bgmLength ? remaining : bgmLength
                        do {
                            try bgmTrack.insertTimeRange(CMTimeRange(start: bgmStart, duration: chunk),
                                                         of: bgmSource, at: t)
                            t = t + chunk
                        } catch {
                            ok = false
                        }
                    }
                    if t > .zero {
                        let volume = snapshot.audio.bgmVolume
                        let params = AVMutableAudioMixInputParameters(track: bgmTrack)
                        // 字幕(=話している区間)とナレーションの間だけ BGM を下げる
                        var speechRanges: [(start: Double, end: Double)] = snapshot.subtitles.map { (start: $0.start, end: $0.end) }
                        speechRanges.append(contentsOf: narrationRanges)
                        let duckIntervals: [(start: Double, end: Double)] = snapshot.documentary.autoDucking
                            ? compositionDuckIntervals(speechRanges, total: totalSeconds)
                            : []
                        if !duckIntervals.isEmpty {
                            compositionApplyBGMEnvelope(params,
                                                        volume: volume,
                                                        duckLevel: snapshot.documentary.duckingLevel,
                                                        intervals: duckIntervals,
                                                        total: totalSeconds,
                                                        fadeOut: snapshot.audio.bgmFadeOut)
                        } else {
                            params.setVolume(volume, at: .zero)
                            if snapshot.audio.bgmFadeOut {
                                let fade = CMTime(value: 2 * Int64(timescale), timescale: timescale)
                                let fadeLength = totalDuration > fade ? fade : totalDuration
                                let fadeStart = totalDuration - fadeLength
                                if fadeLength > .zero {
                                    params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                                         timeRange: CMTimeRange(start: fadeStart, duration: fadeLength))
                                }
                            }
                        }
                        audioParameters.append(params)
                    } else {
                        composition.removeTrack(bgmTrack)
                    }
                }
            }
        }

        // --- 命令の最終調整: コンポジション全長を隙間なく覆う
        var compositionDuration = composition.duration
        if compositionDuration < totalDuration, let first = mainTracks.first, !first.segments.isEmpty {
            compositionPad(first, to: totalDuration)
            compositionDuration = composition.duration
        }
        if compositionDuration > totalDuration, let last = instructions.last {
            instructions[instructions.count - 1] = last.withTimeRange(
                CMTimeRange(start: last.timeRange.start, end: compositionDuration))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = VideoCompositor.self
        videoComposition.renderSize = size
        let fps = Int32(min(max(snapshot.canvas.frameRate, 1), 120))
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
        videoComposition.instructions = instructions.map { $0 as AVVideoCompositionInstructionProtocol }

        var audioMix: AVAudioMix? = nil
        if !audioParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParameters
            audioMix = mix
        }

        let finalDuration = compositionDuration > totalDuration ? compositionDuration : totalDuration
        return BuiltComposition(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: audioMix,
                                renderSize: size,
                                duration: finalDuration)
    }

    // MARK: - 速度(等速 / 速度カーブ)の区間計画

    /// 元素材上の範囲 → 出力上の範囲(等速区間)。speed は実効速度(ソース長 / 出力長)
    struct SpeedPlanSegment {
        let sourceRange: CMTimeRange
        let outRange: CMTimeRange
        let speed: Double
    }

    /// トリミング範囲 [sourceStart, sourceEnd) を出力 [outStart, outStart + outDuration) に割り当てる。
    /// 速度カーブが有効なら speedCurve.segments() の区間ごと、無効なら 1 区間(clip.speed)。
    /// 各区間の出力長は、合計がちょうど outDuration になるよう比例配分する(UI の配置と一致させる)
    private static func speedPlan(clip: Clip,
                                  sourceStart: Double,
                                  sourceEnd: Double,
                                  trackRange: CMTimeRange,
                                  outStart: CMTime,
                                  outDuration: CMTime) -> [SpeedPlanSegment] {
        let trimmed = sourceEnd - sourceStart
        guard trimmed > 0, outDuration > .zero else { return [] }

        let raw: [(from: Double, to: Double, speed: Double)]
        if clip.speedCurve.enabled {
            raw = clip.speedCurve.segments(count: speedCurveSegmentCount).map {
                (from: $0.fromPosition, to: $0.toPosition, speed: max($0.speed, 0.05))
            }
        } else {
            raw = [(from: 0, to: 1, speed: max(clip.speed, 0.01))]
        }
        let rawOut = raw.map { ($0.to - $0.from) * trimmed / $0.speed }
        let rawTotal = rawOut.reduce(0, +)
        guard rawTotal > 0, rawTotal.isFinite else { return [] }
        let factor = outDuration.seconds / rawTotal
        let outEnd = outStart + outDuration

        let trackStart = trackRange.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
        let trackEndTime = trackRange.end.convertScale(timescale, method: .roundTowardZero)

        var result: [SpeedPlanSegment] = []
        var cursor = outStart
        var boundary = compositionTime(sourceStart, method: .roundHalfAwayFromZero)
        if boundary < trackStart { boundary = trackStart }
        for (i, seg) in raw.enumerated() {
            var nextBoundary: CMTime
            if i == raw.count - 1 {
                nextBoundary = compositionTime(sourceEnd, method: .roundTowardZero)
            } else {
                nextBoundary = compositionTime(sourceStart + seg.to * trimmed, method: .roundHalfAwayFromZero)
            }
            if nextBoundary > trackEndTime { nextBoundary = trackEndTime }
            let sStart = boundary
            let sEnd = nextBoundary
            if sEnd > boundary { boundary = nextBoundary }
            guard sEnd > sStart else { continue }

            var oEnd: CMTime
            if i == raw.count - 1 {
                oEnd = outEnd
            } else {
                oEnd = cursor + CMTime(seconds: rawOut[i] * factor, preferredTimescale: timescale)
            }
            if oEnd > outEnd { oEnd = outEnd }
            guard oEnd > cursor else { continue }
            let speed = (sEnd - sStart).seconds / (oEnd - cursor).seconds
            result.append(SpeedPlanSegment(sourceRange: CMTimeRange(start: sStart, end: sEnd),
                                           outRange: CMTimeRange(start: cursor, end: oEnd),
                                           speed: speed))
            cursor = oEnd
        }
        // 丸めで最後が足りないときは最後の区間を伸ばして出力長を揃える
        if let last = result.last, last.outRange.end < outEnd {
            let stretched = CMTimeRange(start: last.outRange.start, end: outEnd)
            let speed = last.sourceRange.duration.seconds / max(stretched.duration.seconds, 0.0001)
            result[result.count - 1] = SpeedPlanSegment(sourceRange: last.sourceRange, outRange: stretched, speed: speed)
        }
        return result
    }

    /// 元素材上の秒 → 出力タイムライン上の秒(区間計画に沿って線形に変換)
    private static func outputTime(forSource seconds: Double, plan: [SpeedPlanSegment]) -> Double? {
        guard let first = plan.first, let last = plan.last else { return nil }
        if seconds <= first.sourceRange.start.seconds { return first.outRange.start.seconds }
        if seconds >= last.sourceRange.end.seconds { return last.outRange.end.seconds }
        for seg in plan {
            let s0 = seg.sourceRange.start.seconds
            let s1 = seg.sourceRange.end.seconds
            if seconds >= s0 && seconds <= s1 {
                let o0 = seg.outRange.start.seconds
                let o1 = seg.outRange.end.seconds
                let t = s1 > s0 ? (seconds - s0) / (s1 - s0) : 0
                return o0 + (o1 - o0) * t
            }
        }
        return nil
    }

    /// 速度カーブ / 逆再生の音声: 映像と同じ区間計画で挿入する(J/L カットは無し)
    private static func insertSegmentedAudio(_ plan: [SpeedPlanSegment],
                                             sourceAudio: AVAssetTrack,
                                             audioRange: CMTimeRange,
                                             lane: AudioLane,
                                             volume: Float,
                                             fadeIn: Double,
                                             fadeOut: Double) {
        var firstAt: CMTime? = nil
        var lastEnd: CMTime? = nil
        for seg in plan {
            let inter = audioRange.intersection(seg.sourceRange)
            guard inter.isValid, !inter.isEmpty else { continue }
            let aStart = inter.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
            let aEnd = inter.end.convertScale(timescale, method: .roundTowardZero)
            guard aEnd > aStart else { continue }
            let aDuration = aEnd - aStart
            let offsetInSegment = max(0, (aStart - seg.sourceRange.start).seconds) / max(seg.speed, 0.01)
            let at = seg.outRange.start + CMTime(seconds: offsetInSegment, preferredTimescale: timescale)
            if at < lane.end { continue }   // 同じレーンの前の音声に重なる
            var aOut = scaledDuration(aDuration, speed: seg.speed)
            if at + aOut > seg.outRange.end { aOut = seg.outRange.end - at }
            guard aOut > .zero else { continue }
            compositionPad(lane.track, to: at)
            do {
                try lane.track.insertTimeRange(CMTimeRange(start: aStart, duration: aDuration), of: sourceAudio, at: at)
            } catch {
                continue
            }
            if aOut != aDuration {
                lane.track.scaleTimeRange(CMTimeRange(start: at, duration: aDuration), toDuration: aOut)
            }
            if firstAt == nil { firstAt = at }
            lastEnd = at + aOut
        }
        if let firstAt, let lastEnd, lastEnd > firstAt {
            lane.addSegment(at: firstAt, duration: lastEnd - firstAt, volume: volume, fadeIn: fadeIn, fadeOut: fadeOut)
        }
    }

    // MARK: - 黒のダミー映像(静止画・読めないクリップ)

    /// 映像ソースの無い層(黒)
    private static func blackLayer(for clip: Clip,
                                   placeholderTrackID: CMPersistentTrackID?,
                                   placement: ClipPlacement) -> VideoCompositorClipLayer {
        VideoCompositorClipLayer(clipID: clip.id,
                                 trackID: nil,
                                 placeholderTrackID: placeholderTrackID,
                                 transform: .identity,
                                 angleSegments: [],
                                 stillImageURL: nil,
                                 filter: clip.filter,
                                 geometry: clip.geometry,
                                 animation: clip.animation,
                                 speedSegments: [],
                                 smoothSlow: false,
                                 start: placement.start,
                                 end: placement.end)
    }

    private static func loadPlaceholderSource() async -> CompositionAngleSource? {
        guard let url = await CompositionPlaceholder.blackVideoURL() else { return nil }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let track = tracks.first,
              let loaded = try? await track.load(.timeRange, .preferredTransform),
              loaded.0.duration > .zero else {
            CompositionPlaceholder.discard(url)
            return nil
        }
        return CompositionAngleSource(track: track, timeRange: loaded.0, transform: loaded.1)
    }

    /// 黒のダミー映像を track の at から duration だけ入れる(フレームは描画に使わない)。
    /// 入れられたらそのトラック ID、入れられなければ空区間で長さだけ確保して nil
    private static func insertPlaceholder(_ source: CompositionAngleSource?,
                                          into track: AVMutableCompositionTrack,
                                          at: CMTime,
                                          duration: CMTime) -> CMPersistentTrackID? {
        guard duration > .zero else { return nil }
        let end = at + duration
        guard trackEnd(track) <= at else { return nil }
        if let source, source.timeRange.duration > .zero {
            let available = source.timeRange.duration
            let srcDuration = available < duration ? available : duration
            let srcRange = CMTimeRange(start: source.timeRange.start, duration: srcDuration)
            compositionPad(track, to: at)
            do {
                try track.insertTimeRange(srcRange, of: source.track, at: at)
                if srcDuration != duration {
                    track.scaleTimeRange(CMTimeRange(start: at, duration: srcDuration), toDuration: duration)
                }
                return track.trackID
            } catch {
                // 空区間で代用
            }
        }
        compositionPad(track, to: end)
        return nil
    }

    // MARK: - クリップ音声(ゲイン・J カット・L カット)

    private struct AudioPlacement {
        let sourceRange: CMTimeRange
        let at: CMTime
        let outDuration: CMTime
    }

    /// クリップ音声の配置を求める。
    /// - J カット(leadIn): 映像より前に音声を始める。素材の (startTime - leadIn) から取り、
    ///   タイムラインの (クリップ開始 - leadIn / speed) に置く(素材の先頭・タイムラインの先頭・前のクリップ長を越えない)
    /// - L カット(tailOut): 映像が終わった後も音声を続ける(素材の末尾・次のクリップ長を越えない)
    /// - 速度: 拡張したソース範囲をそのまま挿入し、長さを (ソース長 / speed) に縮めるので映像と正確に揃う
    /// - 同じレーンの前の音声と重なる分は先頭を削る
    private static func clipAudioPlacement(audioRange: CMTimeRange,
                                           srcStart: CMTime,
                                           srcEnd: CMTime,
                                           speed: Double,
                                           leadIn: Double,
                                           tailOut: Double,
                                           cursor: CMTime,
                                           maxLeadTimeline: Double,
                                           maxTailTimeline: Double,
                                           laneEnd: CMTime) -> AudioPlacement? {
        guard audioRange.isValid, !audioRange.isEmpty else { return nil }
        let srcStartSec = srcStart.seconds
        let srcEndSec = srcEnd.seconds
        let cursorSec = cursor.seconds
        let audioStartSec = max(0, audioRange.start.seconds)
        let audioEndSec = audioRange.end.seconds
        guard audioEndSec.isFinite, audioEndSec > audioStartSec else { return nil }

        // J カット(素材秒)。タイムライン上では lead / speed 秒だけ早く始まる
        var lead = (leadIn.isFinite && leadIn > 0) ? leadIn : 0
        lead = min(lead, srcStartSec - audioStartSec)
        lead = min(lead, cursorSec * speed)
        lead = min(lead, max(0, maxLeadTimeline) * speed)
        lead = max(0, lead)

        // L カット(素材秒)
        var tail = (tailOut.isFinite && tailOut > 0) ? tailOut : 0
        tail = min(tail, audioEndSec - srcEndSec)
        tail = min(tail, max(0, maxTailTimeline) * speed)
        tail = max(0, tail)

        var aStartSec = max(srcStartSec - lead, audioStartSec)
        let aEndSec = min(srcEndSec + tail, audioEndSec)

        // 同じレーンの前の音声と重ならないように(重なる分は先頭を削る)
        var atSec = cursorSec + (aStartSec - srcStartSec) / speed
        let laneEndSec = (laneEnd.isValid && laneEnd.isNumeric) ? laneEnd.seconds : 0
        if atSec < laneEndSec {
            aStartSec += (laneEndSec - atSec) * speed
            atSec = laneEndSec
        }
        if atSec < 0 {
            aStartSec += -atSec * speed
            atSec = 0
        }
        guard aEndSec - aStartSec > 0.01 else { return nil }

        let aStart = compositionTime(aStartSec, method: .roundTowardPositiveInfinity)
        let aEnd = compositionTime(aEndSec, method: .roundTowardZero)
        guard aEnd > aStart else { return nil }
        // 丸めた後のソース開始位置から、映像と揃う配置時刻を出し直す
        let alignedAtSec = max(laneEndSec, cursorSec + (aStart.seconds - srcStartSec) / speed)
        let at = compositionTime(max(0, alignedAtSec), method: .roundHalfAwayFromZero)
        let sourceDuration = aEnd - aStart
        let outDuration = scaledDuration(sourceDuration, speed: speed)
        guard outDuration > .zero else { return nil }
        return AudioPlacement(sourceRange: CMTimeRange(start: aStart, duration: sourceDuration),
                              at: at,
                              outDuration: outDuration)
    }

    // MARK: - オーバーレイ

    /// オーバーレイをコンポジションへ入れる(動画: 映像トラック + 音量 > 0 なら音声レーン。写真: トラックなし)。
    /// 戻り値はコンポジタ命令に渡すプレーンデータ(開始時刻順)
    private static func insertOverlays(_ overlays: [OverlayClip],
                                       into composition: AVMutableComposition,
                                       totalSeconds: Double,
                                       audioLanes: inout [AudioLane]) async -> [VideoCompositorOverlay] {
        guard !overlays.isEmpty, totalSeconds > 0 else { return [] }
        var videoTracks: [AVMutableCompositionTrack] = []
        var result: [VideoCompositorOverlay] = []

        let sorted = overlays.sorted { $0.start < $1.start }
        for overlay in sorted {
            guard overlay.duration > 0.01, overlay.end > 0, overlay.start < totalSeconds else { continue }

            // タイムライン上の範囲(先頭より前・全体の終わりより後は切る)
            let speed = max(overlay.speed, 0.01)
            var timelineStart = overlay.start
            var sourceStartSec = max(0, overlay.sourceStart)
            if timelineStart < 0 {
                sourceStartSec += (-timelineStart) * (overlay.isImage ? 1 : speed)
                timelineStart = 0
            }
            let timelineEnd = min(overlay.end, totalSeconds)
            let timelineDuration = timelineEnd - timelineStart
            guard timelineDuration > 0.01 else { continue }

            if overlay.isImage {
                result.append(VideoCompositorOverlay(overlay: overlay, trackID: nil))
                continue
            }

            // --- 動画オーバーレイ
            let asset = AVURLAsset(url: overlay.url)
            guard let sourceVideo = (try? await asset.loadTracks(withMediaType: .video))?.first,
                  let loaded = try? await sourceVideo.load(.timeRange, .preferredTransform) else {
                continue
            }
            let (trackRange, transform) = loaded
            let trackStart = trackRange.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
            let trackEndTime = trackRange.end.convertScale(timescale, method: .roundTowardZero)

            var oSrcStart = compositionTime(sourceStartSec, method: .roundTowardPositiveInfinity)
            var oSrcEnd = compositionTime(sourceStartSec + timelineDuration * speed, method: .roundTowardZero)
            if oSrcStart < trackStart { oSrcStart = trackStart }
            if oSrcEnd > trackEndTime { oSrcEnd = trackEndTime }
            guard oSrcEnd > oSrcStart else { continue }
            let oSrcDuration = oSrcEnd - oSrcStart
            let outStart = compositionTime(timelineStart, method: .roundHalfAwayFromZero)
            let outDuration = scaledDuration(oSrcDuration, speed: speed)
            guard outDuration > .zero else { continue }

            // 空いている映像トラック(重なるオーバーレイはそれぞれ別のトラックへ)
            guard let track = availableVideoTrack(in: &videoTracks, at: outStart,
                                                  composition: composition, limit: overlayVideoTrackLimit) else {
                continue
            }
            compositionPad(track, to: outStart)
            do {
                try track.insertTimeRange(CMTimeRange(start: oSrcStart, duration: oSrcDuration),
                                          of: sourceVideo, at: outStart)
            } catch {
                continue
            }
            if outDuration != oSrcDuration {
                track.scaleTimeRange(CMTimeRange(start: outStart, duration: oSrcDuration), toDuration: outDuration)
            }

            // --- 音声(volume > 0 のときだけ)
            if overlay.volume > 0.001,
               let sourceAudio = (try? await asset.loadTracks(withMediaType: .audio))?.first,
               let audioRange = try? await sourceAudio.load(.timeRange) {
                let inter = audioRange.intersection(CMTimeRange(start: oSrcStart, end: oSrcEnd))
                if inter.isValid && !inter.isEmpty {
                    let aStart = inter.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
                    let aEnd = inter.end.convertScale(timescale, method: .roundTowardZero)
                    if aEnd > aStart {
                        let at = outStart + scaledDuration(aStart - oSrcStart, speed: speed)
                        let aDuration = aEnd - aStart
                        var aOut = scaledDuration(aDuration, speed: speed)
                        let outEnd = outStart + outDuration
                        if at + aOut > outEnd { aOut = outEnd - at }
                        if aOut > .zero,
                           let lane = availableAudioLane(in: &audioLanes, at: at,
                                                         composition: composition, limit: overlayAudioTrackLimit) {
                            compositionPad(lane.track, to: at)
                            do {
                                try lane.track.insertTimeRange(CMTimeRange(start: aStart, duration: aDuration),
                                                               of: sourceAudio, at: at)
                                if aOut != aDuration {
                                    lane.track.scaleTimeRange(CMTimeRange(start: at, duration: aDuration),
                                                              toDuration: aOut)
                                }
                                lane.addVolume(min(max(overlay.volume, 0), 1), at: at)
                            } catch {
                                // 音声が入らなくても映像は続行
                            }
                        }
                    }
                }
            }

            result.append(VideoCompositorOverlay(overlay: overlay, trackID: track.trackID, preferredTransform: transform))
        }
        return result
    }

    // MARK: - トラック(段)の順

    /// テキストを段の小さい順(同じ段なら開始の早い順)に並べる
    static func sortedByLane(_ clips: [TextClip], lanes: [UUID: Int]) -> [TextClip] {
        clips.sorted { a, b in
            let laneA = lanes[a.id] ?? 0
            let laneB = lanes[b.id] ?? 0
            if laneA != laneB { return laneA < laneB }
            return a.start < b.start
        }
    }

    /// オーバーレイを段の小さい順(同じ段なら元の並び順)に並べる
    static func sortedOverlaysByLane(_ overlays: [VideoCompositorOverlay], lanes: [UUID: Int]) -> [VideoCompositorOverlay] {
        overlays.enumerated().sorted { a, b in
            let laneA = lanes[a.element.id] ?? 0
            let laneB = lanes[b.element.id] ?? 0
            if laneA != laneB { return laneA < laneB }
            return a.offset < b.offset
        }.map { $0.element }
    }

    // MARK: - ナレーション

    /// ナレーションを音声レーンへ入れる(音声エフェクトは処理済みファイルがあればそれを使う)。
    /// 戻り値はダッキング用の区間(タイムライン秒)
    private static func insertNarration(_ clips: [NarrationClip],
                                        into composition: AVMutableComposition,
                                        totalSeconds: Double,
                                        lanes: inout [AudioLane]) async -> [(start: Double, end: Double)] {
        guard !clips.isEmpty, totalSeconds > 0 else { return [] }
        var ranges: [(start: Double, end: Double)] = []
        let sorted = clips.sorted { $0.start < $1.start }
        for clip in sorted {
            guard clip.duration > 0.01, clip.end > 0, clip.start < totalSeconds else { continue }

            var timelineStart = clip.start
            var sourceStartSec = max(0, clip.sourceStart)
            if timelineStart < 0 {
                sourceStartSec += -timelineStart
                timelineStart = 0
            }
            let timelineEnd = min(clip.end, totalSeconds)
            let timelineDuration = timelineEnd - timelineStart
            guard timelineDuration > 0.01 else { continue }

            var url = clip.url
            if !clip.effects.isIdentity,
               let processed = AudioEffectsRenderer.cachedProcessedURL(for: clip.url, effects: clip.effects) {
                url = processed
            }
            let asset = AVURLAsset(url: url)
            guard let sourceAudio = (try? await asset.loadTracks(withMediaType: .audio))?.first,
                  let audioRange = try? await sourceAudio.load(.timeRange) else {
                continue
            }
            let requested = CMTimeRange(start: compositionTime(sourceStartSec, method: .roundTowardPositiveInfinity),
                                        end: compositionTime(sourceStartSec + timelineDuration, method: .roundTowardZero))
            let inter = audioRange.intersection(requested)
            guard inter.isValid, !inter.isEmpty else { continue }
            let aStart = inter.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
            let aEnd = inter.end.convertScale(timescale, method: .roundTowardZero)
            guard aEnd > aStart else { continue }
            let aDuration = aEnd - aStart
            // 素材の先頭が足りない分だけ後ろへずれる
            let at = compositionTime(timelineStart + (aStart.seconds - sourceStartSec), method: .roundHalfAwayFromZero)

            guard let lane = availableAudioLane(in: &lanes, at: at,
                                                composition: composition, limit: narrationTrackLimit) else {
                continue
            }
            compositionPad(lane.track, to: at)
            do {
                try lane.track.insertTimeRange(CMTimeRange(start: aStart, duration: aDuration), of: sourceAudio, at: at)
            } catch {
                continue
            }
            let volume = clip.effectiveVolume
            lane.addVolume(volume.isFinite ? min(max(volume, 0), maxClipVolume) : 1, at: at)
            ranges.append((start: at.seconds, end: (at + aDuration).seconds))
        }
        return ranges
    }

    // MARK: - トラックのプール

    /// 末尾が time 以前の映像トラックを返す。無ければ limit まで新しく作る
    private static func availableVideoTrack(in tracks: inout [AVMutableCompositionTrack],
                                            at time: CMTime,
                                            composition: AVMutableComposition,
                                            limit: Int) -> AVMutableCompositionTrack? {
        for track in tracks where trackEnd(track) <= time {
            return track
        }
        guard tracks.count < limit,
              let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        tracks.append(track)
        return track
    }

    /// 末尾が time 以前の音声レーンを返す。無ければ limit まで新しく作る
    private static func availableAudioLane(in lanes: inout [AudioLane],
                                           at time: CMTime,
                                           composition: AVMutableComposition,
                                           limit: Int) -> AudioLane? {
        for lane in lanes where lane.end <= time {
            return lane
        }
        guard lanes.count < limit,
              let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let lane = AudioLane(track: track)
        lanes.append(lane)
        return lane
    }

    /// 1 本の音声トラックと、その上に置いた区間ごとの音量(段階的な設定とランプ。時刻は昇順)
    private final class AudioLane {
        let track: AVMutableCompositionTrack

        private enum Event {
            case set(time: CMTime, volume: Float)
            case ramp(range: CMTimeRange, from: Float, to: Float)
        }

        private var events: [Event] = []
        /// 最後に設定した時刻(AVAudioMix は昇順・重なりなしを要求する)
        private var lastTime: CMTime = .zero

        init(track: AVMutableCompositionTrack) {
            self.track = track
        }

        var end: CMTime {
            let e = track.timeRange.end
            return (e.isValid && e.isNumeric) ? e : .zero
        }

        var isEmpty: Bool { events.isEmpty }

        /// time 以降の音量(時刻は昇順に追加する)
        func addVolume(_ volume: Float, at time: CMTime) {
            guard events.isEmpty || time >= lastTime else { return }
            events.append(.set(time: time, volume: volume))
            lastTime = time
        }

        /// at から duration の区間を volume にし、先頭 fadeIn 秒でフェードイン・末尾 fadeOut 秒でフェードアウトする
        func addSegment(at: CMTime, duration: CMTime, volume: Float, fadeIn: Double, fadeOut: Double) {
            guard duration > .zero, events.isEmpty || at >= lastTime else { return }
            let durationSec = duration.seconds
            let fin = (fadeIn.isFinite && fadeIn > 0.01) ? min(fadeIn, durationSec / 2) : 0
            let fout = (fadeOut.isFinite && fadeOut > 0.01) ? min(fadeOut, durationSec / 2) : 0
            let end = at + duration

            if fin > 0 {
                let range = CMTimeRange(start: at, duration: CMTime(seconds: fin, preferredTimescale: CompositionBuilder.timescale))
                events.append(.ramp(range: range, from: 0, to: volume))
                lastTime = range.end
            } else {
                events.append(.set(time: at, volume: volume))
                lastTime = at
            }
            if fout > 0 {
                let start = end - CMTime(seconds: fout, preferredTimescale: CompositionBuilder.timescale)
                if start >= lastTime && end > start {
                    events.append(.ramp(range: CMTimeRange(start: start, end: end), from: volume, to: 0))
                    lastTime = end
                }
            }
        }

        func makeParameters() -> AVMutableAudioMixInputParameters {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTimePitchAlgorithm = .spectral
            if let first = events.first {
                switch first {
                case .set(let time, let volume):
                    if time > .zero { params.setVolume(volume, at: .zero) }
                case .ramp(let range, _, _):
                    if range.start > .zero { params.setVolume(0, at: .zero) }
                }
            }
            for event in events {
                switch event {
                case .set(let time, let volume):
                    params.setVolume(volume, at: time)
                case .ramp(let range, let from, let to):
                    params.setVolumeRamp(fromStartVolume: from, toEndVolume: to, timeRange: range)
                }
            }
            return params
        }
    }

    // MARK: - オートダッキング

    /// 話している区間(字幕・ナレーション)を [0, total] に収め、0.6 秒未満の隙間は結合する
    private static func compositionDuckIntervals(_ ranges: [(start: Double, end: Double)],
                                                 total: Double) -> [(start: Double, end: Double)] {
        guard total > 0 else { return [] }
        let sorted = ranges
            .filter { $0.end > $0.start && $0.end > 0 && $0.start < total }
            .sorted { $0.start < $1.start }
        var result: [(start: Double, end: Double)] = []
        for range in sorted {
            let s = max(0, range.start)
            let e = min(total, range.end)
            guard e > s else { continue }
            if let last = result.last, s - last.end < 0.6 {
                result[result.count - 1] = (start: last.start, end: max(last.end, e))
            } else {
                result.append((start: s, end: e))
            }
        }
        return result
    }

    /// ダッキング(0.3 秒のランプ)と最後のフェードアウトを、重ならない連続ランプとして設定する
    private static func compositionApplyBGMEnvelope(_ params: AVMutableAudioMixInputParameters,
                                                    volume: Float,
                                                    duckLevel: Float,
                                                    intervals: [(start: Double, end: Double)],
                                                    total: Double,
                                                    fadeOut: Bool) {
        let ramp = 0.3
        let ducked = volume * min(max(duckLevel, 0), 1)
        let fadeLength = fadeOut ? min(2.0, total) : 0
        let fadeStart = total - fadeLength

        // ダッキングのみを反映した音量
        func duckedVolume(_ t: Double) -> Float {
            var v = volume
            for iv in intervals {
                if t >= iv.start && t <= iv.end { return ducked }
                if t < iv.start && t > iv.start - ramp {
                    let p = Float((iv.start - t) / ramp)
                    v = min(v, ducked + (volume - ducked) * p)
                } else if t > iv.end && t < iv.end + ramp {
                    let p = Float((t - iv.end) / ramp)
                    v = min(v, ducked + (volume - ducked) * p)
                }
            }
            return v
        }
        // フェードアウトも掛けた最終音量
        func finalVolume(_ t: Double) -> Float {
            var v = duckedVolume(t)
            if fadeLength > 0 && t > fadeStart {
                v *= Float(max(0, (total - t) / fadeLength))
            }
            return v
        }

        var candidates: [Double] = [0, total]
        for iv in intervals {
            candidates.append(iv.start - ramp)
            candidates.append(iv.start)
            candidates.append(iv.end)
            candidates.append(iv.end + ramp)
        }
        if fadeLength > 0 { candidates.append(fadeStart) }
        let clampedTimes = candidates.map { min(max($0, 0), total) }.sorted()
        var points: [Double] = []
        for t in clampedTimes {
            if let last = points.last, t - last < 0.002 { continue }
            points.append(t)
        }

        params.setVolume(finalVolume(0), at: .zero)
        guard points.count >= 2 else { return }
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let start = CMTime(seconds: a, preferredTimescale: timescale)
            let end = CMTime(seconds: b, preferredTimescale: timescale)
            guard end > start else { continue }
            params.setVolumeRamp(fromStartVolume: finalVolume(a),
                                 toEndVolume: finalVolume(b),
                                 timeRange: CMTimeRange(start: start, end: end))
        }
    }

    // MARK: - ヘルパー

    private static func compositionTime(_ seconds: Double, method: CMTimeRoundingMethod) -> CMTime {
        guard seconds.isFinite else { return .zero }
        return CMTime(seconds: max(0, seconds), preferredTimescale: 60000).convertScale(timescale, method: method)
    }

    /// 速度を反映した出力上の長さ(timescale 600)
    private static func scaledDuration(_ duration: CMTime, speed: Double) -> CMTime {
        if abs(speed - 1) < 0.0001 {
            return duration.convertScale(timescale, method: .roundHalfAwayFromZero)
        }
        let seconds = duration.seconds / speed
        guard seconds.isFinite, seconds > 0 else { return .zero }
        return CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// トラック末尾(無効なら 0)
    private static func trackEnd(_ track: AVMutableCompositionTrack) -> CMTime {
        let end = track.timeRange.end
        return (end.isValid && end.isNumeric) ? end : .zero
    }

    /// トラック末尾が time より前なら空区間を挿入して揃える
    private static func compositionPad(_ track: AVMutableCompositionTrack, to time: CMTime) {
        let currentEnd = trackEnd(track)
        if currentEnd < time {
            track.insertEmptyTimeRange(CMTimeRange(start: currentEnd, end: time))
        }
    }

    /// 元素材上の範囲 [sourceStart, sourceEnd) をアングル番号ごとの区間に分割する
    private static func compositionAngleRuns(multicam: MulticamInfo,
                                             sourceStart: Double,
                                             sourceEnd: Double) -> [(start: Double, end: Double, angle: Int)] {
        var runs: [(start: Double, end: Double, angle: Int)] = []
        var current = multicam.angleIndex(at: sourceStart)
        var runStart = sourceStart
        let sorted = multicam.switches.sorted { $0.time < $1.time }
        for sw in sorted where sw.time > sourceStart && sw.time < sourceEnd {
            let angle = min(max(sw.angle, 0), multicam.angles.count)
            if angle != current {
                if sw.time - runStart > 0.001 {
                    runs.append((start: runStart, end: sw.time, angle: current))
                }
                runStart = sw.time
                current = angle
            }
        }
        if sourceEnd - runStart > 0.001 {
            runs.append((start: runStart, end: sourceEnd, angle: current))
        }
        return runs
    }

    private static func loadAngleSource(_ angle: CameraAngle) async -> CompositionAngleSource? {
        let asset = AVURLAsset(url: angle.url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        do {
            let (range, transform) = try await track.load(.timeRange, .preferredTransform)
            return CompositionAngleSource(track: track, timeRange: range, transform: transform)
        } catch {
            return nil
        }
    }
}

/// 読み込み済みアングル素材(黒のダミー映像にも使う)
struct CompositionAngleSource {
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
}

// MARK: - 黒のダミー映像(Caches に 1 回だけ生成)

/// 静止画クリップや読めないクリップのために、コンポジションの長さを確保する小さな黒い mp4。
/// フレームは描画に使わない(コンポジタが画像または黒を描く)。
enum CompositionPlaceholder {

    static let pixelSize = 64
    private static let lock = NSLock()
    private static var cachedURL: URL?

    private static var fileURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("VideoMania", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("placeholder_black_64_v1.mp4")
    }

    /// 黒のダミー映像(1 秒、64×64)。無ければ生成する。失敗したら nil
    static func blackVideoURL() async -> URL? {
        lock.lock()
        let cached = cachedURL
        lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }

        guard let url = fileURL else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            remember(url)
            return url
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent("placeholder_\(UUID().uuidString).mp4")
        let ok = await writeBlackVideo(to: temp)
        guard ok else {
            try? fm.removeItem(at: temp)
            return nil
        }
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: temp)
        } else {
            do {
                try fm.moveItem(at: temp, to: url)
            } catch {
                try? fm.removeItem(at: temp)
                if !fm.fileExists(atPath: url.path) { return nil }
            }
        }
        remember(url)
        return url
    }

    /// 壊れていたファイルを捨てる(次回作り直す)
    static func discard(_ url: URL) {
        lock.lock()
        if cachedURL == url { cachedURL = nil }
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    private static func remember(_ url: URL) {
        lock.lock()
        cachedURL = url
        lock.unlock()
    }

    private static func writeBlackVideo(to url: URL) async -> Bool {
        let size = pixelSize
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        var created: CVPixelBuffer? = nil
        if let pool = adaptor.pixelBufferPool {
            _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        }
        if created == nil {
            _ = CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                                    attributes as CFDictionary, &created)
        }
        guard let pixelBuffer = created else {
            writer.cancelWriting()
            return false
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let total = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
            memset(base, 0, total)
            // BGRA のアルファを不透明に
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var i = 3
            while i < total {
                bytes[i] = 255
                i += 4
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let frameCount = 10
        for index in 0..<frameCount {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 1
            }
            guard input.isReadyForMoreMediaData else { break }
            let time = CMTime(value: CMTimeValue(index), timescale: 10)
            if !adaptor.append(pixelBuffer, withPresentationTime: time) { break }
        }
        guard writer.status == .writing else {
            writer.cancelWriting()
            return false
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        return writer.status == .completed
    }
}

/// 偶数の整数に丸める(最小 2)
private func compositionEven(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 2 }
    let v = Int((value / 2).rounded()) * 2
    return CGFloat(max(2, v))
}
