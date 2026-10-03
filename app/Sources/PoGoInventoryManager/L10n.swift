import Foundation

/// Jazyk aplikace i výpisu bota: čeština, nebo angličtina (výchozí podle systému). Ukládá se v config.json
/// („language“), takže ho čte i bot.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case cs, en   // pořadí v přepínači: Čeština / English

    var id: String { rawValue }

    /// Výchozí jazyk podle systému: čeština, když je první v Nastavení systému → Jazyk a oblast.
    static var system: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("cs") == true ? .cs : .en
    }

    /// Název jazyka v něm samém (přepínač v nastavení).
    var title: String { self == .en ? "English" : "Čeština" }
}

enum L10n {
    /// Aktuální jazyk – nastavuje ho ConfigStore při načtení a při každé změně nastavení.
    static var lang: AppLanguage = .en

    static var locale: Locale { Locale(identifier: lang == .cs ? "cs_CZ" : "en_US") }
}

/// Text v aktuálním jazyce: `tr("Spustit", "Start")`.
func tr(_ cs: String, _ en: String) -> String {
    L10n.lang == .cs ? cs : en
}

/// Počet s podstatným jménem: čeština má tři tvary (1 kus, 2 kusy, 5 kusů), angličtina dva.
func trCount(_ n: Int, cs one: String, _ few: String, _ many: String, en enOne: String, _ enMany: String) -> String {
    if L10n.lang == .en {
        return "\(n) \(n == 1 ? enOne : enMany)"
    }
    return "\(n) \(n == 1 ? one : (2...4).contains(n) ? few : many)"
}

/// Procenta: česky s mezerou („85 %“), anglicky bez („85%“).
func percentText(_ n: Int) -> String { tr("\(n) %", "\(n)%") }

/// Rozsah procent („85–100 %“ / „85–100%“); stejné meze = jedno číslo.
func pctRange(_ lo: Int, _ hi: Int) -> String { lo == hi ? percentText(lo) : tr("\(lo)–\(hi) %", "\(lo)–\(hi)%") }

