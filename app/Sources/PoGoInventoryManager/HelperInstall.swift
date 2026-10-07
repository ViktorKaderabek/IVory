import SwiftUI

/// `core/setup.py install`: signs WebDriverAgent with the user's Apple ID and puts it on the phone.
@MainActor
final class HelperInstall: ObservableObject {
    enum Part: String { case sign, phone }

    enum State: Equatable {
        case idle
        case running(Part)
        case done
        case failed(Part, String)
    }

    @Published private(set) var state = State.idle
    private var process: LineProcess?

    func isDone(_ part: Part) -> Bool {
        switch state {
        case .done: return true
        case .running(let p), .failed(let p, _): return part == .sign && p == .phone
        case .idle: return false
        }
    }

    var failure: String? {
        if case .failed(_, let why) = state { return why }
        return nil
    }

    func start(udid: String, appleId: String) {
        guard state == .idle else { return }
        guard let python = DeviceTools.venvPython else {
            state = .failed(.sign, tr("Python ještě není připravený.", "Python isn't ready yet."))
            return
        }
        let process = LineProcess(python, ["\(DeviceTools.core)/setup.py", "install", udid, appleId],
                                  environment: DeviceTools.pythonEnvironment)
        process.onLine = { [weak self, weak process] line in
            guard let self, let process, process === self.process,
                  let e = LineProcess.event(line, kind: "setup") else { return }
            self.event(e)
        }
        process.onExit = { [weak self, weak process] code in
            guard let self, let process, process === self.process else { return }
            self.finished(code)
        }
        state = .running(.sign)
        do { try process.run() } catch {
            state = .failed(.sign, tr("Instalaci se nepodařilo spustit.", "Couldn't start the installation."))
            return
        }
        self.process = process
    }

    func reset() {
        process?.terminate()
        process = nil
        state = .idle
    }

    private var currentPart: Part {
        if case .running(let p) = state { return p }
        return .sign
    }

    private func event(_ e: [String: Any]) {
        let part = (e["id"] as? String).flatMap(Part.init(rawValue:))
        switch e["state"] as? String {
        case "start": if let part { withAnimation(.easeOut(duration: 0.3)) { state = .running(part) } }
        case "done": withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { state = .done }
        case "fail": state = .failed(currentPart, (e["text"] as? String) ?? tr("Instalace selhala.", "The installation failed."))
        default: break
        }
    }

    private func finished(_ code: Int32) {
        process = nil
        switch state {
        case .done: SetupFlow.shared.installSucceeded()
        case .failed: break
        default: state = .failed(currentPart, tr("Instalace skončila chybou (\(code)).", "The installation failed (\(code))."))
        }
    }
}
