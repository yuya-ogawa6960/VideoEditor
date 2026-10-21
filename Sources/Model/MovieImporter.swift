import Foundation
import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// =====================================================================
// 写真アプリからの動画の取り込みを、失敗しにくくする。
//
// 実機で「Cannot import PickedMovie ... contains no compatible representations」
// が出た。スローモーション・シネマティック・iCloud にしかない動画などは、
// .movie の FileRepresentation だけでは受け取れないことがあるため、次の順に試す。
//   1. いくつかの動画形式で Transferable として受け取る
//   2. 写真ライブラリから PHAsset として取り出す(iCloud からのダウンロード込み)
//      スローモーションなど複数の素材でできた動画は 1 本の .mov に書き出す
// iCloud にしかない大きな動画はダウンロードに時間がかかるので、進み具合を onProgress に渡し、
// 呼び出し側の Task がキャンセルされたらダウンロードも止める。
// =====================================================================

/// .movie 以外の形式でも受け取れる動画
struct PickedAnyMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .quickTimeMovie) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mov"))
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mp4"))
        }
        FileRepresentation(importedContentType: .video) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mov"))
        }
        FileRepresentation(importedContentType: .audiovisualContent) { received in
            PickedAnyMovie(url: try MovieImporter.copyIntoMedia(received.file, fallbackExtension: "mov"))
        }
    }
}

enum MovieImporterError: LocalizedError {
    case unsupported
    case noLibraryAccess
    /// 写真へのアクセスが「選択した写真のみ」で、この動画がその中に入っていない
    case limitedAccess
    /// 通信できず iCloud からダウンロードできなかった
    case networkUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "この動画は読み込めませんでした。写真アプリで動画を開き、iCloud から本体にダウンロードしてからもう一度お試しください。")
        case .noLibraryAccess:
            return String(localized: "写真ライブラリへのアクセスが許可されていません。設定アプリの「Video Mania」→「写真」で「フルアクセス」を選んでください。")
        case .limitedAccess:
            return String(localized: "この動画は、アクセスを許可した写真に含まれていないため読み込めませんでした。設定アプリの「Video Mania」→「写真」で「フルアクセス」を選ぶか、許可する写真にこの動画を追加してから、もう一度お試しください。")
        case .networkUnavailable:
            return String(localized: "iCloud から動画をダウンロードできませんでした。インターネットに接続してから、もう一度お試しください。")
        case .exportFailed(let detail):
            return String(localized: "動画の変換に失敗しました(\(detail))。")
        }
    }

    /// 写真へのアクセスの設定で直せるエラーか(「設定を開く」を出す)
    static func isPhotoAccessError(_ error: Error) -> Bool {
        switch error as? MovieImporterError {
        case .noLibraryAccess?, .limitedAccess?: return true
        default: return false
        }
    }
}

/// 写真の読み込み 1 回ぶん(iCloud からのダウンロードを含む)。
/// 結果とキャンセルのどちらが先に来ても続きは 1 回だけ再開し、キャンセルのときは読み込みも止める
/// (止めたあとに完了の知らせが来なくても待ち続けないように)
final class PhotoLoadRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var stopLoading: (() -> Void)?
    private var isCancelled = false

    /// start で読み込みを始め、止める処理を返す。結果は finish で渡す
    func run(_ start: () -> (() -> Void)) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let stop = start()
                lock.lock()
                let cancelledMeanwhile = isCancelled
                if !cancelledMeanwhile {
                    stopLoading = stop
                }
                lock.unlock()
                if cancelledMeanwhile {
                    stop()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        stopLoading = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let pending = continuation
        continuation = nil
        let stop = stopLoading
        stopLoading = nil
        lock.unlock()
        stop?()
        pending?.resume(throwing: CancellationError())
    }
}

enum MovieImporter {

    /// 受け取った一時ファイルをアプリ内の素材フォルダへコピーする
    static func copyIntoMedia(_ file: URL, fallbackExtension: String) throws -> URL {
        var name = file.lastPathComponent
        if (name as NSString).pathExtension.isEmpty {
            name += "." + fallbackExtension
        }
        let destination = MediaStore.uniqueDestination(forFileName: name)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// 読み込みの進み具合(0...1)を受け取る。メインスレッドで呼ばれる
    typealias ProgressHandler = @MainActor @Sendable (Double) -> Void

    /// PhotosPickerItem から動画を取り出し、アプリ内の素材フォルダの URL を返す。
    /// onProgress には iCloud からのダウンロードの進み具合が届く。Task がキャンセルされたら CancellationError を投げる
    static func importMovie(_ item: PhotosPickerItem, onProgress: ProgressHandler? = nil) async throws -> URL {
        // 1・2 が失敗した本当の理由(通信できないなら、ほかの方法でもダウンロードできないので先へ進まない)
        var lastError: Error?
        // 1. 既存の形式
        do {
            if let movie = try await load(PickedMovie.self, from: item, onProgress: onProgress) {
                return movie.url
            }
        } catch {
            try rethrowIfCancelled(error)
            lastError = error
        }
        // 2. ほかの動画形式
        if !isOfflineError(lastError) {
            do {
                if let movie = try await load(PickedAnyMovie.self, from: item, onProgress: onProgress) {
                    return movie.url
                }
            } catch {
                try rethrowIfCancelled(error)
                lastError = error
            }
        }
        if isOfflineError(lastError) {
            // 本当に通信できないときだけ。写真ライブラリから取り出しても同じなので、写真へのアクセスの許可も求めない
            throw MovieImporterError.networkUnavailable
        }
        // 3. 写真ライブラリから直接
        if let identifier = item.itemIdentifier {
            do {
                return try await importFromLibrary(localIdentifier: identifier, onProgress: onProgress)
            } catch {
                try rethrowIfCancelled(error)
                if isNetworkError(error) {
                    throw MovieImporterError.networkUnavailable
                }
                throw error
            }
        }
        throw lastError ?? MovieImporterError.unsupported
    }

    /// Transferable として受け取る。ダウンロードの進み具合を onProgress に渡し、キャンセルされたら読み込みも止める
    private static func load<T: Transferable>(_ type: T.Type, from item: PhotosPickerItem,
                                              onProgress: ProgressHandler?) async throws -> T? {
        try Task.checkCancellation()
        let request = PhotoLoadRequest<T?>()
        var watcher: Task<Void, Never>?
        defer { watcher?.cancel() }
        return try await request.run {
            let progress = item.loadTransferable(type: type) { result in
                request.finish(result)
            }
            if let onProgress {
                // 0.25 秒ごとに進み具合を伝える
                watcher = Task { @MainActor in
                    while !Task.isCancelled {
                        onProgress(progress.fractionCompleted)
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }
            return { progress.cancel() }
        }
    }

    /// キャンセルによる失敗なら CancellationError を投げ直す(ほかの方法を試さずにやめる)
    private static func rethrowIfCancelled(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// 通信できないための失敗か(下の階層のエラーもたどる)
    /// 通信に関係するエラーか(写真ライブラリから直接取り出したときの失敗の言い換えに使う)
    private static func isNetworkError(_ error: Error?) -> Bool {
        let networkCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                             .internationalRoamingOff, .dataNotAllowed]
        return containsError(error, urlCodes: networkCodes,
                             photosCodes: [PHPhotosError.Code.networkAccessRequired.rawValue, 3169])
    }

    /// 本当に通信できない状態か(1・2 の失敗のあと、写真ライブラリから直接取り出すのを諦めるかの判断に使う)。
    /// networkAccessRequired(3164)や時間切れは、iCloud にだけある動画で 1・2 が返すことがあり、
    /// 3 の写真ライブラリから(ネットワーク利用を許可して)ならダウンロードできるので含めない
    private static func isOfflineError(_ error: Error?) -> Bool {
        let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost,
                                             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                             .internationalRoamingOff, .dataNotAllowed]
        return containsError(error, urlCodes: offlineCodes, photosCodes: [3169])
    }

    /// error とその下のエラー(NSUnderlyingErrorKey)に、指定したコードのものがあるか
    private static func containsError(_ error: Error?, urlCodes: [URLError.Code], photosCodes: [Int]) -> Bool {
        var current: NSError? = error.map { $0 as NSError }
        var depth = 0
        while let ns = current, depth < 8 {
            if ns.domain == NSURLErrorDomain, urlCodes.contains(URLError.Code(rawValue: ns.code)) {
                return true
            }
            // PHPhotosError(networkAccessRequired = 3164、networkError = 3169)
            if ns.domain == PHPhotosError.errorDomain, photosCodes.contains(ns.code) {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    // MARK: - 写真ライブラリから

    private static func importFromLibrary(localIdentifier: String, onProgress: ProgressHandler?) async throws -> URL {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw MovieImporterError.noLibraryAccess
        }
        try Task.checkCancellation()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject, asset.mediaType == .video else {
            // 「選択した写真のみ」のときは、写真ピッカーで選んだ動画でも、許可した写真に入っていなければ見つからない
            if status == .limited, assets.firstObject == nil {
                throw MovieImporterError.limitedAccess
            }
            throw MovieImporterError.unsupported
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        let avAsset = try await requestAVAsset(forVideo: asset, options: options, onProgress: onProgress)
        try Task.checkCancellation()

        // 普通の動画ファイルならそのままコピー
        if let urlAsset = avAsset as? AVURLAsset {
            return try copyIntoMedia(urlAsset.url, fallbackExtension: "mov")
        }

        // スローモーションなど(AVComposition)は 1 本の .mov に書き出す
        let baseName = "Imported_\(UUID().uuidString.prefix(8)).mov"
        let destination = MediaStore.uniqueDestination(forFileName: baseName)
        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MovieImporterError.exportFailed(String(localized: "書き出しを開始できません"))
        }
        do {
            try await session.export(to: destination, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try rethrowIfCancelled(error)
            throw MovieImporterError.exportFailed(error.localizedDescription)
        }
        return destination
    }

    /// 写真ライブラリの動画を AVAsset として取り出す(iCloud からのダウンロード込み)。
    /// 進み具合を onProgress に渡し、Task がキャンセルされたら取り出しも止める
    static func requestAVAsset(forVideo asset: PHAsset, options: PHVideoRequestOptions,
                               onProgress: ProgressHandler?) async throws -> AVAsset {
        try Task.checkCancellation()
        if let onProgress {
            options.progressHandler = { fraction, _, _, _ in
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        }
        let request = PhotoLoadRequest<AVAsset>()
        return try await request.run {
            let manager = PHImageManager.default()
            let requestID = manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    request.finish(.success(avAsset))
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    request.finish(.failure(CancellationError()))
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    request.finish(.failure(error ?? MovieImporterError.unsupported))
                }
            }
            return { manager.cancelImageRequest(requestID) }
        }
    }
}
