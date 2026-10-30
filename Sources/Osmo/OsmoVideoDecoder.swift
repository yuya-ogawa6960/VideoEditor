// =====================================================================
// Osmo のライブビュー(HEVC / H.264 の Annex-B)を VideoToolbox で絵にして、
// AVSampleBufferDisplayLayer に出す(実験中・開発者向け)
//
// 考え方は OpenCine の Sources/OpenCineApple/VideoToolboxDecoder.swift(Apache 2.0)と
// OpenPocketCine の資料(handbook/protocol/live-view.md)に従った:
// - 符号化方式はパラメーターセットで決める(Pocket 4 は HEVC、Pocket 3 は H.264 が観測されている)
// - パラメーターセットとキーフレームは 2 つの塊に分かれて ~1ms 差で届くことが多い
// - 定期的なキーフレームは無い。最初のキーフレーム(HEVC IRAP 16〜21 / AVC IDR)までは P フレームを捨てる
// - 実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

final class OsmoVideoDecoder: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// 絵が出たとき(メインスレッド)。幅と高さ
    var onFrame: ((Int, Int) -> Void)?
    /// 復号が壊れた・キーフレームが要る(メインスレッド)
    var onNeedsKeyframe: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private let q = DispatchQueue(label: "videomania.osmo.decoder")
    // ---- 以下は q の上だけで触る ----
    private(set) var codec: OsmoVideoCodec?
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var awaitingRandomAccess = true
    private var frameIndex: Int64 = 0
    private var decodeErrors = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    /// データリンクのキューから呼んでよい
    func decode(accessUnit: [UInt8]) {
        q.async { [self] in decodeOnQueue(accessUnit) }
    }

    func reset() {
        q.sync {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            format = nil
            codec = nil
            vps = nil; sps = nil; pps = nil
            awaitingRandomAccess = true
            frameIndex = 0
        }
        DispatchQueue.main.async { [displayLayer] in
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    var codecName: String { q.sync { codec?.rawValue ?? "—" } }

    // MARK: q の上

    private func decodeOnQueue(_ au: [UInt8]) {
        let nals = OsmoNAL.nalUnits(au)
        if codec == nil {
            guard let detected = OsmoNAL.detectCodec(nals) else { return }  // パラメーターセット待ち
            codec = detected
            log("decoder: codec \(detected.rawValue)")
        }
        guard let codec else { return }
        updateParameterSets(nals, codec: codec)
        guard let format else { return }

        let pictures = nals.filter { OsmoNAL.isPicture($0, codec: codec) }
        guard !pictures.isEmpty else { return }
        if awaitingRandomAccess {
            guard pictures.contains(where: { OsmoNAL.isRandomAccess($0, codec: codec) }) else { return }
            awaitingRandomAccess = false
            log("decoder: first keyframe")
        }
        if session == nil, !openSession(format) { return }
        guard let session, let sample = makeSample(pictures, format: format) else { return }

        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status != noErr {
                self.q.async { self.noteDecodeError(status) }
                return
            }
            // 絵が無く失敗でもないのは「捨てた」フレーム(BLA の後の RASL など)。何もしない
            if let imageBuffer { self.present(imageBuffer) }
        }
        // 失敗のときコールバックが呼ばれないことがあるので、戻り値でも見る(作り直しが 2 回になっても害はない)
        if status != noErr { noteDecodeError(status) }
    }

    private func updateParameterSets(_ nals: [[UInt8]], codec: OsmoVideoCodec) {
        var newVPS = vps, newSPS = sps, newPPS = pps
        for nal in nals where OsmoNAL.isParameterSet(nal, codec: codec) {
            guard let b = nal.first else { continue }
            switch codec {
            case .hevc:
                switch OsmoNAL.hevcType(b) {
                case 32: newVPS = nal
                case 33: newSPS = nal
                default: newPPS = nal
                }
            case .avc:
                if OsmoNAL.avcType(b) == 7 { newSPS = nal } else { newPPS = nal }
            }
        }
        guard newVPS != vps || newSPS != sps || newPPS != pps else { return }
        vps = newVPS; sps = newSPS; pps = newPPS
        guard let s = sps, let p = pps else { return }
        let made: CMVideoFormatDescription?
        switch codec {
        case .hevc:
            guard let v = vps else { return }
            made = Self.makeFormat([v, s, p], hevc: true)
        case .avc:
            made = Self.makeFormat([s, p], hevc: false)
        }
        guard let made else {
            log("decoder: could not build format from parameter sets")
            return
        }
        format = made
        let dims = CMVideoFormatDescriptionGetDimensions(made)
        log("decoder: format \(dims.width)x\(dims.height)")
        // 新しいパラメーターセットを今のセッションが受けられなければ作り直す
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: made) {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    private static func makeFormat(_ sets: [[UInt8]], hevc: Bool) -> CMVideoFormatDescription? {
        // 作り終わるまで全部のポインタを生かしておく
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        var fmt: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }

    private func openSession(_ format: CMVideoFormatDescription) -> Bool {
        // 8bit 4:2:0 は AVSampleBufferDisplayLayer がそのまま表示できる(OpenCine でも最初に試す形式)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            log("decoder: VTDecompressionSessionCreate failed \(status)")
            return false
        }
        session = created
        log("decoder: session created")
        return true
    }

    /// NAL を 4 バイトの長さ付き(AVCC/HVCC)に並べて 1 つのサンプルにする
    private func makeSample(_ nals: [[UInt8]], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            bytes += nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block
        else { return nil }
        let copied = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        frameIndex += 1
        // ライブビューは約 25fps
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
                                        presentationTimeStamp: CMTime(value: frameIndex, timescale: 25),
                                        decodeTimeStamp: .invalid)
        var sizes = [bytes.count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    private func noteDecodeError(_ status: OSStatus) {
        decodeErrors += 1
        log("decoder: error \(status) (#\(decodeErrors))")
        // セッションを作り直し、次のキーフレームから出し直す
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        awaitingRandomAccess = true
        let reason = "decode error \(status)"
        DispatchQueue.main.async { [weak self] in self?.onNeedsKeyframe?(reason) }
    }

    /// 復号した絵をすぐ表示する(VideoToolbox のスレッドから呼ばれる)
    private func present(_ imageBuffer: CVImageBuffer) {
        var formatOut: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &formatOut) == noErr,
            let formatOut
        else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatOut,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample
        else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let renderer = self.displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
            self.onFrame?(width, height)
        }
    }

    private func log(_ s: String) {
        let handler = onLog
        DispatchQueue.main.async { handler?(s) }
    }
}

#endif
