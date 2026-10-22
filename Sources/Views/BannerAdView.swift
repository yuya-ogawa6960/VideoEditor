import SwiftUI
import UIKit
import GoogleMobileAds

// =====================================================================
// バナー広告(AdMob のアダプティブバナー。画面の幅に合わせた高さで下に置く)。
// 編集画面には出さず、プロジェクト一覧と書き出し画面の下だけに出す。
// 広告が読み込めるまでは高さ 0(場所を取らない)。
// 本番用のバナーの広告ユニット ID が空のあいだは、TestFlight・デバッグ(テスト広告)でしか出さない。
// =====================================================================

enum BannerAds {
    /// 本番用のバナーの広告ユニット ID(AdMob で「バナー」の広告ユニットを作ったら入れる。空なら本番では出さない)
    static let liveUnit = ""
    /// Google のテスト用アダプティブバナー
    static let testUnit = "ca-app-pub-3940256099942544/2435281174"

    static var unit: String { AdsManager.usesTestAds ? testUnit : liveUnit }
    static var isAvailable: Bool { !unit.isEmpty }

    /// サポート用の情報に出す、最後の読み込みの結果
    @MainActor static var lastStatus: String = AdsManager.notLoadedText
}

/// 画面の下に置くバナー広告の枠
struct BannerAdSlot: View {
    @State private var height: CGFloat = 0

    var body: some View {
        // SDK が始まったら読み込む(AdsManager は @Observable なので、ここで読むと始まったときに描き直される)
        let started = AdsManager.shared.isStarted
        if BannerAds.isAvailable {
            GeometryReader { geo in
                BannerAdRepresentable(width: geo.size.width, started: started) { loadedHeight in
                    height = loadedHeight
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
    }
}

private struct BannerAdRepresentable: UIViewRepresentable {
    let width: CGFloat
    let started: Bool
    let onLoaded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> BannerView {
        let size = currentOrientationAnchoredAdaptiveBanner(width: max(width, 320))
        let banner = BannerView(adSize: size)
        banner.adUnitID = BannerAds.unit
        banner.delegate = context.coordinator
        context.coordinator.adHeight = size.size.height
        loadIfReady(banner, context: context)
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        context.coordinator.onLoaded = onLoaded
        loadIfReady(banner, context: context)
    }

    private func loadIfReady(_ banner: BannerView, context: Context) {
        guard started, !context.coordinator.requested else { return }
        context.coordinator.requested = true
        banner.rootViewController = AdsManager.presentingViewController()
        banner.load(Request())
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        var onLoaded: (CGFloat) -> Void
        var adHeight: CGFloat = 0
        var requested = false

        init(onLoaded: @escaping (CGFloat) -> Void) {
            self.onLoaded = onLoaded
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            let height = adHeight > 0 ? adHeight : bannerView.adSize.size.height
            Task { @MainActor in
                BannerAds.lastStatus = AdsManager.loadResultText(success: true, error: nil)
                self.onLoaded(height)
            }
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            let message = error.localizedDescription
            Task { @MainActor in
                BannerAds.lastStatus = AdsManager.loadResultText(success: false, error: message)
            }
        }
    }
}
