import SwiftUI
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
        guard clip.hasSlowPart else {
            show(FlowSlowError.notSlow.localizedDescription, for: clipID)
            return
        }
        let slowest = clip.slowestSpeed
        let target = Double(project.canvas.frameRate)
        progress = ClipFXProgress(title: String(localized: "なめらかスローを作成中"), fraction: 0)
        task = Task { @MainActor in
            defer {
                self.task = nil
                self.progress = nil
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
            } catch is CancellationError {
                // キャンセル: 何もしない
            } catch {
                if !Task.isCancelled {
                    self.show(String(localized: "なめらかスローを作成できませんでした。\n\(error.localizedDescription)"), for: clipID)
                }
            }
        }
    }

    private func show(_ text: String, for clipID: UUID) {
        messageText = text
        messageClipID = clipID
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
        let usable = clip.hasSlowPart || clip.flowSlow.enabled
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
                if clip.flowSlow.enabled, !fileReady, clip.hasSlowPart {
                    EditorChip(title: String(localized: "作り直す"), isSelected: false) {
                        jobs.start(clipID: clip.id, project: project)
                    }
                    .disabled(jobs.isRunning)
                }
            }
        }
    }
}
