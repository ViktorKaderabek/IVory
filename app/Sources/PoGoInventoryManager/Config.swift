import Foundation

/// Jeden IV tag: od kolika procent IV se Pokémon do tagu zařadí.
struct IVTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var min: Int
    var name: String

    enum CodingKeys: String, CodingKey { case min, name }
}

/// Nastavení bota. Ukládá se do ~/.pogo/config.json, odkud ho čte core/pogo_bot.py.
struct AppConfig: Codable, Equatable {
    var udid = ""
    var teamId = ""
    var savedSearch = "duplicit"
    var removeTag = "Removable"
    var keepBest = 1
    var ivTags = AppConfig.defaultIVTags
    var recheckTagged = false
    var ivCacheHours = 6
    var maxGroups = 0

    static let defaultIVTags = [
        IVTag(min: 100, name: "100% Perfect"),
        IVTag(min: 95, name: "95-99% Insane"),
        IVTag(min: 90, name: "90-95% Amazing"),
        IVTag(min: 85, name: "85-90% Great"),
        IVTag(min: 80, name: "80-85% Good"),
        IVTag(min: 70, name: "70-80% Mid"),
        IVTag(min: 0, name: "70-0% Garbage"),
    ]

    enum CodingKeys: String, CodingKey {
        case udid
        case teamId = "team_id"
        case savedSearch = "saved_search"
        case removeTag = "remove_tag"
        case keepBest = "keep_best"
        case ivTags = "iv_tags"
        case recheckTagged = "recheck_tagged"
        case ivCacheHours = "iv_cache_hours"
        case maxGroups = "max_groups"
    }

    init() {}

    /// Tolerantní načtení: co v souboru chybí, zůstane výchozí.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        udid = try c.decodeIfPresent(String.self, forKey: .udid) ?? d.udid
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId) ?? d.teamId
        savedSearch = try c.decodeIfPresent(String.self, forKey: .savedSearch) ?? d.savedSearch
        removeTag = try c.decodeIfPresent(String.self, forKey: .removeTag) ?? d.removeTag
        keepBest = try c.decodeIfPresent(Int.self, forKey: .keepBest) ?? d.keepBest
        ivTags = try c.decodeIfPresent([IVTag].self, forKey: .ivTags) ?? d.ivTags
        recheckTagged = try c.decodeIfPresent(Bool.self, forKey: .recheckTagged) ?? d.recheckTagged
        ivCacheHours = try c.decodeIfPresent(Int.self, forKey: .ivCacheHours) ?? d.ivCacheHours
        maxGroups = try c.decodeIfPresent(Int.self, forKey: .maxGroups) ?? d.maxGroups
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pogo/config.json")

    @Published var config: AppConfig {
        didSet { if config != oldValue { scheduleSave() } }
    }
    @Published private(set) var savedAt: Date?
    @Published private(set) var error: String?

    private var saveTask: Task<Void, Never>?

    init() {
        config = Self.load()
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
        do {
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: Self.url, options: .atomic)
            savedAt = Date()
            error = nil
        } catch {
            self.error = "Nastavení se nepodařilo uložit: \(error.localizedDescription)"
        }
    }

    func resetKeepingDevice() {
        var fresh = AppConfig()
        fresh.udid = config.udid
        fresh.teamId = config.teamId
        config = fresh
    }
}
