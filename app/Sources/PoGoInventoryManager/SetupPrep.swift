import SwiftUI

/// `scripts/run.sh --prepare` in the background: Python, the iPhone tools, Appium, the libraries and the
/// game data – everything the first run would otherwise download while the user waits. It starts when
/// the guide opens, so most of it is done by the Install step, and the iPhone tools come first because
/// the Developer Mode step needs them.
@MainActor
final class SetupPrep: ObservableObject {
    enum Item: String, CaseIterable {
        case python, devtools, appium, libs, gamedata
    }

    enum ItemState: Equatable {
        case waiting
        case running(done: Int64, total: Int64)
        case done
        case failed
    }

    enum State: Equatable { case idle, running, done, failed(String) }

    @Published private(set) var state = State.idle
    @Published private(set) var items: [Item: ItemState] = [:]

    private var process: LineProcess?
    /// The last lines run.sh printed; the failure message is picked from them.
    private var tail: [String] = []

    var toolsReady: Bool { items[.devtools] == .done || state == .done }

    /// 0–1 over the five items, a running download counting by its bytes.
    var fraction: Double {
        let parts = Item.allCases.map { item -> Double in
            switch items[item] ?? .waiting {
            case .done: return 1
            case .running(let d, let t): return t > 0 ? min(0.95, Double(d) / Double(t)) : 0.3
            default: return 0
            }
        }
        return parts.reduce(0, +) / Double(Item.allCases.count)
    }

    /// Starts the preparation, or starts it again after it failed.
    func start() {
        if case .failed = state { stop(); state = .idle }
        guard state == .idle else { return }
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["IVORY_SETUP"], id != "live" { return }
        #endif
        guard let script = Runner.shared.scriptURL else {
            state = .failed(tr("V aplikaci chybí scripts/run.sh.", "The app is missing scripts/run.sh."))
            return
        }
        let process = LineProcess("/bin/bash", [script.path, "--prepare"], environment: ["PYTHONUNBUFFERED": "1"])
        process.onLine = { [weak self, weak process] line in
            guard let self, let process, process === self.process else { return }
            self.read(line)
        }
        process.onExit = { [weak self, weak process] code in
            guard let self, let process, process === self.process else { return }
            self.finished(code)
        }
        items = Dictionary(uniqueKeysWithValues: Item.allCases.map { ($0, ItemState.waiting) })
        tail = []
        state = .running
        do { try process.run() } catch {
            state = .failed(tr("Přípravu se nepodařilo spustit.", "Couldn't start the preparation."))
            return
        }
        self.process = process
    }

    func stop() {
        process?.interrupt()
        process = nil
    }

    private func read(_ line: String) {
        if let e = LineProcess.event(line, kind: "prep") {
            event(e)
        } else if line.hasPrefix("✖") {
            tail.append(String(line.dropFirst(2)))
        }
    }

    private func event(_ e: [String: Any]) {
        let item = (e["id"] as? String).flatMap(Item.init(rawValue:))
        switch e["state"] as? String {
        case "start": if let item { items[item] = .running(done: 0, total: 0) }
        case "progress":
            if let item {
                items[item] = .running(done: (e["done"] as? NSNumber)?.int64Value ?? 0,
                                       total: (e["total"] as? NSNumber)?.int64Value ?? 0)
            }
        case "done": if let item { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { items[item] = .done } }
        case "fail":
            if let item { items[item] = .failed }
            state = .failed((e["text"] as? String) ?? tr("Příprava selhala.", "The preparation failed."))
        default: break
        }
    }

    private func finished(_ code: Int32) {
        process = nil
        if case .failed = state { return }
        if code == 0 {
            for item in Item.allCases where items[item] != .done { items[item] = .done }
            state = .done
            SetupFlow.shared.prepFinished()
        } else {
            state = .failed(tail.last ?? tr("Příprava skončila chybou (\(code)).", "The preparation failed (\(code))."))
        }
    }

    #if DEBUG
    func preview(done: Bool) {
        if done {
            items = Dictionary(uniqueKeysWithValues: Item.allCases.map { ($0, ItemState.done) })
            state = .done
        } else {
            items = [.python: .done, .devtools: .done, .appium: .done,
                     .libs: .running(done: 15_000_000, total: 100_000_000), .gamedata: .waiting]
            state = .running
        }
    }
    #endif
}
