import AppKit
import SwiftUI

/// Pictures of Pokémon, downloaded on first use and kept in ~/Library/Caches/IVory/pokemon.
///
/// Two kinds, as in the design:
///   - `.artwork` – the official render, for the big slots (Now reading, the detail panel, raid cards).
///     By Pokédex number only, so forms share the base species' picture; ~150 kB each.
///   - `.icon` – the game's own icon. It knows the forms (Alolan, Galarian, Hisuian…) and is ~10× smaller,
///     so it is what the lists and thumbnails use.
///
/// Nothing here is essential: when a picture can't be downloaded the views draw their placeholder, and
/// the run doesn't care either way.
@MainActor
enum PokeImages {
    enum Kind { case artwork, icon }

    /// The official artwork, by Pokédex number (PokeAPI/sprites).
    private static let artworkBase =
        "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork"
    /// The game's own icons, extracted from Pokémon GO (PokeMiners/pogo_assets), named the way the game
    /// names them: pm26.fALOLA.icon.png. The same names LeekDuck uses for the raid bosses.
    private static let iconBase =
        "https://raw.githubusercontent.com/PokeMiners/pogo_assets/master/Images/Pokemon/Addressable%20Assets"

    /// PvPoke's species id carries the form ("raichu_alolan"); the game's file name uses its own token
    /// ("ALOLA"). Upper-casing the id's suffix hits it for all but a handful, and those fall through to
    /// the species' plain icon – the right Pokémon, just the base form.
    private static let formAliases = ["alolan": "ALOLA"]

    private static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IVory/pokemon")
    private static var loaded: [String: NSImage] = [:]
    private static var failed: Set<String> = []
    private static var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// The form token of a species id, or nil for a Pokémon without a form ("pikachu").
    /// Shadow forms look the same as the base one and the data has no separate picture for them.
    static func form(_ sid: String?) -> String? {
        guard let sid, let suffix = sid.split(separator: "_", maxSplits: 1).dropFirst().first else { return nil }
        let s = String(suffix)
        if s == "shadow" { return nil }
        return formAliases[s] ?? s.uppercased()
    }

    private static func key(_ kind: Kind, _ dex: Int, _ form: String?) -> String {
        switch kind {
        case .artwork: return "artwork-\(dex)"
        case .icon: return "icon-\(dex)" + (form.map { "-\($0)" } ?? "")
        }
    }

    /// Where the picture is looked for, best first. The chain matters: the game's icon for the exact form,
    /// then the species' plain icon (a few Pokémon exist only in forms, and the newest ones aren't in the
    /// extracted assets yet), then the official artwork, which covers every number.
    private static func sources(_ kind: Kind, _ dex: Int, _ form: String?) -> [URL] {
        let artwork = URL(string: "\(artworkBase)/\(dex).png")
        switch kind {
        case .artwork:
            return [artwork].compactMap { $0 }
        case .icon:
            return [
                form.flatMap { URL(string: "\(iconBase)/pm\(dex).f\($0).icon.png") },
                URL(string: "\(iconBase)/pm\(dex).icon.png"),
                artwork,
            ].compactMap { $0 }
        }
    }

    /// The picture if it is already in memory or on disk – no download, safe to call while drawing.
    static func cached(_ kind: Kind, dex: Int, sid: String? = nil) -> NSImage? {
        let k = key(kind, dex, form(sid))
        if let img = loaded[k] { return img }
        if let img = NSImage(contentsOf: file(k)) {
            loaded[k] = img
            return img
        }
        return nil
    }

    static func hasFailed(_ kind: Kind, dex: Int, sid: String? = nil) -> Bool {
        failed.contains(key(kind, dex, form(sid)))
    }

    /// The picture, downloading it the first time. Several views asking for the same one at once share
    /// a single download.
    static func load(_ kind: Kind, dex: Int, sid: String? = nil) async -> NSImage? {
        let f = form(sid)
        let k = key(kind, dex, f)
        if let img = cached(kind, dex: dex, sid: sid) { return img }
        guard !failed.contains(k) else { return nil }
        if let running = inFlight[k] { return await running.value }

        let task = Task<NSImage?, Never> { [sources = sources(kind, dex, f)] in
            for url in sources {
                guard let (body, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let img = NSImage(data: body) else { continue }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? body.write(to: file(k), options: .atomic)
                return img
            }
            return nil
        }
        inFlight[k] = task
        let img = await task.value
        inFlight[k] = nil
        if let img {
            loaded[k] = img
        } else {
            failed.insert(k)
        }
        return img
    }

    /// Downloads pictures in the background without blocking the caller – for the Pokémon a screen is
    /// about to show.
    static func prefetch(_ kind: Kind, dex: Int, sid: String? = nil) {
        guard cached(kind, dex: dex, sid: sid) == nil, !hasFailed(kind, dex: dex, sid: sid) else { return }
        Task { _ = await load(kind, dex: dex, sid: sid) }
    }

    private static func file(_ key: String) -> URL {
        dir.appendingPathComponent(key + ".png")
    }

    /// How much the pictures take up, for Settings.
    static func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: dir)
        loaded = [:]
        failed = []
    }
}

// MARK: - View

/// A Pokémon's picture, faded in once it has been downloaded. Until then (and for a Pokémon the bot
/// couldn't identify) it shows a quiet placeholder rather than a gap, so a list doesn't jump around.
struct PokeImage: View {
    let dex: Int?
    var sid: String?
    var kind: PokeImages.Kind = .icon
    var size: CGFloat
    /// Plays a short pop when the picture appears – for the big "Now reading" slot, where a new Pokémon
    /// arrives every few seconds. Lists pass false and only fade.
    var pops = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var shown = false

    var body: some View {
        ZStack {
            placeholder
                .opacity(image == nil ? 1 : 0)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(shown || reduceMotion ? 1 : (pops ? 0.86 : 0.97))
                    .opacity(shown || reduceMotion ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.22), value: image == nil)
        .task(id: taskKey) { await reload() }
    }

    private var taskKey: String { "\(dex ?? -1)|\(sid ?? "")|\(kind == .icon ? "i" : "a")" }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Theme.track.opacity(0.45))
            .overlay {
                Circle()
                    .strokeBorder(Theme.muted.opacity(0.25), lineWidth: max(1, size * 0.045))
                    .padding(size * 0.26)
            }
    }

    private func reload() async {
        guard let dex else {
            image = nil
            return
        }
        // already on disk: show it at once, no fade, so scrolling a list doesn't flicker
        if let have = PokeImages.cached(kind, dex: dex, sid: sid) {
            image = have
            shown = true
            return
        }
        image = nil
        shown = false
        let img = await PokeImages.load(kind, dex: dex, sid: sid)
        guard !Task.isCancelled else { return }
        image = img
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.66)) { shown = true }
    }
}
