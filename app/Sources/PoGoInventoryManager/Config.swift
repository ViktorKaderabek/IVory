import Foundation

/// The 8 tag colors the game offers (in the game's order).
enum TagColor: String, Codable, CaseIterable, Identifiable {
    case blue, green, purple, yellow, red, orange, gray, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return tr("Modrá", "Blue")
        case .green: return tr("Zelená", "Green")
        case .purple: return tr("Fialová", "Purple")
        case .yellow: return tr("Žlutá", "Yellow")
        case .red: return tr("Červená", "Red")
        case .orange: return tr("Oranžová", "Orange")
        case .gray: return tr("Šedá", "Gray")
        case .black: return tr("Černá", "Black")
        }
    }
}

/// One IV tag: the IV percentage from which a Pokémon goes into the tag, and the tag's color in the game.
struct IVTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var min: Int
    var name: String
    var color: TagColor = .gray

    enum CodingKeys: String, CodingKey { case min, name, color }

    init(min: Int, name: String, color: TagColor = .gray) {
        self.min = min
        self.name = name
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = try c.decodeIfPresent(Int.self, forKey: .min) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? c.decodeIfPresent(TagColor.self, forKey: .color)) ?? AppConfig.defaultColor(forIVTag: name, min: min)
    }
}

/// Which steps a run does. The order is always duplicates → IV tags → PvP tags → renaming → Battle tags.
struct Steps: Codable, Equatable {
    var duplicates = true
    var iv = true
    var pvp = false
    var rename = false
    var battle = false
    var weak = false

    /// For the bot: --steps duplicates,iv,pvp,rename,battle,weak
    var argument: String {
        [("duplicates", duplicates), ("iv", iv), ("pvp", pvp), ("rename", rename), ("battle", battle), ("weak", weak)]
            .filter(\.1).map(\.0).joined(separator: ",")
    }

    var count: Int { [duplicates, iv, pvp, rename, battle, weak].filter { $0 }.count }
}

extension Steps {
    /// Lenient decoding (a config.json from before the Battle step keeps its steps); in an extension so the
    /// memberwise initializer stays.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Steps()
        self.init(duplicates: try c.decodeIfPresent(Bool.self, forKey: .duplicates) ?? d.duplicates,
                  iv: try c.decodeIfPresent(Bool.self, forKey: .iv) ?? d.iv,
                  pvp: try c.decodeIfPresent(Bool.self, forKey: .pvp) ?? d.pvp,
                  rename: try c.decodeIfPresent(Bool.self, forKey: .rename) ?? d.rename,
                  battle: try c.decodeIfPresent(Bool.self, forKey: .battle) ?? d.battle,
                  weak: try c.decodeIfPresent(Bool.self, forKey: .weak) ?? d.weak)
    }
}

/// Weak Pokémon (the weak step): everyone under maxIV % gets the Removable tag, except the ones the keep
/// switches protect. The bot can't tell shadow, lucky or Dynamax apart, so for those there is keepTag: a tag
/// you put on them in the game yourself.
struct WeakConfig: Codable, Equatable {
    var maxIV = 70
    var keepLegendary = true
    var keepMythical = true
    var keepUltraBeast = true
    var keepRegional = true
    var keepBest = true
    var keepBattle = true
    var keepTag = ""

    enum CodingKeys: String, CodingKey {
        case maxIV = "max_iv"
        case keepLegendary = "keep_legendary"
        case keepMythical = "keep_mythical"
        case keepUltraBeast = "keep_ultra_beast"
        case keepRegional = "keep_regional"
        case keepBest = "keep_best"
        case keepBattle = "keep_battle"
        case keepTag = "keep_tag"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WeakConfig()
        maxIV = (try? c.decodeIfPresent(Int.self, forKey: .maxIV)) ?? d.maxIV
        keepLegendary = (try? c.decodeIfPresent(Bool.self, forKey: .keepLegendary)) ?? d.keepLegendary
        keepMythical = (try? c.decodeIfPresent(Bool.self, forKey: .keepMythical)) ?? d.keepMythical
        keepUltraBeast = (try? c.decodeIfPresent(Bool.self, forKey: .keepUltraBeast)) ?? d.keepUltraBeast
        keepRegional = (try? c.decodeIfPresent(Bool.self, forKey: .keepRegional)) ?? d.keepRegional
        keepBest = (try? c.decodeIfPresent(Bool.self, forKey: .keepBest)) ?? d.keepBest
        keepBattle = (try? c.decodeIfPresent(Bool.self, forKey: .keepBattle)) ?? d.keepBattle
        keepTag = (try? c.decodeIfPresent(String.self, forKey: .keepTag)) ?? d.keepTag
    }
}

/// Battle tags (the battle step): IVory picks the Pokémon, the bot tags them in the game. "Raid" goes to the best
/// raid attackers of each attack type (found in the game with e.g. #Raid&@steel), a team tag to the PvP team chosen
/// on the Battle screen. The bot takes the tag off anyone who is no longer picked.
struct BattleConfig: Codable, Equatable {
    struct RaidTag: Codable, Equatable {
        var enabled = true
        var name = "Raid"
        var color = TagColor.red
        var perType = 6               // the best this many for each attack type

        enum CodingKeys: String, CodingKey {
            case enabled, name, color
            case perType = "per_type"
        }
    }

    struct TeamTag: Codable, Equatable {
        var enabled = true
        var name: String
        var color: TagColor
        var team: [String] = []       // the chosen team (PvPoke ids); empty = IVory's first team
    }

    /// A tag with the Pokémon picked for it, by CP and IVs (what the bot reads in the game).
    struct Pick: Codable, Equatable {
        struct Mon: Codable, Equatable {
            var cp: Int
            var iv: [Int]
            var name: String
            /// The species, so the bot still finds it after a power-up (CP changes, the IVs don't).
            var sid: String?
        }
        var name: String
        var color: TagColor
        var mons: [Mon]
    }

    var raid = RaidTag()
    var great = TeamTag(name: "GL Team", color: .blue)
    var ultra = TeamTag(name: "UL Team", color: .yellow)
    var master = TeamTag(name: "ML Team", color: .purple)
    /// Notifications about new raid bosses (the app's, the bot doesn't use it).
    var notifyBosses = true
    /// Worked out by the app when a run starts (BattleStore.picks), read by the bot.
    var tags: [Pick] = []

    var teams: [(league: PvPLeague, tag: TeamTag)] { [(.great, great), (.ultra, ultra), (.master, master)] }
    var tagNames: [String] { ([raid.name] + teams.map(\.tag.name)).filter { !$0.isEmpty } }

    func team(_ league: PvPLeague) -> TeamTag { league == .great ? great : league == .ultra ? ultra : master }

    mutating func setTeam(_ league: PvPLeague, _ forms: [String]) {
        switch league {
        case .great: great.team = forms
        case .ultra: ultra.team = forms
        case .master: master.team = forms
        }
    }

    enum CodingKeys: String, CodingKey {
        case raid, great, ultra, master, tags
        case notifyBosses = "notify_bosses"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BattleConfig()
        raid = (try? c.decodeIfPresent(RaidTag.self, forKey: .raid)) ?? d.raid
        great = (try? c.decodeIfPresent(TeamTag.self, forKey: .great)) ?? d.great
        ultra = (try? c.decodeIfPresent(TeamTag.self, forKey: .ultra)) ?? d.ultra
        master = (try? c.decodeIfPresent(TeamTag.self, forKey: .master)) ?? d.master
        notifyBosses = (try? c.decodeIfPresent(Bool.self, forKey: .notifyBosses)) ?? d.notifyBosses
        tags = (try? c.decodeIfPresent([Pick].self, forKey: .tags)) ?? d.tags
    }
}

/// PvP league: a Pokémon whose IV rank is within maxRank gets the tag.
struct League: Codable, Equatable {
    var name: String
    var enabled = true
    var maxRank: Int
    var color: TagColor

    enum CodingKeys: String, CodingKey {
        case name, enabled, color
        case maxRank = "max_rank"
    }
}

struct PvPConfig: Codable, Equatable {
    var great = League(name: "Great League", maxRank: 100, color: .blue)
    var ultra = League(name: "Ultra League", maxRank: 100, color: .yellow)
    var master = League(name: "Master League", maxRank: 50, color: .purple)

    static var caps: [String: String] {
        ["great": tr("do 1 500 CP", "up to 1,500 CP"), "ultra": tr("do 2 500 CP", "up to 2,500 CP"),
         "master": tr("bez limitu CP", "no CP limit")]
    }

    var all: [(key: String, league: League)] {
        [("great", great), ("ultra", ultra), ("master", master)]
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PvPConfig()
        great = (try? c.decodeIfPresent(League.self, forKey: .great)) ?? d.great
        ultra = (try? c.decodeIfPresent(League.self, forKey: .ultra)) ?? d.ultra
        master = (try? c.decodeIfPresent(League.self, forKey: .master)) ?? d.master
    }

    enum CodingKeys: String, CodingKey { case great, ultra, master }
}

/// A piece of the name template: k = kind of piece (iv, ivs, lvl, species, short, evo, cpEvo, cpMax,
/// great, ultra, master, text, space, dash, pipe), v = custom text.
struct NameToken: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var k: String
    var v: String?

    enum CodingKeys: String, CodingKey { case k, v }

    init(_ k: String, _ v: String? = nil) {
        self.k = k
        self.v = v
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        k = try c.decode(String.self, forKey: .k)
        v = try c.decodeIfPresent(String.self, forKey: .v)
    }
}

struct RenameConfig: Codable, Equatable {
    var min = 85
    var max = 100
    var template = RenameConfig.defaultTemplate
    var overwriteCustom = false
    var skipRemovable = true
    var onlyTagEnabled = false
    var onlyTag = ""

    static let defaultTemplate = [NameToken("iv"), NameToken("space"), NameToken("evo"), NameToken("space"),
                                  NameToken("master")]

    enum CodingKeys: String, CodingKey {
        case min, max, template
        case overwriteCustom = "overwrite_custom"
        case skipRemovable = "skip_removable"
        case onlyTagEnabled = "only_tag_enabled"
        case onlyTag = "only_tag"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenameConfig()
        min = try c.decodeIfPresent(Int.self, forKey: .min) ?? d.min
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? d.max
        template = (try? c.decodeIfPresent([NameToken].self, forKey: .template)) ?? d.template
        overwriteCustom = try c.decodeIfPresent(Bool.self, forKey: .overwriteCustom) ?? d.overwriteCustom
        skipRemovable = try c.decodeIfPresent(Bool.self, forKey: .skipRemovable) ?? d.skipRemovable
        onlyTagEnabled = try c.decodeIfPresent(Bool.self, forKey: .onlyTagEnabled) ?? d.onlyTagEnabled
        onlyTag = try c.decodeIfPresent(String.self, forKey: .onlyTag) ?? d.onlyTag
    }

    /// For the bot: only_tag stays empty unless the toggle is on.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(min, forKey: .min)
        try c.encode(max, forKey: .max)
        try c.encode(template, forKey: .template)
        try c.encode(overwriteCustom, forKey: .overwriteCustom)
        try c.encode(skipRemovable, forKey: .skipRemovable)
        try c.encode(onlyTagEnabled, forKey: .onlyTagEnabled)
        try c.encode(onlyTagEnabled ? onlyTag : "", forKey: .onlyTag)
    }
}

/// Bot settings. Saved to ~/.pogo/config.json, which runner.load_config (core/ivory/runner.py) reads.
struct AppConfig: Codable, Equatable {
    var udid = ""
    var teamId = ""
    var searchQuery = AppConfig.defaultSearchQuery
    var removeTag = "Removable"
    var removeTagColor = TagColor.red
    var keepBest = 1
    var ivTags = AppConfig.defaultIVTags
    var recheckTagged = false
    var maxGroups = 0
    var steps = Steps()
    var pvp = PvPConfig()
    var rename = RenameConfig()
    var battle = BattleConfig()
    var weak = WeakConfig()
    var language = AppLanguage.system
    /// Check for updates at launch and once every 24 hours (Updater.swift).
    var checkUpdates = true
    /// Consent to the risk notice (the window on first launch, see Consent.swift): text version,
    /// when, and in which app version. scripts/run.sh writes the same fields after confirmation in Terminal.
    var consentVersion = 0
    var consentAt = ""
    var consentAppVersion = ""

    /// What the bot types into the storage Search field (the Pokémon it looks for duplicates among).
    static let defaultSearchQuery = "count & !legendary & !ultra beasts"

    /// IV tags from the best: yellow, orange, purple, blue, green, gray, black.
    static let defaultIVTags = [
        IVTag(min: 100, name: "100% Perfect", color: .yellow),
        IVTag(min: 95, name: "95-99% Insane", color: .orange),
        IVTag(min: 90, name: "90-95% Amazing", color: .purple),
        IVTag(min: 85, name: "85-90% Great", color: .blue),
        IVTag(min: 80, name: "80-85% Good", color: .green),
        IVTag(min: 70, name: "70-80% Mid", color: .gray),
        IVTag(min: 0, name: "70-0% Garbage", color: .black),
    ]

    static func defaultColor(forIVTag name: String, min: Int) -> TagColor {
        if let d = defaultIVTags.first(where: { $0.name == name }) { return d.color }
        return defaultIVTags.first(where: { min >= $0.min })?.color ?? .gray
    }

    /// Every tag the bot uses (the choices in the "Only Pokémon with a tag" menu).
    var allTagNames: [String] {
        [removeTag] + ivTags.sorted { $0.min > $1.min }.map(\.name).filter { !$0.isEmpty } + pvp.all.map(\.league.name)
            + battle.tagNames
    }

    enum CodingKeys: String, CodingKey {
        case udid
        case teamId = "team_id"
        case searchQuery = "search_query"
        case removeTag = "remove_tag"
        case removeTagColor = "remove_tag_color"
        case keepBest = "keep_best"
        case ivTags = "iv_tags"
        case recheckTagged = "recheck_tagged"
        case maxGroups = "max_groups"
        case steps, pvp, rename, battle, weak, language
        case checkUpdates = "check_updates"
        case consentVersion = "consent_version"
        case consentAt = "consent_at"
        case consentAppVersion = "app_version"
    }

    init() {}

    /// Lenient decoding: anything missing from the file keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        udid = try c.decodeIfPresent(String.self, forKey: .udid) ?? d.udid
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId) ?? d.teamId
        searchQuery = try c.decodeIfPresent(String.self, forKey: .searchQuery) ?? d.searchQuery
        removeTag = try c.decodeIfPresent(String.self, forKey: .removeTag) ?? d.removeTag
        removeTagColor = (try? c.decodeIfPresent(TagColor.self, forKey: .removeTagColor)) ?? d.removeTagColor
        keepBest = try c.decodeIfPresent(Int.self, forKey: .keepBest) ?? d.keepBest
        ivTags = try c.decodeIfPresent([IVTag].self, forKey: .ivTags) ?? d.ivTags
        recheckTagged = try c.decodeIfPresent(Bool.self, forKey: .recheckTagged) ?? d.recheckTagged

        maxGroups = try c.decodeIfPresent(Int.self, forKey: .maxGroups) ?? d.maxGroups
        steps = (try? c.decodeIfPresent(Steps.self, forKey: .steps)) ?? d.steps
        pvp = (try? c.decodeIfPresent(PvPConfig.self, forKey: .pvp)) ?? d.pvp
        rename = (try? c.decodeIfPresent(RenameConfig.self, forKey: .rename)) ?? d.rename
        battle = (try? c.decodeIfPresent(BattleConfig.self, forKey: .battle)) ?? d.battle
        weak = (try? c.decodeIfPresent(WeakConfig.self, forKey: .weak)) ?? d.weak
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? d.language
        checkUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkUpdates)) ?? d.checkUpdates
        consentVersion = (try? c.decodeIfPresent(Int.self, forKey: .consentVersion)) ?? d.consentVersion
        consentAt = (try? c.decodeIfPresent(String.self, forKey: .consentAt)) ?? d.consentAt
        consentAppVersion = (try? c.decodeIfPresent(String.self, forKey: .consentAppVersion)) ?? d.consentAppVersion
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pogo/config.json")

    @Published var config: AppConfig {
        didSet {
            L10n.lang = config.language
            if config != oldValue { scheduleSave() }
        }
    }
    @Published private(set) var savedAt: Date?
    @Published private(set) var error: String?

    private var saveTask: Task<Void, Never>?
    private let readOnly: Bool

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        config = Self.load()
        L10n.lang = config.language
    }

    /// The ConfigStore the app starts with. Nothing is saved in the debug preview (IVORY_PREVIEW) or while
    /// taking screenshots (IVORY_SHOTS).
    static func launch() -> ConfigStore {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["IVORY_SHOTS"] != nil {
            let store = ConfigStore(readOnly: true)
            store.config = ShotSession.demoConfig
            return store
        }
        if env["IVORY_PREVIEW"] != nil { return ConfigStore(readOnly: true) }
        #endif
        return ConfigStore()
    }

    private static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    /// Saves automatically shortly after every change.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Before a run: with the Battle step on, the Pokémon for the Battle tags are picked now (from the current
    /// storage and game data; when those aren't ready, the last picks stay), then everything is saved for the bot.
    func prepareRun() {
        if config.steps.battle, let picks = BattleStore.shared.picks(for: config.battle) {
            config.battle.tags = picks
        }
        save()
    }

    func save() {
        saveTask?.cancel()
        guard !readOnly else { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: Self.url, options: .atomic)
            savedAt = Date()
            error = nil
        } catch {
            self.error = tr("Nastavení se nepodařilo uložit: ", "Couldn't save the settings: ") + error.localizedDescription
        }
    }

    func resetKeepingDevice() {
        var fresh = AppConfig()
        fresh.udid = config.udid
        fresh.teamId = config.teamId
        fresh.language = config.language
        fresh.checkUpdates = config.checkUpdates
        fresh.consentVersion = config.consentVersion
        fresh.consentAt = config.consentAt
        fresh.consentAppVersion = config.consentAppVersion
        config = fresh
    }
}
