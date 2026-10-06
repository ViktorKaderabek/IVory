import AppKit
import SwiftUI

/// Pieces several screens share: the empty state before the first run, the type and weather tables the
/// Raids, PvP and Power-ups screens read from, and the little text helpers.

/// The bot has never run: nothing to recommend from. Centred in the empty screen, since there is
/// nothing above or beside it to line up with.
struct NeverRun: View {
    let startRun: () -> Void
    /// What the screen would show once the bot has read the storage.
    var promise: String = tr("nejlepší countery proti raid bossům, šanci na výhru a týmy pro PvP ligy",
                             "the best counters against raid bosses, the win chance and teams for the PvP leagues")

    /// How far down the scrolling area this starts – the screen's heading sits above it.
    @State private var top: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            SoftIcon(symbol: "figure.fencing", size: 56, radius: 16)
            Text(tr("Zatím není z čeho doporučovat", "Nothing to recommend from yet"))
                .font(.system(size: 24, weight: .medium)).tracking(-0.48)
            Text(tr("IVory ještě nezná žádného tvého Pokémona. Po prvním běhu tu uvidíš \(promise).",
                    "IVory doesn't know any of your Pokémon yet. After the first run you'll see \(promise)."))
                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: startRun) { Label(tr("Spustit první běh", "Start the first run"), systemImage: "play.fill") }
                .buttonStyle(OutlineButtonStyle(height: 36))
                .padding(.top, 6)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { p in
                Color.clear.preference(key: TopInset.self, value: p.frame(in: .scrollView).minY)
            }
        }
        .onPreferenceChange(TopInset.self) { top = $0 }
        // take the rest of the window below the heading, so it sits in the middle of what you see
        // instead of hanging under it (the 40 is the bottom padding every screen gets in MainView)
        .containerRelativeFrame(.vertical) { height, _ in max(320, height - top - 40) }
    }
}

/// Where a view starts inside the screen's scrolling area.
private struct TopInset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A Pokémon's standing in one league: where it is among the ones you own, and how good its IVs are
/// of all 4,096 the species can have. The two answer different questions – your best Great League
/// Pokémon can still be far from the best possible spread – so both are shown.
struct LeagueRanks: View {
    let mine: Int?
    let best: Int

    var body: some View {
        HStack(spacing: 10) {
            if let mine {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("#\(mine)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(mine == 1 ? Theme.accentInk : Theme.text)
                    Text(tr("u tebe", "of yours"))
                        .font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
                Rectangle().fill(Theme.border).frame(width: 1, height: 18)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text("#\(best.formatted())")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(best <= 100 ? Theme.accentInk : Theme.text)
                Text(tr("ze 4 096", "of 4,096"))
                    .font(.system(size: 9)).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Types: names in both languages (Czech also in the dative, "proti Trávě"), colors and icons from the design.
enum BattleType {
    private static let table: [String: (cs: String, dative: String, en: String, hue: Double, chroma: Double, symbol: String)] = [
        "normal": ("Normální", "Normálnímu", "Normal", 90, 0.03, "circle"),
        "fire": ("Oheň", "Ohni", "Fire", 40, 0.15, "flame.fill"),
        "water": ("Voda", "Vodě", "Water", 245, 0.13, "drop.fill"),
        "grass": ("Tráva", "Trávě", "Grass", 145, 0.14, "leaf.fill"),
        "electric": ("Elektřina", "Elektřině", "Electric", 95, 0.14, "bolt.fill"),
        "ice": ("Led", "Ledu", "Ice", 210, 0.1, "snowflake"),
        "fighting": ("Boj", "Boji", "Fighting", 30, 0.14, "figure.boxing"),
        "poison": ("Jed", "Jedu", "Poison", 320, 0.14, "flask.fill"),
        "ground": ("Země", "Zemi", "Ground", 70, 0.1, "mountain.2.fill"),
        "flying": ("Létání", "Létání", "Flying", 270, 0.1, "bird.fill"),
        "psychic": ("Psychika", "Psychice", "Psychic", 355, 0.14, "eye.fill"),
        "bug": ("Hmyz", "Hmyzu", "Bug", 125, 0.13, "ladybug.fill"),
        "rock": ("Kámen", "Kameni", "Rock", 75, 0.07, "cube.fill"),
        "ghost": ("Duch", "Duchu", "Ghost", 300, 0.12, "theatermasks.fill"),
        "dragon": ("Drak", "Drakovi", "Dragon", 285, 0.15, "lizard.fill"),
        "dark": ("Temno", "Temnu", "Dark", 20, 0.03, "moon.fill"),
        "steel": ("Ocel", "Oceli", "Steel", 220, 0.04, "shield.fill"),
        "fairy": ("Víla", "Víle", "Fairy", 0, 0.12, "sparkles"),
    ]

    static func name(_ t: String) -> String { table[t].map { tr($0.cs, $0.en) } ?? t.capitalized }
    static func dative(_ t: String) -> String { table[t].map { tr($0.dative, $0.en) } ?? t.capitalized }
    static func symbol(_ t: String) -> String { table[t]?.symbol ?? "circle" }

    static func color(_ t: String) -> Color {
        let v = table[t] ?? ("", "", "", 280, 0.02, "")
        return .adaptive(dark: .oklch(0.78, v.chroma, v.hue), light: .oklch(0.5, v.chroma, v.hue))
    }

    static func tint(_ t: String) -> Color {
        let v = table[t] ?? ("", "", "", 280, 0.02, "")
        return .adaptive(dark: .oklch(0.78, v.chroma, v.hue, alpha: 0.18), light: .oklch(0.5, v.chroma, v.hue, alpha: 0.14))
    }
}

enum BattleWeather {
    static func name(_ w: String) -> String {
        switch w {
        case "sunny": tr("Slunečno", "Sunny")
        case "rainy": tr("Déšť", "Rain")
        case "partly cloudy": tr("Polojasno", "Partly cloudy")
        case "cloudy": tr("Zataženo", "Cloudy")
        case "windy": tr("Větrno", "Windy")
        case "snow": tr("Sníh", "Snow")
        case "fog": tr("Mlha", "Fog")
        default: w.capitalized
        }
    }

    static func symbol(_ w: String) -> String {
        ["sunny": "sun.max", "rainy": "cloud.rain", "partly cloudy": "cloud.sun", "cloudy": "cloud", "windy": "wind",
         "snow": "snowflake", "fog": "cloud.fog"][w] ?? "cloud"
    }
}

@MainActor
enum BattleFormat {
    static func number(_ n: Int) -> String { n.formatted(.number.locale(L10n.locale)) }

    static func decimal(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale)) }

    static func multiplier(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale)) }

    static func level(_ l: Double) -> String {
        l == l.rounded() ? "L\(Int(l))" : "L" + l.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
    }

    /// "a, b and c" / "a, b a c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + tr(" a ", " and ") + items[items.count - 1]
    }

    /// "today at 6:02" or the date.
    static func when(_ d: Date) -> String {
        let time = d.formatted(.dateTime.hour().minute().locale(L10n.locale))
        if Calendar.current.isDateInToday(d) { return tr("dnes v \(time)", "today at \(time)") }
        let day = d.formatted(.dateTime.day().month().year().locale(L10n.locale))
        return tr("\(day) v \(time)", "\(day) at \(time)")
    }

    static func meta(_ m: InventoryStats.Mon) -> String {
        var parts = ["IV \(percentText(m.pct))"]
        if let l = m.level { parts.append(level(l)) }
        parts.append("\(number(m.cp)) CP")
        return parts.joined(separator: " · ")
    }

    static func reason(_ c: RaidCounter, _ boss: RaidBoss) -> String {
        let mult = c.effectiveness.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))
        let weather = c.boosted ? tr(" · počasí 1,2×", " · weather 1.2×") : ""
        let type = BattleType.name(c.attackType)
        if c.effectiveness >= 1.5 {
            let math = BattleStore.shared.data?.battle.map(TypeMath.init)
            let weakTo = boss.types.filter { math?.eff(c.attackType, [$0]) ?? 1 > 1 }
            let against = list(weakTo.map(BattleType.dative))
            return tr("\(type) \(mult)× proti \(against)", "\(type) \(mult)× vs \(list(weakTo.map(BattleType.name)))") + weather
        }
        if c.effectiveness < 0.9 { return tr("\(type) jen \(mult)×", "\(type) only \(mult)×") + weather }
        return tr("\(type) bez typové výhody", "\(type), no type advantage") + weather
    }

    static func raidTags(_ c: RaidCounter) -> [BattleTag] {
        var out: [BattleTag] = []
        if let evo = c.evolveTo { out.append(BattleTag(text: tr("vyvinout na \(evo)", "evolve into \(evo)"), symbol: "wand.and.stars")) }
        if c.powerUp { out.append(BattleTag(text: tr("vylepšit na L40", "power up to L40"), symbol: "arrow.up")) }
        return out
    }

    static func pvpTags(_ m: PvPMember) -> [BattleTag] {
        var out: [BattleTag] = []
        if m.evolves { out.append(BattleTag(text: tr("vyvinout na \(m.formName)", "evolve into \(m.formName)"), symbol: "wand.and.stars")) }
        if m.powerUp { out.append(BattleTag(text: tr("vylepšit na \(level(m.level))", "power up to \(level(m.level))"), symbol: "arrow.up")) }
        return out
    }

    static func rank(_ r: Int) -> String { tr("#\(r) z 4 096", "#\(r) of 4,096") }

    static func cp(_ m: PvPMember) -> String {
        m.mon.cp == m.cp && !m.evolves ? "\(number(m.cp)) CP" : "\(number(m.mon.cp)) → \(number(m.cp)) CP"
    }

    static func level(_ m: PvPMember, _ league: PvPLeague) -> String {
        guard !m.powerUp else { return tr("na \(level(m.level))", "to \(level(m.level))") }
        return league.cap == nil ? tr("\(level(m.level)) · na maximu", "\(level(m.level)) · maxed")
            : tr("\(level(m.level)) · na limitu", "\(level(m.level)) · at the limit")
    }

    static func moves(_ moveset: [String]) -> (fast: String, charged: String) {
        let names = moveset.map { BattleStore.shared.data?.battle?.moves[$0]?.name ?? $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return (names.first ?? "", names.dropFirst().joined(separator: " · "))
    }

    /// "Medicham leads. Lanturn and Azumarill cover its threats."
    static func summary(_ team: PvPTeam) -> String {
        let ms = team.members
        guard let lead = ms.first?.formName else {
            return tr("Do ligy se ti zatím nevejde žádný vhodný Pokémon.", "No suitable Pokémon fits the league yet.")
        }
        guard ms.count == 3 else {
            return tr("Neúplný tým, \(ms.count) ze 3. \(lead) začíná.", "An incomplete team, \(ms.count) of 3. \(lead) leads.")
        }
        let sw = ms[1].formName, cl = ms[2].formName
        let covered = team.threats.filter { $0.cells.first == -1 && $0.covered }
            .compactMap { BattleStore.shared.data?.battle?.pokemon[$0.opponent]?.name }
        guard !covered.isEmpty else {
            return tr("\(lead) začíná, \(sw) střídá a \(cl) dokončuje.", "\(lead) leads, \(sw) switches in and \(cl) closes.")
        }
        return tr("\(lead) začíná. \(sw) a \(cl) kryjí jeho hrozby, \(list(covered.prefix(2).map { $0 })).",
                  "\(lead) leads. \(sw) and \(cl) cover its threats, \(list(covered.prefix(2).map { $0 })).")
    }

    static func leagueColor(_ l: PvPLeague) -> Color {
        switch l {
        case .great: .oklch(0.72, 0.13, 250)
        case .ultra: .oklch(0.84, 0.15, 92)
        case .master: .oklch(0.7, 0.15, 300)
        }
    }

}

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

/// A little label on a card: a word, sometimes with an icon.
struct BattleTag: Hashable {
    let text: String
    let symbol: String?
    var muted = false
}
