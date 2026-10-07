import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-icon"), i + 1 < args.count {
            let code = MainActor.assumeIsolated { IconExport.run(to: args[i + 1]) }
            exit(code)
        }
        #if DEBUG
        if args.contains("--battle-dump") {
            MainActor.assumeIsolated { BattleStore.shared.dump() }
            exit(0)
        }
        #endif
        IVoryApp.main()
    }
}

struct IVoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConfigStore.launch()
    @StateObject private var runner = Runner.shared

    var body: some Scene {
        WindowGroup(Theme.appName) {
            MainView()
                .environmentObject(store)
                .environmentObject(runner)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1040, height: 900)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // If the app quits during a run, the bot shuts down cleanly (it saves the results).
        MainActor.assumeIsolated {
            Runner.shared.terminateNow()
            SetupFlow.shared.terminate()
        }
    }
}
