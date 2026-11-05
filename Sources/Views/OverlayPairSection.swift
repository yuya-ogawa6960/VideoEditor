import SwiftUI

// =====================================================================
// V1 と V2(動画のオーバーレイ)を 1 つの画面に並べる
//   - 音声で V1 に合わせる: マルチカムと同じ AudioSync で、V2 の素材の位置・開始・速度を V1 のクリップに合わせる
//   - 上下 / 左右に並べる: V1 のクリップを画面の半分(ClipGeometry.canvasFrame)、V2 を残りの半分に置く
// 例: 手元の映像(V1)と表情の映像(V2)を 1 本で書き出す
// =====================================================================

struct OverlayPairSection: View {
    let project: EditorProject
    let history: EditorHistory?
    @Binding var overlay: OverlayClip

    @State private var isSyncing = false
    @State private var note: String?
    @State private var syncTask: Task<Void, Never>?
    /// 顔を探している途中
    @State private var isFindingFace = false

    private static let topHalf = NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)
    private static let bottomHalf = NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5)
    private static let leftHalf = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
    private static let rightHalf = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("V1 と 1 つの画面に並べる")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                syncByAudio()
            } label: {
                HStack(spacing: 6) {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "waveform")
                    }
                    Text(isSyncing ? "音を聞き比べています…" : "音声で V1 に合わせる")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSyncing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    EditorChip(title: String(localized: "上下に並べる"),
                               isSelected: isArranged(v1: Self.topHalf, v2: Self.bottomHalf)) {
                        arrange(v1: Self.topHalf, v2: Self.bottomHalf)
                    }
                    EditorChip(title: String(localized: "左右に並べる"),
                               isSelected: isArranged(v1: Self.leftHalf, v2: Self.rightHalf)) {
                        arrange(v1: Self.leftHalf, v2: Self.rightHalf)
                    }
                    EditorChip(title: String(localized: "入れ替え"), isSelected: false) {
                        swapSides()
                    }
                    .disabled(currentPane == nil)
                    .opacity(currentPane == nil ? 0.4 : 1)
                    EditorChip(title: String(localized: "元に戻す"), isSelected: false) {
                        unarrange()
                    }
                    .disabled(currentPane == nil)
                    .opacity(currentPane == nil ? 0.4 : 1)
                }
            }

            Text(note ?? String(localized: "V1 の音と V2 の音を聞き比べて、同じ瞬間がそろうように V2 を動かします。並べたあとは、プレビューをドラッグ・ピンチして、それぞれ映す位置を直せます。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            framingControls
        }
        .onDisappear { syncTask?.cancel() }
    }

    // MARK: - V2 の映す範囲(顔を真ん中に・追いかける・大きさ)

    private var framingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("V2 の映す範囲")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button {
                    findFace(track: false)
                } label: {
                    Label("顔を真ん中に", systemImage: "person.crop.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if overlay.reframe.isActive {
                    Button {
                        stopTracking()
                    } label: {
                        Label("追いかけをやめる", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        findFace(track: true)
                    } label: {
                        Label("顔を追いかける", systemImage: "person.fill.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(isFindingFace || isSyncing)
            if isFindingFace {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("顔を探しています…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("大きさ")
                    .font(.caption)
                Slider(value: zoomBinding, in: 1...4) { editing in
                    if editing { history?.record(project) }
                }
                Text(verbatim: String(format: "%.1fx", overlay.contentZoom))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("プレビューで V2 をダブルタップすると、ドラッグで映す位置、2本指で大きさを変えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                EditorChip(title: String(localized: "映す範囲を戻す"), isSelected: false) {
                    resetFraming()
                }
                .disabled(!hasFraming)
                .opacity(hasFraming ? 1 : 0.4)
            }
        }
    }

    private var hasFraming: Bool {
        overlay.reframe.isActive || overlay.contentZoom > 1.001 || overlay.contentCenter != .center
    }

    private var zoomBinding: Binding<Double> {
        Binding(get: { overlay.contentZoom },
                set: { value in
                    var updated = overlay
                    updated.contentZoom = min(max(value, 1), 4)
                    updated.fit = .fill
                    updated.kenBurns.enabled = false
                    overlay = updated
                })
    }

    private func resetFraming() {
        history?.record(project)
        var updated = overlay
        updated.contentCenter = .center
        updated.contentZoom = 1
        updated.reframe.enabled = false
        overlay = updated
        note = nil
    }

    private func stopTracking() {
        history?.record(project)
        var updated = overlay
        updated.reframe.enabled = false
        // 追いかけていた位置のまん中あたりで止める
        if let center = Self.medianCenter(updated.reframe.samples, from: updated.sourceStart, to: updated.sourceEnd) {
            updated.contentCenter = center
        }
        overlay = updated
        note = nil
    }

    /// 顔(見つからなければ上半身)を探して、真ん中に置く(track = false)か、追いかける(track = true)。
    /// 同じ範囲を調べたことがあれば、その結果を使う
    private func findFace(track: Bool) {
        guard !overlay.isImage else { return }
        let samples = overlay.reframe.samples
        if let first = samples.first, let last = samples.last,
           first.time <= overlay.sourceStart + 0.5, last.time >= overlay.sourceEnd - 0.5 {
            applyFace(track: track, samples: samples, overlayID: overlay.id)
            return
        }
        isFindingFace = true
        note = nil
        let url = overlay.url
        let start = overlay.sourceStart
        let end = overlay.sourceEnd
        let overlayID = overlay.id
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            defer { isFindingFace = false }
            do {
                let found = try await VisionReframe.analyzeSamples(url: url, start: start, end: end,
                                                                   step: 0.25, progress: nil)
                guard !Task.isCancelled else { return }
                applyFace(track: track, samples: Self.smoothed(found), overlayID: overlayID)
            } catch is CancellationError {
            } catch {
                note = String(localized: "顔を見つけられませんでした: \(error.localizedDescription)")
            }
        }
    }

    private func applyFace(track: Bool, samples: [ReframeSample], overlayID: UUID) {
        guard let oi = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return }
        history?.record(project)
        var updated = project.overlays[oi]
        updated.fit = .fill
        updated.kenBurns.enabled = false
        updated.reframe.samples = samples
        updated.reframe.enabled = track && samples.count >= 2
        if !track, let center = Self.medianCenter(samples, from: updated.sourceStart, to: updated.sourceEnd) {
            updated.contentCenter = center
        }
        // 素材と枠の縦横比が近いと動かす余地が無いので、少し寄せる
        if updated.contentZoom < 1.2 {
            updated.contentZoom = 1.3
        }
        project.overlays[oi] = updated
        note = track
            ? String(localized: "顔を追いかけて、枠の真ん中に映します。「大きさ」で寄り方を変えられます。")
            : String(localized: "顔が枠の真ん中に来るようにしました。")
    }

    /// 範囲の中の注目点の中央値
    private static func medianCenter(_ samples: [ReframeSample], from: Double, to: Double) -> NormalizedPoint? {
        let inRange = samples.filter { $0.time >= from - 0.01 && $0.time <= to + 0.01 }
        let use = inRange.isEmpty ? samples : inRange
        guard !use.isEmpty else { return nil }
        let xs = use.map { $0.center.x }.sorted()
        let ys = use.map { $0.center.y }.sorted()
        return NormalizedPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
    }

    /// 前後から指数平滑して、細かい揺れを抑える(追いかけがカクカクしないように)
    private static func smoothed(_ samples: [ReframeSample]) -> [ReframeSample] {
        guard samples.count > 2 else { return samples }
        let alpha = 0.3
        var out = samples
        for i in 1..<out.count {
            out[i].center.x = out[i - 1].center.x + (out[i].center.x - out[i - 1].center.x) * alpha
            out[i].center.y = out[i - 1].center.y + (out[i].center.y - out[i - 1].center.y) * alpha
        }
        for i in stride(from: out.count - 2, through: 0, by: -1) {
            out[i].center.x = out[i + 1].center.x + (out[i].center.x - out[i + 1].center.x) * alpha
            out[i].center.y = out[i + 1].center.y + (out[i].center.y - out[i + 1].center.y) * alpha
        }
        return out
    }

    // MARK: - V1 のクリップ

    /// V2 と時間が重なる V1 のクリップの番号と、タイムライン上の範囲
    private var pairedClips: [(index: Int, start: Double, end: Double)] {
        let starts = project.clipStartTimes()
        var result: [(index: Int, start: Double, end: Double)] = []
        for (i, clip) in project.clips.enumerated() where i < starts.count {
            let start = starts[i]
            let end = start + clip.outputDuration
            if end > overlay.start + 0.01, start < overlay.end - 0.01 {
                result.append((index: i, start: start, end: end))
            }
        }
        return result
    }

    /// いま画面を分けているときの V1 の置き場所(分けていなければ nil。V2 を動かしたあとも見つかるように、重なりが無ければ全体から探す)
    private var currentPane: NormalizedRect? {
        for item in pairedClips {
            let pane = project.clips[item.index].geometry.canvasFrame
            if !pane.isFull { return pane }
        }
        return project.clips.first(where: { !$0.geometry.canvasFrame.isFull })?.geometry.canvasFrame
    }

    private func isArranged(v1: NormalizedRect, v2: NormalizedRect) -> Bool {
        guard let pane = currentPane else { return false }
        return Self.almostEqual(pane, v1) && Self.almostEqual(overlay.frame, v2)
    }

    private static func almostEqual(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
        abs(a.x - b.x) < 0.005 && abs(a.y - b.y) < 0.005 && abs(a.width - b.width) < 0.005 && abs(a.height - b.height) < 0.005
    }

    // MARK: - 並べる

    private func arrange(v1: NormalizedRect, v2: NormalizedRect) {
        let clips = pairedClips
        guard !clips.isEmpty else {
            note = String(localized: "この V2 の下(同じ時間)に V1 のクリップがありません。")
            return
        }
        history?.record(project)
        for item in clips {
            project.clips[item.index].geometry.canvasFrame = v1
        }
        var updated = overlay
        updated.frame = v2
        updated.fit = .fill
        updated.rotation = 0
        updated.opacity = 1
        updated.cornerRadius = 0
        // 位置のキーフレームがあると枠より優先されるので外す
        updated.keyframes = []
        overlay = updated
        // V1 のクリップが V2 より長いと、V2 の無い時間は半分が黒くなる
        if clips.contains(where: { $0.start < overlay.start - 0.05 || $0.end > overlay.end + 0.05 }) {
            note = String(localized: "V1 のクリップが V2 より長いため、V2 の無い時間は半分が黒くなります。V1 を V2 の長さに合わせて切ってください。")
        } else {
            note = nil
        }
    }

    private func swapSides() {
        guard let pane = currentPane else { return }
        arrange(v1: overlay.frame, v2: pane)
    }

    private func unarrange() {
        history?.record(project)
        // V2 を動かしたあとでも戻せるように、半分に置いた V1 のクリップはすべて画面全体に戻す
        for i in project.clips.indices where !project.clips[i].geometry.canvasFrame.isFull {
            project.clips[i].geometry.canvasFrame = .full
        }
        var updated = overlay
        OverlayPreset.pipSmallCorner.apply(to: &updated)
        updated.frame = OverlayPreset.pipSmallCorner.frame
        overlay = updated
        note = nil
    }

    // MARK: - 音声で合わせる

    /// V2 の頭(なければいちばん長く重なるもの)の下にある V1 のクリップ
    private var referenceClip: (index: Int, start: Double, end: Double)? {
        let clips = pairedClips
        if let atStart = clips.first(where: { overlay.start >= $0.start - 0.01 && overlay.start < $0.end }) {
            return atStart
        }
        return clips.max { min($0.end, overlay.end) - max($0.start, overlay.start) < min($1.end, overlay.end) - max($1.start, overlay.start) }
    }

    private func syncByAudio() {
        guard !overlay.isImage else { return }
        guard let reference = referenceClip else {
            note = String(localized: "この V2 の下(同じ時間)に V1 のクリップがありません。V2 を V1 の動画の上に置いてから合わせてください。")
            return
        }
        let clip = project.clips[reference.index]
        guard !clip.isStill, !clip.speedCurve.enabled, !(clip.isReversed && clip.reversedURL != nil) else {
            note = String(localized: "写真・速度カーブ・逆再生のクリップとは、音声で合わせられません。")
            return
        }
        isSyncing = true
        note = nil
        let referenceURL = clip.url
        let angleURL = overlay.url
        let focus = clip.startTime...max(clip.endTime, clip.startTime + 0.1)
        let clipID = clip.id
        let overlayID = overlay.id
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            defer { isSyncing = false }
            do {
                let result = try await AudioSync.analyze(referenceURL: referenceURL, angleURL: angleURL,
                                                         focus: focus, progress: { _ in })
                guard !Task.isCancelled else { return }
                apply(result, clipID: clipID, overlayID: overlayID)
            } catch is CancellationError {
            } catch {
                note = String(localized: "合わせられませんでした: \(error.localizedDescription)")
            }
        }
    }

    /// V2 の時刻 = offset + rate × V1 の元素材の時刻。V1 のクリップの頭から V2 が同じ瞬間を映すように置く
    private func apply(_ result: AudioSyncResult, clipID: UUID, overlayID: UUID) {
        guard let i = project.index(of: clipID),
              let oi = project.overlays.firstIndex(where: { $0.id == overlayID }) else { return }
        let starts = project.clipStartTimes()
        guard i < starts.count else { return }
        let clip = project.clips[i]
        let clipStart = starts[i]
        let clipEnd = clipStart + clip.outputDuration
        // タイムライン 1 秒あたりに進む V2 の素材の秒数
        let rate = result.rate * max(clip.speed, 0.01)
        guard rate >= 0.25, rate <= 4 else {
            note = String(localized: "合わせられませんでした。")
            return
        }
        var updated = project.overlays[oi]
        var start = clipStart
        var sourceStart = result.offset + result.rate * clip.startTime
        if sourceStart < 0 {
            // V2 の撮り始めが V1 より遅い: V2 を後ろへずらして、素材の頭から使う
            start += -sourceStart / rate
            sourceStart = 0
        }
        guard start < clipEnd - 0.05, sourceStart < updated.sourceDuration - 0.05 else {
            note = String(localized: "音は合いましたが、V1 のクリップと同じ時間の部分が V2 にありません。")
            return
        }
        history?.record(project)
        updated.start = start
        updated.sourceStart = sourceStart
        updated.speed = min(max(rate, 0.25), 4)
        updated.duration = max(0.1, min(clipEnd - start, (updated.sourceDuration - sourceStart) / updated.speed))
        // 同じ音が 2 重に聞こえないように、V2 の音は消す(音量のパネルで戻せる)
        updated.volume = 0
        // そろえた映像が途中から薄く出てこないように、フェードは無くす
        updated.fadeIn = 0
        updated.fadeOut = 0
        project.overlays[oi] = updated
        project.sortOverlays()
        switch result.confidence {
        case .high:
            note = String(localized: "音声で合わせました。V2 の音は消してあります(音量で戻せます)。")
        case .medium:
            note = String(localized: "合わせましたが、自信がありません。再生して、口の動きや手の音がそろっているか確かめてください。")
        }
    }
}
