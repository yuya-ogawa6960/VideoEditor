import SwiftUI
import UIKit
import AVFoundation

/// AVPlayerLayer をレイヤーに持つ UIView
final class PreviewPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass で AVPlayerLayer を指定しているので必ず成功する
        return layer as! AVPlayerLayer
    }
}

struct PreviewPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PreviewPlayerUIView {
        let view = PreviewPlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PreviewPlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// プレビュー表示(出力のアスペクト比で表示)
struct PreviewView: View {
    let player: PlayerController

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
            PreviewPlayerLayerView(player: player.player)
            if player.isRebuilding {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
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
        .aspectRatio(aspectRatio, contentMode: .fit)
    }
}
