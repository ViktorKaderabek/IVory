import AppKit
import SwiftUI

/// Jediná obrazovka aplikace: velké tlačítko, režim, průběh a (sbalený) výpis.
/// Nastavení vyjíždí z boku (ozubené kolečko vpravo nahoře).
struct MainView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @AppStorage("runMode") private var modeRaw = Runner.Mode.both.rawValue
    @AppStorage("showLog") private var showLog = false
    @State private var showSettings = false
    @State private var fresh = false
    @State private var confettiStart: Date?
    @Namespace private var modeSpace

    private var mode: Runner.Mode { Runner.Mode(rawValue: modeRaw) ?? .both }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HeroCard(mode: mode, fresh: $fresh)
                modePicker
                ProgressPanel(mode: mode)
                logSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if let confettiStart {
                ConfettiView(start: confettiStart)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: runner.finishedAt) { _, end in
            guard let end, runner.outcome == .done else { return }
            confettiStart = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                if confettiStart == end { confettiStart = nil }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("PoGo Inventory Manager").font(.headline)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    runner.openResults()
                } label: {
                    Label("Výsledky", systemImage: "folder")
                }
                .help("Složka s výsledky a screenshoty")
                Button {
                    withAnimation(.snappy) { showSettings.toggle() }
                } label: {
                    Label("Nastavení", systemImage: "gearshape")
                }
                .help("Nastavení")
            }
        }
        .inspector(isPresented: $showSettings) {
            SettingsInspector()
                .inspectorColumnWidth(min: 360, ideal: 400, max: 520)
        }
    }

    // MARK: - Režim

    private var modePicker: some View {
        HStack(spacing: 14) {
            ForEach(Runner.Mode.allCases) { m in
                ModeCard(mode: m, selected: m == mode, namespace: modeSpace) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { modeRaw = m.rawValue }
                }
            }
        }
        .disabled(runner.isRunning)
        .opacity(runner.isRunning ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: runner.isRunning)
    }

    // MARK: - Výpis

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showLog.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showLog ? 90 : 0))
                        Text("Podrobnosti").font(.headline)
                        Text("\(runner.lines.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .contentTransition(.numericText(value: Double(runner.lines.count)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if showLog {
                    Group {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(runner.logText, forType: .string)
                        } label: { Label("Kopírovat", systemImage: "doc.on.doc") }
                        Button { runner.clear() } label: { Label("Vymazat", systemImage: "trash") }
                            .disabled(runner.isRunning)
                    }
                    .buttonStyle(.borderless)
                    .transition(.opacity)
                }
            }
            if showLog {
                LogConsole(lines: runner.lines)
                    .frame(height: 280)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity))
            }
        }
    }
}

// MARK: - Hero

/// Velká karta nahoře: stav, co se právě děje, a hlavní tlačítko.
struct HeroCard: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    let mode: Runner.Mode
    @Binding var fresh: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                StatusPill()

                HStack(spacing: 10) {
                    if let symbol = outcomeSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .symbolEffect(.bounce, value: runner.finishedAt)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(headline)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: headline)

                ZStack(alignment: .leading) {
                    Text(subtitle)
                        .id(subtitle)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .frame(maxWidth: 520, minHeight: 44, alignment: .topLeading)
                .clipped()
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: subtitle)

                if let started = runner.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label(elapsed(since: started, until: runner.finishedAt), systemImage: "timer")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .contentTransition(.numericText())
                    }
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                StartButton(mode: mode, fresh: fresh)
                if !runner.isRunning {
                    Toggle(isOn: $fresh) {
                        Text("Změřit IV znovu").foregroundStyle(.white.opacity(0.9))
                    }
                    .toggleStyle(.checkbox)
                    .help("Nepoužít IV uložená z předchozích běhů")
                    .transition(.opacity)
                }
            }
        }
        .padding(30)
        .frame(minHeight: 230)
        .background(AnimatedHeroBackground(running: runner.isRunning, outcome: runner.outcome))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.blue.opacity(runner.isRunning ? 0.4 : 0.22), radius: runner.isRunning ? 26 : 16, y: 10)
        .animation(.easeInOut(duration: 0.5), value: runner.isRunning)
    }

    private var outcomeSymbol: String? {
        if runner.isRunning { return nil }
        switch runner.outcome {
        case .done: return "checkmark.seal.fill"
        case .stopped: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .none: return nil
        }
    }

    private var headline: String {
        if runner.isRunning { return "Uklízím box…" }
        switch runner.outcome {
        case .done: return "Hotovo"
        case .stopped: return "Zastaveno"
        case .failed: return "Něco se nepovedlo"
        case .none: return "Připraveno"
        }
    }

    private var subtitle: String {
        if runner.isRunning || runner.outcome != nil { return runner.activity }
        let c = store.config
        switch mode {
        case .both:
            return "Duplicity z hledání „\(c.savedSearch)“ dostanou tag \(c.removeTag), pak se celý box roztřídí do \(c.ivTags.count) IV tagů."
        case .duplicates:
            return "Duplicity z hledání „\(c.savedSearch)“ porovnám podle IV a horší dostanou tag \(c.removeTag)."
        case .ivTags:
            return "Projdu celý box a každého Pokémona zařadím do jednoho z \(c.ivTags.count) IV tagů."
        }
    }

    private func elapsed(since start: Date, until end: Date?) -> String {
        let s = Int((end ?? Date()).timeIntervalSince(start))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Malý štítek stavu (svítící tečka + text).
struct StatusPill: View {
    @EnvironmentObject private var runner: Runner

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .phaseAnimator([false, true]) { view, phase in
                    view.opacity(runner.isRunning && phase ? 0.35 : 1)
                } animation: { _ in .easeInOut(duration: 0.8) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.18), in: Capsule())
    }

    private var text: String {
        if runner.isRunning { return "BĚŽÍ · nesahej na telefon" }
        switch runner.outcome {
        case .done: return "DOKONČENO"
        case .stopped: return "ZASTAVENO"
        case .failed: return "CHYBA"
        case .none: return "iPhone připoj kabelem a odemkni"
        }
    }

    private var dot: Color {
        if runner.isRunning { return .green }
        switch runner.outcome {
        case .done: return .white
        case .stopped: return .orange
        case .failed: return .red
        case .none: return .white.opacity(0.8)
        }
    }
}

/// Pohyblivý gradient s plujícími světly; zrychlí, když úklid běží.
struct AnimatedHeroBackground: View {
    let running: Bool
    let outcome: Runner.Outcome?

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (running ? 0.55 : 0.18)
            ZStack {
                LinearGradient(
                    colors: colors,
                    startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t), y: 0.5 + 0.5 * sin(t)),
                    endPoint: UnitPoint(x: 0.5 - 0.5 * cos(t), y: 0.5 - 0.5 * sin(t)))
                blob(color: .white.opacity(0.16), size: 300, x: 0.80 + 0.10 * cos(t * 1.3), y: 0.15 + 0.12 * sin(t * 1.1))
                blob(color: Theme.violet.opacity(0.35), size: 260, x: 0.15 + 0.08 * sin(t * 0.9), y: 0.95 + 0.10 * cos(t * 1.2))
                blob(color: Theme.teal.opacity(0.35), size: 220, x: 0.45 + 0.15 * cos(t * 0.7), y: 0.55 + 0.15 * sin(t * 0.8))
            }
        }
    }

    private var colors: [Color] {
        switch outcome {
        case .failed where !running: return [Color(red: 0.85, green: 0.3, blue: 0.35), Theme.violet]
        default: return [Theme.teal, Theme.blue, Theme.violet]
        }
    }

    private func blob(color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        GeometryReader { geo in
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .blur(radius: 40)
                .position(x: geo.size.width * x, y: geo.size.height * y)
        }
    }
}

/// Kulaté hlavní tlačítko: Start (dýchá), během běhu Stop s točícím se kroužkem.
struct StartButton: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    let mode: Runner.Mode
    let fresh: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            if runner.isRunning {
                runner.stop()
            } else {
                store.save()
                runner.start(mode: mode, fresh: fresh)
            }
        } label: {
            ZStack {
                // točící se oblouk během běhu
                if runner.isRunning {
                    TimelineView(.animation) { context in
                        let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360
                        Circle()
                            .trim(from: 0, to: 0.28)
                            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(angle))
                    }
                    .frame(width: 132, height: 132)
                    .transition(.opacity.combined(with: .scale))
                } else {
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .phaseAnimator([false, true]) { view, phase in
                            view.scaleEffect(phase ? 1.08 : 0.98).opacity(phase ? 0 : 0.9)
                        } animation: { _ in .easeOut(duration: 1.6) }
                }
                Circle()
                    .fill(.white)
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                VStack(spacing: 4) {
                    Image(systemName: runner.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(runner.isRunning ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent))
                        .contentTransition(.symbolEffect(.replace))
                    Text(runner.isRunning ? "Zastavit" : "Spustit")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(runner.isRunning ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.blue))
                        .contentTransition(.opacity)
                }
            }
            .scaleEffect(hovering ? 1.05 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.defaultAction)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: runner.isRunning)
        .help(runner.isRunning ? "Zastavit (výsledky se uloží)" : "Spustit úklid (Enter)")
    }
}

/// Lehké „zmáčknutí“ tlačítka.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Režim

struct ModeCard: View {
    let mode: Runner.Mode
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SoftIcon(symbol: mode.symbol, color: selected ? Theme.blue : .secondary, size: 36)
                        .symbolEffect(.bounce, value: selected)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(mode.rawValue).font(.headline)
                Text(mode.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.background.secondary)
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.quaternary)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 10, y: 4)
            .offset(y: hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovering = h } }
    }
}

// MARK: - Průběh

struct ProgressPanel: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    let mode: Runner.Mode

    var body: some View {
        VStack(spacing: 16) {
            PhaseBar(mode: mode)
            HStack(spacing: 14) {
                StatTile(symbol: "gauge.with.dots.needle.67percent", title: "Změřeno IV", value: runner.stats.measured, color: Theme.blue)
                StatTile(symbol: "tag.slash", title: store.config.removeTag, value: runner.stats.removable, color: .orange)
                StatTile(symbol: "tag.fill", title: "IV tagy", value: runner.stats.ivTagged, color: Theme.teal)
                StatTile(symbol: "arrow.uturn.backward", title: "Vyřešené chyby", value: runner.stats.errors, color: .pink)
            }
        }
    }
}

/// Dva kroky (Duplicity → IV tagy) se spojnicí, která se plní.
struct PhaseBar: View {
    @EnvironmentObject private var runner: Runner
    let mode: Runner.Mode

    var body: some View {
        HStack(spacing: 0) {
            PhaseDot(number: 1, title: "Duplicity", state: state(1), enabled: mode != .ivTags)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * fill)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
            PhaseDot(number: 2, title: "IV tagy", state: state(2), enabled: mode != .duplicates)
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fill)
        .padding(.horizontal, 6)
    }

    private var fill: CGFloat {
        let p = runner.stats.phase
        if runner.outcome == .done && !runner.isRunning { return 1 }
        if p >= 2 { return 1 }
        if p == 1 && runner.isRunning { return 0.5 }
        return 0
    }

    private func state(_ n: Int) -> PhaseDot.State {
        let p = runner.stats.phase
        if !runner.isRunning && runner.outcome == .done {
            if (n == 1 && mode == .ivTags) || (n == 2 && mode == .duplicates) { return .waiting }
            return .done
        }
        guard runner.isRunning else { return .waiting }
        let current = p == 0 ? (mode == .ivTags ? 2 : 1) : p
        if n == current { return .active }
        return n < current ? .done : .waiting
    }
}

struct PhaseDot: View {
    enum State { case waiting, active, done }
    let number: Int
    let title: String
    let state: State
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state == .waiting ? AnyShapeStyle(Color.secondary.opacity(0.15)) : AnyShapeStyle(Theme.accent))
                    .frame(width: 30, height: 30)
                    .phaseAnimator([false, true]) { view, phase in
                        view.shadow(color: Theme.teal.opacity(state == .active && phase ? 0.8 : 0), radius: 8)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(state == .waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(enabled ? caption : "vynecháno").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }

    private var caption: String {
        switch state {
        case .waiting: return "čeká"
        case .active: return "probíhá"
        case .done: return "hotovo"
        }
    }
}

/// Dlaždice s číslem, které při změně „poskočí“.
struct StatTile: View {
    let symbol: String
    let title: String
    let value: Int
    let color: Color
    @State private var bump = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SoftIcon(symbol: symbol, color: color, size: 30)
                .symbolEffect(.bounce, value: value)
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: Double(value)))
                .scaleEffect(bump ? 1.12 : 1, anchor: .leading)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary))
        .onChange(of: value) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { bump = false }
            }
        }
        .animation(.snappy, value: value)
    }
}

/// Tmavá konzole s barevnými řádky výpisu.
struct LogConsole: View {
    let lines: [Runner.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(for: line.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .textSelection(.enabled)
                .padding(14)
            }
            .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
            .overlay {
                if lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.alignleft").font(.title2)
                        Text("Po spuštění tu uvidíš každý krok.")
                    }
                    .foregroundStyle(.white.opacity(0.35))
                }
            }
            .onChange(of: lines.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private func color(for text: String) -> Color {
        if text.contains("!!") || text.contains("✖") || text.contains("POZOR") { return Color(red: 1, green: 0.42, blue: 0.42) }
        if text.contains("✔") { return Color(red: 0.36, green: 0.9, blue: 0.6) }
        if text.contains("-> ") { return Color(red: 0.55, green: 0.85, blue: 1) }
        if text.hasPrefix("──") || text.hasPrefix("▶") || text.hasPrefix("■") || text.contains("=====") {
            return Color(red: 0.98, green: 0.82, blue: 0.4)
        }
        if text.contains("klepnutí") || text.contains("tažení") || text.contains("podržení") {
            return .white.opacity(0.45)
        }
        return .white.opacity(0.85)
    }
}

// MARK: - Konfeta po dokončení

/// Krátký déšť konfet, když úklid doběhne.
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
            color = [Theme.teal, Theme.blue, Theme.violet, .pink, .orange, .yellow, .green][Int(r() * 7) % 7]
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
                    c.opacity = tt > 2.3 ? max(0, 1 - (tt - 2.3) / 0.7) : 1
                    let x = p.x * size.width + sin(tt * 3 + p.angle) * p.drift
                    let y = -20 + tt * p.speed * size.height
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .degrees(p.angle + tt * 360 * p.spin))
                    let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
                    c.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(p.color))
                }
            }
        }
    }
}
