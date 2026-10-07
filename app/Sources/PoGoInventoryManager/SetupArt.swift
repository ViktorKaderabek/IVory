import AppKit
import SwiftUI

/// The setup guide's own colours (the `--w-*` tokens of "Setup Guide"). Dark is the app's palette; the
/// light one is the design's, a touch softer than the main window's.
enum SW {
    private static func pair(_ dark: NSColor, _ light: NSColor) -> Color { .adaptive(dark: dark, light: light) }

    static let bg = pair(.oklch(0.175, 0.026, 278), .oklch(0.955, 0.007, 280))
    static let chrome = pair(.oklch(0.155, 0.024, 278), .oklch(0.925, 0.01, 280))
    static let surface = pair(.oklch(0.205, 0.028, 278), .oklch(0.985, 0.004, 280))
    static let raise = pair(.oklch(0.24, 0.027, 280), .oklch(0.925, 0.009, 280))
    static let hover = pair(.oklch(0.235, 0.027, 280), .oklch(0.9, 0.011, 280))
    static let input = pair(.oklch(0.183, 0.027, 278), .oklch(0.97, 0.01, 290))
    static let text = pair(.oklch(0.96, 0.008, 280), .oklch(0.16, 0.025, 278))
    static let muted = pair(.oklch(0.67, 0.02, 280), .oklch(0.42, 0.024, 280))
    static let border = pair(NSColor.white.withAlphaComponent(0.09), .oklch(0.16, 0.025, 278, alpha: 0.13))
    static let track = pair(.oklch(0.29, 0.026, 280), .oklch(0.87, 0.012, 280))
    static let accent = pair(.oklch(0.70, 0.16, 290), .oklch(0.58, 0.19, 290))
    static let ink = pair(.oklch(0.82, 0.10, 290), .oklch(0.50, 0.19, 290))
    static let onAccent = pair(.oklch(0.16, 0.025, 278), .oklch(0.975, 0.006, 280))
    static let tint = pair(.oklch(0.30, 0.09, 290), .oklch(0.91, 0.05, 290))
    static let green = pair(.oklch(0.8, 0.15, 152), .oklch(0.52, 0.13, 152))
    static let greenTint = pair(.oklch(0.32, 0.06, 152), .oklch(0.93, 0.04, 152))
    static let orange = pair(.oklch(0.8, 0.13, 65), .oklch(0.58, 0.14, 55))
    static let orangeTint = pair(.oklch(0.33, 0.06, 65), .oklch(0.94, 0.04, 65))
    static let red = pair(.oklch(0.74, 0.16, 22), .oklch(0.55, 0.18, 22))
    static let redTint = pair(.oklch(0.32, 0.08, 22), .oklch(0.93, 0.04, 22))
    static let shadow = pair(NSColor.black.withAlphaComponent(0.5), .oklch(0.3, 0.05, 280, alpha: 0.22))

    /// The phone itself: the same near-black body in both looks.
    static let phoneBody = Color.oklch(0.14, 0.02, 278)
    static let phoneScreen = Color.oklch(0.2, 0.02, 278)

    /// The band of the window's own title bar (the traffic lights), which stays opaque over the content.
    static let titleBar: CGFloat = 28

    /// The design's one curve, cubic-bezier(.2,.8,.2,1).
    static func ease(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
}

// MARK: - the screenshots

/// The iPhone screenshots of the guide, the files of the design: `setup/<name>.png` in English and
/// `setup/cs/<name>.png` in Czech, in the app's Resources (app/Resources/setup in the repo).
enum SetupArt: String {
    case allowAccessory = "allow-accessory"
    case trustComputer = "trust-computer"
    case privacy
    case devmodeTurnOn = "devmode-turnon"
    case restart
    case settingsDeveloper = "settings-developer"
    case uiAutomation = "ui-automation"
    case appleCode = "apple-code"
    case homeBlur = "home-blur"
    case helperApp = "helper-app"
    case trustDeveloper = "trust-developer"
    case trustDialog = "trust-dialog"
    case openPogo = "open-pogo"

    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor private static var missing: Set<String> = []

    @MainActor var image: NSImage? {
        let key = "\(L10n.lang.rawValue)/\(rawValue)"
        if let hit = Self.cache[key] { return hit }
        if Self.missing.contains(key) { return nil }
        let names = L10n.lang == .cs ? ["cs/\(rawValue)", rawValue] : [rawValue]
        for dir in Self.folders {
            for name in names {
                if let img = NSImage(contentsOf: dir.appendingPathComponent("\(name).png")) {
                    Self.cache[key] = img
                    return img
                }
            }
        }
        Self.missing.insert(key)
        return nil
    }

    private static var folders: [URL] {
        var list: [URL] = []
        if let res = Bundle.main.resourceURL { list.append(res.appendingPathComponent("setup")) }
        #if DEBUG
        // a debug build runs out of .build/, next to the sources
        list.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/setup").standardized)
        #endif
        return list
    }
}
