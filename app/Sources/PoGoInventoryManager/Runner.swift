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

    /// A Pokémon the bot has just read, for the "Now reading" panel. `seq` is its order in the run and
    /// doubles as the identity SwiftUI animates on, so two Pokémon with the same CP and IV still count
    /// as a change.
    struct LiveMon: Identifiable, Equatable {
        let seq: Int
        let cp: Int
        let name: String
        let dex: Int?
        let sid: String?
        let iv: [Int]?
        let pct: Int?
        let level: Double?
        let types: [String]
        /// The IV tag it is going to get (the tagging itself happens later, in bulk).
        let tag: String?
        var id: Int { seq }
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    /// The bot's output. It is its own object on purpose: a line arrives several times a second and if it
    /// lived on `Runner`, every one of them would invalidate the whole screen instead of just the log.
    let log = RunLog()
    @Published var isRunning = false
    @Published var status = ""
    @Published var outcome: Outcome?
    @Published var stats = Stats()
    /// Progress of the current phase (0–1) when the bot reports it (IV reading: "scan" with n/total); otherwise nil.
    @Published var phaseProgress: Double?
    /// The Pokémon the bot has just read, and the few before it (newest first) – the live panel.
    @Published var current: LiveMon?
    @Published var justRead: [LiveMon] = []
    /// How far the IV reading is ("264 / 425" in the live panel); nil outside that step.
    @Published var scanned: (done: Int, total: Int)?
    @Published var activity = ""
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published var steps = Steps()
    @Published var exitCode: Int32 = 0
    /// "Tags in your storage" panel: tag → Pokémon count, storage size and the last change (lights up with +N).
    @Published var tagCounts: [String: Int] = [:]
    @Published var boxTotal = 0
    @Published var lastTagChange: (tag: String, delta: Int)?
    /// The message the bot ended with (a plain sentence for the hero card).
    @Published var fatalText: String?

    var process: Process?
    var pending = ""
    var measuredSeen = Set<String>()
    var liveSeq = 0
    /// How many of the last-read Pokémon the panel keeps.
    static let justReadCount = 6
    /// How much of a step the scroll through the list is worth. Scrolling covers about nine Pokémon a
    /// second and reading them about one, so the list is roughly the first tenth of the step; counting
    /// it a little higher keeps the progress from stalling at the hand-over.
    static let listShare = 0.15

    /// Pokémon are being read out of the appraisal right now. A step first scrolls through the list
    /// (nothing to show yet), then reads them one by one, then tags – and the later steps don't read
    /// at all. "Now reading" is worth the space only in the middle part; the rest of the time the tag
    /// chart goes there instead.
    var isReading: Bool {
        guard isRunning, let s = scanned, s.total > 0 else { return false }
        return s.done < s.total
    }

    /// How far the whole run is, 0–1: the steps already done plus how far the one under way has got.
    /// Everything that shows a percentage shows this one, so the rail, the dial and the card agree.
    var runProgress: Double {
        let total = Double(Step.allCases.count)
        return min(1, (Double(max(0, stats.phase - 1)) + (phaseProgress ?? 0)) / total)
    }
    var changeTask: Task<Void, Never>?

    static let resultsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/pogo_runs")

    var scriptURL: URL? {
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
        current = nil
        justRead = []
        scanned = nil
        liveSeq = 0
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
        log.clear()
    }

    var logText: String { log.text }

    func openResults() {
        try? FileManager.default.createDirectory(at: Self.resultsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.resultsURL)
    }

    // MARK: - Bot events

    #if DEBUG
    #endif

}

/// The bot's output, kept apart from `Runner` so a new line only redraws the log.
@MainActor
final class RunLog: ObservableObject {
    @Published var lines: [Runner.LogLine] = []

    var nextId = 0
    let maxLines = 4000

    func append(_ text: String) {
        lines.append(Runner.LogLine(id: nextId, text: text))
        nextId += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() { lines.removeAll() }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}
