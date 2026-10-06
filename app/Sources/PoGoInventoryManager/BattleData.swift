import AppKit
import Foundation

/// Everything the Battle screen loads: the game data, the raid bosses (downloaded once a day) and the PvP teams.
@MainActor
final class BattleStore: ObservableObject {
    static let shared = BattleStore()
    static let raidsURL = URL(string: "https://raw.githubusercontent.com/bigfoott/ScrapedDuck/data/raids.min.json")!
    static let cacheURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/raids.json")

    enum DataState: Equatable { case loading, ready, downloading, missing }
    enum BossState: Equatable { case loading, ok, offline, failed }

    @Published private(set) var data: GameData?
    @Published private(set) var dataState = DataState.loading
    @Published private(set) var bosses: [RaidBoss] = []
    @Published private(set) var bossesAt: Date?
    @Published private(set) var bossState = BossState.loading
    @Published private(set) var teams: [PvPLeague: PvPResult] = [:]
    /// A boss to show (a click on its notification); BattleView selects it.
    @Published var focusBoss: String?
    /// A power-up row to open (the link from a PvP team member).
    @Published var focusUpgrade: String?

    private var started = false
    private var fetching = false
    private var raw: [ScrapedRaid] = []
    private var counterCache: [String: RaidResult] = [:]
    private var teamsFor: Int?
    private var alertPending = false      // a fresh boss list waiting for the new-boss check
    private var timer: Timer?

    /// The first time the screen shows: game data and bosses; later only what has gone stale.
    func appear() {
        if !started {
            started = true
            loadData()
            loadCachedBosses()
        }
        if bossesAt.map({ Date().timeIntervalSince($0) > 20 * 3600 }) ?? true { fetchBosses() }
        if timer == nil {             // while IVory stays open, the list is refreshed once a day too
            timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
                Task { @MainActor in
                    let store = BattleStore.shared
                    if store.bossesAt.map({ Date().timeIntervalSince($0) > 20 * 3600 }) ?? true { store.fetchBosses() }
                }
            }
        }
    }

    func retry() { fetchBosses() }

    /// Raid counters for a boss in a weather, computed once.
    func counters(_ boss: RaidBoss, weather: String, mons: [InventoryStats.Mon]) -> RaidResult? {
        guard let data, data.battle != nil, boss.form != nil else { return nil }
        let key = "\(boss.id)|\(weather)|\(mons.count)"
        if let hit = counterCache[key] { return hit }
        let result = RaidCalc(data: data).counters(boss, weather: weather, mons: mons)
        counterCache[key] = result
        return result
    }

    /// The Pokémon for the Battle tags (the battle step), from the current storage: the best raid attackers of each
    /// attack type for the Raid tag, the chosen team (IVory's first until one is picked) for each team tag.
    /// nil while the game data or the storage isn't loaded (the last picks stay then).
    func picks(for c: BattleConfig) -> [BattleConfig.Pick]? {
        guard let data, data.battle != nil, let mons = StatsStore.shared.stats?.mons, !mons.isEmpty else { return nil }
        func entry(_ m: InventoryStats.Mon) -> BattleConfig.Pick.Mon { .init(cp: m.cp, iv: m.iv, name: m.gameName, sid: m.sid) }
        var out: [BattleConfig.Pick] = []
        if c.raid.enabled, !c.raid.name.isEmpty {
            var seen = Set<String>(), list: [BattleConfig.Pick.Mon] = []
            let leaders = RaidCalc(data: data).leaders(mons: mons, perType: c.raid.perType)
            for t in leaders.keys.sorted() {
                for counter in leaders[t] ?? [] where seen.insert("\(counter.mon.cp)|\(counter.mon.iv)").inserted {
                    list.append(entry(counter.mon))
                }
            }
            out.append(.init(name: c.raid.name, color: c.raid.color, mons: list))
        }
        for (league, tag) in c.teams where tag.enabled && !tag.name.isEmpty {
            let result = teams[league] ?? PvPCalc(data: data).result(league, mons: mons)
            let team = chosenTeam(result, tag) ?? result.teams.first
            out.append(.init(name: tag.name, color: tag.color, mons: (team?.members ?? []).map { entry($0.mon) }))
        }
        return out
    }

    private var upgradeCache: (stamp: Int, list: [RaidUpgrade])?

    /// Raid attackers worth powering up to L40, the most strength per stardust first (computed once per storage).
    func raidUpgrades(perType: Int, mons: [InventoryStats.Mon]) -> [RaidUpgrade] {
        guard let data, data.battle != nil else { return [] }
        let stamp = mons.count &* 31 &+ mons.reduce(0) { $0 &+ $1.cp } &+ perType
        if let c = upgradeCache, c.stamp == stamp { return c.list }
        let list = RaidCalc(data: data).upgrades(mons: mons, perType: perType)
        upgradeCache = (stamp, list)
        return list
    }

    /// The CP a form with these IVs has at a level.
    func cp(_ stats: [Int], _ iv: [Int], at level: Double) -> Int {
        guard stats.count == 3, iv.count == 3, let data else { return 0 }
        return data.cp(stats, iv, level: level)
    }

    /// What powering a team member up to the league's cap costs.
    func price(_ m: PvPMember) -> GameData.Price {
        data?.battle?.upgrades?.cost(from: m.mon.level ?? m.level, to: m.level) ?? GameData.Price()
    }

    /// The team picked for the tag on the Battle screen, when it's still among the teams.
    func chosenTeam(_ result: PvPResult, _ tag: BattleConfig.TeamTag) -> PvPTeam? {
        guard !tag.team.isEmpty else { return nil }
        return result.teams.first { Set($0.members.map(\.form)) == Set(tag.team) }
    }

    /// PvP teams for all leagues, computed in the background whenever the storage or the data changes.
    func buildTeams(_ mons: [InventoryStats.Mon]) {
        guard let data, data.battle != nil else { return }
        checkAlerts()
        let stamp = mons.count &* 31 &+ mons.reduce(0) { $0 &+ $1.cp }
        guard stamp != teamsFor else { return }
        teamsFor = stamp
        counterCache = [:]
        Task.detached(priority: .userInitiated) {
            let calc = PvPCalc(data: data)
            let out = Dictionary(uniqueKeysWithValues: PvPLeague.allCases.map { ($0, calc.result($0, mons: mons)) })
            await MainActor.run { self.teams = out }
        }
    }

    // MARK: Game data

    private func loadData() {
        dataState = .loading
        Task.detached(priority: .userInitiated) {
            let decoded = (try? Data(contentsOf: GameData.url)).flatMap { try? JSONDecoder().decode(GameData.self, from: $0) }
            let modified = (try? FileManager.default.attributesOfItem(atPath: GameData.url.path)[.modificationDate]) as? Date
            await MainActor.run {
                self.data = decoded
                self.teamsFor = nil
                self.rebuildBosses()   // the matching to forms needs the data
                let stale = modified.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
                if decoded?.battle == nil || stale {
                    self.downloadData(fallback: decoded?.battle == nil ? .missing : .ready)
                } else {
                    self.dataState = .ready
                }
            }
        }
    }

    /// Data from an older IVory has no Battle part (and data older than a week gets refreshed): the bot's
    /// downloader (core/pokedata.py) runs in the bot's Python, which exists once the bot has run.
    private func downloadData(fallback: DataState) {
        let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path), let script = Self.pokedataScript else {
            dataState = fallback
            return
        }
        dataState = fallback == .ready ? .ready : .downloading
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            Task { @MainActor in
                if p.terminationStatus == 0 { self.loadData() } else { self.dataState = fallback }
            }
        }
        do { try process.run() } catch { dataState = fallback }
    }

    /// core/pokedata.py: in Resources/core inside the app, next to the sources during development.
    private static var pokedataScript: URL? {
        if let url = Bundle.main.url(forResource: "pokedata", withExtension: "py", subdirectory: "core") { return url }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../core/pokedata.py").standardizedFileURL
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
        #else
        return nil
        #endif
    }

    // MARK: Bosses

    /// The last downloaded list (~/.pogo/raids.json, as ScrapedDuck sends it; downloaded = the file's date).
    private func loadCachedBosses() {
        guard let body = try? Data(contentsOf: Self.cacheURL),
              let list = try? JSONDecoder().decode([ScrapedRaid].self, from: body) else { return }
        raw = list
        bossesAt = (try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path)[.modificationDate]) as? Date
        bossState = .ok
        rebuildBosses()
    }

    fileprivate func fetchBosses() {
        guard !fetching else { return }
        fetching = true
        if bosses.isEmpty { bossState = .loading }
        Task {
            defer { fetching = false }
            do {
                var request = URLRequest(url: Self.raidsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("IVory", forHTTPHeaderField: "User-Agent")
                let (body, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let list = try JSONDecoder().decode([ScrapedRaid].self, from: body)
                try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? body.write(to: Self.cacheURL, options: .atomic)
                raw = list
                bossesAt = Date()
                bossState = .ok
                alertPending = true
                rebuildBosses()
            } catch {
                bossState = bosses.isEmpty ? .failed : .offline
            }
        }
    }

    /// The bosses matched to the game data (the matching needs the data, so it runs again once it loads).
    private func rebuildBosses() {
        let index = BossNames(data?.battle)
        bosses = raw.map { r in
            let shadow = r.name.hasPrefix("Shadow ")
            let form = index.form(for: r.name)
            let types = form.flatMap { data?.battle?.pokemon[$0]?.types } ?? (r.types ?? []).map { $0.name.lowercased() }
            return RaidBoss(name: r.name, tier: .from(r.tier, shadow: shadow), types: types,
                            cp: r.combatPower?.normal.map { $0.min...max($0.min, $0.max) },
                            cpBoosted: r.combatPower?.boosted.map { $0.min...max($0.min, $0.max) },
                            weather: (r.boostedWeather ?? []).map { $0.name.lowercased() },
                            image: r.image.flatMap(URL.init(string:)), form: form)
        }
        counterCache = [:]
        checkAlerts()
    }

    /// New bosses in a fresh list get their notification once the game data and the storage are there.
    private func checkAlerts() {
        guard alertPending, data?.battle != nil, !bosses.isEmpty else { return }
        if BossAlerts.check(bosses, store: self) { alertPending = false }
    }

    private init() {}

    #if DEBUG
    /// Windowless snapshots: everything loaded synchronously, without downloading.
    func loadNow(mons: [InventoryStats.Mon]) {
        started = true
        data = (try? Data(contentsOf: GameData.url)).flatMap { try? JSONDecoder().decode(GameData.self, from: $0) }
        dataState = data?.battle == nil ? .missing : .ready
        loadCachedBosses()
        if let data, data.battle != nil {
            for league in PvPLeague.allCases { teams[league] = PvPCalc(data: data).result(league, mons: mons) }
            teamsFor = mons.count &* 31 &+ mons.reduce(0) { $0 &+ $1.cp }
        }
    }

    /// `--battle-dump`: the counters and win chances for every cached boss, the teams and the Battle tag picks, as
    /// text (checking the math).
    func dump() {
        let mons = InventoryStats.load(removeTag: "Removable").mons
        loadNow(mons: mons)
        if let data {
            let leaders = RaidCalc(data: data).leaders(mons: mons, perType: 6)
            for t in leaders.keys.sorted() {
                print("Raid \(t):", leaders[t]!.map { "\($0.mon.name) L\($0.mon.level ?? 0)" }.joined(separator: ", "))
            }
            let upgrades = RaidCalc(data: data).upgrades(mons: mons, perType: 6)
            for u in upgrades {
                print("  up \(u.counter.mon.name) \(u.type) #\(u.rankNow.map(String.init) ?? "–")→#\(u.rankAfter) " +
                      "+\(Int(u.gain * 100))% \(u.price.stardust) dust")
            }
        }
        for boss in RaidTier.allCases.flatMap({ t in bosses.filter { $0.tier == t } }) {
            guard let r = counters(boss, weather: "none", mons: mons) else { print("\(boss.tier.label)\t\(boss.name)\t– no data"); continue }
            let top = r.counters.prefix(3).map { "\($0.mon.name) \(Int($0.dps)) DPS \(Int($0.tdo)) TDO" }.joined(separator: ", ")
            print("\(boss.tier.label)\t\(boss.name)\t\(r.chances.map { $0.map(String.init).joined(separator: "/") } ?? "–")\t\(top)")
        }
        for league in PvPLeague.allCases {
            guard let r = teams[league] else { continue }
            print(league.name, "–", r.candidates, "candidates")
            for t in r.teams {
                print("  \(t.answered)/\(t.faced)", t.members.map { "\($0.role.title): \($0.mon.name)→\($0.formName) #\($0.rank)" },
                      "strong:", t.strong.count, "weak:", t.weak.joined(separator: ","))
            }
        }
    }
    #endif
}
