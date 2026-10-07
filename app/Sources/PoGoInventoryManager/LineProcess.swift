import Foundation

/// A helper process read line by line on the main actor, for the scripts that report progress as
/// `@@{json}` lines. Each run is its own object, so whoever owns it can tell a stopped run's last lines
/// and exit from those of the run that replaced it.
@MainActor
final class LineProcess {
    var onLine: (String) -> Void = { _ in }
    var onExit: (Int32) -> Void = { _ in }

    private let process = Process()
    private var pending = ""

    init(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
    }

    func run() throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.feed(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)     // the last output arrives first
                self?.onExit(code)
            }
        }
        try process.run()
    }

    /// SIGINT, so a shell script can clean up after itself.
    func interrupt() { if process.isRunning { process.interrupt() } }

    func terminate() { if process.isRunning { process.terminate() } }

    private func feed(_ text: String) {
        pending += text
        while let nl = pending.firstIndex(of: "\n") {
            onLine(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
    }

    /// The JSON of an `@@` event line of the given kind (`"e"`), or nil for any other line.
    static func event(_ line: String, kind: String) -> [String: Any]? {
        guard line.hasPrefix("@@"), let data = line.dropFirst(2).data(using: .utf8),
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              e["e"] as? String == kind else { return nil }
        return e
    }
}
