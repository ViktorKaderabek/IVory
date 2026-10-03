import Foundation
import Observation

/// Language of the app and of the bot's log: Czech or English (the default follows the system). Stored in
/// config.json ("language"), so the bot reads it too.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case cs, en   // order in the picker: Czech, then English

    var id: String { rawValue }

    /// Default language from the system: Czech when it is first in System Settings → Language & Region.
    static var system: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("cs") == true ? .cs : .en
    }

    /// The language's name in that language (the picker in settings).
    var title: String { self == .en ? "English" : "Čeština" }
}

enum L10n {
    /// Current language, set by ConfigStore on load and on every settings change.
    /// It is observed (Observation): a view that calls `tr()` while rendering redraws itself when the
    /// language changes, so switching the language does not rebuild the whole window (that took ~300 ms).
    static var lang: AppLanguage {
        get { current.lang }
        set { if current.lang != newValue { current.lang = newValue } }
    }

    static var locale: Locale { Locale(identifier: lang == .cs ? "cs_CZ" : "en_US") }

    @Observable
    final class Current: @unchecked Sendable {
        var lang: AppLanguage = .en
    }

    private static let current = Current()
}

/// Text in the current language: `tr("Spustit", "Start")`.
func tr(_ cs: String, _ en: String) -> String {
    L10n.lang == .cs ? cs : en
}

/// A count with a noun: Czech has three forms (for 1, for 2–4 and for the rest), English two.
func trCount(_ n: Int, cs one: String, _ few: String, _ many: String, en enOne: String, _ enMany: String) -> String {
    if L10n.lang == .en {
        return "\(n) \(n == 1 ? enOne : enMany)"
    }
    return "\(n) \(n == 1 ? one : (2...4).contains(n) ? few : many)"
}

/// Percent: Czech with a space ("85 %"), English without ("85%").
func percentText(_ n: Int) -> String { tr("\(n) %", "\(n)%") }

/// Percent range ("85–100 %" / "85–100%"); equal bounds give a single number.
func pctRange(_ lo: Int, _ hi: Int) -> String { lo == hi ? percentText(lo) : tr("\(lo)–\(hi) %", "\(lo)–\(hi)%") }

