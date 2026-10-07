import SwiftUI

/// The guide in its frame: which screen is shown, the sidebar marks and the buttons at the bottom.
struct SetupGuide: View {
    @ObservedObject var flow: SetupFlow
    @ObservedObject var prep: SetupPrep
    @ObservedObject var signIn: AppleSignIn
    @ObservedObject var install: HelperInstall
    @ObservedObject private var form = SetupForm.shared
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SetupShell(marks: marks, highlight: highlight,
                   railSub: tr("Asi 10 minut", "About 10 minutes"),
                   stepLabel: tr("Krok \(flow.step.number) ze 7", "Step \(flow.step.number) of 7"),
                   cue: flow.screen.cue, footer: footer,
                   canVisit: flow.canVisit, visit: { flow.go(to: $0.firstScreen) }) {
            screen
                .id(flow.screen)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .modifier(active: PageIn(y: 10, opacity: 0), identity: PageIn(y: 0, opacity: 1)),
                    removal: .opacity))
        }
        .onChange(of: signIn.state) { _, state in
            if state == .needsCode { flow.go(to: .appleidCode) }
            if case .failed = state, flow.screen == .appleidCode { flow.go(to: .appleid) }
            if state == .ok { flow.signInSucceeded(appleId: form.appleId) }
        }
    }

    @ViewBuilder private var screen: some View {
        switch flow.screen {
        case .appleid, .appleidCode: AppleIdScreen(flow: flow, signIn: signIn)
        case .install: InstallScreen(flow: flow, prep: prep, install: install)
        default: PhoneScreen(flow: flow)
        }
    }

    private var marks: [SetupStep: RailMark] {
        Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { s in
            (s, flow.done.contains(s) ? .done : s == flow.step ? .now : .todo)
        })
    }

    private var highlight: SetupStep? { flow.done.contains(flow.step) ? nil : flow.step }

    // MARK: the buttons

    /// The step's buttons, plus Close (and Esc) once IVory has been set up – the first time through,
    /// the guide is the way into the app.
    private var footer: SetupFooterBar {
        var bar = stepButtons
        if flow.canClose { bar.close = flow.close }
        return bar
    }

    private var stepButtons: SetupFooterBar {
        let next = tr("Pokračovat", "Continue")
        let done = flow.done
        let back = flow.onlySignIn ? nil : flow.screen.back.map { target in { flow.go(to: target) } }
        switch flow.screen {
        case .connect:
            return SetupFooterBar(back: back,
                                  secondary: done.contains(.connect) ? nil : .init(title: tr("Zkusit znovu", "Try again"), run: flow.lookNow),
                                  primary: .init(title: next, enabled: done.contains(.connect), run: flow.advance))
        case .devmode:
            return SetupFooterBar(back: back,
                                  secondary: .init(title: tr("Tuhle volbu nevidím", "I don’t see this option"), run: flow.revealDeveloperMode),
                                  primary: .init(title: next, enabled: done.contains(.devmode), run: flow.advance))
        case .devmodeMissing, .devmodeRestart:
            return SetupFooterBar(back: back, primary: .init(title: next, enabled: done.contains(.devmode), run: flow.advance))
        case .uiauto, .trustdev:
            return SetupFooterBar(back: back, primary: .init(title: next, enabled: flow.isConfirmed(flow.step), run: flow.advance))
        case .appleid where signedIn, .appleidCode where signedIn:
            return SetupFooterBar(back: back, primary: .init(title: next, run: flow.advance))
        case .appleid:
            return SetupFooterBar(back: back, primary: .init(title: tr("Přihlásit", "Sign in"), enabled: !signIn.busy && form.ready) {
                form.submit(signIn)
            })
        case .appleidCode:
            return SetupFooterBar(back: newCode,
                                  secondary: .init(title: tr("Poslat nový kód", "Send a new code"), enabled: !signIn.busy, run: newCode),
                                  primary: .init(title: tr("Ověřit", "Verify"), enabled: form.code.count == 6 && signIn.state == .needsCode) {
                                      form.submitCode(signIn)
                                  })
        case .install:
            return SetupFooterBar(back: back,
                                  secondary: installFailed ? .init(title: tr("Zkusit znovu", "Try again"), run: flow.retryInstall) : nil,
                                  primary: .init(title: next, enabled: done.contains(.install)) { flow.go(to: .helper) })
        case .helper:
            return SetupFooterBar(back: back, primary: .init(title: next, run: flow.advance))
        case .ready:
            return SetupFooterBar(back: back, primary: .init(title: "Start", symbol: "play.fill", enabled: store.config.steps.count > 0,
                                                             run: flow.finishAndStart))
        }
    }

    /// Signed in and nothing new typed: Continue instead of Sign in.
    private var signedIn: Bool { flow.done.contains(.appleid) && !signIn.busy && !form.hasPassword }

    private var installFailed: Bool {
        if case .failed = prep.state { return true }
        return install.failure != nil
    }

    /// A new code means signing in again: the password isn't kept, so it's typed once more.
    private func newCode() {
        signIn.reset()
        flow.go(to: .appleid)
    }
}
