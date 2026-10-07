import AppKit
import SwiftUI

/// The app's main window: the sidebar on the left, the chosen screen on the right, and the consent
/// overlay over everything on the first start. Only the screen in front is in the window – see `pages`.
struct MainView: View {
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = Page.run
    @State private var window = WindowRef()
    @State private var fresh = false
    @State private var confettiStart: Date?
    /// Consent window: decided at launch (revoking consent in Settings takes effect from the next launch).
    @State private var askConsent: Bool?
    @ObservedObject private var setup = SetupFlow.shared

    private var showConsent: Bool { askConsent ?? true }
    private var showSetup: Bool { setup.isOpen }

    /// Minimum width of the screen next to the sidebar.
    private static let contentMinWidth: CGFloat = 1000
    /// The window has no title bar of its own, but the traffic lights still need their band.
    private static let titleBar: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
            pages
        }
        .background(Theme.bg)
        .clipped()
        .disabled(showConsent || showSetup)
        .overlay {
            // After the notice, the setup guide: the main window can't be used until it's done.
            if showSetup && !showConsent {
                SetupOverlay().transition(.opacity)
            }
        }
        .overlay {
            // On the first start the notice covers the window instead of sitting in a dialog over it.
            if showConsent {
                ConsentOverlay {
                    withAnimation(.easeOut(duration: 0.25)) { askConsent = false }
                    SetupFlow.shared.appLaunched()
                }
                .transition(.opacity)
            }
        }
        .background { ConfigWatcher() }
        .alert(tr("iPhone se nepodařilo ovládat", "IVory couldn’t control your iPhone"), isPresented: $setup.askGuide) {
            Button(tr("Projít průvodce", "Go through the guide")) { setup.rerun() }
            Button(tr("Teď ne", "Not now"), role: .cancel) {}
        } message: {
            Text(tr("Na iPhonu se možná něco změnilo. Chceš znovu projít průvodce nastavením? Povede tě krok po kroku, co funguje, přeskočí sám.",
                    "Something on your iPhone may have changed. Go through the setup guide again? It takes you step by step and skips what already works."))
        }
        .onAppear {
            guard let store = ConfigStore.current else { return }
            #if DEBUG
            if Perf.isActive { Perf.start(store: store) }
            #endif
            if askConsent == nil { askConsent = !Consent.isGiven(store.config) }
            if askConsent == false { SetupFlow.shared.appLaunched() }
            Updater.shared.start { store.config.checkUpdates }
            StatsStore.shared.refresh(removeTag: store.config.removeTag)   // so Storage is ready right away
            BattleStore.shared.appear()       // the game data and bosses (Battle tags, new boss notifications)
            BossAlerts.enabled = store.config.battle.notifyBosses
            BossAlerts.setUp()
        }
        .onChange(of: runner.finishedAt) { _, _ in
            StatsStore.shared.refresh(removeTag: ConfigStore.current?.config.removeTag ?? "Removable")
            // the run reached the phone but never got to control it: the guide is what fixes that
            if runner.outcome == .failed, !runner.connected, runner.fatalHelp != nil || runner.reachedPhone {
                SetupFlow.shared.runFailedOnPhone()
            }
        }
        .onReceive(StatsStore.shared.$stats) { BattleStore.shared.buildTeams($0?.mons ?? []) }
        .onReceive(NotificationCenter.default.publisher(for: BossAlerts.openNote)) { note in
            BattleStore.shared.focusBoss = note.object as? String
            showPage(.raids)
        }
        .foregroundStyle(Theme.text)
        .frame(minWidth: Sidebar.width + Self.contentMinWidth, minHeight: 660)
        .background(WindowReader(ref: window))
        .overlay {
            if let confettiStart {
                ConfettiView(start: confettiStart)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: runner.finishedAt) { _, end in
            guard let end, runner.outcome == .done, !reduceMotion else { return }
            confettiStart = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                if confettiStart == end { confettiStart = nil }
            }
        }
        .onChange(of: window.window) { _, win in chromeless(win) }
        .ignoresSafeArea(.container, edges: .top)
        #if DEBUG
        .onAppear(perform: applyPreview)
        .onReceive(NotificationCenter.default.publisher(for: ShotSession.pageNote)) { note in
            if let id = note.object as? String, let target = Page(rawValue: id) { showPage(target) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShotSession.settingsNote)) { note in
            showPage(((note.object as? Bool) ?? false) ? .settings : .run)
        }
        #endif
    }

    /// The window has no title bar of its own – the sidebar runs the whole height and the traffic lights
    /// sit on it, as in the design.
    private func chromeless(_ win: NSWindow?) {
        guard let win else { return }
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.styleMask.insert(.fullSizeContentView)
        win.backgroundColor = NSColor(Theme.bg)
    }

    /// Only the screen in front is in the window. Keeping all six there meant every change to the settings
    /// redrew the ones nobody was looking at as well. What a screen has to remember between visits lives in
    /// its own object (see ScreenState), not in its views.
    @ViewBuilder
    private var pages: some View {
        ZStack(alignment: .top) {
            switch page {
            case .run: pageView(.run) { RunScreen(fresh: $fresh) }
            case .storage: pageView(.storage) { StorageScreen(startRun: startFromStats) }
            case .raids: pageView(.raids) { RaidsScreen(startRun: startFromStats) }
            case .pvp: pageView(.pvp) { PvPScreen(startRun: startFromStats) }
            case .powerups: pageView(.powerups) { PowerUpsScreen(startRun: startFromStats) }
            case .settings: pageView(.settings) { SettingsScreen() }
            }
        }
        .id(page)
        .transition(.asymmetric(insertion: .modifier(active: PageIn(y: 8, opacity: 0),
                                                     identity: PageIn(y: 0, opacity: 1)),
                                removal: .opacity))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { StatsSheetHost(active: page == .storage, startRun: startFromStats) }
        .overlay { PowerUpDetailHost(active: page == .powerups) }
        .overlay { MonDetailHost(active: page == .storage) }
        .overlay { RenameEditorHost() }
    }

    /// From a screen's empty state: back to Run and start a run with the steps selected there.
    private func startFromStats() {
        showPage(.run)
        guard !runner.isRunning, let store = ConfigStore.current else { return }
        SetupFlow.shared.beforeStart {
            store.prepareRun()
            runner.start(steps: store.config.steps, fresh: false)
        }
    }

    #if DEBUG
    /// Appearance check: IVORY_PREVIEW=state, IVORY_SETTINGS=1, IVORY_STEPS=duplicates,iv,pvp,rename,
    /// IVORY_PAGE=storage|raids, IVORY_CONFETTI=1. README screenshots: IVORY_SHOTS=folder (see Shots.swift).
    private func applyPreview() {
        let env = ProcessInfo.processInfo.environment
        guard let store = ConfigStore.current,
              let state = env["IVORY_PREVIEW"] ?? (ShotSession.isActive ? "none" : nil) else { return }
        defer { if ShotSession.isActive { ShotSession.start(runner: runner, store: store) } }
        runner.applyPreview(state)
        if let raw = env["IVORY_STEPS"] {
            let on = Set(raw.split(separator: ","))
            store.config.steps = Steps(duplicates: on.contains("duplicates"), iv: on.contains("iv"),
                                       pvp: on.contains("pvp"), rename: on.contains("rename"), battle: on.contains("battle"),
                                       weak: on.contains("weak"))
        }
        // the old names still work, so existing notes and scripts don't break
        switch env["IVORY_PAGE"] {
        case "storage", "stats": page = .storage
        case "raids", "battle": page = .raids
        case "pvp": page = .pvp
        case "powerups": page = .powerups
        case "settings": page = .settings
        default: break
        }
        if env["IVORY_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPage(.settings) }
        }
        if state == "done" && env["IVORY_CONFETTI"] == "1" { confettiStart = Date() }
    }
    #endif

    private func showPage(_ new: Page) {
        guard new != page else { return }
        withAnimation(.design(0.28)) { page = new }
    }

    /// A screen with its own scrolling. Switching is blended by Crossfade, so the rebuild never shows.
    private func pageView<Content: View>(_ which: Page, @ViewBuilder content: () -> Content) -> some View {
        // Run starts a touch higher than the rest, as in the design; on top of that every screen clears the
        // window's title bar, so the first heading is level with the app name in the rail.
        let top: CGFloat = (which == .run ? 24 : 28) + Self.titleBar
        return ScrollView {
            content()
                .padding(EdgeInsets(top: top, leading: 28, bottom: 40, trailing: 28))
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Language switch

/// Crossfades the whole window via Core Animation: the change is applied at once (one SwiftUI pass) and the
/// system blends the old image into the new one. A SwiftUI animation would recompute the window on every frame instead.
@MainActor
enum Crossfade {
    static func run(in window: NSWindow? = nil, duration: Double = 0.22, _ change: () -> Void) {
        let win = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let layer = (win?.contentView?.superview ?? win?.contentView)?.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "crossfade")
        }
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain, change)
    }
}

/// Language change: the texts are rewritten in place (see L10n) and the old ones crossfade into the new ones.
@MainActor
enum LanguageSwitch {
    static func change(to lang: AppLanguage, store: ConfigStore) {
        guard lang != store.config.language else { return }
        Crossfade.run(duration: 0.25) { store.config.language = lang }
    }
}

/// Reference to the window the view is in (for widening the window when the settings open).
final class WindowRef {
    weak var window: NSWindow?
}

struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.ref = ref
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var ref: WindowRef?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref?.window = window
        }
    }
}

/// Watches the settings for the two things the whole app cares about, so `MainView` itself does not have to
/// observe them – it would redraw the rail and the screen on every keystroke in a tag name.
private struct ConfigWatcher: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: store.config.battle.notifyBosses) { _, on in BossAlerts.enabled = on }
            .onChange(of: store.config.language) { _, lang in L10n.lang = lang }
    }
}

/// How a screen arrives: it fades in and settles upwards a little.
struct PageIn: ViewModifier {
    let y: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: y).opacity(opacity)
    }
}
