import Foundation

// PvP: scoring a Pokémon for a league from the PvPoke rankings, and building a team out of the storage.

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
