import AppKit
import SwiftUI

/// Hlavní stránka: spuštění úklidu, živý přehled a výpis.
struct DashboardView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @AppStorage("runMode") private var modeRaw = Runner.Mode.both.rawValue
    @AppStorage("showLog") private var showLog = true
    @State private var fresh = false

    private var mode: Runner.Mode { Runner.Mode(rawValue: modeRaw) ?? .both }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                modePicker
                statsGrid
                phases
                console
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Úklid boxu")
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            Theme.hero
            // jemné dekorativní kruhy
            Circle().fill(.white.opacity(0.08)).frame(width: 260).offset(x: 80, y: -120)
            Circle().fill(.white.opacity(0.06)).frame(width: 180).offset(x: -40, y: 110)

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("PoGo Inventory Manager")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                    Text(runner.isRunning ? "Uklízím box…" : headline)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(runner.isRunning || runner.outcome != nil ? runner.activity : summary)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: 560, alignment: .leading)

                    if let started = runner.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Label(elapsed(since: started, until: runner.finishedAt), systemImage: "clock")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                Spacer(minLength: 12)
                actionButton
            }
            .padding(28)
        }
        .frame(minHeight: 190)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.blue.opacity(0.25), radius: 18, y: 8)
    }

    private var actionButton: some View {
        VStack(spacing: 10) {
            if runner.isRunning {
                Button {
                    runner.stop()
                } label: {
                    Label("Zastavit", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle(destructive: true))
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Button {
                    store.save()
                    runner.start(mode: mode, fresh: fresh)
                } label: {
                    Label("Spustit úklid", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Toggle(isOn: $fresh) {
                    Text("Změřit IV znovu").foregroundStyle(.white.opacity(0.9))
                }
                .toggleStyle(.checkbox)
                .help("Nepoužít IV uložená z předchozích běhů")
            }
        }
    }

    private var headline: String {
        switch runner.outcome {
        case .done: return "Hotovo ✨"
        case .stopped: return "Zastaveno"
        case .failed: return "Něco se nepovedlo"
        case .none: return "Připraveno k úklidu"
        }
    }

    private var summary: String {
        let c = store.config
        switch mode {
        case .both:
            return "Duplicity z hledání „\(c.savedSearch)“ dostanou tag \(c.removeTag), pak celý box \(c.ivTags.count) IV tagů. iPhone odemkni a připoj kabelem."
        case .duplicates:
            return "Duplicity z hledání „\(c.savedSearch)“ porovnám podle IV a horší dostanou tag \(c.removeTag)."
        case .ivTags:
            return "Projdu celý box a každého Pokémona zařadím do jednoho z \(c.ivTags.count) IV tagů."
        }
    }

    // MARK: - Výběr režimu

    private var modePicker: some View {
        HStack(spacing: 14) {
            ForEach(Runner.Mode.allCases) { m in
                ModeCard(mode: m, selected: m == mode) { modeRaw = m.rawValue }
            }
        }
        .disabled(runner.isRunning)
        .opacity(runner.isRunning ? 0.6 : 1)
    }

    // MARK: - Přehled

    private var statsGrid: some View {
        let s = runner.stats
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            StatTile(symbol: "gauge.with.dots.needle.67percent", title: "Změřeno IV", value: s.measured, color: Theme.blue)
            StatTile(symbol: "tag.slash", title: store.config.removeTag, value: s.removable, color: .orange)
            StatTile(symbol: "tag.fill", title: "IV tagy", value: s.ivTagged, color: Theme.teal)
            StatTile(symbol: "exclamationmark.triangle", title: "Chyby (opraveno)", value: s.errors, color: .red)
        }
    }

    private var phases: some View {
        HStack(spacing: 12) {
            PhaseStep(number: 1, title: "Duplicity", subtitle: "porovnat a označit",
                      state: phaseState(1), enabled: mode != .ivTags)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            PhaseStep(number: 2, title: "IV tagy", subtitle: "celý box podle IV",
                      state: phaseState(2), enabled: mode != .duplicates)
            Spacer()
            if runner.stats.skipped > 0 {
                Label("\(runner.stats.skipped) přeskočeno (už mají tag)", systemImage: "forward.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phaseState(_ n: Int) -> PhaseStep.State {
        let current = runner.stats.phase
        if runner.isRunning {
            if current == n || (current == 0 && n == (mode == .ivTags ? 2 : 1)) { return .active }
            return current > n ? .done : .waiting
        }
        if runner.outcome == .done {
            if (n == 1 && mode == .ivTags) || (n == 2 && mode == .duplicates) { return .waiting }
            return .done
        }
        return current > n ? .done : .waiting
    }

    // MARK: - Výpis

    private var console: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.snappy) { showLog.toggle() }
                } label: {
                    Label("Výpis", systemImage: showLog ? "chevron.down" : "chevron.right")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                Text("\(runner.lines.count) řádků").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.logText, forType: .string)
                } label: { Label("Kopírovat", systemImage: "doc.on.doc") }
                Button { runner.openResults() } label: { Label("Výsledky", systemImage: "folder") }
                Button { runner.clear() } label: { Label("Vymazat", systemImage: "trash") }
                    .disabled(runner.isRunning)
            }
            .buttonStyle(.borderless)

            if showLog {
                LogConsole(lines: runner.lines)
                    .frame(height: 300)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func elapsed(since start: Date, until end: Date?) -> String {
        let s = Int((end ?? Date()).timeIntervalSince(start))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

// MARK: - Komponenty

struct ModeCard: View {
    let mode: Runner.Mode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                SoftIcon(symbol: mode.symbol, color: selected ? Theme.blue : .secondary, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.rawValue).font(.headline)
                    Text(mode.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary),
                                  lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct StatTile: View {
    let symbol: String
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SoftIcon(symbol: symbol, color: color, size: 30)
                Spacer()
            }
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
    }
}

struct PhaseStep: View {
    enum State { case waiting, active, done }

    let number: Int
    let title: String
    let subtitle: String
    let state: State
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state == .waiting ? AnyShapeStyle(Color.secondary.opacity(0.15)) : AnyShapeStyle(Theme.accent))
                    .frame(width: 30, height: 30)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(state == .waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                }
            }
            .symbolEffect(.pulse, isActive: state == .active)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(enabled ? subtitle : "vynecháno").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(state == .active ? AnyShapeStyle(Theme.teal.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: Capsule())
        .opacity(enabled ? 1 : 0.45)
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
            .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
            .overlay {
                if lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.alignleft").font(.title2)
                        Text("Tady se po spuštění ukáže, co skript zrovna dělá.")
                    }
                    .foregroundStyle(.white.opacity(0.35))
                }
            }
            .onChange(of: lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
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
