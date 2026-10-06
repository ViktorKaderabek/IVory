import SwiftUI

/// Power-ups: where the stardust is worth spending. One recommendation at the top, then the two reasons
/// to power anything up at all, side by side – getting a PvP team member to its league's CP limit, and
/// doing more damage to the bosses that are up right now.
struct PowerUpsScreen: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var battle = BattleStore.shared
    @ObservedObject private var statsStore = StatsStore.shared
    @ObservedObject private var selection = PowerUpSelection.shared
    /// Empty state: back to Run and start a run.
    var startRun: () -> Void

    /// How many rows each column shows.
    private static let rows = 8

    private var mons: [InventoryStats.Mon] { statsStore.stats?.mons ?? [] }

    var body: some View {
        let pvp = Array(pvpRows.prefix(Self.rows))
        let raids = Array(battle.raidUpgrades(perType: store.config.battle.raid.perType, mons: mons).prefix(Self.rows))

        VStack(alignment: .leading, spacing: 28) {
            header
            if let stats = statsStore.stats, stats.isEmpty {
                NeverRun(startRun: startRun,
                         promise: tr("koho vylepšit stardustem a co za to dostaneš",
                                     "which Pokémon to power up with stardust, and what you get for it"))
            } else if battle.data?.battle == nil {
                Color.clear.frame(height: 200)
            } else {
                if let best = bestValue(pvp: pvp, raids: raids) {
                    Button { selection.open(best) } label: { StartHere(pick: best) }
                        .buttonStyle(CardButtonStyle())
                        .entrance(0.05, rise: 10)
                }
                WeightedColumns(weights: [1, 1], spacing: 20) {
                    pvpColumn(pvp).entrance(0.12, rise: 10)
                    raidColumn(raids).entrance(0.18, rise: 10)
                }
                Text(tr("Ceny platí pro běžné kusy: lucky stojí polovinu stardustu, shadow o 20 % víc a purified o 10 % míň. Candy na vyvinutí se nepočítá.",
                        "The costs are for regular Pokémon: lucky ones cost half the stardust, shadow ones 20% more and purified ones 10% less. Candy for evolving isn't counted."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { battle.appear() }
        #if DEBUG
        // Appearance check: IVORY_DETAIL=pvp|raid opens that kind of power-up at launch.
        .onChange(of: battle.teams.count) { _, _ in openPreviewDetail(pvp: pvp, raids: raids) }
        .onAppear { openPreviewDetail(pvp: pvp, raids: raids) }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Vylepšení", "Power-ups"))
                .font(.system(size: 26, weight: .medium))
            Text(tr("Koho vylepšit stardustem a co za to dostaneš. Jsou tu jen Pokémoni z tvých PvP týmů a nejlepších raid part. Klepnutím otevřeš detail.",
                    "Which Pokémon to power up with stardust, and what you get for it. Only Pokémon from your PvP teams and your best raid parties are listed. Click one for the details."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: - What to do first

    enum Pick {
        case pvp(league: PvPLeague, member: PvPMember)
        case raid(RaidUpgrade)
    }

    /// The one to start with. A team member that still isn't at its league's cap wins – it is the cheapest
    /// way to make a team strictly better – and the cheapest of those; with no such member, the raid
    /// upgrade that buys the most party strength per stardust.
    private func bestValue(pvp: [(league: PvPLeague, member: PvPMember)], raids: [RaidUpgrade]) -> Pick? {
        if let first = pvp.first { return .pvp(league: first.league, member: first.member) }
        if let first = raids.max(by: { $0.value < $1.value }) { return .raid(first) }
        return nil
    }

    // MARK: - PvP

    /// Members of each league's tagged team that still have room under the cap, cheapest first.
    private var pvpRows: [(league: PvPLeague, member: PvPMember)] {
        PvPLeague.allCases.flatMap { league -> [(league: PvPLeague, member: PvPMember)] in
            guard let r = battle.teams[league] else { return [] }
            let team = battle.chosenTeam(r, store.config.battle.team(league)) ?? r.teams.first
            return (team?.members ?? []).filter(\.powerUp).map { (league, $0) }
        }
        .sorted { battle.price($0.member).stardust < battle.price($1.member).stardust }
    }

    private func pvpColumn(_ rows: [(league: PvPLeague, member: PvPMember)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHead("trophy", tr("Pro tvoje PvP týmy", "For your PvP teams"),
                       tr("Cíl: dostat se co nejblíž limitu CP ligy. Pruh ukazuje CP teď, co přidá vylepšení, a limit.",
                          "Goal: get as close to the league's CP limit as possible. The bar shows CP now, what the power-up adds, and the limit."),
                       total: rows.reduce(0) { $0 + battle.price($1.member).stardust })
            if rows.isEmpty {
                emptyCard(tr("Členové týmů už jsou na limitu ligy.", "The team members are already at the league's cap."))
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        RowButton(open: { selection.open(.pvp(league: row.league, member: row.member)) },
                                  selected: selection.isOpen(.pvp(league: row.league, member: row.member))) {
                            PvPUpgradeCell(league: row.league, member: row.member, color: leagueColor(row.league))
                        }
                    }
                }
                .padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            }
        }
    }

    // MARK: - Raids

    private func raidColumn(_ rows: [RaidUpgrade]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHead("shield", tr("Pro raidy", "For raids"),
                       tr("Cíl: víc damage proti aktuálním bossům. Do L40, nejvíc damage za stardust napřed.",
                          "Goal: more damage against the current bosses. Up to L40, the most damage per stardust first."),
                       total: rows.reduce(0) { $0 + $1.price.stardust })
            if rows.isEmpty {
                emptyCard(tr("Žádné vylepšení na L40 by tvou nejlepší partu nezměnilo.",
                             "No power-up to L40 would change your best party."))
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, u in
                        RowButton(open: { selection.open(.raid(u)) }, selected: selection.isOpen(.raid(u))) {
                            RaidUpgradeCell(u: u, bosses: helps(u))
                        }
                    }
                }
                .padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            }
        }
    }

    /// The bosses that are up now and take extra damage from the type this power-up raises.
    private func helps(_ u: RaidUpgrade) -> [RaidBoss] {
        guard let b = battle.data?.battle else { return [] }
        let math = TypeMath(b)
        return battle.bosses.filter { math.eff(u.type, $0.types) > 1 }.prefix(2).map { $0 }
    }

    // MARK: - Bits

    private func columnHead(_ symbol: String, _ title: String, _ note: String, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accentInk)
                Text(title).font(.system(size: 17, weight: .medium))
                Spacer(minLength: 8)
                Text(tr("\(number(total)) stardustu", "\(number(total)) stardust"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyCard(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func leagueColor(_ league: PvPLeague) -> Color {
        (store.config.pvp.all.first { $0.key == league.rawValue }?.league.color ?? .purple).swatch
    }

    #if DEBUG
    private func openPreviewDetail(pvp: [(league: PvPLeague, member: PvPMember)], raids: [RaidUpgrade]) {
        guard selection.pick == nil else { return }
        // next turn of the run loop – see the note in StorageScreen
        switch ProcessInfo.processInfo.environment["IVORY_DETAIL"] {
        case "pvp":
            if let first = pvp.first {
                DispatchQueue.main.async { selection.open(.pvp(league: first.league, member: first.member)) }
            }
        case "raid":
            if let first = raids.first { DispatchQueue.main.async { selection.open(.raid(first)) } }
        default: break
        }
    }
    #endif
}

/// The single recommendation at the top of the screen.
struct StartHere: View {
    let pick: PowerUpsScreen.Pick
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var battle = BattleStore.shared

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                RadialGradient(colors: [Theme.bg.opacity(0.4), .clear], center: UnitPoint(x: 0.5, y: 0.7),
                               startRadius: 0, endRadius: 150)
                MonArtwork(m: mon, size: 140)
            }
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(tr("ZAČNI TADY · NEJLEPŠÍ POMĚR", "START HERE · THE BEST VALUE"))
                    .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(Theme.accentInk)
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(reasonColor).frame(width: 8, height: 8).padding(.top, 5)
                    Text(reason)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .pvp(let league, let member) = pick {
                    PowerUpCPBar(now: member.mon.cp, after: member.cp, cap: league.cap, height: 8, split: true)
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(number(price.stardust))
                    .font(.system(size: 32, weight: .medium).monospacedDigit())
                Text(tr("stardustu", "stardust"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 4) {
                    Text(tr("Detail", "Details")).font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.right").font(.system(size: 11))
                }
                .foregroundStyle(Theme.accentInk)
                .padding(.top, 10)
            }
            .padding(.leading, 24)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(LinearGradient(colors: [Theme.tint, Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1)
        }
    }

    private var mon: InventoryStats.Mon {
        switch pick {
        case .pvp(_, let m): return m.mon
        case .raid(let u): return u.counter.mon
        }
    }

    private var price: GameData.Price {
        switch pick {
        case .pvp(_, let m): return battle.price(m)
        case .raid(let u): return u.price
        }
    }

    private var title: String {
        switch pick {
        case .pvp(_, let m):
            return tr("Vylepši \(m.mon.name) z L\(levelText(m.mon.level)) na L\(levelText(m.level))",
                      "Power up \(m.mon.name) from L\(levelText(m.mon.level)) to L\(levelText(m.level))")
        case .raid(let u):
            return tr("Vylepši \(u.counter.mon.name) z L\(levelText(u.counter.mon.level)) na L40",
                      "Power up \(u.counter.mon.name) from L\(levelText(u.counter.mon.level)) to L40")
        }
    }

    private var reason: String {
        switch pick {
        case .pvp(let league, let m):
            guard let cap = league.cap else {
                return tr("Je v tvém týmu pro \(league.name), kde CP nic neomezuje.",
                          "It's in your \(league.name) team, where nothing caps the CP.")
            }
            return tr("Je v tvém týmu pro \(league.name) a dostane se na \(number(m.cp)) z limitu \(number(cap)) CP.",
                      "It's in your \(league.name) team and gets to \(number(m.cp)) of the \(number(cap)) CP limit.")
        case .raid(let u):
            let gain = Int((u.gain * 100).rounded())
            return tr("Dá o \(gain) % víc damage jako \(BattleType.name(u.type)) útočník.",
                      "It does \(gain)% more damage as a \(BattleType.name(u.type)) attacker.")
        }
    }

    private var reasonColor: Color {
        switch pick {
        case .pvp(let league, _):
            return (store.config.pvp.all.first { $0.key == league.rawValue }?.league.color ?? .purple).swatch
        case .raid(let u):
            return BattleType.color(u.type)
        }
    }
}

extension PowerUpsScreen.Pick {
    /// Identity that survives the lists being recomputed.
    var key: String {
        switch self {
        case .pvp(let league, let member): return "p-\(league.rawValue)-\(member.id)"
        case .raid(let u): return "r-\(u.id)"
        }
    }
}
