import Foundation

// The list of past runs the app keeps in ~/.pogo/runs.json.

/// The run history in ~/.pogo/runs.json. The runs found in the pogo_runs folders are added to it on every load,
/// so deleting the results in the settings (or by hand) doesn't erase the history in Stats.
enum RunHistory {
    static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/runs.json") }

    /// The saved history with these runs added (a run still in its folder replaces the saved one); saved again
    /// when something was added. Oldest first.
    static func merge(_ runs: [InventoryStats.Run]) -> [InventoryStats.Run] {
        var byId: [String: InventoryStats.Run] = [:]
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([InventoryStats.Run].self, from: data) {
            for r in saved { byId[r.id] = r }
        }
        let before = byId.count
        var changed = false
        for r in runs {
            if let old = byId[r.id], old.duration == r.duration, old.checked == r.checked, old.errors == r.errors { continue }
            byId[r.id] = r
            changed = true
        }
        let all = byId.values.sorted { $0.date < $1.date }
        if changed || byId.count != before, let data = try? JSONEncoder().encode(all) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return all
    }

    /// Without any history (the results were deleted before it was kept): runs guessed from when the bot first
    /// read each Pokémon in the memory. Reads more than 30 minutes apart belong to different runs; how many
    /// Pokémon a run checked isn't known.
    static func estimate(_ reads: [Date]) -> [InventoryStats.Run] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        var runs: [InventoryStats.Run] = []
        var start: Date?, last: Date?
        func close() {
            if let start, let last {
                runs.append(.init(id: f.string(from: start), date: start, duration: last.timeIntervalSince(start), checked: nil, errors: 0))
            }
        }
        for t in reads.sorted() {
            if let l = last, t.timeIntervalSince(l) > 30 * 60 { close(); start = nil }
            if start == nil { start = t }
            last = t
        }
        close()
        return runs
    }
}
