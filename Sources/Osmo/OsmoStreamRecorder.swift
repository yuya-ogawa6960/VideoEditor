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
// - 高画質モード(RTMP、OsmoRTMPSession)からも使う: 時刻はカメラが付けたもの(ミリ秒)をホストの時計に写して使い、
//   B フレームの表示の時刻(composition time)も入れる。カメラの AAC は作り直さずにそのまま入れる(マイクより優先)。
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
    // RTMP(OsmoRTMPSession)から: カメラが付けた時刻とカメラの音
    /// カメラの時刻(ミリ秒)の基準と、それにあたるホストの時刻
    private var cameraClockBase: (ms: Int64, host: CMTime)?
    private var cameraAudioFormat: CMAudioFormatDescription?
    /// この録画でカメラの音を使いたい(start の cameraAudio)
    private var prefersCameraAudio = false
    /// いまの録画の音がカメラの音
    private var usesCameraAudio = false
    private var cameraAudioNextPTS: CMTime = .invalid
    /// 表示の時刻のいちばん後ろ(B フレームがあると最後に書いた絵より後ろのことがある)
    private var lastPresentationPTS: CMTime = .invalid
    /// 最後に絵を書いた本当の時刻(止まっているかの判定。RTMP ではカメラの時刻と少しずれるため別に持つ)
    private var lastWriteRealTime: CMTime = .invalid
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

    /// RTMP の 1 枚(Annex-B。キーフレームにはパラメーターセットを付けて渡す)。時刻はカメラが付けた復号の時刻(ミリ秒)、
    /// compositionMs は表示の時刻との差(B フレーム)。codec はコンテナで分かっている符号化方式
    func observe(accessUnit au: [UInt8], timestampMs: Int64, compositionMs: Int32, codec hint: OsmoVideoCodec) {
        q.async { [self] in
            let dts = cameraHostTime(timestampMs)
            handle(au, arrival: dts, composition: CMTime(value: Int64(compositionMs), timescale: 1000), codecHint: hint)
        }
    }

    /// カメラの音の形式(RTMP の AudioSpecificConfig から makeAACFormat で作ったもの)。nil で忘れる
    func setCameraAudioFormat(_ format: CMAudioFormatDescription?) {
        q.async { [self] in cameraAudioFormat = format }
    }

    /// カメラの音(生の AAC 1 フレーム)。時刻はカメラが付けたもの(ミリ秒)
    func observeCameraAudio(_ frame: [UInt8], timestampMs: Int64) {
        q.async { [self] in appendCameraAudio(frame, at: cameraHostTime(timestampMs)) }
    }

    /// 新しい RTMP の配信が始まったとき。カメラの時刻の基準を取り直す(録画していなければ符号化方式も忘れる)
    func resetCameraClock() {
        q.async { [self] in
            cameraClockBase = nil
            cameraAudioFormat = nil
            cameraAudioNextPTS = .invalid
            if state == .idle {
                codec = nil
                vps = nil; sps = nil; pps = nil
                format = nil
            }
        }
    }

    /// 録画を始める。マイクを使うときは、マイクの音が届いてからキーフレームを待つ(音の形式を知るため)。
    /// cameraAudio: カメラの音(setCameraAudioFormat)が届いていればそれを使う(RTMP のとき)
    func start(url: URL, microphone: Bool, cameraAudio: Bool = false) {
        q.async { [self] in
            guard state == .idle else { return }
            outputURL = url
            prefersCameraAudio = cameraAudio
            usesCameraAudio = false
            cameraAudioNextPTS = .invalid
            lastPresentationPTS = .invalid
            lastWriteRealTime = .invalid
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
            if state == .writing, lastWriteRealTime.isValid {
                s.secondsSinceLastFrame = CMTimeGetSeconds(CMTimeSubtract(now, lastWriteRealTime))
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

    /// composition: 表示の時刻 − 復号の時刻(RTMP の B フレーム。ライブビューは 0)。codecHint: RTMP で分かっている符号化方式
    private func handle(_ au: [UInt8], arrival: CMTime, composition: CMTime = .zero, codecHint: OsmoVideoCodec? = nil) {
        let nals = OsmoNAL.nalUnits(au)
        if codec == nil {
            guard let detected = codecHint ?? OsmoNAL.detectCodec(nals) else { return }
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
        appendVideo(pictures, isKey: isKey, arrival: arrival, composition: composition, format: format)
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
        usesCameraAudio = false
        if prefersCameraAudio, let caf = cameraAudioFormat {
            // カメラの AAC を作り直さずにそのまま書く(RTMP)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: caf)
            input.expectsMediaDataInRealTime = true
            if w.canAdd(input) {
                w.add(input)
                a = input
                usesCameraAudio = true
                cameraAudioNextPTS = .invalid
            } else {
                log("recorder: cannot add camera audio input, recording without sound")
            }
        } else if wantsMicrophone, let af = audioFormat,
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
        log("recorder: started \(codec?.rawValue ?? "?") \(dims.width)x\(dims.height)\(a == nil ? "" : (usesCameraAudio ? " + camera audio" : " + mic"))")
        let handler = onStarted
        DispatchQueue.main.async { handler?() }
        return true
    }

    private func appendVideo(_ pictures: [[UInt8]], isKey: Bool, arrival: CMTime, composition: CMTime = .zero,
                             format: CMVideoFormatDescription) {
        guard let writer, let videoInput, writer.status == .writing else {
            finish(message: String(localized: "録画を保存できませんでした"))
            return
        }
        // 復号の時刻 = 届いた時刻(RTMP ではカメラの時刻)− 始めた時刻。必ず前の絵より後ろにする
        var dts = CMTimeConvertScale(CMTimeSubtract(arrival, startHostTime), timescale: 90_000,
                                     method: .roundHalfAwayFromZero)
        if lastVideoPTS.isValid, CMTimeCompare(dts, lastVideoPTS) <= 0 {
            dts = CMTimeAdd(lastVideoPTS, CMTime(value: 1, timescale: 90_000))
        }
        // 表示の時刻(B フレームのときだけ復号の時刻とずれる)。復号の時刻より前にはしない
        var pts = dts
        if CMTimeCompare(composition, .zero) != 0 {
            pts = CMTimeConvertScale(CMTimeAdd(dts, composition), timescale: 90_000, method: .roundHalfAwayFromZero)
            if CMTimeCompare(pts, dts) < 0 { pts = dts }
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
        guard let sample = Self.makeSample(pictures, format: format, pts: pts, dts: dts, isKey: isKey) else { return }
        guard videoInput.append(sample) else {
            log("recorder: append failed \(writer.error?.localizedDescription ?? "")")
            finish(message: String(localized: "録画を保存できませんでした"))
            return
        }
        lastVideoPTS = dts
        if !lastPresentationPTS.isValid || CMTimeCompare(pts, lastPresentationPTS) > 0 { lastPresentationPTS = pts }
        lastFrameHostTime = arrival
        lastWriteRealTime = Self.hostNow()
        writtenFrames += 1
    }

    // MARK: カメラの音(RTMP、q の上)

    /// カメラの時刻(ミリ秒)をホストの時計に写す。最初に届いた時刻を基準にする
    private func cameraHostTime(_ ms: Int64) -> CMTime {
        if cameraClockBase == nil { cameraClockBase = (ms, Self.hostNow()) }
        guard let base = cameraClockBase else { return Self.hostNow() }
        return CMTimeAdd(base.host, CMTime(value: ms - base.ms, timescale: 1000))
    }

    private func appendCameraAudio(_ frame: [UInt8], at hostTime: CMTime) {
        guard usesCameraAudio, state == .writing, let audioInput, let writer, writer.status == .writing,
              startHostTime.isValid, let fmt = cameraAudioFormat,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mSampleRate > 0
        else { return }
        let rate = CMTimeScale(asbd.mSampleRate.rounded())
        let framesPerPacket = Int64(asbd.mFramesPerPacket > 0 ? asbd.mFramesPerPacket : 1024)
        var pts = CMTimeConvertScale(CMTimeSubtract(hostTime, startHostTime), timescale: rate,
                                     method: .roundHalfAwayFromZero)
        // 0 秒より前の音は捨てる
        guard CMTimeCompare(pts, .zero) >= 0 else { return }
        // RTMP の時刻はミリ秒に丸められている。ずれが小さいあいだはサンプル数で進めて、つなぎ目に隙間や重なりを作らない
        if cameraAudioNextPTS.isValid {
            let gap = CMTimeGetSeconds(CMTimeSubtract(pts, cameraAudioNextPTS))
            if abs(gap) < 0.1 {
                pts = cameraAudioNextPTS
            } else if gap < 0 {
                return  // 前の音と重なる(時刻が戻った)ものは捨てる
            }
        }
        cameraAudioNextPTS = CMTimeAdd(pts, CMTime(value: framesPerPacket, timescale: rate))
        // 音は少し欠けても困らないので、受けられなければ捨てる
        guard audioInput.isReadyForMoreMediaData else { return }
        guard let sample = Self.makeAACSample(frame, format: fmt, pts: pts) else { return }
        if !audioInput.append(sample), !audioAppendFailed {
            audioAppendFailed = true
            log("recorder: camera audio append failed \(writer.error?.localizedDescription ?? "")")
        }
    }

    /// AAC の AudioSpecificConfig から音の形式を作る(カメラの音を作り直さずに書くため)。
    /// マジッククッキーは MP4 の esds と同じ形(ES_Descriptor の中に AudioSpecificConfig)にする
    static func makeAACFormat(audioSpecificConfig asc: [UInt8]) -> CMAudioFormatDescription? {
        guard asc.count >= 2, asc.count < 100 else { return nil }
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let objectType = Int(asc[0] >> 3)
        let rateIndex = Int((asc[0] & 0x07) << 1 | asc[1] >> 7)
        let channels = Int((asc[1] >> 3) & 0x0F)
        guard objectType > 0, objectType < 31, rateIndex < rates.count, (1...6).contains(channels) else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rates[rateIndex], mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(objectType),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
        // DecoderConfigDescriptor: 0x40 = MPEG-4 Audio、0x15 = 音のストリーム、バッファと平均・最大ビットレートは 0
        let decoderConfig = descriptor(0x04, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descriptor(0x05, asc))
        let cookie = descriptor(0x03, [0x00, 0x00, 0x00] + decoderConfig + descriptor(0x06, [0x02]))
        var out: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: raw.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &out)
        }
        return status == noErr ? out : nil
    }

    /// 生の AAC 1 フレームを 1 つのサンプルにする
    private static func makeAACSample(_ frame: [UInt8], format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        guard !frame.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frame.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block
        else { return nil }
        let copied = frame.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: frame.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                  mDataByteSize: UInt32(frame.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: pts, packetDescriptions: &packet, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
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
        // カメラの AAC をそのまま書いている入力に、マイクの PCM を混ぜない(形式が違うと書き込みが失敗する)
        guard !usesCameraAudio else { return }
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
            // 最後の絵にも 1 枚分(約 25fps)の長さを付ける(B フレームがあれば表示の時刻のいちばん後ろから)
            let lastEnd = lastPresentationPTS.isValid && CMTimeCompare(lastPresentationPTS, lastVideoPTS) > 0
                ? lastPresentationPTS : lastVideoPTS
            if lastEnd.isValid {
                writer.endSession(atSourceTime: CMTimeAdd(lastEnd, CMTime(value: 1, timescale: 25)))
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
        lastWriteRealTime = .invalid
        usesCameraAudio = false
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
                                   pts: CMTime, dts: CMTime, isKey: Bool) -> CMSampleBuffer? {
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
        // ライブビューに B フレームは無い前提(pts = dts)。RTMP は composition time から pts を作る。長さは次の絵との差で決まる
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: dts)
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
