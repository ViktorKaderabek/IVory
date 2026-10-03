import AppKit
import SwiftUI

/// Pictures of the Pokémon that the bot saves while it reads the IVs (core/ivory/detail.py save_card):
/// ~/.pogo/cards/883_14-13-14.jpg (the whole phone screen with the appraisal) and 883_14-13-14_icon.jpg (a square
/// of just the Pokémon). Pokémon read before the bot saved pictures have none until they are measured again;
/// until then the square of another Pokémon of the same species stands in for theirs.
@MainActor
enum MonImages {
    static let dir: URL = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["IVORY_CARDS"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/cards")
    }()

    private static var loaded: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var barsShots: [String: URL?] = [:]
    private static var bySpecies: [String: [InventoryStats.Mon]] = [:]
    private static var speciesIcons: [String: URL?] = [:]

    static func key(_ m: InventoryStats.Mon) -> String { "\(m.cp)_\(m.iv.map(String.init).joined(separator: "-"))" }

    static func iconURL(_ m: InventoryStats.Mon) -> URL { dir.appendingPathComponent(key(m) + "_icon.jpg") }
    static func photoURL(_ m: InventoryStats.Mon) -> URL { dir.appendingPathComponent(key(m) + ".jpg") }

    /// The Pokémon's own square, otherwise the best one of its species that has a square.
    static func icon(_ m: InventoryStats.Mon) -> NSImage? {
        if let img = image(iconURL(m)) { return img }
        guard let species = m.species else { return nil }
        if speciesIcons[species] == nil {
            let best = (bySpecies[species] ?? []).sorted { ($0.pct, $0.cp) > ($1.pct, $1.cp) }
            speciesIcons[species] = .some(best.lazy.map(iconURL).first { image($0) != nil })
        }
        return (speciesIcons[species] ?? nil).flatMap(image)
    }

    /// The whole screen from the game with this Pokémon's appraisal (never another Pokémon's: it shows its IVs).
    static func photo(_ m: InventoryStats.Mon) -> NSImage? { image(photoURL(m)) }

    /// The bot's crop of the IV bars in the results (iv/CP883_14-13-14.jpg), for Pokémon without a picture yet.
    static func bars(_ m: InventoryStats.Mon) -> (NSImage, URL)? {
        let k = key(m)
        if barsShots[k] == nil { barsShots[k] = .some(InventoryStats.ivShot(of: m)) }
        guard let url = barsShots[k] ?? nil, let img = image(url) else { return nil }
        return (img, url)
    }

    /// After a run there may be new pictures (and a missing one may have appeared).
    static func reset(for stats: InventoryStats) {
        loaded = [:]
        missing = []
        barsShots = [:]
        speciesIcons = [:]
        bySpecies = Dictionary(grouping: stats.mons.filter { $0.species != nil }) { $0.species ?? "" }
    }

    private static func image(_ url: URL) -> NSImage? {
        let path = url.path
        if let img = loaded[path] { return img }
        if missing.contains(path) { return nil }
        guard let img = NSImage(contentsOf: url) else {
            missing.insert(path)
            return nil
        }
        loaded[path] = img
        return img
    }
}

/// The Pokémon's picture from the game; without one, its type's color with the first letter.
struct MonIcon: View {
    let m: InventoryStats.Mon
    var size: CGFloat = 34
    var circle = false
    var ring: Color? = nil

    var body: some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        Group {
            if let img = MonImages.icon(m) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                MonLetter(m: m, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(ring ?? Theme.border, lineWidth: ring == nil ? 1 : 2))
    }
}

/// Without a picture: the type's color and the first letter of the name.
struct MonLetter: View {
    let m: InventoryStats.Mon
    var size: CGFloat

    var body: some View {
        let color = PokeType.color(m.types.first ?? "")
        ZStack {
            color.opacity(0.22)
            Text(String(m.name.prefix(1))).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(color)
        }
    }
}
