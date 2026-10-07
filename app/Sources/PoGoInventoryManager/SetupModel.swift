import Foundation

// The setup guide: seven steps in three phases that take a new user from a plugged-in iPhone to the
// first run. It opens by itself after the risk notice and stays until a run has connected to the
// iPhone; a first run that can't connect brings it back. After that, a run that fails on the phone asks
// whether to go through the guide again.
//
// A step that is met turns green and lights up Continue; apart from a successful sign-in the guide never
// moves on by itself, so there is time to read. Steps already done (a valid sign-in, say) are skipped on the way forward. The two things
// IVory can't see from the Mac (UI Automation and trusting the developer) the user ticks.

enum SetupPhase: Int, CaseIterable, Identifiable {
    case iphone, appleId, firstStart

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .iphone: return "iPhone"
        case .appleId: return "Apple ID"
        case .firstStart: return tr("První start", "First start")
        }
    }
}

enum SetupStep: String, CaseIterable, Identifiable {
    case connect, devmode, uiauto, appleid, install, trust, ready

    var id: String { rawValue }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var phase: SetupPhase {
        switch self {
        case .connect, .devmode, .uiauto: return .iphone
        case .appleid: return .appleId
        case .install, .trust, .ready: return .firstStart
        }
    }

    var title: String {
        switch self {
        case .connect: return tr("Připojení", "Connect")
        case .devmode: return tr("Režim pro vývojáře", "Developer Mode")
        case .uiauto: return tr("Automatizace UI", "UI Automation")
        case .appleid: return tr("Přihlášení", "Sign in")
        case .install: return tr("Instalace", "Install")
        case .trust: return tr("Důvěra vývojáři", "Trust developer")
        case .ready: return tr("Otevřít Pokémon GO", "Open Pokémon GO")
        }
    }

    /// Done on the iPhone rather than on the Mac.
    var onPhone: Bool { self != .appleid && self != .install }

    /// The two things IVory can't see from the Mac; the user ticks them.
    var confirmedByHand: Bool { self == .uiauto || self == .trust }

    var firstScreen: SetupScreen {
        switch self {
        case .connect: return .connect
        case .devmode: return .devmode
        case .uiauto: return .uiauto
        case .appleid: return .appleid
        case .install: return .install
        case .trust: return .trustdev
        case .ready: return .ready
        }
    }

    var next: SetupStep? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

/// One screen of the guide; a step can have a few (the Developer Mode detours, the code, the new app).
enum SetupScreen: String, CaseIterable {
    case connect
    case devmode, devmodeMissing = "devmode-missing", devmodeRestart = "devmode-restart"
    case uiauto
    case appleid, appleidCode = "appleid-code"
    case install, helper
    case trustdev
    case ready

    var step: SetupStep {
        switch self {
        case .connect: return .connect
        case .devmode, .devmodeMissing, .devmodeRestart: return .devmode
        case .uiauto: return .uiauto
        case .appleid, .appleidCode: return .appleid
        case .install, .helper: return .install
        case .trustdev: return .trust
        case .ready: return .ready
        }
    }

    /// Where the user has to look: the phone, the code on the phone, or the Mac.
    var cue: SetupCue {
        switch self {
        case .appleid, .install: return .mac
        case .appleidCode: return .code
        default: return .phone
        }
    }

    /// Where Back goes.
    var back: SetupScreen? {
        switch self {
        case .connect: return nil
        case .devmode: return .connect
        case .devmodeMissing, .devmodeRestart, .uiauto: return .devmode
        case .appleid: return .uiauto
        case .appleidCode, .install: return .appleid
        case .helper: return .install
        case .trustdev: return .helper
        case .ready: return .trustdev
        }
    }
}
