import Foundation

/// 8 barev tagů, které hra nabízí (pořadí jako ve hře).
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

/// Jeden IV tag: od kolika procent IV se kus do tagu zařadí a jakou barvu tag ve hře dostane.
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

/// Které kroky běh udělá. Pořadí je vždy Duplicity → IV tagy → PvP tagy → Přejmenování.
struct Steps: Codable, Equatable {
    var duplicates = true
    var iv = true
    var pvp = false
    var rename = false

    /// Pro bota: --steps duplicates,iv,pvp,rename
    var argument: String {
        [("duplicates", duplicates), ("iv", iv), ("pvp", pvp), ("rename", rename)]
            .filter(\.1).map(\.0).joined(separator: ",")
    }

    var count: Int { [duplicates, iv, pvp, rename].filter { $0 }.count }
}

/// PvP liga: tag dostane kus s pořadím IV do maxRank.
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

/// Dílek šablony jména: k = druh dílku (iv, ivs, lvl, species, short, evo, cpEvo, cpMax,
/// great, ultra, master, text, space, dash, pipe), v = vlastní text.
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

    /// Pro bota: jen když je přepínač zapnutý.
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

/// Nastavení bota. Ukládá se do ~/.pogo/config.json, odkud ho čte core/pogo_bot.py.
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
    var language = AppLanguage.system
    /// Kontrolovat aktualizace při spuštění a jednou za 24 hodin (Updater.swift).
    var checkUpdates = true
    /// Souhlas s upozorněním na rizika (okno při prvním spuštění, viz Consent.swift): verze textu,
    /// kdy a ve které verzi aplikace. Stejná pole zapisuje i scripts/run.sh po potvrzení v Terminálu.
    var consentVersion = 0
    var consentAt = ""
    var consentAppVersion = ""

    /// Co bot napíše do pole Search v inventáři (kusy, mezi kterými hledá duplicity).
    static let defaultSearchQuery = "count & !legendary & !ultra beasts"

    /// IV tagy od nejlepšího: žlutá, oranžová, fialová, modrá, zelená, šedá, černá.
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

    /// Všechny tagy, které bot používá (pro panel tagů a výběr „Jen kusy s tagem“).
    var allTagNames: [String] {
        [removeTag] + ivTags.sorted { $0.min > $1.min }.map(\.name).filter { !$0.isEmpty } + pvp.all.map(\.league.name)
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
        case steps, pvp, rename, language
        case checkUpdates = "check_updates"
        case consentVersion = "consent_version"
        case consentAt = "consent_at"
        case consentAppVersion = "app_version"
    }

    init() {}

    /// Tolerantní načtení: co v souboru chybí, zůstane výchozí.
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

    /// Obchod pro aplikaci. V ladicím náhledu (IVORY_PREVIEW) a při focení (IVORY_SHOTS) se nic neukládá.
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

    /// Ukládá se samo chvilku po každé změně.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
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
