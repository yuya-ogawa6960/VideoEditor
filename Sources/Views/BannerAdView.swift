import SwiftUI
import UIKit
import GoogleMobileAds

// =====================================================================
// バナー広告(AdMob のアダプティブバナー。画面の幅に合わせた高さで下に置く)。
// 編集画面には出さず、プロジェクト一覧と書き出し画面の下だけに出す。
// 広告が届く前から、その幅のバナーの高さぶん場所を取っておく(届いたときに上のボタンが動かないように)。
// 届かなかった(オフライン・在庫なし)ときは枠を閉じ、しばらくしてから読み込み直して、届いたらそのとき開く。
// 本番用のバナーの広告ユニット ID が空のあいだは、TestFlight・デバッグ(テスト広告)でしか出さない。
// =====================================================================

enum BannerAds {
    /// 本番用のバナーの広告ユニット ID(AdMob の「バナー」。空なら本番では出さない)
    static let liveUnit = "ca-app-pub-5816286661245536/2012576270"
    /// Google のテスト用アダプティブバナー
    static let testUnit = "ca-app-pub-3940256099942544/2435281174"

    static var unit: String { AdsManager.usesTestAds ? testUnit : liveUnit }
    static var isAvailable: Bool { !unit.isEmpty }

    /// その幅のアダプティブバナーの高さ。幅と端末で決まる(SDK は同じ組み合わせに同じ高さを返す)ので、読み込む前から枠の高さに使える
    @MainActor static func bannerHeight(forWidth width: CGFloat) -> CGFloat {
        currentOrientationAnchoredAdaptiveBanner(width: max(width, 320)).size.height
    }

    /// サポート用の情報に出す、最後の読み込みの結果
    @MainActor static var lastStatus: String = AdsManager.notLoadedText
}

/// 画面の下に置くバナー広告の枠。
/// 広告が届く前から同じ高さで場所を取り(届いたときに上のボタンが動かないように)、届かなかったら枠を閉じる。
/// 閉じたあとも、しばらくしてから読み込み直し、届いたらそのとき開く(オフラインで開いて、あとでつながったときなど)
struct BannerAdSlot: View {
    /// 枠の幅(最初の配置で測る。測れるまでは広告を頼まない)
    @State private var width: CGFloat?
    /// 枠の状態
    @State private var slot: SlotState = .reserved
    /// 読み込み直した回数(バナーを作り直すために .id に入れる)
    @State private var attempt = 0

    private enum SlotState {
        /// 届くまで、バナーの高さで場所を取っている
        case reserved
        /// 広告が出ている
        case shown
        /// 届かなかったので閉じている(高さ 0)
        case collapsed
    }

    /// 届かないまま、これだけ待ったら枠を閉じる(SDK が始まれない・同意待ちのときに黒い帯を残さないように)
    private static let reserveTimeout: Duration = .seconds(10)
    /// 閉じたあと、読み込み直すまでの間
    private static let retryInterval: Duration = .seconds(60)

    var body: some View {
        // SDK が始まったら読み込む(AdsManager は @Observable なので、ここで読むと始まったときに描き直される)
        let started = AdsManager.shared.isStarted
        if BannerAds.isAvailable {
            ZStack {
                Color.black
                if let width {
                    BannerAdRepresentable(width: width, started: started) { received in
                        if received {
                            slot = .shown
                        } else if slot == .reserved {
                            // 届かなかった。出ている広告があるときは閉じない(読み直しに失敗しても前の広告は残る)
                            slot = .collapsed
                        }
                    }
                    // 広告の大きさは作るときの幅で決まるので、幅が変わったら(iPhone Duo の開閉など)作り直す。読み込み直すときも作り直す
                    .id("\(Int(width.rounded()))-\(attempt)")
                }
            }
            .frame(height: slot == .collapsed ? 0 : BannerAds.bannerHeight(forWidth: width ?? 320))
            .frame(maxWidth: .infinity)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                // 幅が変わるとバナーを作り直すので、出ていた広告は消える。届くまでは枠だけ空けておく
                if let width, Int(width.rounded()) != Int(newWidth.rounded()), slot == .shown {
                    slot = .reserved
                }
                width = newWidth
            }
            .task(id: "\(slot)-\(attempt)") {
                switch slot {
                case .shown:
                    return
                case .reserved:
                    // 届かないまま時間切れになったら、枠を閉じる
                    try? await Task.sleep(for: Self.reserveTimeout)
                    guard !Task.isCancelled, slot == .reserved else { return }
                    slot = .collapsed
                case .collapsed:
                    // しばらくしてから読み込み直す(バナーを作り直す)
                    try? await Task.sleep(for: Self.retryInterval)
                    guard !Task.isCancelled, slot == .collapsed else { return }
                    attempt += 1
                }
            }
        }
    }
}

private struct BannerAdRepresentable: UIViewRepresentable {
    let width: CGFloat
    let started: Bool
    /// 読み込みの結果(true: 届いた、false: 届かなかった)。同じバナーで何度も呼ばれることがある
    let onResult: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> BannerView {
        let size = currentOrientationAnchoredAdaptiveBanner(width: max(width, 320))
        let banner = BannerView(adSize: size)
        banner.adUnitID = BannerAds.unit
        banner.delegate = context.coordinator
        context.coordinator.onResult = onResult
        loadIfReady(banner, context: context)
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        context.coordinator.onResult = onResult
        loadIfReady(banner, context: context)
    }

    private func loadIfReady(_ banner: BannerView, context: Context) {
        guard started, !context.coordinator.requested else { return }
        context.coordinator.requested = true
        banner.rootViewController = AdsManager.presentingViewController()
        banner.load(Request())
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        var requested = false
        var onResult: (@MainActor (Bool) -> Void)?

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            Task { @MainActor in
                BannerAds.lastStatus = AdsManager.loadResultText(success: true, error: nil)
                onResult?(true)
            }
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            let message = error.localizedDescription
            Task { @MainActor in
                BannerAds.lastStatus = AdsManager.loadResultText(success: false, error: message)
                onResult?(false)
            }
        }
    }
}
