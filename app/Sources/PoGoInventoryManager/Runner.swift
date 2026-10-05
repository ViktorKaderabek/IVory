import AppKit
import Foundation

/// Runs scripts/run.sh (Appium + bot), collects its output and, from the bot's events ("@@{json}" lines),
/// computes the overview: phases, tiles, tags panel and what is happening right now.
@MainActor
final class Runner: ObservableObject {
    static let shared = Runner()

    /// A step of the run (cards with checkboxes; the order is fixed).
    enum Step: Int, CaseIterable, Identifiable {
        case duplicates = 1, iv, pvp, rename, battle, weak

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .duplicates: return tr("Duplicity", "Duplicates")
            case .iv: return tr("IV tagy", "IV tags")
            case .pvp: return tr("PvP tagy", "PvP tags")
            case .rename: return tr("Přejmenovat", "Rename")
            case .battle: return tr("Battle tagy", "Battle tags")
            case .weak: return tr("Slabé kusy", "Weak Pokémon")
            }
        }

        /// Phase name in the progress indicator.
        var phaseTitle: String { self == .rename ? tr("Přejmenování", "Renaming") : title }

        var symbol: String {
            switch self {
            case .duplicates: return "square.on.square"
            case .iv: return "tag"
            case .pvp: return "trophy"
            case .rename: return "pencil"
            case .battle: return "figure.fencing"
            case .weak: return "arrow.down.circle"
            }
        }

        func isOn(_ s: Steps) -> Bool {
            switch self {
            case .duplicates: return s.duplicates
            case .iv: return s.iv
            case .pvp: return s.pvp
            case .rename: return s.rename
            case .battle: return s.battle
            case .weak: return s.weak
            }
        }

        func set(_ s: inout Steps, _ on: Bool) {
            switch self {
            case .duplicates: s.duplicates = on
            case .iv: s.iv = on
            case .pvp: s.pvp = on
            case .rename: s.rename = on
            case .battle: s.battle = on
            case .weak: s.weak = on
            }
        }
    }

    enum Outcome { case done, stopped, failed }

    /// Overview computed from the bot's events (and, for older lines, from its text output).
    struct Stats {
        var measured = 0
        var removable = 0
        var ivTagged = 0
        var pvpTagged = 0
        var renamed = 0
        var battleTagged = 0
        var weakTagged = 0
        var skipped = 0
        var errors = 0
        var phase = 0          // 0 = preparation, then 1…6 in the order of Step
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var outcome: Outcome?
    @Published private(set) var stats = Stats()
    /// Progress of the current phase (0–1) when the bot reports it (IV reading: "scan" with n/total); otherwise nil.
    @Published private(set) var phaseProgress: Double?
    @Published private(set) var activity = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var steps = Steps()
    @Published private(set) var exitCode: Int32 = 0
    /// "Tags in your storage" panel: tag → Pokémon count, storage size and the last change (lights up with +N).
    @Published private(set) var tagCounts: [String: Int] = [:]
    @Published private(set) var boxTotal = 0
    @Published private(set) var lastTagChange: (tag: String, delta: Int)?
    /// The message the bot ended with (a plain sentence for the hero card).
    @Published private(set) var fatalText: String?

    private var process: Process?
    private var pending = ""
    private var nextId = 0
    private let maxLines = 4000
    private var measuredSeen = Set<String>()
    private var changeTask: Task<Void, Never>?

    static let resultsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/pogo_runs")

    private var scriptURL: URL? {
        Bundle.main.url(forResource: "run", withExtension: "sh", subdirectory: "scripts")
    }

    func start(steps: Steps, fresh: Bool) {
        guard !isRunning, steps.count > 0 else { return }
        guard let script = scriptURL else {
            append(tr("✖ V aplikaci chybí scripts/run.sh – sestav ji znovu přes app/build_app.sh.",
                      "✖ The app is missing scripts/run.sh – rebuild it with app/build_app.sh."))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--steps", steps.argument] + (fresh ? ["--fresh"] : [])
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["POGO_EVENTS"] = "1"
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
        phaseProgress = nil
        tagCounts = [:]
        boxTotal = 0
        lastTagChange = nil
        fatalText = nil
        measuredSeen = []
        activity = tr("Připravuji Appium a Python…", "Starting Appium and Python…")
        outcome = nil
        self.steps = steps
        do {
            try process.run()
        } catch {
            append(tr("✖ Nepodařilo se spustit: ", "✖ Couldn't start: ") + error.localizedDescription)
            outcome = .failed
            return
        }
        self.process = process
        isRunning = true
        startedAt = Date()
        finishedAt = nil
        status = tr("Běží", "Running")
        let names = Step.allCases.filter { $0.isOn(steps) }.map(\.phaseTitle).joined(separator: " → ")
        append("▶ Start: \(names)" + (fresh ? tr(" · IV změřit znovu", " · measure IV again") : ""))
    }

    /// Stop = like Ctrl+C: the bot finishes the current step, saves the results and exits.
    func stop() {
        guard let process, process.isRunning else { return }
        status = tr("Zastavuji…", "Stopping…")
        activity = tr("Ukládám výsledky…", "Saving results…")
        process.interrupt()
    }

    /// When the app quits: interrupt, wait a moment, then terminate it outright.
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
            let line = String(pending[..<range.lowerBound])
            pending.removeSubrange(..<range.upperBound)
            if line.hasPrefix("@@") {
                handleEvent(line.dropFirst(2))
            } else {
                append(line)
            }
        }
    }

    private func append(_ line: String) {
        lines.append(LogLine(id: nextId, text: line))
        nextId += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        parseText(line)
    }

    // MARK: - Bot events

    private func handleEvent(_ json: Substring) {
        guard let data = json.data(using: .utf8),
              let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = e["e"] as? String else { return }
        switch kind {
        case "step":
            if let t = e["text"] as? String { activity = t }
        case "phase":
            if let n = e["n"] as? Int, n != stats.phase {
                stats.phase = n
                phaseProgress = nil
            }
        case "scan":
            if e["what"] as? String == "iv", let n = e["n"] as? Int, let total = e["total"] as? Int, total > 0 {
                phaseProgress = min(1, Double(n) / Double(total))
            }
            if e["what"] as? String == "iv", e["iv"] as? [Int] != nil, let n = e["n"] as? Int {
                let key = "\(stats.phase):\(n)"
                if !measuredSeen.contains(key) {
                    measuredSeen.insert(key)
                    stats.measured += 1
                }
            }
        case "tagcounts":
            if let counts = e["counts"] as? [String: Int] { tagCounts = counts }
            if let total = e["total"] as? Int { boxTotal = total }
            if let tag = e["changed"] as? String, let delta = e["delta"] as? Int, delta != 0 {
                flash(tag, delta)
            }
        case "tagged":
            // during duplicates (the storage hasn't been fully read yet) count the tagged Pokémon directly
            if let tag = e["tag"] as? String, let items = e["items"] as? [Any], e["remove"] as? Bool != true,
               stats.phase <= 1 {
                tagCounts[tag, default: 0] += items.count
                stats.removable += items.count
                flash(tag, items.count)
            }
            if let tag = e["tag"] as? String, let items = e["items"] as? [Any], e["remove"] as? Bool != true,
               stats.phase == Step.battle.rawValue {
                stats.battleTagged += items.count
                activity = tr("Battle tagy", "Battle tags") + " · \(tag) +\(items.count)"
            }
            if let items = e["items"] as? [Any], e["remove"] as? Bool != true, stats.phase == Step.weak.rawValue {
                stats.weakTagged += items.count
                stats.removable += items.count
                activity = tr("Slabé kusy", "Weak Pokémon") + " · +\(items.count)"
            }
        case "iv":
            if let status = e["status"] as? String {
                if status == "skip" { stats.skipped += 1 }
                if status == "done", e["had"] as? Bool != true { stats.ivTagged += 1 }
            }
        case "rename":
            if let old = e["old"] as? String, let new = e["new"] as? String {
                stats.renamed += 1
                activity = tr("Přejmenování", "Renaming") + " · \(old) → \(new)"
            }
        case "pvp":
            if let name = e["name"] as? String, let tags = e["tags"] as? [String], let ranks = e["ranks"] as? [String: Any] {
                let r = [("great", "G"), ("ultra", "U"), ("master", "M")]
                    .map { key, letter in "\(letter)\((ranks[key] as? Int).map(String.init) ?? "–")" }
                    .joined(separator: " ")
                activity = tr("PvP tagy", "PvP tags") + " · \(name) · \(r)" + (tags.isEmpty ? "" : " → \(tags.joined(separator: ", "))")
                if !tags.isEmpty { stats.pvpTagged += 1 }
            }
        case "problem":
            stats.errors += 1
            if let t = e["text"] as? String { activity = t }
        case "fatal":
            if let t = e["text"] as? String {
                fatalText = t
                activity = t
            }
        default:
            break
        }
    }

    /// A tag that just gained Pokémon lights up briefly.
    private func flash(_ tag: String, _ delta: Int) {
        lastTagChange = (tag, delta)
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.lastTagChange = nil
        }
    }

    /// Plain text lines (slow mode, run.sh) – only what the events don't cover.
    private func parseText(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        if t.range(of: #"^CP\d+: IV \d+/\d+/\d+"#, options: .regularExpression) != nil { stats.measured += 1 }
        if t.hasPrefix("▶ "), !t.hasPrefix("▶ Start") { activity = String(t.dropFirst(2)) }
        if t.hasPrefix("✖ ") { fatalText = String(t.dropFirst(2)) }
    }

    #if DEBUG
    /// Only for checking the look: `IVORY_PREVIEW=running|done|stopped|error` fills in sample data as in the design.
    func applyPreview(_ state: String) {
        let sample: [String] = [
            tr("Hledání ve hře: count & !legendary & !ultra beasts", "Search in the game: count & !legendary & !ultra beasts"),
            tr("── Skupina: Charmander (3×)", "── Group: Charmander (3×)"),
            tr("   klepnutí: otevřít CP812", "   tap: open CP812"),
            tr("   ✔ tag Removable přidán: 2 Pokémoni", "   ✔ tag Removable added: 2 Pokémon"),
            tr("!! nečekaná obrazovka – vracím se do inventáře", "!! unexpected screen – going back to the storage"),
            tr("========== 2. část: třídím celý inventář do IV tagů ==========",
               "========== Part 2: sorting the whole storage into IV tags =========="),
            "   CP984   #0377  10/12/09  69 %  -> 70-0% Garbage",
            "   CP1504  #0998  14/13/14  G12  U5  M30  -> Great, Ultra, Master",
            "   CP1504  91 %  Baxcalibur → 91 Bax M30",
        ]
        lines.removeAll()
        isRunning = false; outcome = nil; activity = ""; lastTagChange = nil
        stats = Stats(); phaseProgress = nil; tagCounts = [:]; boxTotal = 0; startedAt = nil; finishedAt = nil
        for l in sample { lines.append(LogLine(id: nextId, text: l)); nextId += 1 }
        let now = Date()
        steps = Steps(duplicates: true, iv: true, pvp: true, rename: true, battle: true, weak: true)
        let counts = ["Removable": 38, "100% Perfect": 2, "95-99% Insane": 14, "90-95% Amazing": 31, "85-90% Great": 46,
                      "80-85% Good": 58, "70-80% Mid": 97, "70-0% Garbage": 164, "Great League": 24,
                      "Ultra League": 18, "Master League": 9, "Raid": 61, "GL Team": 3, "UL Team": 3, "ML Team": 3]
        switch state {
        case "running":
            isRunning = true
            stats = Stats(measured: 98, removable: 38, ivTagged: 233, errors: 1, phase: 2)
            phaseProgress = 0.46
            tagCounts = counts.mapValues { $0 / 2 }
            boxTotal = 499
            lastTagChange = ("90-95% Amazing", 1)
            activity = tr("IV tagy · 93 % → 90-95% Amazing", "IV tags · 93% → 90-95% Amazing")
            startedAt = now.addingTimeInterval(-1834)
        case "done":
            outcome = .done
            stats = Stats(measured: 142, removable: 164, ivTagged: 412, pvpTagged: 51, renamed: 86, battleTagged: 70,
                          weakTagged: 126, errors: 3, phase: 6)
            tagCounts = counts
            boxTotal = 499
            startedAt = now.addingTimeInterval(-4328); finishedAt = now
            lines.append(LogLine(id: nextId, text: "■ " + tr("Hotovo", "Done"))); nextId += 1
        case "stopped":
            outcome = .stopped
            stats = Stats(measured: 64, removable: 19, errors: 1, phase: 2)
            startedAt = now.addingTimeInterval(-1122); finishedAt = now
            lines.append(LogLine(id: nextId, text: "■ " + tr("Zastaveno", "Stopped"))); nextId += 1
        case "error":
            outcome = .failed; exitCode = 1
            stats = Stats(measured: 9, removable: 2, errors: 4, phase: 2)
            startedAt = now.addingTimeInterval(-291); finishedAt = now
            lines.append(LogLine(id: nextId, text: "■ " + tr("Skončilo s chybou (1)", "Failed (1)"))); nextId += 1
        default:
            lines.removeAll()
        }
    }
    #endif

    private func finished(code: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if !pending.isEmpty {
            if pending.hasPrefix("@@") { handleEvent(pending.dropFirst(2)) } else { append(pending) }
            pending = ""
        }
        process = nil
        isRunning = false
        finishedAt = Date()
        exitCode = code
        switch code {
        case 0:
            status = tr("Hotovo", "Done")
            outcome = .done
            activity = tr("Hotovo – výsledky jsou ve složce pogo_runs", "Done – results are in the pogo_runs folder")
        case 130:
            status = tr("Zastaveno", "Stopped")
            outcome = .stopped
            activity = tr("Zastaveno – výsledky se uložily", "Stopped – results are saved")
        default:
            status = tr("Skončilo s chybou", "Failed")
            outcome = .failed
            activity = fatalText ?? tr("Skončilo s chybou (\(code)) – podívej se do výpisu", "Failed (\(code)) – check the log")
        }
        append("■ \(status)")
    }
}
