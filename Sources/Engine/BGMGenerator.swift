import Foundation
import AVFoundation

// =====================================================================
// 用意された曲(BGMPreset)をその場で合成する。ステレオ 44.1kHz。
//
// 音の作り方(安っぽくならないように):
//  - 発振器は PolyBLEP(帯域制限)ののこぎり波・矩形波。正弦波・三角波はテーブル引き
//  - 1 音 = 2〜3 本の発振器を数セントずらして重ね、開始位相はランダム
//  - 2 次の状態変数フィルター(SVF、レゾナンス付き)に専用のエンベロープ
//  - 打鍵タイミング ±8ms、強さ ±10% の揺らぎ
//  - 楽器: FM ピアノ(非整数倍音+ハンマーのノイズ+高い音ほど短い減衰)、
//          カープラス・ストロングのギター/ピチカート、スーパーソウ+LFO フィルター+コーラスのパッド、
//          サブ+中域+サチュレーションのベース、FM のベル/マレット、弦楽合奏(ずらしたのこぎり波+遅いアタック+ビブラート)
//  - ドラム: キック(正弦波スイープ+クリック+サチュレーション)、スネア(2 つの音+ノイズ+部屋鳴り)、
//            ハイハット(808 風に矩形波 6 本をハイパス)、手拍子(3 回ずらしたノイズ)
//  - バス処理: ベース以外は 120Hz でハイパス、パッドにコーラス、ステレオの Schroeder リバーブ(プリディレイ・ダンピング)、
//              軽いグルーコンプ、ソフトクリップのリミッター(-1dBFS)、RMS で -14 LUFS 相当にそろえる
//  - 構成: イントロ → A → B(楽器を足す)→ A' → … → アウトロ(フィルターを閉じてフェード)。
//          4 小節ごとにドラムのフィル、コードは前の声部に近い転回形(声部連結)、音階から作ったモチーフを変奏して乗せる
// 乱数の種はプリセット id なので、同じプリセットは何度作っても同じ曲になる。
// =====================================================================

enum BGMGenerator {
    static let sampleRate: Double = 44100
    /// 仕上がりのピーク(-1 dBFS)
    static let targetPeak: Float = 0.891
    /// 仕上がりの RMS(-16 dBFS ≒ -14 LUFS 前後)
    static let targetRMS: Float = 0.158

    enum GeneratorError: Error {
        case bufferUnavailable
    }

    // MARK: - 公開 API

    /// 曲を合成して url に書き出す(.m4a = AAC。拡張子が .caf なら PCM)。重い処理なのでバックグラウンドで行う
    static func render(preset: BGMPreset, seconds: Double = 60, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try renderFile(preset: preset, seconds: seconds, to: url)
        }.value
    }

    /// 試聴用の 15 秒(Caches に置き、2 回目からはそのまま返す)
    static func previewURL(preset: BGMPreset) async throws -> URL {
        let url = previewDirectory.appendingPathComponent("\(preset.id)_v2.m4a")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try await render(preset: preset, seconds: 15, to: url)
        return url
    }

    /// 試聴ファイルの置き場所(Caches/BGMPreviews)
    static var previewDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("BGMPreviews", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 同期版(呼び出し側でスレッドを選ぶ)
    static func renderFile(preset: BGMPreset, seconds: Double, to url: URL) throws {
        let master = renderMaster(preset: preset, seconds: seconds)
        defer { master.free() }
        let isPCM = url.pathExtension.lowercased() == "caf"
        let settings: [String: Any]
        if isPCM {
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        } else {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        // file はこの関数を抜けると閉じられる
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        // 曲全体ぶんのバッファは作らず、1 秒(44100 フレーム)のバッファを使い回して少しずつ書き出す
        let chunk = Int(sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let channels = buffer.floatChannelData else {
            throw GeneratorError.bufferUnavailable
        }
        var offset = 0
        while offset < master.count {
            let n = min(chunk, master.count - offset)
            channels[0].update(from: master.l + offset, count: n)
            channels[1].update(from: master.r + offset, count: n)
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            offset += n
        }
    }

    // MARK: - 乱数・テーブル

    /// 種を固定した乱数(splitmix64)
    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0..<1
        mutating func unit() -> Double {
            Double(next() >> 11) / 9_007_199_254_740_992.0
        }

        /// -1...1 のホワイトノイズ
        mutating func noise() -> Float {
            Float(unit() * 2 - 1)
        }

        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }

        mutating func int(_ n: Int) -> Int {
            Int(next() % UInt64(max(n, 1)))
        }

        mutating func chance(_ p: Double) -> Bool {
            unit() < p
        }
    }

    /// 文字列から安定した種を作る(FNV-1a。hashValue は起動ごとに変わるので使わない)
    static func seed(for id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in id.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    private static let tableSize = 4096
    private static let tableMask = 4095
    private static let sineTable: [Float] = (0..<tableSize).map { Float(sin(Double($0) / Double(tableSize) * 2 * .pi)) }

    /// PolyBLEP: 段差の前後 1 サンプルをなめらかにしてエイリアスを消す
    @inline(__always)
    private static func polyBlep(_ t: Double, _ dt: Double) -> Float {
        if t < dt {
            let x = t / dt
            return Float(x + x - x * x - 1)
        } else if t > 1 - dt {
            let x = (t - 1) / dt
            return Float(x * x + x + x + 1)
        }
        return 0
    }

    @inline(__always)
    private static func wrap(_ p: inout Double) {
        if p >= 1 { p -= 1 }
    }

    // MARK: - バッファ

    /// ステレオのバッファ(生ポインタ。ループの中で配列の境界チェックを避ける)
    final class Bus {
        let l: UnsafeMutablePointer<Float>
        let r: UnsafeMutablePointer<Float>
        let count: Int

        init(count: Int) {
            self.count = count
            l = UnsafeMutablePointer<Float>.allocate(capacity: count)
            r = UnsafeMutablePointer<Float>.allocate(capacity: count)
            l.initialize(repeating: 0, count: count)
            r.initialize(repeating: 0, count: count)
        }

        func clear() {
            l.update(repeating: 0, count: count)
            r.update(repeating: 0, count: count)
        }

        func free() {
            l.deallocate()
            r.deallocate()
        }
    }

    /// モノラルのバッファ(リバーブ送り)
    final class Mono {
        let p: UnsafeMutablePointer<Float>
        let count: Int

        init(count: Int) {
            self.count = count
            p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
        }

        func free() { p.deallocate() }
    }

    /// 1 音の書き込み先(バス+リバーブ送り)
    struct Target {
        let bus: Bus
        let send: Mono
        /// リバーブに送る量
        var sendLevel: Float
    }

    // MARK: - 音色(パッチ)

    enum Wave {
        case sine, triangle, saw, square
    }

    enum Model {
        /// 減算(発振器を重ねてフィルター)
        case analog
        /// FM ピアノ
        case fmPiano
        /// カープラス・ストロング(弦)
        case karplus
        /// FM ベル・マレット
        case fmBell
    }

    struct Patch {
        var model: Model = .analog
        /// 発振器(analog)。detuneCents と同じ数
        var waves: [Wave] = [.saw]
        var detuneCents: [Double] = [0]
        /// 1 本目を 1 オクターブ下にする(ベースのサブ)
        var subOctave = false
        var attack: Double = 0.01
        var decay: Double = 0.3
        var sustain: Float = 0.5
        var release: Double = 0.2
        /// フィルター(Hz)。cutoffEnv は倍率(1 = エンベロープで 2 倍まで開く)、filterDecay 秒で閉じる
        var cutoff: Double = 3000
        var cutoffEnv: Double = 0
        var filterDecay: Double = 0.3
        var resonance: Double = 0.7
        /// フィルターをゆっくり揺らす(Hz、深さ=倍率)
        var filterLFORate: Double = 0
        var filterLFODepth: Double = 0
        var vibratoRate: Double = 5
        var vibratoDepth: Double = 0
        /// ビブラートが始まるまでの秒
        var vibratoDelay: Double = 0.3
        /// FM: 変調比と深さ、深さが減る秒
        var fmRatio: Double = 1
        var fmIndex: Double = 2
        var fmIndexDecay: Double = 0.5
        /// 高い音ほど減衰を短くする(1 オクターブごとの倍率)
        var keyTracking: Double = 1
        /// カープラス: 弦の減衰(0.99〜0.9995)と明るさ(0〜1)
        var stringDamping: Double = 0.996
        var stringBrightness: Double = 0.6
        /// サチュレーション(0 = 無し)
        var drive: Float = 0
        var gain: Float = 0.2
        var sendLevel: Float = 0.2
    }

    /// 状態変数フィルター(TPT 型)
    struct SVF {
        var ic1: Float = 0
        var ic2: Float = 0
        var g: Float = 0
        var k: Float = 1
        var a1: Float = 0
        var a2: Float = 0
        var a3: Float = 0

        mutating func set(cutoff: Double, q: Double) {
            let f = min(max(cutoff, 30), BGMGenerator.sampleRate * 0.45)
            g = Float(tan(Double.pi * f / BGMGenerator.sampleRate))
            k = Float(1 / max(q, 0.3))
            a1 = 1 / (1 + g * (g + k))
            a2 = g * a1
            a3 = g * a2
        }

        @inline(__always)
        mutating func lowpass(_ x: Float) -> Float {
            let v3 = x - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return v2
        }
    }

    /// 1 音を鳴らす(start/length はフレーム)
    static func play(midi: Int, start: Int, length: Int, velocity: Float, pan: Float,
                     patch: Patch, target: Target, rng: inout Random) {
        guard start >= 0, start < target.bus.count, length > 0 else { return }
        let sr = sampleRate
        let freq = 440 * pow(2, Double(midi - 69) / 12)
        // 高い音ほど短く
        let track = pow(patch.keyTracking, Double(midi - 60) / 12)
        let decaySec = max(patch.decay * track, 0.01)
        let releaseSec = max(patch.release, 0.01)
        let attackFrames = max(1, Int(patch.attack * sr))
        let noteFrames = length
        let total = min(noteFrames + Int(releaseSec * sr * 1.5), target.bus.count - start)
        guard total > 0 else { return }
        let decayCoef = Float(exp(-1 / (decaySec * sr)))
        let releaseCoef = Float(exp(-3 / (releaseSec * sr)))
        let filterCoef = Float(exp(-1 / (max(patch.filterDecay, 0.005) * sr)))
        let gainL = patch.gain * velocity * min(1, 1 - pan)
        let gainR = patch.gain * velocity * min(1, 1 + pan)
        let sendLevel = target.sendLevel * patch.sendLevel
        let L = target.bus.l + start
        let R = target.bus.r + start
        let S = target.send.p + start
        let drive = patch.drive

        switch patch.model {
        case .analog:
            playAnalog(freq: freq, total: total, noteFrames: noteFrames, attackFrames: attackFrames,
                       decayCoef: decayCoef, releaseCoef: releaseCoef, filterCoef: filterCoef,
                       patch: patch, L: L, R: R, S: S, gainL: gainL, gainR: gainR, send: sendLevel, drive: drive, rng: &rng)
        case .fmPiano:
            playFMPiano(freq: freq, midi: midi, total: total, noteFrames: noteFrames,
                        decayCoef: decayCoef, releaseCoef: releaseCoef, patch: patch,
                        L: L, R: R, S: S, gainL: gainL, gainR: gainR, send: sendLevel, velocity: velocity, rng: &rng)
        case .karplus:
            playKarplus(freq: freq, total: total, noteFrames: noteFrames, releaseCoef: releaseCoef, patch: patch,
                        L: L, R: R, S: S, gainL: gainL, gainR: gainR, send: sendLevel, velocity: velocity, rng: &rng)
        case .fmBell:
            playFMBell(freq: freq, total: total, noteFrames: noteFrames, decayCoef: decayCoef, releaseCoef: releaseCoef,
                       patch: patch, L: L, R: R, S: S, gainL: gainL, gainR: gainR, send: sendLevel, rng: &rng)
        }
    }

    /// 減算シンセ: PolyBLEP 発振器 × 2〜3(セント単位でずらす、開始位相ランダム)→ SVF ローパス(専用エンベロープ+LFO)→ ADSR
    private static func playAnalog(freq: Double, total: Int, noteFrames: Int, attackFrames: Int,
                                   decayCoef: Float, releaseCoef: Float, filterCoef: Float, patch: Patch,
                                   L: UnsafeMutablePointer<Float>, R: UnsafeMutablePointer<Float>, S: UnsafeMutablePointer<Float>,
                                   gainL: Float, gainR: Float, send: Float, drive: Float, rng: inout Random) {
        let sr = sampleRate
        let oscCount = min(patch.waves.count, 3)
        var phases = [Double](repeating: 0, count: 3)
        var incs = [Double](repeating: 0, count: 3)
        for i in 0..<oscCount {
            phases[i] = rng.unit()
            var f = freq * pow(2, patch.detuneCents[min(i, patch.detuneCents.count - 1)] / 1200)
            if i == 0, patch.subOctave { f *= 0.5 }
            incs[i] = f / sr
        }
        let oscGain: Float = 1 / Float(oscCount)
        var filter = SVF()
        var filterEnv: Float = 1
        var amp: Float = 0
        var decayState: Float = 1
        var vibPhase = 0.0
        let vibInc = patch.vibratoRate / sr
        let vibDelayFrames = Int(patch.vibratoDelay * sr)
        var lfoPhase = rng.unit()
        let lfoInc = patch.filterLFORate / sr
        let sustain = patch.sustain
        let w0 = patch.waves[0]
        let w1 = oscCount > 1 ? patch.waves[1] : .sine
        let w2 = oscCount > 2 ? patch.waves[2] : .sine
        var p0 = phases[0], p1 = phases[1], p2 = phases[2]
        let i0 = incs[0], i1 = incs[1], i2 = incs[2]

        sineTable.withUnsafeBufferPointer { tbl in
            let T = tbl.baseAddress!
            func osc(_ w: Wave, _ p: Double, _ dt: Double) -> Float {
                switch w {
                case .sine: return T[Int(p * 4096) & tableMask]
                case .triangle: return Float(p < 0.5 ? (p * 4 - 1) : (3 - p * 4))
                case .saw: return Float(2 * p - 1) - polyBlep(p, dt)
                case .square:
                    var v: Float = p < 0.5 ? 1 : -1
                    v += polyBlep(p, dt)
                    v -= polyBlep((p + 0.5).truncatingRemainder(dividingBy: 1), dt)
                    return v
                }
            }
            for i in 0..<total {
                // 音量エンベロープ
                if i < noteFrames {
                    if i < attackFrames {
                        amp = Float(i) / Float(attackFrames)
                    } else {
                        decayState *= decayCoef
                        amp = sustain + (1 - sustain) * decayState
                    }
                } else {
                    amp *= releaseCoef
                    if amp < 0.0003 { break }
                }
                // フィルター(32 サンプルごとに係数を更新)
                if i & 31 == 0 {
                    var cutoff = patch.cutoff * (1 + patch.cutoffEnv * Double(filterEnv))
                    if lfoInc > 0 {
                        cutoff *= 1 + patch.filterLFODepth * Double(T[Int(lfoPhase * 4096) & tableMask])
                        lfoPhase += lfoInc * 32
                        wrap(&lfoPhase)
                    }
                    filter.set(cutoff: cutoff, q: patch.resonance)
                }
                filterEnv *= filterCoef
                // ビブラート
                var vib = 1.0
                if patch.vibratoDepth > 0, i > vibDelayFrames {
                    let depth = min(1, Double(i - vibDelayFrames) / (0.5 * sr)) * patch.vibratoDepth
                    vib = 1 + depth * Double(T[Int(vibPhase * 4096) & tableMask])
                    vibPhase += vibInc
                    wrap(&vibPhase)
                }
                var x = osc(w0, p0, i0)
                p0 += i0 * vib
                wrap(&p0)
                if oscCount > 1 {
                    x += osc(w1, p1, i1)
                    p1 += i1 * vib
                    wrap(&p1)
                }
                if oscCount > 2 {
                    x += osc(w2, p2, i2)
                    p2 += i2 * vib
                    wrap(&p2)
                }
                x *= oscGain
                x = filter.lowpass(x)
                if drive > 0 {
                    // やわらかいサチュレーション
                    let d = x * drive
                    x = (d - d * d * d / 3) / drive
                    if x > 0.9 { x = 0.9 } else if x < -0.9 { x = -0.9 }
                }
                let y = x * amp
                L[i] += y * gainL
                R[i] += y * gainR
                S[i] += y * send
            }
        }
    }

    /// FM ピアノ: 正弦波キャリア 2 本(少しずらして非整数倍音)+ 比 1 と 3.01 の変調(打鍵で明るく、すぐ落ち着く)+ ハンマーのノイズ。高い音ほど短く減衰
    private static func playFMPiano(freq: Double, midi: Int, total: Int, noteFrames: Int,
                                    decayCoef: Float, releaseCoef: Float, patch: Patch,
                                    L: UnsafeMutablePointer<Float>, R: UnsafeMutablePointer<Float>, S: UnsafeMutablePointer<Float>,
                                    gainL: Float, gainR: Float, send: Float, velocity: Float, rng: inout Random) {
        let sr = sampleRate
        let inc = freq / sr
        var c1 = rng.unit(), c2 = rng.unit(), m1 = 0.0, m2 = 0.0
        let stretch = 1 + 0.0007 * Double(max(midi - 48, 0)) / 12       // ピアノの倍音の伸び
        let inc2 = inc * 2 * stretch
        let incM1 = inc * patch.fmRatio
        let incM2 = inc * 3.01
        var index = Float(patch.fmIndex) * (0.6 + 0.6 * velocity)
        let indexCoef = Float(exp(-1 / (patch.fmIndexDecay * sr)))
        var amp: Float = 1
        var decayState: Float = 1
        var hammer: Float = 1
        let hammerCoef = Float(exp(-1 / (0.004 * sr)))
        var hammerLP: Float = 0
        let twoPi = Float(2 * Double.pi)
        sineTable.withUnsafeBufferPointer { tbl in
            let T = tbl.baseAddress!
            for i in 0..<total {
                if i < noteFrames {
                    decayState *= decayCoef
                    amp = decayState
                } else {
                    amp *= releaseCoef
                    if amp < 0.0003 { break }
                }
                index *= indexCoef
                // 変調波
                let mod1 = T[Int(m1 * 4096) & tableMask] * index
                let mod2 = T[Int(m2 * 4096) & tableMask] * index * 0.35
                m1 += incM1
                wrap(&m1)
                m2 += incM2
                wrap(&m2)
                // キャリア(位相変調)
                var ph1 = c1 + Double(mod1 / twoPi)
                ph1 -= floor(ph1)
                var ph2 = c2 + Double(mod2 / twoPi)
                ph2 -= floor(ph2)
                var x = T[Int(ph1 * 4096) & tableMask] + 0.3 * T[Int(ph2 * 4096) & tableMask]
                c1 += inc
                wrap(&c1)
                c2 += inc2
                wrap(&c2)
                // ハンマーのノイズ(最初の数ミリ秒)
                if hammer > 0.001 {
                    let n = rng.noise()
                    hammerLP += 0.3 * (n - hammerLP)
                    x += hammerLP * hammer * 0.6
                    hammer *= hammerCoef
                }
                let y = x * amp * 0.7
                L[i] += y * gainL
                R[i] += y * gainR
                S[i] += y * send
            }
        }
    }

    /// カープラス・ストロング: ノイズで弾いた弦を遅延ループ+ローパスで減衰させる(ギター・ピチカート)
    private static func playKarplus(freq: Double, total: Int, noteFrames: Int, releaseCoef: Float, patch: Patch,
                                    L: UnsafeMutablePointer<Float>, R: UnsafeMutablePointer<Float>, S: UnsafeMutablePointer<Float>,
                                    gainL: Float, gainR: Float, send: Float, velocity: Float, rng: inout Random) {
        let sr = sampleRate
        let period = max(2, Int((sr / freq).rounded()))
        var line = [Float](repeating: 0, count: period)
        // 弾く位置: ノイズを少しローパスしてから入れる(明るさ)
        var lp: Float = 0
        let bright = Float(0.2 + 0.75 * patch.stringBrightness) * (0.7 + 0.3 * velocity)
        for i in 0..<period {
            let n = rng.noise()
            lp += bright * (n - lp)
            line[i] = lp
        }
        let damping = Float(patch.stringDamping)
        var idx = 0
        var prev: Float = 0
        var amp: Float = 1
        var dc: Float = 0
        line.withUnsafeMutableBufferPointer { D in
            for i in 0..<total {
                let x = D[idx]
                // ループのフィルター(隣と平均 = ローパス)× 減衰
                let next = (x + prev) * 0.5 * damping
                prev = x
                D[idx] = next
                idx += 1
                if idx == period { idx = 0 }
                if i >= noteFrames {
                    amp *= releaseCoef
                    if amp < 0.0003 { break }
                }
                // 直流を抜く
                dc += 0.002 * (x - dc)
                let y = (x - dc) * amp
                L[i] += y * gainL
                R[i] += y * gainR
                S[i] += y * send
            }
        }
    }

    /// FM ベル・マレット: キャリア+非整数比(3.5 など)の変調で金属的な倍音。深さが減って丸くなる
    private static func playFMBell(freq: Double, total: Int, noteFrames: Int, decayCoef: Float, releaseCoef: Float, patch: Patch,
                                   L: UnsafeMutablePointer<Float>, R: UnsafeMutablePointer<Float>, S: UnsafeMutablePointer<Float>,
                                   gainL: Float, gainR: Float, send: Float, rng: inout Random) {
        let sr = sampleRate
        let inc = freq / sr
        var c = rng.unit(), m = 0.0, c2 = rng.unit()
        let incM = inc * patch.fmRatio
        let inc2 = inc * 4.0 * 1.003
        var index = Float(patch.fmIndex)
        let indexCoef = Float(exp(-1 / (patch.fmIndexDecay * sr)))
        var amp: Float = 0
        var decayState: Float = 1
        let attackFrames = max(1, Int(patch.attack * sr))
        let twoPi = Float(2 * Double.pi)
        sineTable.withUnsafeBufferPointer { tbl in
            let T = tbl.baseAddress!
            for i in 0..<total {
                if i < noteFrames {
                    if i < attackFrames {
                        amp = Float(i) / Float(attackFrames)
                    } else {
                        decayState *= decayCoef
                        amp = decayState
                    }
                } else {
                    amp *= releaseCoef
                    if amp < 0.0003 { break }
                }
                index *= indexCoef
                let mod = T[Int(m * 4096) & tableMask] * index
                m += incM
                wrap(&m)
                var ph = c + Double(mod / twoPi)
                ph -= floor(ph)
                var x = T[Int(ph * 4096) & tableMask]
                // 高い倍音は早く消える
                x += 0.25 * T[Int(c2 * 4096) & tableMask] * amp * amp
                c += inc
                wrap(&c)
                c2 += inc2
                wrap(&c2)
                let y = x * amp * 0.8
                L[i] += y * gainL
                R[i] += y * gainR
                S[i] += y * send
            }
        }
    }

    // MARK: - 楽器ごとのパッチ

    static func padPatch(preset: BGMPreset) -> Patch {
        var p = Patch()
        if preset.organ {
            // オルガン: 矩形波+正弦波+三角波を重ね、減衰せず、軽いビブラート
            p.waves = [.square, .sine, .triangle]
            p.detuneCents = [0, 1200, -1200]
            p.attack = 0.05
            p.decay = 1
            p.sustain = 1
            p.release = 0.5
            p.cutoff = 2200
            p.resonance = 0.5
            p.vibratoDepth = 0.002
            p.vibratoRate = 5.5
            p.gain = 0.1
            p.sendLevel = 0.45
        } else if preset.widePad {
            // 弦楽合奏風: のこぎり波 3 本(±9 セント)+遅いアタック+遅れて始まるビブラート
            p.waves = [.saw, .saw, .saw]
            p.detuneCents = [-9, 0, 9]
            p.attack = 0.9
            p.decay = 2
            p.sustain = 0.9
            p.release = 1.4
            p.cutoff = 1500
            p.cutoffEnv = 0.6
            p.filterDecay = 1.5
            p.resonance = 0.6
            p.filterLFORate = 0.11
            p.filterLFODepth = 0.25
            p.vibratoDepth = 0.0035
            p.vibratoRate = 4.8
            p.vibratoDelay = 0.6
            p.gain = 0.075
            p.sendLevel = 0.5
        } else {
            // スーパーソウ: のこぎり波 3 本(±12 セント)+ゆっくり動くフィルター(コーラスはバスで)
            p.waves = [.saw, .saw, .saw]
            p.detuneCents = [-12, 0, 12]
            p.attack = 0.3
            p.decay = 1
            p.sustain = 0.85
            p.release = 0.7
            p.cutoff = 1300
            p.cutoffEnv = 0.8
            p.filterDecay = 0.8
            p.resonance = 0.8
            p.filterLFORate = 0.17
            p.filterLFODepth = 0.3
            p.gain = 0.07
            p.sendLevel = 0.4
        }
        if preset.detuned {
            p.detuneCents = [-28, 0, 24]
            p.cutoff = 700
            p.vibratoDepth = 0.006
            p.vibratoRate = 0.3
            p.vibratoDelay = 0
            p.sendLevel = 0.6
        }
        return p
    }

    static func keysPatch(tone: BGMPluckTone) -> Patch {
        var p = Patch()
        switch tone {
        case .piano:
            p.model = .fmPiano
            p.decay = 2.4
            p.keyTracking = 0.62
            p.release = 0.35
            p.fmRatio = 1
            p.fmIndex = 1.6
            p.fmIndexDecay = 0.25
            p.gain = 0.2
            p.sendLevel = 0.3
        case .pluck:
            p.model = .karplus
            p.stringDamping = 0.9965
            p.stringBrightness = 0.55
            p.release = 0.15
            p.gain = 0.2
            p.sendLevel = 0.25
        case .pizzicato:
            p.model = .karplus
            p.stringDamping = 0.985
            p.stringBrightness = 0.8
            p.release = 0.05
            p.gain = 0.24
            p.sendLevel = 0.2
        case .bell:
            p.model = .fmBell
            p.attack = 0.002
            p.decay = 1.6
            p.keyTracking = 0.7
            p.release = 0.5
            p.fmRatio = 3.5
            p.fmIndex = 1.4
            p.fmIndexDecay = 0.5
            p.gain = 0.15
            p.sendLevel = 0.45
        case .marimba:
            p.model = .fmBell
            p.attack = 0.001
            p.decay = 0.3
            p.keyTracking = 0.7
            p.release = 0.1
            p.fmRatio = 4
            p.fmIndex = 0.9
            p.fmIndexDecay = 0.06
            p.gain = 0.22
            p.sendLevel = 0.25
        case .brass:
            p.model = .analog
            p.waves = [.saw, .saw, .square]
            p.detuneCents = [-6, 5, 0]
            p.attack = 0.05
            p.decay = 0.4
            p.sustain = 0.65
            p.release = 0.12
            p.cutoff = 900
            p.cutoffEnv = 2.5
            p.filterDecay = 0.12
            p.resonance = 1.1
            p.vibratoDepth = 0.003
            p.vibratoRate = 5
            p.vibratoDelay = 0.25
            p.drive = 1.2
            p.gain = 0.12
            p.sendLevel = 0.3
        }
        return p
    }

    static func bassPatch(preset: BGMPreset) -> Patch {
        // サブ(正弦波、1 オクターブ下)+中域(のこぎり/矩形)+サチュレーション
        var p = Patch()
        p.waves = [.sine, preset.drums == .house ? .saw : .square, .triangle]
        p.detuneCents = [0, 0, 4]
        p.subOctave = true
        p.attack = 0.004
        p.decay = preset.drums == .house ? 0.3 : 0.6
        p.sustain = preset.drums == .house ? 0.25 : 0.45
        p.release = 0.08
        p.cutoff = preset.drums == .house ? 380 : 260
        p.cutoffEnv = 2.0
        p.filterDecay = 0.1
        p.resonance = 0.9
        p.drive = 1.6
        p.gain = 0.3
        p.sendLevel = 0
        return p
    }

    static func arpPatch(tone: BGMPluckTone) -> Patch {
        var p = keysPatch(tone: tone == .brass ? .pluck : tone)
        if tone == .piano {
            // ピアノ曲のアルペジオは軽いプラック
            p = keysPatch(tone: .pluck)
            p.stringBrightness = 0.45
        }
        p.gain *= 0.6
        p.sendLevel += 0.1
        return p
    }

    static func melodyPatch(tone: BGMPluckTone) -> Patch {
        var p = keysPatch(tone: tone == .pizzicato ? .pluck : tone)
        p.gain *= 0.8
        p.sendLevel += 0.1
        return p
    }

    static func sparklePatch(horror: Bool) -> Patch {
        var p = keysPatch(tone: .bell)
        p.decay = horror ? 2.2 : 1.0
        p.fmRatio = horror ? 5.1 : 3.5
        p.gain = 0.06
        p.sendLevel = 0.7
        return p
    }

    // MARK: - ドラム(1 回だけ作って貼り付ける)

    struct DrumKit {
        var kick: [Float] = []
        var snare: [Float] = []
        var hat: [Float] = []
        var openHat: [Float] = []
        var clap: [Float] = []
        var bells: [Float] = []
        var heartbeat: [Float] = []
        var shaker: [Float] = []
    }

    static func makeDrums(preset: BGMPreset, rng: inout Random) -> DrumKit {
        var kit = DrumKit()
        let sr = sampleRate
        let soft = preset.drums == .soft || preset.drums == .lofi
        let lofi = preset.drums == .lofi

        // キック: 正弦波スイープ(160→45Hz)+クリック+サチュレーション
        do {
            let n = Int(sr * 0.45)
            var out = [Float](repeating: 0, count: n)
            var phase = 0.0
            let startF = soft ? 110.0 : 170.0
            let endF = preset.drums == .house ? 42.0 : 50.0
            var clickLP: Float = 0
            for i in 0..<n {
                let t = Double(i) / sr
                let f = endF + (startF - endF) * exp(-t * 32)
                phase += f / sr
                let env = Float(exp(-t * (soft ? 11 : 7.5)))
                let n0 = rng.noise()
                clickLP += 0.5 * (n0 - clickLP)
                let click = clickLP * Float(exp(-t * 350)) * (soft ? 0.25 : 0.5)
                var x = Float(sin(phase * 2 * .pi)) * env * 1.4 + click
                x = tanh(x)                       // サチュレーション
                out[i] = x
            }
            kit.kick = out
        }
        // スネア: 2 つの音(185/330Hz)+ハイパスしたノイズ+部屋鳴り(短いノイズの尾)
        do {
            let n = Int(sr * (lofi ? 0.25 : 0.32))
            var out = [Float](repeating: 0, count: n)
            var lp1: Float = 0, lp2: Float = 0
            var p1 = 0.0, p2 = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                let noise = rng.noise()
                lp1 += 0.22 * (noise - lp1)
                let hp = noise - lp1
                lp2 += 0.08 * (noise - lp2)
                let room = (noise - lp2) * Float(exp(-t * 9)) * 0.12
                p1 += 185 / sr
                p2 += 330 / sr
                let tone = (Float(sin(p1 * 2 * .pi)) * 0.7 + Float(sin(p2 * 2 * .pi)) * 0.35) * Float(exp(-t * 32))
                let env = Float(exp(-t * (soft ? 24 : 15)))
                var x = hp * (soft ? 0.6 : 0.85) * env + tone * (soft ? 0.5 : 0.8) + room
                if lofi { x = tanh(x * 1.5) * 0.8 }
                out[i] = x
            }
            kit.snare = out
        }
        // ハイハット: 808 風に矩形波 6 本(非整数比)を重ねてハイパス
        func hat(seconds: Double, decayRate: Double) -> [Float] {
            let n = Int(sr * seconds)
            var out = [Float](repeating: 0, count: n)
            let ratios: [Double] = [1.0, 1.4471, 1.6170, 1.9265, 2.5028, 2.6637]
            let base = 540.0
            var phases = [Double](repeating: 0, count: 6)
            var lp1: Float = 0, lp2: Float = 0, lp3: Float = 0
            for i in 0..<n {
                let t = Double(i) / sr
                var x: Float = 0
                for k in 0..<6 {
                    phases[k] += base * ratios[k] / sr
                    if phases[k] >= 1 { phases[k] -= 1 }
                    x += phases[k] < 0.5 ? 1 : -1
                }
                x /= 6
                // 3 段のハイパス(約 7kHz)
                lp1 += 0.62 * (x - lp1)
                lp2 += 0.62 * (lp1 - lp2)
                lp3 += 0.62 * (lp2 - lp3)
                let hp = x - lp3
                out[i] = hp * Float(exp(-t * decayRate)) * (lofi ? 0.5 : 0.7)
            }
            return out
        }
        kit.hat = hat(seconds: 0.08, decayRate: 70)
        kit.openHat = hat(seconds: 0.35, decayRate: 11)
        // シェイカー(soft 用): 短いノイズ
        do {
            let n = Int(sr * 0.07)
            var out = [Float](repeating: 0, count: n)
            var lp1: Float = 0, lp2: Float = 0
            for i in 0..<n {
                let t = Double(i) / sr
                let noise = rng.noise()
                lp1 += 0.5 * (noise - lp1)
                lp2 += 0.5 * (lp1 - lp2)
                out[i] = (noise - lp2) * Float(exp(-t * 90)) * 0.4
            }
            kit.shaker = out
        }
        // 手拍子: 10ms ずつずらした 3 回のノイズ+尾
        do {
            let n = Int(sr * 0.3)
            var out = [Float](repeating: 0, count: n)
            var lp: Float = 0, lp2: Float = 0
            for i in 0..<n {
                let t = Double(i) / sr
                let noise = rng.noise()
                lp += 0.35 * (noise - lp)
                lp2 += 0.05 * (noise - lp2)
                let bp = lp - lp2
                var env = Float(exp(-(t - 0.03) * 22))
                if t < 0.03 { env = Float(exp(-(t.truncatingRemainder(dividingBy: 0.01)) * 350)) }
                out[i] = bp * env * 0.9
            }
            kit.clap = out
        }
        // 鈴(スレイベル): 高いノイズ+高い正弦波のきらめき+揺れ
        do {
            let n = Int(sr * 0.2)
            var out = [Float](repeating: 0, count: n)
            var lp1: Float = 0, lp2: Float = 0
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                let noise = rng.noise()
                lp1 += 0.75 * (noise - lp1)
                lp2 += 0.75 * (lp1 - lp2)
                let hp = noise - lp2
                phase += 7600 / sr
                let ring = Float(sin(phase * 2 * .pi)) * 0.3
                let shake = Float(0.6 + 0.4 * sin(t * 2 * .pi * 60))
                out[i] = (hp * 0.5 + ring) * Float(exp(-t * 20)) * shake
            }
            kit.bells = out
        }
        // 心臓の鼓動: 低いキックを 2 回(ドッ・クン)
        do {
            let n = Int(sr * 0.6)
            var out = [Float](repeating: 0, count: n)
            func thump(at offset: Double, gain: Float) {
                var phase = 0.0
                let startI = Int(offset * sr)
                for i in startI..<n {
                    let t = Double(i - startI) / sr
                    let f = 45 + 50 * exp(-t * 30)
                    phase += f / sr
                    out[i] += tanh(Float(sin(phase * 2 * .pi)) * Float(exp(-t * 12)) * gain * 1.3)
                }
            }
            thump(at: 0, gain: 0.9)
            thump(at: 0.17, gain: 0.6)
            kit.heartbeat = out
        }
        return kit
    }

    /// 作っておいたドラムの波形を貼り付ける(send にも少し送る)
    static func hit(_ sample: [Float], at start: Int, gain: Float, pan: Float, send: Float, master: Bus, sendBus: Mono) {
        guard start >= 0, start < master.count else { return }
        let n = min(sample.count, master.count - start)
        guard n > 0 else { return }
        let gL = gain * min(1, 1 - pan)
        let gR = gain * min(1, 1 + pan)
        let L = master.l + start
        let R = master.r + start
        let S = sendBus.p + start
        sample.withUnsafeBufferPointer { P in
            for i in 0..<n {
                let x = P[i]
                L[i] += x * gL
                R[i] += x * gR
                S[i] += x * send
            }
        }
    }

    // MARK: - リズム

    /// 小節内の 16 分音符の位置(0〜15)ごとの叩く場所
    struct DrumPattern {
        var kick: [Int] = []
        var snare: [Int] = []
        var hat: [Int] = []
        var openHat: [Int] = []
        var kickGain: Float = 0.9
        var snareGain: Float = 0.6
        var hatGain: Float = 0.25
    }

    /// B セクションでは少しにぎやかにする(variation = true)
    static func drumPattern(for preset: BGMPreset, variation: Bool) -> DrumPattern {
        let p = (preset.drumPattern + (variation ? 1 : 0)) & 3
        var d = DrumPattern()
        let eighths = [0, 2, 4, 6, 8, 10, 12, 14]
        let sixteenths = Array(0..<16)
        switch preset.drums {
        case .none:
            break
        case .heartbeat:
            d.kick = [0, 4, 8, 12]
            d.kickGain = 0.7
        case .soft:
            d.kick = [[0, 8], [0, 10], [0, 6, 8], [0, 8, 14]][p]
            d.snare = [4, 12]
            d.hat = variation ? sixteenths : eighths
            d.kickGain = 0.5
            d.snareGain = 0.22
            d.hatGain = 0.16
        case .pop:
            d.kick = [[0, 8], [0, 6, 8, 10], [0, 8, 11], [0, 7, 8]][p]
            d.snare = [4, 12]
            d.hat = eighths
            d.openHat = (p == 1 || variation) ? [14] : []
            d.kickGain = 0.95
            d.snareGain = 0.6
            d.hatGain = 0.2
        case .lofi:
            d.kick = [[0, 7, 10], [0, 10], [0, 6, 8, 11], [0, 9]][p]
            d.snare = [4, 12]
            d.hat = p == 2 ? sixteenths : eighths
            d.kickGain = 0.75
            d.snareGain = 0.45
            d.hatGain = p == 2 ? 0.1 : 0.15
        case .house:
            d.kick = [0, 4, 8, 12]
            d.snare = [4, 12]
            d.openHat = [2, 6, 10, 14]
            d.hat = (p == 1 || variation) ? sixteenths : []
            d.kickGain = 1.0
            d.snareGain = 0.4
            d.hatGain = 0.11
        case .march:
            d.kick = [0, 8]
            d.snare = variation ? sixteenths : eighths
            d.kickGain = 0.7
            d.snareGain = 0.35
        }
        return d
    }

    /// 伴奏(弾く音)を鳴らす 16 分の位置
    static func compSteps(for preset: BGMPreset) -> [Int] {
        if preset.beatsPerBar == 3 {
            return preset.drumPattern == 0 ? [0, 8] : [0, 4, 8]
        }
        switch preset.drumPattern & 3 {
        case 0: return [0, 8]
        case 1: return [0, 4, 8, 12]
        case 2: return [0, 3, 6, 8, 11, 14]
        default: return [0, 6, 10, 12]
        }
    }

    /// ベースの位置と、そこで弾く音(0 = ルート、1 = 5 度、2 = ルートのオクターブ上)
    static func bassSteps(for preset: BGMPreset) -> [(step: Int, tone: Int)] {
        if preset.beatsPerBar == 3 {
            return [(0, 0), (4, 1), (8, 1)]
        }
        if preset.pluckTone == .pizzicato {
            return [(0, 0), (4, 1), (6, 2), (8, 0), (12, 1), (14, 2)]
        }
        switch preset.drums {
        case .none, .soft, .heartbeat: return [(0, 0), (8, 1)]
        case .pop: return [(0, 0), (6, 1), (8, 0), (14, 2)]
        case .lofi: return [(0, 0), (7, 0), (10, 1)]
        case .house: return [(0, 0), (2, 2), (4, 0), (6, 2), (8, 0), (10, 2), (12, 0), (14, 2)]
        case .march: return [(0, 0), (4, 1), (8, 0), (12, 1)]
        }
    }

    // MARK: - コード

    /// 1 小節のコード
    struct BarChord {
        /// コードの音(ピッチクラス 0〜11、ルートが先頭)
        var classes: [Int]
        /// パッド・伴奏の声部(MIDI、声部連結済み)
        var voicing: [Int]
        var bassRoot: Int
        var bassFifth: Int
        /// アルペジオ用(72〜84)
        var arp: [Int]
    }

    /// 度数からコードの音(ピッチクラス)を作る
    static func chordClasses(degree: Int, key: Int, scale: BGMScale, sevenths: Bool) -> [Int] {
        let iv = scale.intervals
        let d = max(1, min(7, degree)) - 1
        var classes: [Int] = []
        for k in 0..<(sevenths ? 4 : 3) {
            let idx = d + 2 * k
            classes.append((key + iv[idx % 7] + 12 * (idx / 7)) % 12)
        }
        return classes
    }

    /// 声部連結: 前の声部にいちばん近い転回形を選ぶ(57〜76 の範囲)
    static func voiceLead(classes: [Int], previous: [Int]?) -> [Int] {
        let low = 57, high = 76
        // 候補: 各音をオクターブ違いで並べ、下から順に積む転回形
        var candidates: [[Int]] = []
        let n = classes.count
        for inversion in 0..<n {
            var notes: [Int] = []
            var cursor = low
            for k in 0..<n {
                let pc = classes[(inversion + k) % n]
                var m = cursor + ((pc - cursor) % 12 + 12) % 12
                if k > 0, m == notes.last { m += 12 }
                notes.append(m)
                cursor = m + 1
            }
            for shift in [0, 12] where (notes.last ?? 0) + shift <= high {
                candidates.append(notes.map { $0 + shift })
            }
        }
        if candidates.isEmpty { return classes.map { 60 + $0 }.sorted() }
        guard let previous, !previous.isEmpty else {
            // 最初は真ん中あたり(平均が 66 に近いもの)
            return candidates.min { abs($0.reduce(0, +) / $0.count - 66) < abs($1.reduce(0, +) / $1.count - 66) } ?? candidates[0]
        }
        func distance(_ a: [Int]) -> Int {
            let m = min(a.count, previous.count)
            var sum = 0
            for i in 0..<m { sum += abs(a[i] - previous[i]) }
            // 真ん中から離れすぎるのも避ける
            sum += abs(a.reduce(0, +) / a.count - 66) / 2
            return sum
        }
        return candidates.min { distance($0) < distance($1) } ?? candidates[0]
    }

    static func makeChord(degree: Int, key: Int, scale: BGMScale, sevenths: Bool, previous: [Int]?) -> BarChord {
        let classes = chordClasses(degree: degree, key: key, scale: scale, sevenths: sevenths)
        let voicing = voiceLead(classes: classes, previous: previous)
        let iv = scale.intervals
        let d = max(1, min(7, degree)) - 1
        let bassRoot = 36 + classes[0]
        let fifthIdx = d + 4
        let fifthClass = (key + iv[fifthIdx % 7] + 12 * (fifthIdx / 7)) % 12
        var bassFifth = 36 + fifthClass
        if bassFifth < bassRoot { bassFifth += 12 }
        if bassFifth - bassRoot > 7 { bassFifth -= 12 }
        // アルペジオ: コードの音を 72〜83 に(5 音階なら近い音に寄せる)
        let melodic = scale.melodicIntervals
        var arp: [Int] = []
        for c in classes {
            var rel = (c - key + 12) % 12
            if !melodic.contains(rel) {
                rel = melodic.min { abs($0 - rel) < abs($1 - rel) } ?? rel
            }
            let m = 72 + (key + rel) % 12
            if !arp.contains(m) { arp.append(m) }
        }
        arp.sort()
        if let first = arp.first { arp.append(first + 12) }
        return BarChord(classes: classes, voicing: voicing, bassRoot: bassRoot, bassFifth: bassFifth, arp: arp)
    }

    // MARK: - モチーフ(旋律)

    struct MotifNote {
        var step: Int     // 2 小節内の 16 分の位置
        var length: Int   // 16 分の数
        var degree: Int   // 音階上の番号(melodicPool の添字)
    }

    /// 2 小節のモチーフを作る(リズムは型から、音は音階上を順次進行+ときどき跳躍)
    static func makeMotif(preset: BGMPreset, stepsPerBar: Int, rng: inout Random) -> [MotifNote] {
        let rhythms4: [[(Int, Int)]] = [
            [(0, 4), (4, 2), (6, 2), (8, 4), (12, 4), (16, 6), (22, 2), (24, 8)],
            [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2), (12, 4), (16, 4), (20, 4), (24, 8)],
            [(0, 3), (3, 3), (6, 2), (8, 4), (12, 4), (16, 3), (19, 3), (22, 2), (24, 4), (28, 4)],
            [(2, 2), (4, 4), (8, 2), (10, 2), (12, 4), (18, 2), (20, 4), (24, 6)]
        ]
        let rhythms3: [[(Int, Int)]] = [
            [(0, 4), (4, 4), (8, 4), (12, 8), (20, 4)],
            [(0, 6), (6, 2), (8, 4), (12, 4), (16, 4), (20, 4)]
        ]
        let rhythm = stepsPerBar == 12 ? rhythms3[rng.int(rhythms3.count)] : rhythms4[rng.int(rhythms4.count)]
        let poolCount = preset.scale.melodicIntervals.count * 2    // 2 オクターブ分
        var degree = poolCount / 2 + rng.int(3) - 1
        var direction = rng.chance(0.5) ? 1 : -1
        var notes: [MotifNote] = []
        for (i, r) in rhythm.enumerated() {
            if i > 0 {
                if rng.chance(0.3) { direction = -direction }
                let leap = rng.chance(0.25) ? 2 + rng.int(2) : 1
                degree += direction * leap
                if degree < 2 { degree = 2; direction = 1 }
                if degree > poolCount - 3 { degree = poolCount - 3; direction = -1 }
            }
            notes.append(MotifNote(step: r.0, length: r.1, degree: degree))
        }
        return notes
    }

    // MARK: - 構成

    struct Layers: OptionSet {
        let rawValue: Int
        static let pad = Layers(rawValue: 1)
        static let keys = Layers(rawValue: 2)
        static let bass = Layers(rawValue: 4)
        static let drums = Layers(rawValue: 8)
        static let arp = Layers(rawValue: 16)
        static let melody = Layers(rawValue: 32)
        static let full = Layers(rawValue: 64)     // ドラムのバリエーション・オープンハット・手拍子
    }

    enum Section {
        case intro, a, b, aPrime, outro
    }

    // MARK: - 本体

    /// 曲を合成してマスター(ステレオ)を返す。呼び出し側が free() する
    static func renderMaster(preset: BGMPreset, seconds: Double) -> Bus {
        let sr = sampleRate
        let frames = max(Int(max(seconds, 1) * sr), 1)
        let master = Bus(count: frames)
        let bus = Bus(count: frames)          // パッド → 鍵盤 の順に使い回す
        let send = Mono(count: frames)
        // bus / send は最後に使った直後に free する(長い曲でメモリの山を低くするため。途中で return しないこと)
        var rng = Random(seed: seed(for: preset.id))

        let beatSec = 60 / max(preset.bpm, 30)
        let stepSec = beatSec / 4
        let stepsPerBar = max(preset.beatsPerBar, 2) * 4
        let barSec = stepSec * Double(stepsPerBar)
        let barFrames = Int(barSec * sr)
        let stepFrames = Int(stepSec * sr)
        let totalBars = Int(ceil(seconds / barSec)) + 1
        let progression = preset.progression.isEmpty ? [1] : preset.progression
        let short = seconds < 30
        let introBars = short ? 1 : 2
        let sectionBars = short ? 4 : 8
        let outroBars = short ? 1 : 2

        let drums = makeDrums(preset: preset, rng: &rng)
        let patternA = drumPattern(for: preset, variation: false)
        let patternB = drumPattern(for: preset, variation: true)
        let comp = compSteps(for: preset)
        let bassPlan = bassSteps(for: preset)
        let padP = padPatch(preset: preset)
        let keysP = keysPatch(tone: preset.pluckTone)
        let bassP = bassPatch(preset: preset)
        let arpP = arpPatch(tone: preset.pluckTone)
        let melodyP = melodyPatch(tone: preset.pluckTone)
        let sparkleP = sparklePatch(horror: preset.mood == .horror)
        let arpDivision = preset.bpm < 100 ? 1 : 2          // 1 = 16 分、2 = 8 分
        let swingFrames = preset.swing * stepSec * sr
        let humanFrames = Int(0.008 * sr)

        // タイミング・強さの揺らぎ用の乱数(音色用の rng とは別にして、同じ呼び出しの中で重ならないようにする)
        var humanRNG = Random(seed: seed(for: preset.id) ^ 0x5555_AAAA)
        /// スウィング+人間らしいずれ込み(±8ms)の開始フレーム
        func frame(bar: Int, step: Int, humanize: Bool = true) -> Int {
            var f = Double(bar * barFrames + step * stepFrames)
            if step % 4 == 2 { f += swingFrames * 2 } else if step % 2 == 1 { f += swingFrames }
            if humanize { f += Double(humanRNG.int(humanFrames * 2 + 1) - humanFrames) }
            return max(0, Int(f))
        }
        /// 強さ ±10%
        func velocity(_ base: Float) -> Float {
            base * Float(0.9 + humanRNG.unit() * 0.2)
        }

        // 小節ごとのセクション
        func section(of bar: Int) -> Section {
            if bar < introBars { return .intro }
            if bar >= totalBars - outroBars - 1 { return .outro }
            let block = (bar - introBars) / sectionBars
            switch block % 3 {
            case 0: return .a
            case 1: return .b
            default: return .aPrime
            }
        }
        func layers(for s: Section) -> Layers {
            switch s {
            case .intro: return [.pad, .arp]
            case .a: return [.pad, .keys, .bass, .drums, .arp]
            case .b: return [.pad, .keys, .bass, .drums, .arp, .melody, .full]
            case .aPrime: return [.pad, .keys, .bass, .drums, .melody]
            case .outro: return [.pad, .keys, .bass, .arp]
            }
        }

        // 小節ごとのコード(声部連結。進行を 2 周したら平行長調へ)
        var chords: [BarChord] = []
        chords.reserveCapacity(totalBars)
        var previousVoicing: [Int]? = nil
        for bar in 0..<totalBars {
            var key = preset.key
            var scale = preset.scale
            if preset.liftToMajor, bar >= introBars + progression.count * 2 {
                key = (preset.key + 3) % 12
                scale = .major
            }
            let c = makeChord(degree: progression[(bar - introBars + progression.count * 64) % progression.count],
                              key: key, scale: scale, sevenths: preset.sevenths, previous: previousVoicing)
            previousVoicing = c.voicing
            chords.append(c)
        }
        // 旋律に使える音(2 オクターブ、72〜95)
        func melodicPool(bar: Int) -> [Int] {
            var key = preset.key
            var scale = preset.scale
            if preset.liftToMajor, bar >= introBars + progression.count * 2 {
                key = (preset.key + 3) % 12
                scale = .major
            }
            var pool: [Int] = []
            for octave in [72, 84] {
                for rel in scale.melodicIntervals { pool.append(octave + (key + rel) % 12) }
            }
            return pool.sorted()
        }
        let motif = makeMotif(preset: preset, stepsPerBar: stepsPerBar, rng: &rng)

        // ---------- 1. パッド(コードが変わるまで 1 音で伸ばす)→ バス処理(HPF+コーラス) ----------
        let padTarget = Target(bus: bus, send: send, sendLevel: Float(preset.reverb))
        if preset.pad {
            var bar = 0
            while bar < totalBars {
                var end = bar + 1
                while end < totalBars, chords[end].voicing == chords[bar].voicing, section(of: end) == section(of: bar) { end += 1 }
                let start = bar * barFrames
                let length = (end - bar) * barFrames - Int(0.03 * sr)
                let notes = chords[bar].voicing
                let quiet: Float = section(of: bar) == .intro ? 0.8 : 1
                for (n, midi) in notes.enumerated() {
                    let pan = Float(n) / Float(max(notes.count - 1, 1)) * 0.8 - 0.4
                    play(midi: midi, start: start, length: length, velocity: quiet, pan: pan, patch: padP, target: padTarget, rng: &rng)
                }
                if preset.widePad || preset.organ, let root = notes.first {
                    // 弦楽合奏のチェロ(ルートを 1 オクターブ下)
                    var low = padP
                    low.gain *= 0.7
                    low.cutoff *= 0.7
                    play(midi: root - 12, start: start, length: length, velocity: quiet, pan: 0, patch: low, target: padTarget, rng: &rng)
                }
                if preset.detuned, let top = notes.last {
                    var v = padP
                    v.gain *= 0.4
                    play(midi: top + 1, start: start, length: length, velocity: 1, pan: 0.2, patch: v, target: padTarget, rng: &rng)
                }
                bar = end
            }
        }
        // ドローン(主音を鳴らし続ける)
        if preset.drone {
            var d = Patch()
            d.waves = [.saw, .saw, .sine]
            d.detuneCents = [-7, 7, -1200]
            d.attack = 1.5
            d.decay = 1
            d.sustain = 1
            d.release = 1
            d.cutoff = 240
            d.cutoffEnv = 0
            d.filterLFORate = 0.08
            d.filterLFODepth = 0.5
            d.resonance = 1.2
            d.vibratoDepth = preset.detuned ? 0.004 : 0
            d.vibratoRate = 0.2
            d.vibratoDelay = 0
            d.gain = 0.14
            d.sendLevel = 0.5
            play(midi: 36 + preset.key, start: 0, length: frames - Int(2 * sr), velocity: 1, pan: 0, patch: d, target: padTarget, rng: &rng)
        }
        highpass(bus, cutoff: 110)
        if !preset.organ {
            chorus(bus, rate: preset.widePad ? 0.35 : 0.6, depthMs: preset.widePad ? 5 : 3.5, delayMs: preset.widePad ? 22 : 14, mix: 0.45)
        }
        addBus(bus, to: master)
        bus.clear()

        // ---------- 2. 鍵盤・アルペジオ・旋律・きらめき(1 つのバス) → HPF ----------
        let keysTarget = Target(bus: bus, send: send, sendLevel: Float(preset.reverb))
        var motifVariant = 0
        for bar in 0..<totalBars {
            let ch = chords[bar]
            let sec = section(of: bar)
            let ly = layers(for: sec)

            // 伴奏(コードを少しずらして弾く)
            if preset.pluck, ly.contains(.keys) {
                for (i, step) in comp.enumerated() where step < stepsPerBar {
                    let start = frame(bar: bar, step: step)
                    let nextStep = i + 1 < comp.count ? comp[i + 1] : stepsPerBar
                    var length = (nextStep - step) * stepFrames
                    if preset.pluckTone == .pizzicato { length = min(length, Int(0.12 * sr)) }
                    let base: Float = step == 0 ? 1 : 0.8
                    let notes = ch.voicing
                    for (n, midi) in notes.enumerated() {
                        let pan = Float(n) / Float(max(notes.count - 1, 1)) * 0.5 - 0.25
                        play(midi: midi, start: start + n * Int(0.012 * sr), length: length,
                             velocity: velocity(base * (sec == .aPrime ? 0.9 : 1)), pan: pan, patch: keysP, target: keysTarget, rng: &rng)
                    }
                }
            }

            // アルペジオ(上下に行き来。B では 1 オクターブ上の音も混ぜる)
            if preset.arpeggio, ly.contains(.arp) {
                let notes = ch.arp
                let count = notes.count
                var step = 0
                var index = 0
                while step < stepsPerBar {
                    let cycle = max(count * 2 - 2, 1)
                    let k = index % cycle
                    let noteIndex = k < count ? k : cycle - k
                    var midi = notes[min(noteIndex, count - 1)]
                    if ly.contains(.full), step % 8 == 6 { midi += 12 }
                    let start = frame(bar: bar, step: step)
                    let length = Int(Double(arpDivision * stepFrames) * 0.9)
                    let accent: Float = step % 4 == 0 ? 1 : 0.7
                    let pan = Float(k % 2 == 0 ? 0.3 : -0.3)
                    play(midi: midi, start: start, length: length, velocity: velocity(accent * (sec == .intro ? 0.75 : 1)),
                         pan: pan, patch: arpP, target: keysTarget, rng: &rng)
                    step += arpDivision
                    index += 1
                }
            }

            // 旋律(2 小節のモチーフを変奏しながら。強拍はコードの音に寄せる)
            if preset.melody, ly.contains(.melody), (bar - introBars) % 2 == 0 {
                let pool = melodicPool(bar: bar)
                let shift = [0, 0, 1, -1, 2][motifVariant % 5]
                motifVariant += 1
                for (i, note) in motif.enumerated() {
                    // 変奏: 最後の 2 音をたまに変える、たまに休む
                    if i >= motif.count - 2, rng.chance(0.3) { continue }
                    let noteBar = bar + note.step / stepsPerBar
                    guard noteBar < totalBars else { continue }
                    let stepInBar = note.step % stepsPerBar
                    var degree = note.degree + shift
                    degree = max(1, min(pool.count - 2, degree))
                    var midi = pool[degree]
                    if stepInBar % 8 == 0 || note.length >= 6 {
                        // コードの音へ寄せる
                        let tones = chords[noteBar].classes
                        if !tones.contains(midi % 12) {
                            let up = pool[min(degree + 1, pool.count - 1)]
                            let down = pool[max(degree - 1, 0)]
                            if tones.contains(up % 12) { midi = up } else if tones.contains(down % 12) { midi = down }
                        }
                    }
                    let start = frame(bar: noteBar, step: stepInBar)
                    let length = Int(Double(note.length * stepFrames) * (preset.pluckTone == .pizzicato ? 0.5 : 0.92))
                    play(midi: midi, start: start, length: length,
                         velocity: velocity(stepInBar % 4 == 0 ? 0.9 : 0.75), pan: 0.1, patch: melodyP, target: keysTarget, rng: &rng)
                }
            }

            // きらめき(高い鈴をときどき)
            if preset.sparkle, sec != .outro {
                let pool = melodicPool(bar: bar)
                for step in stride(from: 0, to: stepsPerBar, by: 2) where rng.chance(0.14) {
                    let midi = pool[pool.count / 2 + rng.int(pool.count / 2)] + (rng.chance(0.3) ? 12 : 0)
                    let vel = Float(rng.uniform(0.5...1))
                    let pan = Float(rng.uniform(-0.7...0.7))
                    play(midi: midi, start: frame(bar: bar, step: step), length: Int(0.1 * sr),
                         velocity: vel, pan: pan, patch: sparkleP, target: keysTarget, rng: &rng)
                }
            }
        }
        highpass(bus, cutoff: 130)
        addBus(bus, to: master)
        // 作業用バスはここで使い終わり。すぐ解放する
        bus.free()

        // ---------- 3. ベース(マスターへ直接。リバーブ無し) ----------
        let bassTarget = Target(bus: master, send: send, sendLevel: 0)
        if preset.bass {
            for bar in 0..<totalBars where layers(for: section(of: bar)).contains(.bass) {
                let ch = chords[bar]
                for (i, entry) in bassPlan.enumerated() where entry.step < stepsPerBar {
                    let start = frame(bar: bar, step: entry.step)
                    let nextStep = i + 1 < bassPlan.count ? bassPlan[i + 1].step : stepsPerBar
                    let length = max((nextStep - entry.step) * stepFrames - Int(0.03 * sr), stepFrames / 2)
                    let midi: Int
                    switch entry.tone {
                    case 1: midi = ch.bassFifth
                    case 2: midi = ch.bassRoot + 12
                    default: midi = ch.bassRoot
                    }
                    play(midi: midi, start: start, length: length, velocity: velocity(entry.step == 0 ? 1 : 0.85),
                         pan: 0, patch: bassP, target: bassTarget, rng: &rng)
                }
            }
        }

        // ---------- 4. ドラム(マスターへ。スネア・手拍子は少しリバーブへ) ----------
        if preset.drums != .none {
            let drumSend = Float(preset.reverb) * 0.5
            for bar in 0..<totalBars {
                let sec = section(of: bar)
                let ly = layers(for: sec)
                guard ly.contains(.drums) else { continue }
                let pattern = ly.contains(.full) ? patternB : patternA
                let fillBar = (bar - introBars) % 4 == 3
                let kickSample = preset.drums == .heartbeat ? drums.heartbeat : drums.kick
                for step in pattern.kick where step < stepsPerBar {
                    hit(kickSample, at: frame(bar: bar, step: step, humanize: false), gain: pattern.kickGain, pan: 0, send: 0, master: master, sendBus: send)
                }
                for step in pattern.snare where step < stepsPerBar {
                    var gain = pattern.snareGain
                    if preset.drums == .march { gain *= (step % 4 == 0 ? 1 : (step % 2 == 0 ? 0.5 : 0.3)) }
                    hit(drums.snare, at: frame(bar: bar, step: step), gain: velocity(gain), pan: 0.05, send: drumSend, master: master, sendBus: send)
                }
                let hatSample = preset.sleighBells ? drums.bells : (preset.drums == .soft ? drums.shaker : drums.hat)
                let hatSteps = preset.sleighBells ? [0, 2, 4, 6, 8, 10, 12, 14] : pattern.hat
                let hatGain = preset.sleighBells ? max(pattern.hatGain, 0.2) : pattern.hatGain
                for step in hatSteps where step < stepsPerBar {
                    let accent: Float = preset.sleighBells ? (step % 4 == 2 ? 1 : 0.6) : (step % 4 == 0 ? 1 : (step % 2 == 0 ? 0.7 : 0.45))
                    hit(hatSample, at: frame(bar: bar, step: step), gain: velocity(hatGain * accent), pan: -0.25, send: 0, master: master, sendBus: send)
                }
                if ly.contains(.full) {
                    for step in pattern.openHat where step < stepsPerBar {
                        hit(drums.openHat, at: frame(bar: bar, step: step), gain: pattern.hatGain * 1.1, pan: 0.25, send: drumSend * 0.3, master: master, sendBus: send)
                    }
                    if preset.claps {
                        for step in [4, 12] where step < stepsPerBar {
                            hit(drums.clap, at: frame(bar: bar, step: step), gain: velocity(0.5), pan: 0.1, send: drumSend, master: master, sendBus: send)
                        }
                    }
                }
                // フィル(4 小節ごとの最後)
                if fillBar {
                    switch preset.drums {
                    case .pop, .house, .lofi, .soft:
                        let gain = pattern.snareGain
                        let variant = rng.int(3)
                        let steps: [Int] = [[stepsPerBar - 2, stepsPerBar - 1],
                                            [stepsPerBar - 4, stepsPerBar - 3, stepsPerBar - 1],
                                            [stepsPerBar - 3, stepsPerBar - 2, stepsPerBar - 1]][variant]
                        for (i, step) in steps.enumerated() {
                            hit(drums.snare, at: frame(bar: bar, step: step), gain: gain * (0.5 + 0.2 * Float(i)), pan: 0.05, send: drumSend, master: master, sendBus: send)
                        }
                        if ly.contains(.full), preset.drums != .soft {
                            hit(drums.kick, at: frame(bar: bar, step: stepsPerBar - 2, humanize: false), gain: pattern.kickGain * 0.8, pan: 0, send: 0, master: master, sendBus: send)
                        }
                    case .march:
                        // 小節の後半をスネアロールにする
                        let rollStart = stepsPerBar - 4
                        for i in 0..<8 {
                            let at = bar * barFrames + rollStart * stepFrames + i * stepFrames / 2
                            hit(drums.snare, at: at, gain: pattern.snareGain * (0.4 + 0.08 * Float(i)), pan: 0.05, send: drumSend, master: master, sendBus: send)
                        }
                    case .none, .heartbeat:
                        break
                    }
                }
            }
        }

        // ---------- 5. レコードノイズ ----------
        if preset.vinyl {
            var lp: Float = 0
            var crackle: Float = 0
            let L = master.l, R = master.r
            for i in 0..<frames {
                let n = rng.noise()
                lp += 0.35 * (n - lp)
                if rng.chance(0.00018) { crackle = Float(rng.uniform(0.15...0.4)) }
                crackle *= 0.995
                let v = lp * 0.012 + crackle * n * 0.5
                L[i] += v
                R[i] += v * 0.9
            }
        }

        // ---------- 6. マスター: リバーブ → グルーコンプ → アウトロのフィルター+フェード → ラウドネス → リミッター ----------
        reverb(send: send, into: master, amount: Float(preset.reverb), size: preset.widePad ? 0.9 : 0.8, damping: preset.widePad ? 0.3 : 0.45)
        // リバーブ送りはここで使い終わり。コンプなどの前に解放する
        send.free()
        compress(master, thresholdDb: -14, ratio: 2.5, attack: 0.012, release: 0.25)
        outro(master, seconds: short ? 2.0 : 3.5)
        finalize(master)
        return master
    }

    // MARK: - バス処理

    static func addBus(_ bus: Bus, to master: Bus) {
        for i in 0..<bus.count {
            master.l[i] += bus.l[i]
            master.r[i] += bus.r[i]
        }
    }

    /// 2 次(1 次 × 2)のハイパス
    static func highpass(_ bus: Bus, cutoff: Double) {
        let c = Float(1 - exp(-2 * .pi * cutoff / sampleRate))
        var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0
        let L = bus.l, R = bus.r
        for i in 0..<bus.count {
            let xl = L[i]
            l1 += c * (xl - l1)
            let hl = xl - l1
            l2 += c * (hl - l2)
            L[i] = hl - l2
            let xr = R[i]
            r1 += c * (xr - r1)
            let hr = xr - r1
            r2 += c * (hr - r2)
            R[i] = hr - r2
        }
    }

    /// コーラス: 左右で位相の違う LFO で揺らした短いディレイを混ぜる(広がり+ Haas 効果)
    static func chorus(_ bus: Bus, rate: Double, depthMs: Double, delayMs: Double, mix: Float) {
        let sr = sampleRate
        let maxDelay = Int((delayMs + depthMs + 2) / 1000 * sr) + 2
        var lineL = [Float](repeating: 0, count: maxDelay)
        var lineR = [Float](repeating: 0, count: maxDelay)
        var w = 0
        var phase = 0.0
        let inc = rate / sr
        let base = delayMs / 1000 * sr
        let depth = depthMs / 1000 * sr
        let L = bus.l, R = bus.r
        lineL.withUnsafeMutableBufferPointer { DL in
            lineR.withUnsafeMutableBufferPointer { DR in
                for i in 0..<bus.count {
                    let xl = L[i], xr = R[i]
                    DL[w] = xl
                    DR[w] = xr
                    let dl = base + depth * sin(phase * 2 * .pi)
                    let dr = base + depth * sin(phase * 2 * .pi + 2.1)
                    phase += inc
                    if phase >= 1 { phase -= 1 }
                    func read(_ D: UnsafeMutableBufferPointer<Float>, _ d: Double) -> Float {
                        let pos = Double(w) - d
                        let p0 = Int(floor(pos))
                        let frac = Float(pos - Double(p0))
                        let i0 = ((p0 % maxDelay) + maxDelay) % maxDelay
                        let i1 = (i0 + 1) % maxDelay
                        return D[i0] * (1 - frac) + D[i1] * frac
                    }
                    // 左の遅れを右へ、右の遅れを左へ(広がる)
                    let cl = read(DR, dl)
                    let cr = read(DL, dr)
                    L[i] = xl * (1 - mix * 0.5) + cl * mix
                    R[i] = xr * (1 - mix * 0.5) + cr * mix
                    w += 1
                    if w == maxDelay { w = 0 }
                }
            }
        }
    }

    /// Schroeder リバーブ(プリディレイ 20ms、左右で長さの違うコム 4 本+オールパス 2 本、ダンピング付き)
    static func reverb(send: Mono, into master: Bus, amount: Float, size: Double, damping: Float) {
        guard amount > 0.001 else { return }
        let sr = sampleRate
        let scale = sr / 44100
        let combL = [1116, 1188, 1277, 1356].map { Int(Double($0) * scale) }
        let combR = combL.map { $0 + 23 }
        let apL = [556, 441].map { Int(Double($0) * scale) }
        let apR = [579, 464].map { Int(Double($0) * scale) }
        let feedback = Float(0.7 + 0.2 * size)
        let preDelay = Int(0.02 * sr)

        final class Comb {
            var buf: [Float]
            var idx = 0
            var store: Float = 0
            init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
            func process(_ x: Float, feedback: Float, damp: Float) -> Float {
                let out = buf[idx]
                store = out * (1 - damp) + store * damp
                buf[idx] = x + store * feedback
                idx += 1
                if idx == buf.count { idx = 0 }
                return out
            }
        }
        final class Allpass {
            var buf: [Float]
            var idx = 0
            init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
            func process(_ x: Float) -> Float {
                let b = buf[idx]
                let out = -x + b
                buf[idx] = x + b * 0.5
                idx += 1
                if idx == buf.count { idx = 0 }
                return out
            }
        }
        let cL = combL.map { Comb($0) }, cR = combR.map { Comb($0) }
        let aL = apL.map { Allpass($0) }, aR = apR.map { Allpass($0) }
        var pre = [Float](repeating: 0, count: max(preDelay, 1))
        var preIdx = 0
        let S = send.p, L = master.l, R = master.r
        let wet = amount * 0.22
        for i in 0..<master.count {
            let x = pre[preIdx]
            pre[preIdx] = S[i] * 0.5
            preIdx += 1
            if preIdx == pre.count { preIdx = 0 }
            var yl: Float = 0, yr: Float = 0
            for c in cL { yl += c.process(x, feedback: feedback, damp: damping) }
            for c in cR { yr += c.process(x, feedback: feedback, damp: damping) }
            for a in aL { yl = a.process(yl) }
            for a in aR { yr = a.process(yr) }
            L[i] += yl * wet
            R[i] += yr * wet
        }
    }

    /// グルーコンプ(ピーク検出、左右連動)
    static func compress(_ bus: Bus, thresholdDb: Float, ratio: Float, attack: Double, release: Double) {
        let threshold = powf(10, thresholdDb / 20)
        let aCoef = Float(exp(-1 / (attack * sampleRate)))
        let rCoef = Float(exp(-1 / (release * sampleRate)))
        var env: Float = 0
        let L = bus.l, R = bus.r
        for i in 0..<bus.count {
            let x = max(abs(L[i]), abs(R[i]))
            env = x > env ? aCoef * env + (1 - aCoef) * x : rCoef * env + (1 - rCoef) * x
            if env > threshold {
                let g = (threshold + (env - threshold) / ratio) / env
                L[i] *= g
                R[i] *= g
            }
        }
        // メイクアップ
        let makeup: Float = 1.25
        for i in 0..<bus.count {
            L[i] *= makeup
            R[i] *= makeup
        }
    }

    /// アウトロ: 最後の数秒でローパスを閉じながらフェードアウト
    static func outro(_ bus: Bus, seconds: Double) {
        let n = min(Int(seconds * sampleRate), bus.count / 3)
        guard n > 0 else { return }
        let startIdx = bus.count - n
        var coef: Float = 1
        var ll: Float = 0, lr: Float = 0
        let L = bus.l, R = bus.r
        for i in 0..<n {
            let t = Double(i) / Double(n)
            if i & 31 == 0 {
                // 18kHz → 250Hz(対数で)
                let cutoff = 18000 * pow(250.0 / 18000, t)
                coef = Float(1 - exp(-2 * .pi * cutoff / sampleRate))
            }
            // 最後の 60% で音量を落とす
            let fade: Float = t < 0.4 ? 1 : Float(1 - (t - 0.4) / 0.6)
            let idx = startIdx + i
            ll += coef * (L[idx] - ll)
            lr += coef * (R[idx] - lr)
            L[idx] = ll * fade * fade
            R[idx] = lr * fade * fade
        }
    }

    /// ラウドネスをそろえ(RMS)、ソフトクリップでピークを -1dBFS 以下に
    static func finalize(_ bus: Bus) {
        let L = bus.l, R = bus.r
        var sum: Double = 0
        var peak: Float = 0
        for i in 0..<bus.count {
            let l = L[i], r = R[i]
            sum += Double(l * l + r * r)
            peak = max(peak, abs(l), abs(r))
        }
        let rms = Float(sqrt(sum / Double(max(bus.count * 2, 1))))
        guard rms > 0.00001, peak > 0.00001 else { return }
        // RMS を目標に。ただしピークが 2 倍以上飛び出すほどは上げない(リミッターに頼りすぎない)
        let gain = min(targetRMS / rms, targetPeak * 2.2 / peak)
        let knee: Float = 0.75
        let top = targetPeak
        func clip(_ x: Float) -> Float {
            let a = abs(x)
            if a <= knee { return x }
            let y = knee + (top - knee) * tanh((a - knee) / (top - knee))
            return x < 0 ? -y : y
        }
        for i in 0..<bus.count {
            L[i] = clip(L[i] * gain)
            R[i] = clip(R[i] * gain)
        }
    }
}
