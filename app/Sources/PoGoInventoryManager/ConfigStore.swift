import Foundation

// The settings as one value and the store that keeps them in ~/.pogo/config.json for the bot to read.

/// Bot settings. Saved to ~/.pogo/config.json, which runner.load_config (core/ivory/runner.py) reads.
struct AppConfig: Codable, Equatable {
    var udid = ""
    var appleId = ""
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
    /// The setup guide (Setup.swift): finished, the step it was left on, the steps IVory can't check and
    /// the user confirmed by hand, and which iPhone it was done for.
    var setupDone = false
    var setupStep = ""
    var setupConfirmed: [String] = []
    var setupUdid = ""

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
        case appleId = "apple_id"
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
        case setupDone = "setup_done"
        case setupStep = "setup_step"
        case setupConfirmed = "setup_confirmed"
        case setupUdid = "setup_udid"
    }

    init() {}

    /// Lenient decoding: anything missing from the file keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        udid = try c.decodeIfPresent(String.self, forKey: .udid) ?? d.udid
        appleId = try c.decodeIfPresent(String.self, forKey: .appleId) ?? d.appleId
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
        setupDone = (try? c.decodeIfPresent(Bool.self, forKey: .setupDone)) ?? d.setupDone
        setupStep = (try? c.decodeIfPresent(String.self, forKey: .setupStep)) ?? d.setupStep
        setupConfirmed = (try? c.decodeIfPresent([String].self, forKey: .setupConfirmed)) ?? d.setupConfirmed
        setupUdid = (try? c.decodeIfPresent(String.self, forKey: .setupUdid)) ?? d.setupUdid
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

    /// The store the window was built with. Views that need to *watch* the settings keep their
    /// `@EnvironmentObject`; this is for code that only reads or writes them in an action, where observing
    /// would mean redrawing on every change for nothing.
    @MainActor private(set) static var current: ConfigStore?

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        config = Self.load()
        L10n.lang = config.language
        MainActor.assumeIsolated { ConfigStore.current = self }
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
        fresh.appleId = config.appleId
        fresh.language = config.language
        fresh.checkUpdates = config.checkUpdates
        fresh.consentVersion = config.consentVersion
        fresh.consentAt = config.consentAt
        fresh.consentAppVersion = config.consentAppVersion
        fresh.setupDone = config.setupDone
        fresh.setupStep = config.setupStep
        fresh.setupConfirmed = config.setupConfirmed
        fresh.setupUdid = config.setupUdid
        config = fresh
    }
}
