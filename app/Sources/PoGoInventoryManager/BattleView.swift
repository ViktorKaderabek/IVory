import SwiftUI

/// The Battle screen: the best six from the storage against the current raid bosses with the win chance by the
/// number of players, several PvP teams for each league, and where stardust makes the most difference. Everything is an estimate from public data
/// (BattleCalc.swift); the bosses come from ScrapedDuck once a day (BattleData.swift).
struct BattleView: View {
    enum Tab: String { case raid, pvp, upgrades }

    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var statsStore = StatsStore.shared
    @ObservedObject private var battle = BattleStore.shared
    private let preloaded: InventoryStats?
    /// Empty state: switches to the overview and starts a run.
    var startRun: () -> Void

    @AppStorage("battleTab") private var tab = Tab.raid
    @AppStorage("battleLeague") private var league = PvPLeague.great
    @State private var bossID: String?
    @State private var weather = "none"
    @State private var players: Int?
    @State private var query = ""
    @State private var width: CGFloat = 1000
    @State private var openTeamID: String?

    /// `preloaded` is only for windowless snapshots.
    init(preloaded: InventoryStats? = nil, startRun: @escaping () -> Void) {
        self.preloaded = preloaded
        self.startRun = startRun
    }

    private var stats: InventoryStats? { preloaded ?? statsStore.stats }
    private var mons: [InventoryStats.Mon] { stats?.mons ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let stats {
                if stats.isEmpty { NeverRun(startRun: startRun) }
                else if battle.data?.battle == nil { DataState(state: battle.dataState, startRun: startRun) }
                else if tab == .raid { raids }
                else if tab == .pvp { pvp }
                else { UpgradesView(mons: mons) }
            } else {
                Color.clear.frame(height: 400)
                    .onAppear { statsStore.refresh(removeTag: store.config.removeTag) }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
        })
        .onAppear {
            battle.appear()
            battle.buildTeams(mons)
        }
        .onReceive(statsStore.$stats) { s in if preloaded == nil { battle.buildTeams(s?.mons ?? []) } }   // after every run
        .onChange(of: league) { _, _ in openTeamID = nil }
        .onAppear(perform: focus)
        .onChange(of: battle.focusBoss) { _, _ in focus() }
        .onChange(of: battle.focusUpgrade) { _, key in
            if key != nil { withAnimation(.snappy(duration: 0.2)) { tab = .upgrades } }
        }
        .onChange(of: battle.data == nil) { _, _ in battle.buildTeams(mons) }
    }

    /// A boss from a notification: the Raids tab with that boss.
    private func focus() {
        guard let name = battle.focusBoss else { return }
        battle.focusBoss = nil
        tab = .raid
        bossID = name
        weather = "none"
        players = nil
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Battle").font(.system(size: 28, weight: .medium)).tracking(-0.56)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            if !(stats?.isEmpty ?? true) {
                Segmented(items: [(Tab.raid, tr("Raidy", "Raids"), "shield.lefthalf.filled"), (Tab.pvp, tr("PvP týmy", "PvP teams"), "trophy"),
                                  (Tab.upgrades, tr("Vylepšení", "Power-ups"), "arrow.up.circle")],
                          selection: $tab, height: 30)
            }
        }
    }

    private var subtitle: String {
        if stats?.isEmpty ?? true { return tr("Raidy a PvP týmy z tvého úložiště", "Raids and PvP teams from your storage") }
        switch tab {
        case .raid: return tr("Nejlepší šestice z tvého úložiště proti aktuálním bossům", "The best six from your storage against the current bosses")
        case .pvp: return tr("Několik týmů z tvého úložiště pro každou ligu a proti komu fungují", "Several teams from your storage for each league, and whom they work against")
        case .upgrades: return tr("Kam dát stardust, aby to bylo nejvíc znát", "Where stardust makes the most difference")
        }
    }

    // MARK: - Raids

    @ViewBuilder private var raids: some View {
        VStack(alignment: .leading, spacing: 16) {
            if battle.bossState == .offline { OfflineBanner(date: battle.bossesAt) }
            if battle.bossState == .failed {
                NoBosses(retry: battle.retry) { tab = .pvp }
            } else if battle.bosses.isEmpty {
                RaidSkeleton(wide: width >= 860)
            } else {
                if width >= 860 {
                    HStack(alignment: .top, spacing: 28) {
                        bossList(compact: false).frame(width: 272)
                        bossDetail.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        bossList(compact: true)
                        bossDetail
                    }
                }
            }
        }
    }

    private struct BossGroup: Identifiable {
        let tier: RaidTier
        let bosses: [RaidBoss]
        var id: RaidTier { tier }
    }

    private var groups: [BossGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = battle.bosses.filter { q.isEmpty || $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return RaidTier.allCases.compactMap { t in
            let list = shown.filter { $0.tier == t }
            return list.isEmpty ? nil : BossGroup(tier: t, bosses: list)
        }
    }

    private var boss: RaidBoss? {
        let all = RaidTier.allCases.flatMap { t in battle.bosses.filter { $0.tier == t } }
        return all.first { $0.id == bossID } ?? all.first
    }

    private func select(_ b: RaidBoss) {
        guard b.id != boss?.id else { return }
        bossID = b.id
        weather = "none"
        players = nil
    }

    private func bossList(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField(tr("Hledat bosse", "Search bosses"), text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
            .frame(maxWidth: compact ? 320 : .infinity)

            let gs = groups
            if compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(gs.flatMap(\.bosses)) { b in BossRow(boss: b, selected: b.id == boss?.id, compact: true) { select(b) } }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(gs) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.tier.label.uppercased())
                                .font(.system(size: 11, weight: .semibold)).tracking(0.66)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 10).padding(.bottom, 4)
                            ForEach(g.bosses) { b in BossRow(boss: b, selected: b.id == boss?.id, compact: false) { select(b) } }
                        }
                    }
                }
            }
            if gs.isEmpty {
                Text(tr("Žádný boss neodpovídá hledání.", "No boss matches the search."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.horizontal, 10).padding(.vertical, 8)
            }
            Text(sourceLine)
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 10).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceLine: String {
        let when = battle.bossesAt.map(BattleFormat.when) ?? "–"
        return battle.bossState == .offline
            ? tr("Bossové ze ScrapedDuck · uloženo \(when) · offline", "Bosses from ScrapedDuck · saved \(when) · offline")
            : tr("Bossové ze ScrapedDuck · staženo \(when) · obnova denně", "Bosses from ScrapedDuck · downloaded \(when) · refreshed daily")
    }

    @ViewBuilder private var bossDetail: some View {
        if let boss {
            let boost = boss.weather.filter { battle.data?.battle?.weather[$0] != nil }
            let w = boost.contains(weather) ? weather : "none"
            VStack(alignment: .leading, spacing: 20) {
                BossHeader(boss: boss, weathers: boost, weather: Binding(get: { w }, set: { weather = $0 }))
                if boss.form == nil {
                    InfoCard(symbol: "hourglass", color: Theme.blue, tint: Theme.blueTint,
                             title: tr("\(boss.name) je nový boss a IVory ho v datech ještě nemá", "\(boss.name) is a new boss and IVory doesn't have it in its data yet"),
                             text: tr("Bez statů a útoků bosse se countery spočítat nedají. Data PvPoke se obnovují jednou týdně, takže se tu do týdne objeví nejlepší šestice i šance na výhru.",
                                      "Without the boss's stats and moves the counters can't be worked out. The PvPoke data is refreshed once a week, so the best six and the win chance show up here within a week."))
                } else if let result = battle.counters(boss, weather: w, mons: mons), !result.counters.isEmpty {
                    WeightedRow(weights: [1.15, 1], spacing: 16, minColumn: 380) {
                        ChanceCard(chances: result.chances, shadow: boss.tier.isShadow, players: $players)
                        DetailButton(radius: 16, edge: .bottom) {
                            BestPick(c: result.counters[0], boss: boss)
                        } detail: {
                            RaidDetail(c: result.counters[0], boss: boss, weather: w, best: result.counters[0].strength)
                        }
                    }
                    // four columns as in the design once the detail is wide enough, else two lines per row
                    PartyList(counters: result.counters, boss: boss, weather: w, wide: (width >= 860 ? width - 300 : width) >= 820)
                    GameSearch(boss: boss)
                } else {
                    InfoCard(symbol: "questionmark.circle", color: Theme.muted, tint: Theme.raise,
                             title: tr("Zatím není koho doporučit", "No one to recommend yet"),
                             text: tr("IVory u tvých Pokémonů ještě nezná druh a level. Doplní se při příštím běhu.",
                                      "IVory doesn't know the species and level of your Pokémon yet. They fill in on the next run."))
                }
            }
            .id(boss.id)
        }
    }

    // MARK: - PvP

    private var pvp: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let r = battle.teams[league] {
                LeagueCards(selection: $league, chosen: combo, config: store.config.battle)
                if r.teams.isEmpty {
                    InfoCard(symbol: "person.badge.plus", color: Theme.muted, tint: Theme.raise,
                             title: tr("Do \(league.name) se ti zatím nevejde žádný vhodný Pokémon", "No suitable Pokémon fits the \(league.name) yet"),
                             text: league.cap.map { tr("Ostatní mají CP nad \(BattleFormat.number($0)) a CP se snížit nedá. Týmy se objeví, až IVory přečte vhodné kusy.",
                                                      "The others are over \(BattleFormat.number($0)) CP and CP can't go down. Teams show up once IVory reads suitable ones.") }
                                 ?? tr("Týmy se objeví, až IVory přečte vhodné kusy.", "Teams show up once IVory reads suitable ones."))
                } else if let team = chosen(r) {
                    Combos(result: r, chosen: team, hint: comboHint(r)) { pick in
                        store.config.battle.setTeam(league, pick.members.map(\.form))
                    }
                    TeamHeader(league: league, team: team, tag: tagName, battleStep: store.config.steps.battle)
                    WeightedRow(weights: [1, 1, 1], spacing: 12, minColumn: 230) {
                        ForEach(team.members) { m in MemberCard(m: m, league: league) }
                        ForEach(0..<(3 - team.members.count), id: \.self) { _ in MissingCard(present: team.members.count, league: league) }
                    }
                    WeightedRow(weights: team.bench.isEmpty ? [1] : [1.35, 1], spacing: 16, minColumn: 320) {
                        CoverageTable(team: team)
                        if !team.bench.isEmpty { BenchList(team: team) }
                    }
                }
                Note(text: tr("Skóre, role a zápasy jsou z žebříčků PvPoke, porovnání s typy útoků doplňuje IVory. Je to odhad z veřejných dat, ne simulace souboje.",
                              "Scores, roles and matchups are from the PvPoke rankings; IVory fills in the rest by the move types. An estimate from public data, not a battle simulation."))
            } else {
                PvPSkeleton()
            }
        }
    }

    /// The team the league's tag is on: the one picked in the settings, otherwise IVory's first.
    private func chosen(_ r: PvPResult) -> PvPTeam? {
        battle.chosenTeam(r, store.config.battle.team(league)) ?? r.teams.first
    }

    private var combo: (PvPLeague) -> PvPTeam? {
        { league in
            guard let r = battle.teams[league] else { return nil }
            return battle.chosenTeam(r, store.config.battle.team(league)) ?? r.teams.first
        }
    }

    private var tagName: String? {
        let tag = store.config.battle.team(league)
        return tag.enabled && !tag.name.isEmpty ? tag.name : nil
    }

    private func comboHint(_ r: PvPResult) -> String {
        guard r.teams.count > 1 else {
            return tr("Z tvého úložiště jde složit jen tenhle tým, porovnaný s \(r.meta.count) nejhranějšími Pokémony ligy.",
                      "Your storage makes just this one team, compared with the league's \(r.meta.count) most played Pokémon.")
        }
        return tr("Žádný tým neporazí všechno. Vyber podle soupeřů, na které v lize nejčastěji narážíš; vybraný tým dostane ve hře tag.",
                  "No team beats everything. Pick by the opponents you meet most in the league; the picked team gets the tag in the game.")
    }
}

// MARK: - PvP overview

/// All three leagues at a glance: who's in the team and what it still needs.
private struct LeagueCards: View {
    @Binding var selection: PvPLeague
    let chosen: (PvPLeague) -> PvPTeam?
    let config: BattleConfig

    var body: some View {
        WeightedRow(weights: [1, 1, 1], spacing: 12, minColumn: 230) {
            ForEach(PvPLeague.allCases) { league in
                card(league)
            }
        }
    }

    private func card(_ league: PvPLeague) -> some View {
        let team = chosen(league)
        let on = league == selection
        let needs = team?.members.filter(\.powerUp) ?? []
        let missing = 3 - (team?.members.count ?? 0)
        return Button { withAnimation(.snappy(duration: 0.2)) { selection = league } } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(BattleFormat.leagueColor(league)).frame(width: 9, height: 9)
                    Text(league.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(league.cap.map { "\(BattleFormat.number($0)) CP" } ?? tr("bez limitu", "no cap"))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    Avatars(members: team?.members ?? [], missing: missing)
                }
                status(needs: needs, missing: missing)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Ukázat \(league.name)", "Show the \(league.name)"))
    }

    @ViewBuilder private func status(needs: [PvPMember], missing: Int) -> some View {
        let dust = needs.map { BattleStore.shared.price($0).stardust }.reduce(0, +)
        HStack(spacing: 8) {
            if !needs.isEmpty {
                Image(systemName: "arrow.up.circle").font(.system(size: 14)).foregroundStyle(Theme.accentInk)
                Text(trCount(needs.count, cs: "vylepšení", "vylepšení", "vylepšení", en: "power-up", "power-ups"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentInk)
                Text("\(BattleFormat.number(dust)) stardust" + (missing > 0 ? tr(" · chybí člen", " · a member missing") : ""))
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
            } else if missing > 0 {
                Image(systemName: "person.badge.plus").font(.system(size: 14)).foregroundStyle(Theme.gold)
                Text(trCount(missing, cs: "člen chybí", "členové chybí", "členů chybí", en: "member missing", "members missing"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.gold)
            } else {
                Image(systemName: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Theme.green)
                Text(tr("Připravený", "Ready")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.green)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Overlapping round pictures of a team, with dashes for the members it still lacks.
private struct Avatars: View {
    let members: [PvPMember]
    var missing = 0
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: -6) {
            ForEach(members) { m in
                MonIcon(m: m.mon, size: size, circle: true)
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
            }
            ForEach(0..<max(0, missing), id: \.self) { _ in
                Circle().strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Theme.surface))
            }
        }
    }
}

/// The league's team options: the one that is tagged in the game is highlighted.
private struct Combos: View {
    let result: PvPResult
    let chosen: PvPTeam
    let hint: String
    let onPick: (PvPTeam) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tr("Kombinace", "Combinations")).font(.system(size: 17, weight: .medium))
                Text(hint).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            WeightedRow(weights: Array(repeating: 1, count: max(1, result.teams.count)), spacing: 10, minColumn: 205) {
                ForEach(Array(result.teams.enumerated()), id: \.element.id) { i, t in
                    card(i, t)
                }
            }
        }
    }

    private func card(_ index: Int, _ t: PvPTeam) -> some View {
        let on = t.id == chosen.id
        let needs = t.members.filter(\.powerUp)
        let missing = 3 - t.members.count
        return Button { withAnimation(.snappy(duration: 0.2)) { onPick(t) } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(tr("Kombinace \(index + 1)", "Combination \(index + 1)")).font(.system(size: 13, weight: .semibold))
                    if index == 0 {
                        Text(tr("doporučeno", "recommended")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Spacer(minLength: 4)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(t.score)").font(.system(size: 16, weight: .medium)).monospacedDigit()
                        Text(tr("průměr", "average")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    .help(tr("Průměrné skóre členů v této lize podle PvPoke.", "The members' average PvPoke score in this league."))
                }
                HStack(spacing: 10) {
                    Avatars(members: t.members, missing: missing)
                    Text(t.members.map(\.formName).joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                HStack(spacing: 14) {
                    Label(tr("zvládne \(t.answered) z \(t.faced)", "handles \(t.answered) of \(t.faced)"), systemImage: "checkmark.shield")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(t.answered == t.faced ? Theme.green : Theme.muted)
                    if !needs.isEmpty {
                        Label(trCount(needs.count, cs: "vylepšení", "vylepšení", "vylepšení", en: "power-up", "power-ups"), systemImage: "arrow.up.circle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentInk)
                    } else if missing > 0 {
                        Label(trCount(missing, cs: "člen chybí", "členové chybí", "členů chybí", en: "member missing", "members missing"), systemImage: "person.badge.plus")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.gold)
                    } else {
                        Label(tr("Připravený", "Ready"), systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? tr("Tenhle tým dostane ve hře tag.", "This team gets the tag in the game.")
                 : tr("Vybrat: tenhle tým pak dostane ve hře tag při běhu s krokem Battle tagy.",
                      "Pick it: this team then gets the tag in the game on a run with the Battle tags step."))
    }
}

/// The chosen team's name, what it does and how to find it in the game.
private struct TeamHeader: View {
    let league: PvPLeague
    let team: PvPTeam
    let tag: String?
    let battleStep: Bool
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(league.name).font(.system(size: 19, weight: .medium)).tracking(-0.19).fixedSize()
            Text(BattleFormat.summary(team)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tag {
                HStack(spacing: 8) {
                    Text(tr("Ve hře", "In the game")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text("#\(tag)").font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("#\(tag)", forType: .string)
                        withAnimation(.snappy) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.snappy) { copied = false } }
                    } label: {
                        Label(copied ? tr("Zkopírováno", "Copied") : tr("Kopírovat", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(OutlineButtonStyle(height: 28))
                }
                .help(battleStep ? tr("Tag \(tag) dostane tenhle tým při běhu s krokem Battle tagy.",
                                      "This team gets the \(tag) tag on a run with the Battle tags step.")
                                 : tr("Tag \(tag) dá týmu krok Battle tagy. Zapni ho na Přehledu.",
                                      "The Battle tags step gives the team the \(tag) tag. Turn it on on the Overview."))
            }
        }
    }
}

/// How the team does against the league's most played: a win, a close call or a loss per member.
private struct CoverageTable: View {
    let team: PvPTeam
    @ObservedObject private var battle = BattleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tr("Proti nejhranějším", "Against the most played")).font(.system(size: 17, weight: .medium))
                Hint(BattleHints.coverage)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    legend(1, tr("vyhraje", "win"))
                    legend(0, tr("vyrovnané", "close"))
                    legend(-1, tr("prohraje", "loss"))
                }
            }
            Text(coverLine).font(.system(size: 13)).foregroundStyle(team.gaps.isEmpty ? Theme.green : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(tr("Soupeř", "Opponent")).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(team.members) { m in
                        Text(m.formName).frame(width: 72, alignment: .center).lineLimit(1).truncationMode(.tail)
                    }
                    Text(tr("Tým", "Team")).frame(width: 104, alignment: .trailing)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Theme.raise)
                ForEach(team.threats) { th in
                    Rectangle().fill(Theme.border).frame(height: 1)
                    HStack(spacing: 12) {
                        Text(battle.data?.battle?.pokemon[th.opponent]?.name ?? th.opponent)
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(th.cells.enumerated()), id: \.offset) { _, c in
                            cell(c).frame(width: 72)
                        }
                        Label(th.covered ? tr("zvládne", "handled") : tr("díra", "gap"),
                              systemImage: th.covered ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(th.covered ? Theme.green : Theme.red)
                            .frame(width: 104, alignment: .trailing).lineLimit(1)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
            }
            .card(radius: 14)
        }
    }

    private var coverLine: String {
        let gaps = team.gaps.compactMap { battle.data?.battle?.pokemon[$0]?.name }
        guard !gaps.isEmpty else {
            return tr("Tenhle tým má odpověď na všech \(team.threats.count) nejhranějších.",
                      "This team has an answer to all \(team.threats.count) most played.")
        }
        return tr("Zvládne \(team.threats.count - gaps.count) z \(team.threats.count). Díry: \(BattleFormat.list(gaps)).",
                  "Handles \(team.threats.count - gaps.count) of \(team.threats.count). Gaps: \(BattleFormat.list(gaps)).")
    }

    private func legend(_ value: Int, _ text: String) -> some View {
        HStack(spacing: 5) {
            cell(value, size: 16)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private func cell(_ value: Int, size: CGFloat = 24) -> some View {
        let look: (String, Color, Color) = value > 0 ? ("checkmark", Theme.green, Theme.greenTint)
            : value < 0 ? ("xmark", Theme.red, Theme.redTint) : ("equal", Theme.muted, Theme.raise)
        return Image(systemName: look.0)
            .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(look.1)
            .frame(width: size * 1.17, height: size)
            .background(look.2, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .help(value > 0 ? tr("vyhraje", "win") : value < 0 ? tr("prohraje", "loss") : tr("vyrovnané", "close"))
    }
}

/// What a bench candidate adds: the team's gaps it covers, or that it is simply strong.
@MainActor private func benchNote(_ m: PvPMember, _ beats: [String]) -> String {
    let evolve = m.evolves ? tr("vyvinout na \(m.formName), ", "evolve into \(m.formName), ") : ""
    guard !beats.isEmpty else { return evolve + tr("další silný kus do ligy", "another strong pick for the league") }
    return evolve + tr("zacelí díru proti \(BattleFormat.list(beats))", "closes the gap against \(BattleFormat.list(beats))")
}

/// The next best candidates, in case you want to swap someone.
private struct BenchList: View {
    let team: PvPTeam

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tr("Náhradníci", "Bench")).font(.system(size: 17, weight: .medium))
                Text(tr("další nejlepší kandidáti", "the next best candidates")).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            VStack(spacing: 0) {
                ForEach(Array(team.bench.enumerated()), id: \.element.id) { i, b in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    HStack(spacing: 12) {
                        MonIcon(m: b.member.mon, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(b.member.mon.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(tr("rank \(BattleFormat.rank(b.member.rank))", "rank \(BattleFormat.rank(b.member.rank))"))
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Text(benchNote(b.member, b.beats)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(Int(b.member.ranking.score.rounded()))").font(.system(size: 16, weight: .medium)).monospacedDigit()
                            Text(tr("skóre", "score")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .card(radius: 14)
        }
    }
}

// MARK: - States

/// The bot has never run: nothing to recommend from.
private struct NeverRun: View {
    let startRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SoftIcon(symbol: "figure.fencing", size: 56, radius: 16)
            Text(tr("Zatím není z čeho doporučovat", "Nothing to recommend from yet")).font(.system(size: 24, weight: .medium)).tracking(-0.48)
            Text(tr("IVory ještě nezná žádného tvého Pokémona. Po prvním běhu tu uvidíš nejlepší countery proti raid bossům, šanci na výhru a týmy pro PvP ligy.",
                    "IVory doesn't know any of your Pokémon yet. After the first run you'll see the best counters against raid bosses, the win chance and teams for the PvP leagues."))
                .font(.system(size: 15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button(action: startRun) { Label(tr("Spustit první běh", "Start the first run"), systemImage: "play.fill") }
                .buttonStyle(OutlineButtonStyle(height: 36))
                .padding(.top, 6)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: 520)
    }
}

/// The game data has no Battle part yet: it is downloading, or it will come with the next run.
private struct DataState: View {
    let state: BattleStore.DataState
    let startRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state == .missing {
                SoftIcon(symbol: "icloud.slash", color: Theme.red, background: Theme.redTint, size: 44, radius: 12)
                Text(tr("Herní data pro Battle chybí", "The game data for Battle is missing")).font(.system(size: 20, weight: .medium))
                Text(tr("Útoky, tabulka typů a žebříčky PvPoke se stáhnou při příštím běhu bota.",
                        "Moves, the type chart and the PvPoke rankings download on the bot's next run."))
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button(action: startRun) { Label(tr("Spustit běh", "Start a run"), systemImage: "play.fill") }
                    .buttonStyle(OutlineButtonStyle(height: 34))
            } else {
                HStack(spacing: 10) {
                    SoftIcon(symbol: "arrow.down.circle", size: 30, radius: 9)
                    Text(tr("Stahuji herní data pro Battle", "Downloading the game data for Battle")).font(.system(size: 20, weight: .medium))
                }
                Text(tr("Útoky, tabulka typů a žebříčky PvPoke, asi 22 MB. Stačí jednou týdně.",
                        "Moves, the type chart and the PvPoke rankings, about 22 MB. Once a week is enough."))
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                RaidSkeleton(wide: true).padding(.top, 12)
            }
        }
        .padding(state == .missing ? 40 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardIf(on: state == .missing))
    }
}

private struct OfflineBanner: View {
    let date: Date?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.system(size: 16)).foregroundStyle(Theme.gold)
            Text(text).font(.system(size: 13))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.goldTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var text: AttributedString {
        let when = date.map(BattleFormat.when) ?? "–"
        var bold = AttributedString(when)
        bold.font = .system(size: 13, weight: .semibold)
        return AttributedString(tr("Jsi offline. Bossové jsou z posledního stažení ", "You're offline. The bosses are from the last download, "))
            + bold + AttributedString(tr(", a mezitím se mohli změnit. PvP týmy fungují dál.", ", and may have changed since. PvP teams still work."))
    }
}

private struct NoBosses: View {
    let retry: () -> Void
    let openPvP: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SoftIcon(symbol: "icloud.slash", color: Theme.red, background: Theme.redTint, size: 44, radius: 12)
            Text(tr("Seznam bossů se nepodařilo stáhnout", "Couldn't download the boss list")).font(.system(size: 20, weight: .medium))
            Text(tr("Zdroj ScrapedDuck neodpovídá a uložený seznam zatím žádný není. Raidy se ukážou, až se seznam stáhne. PvP týmy fungují dál.",
                    "ScrapedDuck isn't answering and there's no saved list yet. Raids show up once the list downloads. PvP teams still work."))
                .font(.system(size: 14)).foregroundStyle(Theme.muted).frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: retry) { Label(tr("Zkusit znovu", "Try again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle(height: 34))
                Button(tr("Otevřít PvP týmy", "Open PvP teams"), action: openPvP)
                    .buttonStyle(GhostButtonStyle(color: Theme.muted, hover: Theme.raise, height: 34))
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}

private struct InfoCard: View {
    let symbol: String
    let color: Color
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SoftIcon(symbol: symbol, color: color, background: tint, size: 40, radius: 11)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 17, weight: .medium))
                Text(text).font(.system(size: 14)).foregroundStyle(Theme.muted).frame(maxWidth: 620, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .card(radius: 14)
    }
}

// MARK: - Bosses

private struct BossRow: View {
    let boss: RaidBoss
    let selected: Bool
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                BossPicture(boss: boss, size: 36, radius: 18, symbolSize: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(boss.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(boss.types.map(BattleType.name).joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if !compact { Spacer(minLength: 4) }
                if boss.form == nil {
                    Text(tr("nový", "new")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Theme.blueTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Theme.tint : hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The boss's picture from ScrapedDuck; until it loads (or when it doesn't), its first type's icon.
private struct BossPicture: View {
    let boss: RaidBoss
    let size: CGFloat
    let radius: CGFloat
    let symbolSize: CGFloat
    @State private var image: NSImage?

    /// A picture already in the cache shows right away (no type icon flashing first).
    @MainActor init(boss: RaidBoss, size: CGFloat, radius: CGFloat, symbolSize: CGFloat) {
        self.boss = boss
        self.size = size
        self.radius = radius
        self.symbolSize = symbolSize
        _image = State(initialValue: boss.image.flatMap(BossImages.cached))
    }

    var body: some View {
        let type = boss.types.first ?? "normal"
        ZStack {
            if let image {
                Theme.raise
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                BattleType.tint(type)
                Image(systemName: BattleType.symbol(type)).font(.system(size: symbolSize)).foregroundStyle(BattleType.color(type))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .help(image == nil && boss.image.map(BossImages.hasFailed) == true
              ? tr("Obrázek se nenačetl, místo něj ikona typu", "The picture didn't load, the type's icon instead") : "")
        .task(id: boss.image) {
            guard let url = boss.image else { return }
            image = BossImages.cached(url)
            if image == nil { image = await BossImages.load(url) }
        }
    }
}

private struct BossHeader: View {
    let boss: RaidBoss
    let weathers: [String]
    @Binding var weather: String

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            BossPicture(boss: boss, size: 104, radius: 20, symbolSize: 44)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Pill(text: boss.tier.label, color: tierColor.0, background: tierColor.1, weight: .semibold)
                    ForEach(boss.types, id: \.self) { TypePill(type: $0) }
                }
                Text(boss.name).font(.system(size: 30, weight: .medium)).tracking(-0.75).lineLimit(2)
                FlowRow(spacing: 16) {
                    if !weathers.isEmpty {
                        Label(tr("Posiluje ho \(BattleFormat.list(weathers.map { BattleWeather.name($0).lowercased() }))",
                                 "Boosted by \(BattleFormat.list(weathers.map { BattleWeather.name($0).lowercased() }))"),
                              systemImage: "cloud.sun")
                    }
                    if let cpText { Label(cpText, systemImage: "number").monospacedDigit() }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if !weathers.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(tr("Počasí", "Weather")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Hint(BattleHints.weather)
                    }
                    Segmented(items: [("none", tr("Bez počasí", "No weather"), "minus.circle")]
                                + weathers.map { ($0, BattleWeather.name($0), BattleWeather.symbol($0)) },
                              selection: $weather, height: 28)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tierColor: (Color, Color) {
        boss.tier.isShadow ? (Theme.accentInk, Theme.tint) : (boss.tier == .mega || boss.tier == .megaLegendary) ? (Theme.blue, Theme.blueTint) : (Theme.text, Theme.raise)
    }

    private var cpText: String? {
        let range = { (r: ClosedRange<Int>) in "\(BattleFormat.number(r.lowerBound))–\(BattleFormat.number(r.upperBound))" }
        if weather != "none", let b = boss.cpBoosted { return tr("CP při chycení s počasím \(range(b))", "Catch CP with weather \(range(b))") }
        guard let n = boss.cp else { return nil }
        guard let b = boss.cpBoosted else { return tr("CP při chycení \(range(n))", "Catch CP \(range(n))") }
        return tr("CP při chycení \(range(n)) · s počasím \(range(b))", "Catch CP \(range(n)) · with weather \(range(b))")
    }
}

// MARK: - Counters

private struct ChanceCard: View {
    let chances: [Int]?
    let shadow: Bool
    @Binding var players: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Label(tr("Šance na výhru", "Win chance"), systemImage: "target")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
                Hint(BattleHints.chance)
            }
            if let ch = chances, ch.count == 6 {
                let n = players ?? ((ch.firstIndex { $0 >= 60 } ?? 5) + 1)
                let c = ch[n - 1]
                let number = VStack(alignment: .leading, spacing: 6) {
                    Text(percentText(c))
                        .font(.system(size: 72, weight: .medium)).tracking(-3.2).monospacedDigit()
                        .foregroundStyle(c >= 75 ? Theme.green : c >= 40 ? Theme.text : Theme.red)
                        .lineLimit(1).fixedSize()
                    Text(sentence(ch, n)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
                let bars = HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<6, id: \.self) { i in bar(i, ch[i], on: i + 1 == n) }
                }
                .fixedSize()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 22) {
                        number.frame(minWidth: 190, idealWidth: 200, alignment: .leading)
                        Spacer(minLength: 0)
                        bars
                    }
                    VStack(alignment: .leading, spacing: 16) { number; bars }
                }
            } else {
                Text(tr("U tohoto typu raidu IVory nezná HP bosse ani časový limit, takže šanci neodhadne.",
                        "IVory doesn't know the boss HP and time limit for this kind of raid, so it can't estimate the chance."))
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack {
                Label(tr("Odhad z veřejných dat, ne simulace souboje", "An estimate from public data, not a battle simulation"), systemImage: "info.circle")
                    .help(tr("Počítá s nejlepšími útoky druhu a s průměrem útoků bosse. Shadow a purified nerozlišuje.",
                             "Assumes the species' best moves and the average of the boss's moves. Doesn't tell shadow and purified apart.")
                          + (shadow ? tr(" Zuřivost (enrage) shadow bosse nepočítá, skutečná šance bývá nižší.",
                                         " Doesn't count the shadow boss's enrage, the real chance tends to be lower.") : ""))
                Spacer()
                if chances != nil { Text(tr("počet hráčů", "players")) }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 16)
    }

    private func bar(_ i: Int, _ v: Int, on: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { players = i + 1 }
        } label: {
            VStack(spacing: 4) {
                Text(percentText(v)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(on ? Theme.text : Theme.muted).lineLimit(1).fixedSize()
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raise)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? Theme.accent : Theme.accent.opacity(0.3))
                        .frame(height: 76 * CGFloat(max(v, 3)) / 100)
                }
                .frame(width: 30, height: 76)
                Text("\(i + 1)").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Theme.accentInk : Theme.muted)
                    .frame(width: 30, height: 20)
                    .background(on ? Theme.tint : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(trCount(i + 1, cs: "hráč", "hráči", "hráčů", en: "player", "players")): \(percentText(v))")
    }

    private func sentence(_ ch: [Int], _ n: Int) -> String {
        let n90 = (ch.firstIndex { $0 >= 90 } ?? -1) + 1
        let first = n == 1 ? tr("Když půjdeš sám s touto šesticí.", "If you go alone with this six.")
            : tr("Když vás půjde \(n), každý s podobnou partou.", "If \(n) of you go, each with a similar party.")
        let players = trCount(n90, cs: "hráč", "hráči", "hráčů", en: "player", "players")
        let second = n90 == 0 ? tr(" Ani s 6 hráči to na 90 % nevychází.", " Even 6 players don't reach 90%.")
            : n90 == 1 ? tr(" Zvládneš to i sám.", " You can do it alone.")
            : n90 <= n ? tr(" Na 90 % stačí \(players).", " \(players) are enough for 90%.")
            : tr(" Na 90 % je potřeba \(players).", " It takes \(players) for 90%.")
        return first + second
    }
}

private struct BestPick: View {
    let c: RaidCounter
    let boss: RaidBoss

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MonPhoto(m: c.mon, radius: 12)
                .frame(width: 132)
                .frame(minHeight: 156, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Nejlepší pick", "Best pick").uppercased())
                    .font(.system(size: 12, weight: .semibold)).tracking(0.72).foregroundStyle(Theme.accentInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.mon.name).font(.system(size: 22, weight: .medium)).tracking(-0.44).lineLimit(1).minimumScaleFactor(0.8)
                    Text(BattleFormat.meta(c.mon)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                ReasonPill(c: c, boss: boss)
                VStack(alignment: .leading, spacing: 2) {
                    MovesLabel()
                    Text("\(c.fast.name) · \(c.charged.name)").font(.system(size: 13))
                }
                Tags(tags: BattleFormat.raidTags(c))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(stops: [.init(color: Theme.tint, location: 0), .init(color: Theme.surface, location: 0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct PartyList: View {
    let counters: [RaidCounter]
    let boss: RaidBoss
    let weather: String
    let wide: Bool

    var body: some View {
        let best = counters.first?.strength ?? 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tr("Raid parta", "Raid party")).font(.system(size: 19, weight: .medium)).tracking(-0.19)
                Hint(BattleHints.party)
                Text(sub).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                Text(tr("síla vůči nejlepšímu", "strength vs. the best")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Hint(BattleHints.strength)
            }
            VStack(spacing: 0) {
                ForEach(Array(counters.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    DetailButton(edge: .bottom) {
                        row(i, c, pct: Int((c.strength / best * 100).rounded()))
                    } detail: {
                        RaidDetail(c: c, boss: boss, weather: weather, best: best)
                    }
                    .help(tr("Klikni pro detail", "Click for details"))
                }
            }
            .card(radius: 14)
            Note(text: tr("Útoky jsou nejlepší útoky druhu. Ve hře zkontroluj, jestli je tvůj kus opravdu má.",
                          "The moves are the species' best moves. Check in the game that yours really has them."))
                .help(tr("Bot ze hry nečte, jaké útoky Pokémon má.", "The bot doesn't read a Pokémon's moves from the game."))
        }
    }

    private var sub: String {
        let weak = counters.filter(\.weak).count
        guard weak > 0 else {
            return counters.count >= 6 ? tr("6 nejsilnějších z tvého úložiště", "The 6 strongest from your storage")
                : tr("všichni, kdo z tvého úložiště přicházejí v úvahu", "everyone in your storage who fits")
        }
        let good = counters.count - weak
        let goodText = trCount(good, cs: "dobrý counter", "dobré countery", "dobrých counterů", en: "good counter", "good counters")
        return tr("\(goodText) a \(weak) slabší, víc proti \(boss.types.count > 1 ? "těmto typům" : "tomuto typu") v úložišti nemáš",
                  "\(goodText) and \(weak) weaker, you have nothing better against \(boss.types.count > 1 ? "these types" : "this type")")
    }

    /// Four columns as in the design when there's room; otherwise the moves and the reason go under the name.
    @ViewBuilder private func row(_ i: Int, _ c: RaidCounter, pct: Int) -> some View {
        Group {
            if wide {
                HStack(spacing: 14) {
                    rank(i)
                    MonIcon(m: c.mon, size: 44)
                    who(c).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.fast.name).lineLimit(1)
                        Text(c.charged.name).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ReasonPill(c: c, boss: boss).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                    strength(i, c, pct)
                }
            } else {
                HStack(spacing: 14) {
                    rank(i)
                    MonIcon(m: c.mon, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        who(c)
                        HStack(spacing: 10) {
                            Text("\(c.fast.name) · \(c.charged.name)").font(.system(size: 13)).lineLimit(1)
                            ReasonPill(c: c, boss: boss).fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    strength(i, c, pct)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .opacity(c.weak ? 0.72 : 1)
    }

    private func rank(_ i: Int) -> some View {
        Text("\(i + 1)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.muted)
            .frame(width: 22, alignment: .leading)
    }

    private func who(_ c: RaidCounter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.mon.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Text(BattleFormat.meta(c.mon)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
            let tags = (c.weak ? [BattleTag(text: tr("slabší volba", "weaker pick"), symbol: nil, muted: true)] : []) + BattleFormat.raidTags(c)
            if !tags.isEmpty { Tags(tags: tags, small: true) }
        }
    }

    private func strength(_ i: Int, _ c: RaidCounter, _ pct: Int) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(i == 0 ? Theme.accent : c.weak ? Theme.muted : Theme.accent.opacity(0.6))
                    .frame(width: 84 * CGFloat(pct) / 100)
            }
            .frame(width: 84, height: 6)
            Text(percentText(pct)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 48, alignment: .trailing).lineLimit(1)
        }
        .frame(width: 140)
    }
}

private struct ReasonPill: View {
    let c: RaidCounter
    let boss: RaidBoss

    var body: some View {
        let weak = c.weak
        HStack(spacing: 5) {
            Image(systemName: BattleType.symbol(c.attackType)).font(.system(size: 11))
            Text(BattleFormat.reason(c, boss)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(weak ? Theme.muted : BattleType.color(c.attackType))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(minHeight: 22)
        .background(weak ? Theme.raise : BattleType.tint(c.attackType), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - PvP

/// A team member: role, score, how its CP sits against the league's cap and what it still needs.
private struct MemberCard: View {
    let m: PvPMember
    let league: PvPLeague
    @ObservedObject private var battle = BattleStore.shared

    var body: some View {
        let cap = league.cap ?? m.cp
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                DetailButton(radius: 14, edge: .bottom) {
                    MonIcon(m: m.mon, size: 64)
                } detail: {
                    PvPDetail(m: m, league: league)
                }
                .help(tr("Klikni pro detail", "Click for details"))
                VStack(alignment: .leading, spacing: 4) {
                    Label(m.role.title, systemImage: m.role.symbol)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Theme.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                    Text(m.evolves ? "\(m.mon.name) → \(m.formName)" : m.mon.name)
                        .font(.system(size: 17, weight: .medium)).tracking(-0.17).lineLimit(1).minimumScaleFactor(0.75)
                    Text("IV \(percentText(m.mon.pct)) · \(tr("rank \(BattleFormat.rank(m.rank))", "rank \(BattleFormat.rank(m.rank))"))")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(m.ranking.score.rounded()))").font(.system(size: 20, weight: .medium)).monospacedDigit()
                    Text(tr("skóre", "score")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .help(tr("Skóre druhu v lize podle PvPoke, 0–100.", "The species' score in the league by PvPoke, 0–100."))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(league.cap.map { tr("CP · limit \(BattleFormat.number($0))", "CP · cap \(BattleFormat.number($0))") }
                         ?? tr("CP · bez limitu", "CP · no cap"))
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    Text(m.powerUp ? "\(BattleFormat.number(m.mon.cp)) → \(BattleFormat.number(m.cp))" : BattleFormat.number(m.cp))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1)
                }
                GeometryReader { g in
                    let nowW = g.size.width * min(1, CGFloat(m.powerUp ? m.mon.cp : m.cp) / CGFloat(max(cap, 1)))
                    let addW = m.powerUp ? g.size.width * min(1 - nowW / g.size.width, CGFloat(max(0, m.cp - m.mon.cp)) / CGFloat(max(cap, 1))) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        HStack(spacing: 0) {
                            Rectangle().fill(m.powerUp ? Theme.accent : Theme.green).frame(width: nowW)
                            Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: addW)
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 6)
            }
            if m.powerUp {
                let price = battle.price(m)
                VStack(alignment: .leading, spacing: 4) {
                    Label(tr("Vylepšit na \(BattleFormat.level(m.level))", "Power up to \(BattleFormat.level(m.level))"), systemImage: "arrow.up.circle")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentInk)
                    Text("\(BattleFormat.number(price.stardust)) stardust · \(BattleFormat.number(price.candy)) candy"
                         + (price.xl > 0 ? " · \(BattleFormat.number(price.xl)) XL candy" : ""))
                        .font(.system(size: 12)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    Button {
                        battle.focusUpgrade = "p-\(m.id)"
                    } label: {
                        HStack(spacing: 4) {
                            Text(tr("Otevřít Vylepšení", "Open Power-ups"))
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentInk)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Label(league.cap == nil ? tr("Na maximu · \(BattleFormat.level(m.level))", "Maxed · \(BattleFormat.level(m.level))")
                                        : tr("Na limitu ligy · \(BattleFormat.level(m.level))", "At the league's cap · \(BattleFormat.level(m.level))"),
                      systemImage: "checkmark.circle")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.green)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.greenTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                MovesLabel()
                let names = BattleFormat.moves(m.ranking.moveset)
                Text("\(names.fast) · \(names.charged)").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 16)
    }
}

private struct MissingCard: View {
    let present: Int
    let league: PvPLeague

    var body: some View {
        let missing = 3 - present
        VStack(alignment: .leading, spacing: 10) {
            SoftIcon(symbol: "person.badge.plus", color: Theme.gold, background: Theme.goldTint, size: 40, radius: 11)
            Text(trCount(missing, cs: "člen chybí", "členové chybí", "členů chybí", en: "member missing", "members missing"))
                .font(.system(size: 17, weight: .medium))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var text: String {
        let fit = trCount(present, cs: "vhodný Pokémon", "vhodní Pokémoni", "vhodných Pokémonů", en: "suitable Pokémon", "suitable Pokémon")
        guard let cap = league.cap else {
            return tr("Pro Master League máš v úložišti jen \(fit). Další přidá IVory, až chytíš nebo přečte vhodný kus.",
                      "You have only \(fit) for the Master League. IVory adds more once it reads a suitable one.")
        }
        let limit = BattleFormat.number(cap)
        return tr("Do \(limit) CP se ti vejde jen \(fit). Ostatní mají CP nad limitem a CP se snížit nedá. Další přidá IVory, až chytíš nebo přečte vhodný kus.",
                  "Only \(fit) fit under \(limit) CP. The others are over the cap and CP can't go down. IVory adds more once it reads a suitable one.")
    }
}

private struct Segmented<Value: Hashable>: View {
    let items: [(Value, String, String)]
    @Binding var selection: Value
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (value, title, symbol) = items[i]
                let on = value == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = value } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 13))
                        Text(title).lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? Theme.text : Theme.muted)
                    .padding(.horizontal, height > 28 ? 14 : 11).frame(height: height)
                    .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? Theme.border : .clear))
                    .shadow(color: .black.opacity(on ? 0.2 : 0), radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
    }
}

private struct Pill: View {
    let text: String
    let color: Color
    let background: Color
    var weight: Font.Weight = .medium

    var body: some View {
        Text(text).font(.system(size: 12, weight: weight)).foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 22)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct TypePill: View {
    let type: String

    var body: some View {
        Label(BattleType.name(type), systemImage: BattleType.symbol(type))
            .font(.system(size: 12, weight: .medium)).foregroundStyle(BattleType.color(type))
            .padding(.horizontal, 8).frame(height: 22)
            .background(BattleType.tint(type), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct BattleTag: Hashable {
    let text: String
    let symbol: String?
    var muted = false
}

private struct Tags: View {
    let tags: [BattleTag]
    var small = false

    var body: some View {
        FlowRow(spacing: small ? 4 : 6) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 5) {
                    if let s = t.symbol { Image(systemName: s).font(.system(size: small ? 10 : 11)) }
                    Text(t.text)
                }
                .font(.system(size: small ? 11 : 12, weight: small ? .semibold : .medium))
                .foregroundStyle(t.muted ? Theme.muted : Theme.gold)
                .padding(.horizontal, small ? 6 : 8).frame(height: small ? 18 : 22)
                .background(t.muted ? Theme.raise : Theme.goldTint, in: RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous))
            }
        }
    }
}

private struct MovesLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(tr("Doporučené útoky", "Recommended moves"))
            Text(tr("ověř ve hře", "check in game")).font(.system(size: 11))
                .padding(.horizontal, 6).frame(height: 18)
                .background(Theme.raise, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .help(tr("Bot ze hry nečte, jaké útoky Pokémon má. Počítá s nejlepšími útoky druhu.",
                         "The bot doesn't read a Pokémon's moves from the game. It assumes the species' best moves."))
        }
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }
}

private struct Score: View {
    let value: Double
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(Int(value.rounded()))").font(.system(size: size, weight: .medium)).monospacedDigit().tracking(-0.4)
            Text(tr("skóre", "score")).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Pokémon's picture from the phone filling a rectangle; without one, its type's color and initial.
private struct MonPhoto: View {
    let m: InventoryStats.Mon
    let radius: CGFloat

    var body: some View {
        Theme.raise
            .overlay {
                if let img = MonImages.icon(m) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    GeometryReader { g in MonLetter(m: m, size: min(g.size.width, g.size.height)) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private extension View {
    /// A card: surface background with a hairline border.
    func card(radius: CGFloat) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border))
    }

    /// A card inside a card: the window's own background, so it reads as sunk in.
    func inner(radius: CGFloat) -> some View {
        background(Theme.bg, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - Loading

private struct CardIf: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.card(radius: 14) } else { content }
    }
}

/// A light that sweeps across the placeholder blocks while something loads (not with Reduce Motion).
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Theme.text.opacity(0.07), Theme.accent.opacity(0.10), Theme.text.opacity(0.07), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.5)
                            .offset(x: -g.size.width * 0.5 + phase * g.size.width * 1.5)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

private struct Bone: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.raise)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// The raid layout drawn as placeholders: boss list, header, chance and best pick, party.
private struct RaidSkeleton: View {
    let wide: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            if wide {
                VStack(alignment: .leading, spacing: 14) {
                    Bone(height: 36, radius: 9)
                    ForEach(0..<8, id: \.self) { i in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.raise).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 6) { Bone(width: [120, 90, 140, 100][i % 4]); Bone(width: 70, height: 9) }
                        }
                    }
                }
                .frame(width: 272)
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    Bone(width: 104, height: 104, radius: 20)
                    VStack(alignment: .leading, spacing: 10) { Bone(width: 120, height: 20); Bone(width: 220, height: 28); Bone(width: 260) }
                }
                HStack(spacing: 16) {
                    Bone(height: 180, radius: 16)
                    Bone(height: 180, radius: 16)
                }
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: 14) {
                            Bone(width: 44, height: 44, radius: 10)
                            VStack(alignment: .leading, spacing: 6) { Bone(width: 130); Bone(width: 180, height: 9) }
                            Spacer()
                            Bone(width: 120, height: 6, radius: 3)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                .card(radius: 14)
            }
        }
        .modifier(Shimmer())
        .accessibilityLabel(tr("Načítám", "Loading"))
    }
}

/// PvP teams drawn as placeholders while they're computed.
private struct PvPSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Bone(width: 520, height: 12)
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Bone(width: 70, height: 18); Spacer(); Bone(width: 200, height: 10) }
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: 10) {
                                Bone(width: 48, height: 48, radius: 12)
                                VStack(alignment: .leading, spacing: 6) { Bone(width: 90); Bone(width: 110, height: 9) }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    HStack(spacing: 4) { ForEach(0..<6, id: \.self) { _ in Bone(width: 64, height: 22, radius: 6) } }
                }
                .padding(16)
                .card(radius: 16)
            }
        }
        .modifier(Shimmer())
        .accessibilityLabel(tr("Skládám týmy", "Building the teams"))
    }
}

// MARK: - Power-ups

/// Where stardust makes the most difference: raid attackers whose power-up to L40 makes your best party of a type
/// stronger, and the PvP team members still under the league's cap. A row opens into the strength (or CP) it gains
/// and the cost step by step.
private struct UpgradesView: View {
    let mons: [InventoryStats.Mon]
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var battle = BattleStore.shared
    @State private var open: String?

    /// How many power-ups each list shows.
    private static let rows = 20

    /// A row the PvP tab asked for is already open on the first render.
    @MainActor init(mons: [InventoryStats.Mon]) {
        self.mons = mons
        _open = State(initialValue: BattleStore.shared.focusUpgrade)
    }

    var body: some View {
        let raid = Array(battle.raidUpgrades(perType: store.config.battle.raid.perType, mons: mons).prefix(Self.rows))
        let pvp = Array(pvpRows.prefix(Self.rows))
        VStack(alignment: .leading, spacing: 26) {
            if !raid.isEmpty || !pvp.isEmpty { Summary(raid: raid, pvp: pvp) }
            section(symbol: "shield.lefthalf.filled", title: tr("Pro raidy", "For raids"),
                    subtitle: tr("vylepšení na L40", "power-ups to L40"), hint: BattleHints.raidUpgrades,
                    sort: tr("podle zisku za stardust", "by gain per stardust")) {
                if raid.isEmpty {
                    done(tr("Žádné vylepšení na L40 by tvou nejlepší partu nezměnilo.", "No power-up to L40 would change your best party."))
                } else {
                    rows(raid, id: { "r-\($0.id)" }) { u, isOpen, toggle in
                        RaidUpgradeRow(u: u, open: isOpen, toggle: toggle)
                    }
                }
            }
            section(symbol: "trophy", title: tr("Pro PvP týmy", "For PvP teams"),
                    subtitle: tr("vylepšení na limit ligy", "power-ups to the league cap"), hint: BattleHints.pvpUpgrades,
                    sort: tr("od nejlevnějšího", "cheapest first")) {
                if pvp.isEmpty {
                    done(tr("Členové týmů už jsou na limitu ligy.", "The team members are already at the league's cap."))
                } else {
                    rows(pvp, id: { "p-\($0.member.id)" }) { row, isOpen, toggle in
                        PvPUpgradeRow(member: row.member, league: row.league, tag: store.config.battle.team(row.league).name,
                                      open: isOpen, toggle: toggle)
                    }
                }
            }
            Note(text: tr("Ceny platí pro běžné kusy: lucky stojí polovinu stardustu, shadow o 20 % víc a purified o 10 % míň. Candy na vyvinutí se nepočítá.",
                          "The costs are for regular Pokémon: lucky ones cost half the stardust, shadow ones 20% more and purified ones 10% less. Candy for evolving isn't counted."))
        }
        .onAppear(perform: takeFocus)
        .onChange(of: battle.focusUpgrade) { _, _ in takeFocus() }
    }

    /// A row the PvP tab asked to open.
    private func takeFocus() {
        guard let key = battle.focusUpgrade else { return }
        battle.focusUpgrade = nil
        withAnimation(.snappy(duration: 0.25)) { open = key }
    }

    /// The members of each league's tagged team (IVory's first until one is picked) that still need powering up,
    /// cheapest first.
    private var pvpRows: [(league: PvPLeague, member: PvPMember)] {
        PvPLeague.allCases.flatMap { league -> [(league: PvPLeague, member: PvPMember)] in
            guard let r = battle.teams[league] else { return [] }
            let team = battle.chosenTeam(r, store.config.battle.team(league)) ?? r.teams.first
            return (team?.members ?? []).filter(\.powerUp).map { (league, $0) }
        }
        .sorted { BattleStore.shared.price($0.member).stardust < BattleStore.shared.price($1.member).stardust }
    }

    private func section<Content: View>(symbol: String, title: String, subtitle: String, hint: (String, String),
                                        sort: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.accentInk)
                Text(title).font(.system(size: 19, weight: .medium)).tracking(-0.19)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Hint(hint)
                Spacer(minLength: 12)
                Label(sort, systemImage: "arrow.down").font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize()
            }
            content()
        }
    }

    /// The rows of one list, each able to open; only one is open at a time.
    private func rows<T, Row: View>(_ items: [T], id: @escaping (T) -> String,
                                    @ViewBuilder row: @escaping (T, Bool, @escaping () -> Void) -> Row) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                let key = id(item)
                row(item, open == key, { withAnimation(.snappy(duration: 0.22)) { open = open == key ? nil : key } })
            }
        }
        .card(radius: 14)
    }

    private func done(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.system(size: 14)).foregroundStyle(Theme.text)
            .labelStyle(DoneLabel())
            .padding(.horizontal, 18).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 14)
    }

    private struct DoneLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 10) {
                configuration.icon.font(.system(size: 17)).foregroundStyle(Theme.green)
                configuration.title
            }
        }
    }
}

/// What the whole list would cost: the three cheapest raid power-ups together, then each list's total.
private struct Summary: View {
    let raid: [RaidUpgrade]
    let pvp: [(league: PvPLeague, member: PvPMember)]

    var body: some View {
        let top3 = Array(raid.prefix(3))
        let pvpDust = pvp.map { BattleStore.shared.price($0.member).stardust }.reduce(0, +)
        let pvpXL = pvp.map { BattleStore.shared.price($0.member).xl }.reduce(0, +)
        WeightedRow(weights: [1, 1, 1], spacing: 12, minColumn: 200) {
            card(label: tr("Tři nejvýhodnější", "The three best value"), value: top3.map(\.price.stardust).reduce(0, +),
                 detail: top3.isEmpty ? tr("zatím žádné", "none yet") : top3.map(\.counter.mon.name).joined(separator: ", "),
                 accent: true)
            card(label: tr("Všechna pro raidy", "All for raids"), value: raid.map(\.price.stardust).reduce(0, +),
                 detail: trCount(raid.count, cs: "vylepšení", "vylepšení", "vylepšení", en: "power-up", "power-ups"), accent: false)
            card(label: tr("Všechna pro PvP týmy", "All for PvP teams"), value: pvpDust,
                 detail: trCount(pvp.count, cs: "vylepšení", "vylepšení", "vylepšení", en: "power-up", "power-ups")
                     + (pvpXL > 0 ? " · \(BattleFormat.number(pvpXL)) XL candy" : ""), accent: false)
        }
    }

    private func card(label: String, value: Int, detail: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(BattleFormat.number(value)).font(.system(size: 24, weight: .medium)).monospacedDigit().tracking(-0.48)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("stardust").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(accent ? AnyShapeStyle(LinearGradient(stops: [.init(color: Theme.tint, location: 0), .init(color: Theme.surface, location: 0.75)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                           : AnyShapeStyle(Theme.surface),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

/// One raid power-up: who, in which attack type it rises, what it costs and what it gains.
private struct RaidUpgradeRow: View {
    let u: RaidUpgrade
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    MonIcon(m: u.counter.mon, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.counter.mon.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(BattleFormat.meta(u.counter.mon)).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        TypePill(type: u.type)
                        Text(rankLine).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CostColumn(from: u.counter.mon.level, to: 40, price: u.price,
                               cp: (u.counter.mon.cp, BattleStore.shared.cp(u.counter.formStats, u.counter.mon.iv, at: 40)))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("+" + percentText(Int((u.gain * 100).rounded())) + tr(" síly", " strength"))
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.green)
                            .lineLimit(1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.green).frame(width: 150 * min(1, CGFloat(u.gainPer100k / 0.6)))
                        }
                        .frame(width: 150, height: 4)
                        Text("+" + percentText(Int((u.gainPer100k * 100).rounded())) + tr(" za 100k stardust", " per 100k stardust"))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(width: 150)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(open ? Theme.raise.opacity(0.55) : hovering ? Theme.raise.opacity(0.35) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(open ? tr("Skrýt detail", "Hide the details") : tr("Rozpis síly a ceny", "The strength and cost breakdown"))
            if open {
                UpgradeDetail(title: tr("Síla proti bossům", "Strength against bosses"),
                              bars: [.init(label: tr("teď · \(BattleFormat.level(u.counter.mon.level ?? 0))", "now · \(BattleFormat.level(u.counter.mon.level ?? 0))"),
                                           share: 1 / (1 + u.gain), value: percentText(100), color: Theme.muted),
                                     .init(label: tr("po vylepšení · L40", "after · L40"), share: 1,
                                           value: percentText(Int(((1 + u.gain) * 100).rounded())), color: Theme.green)],
                              note: tr("Síla spojuje rychlost poškození a výdrž, měřená proti neutrálnímu bossovi. Parta typu \(BattleType.name(u.type).lowercased()) tím zesílí nejvíc ze všech vylepšení za stejný stardust.",
                                       "Strength combines damage speed and staying power, measured against a neutral boss. It makes your \(BattleType.name(u.type).lowercased()) party gain the most of any power-up for the same stardust."),
                              evolve: u.counter.evolveTo.map { tr("Počítá se jako \($0): nejdřív ho vyvin.", "Counted as \($0): evolve it first.") },
                              from: u.counter.mon.level ?? 0, to: 40, stats: u.counter.formStats, iv: u.counter.mon.iv)
            }
        }
    }

    /// What the power-up does to its place among your attackers of that type, after the whole plan.
    private var rankLine: String {
        let type = BattleType.name(u.type).lowercased()
        guard let now = u.rankNow else {
            return tr("dostane se mezi tvé nejlepší útočníky typu \(type), na #\(u.rankAfter)",
                      "joins your best \(type) attackers, at #\(u.rankAfter)")
        }
        if u.rankAfter < now {
            return tr("posune se na #\(u.rankAfter) mezi útočníky typu \(type), teď #\(now)",
                      "moves up to #\(u.rankAfter) among your \(type) attackers, now #\(now)")
        }
        return tr("zůstane #\(u.rankAfter) mezi útočníky typu \(type), ale posílí celou šestici",
                  "stays #\(u.rankAfter) among your \(type) attackers, but strengthens the whole six")
    }
}

/// One PvP power-up: a team member up to the highest level that stays under the league's cap.
private struct PvPUpgradeRow: View {
    let member: PvPMember
    let league: PvPLeague
    let tag: String
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let price = BattleStore.shared.price(member)
        let cap = league.cap ?? member.cp
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    MonIcon(m: member.mon, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(member.mon.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                            if member.evolves {
                                Text("→ \(member.formName)").font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                        Text(BattleFormat.meta(member.mon)).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle().fill(BattleFormat.leagueColor(league)).frame(width: 7, height: 7)
                            Text(tag).font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(league.cap.map { tr("na \(BattleFormat.number(member.cp)) CP, těsně pod \(BattleFormat.number($0))",
                                                 "to \(BattleFormat.number(member.cp)) CP, just under \(BattleFormat.number($0))") }
                             ?? tr("na \(BattleFormat.number(member.cp)) CP", "to \(BattleFormat.number(member.cp)) CP"))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CostColumn(from: member.mon.level, to: member.level, price: price)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(BattleFormat.number(member.mon.cp)) → \(BattleFormat.number(member.cp)) CP")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
                        CPBar(now: member.mon.cp, target: member.cp, cap: cap, width: 150)
                        Text(league.cap.map { tr("limit \(BattleFormat.number($0))", "cap \(BattleFormat.number($0))") }
                             ?? tr("bez limitu", "no cap"))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(width: 150)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(open ? Theme.raise.opacity(0.55) : hovering ? Theme.raise.opacity(0.35) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(open ? tr("Skrýt detail", "Hide the details") : tr("Rozpis CP a ceny", "The CP and cost breakdown"))
            if open {
                UpgradeDetail(title: tr("CP proti limitu ligy", "CP against the league's cap"),
                              bars: [.init(label: tr("teď · \(BattleFormat.level(member.mon.level ?? 0))", "now · \(BattleFormat.level(member.mon.level ?? 0))"),
                                           share: Double(member.mon.cp) / Double(cap), value: "\(BattleFormat.number(member.mon.cp)) CP", color: Theme.muted),
                                     .init(label: tr("po vylepšení · \(BattleFormat.level(member.level))", "after · \(BattleFormat.level(member.level))"),
                                           share: Double(member.cp) / Double(cap), value: "\(BattleFormat.number(member.cp)) CP", color: Theme.accent)],
                              note: league.cap.map { tr("Vyšší level by přesáhl limit \(BattleFormat.number($0)) CP. V lize s limitem vede nízký útok a vysoká obrana a HP: Pokémon se pak vejde na vyšší level a vydrží víc.",
                                                        "A higher level would go over the \(BattleFormat.number($0)) CP cap. In a capped league, low attack with high defense and HP wins: the Pokémon fits at a higher level and lasts longer.") }
                                  ?? tr("Master League nemá limit CP, takže se vyplatí jít na level 50.",
                                        "The Master League has no CP cap, so level 50 is worth it."),
                              evolve: member.evolves ? tr("Nejdřív ho vyvin na \(member.formName).", "Evolve it into \(member.formName) first.") : nil,
                              from: member.mon.level ?? member.level, to: member.level,
                              stats: BattleStore.shared.data?.battle?.pokemon[member.form]?.stats ?? [], iv: member.mon.iv)
            }
        }
    }
}

/// The level, stardust and candy in a row of either list.
private struct CostColumn: View {
    let from: Double?
    let to: Double
    let price: GameData.Price
    /// Shown when the row has no CP of its own elsewhere (the raid list).
    var cp: (now: Int, after: Int)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(from.map(BattleFormat.level) ?? "?") → \(BattleFormat.level(to))")
                .font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1)
            Text("\(BattleFormat.number(price.stardust)) stardust · \(BattleFormat.number(price.candy)) candy")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
            if price.xl > 0 {
                Text("\(BattleFormat.number(price.xl)) XL candy").font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(Theme.muted).lineLimit(1)
            }
            if let cp {
                Text("\(BattleFormat.number(cp.now)) → \(BattleFormat.number(cp.after)) CP")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .frame(width: 200, alignment: .leading)
    }
}

/// A CP bar: what it has now and what the power-up adds, against the league's cap.
private struct CPBar: View {
    let now: Int
    let target: Int
    let cap: Int
    var width: CGFloat = 150

    var body: some View {
        let nowW = width * min(1, CGFloat(now) / CGFloat(max(cap, 1)))
        let addW = width * min(1 - nowW / width, CGFloat(max(0, target - now)) / CGFloat(max(cap, 1)))
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.track)
            HStack(spacing: 0) {
                Rectangle().fill(Theme.accent).frame(width: nowW)
                Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: addW)
            }
            .clipShape(Capsule())
        }
        .frame(width: width, height: 4)
    }
}

/// The open part of a row: what the power-up gains and what it costs step by step.
private struct UpgradeDetail: View {
    struct Bar: Identifiable {
        let label: String
        let share: Double
        let value: String
        let color: Color
        var id: String { label }
    }

    let title: String
    let bars: [Bar]
    let note: String
    let evolve: String?
    let from: Double
    let to: Double
    let stats: [Int]
    let iv: [Int]

    var body: some View {
        WeightedRow(weights: [1, 1], spacing: 12, minColumn: 280) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                ForEach(bars) { b in
                    HStack(spacing: 10) {
                        Text(b.label).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(width: 130, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(b.color).frame(width: g.size.width * min(1, max(0, b.share)))
                            }
                        }
                        .frame(height: 8)
                        Text(b.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .frame(width: 84, alignment: .trailing).lineLimit(1)
                    }
                }
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if let evolve {
                    Label(evolve, systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.gold)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Theme.goldTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .inner(radius: 12)
            StepTable(from: from, to: to, stats: stats, iv: iv)
        }
        .padding(EdgeInsets(top: 0, leading: 82, bottom: 16, trailing: 16))
    }
}

/// The cost split into the stretches where one power-up costs the same.
private struct StepTable: View {
    let from: Double
    let to: Double
    let stats: [Int]
    let iv: [Int]
    @ObservedObject private var battle = BattleStore.shared

    var body: some View {
        let steps = battle.data?.battle?.upgrades?.steps(from: from, to: to) ?? []
        let total = steps.reduce(into: GameData.Price()) { $0 += $1.price }
        let xl = total.xl > 0
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Cena po krocích", "Cost by step")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            VStack(spacing: 0) {
                row(tr("Level", "Level"), "CP", "Stardust", "Candy", xl ? "XL" : nil, header: true)
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(Theme.border).frame(height: 1)
                    row("\(BattleFormat.level(s.from)) → \(BattleFormat.level(s.to))", cp(s.to),
                        BattleFormat.number(s.price.stardust), BattleFormat.number(s.price.candy),
                        xl ? (s.price.xl > 0 ? BattleFormat.number(s.price.xl) : "–") : nil, header: false)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                row(tr("Celkem", "Total"), "", BattleFormat.number(total.stardust), BattleFormat.number(total.candy),
                    xl ? BattleFormat.number(total.xl) : nil, header: false, bold: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .inner(radius: 12)
    }

    /// The CP it has once it reaches that level.
    private func cp(_ level: Double) -> String {
        guard stats.count == 3, iv.count == 3, let data = battle.data else { return "" }
        return BattleFormat.number(data.cp(stats, iv, level: level))
    }

    private func row(_ level: String, _ cp: String, _ dust: String, _ candy: String, _ xl: String?,
                     header: Bool, bold: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(level).frame(maxWidth: .infinity, alignment: .leading)
            Text(cp).frame(width: 58, alignment: .trailing)
            Text(dust).frame(width: 74, alignment: .trailing)
            Text(candy).frame(width: 50, alignment: .trailing)
            if let xl { Text(xl).frame(width: 50, alignment: .trailing) }
        }
        .font(.system(size: header ? 12 : 13, weight: bold ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(header ? Theme.muted : Theme.text)
        .lineLimit(1)
        .padding(.vertical, header ? 0 : 5)
        .padding(.bottom, header ? 6 : 0)
    }
}

// MARK: - In-game search

/// How to find the party in the game: the Raid tag (the battle step) and the moves of the types the boss is weak to,
/// e.g. #Raid&@steel,@poison.
private struct GameSearch: View {
    let boss: RaidBoss
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var battle = BattleStore.shared
    @State private var copied = false

    var body: some View {
        let tag = store.config.battle.raid
        if tag.enabled, !tag.name.isEmpty, let query = query(tag.name) {
            HStack(alignment: .center, spacing: 12) {
                SoftIcon(symbol: "magnifyingglass", size: 32, radius: 9)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(tr("Ve hře najdeš útočníky hledáním", "Find the attackers in the game by searching"))
                            .font(.system(size: 13, weight: .medium))
                        Text(query).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .textSelection(.enabled)
                    }
                    Text(store.config.steps.battle
                         ? tr("Tag \(tag.name) mají tvoji nejlepší útočníci každého typu, @typ vybere ty, kdo mají útok toho typu.",
                              "Your best attackers of each type have the \(tag.name) tag; @type picks those with a move of that type.")
                         : tr("Tag \(tag.name) dá tvým nejlepším útočníkům krok Battle tagy. Zapni ho na Přehledu.",
                              "The Battle tags step gives your best attackers the \(tag.name) tag. Turn it on on the Overview."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(query, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.snappy) { copied = false } }
                } label: {
                    Label(copied ? tr("Zkopírováno", "Copied") : tr("Kopírovat", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(OutlineButtonStyle(height: 30))
            }
            .padding(14)
            .card(radius: 14)
        }
    }

    /// The tag and the types the boss is weak to, the strongest first ("#Raid&@steel,@poison").
    private func query(_ tag: String) -> String? {
        guard let b = battle.data?.battle else { return nil }
        let math = TypeMath(b)
        let weak = b.types.order.map { ($0, math.eff($0, boss.types)) }.filter { $0.1 >= 1.5 }.sorted { $0.1 > $1.1 }.map(\.0)
        guard !weak.isEmpty else { return nil }
        return "#\(tag)&" + weak.map { "@\($0)" }.joined(separator: ",")
    }
}

// MARK: - Details and hints

/// A view that opens a detail popover when clicked, lighter on hover.
private struct DetailButton<Label: View, Detail: View>: View {
    var radius: CGFloat = 0
    var edge: Edge = .bottom
    @ViewBuilder var label: Label
    @ViewBuilder var detail: Detail
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Button { shown = true } label: {
            label
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.text.opacity(hovering ? 0.04 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $shown, arrowEdge: edge) { detail }
    }
}

/// A small "?" that explains a number or a label in a popover.
private struct Hint: View {
    let title: String
    let text: String
    @State private var shown = false

    init(_ hint: (String, String)) {
        title = hint.0
        text = hint.1
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 12)).foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// A number with what it means, in the detail popovers.
private struct Fact: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A raid counter in detail: what the strength means, its numbers and why each move hits hard.
struct RaidDetail: View {
    let c: RaidCounter
    let boss: RaidBoss
    let weather: String
    let best: Double             // the best counter's strength (= 100 %)

    var body: some View {
        let pct = Int((c.strength / best * 100).rounded())
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MonIcon(m: c.mon, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.mon.name).font(.system(size: 17, weight: .medium))
                    Text(BattleFormat.meta(c.mon)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                    Text(tr("proti \(boss.name)", "against \(boss.name)")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(percentText(pct)).font(.system(size: 26, weight: .medium)).monospacedDigit()
                    Text(tr("síla vůči nejlepšímu", "strength vs. the best")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Text(pct >= 100
                 ? tr("Nejsilnější Pokémon z tvého úložiště proti tomuto bossovi. Ostatní v partě se měří vůči němu.",
                      "The strongest Pokémon in your storage against this boss. The others in the party are measured against it.")
                 : tr("Dá zhruba \(pct) % toho, co tvůj nejlepší Pokémon proti tomuto bossovi. Síla spojuje, jak rychle dává poškození a jak dlouho vydrží.",
                      "It does about \(pct)% of what your best Pokémon does against this boss. Strength combines how fast it deals damage and how long it lasts."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if c.evolveTo != nil || c.strength40 != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let evo = c.evolveTo {
                        Label(tr("Počítá se jako \(evo): nejdřív ho vyvin.", "Counted as \(evo): evolve it first."), systemImage: "wand.and.stars")
                    }
                    if let s40 = c.strength40 {
                        Label(tr("Vylepšený na L40 by měl \(percentText(Int((s40 / best * 100).rounded()))).",
                                 "Powered up to L40 it would have \(percentText(Int((s40 / best * 100).rounded()))) strength."),
                              systemImage: "arrow.up")
                    }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.gold)
            }
            WeightedRow(weights: [1, 1, 1], spacing: 8, minColumn: 0) {
                Fact(value: BattleFormat.decimal(c.dps), caption: tr("poškození za sekundu (DPS)", "damage per second (DPS)"))
                Fact(value: tr("\(Int(c.alive.rounded())) s", "\(Int(c.alive.rounded())) s"), caption: tr("vydrží, než omdlí", "until it faints"))
                Fact(value: BattleFormat.number(Int(c.tdo.rounded())), caption: tr("poškození, než omdlí (TDO)", "damage before it faints (TDO)"))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Útoky a proč fungují", "Moves and why they work")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                move(c.fast, tr("rychlý útok", "fast move"))
                move(c.charged, tr("nabitý útok", "charged move"))
            }
            Text(tr("Bot ze hry nečte, jaké útoky Pokémon má: počítá s nejlepšími útoky druhu. Ověř je ve hře.",
                    "The bot doesn't read a Pokémon's moves from the game: it assumes the species' best moves. Check them in the game."))
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
    }

    private func move(_ m: GameData.Move, _ kind: String) -> some View {
        let parts = factors(m)
        let total = parts.map(\.1).reduce(1, *)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TypePill(type: m.type)
                Text(m.name).font(.system(size: 13, weight: .medium))
                Text(kind).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            FlowRow(spacing: 4) {
                ForEach(parts.indices, id: \.self) { i in factor(parts[i].0, parts[i].1) }
                Text("= \(BattleFormat.multiplier(total))×").font(.system(size: 12, weight: .semibold)).frame(height: 20)
            }
        }
    }

    /// What multiplies the move's damage: same type as the Pokémon, the type chart, the weather.
    private func factors(_ m: GameData.Move) -> [(String, Double)] {
        var out: [(String, Double)] = []
        if c.formTypes.contains(m.type) { out.append((tr("stejný typ jako Pokémon", "same type as the Pokémon"), 1.2)) }
        if let battle = BattleStore.shared.data?.battle {
            let math = TypeMath(battle)
            let e = math.eff(m.type, boss.types)
            let type = BattleType.name(m.type)
            if e > 1.01 {
                let weak = boss.types.filter { math.eff(m.type, [$0]) > 1 }
                out.append((tr("\(type) proti \(BattleFormat.list(weak.map(BattleType.dative)))", "\(type) vs \(BattleFormat.list(weak.map(BattleType.name)))"), e))
            } else if e < 0.99 {
                out.append((tr("\(boss.name) to snáší dobře", "\(boss.name) resists it"), e))
            }
            if math.boosts(weather, m.type) { out.append((tr("počasí", "weather"), 1.2)) }
        }
        return out
    }

    private func factor(_ label: String, _ value: Double) -> some View {
        Text("\(label) \(BattleFormat.multiplier(value))×")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(value >= 1 ? Theme.text : Theme.red)
            .padding(.horizontal, 7).frame(height: 20)
            .background(value >= 1 ? Theme.raise : Theme.redTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A PvP team member in detail: its role, score, IV rank, the level to power it to, its moves and how it does
/// against the league's most played.
struct PvPDetail: View {
    let m: PvPMember
    let league: PvPLeague
    @ObservedObject private var battle = BattleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MonIcon(m: m.mon, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.mon.name).font(.system(size: 17, weight: .medium))
                        if m.evolves { Text("→ \(m.formName)").font(.system(size: 14)).foregroundStyle(Theme.muted) }
                    }
                    Text(BattleFormat.meta(m.mon)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                    Text(league.name).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                Label(m.role.title, systemImage: m.role.symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(BattleHints.role(m.role)).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            WeightedRow(weights: [1, 1, 1], spacing: 8, minColumn: 0) {
                Fact(value: "\(Int(m.ranking.score.rounded()))", caption: tr("skóre druhu v lize podle PvPoke (0–100)", "the species' score in the league by PvPoke (0–100)"))
                Fact(value: "#\(m.rank)", caption: tr("IV rank z 4 096, \(percentText(Int((m.statProduct * 100).rounded(.down)))) ideálu",
                                                      "IV rank of 4,096, \(percentText(Int((m.statProduct * 100).rounded(.down)))) of the ideal"))
                Fact(value: "\(BattleFormat.number(m.cp)) CP", caption: tr("na \(BattleFormat.level(m.level))", "at \(BattleFormat.level(m.level))"))
            }
            VStack(alignment: .leading, spacing: 4) {
                if m.evolves { Label(tr("Nejdřív ho vyvin na \(m.formName).", "Evolve it into \(m.formName) first."), systemImage: "wand.and.stars") }
                if m.powerUp { Label(powerUpText, systemImage: "arrow.up") }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.gold)
            Text(league.cap == nil
                 ? tr("Master League nemá limit CP, takže vedou co nejvyšší IV a level 50.",
                      "The Master League has no CP limit, so the highest IVs and level 50 win.")
                 : tr("V lize s limitem CP vede nízký útok a vysoká obrana a HP: Pokémon se pak vejde na vyšší level a vydrží víc. Proto IV rank není totéž co IV %.",
                      "In a league with a CP limit, low attack and high defense and HP win: the Pokémon fits at a higher level and lasts longer. That's why the IV rank isn't the IV %."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Doporučené útoky", "Recommended moves")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                ForEach(Array(m.ranking.moveset.enumerated()), id: \.offset) { i, id in
                    if let mv = battle.data?.battle?.moves[id] {
                        HStack(spacing: 8) {
                            TypePill(type: mv.type)
                            Text(mv.name).font(.system(size: 13, weight: .medium))
                            Text(i == 0 ? tr("rychlý", "fast") : tr("nabitý", "charged")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Proti \(m.wins.count + m.losses.count + m.even) nejhranějším: vyhraje \(m.wins.count), prohraje \(m.losses.count), vyrovnaných \(m.even)",
                        "Against the \(m.wins.count + m.losses.count + m.even) most played: wins \(m.wins.count), loses \(m.losses.count), close \(m.even)"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                chips(m.wins, Theme.green, Theme.greenTint)
                chips(m.losses, Theme.red, Theme.redTint)
            }
            Text(tr("Zápasy jsou ze simulací PvPoke; kde je PvPoke neuvádí, odhaduje je IVory podle typů útoků a síly druhů.",
                    "The matchups are from PvPoke's simulations; where PvPoke doesn't list them, IVory estimates them from move types and species strength."))
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }

    private var powerUpText: String {
        let lvl = BattleFormat.level(m.level)
        guard let cap = league.cap else { return tr("Vylepši ho na \(lvl).", "Power it up to \(lvl).") }
        return tr("Vylepši ho na \(lvl): \(BattleFormat.number(m.cp)) CP, víc by přesáhlo limit \(BattleFormat.number(cap)).",
                  "Power it up to \(lvl): \(BattleFormat.number(m.cp)) CP; more would go over the \(BattleFormat.number(cap)) limit.")
    }

    @ViewBuilder private func chips(_ ids: [String], _ color: Color, _ tint: Color) -> some View {
        if !ids.isEmpty {
            FlowRow(spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    Text(battle.data?.battle?.pokemon[id]?.name ?? id)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}

/// The texts behind the "?" hints.
enum BattleHints {
    static var strength: (String, String) {
        (tr("Síla vůči nejlepšímu", "Strength vs. the best"),
         tr("100 % má tvůj nejsilnější Pokémon proti tomuto bossovi, ostatní se měří vůči němu: 90 % dá zhruba o desetinu méně. Síla spojuje rychlost poškození (DPS) a výdrž, tedy kolik poškození dá, než omdlí. Rychlost se počítá víc, protože raid má časový limit. Klikni na Pokémona pro rozpis.",
            "Your strongest Pokémon against this boss has 100%, the others are measured against it: 90% does about a tenth less. Strength combines damage per second (DPS) and staying power, how much damage it deals before it faints. Speed counts more because a raid has a time limit. Click a Pokémon for the breakdown."))
    }
    static var party: (String, String) {
        (tr("Jak číst raid partu", "How to read the raid party"),
         tr("Šest nejsilnějších Pokémonů z tvého úložiště proti tomuto bossovi, každý s útoky, které mu sedí nejlíp. Barevný štítek říká, proč funguje: 1,6× = útok je proti typu bosse super efektivní, 2,56× proti oběma jeho typům, 0,63× neefektivní. „Slabší volba“ nemá typovou výhodu. Klikni na Pokémona pro detail.",
            "The six strongest Pokémon in your storage against this boss, each with the moves that suit it best. The colored label says why it works: 1.6× = the move is super effective against the boss's type, 2.56× against both its types, 0.63× not very effective. A \"weaker pick\" has no type advantage. Click a Pokémon for details."))
    }
    static var chance: (String, String) {
        (tr("Šance na výhru", "Win chance"),
         tr("Odhad, jestli bosse porazíte v časovém limitu raidu (3 minuty u 1★ a 3★, 5 minut u 5★ a Mega). Počítá, že každý hráč má podobnou šestici jako ty a po vypadnutí ztratí asi 15 s návratem. Sloupce ukazují šanci pro 1 až 6 hráčů, kliknutím vybereš počet.",
            "An estimate of whether you beat the boss within the raid's time limit (3 minutes for 1★ and 3★, 5 minutes for 5★ and Mega). It assumes every player has a six like yours and loses about 15 s rejoining after a wipe. The bars show the chance for 1 to 6 players; click one to pick the count."))
    }
    static var weather: (String, String) {
        (tr("Počasí", "Weather"),
         tr("Počasí ve hře posiluje útoky některých typů o 20 %, tvoje i bossovy, a zvyšuje CP bosse při chycení. Přepni podle počasí, které teď máš ve hře.",
            "In-game weather makes moves of some types 20% stronger, yours and the boss's, and raises the boss's catch CP. Switch to the weather you have in the game now."))
    }
    static var answered: (String, String) {
        (tr("Odpověď na nejhranější", "An answer to the most played"),
         tr("Kolik z 30 nejhranějších Pokémonů ligy (podle žebříčku PvPoke) tým zvládne: aspoň jeden člen proti nim jasně vyhrává. Vlastní druhy se nepočítají, souboj stejných je vyrovnaný.",
            "How many of the league's 30 most played Pokémon (by the PvPoke ranking) the team handles: at least one member clearly beats them. The team's own species don't count; a mirror match is even."))
    }
    static var strong: (String, String) {
        (tr("Silný proti", "Strong vs"),
         tr("Soupeři, které porazí aspoň dva ze tří členů. Proti nim tým obstojí, i když ti jeden člen vypadne.",
            "Opponents that at least two of the three members beat. The team holds up against them even when one member is down."))
    }
    static var weak: (String, String) {
        (tr("Slabý proti", "Weak vs"),
         tr("Nejdřív soupeři, na které tým nemá odpověď, pak ti, kteří porazí dva ze tří členů. Když na ně v lize často narážíš, zkus jiný tým.",
            "First the opponents the team has no answer to, then those that beat two of the three members. If you meet them often in the league, try another team."))
    }
    static var raidUpgrades: (String, String) {
        (tr("Vylepšení pro raidy", "Power-ups for raids"),
         tr("Plán vylepšení na L40, od nejvýhodnějšího. Každý krok je ten, po kterém tvá nejlepší šestice daného typu útoku zesílí nejvíc za každý stardust, a počítá s tím, že předchozí kroky jsou hotové, takže druhý Kyurem se měří proti prvnímu už na L40. Od jednoho druhu jsou nejvýš dva kusy, aby jeden druh nevytlačil ostatní typy. Síla se počítá proti neutrálnímu bossovi; procento je síla samotného Pokémona.",
            "A plan of power-ups to L40, best value first. Each step is the one that makes your best six of an attack type gain the most per stardust, and it assumes the earlier steps are done, so a second Kyurem is measured against the first one already at L40. At most two of the same species, so one species doesn't crowd out every other type. Strength is measured against a neutral boss; the percentage is the Pokémon's own strength."))
    }
    static var pvpUpgrades: (String, String) {
        (tr("Vylepšení pro PvP", "Power-ups for PvP"),
         tr("Členové týmů, které dostanou Battle tagy (vybraný tým každé ligy, jinak první), vylepšení na nejvyšší level pod limitem CP ligy. Víc by limit přesáhlo.",
            "Members of the teams that get the Battle tags (each league's picked team, the first otherwise), powered up to the highest level under the league's CP limit. More would go over it."))
    }
    static var coverage: (String, String) {
        (tr("Proti nejhranějším", "Against the most played"),
         tr("Deset nejhranějších Pokémonů ligy podle žebříčku PvPoke a jak si proti nim vede každý člen týmu: vyhraje, vyrovnané, prohraje. „Zvládne“ znamená, že aspoň jeden člen jasně vyhrává, „díra“ je soupeř, na kterého nemá odpověď nikdo. Vlastní druhy týmu se nepočítají.",
            "The league's ten most played Pokémon by the PvPoke ranking and how each team member does against them: win, close, loss. \"Handled\" means at least one member clearly wins, a \"gap\" is an opponent nobody answers. The team's own species don't count."))
    }
    static var score: (String, String) {
        (tr("Skóre", "Score"),
         tr("Jak silný je druh v této lize podle simulací PvPoke, 0–100. Nezávisí na IV tvého kusu.",
            "How strong the species is in this league by PvPoke's simulations, 0–100. It doesn't depend on your Pokémon's IVs."))
    }

    static func role(_ r: PvPRole) -> String {
        switch r {
        case .lead: tr("Začíná zápas. Má vyhrát první souboj, nebo aspoň vytáhnout soupeři štíty.",
                       "Starts the match. It should win the first fight, or at least draw out the opponent's shields.")
        case .switcher: tr("Nastupuje, když lead prohrává. Má být bezpečný proti hodně soupeřům.",
                           "Comes in when the lead is losing. It should be safe against many opponents.")
        case .closer: tr("Dohrává na konci, často když už soupeř nemá štíty.",
                         "Finishes at the end, often when the opponent has no shields left.")
        }
    }
}

// MARK: - Texts and colors

/// Types: names in both languages (Czech also in the dative, "proti Trávě"), colors and icons from the design.
enum BattleType {
    private static let table: [String: (cs: String, dative: String, en: String, hue: Double, chroma: Double, symbol: String)] = [
        "normal": ("Normální", "Normálnímu", "Normal", 90, 0.03, "circle"),
        "fire": ("Oheň", "Ohni", "Fire", 40, 0.15, "flame.fill"),
        "water": ("Voda", "Vodě", "Water", 245, 0.13, "drop.fill"),
        "grass": ("Tráva", "Trávě", "Grass", 145, 0.14, "leaf.fill"),
        "electric": ("Elektřina", "Elektřině", "Electric", 95, 0.14, "bolt.fill"),
        "ice": ("Led", "Ledu", "Ice", 210, 0.1, "snowflake"),
        "fighting": ("Boj", "Boji", "Fighting", 30, 0.14, "figure.boxing"),
        "poison": ("Jed", "Jedu", "Poison", 320, 0.14, "flask.fill"),
        "ground": ("Země", "Zemi", "Ground", 70, 0.1, "mountain.2.fill"),
        "flying": ("Létání", "Létání", "Flying", 270, 0.1, "bird.fill"),
        "psychic": ("Psychika", "Psychice", "Psychic", 355, 0.14, "eye.fill"),
        "bug": ("Hmyz", "Hmyzu", "Bug", 125, 0.13, "ladybug.fill"),
        "rock": ("Kámen", "Kameni", "Rock", 75, 0.07, "cube.fill"),
        "ghost": ("Duch", "Duchu", "Ghost", 300, 0.12, "theatermasks.fill"),
        "dragon": ("Drak", "Drakovi", "Dragon", 285, 0.15, "lizard.fill"),
        "dark": ("Temno", "Temnu", "Dark", 20, 0.03, "moon.fill"),
        "steel": ("Ocel", "Oceli", "Steel", 220, 0.04, "shield.fill"),
        "fairy": ("Víla", "Víle", "Fairy", 0, 0.12, "sparkles"),
    ]

    static func name(_ t: String) -> String { table[t].map { tr($0.cs, $0.en) } ?? t.capitalized }
    static func dative(_ t: String) -> String { table[t].map { tr($0.dative, $0.en) } ?? t.capitalized }
    static func symbol(_ t: String) -> String { table[t]?.symbol ?? "circle" }

    static func color(_ t: String) -> Color {
        let v = table[t] ?? ("", "", "", 280, 0.02, "")
        return .adaptive(dark: .oklch(0.78, v.chroma, v.hue), light: .oklch(0.5, v.chroma, v.hue))
    }

    static func tint(_ t: String) -> Color {
        let v = table[t] ?? ("", "", "", 280, 0.02, "")
        return .adaptive(dark: .oklch(0.78, v.chroma, v.hue, alpha: 0.18), light: .oklch(0.5, v.chroma, v.hue, alpha: 0.14))
    }
}

enum BattleWeather {
    static func name(_ w: String) -> String {
        switch w {
        case "sunny": tr("Slunečno", "Sunny")
        case "rainy": tr("Déšť", "Rain")
        case "partly cloudy": tr("Polojasno", "Partly cloudy")
        case "cloudy": tr("Zataženo", "Cloudy")
        case "windy": tr("Větrno", "Windy")
        case "snow": tr("Sníh", "Snow")
        case "fog": tr("Mlha", "Fog")
        default: w.capitalized
        }
    }

    static func symbol(_ w: String) -> String {
        ["sunny": "sun.max", "rainy": "cloud.rain", "partly cloudy": "cloud.sun", "cloudy": "cloud", "windy": "wind",
         "snow": "snowflake", "fog": "cloud.fog"][w] ?? "cloud"
    }
}

@MainActor
enum BattleFormat {
    static func number(_ n: Int) -> String { n.formatted(.number.locale(L10n.locale)) }

    static func decimal(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale)) }

    static func multiplier(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale)) }

    static func level(_ l: Double) -> String {
        l == l.rounded() ? "L\(Int(l))" : "L" + l.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
    }

    /// "a, b and c" / "a, b a c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + tr(" a ", " and ") + items[items.count - 1]
    }

    /// "today at 6:02" or the date.
    static func when(_ d: Date) -> String {
        let time = d.formatted(.dateTime.hour().minute().locale(L10n.locale))
        if Calendar.current.isDateInToday(d) { return tr("dnes v \(time)", "today at \(time)") }
        let day = d.formatted(.dateTime.day().month().year().locale(L10n.locale))
        return tr("\(day) v \(time)", "\(day) at \(time)")
    }

    static func meta(_ m: InventoryStats.Mon) -> String {
        var parts = ["IV \(percentText(m.pct))"]
        if let l = m.level { parts.append(level(l)) }
        parts.append("\(number(m.cp)) CP")
        return parts.joined(separator: " · ")
    }

    static func reason(_ c: RaidCounter, _ boss: RaidBoss) -> String {
        let mult = c.effectiveness.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))
        let weather = c.boosted ? tr(" · počasí 1,2×", " · weather 1.2×") : ""
        let type = BattleType.name(c.attackType)
        if c.effectiveness >= 1.5 {
            let math = BattleStore.shared.data?.battle.map(TypeMath.init)
            let weakTo = boss.types.filter { math?.eff(c.attackType, [$0]) ?? 1 > 1 }
            let against = list(weakTo.map(BattleType.dative))
            return tr("\(type) \(mult)× proti \(against)", "\(type) \(mult)× vs \(list(weakTo.map(BattleType.name)))") + weather
        }
        if c.effectiveness < 0.9 { return tr("\(type) jen \(mult)×", "\(type) only \(mult)×") + weather }
        return tr("\(type) bez typové výhody", "\(type), no type advantage") + weather
    }

    static func raidTags(_ c: RaidCounter) -> [BattleTag] {
        var out: [BattleTag] = []
        if let evo = c.evolveTo { out.append(BattleTag(text: tr("vyvinout na \(evo)", "evolve into \(evo)"), symbol: "wand.and.stars")) }
        if c.powerUp { out.append(BattleTag(text: tr("vylepšit na L40", "power up to L40"), symbol: "arrow.up")) }
        return out
    }

    static func pvpTags(_ m: PvPMember) -> [BattleTag] {
        var out: [BattleTag] = []
        if m.evolves { out.append(BattleTag(text: tr("vyvinout na \(m.formName)", "evolve into \(m.formName)"), symbol: "wand.and.stars")) }
        if m.powerUp { out.append(BattleTag(text: tr("vylepšit na \(level(m.level))", "power up to \(level(m.level))"), symbol: "arrow.up")) }
        return out
    }

    static func rank(_ r: Int) -> String { tr("#\(r) z 4 096", "#\(r) of 4,096") }

    static func cp(_ m: PvPMember) -> String {
        m.mon.cp == m.cp && !m.evolves ? "\(number(m.cp)) CP" : "\(number(m.mon.cp)) → \(number(m.cp)) CP"
    }

    static func level(_ m: PvPMember, _ league: PvPLeague) -> String {
        guard !m.powerUp else { return tr("na \(level(m.level))", "to \(level(m.level))") }
        return league.cap == nil ? tr("\(level(m.level)) · na maximu", "\(level(m.level)) · maxed")
            : tr("\(level(m.level)) · na limitu", "\(level(m.level)) · at the limit")
    }

    static func moves(_ moveset: [String]) -> (fast: String, charged: String) {
        let names = moveset.map { BattleStore.shared.data?.battle?.moves[$0]?.name ?? $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return (names.first ?? "", names.dropFirst().joined(separator: " · "))
    }

    /// "Medicham leads. Lanturn and Azumarill cover its threats."
    static func summary(_ team: PvPTeam) -> String {
        let ms = team.members
        guard let lead = ms.first?.formName else {
            return tr("Do ligy se ti zatím nevejde žádný vhodný Pokémon.", "No suitable Pokémon fits the league yet.")
        }
        guard ms.count == 3 else {
            return tr("Neúplný tým, \(ms.count) ze 3. \(lead) začíná.", "An incomplete team, \(ms.count) of 3. \(lead) leads.")
        }
        let sw = ms[1].formName, cl = ms[2].formName
        let covered = team.threats.filter { $0.cells.first == -1 && $0.covered }
            .compactMap { BattleStore.shared.data?.battle?.pokemon[$0.opponent]?.name }
        guard !covered.isEmpty else {
            return tr("\(lead) začíná, \(sw) střídá a \(cl) dokončuje.", "\(lead) leads, \(sw) switches in and \(cl) closes.")
        }
        return tr("\(lead) začíná. \(sw) a \(cl) kryjí jeho hrozby, \(list(covered.prefix(2).map { $0 })).",
                  "\(lead) leads. \(sw) and \(cl) cover its threats, \(list(covered.prefix(2).map { $0 })).")
    }

    static func leagueColor(_ l: PvPLeague) -> Color {
        switch l {
        case .great: .oklch(0.72, 0.13, 250)
        case .ultra: .oklch(0.84, 0.15, 92)
        case .master: .oklch(0.7, 0.15, 300)
        }
    }

}
