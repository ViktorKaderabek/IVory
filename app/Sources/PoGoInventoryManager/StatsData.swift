import Foundation

/// The most recently computed stats. They load at launch and after every run, so the Stats
/// screen appears immediately when you switch to it (nothing is computed and the cards aren't laid out twice).
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    @Published private(set) var stats: InventoryStats?
    private var loading = false

    func refresh(removeTag: String) {
        guard !loading else { return }
        loading = true
        Task {
            let loaded = await Task.detached(priority: .utility) { InventoryStats.load(removeTag: removeTag) }.value
            stats = loaded
            loading = false
        }
    }
}

/// Stats for the "What IVory knows" screen. Computed only here on the Mac from what the bot saved:
/// the memory (~/.pogo/pamet.json), the storage as of the last read (~/.pogo/last_box.json), species
/// data (core/pokedata.json in the app) and the run folders (~/Desktop/pogo_runs). Nothing is downloaded.
struct InventoryStats {
    struct Named: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct League: Identifiable {
        let key: String          // great / ultra / master
        let top: [String]        // species with rank 1
        var id: String { key }
    }

    struct Run: Identifiable {
        let id: String           // folder name
        let date: Date
        let duration: TimeInterval
        let checked: Int?        // "Checked: N" from the summary (for runs that printed it)
        let errors: Int          // chyba_* folders = recovered errors
    }

    var total = 0                // entries with IVs in the memory
    var withSpecies = 0          // of those, entries with a known species

    var dexOwned = 0
    var dexTotal = 0
    var generations = Array(repeating: 0, count: 9)   // distinct species per generation (1st–9th)

    var ivAverage = 0
    var ivBins: [(lower: Int, count: Int)] = []    // 90–100, 80–89, 70–79, under 70
    var hundos: [String] = []    // species (or the nickname when the species is unknown)
    var nearPerfect = 0          // 98% or more

    var leagues: [League] = []
    var ranked = 0               // entries with a league rank

    var topCP = 0
    var maxCP: [Named] = []      // theoretical CP at L50, strongest species

    var legendary = 0
    var ultraBeast = 0
    var mythical = 0
    var canEvolve = 0
    var duplicateSpecies = 0
    var removable = 0            // entries with the removal tag

    var types: [Named] = []      // all types, most common first
    var typed = 0
    var topSpecies: [Named] = []
    var levels: [(label: String, count: Int)] = []
    var leveled = 0
    var tags: [Named] = []       // in-game tags, most common first

    var runs: [Run] = []         // oldest first

    var isEmpty: Bool { total == 0 }

    // MARK: - Loading

    static func load(removeTag: String) -> InventoryStats {
        var s = InventoryStats()
        let home = FileManager.default.homeDirectoryForCurrentUser
        s.runs = loadRuns(home.appendingPathComponent("Desktop/pogo_runs"))

        guard let mem = decode(Memory.self, home.appendingPathComponent(".pogo/pamet.json")) else { return s }
        let box = mem.box.filter { $0.iv.count == 3 }
        let species = loadSpecies()?.species ?? [:]
        s.total = box.count
        guard !box.isEmpty else { return s }

        // species
        let known = box.compactMap { item in item.sid.flatMap { species[$0] }.map { (item, $0) } }
        s.withSpecies = known.count
        let dexes = Set(known.map(\.1.dex))
        s.dexOwned = dexes.count
        s.dexTotal = Set(species.values.map(\.dex)).count
        for dex in dexes { if let g = generation(dex) { s.generations[g - 1] += 1 } }
        for (_, sp) in known {
            let tags = Set(sp.tags)
            if tags.contains("legendary") { s.legendary += 1 }
            if tags.contains("ultrabeast") { s.ultraBeast += 1 }
            if tags.contains("mythical") { s.mythical += 1 }
            if !sp.evolutions.isEmpty { s.canEvolve += 1 }
        }
        let bySpecies = Dictionary(grouping: known, by: { $0.1.name }).mapValues(\.count)
        s.duplicateSpecies = bySpecies.values.filter { $0 > 1 }.count
        s.topSpecies = bySpecies.map { Named(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(3).map { $0 }

        // IV
        let pcts = box.map { pct($0.iv) }
        s.ivAverage = Int((Double(pcts.reduce(0, +)) / Double(pcts.count)).rounded())
        s.ivBins = [90, 80, 70, 0].map { lower in
            let upper = lower == 90 ? 101 : (lower == 0 ? 70 : lower + 10)
            return (lower, pcts.filter { $0 >= lower && $0 < upper }.count)
        }
        s.hundos = box.filter { $0.iv == [15, 15, 15] }
            .map { item in item.sid.flatMap { species[$0]?.name } ?? item.name ?? "?" }
        s.nearPerfect = pcts.filter { $0 >= 98 }.count

        // strength, types, levels, tags
        s.topCP = box.compactMap(\.cp).max() ?? 0
        var typeCount: [String: Int] = [:]
        for item in box {
            let types = item.types ?? []
            if !types.isEmpty { s.typed += 1 }
            for t in types { typeCount[t, default: 0] += 1 }
        }
        s.types = typeCount.map { Named(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let lv = box.compactMap(\.level)
        s.leveled = lv.count
        s.levels = [("1–9", 1.0, 10.0), ("10–19", 10, 20), ("20–29", 20, 30), ("30–39", 30, 40), ("40+", 40, 99)]
            .map { label, lo, hi in (label, lv.filter { $0 >= lo && $0 < hi }.count) }
            .filter { $0.count > 0 }
        var tagCount: [String: Int] = [:]
        for item in box { for t in Set(item.tags ?? []) { tagCount[t, default: 0] += 1 } }
        s.tags = tagCount.map { Named(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        s.removable = tagCount[removeTag] ?? 0

        // PvP ranks and max CP from the storage as of the last read
        if let last = decode(LastBoxFile.self, home.appendingPathComponent(".pogo/last_box.json")) {
            let values = last.items.compactMap(\.values)
            s.ranked = values.filter { $0["great"] != nil || $0["ultra"] != nil || $0["master"] != nil }.count
            s.leagues = ["great", "ultra", "master"].map { key in
                let top = values.filter { $0[key].map { $0.dropFirst() == "1" } ?? false }.compactMap { $0["species"] }
                return League(key: key, top: unique(top))
            }
            var best: [String: Int] = [:]
            for v in values {
                guard let name = v["species"], let cp = v["cpMax"].flatMap(Int.init) else { continue }
                best[name] = max(best[name] ?? 0, cp)
            }
            s.maxCP = best.map { Named(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }.prefix(2).map { $0 }
        }
        return s
    }

    // MARK: - Helpers

    static func pct(_ iv: [Int]) -> Int { Int((Double(iv.reduce(0, +)) / 45 * 100).rounded()) }

    private static func generation(_ dex: Int) -> Int? {
        let ends = [151, 251, 386, 493, 649, 721, 809, 905, 1025]
        return ends.firstIndex { dex <= $0 }.map { $0 + 1 }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// core/pokedata.json: in Resources/core inside the app, next to the sources during development.
    private static func loadSpecies() -> PokeData? {
        if let url = Bundle.main.url(forResource: "pokedata", withExtension: "json", subdirectory: "core"),
           let data = decode(PokeData.self, url) {
            return data
        }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../core/pokedata.json").standardizedFileURL
        return decode(PokeData.self, repo)
        #else
        return nil
        #endif
    }

    /// Runs from the folders in pogo_runs (folder name = run start), duration from the timestamps in log.txt.
    private static func loadRuns(_ root: URL) -> [Run] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyyMMdd_HHmmss"
        let checkedRe = try? NSRegularExpression(pattern: "(?:Prošlo|Checked): (\\d+)")
        return names.sorted().compactMap { name -> Run? in
            guard let date = parse.date(from: name) else { return nil }
            let dir = root.appendingPathComponent(name)
            let errors = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("chyba") }.count
            var duration: TimeInterval = 0
            var checked: Int?
            if let log = try? String(contentsOf: dir.appendingPathComponent("log.txt"), encoding: .utf8) {
                let stamps = log.split(separator: "\n").compactMap { seconds(of: $0) }
                if let first = stamps.first, let last = stamps.last {
                    duration = last >= first ? last - first : last + 86_400 - first
                }
                let range = NSRange(log.startIndex..., in: log)
                if let m = checkedRe?.matches(in: log, range: range).last, let r = Range(m.range(at: 1), in: log) {
                    checked = Int(log[r])
                }
            }
            return Run(id: name, date: date, duration: duration, checked: checked, errors: errors)
        }
    }

    /// "HH:mm:ss …" at the start of a log line → seconds since midnight.
    private static func seconds(of line: Substring) -> TimeInterval? {
        let p = line.prefix(8).split(separator: ":")
        guard line.count >= 8, p.count == 3, let h = Int(p[0]), let m = Int(p[1]), let s = Int(p[2]) else { return nil }
        return TimeInterval(h * 3600 + m * 60 + s)
    }

    // MARK: - Files

    private struct Memory: Decodable {
        struct Item: Decodable {
            let cp: Int?
            let name: String?
            let types: [String]?
            let iv: [Int]
            let tags: [String]?
            let sid: String?
            let level: Double?
        }
        let box: [Item]
    }

    private struct PokeData: Decodable {
        struct Species: Decodable {
            let name: String
            let dex: Int
            let evolutions: [String]
            let tags: [String]
        }
        let species: [String: Species]
    }

    private struct LastBoxFile: Decodable {
        struct Item: Decodable { let values: [String: String]? }
        let items: [Item]
    }
}
