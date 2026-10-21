import Foundation
import AVFoundation
import Accelerate
import CryptoKit

// =====================================================================
// 音声エフェクト(EQ・ピッチ・ボイスプリセット・ノイズ低減)の事前レンダリング。
//
// ファイル全体を一度だけ AVAudioEngine のオフライン描画で処理し、
// Caches/ProcessedAudio/<hash>.m4a に保存する。CompositionBuilder は
// cachedProcessedURL(for:effects:) が返すファイルを元素材の代わりに使う
// (処理済みファイルは元素材と同じタイムラインを持つ)。
//
// ノイズ低減(noiseReduction > 0)は、まず AI の音声分離(AudioVoiceIsolator。声だけを残す)を使い、
// 使えないときは次の 2 段構え:
//   1. スペクトルゲート(AudioEffectsSpectralDenoiser): STFT(窓 1024・ホップ 256・√Hann)で
//      ファイル全体の各周波数ビンの大きさの 10 パーセンタイルをノイズプロファイルとし、
//      各フレームで「大きさ − プロファイル × (1 + 2 × nr)」まで下げる(下限 0.1 ... 1 − 0.9nr)。
//      ゲインは周波数方向 3 ビン平均・時間方向に緩やかに戻してミュージカルノイズを抑える
//   2. 従来のハイパス + 軽いノイズゲート(EQ / ピッチのチェーンの中)
// =====================================================================

enum AudioEffectsRendererError: LocalizedError {
    case noAudioTrack
    case cannotCreateBuffer
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return String(localized: "音声トラックがありません")
        case .cannotCreateBuffer: return String(localized: "音声バッファを確保できませんでした")
        case .renderFailed(let detail): return String(localized: "音声効果の処理に失敗しました: \(detail)")
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
        components.append("v3")
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
        let denoised = tempDirectory.appendingPathComponent("fx_\(UUID().uuidString)_nr.caf")
        let rendered = tempDirectory.appendingPathComponent("fx_\(UUID().uuidString)_out.m4a")
        defer {
            try? fm.removeItem(at: extracted)
            try? fm.removeItem(at: denoised)
            try? fm.removeItem(at: rendered)
        }
        // 動画コンテナでも確実に読めるよう、まず音声だけを m4a に取り出す
        try await MediaTools.exportAudio(from: source, start: nil, end: nil, to: extracted)
        try Task.checkCancellation()

        // ノイズ低減: まず AI の音声分離(声だけを残す)。使えなければスペクトルゲート。
        // どちらも失敗したときは従来のゲート処理だけで続ける
        var chainInput = extracted
        if effects.noiseReduction > 0 {
            do {
                try AudioVoiceIsolator.process(input: extracted, output: denoised, amount: effects.noiseReduction)
                chainInput = denoised
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? fm.removeItem(at: denoised)
                do {
                    try AudioEffectsSpectralDenoiser.process(input: extracted, output: denoised, amount: effects.noiseReduction)
                    chainInput = denoised
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    chainInput = extracted
                }
            }
        }
        try renderBlocking(input: chainInput, output: rendered, effects: effects)
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

        // スペクトル処理の後なのでゲートは控えめにかける
        let gate: AudioEffectsNoiseGate? = effects.noiseReduction > 0
            ? AudioEffectsNoiseGate(amount: effects.noiseReduction * 0.5, sampleRate: format.sampleRate)
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
                    throw AudioEffectsRendererError.renderFailed(String(localized: "音声を描画できませんでした"))
                }
            case .error:
                player.stop()
                engine.stop()
                throw AudioEffectsRendererError.renderFailed(String(localized: "描画エラー"))
            @unknown default:
                player.stop()
                engine.stop()
                throw AudioEffectsRendererError.renderFailed(String(localized: "不明な状態"))
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

// MARK: - スペクトルゲート

/// 1 チャンネル分のストリーミング STFT/OLA の状態
private final class AudioEffectsDenoiseChannel {
    /// 入力(先頭に n − hop 個の 0 を詰めてある)。input[0] の絶対位置が base
    var input: [Float]
    /// input と同じ基準で重ね合わせた出力
    var output: [Float]
    var base = 0
    /// 次に処理するフレームの絶対位置
    var nextFrame = 0
    /// 出力済みの絶対位置
    var emitted = 0
    var previousGains: [Float]
    /// 書き出し待ちのサンプル
    var pending: [Float] = []

    init(n: Int, hop: Int, bins: Int) {
        input = [Float](repeating: 0, count: n - hop)
        output = [Float](repeating: 0, count: n - hop)
        previousGains = [Float](repeating: 1, count: bins)
    }
}

/// スペクトルゲートによるノイズ低減(STFT 1024 / ホップ 256 / √Hann 窓、vDSP の実数 FFT)。
/// パス 1 でノイズプロファイル(各ビンの 10 パーセンタイル)を集め、パス 2 でゲインをかけて書き出す。
/// 出力は入力と同じサンプル数・同じチャンネル数の float32 CAF。
private final class AudioEffectsSpectralDenoiser {
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let hop = 256
    /// 複素ビン数(realp[0] = 直流、imagp[0] = ナイキスト)
    private let halfN = 512
    private let setup: FFTSetup
    private let window: [Float]
    /// 1 / 窓の二乗をホップごとに重ねた和
    private let olaScale: Float
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>
    private var smoothedGains: [Float]

    init?() {
        guard let created = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { return nil }
        setup = created
        let length = 1024
        let hopLength = 256
        var w = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(length))
            w[i] = Float(sqrt(max(0, hann)))
        }
        window = w
        var sum: Float = 0
        for i in 0..<hopLength {
            var s: Float = 0
            var k = i
            while k < length {
                s += w[k] * w[k]
                k += hopLength
            }
            sum += s
        }
        let mean = sum / Float(hopLength)
        olaScale = mean > 0 ? 1 / mean : 0.5
        realp = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        imagp = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        frame = UnsafeMutablePointer<Float>.allocate(capacity: length)
        magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        gains = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        realp.initialize(repeating: 0, count: 512)
        imagp.initialize(repeating: 0, count: 512)
        frame.initialize(repeating: 0, count: length)
        magnitudes.initialize(repeating: 0, count: 512)
        gains.initialize(repeating: 1, count: 512)
        smoothedGains = [Float](repeating: 1, count: 512)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        realp.deallocate()
        imagp.deallocate()
        frame.deallocate()
        magnitudes.deallocate()
        gains.deallocate()
    }

    static func process(input: URL, output: URL, amount: Double) throws {
        guard let denoiser = AudioEffectsSpectralDenoiser() else {
            throw AudioEffectsRendererError.renderFailed(String(localized: "FFT を準備できませんでした"))
        }
        try denoiser.run(input: input, output: output, amount: amount)
    }

    // MARK: FFT

    /// input(n サンプル)に窓をかけて FFT。realp / imagp に結果、magnitudes に各ビンの大きさ。戻り値はナイキストの大きさ
    private func forward(_ input: UnsafePointer<Float>) -> Float {
        vDSP_vmul(input, 1, window, 1, frame, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPointer in
            vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(halfN))
        let nyquist = abs(imagp[0])
        magnitudes[0] = abs(realp[0])
        return nyquist
    }

    /// realp / imagp を逆変換し、窓をかけて output に加算する
    private func inverseAdd(into output: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPointer in
            vDSP_ztoc(&split, 1, complexPointer, 2, vDSP_Length(halfN))
        }
        var scale = olaScale / Float(2 * n)
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(n))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))
        vDSP_vadd(output, 1, frame, 1, output, 1, vDSP_Length(n))
    }

    /// magnitudes とプロファイルからビンごとのゲインを作り、スペクトルに掛ける
    private func applyGains(profile: [Float], nyquistMagnitude: Float, over: Float, floorGain: Float,
                            previous: inout [Float]) {
        for k in 0..<halfN {
            let magnitude = magnitudes[k]
            let threshold = profile[k] * over
            var g = floorGain
            if magnitude > 1e-9 {
                g = max(floorGain, (magnitude - threshold) / magnitude)
            }
            gains[k] = g
        }
        // 周波数方向に 3 ビン平均、時間方向には前のゲインの 0.6 倍を下回らないようにする
        for k in 0..<halfN {
            let lo = max(0, k - 1)
            let hi = min(halfN - 1, k + 1)
            var s: Float = 0
            for j in lo...hi { s += gains[j] }
            let average = s / Float(hi - lo + 1)
            smoothedGains[k] = max(average, previous[k] * 0.6)
        }
        for k in 0..<halfN {
            gains[k] = smoothedGains[k]
            previous[k] = smoothedGains[k]
        }
        // ナイキスト
        var nyquistGain = floorGain
        let nyquistThreshold = profile[halfN - 1] * over
        if nyquistMagnitude > 1e-9 {
            nyquistGain = max(floorGain, (nyquistMagnitude - nyquistThreshold) / nyquistMagnitude)
        }
        realp[0] *= gains[0]
        imagp[0] *= nyquistGain
        let rest = vDSP_Length(halfN - 1)
        vDSP_vmul(realp + 1, 1, gains + 1, 1, realp + 1, 1, rest)
        vDSP_vmul(imagp + 1, 1, gains + 1, 1, imagp + 1, 1, rest)
    }

    // MARK: 実行

    private func run(input: URL, output: URL, amount: Double) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let length = Int(file.length)
        guard length > 0, channels > 0, !format.isInterleaved, format.commonFormat == .pcmFormatFloat32 else {
            throw AudioEffectsRendererError.renderFailed(String(localized: "対応していない音声形式です"))
        }
        let nr = Float(min(max(amount, 0), 1))
        let blockFrames: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw AudioEffectsRendererError.cannotCreateBuffer
        }

        // パス 1: ノイズプロファイル(各ビンの大きさの 10 パーセンタイルをヒストグラムで求める)
        let bucketCount = 96
        let minDB: Float = -120
        let stepDB: Float = 1.25
        var histogram = [Int32](repeating: 0, count: channels * halfN * bucketCount)
        var carries = [[Float]](repeating: [], count: channels)
        var frameCount = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            try file.read(into: buffer, frameCount: blockFrames)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for c in 0..<channels {
                carries[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: count))
                var offset = 0
                let available = carries[c].count
                let channelBase = c * halfN * bucketCount
                while offset + n <= available {
                    let frameOffset = offset
                    carries[c].withUnsafeBufferPointer { pointer in
                        if let baseAddress = pointer.baseAddress {
                            _ = forward(baseAddress + frameOffset)
                        }
                    }
                    for k in 0..<halfN {
                        let db = 20 * log10f(magnitudes[k] + 1e-9)
                        var bucket = Int((db - minDB) / stepDB)
                        bucket = min(bucketCount - 1, max(0, bucket))
                        histogram[channelBase + k * bucketCount + bucket] += 1
                    }
                    offset += n   // パス 1 は重ねない
                    if c == 0 { frameCount += 1 }
                }
                if offset > 0 {
                    carries[c].removeFirst(offset)
                }
            }
        }
        guard frameCount > 0 else {
            throw AudioEffectsRendererError.renderFailed(String(localized: "音声が短すぎます"))
        }
        var profiles = [[Float]](repeating: [Float](repeating: 0, count: halfN), count: channels)
        for c in 0..<channels {
            for k in 0..<halfN {
                let baseIndex = c * halfN * bucketCount + k * bucketCount
                var total: Int32 = 0
                for b in 0..<bucketCount { total += histogram[baseIndex + b] }
                guard total > 0 else { continue }
                let target = Int32((Float(total) * 0.1).rounded(.up))
                var cumulative: Int32 = 0
                var chosen = bucketCount - 1
                for b in 0..<bucketCount {
                    cumulative += histogram[baseIndex + b]
                    if cumulative >= target && cumulative > 0 {
                        chosen = b
                        break
                    }
                }
                let db = minDB + stepDB * Float(chosen + 1)
                profiles[c][k] = powf(10, db / 20)
            }
        }

        // パス 2: ゲートをかけて書き出す
        file.framePosition = 0
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        let writer = try AVAudioFile(forWriting: output, settings: fileSettings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let outCapacity = blockFrames + AVAudioFrameCount(n)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else {
            throw AudioEffectsRendererError.cannotCreateBuffer
        }
        var streams: [AudioEffectsDenoiseChannel] = []
        for _ in 0..<channels {
            streams.append(AudioEffectsDenoiseChannel(n: n, hop: hop, bins: halfN))
        }
        let over: Float = 1 + 2 * nr
        let residual: Float = 1 - nr
        let floorGain: Float = 0.1 + 0.9 * residual * residual
        var written = 0
        var finished = false

        while !finished {
            if Task.isCancelled { throw CancellationError() }
            try file.read(into: buffer, frameCount: blockFrames)
            let count = Int(buffer.frameLength)
            if count == 0 { finished = true }
            if let data = buffer.floatChannelData {
                for c in 0..<channels {
                    if count > 0 {
                        streams[c].input.append(contentsOf: UnsafeBufferPointer(start: data[c], count: count))
                    }
                    processChannel(streams[c], profile: profiles[c], over: over, floorGain: floorGain,
                                   finalLength: length, flush: finished)
                }
            } else {
                finished = true
            }
            var ready = Int.max
            for stream in streams { ready = min(ready, stream.pending.count) }
            if ready > 0 && ready != Int.max {
                try write(streams, count: ready, to: writer, using: outBuffer)
                written += ready
            }
        }

        // 不足分(通常は無い)は無音で埋めて長さをそろえる
        if written < length {
            var remaining = length - written
            guard let data = outBuffer.floatChannelData else { return }
            while remaining > 0 {
                let chunk = min(remaining, Int(outBuffer.frameCapacity))
                for c in 0..<channels {
                    data[c].update(repeating: 0, count: chunk)
                }
                outBuffer.frameLength = AVAudioFrameCount(chunk)
                try writer.write(from: outBuffer)
                remaining -= chunk
            }
        }
    }

    /// 溜まった入力を処理できるだけ処理し、確定した出力を pending に移す
    private func processChannel(_ channel: AudioEffectsDenoiseChannel, profile: [Float], over: Float,
                                floorGain: Float, finalLength: Int, flush: Bool) {
        if flush {
            channel.input.append(contentsOf: [Float](repeating: 0, count: n))
        }
        if channel.output.count < channel.input.count {
            channel.output.append(contentsOf: [Float](repeating: 0, count: channel.input.count - channel.output.count))
        }
        while channel.nextFrame + n <= channel.base + channel.input.count {
            let offset = channel.nextFrame - channel.base
            let nyquist: Float = channel.input.withUnsafeBufferPointer { pointer -> Float in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return forward(baseAddress + offset)
            }
            applyGains(profile: profile, nyquistMagnitude: nyquist, over: over, floorGain: floorGain,
                       previous: &channel.previousGains)
            channel.output.withUnsafeMutableBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    inverseAdd(into: baseAddress + offset)
                }
            }
            channel.nextFrame += hop
        }

        // 絶対位置 [emitted, nextFrame) は確定。先頭の詰め物(n − hop)を除いた元の位置に対応させる
        let padding = n - hop
        let lower = max(channel.emitted, padding)
        let upper = min(channel.nextFrame, padding + finalLength)
        if upper > lower {
            let from = lower - channel.base
            let to = upper - channel.base
            if from >= 0 && to <= channel.output.count {
                channel.pending.append(contentsOf: channel.output[from..<to])
            }
        }
        channel.emitted = max(channel.emitted, channel.nextFrame)

        // 使い終わった先頭を捨てる
        let drop = channel.nextFrame - channel.base
        if drop > 0 && drop <= channel.input.count && drop <= channel.output.count {
            channel.input.removeFirst(drop)
            channel.output.removeFirst(drop)
            channel.base = channel.nextFrame
        }
    }

    private func write(_ streams: [AudioEffectsDenoiseChannel], count: Int, to file: AVAudioFile,
                       using buffer: AVAudioPCMBuffer) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, Int(buffer.frameCapacity))
            guard let data = buffer.floatChannelData else { return }
            for (c, stream) in streams.enumerated() {
                stream.pending.withUnsafeBufferPointer { pointer in
                    if let baseAddress = pointer.baseAddress {
                        data[c].update(from: baseAddress, count: chunk)
                    }
                }
                stream.pending.removeFirst(chunk)
            }
            buffer.frameLength = AVAudioFrameCount(chunk)
            try file.write(from: buffer)
            remaining -= chunk
        }
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
