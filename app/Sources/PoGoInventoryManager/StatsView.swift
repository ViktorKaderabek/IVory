import SwiftUI

/// The Stats screen ("What IVory knows"), the "showcase" layout: three big numbers without frames on top
/// (Pokédex, IVs, hundos), the PvP hall of fame with pictures, the most common and rare species, and the
/// smaller distributions in one panel at the bottom. Every number, row, bar and picture opens a window with
/// the Pokémon behind it (StatsSheet.swift).
struct StatsView: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var statsStore = StatsStore.shared
    private let preloaded: InventoryStats?
    /// Empty state: switches to the overview and starts a run with the steps selected there.
    var startRun: () -> Void

    /// `preloaded` is only for windowless snapshots (nothing gets loaded there).
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
        VStack(alignment: .leading, spacing: 36) {
            header(s)
            WeightedRow(weights: [1, 1, 1], spacing: 16, minColumn: 230) {
                DexColumn(s: s)
                IVColumn(s: s)
                HundoColumn(s: s)
            }
            .padding(.horizontal, -20)      // the columns have no frame; their content lines up with the rest
            .padding(.vertical, -18)
            HallOfFame(s: s, pvp: store.config.pvp)
            WeightedRow(weights: [1, 1], spacing: 12, minColumn: 300) {
                TopSpeciesPanel(s: s)
                RarePanel(s: s)
            }
            DistributionPanel(s: s, config: store.config)
        }
    }

    private func header(_ s: InventoryStats) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Co IVory zná", "What IVory knows"))
                    .font(.system(size: 28, weight: .medium)).tracking(-0.56)
                CoverageLine(s: s)
            }
            Spacer(minLength: 12)
            if !s.runs.isEmpty { RunDots(runs: s.runs).frame(width: 300) }
        }
    }
}

/// The noun after a number: Czech has three forms (1, 2–4, the rest), English two.
private func noun(_ n: Int, _ one: String, _ few: String, _ many: String, en enOne: String, _ enMany: String) -> String {
    if L10n.lang == .en { return n == 1 ? enOne : enMany }
    return n == 1 ? one : (2...4).contains(n) ? few : many
}

@MainActor private func open(_ sheet: StatsSheet, select: Int? = nil) {
    StatsSheetModel.shared.open(sheet, select: select)
}

// MARK: - Building blocks

/// A row that opens its own window: highlighted on hover.
private struct RowButton<Label: View>: View {
    var hover: Color = Theme.raise
    var horizontal: CGFloat = 6
    var vertical: CGFloat = 3
    var radius: CGFloat = 6
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, horizontal).padding(.vertical, vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? hover : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -horizontal)
        .onHover { hovering = $0 }
    }
}

/// A link in the accent color, underlined on hover.
private struct TextLink: View {
    let text: String
    var arrow = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text).underline(hovering)
                if arrow { Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(Theme.accentInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "12 more ▾" / "Hide ▴" under a list that doesn't show everything at first.
private struct MoreButton: View {
    let open: Bool
    let more: String
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 5) {
                Text(open ? tr("Skrýt", "Hide") : more)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle(height: 24))
        .padding(.leading, -10)
    }
}

/// Horizontal meter (a share, or a bar in a chart).
private struct Meter: View {
    let fraction: Double
    var height: CGFloat = 10
    var color: Color = Theme.accent
    var glow = false
    var radius: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius ?? height / 2, style: .continuous).fill(Theme.track)
                RoundedRectangle(cornerRadius: radius ?? height / 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(fraction > 0 ? min(height, 4) : 0, geo.size.width * min(1, max(0, fraction))))
                    .shadow(color: glow ? color.opacity(0.9) : .clear, radius: 5)
            }
        }
        .frame(height: height)
    }
}

/// A dark bubble above a bar, a dot or a picture while the mouse is over it.
private struct Tip: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.bg).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.text, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// A panel with a thin border (everything below the three big numbers).
private struct Panel<Content: View>: View {
    var padding = EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct PanelTitle: View {
    let title: String
    var sub: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .medium))
            if let sub { Text(sub).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1) }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Header

/// "From 423 Pokémon read, the species is known for 278 ⓘ": opens the coverage window.
private struct CoverageLine: View {
    let s: InventoryStats
    @State private var hovering = false

    var body: some View {
        Button { open(.coverage) } label: {
            HStack(spacing: 6) {
                Text(tr("Z \(number(s.total)) přečtených kusů, druh známe u \(number(s.withSpecies))",
                        "From \(number(s.total)) Pokémon read, the species is known for \(number(s.withSpecies))"))
                Image(systemName: "info.circle").font(.system(size: 12))
            }
            .font(.system(size: 13)).monospacedDigit()
            .foregroundStyle(hovering ? Theme.text : Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("Z čeho čísla jsou", "What the numbers come from"))
    }
}

/// Run history as a line of dots, the last run bigger; hovering a dot shows that run below, a click lists
/// the Pokémon it read for the first time.
private struct RunDots: View {
    let runs: [InventoryStats.Run]
    @State private var hovered: String?

    var body: some View {
        let recent = Array(runs.suffix(30))
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(recent) { run in
                    let last = run.id == runs.last?.id
                    let on = hovered == run.id
                    HStack(spacing: 0) {
                        Circle()
                            .fill(last || on ? Theme.accent : Theme.accent.opacity(0.5))
                            .frame(width: last || on ? 11 : 6, height: last || on ? 11 : 6)
                            .shadow(color: last || on ? Theme.accent.opacity(0.9) : .clear, radius: 5)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                            .onTapGesture { open(.run(run.id)) }
                            .onHover { hovered = $0 ? run.id : (hovered == run.id ? nil : hovered) }
                            .padding(.horizontal, -3)
                        if !last { Rectangle().fill(Theme.track).frame(height: 2).frame(maxWidth: .infinity) }
                    }
                    .frame(maxWidth: last ? 8 : .infinity)
                }
            }
            .frame(height: 18)
            .animation(.easeOut(duration: 0.15), value: hovered)
            Text(info).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
        }
    }

    private var info: String {
        guard let i = runs.firstIndex(where: { $0.id == hovered }) ?? (runs.isEmpty ? nil : runs.count - 1) else { return "" }
        let run = runs[i]
        var parts = [i == runs.count - 1 && hovered == nil
                     ? trCount(runs.count, cs: "běh", "běhy", "běhů", en: "run", "runs") + tr(" · poslední ", " · last ") + RunText.when(run.date)
                     : tr("Běh \(i + 1) · ", "Run \(i + 1) · ") + RunText.when(run.date)]
        if let n = run.checked { parts.append(tr("\(number(n)) prošlo", "\(number(n)) checked")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The three big numbers

/// One of the three columns on top: no frame, a background only on hover; a click opens its window
/// (bars, pictures and links inside open their own).
private struct HeroColumn<Content: View>: View {
    let symbol: String
    let title: String
    var symbolColor: Color = Theme.accentInk
    var hoverFill: AnyShapeStyle = AnyShapeStyle(Theme.surface)
    let sheet: StatsSheet
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(symbolColor)
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            content
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hovering ? hoverFill : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { open(sheet) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The big number with its caption.
private struct BigNumber: View {
    let value: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value).font(.system(size: 68, weight: .medium)).tracking(-3).monospacedDigit()
            Text(caption).font(.system(size: 16)).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .lineLimit(1)   // no minimumScaleFactor: shrinking the font is measured repeatedly and is expensive
        .padding(.vertical, -7)    // the line height of a 68-point font leaves too much air
    }
}

private struct Footnote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

private struct DexColumn: View {
    let s: InventoryStats
    @State private var hovered: Int?

    var body: some View {
        HeroColumn(symbol: "books.vertical", title: "Pokédex", sheet: .dex) {
            BigNumber(value: "\(s.dexOwned)", caption: tr("z \(number(s.dexTotal)) druhů", "of \(number(s.dexTotal)) species"))
            Meter(fraction: Double(s.dexOwned) / Double(max(1, s.dexTotal)), height: 4, glow: true, radius: 2)
            let top = max(1, s.generations.max() ?? 1)
            let best = s.generations.firstIndex(of: top) ?? 0
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<9, id: \.self) { i in
                    let on = hovered == i
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(on || i == best ? Theme.accent : Theme.accent.opacity(0.5))
                        .shadow(color: on ? Theme.accent.opacity(0.9) : .clear, radius: 6)
                        .frame(height: max(3, 52 * CGFloat(s.generations[i]) / CGFloat(top)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if on {
                                Tip(text: tr("\(InventoryStats.regions[i]) · \(s.generations[i]) z \(s.generationTotals[i]) druhů",
                                             "\(InventoryStats.regions[i]) · \(s.generations[i]) of \(s.generationTotals[i]) species"))
                                    .offset(y: -26)
                            }
                        }
                        .zIndex(on ? 1 : 0)
                        .onTapGesture { open(.region(i)) }
                        .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                }
            }
            .frame(height: 52)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .zIndex(1)
            Spacer(minLength: 0)
            Footnote(text: footnote(best: best))
        }
    }

    private func footnote(best: Int) -> String {
        var parts = [tr("Nejvíc z \(InventoryStats.regions[best])", "Most from \(InventoryStats.regions[best])")]
        if s.newSpecies > 0 {
            let today = s.runs.last.map { Calendar.current.isDateInToday($0.date) } ?? false
            let n = s.newSpecies
            parts.append(today
                         ? noun(n, "dnes přibyl \(n) druh", "dnes přibyly \(n) druhy", "dnes přibylo \(n) druhů",
                                en: "\(n) new species today", "\(n) new species today")
                         : noun(n, "poslední běh přidal \(n) druh", "poslední běh přidal \(n) druhy", "poslední běh přidal \(n) druhů",
                                en: "the last run added \(n) species", "the last run added \(n) species"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct IVColumn: View {
    let s: InventoryStats
    @State private var hovered: Int?

    var body: some View {
        HeroColumn(symbol: "chart.bar.xaxis", title: tr("Průměrné IV", "Average IV"), sheet: .iv) {
            BigNumber(value: percentText(s.ivAverage),
                      caption: tr("u ", "of ") + trCount(s.total, cs: "kusu", "kusů", "kusů", en: "Pokémon", "Pokémon"))
            let bins = Array(s.ivBins.enumerated()).filter { $0.element.count > 0 }
            GeometryReader { geo in
                let free = geo.size.width - 3 * CGFloat(max(0, bins.count - 1))
                HStack(spacing: 3) {
                    ForEach(bins, id: \.offset) { i, bin in
                        let on = hovered == i
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(StatsColors.bin(bin.lower))
                            .frame(width: max(6, free * CGFloat(bin.count) / CGFloat(max(1, s.total))))
                            .opacity(hovered == nil || on ? 1 : 0.4)
                            .overlay(alignment: .top) {
                                if on {
                                    Tip(text: ivBinLabel(bin.lower) + " · " + trCount(bin.count, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon"))
                                        .offset(y: -28)
                                }
                            }
                            .zIndex(on ? 1 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture { open(.ivBin(i)) }
                            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                    }
                }
            }
            .frame(height: 14)
            .padding(.top, 4)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .zIndex(1)
            HStack {
                Text(tr("90 % a víc", "90% or more"))
                Spacer()
                Text(tr("pod 70 %", "under 70%"))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            let top = s.ivBins.first?.count ?? 0
            Footnote(text: noun(top, "\(top) kus má 90 % a víc.", "\(top) kusy mají 90 % a víc.", "\(number(top)) kusů má 90 % a víc.",
                                en: "\(top) Pokémon is at 90% or more.", "\(number(top)) Pokémon are at 90% or more.")
                     + tr(" Slabé kusy se průběžně mažou.", " Weak ones keep getting deleted."))
        }
    }
}

private struct HundoColumn: View {
    let s: InventoryStats
    @State private var hovered: Int?
    @State private var all = false
    static let shown = 16

    var body: some View {
        let gold = StatsColors.gold
        HeroColumn(symbol: "crown.fill", title: "Hundo 15/15/15", symbolColor: gold,
                   hoverFill: AnyShapeStyle(LinearGradient(colors: [gold.opacity(0.14), Theme.surface], startPoint: .topLeading,
                                                           endPoint: UnitPoint(x: 0.75, y: 0.9))),
                   sheet: .hundo) {
            BigNumber(value: "\(s.hundos.count)",
                      caption: noun(s.hundos.count, "kus se 100 %", "kusy se 100 %", "kusů se 100 %", en: "at 100%", "at 100%"))
            if !s.hundos.isEmpty {
                FlowRow(spacing: 8) {
                    ForEach(all ? s.hundos : Array(s.hundos.prefix(Self.shown))) { m in
                        let on = hovered == m.id
                        MonIcon(m: m, size: 38, circle: true, ring: on ? gold : StatsColors.goldTint)
                            .overlay(alignment: .topTrailing) {
                                if m.isNew {
                                    Circle().fill(Theme.green).frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                        .offset(x: 2, y: -2)
                                }
                            }
                            .overlay(alignment: .top) {
                                if on { Tip(text: m.name).offset(y: -28) }
                            }
                            .zIndex(on ? 1 : 0)
                            .contentShape(Circle())
                            .onTapGesture { open(.hundo, select: m.id) }
                            .onHover { hovered = $0 ? m.id : (hovered == m.id ? nil : hovered) }
                    }
                    if s.hundos.count > Self.shown {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { all.toggle() }
                        } label: {
                            Group {
                                if all { Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)) }
                                else { Text("+\(s.hundos.count - Self.shown)").font(.system(size: 12, weight: .semibold)).monospacedDigit() }
                            }
                            .foregroundStyle(gold)
                            .frame(width: 38, height: 38)
                            .overlay(Circle().stroke(StatsColors.goldTint, lineWidth: 2))
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(all ? tr("Skrýt", "Hide") : tr("Ukázat všechny", "Show all"))
                    }
                }
                .padding(.top, 4)
                .zIndex(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if let fresh = s.hundos.first(where: \.isNew) {
                    let today = s.runs.last.map { Calendar.current.isDateInToday($0.date) } ?? false
                    Text(today ? tr("\(fresh.name) přibyl dnes · ", "\(fresh.name) arrived today · ")
                               : tr("\(fresh.name) přibyl v posledním běhu · ", "\(fresh.name) arrived in the last run · "))
                        .foregroundStyle(Theme.muted)
                } else if s.hundos.isEmpty {
                    Text(tr("Zatím žádný · ", "None yet · ")).foregroundStyle(Theme.muted)
                }
                TextLink(text: noun(s.nearPerfect, "\(s.nearPerfect) kus s 98 % a víc", "\(s.nearPerfect) kusy s 98 % a víc",
                                    "\(s.nearPerfect) kusů s 98 % a víc", en: "\(s.nearPerfect) at 98% or more", "\(s.nearPerfect) at 98% or more")) {
                    open(.nearPerfect)
                }
            }
            .font(.system(size: 13)).lineLimit(1)
        }
    }
}

// MARK: - PvP hall of fame

/// For each league the Pokémon with rank 1 (the best IVs for that league there are), with pictures;
/// a league without one gets a dashed tile.
private struct HallOfFame: View {
    let s: InventoryStats
    let pvp: PvPConfig
    @State private var all = false
    static let columns = 6

    private enum Cell {
        case tile(key: String, m: InventoryStats.Mon)
        case empty(String)
        var id: String {
            switch self {
            case .tile(let key, let m): return "\(key)-\(m.id)"
            case .empty(let key): return "empty-" + key
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tr("Síň slávy PvP", "PvP hall of fame")).font(.system(size: 19, weight: .medium)).tracking(-0.2)
                Text(tr("nejlepší možné IV pro ligu", "the best possible IVs for the league"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                if s.ranked > 0 {
                    TextLink(text: tr("Všech \(number(s.ranked)) kusů s pořadím", "All \(number(s.ranked)) ranked Pokémon"), arrow: true) {
                        open(.pvp)
                    }
                    .font(.system(size: 13, weight: .medium))
                }
            }
            let lay = layout()
            let rows = stride(from: 0, to: lay.cells.count, by: Self.columns).map { Array(lay.cells[$0..<min($0 + Self.columns, lay.cells.count)]) }
            VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    WeightedRow(weights: Array(repeating: 1, count: Self.columns), spacing: 12, minColumn: 0) {
                        ForEach(row, id: \.id) { cell in
                            switch cell {
                            case .tile(let key, let m):
                                LeagueTile(m: m, key: key, league: league(key))
                            case .empty(let key):
                                EmptyLeagueTile(key: key, league: league(key),
                                                best: s.mons.compactMap { m in m.ranks[key].map { (m, $0) } }.min { $0.1 < $1.1 })
                            }
                        }
                        ForEach(0..<(Self.columns - row.count), id: \.self) { _ in Color.clear }
                    }
                }
            }
            if lay.hidden > 0 || all {
                MoreButton(open: all, more: noun(lay.hidden, "Další \(lay.hidden) s pořadím 1", "Další \(lay.hidden) s pořadím 1",
                                                 "Dalších \(lay.hidden) s pořadím 1", en: "\(lay.hidden) more at rank 1",
                                                 "\(lay.hidden) more at rank 1")) { all.toggle() }
                    .padding(.top, -6)
            }
        }
    }

    private func league(_ key: String) -> League { pvp.all.first { $0.key == key }?.league ?? pvp.great }

    /// Rank-1 tiles taken from the leagues in turns (so every league with one shows up), then a tile for each
    /// league with none. One row at first; expanded, every rank-1 Pokémon.
    private func layout() -> (cells: [Cell], hidden: Int) {
        // one tile per species in a league; a Pokémon under every CP cap can be #1 in several leagues
        let firsts = pvp.all.map { item in
            var seen = Set<String>()
            return (item.key, s.mons.filter { $0.ranks[item.key] == 1 }
                .sorted { $0.isNew != $1.isNew ? $0.isNew : ($0.pct, $0.cp) > ($1.pct, $1.cp) }
                .filter { seen.insert($0.name).inserted })
        }
        let empty = firsts.filter { $0.1.isEmpty }.map { $0.0 }
        let total = firsts.reduce(0) { $0 + $1.1.count }
        let room = all ? total : Self.columns - empty.count
        var picked: [String: Int] = [:]
        var count = 0
        var round = 0
        while count < room && firsts.contains(where: { $0.1.count > round }) {
            for (key, list) in firsts where list.count > round && count < room {
                picked[key, default: 0] += 1
                count += 1
            }
            round += 1
        }
        let tiles = firsts.flatMap { key, list in list.prefix(picked[key] ?? 0).map { Cell.tile(key: key, m: $0) } }
        return (tiles + empty.map(Cell.empty), total - count)
    }
}

private struct LeagueTile: View {
    let m: InventoryStats.Mon
    let key: String
    let league: League
    @State private var hovering = false

    var body: some View {
        Button { open(.league(key), select: m.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    Theme.raise
                    Group {
                        if let img = MonImages.icon(m) {
                            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        } else {
                            MonLetter(m: m, size: 128)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    HStack(spacing: 5) {
                        Circle().fill(league.color.swatch).frame(width: 7, height: 7)
                        Text("#1").font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Theme.bg.opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(8)
                }
                .frame(height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(league.name).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? Theme.accent : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(m.name) · \(percentText(m.pct)) · \(number(m.cp)) CP")
    }
}

private struct EmptyLeagueTile: View {
    let key: String
    let league: League
    let best: (InventoryStats.Mon, Int)?
    @State private var hovering = false

    var body: some View {
        Button { open(.league(key), select: best?.0.id) } label: {
            VStack(spacing: 6) {
                Circle().fill(league.color.swatch).frame(width: 9, height: 9)
                Text(league.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(tr("zatím nikdo s #1", "no one at #1 yet")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let best {
                    Text(tr("nejlépe #\(best.1) \(best.0.name)", "best #\(best.1) \(best.0.name)"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Species

private struct TopSpeciesPanel: View {
    let s: InventoryStats
    @State private var all = false
    static let shown = 3

    var body: some View {
        Panel {
            PanelTitle(title: tr("Nejčastější druh", "Most common species"), sub: tr("víc kusů téhož", "several of the same"))
            let dupes = s.topSpecies.filter { $0.count > 1 }
            let top = all ? dupes : Array(dupes.prefix(Self.shown))
            ForEach(top) { item in
                let copies = s.mons.filter { $0.species == item.name }
                let best = copies.max { ($0.pct, $0.cp) < ($1.pct, $1.cp) }
                let tagged = copies.filter { $0.tags.contains(s.removeTag) }.count
                RowButton(horizontal: 10, vertical: 6, radius: 10, action: { open(.species(item.name)) }) {
                    HStack(spacing: 12) {
                        if let best { MonIcon(m: best, size: 44, circle: true) }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text(sub(best, tagged)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text("\(item.count)×").font(.system(size: 22, weight: .medium)).tracking(-0.4).monospacedDigit()
                    }
                }
            }
            if dupes.count > Self.shown {
                let n = dupes.count - Self.shown
                MoreButton(open: all, more: noun(n, "Další \(n) druh", "Další \(n) druhy", "Dalších \(n) druhů",
                                                 en: "\(n) more species", "\(n) more species")) { all.toggle() }
                    .padding(.top, 2)
            }
            if top.isEmpty {
                Text(s.withSpecies == 0 ? tr("Ukáže se, až bot pozná druh.", "Shows up once the bot knows the species.")
                                        : tr("Od každého druhu máš jen jeden kus.", "You have just one of each species."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func sub(_ best: InventoryStats.Mon?, _ tagged: Int) -> String {
        var parts: [String] = []
        if let best { parts.append(tr("nejlepší ", "best ") + percentText(best.pct)) }
        if tagged > 0 { parts.append(tr("\(tagged) s tagem \(s.removeTag)", "\(tagged) tagged \(s.removeTag)")) }
        return parts.joined(separator: " · ")
    }
}

private struct RarePanel: View {
    let s: InventoryStats
    @State private var all = false

    var body: some View {
        Panel {
            PanelTitle(title: tr("Vzácné", "Rare"),
                       sub: tr("z \(number(s.withSpecies)) kusů se známým druhem", "of \(number(s.withSpecies)) with known species"))
            row("star.fill", tr("Legendy", "Legendary"), s.legendary, Theme.yellow, Theme.yellowTint, "legendary", \.legendary)
            row("globe.americas.fill", "Ultra beasts", s.ultraBeast, Theme.blue, Theme.blueTint, "ultrabeast", \.ultraBeast)
            row("sparkle", tr("Mýtičtí", "Mythical"), s.mythical, Theme.pink, Theme.pinkTint, "mythical", \.mythical)
            let species = rareSpecies
            if !species.isEmpty {
                if all {
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 6)
                    ForEach(species, id: \.name) { sp in
                        RowButton(horizontal: 10, vertical: 3, radius: 8, action: { open(.species(sp.name)) }) {
                            HStack(spacing: 10) {
                                MonIcon(m: sp.best, size: 30, circle: true)
                                Text(sp.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Image(systemName: sp.symbol).font(.system(size: 10)).foregroundStyle(sp.color)
                                Spacer(minLength: 6)
                                Text(tr("nejlepší ", "best ") + percentText(sp.best.pct)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                Text("\(sp.count)×").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                    .frame(minWidth: 32, alignment: .trailing)
                            }
                        }
                    }
                }
                MoreButton(open: all, more: noun(species.count, "Ukázat \(species.count) druh", "Ukázat všechny \(species.count) druhy",
                                                 "Ukázat všech \(species.count) druhů", en: "Show the \(species.count) species",
                                                 "Show all \(species.count) species")) { all.toggle() }
                    .padding(.top, 2)
            }
        }
    }

    /// Every rare species once: how many you have and the best one, the most frequent first.
    private var rareSpecies: [(name: String, count: Int, best: InventoryStats.Mon, symbol: String, color: Color)] {
        let rare = s.mons.filter { $0.legendary || $0.ultraBeast || $0.mythical }
        return Dictionary(grouping: rare, by: \.name).compactMap { name, list in
            guard let best = list.max(by: { ($0.pct, $0.cp) < ($1.pct, $1.cp) }) else { return nil }
            let (symbol, color): (String, Color) = best.ultraBeast ? ("globe.americas.fill", Theme.blue)
                : best.mythical ? ("sparkle", Theme.pink) : ("star.fill", Theme.yellow)
            return (name, list.count, best, symbol, color)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private func row(_ symbol: String, _ label: String, _ n: Int, _ fg: Color, _ bg: Color, _ kind: String,
                     _ flag: KeyPath<InventoryStats.Mon, Bool>) -> some View {
        // one face per species, the best ones first
        var seen = Set<String>()
        let faces = s.mons.filter { $0[keyPath: flag] }.sorted { ($0.pct, $0.cp) > ($1.pct, $1.cp) }
            .filter { seen.insert($0.name).inserted }.prefix(3)
        return RowButton(horizontal: 10, vertical: 6, radius: 10, action: { open(.rare(kind)) }) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(fg)
                    .frame(width: 44, height: 44).background(bg, in: Circle())
                Text(label).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: -8) {
                    ForEach(Array(faces)) { m in
                        MonIcon(m: m, size: 30, circle: true, ring: Theme.surface)
                    }
                }
                Text("\(n)").font(.system(size: 22, weight: .medium)).tracking(-0.4).monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Distributions

/// Types, levels and tags as small bar charts, and three more numbers on the right.
private struct DistributionPanel: View {
    let s: InventoryStats
    let config: AppConfig
    @State private var allTypes = false
    @State private var allTags = false
    static let types = 6
    static let tags = 5

    var body: some View {
        WeightedRow(weights: [1, 1, 1, 0.9], spacing: 32, minColumn: 150) {
            column(tr("Typy", "Types")) {
                let top = max(1, s.types.first?.count ?? 1)
                ForEach(allTypes ? s.types : Array(s.types.prefix(Self.types))) { t in
                    bar(t.name.capitalized, t.count, top, PokeType.color(t.name), labelWidth: 62) { open(.type(t.name)) }
                }
                if s.types.count > Self.types {
                    let n = s.types.count - Self.types
                    MoreButton(open: allTypes, more: noun(n, "Další \(n) typ", "Další \(n) typy", "Dalších \(n) typů",
                                                          en: "\(n) more type", "\(n) more types")) { allTypes.toggle() }
                        .padding(.top, 4)
                }
                if s.types.isEmpty { empty }
            }
            column(tr("Úrovně", "Levels")) {
                let top = max(1, s.levels.map(\.count).max() ?? 1)
                ForEach(Array(s.levels.enumerated()), id: \.offset) { i, l in
                    bar(l.label, l.count, top, Theme.accent, labelWidth: 52) { open(.level(i)) }
                }
                if s.levels.isEmpty { empty }
            }
            column(tr("Tagy ve hře", "Tags in the game")) {
                let tags = allTags ? s.tags : Array(s.tags.prefix(Self.tags))
                let top = max(1, tags.first?.count ?? 1)
                ForEach(tags) { t in
                    bar(t.name, t.count, top, StatsTagColor.of(t.name, config), labelWidth: 96) { open(.tag(t.name)) }
                }
                if s.tags.count > Self.tags {
                    let n = s.tags.count - Self.tags
                    MoreButton(open: allTags, more: noun(n, "Další \(n) tag", "Další \(n) tagy", "Dalších \(n) tagů",
                                                         en: "\(n) more tag", "\(n) more tags")) { allTags.toggle() }
                        .padding(.top, 4)
                }
                if tags.isEmpty {
                    Text(tr("Zatím bez tagů", "No tags yet")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                more(tr("Nejsilnější", "Strongest"), number(s.topCP?.cp ?? 0), "CP" + (s.topCP.map { " · " + $0.name } ?? ""), .strong)
                more(tr("Ještě vyvinout", "Still to evolve"), number(s.canEvolve),
                     noun(s.canEvolve, "kus", "kusy", "kusů", en: "Pokémon", "Pokémon"), .evolve)
                more(tr("Duplicity", "Duplicates"), number(s.duplicateSpecies),
                     noun(s.duplicateSpecies, "druh", "druhy", "druhů", en: "species", "species")
                        + (s.removable > 0 ? " · \(number(s.removable)) \(s.removeTag)" : ""), .duplicates)
            }
            .padding(.leading, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
        }
        .padding(EdgeInsets(top: 18, leading: 22, bottom: 20, trailing: 22))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }

    private var empty: some View {
        Text(tr("Ukáže se, až bot pozná druh.", "Shows up once the bot knows the species.")).font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .medium)).padding(.bottom, 8)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bar(_ label: String, _ n: Int, _ top: Int, _ color: Color, labelWidth: CGFloat, action: @escaping () -> Void) -> some View {
        RowButton(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).monospacedDigit().lineLimit(1).frame(width: labelWidth, alignment: .leading)
                Meter(fraction: Double(n) / Double(top), height: 6, color: color, radius: 3)
                Text("\(n)").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().frame(minWidth: 24, alignment: .trailing)
            }
        }
    }

    private func more(_ label: String, _ value: String, _ sub: String, _ sheet: StatsSheet) -> some View {
        RowButton(horizontal: 8, vertical: 6, radius: 8, action: { open(sheet) }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(.system(size: 22, weight: .medium)).tracking(-0.4).monospacedDigit()
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Run texts

enum RunText {
    /// "today 14:32", "yesterday 9:05", otherwise "2. 10. 21:16".
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

// MARK: - Empty state

private struct EmptyStats: View {
    let runs: Int
    var startRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Co IVory zná", "What IVory knows")).font(.system(size: 28, weight: .medium)).tracking(-0.56)
                Text(runs == 0 ? tr("Zatím žádný běh", "No runs yet") : tr("Paměť je zatím prázdná", "The memory is still empty"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ZStack(alignment: .top) {
                VStack(spacing: 12) {
                    WeightedRow(weights: [1, 1, 1], minColumn: 0) {
                        ghost(hatched: true, 200); ghost(hatched: true, 200); ghost(hatched: true, 200)
                    }
                    WeightedRow(weights: Array(repeating: 1, count: 6), minColumn: 0) {
                        ForEach(0..<6, id: \.self) { _ in ghost(hatched: false, 170) }
                    }
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

    /// Hatching for the card outlines (12 × 12 points, 1-point line).
    private static let hatch: NSImage = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
        NSColor.gray.withAlphaComponent(0.3).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0)); path.line(to: NSPoint(x: 12, y: 12))
        path.lineWidth = 1
        path.stroke()
        return true
    }
}

// MARK: - Layout

/// A row of cards with width ratios (like `grid-template-columns: 1.35fr 1fr 0.8fr`), all the same height.
/// If any card would be narrower than `minColumn`, the cards stack vertically instead.
/// Caches the measured heights for a given width (SwiftUI asks several times per layout pass).
struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 12
    var minColumn: CGFloat = 190

    struct Cache {
        var width: CGFloat = -1
        var widths: [CGFloat]?        // nil = stacked
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

    // Alignment by card content isn't used; without these SwiftUI would query every card separately.
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

// MARK: - Types

enum PokeType {
    /// The usual type colors (as in the Pokédex).
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
