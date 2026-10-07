#if DEBUG
import Foundation

/// IVORY_SETUP=<screen id> (scripts/design-shots.sh) opens the guide on that screen with the design's
/// made-up phone and no polling. "connect-ok" and "appleid-error" are states of a screen.
extension SetupFlow {
    func preview(_ id: String) {
        previewing = true
        device = DeviceTools.Device(name: "iPhone 15 Pro", os: "18.1", udid: "00008130-PREVIEW")
        paired = true
        prep.preview(done: id != "install")
        SetupForm.shared.appleId = "jan.novak@icloud.com"
        let name = ["connect-ok": "connect", "appleid-error": "appleid"][id] ?? id
        let target = SetupScreen(rawValue: name) ?? .connect
        for s in SetupStep.allCases where s.number < target.step.number { markDone(s) }
        if id == "connect-ok" { markDone(.connect) }
        if id == "connect" || target == .devmodeRestart { device = nil }
        if target == .devmodeMissing { revealed = true }
        if id == "appleid-error" { signIn.setPreview(.failed(.wrongPassword)) }
        if target == .appleidCode { signIn.setPreview(.needsCode) }
        showForPreview(target)
    }
}
#endif
