import AppKit
import CryptoKit
import Foundation

/// Aktualizace z GitHub Releases: při spuštění (a pak jednou za 24 h, když je zapnuté „Kontrolovat
/// automaticky“) se podívá na poslední vydání. Novou verzi stáhne až na pokyn uživatele, ověří
/// otisk SHA-256 a po „Restartovat“ vymění aplikaci za novou a znovu ji spustí.
/// Nikdy nic nespustí sama a během třídění restart nejde.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "ViktorKaderabek/IVory"
    static let assetName = "IVory.dmg"

    struct Release: Equatable {
        let version: String
        let notesURL: URL
        let dmgURL: URL
        let sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)
        case ready(Release, URL)
        case failed(String, Release?)
    }

    @Published private(set) var state = State.idle
    /// Křížek v banneru: schová ho do příštího spuštění (novou verzi pak připomene jen nastavení).
    @Published var bannerHidden = false
    /// Banner chyby jen po akci uživatele (stažení, instalace); chyba automatické kontroly je jen v nastavení.
    @Published private(set) var showErrorBanner = false
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date

    private var downloadTask: Task<Void, Never>?
    private var timer: Timer?

    static var currentVersion: String { Consent.appVersion }

    var release: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .ready(let r, _): return r
        case .failed(_, let r): return r
        default: return nil
        }
    }

    // MARK: - Kontrola

    /// Při spuštění aplikace: zkontrolovat hned a pak každou hodinu ověřit, jestli neuběhlo 24 h.
    func start(automatic: @escaping () -> Bool) {
        #if DEBUG
        if applyPreview() { return }
        #endif
        if automatic() { check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                let u = Updater.shared
                guard automatic(), Date().timeIntervalSince(u.lastCheck ?? .distantPast) > 24 * 3600 else { return }
                u.check()
            }
        }
    }

    func check(manual: Bool = false) {
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                lastCheck = Date()
                UserDefaults.standard.set(lastCheck, forKey: "updateLastCheck")
                if let release, Self.isNewer(release.version, than: Self.currentVersion) {
                    state = .available(release)
                    #if DEBUG
                    if Self.autoTest { download() }
                    #endif
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(manual ? Self.describe(error) : tr("Kontrola aktualizací se nepovedla.",
                                                                   "Couldn't check for updates."), nil)
            }
        }
    }

    /// Poslední vydání z GitHubu. Žádné vydání (404) = není co aktualizovat.
    private static func fetchLatest() async throws -> Release? {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["IVORY_UPDATE_FEED"] {
            return try parse(Data(contentsOf: URL(fileURLWithPath: feed)))
        }
        #endif
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("IVory/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    private static func parse(_ data: Data) throws -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Latest: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset]; let draft: Bool?; let prerelease: Bool? }
        let latest = try JSONDecoder().decode(Latest.self, from: data)
        guard latest.draft != true, latest.prerelease != true,
              let asset = latest.assets.first(where: { $0.name == assetName }) else { return nil }
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        let sha = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, notesURL: latest.html_url, dmgURL: asset.browser_download_url, sha256: sha)
    }

    /// 1.10.0 > 1.9.2 (porovnává čísla, ne text).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Stažení

    func download() {
        guard let release, downloadTask == nil else { return }
        showErrorBanner = false
        state = .downloading(release, 0)
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                let file = try await Self.fetch(release.dmgURL, version: release.version) { progress in
                    Task { @MainActor in
                        if case .downloading = Updater.shared.state { Updater.shared.state = .downloading(release, progress) }
                    }
                }
                if let expected = release.sha256 {
                    let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                    guard digest == expected.lowercased() else {
                        try? FileManager.default.removeItem(at: file)
                        throw UpdateError.checksum
                    }
                }
                state = .ready(release, file)
                #if DEBUG
                if Self.autoTest { installAndRestart() }
                #endif
            } catch is CancellationError {
                state = .available(release)
            } catch {
                if Task.isCancelled { state = .available(release); return }
                state = .failed(Self.describe(error), release)
                showErrorBanner = true
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IVory")
    }

    /// Stáhne soubor s průběhem (0…1) do ~/Library/Caches/IVory.
    private static func fetch(_ url: URL, version: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let target = cacheDir.appendingPathComponent("IVory-\(version).dmg")
        try? FileManager.default.removeItem(at: target)
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let total = max(response.expectedContentLength, 1)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 18 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let p = min(1, Double(received) / Double(total))
                if p - lastReport >= 0.01 { lastReport = p; progress(p) }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
        return target
    }

    // MARK: - Instalace a restart

    /// Připraví novou aplikaci vedle staré, ukončí se a malý skript je po ukončení prohodí a novou spustí.
    /// Když do složky s aplikací nejde zapisovat (nebo běží z DMG), otevře DMG k ruční instalaci.
    func installAndRestart() {
        guard case .ready(let release, let dmg) = state else { return }
        guard !Runner.shared.isRunning else { return }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        let translocated = target.path.contains("/AppTranslocation/") || target.path.hasPrefix("/Volumes/")
        guard !translocated, FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.open(dmg)
            state = .failed(tr("Do složky s aplikací nejde zapisovat. Přetáhni novou verzi z otevřeného DMG do Aplikací.",
                               "Can't write to the app's folder. Drag the new version from the opened DMG to Applications."), release)
            showErrorBanner = true
            return
        }
        do {
            let staged = try Self.stage(dmg: dmg, next: parent.appendingPathComponent(".IVory-update.app"))
            let script = Self.cacheDir.appendingPathComponent("install.sh")
            try """
            #!/bin/bash
            # počká, až se IVory ukončí, prohodí aplikaci za novou a spustí ji
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            if rm -rf "$3" && mv "$2" "$3"; then xattr -dr com.apple.quarantine "$3" 2>/dev/null; fi
            rm -f "$4"
            open "$3"
            """.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, dmg.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(Self.describe(error), release)
            showErrorBanner = true
        }
    }

    /// Připojí DMG, zkontroluje, že v něm je IVory, a zkopíruje ji vedle staré aplikace.
    private static func stage(dmg: URL, next: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ivory-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        let app = mount.appendingPathComponent("IVory.app")
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.badPackage }
        try? FileManager.default.removeItem(at: next)
        try run("/usr/bin/ditto", [app.path, next.path])
        return next
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.tool((tool as NSString).lastPathComponent) }
        return p.terminationStatus
    }

    enum UpdateError: Error {
        case checksum, badPackage, tool(String)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.checksum:
            return tr("Stažený soubor nesedí s otiskem vydání. Zkus to znovu.", "The download doesn't match the release checksum. Try again.")
        case UpdateError.badPackage:
            return tr("V DMG není IVory.", "The DMG doesn't contain IVory.")
        case UpdateError.tool(let name):
            return tr("Instalace selhala (\(name)).", "Installing failed (\(name)).")
        case let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(e.code):
            return tr("Zkontroluj připojení k internetu.", "Check your internet connection.")
        default:
            return tr("Nepovedlo se spojit s GitHubem.", "Couldn't reach GitHub.")
        }
    }

    // MARK: - Náhled (jen pro kontrolu vzhledu)

    #if DEBUG
    /// IVORY_UPDATE_AUTO=1 (s IVORY_UPDATE_FEED): po kontrole sám stáhne a nainstaluje – test celé cesty.
    private static var autoTest: Bool { ProcessInfo.processInfo.environment["IVORY_UPDATE_AUTO"] == "1" }

    /// IVORY_UPDATE_STATE=available|downloading|ready|error nastaví ukázkový stav bez sítě.
    private func applyPreview() -> Bool {
        guard let s = ProcessInfo.processInfo.environment["IVORY_UPDATE_STATE"] else { return false }
        let r = Release(version: "1.1.0", notesURL: URL(string: "https://github.com/\(Self.repo)/releases")!,
                        dmgURL: URL(string: "https://example.invalid/IVory.dmg")!, sha256: nil)
        lastCheck = Date().addingTimeInterval(-300)
        switch s {
        case "available": state = .available(r)
        case "downloading": state = .downloading(r, 0.42)
        case "ready": state = .ready(r, URL(fileURLWithPath: "/dev/null"))
        case "error":
            state = .failed(tr("Zkontroluj připojení k internetu.", "Check your internet connection."), r)
            showErrorBanner = true
        default: state = .upToDate
        }
        return true
    }
    #endif
}
