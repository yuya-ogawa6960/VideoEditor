import Foundation

// =====================================================================
// 逆再生ファイルの範囲(1.12.109 から、元の動画全体ではなく使っている範囲だけを逆再生にする)。
// トリミングを広げてファイルの範囲から出たら、編集画面が作り直す(ContentView.rebuildMissingMediaIfNeeded)。
// 逆再生・なめらかスローのファイルは iCloud バックアップに入れないので、別の iPhone に移したあとも作り直す。
// =====================================================================

extension Clip {
    /// 逆再生ファイルが逆にした元素材の範囲(秒)。前の版のファイル(元素材全体)は 0〜duration
    var reversedCoverage: ClosedRange<Double> {
        reversedRange ?? 0...max(0, duration)
    }

    /// 逆再生ファイルが、いまのトリミング範囲を全部含んでいるか
    var reversedFileCoversTrim: Bool {
        guard reversedURL != nil else { return false }
        let coverage = reversedCoverage
        return startTime >= coverage.lowerBound - 0.01 && endTime <= coverage.upperBound + 0.01
    }

    /// 逆再生にしているのに、ファイルが無い・トリミング範囲を含んでいない(作り直しが要る)
    var needsReversedRebuild: Bool {
        isReversed && !isStill && !reversedFileCoversTrim
    }

    /// なめらかスローを使う設定なのに、ファイルが無い(作り直しが要る)
    var needsFlowSlowRebuild: Bool {
        guard flowSlow.enabled, !isStill, flowSlowUnsupportedReason == nil else { return false }
        guard let url = flowSlow.fileURL else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
