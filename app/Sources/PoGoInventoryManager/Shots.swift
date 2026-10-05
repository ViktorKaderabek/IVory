#if DEBUG
import AppKit
import SwiftUI

/// README only: `IVORY_SHOTS=<folder> PoGoInventoryManager` opens the window with sample data (settings
/// aren't saved), goes through the states in light and dark appearance and captures the window with its shadow.
/// The app's own window can be captured even without screen recording permission.
/// IVORY_SHOTS_HEIGHT = window height (default 1085).
@MainActor
enum ShotSession {
    static let folder = ProcessInfo.processInfo.environment["IVORY_SHOTS"].map { URL(fileURLWithPath: $0) }
    static var isActive: Bool { folder != nil }
    static let settingsNote = Notification.Name("IVoryShotSettings")
    static let editorNote = Notification.Name("IVoryShotEditor")
    private static var started = false

    /// Default settings (no UDID or Team ID), PvP tags on, renaming off.
    static var demoConfig: AppConfig {
        var c = AppConfig()
        c.steps = Steps(duplicates: true, iv: true, pvp: true, rename: false, battle: false, weak: false)
        c.language = ProcessInfo.processInfo.environment["IVORY_SHOTS_LANG"] == "cs" ? .cs : .en
        // shots without the consent window; IVORY_SHOTS_CONSENT=1 captures the consent window
        c.consentVersion = ProcessInfo.processInfo.environment["IVORY_SHOTS_CONSENT"] == "1" ? 0 : Consent.version
        return c
    }

    static func start(runner: Runner, store: ConfigStore) {
        guard let folder, !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(folder: folder, runner: runner, store: store)
            NSApp.terminate(nil)
        }
    }

    private static func run(folder: URL, runner: Runner, store: ConfigStore) async {
        await pause(1.5)
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }) else {
            print("✖ okno nenalezeno")
            return
        }
        let defaults = UserDefaults.standard
        let savedSections = defaults.string(forKey: "settingsOpenSections")
        defaults.set(ProcessInfo.processInfo.environment["IVORY_SHOTS_SECTIONS"] ?? "pvp,rename", forKey: "settingsOpenSections")
        allowTallWindow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        let height = Double(ProcessInfo.processInfo.environment["IVORY_SHOTS_HEIGHT"] ?? "") ?? 1085
        let size = NSSize(width: 1040, height: height)

        for (name, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: look)

            store.config.steps = demoConfig.steps
            runner.applyPreview("none")
            place(win, size)
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            await pause(1.6)
            print("okno \(win.frame) obrazovka \(win.screen?.visibleFrame ?? .zero) aktivní \(NSApp.isActive) klíčové \(win.isKeyWindow)")
            shot([win], folder, "ready-\(name)")

            store.config.steps = Steps(duplicates: true, iv: true, pvp: true, rename: true, battle: true, weak: true)
            runner.applyPreview("running")
            await pause(1.6)
            shot([win], folder, "running-\(name)")

            runner.applyPreview("done")
            await pause(4.0)   // let the confetti finish
            shot([win], folder, "done-\(name)")

            place(win, NSSize(width: size.width + 400, height: size.height))
            NotificationCenter.default.post(name: settingsNote, object: true)
            await pause(1.2)
            shot([win], folder, "settings-\(name)")

            NotificationCenter.default.post(name: editorNote, object: true)
            await pause(1.2)
            if let sheet = win.attachedSheet { shot([sheet, win], folder, "editor-\(name)") }
            NotificationCenter.default.post(name: editorNote, object: false)
            await pause(0.8)
            NotificationCenter.default.post(name: settingsNote, object: false)
            await pause(0.8)
        }
        defaults.set(savedSections, forKey: "settingsOpenSections")
    }

    /// Lets the window be taller than the screen (otherwise macOS shrinks it and the bottom of the content
    /// isn't captured).
    private static func allowTallWindow(_ win: NSWindow) {
        let cls: AnyClass = type(of: win)
        let sel = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let keep: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(keep), method_getTypeEncoding(method))
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Puts the window in the top-left corner of the screen with the highest resolution (Retina = sharp shots);
    /// whatever doesn't fit extends below the screen (it is still captured whole).
    private static func place(_ win: NSWindow, _ size: NSSize) {
        let sharpest = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let screen = sharpest?.visibleFrame ?? win.screen?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.minX + 20, y: screen.maxY - size.height - 10)
        win.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func shot(_ windows: [NSWindow], _ folder: URL, _ name: String) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        guard let image = capture(windows.map { CGWindowID($0.windowNumber) }),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("✖ \(name)")
            return
        }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
        print("✔ \(name) \(image.width)×\(image.height)")
    }

    /// CGWindowListCreateImage(FromArray) is "obsoleted" in the new SDK but still works at runtime,
    /// so it's called via dlsym.
    private static func capture(_ ids: [CGWindowID]) -> CGImage? {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        let options = CGWindowImageOption.bestResolution.rawValue
        if ids.count == 1 {
            typealias Single = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
            return unsafeBitCast(sym, to: Single.self)(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                                       ids[0], options)?.takeRetainedValue()
        }
        typealias Many = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(handle, "CGWindowListCreateImageFromArray") else { return nil }
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil) else { return nil }
        return unsafeBitCast(sym, to: Many.self)(.null, array, options)?.takeRetainedValue()
    }
}
#endif
