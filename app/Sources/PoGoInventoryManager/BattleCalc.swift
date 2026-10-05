import Foundation

/// The type chart and weather boosts from the game data.
struct TypeMath {
    private let index: [String: Int]
    private let chart: [String: [Double]]
    let weather: [String: [String]]

    init(_ battle: GameData.Battle) {
        index = Dictionary(uniqueKeysWithValues: battle.types.order.enumerated().map { ($1, $0) })
        chart = battle.types.chart
        weather = battle.weather
    }

    /// How effective an attack type is against a Pokémon of these types (1.6 per weakness, 0.625 per resistance).
    func eff(_ attack: String, _ defender: [String]) -> Double {
        defender.reduce(1) { acc, t in
            guard let row = chart[attack], let i = index[t], i < row.count else { return acc }
            return acc * row[i]
        }
    }

    func boosts(_ weather: String, _ type: String) -> Bool { self.weather[weather]?.contains(type) ?? false }
}

/// Damage like in the game: ⌊½ · power · attack / defense · multipliers⌋ + 1.
private func damage(_ power: Double, _ attack: Double, _ defense: Double, _ multiplier: Double) -> Double {
    (0.5 * power * attack / defense * multiplier).rounded(.down) + 1
}

// MARK: - Raids

/// One Pokémon from the storage against a raid boss, with the moves that suit it best.
struct RaidCounter: Identifiable {
    let mon: InventoryStats.Mon
    let formName: String
    let evolveTo: String?        // the Pokémon fights as its evolution
    let fast: GameData.Move
    let charged: GameData.Move
    let attackType: String       // the type of the move that does the work
    let effectiveness: Double
    let boosted: Bool
    let dps: Double
    let tdo: Double              // damage dealt before it faints
    let alive: Double            // seconds until it faints
    let formTypes: [String]      // the types it fights with (its evolution's, when it has to evolve)
    let formStats: [Int]         // and its stats, for the CP at a level
    let strength40: Double?      // the same moves at level 40, when it's below that now

    var id: Int { mon.id }
    /// DPS³ · TDO, the usual raid measure (fast damage counts more than staying power), on a linear scale.
    var strength: Double { (dps * dps * dps * tdo).squareRoot().squareRoot() }
    var weak: Bool { effectiveness < 1.5 }
    var powerUp: Bool { (mon.level ?? 40) <= 35 }
}

/// A raid attacker worth powering up to level 40.
struct RaidUpgrade: Identifiable {
    let counter: RaidCounter     // as it is now
    let type: String             // the attack type it rises in
    let rankNow: Int?            // its place among your attackers of the type now (nil = not among the best)
    let rankAfter: Int           // … at level 40
    let gain: Double             // its own strength gained (0.35 = 35 % more)
    let partyGain: Double        // what the type's best party gains, in units of its strongest attacker
    let price: GameData.Price

    var id: Int { counter.mon.id }
    /// The party's gain per stardust, what the list is sorted by.
    var value: Double { partyGain / Double(max(price.stardust, 1)) }
    /// Its own strength gained per 100,000 stardust, the number shown in the list.
    var gainPer100k: Double { gain / Double(max(price.stardust, 1)) * 100_000 }
}

struct RaidResult {
    let counters: [RaidCounter]  // the best 6
    let chances: [Int]?          // win chance in % for 1–6 players; nil when the tier's numbers aren't known
}

/// Raid counters and the win chance. An estimate from public data, not a battle simulation: the best moves of
/// each species (the bot doesn't read the moves), the average of the boss's moves, no dodging, no friendship
/// bonus, no shadow or purified attackers.
struct RaidCalc {
    let data: GameData
    private let battle: GameData.Battle
    private let types: TypeMath

    init(data: GameData) {
        self.data = data
        battle = data.battle!
        types = TypeMath(data.battle!)
    }

    func counters(_ boss: RaidBoss, weather: String, mons: [InventoryStats.Mon]) -> RaidResult? {
        guard let id = boss.form, let form = battle.pokemon[id] else { return nil }
        // a shadow boss hits 1.2× harder; the lower defense of shadows is left out because its enrage (not
        // modelled) more than makes up for it
        let bossAttack = Double(form.stats[0] + 15) * boss.tier.cpm * (boss.tier.isShadow ? 1.2 : 1)
        let bossDefense = Double(form.stats[1] + 15) * boss.tier.cpm
        let elite = Set(form.elite ?? [])
        let bossFast = form.fast.filter { !elite.contains($0) }.compactMap { battle.moves[$0] }
        let bossCharged = form.charged.filter { !elite.contains($0) }.compactMap { battle.moves[$0] }
        let ctx = Context(bossTypes: form.types, bossAttack: bossAttack, bossDefense: bossDefense,
                          bossFast: bossFast, bossCharged: bossCharged, weather: weather)

        var all: [RaidCounter] = []
        for mon in mons {
            guard let sid = mon.sid, let level = mon.level, mon.iv.count == 3 else { continue }
            var forms = [sid]
            for f in data.finalForms(sid) where !forms.contains(f) { forms.append(f) }
            let best = forms.compactMap { fight(mon, as: $0, level: level, ctx) }.max { $0.strength < $1.strength }
            if let best { all.append(best) }
        }
        let top = Array(all.sorted { $0.strength > $1.strength }.prefix(6))
        let chances: [Int]? = boss.tier.hp.map { hp in (1...6).map { chance(top, players: $0, bossHP: hp, seconds: boss.tier.seconds) } }
        return RaidResult(counters: top, chances: top.isEmpty ? nil : chances)
    }

    /// The best raid attackers of each attack type, by their charged move's type, against a neutral boss (no type
    /// advantage, a typical legendary's stats and average moves). For the Raid tag: in the game,
    /// #Raid&@steel then finds the steel ones. Pokémon as they are now, without evolving.
    func leaders(mons: [InventoryStats.Mon], perType: Int) -> [String: [RaidCounter]] {
        attackers(mons).mapValues { Array($0.prefix(perType)) }
    }

    /// A plan of raid power-ups to level 40, best value first: each step is the power-up that makes your best
    /// `perType` party of some attack type gain the most per stardust. Every chosen step counts as done for the
    /// next one, so a second Kyurem is judged against the first one already at L40 (and doesn't claim its place).
    /// At most `perSpecies` of the same species, so one species you own many of doesn't crowd out every other type.
    func upgrades(mons: [InventoryStats.Mon], perType: Int, steps: Int = 24, perSpecies: Int = 2) -> [RaidUpgrade] {
        guard let costs = battle.upgrades else { return [] }
        let byType = attackers(mons)
        var strength: [Int: Double] = [:]        // mon id -> strength now (level 40 once it's in the plan)
        var upgraded: Set<Int> = []
        var count: [String: Int] = [:]           // species -> how many are already in the plan
        var plan: [RaidUpgrade] = []

        func party(_ list: [RaidCounter], without: Int? = nil, with: Double? = nil) -> Double {
            var values = list.filter { $0.mon.id != without }.map { strength[$0.mon.id] ?? $0.strength }
            if let with { values.append(with) }
            return values.sorted(by: >).prefix(perType).reduce(0, +)
        }

        while plan.count < steps {
            var best: (upgrade: RaidUpgrade, id: Int)?
            for (type, list) in byType {
                guard let top = list.first?.strength, top > 0 else { continue }
                let before = party(list)
                for c in list where !upgraded.contains(c.mon.id) {
                    guard let s40 = c.strength40, let level = c.mon.level,
                          count[c.formName, default: 0] < perSpecies else { continue }
                    let after = party(list, without: c.mon.id, with: s40)
                    guard after - before > 0.001 * top else { continue }
                    let price = costs.cost(from: level, to: 40)
                    // the rank it has today; the rank after the plan is filled in below, once every step is known
                    let rankNow = 1 + list.filter { $0.mon.id != c.mon.id && $0.strength > c.strength }.count
                    let u = RaidUpgrade(counter: c, type: type, rankNow: rankNow <= perType ? rankNow : nil,
                                        rankAfter: 0, gain: s40 / c.strength - 1,
                                        partyGain: (after - before) / top, price: price)
                    if best.map({ u.value > $0.upgrade.value }) ?? true { best = (u, c.mon.id) }
                }
            }
            guard let pick = best else { break }
            plan.append(pick.upgrade)
            upgraded.insert(pick.id)
            count[pick.upgrade.counter.formName, default: 0] += 1
            strength[pick.id] = pick.upgrade.counter.strength40
        }
        // where each one ends up once the whole plan is done, so only one of a type is #1
        return plan.map { u in
            let list = byType[u.type] ?? []
            let mine = strength[u.counter.mon.id] ?? u.counter.strength
            let ahead = list.filter { $0.mon.id != u.counter.mon.id && (strength[$0.mon.id] ?? $0.strength) > mine }
            return RaidUpgrade(counter: u.counter, type: u.type, rankNow: u.rankNow, rankAfter: 1 + ahead.count,
                               gain: u.gain, partyGain: u.partyGain, price: u.price)
        }
    }

    /// Every attacker of each attack type (its charged move's, of the Pokémon's own type: a Xerneas with Megahorn
    /// isn't a bug attacker), the strongest first, against a neutral boss.
    private func attackers(_ mons: [InventoryStats.Mon]) -> [String: [RaidCounter]] {
        let ctx = Context(bossTypes: [], bossAttack: 240 * RaidTier.t5.cpm, bossDefense: 200 * RaidTier.t5.cpm,
                          bossFast: [GameData.Move(name: "", type: "", power: 12, duration: 1.5, energy: 10)],
                          bossCharged: [GameData.Move(name: "", type: "", power: 100, duration: 3, energy: 50)],
                          weather: "none")
        var byType: [String: [RaidCounter]] = [:]
        for mon in mons {
            guard let sid = mon.sid, let level = mon.level, mon.iv.count == 3, let form = battle.pokemon[sid] else { continue }
            let types = Set(form.charged.compactMap { battle.moves[$0]?.type }).intersection(form.types)
            for t in types {
                if let c = fight(mon, as: sid, level: level, ctx, chargedType: t) { byType[t, default: []].append(c) }
            }
        }
        return byType.mapValues { $0.sorted { $0.strength > $1.strength } }
    }

    private struct Context {
        let bossTypes: [String]
        let bossAttack: Double
        let bossDefense: Double
        let bossFast: [GameData.Move]
        let bossCharged: [GameData.Move]
        let weather: String
    }

    /// `chargedType`: only movesets whose charged move is of this type (the Raid tag's per-type leaders).
    private func fight(_ mon: InventoryStats.Mon, as id: String, level: Double, _ c: Context,
                       chargedType: String? = nil) -> RaidCounter? {
        guard let form = battle.pokemon[id], form.stats.count == 3 else { return nil }
        // Hidden Power has a random type on each Pokémon, so no particular one can be recommended
        let fastMoves = form.fast.filter { !$0.hasPrefix("HIDDEN_POWER") }.compactMap { battle.moves[$0] }
        let chargedMoves = form.charged.compactMap { battle.moves[$0] }.filter { chargedType == nil || $0.type == chargedType }
        var best: (f: GameData.Move, ch: GameData.Move, p: Performance)?
        for f in fastMoves where f.duration > 0 {
            for ch in chargedMoves where ch.duration > 0 {
                guard let p = perform(form, mon.iv, level, f, ch, c) else { continue }
                if best.map({ p.strength > $0.p.strength }) ?? true { best = (f, ch, p) }
            }
        }
        guard let (f, ch, p) = best else { return nil }
        let fe = types.eff(f.type, c.bossTypes), ce = types.eff(ch.type, c.bossTypes)
        let main = ce >= fe ? ch : f
        return RaidCounter(mon: mon, formName: form.name, evolveTo: id == mon.sid ? nil : form.name,
                           fast: f, charged: ch, attackType: main.type, effectiveness: max(fe, ce),
                           boosted: types.boosts(c.weather, main.type), dps: p.dps, tdo: p.dps * p.alive, alive: p.alive,
                           formTypes: form.types, formStats: form.stats,
                           strength40: level < 40 ? perform(form, mon.iv, 40, f, ch, c)?.strength : nil)
    }

    private struct Performance {
        let dps: Double
        let alive: Double
        var strength: Double { (dps * dps * dps * dps * alive).squareRoot().squareRoot() }
    }

    /// One moveset at one level: damage per second and how long the Pokémon lasts against the boss.
    private func perform(_ form: GameData.Form, _ iv: [Int], _ level: Double, _ f: GameData.Move, _ ch: GameData.Move,
                         _ c: Context) -> Performance? {
        let m = data.cpm(at: level)
        let attack = Double(form.stats[0] + iv[0]) * m
        let defense = Double(form.stats[1] + iv[1]) * m
        let hp = (Double(form.stats[2] + iv[2]) * m).rounded(.down)
        let incoming = bossDPS(c, defense: defense, types: form.types)
        guard incoming > 0 else { return nil }
        func multiplier(_ move: GameData.Move) -> Double {
            (form.types.contains(move.type) ? 1.2 : 1) * types.eff(move.type, c.bossTypes)
                * (types.boosts(c.weather, move.type) ? 1.2 : 1)
        }
        let df = damage(f.power, attack, c.bossDefense, multiplier(f))
        let dc = damage(ch.power, attack, c.bossDefense, multiplier(ch))
        // fast moves until the charged move's energy is there (energy from damage taken speeds this up)
        let energyRate = f.energy / f.duration + 0.5 * incoming
        let fastTime = max(0, ch.energy / max(energyRate, 0.1))
        let cycle = fastTime + ch.duration
        let dps = max((fastTime / f.duration * df + dc) / cycle, df / f.duration)
        return Performance(dps: dps, alive: hp / incoming)
    }

    /// The boss's damage per second against one attacker, averaged over its possible movesets. The boss attacks
    /// every 1.5–2.5 s (2 on average) and uses its charged move as soon as it has the energy.
    private func bossDPS(_ c: Context, defense: Double, types defenderTypes: [String]) -> Double {
        var total = 0.0, n = 0.0
        func multiplier(_ move: GameData.Move) -> Double {
            (c.bossTypes.contains(move.type) ? 1.2 : 1) * types.eff(move.type, defenderTypes)
                * (types.boosts(c.weather, move.type) ? 1.2 : 1)
        }
        for f in c.bossFast where f.duration > 0 {
            let df = damage(f.power, c.bossAttack, defense, multiplier(f))
            for ch in c.bossCharged where ch.duration > 0 {
                let dc = damage(ch.power, c.bossAttack, defense, multiplier(ch))
                let fastMoves = f.energy > 0 ? (ch.energy / f.energy).rounded(.up) : 0
                let cycle = fastMoves * (f.duration + 2) + ch.duration + 2
                total += (fastMoves * df + dc) / cycle
                n += 1
            }
        }
        return n > 0 ? total / n : 0
    }

    /// Win chance for N players who each bring a party like this one. Each player's damage in the time limit
    /// (after a wipe they lose about 15 s rejoining) against the boss's HP; the uncertainty (dodging, players'
    /// skill, the boss's actual moves) makes a soft edge around "just enough".
    private func chance(_ party: [RaidCounter], players: Int, bossHP: Double, seconds: Double) -> Int {
        guard !party.isEmpty else { return 0 }
        let damage = party.map(\.tdo).reduce(0, +)
        let wipe = party.map(\.alive).reduce(0, +) + Double(party.count - 1)
        let time = seconds - 3
        let perSecond = damage / (wipe + (wipe < time ? 15 : 0))
        let x = Double(players) * perSecond * time / bossHP
        let p = 100 / (1 + exp(-6 * (x - 1)))
        return Int(min(99, max(1, p.rounded())))
    }
}

// MARK: - PvP

enum PvPLeague: String, CaseIterable, Identifiable {
    case great, ultra, master

    var id: String { rawValue }
    var cap: Int? { self == .great ? 1500 : self == .ultra ? 2500 : nil }
    var name: String { self == .great ? "Great League" : self == .ultra ? "Ultra League" : "Master League" }
    var limit: String { cap.map { $0.formatted(.number.locale(L10n.locale)) } ?? tr("bez limitu", "no limit") }
}

enum PvPRole {
    case lead, switcher, closer

    var title: String { self == .lead ? "Lead" : self == .switcher ? "Switch" : "Closer" }
    var hint: String {
        switch self {
        case .lead: tr("začíná", "starts")
        case .switcher: tr("střídá", "switches in")
        case .closer: tr("dokončuje", "finishes")
        }
    }
    var symbol: String { self == .lead ? "flag" : self == .switcher ? "arrow.left.arrow.right" : "flag.checkered" }
}

/// A Pokémon from the storage as a candidate for a league: the form it plays as and the level to power it to.
struct PvPMember: Identifiable {
    let mon: InventoryStats.Mon
    let form: String
    let formName: String
    let ranking: GameData.Ranking
    let rank: Int                // IV rank among the 4,096 combinations for the league (1 = best)
    let level: Double            // the highest level that stays under the CP limit (50 without a limit)
    let cp: Int                  // CP at that level
    let value: Double            // PvPoke score weighted by the IV stat product
    let statProduct: Double      // its stat product as a share of the best IVs' (0–1)
    var role = PvPRole.lead
    var wins: [String] = []      // most played opponents it clearly beats
    var losses: [String] = []    // … and clearly loses to
    var even = 0                 // … and too close to call

    var id: String { form }
    var evolves: Bool { form != mon.sid }
    var powerUp: Bool { level > (mon.level ?? level) + 0.01 }
}

/// One team of 3 and how it does against the league's most played Pokémon (ids, most played first).
struct PvPTeam: Identifiable {
    /// One of the league's most played Pokémon and how each team member does against it.
    struct Threat: Identifiable {
        let opponent: String          // PvPoke id
        let cells: [Int]              // per member: 1 win, 0 close, −1 loss
        var covered: Bool { cells.contains(1) }
        var id: String { opponent }
    }

    let members: [PvPMember]      // lead, switch, closer
    let answered: Int             // opponents at least one member clearly beats
    let faced: Int                // the meta without the team's own species (a mirror is nobody's win)
    let strong: [String]          // opponents at least two members beat
    let weak: [String]            // opponents nobody beats, then those that beat at least two members
    let threats: [Threat]         // the most played, most played first
    /// A candidate outside the team, with the team's gaps it would beat.
    struct Bench: Identifiable {
        let member: PvPMember
        let beats: [String]       // names, at most two
        var id: String { member.id }
    }

    /// The next best candidates outside the team.
    var bench: [Bench] = []

    var id: String { members.map(\.form).sorted().joined(separator: "+") }
    var gaps: [String] { threats.filter { !$0.covered }.map(\.opponent) }
    /// The average PvPoke score of the members, shown on the combo cards.
    var score: Int { members.isEmpty ? 0 : Int((members.map(\.ranking.score).reduce(0, +) / Double(members.count)).rounded()) }
}

/// The teams for a league. No team beats everything, so there are several, each with different holes.
struct PvPResult {
    let league: PvPLeague
    let teams: [PvPTeam]          // the widest coverage first; one partial team when fewer than 3 Pokémon fit
    let meta: [String]            // the league's most played species, in PvPoke's order
    let candidates: Int           // Pokémon from the storage that fit the league
}

/// Builds teams of 3 for a league and compares each with the league's 30 most played species (the top of the
/// PvPoke ranking). Each member gets a matchup from −1 to 1 against each opponent (PvPoke's simulated matchups
/// first, otherwise the move types and the species' strength). A good team has an answer to almost everything;
/// teams differ in their weak spots: opponents with no answer and opponents that beat two of the three.
/// An estimate, not a battle simulation.
struct PvPCalc {
    static let metaSize = 30
    /// How many of the most played fit in the team's coverage table.
    static let threatRows = 10

    let data: GameData
    private let battle: GameData.Battle
    private let types: TypeMath
    private let levels: [(level: Double, cpm: Double)]

    init(data: GameData) {
        self.data = data
        battle = data.battle!
        types = TypeMath(data.battle!)
        levels = stride(from: 1.0, through: 50.0, by: 0.5).map { ($0, data.cpm(at: $0)) }
    }

    func result(_ league: PvPLeague, mons: [InventoryStats.Mon]) -> PvPResult {
        guard let rankings = battle.leagues[league.rawValue] else { return PvPResult(league: league, teams: [], meta: [], candidates: 0) }
        let pool = candidates(league, rankings, mons)
        let meta = metaList(rankings)
        let top = Array(pool.prefix(24))
        var rows: [String: [Double]] = [:]           // matchups against the meta, in its order
        for c in top { rows[c.form] = meta.map { matchup(c, $0, rankings) } }
        guard top.count >= 3 else {
            let teams = top.isEmpty ? [] : [team(top, meta, rows)]
            return PvPResult(league: league, teams: teams, meta: meta, candidates: pool.count)
        }

        // a team around each of the 8 strongest: the next two raise the team's answers to the meta the most
        var built: [(team: PvPTeam, score: Double)] = []
        for anchor in top.prefix(8) {
            var members = [anchor]
            for _ in 0..<2 {
                let options = top.filter { c in !members.contains { base($0.form) == base(c.form) } }
                guard let pick = options.max(by: { score(members + [$0], rows) < score(members + [$1], rows) }) else { break }
                members.append(pick)
            }
            built.append((team(members, meta, rows), score(members, rows)))
        }
        built.sort { $0.score > $1.score }
        // different teams, not the same two with another third: first those sharing at most one member
        var chosen: [PvPTeam] = []
        for limit in [1, 2] {
            for (t, _) in built where chosen.count < 4 && !chosen.contains(where: { $0.id == t.id })
                && chosen.allSatisfy({ shared($0, t) <= limit }) {
                chosen.append(t)
            }
            if chosen.count >= 3 { break }
        }
        return PvPResult(league: league, teams: chosen.map { bench($0, top, rows, meta) }, meta: meta, candidates: pool.count)
    }

    /// The three best candidates outside the team, with the team's own gaps each of them would beat.
    private func bench(_ team: PvPTeam, _ pool: [PvPMember], _ rows: [String: [Double]], _ meta: [String]) -> PvPTeam {
        var team = team
        let inTeam = Set(team.members.map { base($0.form) })
        let gaps = team.threats.filter { !$0.covered }.map(\.opponent)
        team.bench = pool.filter { !inTeam.contains(base($0.form)) }.prefix(3).map { c in
            let beats = gaps.filter { o in meta.firstIndex(of: o).map { (rows[c.form]?[$0] ?? 0) >= 0.5 } ?? false }
            return PvPTeam.Bench(member: c, beats: beats.prefix(2).map(name))
        }
        return team
    }

    func name(_ id: String) -> String { battle.pokemon[id]?.name ?? id }

    /// Every Pokémon from the storage that fits the league, as the form it plays as, the best one of each form.
    private func candidates(_ league: PvPLeague, _ rankings: [String: GameData.Ranking], _ mons: [InventoryStats.Mon]) -> [PvPMember] {
        var products: [String: (sorted: [Double], best: Double)] = [:]
        var best: [String: PvPMember] = [:]
        for mon in mons {
            guard let sid = mon.sid, let level = mon.level, mon.iv.count == 3 else { continue }
            for id in data.finalForms(sid) {
                guard let ranking = rankings[id], let form = battle.pokemon[id], form.stats.count == 3,
                      let (target, product) = fit(form.stats, mon.iv, from: level, cap: league.cap) else { continue }
                if products[id] == nil { products[id] = productTable(form.stats, cap: league.cap) }
                guard let table = products[id], table.best > 0 else { continue }
                let rank = 1 + higher(than: product, in: table.sorted)
                let member = PvPMember(mon: mon, form: id, formName: form.name, ranking: ranking, rank: rank, level: target,
                                       cp: cp(form.stats, mon.iv, levelCPM(target)), value: ranking.score * product / table.best,
                                       statProduct: product / table.best)
                if best[id].map({ member.value > $0.value }) ?? true { best[id] = member }
            }
        }
        return best.values.sorted { $0.value > $1.value }
    }

    /// The league's most played species: the top of the PvPoke ranking, shadow and normal forms as one.
    private func metaList(_ rankings: [String: GameData.Ranking]) -> [String] {
        var out: [String] = []
        for (id, _) in rankings.sorted(by: { $0.value.score > $1.value.score }) {
            let b = base(id)
            if !out.contains(b), battle.pokemon[b] != nil { out.append(b) }
            if out.count == Self.metaSize { break }
        }
        return out
    }

    /// The team's best answer to each meta opponent (a mirror match counts as nobody's win).
    private func best(_ members: [PvPMember], _ rows: [String: [Double]], _ i: Int) -> Double {
        members.map { rows[$0.form]?[i] ?? 0 }.max() ?? 0
    }

    private func count(_ members: [PvPMember], _ rows: [String: [Double]], _ i: Int, _ test: (Double) -> Bool) -> Int {
        members.filter { test(rows[$0.form]?[i] ?? 0) }.count
    }

    /// How well a team answers the meta: the best member's matchup against each opponent, minus a penalty for
    /// opponents that beat two or more members (a shared weakness); the most played count more. Plus a little
    /// for the members' own strength.
    private func score(_ members: [PvPMember], _ rows: [String: [Double]]) -> Double {
        let n = rows.values.first?.count ?? 0
        let answers = (0..<n).reduce(0.0) { sum, i in
            let weight = 1 - Double(i) / Double(2 * max(n, 1))
            let shared = count(members, rows, i) { $0 <= -0.5 } >= 2 ? 0.6 : 0
            return sum + (best(members, rows, i) - shared) * weight
        }
        return answers + members.map(\.value).reduce(0, +) / 100
    }

    private func team(_ members: [PvPMember], _ meta: [String], _ rows: [String: [Double]]) -> PvPTeam {
        let own = Set(members.map { base($0.form) })
        var answered = 0, faced = 0
        var strong: [String] = [], unanswered: [String] = [], shared: [String] = []
        for (i, o) in meta.enumerated() where !own.contains(o) {
            faced += 1
            let b = best(members, rows, i)
            if b >= 0.5 { answered += 1 } else { unanswered.append(o) }
            if count(members, rows, i, { $0 >= 0.5 }) >= 2 { strong.append(o) }
            if b >= 0.5 && count(members, rows, i, { $0 <= -0.5 }) >= 2 { shared.append(o) }
        }
        let ordered = roles(members)
        let detailed = ordered.map { m -> PvPMember in
            var m = m
            for (i, o) in meta.enumerated() where o != base(m.form) {
                let r = rows[m.form]?[i] ?? 0
                if r >= 0.5 { m.wins.append(o) } else if r <= -0.5 { m.losses.append(o) } else { m.even += 1 }
            }
            return m
        }
        let threats = meta.enumerated().filter { !own.contains($0.element) }.prefix(Self.threatRows).map { i, o in
            PvPTeam.Threat(opponent: o, cells: ordered.map { m in
                let r = rows[m.form]?[i] ?? 0
                return r >= 0.5 ? 1 : r <= -0.5 ? -1 : 0
            })
        }
        return PvPTeam(members: detailed, answered: answered, faced: faced, strong: strong, weak: unanswered + shared,
                       threats: Array(threats))
    }

    private func shared(_ a: PvPTeam, _ b: PvPTeam) -> Int {
        Set(a.members.map(\.form)).intersection(b.members.map(\.form)).count
    }

    private func base(_ id: String) -> String { id.replacingOccurrences(of: "_shadow", with: "") }

    /// −1 … 1, how the member does against the opponent. PvPoke's simulated matchups decide when they list the
    /// pair (each species lists the 5 it beats and the 5 it loses to). Otherwise a weaker guess: how hard the
    /// member's moves hit the opponent against how hard the opponent's moves hit back, and the two species'
    /// PvPoke scores.
    private func matchup(_ m: PvPMember, _ opp: String, _ rankings: [String: GameData.Ranking]) -> Double {
        let me = base(m.form)
        if me == opp { return 0 }
        if m.ranking.beats.contains(where: { base($0) == opp }) { return 1 }
        if m.ranking.loses.contains(where: { base($0) == opp }) { return -1 }
        let theirs = rankings[opp] ?? rankings[opp + "_shadow"]
        if theirs?.loses.contains(where: { base($0) == me }) ?? false { return 1 }
        if theirs?.beats.contains(where: { base($0) == me }) ?? false { return -1 }
        guard let mine = battle.pokemon[m.form]?.types, let their = battle.pokemon[opp]?.types else { return 0 }
        let attack = m.ranking.moveset.compactMap { battle.moves[$0]?.type }.map { types.eff($0, their) }.max() ?? 1
        let defense = (theirs?.moveset ?? []).compactMap { battle.moves[$0]?.type }.map { types.eff($0, mine) }.max() ?? 1
        let typing = max(-1, min(1, log(attack / defense) / log(1.6)))
        let strength = max(-0.3, min(0.3, (m.ranking.score - (theirs?.score ?? m.ranking.score)) / 50))
        return max(-1, min(1, 0.6 * typing + strength))
    }

    /// The roles by the PvPoke role scores: the best lead starts, the best closer finishes, the third switches.
    private func roles(_ team: [PvPMember]) -> [PvPMember] {
        var rest = team
        func score(_ m: PvPMember, _ i: Int) -> Double { i < m.ranking.roles.count ? m.ranking.roles[i] : 0 }
        guard let li = rest.indices.max(by: { score(rest[$0], 0) < score(rest[$1], 0) }) else { return [] }
        var lead = rest.remove(at: li)
        lead.role = .lead
        guard !rest.isEmpty else { return [lead] }
        if rest.count == 1 {
            var other = rest[0]
            other.role = score(other, 1) >= score(other, 2) ? .closer : .switcher
            return [lead, other]
        }
        let ci = rest.indices.max { score(rest[$0], 1) < score(rest[$1], 1) } ?? 0
        var closer = rest.remove(at: ci)
        closer.role = .closer
        var switcher = rest[0]
        switcher.role = .switcher
        return [lead, switcher, closer]
    }

    // MARK: Stat product

    private func levelCPM(_ level: Double) -> Double { data.cpm(at: level) }

    private func cp(_ st: [Int], _ iv: [Int], _ m: Double) -> Int {
        let a = Double(st[0] + iv[0]), d = Double(st[1] + iv[1]), h = Double(st[2] + iv[2])
        return max(10, Int((a * d.squareRoot() * h.squareRoot() * m * m / 10).rounded(.down)))
    }

    private func product(_ st: [Int], _ iv: [Int], _ m: Double) -> Double {
        (Double(st[0] + iv[0]) * m) * (Double(st[1] + iv[1]) * m) * (Double(st[2] + iv[2]) * m).rounded(.down)
    }

    /// The highest level from `from` up to 50 that stays under the cap, and the stat product there; nil when the
    /// Pokémon is already over the cap (CP can't go down).
    private func fit(_ st: [Int], _ iv: [Int], from: Double, cap: Int?) -> (Double, Double)? {
        let start = levels.firstIndex { $0.level >= from - 0.01 } ?? (levels.count - 1)
        guard let cap else {
            let top = levels[levels.count - 1]
            let lvl = max(top.level, from)
            let m = lvl > top.level ? levelCPM(lvl) : top.cpm
            return (lvl, product(st, iv, m))
        }
        guard cp(st, iv, levels[start].cpm) <= cap else { return nil }
        var lo = start, hi = levels.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cp(st, iv, levels[mid].cpm) <= cap { lo = mid } else { hi = mid - 1 }
        }
        return (levels[lo].level, product(st, iv, levels[lo].cpm))
    }

    /// Stat products of all 4,096 IV combinations at their best level, sorted from the highest.
    private func productTable(_ st: [Int], cap: Int?) -> (sorted: [Double], best: Double) {
        var all: [Double] = []
        all.reserveCapacity(4096)
        for a in 0...15 {
            for d in 0...15 {
                for s in 0...15 {
                    if let (_, p) = fit(st, [a, d, s], from: 1, cap: cap) { all.append(p) }
                }
            }
        }
        all.sort(by: >)
        return (all, all.first ?? 0)
    }

    private func higher(than value: Double, in sorted: [Double]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] > value + 1e-9 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
