// =====================================================================
// Osmo のライブビューを、作り直さず(再エンコードせず)そのまま .mp4 に録る(実験中・開発者向け)
//
// - データリンクが組み立てた 1 枚(Annex-B)を受け取り、パラメーターセット(HEVC の VPS/SPS/PPS、
//   H.264 の SPS/PPS)から CMVideoFormatDescription を作る。
// - NAL を 4 バイトの長さ付き(HVCC/AVCC)に並べ替えて CMSampleBuffer にし、
//   AVAssetWriterInput(outputSettings: nil)にそのまま渡す(パススルー)。
// - 時刻は届いた時刻(ホストの時計)。録画を始めた最初のキーフレームを 0 にする。
//   キーフレームより前の絵は捨てる(定期的なキーフレームが無いので、始めるときに 1 回頼む)。
// - iPhone のマイクの音は AAC にして同じファイルに入れる(任意)。
// - 1 枚ずつすぐ書くので、ストリーム全体をためない。
// - 実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import AVFoundation
import CoreMedia
import Foundation

final class OsmoStreamRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// 1 枚目のキーフレームを書いた(メインスレッド)
    var onStarted: (() -> Void)?
    /// キーフレームが要る(メインスレッド)。理由
    var onNeedsKeyframe: ((String) -> Void)?
    /// 書き終わった(メインスレッド)。保存できたファイル(無ければ nil)と、知らせること
    var onFinished: ((URL?, String?) -> Void)?
    var onLog: ((String) -> Void)?

    struct Snapshot {
        /// 最後に絵を書いてからの秒数(書いていなければ nil)
        var secondsSinceLastFrame: Double?
        /// キーフレームを待っている秒数(待っていなければ nil)
        var secondsWaitingForKeyframe: Double?
    }

    private enum State { case idle, arming, waitingForKeyframe, writing, finishing }

    private let q = DispatchQueue(label: "videomania.osmo.recorder")
    private let micQueue = DispatchQueue(label: "videomania.osmo.recorder.mic")
    // ---- 以下は q の上だけで触る ----
    // パラメーターセットは録画していなくても覚えておく(キーフレームの直前に別の塊で届くことが多い)
    private var codec: OsmoVideoCodec?
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var state: State = .idle
    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// 0 秒にあたるホストの時刻(最初のキーフレームが届いた時刻)
    private var startHostTime: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var lastFrameHostTime: CMTime = .invalid
    /// 途中で絵が抜けたあと、次のキーフレームまで書かない
    private var needsKeyframe = false
    private var waitingSince: CMTime = .invalid
    /// HEVC: 始めた直後や BLA のあとの RASL(単独では絵にならない前の絵)を捨てる
    private var skipsLeadingPictures = false
    private var writtenFrames = 0
    private var finishMessage: String?
    // マイク
    private var wantsMicrophone = false
    private var audioFormat: CMAudioFormatDescription?
    private var audioClock: CMClock?
    private var armTimeout: DispatchWorkItem?
    private var audioAppendFailed = false
    // ---- micQueue の上だけで触る ----
    private var captureSession: AVCaptureSession?

    /// 止まったとみなす秒数(このあとは次のキーフレームから書き直す)
    static let stallSeconds: Double = 2

    // MARK: 外から

    /// データリンクのキューから呼ぶ。届いた時刻はここで取る
    func observe(accessUnit au: [UInt8]) {
        let arrival = Self.hostNow()
        q.async { [self] in handle(au, arrival: arrival) }
    }

    /// 録画を始める。マイクを使うときは、マイクの音が届いてからキーフレームを待つ(音の形式を知るため)
    func start(url: URL, microphone: Bool) {
        q.async { [self] in
            guard state == .idle else { return }
            outputURL = url
            wantsMicrophone = microphone
            audioFormat = nil
            audioClock = nil
            audioAppendFailed = false
            finishMessage = nil
            writtenFrames = 0
            lastVideoPTS = .invalid
            lastFrameHostTime = .invalid
            startHostTime = .invalid
            needsKeyframe = false
            if microphone {
                state = .arming
                startMicrophone()
                // 2 秒たってもマイクの音が来なければ、音なしで始める
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.state == .arming else { return }
                    self.log("recorder: no microphone audio in 2 s, recording without sound")
                    self.wantsMicrophone = false
                    self.stopMicrophone()
                    self.arm()
                }
                armTimeout = item
                q.asyncAfter(deadline: .now() + 2, execute: item)
            } else {
                arm()
            }
        }
    }

    /// 録画を止めてファイルを閉じる。結果は onFinished で返す
    func stop() {
        q.async { [self] in finish(message: nil) }
    }

    /// 画面の数字用(メインスレッドから)
    func snapshot() -> Snapshot {
        q.sync {
            let now = Self.hostNow()
            var s = Snapshot()
            if state == .writing, lastFrameHostTime.isValid {
                s.secondsSinceLastFrame = CMTimeGetSeconds(CMTimeSubtract(now, lastFrameHostTime))
            }
            if (state == .waitingForKeyframe || (state == .writing && needsKeyframe)), waitingSince.isValid {
                s.secondsWaitingForKeyframe = CMTimeGetSeconds(CMTimeSubtract(now, waitingSince))
            }
            return s
        }
    }

    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OsmoRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 前に開いたときの残り(10 分より古いもの)を消す
    static func cleanUpTemporaryFiles() {
        let dir = directory
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-10 * 60)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified < limit else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: 映像(q の上)

    private func arm() {
        armTimeout?.cancel()
        armTimeout = nil
        state = .waitingForKeyframe
        waitingSince = Self.hostNow()
        needsKeyframeNow("recording start")
    }

    private func handle(_ au: [UInt8], arrival: CMTime) {
        let nals = OsmoNAL.nalUnits(au)
        if codec == nil {
            guard let detected = OsmoNAL.detectCodec(nals) else { return }
            codec = detected
        }
        guard let codec else { return }
        updateParameterSets(nals, codec: codec)
        guard state == .waitingForKeyframe || state == .writing, let format else { return }

        let pictures = nals.filter { OsmoNAL.isPicture($0, codec: codec) }
        guard !pictures.isEmpty else { return }
        let isKey = pictures.contains { OsmoNAL.isRandomAccess($0, codec: codec) }

        if state == .writing, lastFrameHostTime.isValid, !needsKeyframe,
           CMTimeGetSeconds(CMTimeSubtract(arrival, lastFrameHostTime)) > Self.stallSeconds, !isKey {
            // 2 秒より長く止まったあとは、途中の絵が抜けている。次のキーフレームから書き直す
            needsKeyframe = true
            waitingSince = arrival
            log("recorder: stream stalled, waiting for a keyframe")
            needsKeyframeNow("recording stalled")
        }

        var resumed = false
        if state == .waitingForKeyframe {
            guard isKey else { return }
            guard startWriter(format: format, at: arrival) else { return }
            resumed = true
        } else if needsKeyframe {
            guard isKey else { return }
            needsKeyframe = false
            resumed = true
            log("recorder: resumed at keyframe")
        }

        if codec == .hevc {
            if isKey {
                let bla = pictures.contains { (16...18).contains(OsmoNAL.hevcType($0[0])) }
                skipsLeadingPictures = resumed || bla
            } else if skipsLeadingPictures {
                let rasl = pictures.allSatisfy { [8, 9].contains(OsmoNAL.hevcType($0[0])) }
                if rasl { return }
                skipsLeadingPictures = false
            }
        }
        appendVideo(pictures, isKey: isKey, arrival: arrival, format: format)
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
            log("recorder: could not build format from parameter sets")
            return
        }
        if state == .writing, let old = format {
            let a = CMVideoFormatDescriptionGetDimensions(old)
            let b = CMVideoFormatDescriptionGetDimensions(made)
            if a.width != b.width || a.height != b.height {
                // 1 つのファイルに大きさの違う絵は入れられない。ここまでで閉じる
                log("recorder: size changed \(a.width)x\(a.height) -> \(b.width)x\(b.height), finishing")
                format = made
                finish(message: String(localized: "映像の大きさが変わったので、録画を止めました"))
                return
            }
            log("recorder: parameter sets changed (same size)")
        }
        format = made
    }

    private func startWriter(format: CMVideoFormatDescription, at arrival: CMTime) -> Bool {
        guard let url = outputURL else { return false }
        try? FileManager.default.removeItem(at: url)
        let w: AVAssetWriter
        do {
            w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            log("recorder: AVAssetWriter failed \(error.localizedDescription)")
            finish(message: String(localized: "録画を保存できませんでした"))
            return false
        }
        // 作り直さずにそのまま書く(outputSettings: nil)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else {
            log("recorder: cannot add video input")
            finish(message: String(localized: "録画を保存できませんでした"))
            return false
        }
        w.add(v)
        var a: AVAssetWriterInput?
        if wantsMicrophone, let af = audioFormat,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee {
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 64_000 * channels,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: af)
            input.expectsMediaDataInRealTime = true
            if w.canAdd(input) {
                w.add(input)
                a = input
            } else {
                log("recorder: cannot add audio input, recording without sound")
            }
        }
        guard w.startWriting() else {
            log("recorder: startWriting failed \(w.error?.localizedDescription ?? "")")
            finish(message: String(localized: "録画を保存できませんでした"))
            return false
        }
        w.startSession(atSourceTime: .zero)
        writer = w
        videoInput = v
        audioInput = a
        startHostTime = arrival
        state = .writing
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        log("recorder: started \(codec?.rawValue ?? "?") \(dims.width)x\(dims.height)\(a == nil ? "" : " + mic")")
        let handler = onStarted
        DispatchQueue.main.async { handler?() }
        return true
    }

    private func appendVideo(_ pictures: [[UInt8]], isKey: Bool, arrival: CMTime, format: CMVideoFormatDescription) {
        guard let writer, let videoInput, writer.status == .writing else {
            finish(message: String(localized: "録画を保存できませんでした"))
            return
        }
        // 届いた時刻 − 始めた時刻。必ず前の絵より後ろにする
        var pts = CMTimeConvertScale(CMTimeSubtract(arrival, startHostTime), timescale: 90_000,
                                     method: .roundHalfAwayFromZero)
        if lastVideoPTS.isValid, CMTimeCompare(pts, lastVideoPTS) <= 0 {
            pts = CMTimeAdd(lastVideoPTS, CMTime(value: 1, timescale: 90_000))
        }
        guard videoInput.isReadyForMoreMediaData else {
            // 1 枚でも抜けると次のキーフレームまで絵が壊れるので、キーフレームから書き直す
            if !isKey {
                needsKeyframe = true
                waitingSince = arrival
                log("recorder: writer busy, dropped a frame; waiting for a keyframe")
                needsKeyframeNow("writer busy")
            }
            return
        }
        guard let sample = Self.makeSample(pictures, format: format, pts: pts, isKey: isKey) else { return }
        guard videoInput.append(sample) else {
            log("recorder: append failed \(writer.error?.localizedDescription ?? "")")
            finish(message: String(localized: "録画を保存できませんでした"))
            return
        }
        lastVideoPTS = pts
        lastFrameHostTime = arrival
        writtenFrames += 1
    }

    // MARK: 音(q の上)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if let f = CMSampleBufferGetFormatDescription(sampleBuffer) { audioFormat = f }
        switch state {
        case .arming:
            log("recorder: microphone ready")
            arm()
        case .writing:
            appendAudio(sampleBuffer)
        default:
            break
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput, let writer, writer.status == .writing, startHostTime.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        // マイクの時刻をホストの時計にそろえる(たいていは同じ時計)
        let hostPTS = audioClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        let newPTS = CMTimeSubtract(hostPTS, startHostTime)
        // 0 秒より前の音は捨てる
        guard CMTimeCompare(newPTS, .zero) >= 0 else { return }
        // 音は少し欠けても困らないので、受けられなければ捨てる
        guard audioInput.isReadyForMoreMediaData else { return }
        guard let retimed = Self.retime(sampleBuffer, by: CMTimeSubtract(pts, newPTS)) else { return }
        if !audioInput.append(retimed), !audioAppendFailed {
            audioAppendFailed = true
            log("recorder: audio append failed \(writer.error?.localizedDescription ?? "")")
        }
    }

    private func startMicrophone() {
        micQueue.async { [weak self] in
            guard let self else { return }
            let session = AVCaptureSession()
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic) else {
                self.q.async { self.microphoneFailed("no microphone input") }
                return
            }
            let output = AVCaptureAudioDataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                self.q.async { self.microphoneFailed("cannot add microphone") }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: self.q)
            session.commitConfiguration()
            session.startRunning()
            self.captureSession = session
            let clock = session.synchronizationClock
            self.q.async { self.audioClock = clock }
        }
    }

    private func stopMicrophone() {
        micQueue.async { [weak self] in
            guard let self, let session = self.captureSession else { return }
            session.stopRunning()
            self.captureSession = nil
            // 録音用に変わったカテゴリを再生用に戻す(CameraRecorder と同じ)
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playback, mode: .default, options: [])
            try? audio.setActive(true)
        }
    }

    private func microphoneFailed(_ reason: String) {
        log("recorder: \(reason), recording without sound")
        wantsMicrophone = false
        if state == .arming { arm() }
    }

    // MARK: 終わり(q の上)

    private func finish(message: String?) {
        armTimeout?.cancel()
        armTimeout = nil
        switch state {
        case .idle, .finishing:
            return
        case .arming, .waitingForKeyframe:
            stopMicrophone()
            state = .idle
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            outputURL = nil
            log("recorder: stopped before the first keyframe")
            report(nil, message ?? String(localized: "映像が届かなかったので、何も録れませんでした"))
        case .writing:
            stopMicrophone()
            state = .finishing
            finishMessage = message
            guard let writer, writer.status == .writing else {
                completeFinish()
                return
            }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            // 最後の絵にも 1 枚分(約 25fps)の長さを付ける
            if lastVideoPTS.isValid {
                writer.endSession(atSourceTime: CMTimeAdd(lastVideoPTS, CMTime(value: 1, timescale: 25)))
            }
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.q.async { self.completeFinish() }
            }
        }
    }

    private func completeFinish() {
        let url = outputURL
        let ok = writer?.status == .completed && writtenFrames > 0
        if !ok {
            log("recorder: finish failed \(writer?.error?.localizedDescription ?? "status \(writer?.status.rawValue ?? -1)")")
            if let url { try? FileManager.default.removeItem(at: url) }
        } else {
            log("recorder: saved \(writtenFrames) frames, \(String(format: "%.1f", CMTimeGetSeconds(lastVideoPTS))) s")
        }
        let message = ok ? finishMessage : String(localized: "録画を保存できませんでした")
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        startHostTime = .invalid
        lastFrameHostTime = .invalid
        needsKeyframe = false
        state = .idle
        report(ok ? url : nil, message)
    }

    private func report(_ url: URL?, _ message: String?) {
        let handler = onFinished
        DispatchQueue.main.async { handler?(url, message) }
    }

    private func needsKeyframeNow(_ reason: String) {
        let handler = onNeedsKeyframe
        DispatchQueue.main.async { handler?(reason) }
    }

    private func log(_ s: String) {
        let handler = onLog
        DispatchQueue.main.async { handler?(s) }
    }

    // MARK: 部品

    private static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
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

    /// 絵の NAL を 4 バイトの長さ付き(HVCC/AVCC)に並べて 1 つのサンプルにする。
    /// パラメーターセットはファイルの先頭(形式の説明)に入るので、サンプルには入れない
    private static func makeSample(_ nals: [[UInt8]], format: CMVideoFormatDescription,
                                   pts: CMTime, isKey: Bool) -> CMSampleBuffer? {
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
        // ライブビューに B フレームは無い前提(届いた順 = 表示の順)。長さは次の絵との差で決まる
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: pts)
        var sizes = [bytes.count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
            let sample
        else { return nil }
        // キーフレーム以外は「単独では絵にならない」と書いておく(早送りや頭出しで使われる)
        if !isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// 音のサンプルの時刻を offset だけ前にずらす
    private static func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        _ = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil,
                                                   entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings,
                                                     entriesNeededOut: &count) == noErr
        else { return nil }
        for i in timings.indices {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count,
            sampleTimingArray: &timings, sampleBufferOut: &out) == noErr
        else { return nil }
        return out
    }
}
#endif
