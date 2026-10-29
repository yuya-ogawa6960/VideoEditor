import SwiftUI
import AVFoundation

// =====================================================================
// 被写体フラッシュのパネル(クリップの「エフェクト」)。
// 人物 / いちばん目立つ被写体 / タップで選んだ被写体 だけを、決めたタイミングでパッと光らせる。
// 「タップで選ぶ」は、光る瞬間のコマ(合成後)をパネルに出して、その上をタップして選ぶ。
// 開いている間は、光る前後をプレビューで繰り返し再生する。
// =====================================================================

struct EditorSubjectFlashPanel: View {
    @Binding var clip: Clip
    let project: EditorProject
    var player: PlayerController? = nil

    /// 「タップで選ぶ」用のコマ
    @State private var frameImage: UIImage? = nil
    @State private var isLoadingFrame = false

    private var flash: Binding<SubjectFlash> {
        Binding(get: { clip.subjectFlash }, set: { clip.subjectFlash = $0 })
    }

    private var enabled: Bool { clip.subjectFlash.enabled }

    /// クリップの出力上の長さ(光るタイミングの上限に使う)
    private var clipLength: Double {
        guard let range = ClipFXTimeline.range(of: clip.id, in: project) else { return clip.outputDuration }
        return max(0, range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: flash.enabled) {
                Label("被写体を光らせる", systemImage: "sparkle")
                    .font(.subheadline)
            }
            .tint(.accentColor)

            Group {
                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: String(localized: "光らせるもの"))
                    HStack(spacing: 8) {
                        ForEach(SubjectFlashTarget.allCases) { target in
                            EditorChip(title: target.displayName, isSelected: clip.subjectFlash.target == target) {
                                clip.subjectFlash.target = target
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                if clip.subjectFlash.target == .tapped {
                    tapPicker
                }

                VStack(alignment: .leading, spacing: 6) {
                    EditorSectionTitle(title: String(localized: "光るタイミング"))
                    HStack(spacing: 8) {
                        EditorChip(title: String(localized: "クリップの始まり"),
                                   isSelected: clip.subjectFlash.time < 0.01) {
                            clip.subjectFlash.time = 0
                        }
                        EditorChip(title: String(localized: "今の再生位置"), isSelected: false) {
                            useCurrentPosition()
                        }
                        .disabled(player == nil)
                        Spacer(minLength: 0)
                        Text(clipFXSeconds(clip.subjectFlash.time))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                EditorSliderRow(title: String(localized: "長さ"),
                                value: flash.duration,
                                range: 0.15...1.0,
                                display: clipFXSeconds(clip.subjectFlash.duration))

                EditorSliderRow(title: String(localized: "強さ"),
                                value: flash.strength,
                                range: 0.2...1.0,
                                display: "\(Int((clip.subjectFlash.strength * 100).rounded()))%")

                Toggle(isOn: flash.glow) {
                    Text("まわりに光のふち")
                        .font(.caption)
                }
                .tint(.accentColor)

                ClipFXHint(text: String(localized: "画面全体を光らせるときは、トランジションの「白飛びフラッシュ」を使います。"))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
        .padding(.top, 6)
        .onAppear { updateLoop() }
        .onChange(of: clip.subjectFlash) { _, _ in updateLoop() }
        .onDisappear { player?.stopLoop() }
        .task(id: frameKey) {
            guard clip.subjectFlash.target == .tapped else { return }
            await loadFrame()
        }
    }

    // MARK: タップで選ぶ

    /// コマを取り直すきっかけ(タイミング・対象の種類が変わったとき)
    private var frameKey: String {
        "\(clip.subjectFlash.target.rawValue)-\(Int((clip.subjectFlash.time * 10).rounded()))"
    }

    private var tapPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionTitle(title: String(localized: "光らせたいものをタップ"))
            ZStack {
                if let frameImage {
                    GeometryReader { geo in
                        let size = geo.size
                        Image(uiImage: frameImage)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in
                                guard size.width > 0, size.height > 0 else { return }
                                EditorHaptics.tap()
                                clip.subjectFlash.point = NormalizedPoint(x: min(max(value.location.x / size.width, 0), 1),
                                                                          y: min(max(value.location.y / size.height, 0), 1))
                            })
                        let p = clip.subjectFlash.point
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .background(Circle().fill(Color.accentColor.opacity(0.6)))
                            .frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .position(x: p.x * size.width, y: p.y * size.height)
                            .allowsHitTesting(false)
                    }
                    .aspectRatio(frameImage.size.width / max(frameImage.size.height, 1), contentMode: .fit)
                } else if isLoadingFrame {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Text("画面を読み取れませんでした")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// 光る瞬間(光り始め)の合成後のコマ
    @MainActor
    private func loadFrame() async {
        guard let player, let item = player.player.currentItem,
              let range = ClipFXTimeline.range(of: clip.id, in: project) else {
            frameImage = nil
            return
        }
        isLoadingFrame = true
        defer { isLoadingFrame = false }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let seconds = min(range.lowerBound + clip.subjectFlash.time, max(range.lowerBound, range.upperBound - 0.05))
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if let result = try? await generator.image(at: time), !Task.isCancelled {
            frameImage = UIImage(cgImage: result.image)
        } else if !Task.isCancelled {
            frameImage = nil
        }
    }

    // MARK: タイミング

    private func useCurrentPosition() {
        guard let player, let range = ClipFXTimeline.range(of: clip.id, in: project) else { return }
        let local = player.currentTime - range.lowerBound
        clip.subjectFlash.time = min(max(local, 0), max(0, clipLength - 0.05))
    }

    /// 光る 0.6 秒前 〜 光り終わって 0.6 秒後 を繰り返す
    private func updateLoop() {
        guard let player else { return }
        guard enabled, let range = ClipFXTimeline.range(of: clip.id, in: project) else {
            player.stopLoop()
            return
        }
        let start = range.lowerBound + clip.subjectFlash.time
        player.startLoop(max(0, start - 0.6)...(start + clip.subjectFlash.duration + 0.6))
    }
}
