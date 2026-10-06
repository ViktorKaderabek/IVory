import AppKit
import SwiftUI

// One Pokémon inside the Stats sheet: its row in the list, and the detail panel it opens.

/// A Pokémon in the list: type dot, name, label, IV %, region · level · CP and the IVs as three small bars.
struct MonRow: View {
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
            .background(selected ? Theme.tint : Theme.raise.opacity(hovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The selected Pokémon: species, type and region, IVs, CP and level, PvP ranks, tags, notes.
struct MonDetail: View {
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
                            if let r {
                                LeagueRanks(mine: stats.place(of: m, in: item.key), best: r)
                            } else {
                                Text("—").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.muted)
                            }
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

/// The Pokémon in the detail panel: the species' official render, downloaded once and kept.
struct GamePhoto: View {
    let m: InventoryStats.Mon
    static let width: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonArtwork(m: m, size: Self.width)
                .background(Theme.raise.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                }
            if m.dex == nil {
                Text(tr("Druh se nepodařilo určit, tak je tu jen písmeno.",
                        "The species couldn't be pinned down, so this is just its letter."))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.width)
    }
}

struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.accentInk)
            configuration.title
        }
    }
}
