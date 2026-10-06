import Foundation

// Raids: how much damage a move does against a boss, and which of your Pokémon fight it best.

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
func damage(_ power: Double, _ attack: Double, _ defense: Double, _ multiplier: Double) -> Double {
    (0.5 * power * attack / defense * multiplier).rounded(.down) + 1
}

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
