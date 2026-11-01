import Foundation
import Accelerate

// =====================================================================
// マルチカメラの音声同期の計算部分(AVFoundation・UI に依存しない。CI の単体テストで確かめる)
// 1) 8 kHz モノラル → 100 Hz の音量の特徴量(プリエンファシス → RMS → 対数)
// 2) 間引きの段数を自動で選び、ずれの範囲を制限せずに総当たりで照合する
//    (重なりごとの Pearson 相関を Fisher 変換し、重なりの長さで重み付けして比べる)
// 3) 上位の候補を 100 Hz で探し直し、放物線でフレーム未満まで詰める
// 4) 8 kHz の波形を複数の窓で照合し、直線を当てて時計のずれ(ドリフト)を推定する
// 符号: アングルの時刻 = メインの時刻 + ずれ
// =====================================================================

enum AudioSyncCore {
    /// 波形の照合に使うサンプルレート
    static let sampleRate: Double = 8000
    /// 特徴量 1 フレームのサンプル数(8000 / 80 = 100 Hz)
    static let frameLength = 80
    /// 特徴量のフレームレート
    static let featureRate: Double = 100
    /// 粗い探索で使う間引きの段数(小さい順)
    static let decimationSteps = [1, 2, 5, 10, 20, 40]

    struct Candidate: Equatable {
        /// ずれ(秒。アングルの時刻 = メインの時刻 + offset)
        var offset: Double
        /// 重なりの長さを考えた一致の強さ(Fisher の z × √有効サンプル数)
        var score: Double
        /// 重なり部分の相関係数
        var r: Double
    }

    struct CoarseResult {
        /// 強い順(1 つ以上)
        var candidates: [Candidate]
        /// 最良の一致が、ほかのずれに比べてどれだけ突出しているか(中央値と MAD による z)
        var robustZ: Double
        /// 1 位と 2 位の強さの比(2 位がなければ 10)
        var peakRatio: Double
        /// 粗い探索で使った間引きの段数
        var decimation: Int
    }

    struct WindowMatch {
        /// main[k] ↔ angle[lagSamples + k](サンプル単位。小数あり)
        var lagSamples: Double
        /// 相関係数の絶対値
        var r: Double
        /// 最良の一致と、その周り(±2 ms の外)の最大との比
        var psr: Double
        /// 波形の極性が逆(マイクの向きなど)
        var inverted: Bool
    }

    struct LineFit {
        /// tMean でのずれ
        var intercept: Double
        var tMean: Double
        var slope: Double
        var residualRMS: Double
        var slopeSE: Double
        var used: Int
        var span: Double

        func value(at t: Double) -> Double { intercept + slope * (t - tMean) }
    }

    struct WeightedPoint {
        var t: Double
        var d: Double
        var w: Double
    }

    enum CoreError: Error, Equatable {
        case tooShort
        /// 一致が弱い。候補のずれ(強い順、最大 3 つ)
        case weak(candidates: [Double])
    }

    // MARK: - 特徴量

    /// 8 kHz のチャンクを順に受け取り、100 Hz の特徴量 log10(1 + 1000·RMS) にする(チャンクの境目もつなげて計算する)
    struct FeatureAccumulator {
        private(set) var features: [Float] = []
        private var carry: [Float] = []
        private var previous: Float = 0
        private var started = false

        init() {}

        mutating func append(_ chunk: [Float]) {
            guard !chunk.isEmpty else { return }
            var data = chunk
            if !started {
                previous = data[0]
                started = true
            }
            AudioSyncCore.preEmphasize(&data, previous: &previous)
            if !carry.isEmpty {
                data = carry + data
                carry = []
            }
            let n = AudioSyncCore.frameLength
            let frames = data.count / n
            if frames > 0 {
                var out = [Float](repeating: 0, count: frames)
                data.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    for i in 0..<frames {
                        var rms: Float = 0
                        vDSP_rmsqv(base + i * n, 1, &rms, vDSP_Length(n))
                        out[i] = log10f(1 + 1000 * rms)
                    }
                }
                features.append(contentsOf: out)
            }
            let used = frames * n
            if used < data.count {
                carry = Array(data[used...])
            }
        }
    }

    /// y[n] = x[n] − c·x[n−1](風・空調・手で触る音など低い音が、音量の値を支配しないようにする)。
    /// previous は直前のチャンクの最後のサンプル(呼んだあとはこのチャンクの最後のサンプルになる)
    static func preEmphasize(_ x: inout [Float], previous: inout Float, coefficient: Float = 0.97) {
        guard !x.isEmpty else { return }
        var prev = previous
        for i in 0..<x.count {
            let v = x[i]
            x[i] = v - coefficient * prev
            prev = v
        }
        previous = prev
    }

    // MARK: - 粗い探索

    /// 積和の回数が予算に収まる、いちばん小さい間引きの段数
    static func chooseDecimation(mainFrames: Int, angleFrames: Int, budget: Double = 1.5e9) -> Int {
        for d in decimationSteps {
            let work = (Double(mainFrames) / Double(d)) * (Double(angleFrames) / Double(d))
            if work <= budget { return d }
        }
        return decimationSteps[decimationSteps.count - 1]
    }

    /// 間引き(D フレームずつ平均)→ 移動平均を引く(音量の変化・自動音量調整を消す)→ 全体で平均 0・分散 1 にする
    static func prepareLevel(_ raw: [Float], decimation: Int) -> [Float] {
        let d = max(1, decimation)
        let count = raw.count / d
        guard count > 0 else { return [] }
        var x = [Float](repeating: 0, count: count)
        if d == 1 {
            x = Array(raw[0..<count])
        } else {
            raw.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for i in 0..<count {
                    var mean: Float = 0
                    vDSP_meanv(base + i * d, 1, &mean, vDSP_Length(d))
                    x[i] = mean
                }
            }
        }
        // 半幅 h フレーム(0.5 秒。間引きが大きいときは最低 5 フレーム)の移動平均を引く
        let h = max(5, Int(0.5 * featureRate / Double(d)))
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            prefix[i + 1] = prefix[i] + Double(x[i])
        }
        var y = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let lo = max(0, i - h)
            let hi = min(count, i + h + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            y[i] = x[i] - Float(mean)
        }
        return zNormalized(y)
    }

    /// 平均を引いて RMS で割る(無音なら 0 の列)
    static func zNormalized(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let n = vDSP_Length(values.count)
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, n)
        var negative = -mean
        var centered = [Float](repeating: 0, count: values.count)
        vDSP_vsadd(values, 1, &negative, &centered, 1, n)
        var rms: Float = 0
        vDSP_rmsqv(centered, 1, &rms, n)
        guard rms > 1e-9 else { return [Float](repeating: 0, count: values.count) }
        var divisor = rms
        var result = [Float](repeating: 0, count: values.count)
        vDSP_vsdiv(centered, 1, &divisor, &result, 1, n)
        return result
    }

    /// 累積和と二乗の累積和(区間の平均・分散を O(1) で求める)
    private struct PrefixStats {
        let sum: [Double]
        let sumSquares: [Double]

        init(_ x: [Float]) {
            var s = [Double](repeating: 0, count: x.count + 1)
            var q = [Double](repeating: 0, count: x.count + 1)
            for i in 0..<x.count {
                let v = Double(x[i])
                s[i + 1] = s[i] + v
                q[i + 1] = q[i] + v * v
            }
            sum = s
            sumSquares = q
        }
    }

    /// 重なり部分(a[i] ↔ b[i + lag])の Pearson 相関。重なりが minOverlap 未満、またはどちらかが無音なら nil
    private static func pearson(a: UnsafePointer<Float>, aCount: Int, aStats: PrefixStats,
                                b: UnsafePointer<Float>, bCount: Int, bStats: PrefixStats,
                                lag: Int, minOverlap: Int) -> (r: Double, n: Int)? {
        let i0 = max(0, -lag)
        let i1 = min(aCount, bCount - lag)
        let n = i1 - i0
        guard n >= max(minOverlap, 2) else { return nil }
        var dot: Float = 0
        vDSP_dotpr(a + i0, 1, b + i0 + lag, 1, &dot, vDSP_Length(n))
        let count = Double(n)
        let sumA = aStats.sum[i1] - aStats.sum[i0]
        let squaresA = aStats.sumSquares[i1] - aStats.sumSquares[i0]
        let sumB = bStats.sum[i1 + lag] - bStats.sum[i0 + lag]
        let squaresB = bStats.sumSquares[i1 + lag] - bStats.sumSquares[i0 + lag]
        let varianceA = squaresA - sumA * sumA / count
        let varianceB = squaresB - sumB * sumB / count
        guard varianceA > 1e-6 * count, varianceB > 1e-6 * count else { return nil }
        let covariance = Double(dot) - sumA * sumB / count
        return (covariance / (varianceA * varianceB).squareRoot(), n)
    }

    /// 重なり部分の Pearson 相関を直接計算する(探し直しのように、調べるずれが少ないとき用)
    /// window を渡すと、a の添字をその範囲に絞って計算する
    private static func pearsonDirect(a: [Float], b: [Float], lag: Int, minOverlap: Int,
                                      window: Range<Int>? = nil) -> (r: Double, n: Int)? {
        var i0 = max(0, -lag)
        var i1 = min(a.count, b.count - lag)
        if let window {
            i0 = max(i0, window.lowerBound)
            i1 = min(i1, window.upperBound)
        }
        let n = i1 - i0
        guard n >= max(minOverlap, 2) else { return nil }
        var dot: Float = 0
        var sumA: Float = 0
        var sumB: Float = 0
        var squaresA: Float = 0
        var squaresB: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let baseA = pa.baseAddress, let baseB = pb.baseAddress else { return }
                let length = vDSP_Length(n)
                vDSP_dotpr(baseA + i0, 1, baseB + i0 + lag, 1, &dot, length)
                vDSP_sve(baseA + i0, 1, &sumA, length)
                vDSP_sve(baseB + i0 + lag, 1, &sumB, length)
                vDSP_svesq(baseA + i0, 1, &squaresA, length)
                vDSP_svesq(baseB + i0 + lag, 1, &squaresB, length)
            }
        }
        let count = Double(n)
        let varianceA = Double(squaresA) - Double(sumA) * Double(sumA) / count
        let varianceB = Double(squaresB) - Double(sumB) * Double(sumB) / count
        guard varianceA > 1e-6 * count, varianceB > 1e-6 * count else { return nil }
        let covariance = Double(dot) - Double(sumA) * Double(sumB) / count
        return (covariance / (varianceA * varianceB).squareRoot(), n)
    }

    /// 一致の強さ。重なりが短いずれがまぐれで勝たないよう、Fisher の z に √(有効サンプル数) を掛ける
    /// (音量の特徴量は隣どうしが似ているので、1 秒あたり約 10 個を独立なサンプルとみなす)
    static func score(r: Double, n: Int, frameRate: Double) -> Double {
        let effective = Double(n) * min(1, 10 / max(frameRate, 1e-6))
        let z = atanh(min(max(r, -0.99), 0.99))
        return z * max(effective - 3, 1).squareRoot()
    }

    /// 2 つの特徴量(100 Hz)を照合して、ずれの候補を強い順に返す。originDelta = アングルの先頭の時刻 − メインの先頭の時刻。
    /// 一致が弱いときは CoreError.weak、短すぎるときは CoreError.tooShort、キャンセルされたら CancellationError
    static func coarseSearch(mainRaw: [Float], angleRaw: [Float], originDelta: Double) throws -> CoarseResult {
        let d = chooseDecimation(mainFrames: mainRaw.count, angleFrames: angleRaw.count)
        let a = prepareLevel(mainRaw, decimation: d)
        let b = prepareLevel(angleRaw, decimation: d)
        let f = featureRate / Double(d)
        let shortSeconds = Double(min(a.count, b.count)) / f
        guard shortSeconds >= 3 else { throw CoreError.tooShort }
        let minOverlapSeconds = min(15, max(3, 0.5 * shortSeconds))
        let minOverlap = Int((minOverlapSeconds * f).rounded(.up))
        let lagLow = -(a.count - minOverlap)
        let lagHigh = b.count - minOverlap
        guard lagLow <= lagHigh else { throw CoreError.tooShort }

        let aStats = PrefixStats(a)
        let bStats = PrefixStats(b)
        let lagCount = lagHigh - lagLow + 1
        var scores = [Double](repeating: -Double.infinity, count: lagCount)
        var cancelled = false
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let baseA = pa.baseAddress, let baseB = pb.baseAddress else { return }
                for k in 0..<lagCount {
                    if k % 2048 == 0 && Task.isCancelled {
                        cancelled = true
                        return
                    }
                    guard let p = pearson(a: baseA, aCount: a.count, aStats: aStats,
                                          b: baseB, bCount: b.count, bStats: bStats,
                                          lag: lagLow + k, minOverlap: minOverlap) else { continue }
                    scores[k] = score(r: p.r, n: p.n, frameRate: f)
                }
            }
        }
        if cancelled { throw CancellationError() }

        var finite: [Double] = []
        finite.reserveCapacity(lagCount)
        for s in scores where s.isFinite { finite.append(s) }
        guard !finite.isEmpty else { throw CoreError.weak(candidates: []) }
        let center = median(finite)
        var deviations: [Double] = []
        deviations.reserveCapacity(finite.count)
        for s in finite { deviations.append(abs(s - center)) }
        let sigma = max(1.4826 * median(deviations), 1e-6)

        // 上位 5 つ(0.5 秒以上離れたもの)
        let separation = max(1, Int((0.5 * f).rounded(.up)))
        let order = scores.indices.filter { scores[$0].isFinite }.sorted { scores[$0] > scores[$1] }
        var picked: [Int] = []
        for k in order {
            var farEnough = true
            for p in picked where abs(p - k) < separation {
                farEnough = false
                break
            }
            if farEnough {
                picked.append(k)
                if picked.count == 5 { break }
            }
        }
        guard let topIndex = picked.first else { throw CoreError.weak(candidates: []) }
        let robustZ = (scores[topIndex] - center) / sigma

        // 100 Hz で探し直して、放物線でフレーム未満まで詰める
        let fineA = d == 1 ? a : prepareLevel(mainRaw, decimation: 1)
        let fineB = d == 1 ? b : prepareLevel(angleRaw, decimation: 1)
        let fineMinOverlap = minOverlap * d
        var candidates: [Candidate] = []
        for k in picked {
            if Task.isCancelled { throw CancellationError() }
            let coarseLag = (lagLow + k) * d
            let reach = d == 1 ? 1 : d + 3
            var bestLag = coarseLag
            var bestScore = -Double.infinity
            var bestR = 0.0
            var rByLag: [Int: Double] = [:]
            for lag in (coarseLag - reach)...(coarseLag + reach) {
                guard let p = pearsonDirect(a: fineA, b: fineB, lag: lag, minOverlap: fineMinOverlap) else { continue }
                rByLag[lag] = p.r
                let s = score(r: p.r, n: p.n, frameRate: featureRate)
                if s > bestScore {
                    bestScore = s
                    bestLag = lag
                    bestR = p.r
                }
            }
            guard bestScore.isFinite else { continue }
            var delta = 0.0
            if let before = rByLag[bestLag - 1], let after = rByLag[bestLag + 1] {
                delta = parabolicDelta(before, bestR, after)
            }
            let offset = (Double(bestLag) + delta) / featureRate + originDelta
            // 長い重なりでは時計のずれで 1 つのずれでの相関が薄まる。判定に使う相関は、重なりの中央 600 秒以内で測る
            var gateR = bestR
            let o0 = max(0, -bestLag)
            let o1 = min(fineA.count, fineB.count - bestLag)
            let maxSpan = Int(600 * featureRate)
            if o1 - o0 > maxSpan {
                let mid = (o0 + o1) / 2
                let window = (mid - maxSpan / 2)..<(mid + maxSpan / 2)
                for lag in (bestLag - 3)...(bestLag + 3) {
                    if let p = pearsonDirect(a: fineA, b: fineB, lag: lag, minOverlap: fineMinOverlap, window: window) {
                        gateR = max(gateR, p.r)
                    }
                }
            }
            candidates.append(Candidate(offset: offset, score: bestScore, r: gateR))
        }
        candidates.sort { $0.score > $1.score }
        // 間引きが大きいと、近くの候補が探し直しで同じずれに集まることがある。0.5 秒以内の重複は 1 つにする
        var distinct: [Candidate] = []
        for c in candidates where !distinct.contains(where: { abs($0.offset - c.offset) < 0.5 }) {
            distinct.append(c)
        }
        candidates = distinct
        guard let best = candidates.first else { throw CoreError.weak(candidates: []) }
        let peakRatio: Double
        if candidates.count >= 2, candidates[1].score > 0 {
            peakRatio = best.score / candidates[1].score
        } else {
            peakRatio = 10
        }
        if best.score < 5 || robustZ < 5 || best.r < 0.08 {
            throw CoreError.weak(candidates: Array(candidates.prefix(3)).map(\.offset))
        }
        return CoarseResult(candidates: candidates, robustZ: robustZ, peakRatio: peakRatio, decimation: d)
    }

    // MARK: - 波形の窓での照合

    /// プリエンファシスをかけて平均を引く
    static func prepareWaveform(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var x = samples
        var previous = x[0]
        preEmphasize(&x, previous: &previous)
        let n = vDSP_Length(x.count)
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, n)
        var negative = -mean
        var result = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &negative, &result, 1, n)
        return result
    }

    /// main(短い窓)を angle(前後に余裕を足した窓)の中で動かして、いちばん一致する位置を探す。
    /// 戻り値の lagSamples は angle の先頭からのサンプル数(main[k] ↔ angle[lagSamples + k])
    static func matchWindow(main: [Float], angle: [Float]) -> WindowMatch? {
        let m = main.count
        guard m >= Int(sampleRate * 0.5), angle.count >= m else { return nil }
        let a = prepareWaveform(main)
        let b = prepareWaveform(angle)
        var energyMain: Float = 0
        vDSP_svesq(a, 1, &energyMain, vDSP_Length(m))
        guard energyMain > 1e-9 else { return nil }
        let lagCount = b.count - m + 1
        var prefix = [Double](repeating: 0, count: b.count + 1)
        for i in 0..<b.count {
            prefix[i + 1] = prefix[i] + Double(b[i]) * Double(b[i])
        }
        var rs = [Double](repeating: 0, count: lagCount)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let baseA = pa.baseAddress, let baseB = pb.baseAddress else { return }
                for l in 0..<lagCount {
                    var dot: Float = 0
                    vDSP_dotpr(baseA, 1, baseB + l, 1, &dot, vDSP_Length(m))
                    let energyAngle = prefix[l + m] - prefix[l]
                    let denominator = (Double(energyMain) * energyAngle).squareRoot()
                    rs[l] = denominator > 1e-12 ? Double(dot) / denominator : 0
                }
            }
        }
        var best = 0
        for l in 0..<lagCount where abs(rs[l]) > abs(rs[best]) {
            best = l
        }
        let peak = abs(rs[best])
        guard peak > 0 else { return nil }
        // ±2 ms の外での最大と比べる(同じ音が繰り返す素材で、隣の山と区別できるか)
        let guardSamples = 16
        var side = 0.0
        var hasSide = false
        for l in 0..<lagCount where abs(l - best) > guardSamples {
            hasSide = true
            side = max(side, abs(rs[l]))
        }
        let psr = hasSide && side > 1e-9 ? min(peak / side, 10) : 10
        var delta = 0.0
        if best > 0 && best < lagCount - 1 {
            delta = parabolicDelta(abs(rs[best - 1]), peak, abs(rs[best + 1]))
        }
        return WindowMatch(lagSamples: Double(best) + delta, r: peak, psr: psr, inverted: rs[best] < 0)
    }

    // MARK: - 時計のずれ

    /// 重み付き最小二乗で直線 d = intercept + slope·(t − tMean) を当てる。外れた点を 1 回除いて当て直す
    static func fitLine(_ points: [WeightedPoint]) -> LineFit? {
        guard !points.isEmpty else { return nil }
        guard var fit = solveLine(points) else { return nil }
        var kept = points
        if points.count >= 3 {
            // 外れた点は、外れ値に引っぱられにくい直線(2 点ずつの傾きの重み付き中央値 = Theil–Sen)からの残差で見分ける。
            // 最小二乗の直線は端の外れ値に引き寄せられ、その点の残差が小さく見えるため
            var slopes: [(value: Double, weight: Double)] = []
            for i in 0..<points.count {
                for j in (i + 1)..<points.count where abs(points[j].t - points[i].t) > 1e-9 {
                    let slope = (points[j].d - points[i].d) / (points[j].t - points[i].t)
                    slopes.append((value: slope, weight: max(points[i].w, 1e-6) * max(points[j].w, 1e-6)))
                }
            }
            let robustSlope = weightedMedian(slopes) ?? fit.slope
            var intercepts: [(value: Double, weight: Double)] = []
            for p in points {
                intercepts.append((value: p.d - robustSlope * p.t, weight: max(p.w, 1e-6)))
            }
            let robustIntercept = weightedMedian(intercepts) ?? (fit.intercept - fit.slope * fit.tMean)
            var residuals: [Double] = []
            for p in points {
                residuals.append(p.d - (robustIntercept + robustSlope * p.t))
            }
            let center = median(residuals)
            var deviations: [Double] = []
            for r in residuals { deviations.append(abs(r - center)) }
            let limit = max(0.003, 3 * 1.4826 * median(deviations))
            var filtered: [WeightedPoint] = []
            for (i, p) in points.enumerated() where abs(residuals[i] - center) <= limit {
                filtered.append(p)
            }
            if filtered.count >= 2 && filtered.count < points.count, let refit = solveLine(filtered) {
                fit = refit
                kept = filtered
            }
        }
        let n = kept.count
        var squares = 0.0
        var tSum = 0.0
        var tMin = Double.infinity
        var tMax = -Double.infinity
        for p in kept {
            let r = p.d - (fit.intercept + fit.slope * (p.t - fit.tMean))
            squares += r * r
            tSum += p.t
            tMin = min(tMin, p.t)
            tMax = max(tMax, p.t)
        }
        let tPlainMean = tSum / Double(n)
        var sxx = 0.0
        for p in kept {
            sxx += (p.t - tPlainMean) * (p.t - tPlainMean)
        }
        let rms = (squares / Double(n)).squareRoot()
        let se: Double
        if n >= 3 && sxx > 1e-9 {
            se = (squares / Double(n - 2) / sxx).squareRoot()
        } else {
            se = .infinity
        }
        return LineFit(intercept: fit.intercept, tMean: fit.tMean, slope: fit.slope,
                       residualRMS: rms, slopeSE: se, used: n, span: max(0, tMax - tMin))
    }

    private static func solveLine(_ points: [WeightedPoint]) -> (intercept: Double, tMean: Double, slope: Double)? {
        var weightSum = 0.0
        var tWeighted = 0.0
        var dWeighted = 0.0
        for p in points {
            let w = max(p.w, 1e-6)
            weightSum += w
            tWeighted += w * p.t
            dWeighted += w * p.d
        }
        guard weightSum > 0 else { return nil }
        let tMean = tWeighted / weightSum
        let dMean = dWeighted / weightSum
        var sxx = 0.0
        var sxy = 0.0
        for p in points {
            let w = max(p.w, 1e-6)
            sxx += w * (p.t - tMean) * (p.t - tMean)
            sxy += w * (p.t - tMean) * (p.d - dMean)
        }
        let slope = sxx > 1e-9 ? sxy / sxx : 0
        return (dMean, tMean, slope)
    }

    // MARK: - 小さな道具

    /// 3 点 (−1, a), (0, b), (1, c) を通る放物線の頂点の位置(−0.5...0.5)
    static func parabolicDelta(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let denominator = a - 2 * b + c
        guard abs(denominator) > 1e-12 else { return 0 }
        return min(max(0.5 * (a - c) / denominator, -0.5), 0.5)
    }

    /// 別のアングルを経由した対応をつなぐ。parent: 参照アングルの時刻 = o_p + k_p·メインの時刻、
    /// child: このアングルの時刻 = o_c + k_c·参照アングルの時刻 → このアングルの時刻 = (o_c + k_c·o_p) + k_c·k_p·メインの時刻
    static func compose(parent: (offset: Double, rate: Double),
                        child: (offset: Double, rate: Double)) -> (offset: Double, rate: Double) {
        (child.offset + child.rate * parent.offset, child.rate * parent.rate)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// 重み付き中央値(重みが 0 以下・値が有限でないものは除く)
    static func weightedMedian(_ values: [(value: Double, weight: Double)]) -> Double? {
        let items = values.filter { $0.weight > 0 && $0.value.isFinite }.sorted { $0.value < $1.value }
        guard !items.isEmpty else { return nil }
        var total = 0.0
        for item in items { total += item.weight }
        var accumulated = 0.0
        for item in items {
            accumulated += item.weight
            if accumulated >= total / 2 { return item.value }
        }
        return items[items.count - 1].value
    }

    // MARK: - 表示と入力

    /// "+12.345" / "−1:02.345" / "+1:00:00.000"
    static func formatOffset(_ seconds: Double) -> String {
        guard seconds.isFinite, abs(seconds) < 1e9 else { return "+0.000" }
        let totalMilliseconds = Int((abs(seconds) * 1000).rounded())
        let sign = seconds < 0 && totalMilliseconds > 0 ? "−" : "+"
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        if h > 0 {
            return sign + String(format: "%d:%02d:%02d.%03d", h, m, s, milliseconds)
        }
        if totalMinutes > 0 {
            return sign + String(format: "%d:%02d.%03d", m, s, milliseconds)
        }
        return sign + String(format: "%d.%03d", s, milliseconds)
    }

    /// "12.5" / "-12,5" / "−3" / "+1:02.5" / "1:00:00"(全角も可)を秒にする。読めなければ nil
    static func parseOffset(_ text: String) -> Double? {
        let replacements: [Character: Character] = [
            "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
            "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
            "．": ".", "，": ".", ",": ".", "：": ":",
            "−": "-", "－": "-", "‐": "-", "–": "-", "ー": "-", "＋": "+",
        ]
        var cleaned = ""
        for ch in text {
            if ch.isWhitespace { continue }
            cleaned.append(replacements[ch] ?? ch)
        }
        guard !cleaned.isEmpty else { return nil }
        var sign = 1.0
        if cleaned.hasPrefix("-") {
            sign = -1
            cleaned.removeFirst()
        } else if cleaned.hasPrefix("+") {
            cleaned.removeFirst()
        }
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            // 数字と小数点だけ(Double は "1e16" や "0x10" も読むので、先に弾く)
            guard !part.isEmpty, part.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
                  let value = Double(part), value.isFinite, value >= 0 else { return nil }
            let isLast = index == parts.count - 1
            // 時・分は整数。2 つめ以降(分・秒)は 60 未満
            if !isLast && value != value.rounded() { return nil }
            if index > 0 && value >= 60 { return nil }
            total = total * 60 + value
        }
        return sign * total
    }
}
