import SwiftUI

@main
struct ZenLiteApp: App {
    @StateObject private var store = BrowserStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(store)
        }
        .onChange(of: phase) { newPhase in
            // In the background, keep only what's on screen so iOS is less
            // likely to kill the app.
            if newPhase == .background {
                store.save()
                store.enforceLimits(aggressive: true)
            }
        }
    }
}
