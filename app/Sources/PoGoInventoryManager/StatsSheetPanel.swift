import AppKit
import SwiftUI

// The sheet the Stats screen opens over itself: the panel, how it slides in and how it closes.

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
            ZStack {
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
                    .shadow(color: Theme.softShadow, radius: 14, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
                    .transition(.modifier(active: SlideFade(y: 12, opacity: 0), identity: SlideFade(y: 0, opacity: 1)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: model.sheet)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .onChange(of: active) { _, on in if !on { model.close() } }
    }
}

struct SlideFade: ViewModifier {
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
        .shadow(color: Theme.panelShadow, radius: 30, y: 18)
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
struct Scrolling<Content: View>: View {
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

struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.muted)
                .frame(width: 30, height: 30)
                .background(Theme.raise.opacity(hovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("Zavřít (esc)", "Close (esc)"))
    }
}

/// The coverage window: how many Pokémon the numbers come from and why some lack the species.
struct CoverageContent: View {
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
