import SwiftUI

/// Obrazovka Statistiky („Co IVory zná“): Pokédex, IV a hundo nahoře, síň slávy PvP, pak menší karty.
/// Kde číslo stojí na neúplných datech, karta říká, z kolika kusů je spočítané.
struct StatsView: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var statsStore = StatsStore.shared
    private let preloaded: InventoryStats?
    /// Prázdný stav: přepne na přehled a spustí běh s kroky z přehledu.
    var startRun: () -> Void

    /// `preloaded` jen pro snímky bez okna (tam se nic nenačítá).
    init(preloaded: InventoryStats? = nil, startRun: @escaping () -> Void) {
        self.preloaded = preloaded
        self.startRun = startRun
    }

    var body: some View {
        Group {
            if let stats = preloaded ?? statsStore.stats {
                if stats.isEmpty { EmptyStats(runs: stats.runs.count, startRun: startRun) }
                else { content(stats) }
            } else {
                Color.clear.frame(height: 400)
                    .onAppear { statsStore.refresh(removeTag: store.config.removeTag) }
            }
        }
    }

    private func content(_ s: InventoryStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(s)
            HStack(spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(Theme.accentInk)
                Text(tr("Čísla ukazují kusy, které IVory přečetl při bězích, ne celý inventář ve hře.",
                        "These numbers cover the Pokémon IVory read during its runs, not your whole storage."))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            WeightedRow(weights: [1.35, 1, 0.8]) {
                DexCard(s: s)
                IVCard(s: s, ivTags: store.config.ivTags)
                HundoCard(s: s)
            }
            WeightedRow(weights: [1.6, 1]) {
                PvPCard(s: s, pvp: store.config.pvp)
                StrongestCard(s: s)
            }
            WeightedRow(weights: [1.5, 1, 1]) {
                RareCard(s: s)
                NumberCard(symbol: "arrow.up.forward.circle", title: tr("Ještě vyvinout", "Still to evolve"),
                           value: s.canEvolve, caption: tr("kusů má další evoluci", "Pokémon have a further evolution"))
                NumberCard(symbol: "square.on.square", title: tr("Duplicity", "Duplicates"), value: s.duplicateSpecies,
                           caption: tr("druhů má víc kusů", "species have more than one"),
                           footnote: s.removable > 0 ? (tr("\(s.removable) s tagem \(store.config.removeTag)",
                                                           "\(s.removable) tagged \(store.config.removeTag)"),
                                                        store.config.removeTagColor.swatch) : nil)
            }
            WeightedRow(weights: [1, 1, 1]) {
                TypesCard(s: s)
                TopSpeciesCard(s: s)
                LevelsCard(s: s)
            }
            WeightedRow(weights: [1.2, 1]) {
                TagsCard(tags: Array(s.tags.prefix(4)), color: tagColor)
                RunsCard(runs: s.runs)
            }
        }
    }

    private func header(_ s: InventoryStats) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Co IVory zná", "What IVory knows"))
                    .font(.system(size: 26, weight: .medium)).tracking(-0.5)
                Text(subtitle(s)).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(trCount(s.total, cs: "kus s IV", "kusy s IV", "kusů s IV", en: "Pokémon with IV", "Pokémon with IV"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(tr("druh a úroveň u \(s.withSpecies) (\(percentText(share(s.withSpecies, s.total))))",
                            "species and level for \(s.withSpecies) (\(percentText(share(s.withSpecies, s.total))))"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .monospacedDigit()
                Meter(fraction: Double(s.withSpecies) / Double(max(1, s.total)), height: 6).frame(width: 72)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        }
    }

    private func subtitle(_ s: InventoryStats) -> String {
        var parts = [trCount(s.runs.count, cs: "běhu", "běhů", "běhů", en: "run", "runs")]
        parts[0] = tr("Z \(parts[0])", "From \(parts[0])")
        if let last = s.runs.last { parts.append(tr("naposledy ", "last ") + RunsCard.when(last.date)) }
        parts.append(tr("počítá se jen na tvém Macu", "computed only on your Mac"))
        return parts.joined(separator: " · ")
    }

    private func tagColor(_ name: String) -> TagColor {
        let c = store.config
        if name == c.removeTag { return c.removeTagColor }
        if let t = c.ivTags.first(where: { $0.name == name }) { return t.color }
        if let l = c.pvp.all.first(where: { $0.league.name == name }) { return l.league.color }
        return .gray
    }
}

private func share(_ part: Int, _ whole: Int) -> Int {
    whole > 0 ? Int((Double(part) / Double(whole) * 100).rounded()) : 0
}

// MARK: - Karty

/// Karta statistiky: ikona, nadpis, vpravo drobný údaj (z kolika kusů), pod tím obsah.
private struct StatCard<Content: View>: View {
    let symbol: String
    let title: String
    var note: String? = nil
    var symbolColor: Color = Theme.accentInk
    var spacing: CGFloat = 12
    var background: AnyShapeStyle = AnyShapeStyle(Theme.surface)
    var stroke: Color = Theme.border
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(symbolColor)
                Text(title).font(.system(size: 14, weight: .semibold))
                if let note {
                    Spacer(minLength: 6)
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            content
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(stroke))
    }
}

/// Velké číslo s popiskem vedle.
private struct BigNumber: View {
    let value: String
    var caption: String? = nil
    var size: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .tracking(-size * 0.04)
                .monospacedDigit()
            if let caption {
                Text(caption).font(.system(size: 15)).foregroundStyle(Theme.muted).monospacedDigit()
            }
        }
        .lineLimit(1)   // bez minimumScaleFactor: zmenšování písma se měří opakovaně a je drahé
    }
}

/// Vodorovný ukazatel (podíl, pruh v grafu).
private struct Meter: View {
    let fraction: Double
    var height: CGFloat = 10
    var color: Color = Theme.accent
    var glow = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * min(1, max(0, fraction))))
                    .shadow(color: glow ? color.opacity(0.7) : .clear, radius: 5)
            }
        }
        .frame(height: height)
    }
}

/// Řádek grafu: popisek · pruh · číslo.
private struct BarRow: View {
    let label: String
    let value: Int
    let maxValue: Int
    var color: Color = Theme.accent
    var labelWidth: CGFloat = 62
    var height: CGFloat = 10
    var labelColor: Color = Theme.muted

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12, weight: labelColor == Theme.muted ? .regular : .medium))
                .foregroundStyle(labelColor).lineLimit(1).frame(width: labelWidth, alignment: .leading)
            Meter(fraction: Double(value) / Double(max(1, maxValue)), height: height, color: color)
            Text("\(value)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }
}

private struct DexCard: View {
    let s: InventoryStats
    private static let regions = ["Kanto", "Johto", "Hoenn", "Sinnoh", "Unova", "Kalos", "Alola", "Galar", "Paldea"]

    var body: some View {
        StatCard(symbol: "books.vertical", title: "Pokédex",
                 note: tr("z \(s.withSpecies) kusů se známým druhem", "from \(s.withSpecies) with known species")) {
            BigNumber(value: "\(s.dexOwned)",
                      caption: tr("z \(s.dexTotal) druhů · \(percentText(share(s.dexOwned, s.dexTotal)))",
                                  "of \(s.dexTotal) species · \(percentText(share(s.dexOwned, s.dexTotal)))"))
            Meter(fraction: Double(s.dexOwned) / Double(max(1, s.dexTotal)), height: 6, glow: true)
            Text(tr("Různé druhy podle regionu, odkud pocházejí", "Different species by home region"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            let top = max(1, s.generations.max() ?? 1)
            Grid(horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow(alignment: .bottom) {
                    ForEach(0..<9, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text("\(s.generations[i])").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2,
                                                   bottomTrailingRadius: 2, topTrailingRadius: 4, style: .continuous)
                                .fill(s.generations[i] == top ? Theme.accent : Theme.accent.opacity(0.5))
                                .frame(height: max(3, 64 * CGFloat(s.generations[i]) / CGFloat(top)))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                GridRow {
                    ForEach(0..<9, id: \.self) { i in
                        VStack(spacing: 0) {
                            Text(Self.regions[i]).font(.system(size: 11, weight: .medium))
                            Text(tr("\(i + 1). gen", "Gen \(i + 1)")).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                        .lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct IVCard: View {
    let s: InventoryStats
    let ivTags: [IVTag]

    var body: some View {
        StatCard(symbol: "chart.bar.xaxis", title: tr("Rozložení IV", "IV spread"),
                 note: trCount(s.total, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon")) {
            BigNumber(value: percentText(s.ivAverage), caption: tr("průměr", "average"))
            let top = max(1, s.ivBins.map(\.count).max() ?? 1)
            VStack(spacing: 7) {
                ForEach(s.ivBins, id: \.lower) { bin in
                    BarRow(label: label(bin.lower), value: bin.count, maxValue: top, color: color(bin.lower), height: 12)
                }
            }
            Spacer(minLength: 0)
            Text(tr("Vychýlené nahoru: slabé kusy se průběžně mažou.", "Skewed high: weak Pokémon keep getting deleted."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ lower: Int) -> String {
        switch lower {
        case 90: return pctRange(90, 100)
        case 0: return tr("pod 70 %", "under 70%")
        default: return pctRange(lower, lower + 9)
        }
    }

    /// Barva IV tagu, do kterého spodek koše spadá (stejné barvy jako ve hře).
    private func color(_ lower: Int) -> Color {
        let tag = ivTags.filter { !$0.name.isEmpty }.sorted { $0.min > $1.min }.first { $0.min <= max(lower, 1) }
        return (tag?.color ?? .gray).swatch
    }
}

private struct HundoCard: View {
    let s: InventoryStats
    private let gold = Color.oklch(0.8, 0.15, 85)

    var body: some View {
        StatCard(symbol: "crown.fill", title: "Hundo", symbolColor: gold, spacing: 10,
                 background: AnyShapeStyle(LinearGradient(colors: [gold.opacity(0.2), Theme.surface],
                                                          startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.7))),
                 stroke: gold.opacity(0.45)) {
            BigNumber(value: "\(s.hundos.count)", caption: tr("kusů 15/15/15", "at 15/15/15"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(s.hundos.enumerated()), id: \.offset) { _, name in
                    VStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in Capsule().fill(gold).frame(height: 3) }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 6)
                    .background(Theme.raise, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(name)
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(s.nearPerfect)").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Text(tr("kusů s 98 % a víc", "at 98% or more")).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct PvPCard: View {
    let s: InventoryStats
    let pvp: PvPConfig

    var body: some View {
        StatCard(symbol: "trophy", title: tr("Síň slávy PvP", "PvP hall of fame"),
                 note: tr("z \(s.ranked) kusů s pořadím", "from \(s.ranked) ranked")) {
            Text(tr("kusy s pořadím 1", "rank 1 Pokémon")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .padding(.top, -8)
            HStack(alignment: .top, spacing: 10) {
                ForEach(s.leagues) { league in leagueBox(league) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func leagueBox(_ league: InventoryStats.League) -> some View {
        let setting = pvp.all.first { $0.key == league.key }?.league
        let cap = ["great": tr("1 500 CP", "1,500 CP"), "ultra": tr("2 500 CP", "2,500 CP"), "master": tr("bez limitu", "no cap")][league.key] ?? ""
        let title = ["great": "Great", "ultra": "Ultra", "master": "Master"][league.key] ?? league.key
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill((setting?.color ?? .gray).swatch).frame(width: 10, height: 10)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(cap).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            if league.top.isEmpty {
                Text(tr("Zatím žádný kus s pořadím 1", "No rank 1 Pokémon yet"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(league.top.prefix(4), id: \.self) { name in
                HStack(spacing: 8) {
                    Text("#1").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(Theme.tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
            }
            if league.top.count > 4 {
                Text(tr("a ještě \(league.top.count - 4)", "and \(league.top.count - 4) more"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct StrongestCard: View {
    let s: InventoryStats

    var body: some View {
        StatCard(symbol: "bolt", title: tr("Nejsilnější", "Strongest")) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Nejvyšší CP teď", "Highest CP now")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                Text(s.topCP.formatted(.number.locale(L10n.locale)))
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(tr("Teoretické maximum na úrovni 50", "Theoretical maximum at level 50"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(s.maxCP) { item in
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(item.count.formatted(.number.locale(L10n.locale)))
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    }
                    Meter(fraction: Double(item.count) / 5000, height: 6)
                }
            }
            if s.maxCP.isEmpty {
                Text(tr("Ukáže se po běhu s PvP tagy.", "Shows up after a run with PvP tags."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct RareCard: View {
    let s: InventoryStats

    var body: some View {
        StatCard(symbol: "sparkles", title: tr("Vzácné", "Rare"),
                 note: tr("hlavně ze starších běhů", "mostly from older runs"), spacing: 10) {
            HStack(spacing: 8) {
                badge("star.fill", s.legendary, tr("legendy", "legendary"), Theme.yellow, Theme.yellowTint)
                badge("globe.americas.fill", s.ultraBeast, "ultra beasts", Theme.blue, Theme.blueTint)
                badge("sparkle", s.mythical, tr("mýtičtí", "mythical"), Theme.pink, Theme.pinkTint)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func badge(_ symbol: String, _ n: Int, _ label: String, _ fg: Color, _ bg: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(fg)
                .frame(width: 30, height: 30).background(bg, in: Circle())
            Text("\(n)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct NumberCard: View {
    let symbol: String
    let title: String
    let value: Int
    let caption: String
    var footnote: (String, Color)? = nil

    var body: some View {
        StatCard(symbol: symbol, title: title, spacing: 6) {
            Text("\(value)").font(.system(size: 36, weight: .semibold)).tracking(-1).monospacedDigit()
            Text(caption).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Circle().fill(footnote.1).frame(width: 8, height: 8)
                    Text(footnote.0).font(.system(size: 12))
                }
            }
        }
    }
}

private struct TypesCard: View {
    let s: InventoryStats

    var body: some View {
        StatCard(symbol: "drop", title: tr("Typy", "Types"),
                 note: trCount(s.typed, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon"), spacing: 10) {
            let shown = s.types.count > 6 ? Array(s.types.prefix(5)) + [s.types.last!] : s.types
            let top = max(1, s.types.first?.count ?? 1)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                if i == 5 && s.types.count > 6 {
                    Text(tr("… dalších \(s.types.count - 6) typů", "… \(s.types.count - 6) more types"))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.leading, 68)
                }
                BarRow(label: t.name.capitalized, value: t.count, maxValue: top, color: PokeType.color(t.name),
                       labelWidth: 60, labelColor: Theme.text)
            }
        }
    }
}

private struct TopSpeciesCard: View {
    let s: InventoryStats
    private let gold = Color.oklch(0.86, 0.15, 92)

    var body: some View {
        StatCard(symbol: "list.number", title: tr("Nejčastější druh", "Most common species"), spacing: 6) {
            ForEach(Array(s.topSpecies.enumerated()), id: \.element.id) { i, sp in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(i == 0 ? Color.oklch(0.2, 0.01, 270) : Theme.text)
                        .frame(width: 22, height: 22)
                        .background(i == 0 ? gold : Theme.raise, in: Circle())
                    Text(sp.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(sp.count)×").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct LevelsCard: View {
    let s: InventoryStats

    var body: some View {
        StatCard(symbol: "stairs", title: tr("Úrovně", "Levels"),
                 note: trCount(s.leveled, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon"), spacing: 10) {
            let top = max(1, s.levels.map(\.count).max() ?? 1)
            ForEach(s.levels, id: \.label) { l in
                BarRow(label: l.label, value: l.count, maxValue: top, labelWidth: 56)
            }
        }
    }
}

private struct TagsCard: View {
    let tags: [InventoryStats.Named]
    let color: (String) -> TagColor

    var body: some View {
        StatCard(symbol: "tag", title: tr("Tagy ve hře", "Tags in the game"),
                 note: tr("jeden kus může mít víc tagů", "one Pokémon can have several")) {
            GeometryReader { geo in
                let total = CGFloat(max(1, tags.map(\.count).reduce(0, +)))
                let free = geo.size.width - CGFloat(max(0, tags.count - 1)) * 3
                HStack(spacing: 3) {
                    ForEach(tags) { t in
                        let c = color(t.name)
                        Text("\(t.count)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(c.isLight ? Color.oklch(0.2, 0.01, 270) : Theme.white)
                            .padding(.horizontal, 8)
                            .frame(width: free * CGFloat(t.count) / total, height: 26, alignment: .leading)
                            .background(c.swatch, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .help("\(t.name): \(t.count)")
                    }
                }
            }
            .frame(height: 26)
            FlowRow(spacing: 6) {
                ForEach(tags) { t in
                    HStack(spacing: 6) {
                        Circle().fill(color(t.name).swatch).frame(width: 9, height: 9)
                        Text(t.name).font(.system(size: 12))
                    }
                    .padding(.trailing, 10)
                }
            }
        }
    }
}

struct RunsCard: View {
    let runs: [InventoryStats.Run]

    var body: some View {
        StatCard(symbol: "clock.arrow.circlepath", title: tr("Historie běhů", "Run history"),
                 note: trCount(runs.count, cs: "běh", "běhy", "běhů", en: "run", "runs")) {
            HStack(spacing: 0) {
                ForEach(Array(runs.suffix(40).enumerated()), id: \.element.id) { i, run in
                    let last = run.id == runs.last?.id
                    HStack(spacing: 0) {
                        Circle()
                            .fill(last ? Theme.accent : Theme.accent.opacity(0.45))
                            .frame(width: last ? 12 : 7, height: last ? 12 : 7)
                            .shadow(color: last ? Theme.accent.opacity(0.8) : .clear, radius: 5)
                            .help(Self.describe(run))
                        if !last { Rectangle().fill(Theme.track).frame(height: 2) }
                    }
                    .frame(maxWidth: last ? 12 : .infinity)
                }
            }
            .frame(height: 22)
            if let last = runs.last {
                Text(Self.when(last.date).prefix(1).uppercased() + Self.when(last.date).dropFirst())
                    .font(.system(size: 13, weight: .semibold))
                + Text("  " + Self.details(last)).font(.system(size: 13)).foregroundColor(Theme.muted)
            }
        }
    }

    static func describe(_ run: InventoryStats.Run) -> String {
        when(run.date) + " · " + details(run)
    }

    static func details(_ run: InventoryStats.Run) -> String {
        var parts = [duration(run.duration)]
        if let n = run.checked { parts.append(tr("\(n) prošlo", "\(n) checked")) }
        parts.append(trCount(run.errors, cs: "vyřešená chyba", "vyřešené chyby", "vyřešených chyb",
                             en: "recovered error", "recovered errors"))
        return parts.joined(separator: " · ")
    }

    /// „dnes 14:32“, „včera 9:05“, jinak „2. 10. 21:16“.
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute().locale(L10n.locale))
        if cal.isDateInToday(date) { return tr("dnes ", "today ") + time }
        if cal.isDateInYesterday(date) { return tr("včera ", "yesterday ") + time }
        return date.formatted(.dateTime.day().month(.defaultDigits).locale(L10n.locale)) + " " + time
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Prázdný stav

private struct EmptyStats: View {
    let runs: Int
    var startRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Co IVory zná", "What IVory knows")).font(.system(size: 26, weight: .medium)).tracking(-0.5)
                Text(runs == 0 ? tr("Zatím žádný běh", "No runs yet") : tr("Paměť je zatím prázdná", "The memory is still empty"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ZStack(alignment: .top) {
                VStack(spacing: 12) {
                    WeightedRow(weights: [1.35, 1, 0.8], minColumn: 0) {
                        ghost(hatched: true, 200); ghost(hatched: true, 200); ghost(hatched: true, 200)
                    }
                    WeightedRow(weights: [1.6, 1], minColumn: 0) { ghost(hatched: false, 150); ghost(hatched: false, 150) }
                }
                .opacity(0.4)
                VStack(spacing: 12) {
                    SoftIcon(symbol: "chart.bar", size: 48, radius: 14)
                    Text(tr("Zatím nic nevím", "Nothing to show yet")).font(.system(size: 20, weight: .medium))
                    Text(tr("Statistiky se plní z běhů. Po prvním běhu tu uvidíš Pokédex, rozložení IV, hundo kusy a síň slávy PvP.",
                            "Stats fill up from runs. After the first run you'll see your Pokédex, IV spread, hundos and the PvP hall of fame."))
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(runs == 0 ? tr("Spustit první běh", "Start the first run") : tr("Spustit běh", "Start a run"),
                           action: startRun)
                        .buttonStyle(OutlineButtonStyle(height: 34))
                        .padding(.top, 4)
                }
                .padding(28)
                .frame(width: 420)
                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                .padding(.top, 110)
            }
        }
    }

    private func ghost(hatched: Bool, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(hatched ? AnyShapeStyle(ImagePaint(image: Image(nsImage: Self.hatch), scale: 1)) : AnyShapeStyle(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .frame(height: height)
    }

    /// Šrafování obrysů karet (12 × 12 bodů, čára 1 bod).
    private static let hatch: NSImage = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
        NSColor.gray.withAlphaComponent(0.3).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0)); path.line(to: NSPoint(x: 12, y: 12))
        path.lineWidth = 1
        path.stroke()
        return true
    }
}

// MARK: - Rozložení

/// Řádek karet v poměrech šířek (jako `grid-template-columns: 1.35fr 1fr 0.8fr`), všechny stejně vysoké.
/// Když by nějaká karta byla užší než `minColumn`, karty se poskládají pod sebe.
/// Změřené výšky si pamatuje pro danou šířku (SwiftUI se ptá několikrát za průchod).
struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 12
    var minColumn: CGFloat = 190

    struct Cache {
        var width: CGFloat = -1
        var widths: [CGFloat]?        // nil = pod sebou
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func widths(_ total: CGFloat, _ n: Int) -> [CGFloat]? {
        let w = (0..<n).map { $0 < weights.count ? weights[$0] : 1 }
        let free = total - spacing * CGFloat(n - 1)
        let sum = w.reduce(0, +)
        let result = w.map { free * $0 / sum }
        return result.allSatisfy { $0 >= minColumn } ? result : nil
    }

    private func measure(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) {
        guard cache.width != width || cache.heights.count != subviews.count else { return }
        cache.width = width
        cache.widths = widths(width, subviews.count)
        if let ws = cache.widths {
            cache.heights = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        } else {
            cache.heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 900
        measure(width, subviews, &cache)
        if cache.widths != nil { return CGSize(width: width, height: cache.heights.max() ?? 0) }
        return CGSize(width: width, height: cache.heights.reduce(0, +) + spacing * CGFloat(max(0, cache.heights.count - 1)))
    }

    // Zarovnání podle obsahu karet se nepoužívá; bez toho by se SwiftUI ptalo každé karty zvlášť.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(bounds.width, subviews, &cache)
        if let ws = cache.widths {
            var x = bounds.minX
            for (view, w) in zip(subviews, ws) {
                view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
                x += w + spacing
            }
            return
        }
        var y = bounds.minY
        for (view, h) in zip(subviews, cache.heights) {
            view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h + spacing
        }
    }
}

// MARK: - Typy

enum PokeType {
    /// Obvyklé barvy typů (jako v Pokédexu).
    static func color(_ type: String) -> Color {
        let hex: [String: UInt32] = [
            "normal": 0xA8A77A, "fire": 0xEE8130, "water": 0x6390F0, "electric": 0xF7D02C, "grass": 0x7AC74C,
            "ice": 0x96D9D6, "fighting": 0xC22E28, "poison": 0xA33EA1, "ground": 0xE2BF65, "flying": 0xA98FF3,
            "psychic": 0xF95587, "bug": 0xA6B91A, "rock": 0xB6A136, "ghost": 0x735797, "dragon": 0x6F35FC,
            "dark": 0x705746, "steel": 0xB7B7CE, "fairy": 0xD685AD,
        ]
        let v = hex[type.lowercased()] ?? 0x9A9AA8
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
