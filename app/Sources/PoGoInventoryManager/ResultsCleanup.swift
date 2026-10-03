import SwiftUI

/// The run folders in ~/Desktop/pogo_runs (log, screenshots of problems, IV crops): how much space they take,
/// and deleting them. Nothing in ~/.pogo is touched: the bot's memory, the Pokémon photos (cards) and the run
/// history (runs.json) stay.
enum RunResults {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/pogo_runs")

    /// Only the folders the bot created (named by the run start, 20261003_184523) – nothing else in pogo_runs.
    static func folders() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.range(of: #"^\d{8}_\d{6}$"#, options: .regularExpression) != nil }
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Space the folder takes on the disk, in bytes.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let v = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func scan() -> (runs: Int, bytes: Int64) {
        let dirs = folders()
        return (dirs.count, dirs.reduce(0) { $0 + size(of: $1) })
    }

    /// Deletes every run folder; returns the bytes freed (a folder that can't be deleted isn't counted).
    static func deleteAll() -> Int64 {
        _ = RunHistory.merge(InventoryStats.loadRuns(root))     // the history keeps the runs about to be deleted
        var freed: Int64 = 0
        for dir in folders() {
            let bytes = size(of: dir)
            if (try? FileManager.default.removeItem(at: dir)) != nil { freed += bytes }
        }
        return freed
    }

    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Settings row under the language and updates: how much space the run results take, and a button to delete them.
struct ResultsSection: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @State private var runs: Int?
    @State private var bytes: Int64 = 0
    @State private var freed: Int64?
    @State private var deleting = false
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SoftIcon(symbol: "internaldrive", size: 26, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Výsledky běhů", "Run results")).font(.system(size: 14, weight: .medium))
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(freed != nil ? Theme.green : Theme.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if deleting {
                ProgressView().controlSize(.small)
            } else {
                Button(tr("Smazat", "Delete")) { confirming = true }
                    .buttonStyle(OutlineButtonStyle(color: Theme.red, stroke: Theme.red.opacity(0.5), hover: Theme.redTint, height: 28))
                    .disabled(runner.isRunning || (runs ?? 0) == 0)
                    .help(runner.isRunning ? tr("Během běhu mazat nejde", "Can't delete while the bot runs") : "")
            }
        }
        .padding(12)
        .task { await rescan() }
        .onChange(of: runner.isRunning) { _, _ in
            freed = nil
            Task { await rescan() }
        }
        .alert(tr("Smazat výsledky všech běhů?", "Delete the results of all runs?"), isPresented: $confirming) {
            Button(tr("Smazat", "Delete"), role: .destructive) { Task { await deleteAll() } }
            Button(tr("Zrušit", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Uvolní se \(RunResults.text(bytes)) (\(runsText): logy, screenshoty a výřezy IV). Fotky Pokémonů, "
                    + "historie běhů ve Statistikách a změřená IV a tagy, které si bot pamatuje, zůstanou. Vrátit to nejde.",
                    "This frees \(RunResults.text(bytes)) (\(runsText): logs, screenshots and IV crops). The Pokémon photos, "
                    + "the run history in Stats and the IVs and tags the bot remembers stay. This can't be undone."))
        }
    }

    private var runsText: String {
        trCount(runs ?? 0, cs: "běh", "běhy", "běhů", en: "run", "runs")
    }

    private var status: String {
        if let freed { return tr("Smazáno · uvolněno \(RunResults.text(freed))", "Deleted · \(RunResults.text(freed)) freed") }
        guard let runs else { return tr("Počítám…", "Measuring…") }
        if runs == 0 { return tr("Žádné uložené výsledky", "No saved results") }
        return runsText + " · " + tr("\(RunResults.text(bytes)) na disku", "\(RunResults.text(bytes)) on disk")
    }

    private func rescan() async {
        let found = await Task.detached(priority: .utility) { RunResults.scan() }.value
        runs = found.runs
        bytes = found.bytes
    }

    private func deleteAll() async {
        deleting = true
        let n = await Task.detached(priority: .userInitiated) { RunResults.deleteAll() }.value
        freed = n
        deleting = false
        await rescan()
        StatsStore.shared.refresh(removeTag: store.config.removeTag)    // the IV crops are gone
    }
}
