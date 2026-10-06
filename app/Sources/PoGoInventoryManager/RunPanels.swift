import AppKit
import SwiftUI

/// The right-hand column of the Run screen. It changes with the run: before one it shows what is in the
/// storage right now, during one the Pokémon being read and the log, after one what the run did.

// MARK: - Before a run

/// "Your storage now": the box as the last run left it – a donut of the IV tags, the three numbers that
/// matter and the full tag legend.
struct StorageNowCard: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @ObservedObject private var stats = StatsStore.shared

    var body: some View {
        let slices = IVSlice.all(config: store.config, mons: stats.stats?.mons ?? [])
        PanelCard {
            RunPanelTitle(tr("Tvoje úložiště", "Your storage now"),
                       note: tr("po posledním běhu", "after the last run"))

            HStack(spacing: 18) {
                IVDonut(slices: slices, inner: Theme.surface) {
                    Text(total(slices).formatted())
                        .font(.system(size: 26, weight: .medium).monospacedDigit())
                    Text(tr("Pokémonů", "Pokémon"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 10) {
                    number(highIV, tr("na 90 % a výš", "at 90% or more"), color: Theme.accentInk)
                    number(stats.stats?.removable ?? 0,
                           tr("s tagem \(store.config.removeTag)", "tagged \(store.config.removeTag)"), color: Theme.red)
                    number(stats.stats?.ranked ?? 0, tr("v PvP lize", "in a PvP league"))
                }
                Spacer(minLength: 0)
            }

            IVLegend(slices: slices)

            ResultsFolderButton(outlined: false)
        }
    }

    private func total(_ slices: [IVSlice]) -> Int { slices.reduce(0) { $0 + $1.count } }

    private var highIV: Int { (stats.stats?.mons ?? []).filter { $0.pct >= 90 }.count }

    private func number(_ value: Int, _ label: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted())
                .font(.system(size: 18, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }
}

/// "This run": what the run that just finished actually did, and the reminder to check the Delete tag
/// before transferring anything.
struct ThisRunCard: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @ObservedObject private var stats = StatsStore.shared

    var body: some View {
        let slices = IVSlice.all(config: store.config, mons: stats.stats?.mons ?? [])
        PanelCard {
            RunPanelTitle(tr("Tenhle běh", "This run"), note: duration)

            HStack(spacing: 18) {
                IVDonut(slices: slices, inner: Theme.surface) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.green)
                    Text(runner.stats.measured.formatted())
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                    Text(tr("změřeno", "measured"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        result(runner.stats.removable, store.config.removeTag, color: Theme.red)
                        result(runner.stats.pvpTagged, tr("PvP tagy", "PvP tags"))
                    }
                    GridRow {
                        result(runner.stats.renamed, tr("Přejmenováno", "Renamed"))
                        result(runner.stats.errors, tr("Vyřešené chyby", "Recovered errors"))
                    }
                }
                Spacer(minLength: 0)
            }

            NoticeBox(symbol: "exclamationmark.triangle.fill",
                      text: tr("Než budeš cokoli přenášet, zkontroluj si tag \(store.config.removeTag) ve hře.",
                               "Check the \(store.config.removeTag) tag in the game before you transfer anything."))

            ResultsFolderButton(outlined: true)
        }
    }

    private var duration: String {
        guard let start = runner.startedAt, let end = runner.finishedAt else { return "" }
        let t = max(0, Int(end.timeIntervalSince(start)))
        return t < 60 ? tr("\(t) s", "\(t)s") : tr("\(t / 60) min \(t % 60) s", "\(t / 60) min \(t % 60)s")
    }

    private func result(_ value: Int, _ label: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted())
                .font(.system(size: 18, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .gridColumnAlignment(.leading)
    }
}

/// The log, cut down to the last three lines – the whole of it is in the results folder.
struct RunLogCard: View {
    /// After a run that ended badly the log opens wider, so the last thing the bot said is readable.
    var expanded = false

    @EnvironmentObject private var runner: Runner
    @ObservedObject private var log = Runner.shared.log
    @State private var copied = false

    private static let ink = Color.oklch(0.8, 0.015, 280)
    private static let dim = Color.oklch(0.6, 0.02, 280)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(tr("Výpis", "Log"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.oklch(0.86, 0.015, 280))
                Text(trCount(log.lines.count, cs: "řádek", "řádky", "řádků", en: "line", "lines"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Self.dim)
                Spacer(minLength: 0)
                DarkIconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                               tint: copied ? Theme.green : nil,
                               help: tr("Zkopírovat celý výpis", "Copy the whole log")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .disabled(log.lines.isEmpty)
                DarkIconButton(symbol: "arrow.up.left.and.arrow.down.right",
                               help: tr("Otevřít složku s výsledky", "Open the results folder")) { runner.openResults() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 34)

            if log.lines.isEmpty {
                Text(tr("Zatím nic. Výpis se plní během běhu.", "Nothing yet. The log fills up during a run."))
                    .font(.system(size: 11))
                    .foregroundStyle(Self.dim)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(log.lines.suffix(expanded ? 10 : 3)) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.text.first?.isNumber == true ? Self.ink : Self.dim)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: 19, alignment: .leading)      // line-height 1.7
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .background(Color.oklch(0.15, 0.022, 278))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
