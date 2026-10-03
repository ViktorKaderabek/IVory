import AppKit
import SwiftUI

/// Jediná obrazovka aplikace: hero karta s tlačítkem, režim, fáze, dlaždice a (sbalený) výpis.
/// Nastavení vyjíždí zprava (tlačítko Nastavení v liště).
struct MainView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settingsWidth") private var settingsWidth = 400.0
    @State private var settingsOpen = false
    @State private var panelWidth: CGFloat = 0
    @State private var minLocked = false
    @State private var grownBy: CGFloat = 0
    @State private var dragStartWidth: Double?
    @State private var window = WindowRef()
    @State private var fresh = false
    @State private var confettiStart: Date?
    /// Okno se souhlasem: rozhoduje se při spuštění (odvolání v Nastavení platí až od dalšího spuštění).
    @State private var askConsent: Bool?

    private var showConsent: Bool { askConsent ?? !Consent.isGiven(store.config) }


    /// Nejmenší šířka hlavního obsahu, pod kterou se karty mačkají.
    private static let mainMinWidth: CGFloat = 720
    private static let panelAnimation = 0.32

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                MainColumn(fresh: $fresh)
                    .id(store.config.language)     // po přepnutí jazyka se všechny texty postaví znovu
                    .padding(EdgeInsets(top: 22, leading: 28, bottom: 26, trailing: 28))
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.bg)

            settingsPanel
        }
        .disabled(showConsent)
        .blur(radius: showConsent ? 3 : 0)
        .overlay {
            if showConsent {
                ConsentOverlay { withAnimation(.easeOut(duration: 0.25)) { askConsent = false } }
                    .transition(.opacity)
            }
        }
        .onAppear {
            if askConsent == nil { askConsent = !Consent.isGiven(store.config) }
            Updater.shared.start { [store] in store.config.checkUpdates }
        }
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

    #if DEBUG
    /// Kontrola vzhledu: IVORY_PREVIEW=stav, IVORY_SETTINGS=1, IVORY_STEPS=duplicates,iv,pvp,rename,
    /// IVORY_CONFETTI=1. Screenshoty pro README: IVORY_SHOTS=složka (viz Shots.swift).
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
        if env["IVORY_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { setSettings(true) }
        }
        if state == "done" && env["IVORY_CONFETTI"] == "1" { confettiStart = Date() }
    }
    #endif

    // MARK: - Nastavení z boku

    /// Panel má pevnou šířku a při otevírání se jen odkrývá (obsah uvnitř se nepřeskládává).
    private var settingsPanel: some View {
        SettingsInspector()
            .id(store.config.language)
            .frame(width: settingsWidth)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            .overlay(alignment: .leading) { resizeHandle }
            .frame(width: panelWidth, alignment: .leading)
            .clipped()
            .allowsHitTesting(settingsOpen)
            .accessibilityHidden(!settingsOpen)
    }

    /// Okraj panelu jde táhnout (šířka 360–520 bodů).
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
                        panelWidth = width
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    /// Otevře/zavře nastavení. Když by na obsah nezbylo dost místa, okno se o chybějící kus
    /// plynule rozšíří (a po zavření zase zúží), takže se karty nemačkají ani neskáčou.
    private func setSettings(_ open: Bool) {
        let duration = Self.panelAnimation
        guard open != settingsOpen else { return }
        settingsOpen = open
        let target = CGFloat(settingsWidth)

        if open {
            if let win = window.window {
                let content = win.contentLayoutRect.width - panelWidth
                var grow = max(0, Self.mainMinWidth + target - content)
                var frame = win.frame
                if let screen = win.screen?.visibleFrame {
                    grow = min(grow, max(0, screen.width - frame.width))
                    frame.size.width += grow
                    if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
                } else {
                    frame.size.width += grow
                }
                grownBy = grow
                if grow > 0 { animateWindow(win, to: frame, duration: duration) }
            }
            withAnimation(.easeInOut(duration: duration)) { panelWidth = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
                if settingsOpen { minLocked = true }
            }
        } else {
            minLocked = false
            withAnimation(.easeInOut(duration: duration)) { panelWidth = 0 }
            if let win = window.window, grownBy > 0 {
                var frame = win.frame
                frame.size.width = max(Self.mainMinWidth, frame.width - grownBy)
                animateWindow(win, to: frame, duration: duration)
            }
            grownBy = 0
        }
    }

    private func animateWindow(_ win: NSWindow, to frame: NSRect, duration: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Lišta

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // bez skleněné „kapsle“ kolem položek lišty, jako v návrhu; pružná mezera odsune
            // tlačítka doprava (jinak je macOS 26 staví hned za název)
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

/// Obsah hlavního okna: hero karta, kroky, fáze, dlaždice, panel tagů a výpis.
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

    // MARK: - Kroky

    private var stepsRow: some View {
        HStack(spacing: 12) {
            ForEach(Runner.Step.allCases) { step in
                let on = step.isOn(steps)
                StepCard(step: step, detail: detail(step), isOn: on, locked: on && steps.count == 1) {
                    guard !(on && steps.count == 1) else { NSSound.beep(); return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        step.set(&store.config.steps, !on)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(runner.isRunning)
        .opacity(runner.isRunning ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: runner.isRunning)
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

    // MARK: - Dlaždice

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

    // MARK: - Výpis

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

// MARK: - Lišta

/// Tlačítko v liště: ikona + text, při najetí podbarvené, aktivní v barvě akcentu.
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
                .background(active ? Theme.tint : (hovering ? Theme.raise : .clear),
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
            configuration.title.font(.system(size: 13))
        }
    }
}

// MARK: - Okno

/// Odkaz na okno, ve kterém view je (kvůli rozšíření okna při otevření nastavení).
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
