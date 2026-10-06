#if DEBUG
import AppKit
import SwiftUI

/// A stopwatch for the window's own redraws, so "it feels sticky" can be turned into a number.
///
///     IVORY_PERF=1 IVORY_PERF_PAGES=run                 # only Run is built
///     IVORY_PERF=1 IVORY_PERF_PAGES=run,storage,raids,pvp,powerups,settings
///
/// It changes one tiny setting over and over (which every screen observes through ConfigStore), flushes
/// the layer tree and prints how long a single update takes. The difference between the two runs is the
/// price of keeping the screens you are not looking at in the window.
@MainActor
enum Perf {
    static var isActive: Bool { ProcessInfo.processInfo.environment["IVORY_PERF"] != nil }

    static var pages: [Page] {
        (ProcessInfo.processInfo.environment["IVORY_PERF_PAGES"] ?? "run")
            .split(separator: ",").compactMap { Page(rawValue: String($0)) }
    }

    private static var started = false

    static func start(store: ConfigStore) {
        guard isActive, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            measure(store: store)
            NSApp.terminate(nil)
        }
    }

    private static func measure(store: ConfigStore) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else {
            print("✖ no window")
            return
        }
        // IVORY_PERF_NOOP=1 changes nothing, so the number is the cost of the forced redraw alone
        let noop = ProcessInfo.processInfo.environment["IVORY_PERF_NOOP"] == "1"
        var samples: [Double] = []
        for i in 0..<80 {
            let t = CFAbsoluteTimeGetCurrent()
            if !noop { store.config.keepBest = 1 + (i % 2) }   // every screen observes ConfigStore
            CATransaction.flush()
            win.contentView?.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        let warm = samples.dropFirst(20).sorted()
        let mean = warm.reduce(0, +) / Double(warm.count)
        print(String(format: "⏱ %@ · %d screens · mean %.2f ms · median %.2f ms · worst %.2f ms",
                     Perf.pages.map(\.rawValue).joined(separator: "+"), Perf.pages.count,
                     mean, warm[warm.count / 2], warm.last ?? 0))
    }
}
#endif
