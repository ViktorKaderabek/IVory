import SwiftUI

/// PvP teams: all three leagues side by side, each with the team IVory would tag and a switcher between
/// the combinations it found. Under them, how the chosen league's team does against the most played
/// Pokémon in it.
struct PvPScreen: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var battle = BattleStore.shared
    @ObservedObject private var statsStore = StatsStore.shared
    var startRun: () -> Void

    @AppStorage("pvpLeague") private var league = PvPLeague.great
    /// Which combination is shown per league (nil = the one IVory picked).
    @ObservedObject private var state = PvPScreenState.shared

    private var mons: [InventoryStats.Mon] { statsStore.stats?.mons ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let stats = statsStore.stats, stats.isEmpty {
                NeverRun(startRun: startRun)
            } else if battle.data?.battle == nil {
                Color.clear.frame(height: 200)
            } else {
                leagueCards
                if let team = team(for: league) {
                    MatchupMatrix(league: league, team: team)
                    if !team.bench.isEmpty { bench(team) }
                }
                Text(tr("Skóre, role a matchupy jsou z žebříčků PvPoke; zbytek IVory dopočítá podle typů útoků. Odhad z veřejných dat, ne simulace souboje.",
                        "Scores, roles and matchups are from the PvPoke rankings; IVory fills in the rest by the move types. An estimate from public data, not a battle simulation."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            battle.appear()
            battle.buildTeams(mons)
        }
        .onReceive(statsStore.$stats) { battle.buildTeams($0?.mons ?? []) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("PvP týmy", "PvP teams")).font(.system(size: 26, weight: .medium))
            Text(tr("Jeden tým na ligu z tvého úložiště. Žádný tým neporazí všechno; vybraný tým dostane ve hře tag ligy.",
                    "One team per league from your storage. No team beats everything; the picked team gets the league tag in the game."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The three leagues

    private var leagueCards: some View {
        WeightedColumns(weights: [1, 1, 1], spacing: 12) {
            ForEach(Array(PvPLeague.allCases.enumerated()), id: \.element) { i, l in
                LeagueCard(league: l,
                           result: battle.teams[l],
                           teamIndex: index(for: l),
                           selected: league == l,
                           color: color(l),
                           tag: store.config.battle.team(l).name,
                           pick: { withAnimation(.easeOut(duration: 0.18)) { league = l } },
                           pickCombo: { i in
                               withAnimation(.easeOut(duration: 0.18)) {
                                   state.combo[l] = i
                                   league = l
                               }
                           })
                .pops(0.05 * Double(i))
            }
        }
    }

    /// Which combination is shown: the one the user clicked, otherwise the team tagged in the game,
    /// otherwise IVory's own first choice.
    private func index(for l: PvPLeague) -> Int {
        if let i = state.combo[l] { return i }
        guard let r = battle.teams[l] else { return 0 }
        if let chosen = battle.chosenTeam(r, store.config.battle.team(l)),
           let i = r.teams.firstIndex(where: { $0.id == chosen.id }) { return i }
        return 0
    }

    private func team(for l: PvPLeague) -> PvPTeam? {
        guard let r = battle.teams[l], !r.teams.isEmpty else { return nil }
        return r.teams[min(index(for: l), r.teams.count - 1)]
    }

    private func color(_ l: PvPLeague) -> Color {
        (store.config.pvp.all.first { $0.key == l.rawValue }?.league.color ?? .purple).swatch
    }

    // MARK: - Bench

    private func bench(_ team: PvPTeam) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tr("Lavička", "Bench")).font(.system(size: 17, weight: .medium))
                Text(tr("vyměň jednoho a díra se zavře", "swap one in to close a gap"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(team.bench.prefix(3)) { b in
                    HStack(spacing: 10) {
                        MonIcon(m: b.member.mon, size: 36, circle: true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(b.member.formName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(tr("rank #\(b.member.rank)", "rank #\(b.member.rank)"))
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                            }
                            Text(b.beats.isEmpty
                                 ? tr("další silný kus do ligy", "another strong pick for the league")
                                 : tr("zavře díru proti \(BattleFormat.list(b.beats))",
                                      "closes the gap against \(BattleFormat.list(b.beats))"))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(b.member.ranking.score.rounded()))")
                                .font(.system(size: 15, weight: .medium).monospacedDigit())
                            Text(tr("skóre", "score")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                }
            }
        }
    }
}
