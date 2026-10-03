import AppKit
import CryptoKit
import Foundation

/// Updates from GitHub Releases: at launch (and then once every 24 h while "Check automatically" is on)
/// it looks up the latest release. It downloads a new version only when the user asks, verifies the
/// SHA-256 checksum (when the release provides one) and, after "Restart", replaces the app with the new
/// one and relaunches it. It never installs anything on its own, and restarting is not possible while sorting.
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
    /// The banner's close button: hides it until the next launch (until then, only the settings mention the new version).
    @Published var bannerHidden = false
    /// Error banner only after a user action (download, install); a failed automatic check shows only in the settings.
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

    // MARK: - Checking

    /// At app launch: check right away, then every hour see whether 24 h have passed.
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

    /// The latest release from GitHub. No release (404) = nothing to update.
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

    /// 1.10.0 > 1.9.2 (compares numbers, not text).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download

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

    /// Downloads the file to ~/Library/Caches/IVory, reporting progress (0…1).
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

    // MARK: - Install and restart

    /// Stages the new app next to the old one and quits; once it has quit, a small script swaps the two
    /// and launches the new one. If the app's folder isn't writable (or the app runs from the DMG),
    /// it opens the DMG for a manual install.
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

    /// Mounts the DMG, checks that it contains IVory and copies it next to the old app.
    private static func stage(dmg: URL, next: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ivory-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
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

    // MARK: - Preview states (for checking the look only)

    #if DEBUG
    /// IVORY_UPDATE_AUTO=1 (with IVORY_UPDATE_FEED): downloads and installs right after the check – an end-to-end test.
    private static var autoTest: Bool { ProcessInfo.processInfo.environment["IVORY_UPDATE_AUTO"] == "1" }

    /// IVORY_UPDATE_STATE=available|downloading|ready|error sets a sample state without any network access.
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
