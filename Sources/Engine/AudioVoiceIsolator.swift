import Foundation
import AVFoundation
import AudioToolbox

// =====================================================================
// AI で声だけを残す(Apple の音声分離 AUSoundIsolation。iPhone の「声を分離」と同じ仕組み)。
//
// AVAudioEngine のオフライン描画でファイル全体を処理する。amount(0...1)は処理後の音の割合
// (WetDryMix)。音声分離には遅れ(レイテンシ)があるので、その分だけ先頭を捨てて元の時刻にそろえる。
// 使えない端末・形式では例外を投げるので、呼び出し側で従来のノイズ低減に切り替える。
// =====================================================================

enum AudioVoiceIsolatorError: LocalizedError {
    case unavailable
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "この端末では AI の音声分離を使えません"
        case .renderFailed: return "AI の音声分離に失敗しました"
        }
    }
}

enum AudioVoiceIsolator {
    /// kAudioUnitSubType_AUSoundIsolation('vois')
    private static let soundIsolationSubType: OSType = 0x766F_6973
    /// kAUSoundIsolationParam_WetDryMixPercent
    private static let wetDryMixAddress: AUParameterAddress = 0

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: soundIsolationSubType,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    static var isAvailable: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    static func process(input: URL, output: URL, amount: Double) throws {
        guard isAvailable else { throw AudioVoiceIsolatorError.unavailable }
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.channelCount > 0 else { throw AudioEffectsRendererError.noAudioTrack }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let isolation = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        engine.attach(player)
        engine.attach(isolation)
        engine.connect(player, to: isolation, format: format)
        engine.connect(isolation, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)

        let mix = Float(min(max(amount, 0), 1) * 100)
        if let parameter = isolation.auAudioUnit.parameterTree?.parameter(withAddress: wetDryMixAddress) {
            parameter.value = mix
        }

        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleFile(file, at: nil)
        player.play()

        let renderFormat = engine.manualRenderingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw AudioEffectsRendererError.cannotCreateBuffer
        }
        let outFile = try AVAudioFile(forWriting: output,
                                      settings: renderFormat.settings,
                                      commonFormat: renderFormat.commonFormat,
                                      interleaved: renderFormat.isInterleaved)

        // 音声分離の遅れの分だけ先頭を捨て、その分だけ最後まで多めに描く
        let latencySeconds = max(0, isolation.auAudioUnit.latency)
        var toSkip = AVAudioFramePosition((latencySeconds * renderFormat.sampleRate).rounded())
        var written: AVAudioFramePosition = 0
        var stalls = 0
        while written < total {
            try Task.checkCancellation()
            let remaining = total - written + toSkip
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), max(1, remaining)))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                stalls = 0
                var produced = AVAudioFramePosition(buffer.frameLength)
                if toSkip > 0 {
                    let skip = min(toSkip, produced)
                    toSkip -= skip
                    if skip > 0 {
                        dropLeadingFrames(buffer, count: AVAudioFrameCount(skip))
                    }
                    produced = AVAudioFramePosition(buffer.frameLength)
                }
                let keep = min(produced, total - written)
                if keep > 0 {
                    buffer.frameLength = AVAudioFrameCount(keep)
                    try outFile.write(from: buffer)
                    written += keep
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 1000 { throw AudioVoiceIsolatorError.renderFailed }
            case .error:
                throw AudioVoiceIsolatorError.renderFailed
            @unknown default:
                throw AudioVoiceIsolatorError.renderFailed
            }
        }
    }

    /// バッファの先頭 count フレームを捨てて詰める
    private static func dropLeadingFrames(_ buffer: AVAudioPCMBuffer, count: AVAudioFrameCount) {
        let length = buffer.frameLength
        guard count > 0 else { return }
        guard count < length else {
            buffer.frameLength = 0
            return
        }
        let remaining = Int(length - count)
        let channels = Int(buffer.format.channelCount)
        if let data = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let p = data[0]
                memmove(p, p + Int(count) * channels, remaining * channels * MemoryLayout<Float>.size)
            } else {
                for c in 0..<channels {
                    let p = data[c]
                    memmove(p, p + Int(count), remaining * MemoryLayout<Float>.size)
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(remaining)
    }
}
