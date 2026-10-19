import Foundation
import AVFoundation
import CoreGraphics

// =====================================================================
// CompositionBuilder: ProjectSnapshot → AVComposition + AVVideoComposition + AVAudioMix
//
// トラック構成:
//   映像: メイン 1 本 + マルチカムのアングル A/B + オーバーレイ動画(重なる分だけ増やす小さなプール)
//   音声: クリップ音声 A/B(偶数クリップ → A、奇数 → B。J/L カットで隣と重なれる)
//         + オーバーレイ音声(volume > 0 のみ) + ナレーション + BGM
// =====================================================================

enum RenderPurpose { case preview, export }

struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let renderSize: CGSize
    let duration: CMTime
}

enum CompositionBuilderError: LocalizedError {
    case noClips
    case noVideo
    case cannotCreateTrack

    var errorDescription: String? {
        switch self {
        case .noClips: return "クリップがありません"
        case .noVideo: return "再生できる映像トラックがありません"
        case .cannotCreateTrack: return "合成トラックを作成できませんでした"
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

    /// クリップ音声の最大音量(originalVolume × gain の上限)
    private static let maxClipVolume: Float = 4

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

    // MARK: - build

    static func build(_ snapshot: ProjectSnapshot, purpose: RenderPurpose) async throws -> BuiltComposition {
        guard !snapshot.clips.isEmpty else { throw CompositionBuilderError.noClips }

        let size = renderSize(for: snapshot, purpose: purpose)
        let composition = AVMutableComposition()
        guard let mainVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionBuilderError.cannotCreateTrack
        }

        // クリップ音声の A/B レーン(偶数クリップ → 0、奇数クリップ → 1)
        var clipLanes: [AudioLane?] = [nil, nil]
        var angleTracks: [AVMutableCompositionTrack] = []
        var nextAngleTrackIndex = 0
        var instructions: [VideoCompositorInstruction] = []
        var clipBoundaries: [Double] = []
        var cursor = CMTime.zero

        // アングル素材の読み込みキャッシュ
        var angleCache: [URL: CompositionAngleSource] = [:]

        // 隣のクリップの出力長(J/L カットが隣のさらに隣へ食い込まないように使う)
        let clipOutputDurations = snapshot.clips.map { $0.outputDuration }
        var placedClipIndex = 0

        for (clipIndex, clip) in snapshot.clips.enumerated() {
            let asset = AVURLAsset(url: clip.url)
            let videoTracks: [AVAssetTrack]
            do {
                videoTracks = try await asset.loadTracks(withMediaType: .video)
            } catch {
                continue
            }
            guard let sourceVideo = videoTracks.first else { continue }
            let (trackRange, mainTransform) = try await sourceVideo.load(.timeRange, .preferredTransform)

            let speed = max(clip.speed, 0.01)

            // ソース範囲(トラックの範囲に収める)
            var srcStart = compositionTime(max(0, clip.startTime), method: .roundHalfAwayFromZero)
            var srcEnd = compositionTime(clip.endTime, method: .roundTowardZero)
            let trackStart = trackRange.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
            let trackEnd = trackRange.end.convertScale(timescale, method: .roundTowardZero)
            if srcStart < trackStart { srcStart = trackStart }
            if srcEnd > trackEnd { srcEnd = trackEnd }
            guard srcEnd > srcStart else { continue }
            let srcDuration = srcEnd - srcStart
            let outDuration = scaledDuration(srcDuration, speed: speed)
            guard outDuration > .zero else { continue }

            // --- メイン映像
            do {
                try mainVideoTrack.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDuration),
                                                   of: sourceVideo, at: cursor)
            } catch {
                continue
            }
            if outDuration != srcDuration {
                mainVideoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: srcDuration),
                                              toDuration: outDuration)
            }
            let clipOutRange = CMTimeRange(start: cursor, duration: outDuration)
            let clipOutEnd = clipOutRange.end

            // --- クリップ音声(マルチカムでもメインの音声。ゲイン・J/L カット・速度を反映)
            if !clip.isMuted && clip.hasAudio {
                if let sourceAudio = (try? await asset.loadTracks(withMediaType: .audio))?.first,
                   let audioRange = try? await sourceAudio.load(.timeRange) {
                    let laneIndex = placedClipIndex % 2
                    if clipLanes[laneIndex] == nil,
                       let track = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
                        clipLanes[laneIndex] = AudioLane(track: track)
                    }
                    if let lane = clipLanes[laneIndex] {
                        let previousOut = clipIndex > 0 ? clipOutputDurations[clipIndex - 1] : 0
                        let nextOut = clipIndex + 1 < clipOutputDurations.count ? clipOutputDurations[clipIndex + 1] : 0
                        if let placement = clipAudioPlacement(audioRange: audioRange,
                                                              srcStart: srcStart,
                                                              srcEnd: srcEnd,
                                                              speed: speed,
                                                              leadIn: clip.audio.audioLeadIn,
                                                              tailOut: clip.audio.audioTailOut,
                                                              cursor: cursor,
                                                              maxLeadTimeline: previousOut,
                                                              maxTailTimeline: nextOut,
                                                              laneEnd: lane.end) {
                            compositionPad(lane.track, to: placement.at)
                            do {
                                try lane.track.insertTimeRange(placement.sourceRange, of: sourceAudio, at: placement.at)
                                if placement.outDuration != placement.sourceRange.duration {
                                    lane.track.scaleTimeRange(CMTimeRange(start: placement.at,
                                                                          duration: placement.sourceRange.duration),
                                                              toDuration: placement.outDuration)
                                }
                                let gain = clip.audio.gain.isFinite ? max(0, clip.audio.gain) : 1
                                let volume = min(snapshot.audio.originalVolume * gain, maxClipVolume)
                                lane.addVolume(volume, at: placement.at)
                            } catch {
                                // 音声が入らなくても映像は続行
                            }
                        }
                    }
                }
            }

            // --- マルチカム
            var segments: [VideoCompositorAngleSegment] = []
            if clip.multicam.isActive {
                let runs = compositionAngleRuns(multicam: clip.multicam,
                                                sourceStart: srcStart.seconds,
                                                sourceEnd: srcEnd.seconds)
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

                    let angleSrcStart = compositionTime(rangeStartSec, method: .roundTowardPositiveInfinity)
                    var angleSrcEnd = compositionTime(rangeEndSec, method: .roundTowardZero)
                    let angleTrackEnd = angleSource.timeRange.end.convertScale(timescale, method: .roundTowardZero)
                    if angleSrcEnd > angleTrackEnd { angleSrcEnd = angleTrackEnd }
                    guard angleSrcEnd > angleSrcStart else { continue }
                    let angleSrcDuration = angleSrcEnd - angleSrcStart

                    // 出力タイムライン上の位置
                    let mainSourceStart = compositionTime(rangeStartSec - angle.offset, method: .roundHalfAwayFromZero)
                    var offsetInClip = mainSourceStart - srcStart
                    if offsetInClip < .zero { offsetInClip = .zero }
                    let outStart = cursor + scaledDuration(offsetInClip, speed: speed)
                    var segOut = scaledDuration(angleSrcDuration, speed: speed)
                    if outStart >= clipOutEnd { continue }
                    if outStart + segOut > clipOutEnd { segOut = clipOutEnd - outStart }
                    guard segOut > .zero else { continue }

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
                    let existingEnd = angleTrack.timeRange.end
                    if existingEnd.isValid && existingEnd > outStart { continue }
                    compositionPad(angleTrack, to: outStart)
                    do {
                        try angleTrack.insertTimeRange(CMTimeRange(start: angleSrcStart, duration: angleSrcDuration),
                                                       of: angleSource.track, at: outStart)
                    } catch {
                        continue
                    }
                    if segOut != angleSrcDuration {
                        angleTrack.scaleTimeRange(CMTimeRange(start: outStart, duration: angleSrcDuration),
                                                  toDuration: segOut)
                    }
                    nextAngleTrackIndex += 1
                    segments.append(VideoCompositorAngleSegment(
                        timeRange: CMTimeRange(start: outStart, duration: segOut),
                        trackID: angleTrack.trackID,
                        transform: angleSource.transform))
                }
            }

            // --- 字幕(このクリップ区間に重なるもの)
            let clipStartSec = clipOutRange.start.seconds
            let clipEndSec = clipOutEnd.seconds
            var subtitles: [VideoCompositorSubtitle] = []
            for cue in snapshot.subtitles where cue.end > clipStartSec && cue.start < clipEndSec && cue.end > cue.start {
                let lines = cue.displayLines(mode: snapshot.subtitleStyle.displayMode)
                if !lines.isEmpty {
                    subtitles.append(VideoCompositorSubtitle(start: cue.start, end: cue.end, lines: lines))
                }
            }

            if !instructions.isEmpty {
                clipBoundaries.append(clipOutRange.start.seconds)
            }
            instructions.append(VideoCompositorInstruction(
                timeRange: clipOutRange,
                mainTrackID: mainVideoTrack.trackID,
                mainTransform: mainTransform,
                angleSegments: segments,
                filter: clip.filter,
                subtitles: subtitles,
                subtitleStyle: snapshot.subtitleStyle,
                scaling: snapshot.canvas.scaling,
                renderSize: size))

            cursor = clipOutEnd
            placedClipIndex += 1
        }

        guard !instructions.isEmpty, cursor > .zero else { throw CompositionBuilderError.noVideo }
        let totalDuration = cursor
        let totalSeconds = totalDuration.seconds

        // --- オーバーレイ(Bロール / ワイプ / 写真)
        var overlayLanes: [AudioLane] = []
        let overlayInfos = await insertOverlays(snapshot.overlays,
                                                into: composition,
                                                totalSeconds: totalSeconds,
                                                audioLanes: &overlayLanes)
        if !overlayInfos.isEmpty {
            instructions = instructions.map { $0.withMediaOverlays(overlayInfos) }
        }

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
            clipBoundaries: clipBoundaries)
        instructions = instructions.map { $0.withDocumentary(documentaryInfo) }

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
        let compositionDuration = composition.duration
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
            let trackEnd = trackRange.end.convertScale(timescale, method: .roundTowardZero)

            var oSrcStart = compositionTime(sourceStartSec, method: .roundTowardPositiveInfinity)
            var oSrcEnd = compositionTime(sourceStartSec + timelineDuration * speed, method: .roundTowardZero)
            if oSrcStart < trackStart { oSrcStart = trackStart }
            if oSrcEnd > trackEnd { oSrcEnd = trackEnd }
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

    // MARK: - ナレーション

    /// ナレーションを音声レーンへ入れる。戻り値はダッキング用の区間(タイムライン秒)
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

            let asset = AVURLAsset(url: clip.url)
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
        for track in tracks {
            let end = track.timeRange.end
            let currentEnd = (end.isValid && end.isNumeric) ? end : .zero
            if currentEnd <= time { return track }
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

    /// 1 本の音声トラックと、その上に置いた区間ごとの音量
    private final class AudioLane {
        let track: AVMutableCompositionTrack
        private var events: [(time: CMTime, volume: Float)] = []

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
            if let last = events.last {
                if last.time == time {
                    events[events.count - 1] = (time: time, volume: volume)
                    return
                }
                if last.time > time { return }
            }
            events.append((time: time, volume: volume))
        }

        func makeParameters() -> AVMutableAudioMixInputParameters {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTimePitchAlgorithm = .spectral
            if let first = events.first, first.time > .zero {
                params.setVolume(first.volume, at: .zero)
            }
            for event in events {
                params.setVolume(event.volume, at: event.time)
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
        return CMTime(seconds: seconds, preferredTimescale: 60000).convertScale(timescale, method: method)
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

    /// トラック末尾が time より前なら空区間を挿入して揃える
    private static func compositionPad(_ track: AVMutableCompositionTrack, to time: CMTime) {
        let end = track.timeRange.end
        let currentEnd = (end.isValid && end.isNumeric) ? end : .zero
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

/// 読み込み済みアングル素材
struct CompositionAngleSource {
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
}

/// 偶数の整数に丸める(最小 2)
private func compositionEven(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 2 }
    let v = Int((value / 2).rounded()) * 2
    return CGFloat(max(2, v))
}
