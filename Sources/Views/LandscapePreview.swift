import SwiftUI
import UIKit

// =====================================================================
// 横向きの全画面プレビュー。
// 編集画面はたて向きのまま固定し、iPhone を横にしたとき(または ⤢ ボタン)だけ
// 画面を横向きにして、動画を大きく再生する。たてに戻すと閉じる。
// =====================================================================

/// アプリが許す画面の向き(AppDelegate が返す)
enum OrientationController {
    static var mask: UIInterfaceOrientationMask = .portrait

    /// 向きを変える(mask を変えてから、画面に回転を頼む)
    static func rotate(to orientation: UIInterfaceOrientationMask) {
        // 横向きにしたら、左右どちらに倒しても回るようにする
        mask = orientation == .portrait ? .portrait : .landscape
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
    }

    /// 端末の向きに合う横向き(端末を左に倒す = 画面は右向き)
    static func landscapeMask(for device: UIDeviceOrientation) -> UIInterfaceOrientationMask {
        device == .landscapeRight ? .landscapeLeft : .landscapeRight
    }
}

/// 全画面プレビュー(タップで操作ボタンの表示 / 非表示)
struct LandscapePreviewView: View {
    let player: PlayerController
    let onClose: () -> Void

    @State private var showsControls = true
    @State private var dragValue: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let total: Double = max(player.duration, 0.01)
        let playing: Bool = player.isPlaying
        let shown: Double = dragValue ?? min(max(player.currentTime, 0), total)

        ZStack {
            Color.black.ignoresSafeArea()
            PreviewPlayerLayerView(player: player.player, keepsLastFrame: true)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                    scheduleHide()
                }

            if showsControls {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            EditorHaptics.tap()
                            onClose()
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("全画面を閉じる")
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            EditorHaptics.tap()
                            player.togglePlay()
                            scheduleHide()
                        } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playing ? String(localized: "一時停止") : String(localized: "再生"))

                        Text(EditorTimeFormat.short(shown))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.white)
                        Slider(value: Binding<Double>(
                                    get: { shown },
                                    set: { newValue in
                                        dragValue = newValue
                                        player.scrub(to: newValue)
                                    }),
                               in: 0...total,
                               onEditingChanged: { editing in
                                   if editing {
                                       if player.isPlaying { player.pause() }
                                       hideTask?.cancel()
                                   } else {
                                       let finalValue: Double = dragValue ?? shown
                                       dragValue = nil
                                       player.endScrub(at: finalValue)
                                       scheduleHide()
                                   }
                               })
                        Text(EditorTimeFormat.short(total))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45), in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // たてに戻したら閉じる
            if UIDevice.current.orientation == .portrait {
                onClose()
            }
        }
    }

    /// 再生中は 3 秒で操作ボタンを隠す
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            if player.isPlaying {
                withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
            }
        }
    }
}
