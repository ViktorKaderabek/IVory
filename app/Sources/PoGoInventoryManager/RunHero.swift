import SwiftUI

// The big round control at the top of the run screen: the dial that starts a run and the one that stops it.

/// The wide band at the top: where the run stands, and the six steps as a strip of segments.
struct RunHero: View {
    @Binding var fresh: Bool
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()

    private var steps: Steps { store.config.steps }

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                pill
                Text(title)
                    .font(.system(size: 32, weight: .medium))
                    .tracking(-0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color.oklch(0.8, 0.02, 280))
                    .lineLimit(1)
                if ready { lastRunLine.padding(.top, 6).transition(.opacity) }
                segments
                    .padding(.top, 8)
                    .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                ZStack {
                    if runner.isRunning {
                        StopDial(fraction: ringFraction, label: ringLabel, stop: runner.stop)
                    } else {
                        StartDial(label: startLabel, symbol: startSymbol, start: start)
                            .disabled(steps.count == 0)
                            .help(steps.count == 0 ? tr("Nejdřív zapni aspoň jeden krok", "Turn on at least one step first")
                                                   : tr("Spustí běh", "Starts the run"))
                    }
                }
                .transition(.opacity)
                Group {
                    if !runner.isRunning {
                        VStack(spacing: 6) {
                            freshToggle
                            if runner.outcome != nil {
                                Text(tr("se stejnými kroky", "with the same steps"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.oklch(0.75, 0.02, 280))
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: runner.isRunning)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background { glow }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
        .foregroundStyle(Theme.white)
        .ticking(every: 1, while: runner.isRunning) { now = $0 }
    }

    /// The lit corner of the band. It never changes, so it is its own equatable view: the elapsed time
    /// ticking once a second must not send two blurred 400-point circles through the compositor again.
    private var glow: some View { HeroGlow().equatable() }

    private var pill: some View {
        HStack(spacing: 8) {
            PulsingCircle(fill: dotColor, glow: dotColor, glowRadius: 4,
                          blinkTo: 0.3, duration: 0.8, animate: runner.isRunning && !reduceMotion)
                .frame(width: 7, height: 7)
            Text(pillText)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
    }

    private var dotColor: Color {
        if runner.isRunning || runner.outcome == .done { return Theme.green }
        if runner.outcome == .failed { return Theme.red }
        return Color.oklch(0.72, 0.02, 280)
    }

    private var pillText: String {
        if runner.isRunning { return tr("Běží · nesahej na telefon", "Running · don't touch the phone") }
        switch runner.outcome {
        case .done: return tr("Hotovo \(finishedAt)", "Finished \(finishedAt)")
        case .stopped: return tr("Zastaveno", "Stopped")
        case .failed: return tr("Skončilo s chybou", "Failed")
        case nil: return tr("Připraveno · připoj a odemkni iPhone", "Ready · connect and unlock your iPhone")
        }
    }

    private var finishedAt: String {
        guard let end = runner.finishedAt else { return "" }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = Calendar.current.isDateInToday(end) ? tr("'dnes' H:mm", "'today' h:mm a") : tr("d. M. H:mm", "MMM d, h:mm a")
        return f.string(from: end)
    }

    private var title: String {
        if runner.isRunning { return tr("Třídím tvoje úložiště…", "Sorting your storage…") }
        switch runner.outcome {
        case .done: return tr("Hotovo", "Done")
        case .stopped: return tr("Zastaveno", "Stopped")
        case .failed: return tr("Nedoběhlo", "Didn't finish")
        case nil: return tr("Příští běh", "Next run")
        }
    }

    private var subtitle: String {
        if runner.isRunning {
            var parts = [tr("Krok \(max(1, runner.stats.phase)) z 6", "Step \(max(1, runner.stats.phase)) of 6")]
            if let step = Runner.Step(rawValue: runner.stats.phase)?.phaseTitle { parts.append(step) }
            if let s = runner.scanned { parts.append(tr("\(s.done) z \(s.total)", "\(s.done) of \(s.total)")) }
            if let start = runner.startedAt { parts.append(elapsed(now.timeIntervalSince(start))) }
            return parts.joined(separator: " · ")
        }
        if runner.outcome != nil, let start = runner.startedAt, let end = runner.finishedAt {
            return tr("\(runner.stats.measured) Pokémonů za \(elapsed(end.timeIntervalSince(start))) · výsledky jsou ve složce pogo_runs",
                      "\(runner.stats.measured) Pokémon in \(elapsed(end.timeIntervalSince(start))) · results are in the pogo_runs folder")
        }
        return tr("Připoj a odemkni iPhone a zmáčkni Spustit.",
                  "Connect and unlock your iPhone, then press Start.")
    }

    /// Six little bars under the title – which steps are on, and which one is running now.
    private var segments: some View {
        HStack(spacing: 6) {
            ForEach(Runner.Step.allCases) { step in
                let on = step.isOn(steps)
                let active = runner.isRunning && runner.stats.phase == step.rawValue
                let past = on && runner.stats.phase > step.rawValue
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bar(on: on, active: active, past: past))
                        .frame(height: 5)
                        .shimmer(active)
                        .shadow(color: active ? Theme.violet.opacity(0.7) : .clear, radius: 6)
                    Text(step.title)
                        .font(.system(size: 11))
                        .foregroundStyle(on ? Color.oklch(0.85, 0.02, 280) : Color.oklch(0.55, 0.02, 280))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.3), value: runner.stats.phase)
    }

    /// Done is green, the step under way is half-filled with the run gradient, the rest is just "on" or "off".
    private func bar(on: Bool, active: Bool, past: Bool) -> AnyShapeStyle {
        let idle = runner.outcome == nil && !runner.isRunning
        if past || (runner.outcome == .done && on) { return AnyShapeStyle(Theme.green) }
        if active {
            let p = runner.phaseProgress ?? 0
            return AnyShapeStyle(LinearGradient(stops: [
                .init(color: Theme.lightTeal, location: 0),
                .init(color: Theme.violet, location: max(0.05, p)),
                .init(color: .white.opacity(0.14), location: max(0.05, p)),
                .init(color: .white.opacity(0.14), location: 1),
            ], startPoint: .leading, endPoint: .trailing))
        }
        if !on { return AnyShapeStyle(Color.white.opacity(0.06)) }
        return AnyShapeStyle(idle ? Theme.violet.opacity(0.75) : Color.white.opacity(0.14))
    }

    private var ready: Bool { !runner.isRunning && runner.outcome == nil }

    /// Before a run: what is switched on and what the last one looked like, in one line under the subtitle.
    private var lastRunLine: some View {
        HStack(spacing: 28) {
            stat("\(steps.count)", tr("kroků zapnuto", "steps on"))
            if let last = StatsStore.shared.stats?.runs.last {
                if let checked = last.checked {
                    stat("\(checked)", tr("Pokémonů minule", "Pokémon last time"))
                }
                stat(tr("\(max(1, Int(last.duration / 60))) min", "\(max(1, Int(last.duration / 60))) min"),
                     tr("minule trvalo", "last run took"))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 22, weight: .medium).monospacedDigit()).tracking(-0.44)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.oklch(0.75, 0.02, 280))
        }
    }

    private var startLabel: String { runner.outcome == nil ? tr("Spustit", "Start") : tr("Znovu", "Run again") }
    private var startSymbol: String { runner.outcome == nil ? "play.fill" : "arrow.clockwise" }

    private func start() {
        guard !runner.isRunning, store.config.steps.count > 0 else { return }
        store.prepareRun()
        runner.start(steps: store.config.steps, fresh: fresh)
    }

    private var freshToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { fresh.toggle() } } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fresh ? Theme.accent : .clear)
                    .frame(width: 14, height: 14)
                    .overlay {
                        if fresh {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                        }
                    }
                Text(tr("Přeměřit všechna IV", "Measure every IV again"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(fresh ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Přečte IV znovu i u Pokémonů, které už IVory zná – jinak se čtou jen noví a změnění.",
                 "Reads the IV again even for Pokémon IVory already knows – otherwise only new and changed ones are read."))
    }

    private func elapsed(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        if t < 60 { return tr("\(t) s", "\(t)s") }
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private var ringFraction: Double { runner.isRunning ? runner.runProgress : 1 }

    private var ringLabel: String {
        guard runner.isRunning else { return tr("všech 6 kroků", "all 6 steps") }
        let step = tr("krok \(max(1, runner.stats.phase)) z 6", "step \(max(1, runner.stats.phase)) of 6")
        guard let p = runner.phaseProgress else { return step }
        return step + " · \(Int(p * 100)) %"
    }
}

/// Start: one big round button, breathing quietly so the eye finds it.
struct StartDial: View {
    let label: String
    let symbol: String
    let start: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var breathing = false
    @State private var hovered = false

    private static let size: CGFloat = 132

    var body: some View {
        Button(action: start) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 28, weight: .medium))
                Text(label).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(Color.oklch(0.9, 0.07, 290))
            .frame(width: Self.size, height: Self.size)
            .background {
                Circle().fill(RadialGradient(colors: [.oklch(0.32, 0.10, 290), .oklch(0.19, 0.035, 280)],
                                             center: UnitPoint(x: 0.5, y: 0.3),
                                             startRadius: 0, endRadius: Self.size * 0.8))
                    .shadow(color: Theme.violet.opacity(0.4), radius: 25)
            }
            .background { halo }
            .overlay(Circle().strokeBorder(Theme.violet, lineWidth: 2))
            .overlay(Circle().fill(.white.opacity(hovered ? 0.07 : 0)))
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    /// Two rings of light around the button, widening and fading as it breathes. No shadow here – the glow
    /// belongs to the button's own circle, so it is drawn once instead of once per ring.
    private var halo: some View {
        let grow: CGFloat = breathing ? 1 : 0
        return ZStack {
            Circle().fill(Theme.violet.opacity(0.08 + 0.05 * grow)).padding(-(9 + 3 * grow))
            Circle().fill(Theme.violet.opacity(0.04 + 0.02 * grow)).padding(-(18 + 8 * grow))
        }
    }
}

/// While the run goes: the same disc, now the progress ring with Stop inside it.
struct StopDial: View {
    let fraction: Double
    let label: String
    let stop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = 0.0
    @State private var hovered = false

    private static let size: CGFloat = 132
    private static let inner: CGFloat = 122

    var body: some View {
        ZStack {
            // The ring measures the whole run, so inside one step its head creeps. These say "right now,
            // something is happening" – the same cue the step that is under way wears in the list.
            PulseRing(color: Theme.violet, cornerRadius: Self.size / 2)
                .frame(width: Self.size, height: Self.size)

            Circle()
                .fill(AngularGradient(stops: stops, center: .center))
                .rotationEffect(.degrees(-90))
                .frame(width: Self.size, height: Self.size)
                .shadow(color: Theme.violet.opacity(0.35), radius: 22)

            // the spark rides the head of the ring: it stops where the run has actually got to
            Circle()
                .fill(Color.oklch(0.97, 0.02, 290))
                .frame(width: 8, height: 8)
                .shadow(color: Color.oklch(0.8, 0.12, 290), radius: reduceMotion ? 3 : 4 + 3 * glow)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.18 * glow)
                .offset(y: -Self.size / 2 + 4)
                .rotationEffect(.degrees(360 * max(0.004, min(1, fraction))))
                .frame(width: Self.size, height: Self.size)
                .animation(.easeOut(duration: 0.5), value: fraction)

            Button(action: stop) {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.red)
                        .frame(width: 18, height: 18)
                    Text(tr("Zastavit", "Stop")).font(.system(size: 13, weight: .medium))
                    // the whole run on its own line, the step it is on under it – together they used
                    // to be one line and the end of it was cut off
                    Text("\(Int(fraction * 100)) %")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    Text(label)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color.oklch(0.72, 0.02, 280))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                }
                .foregroundStyle(Color.oklch(0.96, 0.008, 280))
                .frame(width: Self.inner, height: Self.inner)
                .background(Circle().fill(Color.oklch(hovered ? 0.23 : 0.19, 0.035, 280)))
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = 1 }
        }
        .help(tr("Zastaví běh", "Stops the run"))
    }

    private var stops: [Gradient.Stop] {
        let end = max(0.02, min(1, fraction))
        return [
            .init(color: Theme.lightTeal, location: 0),
            .init(color: Theme.violet, location: end),
            .init(color: .white.opacity(0.1), location: end),
            .init(color: .white.opacity(0.1), location: 1),
        ]
    }
}

/// The light behind the band at the top of Run. Nothing about it depends on the run, so it is drawn once
/// and rasterized; `Equatable` keeps SwiftUI from rebuilding it when the rest of the band changes.
struct HeroGlow: View, Equatable {
    static func == (lhs: HeroGlow, rhs: HeroGlow) -> Bool { true }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [.oklch(0.31, 0.08, 282), .oklch(0.16, 0.025, 278)],
                               center: .topLeading, startRadius: 0,
                               endRadius: max(geo.size.width * 0.9, geo.size.height * 1.7) * 0.64)
                Circle().fill(Theme.violet).blur(radius: 55).opacity(0.34)
                    .frame(width: 420, height: 420)
                    .offset(x: geo.size.width - 300, y: -230)
                Circle().fill(Theme.lightTeal).blur(radius: 55).opacity(0.22)
                    .frame(width: 360, height: 360)
                    .offset(x: geo.size.width * 0.3, y: geo.size.height + 290 - 360)
            }
            .drawingGroup()
        }
    }
}
