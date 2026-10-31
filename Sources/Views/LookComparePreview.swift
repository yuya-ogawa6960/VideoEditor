import SwiftUI

// 長押しで元の色を見る(写真アプリの「before / after」と同じ)。
// 色・ルック系のパネルを開いている間だけ、プレビューを長押しすると元の映像(色・ルック・エフェクトなし)になり、
// 指を離すと調整した映像に戻る。パネルのヘッダーの「比較」も押している間だけ元の色になる。
// 合成は作り直さず VideoCompositor の bypass で描き分ける(PlayerController.setBypassLook)。書き出しには影響しない。

/// 元の色を見る範囲
enum LookCompareScope: Equatable {
    /// このクリップだけ
    case clip(UUID)
    /// 全部のクリップと画面全体のルック(映像エフェクト・質感)
    case all
}

extension EditorPanel {
    /// このパネルを開いている間に「元の色を見る」が使えるなら、その範囲。使えないパネルは nil
    var lookCompareScope: LookCompareScope? {
        switch self {
        case .colorAdjust(let id), .filter(let id), .hsl(let id), .lut(let id), .colorMatch(let id),
             .enhance(let id), .retouch(let id), .subjectFlash(let id):
            return .clip(id)
        case .videoEffect, .videoEffectAdd, .documentary:
            return .all
        default:
            return nil
        }
    }
}

extension PlayerController {
    /// 元の色を見る(押している間 true)。離すときは全部の指定を消す
    func setLookCompare(_ held: Bool, scope: LookCompareScope) {
        if held {
            switch scope {
            case .clip(let id): setBypassLook(true, clipID: id)
            case .all: setBypassLook(true, clipID: nil)
            }
        } else {
            setBypassLook(false, clipID: nil)
        }
    }
}

enum LookCompare {
    /// パネルのヘッダーの「比較」用。使えないパネルは nil(ボタンを出さない)
    static func action(for panel: EditorPanel, player: PlayerController) -> ((Bool) -> Void)? {
        guard let scope = panel.lookCompareScope else { return nil }
        return { held in player.setLookCompare(held, scope: scope) }
    }
}

/// プレビューに付ける: 色・ルック系のパネルを開いている間だけ、長押し(0.25 秒)で元の色を見る。
/// ほかのジェスチャー(選択のタップ・枠のドラッグ・ピンチ)と同時に動く。指が動いたら長押しにしない。
/// パネルを開いていないときはジェスチャーを付けない(いつもの動きのまま)
struct LookCompareHoldModifier: ViewModifier {
    let scope: LookCompareScope?
    let player: PlayerController

    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var touching = false
    /// 今回の指で長押しの判定を始めたか
    @State private var began = false
    /// 指が動いたので今回は長押しにしない
    @State private var movedAway = false
    @State private var holdTask: Task<Void, Never>?

    /// これだけ指が動いたら長押しにしない(pt)
    private static let moveTolerance: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(holdGesture, including: scope != nil ? .all : .subviews)
            .overlay(alignment: .top) {
                if player.bypassLookActive {
                    LookCompareBadge()
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: player.bypassLookActive)
            .onChange(of: touching) { _, now in
                if !now { finishTouch() }
            }
            .onChange(of: scope) { _, _ in
                // パネルを閉じた・切り替えたら元に戻す
                finishTouch()
                player.setBypassLook(false, clipID: nil)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    finishTouch()
                    player.setBypassLook(false, clipID: nil)
                }
            }
            .onDisappear {
                finishTouch()
                player.setBypassLook(false, clipID: nil)
            }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if !began {
                    began = true
                    movedAway = false
                    startTimer()
                }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved > Self.moveTolerance, !player.bypassLookActive, !movedAway {
                    movedAway = true
                    holdTask?.cancel()
                    holdTask = nil
                }
            }
    }

    private func startTimer() {
        holdTask?.cancel()
        guard let scope else { return }
        let player = self.player
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            EditorHaptics.tap()
            player.setLookCompare(true, scope: scope)
        }
    }

    /// 指を離した(またはジェスチャーが取り消された)
    private func finishTouch() {
        holdTask?.cancel()
        holdTask = nil
        began = false
        movedAway = false
        if player.bypassLookActive {
            player.setBypassLook(false, clipID: nil)
        }
    }
}

/// プレビューの上に出す「元の色」
struct LookCompareBadge: View {
    var body: some View {
        Text("元の色")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6), in: Capsule())
            .accessibilityLabel("元の色を表示中")
    }
}

/// パネルのヘッダーの「比較」(押している間だけ元の色)
struct LookCompareHeaderButton: View {
    let onCompare: (Bool) -> Void
    @GestureState private var pressing = false

    var body: some View {
        Text("比較")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(pressing ? 0.35 : 0.15), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
            )
            .onChange(of: pressing) { _, now in
                if now { EditorHaptics.tap() }
                onCompare(now)
            }
            .onDisappear {
                onCompare(false)
            }
            .accessibilityLabel("押している間、元の色を表示")
            .accessibilityAddTraits(.isButton)
    }
}

extension View {
    /// 色・ルック系のパネルを開いている間、プレビューの長押しで元の色を見る
    func lookCompareHold(scope: LookCompareScope?, player: PlayerController) -> some View {
        modifier(LookCompareHoldModifier(scope: scope, player: player))
    }
}
