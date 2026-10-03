import AppKit
import SwiftUI

/// The app's main window: the Overview and Stats screens (switched in the toolbar) and the consent overlay.
/// The settings slide in from the right (Settings button in the toolbar).
struct MainView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settingsWidth") private var settingsWidth = 400.0
    @State private var settingsOpen = false
    @State private var page = Page.overview
    /// Stats are built once (shortly after launch) and then kept; they are only hidden.
    @State private var statsBuilt = false
    /// The panel is slid out (only its offset is animated).
    @State private var panelShown = false
    /// While the panel slides, the main content has a fixed width so it isn't re-laid out on every frame.
    @State private var frozenMainWidth: CGFloat?
    @State private var panelGeneration = 0
    @State private var minLocked = false
    @State private var grownBy: CGFloat = 0
    @State private var dragStartWidth: Double?
    @State private var window = WindowRef()
    @State private var fresh = false
    @State private var confettiStart: Date?
    /// Consent window: decided at launch (revoking consent in Settings takes effect from the next launch).
    @State private var askConsent: Bool?

    private var showConsent: Bool { askConsent ?? !Consent.isGiven(store.config) }

    /// The screen in the main part of the window (switched in the toolbar).
    enum Page { case overview, stats }

    /// Minimum width of the main content; below it the cards get squeezed.
    private static let mainMinWidth: CGFloat = 720
    private static let panelAnimation = 0.32

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .top) {
                pageView(.overview) { MainColumn(fresh: $fresh) }
                if statsBuilt {
                    pageView(.stats) { StatsView(startRun: startFromStats) }
                }
            }
            .frame(width: frozenMainWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay { StatsSheetHost(active: page == .stats, startRun: startFromStats) }   // over the page, not scrolled with it
            .padding(.trailing, frozenMainWidth == nil && settingsOpen ? settingsWidth : 0)

            settingsPanel
        }
        .background(Theme.bg)
        .clipped()
        .disabled(showConsent)
        .modifier(BlurWhen(on: showConsent))
        .overlay {
            if showConsent {
                ConsentOverlay { withAnimation(.easeOut(duration: 0.25)) { askConsent = false } }
                    .transition(.opacity)
            }
        }
        .onAppear {
            if askConsent == nil { askConsent = !Consent.isGiven(store.config) }
            Updater.shared.start { [store] in store.config.checkUpdates }
            StatsStore.shared.refresh(removeTag: store.config.removeTag)   // so Stats are ready right away
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { statsBuilt = true }
        }
        .onChange(of: runner.finishedAt) { _, _ in StatsStore.shared.refresh(removeTag: store.config.removeTag) }
        .foregroundStyle(Theme.text)
        .frame(minWidth: Self.mainMinWidth + (minLocked ? settingsWidth : 0), minHeight: 660)
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
        .toolbar { toolbarContent }
        .toolbarBackground(Theme.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        #if DEBUG
        .onAppear(perform: applyPreview)
        .onReceive(NotificationCenter.default.publisher(for: ShotSession.settingsNote)) { note in
            setSettings((note.object as? Bool) ?? false)
        }
        #endif
    }

    /// From the Stats screen (empty state, coverage window): back to the overview and start a run with the steps
    /// selected there.
    private func startFromStats() {
        showPage(.overview)
        guard !runner.isRunning else { return }
        store.save()
        runner.start(steps: store.config.steps, fresh: false)
    }

    #if DEBUG
    /// Appearance check: IVORY_PREVIEW=state, IVORY_SETTINGS=1, IVORY_STEPS=duplicates,iv,pvp,rename,
    /// IVORY_PAGE=stats, IVORY_CONFETTI=1. README screenshots: IVORY_SHOTS=folder (see Shots.swift).
    private func applyPreview() {
        if ShotSession.isActive { return ShotSession.start(runner: runner, store: store) }
        let env = ProcessInfo.processInfo.environment
        guard let state = env["IVORY_PREVIEW"] else { return }
        runner.applyPreview(state)
        if let raw = env["IVORY_STEPS"] {
            let on = Set(raw.split(separator: ","))
            store.config.steps = Steps(duplicates: on.contains("duplicates"), iv: on.contains("iv"),
                                       pvp: on.contains("pvp"), rename: on.contains("rename"))
        }
        if env["IVORY_PAGE"] == "stats" { statsBuilt = true; page = .stats }
        if env["IVORY_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { setSettings(true) }
        }
        if state == "done" && env["IVORY_CONFETTI"] == "1" { confettiStart = Date() }
    }
    #endif

    // MARK: - Settings side panel

    /// The panel has a fixed width and just slides in from the right (only the offset animates, nothing is re-laid out).
    private var settingsPanel: some View {
        SettingsInspector()
            .frame(width: settingsWidth)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            .overlay(alignment: .leading) { resizeHandle }
            .offset(x: panelShown ? 0 : settingsWidth + 1)
            .allowsHitTesting(settingsOpen)
            .accessibilityHidden(!settingsOpen)
    }

    /// The panel edge can be dragged (width 360–520 points).
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? settingsWidth
                        dragStartWidth = start
                        let width = min(520, max(360, start - value.translation.width))
                        settingsWidth = width
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    /// Opens/closes the settings. If there wouldn't be enough room left for the content, the window smoothly
    /// widens by the missing amount (and narrows again on close), so the cards don't get squeezed.
    /// The main content is re-laid out to the new width only once, right at the start (blended by Crossfade),
    /// and keeps a fixed width during the animation – the panel just slides over it. Previously the content
    /// narrowed frame by frame and every frame re-laid out the whole window (it looked like 5 frames per second).
    private func setSettings(_ open: Bool) {
        let duration = Self.panelAnimation
        guard open != settingsOpen else { return }
        panelGeneration += 1
        let generation = panelGeneration
        let panel = CGFloat(settingsWidth)

        var targetFrame: NSRect?
        var finalMain: CGFloat?
        if let win = window.window {
            let content = win.contentLayoutRect.width
            if open {
                var grow = max(0, Self.mainMinWidth + panel - content)
                var frame = win.frame
                if let screen = win.screen?.visibleFrame {
                    grow = min(grow, max(0, screen.width - frame.width))
                    frame.size.width += grow
                    if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
                } else {
                    frame.size.width += grow
                }
                grownBy = grow
                if grow > 0 { targetFrame = frame }
                finalMain = content + grow - panel
            } else {
                var frame = win.frame
                frame.size.width = max(Self.mainMinWidth, frame.width - grownBy)
                if grownBy > 0 { targetFrame = frame }
                finalMain = content - (win.frame.width - frame.width)
                grownBy = 0
            }
        }

        if !open { minLocked = false }
        Crossfade.run(in: window.window, duration: 0.2) {
            frozenMainWidth = finalMain
            settingsOpen = open
        }
        withAnimation(.easeInOut(duration: duration)) { panelShown = open }
        if let win = window.window, let targetFrame { animateWindow(win, to: targetFrame, duration: duration) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            guard generation == panelGeneration else { return }
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain) { frozenMainWidth = nil }   // the layout is already final, nothing moves
            if open { minLocked = true }
        }
    }

    private func showPage(_ new: Page) {
        guard new != page else { return }
        if new == .stats { statsBuilt = true }
        Crossfade.run(in: window.window) { page = new }
    }

    /// A screen with its own scrolling. Both stay built, only the visibility switches (blended by
    /// Crossfade) – previously every switch threw one away and rebuilt the other, and that stuttered.
    private func pageView<Content: View>(_ which: Page, @ViewBuilder content: () -> Content) -> some View {
        let shown = page == which
        return ScrollView {
            content()
                .padding(EdgeInsets(top: 22, leading: 28, bottom: 26, trailing: 28))
                .frame(maxWidth: .infinity)
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .environment(\.pageActive, shown)
        .zIndex(shown ? 1 : 0)
    }

    private func animateWindow(_ win: NSWindow, to frame: NSRect, duration: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // no glass "capsule" around the toolbar items, as in the design; a flexible spacer pushes
            // the buttons to the right (otherwise macOS 26 puts them right after the title)
            ToolbarItem(placement: .navigation) { titleItem }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) { actionItems }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { titleItem }
            ToolbarItem(placement: .automatic) { actionItems }
        }
    }

    private var titleItem: some View {
        HStack(spacing: 8) {
            AppIconView().frame(width: 26, height: 26)
            Text(Theme.appName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(.leading, 8)
    }

    private var actionItems: some View {
        HStack(spacing: 4) {
            Button { showPage(.overview) } label: {
                Label(tr("Přehled", "Overview"), systemImage: "house")
            }
            .buttonStyle(HeaderButtonStyle(active: page == .overview))
            .help(tr("Třídění a jeho průběh", "Sorting and its progress"))
            Button { showPage(.stats) } label: {
                Label(tr("Statistiky", "Stats"), systemImage: "chart.bar")
            }
            .buttonStyle(HeaderButtonStyle(active: page == .stats))
            .help(tr("Co IVory ví o tvém inventáři", "What IVory knows about your storage"))
            Button { runner.openResults() } label: {
                Label(tr("Výsledky", "Results"), systemImage: "folder")
            }
            .buttonStyle(HeaderButtonStyle(active: false))
            .help(tr("Složka s výsledky a screenshoty", "Folder with results and screenshots"))
            Button {
                setSettings(!settingsOpen)
            } label: {
                Label(tr("Nastavení", "Settings"), systemImage: "gearshape")
            }
            .buttonStyle(HeaderButtonStyle(active: settingsOpen))
            .help(tr("Nastavení", "Settings"))
        }
        .disabled(showConsent)
    }
}

/// The Overview screen: hero card, steps, phases, tiles, tags panel and log.
struct MainColumn: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Binding var fresh: Bool
    @State private var copied = false
    @State private var lastBox = LastBox.load()
    @ObservedObject private var updater = Updater.shared

    private var steps: Steps { store.config.steps }

    var body: some View {
        VStack(spacing: 18) {
            UpdateBanner()
            HeroCard(steps: steps, fresh: $fresh)
            stepsRow
            PhasePanel(steps: steps)
            tiles
            HStack(alignment: .top, spacing: 14) {
                TagsPanel().frame(maxWidth: .infinity)
                logSection.frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: updater.state)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: updater.bannerHidden)
        .onChange(of: runner.finishedAt) { _, _ in lastBox = LastBox.load() }
    }

    // MARK: - Steps

    /// Four cards side by side; when space is tight (e.g. with the settings open), two by two.
    private var stepsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(Runner.Step.allCases) { stepCard($0) }
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { stepCard(.duplicates); stepCard(.iv) }
                GridRow { stepCard(.pvp); stepCard(.rename) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(runner.isRunning)
        .opacity(runner.isRunning ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: runner.isRunning)
    }

    private func stepCard(_ step: Runner.Step) -> some View {
        let on = step.isOn(steps)
        return StepCard(step: step, detail: detail(step), isOn: on, locked: on && steps.count == 1) {
            guard !(on && steps.count == 1) else { NSSound.beep(); return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                step.set(&store.config.steps, !on)
            }
        }
        // ViewThatFits compares ideal widths: below ~200 points per card the text wraps word by word
        .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ step: Runner.Step) -> String {
        let c = store.config
        switch step {
        case .duplicates: return tr("Horší duplicity označí tagem \(c.removeTag).", "Tags worse duplicates with \(c.removeTag).")
        case .iv:
            let n = c.ivTags.filter { !$0.name.isEmpty }.count
            return tr("Roztřídí inventář do \(n) IV tagů.", "Sorts your storage into \(n) IV tags.")
        case .pvp: return tr("Kusům s dobrým pořadím dá tag ligy.", "Gives the league tag to Pokémon with a good rank.")
        case .rename:
            let range = pctRange(c.rename.min, c.rename.max)

            if let box = lastBox, box.count(in: c.rename.min...c.rename.max) == 0 {
                return tr("V rozsahu \(range) nejsou žádné kusy.", "No Pokémon in the \(range) range.")
            }
            return tr("Kusům s IV \(range) dá jméno podle šablony.", "Names Pokémon with IV \(range) by your template.")
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        let c = store.config
        let counts = runner.tagCounts
        let ivNames = Set(c.ivTags.map(\.name))
        let leagueNames = Set(c.pvp.all.map(\.league.name))
        let ivSum = counts.filter { ivNames.contains($0.key) }.values.reduce(0, +)
        let pvpSum = counts.filter { leagueNames.contains($0.key) }.values.reduce(0, +)
        return HStack(spacing: 12) {
            StatTile(symbol: "gauge.with.dots.needle.67percent", title: tr("Změřeno IV", "IV measured"), value: runner.stats.measured,
                     color: Theme.blue, tint: Theme.blueTint)
            StatTile(symbol: "arrow.3.trianglepath", title: c.removeTag, value: counts[c.removeTag] ?? runner.stats.removable,
                     color: Theme.orange, tint: Theme.orangeTint)
            StatTile(symbol: "tag", title: tr("IV tagy", "IV tags"), value: ivSum > 0 ? ivSum : runner.stats.ivTagged,
                     color: Theme.teal, tint: Theme.tealTint)
            StatTile(symbol: "trophy", title: tr("PvP tagy", "PvP tags"), value: pvpSum > 0 ? pvpSum : runner.stats.pvpTagged,
                     color: Theme.green, tint: Theme.greenTint)
            StatTile(symbol: "pencil.line", title: tr("Přejmenováno", "Renamed"), value: runner.stats.renamed,
                     color: Theme.yellow, tint: Theme.yellowTint)
            StatTile(symbol: "arrow.uturn.backward", title: tr("Vyřešené chyby", "Recovered errors"), value: runner.stats.errors,
                     color: Theme.pink, tint: Theme.pinkTint)
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tr("Podrobnosti", "Details")).font(.system(size: 15, weight: .semibold))
                Text(runner.lines.count.formatted())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Theme.raise, in: Capsule())
                    .contentTransition(.numericText(value: Double(runner.lines.count)))
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runner.logText, forType: .string)
                        withAnimation(.snappy) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation(.snappy) { copied = false }
                        }
                    } label: {
                        Label(copied ? tr("Zkopírováno", "Copied") : tr("Kopírovat vše", "Copy all"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.opacity)
                    }
                    .disabled(runner.lines.isEmpty)
                    .help(tr("Zkopíruje celý výpis. Kus výpisu označíš myší a zkopíruješ Cmd+C.",
                             "Copies the whole log. To copy a part, select it and press Cmd+C."))
                    Button { runner.clear() } label: { Label(tr("Vymazat", "Clear"), systemImage: "trash") }
                        .disabled(runner.isRunning || runner.lines.isEmpty)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(GhostButtonStyle(height: 22))
            }
            .frame(height: 22)
            LogConsole(lines: runner.lines)
                .frame(height: 340)
        }
    }
}

// MARK: - Toolbar buttons

/// Toolbar button: icon + text, highlighted on hover, in the accent color when active.
struct HeaderButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, active: active)
    }

    private struct Inner: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(HeaderLabelStyle())
                .foregroundStyle(active ? Theme.accentInk : Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(active ? Theme.tint : (hovering ? Theme.chromeHover : .clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.snappy, value: active)
        }
    }
}

struct HeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 15))
            configuration.title.font(.system(size: 13)).lineLimit(1).fixedSize()
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

/// Is the screen (Overview / Stats) visible right now? A hidden one doesn't react to keyboard shortcuts.
private struct PageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var pageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }
}

/// Blur only when needed (consent window). `.blur(radius: 0)` would still draw the whole window through
/// an extra layer, which put needless load on the CPU with the animated background.
private struct BlurWhen: ViewModifier {
    let on: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if on { content.blur(radius: 3) } else { content }
    }
}

// MARK: - Window

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
