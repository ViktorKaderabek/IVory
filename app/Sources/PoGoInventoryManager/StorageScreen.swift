import SwiftUI

/// Storage: what IVory knows about the box. Three numbers and the IV spread at the top, the best Pokémon
/// for each league as three rankings under them, the Pokédex by region and the collections at the bottom.
/// Clicking a row opens the Pokémon beside the content, not in a window over it.
struct StorageScreen: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var statsStore = StatsStore.shared
    /// Empty state: back to Run and start a run.
    var startRun: () -> Void

    @ObservedObject private var state = StorageScreenState.shared

    private var stats: InventoryStats? { statsStore.stats }

    var body: some View {
        content
            .onAppear { statsStore.refresh(removeTag: store.config.removeTag) }
        #if DEBUG
        .onReceive(statsStore.$stats) { s in
            guard !state.autoPicked,
                  ProcessInfo.processInfo.environment["IVORY_STORAGE_PICK"] == "1"
                      || ProcessInfo.processInfo.environment["IVORY_DETAIL"] == "1",
                  let best = s?.mons.filter({ $0.ranks["great"] != nil }).min(by: { ($0.ranks["great"] ?? 0) < ($1.ranks["great"] ?? 0) })
            else { return }
            state.autoPicked = true
            // next turn of the run loop: opening it from inside the publisher forces a redraw while
            // `stats` is still being assigned, and the screen would keep the stale empty state
            DispatchQueue.main.async { MonSelection.shared.open(best) }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if let stats, !stats.isEmpty {
                WeightedColumns(weights: [0, 1], spacing: 16, fixed: [240, nil], fillHeight: true) {
                    numbers(stats)
                    IVDistribution(stats: stats, tags: store.config.ivTags)
                }
                .fixedSize(horizontal: false, vertical: true)
                bestForPvP(stats)
                WeightedColumns(weights: [1, 1], spacing: 16) {
                    regions(stats)
                    collections(stats)
                }
            } else if stats != nil {
                NeverRun(startRun: startRun,
                         promise: tr("rozložení IV, nejlepší kusy do lig a co ti chybí do kolekcí",
                                     "the IV spread, your best Pokémon for the leagues and what you are missing from the collections"))
            } else {
                Color.clear.frame(height: 400)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Úložiště", "Storage"))
                    .font(.system(size: 26, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            if let runs = stats?.runs, let last = runs.last {
                Menu {
                    ForEach(runs.reversed()) { run in
                        Button(tr("Běh \((runs.firstIndex { $0.id == run.id } ?? 0) + 1) · ",
                                 "Run \((runs.firstIndex { $0.id == run.id } ?? 0) + 1) · ")
                               + run.date.formatted(date: .abbreviated, time: .shortened)) {
                            StatsSheetModel.shared.open(.run(run.id))
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                        Text(tr("Běh \(runs.count) z \(runs.count) · ", "Run \(runs.count) of \(runs.count) · ")
                             + last.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var subtitle: String {
        guard let stats, !stats.isEmpty else {
            return tr("Co IVory ví o tvém úložišti", "What IVory knows about your storage")
        }
        return tr("Přečteno \(stats.total) Pokémonů, druh zná u \(stats.withSpecies)",
                  "\(stats.total) Pokémon read, the species is known for \(stats.withSpecies)")
    }

    // MARK: - The three numbers

    private func numbers(_ s: InventoryStats) -> some View {
        VStack(spacing: 0) {
            numberCell(tr("Pokédex", "Pokédex"), "\(s.dexOwned)",
                       tr("z \(s.dexTotal) druhů", "of \(s.dexTotal) species"),
                       bar: s.dexTotal > 0 ? Double(s.dexOwned) / Double(s.dexTotal) : nil)
            divider
            numberCell(tr("Průměrné IV", "Average IV"), percentText(s.ivAverage),
                       tr("ze \(s.total) Pokémonů", "of \(s.total) Pokémon"))
            divider
            numberCell(tr("Hundo 15/15/15", "Hundo 15/15/15"), "\(s.hundos.count)",
                       tr("· \(s.nearPerfect) na 98 % a víc", "· \(s.nearPerfect) at 98% or more"),
                       crown: true)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    private func numberCell(_ title: String, _ value: String, _ note: String,
                            bar: Double? = nil, crown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if crown {
                    Image(systemName: "crown.fill").font(.system(size: 12)).foregroundStyle(Theme.gold)
                }
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 32, weight: .medium).monospacedDigit())
                Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            if let bar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * bar)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - Best for PvP

    private func bestForPvP(_ s: InventoryStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(tr("Nejlepší na PvP", "Best for PvP"),
                         tr("nejblíž nejlepším možným IV pro každou ligu", "the closest to the best possible IVs for each league"))
            HStack(alignment: .top, spacing: 12) {
                ForEach(PvPLeague.allCases) { league in
                    leagueCard(league, s)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func leagueCard(_ league: PvPLeague, _ s: InventoryStats) -> some View {
        let ranked = s.mons.compactMap { m -> (InventoryStats.Mon, Int)? in
            guard let r = m.ranks[league.rawValue] else { return nil }
            return (m, r)
        }.sorted { $0.1 < $1.1 }

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(leagueColor(league)).frame(width: 8, height: 8)
                Text(league.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                Text(tr("\(tagged(league)) otagováno", "\(tagged(league)) tagged"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            VStack(spacing: 2) {
                ForEach(Array(ranked.prefix(5)), id: \.0.id) { mon, rank in
                    RankedRow(mon: mon, rank: rank)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            AllRankedButton(count: ranked.count) { StatsSheetModel.shared.open(.league(league.rawValue)) }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
    }

    // MARK: - Pokédex and collections

    private func regions(_ s: InventoryStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(tr("Pokédex po regionech", "Pokédex by region"), nil)
            VStack(spacing: 8) {
                ForEach(Array(InventoryStats.regions.enumerated()), id: \.offset) { i, name in
                    let owned = i < s.generations.count ? s.generations[i] : 0
                    let total = i < s.generationTotals.count ? s.generationTotals[i] : 0
                    HStack(spacing: 12) {
                        Text(name).font(.system(size: 13)).frame(width: 64, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(Theme.accent)
                                    .frame(width: total > 0 ? geo.size.width * Double(owned) / Double(total) : 0)
                            }
                        }
                        .frame(height: 6)
                        Text("\(owned) / \(total)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }

    private func collections(_ s: InventoryStats) -> some View {
        let kinds: [(String, String, Color, Int, StatsSheet)] = [
            ("star.fill", tr("Legendární", "Legendary"), Theme.gold, s.legendary, .rare("legendary")),
            ("globe", tr("Ultra beasts", "Ultra beasts"), Theme.blue, s.ultraBeast, .rare("ultrabeast")),
            ("sparkles", tr("Bájní", "Mythical"), Theme.pink, s.mythical, .rare("mythical")),
        ]
        // under them the species you have the most of, with their picture – as in the design
        let most = s.topSpecies.prefix(3)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(tr("Sbírky", "Collections"), nil)
            VStack(spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    CollectionRow(count: "\(row.3)", meta: nil, name: row.1,
                                  icon: { AnyView(Image(systemName: row.0).font(.system(size: 15)).foregroundStyle(row.2).frame(width: 18)) },
                                  open: { StatsSheetModel.shared.open(row.4) })
                }
                ForEach(Array(most.enumerated()), id: \.offset) { _, species in
                    Rectangle().fill(Theme.border).frame(height: 1)
                    let best = s.mons.filter { $0.name == species.name }.map(\.pct).max()
                    CollectionRow(count: "\(species.count)×",
                                  meta: best.map { tr("nejlepší \(percentText($0))", "best \(percentText($0))") },
                                  name: species.name,
                                  icon: {
                                      AnyView(Group {
                                          if let mon = s.mons.first(where: { $0.name == species.name }) {
                                              MonIcon(m: mon, size: 28, circle: true)
                                          } else {
                                              Color.clear.frame(width: 28, height: 28)
                                          }
                                      })
                                  },
                                  open: { StatsSheetModel.shared.open(.species(species.name)) })
                }
            }
            .padding(6)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }

    /// How many Pokémon the bot actually put in that league's tag in the game.
    private func tagged(_ league: PvPLeague) -> Int {
        let name = store.config.pvp.all.first { $0.key == league.rawValue }?.league.name ?? ""
        guard !name.isEmpty else { return 0 }
        return stats?.mons.filter { $0.tags.contains(name) }.count ?? 0
    }

    /// The league's dot takes the colour of the tag the user gave that league in the game.
    private func leagueColor(_ league: PvPLeague) -> Color {
        (store.config.pvp.all.first { $0.key == league.rawValue }?.league.color ?? .purple).swatch
    }

    private func sectionTitle(_ title: String, _ note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .medium))
            if let note {
                Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }
}
