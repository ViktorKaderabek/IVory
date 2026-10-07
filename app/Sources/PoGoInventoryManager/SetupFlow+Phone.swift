import Foundation

/// Watching the iPhone while the guide is open: usbmuxd every 1.5 s for what it can tell, Python for the
/// rest, and marking the steps that turn out to be met.
extension SetupFlow {
    private struct Reading {
        let device: DeviceTools.Device
        let pairRecord: Bool
        let developerMode: Bool?
    }

    func startPolling() {
        #if DEBUG
        if previewing { return }
        #endif
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.lookAtPhone()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    /// "Try again" while the guide looks for the phone: look right now instead of at the next tick.
    func lookNow() {
        #if DEBUG
        if previewing { return }
        #endif
        Task { await lookAtPhone() }
    }

    private func lookAtPhone() async {
        guard let reading = await readPhone() else {
            phoneGone()
            evaluate()
            return
        }
        let udid = reading.device.udid
        if device?.udid != udid { developerMode = nil }
        device = reading.device
        paired = pythonPaired[udid] ?? reading.pairRecord
        if let mode = reading.developerMode { developerMode = mode }
        if reading.developerMode == nil, step == .devmode { await askPython(udid) }
        evaluate()
    }

    /// usbmuxd's view of the phone the settings name, or of the first one on the cable.
    private func readPhone() async -> Reading? {
        let wanted = config.udid
        return await Task.detached(priority: .utility) { () -> Reading? in
            let list = Usbmux.listDevices()
            guard let entry = list.first(where: { $0.udid == wanted }) ?? list.first else { return nil }
            let info = Usbmux.deviceInfo(entry)
            return Reading(device: DeviceTools.Device(name: info?.name ?? "iPhone", os: info?.os ?? "", udid: entry.udid),
                           pairRecord: info != nil && Usbmux.hasPairRecord(udid: entry.udid),
                           developerMode: Usbmux.developerMode(entry))
        }.value
    }

    private func phoneGone() {
        let wasThere = device != nil
        device = nil
        paired = false
        if screen == .connect { unmarkDone(.connect) }
        if wasThere, step == .devmode, !done.contains(.devmode), screen != .devmodeRestart, developerMode != true {
            // the switch was flipped and the phone went down to restart
            go(to: .devmodeRestart)
        }
        developerMode = nil
    }

    /// Developer Mode usually needs a lockdown session, which only Python has. Asked while the step is
    /// on screen, not more often than every few seconds.
    private func askPython(_ udid: String) async {
        guard prep.toolsReady, !askingPython, Date().timeIntervalSince(lastAskedPython) > 3 else { return }
        askingPython = true
        let result = await DeviceTools.check(udid: udid)
        lastAskedPython = Date()
        askingPython = false
        guard let result else { return }
        pythonPaired[udid] = result.paired
        paired = result.paired
        if let mode = result.devmode { developerMode = mode }
    }

    /// Marks the step on screen done once what it asks for is true.
    func evaluate() {
        guard isOpen else { return }
        switch screen {
        case .connect:
            // an iOS older than 17.4 can't be controlled: the guide keeps waiting for one that can
            guard let device, paired, !device.os.isEmpty, device.supported else { return }
            adopt(device)
            markDone(.connect)
        case .devmode, .devmodeMissing, .devmodeRestart:
            if screen == .devmodeMissing, revealed == nil, !revealing, device != nil, prep.toolsReady {
                revealDeveloperMode()
            }
            if developerMode == true, device != nil { markDone(.devmode) }
        case .install:
            startInstallIfReady()
        default:
            break
        }
    }

    /// Another iPhone than the one the guide was done for: its own steps start over.
    private func adopt(_ device: DeviceTools.Device) {
        guard config.setupUdid != device.udid else { return }
        if !config.setupUdid.isEmpty {
            for s in [SetupStep.devmode, .uiauto, .install, .trust] { unmarkDone(s) }
            store?.config.setupConfirmed = []
            install.reset()
        }
        store?.config.setupUdid = device.udid
    }

    /// "I don't see this option": makes the switch appear in Settings.
    func revealDeveloperMode() {
        go(to: .devmodeMissing)
        guard let udid = device?.udid, prep.toolsReady else { revealed = nil; return }
        revealing = true
        revealed = nil
        Task {
            revealed = await DeviceTools.revealDeveloperMode(udid: udid)
            revealing = false
        }
    }
}
