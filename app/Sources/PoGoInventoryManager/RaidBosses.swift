import AppKit
import Foundation

// The raid bosses currently in the game, from ScrapedDuck (LeekDuck): their tiers, names and pictures.

/// A raid tier with the boss's HP, CP multiplier and the raid timer. These aren't in the game master (the server
/// decides them); the values are the ones the community measured, as used by PoGOBase.jl (src/consts.jl) and
/// PogoHub (src/lib/pogo/raid.ts). Shadow bosses keep the HP but hit harder; their enrage isn't counted.
enum RaidTier: String, CaseIterable {
    case t5, mega, megaLegendary, elite, s5, t3, s3, t1, s1, other

    var hp: Double? {
        switch self {
        case .t1, .s1: 600
        case .t3, .s3: 3600
        case .t5, .s5: 15000
        case .mega: 9000
        case .megaLegendary: 22500
        case .elite: 20000
        case .other: nil
        }
    }

    var cpm: Double {
        switch self {
        case .t1, .s1: 0.5974
        case .t3: 0.73
        case .s3: 0.76
        case .s5: 0.82
        default: 0.79
        }
    }

    var seconds: Double { [.t1, .s1, .t3, .s3].contains(self) ? 180 : 300 }
    var isShadow: Bool { [.s1, .s3, .s5].contains(self) }

    var label: String {
        switch self {
        case .t1: "1★"
        case .t3: "3★"
        case .t5: "5★"
        case .mega: "Mega"
        case .megaLegendary: tr("Mega legendární", "Mega Legendary")
        case .elite: tr("Elitní", "Elite")
        case .s1: "Shadow 1★"
        case .s3: "Shadow 3★"
        case .s5: "Shadow 5★"
        case .other: tr("Ostatní", "Other")
        }
    }

    /// ScrapedDuck's tier ("5-Star Raids", "Mega Raids") and whether the name starts with "Shadow".
    static func from(_ raw: String, shadow: Bool) -> RaidTier {
        let t = raw.lowercased()
        if t.contains("mega") || t.contains("primal") { return t.contains("legendary") ? .megaLegendary : .mega }
        if t.contains("elite") { return .elite }
        if t.contains("5") { return shadow ? .s5 : .t5 }
        if t.contains("3") { return shadow ? .s3 : .t3 }
        if t.contains("1") { return shadow ? .s1 : .t1 }
        return .other
    }
}

struct RaidBoss: Identifiable, Equatable {
    let name: String           // "Shadow Thundurus (Incarnate)"
    let tier: RaidTier
    let types: [String]
    let cp: ClosedRange<Int>?
    let cpBoosted: ClosedRange<Int>?
    let weather: [String]      // weather that boosts it: "sunny", "partly cloudy" …
    let image: URL?
    let form: String?          // PvPoke id; nil = IVory doesn't have this boss in its data yet

    var id: String { name }
}

/// raids.min.json from ScrapedDuck (https://github.com/bigfoott/ScrapedDuck), which reads LeekDuck.com.
struct ScrapedRaid: Decodable {
    struct Named: Decodable { let name: String }
    struct Range: Decodable { let min: Int; let max: Int }
    struct CP: Decodable { let normal: Range?; let boosted: Range? }
    let name: String
    let tier: String
    let types: [Named]?
    let combatPower: CP?
    let boostedWeather: [Named]?
    let image: String?
}

/// Boss names from LeekDuck matched to PvPoke forms: "Mega Charizard X" → charizard_mega_x,
/// "Hisuian Lilligant" → lilligant_hisuian, "Astronaut Pikachu" (a costume) → pikachu.
struct BossNames {
    private var byName: [String: String] = [:]

    init(_ battle: GameData.Battle?) {
        for (id, form) in battle?.pokemon ?? [:] where !id.hasSuffix("_shadow") {
            let key = form.name.lowercased()
            if byName[key] == nil || id.count < (byName[key]?.count ?? 0) { byName[key] = id }
        }
    }

    func form(for raw: String) -> String? {
        var name = raw
        if name.hasPrefix("Shadow ") { name.removeFirst(7) }
        var suffix: String?
        for (prefix, form) in [("Mega ", "Mega"), ("Primal ", "Primal"), ("Alolan ", "Alolan"), ("Galarian ", "Galarian"),
                               ("Hisuian ", "Hisuian"), ("Paldean ", "Paldean")] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            suffix = form
        }
        var candidates: [String] = []
        if let suffix {
            if suffix == "Mega", let last = name.split(separator: " ").last, ["X", "Y"].contains(last) {
                let base = name.dropLast(2)
                candidates.append("\(base) (Mega \(last))")
            }
            candidates.append("\(name) (\(suffix))")
        }
        candidates.append(name)
        let words = name.split(separator: " ")
        if words.count > 1 { candidates += (1..<words.count).map { words[$0...].joined(separator: " ") } }   // costumes
        return candidates.lazy.compactMap { byName[$0.lowercased()] }.first
    }
}

/// Boss pictures from the link ScrapedDuck gives, downloaded when first shown and kept in ~/Library/Caches/IVory/raids.
@MainActor
enum BossImages {
    private static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IVory/raids")
    private static var loaded: [URL: NSImage] = [:]
    private static var failed: Set<URL> = []

    static func cached(_ url: URL) -> NSImage? {
        if let img = loaded[url] { return img }
        if let img = NSImage(contentsOf: file(url)) { loaded[url] = img; return img }
        return nil
    }

    static func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    static func load(_ url: URL) async -> NSImage? {
        if let img = cached(url) { return img }
        guard !failed.contains(url) else { return nil }
        do {
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: body) else { throw URLError(.cannotDecodeContentData) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(to: file(url), options: .atomic)
            loaded[url] = img
            return img
        } catch {
            failed.insert(url)
            return nil
        }
    }

    private static func file(_ url: URL) -> URL {
        let name = url.path.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(String(name.suffix(120)))
    }
}
