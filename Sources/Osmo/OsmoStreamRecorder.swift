// =====================================================================
// RTMP で届いた映像と音声を、iPhone の中に動画ファイルとして保存する(実験中・開発者向け)
//
// - 映像は圧縮されたまま書く(作り直さないので画質は落ちず、電池も使わない)。AVAssetWriter の passthrough
// - 音声(AAC)は ADTS の .aac に書き、止めたときに映像と 1 つの .mov にまとめる(作り直しなし)。
//   まとめるのに失敗したら、映像だけの .mov と .aac をそのまま残す
// - 保存先: 書類/Osmo(「ファイル」アプリの「このiPhone内」→ Video Mania → Osmo から見える)
// - 実機のカメラとはまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import CoreMedia
import Foundation

final class OsmoStreamRecorder: @unchecked Sendable {
    var onLog: (@Sendable (String) -> Void)?

    private let q = DispatchQueue(label: "videomania.osmo.recorder")
    // ---- 以下は q の上だけで触る ----
    private var videoFormat: CMVideoFormatDescription?
    private var nalLengthSize = 4
    private var asc: [UInt8]?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioHandle: FileHandle?
    /// 書類/Osmo/Osmo-日時(拡張子なし)。映像は「.video.mov」、音声は「.aac」、まとめたものは「.mov」
    private var baseURL: URL?
    private var startDTS: Int64?
    private var firstAudioTS: Int64?
    private var droppedVideo = 0
    private(set) var isRecording = false

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Osmo", isDirectory: true)
    }

    private func log(_ s: String) { onLog?(s) }

    // MARK: 届いたものを受ける(RTMP のキューから呼んでよい)

    func setVideoConfig(codec: OsmoVideoCodec, parameterSets: [[UInt8]], nalLengthSize: Int) {
        q.async { [self] in
            guard let format = Self.makeFormat(codec: codec, sets: parameterSets) else {
                log("recorder: could not build \(codec.rawValue) format")
                return
            }
            if isRecording, let old = videoFormat, !CMFormatDescriptionEqual(old, otherFormatDescription: format) {
                log("recorder: video format changed while recording (kept the first one)")
                return
            }
            videoFormat = format
            self.nalLengthSize = nalLengthSize
        }
    }

    func setAudioConfig(_ asc: [UInt8]) {
        q.async { [self] in self.asc = asc }
    }

    func appendVideo(data: [UInt8], dts: Int64, pts: Int64, keyframe: Bool) {
        q.async { [self] in appendVideoOnQueue(data: data, dts: dts, pts: pts, keyframe: keyframe) }
    }

    func appendAudio(data: [UInt8], timestamp: Int64) {
        q.async { [self] in appendAudioOnQueue(data: data, timestamp: timestamp) }
    }

    // MARK: 録画の開始・終了

    /// 映像の形式(パラメーターセット)が届いていないと始められない
    func start() async -> Bool {
        await withCheckedContinuation { cont in
            q.async { [self] in cont.resume(returning: startOnQueue()) }
        }
    }

    /// 止めて 1 つのファイルにまとめる。できたファイルの URL
    func stop() async -> URL? {
        let parts: (URL, URL?, Int64, Int64?)? = await withCheckedContinuation { cont in
            q.async { [self] in
                guard isRecording, let writer, let videoInput, let base = baseURL else {
                    cont.resume(returning: nil)
                    return
                }
                isRecording = false
                try? audioHandle?.close()
                audioHandle = nil
                let audioURL = Self.url(base, ".aac")
                let hasAudio = firstAudioTS != nil
                let audioStart = firstAudioTS
                guard let start = startDTS else {
                    // キーフレームが 1 枚も来なかった
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: audioURL)
                    try? FileManager.default.removeItem(at: writer.outputURL)
                    log("recorder: no keyframe arrived, nothing saved")
                    cont.resume(returning: nil)
                    return
                }
                // 音声が 1 つも来なかったら空の .aac は消す
                if !hasAudio { try? FileManager.default.removeItem(at: audioURL) }
                videoInput.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status != .completed {
                        log("recorder: finishWriting failed \(writer.error?.localizedDescription ?? "")")
                    }
                    cont.resume(returning: (writer.outputURL, hasAudio ? audioURL : nil, start, audioStart))
                }
            }
        }
        guard let parts else { return nil }
        let (videoURL, audioURL, start, audioStart) = parts
        guard let audioURL, let audioStart else { return videoURL }
        return await merge(videoURL: videoURL, audioURL: audioURL, offsetMs: audioStart - start)
    }

    // MARK: q の上

    private func startOnQueue() -> Bool {
        guard !isRecording else { return true }
        guard let format = videoFormat else {
            log("recorder: no video format yet")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let base = Self.folder.appendingPathComponent("Osmo-\(f.string(from: Date()))")
            let videoURL = Self.url(base, ".video.mov")
            let w = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else {
                log("recorder: writer cannot take this video format")
                return false
            }
            w.add(input)
            guard w.startWriting() else {
                log("recorder: startWriting failed \(w.error?.localizedDescription ?? "")")
                return false
            }
            writer = w
            videoInput = input
            baseURL = base
            startDTS = nil
            firstAudioTS = nil
            droppedVideo = 0
            let audioURL = Self.url(base, ".aac")
            FileManager.default.createFile(atPath: audioURL.path, contents: nil)
            audioHandle = try FileHandle(forWritingTo: audioURL)
            isRecording = true
            log("recorder: started \(base.lastPathComponent) (waiting for a keyframe)")
            return true
        } catch {
            log("recorder: \(error.localizedDescription)")
            return false
        }
    }

    private func appendVideoOnQueue(data: [UInt8], dts: Int64, pts: Int64, keyframe: Bool) {
        guard isRecording, let writer, let videoInput, let format = videoFormat else { return }
        if startDTS == nil {
            // キーフレームから書き始める
            guard keyframe else { return }
            startDTS = dts
            writer.startSession(atSourceTime: CMTime(value: pts - dts, timescale: 1000))
            log("recorder: first keyframe")
        }
        guard let start = startDTS else { return }
        let payload = nalLengthSize == 4 ? data : Self.toFourByteLengths(data, from: nalLengthSize)
        guard let sample = Self.makeSample(payload, format: format,
                                           dts: CMTime(value: dts - start, timescale: 1000),
                                           pts: CMTime(value: pts - start, timescale: 1000),
                                           keyframe: keyframe) else { return }
        if videoInput.isReadyForMoreMediaData {
            if !videoInput.append(sample) {
                log("recorder: append failed \(writer.error?.localizedDescription ?? "")")
            }
        } else {
            droppedVideo += 1
            if droppedVideo % 25 == 1 { log("recorder: writer busy, dropped \(droppedVideo) video frames") }
        }
    }

    private func appendAudioOnQueue(data: [UInt8], timestamp: Int64) {
        guard isRecording, startDTS != nil, let asc, asc.count >= 2, let audioHandle else { return }
        if firstAudioTS == nil { firstAudioTS = timestamp }
        try? audioHandle.write(contentsOf: Data(Self.adtsHeader(asc: asc, payloadLength: data.count) + data))
    }

    // MARK: まとめる

    private func merge(videoURL: URL, audioURL: URL, offsetMs: Int64) async -> URL {
        let name = videoURL.lastPathComponent.replacingOccurrences(of: ".video.mov", with: ".mov")
        let finalURL = videoURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            let comp = AVMutableComposition()
            let vAsset = AVURLAsset(url: videoURL)
            guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
                  let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return videoURL }
            let vRange = try await vTrack.load(.timeRange)
            try cv.insertTimeRange(vRange, of: vTrack, at: .zero)
            let duration = vRange.duration

            let aAsset = AVURLAsset(url: audioURL)
            if let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first,
               let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let aRange = try await aTrack.load(.timeRange)
                let offset = CMTime(value: offsetMs, timescale: 1000)
                // 音声が映像より後に始まったら後ろにずらし、先に始まったら頭を切る
                var source = aRange
                var at = CMTime.zero
                if offset > .zero { at = offset } else { source.start = source.start - offset; source.duration = source.duration + offset }
                let room = duration - at
                if source.duration > room { source.duration = room }
                if source.duration > .zero { try ca.insertTimeRange(source, of: aTrack, at: at) }
            }

            try? FileManager.default.removeItem(at: finalURL)
            guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
                return videoURL
            }
            try await export.export(to: finalURL, as: .mov)
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
            log("recorder: saved \(finalURL.lastPathComponent)")
            return finalURL
        } catch {
            log("recorder: merge failed (\(error.localizedDescription)); kept video and .aac separately")
            return videoURL
        }
    }

    // MARK: 部品

    private static func url(_ base: URL, _ suffix: String) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + suffix)
    }

    static func makeFormat(codec: OsmoVideoCodec, sets: [[UInt8]]) -> CMVideoFormatDescription? {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, set.count))
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        var fmt: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        case .avc:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }

    /// NAL の長さを 4 バイトにそろえる
    static func toFourByteLengths(_ data: [UInt8], from size: Int) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + size <= data.count {
            var n = 0
            for k in 0..<size { n = n << 8 | Int(data[i + k]) }
            i += size
            guard i + n <= data.count else { break }
            out += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            out += data[i..<(i + n)]
            i += n
        }
        return out
    }

    /// 長さ付きの NAL(4 バイト)を Annex-B(00 00 00 01)にする。画面の表示用
    static func annexB(fromLengthPrefixed data: [UInt8], nalLengthSize size: Int) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + size <= data.count {
            var n = 0
            for k in 0..<size { n = n << 8 | Int(data[i + k]) }
            i += size
            guard n > 0, i + n <= data.count else { break }
            out += [0, 0, 0, 1]
            out += data[i..<(i + n)]
            i += n
        }
        return out
    }

    private static func makeSample(_ bytes: [UInt8], format: CMVideoFormatDescription,
                                   dts: CMTime, pts: CMTime, keyframe: Bool) -> CMSampleBuffer? {
        guard !bytes.isEmpty else { return nil }
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
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sizes = [bytes.count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
            let sample
        else { return nil }
        if !keyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// AAC の 1 フレームの前に付ける 7 バイト(CRC なし)。AudioSpecificConfig から作る
    static func adtsHeader(asc: [UInt8], payloadLength: Int) -> [UInt8] {
        let objectType = Int(asc[0] >> 3)
        let freqIndex = Int(asc[0] & 0x07) << 1 | Int(asc[1] >> 7)
        let channels = Int(asc[1] >> 3) & 0x0F
        let profile = max(0, objectType - 1) & 0x03
        let length = 7 + payloadLength
        return [
            0xFF, 0xF1,
            UInt8(profile << 6 | freqIndex << 2 | channels >> 2),
            UInt8((channels & 0x03) << 6 | (length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x07) << 5 | 0x1F),
            0xFC,
        ]
    }
}
#endif
