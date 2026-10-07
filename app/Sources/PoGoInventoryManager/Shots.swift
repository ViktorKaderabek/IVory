#if DEBUG
import AppKit
import SwiftUI

/// Appearance check and README pictures: one launch captures one state and quits.
///
///     IVORY_SHOTS=<folder> IVORY_SHOTS_NAME=run-ready IVORY_PREVIEW=none IVORY_STEP=rename …
///
/// What the state looks like is set by the same environment variables the normal appearance check uses
/// (IVORY_PREVIEW, IVORY_PAGE, IVORY_STEP, IVORY_DETAIL, IVORY_BANNER, IVORY_SHOTS_CONSENT); this file
/// only sizes the window, waits for the pictures to arrive and captures it with its shadow.
/// IVORY_SHOTS_LOOK = dark | light, IVORY_SHOTS_WIDTH / _HEIGHT = the window size (1280×900 as in the design),
/// IVORY_SHOTS_WAIT = how long to wait before the shot.
/// `scripts/design-shots.sh` runs through every state.
@MainActor
enum ShotSession {
    static let folder = ProcessInfo.processInfo.environment["IVORY_SHOTS"].map { URL(fileURLWithPath: $0) }
    static var isActive: Bool { folder != nil }
    /// Switches the screen before a shot (the appearance check uses it too).
    static let pageNote = Notification.Name("IVoryShotPage")
    static let settingsNote = Notification.Name("IVoryShotSettings")
    private static var started = false

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Sample settings: every step on, no UDID or Team ID, nothing is saved to disk.
    static var demoConfig: AppConfig {
        var c = AppConfig()
        c.steps = Steps(duplicates: true, iv: true, pvp: true, rename: true, battle: true, weak: true)
        c.language = env["IVORY_SHOTS_LANG"] == "cs" ? .cs : .en
        c.consentVersion = env["IVORY_SHOTS_CONSENT"] == "1" ? 0 : Consent.version
        c.setupDone = env["IVORY_SHOTS_SETUP_DONE"] == "1"          // the guide reopened later: it has Close
        return c
    }

    static func start(runner: Runner, store: ConfigStore) {
        guard let folder, !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(folder: folder)
            NSApp.terminate(nil)
        }
    }

    private static func run(folder: URL) async {
        NSApp.appearance = NSAppearance(named: env["IVORY_SHOTS_LOOK"] == "light" ? .aqua : .darkAqua)
        await pause(0.6)
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }) else {
            print("✖ window not found")
            return
        }
        allowTallWindow(win)
        place(win, NSSize(width: Double(env["IVORY_SHOTS_WIDTH"] ?? "") ?? 1280,
                          height: Double(env["IVORY_SHOTS_HEIGHT"] ?? "") ?? 900))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        await pause(Double(env["IVORY_SHOTS_WAIT"] ?? "") ?? 3.0)   // the pictures download the first time round
        shot([win], folder, env["IVORY_SHOTS_NAME"] ?? "shot")
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
