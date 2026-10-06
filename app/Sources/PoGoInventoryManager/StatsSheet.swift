import AppKit
import SwiftUI

/// What a click on the Stats screen opens: a card, a row or a column.
enum StatsSheet: Hashable {
    case coverage, dex, region(Int), iv, ivBin(Int), hundo, nearPerfect, pvp, league(String), strong
    case rare(String)            // legendary / ultrabeast / mythical
    case evolve, duplicates, type(String), species(String), level(Int), tag(String), run(String)
}

/// The window over the Stats screen: which one is open, the selected Pokémon, the sorting, and the toast
/// after copying.
@MainActor
final class StatsSheetModel: ObservableObject {
    static let shared = StatsSheetModel()
    @Published private(set) var sheet: StatsSheet?
    @Published var selected: Int?
    @Published var sort: StatsSort?
    @Published private(set) var toast: String?
    /// The Pokémon whose photo from the game is shown enlarged over the window.
    private var toastTask: Task<Void, Never>?

    func open(_ sheet: StatsSheet, select: Int? = nil) {
        self.sheet = sheet
        selected = select
        sort = nil
    }

    func close() {
        sheet = nil
    }

    /// Esc: the enlarged photo first, then the window.
    func back() {
        close()
    }

    func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(message)
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { toast = nil }
        }
    }

    /// Shows the bot's crop of the IV bars in Finder – the proof of how this Pokémon was measured, in the
    /// run folder where it happened.
    func reveal(_ m: InventoryStats.Mon) {
        if let url = InventoryStats.ivShot(of: m) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            show(tr("Snímek tohoto kusu ve Výsledcích už není", "This Pokémon's screenshot is no longer in the results"))
        }
    }
}

enum StatsColors {
    static let gold = Color.adaptive(dark: .oklch(0.8, 0.15, 85), light: .oklch(0.6, 0.13, 75))
    static let goldTint = Color.adaptive(dark: .oklch(0.34, 0.07, 85), light: .oklch(0.93, 0.06, 85))
    static let hundoGlow = Color.oklch(0.86, 0.15, 92)
    static let ink = Color.oklch(0.2, 0.01, 270)
    static let orange = Color.oklch(0.73, 0.16, 55)
    static let blue = Color.oklch(0.62, 0.15, 255)
    static let gray = Color.oklch(0.64, 0.01, 270)
    static let dim = Color.oklch(0.45, 0.01, 270)

    /// The color of an IV percentage: gold for a hundo, then orange, blue and gray.
    static func iv(_ pct: Int) -> Color {
        pct == 100 ? gold : pct >= 90 ? orange : pct >= 80 ? blue : pct >= 70 ? gray : Theme.muted
    }

    /// The bars of the IV card: 90–100, 80–89, 70–79, under 70.
    static func bin(_ lower: Int) -> Color {
        switch lower {
        case 90: return orange
        case 80: return blue
        case 70: return gray
        default: return dim
        }
    }
}

/// The color a tag has in the game (from the settings); other tags are gray.
enum StatsTagColor {
    static func of(_ name: String, _ c: AppConfig) -> Color {
        if name == c.removeTag { return c.removeTagColor.swatch }
        if let t = c.ivTags.first(where: { $0.name == name }) { return t.color.swatch }
        if let l = c.pvp.all.first(where: { $0.league.name == name }) { return l.league.color.swatch }
        if name == c.battle.raid.name { return c.battle.raid.color.swatch }
        if let t = c.battle.teams.first(where: { $0.tag.name == name }) { return t.tag.color.swatch }
        return TagColor.gray.swatch
    }
}
