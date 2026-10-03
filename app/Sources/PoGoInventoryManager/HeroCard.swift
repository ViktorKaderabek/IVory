import SwiftUI

/// Stav, který ukazuje hero karta.
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

/// Velká karta nahoře: stav, co se právě děje, a hlavní tlačítko. V obou režimech tmavá.
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
            // světlá hrana nahoře
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

    /// „Označím horší duplicity, roztřídím inventář do IV tagů, otaguji kusy pro PvP ligy a přejmenuji …“
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
        guard !parts.isEmpty else { return tr("Vyber, co se má udělat.", "Choose what to do.") }
        let text = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + tr(" a ", " and ") + parts.last!
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    private func elapsed(since start: Date, until end: Date?) -> String {
        let s = max(0, Int((end ?? Date()).timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Barvy hero karty (tmavé v obou režimech).
enum HeroPalette {
    static let green = Color.oklch(0.82, 0.17, 150)
    static let orange = Color.oklch(0.8, 0.14, 65)
    static let red = Color.oklch(0.72, 0.19, 22)
    static let stopRed = Color.oklch(0.8, 0.14, 22)
}

/// Pilulka stavu: tečka (při běhu bliká) + text.
struct StatusPill: View {
    let state: HeroState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .shadow(color: state == .running ? dot : .clear, radius: 5)
                .phaseAnimator([false, true]) { view, phase in
                    view.opacity(state == .running && !reduceMotion && phase ? 0.3 : 1)
                } animation: { _ in .easeInOut(duration: 0.8) }
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

/// Zaškrtávátko na tmavé kartě.
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

// MARK: - Pozadí se světly

/// Tři rozostřená světla, která plují. Při běhu zrychlí (16 s → 5 s), při zastavení zmrznou.
struct HeroBackground: View {
    let state: HeroState
    let reduceMotion: Bool
    @State private var clock = DriftClock()

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
        TimelineView(.animation(paused: reduceMotion || look.paused)) { context in
            let p = reduceMotion ? 0 : clock.advance(to: context.date, duration: look.duration, paused: look.paused)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Theme.nightSection, .oklch(0.177, 0.031, 279)],
                                   startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))
                    ZStack(alignment: .topLeading) {
                        blob(look.colors[0], size: 340, left: -0.08, top: 0.35, in: geo.size,
                             keys: [(70, 24, 1.18), (-30, 40, 0.94)], phase: p)
                        blob(look.colors[1], size: 380, left: 0.32, top: -0.45, in: geo.size,
                             keys: [(-80, 30, 0.9), (-20, -30, 1.15)], phase: p / 1.2)
                        blob(look.colors[2], size: 360, left: 0.68, top: 0.10, in: geo.size,
                             keys: [(40, -40, 1.2), (-60, 10, 1)], phase: p / 0.9)
                    }
                    .opacity(look.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: state)
    }

    /// Klíčové snímky z návrhu: 0 % → 50 % → 100 %, tam a zpět (ease-in-out, alternate).
    private func blob(_ color: Color, size: CGFloat, left: CGFloat, top: CGFloat, in box: CGSize,
                      keys: [(CGFloat, CGFloat, CGFloat)], phase: Double) -> some View {
        let cycle = phase.truncatingRemainder(dividingBy: 2)
        let linear = cycle <= 1 ? cycle : 2 - cycle
        let t = (1 - cos(linear * .pi)) / 2
        let frames: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 1)] + keys
        let seg = t < 0.5 ? 0 : 1
        let local = CGFloat(t < 0.5 ? t * 2 : (t - 0.5) * 2)
        let a = frames[seg], b = frames[seg + 1]
        let dx = a.0 + (b.0 - a.0) * local
        let dy = a.1 + (b.1 - a.1) * local
        let sc = a.2 + (b.2 - a.2) * local
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(sc)
            .blur(radius: 56)
            .offset(x: box.width * left + dx, y: box.height * top + dy)
    }
}

/// Fáze plujících světel. Fáze se přičítá po snímcích, takže změna rychlosti neskočí.
final class DriftClock {
    private var phase = 0.0
    private var last: Date?

    func advance(to date: Date, duration: Double, paused: Bool) -> Double {
        defer { last = date }
        guard let last, !paused else { return phase }
        let dt = min(0.1, max(0, date.timeIntervalSince(last)))
        phase += dt / duration
        return phase
    }
}

// MARK: - Hlavní tlačítko

/// Kulaté tlačítko: Spustit (dýchá), během běhu Zastavit s točícím se obloukem a radarovými vlnami.
struct StartButton: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let steps: Steps
    let fresh: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            if runner.isRunning {
                runner.stop()
            } else {
                store.save()
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
        .keyboardShortcut(.defaultAction)
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

    @ViewBuilder private var rings: some View {
        if runner.isRunning {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ripple(t, delay: 0)
                    ripple(t, delay: 1.3)
                    Circle()
                        .strokeBorder(AngularGradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .clear, location: 0.6),
                            .init(color: Theme.lightTeal, location: 0.86), .init(color: Theme.white, location: 1),
                        ], center: .center), lineWidth: 4)
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360 - 90))
                }
            }
            .transition(.opacity)
        } else {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                        let e = 1 - pow(1 - p, 2)  // ease-out
                        Circle()
                            .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                            .scaleEffect(0.97 + 0.23 * e)
                            .opacity(0.9 * (1 - e))
                    }
                }
            }
            .transition(.opacity)
        }
    }

    /// Radarová vlna: z 0,85× na 2,1×, vybledne (2,6 s).
    private func ripple(_ t: Double, delay: Double) -> some View {
        let p = ((t - delay).truncatingRemainder(dividingBy: 2.6) + 2.6).truncatingRemainder(dividingBy: 2.6) / 2.6
        let e = 1 - pow(1 - p, 2)
        return Circle()
            .strokeBorder(Theme.lightTeal, lineWidth: 1)
            .scaleEffect(0.85 + 1.25 * e)
            .opacity(reduceMotion ? 0 : 0.7 * (1 - e))
    }
}

// MARK: - Konfety po dokončení

/// Konfety v barvách IV tagů přes celé okno, 3 s.
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
