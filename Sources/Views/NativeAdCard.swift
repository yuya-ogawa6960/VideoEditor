import SwiftUI
import UIKit
import GoogleMobileAds

// =====================================================================
// ネイティブ広告(AdMob ネイティブアドバンス)のカード。
// 処理中の画面(書き出し中・字幕の自動作成中)、AI 処理中のカード、書き出し完了画面に出す。
// 広告が届く前から同じ大きさの枠を取っておく(届いたときに近くのボタンが動いて押し間違えないように)。
// =====================================================================

/// ネイティブ広告を 1 件ずつ先読みして配る
@MainActor
final class NativeAdProvider: NSObject {
    static let shared = NativeAdProvider()

    private static let liveUnit = "ca-app-pub-5816286661245536/8409172668"
    private static let testUnit = "ca-app-pub-3940256099942544/3986624511"
    private var unit: String { AdsManager.usesTestAds ? Self.testUnit : Self.liveUnit }

    private var loader: AdLoader?
    private var ready: NativeAd?
    private var waiting: [(NativeAd) -> Void] = []
    /// 続けて読み込みに失敗した回数(読み込み直すまでの間隔に使う)
    private var failures = 0
    /// 読み込み直しの予定がすでにあるか(カードが出るたびの読み込みが失敗しても、予定を重ねないため)
    private var isRetryScheduled = false
    /// サポート用の情報に出す、最後の読み込みの結果
    private(set) var lastStatus = AdsManager.notLoadedText
    private(set) var receivedCount = 0

    /// サポート用の情報(1 行)
    var diagnostic: String {
        var parts = [lastStatus, String(localized: "受け取った数 ") + "\(receivedCount)"]
        if ready != nil { parts.append(String(localized: "準備済み")) }
        if !waiting.isEmpty { parts.append(String(localized: "待っている画面 ") + "\(waiting.count)") }
        if loader != nil { parts.append(String(localized: "読み込み中")) }
        return parts.joined(separator: "・")
    }

    /// 広告を 1 件もらう(なければ読み込みが終わったときに渡す)
    func request(_ handler: @escaping (NativeAd) -> Void) {
        if let ad = ready {
            ready = nil
            handler(ad)
            load()
        } else {
            waiting.append(handler)
            load()
        }
    }

    func preload() {
        if ready == nil { load() }
    }

    private func load() {
        guard AdsManager.shared.isStarted, loader == nil else { return }
        let adLoader = AdLoader(adUnitID: unit, rootViewController: nil, adTypes: [.native], options: nil)
        adLoader.delegate = self
        loader = adLoader
        adLoader.load(Request())
    }

    fileprivate func received(_ ad: NativeAd) {
        loader = nil
        failures = 0
        receivedCount += 1
        lastStatus = AdsManager.loadResultText(success: true, error: nil)
        if !waiting.isEmpty {
            let handler = waiting.removeFirst()
            handler(ad)
            if !waiting.isEmpty { load() }
        } else {
            ready = ad
        }
    }

    fileprivate func failed(_ message: String) {
        loader = nil
        lastStatus = AdsManager.loadResultText(success: false, error: message)
        // 電波が弱いときなど。間をあけて読み込み直す(待っているカードがあればそこに渡す。予定がすでにあれば重ねない)
        failures += 1
        guard !isRetryScheduled else { return }
        isRetryScheduled = true
        let delay = AdsManager.retryDelay(failures: failures)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.isRetryScheduled = false
            self?.preload()
        }
    }
}

extension NativeAdProvider: NativeAdLoaderDelegate {
    nonisolated func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        Task { @MainActor in self.received(nativeAd) }
    }

    nonisolated func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.failed(message) }
    }
}

/// SwiftUI に置くネイティブ広告のカード(高さ 72)。届く前から同じ高さの枠を取る
struct NativeAdCard: View {
    @State private var ad: NativeAd?

    var body: some View {
        // 広告が届くまでも同じ大きさの枠を置いておく(.onAppear を呼ばせるため、そして届いたときに下のボタンが動かないため)
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
            if let ad {
                NativeAdRepresentable(ad: ad)
            }
        }
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .onAppear {
            guard ad == nil else { return }
            NativeAdProvider.shared.request { received in
                ad = received
            }
        }
    }
}

private struct NativeAdRepresentable: UIViewRepresentable {
    let ad: NativeAd

    func makeUIView(context: Context) -> NativeAdView {
        let view = NativeAdView()
        view.backgroundColor = UIColor(white: 1, alpha: 0.08)
        view.layer.cornerRadius = 10
        view.clipsToBounds = true

        let icon = UIImageView()
        icon.contentMode = .scaleAspectFill
        icon.layer.cornerRadius = 8
        icon.clipsToBounds = true

        let badge = UILabel()
        badge.text = String(localized: "広告")
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .black
        badge.backgroundColor = UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 3
        badge.clipsToBounds = true

        let headline = UILabel()
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.textColor = .white
        headline.numberOfLines = 1

        let body = UILabel()
        body.font = .systemFont(ofSize: 11)
        body.textColor = UIColor(white: 1, alpha: 0.7)
        body.numberOfLines = 2

        let action = UIButton(type: .system)
        action.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        action.setTitleColor(.white, for: .normal)
        action.backgroundColor = UIColor(red: 0.12, green: 0.42, blue: 0.78, alpha: 1)
        action.layer.cornerRadius = 12
        action.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        // 押したときの処理は SDK が行う
        action.isUserInteractionEnabled = false

        for sub in [icon, badge, headline, body, action] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            badge.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 14),

            headline.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            headline.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),

            body.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            body.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 4),
            body.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),

            action.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            action.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        action.setContentCompressionResistancePriority(.required, for: .horizontal)

        view.iconView = icon
        view.headlineView = headline
        view.bodyView = body
        view.callToActionView = action
        apply(ad, to: view)
        return view
    }

    func updateUIView(_ view: NativeAdView, context: Context) {
        if view.nativeAd !== ad { apply(ad, to: view) }
    }

    private func apply(_ ad: NativeAd, to view: NativeAdView) {
        (view.headlineView as? UILabel)?.text = ad.headline
        (view.bodyView as? UILabel)?.text = ad.body
        (view.iconView as? UIImageView)?.image = ad.icon?.image
        view.iconView?.isHidden = ad.icon == nil
        (view.callToActionView as? UIButton)?.setTitle(ad.callToAction, for: .normal)
        view.callToActionView?.isHidden = ad.callToAction == nil
        view.nativeAd = ad
    }
}

// MARK: - 大きめのネイティブ広告(作業中のカードの上)

/// 作業中のカードの上に出す大きめのネイティブ広告(メディア + アイコン + 見出し + ボタン)。幅 300・高さ 196。
/// 届く前から同じ大きさの枠を取る(入るかどうかの判定と、カードの位置が途中で変わらないように)
struct NativeAdPanel: View {
    @State private var ad: NativeAd?

    var body: some View {
        // NativeAdCard と同じく、広告が届くまでも同じ大きさの枠を置いて .onAppear を呼ばせる
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.1, opacity: 0.92))
            if let ad {
                NativeAdPanelRepresentable(ad: ad)
            }
        }
        .frame(width: 300, height: 196)
        .onAppear {
            guard ad == nil else { return }
            NativeAdProvider.shared.request { received in
                ad = received
            }
        }
    }
}

private struct NativeAdPanelRepresentable: UIViewRepresentable {
    let ad: NativeAd

    func makeUIView(context: Context) -> NativeAdView {
        let view = NativeAdView()
        view.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        view.layer.cornerRadius = 16
        view.clipsToBounds = true

        let media = MediaView()
        media.contentMode = .scaleAspectFill
        media.clipsToBounds = true
        media.backgroundColor = UIColor(white: 0, alpha: 0.4)

        let badge = UILabel()
        badge.text = String(localized: "広告")
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .black
        badge.backgroundColor = UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 3
        badge.clipsToBounds = true

        let icon = UIImageView()
        icon.contentMode = .scaleAspectFill
        icon.layer.cornerRadius = 7
        icon.clipsToBounds = true

        let headline = UILabel()
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.textColor = .white
        headline.numberOfLines = 1

        let body = UILabel()
        body.font = .systemFont(ofSize: 11)
        body.textColor = UIColor(white: 1, alpha: 0.7)
        body.numberOfLines = 1

        let action = UIButton(type: .system)
        action.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        action.setTitleColor(.white, for: .normal)
        action.backgroundColor = UIColor(red: 0.12, green: 0.42, blue: 0.78, alpha: 1)
        action.layer.cornerRadius = 12
        action.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        // 押したときの処理は SDK が行う
        action.isUserInteractionEnabled = false

        for sub in [media, badge, icon, headline, body, action] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            media.topAnchor.constraint(equalTo: view.topAnchor),
            media.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            media.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            media.heightAnchor.constraint(equalToConstant: 130),

            badge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 14),

            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: media.bottomAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            headline.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            headline.topAnchor.constraint(equalTo: media.bottomAnchor, constant: 12),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),

            body.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            body.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 2),
            body.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),

            action.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            action.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
        action.setContentCompressionResistancePriority(.required, for: .horizontal)

        view.mediaView = media
        view.iconView = icon
        view.headlineView = headline
        view.bodyView = body
        view.callToActionView = action
        apply(ad, to: view)
        return view
    }

    func updateUIView(_ view: NativeAdView, context: Context) {
        if view.nativeAd !== ad { apply(ad, to: view) }
    }

    private func apply(_ ad: NativeAd, to view: NativeAdView) {
        view.mediaView?.mediaContent = ad.mediaContent
        (view.headlineView as? UILabel)?.text = ad.headline
        (view.bodyView as? UILabel)?.text = ad.body ?? ad.advertiser
        (view.iconView as? UIImageView)?.image = ad.icon?.image
        view.iconView?.isHidden = ad.icon == nil
        (view.callToActionView as? UIButton)?.setTitle(ad.callToAction, for: .normal)
        view.callToActionView?.isHidden = ad.callToAction == nil
        view.nativeAd = ad
    }
}
