import AppKit
import SwiftUI

/// What a click on the Stats screen opens: a card, a row or a column.
enum StatsSheet: Hashable {
    case coverage, dex, region(Int), iv, ivBin(Int), hundo, nearPerfect, pvp, league(String), strong
    case rare(String)            // legendary / ultrabeast / mythical
    case evolve, duplicates, type(String), species(String), level(Int), tag(String), run(String)
}

/// The window over the Stats screen: which one is open, the selected Pokémon, the sorting, and the toast
/// after copying.
@MainActor
final class StatsSheetModel: ObservableObject {
    static let shared = StatsSheetModel()
    @Published private(set) var sheet: StatsSheet?
    @Published var selected: Int?
    @Published var sort: StatsSort?
    @Published private(set) var toast: String?
    /// The Pokémon whose photo from the game is shown enlarged over the window.
    @Published var zoomed: InventoryStats.Mon?
    private var toastTask: Task<Void, Never>?

    func open(_ sheet: StatsSheet, select: Int? = nil) {
        self.sheet = sheet
        selected = select
        sort = nil
        zoomed = nil
    }

    func close() {
        sheet = nil
        zoomed = nil
    }

    /// Esc: the enlarged photo first, then the window.
    func back() {
        if zoomed != nil { zoomed = nil } else { close() }
    }

    func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(message)
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { toast = nil }
        }
    }

    /// Shows the Pokémon's photo from the game in Finder, otherwise the screenshot of its IV bars (the run folder
    /// where it was measured).
    func reveal(_ m: InventoryStats.Mon) {
        if MonImages.photo(m) != nil {
            NSWorkspace.shared.activateFileViewerSelecting([MonImages.photoURL(m)])
        } else if let url = InventoryStats.ivShot(of: m) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            show(tr("Snímek tohoto kusu ve Výsledcích už není", "This Pokémon's screenshot is no longer in the results"))
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

// MARK: - Shared bits

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

enum StatsColors {
    static let gold = Color.adaptive(dark: .oklch(0.8, 0.15, 85), light: .oklch(0.6, 0.13, 75))
    static let goldTint = Color.adaptive(dark: .oklch(0.34, 0.07, 85), light: .oklch(0.93, 0.06, 85))
    static let hundoGlow = Color.oklch(0.86, 0.15, 92)
    static let ink = Color.oklch(0.2, 0.01, 270)
    static let orange = Color.oklch(0.73, 0.16, 55)
    static let blue = Color.oklch(0.62, 0.15, 255)
    static let gray = Color.oklch(0.64, 0.01, 270)
    static let dim = Color.oklch(0.45, 0.01, 270)

    /// The color of an IV percentage: gold for a hundo, then orange, blue and gray.
    static func iv(_ pct: Int) -> Color {
        pct == 100 ? gold : pct >= 90 ? orange : pct >= 80 ? blue : pct >= 70 ? gray : Theme.muted
    }

    /// The bars of the IV card: 90–100, 80–89, 70–79, under 70.
    static func bin(_ lower: Int) -> Color {
        switch lower {
        case 90: return orange
        case 80: return blue
        case 70: return gray
        default: return dim
        }
    }
}

// MARK: - The window

/// Over the Stats screen: the dimmed screen, the window sliding down from the toolbar, and the toast.
/// Esc or a click outside closes it.
struct StatsSheetHost: View {
    let active: Bool
    var startRun: () -> Void
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var model = StatsSheetModel.shared
    @ObservedObject private var statsStore = StatsStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if active, let sheet = model.sheet, let stats = statsStore.stats, !stats.isEmpty {
                    Theme.bg.opacity(0.55)
                        .contentShape(Rectangle())
                        .onTapGesture { model.close() }
                        .transition(.opacity)
                    StatsSheetPanel(def: .make(sheet, stats, store.config), stats: stats, startRun: {
                        model.close()
                        startRun()
                    })
                    .frame(width: min(940, geo.size.width - 32), height: min(660, geo.size.height - 16))
                    .transition(.modifier(active: SlideFade(y: -24, opacity: 0), identity: SlideFade(y: 0, opacity: 1)))
                    if let m = model.zoomed, let img = MonImages.photo(m) {
                        PhotoZoom(m: m, image: img, height: geo.size.height - 56)
                            .transition(.opacity)
                    }
                    Button("") { model.back() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0).frame(width: 0, height: 0)
                }
                if let toast = model.toast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                        Text(toast).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 16).frame(height: 38)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
                    .transition(.modifier(active: SlideFade(y: 12, opacity: 0), identity: SlideFade(y: 0, opacity: 1)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: model.sheet)
        .animation(.easeOut(duration: 0.18), value: model.zoomed?.id)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .onChange(of: active) { _, on in if !on { model.close() } }
    }
}

private struct SlideFade: ViewModifier {
    let y: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(y: y).opacity(opacity) }
}

/// The window itself: header, the search for the game and the sorting, the list on the left, the selected
/// Pokémon on the right. For the coverage it explains where the numbers come from instead.
struct StatsSheetPanel: View {
    let def: StatsSheetDef
    let stats: InventoryStats
    var startRun: () -> Void
    /// False only for windowless snapshots: ImageRenderer draws a ScrollView empty.
    var scrolls = true
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var model = StatsSheetModel.shared

    private var sort: StatsSort { model.sort.flatMap { def.sorts.contains($0) ? $0 : nil } ?? def.sort }

    var body: some View {
        let list = def.sorted(sort)
        let selected = list.first { $0.id == model.selected } ?? list.first
        VStack(spacing: 0) {
            header
            if !def.strip.isEmpty { strip }
            if def.coverage {
                CoverageContent(stats: stats, startRun: startRun)
            } else {
                controls
                HStack(spacing: 0) {
                    Scrolling(on: scrolls) {
                        LazyVStack(spacing: 2) {
                            ForEach(list) { m in
                                MonRow(m: m, badge: badge(m), selected: m.id == selected?.id) { model.selected = m.id }
                            }
                            if list.isEmpty {
                                Text(tr("Mezi přečtenými kusy tu nic není.", "Nothing here among the Pokémon read."))
                                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 16)
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 340)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    Group {
                        if let selected {
                            Scrolling(on: scrolls) {
                                MonDetail(m: selected, def: def, stats: stats).padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
                            }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Theme.bg)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            footer(list.count)
        }
        .background(Theme.chrome)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .compositingGroup()      // one shadow for the window, not one under every box inside it
        .shadow(color: .black.opacity(0.45), radius: 34, y: 20)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            SoftIcon(symbol: def.icon, size: 36, radius: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Statistiky", "Stats") + " › " + def.crumb).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(def.title).font(.system(size: 19, weight: .medium)).tracking(-0.2).lineLimit(1)
            }
            Text(def.sub).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 3)
            Spacer(minLength: 8)
            CloseButton { model.close() }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 18))
    }

    private var strip: some View {
        HStack(spacing: 8) {
            ForEach(def.strip, id: \.0) { k, v in
                VStack(alignment: .leading, spacing: 0) {
                    Text(k).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text(v).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let search = def.search {
                Text(tr("Ve hře vyhledáš", "Search in the game")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize()
                HStack(spacing: 8) {
                    Text(search).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                    Button {
                        model.copy(search, message: tr("Zkopírováno „\(search)“ · vlož do vyhledávání ve hře",
                                                       "Copied “\(search)” · paste it into the search in the game"))
                    } label: {
                        Label(tr("Kopírovat", "Copy"), systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                }
                .padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
                .fixedSize()
            }
            if let note = def.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text(tr("Řadit", "Sort")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack(spacing: 2) {
                    ForEach(def.sorts, id: \.self) { key in
                        let on = key == sort
                        Button { model.sort = key } label: {
                            Text(key.title).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(on ? Theme.text : Theme.muted)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(color: on ? .black.opacity(0.25) : .clear, radius: 1, y: 1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))   // raise is the window color in light mode
            }
            .fixedSize()
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func footer(_ count: Int) -> some View {
        HStack(spacing: 12) {
            Group {
                if def.coverage {
                    Text(trCount(stats.runs.count, cs: "běh", "běhy", "běhů", en: "run", "runs")
                         + (stats.runs.last.map { " · " + tr("poslední ", "last ") + RunText.when($0.date) } ?? ""))
                } else if def.perSpecies {
                    Text(trCount(count, cs: "druh", "druhy", "druhů", en: "species", "species"))
                } else {
                    Text(trCount(count, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon"))
                }
            }
            .monospacedDigit()
            HStack(spacing: 4) {
                Text("esc").font(.system(size: 11)).padding(.horizontal, 5).frame(height: 17)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(tr("zavřít", "close"))
            }
            Spacer()
        }
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
        .padding(.horizontal, 20).frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// The small label next to the name in the list: the rank, the best of the species, a hundo, the removal tag.
    private func badge(_ m: InventoryStats.Mon) -> MonRow.Badge? {
        if def.rankLeague == "best", let best = m.bestRank {
            return .init(text: "#\(best.rank) " + (StatsSheetDef.leagueShort[best.league] ?? ""), fg: Theme.accentInk, bg: Theme.tint)
        }
        if let key = def.rankLeague, let r = m.ranks[key] { return .init(text: "#\(r)", fg: Theme.accentInk, bg: Theme.tint) }
        if m.id == def.bestId { return .init(text: tr("nejlepší", "best"), fg: Theme.green, bg: Theme.greenTint) }
        if m.pct == 100 {
            return .init(text: m.isNew ? tr("hundo · nový", "hundo · new") : "hundo", fg: StatsColors.gold, bg: StatsColors.goldTint)
        }
        if m.tags.contains(stats.removeTag) { return .init(text: stats.removeTag, fg: Theme.red, bg: Theme.redTint) }
        return nil
    }
}

/// A ScrollView, or (for snapshots) the content cut off at the bottom.
private struct Scrolling<Content: View>: View {
    let on: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if on {
            ScrollView { content }
        } else {
            GeometryReader { geo in content.frame(width: geo.size.width) }.clipped()
        }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.muted)
                .frame(width: 30, height: 30)
                .background(hovering ? Theme.raise : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("Zavřít (esc)", "Close (esc)"))
    }
}

/// A Pokémon in the list: type dot, name, label, IV %, region · level · CP and the IVs as three small bars.
private struct MonRow: View {
    struct Badge {
        let text: String
        let fg: Color
        let bg: Color
    }

    let m: InventoryStats.Mon
    let badge: Badge?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
            MonIcon(m: m, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(PokeType.color(m.types.first ?? "")).frame(width: 8, height: 8)
                    Text(m.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let badge {
                        Text(badge.text).font(.system(size: 10, weight: .bold)).foregroundStyle(badge.fg).lineLimit(1)
                            .padding(.horizontal, 6).frame(height: 17)
                            .background(badge.bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .fixedSize()
                    }
                    Spacer(minLength: 6)
                    Text(percentText(m.pct)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                HStack(spacing: 10) {
                    Text(MonDetail.meta(m)).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(Theme.track).frame(width: 14, height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(StatsColors.iv(m.pct)).frame(width: 14 * CGFloat(m.iv[i]) / 15)
                                }
                        }
                    }
                }
            }
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 7)
            .background(selected ? Theme.tint : (hovering ? Theme.raise : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The selected Pokémon: species, type and region, IVs, CP and level, PvP ranks, tags, notes.
private struct MonDetail: View {
    let m: InventoryStats.Mon
    let def: StatsSheetDef
    let stats: InventoryStats
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var model = StatsSheetModel.shared

    /// "Kanto · L40 · 3 792 CP"
    static func meta(_ m: InventoryStats.Mon) -> String {
        var parts: [String] = []
        if let g = m.gen { parts.append(InventoryStats.regions[g - 1]) }
        if let l = m.levelText { parts.append("L" + l) }
        parts.append("\(number(m.cp)) CP")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                GamePhoto(m: m)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(m.name).font(.system(size: 28, weight: .medium)).tracking(-0.56).lineLimit(1)
                        if m.gameName != m.name {
                            Text(tr("Ve hře: \(m.gameName)", "In the game: \(m.gameName)")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        FlowRow(spacing: 6) {
                            ForEach(m.types, id: \.self) { t in
                                chip(Theme.raise) {
                                    Circle().fill(PokeType.color(t)).frame(width: 8, height: 8)
                                    Text(t.capitalized)
                                }
                            }
                            if let g = m.gen {
                                chip(Theme.raise) { Text(InventoryStats.regions[g - 1] + " · " + tr("\(g). gen", "gen \(g)")) }
                            }
                            ForEach(flags, id: \.self) { f in
                                chip(Theme.tint) { Text(f).fontWeight(.medium).foregroundStyle(Theme.accentInk) }
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(percentText(m.pct)).font(.system(size: 44, weight: .medium)).tracking(-1.7).monospacedDigit()
                            .foregroundStyle(m.pct == 100 ? StatsColors.gold : Theme.text)
                        Text("IV").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                    VStack(spacing: 8) {
                        ForEach(Array(zip([tr("Útok", "Attack"), tr("Obrana", "Defense"), "HP"], m.iv)), id: \.0) { label, v in
                            HStack(spacing: 10) {
                                Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.track)
                                        Capsule().fill(StatsColors.iv(m.pct)).frame(width: geo.size.width * CGFloat(v) / 15)
                                    }
                                }
                                .frame(height: 8)
                                Text("\(v)/15").font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                    HStack(spacing: 8) {
                        cell("CP", number(m.cp))
                        cell(tr("Úroveň", "Level"), m.levelText ?? "–")
                        cell(tr("Max CP na L50", "Max CP at L50"), m.maxCP50.map(number) ?? "–")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Pořadí v PvP", "PvP rank")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    ForEach(store.config.pvp.all, id: \.key) { item in
                        let r = m.ranks[item.key]
                        HStack(spacing: 8) {
                            Circle().fill(item.league.color.swatch).frame(width: 9, height: 9)
                            Text(StatsSheetDef.leagueShort[item.key] ?? item.key).font(.system(size: 13))
                            Spacer(minLength: 4)
                            Text(r.map { "#\($0)" } ?? "—").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(r == 1 ? Theme.accentInk : (r == nil ? Theme.muted : Theme.text))
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Tagy ve hře", "Tags in the game")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                if m.tags.isEmpty {
                    Text(tr("Bez tagu", "No tag")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                } else {
                    FlowRow(spacing: 6) {
                        ForEach(m.tags, id: \.self) { t in
                            chip(Theme.raise, height: 24) {
                                Circle().fill(StatsTagColor.of(t, store.config)).frame(width: 8, height: 8)
                                Text(t)
                            }
                        }
                    }
                }
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: n.icon).font(.system(size: 13)).foregroundStyle(n.color)
                    Text(n.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 8) {
                Button { model.reveal(m) } label: { Label(tr("Ukázat ve Výsledcích", "Show in Results"), systemImage: "folder") }
                    .buttonStyle(OutlineButtonStyle(height: 32))
                    .help(tr("Ukáže ve Finderu fotku kusu ze hry, jinak snímek IV z běhu, kdy se měřil",
                             "Shows the Pokémon's photo from the game in Finder, otherwise the IV screenshot from the run that measured it"))
                Button {
                    model.copy(m.gameName, message: tr("Zkopírováno „\(m.gameName)“", "Copied “\(m.gameName)”"))
                } label: { Label(tr("Kopírovat jméno", "Copy name"), systemImage: "doc.on.doc") }
                    .buttonStyle(GhostButtonStyle(color: Theme.text, hover: Theme.raise, height: 32))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var flags: [String] {
        var f: [String] = []
        if m.legendary { f.append(tr("Legenda", "Legendary")) }
        if m.ultraBeast { f.append("Ultra beast") }
        if m.mythical { f.append(tr("Mýtický", "Mythical")) }
        if m.canEvolve { f.append(tr("Má další evoluci", "Can evolve")) }
        if m.isNew { f.append(tr("Nový z posledního běhu", "New in the last run")) }
        return f
    }

    private var notes: [(icon: String, color: Color, text: String)] {
        var n: [(String, Color, String)] = []
        if m.pct == 100 { n.append(("crown.fill", StatsColors.gold, tr("Hundo: 15/15/15, lepší IV mít nejde.", "Hundo: 15/15/15, the best IVs there are."))) }
        if m.id == def.bestId {
            n.append(("checkmark.circle", Theme.green, tr("Nejlepší kus druhu v inventáři.", "The best of its species in the storage.")))
        } else if m.tags.contains(stats.removeTag) {
            n.append(("trash", Theme.red, tr("Má lepší kopii stejného druhu, proto dostal tag \(stats.removeTag). Smazat ho musíš ve hře sám.",
                                              "It has a better copy of the same species, so it got the \(stats.removeTag) tag. You delete it in the game yourself.")))
        }
        for item in store.config.pvp.all where m.ranks[item.key] == 1 {
            n.append(("trophy", Theme.accentInk, tr("Pořadí 1 v \(item.league.name): lepší IV pro tuto ligu mít nejde.",
                                                     "Rank 1 in \(item.league.name): no IVs are better for this league.")))
        }
        if m.species == nil {
            n.append(("questionmark.circle", Theme.muted, tr("Druh se nepodařilo poznat, proto chybí region, úroveň a PvP pořadí.",
                                                             "The species wasn't recognized, so the region, level and PvP ranks are missing.")))
        }
        return n
    }

    private func chip<C: View>(_ bg: Color, height: CGFloat = 22, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12)).lineLimit(1)
            .padding(.horizontal, 8).frame(height: height)
            .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func cell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Text(v).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The whole screen from the game with the Pokémon and its appraisal, saved by the bot while it read the IVs;
/// a click enlarges it over the window. Without one, the bot's crop of the IV bars from the results, otherwise
/// the species' picture with a note that the photo comes with the next measurement.
private struct GamePhoto: View {
    let m: InventoryStats.Mon
    @ObservedObject private var model = StatsSheetModel.shared
    @State private var hovering = false
    static let width: CGFloat = 168

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if let img = MonImages.photo(m) {
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: Self.width, height: Self.width * img.size.height / max(1, img.size.width))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(hovering ? Theme.accent.opacity(0.8) : Theme.border))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .padding(8)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(shape)
                    .onTapGesture { model.zoomed = m }
                    .onHover { hovering = $0 }
                    .help(tr("Zvětšit", "Enlarge"))
                Text(tr("Ze hry, při měření IV", "From the game, while reading the IVs"))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else if case let (img, url)? = MonImages.bars(m) {
                MonIcon(m: m, size: Self.width)
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: Self.width, height: Self.width * img.size.height / max(1, img.size.width))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(hovering ? Theme.accent.opacity(0.8) : Theme.border))
                    .contentShape(shape)
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .onHover { hovering = $0 }
                    .help(tr("Otevřít v Náhledu", "Open in Preview"))
                note
            } else {
                MonIcon(m: m, size: Self.width)
                note
            }
        }
        .frame(width: Self.width)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var note: some View {
        Text(tr("Fotka ze hry se uloží, až bot kus změří znovu.", "A photo from the game is saved when the bot measures it again."))
            .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// The photo from the game as big as the window allows; a click anywhere or esc closes it.
struct PhotoZoom: View {
    let m: InventoryStats.Mon
    let image: NSImage
    let height: CGFloat
    @ObservedObject private var model = StatsSheetModel.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 12) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: max(200, height - 50))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                HStack(spacing: 10) {
                    Text("\(m.name) · \(percentText(m.pct)) · \(number(m.cp)) CP")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white).monospacedDigit()
                    Button(tr("Otevřít v Náhledu", "Open in Preview")) { NSWorkspace.shared.open(MonImages.photoURL(m)) }
                        .buttonStyle(GhostButtonStyle(color: .white, hover: .white.opacity(0.15), height: 26))
                }
            }
            .padding(.vertical, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.zoomed = nil }
    }
}

/// The coverage window: how many Pokémon the numbers come from and why some lack the species.
private struct CoverageContent: View {
    let stats: InventoryStats
    var startRun: () -> Void
    @EnvironmentObject private var runner: Runner

    var body: some View {
        let s = stats
        let missing = s.total - s.withSpecies
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                row(tr("Kusy s IV", "Pokémon with IVs"), s.total, Theme.accent)
                row(tr("S druhem a úrovní", "With species and level"), s.withSpecies, Theme.accent.opacity(0.65))
                row(tr("Jen IV, bez druhu", "IVs only, no species"), missing, Theme.muted)
            }
            .frame(maxWidth: 680)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                card("eye", tr("Co IVory čte", "What IVory reads"),
                     tr("IV, CP, HP, typy a tagy čte u každého kusu. Druh a úroveň dopočítá z CP, HP a IV.",
                        "IVs, CP, HP, types and tags for every Pokémon. It works out the species and level from CP, HP and IVs."))
                card("clock.arrow.circlepath", tr("Proč \(missing) nemá druh", "Why \(missing) lack the species"),
                     tr("Z CP, HP a IV se druh nedal určit jednoznačně, třeba kvůli přezdívce. Další běh to zkusí znovu.",
                        "The species couldn't be told from CP, HP and IVs, for example because of a nickname. The next run tries again."))
                card("books.vertical", tr("Které karty to ovlivní", "Which cards it affects"),
                     tr("Pokédex, Vzácné, Úrovně, Ještě vyvinout a Nejčastější druh počítají jen z \(s.withSpecies) kusů.",
                        "Pokédex, Rare, Levels, Still to evolve and Most common species count only the \(s.withSpecies) Pokémon."))
                card("lock", tr("Kde data jsou", "Where the data is"), tr("Jen na tvém Macu. Nic se neodesílá.", "Only on your Mac. Nothing is sent anywhere."))
            }
            .frame(maxWidth: 820)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(action: startRun) { Label(tr("Spustit běh", "Start a run"), systemImage: "play") }
                    .buttonStyle(OutlineButtonStyle(height: 32))
                    .disabled(runner.isRunning)
                Text(tr("Běh doplní druh a úroveň u kusů, které projde.", "A run adds the species and level for the Pokémon it goes through."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func row(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 14) {
            Text(label).font(.system(size: 14)).frame(width: 200, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.track)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
                        .frame(width: geo.size.width * CGFloat(n) / CGFloat(max(1, stats.total)))
                }
            }
            .frame(height: 12)
            Text(number(n)).font(.system(size: 15, weight: .semibold)).monospacedDigit().frame(width: 60, alignment: .trailing)
        }
    }

    private func card(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
                .labelStyle(TintedIconLabel())
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.accentInk)
            configuration.title
        }
    }
}

/// The color a tag has in the game (from the settings); other tags are gray.
enum StatsTagColor {
    static func of(_ name: String, _ c: AppConfig) -> Color {
        if name == c.removeTag { return c.removeTagColor.swatch }
        if let t = c.ivTags.first(where: { $0.name == name }) { return t.color.swatch }
        if let l = c.pvp.all.first(where: { $0.league.name == name }) { return l.league.color.swatch }
        return TagColor.gray.swatch
    }
}
