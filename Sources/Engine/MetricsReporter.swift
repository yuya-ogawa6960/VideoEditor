import Foundation
import MetricKit

// =====================================================================
// 動作の重さ・落ちた回数(使い勝手の計測)。
// Apple の MetricKit が 1 日に 1 回ほど届けるまとめ(起動時間・固まった時間・メモリ・異常終了・クラッシュ)を、
// 使い方の統計(匿名)として送る。中身(スタック・ファイル)は送らず、数と平均だけ。
// =====================================================================

final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsReporter()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    /// 1 日分のまとめ
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var params: [String: String] = ["version": payload.latestApplicationVersion]
            if let launch = payload.applicationLaunchMetrics,
               let average = Self.average(launch.histogrammedTimeToFirstDraw) {
                params["launch_ms"] = String(Int(average.milliseconds))
            }
            if let responsiveness = payload.applicationResponsivenessMetrics,
               let average = Self.average(responsiveness.histogrammedApplicationHangTime) {
                params["hang_ms"] = String(Int(average.milliseconds))
                params["hangs"] = String(average.count)
            }
            if let memory = payload.memoryMetrics {
                params["peak_mb"] = String(Int(memory.peakMemoryUsage.converted(to: .megabytes).value))
            }
            if let time = payload.applicationTimeMetrics {
                params["fg_min"] = String(Int(time.cumulativeForegroundTime.converted(to: .minutes).value))
            }
            if let exits = payload.applicationExitMetrics {
                let foreground = exits.foregroundExitData
                params["fg_normal"] = String(foreground.cumulativeNormalAppExitCount)
                params["fg_abnormal"] = String(foreground.cumulativeAbnormalExitCount)
                params["fg_memory"] = String(foreground.cumulativeMemoryResourceLimitExitCount)
                params["fg_watchdog"] = String(foreground.cumulativeAppWatchdogExitCount)
            }
            Analytics.shared.track("metrics", params)
        }
    }

    /// クラッシュ・固まり・CPU やディスクの使いすぎ(起きたときだけ届く)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var params: [String: String] = [
                "crashes": String(payload.crashDiagnostics?.count ?? 0),
                "hangs": String(payload.hangDiagnostics?.count ?? 0),
                "cpu": String(payload.cpuExceptionDiagnostics?.count ?? 0),
                "disk": String(payload.diskWriteExceptionDiagnostics?.count ?? 0),
            ]
            if let crash = payload.crashDiagnostics?.first {
                params["version"] = crash.applicationVersion
                if let type = crash.exceptionType { params["exception"] = type.stringValue }
                if let signal = crash.signal { params["signal"] = signal.stringValue }
            }
            Analytics.shared.track("diagnostic", params)
        }
    }

    /// ヒストグラムの平均(各区間の中央 × 回数)と回数
    private static func average(_ histogram: MXHistogram<UnitDuration>) -> (milliseconds: Double, count: Int)? {
        var total = 0.0
        var count = 0
        for case let bucket as MXHistogramBucket<UnitDuration> in histogram.bucketEnumerator.allObjects {
            let start = bucket.bucketStart.converted(to: .milliseconds).value
            let end = bucket.bucketEnd.converted(to: .milliseconds).value
            total += (start + end) / 2 * Double(bucket.bucketCount)
            count += bucket.bucketCount
        }
        guard count > 0 else { return nil }
        return (total / Double(count), count)
    }
}
