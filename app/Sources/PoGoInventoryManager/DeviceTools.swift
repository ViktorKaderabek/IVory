import Foundation

/// Finding the connected iPhone and asking it what the setup guide needs to know.
///
/// None of it reaches for Xcode. usbmuxd answers what it can on its own (see Usbmux); everything that
/// needs a lockdown session goes through pymobiledevice3 – the same library the bot drives the phone
/// with – via `core/setup.py`, once `scripts/run.sh --prepare` has set up the Python for it.
enum DeviceTools {
    struct Device: Identifiable, Hashable {
        let name: String
        let os: String
        let udid: String
        var id: String { udid }
        /// The userspace tunnel needs CoreDeviceProxy, which iOS 17.0–17.3 don't have.
        var supported: Bool {
            let parts = os.split(separator: ".").compactMap { Int($0) }
            guard let major = parts.first else { return true }
            return major > 17 || (major == 17 && (parts.count > 1 ? parts[1] : 0) >= 4)
        }
    }

    /// What `setup.py check` found out about one phone.
    struct Check: Decodable {
        let paired: Bool
        let devmode: Bool?
    }

    // MARK: - where the pieces live

    /// Resources/ inside IVory.app, or the repository root when run from a clone.
    static var resources: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var core: String { resources.appendingPathComponent("core").path }

    /// The environment for running the core's Python. Its compiled files go to ~/.pogo/pycache: inside
    /// IVory.app they would break the app's code signature (see AppleAccount.bundleIsIntact).
    static var pythonEnvironment: [String: String] {
        ["PYTHONPATH": core, "PYTHONUNBUFFERED": "1", "PYTHONWARNINGS": "ignore",
         "PYTHONPYCACHEPREFIX": NSHomeDirectory() + "/.pogo/pycache"]
    }

    /// The Python `run.sh --prepare` sets up. The guide opens before that is done, so every caller has to
    /// cope with it being missing rather than assume a working environment.
    static var venvPython: String? {
        let p = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pogo/venv/bin/python").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    // MARK: - devices

    /// Connected iPhones, with names and iOS versions straight from their lockdown service.
    static func connectedDevices() async -> [Device] {
        await Task.detached(priority: .userInitiated) {
            Usbmux.listDevices().map { entry in
                let info = Usbmux.deviceInfo(entry)
                return Device(name: info?.name ?? "iPhone", os: info?.os ?? "", udid: entry.udid)
            }
        }.value
    }

    /// Paired and Developer Mode, asked over a lockdown session. Nil while the Python for it isn't ready.
    static func check(udid: String) async -> Check? {
        guard let python = venvPython else { return nil }
        let out = await run(python, ["\(core)/setup.py", "check", udid], env: pythonEnvironment)
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Check.self, from: data)
    }

    /// Makes the Developer Mode switch appear in the phone's Settings.
    static func revealDeveloperMode(udid: String) async -> Bool {
        guard let python = venvPython else { return false }
        let out = await run(python, ["\(core)/setup.py", "reveal", udid], env: pythonEnvironment)
        return out.contains("\"ok\": true")
    }

    // MARK: - running things

    /// Runs a helper and returns its stdout. A phone that hangs (locked, asking to trust) must not hang the
    /// guide, so the helper is stopped after `timeout` seconds – longer than its own two 30 s waits.
    static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: Double = 75) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                if !env.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
                }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice      // a full, unread pipe would block it
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { process.terminate() }
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
