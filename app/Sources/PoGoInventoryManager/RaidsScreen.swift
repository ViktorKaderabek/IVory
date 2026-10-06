import AppKit
import SwiftUI

/// Raids: the bosses that are up now as a strip of tiles, and for the one picked, the chance of winning
/// and the best six from the storage as cards. The strongest is the first card.
struct RaidsScreen: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var battle = BattleStore.shared
    @ObservedObject private var statsStore = StatsStore.shared
    var startRun: () -> Void

    @ObservedObject private var state = RaidsScreenState.shared
    @State private var copied = false

    private var mons: [InventoryStats.Mon] { statsStore.stats?.mons ?? [] }

    private var boss: RaidBoss? {
        battle.bosses.first { $0.id == state.bossID } ?? defaultBoss
    }

    /// The first 5★ boss – that is what people open this screen for – otherwise the first one listed.
    private var defaultBoss: RaidBoss? {
        battle.bosses.first { $0.tier == .t5 } ?? battle.bosses.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let stats = statsStore.stats, stats.isEmpty {
                NeverRun(startRun: startRun)
            } else if battle.bosses.isEmpty {
                Color.clear.frame(height: 200)
            } else {
                bossStrip
                if let boss {
                    bossHead(boss)
                    WeightedColumns(weights: [0, 1], spacing: 16, fixed: [290, nil]) {
                        leftColumn(boss)
                        party(boss)
                    }
                }
            }
        }
        .onAppear {
            battle.appear()
            if state.bossID == nil { state.bossID = battle.focusBoss ?? defaultBoss?.id }
            battle.focusBoss = nil
        }
        .onChange(of: battle.focusBoss) { _, name in
            guard let name else { return }
            state.bossID = name
            state.weather = "none"
            state.players = nil
            battle.focusBoss = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Raidy", "Raids")).font(.system(size: 26, weight: .medium))
            Text(tr("Nejlepší šestice z tvého úložiště proti aktuálním bossům", "The best six from your storage against the current bosses")
                 + (battle.bossesAt.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - The bosses

    private var bossStrip: some View {
        // full bleed: the page's own 28 pt of padding is cancelled here and put back inside, so the strip
        // scrolls right up to the edge of the window instead of stopping short of it
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(RaidTier.allCases, id: \.self) { tier in
                    let list = battle.bosses.filter { $0.tier == tier }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tier.label.uppercased())
                                .font(.system(size: 11, weight: .medium)).kerning(0.6)
                                .foregroundStyle(Theme.muted)
                            HStack(spacing: 8) {
                                ForEach(list) { b in BossTile(boss: b, selected: b.id == boss?.id) {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        state.bossID = b.id
                                        state.weather = "none"
                                        state.players = nil
                                    }
                                } }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, -28)
    }

    private func bossHead(_ b: RaidBoss) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(b.name).font(.system(size: 24, weight: .medium)).lineLimit(1)
                    chip(b.tier.label)
                    ForEach(b.types, id: \.self) { t in
                        HStack(spacing: 6) {
                            Circle().fill(BattleType.color(t)).frame(width: 7, height: 7)
                            Text(BattleType.name(t)).font(.system(size: 12))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raise))
                    }
                }
                Text(catchLine(b))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            weatherPicker(b)
        }
        .padding(.top, 20)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raise))
    }

    private func catchLine(_ b: RaidBoss) -> String {
        var parts: [String] = []
        if !b.weather.isEmpty {
            parts.append(tr("Posiluje ho \(BattleFormat.list(b.weather))", "Boosted by \(BattleFormat.list(b.weather))"))
        }
        if let cp = b.cp {
            var s = tr("chytíš za \(number(cp.lowerBound))–\(number(cp.upperBound)) CP",
                       "catch CP \(number(cp.lowerBound))–\(number(cp.upperBound))")
            if let boosted = b.cpBoosted {
                s += tr(", s počasím \(number(boosted.lowerBound))–\(number(boosted.upperBound))",
                        ", with weather \(number(boosted.lowerBound))–\(number(boosted.upperBound))")
            }
            parts.append(s)
        }
        return parts.joined(separator: " · ")
    }

    /// No weather, or one of the kinds that boost this boss's counters.
    private func weatherPicker(_ b: RaidBoss) -> some View {
        let options = ["none"] + b.weather
        return HStack(spacing: 2) {
            ForEach(options, id: \.self) { w in
                Button { withAnimation(.easeOut(duration: 0.15)) { state.weather = w } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: w == "none" ? "minus.circle" : BattleWeather.symbol(w))
                            .font(.system(size: 12))
                        Text(w == "none" ? tr("Bez počasí", "No weather") : BattleWeather.name(w))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(state.weather == w ? Theme.text : Theme.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.raise.opacity(state.weather == w ? 1 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }

    // MARK: - Win chance and the in-game search

    private func leftColumn(_ b: RaidBoss) -> some View {
        let result = battle.counters(b, weather: state.weather, mons: mons)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tr("Šance na výhru", "Win chance")).font(.system(size: 17, weight: .medium))
                Text(tr("kolik vás musí jít", "how many of you it takes"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            WinChance(chances: result?.chances, players: $state.players, shadow: b.tier.isShadow)
            if let counters = result?.counters, !counters.isEmpty {
                searchCard(counters)
            }
        }
    }

    private func searchCard(_ counters: [RaidCounter]) -> some View {
        var seen = Set<String>()
        // their nicknames, not the species: that way the search picks out these very Pokémon and not
        // every Tinkatink in the storage
        let query = counters.prefix(6)
            .map { $0.mon.gameName.isEmpty ? $0.mon.name : $0.mon.gameName }
            .filter { seen.insert($0).inserted }
            .joined(separator: ",")
        return VStack(alignment: .leading, spacing: 6) {
            Text(tr("Hledání ve hře", "Search in the game"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(query)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(query, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                    Text(copied ? tr("Zkopírováno", "Copied") : tr("Kopírovat", "Copy"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    // MARK: - The six

    private func party(_ b: RaidBoss) -> some View {
        let counters = Array((battle.counters(b, weather: state.weather, mons: mons)?.counters ?? []).prefix(6))
        let best = counters.first?.strength ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tr("Tvoje nejlepší šestice", "Your best six")).font(.system(size: 17, weight: .medium))
                Text(tr("nejsilnější napřed", "strongest first")).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            if counters.isEmpty {
                Text(tr("Proti tomuhle bossovi nemáš v úložišti nic použitelného.",
                        "You have nothing usable against this boss in your storage."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(Array(counters.enumerated()), id: \.offset) { i, c in
                        PartyCard(c: c, rank: i + 1, share: best > 0 ? c.strength / best : 0)
                            .entrance(0.06 * Double(i))
                    }
                }
            }
        }
    }
}
