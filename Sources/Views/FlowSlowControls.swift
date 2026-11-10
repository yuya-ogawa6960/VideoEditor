import SwiftUI
import UIKit
import Observation

// =====================================================================
// なめらかスロー(コマを作って足す)の作成と、速度パネルのスイッチ。
// 作成中は ContentView が FlowSlowJobs.shared.progress を見て、画面全体の進捗(キャンセルつき)を出す。
// 作ったファイルは逆再生と同じく mediaDirectory に置き、切ってもファイルは残す(もう一度入れたらすぐ使う)。
// =====================================================================

@Observable
final class FlowSlowJobs {
    static let shared = FlowSlowJobs()

    /// 作成中の進み具合(nil なら作成していない)
    var progress: ClipFXProgress? = nil
    /// 直前に作れなかった理由と、そのクリップ
    var messageClipID: UUID? = nil
    var messageText: String = ""

    @ObservationIgnored private var task: Task<Void, Never>? = nil

    var isRunning: Bool { progress != nil }

    func cancel() {
        task?.cancel()
    }

    /// クリップのなめらかスローを作り、できたら有効にする
    func start(clipID: UUID, project: EditorProject) {
        guard task == nil, let clip = project.clips.first(where: { $0.id == clipID }) else { return }
        messageClipID = nil
        // 逆再生・マルチカメラのクリップでは合成に使われない(Clip.activeFlowSlow)ので作らない
        if let reason = clip.flowSlowUnsupportedReason {
            show(reason, for: clipID)
            return
        }
        guard clip.hasSlowPart else {
            show(FlowSlowError.notSlow.localizedDescription, for: clipID)
            return
        }
        let slowest = clip.slowestSpeed
        let target = Double(project.canvas.frameRate)
        let title = String(localized: "なめらかスローを作成中")
        progress = ClipFXProgress(title: title, fraction: 0)
        // 作成中は画面の自動ロックを止め、アプリを離れてもしばらく(iOS 26 以降はロック中も)続ける
        let keepAlive = MainActor.assumeIsolated {
            LongTaskKeepAlive.begin(title: title) {
                FlowSlowJobs.shared.cancel()
            }
        }
        task = Task { @MainActor in
            var succeeded = false
            defer {
                self.task = nil
                self.progress = nil
                keepAlive.finish(success: succeeded)
            }
            let fps = await FlowSlowRenderer.sourceFrameRate(of: clip.url)
            let factor = FlowSlowRenderer.factor(sourceFrameRate: fps, slowestSpeed: slowest, targetFrameRate: target)
            guard factor >= 2 else {
                self.show(FlowSlowError.notNeeded.localizedDescription, for: clipID)
                return
            }
            do {
                let output = try await FlowSlowRenderer.makeCopy(of: clip.url,
                                                                 start: clip.startTime,
                                                                 end: clip.endTime,
                                                                 factor: factor) { value in
                    DispatchQueue.main.async {
                        if FlowSlowJobs.shared.progress != nil {
                            FlowSlowJobs.shared.progress?.fraction = value
                            MainActor.assumeIsolated {
                                keepAlive.update(value)
                            }
                        }
                    }
                }
                guard !Task.isCancelled, let i = project.index(of: clipID) else {
                    try? FileManager.default.removeItem(at: output.url)
                    return
                }
                var flow = FlowSlowMotion()
                flow.enabled = true
                flow.fileURL = output.url
                flow.sourceStart = output.sourceStart
                flow.sourceEnd = output.sourceEnd
                flow.factor = output.factor
                flow.slowestSpeed = slowest
                project.clips[i].flowSlow = flow
                succeeded = true
            } catch is CancellationError {
                // キャンセル: 何もしない
            } catch {
                if !Task.isCancelled {
                    if keepAlive.leftApp {
                        // 作成中にアプリを離れた(自動ロック・ほかのアプリ)ため、iOS に止められた
                        self.show(String(localized: "アプリを離れたため止まりました。もう一度お試しください"), for: clipID)
                    } else {
                        self.show(String(localized: "なめらかスローを作成できませんでした。\n\(error.localizedDescription)"), for: clipID)
                    }
                }
            }
        }
    }

    private func show(_ text: String, for clipID: UUID) {
        messageText = text
        messageClipID = clipID
    }
}

extension Clip {
    /// なめらかスローを使えない理由(使えるなら nil)。逆再生・マルチカメラは合成で元の素材を使う(activeFlowSlow が nil)ので、
    /// 作っても映像が変わらない(前は作成に時間をかけたうえ「〇倍に増やしています」と出ていた)
    var flowSlowUnsupportedReason: String? {
        if isReversed && reversedURL != nil {
            return String(localized: "逆再生中のクリップでは使えません")
        }
        if multicam.isActive {
            return String(localized: "マルチカメラのクリップでは使えません")
        }
        return nil
    }
}

/// 長い作成処理(なめらかスロー・逆再生)の間だけ、画面の自動ロックを止め、アプリを離れてもしばらく続ける
/// (beginBackgroundTask。iOS 26 以降はロック中も続けられる ContinuedProcessing)。
/// 前は自動ロックでアプリが一時停止して止まり、戻るとエンコーダが使えず失敗することが多かった。
/// 解析(MaskPanels.swift の EditorAnalysisRunner)と同じやり方。終わったら(成功・失敗・キャンセルとも)必ず finish を呼ぶ
@MainActor
final class LongTaskKeepAlive {
    private let idleTimerKey = "longtask-" + UUID().uuidString
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var handle: ContinuedProcessingHandle?
    private var observer: NSObjectProtocol?
    private var finished = false
    /// 処理中にアプリがバックグラウンドへ移ったか(失敗したときの説明に使う)
    private(set) var leftApp = false

    /// 始める(ユーザーの操作から、アプリが前面にあるときに呼ぶ)。onExpire はロック画面などで止められたときに呼ばれる
    static func begin(title: String, onExpire: (@MainActor () -> Void)? = nil) -> LongTaskKeepAlive {
        let keepAlive = LongTaskKeepAlive()
        keepAlive.start(title: title, onExpire: onExpire)
        return keepAlive
    }

    private func start(title: String, onExpire: (@MainActor () -> Void)?) {
        IdleTimerGuard.set(true, for: idleTimerKey)
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LongTask") { [weak self] in
            // 時間切れ(メインスレッドで呼ばれる)。終了しないとアプリが強制終了される。処理そのものは止めない
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
        let continued = ContinuedProcessing.begin(kind: .analyze, title: title, subtitle: title, wantsGPU: true)
        continued?.onExpire = onExpire
        handle = continued
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.leftApp = true
            }
        }
    }

    /// 進み具合(0...1)。ロック画面などのシステムの表示に出る
    func update(_ fraction: Double) {
        handle?.update(completed: fraction, subtitle: nil)
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        handle?.finish(success: success)
        handle = nil
        endBackgroundTask()
        IdleTimerGuard.set(false, for: idleTimerKey)
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

/// 速度パネル・タイムリマップのパネルに入れる「スロー(なめらか)」のスイッチ
struct EditorFlowSlowSection: View {
    let project: EditorProject
    @Binding var clip: Clip

    private var jobs: FlowSlowJobs { FlowSlowJobs.shared }

    /// 作成済みのファイルが、いまのトリミング範囲・速度にそのまま使えるか
    private var fileReady: Bool {
        guard clip.flowSlowCoversRange, let url = clip.flowSlow.fileURL,
              clip.flowSlow.slowestSpeed <= clip.slowestSpeed + 0.01 else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var isOn: Binding<Bool> {
        Binding<Bool>(
            get: { clip.flowSlow.enabled },
            set: { newValue in
                if !newValue {
                    clip.flowSlow.enabled = false
                } else if clip.flowSlowUnsupportedReason != nil {
                    return
                } else if fileReady {
                    clip.flowSlow.enabled = true
                } else {
                    jobs.start(clipID: clip.id, project: project)
                }
            }
        )
    }

    private var statusText: String {
        if jobs.messageClipID == clip.id, !jobs.messageText.isEmpty {
            return jobs.messageText
        }
        if let reason = clip.flowSlowUnsupportedReason {
            return reason
        }
        if !clip.hasSlowPart {
            return String(localized: "速度を1xより遅くすると使えます")
        }
        if clip.flowSlow.enabled {
            if fileReady {
                return String(localized: "前後のコマの動きから、間のコマを \(clip.flowSlow.factor) 倍に増やしています")
            }
            return String(localized: "トリミングや速度を変えたので、作り直すとなめらかになります")
        }
        return String(localized: "動きから間のコマを作って、スローをなめらかにします。作るのに少し時間がかかります")
    }

    var body: some View {
        // 逆再生・マルチカメラのクリップでは入れられない(入っているときは切れるようにだけしておく)
        let supported = clip.flowSlowUnsupportedReason == nil
        let usable = supported ? (clip.hasSlowPart || clip.flowSlow.enabled) : clip.flowSlow.enabled
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                Label("スロー(なめらか)", systemImage: "wand.and.rays")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            .disabled(!usable || jobs.isRunning)
            .opacity(usable ? 1 : 0.4)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if supported, clip.flowSlow.enabled, !fileReady, clip.hasSlowPart {
                    EditorChip(title: String(localized: "作り直す"), isSelected: false) {
                        jobs.start(clipID: clip.id, project: project)
                    }
                    .disabled(jobs.isRunning)
                }
            }
        }
    }
}
