import SwiftUI

@main
struct VideoEditorApp: App {
    init() {
        AppLifecycle.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
