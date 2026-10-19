import Foundation
import AVFoundation
import CoreGraphics

// =====================================================================
// CompositionBuilder: ProjectSnapshot → AVComposition + AVVideoComposition + AVAudioMix
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

        var clipAudioTrack: AVMutableCompositionTrack? = nil
        var angleTracks: [AVMutableCompositionTrack] = []
        var nextAngleTrackIndex = 0
        var instructions: [VideoCompositorInstruction] = []
        var cursor = CMTime.zero

        // アングル素材の読み込みキャッシュ
        var angleCache: [URL: CompositionAngleSource] = [:]

        for clip in snapshot.clips {
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

            // --- クリップ音声(マルチカムでもメインの音声)
            if !clip.isMuted && clip.hasAudio {
                if let sourceAudio = (try? await asset.loadTracks(withMediaType: .audio))?.first,
                   let audioRange = try? await sourceAudio.load(.timeRange) {
                    let inter = audioRange.intersection(CMTimeRange(start: srcStart, end: srcEnd))
                    if inter.isValid && !inter.isEmpty {
                        let aStart = inter.start.convertScale(timescale, method: .roundTowardPositiveInfinity)
                        let aEnd = inter.end.convertScale(timescale, method: .roundTowardZero)
                        if aEnd > aStart {
                            if clipAudioTrack == nil {
                                clipAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
                            }
                            if let audioTrack = clipAudioTrack {
                                var at = cursor + scaledDuration(aStart - srcStart, speed: speed)
                                let currentEnd = audioTrack.timeRange.end
                                if currentEnd.isValid && currentEnd > at { at = currentEnd }
                                let aDuration = aEnd - aStart
                                var aOut = scaledDuration(aDuration, speed: speed)
                                if at + aOut > clipOutEnd { aOut = clipOutEnd - at }
                                if aOut > .zero {
                                    compositionPad(audioTrack, to: at)
                                    do {
                                        try audioTrack.insertTimeRange(CMTimeRange(start: aStart, duration: aDuration),
                                                                       of: sourceAudio, at: at)
                                        if aOut != aDuration {
                                            audioTrack.scaleTimeRange(CMTimeRange(start: at, duration: aDuration),
                                                                      toDuration: aOut)
                                        }
                                    } catch {
                                        // 音声が入らなくても映像は続行
                                    }
                                }
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
        }

        guard !instructions.isEmpty, cursor > .zero else { throw CompositionBuilderError.noVideo }
        let totalDuration = cursor

        // --- BGM(ループして全体長に合わせる)
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        if let clipAudioTrack {
            let params = AVMutableAudioMixInputParameters(track: clipAudioTrack)
            params.setVolume(snapshot.audio.originalVolume, at: .zero)
            params.audioTimePitchAlgorithm = .spectral
            audioParameters.append(params)
        }

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
