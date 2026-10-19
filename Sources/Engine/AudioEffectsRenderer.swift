import Foundation
import AVFoundation
import CryptoKit

// =====================================================================
// 音声エフェクト(EQ・ピッチ・ボイスプリセット・簡易ノイズ低減)の事前レンダリング。
//
// ファイル全体を一度だけ AVAudioEngine のオフライン描画で処理し、
// Caches/ProcessedAudio/<hash>.m4a に保存する。CompositionBuilder は
// cachedProcessedURL(for:effects:) が返すファイルを元素材の代わりに使う
// (処理済みファイルは元素材と同じタイムラインを持つ)。
// =====================================================================

enum AudioEffectsRendererError: LocalizedError {
    case noAudioTrack
    case cannotCreateBuffer
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "音声トラックがありません"
        case .cannotCreateBuffer: return "音声バッファを確保できませんでした"
        case .renderFailed(let detail): return "音声効果の処理に失敗しました: \(detail)"
        }
    }
}

enum AudioEffectsRenderer {
    private static let lock = NSLock()
    private static var inFlight: [String: Task<URL, Error>] = [:]

    /// Caches/ProcessedAudio(必要に応じて作成)
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ProcessedAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - キャッシュ

    /// 元ファイル(名前・サイズ・更新日時)と効果の値から決まるキー(起動をまたいでも同じ)
    static func cacheKey(for url: URL, effects: AudioEffects) -> String {
        var components: [String] = [url.lastPathComponent]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            components.append(String(size))
            components.append(String(format: "%.0f", modified))
        }
        components.append(String(format: "%.3f", effects.eqLow))
        components.append(String(format: "%.3f", effects.eqMid))
        components.append(String(format: "%.3f", effects.eqHigh))
        components.append(String(format: "%.3f", effects.pitchSemitones))
        components.append(effects.voicePreset.rawValue)
        components.append(String(format: "%.3f", effects.noiseReduction))
        components.append("v1")
        let digest = SHA256.hash(data: Data(components.joined(separator: "|").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheURL(for url: URL, effects: AudioEffects) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(for: url, effects: effects) + ".m4a")
    }

    /// 処理済みファイルがあればその URL(同期。effects が identity なら nil)
    static func cachedProcessedURL(for url: URL, effects: AudioEffects) -> URL? {
        guard !effects.isIdentity else { return nil }
        let target = cacheURL(for: url, effects: effects)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// 処理済みファイルを返す(無ければ作る)。effects が identity なら元の URL をそのまま返す
    static func processedURL(for url: URL, effects: AudioEffects) async throws -> URL {
        if effects.isIdentity { return url }
        let key = cacheKey(for: url, effects: effects)
        let target = cacheDirectory.appendingPathComponent(key + ".m4a")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return try await existing.value
        }
        let task = Task.detached(priority: .userInitiated) { () async throws -> URL in
            try await AudioEffectsRenderer.render(source: url, effects: effects, to: target)
            return target
        }
        inFlight[key] = task
        lock.unlock()
        defer {
            lock.lock()
            inFlight[key] = nil
            lock.unlock()
        }
        return try await task.value
    }

    /// キャッシュをすべて削除する
    static func clearCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: - レンダリング

    private static func render(source: URL, effects: AudioEffects, to target: URL) async throws {
        let fm = FileManager.default
        let tempDirectory = fm.temporaryDirectory
        let extracted = tempDirectory.appendingPathComponent("fx_\(UUID().uuidString).m4a")
        let rendered = tempDirectory.appendingPathComponent("fx_\(UUID().uuidString)_out.m4a")
        defer {
            try? fm.removeItem(at: extracted)
            try? fm.removeItem(at: rendered)
        }
        // 動画コンテナでも確実に読めるよう、まず音声だけを m4a に取り出す
        try await MediaTools.exportAudio(from: source, start: nil, end: nil, to: extracted)
        try renderBlocking(input: extracted, output: rendered, effects: effects)
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
        try fm.moveItem(at: rendered, to: target)
    }

    private static func renderBlocking(input inputURL: URL, output outputURL: URL, effects: AudioEffects) throws {
        let file = try AVAudioFile(forReading: inputURL)
        let format = file.processingFormat
        guard file.length > 0, format.channelCount > 0 else { throw AudioEffectsRendererError.noAudioTrack }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 5)
        let timePitch = AVAudioUnitTimePitch()
        let distortion = AVAudioUnitDistortion()
        let reverb = AVAudioUnitReverb()
        engine.attach(player)
        engine.attach(eq)
        engine.attach(timePitch)
        engine.attach(distortion)
        engine.attach(reverb)
        configure(eq: eq, timePitch: timePitch, distortion: distortion, reverb: reverb, effects: effects)

        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: timePitch, format: format)
        engine.connect(timePitch, to: distortion, format: format)
        engine.connect(distortion, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
        } catch {
            throw AudioEffectsRendererError.renderFailed(error.localizedDescription)
        }
        player.scheduleFile(file, at: nil, completionHandler: nil)
        player.play()

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 192_000
        ]
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let outputFile = try AVAudioFile(forWriting: outputURL,
                                         settings: outputSettings,
                                         commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw AudioEffectsRendererError.cannotCreateBuffer
        }

        // 各ユニットの遅延分だけ先頭を捨て、末尾は余分に描画して元素材と同じタイムラインにそろえる
        let latencySeconds = eq.auAudioUnit.latency + timePitch.auAudioUnit.latency
            + distortion.auAudioUnit.latency + reverb.auAudioUnit.latency
        var framesToSkip = max(0, Int((latencySeconds * format.sampleRate).rounded()))
        let tailSeconds: Double = effects.voicePreset == .cathedral ? 2.5 : 0.3
        let totalFrames = file.length + AVAudioFramePosition(latencySeconds * format.sampleRate)
            + AVAudioFramePosition(tailSeconds * format.sampleRate)

        let gate: AudioEffectsNoiseGate? = effects.noiseReduction > 0
            ? AudioEffectsNoiseGate(amount: effects.noiseReduction, sampleRate: format.sampleRate)
            : nil

        var stalls = 0
        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(count, to: buffer)
            } catch {
                player.stop()
                engine.stop()
                throw AudioEffectsRendererError.renderFailed(error.localizedDescription)
            }
            switch status {
            case .success:
                stalls = 0
                gate?.process(buffer)
                try write(buffer, to: outputFile, skipping: &framesToSkip)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 50 {
                    player.stop()
                    engine.stop()
                    throw AudioEffectsRendererError.renderFailed("音声を描画できませんでした")
                }
            case .error:
                player.stop()
                engine.stop()
                throw AudioEffectsRendererError.renderFailed("描画エラー")
            @unknown default:
                player.stop()
                engine.stop()
                throw AudioEffectsRendererError.renderFailed("不明な状態")
            }
        }
        player.stop()
        engine.stop()
    }

    /// 先頭の skip フレームを捨てて書き込む
    private static func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile, skipping skip: inout Int) throws {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        if skip <= 0 {
            try file.write(from: buffer)
            return
        }
        if skip >= n {
            skip -= n
            return
        }
        let count = n - skip
        guard !buffer.format.isInterleaved,
              let source = buffer.floatChannelData,
              let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let destination = trimmed.floatChannelData else {
            // 想定外の形式のときはそのまま書く(わずかな遅れが残るだけ)
            skip = 0
            try file.write(from: buffer)
            return
        }
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            destination[c].update(from: source[c].advanced(by: skip), count: count)
        }
        trimmed.frameLength = AVAudioFrameCount(count)
        skip = 0
        try file.write(from: trimmed)
    }

    // MARK: - ユニット設定

    private static func configure(eq: AVAudioUnitEQ,
                                  timePitch: AVAudioUnitTimePitch,
                                  distortion: AVAudioUnitDistortion,
                                  reverb: AVAudioUnitReverb,
                                  effects: AudioEffects) {
        // bands: 0 ハイパス / 1 低域シェルフ / 2 中域 / 3 高域シェルフ / 4 ローパス
        let bands = eq.bands
        guard bands.count >= 5 else { return }
        bands[0].filterType = .highPass
        bands[0].frequency = 80
        bands[0].bandwidth = 0.5
        bands[0].bypass = true

        bands[1].filterType = .lowShelf
        bands[1].frequency = 150
        bands[1].gain = Float(min(max(effects.eqLow, -24), 24))
        bands[1].bypass = effects.eqLow == 0

        bands[2].filterType = .parametric
        bands[2].frequency = 1000
        bands[2].bandwidth = 1.5
        bands[2].gain = Float(min(max(effects.eqMid, -24), 24))
        bands[2].bypass = effects.eqMid == 0

        bands[3].filterType = .highShelf
        bands[3].frequency = 6000
        bands[3].gain = Float(min(max(effects.eqHigh, -24), 24))
        bands[3].bypass = effects.eqHigh == 0

        bands[4].filterType = .lowPass
        bands[4].frequency = 18_000
        bands[4].bandwidth = 0.5
        bands[4].bypass = true

        if effects.noiseReduction > 0 {
            bands[0].bypass = false
            bands[0].frequency = Float(80 + 80 * min(max(effects.noiseReduction, 0), 1))
        }

        var pitchCents = Float(effects.pitchSemitones * 100)
        distortion.bypass = true
        distortion.wetDryMix = 0
        reverb.bypass = true
        reverb.wetDryMix = 0

        switch effects.voicePreset {
        case .none:
            break
        case .robot:
            distortion.loadFactoryPreset(.speechCosmicInterference)
            distortion.wetDryMix = 45
            distortion.bypass = false
            pitchCents -= 200
        case .chipmunk:
            pitchCents += 700
        case .deep:
            pitchCents -= 500
        case .radio:
            bands[0].bypass = false
            bands[0].frequency = 300
            bands[4].bypass = false
            bands[4].frequency = 3400
            distortion.loadFactoryPreset(.speechRadioTower)
            distortion.wetDryMix = 25
            distortion.bypass = false
        case .telephone:
            bands[0].bypass = false
            bands[0].frequency = 400
            bands[4].bypass = false
            bands[4].frequency = 3000
            distortion.loadFactoryPreset(.multiDecimated2)
            distortion.wetDryMix = 15
            distortion.bypass = false
        case .cathedral:
            reverb.loadFactoryPreset(.cathedral)
            reverb.wetDryMix = 55
            reverb.bypass = false
        }

        timePitch.pitch = min(max(pitchCents, -2400), 2400)
        timePitch.rate = 1
        timePitch.overlap = 8
        timePitch.bypass = (pitchCents == 0)
        eq.globalGain = 0
    }
}

/// 簡易ノイズゲート(RMS がしきい値未満の区間の音量を下げる)
private final class AudioEffectsNoiseGate {
    private let thresholdLinear: Float
    private let floorGain: Float
    private let attack: Float
    private let release: Float
    private var gain: Float = 1

    init(amount: Double, sampleRate: Double) {
        let a = Float(min(max(amount, 0), 1))
        let thresholdDB: Float = -62 + 24 * a      // -62 ... -38 dBFS
        thresholdLinear = powf(10, thresholdDB / 20)
        floorGain = 1 - 0.85 * a
        let rate = Float(max(8000, sampleRate))
        attack = 1 - expf(-1 / (rate * 0.005))
        release = 1 - expf(-1 / (rate * 0.08))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard !buffer.format.isInterleaved, let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard n > 0, channels > 0 else { return }
        let block = 128
        var i = 0
        while i < n {
            let end = min(n, i + block)
            var sum: Float = 0
            for c in 0..<channels {
                let p = data[c]
                for j in i..<end {
                    sum += p[j] * p[j]
                }
            }
            let rms = sqrtf(sum / Float((end - i) * channels))
            let target: Float = rms < thresholdLinear ? floorGain : 1
            for j in i..<end {
                let coefficient = target > gain ? attack : release
                gain += (target - gain) * coefficient
                for c in 0..<channels {
                    data[c][j] *= gain
                }
            }
            i = end
        }
    }
}
