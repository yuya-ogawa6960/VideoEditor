import SwiftUI
import AVFoundation

// =====================================================================
// 効果音パネル(ルートのオーディオ › 効果音)。
// 分類ごとに一覧を出し、▶︎ で試聴、「追加」で再生位置にナレーションとして入れる。
// 追加しても選択は変えない(選択が変わるとパネルが閉じ、続けて追加できなくなるため)
// =====================================================================

struct EditorSoundEffectsPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory

    @State private var category: SoundEffectCategory = .motion
    @State private var preview = SoundEffectPreviewPlayer()
    @State private var resultText: String?
    @State private var errorText: String?

    private var items: [SoundEffectKind] {
        SoundEffectKind.allCases.filter { $0.category == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 分類(6 つになって狭い画面では収まらないので、横に流れるチップにする)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SoundEffectCategory.allCases) { c in
                        EditorChip(title: c.title, isSelected: category == c) {
                            category = c
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { kind in
                        row(kind)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let resultText {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("▶︎ で試聴、「追加」で再生位置に入れます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .onAppear {
            // まだ作っていない効果音を先に作っておく(試聴・追加ですぐ鳴るように)
            Task.detached(priority: .utility) {
                SoundEffectLibrary.prepareAll()
            }
        }
        .onDisappear {
            preview.stop()
        }
        .onChange(of: category) {
            preview.stop()
        }
    }

    private func row(_ kind: SoundEffectKind) -> some View {
        let isPlaying = preview.playingKind == kind
        return HStack(spacing: 8) {
            Button {
                togglePreview(kind)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? Text("試聴を止める") : Text("試聴"))

            Text(kind.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                add(kind)
            } label: {
                Label("追加", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func togglePreview(_ kind: SoundEffectKind) {
        if preview.playingKind == kind {
            preview.stop()
            return
        }
        // 編集中の再生と重ならないよう止める
        if player.isPlaying { player.pause() }
        if preview.play(kind) {
            errorText = nil
        } else {
            errorText = String(localized: "効果音を再生できませんでした。")
        }
    }

    private func add(_ kind: SoundEffectKind) {
        preview.stop()
        guard let url = SoundEffectLibrary.url(for: kind),
              let duration = SoundEffectLibrary.duration(of: url) else {
            errorText = String(localized: "効果音を作れませんでした。")
            return
        }
        EditorHaptics.tap()
        errorText = nil
        let startTime = max(0, player.currentTime)
        history.record(project)
        let clip = NarrationClip(url: url,
                                 name: String(localized: "効果音: ") + kind.name,
                                 start: startTime,
                                 duration: duration)
        project.narration.append(clip)
        project.sortNarration()
        resultText = String(localized: "\(MediaTimeText.precise(startTime)) に「\(kind.name)」を追加しました。")
    }
}

// MARK: - 試聴

/// 効果音の試聴(AVAudioPlayer)。鳴っている種類を出す
@Observable
final class SoundEffectPreviewPlayer {
    private(set) var playingKind: SoundEffectKind? = nil
    @ObservationIgnored private var audioPlayer: AVAudioPlayer? = nil
    private let proxy = SoundEffectPreviewDelegateProxy()

    init() {
        proxy.owner = self
    }

    /// 鳴らせたら true
    func play(_ kind: SoundEffectKind) -> Bool {
        stop()
        guard let url = SoundEffectLibrary.url(for: kind),
              let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        AudioSessionSetup.ensurePlayback()
        p.delegate = proxy
        p.prepareToPlay()
        guard p.play() else { return false }
        audioPlayer = p
        playingKind = kind
        return true
    }

    func stop() {
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingKind = nil
    }

    fileprivate func didFinish(_ player: AVAudioPlayer) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        playingKind = nil
    }
}

/// AVAudioPlayer の delegate を受けて SoundEffectPreviewPlayer に渡す(NSObject でないため)
private final class SoundEffectPreviewDelegateProxy: NSObject, AVAudioPlayerDelegate {
    weak var owner: SoundEffectPreviewPlayer?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // delegate がどのスレッドで呼ばれるかは決まっていないので、メインスレッドで処理する
        DispatchQueue.main.async { [weak self] in
            self?.owner?.didFinish(player)
        }
    }
}
