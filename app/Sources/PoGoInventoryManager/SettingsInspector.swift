import AppKit
import SwiftUI

/// Settings panel that slides in from the right: the essentials on top, the rest under "Advanced",
/// save status in the footer.
struct SettingsInspector: View {
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SettingsContent()
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            SaveFooter()
        }
        .background(Theme.chrome)
        .foregroundStyle(Theme.text)
    }
}

struct SettingsContent: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @State private var devices: [DeviceTools.Device] = []
    @State private var message: String?
    @State private var messageKind = MessageKind.info
    @State private var proposedTeam: String?
    @State private var busy = false
    @State private var editorOpen = false
    @State private var lastBox = LastBox.load()
    @AppStorage("settingsOpenSections") private var openRaw = "pvp,rename"

    enum MessageKind { case info, ok, warning }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Nastavení", "Settings"))
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.3)
            LanguageUpdateCard()
            if runner.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 14))
                    Text(tr("Během třídění nastavení měnit nejde.", "Settings can't be changed while sorting."))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.yellow)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.yellowTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 8) {
                section("duplicates", tr("Duplicity", "Duplicates"), "square.on.square",
                        "\(store.config.removeTag) · " + tr("nechat \(store.config.keepBest)", "keep \(store.config.keepBest)")) {
                    duplicates
                }
                section("iv", tr("IV tagy", "IV tags"), "tag", tagCount(store.config.ivTags.filter { !$0.name.isEmpty }.count)) { ivTags }
                section("pvp", tr("PvP tagy", "PvP tags"), "trophy", leagueCount) { pvpTags }
                section("rename", tr("Přejmenování", "Renaming"), "pencil", rangeText) { rename }
                section("battle", tr("Battle tagy", "Battle tags"), "figure.fencing", battleSummary) { battleTags }
                section("weak", tr("Slabé kusy", "Weak Pokémon"), "arrow.down.circle", weakSummary) { weak }
                section("device", "iPhone", "iphone.gen3", deviceSummary) { device }
                section("advanced", tr("Pokročilé", "Advanced"), "slider.horizontal.3", "") { advanced }
            }
            .disabled(runner.isRunning)
            .opacity(runner.isRunning ? 0.5 : 1)
            section("about", tr("O aplikaci", "About"), "info.circle", Consent.appVersion) { AboutContent() }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
        .animation(.snappy, value: runner.isRunning)
        .sheet(isPresented: $editorOpen) {
            RenameEditor(config: $store.config.rename, samples: samples)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: ShotSession.editorNote)) { note in
            editorOpen = (note.object as? Bool) ?? false
        }
        #endif
        .onChange(of: runner.finishedAt) { _, _ in lastBox = LastBox.load() }
    }

    // MARK: - Collapsible sections

    private func isOpen(_ key: String) -> Bool { openRaw.split(separator: ",").contains(Substring(key)) }

    private func toggle(_ key: String) {
        var set = Set(openRaw.split(separator: ",").map(String.init))
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { openRaw = set.sorted().joined(separator: ",") }
    }

    private func section<Content: View>(_ key: String, _ title: String, _ symbol: String, _ summary: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggle(key) } label: {
                HStack(spacing: 8) {
                    SoftIcon(symbol: symbol, size: 26, radius: 8)
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen(key) ? 180 : 0))
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen(key) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
                    .padding(.top, 8)
                    .transition(.reveal)
            }
        }
    }

    private func tagCount(_ n: Int) -> String { trCount(n, cs: "tag", "tagy", "tagů", en: "tag", "tags") }

    private var leagueCount: String {
        let n = store.config.pvp.all.filter(\.league.enabled).count
        return tr("\(n) z 3 lig", "\(n) of 3 leagues")
    }

    private var rangeText: String { pctRange(store.config.rename.min, store.config.rename.max) }

    private var weakSummary: String {
        let c = store.config.weak
        let kept = [c.keepLegendary, c.keepMythical, c.keepUltraBeast, c.keepRegional, c.keepBest, c.keepBattle]
            .filter { $0 }.count + (c.keepTag.isEmpty ? 0 : 1)
        return tr("pod \(c.maxIV) % · \(kept) pojistek", "under \(c.maxIV)% · \(kept) safeguards")
    }

    // MARK: - Weak Pokémon

    private var weak: some View {
        let c = store.config.weak
        let inRange = c.maxIV > 0 ? lastBox?.count(in: 0...(c.maxIV - 1)) : 0
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("Označit kusy pod", "Tag Pokémon under")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(percentText(c.maxIV)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(c.maxIV)))
                }
                Slider(value: Binding(get: { Double(c.maxIV) }, set: { store.config.weak.maxIV = Int($0.rounded()) }),
                       in: 0...100, step: 1)
                    .tint(Theme.accent)
                Text(inRange.map { n in
                        let count = trCount(n, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon")
                        return tr("\(count) v inventáři dostane tag \(store.config.removeTag), pokud je nechrání pojistka. Z posledního měření.",
                                  "\(count) in your storage would get the \(store.config.removeTag) tag unless a safeguard keeps them. From the last measurement.")
                    } ?? tr("Kusy pod touhle hranicí dostanou tag \(store.config.removeTag).",
                            "Pokémon under this threshold get the \(store.config.removeTag) tag."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(tr("Pojistky: tyhle se neoznačí", "Safeguards: these are left alone"))
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                keepRow(tr("Legendární", "Legendary"), $store.config.weak.keepLegendary)
                keepRow(tr("Mýtičtí", "Mythical"), $store.config.weak.keepMythical)
                keepRow(tr("Ultra Beasts", "Ultra Beasts"), $store.config.weak.keepUltraBeast)
                keepRow(tr("Regionální formy", "Regional forms"), $store.config.weak.keepRegional,
                        detail: tr("Alolan, Galarian, Hisuian, Paldean", "Alolan, Galarian, Hisuian, Paldean"))
                keepRow(tr("Nejlepší svého druhu", "The best of each species"), $store.config.weak.keepBest,
                        detail: tr("nikdy nepřijdeš o poslední kus druhu", "so you never lose your last one of a species"))
                keepRow(tr("S PvP nebo Battle tagem", "With a PvP or Battle tag"), $store.config.weak.keepBattle,
                        detail: tr("nízké IV bývá pro Great League dobré", "low IV is often good for the Great League"))
            }
            .padding(.horizontal, 4)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Vlastní tag ze hry", "Your own tag from the game")).font(.system(size: 13, weight: .medium))
                Text(tr("Shadow, lucky, Dynamax ani oblíbené kusy bot z obrazovky nepozná. Otaguj si je ve hře a vyber ten tag tady: IVory se jich pak nedotkne.",
                        "The bot can't tell shadow, lucky, Dynamax or favorites from the screen. Tag them in the game, pick that tag here and IVory leaves them alone."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                FieldBox {
                    TextField(tr("Bez tagu", "No tag"), text: $store.config.weak.keepTag)
                }
            }
            .padding(.horizontal, 4)
            Text(tr("Tag se jen přidává, nikdy neodebírá: ten samý tag dávají i duplicity a můžeš ho mít na kusech sám. IVory nikdy nic nepřenáší, přenesení je na tobě ve hře.",
                    "The tag is only added, never taken off: the duplicates step uses the same tag and you may have set it by hand. IVory never transfers anything, that's up to you in the game."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .padding(12)
    }

    private func keepRow(_ title: String, _ on: Binding<Bool>, detail: String? = nil) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
    }

    private var battleSummary: String {
        let b = store.config.battle
        return tagCount((b.raid.enabled ? 1 : 0) + b.teams.filter(\.tag.enabled).count)
    }

    private var deviceSummary: String {
        if let d = devices.first(where: { $0.udid == store.config.udid }) { return d.name }
        return store.config.udid.isEmpty ? tr("automaticky", "automatic") : tr("vybraný", "selected")
    }

    // MARK: - Duplicates

    private var duplicates: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("Hledání ve hře", "Search in the game")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if store.config.searchQuery != AppConfig.defaultSearchQuery {
                        Button(tr("Výchozí", "Default")) { store.config.searchQuery = AppConfig.defaultSearchQuery }
                            .buttonStyle(GhostButtonStyle(height: 22))
                    }
                }
                FieldBox(monospaced: true) {
                    TextField(AppConfig.defaultSearchQuery, text: $store.config.searchQuery)
                }
                Text(tr("Bot to napíše do Search v inventáři a duplicity hledá jen mezi tím, co hledání ukáže. & = a zároveň, ! = kromě.",
                        "The bot types this into Search in your storage and looks for duplicates only among the results. & = and, ! = not."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Tag pro horší kusy", "Tag for the worse ones")).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    ColorDotButton(color: $store.config.removeTagColor)
                    FieldBox { TextField("Removable", text: $store.config.removeTag) }
                }
                Text(tr("Když ve hře chybí, vytvoří se v téhle barvě.", "If it's missing in the game, it's created in this color."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 10) {
                Text(tr("Kolik nejlepších nechat", "How many of the best to keep")).font(.system(size: 14))
                Spacer()
                PlusMinus(value: $store.config.keepBest, range: 1...10)
            }
        }
        .padding(14)
    }

    // MARK: - IV tags

    private var ivTags: some View {
        VStack(alignment: .leading, spacing: 12) {
            let sorted = store.config.ivTags.sorted { $0.min > $1.min }
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, tag in
                    if let binding = binding(for: tag) {
                        TagRow(tag: binding, range: range(for: index, in: sorted)) {
                            withAnimation(.snappy) { store.config.ivTags.removeAll { $0.id == tag.id } }
                        }
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sorted.map(\.min))

            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy) { store.config.ivTags.append(IVTag(min: 50, name: "", color: .gray)) }
                } label: { Label(tr("Přidat", "Add"), systemImage: "plus") }
                Button {
                    withAnimation(.snappy) { store.config.ivTags = AppConfig.defaultIVTags }
                } label: { Label(tr("Výchozí", "Default"), systemImage: "arrow.counterclockwise") }
            }
            .buttonStyle(GhostButtonStyle())
            .padding(.horizontal, 4)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Přeskočit už otagované", "Skip already tagged")).font(.system(size: 14))
                    Text(tr("Platí pro pomalý režim. V rychlém bot přečte IV všech a nesedící tagy opraví.",
                            "Applies to slow mode. In fast mode the bot reads every IV and fixes tags that don't match."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !store.config.recheckTagged }, set: { store.config.recheckTagged = !$0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 8)

            Text(tr("Klikni na tečku a vyber barvu. Hra má 8 barev, víc tagů může mít stejnou. % = součet IV / 45.",
                    "Click a dot to pick its color. The game has 8 colors, so several tags can share one. % = IV sum / 45."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 14, trailing: 8))
    }

    // MARK: - PvP tags

    private var pvpTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            leagueRow("great", $store.config.pvp.great)
            leagueRow("ultra", $store.config.pvp.ultra)
            leagueRow("master", $store.config.pvp.master)
            Text(tr("Tag dostane kus s pořadím do zadaného čísla. Pořadí 1 = nejlepší IV pro ligu ze 4 096 kombinací pro poslední evoluci (při větvení tu nejlepší) pod limitem CP. Jeden kus může mít víc PvP tagů.",
                    "A Pokémon gets the tag when its rank is within the number. Rank 1 = the best IVs for the league out of 4,096 combinations for the final evolution (the best branch, if it branches) under the CP cap. One Pokémon can get several PvP tags."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(12)
    }

    private func leagueRow(_ key: String, _ league: Binding<League>) -> some View {
        HStack(spacing: 8) {
            ColorDotButton(color: league.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(league.wrappedValue.name).font(.system(size: 14, weight: .medium))
                Text("\(PvPConfig.caps[key] ?? "") · \(league.wrappedValue.color.title)")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            Text(tr("do", "top")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            PlusMinus(value: league.maxRank, range: 1...4096, step: 10)
            Toggle("", isOn: league.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .opacity(league.wrappedValue.enabled ? 1 : 0.55)
        .padding(.horizontal, 4)
    }

    // MARK: - Battle tags

    private var battleTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ColorDotButton(color: $store.config.battle.raid.color)
                VStack(alignment: .leading, spacing: 1) {
                    TextField(tr("Název tagu", "Tag name"), text: $store.config.battle.raid.name)
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                    Text(tr("raid útočníci · \(store.config.battle.raid.perType) nejlepších na typ útoku",
                            "raid attackers · the best \(store.config.battle.raid.perType) per attack type"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                PlusMinus(value: $store.config.battle.raid.perType, range: 1...12)
                Toggle("", isOn: $store.config.battle.raid.enabled)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
            }
            .opacity(store.config.battle.raid.enabled ? 1 : 0.55)
            .padding(.horizontal, 4)
            teamRow(.great, $store.config.battle.great)
            teamRow(.ultra, $store.config.battle.ultra)
            teamRow(.master, $store.config.battle.master)
            Text(tr("Krok Battle tagy otaguje ve hře tvoje nejlepší útočníky na raidy a PvP týmy, které vybereš na obrazovce Battle. Ve hře je pak najdeš hledáním, třeba #\(store.config.battle.raid.name)&@steel pro útočníky s ocelovým útokem. Kusům, které už vybrané nejsou, tag sundá.",
                    "The Battle tags step tags your best raid attackers and the PvP teams you pick on the Battle screen. In the game you then find them by searching, e.g. #\(store.config.battle.raid.name)&@steel for attackers with a steel move. It takes the tag off Pokémon that are no longer picked."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            Rectangle().fill(Theme.border).frame(height: 1)
            Toggle(isOn: $store.config.battle.notifyBosses) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Upozornit na nové raid bosse", "Notify me about new raid bosses")).font(.system(size: 14, weight: .medium))
                    Text(tr("Když přijde boss, na kterého máš silnou partu, nebo naopak žádné countery. Jen když je IVory otevřená.",
                            "When a boss arrives that you have a strong party for, or no counters at all. Only while IVory is open."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
            .padding(.horizontal, 4)
            .onChange(of: store.config.battle.notifyBosses) { _, on in if on { BossAlerts.requestPermission() } }
        }
        .padding(12)
    }

    private func teamRow(_ league: PvPLeague, _ tag: Binding<BattleConfig.TeamTag>) -> some View {
        HStack(spacing: 8) {
            ColorDotButton(color: tag.color)
            VStack(alignment: .leading, spacing: 1) {
                TextField(tr("Název tagu", "Tag name"), text: tag.name)
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                Text(tr("\(league.name) · tým vybraný v Battle", "\(league.name) · the team picked in Battle"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: tag.enabled)
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
        }
        .opacity(tag.wrappedValue.enabled ? 1 : 0.55)
        .padding(.horizontal, 4)
    }

    // MARK: - Renaming

    private var samples: [NameSample] {
        lastBox?.samples(in: store.config.rename.min...store.config.rename.max) ?? NameSample.design
    }

    /// The smallest and largest IV sum that falls into the range (percentages are rounded).
    private var sumRange: (Int, Int) {
        let r = store.config.rename
        let pct = { (s: Int) in Int((Double(s) / 45 * 100).rounded()) }
        let sums = (0...45).filter { (r.min...r.max).contains(pct($0)) }
        return (sums.first ?? 0, sums.last ?? 0)
    }

    private var rename: some View {
        let r = store.config.rename
        let longest = samples.filter { !($0.custom && !r.overwriteCustom) }
            .map { NamePiece.render(r.template, $0.values).count }.max() ?? 0
        let first = samples.first(where: { !$0.custom }) ?? samples[0]
        let inRange = lastBox?.count(in: r.min...r.max)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("Rozsah IV", "IV range")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(rangeText).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                DualRange(lo: $store.config.rename.min, hi: $store.config.rename.max)
                if inRange == 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("V rozsahu nejsou žádné kusy", "No Pokémon in this range")).font(.system(size: 13, weight: .semibold))
                        Text(tr("Podle posledního měření nic nemá \(rangeText). Rozšiř rozsah, jinak se nic nepřejmenuje.",
                                "By the last measurement nothing has \(rangeText). Widen the range, otherwise nothing gets renamed."))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.orangeTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text(inRange.map {
                        tr("\(pieces($0)) v rozsahu · součet IV \(sumRange.0)–\(sumRange.1) · podle posledního měření",
                           "\(pieces($0)) in range · IV sum \(sumRange.0)–\(sumRange.1) · from the last measurement")
                    } ?? tr("Součet IV \(sumRange.0)–\(sumRange.1). Kolik kusů to je, ukážu po prvním měření.",
                            "IV sum \(sumRange.0)–\(sumRange.1). How many Pokémon that is shows up after the first measurement."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("Šablona jména", "Name template")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    CharCounter(n: longest)
                }
                HStack(spacing: 6) {
                    FlowRow(spacing: 4) {
                        ForEach(r.template) { t in
                            NameChipView(token: .constant(t), value: "", small: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { editorOpen = true } label: {
                        Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(Theme.accentInk)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Upravit šablonu", "Edit the template"))
                }
                .padding(8)
                .background(Theme.tint.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.3)))
                HStack(spacing: 6) {
                    Text(first.name).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    Text(String(NamePiece.render(r.template, first.values).prefix(NamePiece.maxLength)))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(tr("Upravit šablonu…", "Edit template…")) { editorOpen = true }
                        .buttonStyle(OutlineButtonStyle(height: 28))
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            switchRow(tr("Přepsat i vlastní přezdívky", "Overwrite custom nicknames too"),
                      tr("Jinak kusy s vlastním jménem vynechám.", "Otherwise Pokémon with a custom name are skipped."),
                      $store.config.rename.overwriteCustom)
            switchRow(tr("Vynechat kusy s tagem \(store.config.removeTag)", "Skip Pokémon tagged \(store.config.removeTag)"), nil,
                      $store.config.rename.skipRemovable)
            switchRow(tr("Jen kusy s tagem", "Only Pokémon with a tag"),
                      tr("Volitelné. Ostatní v rozsahu vynechám.", "Optional. The rest of the range is skipped."),
                      $store.config.rename.onlyTagEnabled)
            Menu {
                ForEach(store.config.allTagNames, id: \.self) { name in
                    Button(name) { store.config.rename.onlyTag = name }
                }
            } label: {
                FieldBox {
                    HStack(spacing: 8) {
                        Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Text(r.onlyTag.isEmpty ? tr("Vyber tag", "Pick a tag") : r.onlyTag)
                            .foregroundStyle(r.onlyTag.isEmpty ? Theme.muted : Theme.text)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!r.onlyTagEnabled)
            .opacity(r.onlyTagEnabled ? 1 : 0.5)

            Button {
                withAnimation(.snappy) { store.config.rename = RenameConfig() }
            } label: { Label(tr("Výchozí", "Default"), systemImage: "arrow.counterclockwise") }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(14)
    }

    private func pieces(_ n: Int) -> String { trCount(n, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon") }

    private func switchRow(_ title: String, _ subtitle: String?, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }

    private func binding(for tag: IVTag) -> Binding<IVTag>? {
        guard let i = store.config.ivTags.firstIndex(where: { $0.id == tag.id }) else { return nil }
        return $store.config.ivTags[i]
    }

    private func range(for index: Int, in sorted: [IVTag]) -> ClosedRange<Int> {
        let low = sorted[index].min
        let high = index == 0 ? 100 : max(low, sorted[index - 1].min - 1)
        return low...max(low, high)
    }

    // MARK: - iPhone

    private var device: some View {
        Group {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Zařízení", "Device")).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 8) {
                        deviceField
                        Button(tr("Najít", "Find")) { findDevices() }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(busy)
                    }
                    statusLine
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Team ID").font(.system(size: 13, weight: .medium))
                    HStack(spacing: 8) {
                        FieldBox(monospaced: true) {
                            TextField(tr("automaticky z certifikátu", "automatic, from the certificate"), text: $store.config.teamId)
                        }
                        Button(tr("Zjistit", "Detect")) { findTeam() }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(busy)
                    }
                }
            }
            .padding(14)
        }
        .animation(.snappy, value: message)
    }

    /// Found iPhones as a menu, otherwise a manually entered UDID.
    @ViewBuilder private var deviceField: some View {
        if devices.isEmpty {
            FieldBox {
                TextField(tr("automaticky – první připojený", "automatic – first connected"), text: $store.config.udid)
            }
        } else {
            Menu {
                Button(tr("Automaticky – první připojený", "Automatic – first connected")) { store.config.udid = "" }
                Divider()
                ForEach(devices) { d in
                    Button("\(d.name) – iOS \(d.os)") { store.config.udid = d.udid }
                }
            } label: {
                FieldBox {
                    HStack(spacing: 8) {
                        Text(selectedDeviceTitle).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var selectedDeviceTitle: String {
        if let d = devices.first(where: { $0.udid == store.config.udid }) { return "\(d.name) – iOS \(d.os)" }
        return store.config.udid.isEmpty ? tr("Automaticky – první připojený", "Automatic – first connected") : store.config.udid
    }

    @ViewBuilder private var statusLine: some View {
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dotColor).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let proposedTeam {
                    Button(tr("Použít", "Use")) {
                        store.config.teamId = proposedTeam
                        self.proposedTeam = nil
                        messageKind = .ok
                        self.message = "Team ID: \(proposedTeam)"
                    }
                    .buttonStyle(GhostButtonStyle(height: 22))
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var dotColor: Color {
        switch messageKind {
        case .ok: return Theme.green
        case .warning: return Theme.orange
        case .info: return Theme.muted
        }
    }

    private func findDevices() {
        busy = true
        messageKind = .info
        message = tr("Hledám připojené iPhony…", "Looking for connected iPhones…")
        Task {
            let found = await DeviceTools.connectedDevices()
            devices = found
            if let first = found.first {
                if !store.config.udid.isEmpty && !found.contains(where: { $0.udid == store.config.udid }) {
                    store.config.udid = first.udid
                } else if store.config.udid.isEmpty {
                    store.config.udid = first.udid
                }
                messageKind = .ok
                message = found.count == 1
                    ? tr("Nalezen \(first.name) (iOS \(first.os))", "Found \(first.name) (iOS \(first.os))")
                    : tr("Nalezeno \(found.count) zařízení – vyber v seznamu.", "Found \(found.count) devices – pick one from the list.")
            } else {
                messageKind = .warning
                message = tr("Žádný iPhone nevidím. Připoj ho kabelem, odemkni a potvrď „Důvěřovat“.",
                             "No iPhone found. Connect it with a cable, unlock it and tap “Trust”.")
            }
            busy = false
        }
    }

    private func findTeam() {
        busy = true
        messageKind = .info
        message = tr("Hledám certifikát Apple Development…", "Looking for the Apple Development certificate…")
        proposedTeam = nil
        Task {
            if let team = await DeviceTools.teamId() {
                if store.config.teamId.isEmpty {
                    store.config.teamId = team
                    messageKind = .ok
                    message = "Team ID: \(team)"
                } else if store.config.teamId == team {
                    messageKind = .ok
                    message = tr("Team ID sedí s certifikátem.", "The Team ID matches the certificate.")
                } else {
                    // Don't overwrite the current value automatically – if signing works, it's correct.
                    proposedTeam = team
                    messageKind = .warning
                    message = tr("V certifikátu je \(team). Když ti podepisování funguje se současnou hodnotou, nech ji být.",
                                 "The certificate says \(team). If signing works with the current value, leave it as it is.")
                }
            } else {
                messageKind = .warning
                message = tr("Certifikát „Apple Development“ jsem nenašel. Přihlas se v Xcode → Settings → Accounts.",
                             "No “Apple Development” certificate found. Sign in under Xcode → Settings → Accounts.")
            }
            busy = false
        }
    }

    // MARK: - Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(tr("Kolik skupin duplicit projít", "Duplicate groups to check"))
                Spacer()
                Text(store.config.maxGroups == 0 ? tr("všechny", "all") : "\(store.config.maxGroups)")
                    .monospacedDigit().foregroundStyle(Theme.muted)
                MiniStepper(value: $store.config.maxGroups, range: 0...999)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
                } label: {
                    Label(tr("Soubor s nastavením", "Settings file"), systemImage: "doc.text")
                }
                .buttonStyle(OutlineButtonStyle(color: Theme.text, stroke: Theme.border, hover: Theme.raise, height: 28))
                Spacer()
                Button(tr("Obnovit výchozí", "Reset to defaults")) {
                    withAnimation(.snappy) { store.resetKeepingDevice() }
                }
                .buttonStyle(GhostButtonStyle(color: Theme.red, hover: Theme.redTint))
            }
        }
        .font(.system(size: 14))
        .padding(14)

    }
}

// MARK: - Components

/// Expanding a section: the card is revealed top to bottom (its height grows from zero)
/// and the sections below slide down smoothly.
extension AnyTransition {
    static var reveal: AnyTransition {
        .modifier(active: Reveal(progress: 0), identity: Reveal(progress: 1))
    }
}

private struct Reveal: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { content }
            .clipped()
            .opacity(Double(min(1, progress * 1.6)))
    }
}

/// Reports only `progress` of the content's height and pins the content to the top (`clipped` cuts off the rest).
private struct RevealLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // expanded: just pass through (same size proposal = SwiftUI reuses its cached measurement, no extra work)
        if progress >= 1 { return child.sizeThatFits(proposal) }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: progress >= 1 ? proposal : ProposedViewSize(width: bounds.width, height: nil))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// −  number  +
struct PlusMinus: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value % step == 0 || step == 1 ? value - step : value - value % step)
            }
            Text("\(value)")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .frame(minWidth: step > 1 ? 34 : 22)
                .contentTransition(.numericText(value: Double(value)))
            button("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, step == 1 ? value + 1 : value - value % step + step)
            }
        }
        .background(Theme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .animation(.snappy, value: value)
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Theme.accentInk : Theme.muted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// IV tag row: color dot, name (editable), range, the "from X%" threshold, arrows, delete.
struct TagRow: View {
    @Binding var tag: IVTag
    let range: ClosedRange<Int>
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ColorDotButton(color: $tag.color)
            VStack(alignment: .leading, spacing: 1) {
                TextField(tr("Název tagu", "Tag name"), text: $tag.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                Text(pctRange(range.lowerBound, range.upperBound) + " · \(tag.color.title)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            Text(tr("od \(tag.min) %", "from \(tag.min)%"))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .contentTransition(.numericText(value: Double(tag.min)))
            MiniStepper(value: $tag.min, range: 0...100)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .opacity(hovering ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .help(tr("Odebrat tag", "Remove the tag"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Theme.raise : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .animation(.snappy, value: tag.min)
    }
}

/// Panel footer: save status and the file path.
struct SaveFooter: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if store.error != nil {
                    Label(tr("Nastavení se nepodařilo uložit", "Couldn't save the settings"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.red)
                        .help(store.error ?? "")
                } else if let savedAt = store.savedAt {
                    Label(tr("Uloženo", "Saved"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.green)
                        .id(savedAt)
                        .transition(.opacity.combined(with: .scale))
                } else {
                    Label(tr("Ukládá se automaticky", "Saves automatically"), systemImage: "arrow.triangle.2.circlepath")

                        .foregroundStyle(Theme.muted)
                }
            }
            .labelStyle(FooterLabelStyle())
            Spacer()
            Text("~/" + ConfigStore.url.pathComponents.suffix(2).joined(separator: "/"))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(.snappy, value: store.savedAt)
    }
}

private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 13))
            configuration.title
        }
    }
}
