import Foundation
import AVFoundation
import CoreImage
import CoreVideo

// =====================================================================
// VideoCompositor: カスタム AVVideoCompositing
// プレビュー(AVPlayerItem)と書き出し(AVAssetReaderVideoCompositionOutput)で
// 同じ描画になるよう、全ての処理をここで行う。
//
// 1 フレームの手順:
//   クリップ(1 つ、またはトランジション中は 2 つ)
//     ソース(トラック / 静止画)→ 向き → ジオメトリ → フィルタ → キャンバスに配置 → ルック → イン/アウト
//   → トランジション合成 → Bロール/ワイプ → 周辺減光・粒子 → 章タイトル/テロップ
//   → 手書き → テキストレイヤー → 字幕 → 黒帯・黒フェード → 透かし
// =====================================================================

/// マルチカムのアングル区間(出力タイムライン上)
struct VideoCompositorAngleSegment {
    let timeRange: CMTimeRange
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
}

/// 出力タイムライン上の字幕(表示行は事前計算済み)
struct VideoCompositorSubtitle {
    let start: Double
    let end: Double
    let lines: [String]
    /// 単語タイミング(カラオケ風テンプレート用。空なら通常描画)
    let words: [SubtitleWord]
    /// cue.text(1 行目が原文かどうかの判定に使う)
    let originalText: String

    init(start: Double, end: Double, lines: [String], words: [SubtitleWord] = [], originalText: String = "") {
        self.start = start
        self.end = end
        self.lines = lines
        self.words = words
        self.originalText = originalText
    }
}

/// メイン映像の上に重ねる Bロール / ワイプ / 写真(コンポジタ命令に渡すプレーンデータ)
/// 時刻はすべて出力タイムライン上の秒。
struct VideoCompositorOverlay {
    let id: UUID
    /// 動画オーバーレイのコンポジショントラック。写真(または挿入できなかった動画)は nil
    let trackID: CMPersistentTrackID?
    let isImage: Bool
    let url: URL
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let start: Double
    let duration: Double
    let speed: Double
    let sourceStart: Double
    let frame: NormalizedRect
    /// 枠の中心まわりの回転(度、時計回りが正)
    let rotation: Double
    let fit: OverlayFit
    let opacity: Double
    let cornerRadius: Double
    let kenBurns: KenBurns
    let filter: FilterSettings
    let fadeIn: Double
    let fadeOut: Double
    /// 位置・大きさ・回転・不透明度のキーフレーム(start からの相対秒)
    let keyframes: [Keyframe]
    /// CoreImage のブレンドフィルタ名(nil = 通常の重ね合わせ)
    let blendMode: String?
    /// マスク(中心・大きさはオーバーレイの枠を基準)
    let mask: MaskSettings
    /// 写真の 3D ズーム(奥行き)。有効なら Ken Burns の代わりに使う
    let parallax: DepthParallax

    init(overlay: OverlayClip, trackID: CMPersistentTrackID?, preferredTransform: CGAffineTransform? = nil) {
        self.id = overlay.id
        self.trackID = trackID
        self.isImage = overlay.isImage
        self.url = overlay.url
        self.naturalSize = overlay.naturalSize
        self.preferredTransform = preferredTransform ?? overlay.preferredTransform
        self.start = overlay.start
        self.duration = overlay.duration
        self.speed = max(overlay.speed, 0.01)
        self.sourceStart = overlay.sourceStart
        self.frame = overlay.frame.clamped()
        self.rotation = overlay.rotation
        self.fit = overlay.fit
        self.opacity = min(max(overlay.opacity, 0), 1)
        self.cornerRadius = min(max(overlay.cornerRadius, 0), 0.5)
        self.kenBurns = overlay.kenBurns
        self.filter = overlay.filter
        self.fadeIn = max(0, overlay.fadeIn)
        self.fadeOut = max(0, overlay.fadeOut)
        self.keyframes = overlay.keyframes
        self.blendMode = overlay.blendMode
        self.mask = overlay.mask
        self.parallax = overlay.parallax
    }

    var end: Double { start + duration }

    /// 動画を描くために必要なソーストラックか(写真は不要)
    var needsSourceFrame: Bool { !isImage && trackID != nil }

    func contains(timelineTime time: Double) -> Bool {
        time >= start && time < end
    }

    func intersects(_ range: CMTimeRange) -> Bool {
        let rs = range.start.seconds
        let re = range.end.seconds
        guard rs.isFinite, re.isFinite else { return true }
        return end > rs && start < re
    }

    /// 進行度 0...1(Ken Burns 用)
    func progress(at time: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max((time - start) / duration, 0), 1)
    }

    /// フェードイン/アウトだけの係数 0...1(不透明度は含まない)
    func fadeFactor(at time: Double) -> Double {
        guard duration > 0 else { return 0 }
        let local = time - start
        guard local >= 0, local <= duration else { return 0 }
        var factor = 1.0
        if fadeIn > 0, local < fadeIn {
            factor = min(factor, local / fadeIn)
        }
        if fadeOut > 0, duration - local < fadeOut {
            factor = min(factor, (duration - local) / fadeOut)
        }
        return max(0, min(1, factor))
    }

    /// フェードを含む不透明度(OverlayClip.effectiveOpacity と同じ計算)
    func effectiveOpacity(at time: Double) -> Double {
        fadeFactor(at: time) * opacity
    }
}

/// 速度カーブの等速区間(出力タイムライン上の秒と、その区間の再生速度)
struct VideoCompositorSpeedSegment {
    let start: Double
    let end: Double
    let speed: Double
    /// この区間の先頭に対応する素材ファイル上の秒(逆再生では逆再生済みファイル上の秒)
    var sourceStart: Double = 0
}

/// 1 クリップ分の描画情報(トランジション中は 2 つの層になる)
struct VideoCompositorClipLayer {
    let clipID: UUID
    /// 映像のコンポジショントラック。静止画・読めなかったクリップは nil
    let trackID: CMPersistentTrackID?
    /// 静止画などでトラックの長さを確保するために入れた黒のダミー映像(フレームは使わない)
    let placeholderTrackID: CMPersistentTrackID?
    let transform: CGAffineTransform
    let angleSegments: [VideoCompositorAngleSegment]
    /// 静止画クリップの画像
    let stillImageURL: URL?
    let filter: FilterSettings
    let geometry: ClipGeometry
    let animation: ClipAnimation
    /// 速度カーブ(smoothSlow 用)。等速なら 1 要素または空
    let speedSegments: [VideoCompositorSpeedSegment]
    let smoothSlow: Bool
    /// このクリップの出力上の開始・終了(トランジションの重なりを含む実際の表示範囲)
    let start: Double
    let end: Double
    /// マスク(キャンバス基準)
    var mask: MaskSettings = MaskSettings()
    /// 自動リフレーム(人物追尾)。samples は元素材上の秒
    var reframe: ReframeTrack = ReframeTrack()
    /// 手ぶれ補正。samples は元素材上の秒
    var stabilization: StabilizationTrack = StabilizationTrack()
    /// ノイズ除去・美肌・簡易高画質化
    var enhance: ClipEnhancements = ClipEnhancements()
    /// 静止画クリップの 3D ズーム
    var parallax: DepthParallax = DepthParallax()
    /// 逆再生のとき元素材の全長(逆再生済みファイル上の秒 → 元素材上の秒 の変換に使う)。通常は nil
    var reversedSourceDuration: Double? = nil

    var duration: Double { max(0, end - start) }
    var hasPicture: Bool { trackID != nil || stillImageURL != nil }

    /// 出力時刻 t に対応する元素材上の秒(リフレーム・手ぶれ補正のサンプル参照用)。速度区間が無ければ nil
    func sourceTime(at t: Double) -> Double? {
        guard let first = speedSegments.first, let last = speedSegments.last else { return nil }
        var segment = last
        if t < first.start {
            segment = first
        } else {
            for seg in speedSegments where t >= seg.start && t < seg.end {
                segment = seg
                break
            }
        }
        let local = min(max(t - segment.start, 0), max(0, segment.end - segment.start))
        let fileTime = segment.sourceStart + local * segment.speed
        if let total = reversedSourceDuration {
            return max(0, total - fileTime)
        }
        return fileTime
    }

    /// コンポジタが必要とするソーストラック
    var requiredTrackIDs: [CMPersistentTrackID] {
        var ids: [CMPersistentTrackID] = []
        if let trackID { ids.append(trackID) }
        if let placeholderTrackID, !ids.contains(placeholderTrackID) { ids.append(placeholderTrackID) }
        for seg in angleSegments where !ids.contains(seg.trackID) {
            ids.append(seg.trackID)
        }
        return ids
    }

    func angleSegment(at time: CMTime) -> VideoCompositorAngleSegment? {
        for seg in angleSegments where seg.timeRange.containsTime(time) {
            return seg
        }
        return nil
    }

    /// 出力時刻 t でのローカル再生速度(1 = 等速)
    func localSpeed(at t: Double) -> Double {
        for seg in speedSegments where t >= seg.start && t < seg.end {
            return seg.speed
        }
        return speedSegments.last?.speed ?? 1
    }
}

/// クリップ間のトランジション(出力タイムライン上)
struct VideoCompositorTransition {
    let type: TransitionType
    /// 重なりの開始(= 次のクリップの開始)
    let start: Double
    let duration: Double

    func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((time - start) / duration, 0), 1)
    }
}

/// 作品全体で共通の描画情報(全命令で同じインスタンスを参照する。生成後は変更しない)
final class VideoCompositorScene {
    let renderSize: CGSize
    let scaling: ScalingMode
    let subtitles: [VideoCompositorSubtitle]
    let subtitleStyle: SubtitleStyle
    let textClips: [TextClip]
    let drawings: [DrawingClip]
    let watermark: WatermarkSettings
    let documentary: DocumentaryRenderInfo
    /// Bロール / ワイプ / 写真(開始時刻順)
    let mediaOverlays: [VideoCompositorOverlay]
    let totalDuration: Double

    init(renderSize: CGSize,
         scaling: ScalingMode,
         subtitles: [VideoCompositorSubtitle],
         subtitleStyle: SubtitleStyle,
         textClips: [TextClip],
         drawings: [DrawingClip],
         watermark: WatermarkSettings,
         documentary: DocumentaryRenderInfo,
         mediaOverlays: [VideoCompositorOverlay],
         totalDuration: Double) {
        self.renderSize = renderSize
        self.scaling = scaling
        self.subtitles = subtitles
        self.subtitleStyle = subtitleStyle
        self.textClips = textClips
        self.drawings = drawings
        self.watermark = watermark
        self.documentary = documentary
        self.mediaOverlays = mediaOverlays
        self.totalDuration = totalDuration
    }

    static let empty = VideoCompositorScene(renderSize: CGSize(width: 2, height: 2),
                                            scaling: .fit,
                                            subtitles: [],
                                            subtitleStyle: SubtitleStyle(),
                                            textClips: [],
                                            drawings: [],
                                            watermark: WatermarkSettings(),
                                            documentary: .empty,
                                            mediaOverlays: [],
                                            totalDuration: 0)
}

/// 1 区間分の描画指示(プレーンデータのみ保持)
final class VideoCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    // AVVideoCompositionInstructionProtocol
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// 1 つ(単独区間)または 2 つ(トランジション区間: [終わるクリップ, 始まるクリップ])
    let layers: [VideoCompositorClipLayer]
    let transition: VideoCompositorTransition?
    let scene: VideoCompositorScene

    init(timeRange: CMTimeRange,
         layers: [VideoCompositorClipLayer],
         transition: VideoCompositorTransition?,
         scene: VideoCompositorScene) {
        self.timeRange = timeRange
        self.layers = layers
        self.transition = transition
        self.scene = scene

        var ids: [CMPersistentTrackID] = []
        for layer in layers {
            for id in layer.requiredTrackIDs where !ids.contains(id) {
                ids.append(id)
            }
        }
        for overlay in scene.mediaOverlays {
            if let trackID = overlay.trackID, overlay.intersects(timeRange), !ids.contains(trackID) {
                ids.append(trackID)
            }
        }
        self.requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
        super.init()
    }

    /// 同じ内容で timeRange だけ差し替えたコピー
    func withTimeRange(_ newRange: CMTimeRange) -> VideoCompositorInstruction {
        VideoCompositorInstruction(timeRange: newRange, layers: layers, transition: transition, scene: scene)
    }
}

enum VideoCompositorError: Error {
    case noOutputBuffer
}

final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    private let renderQueue = DispatchQueue(label: "VideoEditor.VideoCompositor.render", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: Int = 0

    /// smoothSlow(フレームブレンド)用: トラックごとの直前のソースフレーム。renderQueue 上でのみ触る
    private var previousFrames: [CMPersistentTrackID: (time: Double, buffer: CVPixelBuffer)] = [:]

    /// 自動リフレームのなめらかな追従用: クリップごとの直前の注目点(出力時刻つき)。renderQueue 上でのみ触る
    private var reframeStates: [UUID: (time: Double, center: NormalizedPoint)] = [:]

    override init() {
        super.init()
    }

    // MARK: AVVideoCompositing

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // 出力バッファは各リクエストの renderContext から取得するので保持不要
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let request = asyncVideoCompositionRequest
        let requestGeneration = currentGeneration()
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            if requestGeneration != self.currentGeneration() {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                do {
                    let buffer = try self.render(request)
                    request.finish(withComposedVideoFrame: buffer)
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation &+= 1
        lock.unlock()
        renderQueue.async { [weak self] in
            self?.previousFrames.removeAll()
            self?.reframeStates.removeAll()
        }
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    // MARK: 描画

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else {
            throw VideoCompositorError.noOutputBuffer
        }
        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor.black).cropped(to: canvas)
        var frame = black

        if let instruction = request.videoCompositionInstruction as? VideoCompositorInstruction {
            let seconds = request.compositionTime.seconds
            let scene = instruction.scene
            let documentary = scene.documentary

            // 1. クリップ(単独 or トランジション中の 2 つ)
            var rendered: [CIImage?] = []
            for layer in instruction.layers {
                rendered.append(renderLayer(layer, request: request, time: seconds, scene: scene, canvasSize: size))
            }
            if instruction.layers.count >= 2, let transition = instruction.transition {
                let outgoing = rendered[0] ?? black
                let incoming = rendered[1] ?? black
                frame = TransitionRenderer.blend(outgoing: outgoing,
                                                 incoming: incoming,
                                                 type: transition.type,
                                                 progress: transition.progress(at: seconds),
                                                 canvasSize: size)
            } else if let first = rendered.first, let image = first {
                frame = image.composited(over: frame)
            }

            // 2. Bロール / ワイプ / 写真(メイン映像とルックの後、質感・テロップ・字幕・黒帯・フェードの前)
            if !scene.mediaOverlays.isEmpty {
                frame = OverlayRenderer.draw(scene.mediaOverlays,
                                             over: frame,
                                             time: seconds,
                                             request: request,
                                             canvasSize: size)
            }

            // 2.5 モザイク / ぼかし(映像とオーバーレイだけにかける。文字や字幕はこの後に重なる)
            frame = MosaicRenderer.apply(scene.textClips, to: frame, time: seconds, canvasSize: size)

            // 3. 周辺減光 → フィルム粒子 → 章タイトル / テロップ
            frame = DocumentaryRenderer.applyTexture(frame, time: seconds, info: documentary, canvasSize: size)
            frame = DocumentaryRenderer.applyOverlays(frame, time: seconds, info: documentary, canvasSize: size)

            // 4. 手書き
            for drawing in scene.drawings where seconds >= drawing.start && seconds < drawing.end {
                if let layer = DrawingLayerRenderer.layer(for: drawing, time: seconds, canvasSize: size) {
                    frame = layer.composited(over: frame)
                }
            }

            // 5. テキストレイヤー / ステッカー
            for textClip in scene.textClips where !textClip.isMosaic && textClip.contains(timelineTime: seconds) {
                if let layer = TextRenderer.layer(for: textClip, time: seconds, canvasSize: size) {
                    frame = layer.composited(over: frame)
                }
            }

            // 6. 字幕(シネスコ黒帯があるときは映像部分の内側へずらす)
            let bar = DocumentaryRenderer.letterboxBarHeight(canvasSize: size, style: documentary.style)
            for subtitle in scene.subtitles where seconds >= subtitle.start && seconds < subtitle.end {
                if var subImage = SubtitleRenderer.image(lines: subtitle.lines,
                                                         words: subtitle.words,
                                                         originalText: subtitle.originalText,
                                                         time: seconds,
                                                         cueStart: subtitle.start,
                                                         cueEnd: subtitle.end,
                                                         style: scene.subtitleStyle,
                                                         renderSize: size) {
                    if bar > 0 {
                        switch scene.subtitleStyle.position {
                        case .bottom:
                            subImage = subImage.transformed(by: CGAffineTransform(translationX: 0, y: bar))
                        case .top:
                            subImage = subImage.transformed(by: CGAffineTransform(translationX: 0, y: -bar))
                        case .center:
                            break
                        }
                    }
                    frame = subImage.composited(over: frame)
                }
            }

            // 7. シネスコ黒帯 → 黒フェード
            frame = DocumentaryRenderer.applyFinish(frame, time: seconds, info: documentary, canvasSize: size)

            // 8. 透かし(最後。黒帯の上にも出る)
            if scene.watermark.isActive {
                frame = WatermarkRenderer.draw(scene.watermark, over: frame, canvasSize: size)
            }

            pruneStaleFrames(now: seconds)
        }

        frame = frame.cropped(to: canvas)
        FilterEngineContexts.current.render(frame, to: output, bounds: canvas,
                                            colorSpace: FilterEngineContexts.colorSpace)
        return output
    }

    /// 1 クリップ分をキャンバス大(余白は透明)に描く。ソースが無ければ nil
    private func renderLayer(_ layer: VideoCompositorClipLayer,
                             request: AVAsynchronousVideoCompositionRequest,
                             time: Double,
                             scene: VideoCompositorScene,
                             canvasSize size: CGSize) -> CIImage? {
        let canvas = CGRect(origin: .zero, size: size)
        var source: CIImage? = nil

        if let still = layer.stillImageURL {
            source = OverlayRenderer.cachedImage(url: still, canvasSize: size)
        } else if let trackID = layer.trackID {
            // ソース選択: アングル区間ならアングルトラック、フレームが無ければメインにフォールバック
            var buffer: CVPixelBuffer? = nil
            var transform = layer.transform
            var usedTrack = trackID
            if let segment = layer.angleSegment(at: request.compositionTime),
               let angleBuffer = request.sourceFrame(byTrackID: segment.trackID) {
                buffer = angleBuffer
                transform = segment.transform
                usedTrack = segment.trackID
            }
            if buffer == nil {
                buffer = request.sourceFrame(byTrackID: trackID)
                transform = layer.transform
                usedTrack = trackID
            }
            if let buffer {
                var image = CIImage(cvPixelBuffer: buffer)
                if layer.smoothSlow {
                    image = blendWithPreviousFrame(image, buffer: buffer, trackID: usedTrack,
                                                   time: time, speed: layer.localSpeed(at: time))
                }
                source = Self.oriented(image, transform: transform)
            }
        }

        guard var image = source else { return nil }
        let isStill = layer.stillImageURL != nil
        let sourceTime: Double? = isStill ? nil : layer.sourceTime(at: time)

        // 手ぶれ補正(向き反映済みのソースに対して、平行移動 → 回転 → 端を隠す拡大)
        if !isStill, layer.stabilization.isActive, let st = sourceTime,
           let sample = layer.stabilization.sample(at: st) {
            image = Self.stabilized(image, sample: sample, track: layer.stabilization)
        }

        // 画質補正(ノイズ除去 → 美肌)。フィルタより前
        if !layer.enhance.isIdentity {
            image = EnhanceFilters.applyPreFilters(layer.enhance, to: image)
        }

        // 静止画の 3D ズーム(奥行きがあれば視差、無ければ Ken Burns 風)
        var usedParallax = false
        if let still = layer.stillImageURL, layer.parallax.enabled {
            let progress = layer.duration > 0 ? GeometryMath.clamp((time - layer.start) / layer.duration, 0, 1) : 0
            let depth = DepthParallaxRenderer.depth(for: still)
            image = DepthParallaxRenderer.render(image: image, depth: depth, parallax: layer.parallax, progress: progress)
            usedParallax = true
        }

        image = GeometryMath.applyClipGeometry(image, geometry: layer.geometry)
        image = FilterEngine.apply(layer.filter, to: image)
        let sourceExtent = image.extent

        // キャンバスへの配置(自動リフレームが効く条件ならクロップ窓を切り出して埋める)
        var placed: CIImage
        if !isStill, let st = sourceTime,
           let window = reframeCrop(layer: layer, sourceTime: st, time: time,
                                    imageSize: sourceExtent.size, canvasSize: size, scaling: scene.scaling) {
            let cropped = GeometryMath.normalizedToOrigin(image.cropped(to: window))
            placed = Self.place(cropped, canvasSize: size, scaling: .fill)
        } else {
            placed = Self.place(image, canvasSize: size, scaling: scene.scaling)
        }

        // 簡易高画質化(配置後。拡大されていればアンシャープマスク、そうでなければ弱いシャープ)
        if layer.enhance.sharpenUpscale > 0.001, sourceExtent.width >= 1, sourceExtent.height >= 1, !sourceExtent.isInfinite {
            let fitScale = min(size.width / sourceExtent.width, size.height / sourceExtent.height)
            placed = EnhanceFilters.sharpen(placed, amount: layer.enhance.sharpenUpscale, upscaled: fitScale > 1.02)
                .cropped(to: canvas)
        }

        var animation = layer.animation
        if isStill {
            // 静止画: ズームの指定は Ken Burns 風のゆっくりしたズームにする(3D ズーム中は不要)
            if !usedParallax {
                let zoom = Self.stillZoom(layer: layer, time: time)
                if abs(zoom - 1) > 0.0005 {
                    placed = GeometryMath.scaledAboutCenter(placed, scale: CGFloat(zoom)).cropped(to: canvas)
                }
            }
            if animation.inType == .zoomIn || animation.inType == .zoomOut { animation.inType = .none }
            if animation.outType == .zoomIn || animation.outType == .zoomOut { animation.outType = .none }
        }

        // 全体のルック(余白は透明のままなので黒帯は黒のまま)
        placed = DocumentaryRenderer.applyLook(placed, info: scene.documentary)

        // マスク(形の外は透明 → 背景の黒が見える)
        if layer.mask.isActive {
            placed = MaskRenderer.apply(layer.mask, to: placed, canvasSize: size)
        }

        // イン / アウトのアニメーション
        placed = TransitionRenderer.animate(placed,
                                            animation: animation,
                                            localTime: time - layer.start,
                                            clipDuration: layer.duration,
                                            canvasSize: size)
        return placed
    }

    /// 静止画のゆっくりしたズーム倍率(zoomIn: 1 → 1.1、zoomOut: 1.1 → 1)
    static func stillZoom(layer: VideoCompositorClipLayer, time: Double) -> Double {
        let duration = layer.duration
        guard duration > 0 else { return 1 }
        let p = GeometryMath.clamp((time - layer.start) / duration, 0, 1)
        let e = GeometryMath.smoothstep(p)
        let a = layer.animation
        if a.inType == .zoomIn || a.outType == .zoomIn { return 1 + 0.1 * e }
        if a.inType == .zoomOut || a.outType == .zoomOut { return 1.1 - 0.1 * e }
        return 1
    }

    /// スロー区間で直前のコマと 50% 混ぜる(同じコマが続いている間は何もしない)
    private func blendWithPreviousFrame(_ image: CIImage,
                                        buffer: CVPixelBuffer,
                                        trackID: CMPersistentTrackID,
                                        time: Double,
                                        speed: Double) -> CIImage {
        var result = image
        if let previous = previousFrames[trackID] {
            if CFEqual(previous.buffer, buffer) {
                return image
            }
            let dt = time - previous.time
            if speed < 0.999, dt > 0.0001, dt < 0.3 {
                result = image.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: CIImage(cvPixelBuffer: previous.buffer),
                    kCIInputTimeKey: NSNumber(value: 0.5)
                ])
            }
        }
        previousFrames[trackID] = (time: time, buffer: buffer)
        return result
    }

    /// 1 秒以上前のコマは手放す(シーク後などに古いバッファを持ち続けない)
    private func pruneStaleFrames(now: Double) {
        if !previousFrames.isEmpty {
            for (key, value) in previousFrames where abs(now - value.time) > 1 {
                previousFrames[key] = nil
            }
        }
        if !reframeStates.isEmpty {
            for (key, value) in reframeStates where abs(now - value.time) > 1 {
                reframeStates[key] = nil
            }
        }
    }

    // MARK: 自動リフレーム

    /// 自動リフレームのクロップ窓(ジオメトリ・フィルタ後の画像座標、CoreImage 左下原点)。
    /// 条件: track が有効で、キャンバスが「埋める」か、キャンバスと画像の縦横比が違うとき。
    /// 窓の大きさ = キャンバスの縦横比を画像に内接させた大きさ ÷ zoom。中心は注目点をなめらかに追い、画像の内側に収める
    private func reframeCrop(layer: VideoCompositorClipLayer,
                             sourceTime: Double,
                             time: Double,
                             imageSize: CGSize,
                             canvasSize: CGSize,
                             scaling: ScalingMode) -> CGRect? {
        let track = layer.reframe
        guard track.isActive else { return nil }
        guard imageSize.width >= 2, imageSize.height >= 2, imageSize.width.isFinite, imageSize.height.isFinite,
              canvasSize.width >= 2, canvasSize.height >= 2 else { return nil }
        let canvasAspect = canvasSize.width / canvasSize.height
        let imageAspect = imageSize.width / imageSize.height
        let aspectDiffers = abs(canvasAspect - imageAspect) / imageAspect > 0.02
        guard scaling == .fill || aspectDiffers else { return nil }

        let zoom = CGFloat(GeometryMath.clamp(track.zoom, 1, 4))
        var cropW: CGFloat
        var cropH: CGFloat
        if imageAspect > canvasAspect {
            cropH = imageSize.height
            cropW = cropH * canvasAspect
        } else {
            cropW = imageSize.width
            cropH = cropW / canvasAspect
        }
        cropW = max(2, cropW / zoom)
        cropH = max(2, cropH / zoom)

        let target = track.center(at: sourceTime)
        let center = smoothedReframeCenter(clipID: layer.clipID, target: target, time: time, smoothing: track.smoothing)

        // 左上原点の正規化座標 → CoreImage 座標(左下原点)、窓が画像からはみ出さないように
        var cx = CGFloat(GeometryMath.clamp(center.x, 0, 1)) * imageSize.width
        var cy = (1 - CGFloat(GeometryMath.clamp(center.y, 0, 1))) * imageSize.height
        cx = min(max(cx, cropW / 2), imageSize.width - cropW / 2)
        cy = min(max(cy, cropH / 2), imageSize.height - cropH / 2)
        let rect = CGRect(x: cx - cropW / 2, y: cy - cropH / 2, width: cropW, height: cropH)
        let bounds = CGRect(origin: .zero, size: imageSize)
        let window = rect.integral.intersection(bounds)
        guard window.width >= 2, window.height >= 2 else { return nil }
        return window
    }

    /// 注目点を指数平滑で追う(alpha = 1 - smoothing を 1/30 秒あたりの係数とし、フレーム間隔で換算)。
    /// シーク(時間が戻る / 大きく飛ぶ)では目標へ即座に合わせる
    private func smoothedReframeCenter(clipID: UUID,
                                      target: NormalizedPoint,
                                      time: Double,
                                      smoothing: Double) -> NormalizedPoint {
        let k = GeometryMath.clamp(1 - smoothing, 0.02, 1)
        var result = target
        if let previous = reframeStates[clipID] {
            let dt = time - previous.time
            if dt >= 0, dt < 0.5 {
                if dt < 0.0001 {
                    result = previous.center
                } else {
                    let frames = dt * 30
                    let alpha = 1 - pow(1 - k, frames)
                    let nx = previous.center.x + (target.x - previous.center.x) * alpha
                    let ny = previous.center.y + (target.y - previous.center.y) * alpha
                    result = NormalizedPoint(x: nx, y: ny)
                }
            }
        }
        reframeStates[clipID] = (time: time, center: result)
        return result
    }

    // MARK: 手ぶれ補正

    /// 向き反映済みのソース画像に補正を掛ける。dx / dy は画面幅・高さに対する比率(左上原点: 正の dy は下)、
    /// rotation は度(時計回りが正)。strength で弱め、cropZoom で中心まわりに拡大して端の黒を隠す(端は伸ばす)
    static func stabilized(_ image: CIImage, sample: StabilizationSample, track: StabilizationTrack) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, e.width >= 2, e.height >= 2 else { return image }
        let strength = GeometryMath.clamp(track.strength, 0, 1)
        let zoom = CGFloat(GeometryMath.clamp(track.cropZoom, 1, 1.5))
        let dx = CGFloat(GeometryMath.clamp(sample.dx, -0.5, 0.5) * strength) * e.width
        let dy = -CGFloat(GeometryMath.clamp(sample.dy, -0.5, 0.5) * strength) * e.height
        let rotation = GeometryMath.clamp(sample.rotation, -45, 45) * strength
        if abs(dx) < 0.01, abs(dy) < 0.01, abs(rotation) < 0.0005, abs(zoom - 1) < 0.0005 {
            return image
        }
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
        if abs(rotation) > 0.0005 {
            let radians = CGFloat(-rotation * Double.pi / 180)
            t = t.concatenating(CGAffineTransform(rotationAngle: radians))
        }
        t = t.concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
        t = t.concatenating(CGAffineTransform(translationX: e.midX + dx, y: e.midY + dy))
        return image.clampedToExtent().transformed(by: t).cropped(to: e)
    }

    /// preferredTransform(UIKit 座標系 = 左上原点)を CoreImage 座標系(左下原点)で適用し、原点を (0,0) に揃える
    static func oriented(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        if transform.isIdentity { return image }
        let extent = image.extent
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        let combined = flipIn.concatenating(transform).concatenating(flipOut)
        let transformed = image.transformed(by: combined)
        let e = transformed.extent
        return transformed.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    /// キャンバスへの配置(fit: 黒帯 / fitBlur: ぼかし背景 / fill: 中央クロップ)
    static func place(_ image: CIImage, canvasSize: CGSize, scaling: ScalingMode) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return CIImage.empty() }

        let fitScale = min(canvasSize.width / extent.width, canvasSize.height / extent.height)
        let fillScale = max(canvasSize.width / extent.width, canvasSize.height / extent.height)

        func scaledCentered(_ scale: CGFloat) -> CIImage {
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let e = scaled.extent
            let dx = (canvasSize.width - e.width) / 2 - e.origin.x
            let dy = (canvasSize.height - e.height) / 2 - e.origin.y
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }

        switch scaling {
        case .fit:
            return scaledCentered(fitScale).cropped(to: canvas)
        case .fill:
            return scaledCentered(fillScale).cropped(to: canvas)
        case .fitBlur:
            let foreground = scaledCentered(fitScale).cropped(to: canvas)
            // 縦横比が同じなら背景は不要
            if abs(fitScale - fillScale) < 0.0001 { return foreground }
            let sigma = Double(max(canvasSize.width, canvasSize.height)) * 0.025
            let background = scaledCentered(fillScale)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: NSNumber(value: -0.08),
                    kCIInputContrastKey: NSNumber(value: 1.0),
                    kCIInputSaturationKey: NSNumber(value: 1.0)
                ])
                .cropped(to: canvas)
            return foreground.composited(over: background)
        }
    }
}
