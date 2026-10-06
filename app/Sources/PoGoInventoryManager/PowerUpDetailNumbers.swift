import SwiftUI

// The numbers behind the power-up detail: the levels, the price, what it gains and why it is worth it.

extension PowerUpDetail {
    var isPvP: Bool { if case .pvp = pick { return true }; return false }

    var mon: InventoryStats.Mon {
        switch pick {
        case .pvp(_, let m): return m.mon
        case .raid(let u): return u.counter.mon
        }
    }

    var glow: Color {
        switch pick {
        case .pvp(let league, _): return leagueColor(league).opacity(0.45)
        case .raid(let u): return BattleType.color(u.type).opacity(0.45)
        }
    }

    var chips: [(String, Color)] {
        switch pick {
        case .pvp(let league, let m):
            var out: [(String, Color)] = [(league.name, leagueColor(league))]
            out.append((tr("pořadí #\(number(m.rank))", "rank #\(number(m.rank))"), Theme.accent))
            if m.evolves { out.append((m.formName, Theme.green)) }
            return out
        case .raid(let u):
            var out: [(String, Color)] = [(BattleType.name(u.type), BattleType.color(u.type))]
            if let to = u.counter.evolveTo { out.append((to, Theme.green)) }
            return out
        }
    }

    var price: GameData.Price {
        switch pick {
        case .pvp(_, let m): return battle.price(m)
        case .raid(let u): return u.price
        }
    }

    var fromLevel: Double? {
        switch pick {
        case .pvp(_, let m): return m.mon.level
        case .raid(let u): return u.counter.mon.level
        }
    }

    var toLevel: Double? {
        switch pick {
        case .pvp(_, let m): return m.level
        case .raid: return 40
        }
    }

    var steps: String {
        guard let from = fromLevel, let to = toLevel, to > from else { return "" }
        let n = Int(((to - from) * 2).rounded())
        return trCount(n, cs: "vylepšení", "vylepšení", "vylepšení", en: "power-up", "power-ups")
    }

    var why: String {
        switch pick {
        case .pvp(let league, let m):
            guard let cap = league.cap else {
                return tr("Je v tvém týmu pro \(league.name), kde CP nic neomezuje – každá úroveň navíc se počítá.",
                          "It's in your \(league.name) team, where nothing caps the CP – every level helps.")
            }
            return tr("Je v tvém týmu pro \(league.name) a dostane se na \(number(m.cp)) z limitu \(number(cap)) CP.",
                      "It's in your \(league.name) team and gets to \(number(m.cp)) of the \(number(cap)) CP limit.")
        case .raid(let u):
            let gain = Int((u.gain * 100).rounded())
            return tr("Dá o \(gain) % víc damage jako \(BattleType.name(u.type)) útočník, takže posune celou partu.",
                      "It does \(gain)% more damage as a \(BattleType.name(u.type)) attacker, which lifts the whole party.")
        }
    }

    var changes: [Change] {
        switch pick {
        case .pvp(let league, let m):
            var out = [Change(label: tr("Úroveň", "Level"), before: "L\(levelText(m.mon.level))",
                              after: "L\(levelText(m.level))", good: true),
                       Change(label: "CP", before: number(m.mon.cp), after: number(m.cp), good: true)]
            if let cap = league.cap {
                out.append(Change(label: tr("Z limitu ligy", "Of the league cap"),
                                  before: percentText(Int(Double(m.mon.cp) / Double(cap) * 100)),
                                  after: percentText(Int(Double(m.cp) / Double(cap) * 100)), good: true))
            }
            out.append(Change(label: tr("Součin statů", "Stat product"),
                              before: percentText(Int(m.statProduct * 100)),
                              after: percentText(Int(m.statProduct * 100)), good: false))
            return out
        case .raid(let u):
            var out = [Change(label: tr("Úroveň", "Level"), before: "L\(levelText(u.counter.mon.level))",
                              after: "L40", good: true)]
            if let after = u.counter.strength40 {
                out.append(Change(label: tr("Síla", "Strength"), before: String(format: "%.0f", u.counter.strength),
                                  after: String(format: "%.0f", after), good: true))
            }
            out.append(Change(label: tr("Damage za vteřinu", "Damage per second"),
                              before: String(format: "%.1f", u.counter.dps),
                              after: String(format: "%.1f", u.counter.dps * (1 + u.gain)), good: true))
            out.append(Change(label: tr("Místo mezi tvými útočníky", "Place among your attackers"),
                              before: u.rankNow.map { "#\($0)" } ?? tr("mimo", "outside"),
                              after: "#\(u.rankAfter)", good: true))
            return out
        }
    }

    var moves: [(String, Color)] {
        switch pick {
        case .pvp(_, let m):
            let names = BattleFormat.moves(m.ranking.moveset)
            let types = m.ranking.moveset.compactMap { battle.data?.battle?.moves[$0]?.type }
            return [(names.fast, types.first.map(BattleType.color) ?? Theme.muted),
                    (names.charged, types.count > 1 ? BattleType.color(types[1]) : Theme.muted)]
        case .raid(let u):
            return [(u.counter.fast.name, BattleType.color(u.counter.fast.type)),
                    (u.counter.charged.name, BattleType.color(u.counter.charged.type))]
        }
    }

    func teamMembers(_ league: PvPLeague) -> [PvPMember]? {
        guard let result = battle.teams[league] else { return nil }
        let team = battle.chosenTeam(result, store.config.battle.team(league)) ?? result.teams.first
        return team?.members
    }

    /// How much each boss that is up right now gains from this power-up.
    func bossGains(_ u: RaidUpgrade) -> [BossGain] {
        guard let data = battle.data?.battle else { return [] }
        let math = TypeMath(data)
        let hits = battle.bosses.filter { math.eff(u.type, $0.types) > 1 }
        guard !hits.isEmpty else { return [] }
        let best = hits.map { math.eff(u.type, $0.types) }.max() ?? 1
        return hits.prefix(5).map { boss in
            let eff = math.eff(u.type, boss.types)
            return BossGain(boss: boss, gain: u.gain * eff / best, share: eff / best,
                            place: tr("v šestici #\(u.rankAfter)", "#\(u.rankAfter) in the six"))
        }
    }

    func leagueColor(_ league: PvPLeague) -> Color {
        (store.config.pvp.all.first { $0.key == league.rawValue }?.league.color ?? .purple).swatch
    }
}
