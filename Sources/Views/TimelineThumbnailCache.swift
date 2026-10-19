import SwiftUI
import UIKit

// =====================================================================
// タイムライン用サムネイルのキャッシュ(クリップ URL + 元素材上の時刻 をキーにする)
// =====================================================================

final class TimelineThumbnailCache: @unchecked Sendable {
    static let shared = TimelineThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var failedKeys = Set<String>()

    /// ズーム段階に応じてサムネイル時刻を丸める刻み(秒)
    private static let quantizeSteps: [Double] = [0.25, 0.5, 1, 2, 4, 8, 15, 30, 60, 120, 300, 600]

    private init() {
        cache.countLimit = 800
    }

    static func key(url: URL, time: Double) -> String {
        let centis = time.isFinite ? Int((time * 100).rounded()) : 0
        return url.path + "#" + String(centis)
    }

    /// サムネイル 1 枚が表す元素材の長さ(tileSpan 秒)に合わせて時刻を丸める。
    /// 丸めることでズームを変えてもキャッシュが再利用されやすくなる。
    static func quantizedTime(_ seconds: Double, tileSpan: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        var step = 600.0
        for s in quantizeSteps where s >= tileSpan * 0.5 {
            step = s
            break
        }
        let rounded = (seconds / step).rounded() * step
        let upper = max(0, duration - 0.05)
        return min(max(0, rounded), upper)
    }

    func cachedImage(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func image(url: URL, time: Double) async -> UIImage? {
        let key = Self.key(url: url, time: time)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        let failed = lock.withLock { failedKeys.contains(key) }
        if failed { return nil }

        let image = await MediaStore.thumbnail(for: url, at: time, maxPixel: 180)
        if let image {
            cache.setObject(image, forKey: key as NSString)
        } else if !Task.isCancelled {
            lock.withLock {
                _ = failedKeys.insert(key)
            }
        }
        return image
    }
}

/// サムネイル 1 枚。読み込みは少し待ってから行う(高速スクロール中の無駄な生成を防ぐ)
struct TimelineThumbnailTile: View {
    let url: URL
    let time: Double
    let placeholder: UIImage?

    @State private var loaded: UIImage? = nil
    @State private var loadedKey: String = ""

    var body: some View {
        let key = TimelineThumbnailCache.key(url: url, time: time)
        let current: UIImage? = (loadedKey == key ? loaded : nil)
            ?? TimelineThumbnailCache.shared.cachedImage(forKey: key)
            ?? loaded
            ?? placeholder

        ZStack {
            if let current {
                Image(uiImage: current)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.22)
            }
        }
        .task(id: key) {
            if let hit = TimelineThumbnailCache.shared.cachedImage(forKey: key) {
                loaded = hit
                loadedKey = key
                return
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let image = await TimelineThumbnailCache.shared.image(url: url, time: time)
            if Task.isCancelled { return }
            if let image {
                loaded = image
                loadedKey = key
            }
        }
    }
}
