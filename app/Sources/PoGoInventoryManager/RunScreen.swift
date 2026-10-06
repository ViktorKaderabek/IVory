import SwiftUI

/// The Run screen: what a run will do, what it is doing, and what it did.
///
/// The steps are a vertical pipeline instead of a row of cards – it reads in the order things happen,
/// and it leaves room on the right for the panel that matters while the bot works: the Pokémon it is
/// reading this second.
struct RunScreen: View {
    @Binding var fresh: Bool
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @ObservedObject private var state = RunScreenState.shared

    /// The width of the column on the right, as in the design.
    static let sideWidth: CGFloat = 336
    /// The right column starts level with the first step, not with the "Steps" heading.
    private static let sideTop: CGFloat = 40

    /// While the bot works the step it is on opens by itself, but any step can still be opened by hand –
    /// the settings are only locked, not hidden.
    private var openStep: Runner.Step? {
        if state.touched { return state.expanded }
        return runner.isRunning ? Runner.Step(rawValue: max(1, runner.stats.phase)) : state.expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            RunHero(fresh: $fresh)
            WeightedColumns(weights: [1, 0], spacing: 24,
                            fixed: [nil, Self.sideWidth], tops: [0, Self.sideTop]) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    pipeline
                }
                sidePanel
            }
        }
        .animation(.easeInOut(duration: 0.25), value: runner.isRunning)
        .onChange(of: runner.startedAt) { _, _ in state.followTheRun() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tr("Kroky", "Steps"))
                .font(.system(size: 17, weight: .medium))
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
    }

    private var note: String {
        if runner.isRunning { return tr("během třídění se nastavení nemění", "settings are locked while sorting") }
        if runner.outcome != nil { return tr("co který krok udělal", "what each step did") }
        return tr("v tomhle pořadí · klepnutím krok rozbalíš", "in this order · open a step to change how it works")
    }

    private var pipeline: some View {
        VStack(spacing: 0) {
            ForEach(Runner.Step.allCases) { step in
                StepRow(model: model(for: step),
                        toggleExpand: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                                state.touched = true
                                state.expanded = openStep == step ? nil : step
                            }
                        },
                        toggle: {
                            guard !(step.isOn(store.config.steps) && store.config.steps.count == 1) else {
                                NSSound.beep()
                                return
                            }
                            var s = store.config.steps
                            step.set(&s, !step.isOn(s))
                            store.config.steps = s
                        })
                .equatable()
            }
        }
    }

    /// What the step is doing now, or what it did – otherwise what it is set up to do.
    private func subtitle(_ step: Runner.Step, on: Bool, ready: Bool, running: Bool, finished: Bool) -> String {
        let c = store.config
        if !on && !ready { return tr("Vypnuto", "Off") }
        if running {
            if step == .iv, let s = runner.scanned {
                return tr("\(s.done) z \(s.total) · čtu IV", "\(s.done) of \(s.total) · reading IV")
            }
            return tr("probíhá…", "running…")
        }
        if finished {
            switch step {
            case .duplicates: return tr("\(runner.stats.removable) označeno \(c.removeTag)", "\(runner.stats.removable) tagged \(c.removeTag)")
            case .iv: return tr("\(runner.stats.ivTagged) otagováno", "\(runner.stats.ivTagged) tagged")
            case .pvp: return tr("\(runner.stats.pvpTagged) do lig", "\(runner.stats.pvpTagged) into leagues")
            case .rename: return tr("\(runner.stats.renamed) přejmenováno", "\(runner.stats.renamed) renamed")
            case .battle: return tr("\(runner.stats.battleTagged) otagováno", "\(runner.stats.battleTagged) tagged")
            case .weak: return tr("\(runner.stats.weakTagged) označeno", "\(runner.stats.weakTagged) tagged")
            }
        }
        let plan = planned(step)
        return ready ? plan : tr("Čeká · \(plan)", "Waiting · \(plan)")
    }

    /// What the step will do with the settings as they stand.
    private func planned(_ step: Runner.Step) -> String {
        let c = store.config
        switch step {
        case .duplicates:
            return tr("Horší duplicity dostanou \(c.removeTag) · nechat \(c.keepBest) na druh",
                      "Worse duplicates get \(c.removeTag) · keep \(c.keepBest) per species")
        case .iv:
            let names = c.ivTags.sorted { $0.min > $1.min }.map { $0.name.isEmpty ? tr("Bez názvu", "Untitled") : $0.name }
            let head = names.prefix(3).joined(separator: ", ")
            return tr("\(c.ivTags.count) tagů · \(head)\(names.count > 3 ? "…" : "")",
                      "\(c.ivTags.count) tags · \(head)\(names.count > 3 ? "…" : "")")
        case .pvp:
            return tr("Great, Ultra a Master · rank do \(c.pvp.great.maxRank)",
                      "Great, Ultra and Master League · rank up to \(c.pvp.great.maxRank)")
        case .rename:
            return tr("IV \(pctRange(c.rename.min, c.rename.max)) · podle tvé šablony",
                      "IV \(pctRange(c.rename.min, c.rename.max)) · by your template")
        case .battle:
            return tr("Raid útočníci a tři vybrané PvP týmy", "Raid attackers and the 3 picked PvP teams")
        case .weak:
            let kept = [c.weak.keepLegendary, c.weak.keepMythical, c.weak.keepUltraBeast,
                        c.weak.keepRegional, c.weak.keepBest, c.weak.keepBattle].filter { $0 }.count
            return tr("Pod \(percentText(c.weak.maxIV)) IV dostanou \(c.removeTag) · \(kept) pojistek",
                      "Under \(percentText(c.weak.maxIV)) IV get \(c.removeTag) · \(kept) kinds kept")
        }
    }

    /// Everything a step's row draws, as plain values. The rows used to read the settings themselves, so a
    /// change to any of them – a keystroke in a tag name – redrew all six; now only the row that actually
    /// says something different is rebuilt.
    private func model(for step: Runner.Step) -> StepRow.Model {
        let on = step.isOn(store.config.steps)
        let ready = !runner.isRunning && runner.outcome == nil
        let running = runner.isRunning && runner.stats.phase == step.rawValue
        let finished = on && (runner.stats.phase > step.rawValue || (runner.outcome == .done && !runner.isRunning))
        return StepRow.Model(step: step,
                             isLast: step == Runner.Step.allCases.last,
                             expanded: openStep == step,
                             on: on, ready: ready, running: running, finished: finished,
                             subtitle: subtitle(step, on: on, ready: ready, running: running, finished: finished))
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if runner.isRunning {
                    if runner.isReading { NowReadingPanel() } else { RunTagChart() }
                } else if runner.outcome != nil {
                    ThisRunCard()
                } else {
                    StorageNowCard()
                }
            }
            .transition(.opacity)       // the card swaps in place instead of sliding in from the side
            // the log is always there: when a run fails this is where the reason is
            RunLogCard(expanded: runner.outcome == .failed)
        }
    }
}
