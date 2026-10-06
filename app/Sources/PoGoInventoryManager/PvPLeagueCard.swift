import SwiftUI

// One league on the PvP screen: the team it suggests and the matchup grid underneath.

struct LeagueCard: View {
    let league: PvPLeague
    let result: PvPResult?
    let teamIndex: Int
    let selected: Bool
    let color: Color
    let tag: String
    let pick: () -> Void
    let pickCombo: (Int) -> Void

    @ObservedObject private var battle = BattleStore.shared
    @State private var copied = false
    @State private var copiedNames = false

    private var team: PvPTeam? {
        guard let result, !result.teams.isEmpty else { return nil }
        return result.teams[min(teamIndex, result.teams.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            members
            footer
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(league.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(league.limit).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let result, result.teams.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(Array(result.teams.prefix(4).enumerated()), id: \.offset) { i, _ in
                            Button { pickCombo(i) } label: {
                                Text("\(i + 1)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(i == teamIndex ? Theme.onAccent : Theme.muted)
                                    .frame(minWidth: 26, minHeight: 22)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(i == teamIndex ? Theme.accent : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(tr("Kombinace \(i + 1)", "Combination \(i + 1)"))
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
                }
                Text(teamIndex == 0 ? tr("doporučeno", "recommended") : tr("jiná díra", "a different gap"))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                if let team {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(team.score)").font(.system(size: 18, weight: .medium).monospacedDigit())
                        Text(tr("skóre", "score")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var members: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle().fill(Theme.border).frame(height: 1)
                if let m = team?.members[safe: i] {
                    HStack(spacing: 12) {
                        MonIcon(m: m.mon, size: 40, circle: true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(m.role.title.uppercased())
                                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                                .foregroundStyle(Theme.muted)
                            Text(m.formName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if m.powerUp {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.accentInk)
                                .help(tr("Potřebuje vylepšit", "Needs a power-up"))
                        }
                        Text("#\(m.rank)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(Theme.muted, lineWidth: 1.5).opacity(0.6))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tr("CHYBÍ", "MISSING"))
                                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                                .foregroundStyle(Theme.gold)
                            Text(tr("Zatím není třetí do party", "No third fit yet"))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let team {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield").font(.system(size: 12))
                        Text(tr("zvládne \(team.answered) z \(team.faced)", "handles \(team.answered) of \(team.faced)"))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(team.answered == team.faced ? Theme.green : Theme.muted)
                }
                Spacer(minLength: 4)
                if !tag.isEmpty {
                    Text("#\(tag)")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raise))
                        .lineLimit(1)
                    copyButton(what: "#" + tag, done: $copied,
                               help: tr("Zkopírovat hledání podle tagu", "Copy the search by tag"))
                }
            }
            // the tag only finds them once a run has put it on them; these names find them right now,
            // and the user can read them without copying anything
            if !names.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(names)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyButton(what: names, done: $copiedNames,
                               help: tr("Zkopírovat jména těchhle tří ze hry",
                                        "Copy these three Pokémon's in-game names"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func copyButton(what: String, done: Binding<Bool>, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(what, forType: .string)
            done.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { done.wrappedValue = false }
        } label: {
            Image(systemName: done.wrappedValue ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(done.wrappedValue ? Theme.green : Theme.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The three Pokémon as the game knows them – that is what its search understands.
    private var names: String {
        (team?.members ?? []).map(\.mon.gameName).filter { !$0.isEmpty }.joined(separator: ", ")
    }

}

/// Rows are the team's members, columns the league's most played: who wins what.
struct MatchupMatrix: View {
    let league: PvPLeague
    let team: PvPTeam
    @ObservedObject private var battle = BattleStore.shared

    /// How many opponents fit across the window without turning into slivers.
    private static let columns = 8

    private var threats: [PvPTeam.Threat] { Array(team.threats.prefix(Self.columns)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tr("\(league.name) proti nejhranějším", "\(league.name) against the most played"))
                    .font(.system(size: 17, weight: .medium))
                Text(coverage).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    legend(Theme.greenTint, tr("vyhraje", "win"))
                    legend(Theme.raise, tr("těsné", "close"))
                    legend(Theme.redTint, tr("prohraje", "loss"))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            }

            VStack(spacing: 0) {
                opponentRow
                ForEach(Array(team.members.enumerated()), id: \.offset) { i, m in
                    row(label: m.formName, cells: threats.map { $0.cells[safe: i] ?? 0 }, rank: i)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                row(label: tr("Tým", "Team"), cells: nil, rank: 3)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        }
    }

    private var coverage: String {
        let gaps = team.gaps.compactMap { battle.data?.battle?.pokemon[$0]?.name }
        if team.answered >= team.faced {
            return tr("na všech \(team.faced) má odpověď", "it has an answer to all \(team.faced)")
        }
        if gaps.isEmpty {
            return tr("zvládne \(team.answered) z \(team.faced)", "handles \(team.answered) of \(team.faced)")
        }
        return tr("zvládne \(team.answered) z \(team.faced) · díry: \(BattleFormat.list(gaps))",
                  "handles \(team.answered) of \(team.faced) · gaps: \(BattleFormat.list(gaps))")
    }

    /// The label column plus one column per opponent, each proposed its exact width.
    private var matrixColumns: WeightedColumns {
        WeightedColumns(weights: [0] + Array(repeating: 1, count: threats.count), spacing: 6,
                        fixed: [150] + Array(repeating: CGFloat?.none, count: threats.count))
    }

    private var opponentRow: some View {
        matrixColumns {
            Color.clear.frame(width: 150, height: 1)
            ForEach(threats) { th in
                VStack(spacing: 4) {
                    PokeImage(dex: battle.data?.battle?.pokemon[th.opponent]?.dex, sid: th.opponent, kind: .icon, size: 30)
                    Text(battle.data?.battle?.pokemon[th.opponent]?.name ?? th.opponent)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// One member's row, or the summary row when `cells` is nil.
    private func row(label: String, cells: [Int]?, rank: Int) -> some View {
        matrixColumns {
            Text(label)
                .font(.system(size: 13, weight: cells == nil ? .semibold : .medium))
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            ForEach(Array(threats.enumerated()), id: \.offset) { i, th in
                Group {
                    if let cells {
                        cell(cells[safe: i] ?? 0)
                    } else {
                        Image(systemName: th.covered ? "checkmark.shield" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(th.covered ? Theme.green : Theme.red)
                            .frame(height: 26)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(th.covered ? Theme.greenTint.opacity(0.5) : Theme.redTint))
                    }
                }
                .frame(maxWidth: .infinity)
                .pops(0.05 + 0.05 * Double(i) + 0.03 * Double(rank))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func cell(_ value: Int) -> some View {
        let (symbol, color, background): (String, Color, Color) =
            value > 0 ? ("checkmark", Theme.green, Theme.greenTint)
            : value < 0 ? ("xmark", Theme.red, Theme.redTint)
            : ("equal", Theme.muted, Theme.raise)
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(text)
        }
    }
}
