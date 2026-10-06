import AppKit
import SwiftUI

// What the Stats screen can show: every chart and list it offers, and how each one is computed.

/// Everything the window shows for one click: title, the in-game search, the Pokémon and how to sort them.
struct StatsSheetDef {
    var icon: String
    var crumb: String
    var title: String
    var sub: String
    var search: String?
    var note: String?
    var items: [InventoryStats.Mon] = []
    var sorts: [StatsSort] = [.iv, .cp, .name]
    var sort: StatsSort = .iv
    var rankLeague: String?      // "best" or a league key: the list shows ranks and sorts by them
    var bestId: Int?             // all copies of a species: the best one
    var perSpecies = false       // one Pokémon per species (the footer counts species)
    var strip: [(String, String)] = []
    var coverage = false

    static let leagueShort = ["great": "Great", "ultra": "Ultra", "master": "Master"]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @MainActor static func make(_ sheet: StatsSheet, _ s: InventoryStats, _ config: AppConfig) -> StatsSheetDef {
        let mons = s.mons
        let pokemon = { (n: Int) in trCount(n, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon") }
        let crown = tr("Hvězdy ve hře mají jiné hranice.", "The stars in the game have other limits.")
        // the stats can reload while the window is open (after a run, after deleting the results)
        let gone = StatsSheetDef(icon: "chart.bar", crumb: "", title: tr("Už tu nic není", "Nothing here any more"), sub: "")
        switch sheet {
        case .ivBin(let i) where !s.ivBins.indices.contains(i), .level(let i) where !s.levels.indices.contains(i),
             .region(let i) where !InventoryStats.regions.indices.contains(i):
            return gone
        case .run(let id) where !s.runs.contains(where: { $0.id == id }):
            return gone
        default: break
        }
        switch sheet {
        case .coverage:
            return StatsSheetDef(icon: "cylinder.split.1x2", crumb: tr("Pokrytí", "Coverage"),
                                 title: tr("Z čeho čísla jsou", "What the numbers come from"),
                                 sub: tr("\(pokemon(s.total)) s IV · \(s.withSpecies) i s druhem",
                                         "\(pokemon(s.total)) with IVs · \(s.withSpecies) with the species too"),
                                 coverage: true)
        case .dex:
            return StatsSheetDef(icon: "books.vertical", crumb: "Pokédex", title: "Pokédex",
                                 sub: tr("\(s.dexOwned) druhů z \(s.dexTotal)", "\(s.dexOwned) of \(s.dexTotal) species"),
                                 note: tr("Nejlepší kus každého druhu.", "The best Pokémon of each species."),
                                 items: bestPerSpecies(mons.filter { $0.dex != nil }), perSpecies: true)
        case .region(let i):
            let region = InventoryStats.regions[i]
            return StatsSheetDef(icon: "map", crumb: "Pokédex", title: region,
                                 sub: tr("\(s.generations[i]) druhů z \(s.generationTotals[i]) · \(i + 1). generace",
                                         "\(s.generations[i]) of \(s.generationTotals[i]) species · generation \(i + 1)"),
                                 search: region.lowercased(),
                                 note: tr("Nejlepší kus každého druhu.", "The best Pokémon of each species."),
                                 items: bestPerSpecies(mons.filter { $0.gen == i + 1 }), perSpecies: true)
        case .iv:
            return StatsSheetDef(icon: "chart.bar.xaxis", crumb: tr("Rozložení IV", "IV spread"),
                                 title: tr("Všechny kusy podle IV", "Every Pokémon by IV"),
                                 sub: tr("\(pokemon(s.total)) · průměr \(percentText(s.ivAverage))",
                                         "\(pokemon(s.total)) · average \(percentText(s.ivAverage))"),
                                 items: mons)
        case .ivBin(let i):
            let bin = s.ivBins[i]
            return StatsSheetDef(icon: "chart.bar.xaxis", crumb: tr("Rozložení IV", "IV spread"),
                                 title: "IV " + ivBinLabel(bin.lower),
                                 sub: tr("\(pokemon(bin.count)) · \(percentText(share(bin.count, s.total))) všech",
                                         "\(pokemon(bin.count)) · \(percentText(share(bin.count, s.total))) of all"),
                                 search: ["3*,4*", "3*", "2*", "0*,1*,2*"][i], note: crown,
                                 items: mons.filter { $0.pct >= bin.lower && $0.pct < bin.upper })
        case .hundo:
            return StatsSheetDef(icon: "crown.fill", crumb: "Hundo", title: "Hundo 15/15/15", sub: pokemon(s.hundos.count),
                                 search: "4*", items: s.hundos, sort: .cp)
        case .nearPerfect:
            return StatsSheetDef(icon: "crown.fill", crumb: "Hundo", title: tr("98 % a víc", "98% or more"),
                                 sub: pokemon(s.nearPerfect), search: "4*,3*",
                                 note: tr("3★ zahrnuje kusy už od 82 %.", "3★ includes Pokémon from 82%."),
                                 items: mons.filter { $0.pct >= 98 })
        case .pvp:
            let firsts = mons.filter { $0.bestRank?.rank == 1 }.count
            return StatsSheetDef(icon: "trophy", crumb: tr("Síň slávy PvP", "PvP hall of fame"),
                                 title: tr("Všechny kusy s pořadím", "Every Pokémon with a rank"),
                                 sub: tr("\(pokemon(s.ranked)) · \(firsts) s pořadím 1", "\(pokemon(s.ranked)) · \(firsts) at rank 1"),
                                 search: config.pvp.all.map { "#" + $0.league.name }.joined(separator: ","),
                                 note: tr("Podle nejlepšího pořadí v kterékoli lize.", "By the best rank in any league."),
                                 items: mons.filter { !$0.ranks.isEmpty }, sorts: [.rank, .iv, .cp], sort: .rank, rankLeague: "best")
        case .league(let key):
            let league = config.pvp.all.first { $0.key == key }?.league ?? config.pvp.great
            let tagged = mons.filter { $0.tags.contains(league.name) }.count
            return StatsSheetDef(icon: "trophy", crumb: tr("Síň slávy PvP", "PvP hall of fame"), title: league.name,
                                 sub: (PvPConfig.caps[key] ?? "") + " · " + tr("\(pokemon(tagged)) s tagem", "\(pokemon(tagged)) tagged"),
                                 search: "#" + league.name,
                                 items: mons.filter { $0.ranks[key] != nil }, sorts: [.rank, .iv, .cp], sort: .rank, rankLeague: key)
        case .strong:
            let limit = mons.contains { $0.cp >= 3000 } ? 3000 : 2000
            let top = s.topCP.map { "\($0.name) \(number($0.cp)) CP" } ?? ""
            return StatsSheetDef(icon: "bolt", crumb: tr("Nejsilnější", "Strongest"),
                                 title: tr("Nad \(number(limit)) CP", "Over \(number(limit)) CP"),
                                 sub: tr("nejvyšší ", "highest ") + top, search: "cp\(limit)-",
                                 items: mons.filter { $0.cp >= limit }, sort: .cp)
        case .rare(let kind):
            let (title, search, items): (String, String, [InventoryStats.Mon]) = {
                switch kind {
                case "ultrabeast": return ("Ultra beasts", "ultra beasts", mons.filter(\.ultraBeast))
                case "mythical": return (tr("Mýtičtí", "Mythical"), "mythical", mons.filter(\.mythical))
                default: return (tr("Legendy", "Legendary"), "legendary", mons.filter(\.legendary))
                }
            }()
            return StatsSheetDef(icon: "sparkles", crumb: tr("Vzácné", "Rare"), title: title, sub: pokemon(items.count),
                                 search: search, items: items)
        case .evolve:
            return StatsSheetDef(icon: "arrowshape.up", crumb: tr("Ještě vyvinout", "Still to evolve"),
                                 title: tr("Má další evoluci", "Has a further evolution"), sub: pokemon(s.canEvolve),
                                 search: "evolve", items: mons.filter(\.canEvolve))
        case .duplicates:
            return StatsSheetDef(icon: "square.on.square", crumb: tr("Duplicity", "Duplicates"),
                                 title: tr("Kusy s tagem \(s.removeTag)", "Pokémon tagged \(s.removeTag)"),
                                 sub: tr("\(s.duplicateSpecies) druhů má víc kusů", "\(s.duplicateSpecies) species have more than one"),
                                 search: "#" + s.removeTag,
                                 note: tr("Každý má lepší kopii stejného druhu.", "Each has a better copy of the same species."),
                                 items: mons.filter { $0.tags.contains(s.removeTag) })
        case .type(let type):
            let items = mons.filter { $0.types.contains(type) }
            return StatsSheetDef(icon: "drop", crumb: tr("Typy", "Types"), title: type.capitalized, sub: pokemon(items.count),
                                 search: type, items: items)
        case .species(let name):
            let items = mons.filter { $0.species == name }
            let best = items.max { ($0.pct, $0.cp) < ($1.pct, $1.cp) }
            let tagged = items.contains { $0.tags.contains(s.removeTag) }
            return StatsSheetDef(icon: "list.number", crumb: tr("Nejčastější druh", "Most common species"), title: name,
                                 sub: tr("\(items.count)× v inventáři", "\(items.count)× in the storage"),
                                 search: name.lowercased(),
                                 note: tagged ? tr("Nejlepší nahoře, ostatní kopie mají tag \(s.removeTag).",
                                                   "The best on top, the other copies are tagged \(s.removeTag).")
                                              : tr("Nejlepší nahoře.", "The best on top."),
                                 items: items, bestId: best?.id)
        case .level(let i):
            let bin = s.levels[i]
            return StatsSheetDef(icon: "stairs", crumb: tr("Úrovně", "Levels"),
                                 title: tr("Úroveň \(bin.label)", "Level \(bin.label)"), sub: pokemon(bin.count),
                                 note: tr("Podle úrovně ve hře vyhledávat nejde.", "The game can't search by level."),
                                 items: mons.filter { ($0.level ?? -1) >= bin.lower && ($0.level ?? -1) < bin.upper },
                                 sorts: [.level, .iv, .cp], sort: .level)
        case .tag(let name):
            let items = mons.filter { $0.tags.contains(name) }
            return StatsSheetDef(icon: "tag", crumb: tr("Tagy ve hře", "Tags in the game"), title: name, sub: pokemon(items.count),
                                 search: "#" + name, items: items)
        case .run(let id):
            let i = s.runs.firstIndex { $0.id == id }!     // checked above
            let run = s.runs[i]
            let read = s.firstRead(in: run)
            return StatsSheetDef(icon: "clock.arrow.circlepath", crumb: tr("Historie běhů", "Run history"),
                                 title: tr("Běh \(i + 1)", "Run \(i + 1)"), sub: RunText.when(run.date),
                                 note: tr("Kusy, které tento běh přečetl poprvé.", "The Pokémon this run read for the first time."),
                                 items: read,
                                 strip: [(tr("Trvání", "Duration"), RunText.duration(run.duration)),
                                         (tr("Prošlo", "Checked"), run.checked.map { number($0) } ?? "–"),
                                         (tr("Nově přečteno", "Read for the first time"), number(read.count)),
                                         (tr("Vyřešené chyby", "Recovered errors"), number(run.errors))])
        }
    }

    private static func bestPerSpecies(_ mons: [InventoryStats.Mon]) -> [InventoryStats.Mon] {
        Dictionary(grouping: mons, by: \.name).values.compactMap { $0.max { ($0.pct, $0.cp) < ($1.pct, $1.cp) } }
    }

    func sorted(_ by: StatsSort) -> [InventoryStats.Mon] {
        let rank = { (m: InventoryStats.Mon) -> Int in
            (rankLeague == "best" ? m.bestRank?.rank : rankLeague.flatMap { m.ranks[$0] }) ?? 9999
        }
        return items.sorted { a, b in
            switch by {
            case .iv: return a.pct != b.pct ? a.pct > b.pct : a.cp > b.cp
            case .cp: return a.cp != b.cp ? a.cp > b.cp : a.pct > b.pct
            case .name: return a.name.localizedCompare(b.name) == .orderedAscending
            case .rank: return rank(a) != rank(b) ? rank(a) < rank(b) : a.pct > b.pct
            case .level: return (a.level ?? 0) != (b.level ?? 0) ? (a.level ?? 0) > (b.level ?? 0) : a.pct > b.pct
            }
        }
    }
}

enum StatsSort: String {
    case iv, cp, name, rank, level

    var title: String {
        switch self {
        case .iv: return "IV"
        case .cp: return "CP"
        case .name: return tr("Název", "Name")
        case .rank: return tr("Pořadí", "Rank")
        case .level: return tr("Úroveň", "Level")
        }
    }
}

func share(_ part: Int, _ whole: Int) -> Int {
    whole > 0 ? Int((Double(part) / Double(whole) * 100).rounded()) : 0
}

/// A number with thousands separated the way the app language writes them ("3 905" / "3,905").
func number(_ n: Int) -> String { n.formatted(.number.locale(L10n.locale)) }

/// "90–100 %", "80–89 %", "pod 70 %".
func ivBinLabel(_ lower: Int) -> String {
    switch lower {
    case 90: return pctRange(90, 100)
    case 0: return tr("pod 70 %", "under 70%")
    default: return pctRange(lower, lower + 9)
    }
}
