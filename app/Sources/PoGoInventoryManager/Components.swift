import SwiftUI

// MARK: - Kroky

/// Karta kroku se zaškrtávátkem. Kroky jdou libovolně kombinovat, poslední zapnutý vypnout nejde.
struct StepCard: View {
    let step: Runner.Step
    let detail: String
    let isOn: Bool
    let locked: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 10) {
                SoftIcon(symbol: step.symbol,
                         color: isOn ? Theme.accentInk : Theme.muted,
                         background: isOn ? Theme.tint : Theme.raise,
                         size: 34, radius: 9)
                    .symbolEffect(.bounce, value: isOn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Theme.accent : .clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent : Theme.muted, lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 18, height: 18)
            }
            .foregroundStyle(Theme.text)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent : Theme.border, lineWidth: isOn ? 1.5 : 1))
            .shadow(color: isOn ? Theme.accent.opacity(0.3) : .clear, radius: 10, y: 6)
            .offset(y: hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .help(locked ? tr("Aspoň jeden krok musí zůstat zapnutý.", "At least one step has to stay on.")
                     : (isOn ? tr("Vypnout krok", "Turn the step off") : tr("Zapnout krok", "Turn the step on")))
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
        .animation(.snappy, value: isOn)
    }
}

// MARK: - Fáze

/// Čtyři fáze (Duplicity → IV tagy → PvP tagy → Přejmenování) se spojnicemi, které se plní.
struct PhasePanel: View {
    @EnvironmentObject private var runner: Runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let steps: Steps

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Runner.Step.allCases) { step in
                if step != .duplicates {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.progress).frame(width: geo.size.width * fill(before: step))
                            if flowing(before: step) {
                                // fáze vlevo právě běží: po spojnici k další fázi běží světlo
                                FlowStripe(reduceMotion: reduceMotion)
                                    .clipShape(Capsule())
                                    .transition(.opacity)
                            }
                        }
                    }
                    .frame(height: 4)
                    .frame(minWidth: 24)
                }
                PhaseStep(number: step.rawValue, title: step.phaseTitle, state: state(step))
                    .fixedSize()
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: runner.stats.phase)
        .animation(.easeOut(duration: 0.5), value: runner.phaseProgress)
    }

    private var shownSteps: Steps { HeroState(runner: runner) == .ready ? steps : runner.steps }

    /// Kterou fázi bot zrovna dělá (nebo dělal, když skončil).
    private var current: Int {
        let p = runner.stats.phase
        if p == 0 { return Runner.Step.allCases.first { $0.isOn(shownSteps) }?.rawValue ?? 1 }
        return p
    }

    /// Spojnice před krokem: plná, když je předchozí krok hotový. Během běhu předchozího ukazuje,
    /// kolik z něj je hotovo – jen když to bot hlásí (čtení IV); jinak zůstane prázdná a běží po ní světlo.
    private func fill(before step: Runner.Step) -> CGFloat {
        let prev = step.rawValue - 1
        switch HeroState(runner: runner) {
        case .ready: return 0
        case .done: return 1
        case .running:
            if current > prev { return 1 }
            return current == prev ? CGFloat(min(0.95, runner.phaseProgress ?? 0)) : 0
        case .stopped, .error: return current > prev ? 1 : 0
        }
    }

    /// Po spojnici za právě běžící fází běží světlo.
    private func flowing(before step: Runner.Step) -> Bool {
        HeroState(runner: runner) == .running && current == step.rawValue - 1
    }

    private func state(_ step: Runner.Step) -> PhaseStep.State {
        if !step.isOn(shownSteps) { return .skipped }
        let n = step.rawValue
        switch HeroState(runner: runner) {
        case .ready: return .waiting
        case .done: return .done
        case .running:
            if n == current { return .active }
            return n < current ? .done : .waiting
        case .stopped, .error:
            return runner.stats.phase > 0 && n < current ? .done : .waiting
        }
    }
}

struct PhaseStep: View {
    enum State { case waiting, active, done, skipped }
    let number: Int
    let title: String
    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                background
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(state == .active ? Theme.white : Theme.muted)
                }
            }
            .frame(width: 30, height: 30)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(state == .active ? Theme.teal : Theme.muted)
            }
        }
        .opacity(state == .skipped ? 0.45 : 1)
    }

    @ViewBuilder private var background: some View {
        switch state {
        case .waiting:
            Circle().fill(Theme.raise).overlay(Circle().strokeBorder(Theme.border))
        case .skipped:
            Circle().strokeBorder(Theme.border, lineWidth: 1.5)
        case .done:
            Circle().fill(Theme.accent)
        case .active:
            Circle()
                .fill(LinearGradient(stops: [
                    .init(color: Theme.lightTeal, location: 0), .init(color: Theme.lightBlue, location: 0.55),
                    .init(color: Theme.violet, location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .background(Circle().fill(Theme.lightTeal.opacity(0.22)).padding(-4))
                .background(PulsingCircle(glow: Theme.lightTeal, glowRadius: 10,
                                          glowRange: reduceMotion ? 0.55...0.55 : 0.3...0.75, duration: 1.0,
                                          animate: !reduceMotion))
        }
    }

    private var caption: String {
        switch state {
        case .waiting: return tr("čeká", "waiting")
        case .active: return tr("probíhá", "in progress")
        case .done: return tr("hotovo", "done")
        case .skipped: return tr("vynecháno", "skipped")
        }
    }
}

// MARK: - Dlaždice

/// Dlaždice s číslem, které se přetočí a při změně poskočí. Nula je ztlumená.
struct StatTile: View {
    let symbol: String
    let title: String
    let value: Int
    let color: Color
    let tint: Color
    @State private var bump = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SoftIcon(symbol: symbol, color: color, background: tint, size: 30, radius: 9)
                .symbolEffect(.bounce, value: value)
            Text(value.formatted())
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.6)
                .monospacedDigit()
                .foregroundStyle(value == 0 ? Theme.muted : Theme.text)
                .contentTransition(.numericText(value: Double(value)))
                .scaleEffect(bump ? 1.12 : 1, anchor: .leading)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .onChange(of: value) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { bump = false }
            }
        }
        .animation(.snappy, value: value)
    }
}

// MARK: - Výpis

/// Tmavá konzole s barevnými řádky výpisu (tmavá v obou režimech).
/// Výpis jako v terminálu: dá se označit myší (i přes víc řádků), Cmd+A, Cmd+C, pravým tlačítkem Kopírovat.
struct LogConsole: View {
    let lines: [Runner.LogLine]

    var body: some View {
        LogTextView(lines: lines)
            .padding(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            .background(Theme.nightBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.white.opacity(0.08)))
            .overlay {
                if lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.alignleft").font(.system(size: 22))
                        Text(tr("Po spuštění tu bude každý krok.", "Every step will show up here once you start."))
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(Theme.neutral600)
                    .allowsHitTesting(false)
                }
            }
            .environment(\.colorScheme, .dark)
    }
}

/// NSTextView pod výpisem: nové řádky jen připisuje (rychlé i se 4000 řádky), označení zůstává,
/// a když je výpis dole, jede s ním.
struct LogTextView: NSViewRepresentable {
    let lines: [Runner.LogLine]

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.lineBreakMode = .byWordWrapping
        return p
    }()
    private static let yellow = NSColor(Color.oklch(0.87, 0.12, 92))
    private static let green = NSColor(Color.oklch(0.82, 0.14, 155))
    private static let red = NSColor(Color.oklch(0.74, 0.16, 22))
    private static let blue = NSColor(Color.oklch(0.82, 0.09, 230))
    private static let dim = NSColor(Theme.neutral600)
    private static let normal = NSColor(Theme.neutral300)

    final class Coordinator {
        var firstId: Int?
        var lastId: Int?
        var lengths: [Int] = []          // délka každého řádku v textu (včetně \n)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.appearance = NSAppearance(named: .darkAqua)
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.isRichText = false
            tv.textContainerInset = NSSize(width: 8, height: 4)
            tv.selectedTextAttributes = [.backgroundColor: NSColor(Theme.violet600).withAlphaComponent(0.55)]
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let c = context.coordinator
        let atBottom = tv.visibleRect.maxY >= tv.bounds.height - 40
        storage.beginEditing()
        if let first = c.firstId, let last = c.lastId, let newFirst = lines.first?.id,
           newFirst >= first, newFirst <= last + 1 {
            let drop = min(newFirst - first, c.lengths.count)      // řádky, které Runner zepředu oříznul
            if drop > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: c.lengths.prefix(drop).reduce(0, +)))
                c.lengths.removeFirst(drop)
            }
            append(lines.filter { $0.id > last }, to: storage, c)
        } else {
            storage.setAttributedString(NSAttributedString())
            c.lengths = []
            append(lines, to: storage, c)
        }
        storage.endEditing()
        c.firstId = lines.first?.id
        c.lastId = lines.last?.id
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }

    private func append(_ new: [Runner.LogLine], to storage: NSTextStorage, _ c: Coordinator) {
        for line in new {
            let text = (line.text.isEmpty ? " " : line.text) + "\n"
            storage.append(NSAttributedString(string: text, attributes: [
                .font: Self.font, .foregroundColor: Self.color(for: line.text), .paragraphStyle: Self.paragraph]))
            c.lengths.append((text as NSString).length)
        }
    }

    private static func color(for text: String) -> NSColor {
        // výpis bota je česky, nebo anglicky (podle jazyka aplikace)
        if text.contains("!!") || text.contains("✖") || text.contains("POZOR") || text.contains("WARNING")
            || text.contains("s chybou") { return red }
        if text.contains("✔") { return green }
        if text.hasPrefix("──") || text.hasPrefix("▶") || text.hasPrefix("■") || text.contains("=====") { return yellow }
        if text.contains("->") { return blue }
        if text.contains("klepnutí") || text.contains("tažení") || text.contains("podržení")
            || text.contains("tap:") || text.contains("drag:") || text.contains("hold ") { return dim }
        return normal

    }
}
