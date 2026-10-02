import AppKit
import SwiftUI

@main
struct PoGoInventoryManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConfigStore()
    @StateObject private var runner = Runner.shared

    var body: some Scene {
        WindowGroup("PoGo Inventory Manager") {
            RootView()
                .environmentObject(store)
                .environmentObject(runner)
                .frame(minWidth: 900, minHeight: 640)
                .tint(Theme.teal)
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Když se aplikace zavře během běhu, bot se korektně ukončí (uloží výsledky).
        MainActor.assumeIsolated {
            Runner.shared.terminateNow()
        }
    }
}
