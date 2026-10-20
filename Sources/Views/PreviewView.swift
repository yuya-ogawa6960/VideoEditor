import SwiftUI
import UIKit
import AVFoundation
import CoreImage

/// AVPlayerLayer をレイヤーに持つ UIView
final class PreviewPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass で AVPlayerLayer を指定しているので必ず成功する
        return layer as! AVPlayerLayer
    }
}

/// プレイヤーのレイヤーと、その下に敷く「直前のフレーム」の画像をまとめた入れ物。
/// プレビューの作り直しで AVPlayerItem が差し替わると、新しい項目の最初のフレームが出るまで
/// レイヤーは何も描かない。その間に黒い画面ではなく直前のフレームが見えるようにする。
final class PreviewPlayerContainerView: UIView {
    let snapshotView = UIImageView()
    let playerView = PreviewPlayerUIView()

    /// 直前のフレームを保持するか(false なら AVPlayerItemVideoOutput を付けない)
    private(set) var keepsLastFrame = false

    private var itemObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        snapshotView.contentMode = .scaleAspectFit
        snapshotView.frame = bounds
        snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshotView.backgroundColor = .clear
        addSubview(snapshotView)

        // レイヤーに映像が無い間は下の画像が透けて見えるよう、背景は透明にする
        playerView.backgroundColor = .clear
        playerView.frame = bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerView.playerLayer.videoGravity = .resizeAspect
        addSubview(playerView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(player: AVPlayer, keepsLastFrame: Bool) {
        let samePlayer = playerView.playerLayer.player === player
        if samePlayer && self.keepsLastFrame == keepsLastFrame { return }
        self.keepsLastFrame = keepsLastFrame

        itemObservation?.invalidate()
        itemObservation = nil
        readyObservation?.invalidate()
        readyObservation = nil
        if !samePlayer {
            playerView.playerLayer.player = player
        }
        snapshotView.image = nil
        guard keepsLastFrame else {
            detachOutput()
            return
        }

        attachOutput(to: player.currentItem)
        // .prior: 差し替えの直前(古い項目がまだ current の時点)にも呼ばれる。
        // KVO は replaceCurrentItem を呼んだスレッド(PlayerController はメインスレッドで呼ぶ)で届く
        itemObservation = player.observe(\.currentItem, options: [.prior]) { [weak self] _, change in
            guard let strong = self else { return }
            let isPrior = change.isPrior
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    strong.handleItemChange(isPrior: isPrior)
                }
            } else if !isPrior {
                Task { @MainActor in
                    strong.handleItemChange(isPrior: false)
                }
            }
        }
        // 新しい項目の映像が出たら画像は不要(レイヤーに隠れるが、メモリを解放する)
        readyObservation = playerView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            guard let strong = self else { return }
            Task { @MainActor in
                // 準備完了の直後はまだ描画が間に合っていないことがあるので少し待つ
                try? await Task.sleep(nanoseconds: 150_000_000)
                strong.clearSnapshotIfReady()
            }
        }
    }

    private func handleItemChange(isPrior: Bool) {
        if isPrior {
            captureLastFrame()
            return
        }
        let item = playerView.playerLayer.player?.currentItem
        if item == nil {
            snapshotView.image = nil
        }
        attachOutput(to: item)
    }

    private func clearSnapshotIfReady() {
        let layer = playerView.playerLayer
        guard layer.isReadyForDisplay else { return }
        guard let item = layer.player?.currentItem, item === outputItem else { return }
        snapshotView.image = nil
    }

    private func detachOutput() {
        if let videoOutput, let outputItem, outputItem.outputs.contains(where: { $0 === videoOutput }) {
            outputItem.remove(videoOutput)
        }
        videoOutput = nil
        outputItem = nil
    }

    private func attachOutput(to item: AVPlayerItem?) {
        detachOutput()
        guard let item else { return }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
        outputItem = item
    }

    /// 今表示している項目の現在フレームを画像にして下に敷く
    private func captureLastFrame() {
        guard let videoOutput, let outputItem else {
            snapshotView.image = nil
            return
        }
        let time = outputItem.currentTime()
        guard let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            // フレームが取れないときは古い画像を残さない(別の位置の絵が一瞬出るのを避ける)
            snapshotView.image = nil
            return
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            snapshotView.image = nil
            return
        }
        snapshotView.image = UIImage(cgImage: cgImage)
    }
}

struct PreviewPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// 作り直しの間、直前のフレームを表示し続けるか
    var keepsLastFrame: Bool = false

    func makeUIView(context: Context) -> PreviewPlayerContainerView {
        let view = PreviewPlayerContainerView()
        view.configure(player: player, keepsLastFrame: keepsLastFrame)
        return view
    }

    func updateUIView(_ uiView: PreviewPlayerContainerView, context: Context) {
        uiView.configure(player: player, keepsLastFrame: keepsLastFrame)
    }
}

/// プレビュー表示(出力のアスペクト比で表示)
struct PreviewView: View {
    let player: PlayerController

    /// 作り直しが 400 ms 以上続いたときだけ出す小さなくるくる
    @State private var showSpinner = false

    private var aspectRatio: CGFloat {
        let size = player.renderSize
        if size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return 9.0 / 16.0
    }

    var body: some View {
        ZStack {
            Color.black
            PreviewPlayerLayerView(player: player.player, keepsLastFrame: true)
            if let message = player.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .overlay(alignment: .topTrailing) {
            if showSpinner {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                    .padding(6)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityLabel("プレビューを更新中")
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .task(id: player.isRebuilding) {
            if player.isRebuilding {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSpinner = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSpinner = false
                }
            }
        }
    }
}
