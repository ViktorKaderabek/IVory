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
            MonImages.reset(for: loaded)
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

    /// One Pokémon from the memory, with what is known about its species. The cards count these and
    /// the window behind a card lists them.
    struct Mon: Identifiable {
        let id: Int
        let species: String?      // species name ("Dragonite"); nil when the bot didn't recognize it
        let gameName: String      // the name in the game (a nickname after renaming)
        let dex: Int?
        let types: [String]       // lower case, the primary type first
        let iv: [Int]             // attack / defense / HP
        let cp: Int
        let level: Double?
        let tags: [String]
        let legendary: Bool
        let ultraBeast: Bool
        let mythical: Bool
        let canEvolve: Bool
        let readAt: Date?         // when the bot first read it
        let ranks: [String: Int]  // great / ultra / master → rank among the 4,096 IV combinations (1 = best)
        let maxCP50: Int?         // this species at level 50 with these IVs
        /// First read by the last run (false for everyone when the last run read the whole memory afresh).
        var isNew = false

        var name: String { species ?? gameName }
        var pct: Int { InventoryStats.pct(iv) }
        var gen: Int? { dex.flatMap(InventoryStats.generation) }
        var levelText: String? { level.map { $0.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int($0))" : String(format: "%.1f", $0) } }
        /// The best rank in any league.
        var bestRank: (league: String, rank: Int)? {
            ranks.min { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }

    struct Run: Identifiable, Codable {
        let id: String           // folder name (the run start)
        let date: Date
        let duration: TimeInterval
        let checked: Int?        // "Checked: N" from the summary (for runs that printed it)
        let errors: Int          // chyba_* folders = recovered errors
    }

    /// IV bins of the IV card: label, bounds, the in-game search with stars.
    struct IVBin {
        let lower: Int
        let upper: Int           // exclusive
        let count: Int
    }

    /// Level bins of the Levels card.
    struct LevelBin {
        let label: String
        let lower: Double
        let upper: Double        // exclusive
        let count: Int
    }

    static let regions = ["Kanto", "Johto", "Hoenn", "Sinnoh", "Unova", "Kalos", "Alola", "Galar", "Paldea"]

    var mons: [Mon] = []
    var runs: [Run] = []         // oldest first
    var removeTag = "Removable"

    var withSpecies = 0          // entries with a known species
    var dexOwned = 0
    var dexTotal = 0
    var generations = Array(repeating: 0, count: 9)        // distinct species per generation (1st–9th)
    var generationTotals = Array(repeating: 0, count: 9)   // species per generation in the species data
    var newSpecies = 0           // species the last run read for the first time

    var ivAverage = 0
    var ivBins: [IVBin] = []     // 90–100, 80–89, 70–79, under 70
    var hundos: [Mon] = []       // new today first, then by CP
    var nearPerfect = 0          // 98% or more

    var ranked = 0               // entries with at least one league rank
    var topCP: Mon?

    var legendary = 0
    var ultraBeast = 0
    var mythical = 0
    var canEvolve = 0
    var duplicateSpecies = 0
    var removable = 0            // entries with the removal tag

    var types: [Named] = []      // all types, most common first
    var typed = 0
    var topSpecies: [Named] = []
    var levels: [LevelBin] = []
    var leveled = 0
    var tags: [Named] = []       // in-game tags, most common first

    var total: Int { mons.count }
    var isEmpty: Bool { mons.isEmpty }

    // MARK: - Loading

    static func load(removeTag: String) -> InventoryStats {
        var s = InventoryStats()
        s.removeTag = removeTag
        let home = FileManager.default.homeDirectoryForCurrentUser
        s.runs = RunHistory.merge(loadRuns(RunResults.root))

        guard let mem = decode(Memory.self, home.appendingPathComponent(".pogo/pamet.json")) else { return s }
        let data = loadSpecies()
        let species = data?.species ?? [:]
        let cpm50 = (data?.cpm.count ?? 0) >= 50 ? data?.cpm[49] : nil
        let values = rankValues(decode(LastBoxFile.self, home.appendingPathComponent(".pogo/last_box.json")))

        s.mons = mem.box.filter { $0.iv.count == 3 }.enumerated().map { i, item in
            let sp = item.sid.flatMap { species[$0] }
            let gameName = item.name ?? item.gname ?? "?"
            let v = values.take(cp: item.cp, iv: item.iv, name: gameName)
            var ranks: [String: Int] = [:]
            for key in ["great", "ultra", "master"] {
                if let r = v?[key].flatMap({ Int($0.dropFirst()) }) { ranks[key] = r }   // "G3597" → 3597
            }
            var maxCP: Int?
            if let st = sp?.stats, st.count == 3, let cpm = cpm50 {
                maxCP = cp(stats: st, iv: item.iv, cpm: cpm)
            }
            let tags = Set(sp?.tags ?? [])
            return Mon(id: i, species: sp?.name, gameName: gameName, dex: sp?.dex,
                       types: (sp?.types ?? item.types ?? []).map { $0.lowercased() },
                       iv: item.iv, cp: item.cp ?? 0, level: item.level, tags: item.tags ?? [],
                       legendary: tags.contains("legendary"), ultraBeast: tags.contains("ultrabeast"),
                       mythical: tags.contains("mythical"), canEvolve: !(sp?.evolutions ?? []).isEmpty,
                       readAt: item.t.map { Date(timeIntervalSince1970: $0) }, ranks: ranks, maxCP50: maxCP)
        }
        guard !s.mons.isEmpty else { return s }
        if s.runs.isEmpty { s.runs = RunHistory.merge(RunHistory.estimate(s.mons.compactMap(\.readAt))) }
        if let start = s.runs.last?.date.addingTimeInterval(-5) {
            let fresh = s.mons.indices.filter { (s.mons[$0].readAt ?? .distantPast) >= start }
            if fresh.count < s.mons.count { for i in fresh { s.mons[i].isNew = true } }
        }
        let mons = s.mons

        // species and regions
        let known = mons.filter { $0.dex != nil }
        s.withSpecies = known.count
        let dexes = Set(known.compactMap(\.dex))
        s.dexOwned = dexes.count
        let allDex = Set(species.values.map(\.dex))
        s.dexTotal = allDex.count
        for dex in allDex { if let g = generation(dex) { s.generationTotals[g - 1] += 1 } }
        for dex in dexes { if let g = generation(dex) { s.generations[g - 1] += 1 } }
        let before = Set(known.filter { !$0.isNew }.compactMap(\.dex))
        s.newSpecies = dexes.subtracting(before).count
        s.legendary = known.filter(\.legendary).count
        s.ultraBeast = known.filter(\.ultraBeast).count
        s.mythical = known.filter(\.mythical).count
        s.canEvolve = known.filter(\.canEvolve).count
        let bySpecies = Dictionary(grouping: known, by: \.name).mapValues(\.count)
        s.duplicateSpecies = bySpecies.values.filter { $0 > 1 }.count
        s.topSpecies = ranked(bySpecies)

        // IV
        s.ivAverage = Int((Double(mons.map(\.pct).reduce(0, +)) / Double(mons.count)).rounded())
        s.ivBins = [(90, 101), (80, 90), (70, 80), (0, 70)].map { lo, hi in
            IVBin(lower: lo, upper: hi, count: mons.filter { $0.pct >= lo && $0.pct < hi }.count)
        }
        s.hundos = mons.filter { $0.pct == 100 }.sorted { $0.isNew != $1.isNew ? $0.isNew : $0.cp > $1.cp }
        s.nearPerfect = mons.filter { $0.pct >= 98 }.count

        // PvP, strength
        s.ranked = mons.filter { !$0.ranks.isEmpty }.count
        s.topCP = mons.max { $0.cp < $1.cp }

        // types, levels, tags
        var typeCount: [String: Int] = [:]
        for m in mons where !m.types.isEmpty {
            s.typed += 1
            for t in m.types { typeCount[t, default: 0] += 1 }
        }
        s.types = typeCount.map { Named(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let lv = mons.compactMap(\.level)
        s.leveled = lv.count
        s.levels = levelBins.map { label, lo, hi in LevelBin(label: label, lower: lo, upper: hi, count: lv.filter { $0 >= lo && $0 < hi }.count) }
            .filter { $0.count > 0 }
        var tagCount: [String: Int] = [:]
        for m in mons { for t in Set(m.tags) { tagCount[t, default: 0] += 1 } }
        s.tags = tagCount.map { Named(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        s.removable = tagCount[removeTag] ?? 0
        return s
    }

    /// Counts by name, the largest first (equal counts alphabetically).
    private static func ranked(_ counts: [String: Int]) -> [Named] {
        counts.map { Named(name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static let levelBins: [(String, Double, Double)] = [("1–9", 1, 10), ("10–19", 10, 20), ("20–29", 20, 30), ("30–39", 30, 40), ("40+", 40, 99)]

    /// Pokémon the bot read for the first time during the run.
    func firstRead(in run: Run) -> [Mon] {
        let end = run.date.addingTimeInterval(run.duration + 120)
        return mons.filter { m in m.readAt.map { $0 >= run.date.addingTimeInterval(-5) && $0 <= end } ?? false }
    }

    // MARK: - Helpers

    static func pct(_ iv: [Int]) -> Int { Int((Double(iv.reduce(0, +)) / 45 * 100).rounded()) }

    static func generation(_ dex: Int) -> Int? {
        let ends = [151, 251, 386, 493, 649, 721, 809, 905, 1025]
        return ends.firstIndex { dex <= $0 }.map { $0 + 1 }
    }

    /// CP like in the game: (attack · √defense · √HP) · CPM² / 10, at least 10.
    private static func cp(stats: [Int], iv: [Int], cpm: Double) -> Int {
        let a = Double(stats[0] + iv[0]), d = Double(stats[1] + iv[1]), h = Double(stats[2] + iv[2])
        return max(10, Int((a * d.squareRoot() * h.squareRoot() * cpm * cpm / 10).rounded(.down)))
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

    /// The PvP ranks from last_box.json, matched to the memory by CP and IVs (and the name when two match).
    private final class RankValues {
        var byKey: [String: [(name: String, values: [String: String])]] = [:]

        func take(cp: Int?, iv: [Int], name: String) -> [String: String]? {
            guard let cp else { return nil }
            let key = "\(cp)|\(iv.map(String.init).joined(separator: "/"))"
            guard var list = byKey[key], !list.isEmpty else { return nil }
            let i = list.firstIndex { $0.name == name } ?? 0
            let found = list.remove(at: i)
            byKey[key] = list
            return found.values
        }
    }

    private static func rankValues(_ file: LastBoxFile?) -> RankValues {
        let r = RankValues()
        for item in file?.items ?? [] {
            guard let cp = item.cp, let iv = item.iv, iv.count == 3, let v = item.values else { continue }
            r.byKey["\(cp)|\(iv.map(String.init).joined(separator: "/"))", default: []].append((item.name ?? "", v))
        }
        return r
    }

    /// Runs from the folders in pogo_runs (folder name = run start), duration from the timestamps in log.txt.
    static func loadRuns(_ root: URL) -> [Run] {
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

    /// The newest screenshot of this Pokémon's IV bars in the run folders (iv/CP883_14-13-14.jpg), if it's still there.
    static func ivShot(of m: Mon) -> URL? {
        let fm = FileManager.default
        let file = "CP\(m.cp)_\(m.iv.map(String.init).joined(separator: "-")).jpg"
        let names = ((try? fm.contentsOfDirectory(atPath: RunResults.root.path)) ?? []).sorted(by: >)
        return names.lazy.map { RunResults.root.appendingPathComponent($0).appendingPathComponent("iv").appendingPathComponent(file) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Files

    private struct Memory: Decodable {
        struct Item: Decodable {
            let cp: Int?
            let name: String?
            let gname: String?
            let types: [String]?
            let iv: [Int]
            let tags: [String]?
            let sid: String?
            let level: Double?
            let t: Double?
        }
        let box: [Item]
    }

    private struct PokeData: Decodable {
        struct Species: Decodable {
            let name: String
            let dex: Int
            let stats: [Int]?
            let types: [String]?
            let evolutions: [String]
            let tags: [String]
        }
        let cpm: [Double]
        let species: [String: Species]
    }

    private struct LastBoxFile: Decodable {
        struct Item: Decodable {
            let cp: Int?
            let name: String?
            let iv: [Int]?
            let values: [String: String]?
        }
        let items: [Item]
    }
}

/// The run history in ~/.pogo/runs.json. The runs found in the pogo_runs folders are added to it on every load,
/// so deleting the results in the settings (or by hand) doesn't erase the history in Stats.
enum RunHistory {
    static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/runs.json") }

    /// The saved history with these runs added (a run still in its folder replaces the saved one); saved again
    /// when something was added. Oldest first.
    static func merge(_ runs: [InventoryStats.Run]) -> [InventoryStats.Run] {
        var byId: [String: InventoryStats.Run] = [:]
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([InventoryStats.Run].self, from: data) {
            for r in saved { byId[r.id] = r }
        }
        let before = byId.count
        var changed = false
        for r in runs {
            if let old = byId[r.id], old.duration == r.duration, old.checked == r.checked, old.errors == r.errors { continue }
            byId[r.id] = r
            changed = true
        }
        let all = byId.values.sorted { $0.date < $1.date }
        if changed || byId.count != before, let data = try? JSONEncoder().encode(all) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return all
    }

    /// Without any history (the results were deleted before it was kept): runs guessed from when the bot first
    /// read each Pokémon in the memory. Reads more than 30 minutes apart belong to different runs; how many
    /// Pokémon a run checked isn't known.
    static func estimate(_ reads: [Date]) -> [InventoryStats.Run] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        var runs: [InventoryStats.Run] = []
        var start: Date?, last: Date?
        func close() {
            if let start, let last {
                runs.append(.init(id: f.string(from: start), date: start, duration: last.timeIntervalSince(start), checked: nil, errors: 0))
            }
        }
        for t in reads.sorted() {
            if let l = last, t.timeIntervalSince(l) > 30 * 60 { close(); start = nil }
            if start == nil { start = t }
            last = t
        }
        close()
        return runs
    }
}
