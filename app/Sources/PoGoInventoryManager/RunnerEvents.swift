import AppKit
import Foundation

// What the bot reports while it runs: its events and log lines turned into what the app shows.

extension Runner {
    func consume(_ text: String) {
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

    func append(_ line: String) {
        log.append(line)
        parseText(line)
    }

    func handleEvent(_ json: Substring) {
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
                scanned = nil          // the count belongs to the step that is over
            }
        case "scan":
            // A step first scrolls through the list and then reads the Pokémon one by one. Both report
            // how far they have got, so the progress keeps moving through the whole step instead of
            // standing still for the minutes the scrolling takes.
            if let what = e["what"] as? String, let n = e["n"] as? Int, let total = e["total"] as? Int, total > 0 {
                let done = min(1, Double(n) / Double(total))
                if what == "seznam" {
                    phaseProgress = Self.listShare * done
                } else if what == "iv" {
                    phaseProgress = Self.listShare + (1 - Self.listShare) * done
                    scanned = (n, total)
                }
            }
            if e["what"] as? String == "iv", e["iv"] as? [Int] != nil, let n = e["n"] as? Int {
                let key = "\(stats.phase):\(n)"
                if !measuredSeen.contains(key) {
                    measuredSeen.insert(key)
                    stats.measured += 1
                }
                readPokemon(e)
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
        case "device":
            reachedPhone = true
        case "connected":
            connected = true
            SetupFlow.shared.runConnected()
        case "fatal":
            if let t = e["text"] as? String {
                fatalText = t
                activity = t
            }
            fatalHelp = e["help"] as? String
        default:
            break
        }
    }

    /// One Pokémon read: it becomes the big "Now reading" card and pushes the previous one into the strip
    /// underneath. A Pokémon the bot couldn't pin to a species has no dex number and so no picture; the
    /// rest of the card still works.
    func readPokemon(_ e: [String: Any]) {
        guard let cp = e["cp"] as? Int else { return }
        liveSeq += 1
        let mon = LiveMon(seq: liveSeq,
                          cp: cp,
                          name: (e["name"] as? String) ?? "",
                          dex: e["dex"] as? Int,
                          sid: e["sid"] as? String,
                          iv: e["iv"] as? [Int],
                          pct: e["pct"] as? Int,
                          level: e["level"] as? Double,
                          types: (e["types"] as? [String]) ?? [],
                          tag: e["tag"] as? String)
        if let previous = current {
            justRead.insert(previous, at: 0)
            if justRead.count > Self.justReadCount { justRead.removeLast(justRead.count - Self.justReadCount) }
        }
        current = mon
        // the picture of the Pokémon the panel is about to show, fetched while the bot reads the next one
        if let dex = mon.dex {
            PokeImages.prefetch(.artwork, dex: dex)
            PokeImages.prefetch(.icon, dex: dex, sid: mon.sid)
        }
    }

    /// A tag that just gained Pokémon lights up briefly.
    func flash(_ tag: String, _ delta: Int) {
        lastTagChange = (tag, delta)
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.lastTagChange = nil
        }
    }

    /// Plain text lines (slow mode, run.sh) – only what the events don't cover.
    func parseText(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        if t.range(of: #"^CP\d+: IV \d+/\d+/\d+"#, options: .regularExpression) != nil { stats.measured += 1 }
        if t.hasPrefix("▶ "), !t.hasPrefix("▶ Start") { activity = String(t.dropFirst(2)) }
        if t.hasPrefix("✖ ") { fatalText = String(t.dropFirst(2)) }
    }

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
        log.clear()
        isRunning = false; outcome = nil; activity = ""; lastTagChange = nil
        stats = Stats(); phaseProgress = nil; tagCounts = [:]; boxTotal = 0; startedAt = nil; finishedAt = nil
        current = nil; justRead = []; scanned = nil
        for l in sample { log.append(l) }
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
            // IVORY_PREVIEW_TICK=1 keeps the progress creeping, the way a real run does. Motion that
            // only misbehaves while the progress changes stays invisible in a frozen preview.
            #if DEBUG
            if let step = Double(ProcessInfo.processInfo.environment["IVORY_PREVIEW_TICK"] ?? ""), step > 0 {
                Task { @MainActor [weak self] in
                    while self?.isRunning == true {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        self?.phaseProgress = min(1, (self?.phaseProgress ?? 0) + step)
                    }
                }
            }
            #endif
            tagCounts = counts.mapValues { $0 / 2 }
            boxTotal = 499
            lastTagChange = ("90-95% Amazing", 1)
            scanned = (264, 425)
            // real species, so the pictures are the ones a run would actually download
            let live: [(Int, String, Int, String, [Int], Double, String)] = [
                (25, "Pikachu", 345, "pikachu", [14, 12, 15], 15, "90-95% Amazing"),
                (377, "Regirock", 2963, "regirock", [14, 12, 14], 35, "85-90% Great"),
                (382, "Kyogre", 3521, "kyogre", [15, 15, 15], 40, "100% Perfect"),
                (26, "Raichu", 1204, "raichu_alolan", [14, 14, 13], 30, "90-95% Amazing"),
                (149, "Dragonite", 3640, "dragonite", [13, 12, 13], 37, "80-85% Good"),
            ]
            let mons = live.enumerated().map { i, m in
                LiveMon(seq: live.count - i, cp: m.2, name: m.1, dex: m.0, sid: m.3, iv: m.4,
                        pct: Int((Double(m.4.reduce(0, +)) * 100 / 45).rounded()), level: m.5,
                        types: [], tag: m.6)
            }
            current = mons.first
            justRead = Array(mons.dropFirst())
            activity = tr("IV tagy · 93 % → 90-95% Amazing", "IV tags · 93% → 90-95% Amazing")
            startedAt = now.addingTimeInterval(-1834)
        case "tagging":
            // everything read, the bot is on the tagging steps – "Now reading" has nothing left to show
            isRunning = true
            stats = Stats(measured: 425, removable: 38, ivTagged: 425, errors: 1, phase: 3)
            phaseProgress = 0.38
            tagCounts = counts
            boxTotal = 499
            scanned = (425, 425)
            lastTagChange = ("90-95% Amazing", 3)
            startedAt = now.addingTimeInterval(-2_460)
        case "done":
            outcome = .done
            stats = Stats(measured: 142, removable: 164, ivTagged: 412, pvpTagged: 51, renamed: 86, battleTagged: 70,
                          weakTagged: 126, errors: 3, phase: 6)
            tagCounts = counts
            boxTotal = 499
            startedAt = now.addingTimeInterval(-4328); finishedAt = now
            log.append("■ " + tr("Hotovo", "Done"))
        case "stopped":
            outcome = .stopped
            stats = Stats(measured: 64, removable: 19, errors: 1, phase: 2)
            startedAt = now.addingTimeInterval(-1122); finishedAt = now
            log.append("■ " + tr("Zastaveno", "Stopped"))
        case "error":
            outcome = .failed; exitCode = 1
            stats = Stats(measured: 9, removable: 2, errors: 4, phase: 2)
            startedAt = now.addingTimeInterval(-291); finishedAt = now
            log.append("■ " + tr("Skončilo s chybou (1)", "Failed (1)"))
        default:
            log.clear()
        }
    }

    func finished(code: Int32) {
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
