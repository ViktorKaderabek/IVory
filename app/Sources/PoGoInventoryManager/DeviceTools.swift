import Foundation

/// Helpers for settings: find the connected iPhone and the Apple Team ID.
enum DeviceTools {
    struct Device: Identifiable, Hashable {
        let name: String
        let os: String
        let udid: String
        var id: String { udid }
    }

    /// Connected iPhones (not simulators), from `xcrun xctrace list devices`.
    static func connectedDevices() async -> [Device] {
        let output = await shell("xcrun xctrace list devices 2>/dev/null")
        var devices: [Device] = []
        var section = ""
        let pattern = #"^(.*) \(([\d.]+)\) \(([0-9A-Fa-f-]{20,})\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==") {
                section = line
                continue
            }
            guard !section.contains("Simulator"), !line.contains("Simulator") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range), m.numberOfRanges == 4,
                  let name = Range(m.range(at: 1), in: line),
                  let os = Range(m.range(at: 2), in: line),
                  let udid = Range(m.range(at: 3), in: line) else { continue }
            devices.append(Device(name: String(line[name]), os: String(line[os]), udid: String(line[udid])))
        }
        return devices
    }

    /// Team ID from the "Apple Development" certificate in the Keychain (the OU field).
    static func teamId() async -> String? {
        let output = await shell(
            "security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null")
        guard let regex = try? NSRegularExpression(pattern: #"OU\s*=\s*([A-Z0-9]{10})"#),
              let m = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let r = Range(m.range(at: 1), in: output) else { return nil }
        return String(output[r])
    }

    private static func shell(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
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
