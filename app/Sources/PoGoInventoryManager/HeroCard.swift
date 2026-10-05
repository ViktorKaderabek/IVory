import SwiftUI

/// The state the hero card shows.
enum HeroState: Equatable {
    case ready, running, done, stopped, error

    @MainActor init(runner: Runner) {
        if runner.isRunning { self = .running; return }
        switch runner.outcome {
        case .done: self = .done
        case .stopped: self = .stopped
        case .failed: self = .error
        case .none: self = .ready
        }
    }
}

/// The big card at the top: the state, what is happening right now, and the main button. Dark in both modes.
struct HeroCard: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let steps: Steps
    @Binding var fresh: Bool

    private var state: HeroState { HeroState(runner: runner) }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                StatusPill(state: state)

                HStack(spacing: 12) {
                    if let icon = stateIcon {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(icon.color)
                            .symbolEffect(.bounce, value: runner.finishedAt)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(headline)
                        .font(.system(size: 34, weight: .medium))
                        .tracking(-0.75)
                        .contentTransition(.opacity)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: state)

                ZStack(alignment: .topLeading) {
                    Text(subtitle)
                        .id(subtitle)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Theme.neutral200)
                .lineLimit(2)
                .frame(maxWidth: 520, minHeight: 45, alignment: .topLeading)
                .clipped()
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: subtitle)

                if let started = runner.startedAt, state != .ready {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 6) {
                            Image(systemName: "timer").font(.system(size: 15))
                            Text(elapsed(since: started, until: runner.finishedAt))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.neutral300)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                StartButton(steps: steps, fresh: fresh)
                if !runner.isRunning {
                    HeroCheckbox(isOn: $fresh, title: tr("Změřit IV znovu", "Measure IV again"))
                        .help(tr("Přečíst znovu IV všech Pokémonů – paměť z minulých běhů se nepoužije, jen přepíše",
                                 "Read every Pokémon's IV again – the memory from earlier runs is not used, just rewritten"))

                        .transition(.opacity)
                }
            }
        }
        .padding(EdgeInsets(top: 28, leading: 32, bottom: 28, trailing: 30))
        .frame(minHeight: 236)
        .foregroundStyle(Theme.white)
        .background(HeroBackground(state: state, reduceMotion: reduceMotion))
        .overlay(alignment: .top) {
            // light edge at the top
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .white.opacity(0.35), location: 0.06),
                .init(color: .white.opacity(0.35), location: 0.94), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(color: glow, radius: 18, y: 18)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.5), value: state)
    }

    private var glow: Color {
        switch state {
        case .error: return Color.oklch(0.62, 0.2, 18).opacity(0.4)
        case .running: return Theme.lightBlue.opacity(0.6)
        default: return Theme.lightBlue.opacity(0.32)
        }
    }

    private var stateIcon: (symbol: String, color: Color)? {
        switch state {
        case .done: return ("checkmark.seal.fill", .oklch(0.88, 0.1, 190))
        case .stopped: return ("pause.circle.fill", HeroPalette.orange)
        case .error: return ("exclamationmark.circle.fill", HeroPalette.red)
        default: return nil
        }
    }

    private var headline: String {
        switch state {
        case .ready: return tr("Připraveno", "Ready")
        case .running: return tr("Třídím inventář…", "Sorting your storage…")
        case .done: return tr("Hotovo", "Done")
        case .stopped: return tr("Zastaveno", "Stopped")
        case .error: return tr("Třídění selhalo", "Sorting failed")
        }
    }

    private var subtitle: String {
        let c = store.config
        switch state {
        case .ready:
            return plan(c)
        case .running: return runner.activity
        case .done:
            let folder = Runner.resultsURL.lastPathComponent
            return tr("Výsledky jsou ve složce \(folder).", "Results are in the \(folder) folder.")
        case .stopped: return tr("Dosavadní výsledky jsou uložené.", "Results so far are saved.")
        case .error:
            if let text = runner.fatalText { return text }
            return runner.exitCode != 0
                ? tr("Kód chyby \(runner.exitCode). Detail je v Podrobnostech.", "Error code \(runner.exitCode). See Details.")
                : tr("Detail je v Podrobnostech.", "See Details.")
        }
    }

    /// "Tag worse duplicates, sort your storage into IV tags, tag Pokémon for PvP leagues and rename …"
    private func plan(_ c: AppConfig) -> String {
        let n = c.ivTags.filter { !$0.name.isEmpty }.count
        let range = pctRange(c.rename.min, c.rename.max)

        let alone = steps.count == 1
        var parts: [String] = []
        if steps.duplicates {
            parts.append(alone ? tr("označím horší duplicity tagem \(c.removeTag)", "tag worse duplicates with \(c.removeTag)")
                               : tr("označím horší duplicity", "tag worse duplicates"))
        }
        if steps.iv {
            parts.append(alone ? tr("roztřídím celý inventář do \(n) IV tagů", "sort your whole storage into \(n) IV tags")
                               : tr("roztřídím inventář do IV tagů", "sort your storage into IV tags"))
        }
        if steps.pvp { parts.append(tr("otaguji kusy pro PvP ligy", "tag Pokémon for PvP leagues")) }
        if steps.rename { parts.append(tr("přejmenuji kusy s IV \(range)", "rename Pokémon with IV \(range)")) }
        if steps.battle { parts.append(tr("otaguji raid útočníky a PvP týmy", "tag raid attackers and PvP teams")) }
        if steps.weak { parts.append(tr("označím kusy pod \(c.weak.maxIV) % IV", "tag Pokémon under \(c.weak.maxIV)% IV")) }
        guard !parts.isEmpty else { return tr("Vyber, co se má udělat.", "Choose what to do.") }
        let text = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + tr(" a ", " and ") + parts.last!
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    private func elapsed(since start: Date, until end: Date?) -> String {
        let s = max(0, Int((end ?? Date()).timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Hero card colors (the card is dark in both modes).
enum HeroPalette {
    static let green = Color.oklch(0.82, 0.17, 150)
    static let orange = Color.oklch(0.8, 0.14, 65)
    static let red = Color.oklch(0.72, 0.19, 22)
    static let stopRed = Color.oklch(0.8, 0.14, 22)
}

/// Status pill: a dot (blinking during a run) + text.
struct StatusPill: View {
    let state: HeroState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            PulsingCircle(fill: dot, glow: state == .running ? dot : nil, glowRadius: 5,
                          blinkTo: 0.3, duration: 0.8, animate: state == .running && !reduceMotion)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
        }
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 12))
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .animation(.easeInOut(duration: 0.3), value: state)
    }

    private var text: String {
        switch state {
        case .ready: return tr("Připoj a odemkni iPhone", "Connect and unlock your iPhone")
        case .running: return tr("BĚŽÍ · nesahej na telefon", "RUNNING · don't touch the phone")
        case .done: return tr("DOKONČENO", "DONE")
        case .stopped: return tr("ZASTAVENO", "STOPPED")
        case .error: return tr("CHYBA", "ERROR")
        }
    }

    private var dot: Color {
        switch state {
        case .ready: return Theme.neutral300
        case .running: return HeroPalette.green
        case .done: return Theme.white
        case .stopped: return HeroPalette.orange
        case .error: return HeroPalette.red
        }
    }

    private var background: Color {
        switch state {
        case .stopped: return HeroPalette.orange.opacity(0.26)
        case .error: return HeroPalette.red.opacity(0.26)
        default: return .white.opacity(0.12)
        }
    }
}

/// A checkbox on the dark card.
struct HeroCheckbox: View {
    @Binding var isOn: Bool
    let title: String

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Theme.white : .clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(isOn ? 1 : 0.55), lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.violet600)
                    }
                }
                .frame(width: 16, height: 16)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.neutral200)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

// MARK: - Background with lights

/// Three blurred drifting lights. They speed up during a run (16 s → 5 s) and freeze when stopped.
/// Core Animation animates them (HeroLights), so the app computes nothing between frames.
struct HeroBackground: View {
    let state: HeroState
    let reduceMotion: Bool

    private struct Look {
        let colors: [Color]
        let opacity: Double
        let duration: Double
        let paused: Bool
    }

    private var look: Look {
        let normal = [Theme.lightTeal, Theme.lightBlue, Theme.violet]
        switch state {
        case .ready: return Look(colors: normal, opacity: 0.5, duration: 16, paused: false)
        case .running: return Look(colors: normal, opacity: 0.85, duration: 5, paused: false)
        case .done: return Look(colors: normal, opacity: 0.7, duration: 16, paused: false)
        case .stopped:
            return Look(colors: [Theme.neutral600, .oklch(0.5, 0.06, 262), Theme.violet700], opacity: 0.4, duration: 16, paused: true)
        case .error:
            return Look(colors: [.oklch(0.62, 0.2, 18), .oklch(0.55, 0.18, 340), Theme.violet], opacity: 0.75, duration: 16, paused: false)
        }
    }

    var body: some View {
        let look = look
        ZStack {
            LinearGradient(colors: [Theme.nightSection, .oklch(0.177, 0.031, 279)],
                           startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))
            HeroLights(colors: look.colors, opacity: look.opacity,
                       speed: reduceMotion || look.paused ? 0 : 16 / look.duration)
        }
    }
}

// MARK: - Main button

/// Round button: Start (breathing); during a run, Stop with a spinning arc and radar ripples.
struct StartButton: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var pageActive
    let steps: Steps
    let fresh: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            if runner.isRunning {
                runner.stop()
            } else {
                store.prepareRun()
                runner.start(steps: steps, fresh: fresh)
            }
        } label: {
            ZStack {
                rings
                face.scaleEffect(hovering ? 1.04 : 1)
            }
            .frame(width: 136, height: 136)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(pageActive ? .defaultAction : nil)   // on a hidden screen, Enter starts nothing
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: runner.isRunning)
        .help(runner.isRunning ? tr("Zastavit (výsledky se uloží)", "Stop (results are saved)") : tr("Spustit (Enter)", "Start (Enter)"))
    }

    @ViewBuilder private var face: some View {
        if runner.isRunning {
            VStack(spacing: 3) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(HeroPalette.stopRed)
                    .transition(.symbolEffect(.automatic))
                Text(tr("Zastavit", "Stop")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.white)
            }
            .frame(width: 108, height: 108)
            .background(.ultraThinMaterial.opacity(0.6), in: Circle())
            .background(Color.white.opacity(0.12), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.3)))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            VStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.violet600)
                    .padding(.leading, 4)
                Text(tr("Spustit", "Start")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.violet700)

            }
            .frame(width: 108, height: 108)
            .background(Circle().fill(Theme.white.shadow(.inner(color: Theme.violet200, radius: 0, y: -3))))
            .shadow(color: Theme.lightBlue.opacity(0.55), radius: 15, y: 14)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// Rings around the button (animated by Core Animation, see StartRings).
    private var rings: some View {
        ZStack {
            if !runner.isRunning {
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1).transition(.opacity)
            }
            StartRings(running: runner.isRunning, reduceMotion: reduceMotion)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Confetti when finished

/// Confetti in the IV tag colors over the whole window, 3 s.
struct ConfettiView: View {
    let start: Date
    private let pieces = (0..<80).map(Piece.init)

    struct Piece {
        let x: Double, delay: Double, speed: Double, drift: Double, spin: Double, angle: Double
        let color: Color, w: Double, h: Double

        init(_ seed: Int) {
            var s = UInt64(seed &+ 1) &* 6364136223846793005 &+ 1442695040888963407
            func r() -> Double {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                return Double(s >> 11) / Double(1 << 53)
            }
            x = r()
            delay = r() * 0.6
            speed = 0.35 + r() * 0.35
            drift = 10 + r() * 30
            spin = 0.5 + r() * 1.5
            angle = r() * 360
            let colors: [Color] = [Theme.lightTeal, Theme.lightBlue, Theme.violet, .oklch(0.84, 0.14, 85),
                                   .oklch(0.74, 0.15, 30), .oklch(0.72, 0.16, 350), Theme.white]
            color = colors[seed % colors.count]
            w = 5 + r() * 5
            h = 9 + r() * 7
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { ctx, size in
                for p in pieces {
                    let tt = t - p.delay
                    guard tt > 0, tt < 3 else { continue }
                    var c = ctx
                    c.opacity = (tt > 2.3 ? max(0, 1 - (tt - 2.3) / 0.7) : 1) * 0.9
                    let x = p.x * size.width + sin(tt * 3 + p.angle) * p.drift
                    let y = -20 + tt * p.speed * size.height
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .degrees(p.angle + tt * 360 * p.spin))
                    let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
                    c.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(p.color))
                }
            }
        }
    }
}
