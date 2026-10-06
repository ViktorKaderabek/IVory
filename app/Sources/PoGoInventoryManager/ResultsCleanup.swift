import SwiftUI

/// The run folders in ~/Desktop/pogo_runs (log, screenshots of problems, IV crops): how much space they take,
/// and deleting them. Nothing in ~/.pogo is touched: the bot's memory and the run history (runs.json) stay.
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
