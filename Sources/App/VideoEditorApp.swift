import SwiftUI

@main
struct VideoEditorApp: App {
    init() {
        AppLifecycle.shared.start()
        // フィルタの LUT をバックグラウンドで先に作っておく(初回表示のもたつき防止)
        Task.detached(priority: .utility) { FilterLUT.prewarm() }
        // 読み込んだフォント(.ttf / .otf)を起動時に登録する
        Task.detached(priority: .utility) { MediaTools.registerStoredFonts() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
