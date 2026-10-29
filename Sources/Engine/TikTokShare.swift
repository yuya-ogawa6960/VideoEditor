import Foundation
import UIKit
#if canImport(TikTokOpenShareSDK)
import TikTokOpenSDKCore
import TikTokOpenShareSDK
#endif

// =====================================================================
// 書き出した動画を TikTok に送る(TikTok OpenSDK の Share Kit)。
//
// - クライアントキーは Info.plist の TikTokClientKey(project.yml の TIKTOK_CLIENT_KEY。
//   CI は GitHub の Secret TIKTOK_CLIENT_KEY から入れる)。空のあいだはボタンを出さない。
// - Share Kit は写真ライブラリの動画を localIdentifier で渡す。ExportManager が写真に保存したときに記録した ID を使う。
// - 結果は TikTok から redirectURI(ユニバーサルリンク)で戻る。Info.plist の TikTokRedirectURI。
//   アプリに戻れなくても投稿そのものは TikTok 側で進む。
// - TikTok アプリが無いときは SDK が App Store の案内を出す。
// - SDK(パッケージ)を外したビルドでは `#if canImport` で守り、isAvailable == false になる。
// =====================================================================

enum TikTokShare {
    /// Info.plist の TikTokClientKey(空・"$(" のまま・読めなければ nil)
    static var clientKey: String? {
        infoString("TikTokClientKey")
    }

    /// TikTok から戻ってくるときの URL(TikTok for Developers に登録したもの)
    static var redirectURI: String? {
        infoString("TikTokRedirectURI")
    }

    /// 「TikTok に投稿」を出せるか(SDK が入っていて、クライアントキーと戻り先が設定されている)
    static var isAvailable: Bool {
        #if canImport(TikTokOpenShareSDK)
        return clientKey != nil && redirectURI != nil
        #else
        return false
        #endif
    }

    /// 送った結果
    enum Outcome {
        case success
        case cancelled
        case notInstalled
        case failed(String)
    }

    #if canImport(TikTokOpenShareSDK)
    /// 結果が戻るまで依頼を強く持っておく(SDK の決まり)
    @MainActor private static var pendingRequest: TikTokShareRequest?
    #endif

    /// 写真ライブラリの動画(localIdentifier)を TikTok に送る。
    /// TikTok を開けなかったときは false(onResult は呼ばれないことがある)
    @MainActor
    @discardableResult
    static func share(localIdentifiers: [String], onResult: @escaping @MainActor (Outcome) -> Void) -> Bool {
        #if canImport(TikTokOpenShareSDK)
        guard isAvailable, let redirectURI = Self.redirectURI, !localIdentifiers.isEmpty else { return false }
        let request = TikTokShareRequest(localIdentifiers: localIdentifiers, mediaType: .video, redirectURI: redirectURI)
        request.shareFormat = .normal
        pendingRequest = request
        let sent = request.send { response in
            let outcome = Self.outcome(from: response)
            Task { @MainActor in
                Self.pendingRequest = nil
                onResult(outcome)
            }
        }
        // TikTok が入っていないときも false(SDK が App Store の案内を出し、閉じたあとで notInstalled が届く)。
        // そのため依頼は結果が届くまで持っておく
        return sent
        #else
        return false
        #endif
    }

    /// TikTok から戻ってきた URL を SDK に渡す(RootView の onOpenURL / onContinueUserActivity)。SDK が扱ったら true
    @discardableResult
    static func handleOpenURL(_ url: URL?) -> Bool {
        #if canImport(TikTokOpenShareSDK)
        return TikTokURLHandler.handleOpenURL(url)
        #else
        return false
        #endif
    }

    // MARK: - Private

    #if canImport(TikTokOpenShareSDK)
    private static func outcome(from response: TikTokBaseResponse) -> Outcome {
        guard let response = response as? TikTokShareResponse else {
            return .failed(String(localized: "TikTok から結果を受け取れませんでした"))
        }
        if response.errorCode == .noError { return .success }
        switch response.shareState {
        case .success, .saveAsDraft:
            return .success
        case .cancelled:
            return .cancelled
        case .tiktokIsNotInstalled:
            return .notInstalled
        case .videoTimeLimitError:
            return .failed(String(localized: "動画の長さが TikTok の条件に合いません(3 秒より長く、10 分以内)"))
        case .videoResolutionError, .videoFormatError:
            return .failed(String(localized: "この動画の形式・解像度は TikTok に送れません"))
        case .noPhotoLibraryPermission:
            return .failed(String(localized: "TikTok に写真へのアクセスを許可してください"))
        case .userNotLogin:
            return .failed(String(localized: "TikTok アプリでログインしてから、もう一度お試しください"))
        case .upgradeTikTokVersion:
            return .failed(String(localized: "TikTok アプリを最新にしてから、もう一度お試しください"))
        default:
            if response.errorCode == .cancelled { return .cancelled }
            let detail = response.errorDescription ?? ""
            return .failed(detail.isEmpty ? String(localized: "TikTok に送れませんでした") : detail)
        }
    }
    #endif

    private static func infoString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

/// 写真ライブラリへの保存ブロックの中で作った動画の ID を外へ持ち出す入れ物(ExportManager.saveVideoToPhotos)
final class PhotoAssetIDHolder: @unchecked Sendable {
    var value: String?
}
