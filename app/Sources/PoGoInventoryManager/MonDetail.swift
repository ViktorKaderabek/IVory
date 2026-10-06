import SwiftUI

/// One Pokémon from the storage, opened from the right over the screen – the same drawer the power-ups
/// use, only with what is known about a Pokémon in it. Clicking beside it closes it.

/// Which Pokémon has its detail open.
@MainActor
final class MonSelection: ObservableObject {
    static let shared = MonSelection()
    @Published private(set) var mon: InventoryStats.Mon?

    func open(_ mon: InventoryStats.Mon) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            self.mon = self.mon?.id == mon.id ? nil : mon
        }
    }

    func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { mon = nil }
    }

    func isOpen(_ other: InventoryStats.Mon) -> Bool { mon?.id == other.id }
}

/// The drawer over the Storage screen: the scrim and the panel.
struct MonDetailHost: View {
    let active: Bool
    @ObservedObject private var selection = MonSelection.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            if active, let mon = selection.mon {
                Color.oklch(0.1, 0.02, 278).opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.close() }
                    .transition(.opacity)
                MonDetailPanel(m: mon) { selection.close() }
                    .transition(.move(edge: .trailing))
            }
        }
    }
}

struct MonDetailPanel: View {
    let m: InventoryStats.Mon
    let close: () -> Void
    @EnvironmentObject private var store: ConfigStore

    static let width: CGFloat = 420

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            art
            VStack(alignment: .leading, spacing: 6) {
                Text(m.name)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(2)
                FlowRow(spacing: 6) {
                    ForEach(chips, id: \.0) { label, color in
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 7, height: 7)
                            Text(label).font(.system(size: 12))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raise))
                    }
                }
            }

            ivCard
            inTheGame
            if !m.ranks.isEmpty { ranks }
            if !m.tags.isEmpty { tagList }
            pokedex
            SearchCopyRow(text: m.gameName)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    // MARK: - Head

    private var art: some View {
        ZStack {
            RadialGradient(colors: [ivColor.opacity(0.35), Theme.bg], center: UnitPoint(x: 0.5, y: 0.7),
                           startRadius: 0, endRadius: 230)
            MonArtwork(m: m, size: 170)
        }
        .frame(height: 210)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -22)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(10)
        }
        .overlay(alignment: .topLeading) {
            if let headline {
                HStack(spacing: 6) {
                    Image(systemName: headline.1).font(.system(size: 11)).foregroundStyle(headline.2)
                    Text(headline.0).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
                .padding(12)
            }
        }
        .padding(.top, 24)      // clears the window's title bar
    }

    /// What makes this one worth looking at – the best thing we can say about it.
    private var headline: (String, String, Color)? {
        if m.pct == 100 { return (tr("Hundo 15/15/15", "Hundo 15/15/15"), "crown.fill", Theme.gold) }
        if let best = m.bestRank, best.rank <= 100 {
            let league = PvPLeague(rawValue: best.league)?.name ?? best.league
            return ("\(league) #\(number(best.rank))", "trophy.fill", Theme.accentInk)
        }
        if m.legendary { return (tr("Legendární", "Legendary"), "star.fill", Theme.gold) }
        if m.mythical { return (tr("Bájný", "Mythical"), "sparkles", Theme.pink) }
        if m.ultraBeast { return ("Ultra Beast", "globe", Theme.blue) }
        if m.pct >= 90 { return (percentText(m.pct) + " IV", "chart.bar.fill", Theme.green) }
        return nil
    }

    private var chips: [(String, Color)] {
        var out: [(String, Color)] = m.types.map { (BattleType.name($0), PokeType.color($0)) }
        if let gen = m.gen, gen - 1 < InventoryStats.regions.count {
            out.append((InventoryStats.regions[gen - 1], Theme.muted))
        }
        if m.canEvolve { out.append((tr("jde vyvinout", "can evolve"), Theme.green)) }
        return out
    }

    // MARK: - Blocks

    private var ivCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percentText(m.pct))
                    .font(.system(size: 30, weight: .medium).monospacedDigit())
                    .foregroundStyle(ivColor)
                Text(tr("součet \(m.iv.reduce(0, +)) ze 45", "\(m.iv.reduce(0, +)) of 45"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
            }
            VStack(spacing: 7) {
                ForEach(Array(zip([tr("Útok", "Attack"), tr("Obrana", "Defense"), "HP"], m.iv)), id: \.0) { label, v in
                    HStack(spacing: 10) {
                        Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(ivColor).frame(width: geo.size.width * Double(v) / 15)
                            }
                        }
                        .frame(height: 5)
                        Text("\(v)/15").font(.system(size: 12).monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ivColor.opacity(0.5), lineWidth: 1) }
    }

    private var inTheGame: some View {
        SectionBlock(title: tr("Ve hře", "In the game")) {
            HStack(spacing: 1) {
                cell("CP", number(m.cp))
                cell(tr("Úroveň", "Level"), m.levelText ?? "–")
                cell(tr("CP na L50", "CP at L50"), m.maxCP50.map(number) ?? "–")
            }
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var ranks: some View {
        SectionBlock(title: tr("PvP pořadí", "PvP rank")) {
            VStack(spacing: 0) {
                ForEach(Array(PvPLeague.allCases.enumerated()), id: \.element) { i, league in
                    if let rank = m.ranks[league.rawValue] {
                        HStack(spacing: 8) {
                            Circle().fill(leagueColor(league)).frame(width: 7, height: 7)
                            Text(league.name).font(.system(size: 13))
                            Spacer(minLength: 4)
                            LeagueRanks(mine: StatsStore.shared.stats?.place(of: m, in: league.rawValue),
                                        best: rank)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                    }
                }
            }
            .background(Theme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }

    private var tagList: some View {
        SectionBlock(title: tr("Tagy ve hře", "Tags in the game")) {
            FlowRow(spacing: 6) {
                ForEach(m.tags, id: \.self) { name in
                    HStack(spacing: 6) {
                        TagDot(color: tagColor(name), size: 7)
                        Text(name).font(.system(size: 12))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.raise))
                }
            }
        }
    }

    private var pokedex: some View {
        SectionBlock(title: "Pokédex") {
            VStack(spacing: 0) {
                factRow(tr("Číslo", "Number"), m.dex.map { "#\($0)" } ?? "–", first: true)
                if let gen = m.gen, gen - 1 < InventoryStats.regions.count {
                    factRow(tr("Region", "Region"), InventoryStats.regions[gen - 1])
                }
                if !m.types.isEmpty {
                    factRow(tr("Typ", "Type"), m.types.map(BattleType.name).joined(separator: " · "))
                }
                factRow(tr("Jméno ve hře", "Name in the game"), m.gameName)
                if let read = m.readAt {
                    factRow(tr("Poprvé přečten", "First read"), RunText.when(read))
                }
            }
            .background(Theme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }

    private func factRow(_ label: String, _ value: String, first: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(Theme.border).frame(height: 1) }
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bg.opacity(0.45))
    }

    private func leagueColor(_ league: PvPLeague) -> Color {
        (store.config.pvp.all.first { $0.key == league.rawValue }?.league.color ?? .purple).swatch
    }

    private func tagColor(_ name: String) -> Color {
        if name == store.config.removeTag { return store.config.removeTagColor.swatch }
        if let iv = store.config.ivTags.first(where: { $0.name == name }) { return iv.color.swatch }
        if let pvp = store.config.pvp.all.first(where: { $0.league.name == name }) { return pvp.league.color.swatch }
        return Theme.muted
    }

    /// The same reading as the IV tags: better Pokémon get a warmer bar.
    private var ivColor: Color {
        switch m.pct {
        case 100...: return Theme.gold
        case 90...: return Theme.green
        case 80...: return Theme.accent
        case 70...: return Theme.blue
        default: return Theme.muted
        }
    }
}
