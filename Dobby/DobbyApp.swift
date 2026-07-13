import SwiftUI

@main
struct DobbyApp: App {
    @StateObject private var playback = PlaybackCoordinator()
    @StateObject private var offline = OfflineStore()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playback)
                .environmentObject(offline)
                .ignoresSafeArea()
        }
        #if os(macOS)
        // Standard title bar: hiddenTitleBar left no draggable region (the web view
        // fills the window and eats mouse events), so the window couldn't be moved.
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}

#if os(iOS)
import UIKit

/// Stores the system completion handler iOS hands us when it relaunches the app to
/// finish background offline downloads; OfflineStore calls it once events drain.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == OfflineStore.bgSessionID {
            OfflineStore.backgroundCompletion = completionHandler
        } else {
            completionHandler()
        }
    }
}
#endif
