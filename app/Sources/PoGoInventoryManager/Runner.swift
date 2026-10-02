import AppKit
import Foundation

/// Spouští scripts/run.sh (Appium + bot), sbírá jeho výpis a počítá z něj přehled.
@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()

    enum Mode: String, CaseIterable, Identifiable {
        case both = "Duplicity + IV tagy"
        case duplicates = "Jen duplicity"
        case ivTags = "Jen IV tagy"

        var id: String { rawValue }

        var arguments: [String] {
            switch self {
            case .both: return []
            case .duplicates: return ["--no-iv"]
            case .ivTags: return ["--only-iv"]
            }
        }

        var symbol: String {
            switch self {
            case .both: return "wand.and.stars"
            case .duplicates: return "square.on.square"
            case .ivTags: return "tag"
            }
        }

        var detail: String {
            switch self {
            case .both: return "Nejdřív duplicity, pak celý box do IV tagů"
            case .duplicates: return "Horší duplicity dostanou tag"
            case .ivTags: return "Každý Pokémon dostane tag podle IV"
            }
        }
    }

    enum Outcome { case done, stopped, failed }

    /// Přehled spočítaný z výpisu bota.
    struct Stats {
        var measured = 0
        var removable = 0
        var ivTagged = 0
        var skipped = 0
        var errors = 0
        var phase = 0          // 0 = příprava, 1 = duplicity, 2 = IV tagy
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Připraveno"
    @Published private(set) var outcome: Outcome?
    @Published private(set) var stats = Stats()
    @Published private(set) var activity = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var mode: Mode = .both

    private var process: Process?
    private var pending = ""
    private var nextId = 0
    private let maxLines = 4000

    static let resultsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/pogo_runs")

    private var scriptURL: URL? {
        Bundle.main.url(forResource: "run", withExtension: "sh", subdirectory: "scripts")
    }

    func start(mode: Mode, fresh: Bool) {
        guard !isRunning else { return }
        guard let script = scriptURL else {
            append("✖ V aplikaci chybí scripts/run.sh – sestav ji znovu přes app/build_app.sh.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + mode.arguments + (fresh ? ["--fresh"] : [])
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { Runner.shared.consume(text) }
        }
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async { Runner.shared.finished(code: code) }
        }

        stats = Stats()
        activity = "Připravuji Appium a Python…"
        outcome = nil
        self.mode = mode
        do {
            try process.run()
        } catch {
            append("✖ Nepodařilo se spustit: \(error.localizedDescription)")
            outcome = .failed
            return
        }
        self.process = process
        isRunning = true
        startedAt = Date()
        finishedAt = nil
        status = "Běží"
        append("▶ Start: \(mode.rawValue)\(fresh ? ", IV změřit znovu" : "")")
    }

    /// Stop = jako Ctrl+C: bot dokončí krok, uloží výsledky a skončí.
    func stop() {
        guard let process, process.isRunning else { return }
        status = "Zastavuji…"
        activity = "Ukládám výsledky…"
        process.interrupt()
    }

    /// Při zavírání aplikace: přerušit a chvilku počkat, pak natvrdo ukončit.
    func terminateNow() {
        guard let process, process.isRunning else { return }
        process.interrupt()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning { process.terminate() }
    }

    func clear() {
        lines.removeAll()
    }

    var logText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    func openResults() {
        try? FileManager.default.createDirectory(at: Self.resultsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.resultsURL)
    }

    private func consume(_ text: String) {
        pending += text
        while let range = pending.range(of: "\n") {
            append(String(pending[..<range.lowerBound]))
            pending.removeSubrange(..<range.upperBound)
        }
    }

    private func append(_ line: String) {
        lines.append(LogLine(id: nextId, text: line))
        nextId += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        parse(line)
    }

    /// Z řádků výpisu bota počítá přehled (formát řádků viz core/pogo_bot.py).
    private func parse(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        if t.hasPrefix("!!") {
            stats.errors += 1
            activity = "Chyba – vracím se do boxu a pokračuji"
            return
        }
        if t.contains("2. část") {
            stats.phase = 2
            activity = "Celý box → IV tagy"
            return
        }
        if t.range(of: #"^CP\d+: IV \d+/\d+/\d+"#, options: .regularExpression) != nil {
            stats.measured += 1
            return
        }
        if t.contains("ks má tag"), let n = Int(t.split(separator: " ").first { Int($0) != nil } ?? "") {
            stats.removable += n
            activity = "Otagováno \(n) ks"
            return
        }
        if stats.phase == 2, t.hasPrefix("CP"), t.contains(" -> ") {
            if t.contains("přeskakuji") || t.contains("už má") || t.contains("už měl") {
                stats.skipped += 1
            } else if !t.contains("nepovedlo") {
                stats.ivTagged += 1
                if !t.contains("z paměti") && t.range(of: #"\d+/\s*\d+/\s*\d+"#, options: .regularExpression) != nil {
                    stats.measured += 1
                }
            }
            activity = Self.friendlyIVLine(t) ?? t
            return
        }
        if stats.phase == 0 && (t.hasPrefix("měřím") || t.hasPrefix("── Várka")) {
            stats.phase = 1
        }
        if let nice = Self.friendlyActivity(t) {
            activity = nice
        }
    }

    /// „CP1617  Charizard   15/14/13  93%  -> 90-95% Amazing“ → „Charizard (CP1617) → 90-95% Amazing · 15/14/13 · 93 %“
    private static func friendlyIVLine(_ t: String) -> String? {
        let pattern = #"^CP(\d+)\s+(.+?)\s+([\d ?]+/[\d ?]+/[\d ?]+)\s+(\S+)\s+->\s+(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: t) else { return "" }
            return t[r].trimmingCharacters(in: .whitespaces)
        }
        let iv = g(3).replacingOccurrences(of: " ", with: "")
        let note = g(5).replacingOccurrences(of: " (IV z paměti)", with: "")
        if iv.contains("?") { return "\(g(2)) (CP\(g(1))) – \(note)" }
        return "\(g(2)) (CP\(g(1))) → \(note) · \(iv) · \(g(4).replacingOccurrences(of: "%", with: " %"))"
    }

    /// Řádky výpisu, které stojí za to ukázat jako „co se právě děje“.
    private static func friendlyActivity(_ t: String) -> String? {
        if t.hasPrefix("měřím ") {
            let rest = t.dropFirst("měřím ".count)
            let parts = rest.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { return "Měřím IV: \(parts[1]) (\(parts[0]))" }
            return "Měřím IV: \(rest)"
        }
        if t.hasPrefix("── Várka: ") { return "Várka: " + t.dropFirst("── Várka: ".count) }
        if t.hasPrefix("obrazovka: ") { return "Na obrazovce: " + t.dropFirst("obrazovka: ".count) }
        if t.hasPrefix("označuji ") { return "Označuji " + t.dropFirst("označuji ".count) }
        if t.hasPrefix("✔") { return String(t.dropFirst(2)) }
        for prefix in ["Restartuji", "Doznačuji", "Připojuji", "Obraz:", "tag '", "▶ "] where t.hasPrefix(prefix) {
            return t.replacingOccurrences(of: "▶ ", with: "")
        }
        return nil
    }

    #if PREVIEW_RENDER
    /// Jen pro vykreslení náhledu vzhledu (swiftc -D PREVIEW_RENDER).
    func previewState(running: Bool) {
        isRunning = running
        status = running ? "Běží" : "Hotovo"
        outcome = running ? nil : .done
        stats = Stats(measured: 37, removable: 12, ivTagged: 58, skipped: 140, errors: 1, phase: 2)
        activity = running ? "CP1617  Charizard        15/14/13  93%  -> 90-95% Amazing" : "Hotovo – výsledky jsou ve složce pogo_runs"
        startedAt = Date().addingTimeInterval(-1834)
        finishedAt = running ? nil : Date()
        for l in ["▶ Start: Duplicity + IV tagy", "── Várka: Charmander (4 ks)", "   CP691   15/14/13   93%  -> Removable ✔ otagováno",
                  "   klepnutí: otevřít CP1617 (0.50, 0.49)", "   CP1617  Charizard        15/14/13  93%  -> 90-95% Amazing"] {
            append(l)
        }
    }
    #endif

    private func finished(code: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if !pending.isEmpty {
            append(pending)
            pending = ""
        }
        process = nil
        isRunning = false
        finishedAt = Date()
        switch code {
        case 0:
            status = "Hotovo"
            outcome = .done
            activity = "Hotovo – výsledky jsou ve složce pogo_runs"
        case 130:
            status = "Zastaveno"
            outcome = .stopped
            activity = "Zastaveno – výsledky se uložily"
        default:
            status = "Skončilo s chybou"
            outcome = .failed
            activity = "Skončilo s chybou (\(code)) – podívej se do výpisu"
        }
        append("■ \(status)")
    }
}
