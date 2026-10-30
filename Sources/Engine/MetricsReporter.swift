import Foundation
import MetricKit

// =====================================================================
// 動作の重さ・落ちた回数(使い勝手の計測)。
// Apple の MetricKit が 1 日に 1 回ほど届けるまとめ(起動時間・固まった時間・メモリ・異常終了・クラッシュ)を、
// 使い方の統計(匿名)として送る。まとめは数と平均だけ。クラッシュ・固まりは原因を追うため、
// 種類・理由・スタックの先頭(バイナリ名とオフセットだけ。ファイル名や文章は含まない)を 1 件ずつ送る。
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

    /// クラッシュ・固まり・CPU やディスクの使いすぎ(起きたときだけ届く)。
    /// クラッシュと固まりは原因を追えるよう 1 件ずつ、種類・理由・スタックの先頭(バイナリ名 + オフセット。個人の情報は含まない)も送る
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

            for crash in (payload.crashDiagnostics ?? []).prefix(3) {
                var detail: [String: String] = ["version": crash.applicationVersion]
                if let type = crash.exceptionType { detail["exception"] = type.stringValue }
                if let signal = crash.signal { detail["signal"] = signal.stringValue }
                if let code = crash.exceptionCode { detail["code"] = code.stringValue }
                if let reason = crash.terminationReason { detail["term"] = Self.clip(reason) }
                if let objc = crash.exceptionReason {
                    detail["reason"] = Self.clip(objc.composedMessage)
                } else if let region = crash.virtualMemoryRegionInfo {
                    detail["reason"] = Self.clip(region)
                }
                detail.merge(Self.frameParams(crash.callStackTree)) { current, _ in current }
                Analytics.shared.track("crash", detail)
            }
            for hang in (payload.hangDiagnostics ?? []).prefix(3) {
                var detail: [String: String] = [
                    "version": hang.applicationVersion,
                    "seconds": String(format: "%.1f", hang.hangDuration.converted(to: .seconds).value),
                ]
                detail.merge(Self.frameParams(hang.callStackTree)) { current, _ in current }
                Analytics.shared.track("hang", detail)
            }
        }
    }

    private static let appBinaryName: String = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? "VideoEditor"

    private static func clip(_ text: String) -> String {
        String(text.prefix(80))
    }

    /// スタックの先頭を "バイナリ名+0xオフセット" で送る: f0・f1 = いちばん深い所から 2 段、a0〜a2 = アプリ本体の関数の先頭 3 段。
    /// uuid はアプリ本体のビルドの UUID(CI に残した dSYM で場所を読むため)
    private static func frameParams(_ tree: MXCallStackTree) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [:] }
        // 原因のスレッド(threadAttributed)を優先。無ければ先頭のスレッド
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard let rootFrames = stack?["callStackRootFrames"] as? [[String: Any]] else { return [:] }
        // 木の根(外側)から葉(落ちた場所)へたどる。枝分かれは標本の多い方
        var chain: [[String: Any]] = []
        var level = rootFrames
        while let next = level.max(by: { (($0["sampleCount"] as? Int) ?? 0) < (($1["sampleCount"] as? Int) ?? 0) }) {
            chain.append(next)
            level = next["subFrames"] as? [[String: Any]] ?? []
        }
        func describe(_ frame: [String: Any]) -> String {
            let name = (frame["binaryName"] as? String) ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            return "\(name)+0x\(String(offset, radix: 16))"
        }
        var params: [String: String] = [:]
        let leafFirst = Array(chain.reversed())
        for (index, frame) in leafFirst.prefix(2).enumerated() {
            params["f\(index)"] = describe(frame)
        }
        let appFrames = leafFirst.filter { ($0["binaryName"] as? String) == appBinaryName }
        for (index, frame) in appFrames.prefix(3).enumerated() {
            params["a\(index)"] = describe(frame)
        }
        if let uuid = appFrames.first?["binaryUUID"] as? String {
            params["uuid"] = uuid
        }
        return params
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
