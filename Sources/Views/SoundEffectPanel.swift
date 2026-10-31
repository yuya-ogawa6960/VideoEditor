import SwiftUI
import AVFoundation

// =====================================================================
// 効果音パネル(ルートのオーディオ › 効果音)。
// 上のチップで「場面(SoundScene)」か「分類(SoundEffectCategory)」を選び、一覧を出す。
// 場面を選ぶと、その場面のレシピ(SoundRecipe)と、合う内蔵の効果音(SoundEffectKind)を並べる。
// ▶︎ で試聴、「追加」で再生位置にナレーションとして入れる。
// 追加しても選択は変えない(選択が変わるとパネルが閉じ、続けて追加できなくなるため)
// =====================================================================

/// 一覧の 1 行(内蔵の効果音か、レシピ)
enum SoundEffectItem: Identifiable {
    case kind(SoundEffectKind)
    case recipe(SoundRecipe)

    var id: String {
        switch self {
        case .kind(let k): return "kind." + k.rawValue
        case .recipe(let r): return "recipe." + r.id
        }
    }

    var name: String {
        switch self {
        case .kind(let k): return k.name
        case .recipe(let r): return String(localized: String.LocalizationValue(r.name))
        }
    }

    /// 音のファイル(なければ合成する。失敗したら nil)
    func url() -> URL? {
        switch self {
        case .kind(let k): return SoundEffectLibrary.url(for: k)
        case .recipe(let r): return SoundEffectLibrary.url(forRecipe: r)
        }
    }

    var recipeID: String? {
        if case .recipe(let r) = self { return r.id }
        return nil
    }
}

/// チップの選択(場面か分類)
enum SoundEffectBrowse: Hashable {
    case scene(SoundScene)
    case category(SoundEffectCategory)
}

struct EditorSoundEffectsPanel: View {
    let project: EditorProject
    let player: PlayerController
    let history: EditorHistory

    @State private var browse: SoundEffectBrowse = .scene(.ui)
    @State private var preview = SoundEffectPreviewPlayer()
    @State private var resultText: String?
    @State private var errorText: String?

    private var items: [SoundEffectItem] {
        switch browse {
        case .scene(let scene):
            // 先にレシピ、そのあと合う内蔵の効果音(同じ音が 2 回出ないように)
            let sceneRecipes: [SoundRecipe] = SoundRecipe.recipes(in: scene)
            // レシピと同じ名前の内蔵効果音は出さない(レシピの方が豊かなステレオ版)。
            // 内蔵の名前は翻訳されるので、元の日本語と翻訳後の両方で比べる
            var recipeNames: Set<String> = []
            for recipe in sceneRecipes {
                recipeNames.insert(recipe.name)
                recipeNames.insert(String(localized: String.LocalizationValue(recipe.name)))
            }
            let recipes: [SoundEffectItem] = sceneRecipes.map { SoundEffectItem.recipe($0) }
            let kinds: [SoundEffectItem] = scene.relatedKinds
                .filter { !recipeNames.contains($0.name) }
                .map { SoundEffectItem.kind($0) }
            return recipes + kinds
        case .category(let category):
            return SoundEffectKind.allCases.filter { $0.category == category }.map { SoundEffectItem.kind($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 場面と分類のチップ(多いので横に流す)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SoundScene.allCases) { s in
                        EditorChip(title: s.title, isSelected: browse == .scene(s)) {
                            browse = .scene(s)
                        }
                    }
                    Divider()
                        .frame(height: 20)
                    ForEach(SoundEffectCategory.allCases) { c in
                        EditorChip(title: c.title, isSelected: browse == .category(c)) {
                            browse = .category(c)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        row(item)
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
            prepareScene()
        }
        .onDisappear {
            preview.stop()
        }
        .onChange(of: browse) {
            preview.stop()
            prepareScene()
        }
    }

    /// 選んだ場面のレシピをまとめて作っておく
    private func prepareScene() {
        guard case .scene(let scene) = browse else { return }
        Task.detached(priority: .utility) {
            SoundEffectLibrary.prepare(scene: scene)
        }
    }

    private func row(_ item: SoundEffectItem) -> some View {
        let isPlaying = preview.playingID == item.id
        return HStack(spacing: 8) {
            Button {
                togglePreview(item)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? Text("試聴を止める") : Text("試聴"))

            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                add(item)
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

    private func togglePreview(_ item: SoundEffectItem) {
        if preview.playingID == item.id {
            preview.stop()
            return
        }
        // 編集中の再生と重ならないよう止める
        if player.isPlaying { player.pause() }
        if let url = item.url(), preview.play(url: url, id: item.id) {
            errorText = nil
        } else {
            errorText = String(localized: "効果音を再生できませんでした。")
        }
    }

    private func add(_ item: SoundEffectItem) {
        preview.stop()
        guard let url = item.url(),
              let duration = SoundEffectLibrary.duration(of: url) else {
            errorText = String(localized: "効果音を作れませんでした。")
            return
        }
        EditorHaptics.tap()
        errorText = nil
        let startTime = max(0, player.currentTime)
        history.record(project)
        var clip = NarrationClip(url: url,
                                 name: String(localized: "効果音: ") + item.name,
                                 start: startTime,
                                 duration: duration)
        clip.soundRecipeID = item.recipeID
        project.narration.append(clip)
        project.sortNarration()
        resultText = String(localized: "\(MediaTimeText.precise(startTime)) に「\(item.name)」を追加しました。")
    }
}

// MARK: - 試聴

/// 効果音の試聴(AVAudioPlayer)。鳴っている行の id を出す
@Observable
final class SoundEffectPreviewPlayer {
    private(set) var playingID: String? = nil
    @ObservationIgnored private var audioPlayer: AVAudioPlayer? = nil
    private let proxy = SoundEffectPreviewDelegateProxy()

    init() {
        proxy.owner = self
    }

    /// 内蔵の効果音を鳴らす(鳴らせたら true)
    func play(_ kind: SoundEffectKind) -> Bool {
        guard let url = SoundEffectLibrary.url(for: kind) else { return false }
        return play(url: url, id: SoundEffectItem.kind(kind).id)
    }

    /// ファイルを鳴らす(鳴らせたら true)
    func play(url: URL, id: String) -> Bool {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        AudioSessionSetup.ensurePlayback()
        p.delegate = proxy
        p.prepareToPlay()
        guard p.play() else { return false }
        audioPlayer = p
        playingID = id
        return true
    }

    func stop() {
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
    }

    fileprivate func didFinish(_ player: AVAudioPlayer) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        playingID = nil
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
