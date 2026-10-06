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
