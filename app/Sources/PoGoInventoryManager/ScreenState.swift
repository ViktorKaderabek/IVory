import SwiftUI

/// What each screen remembers between visits.
///
/// Only the screen you are looking at is in the window – with all six in it, every change to the settings
/// redrew all of them and a single toggle cost tens of milliseconds. Their `@State` would die with them,
/// so the few things worth keeping (the open step, the picked boss, the selected Pokémon) live here.
/// Each screen has its own object, so a change on one does not redraw another.

@MainActor
final class RunScreenState: ObservableObject {
    static let shared = RunScreenState()
    /// True once the user has opened or closed a step by hand; until then the run decides which is open.
    @Published var touched = false
    /// Which step has its settings open.
    @Published var expanded: Runner.Step? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["IVORY_STEP"] {
        case "duplicates": return .duplicates
        case "iv": return .iv
        case "pvp": return .pvp
        case "rename": return .rename
        case "battle": return .battle
        case "weak": return .weak
        default: return nil
        }
        #else
        return nil
        #endif
    }()

    /// A new run takes the lead again.
    func followTheRun() {
        touched = false
        expanded = nil
    }
}

@MainActor
final class StorageScreenState: ObservableObject {
    static let shared = StorageScreenState()
    /// Appearance check only: the first ranked Pokémon is opened once.
    var autoPicked = false
}

@MainActor
final class RaidsScreenState: ObservableObject {
    static let shared = RaidsScreenState()
    @Published var bossID: String?
    @Published var weather = "none"
    /// How many players go; nil until the user picks, then the chance decides.
    @Published var players: Int?
}

@MainActor
final class PvPScreenState: ObservableObject {
    static let shared = PvPScreenState()
    /// Which of the suggested teams is picked in each league.
    @Published var combo: [PvPLeague: Int] = [:]
}

/// Which iPhone is plugged in right now, for the card at the bottom of the rail. Looked up once when the
/// window opens and again whenever a run starts or ends, so the rail can name the phone instead of just
/// saying "iPhone".
@MainActor
final class ConnectedPhone: ObservableObject {
    static let shared = ConnectedPhone()
    @Published private(set) var devices: [DeviceTools.Device] = []
    private var looking = false

    /// The chosen one, or the first connected when the settings say "automatic".
    func current(udid: String) -> DeviceTools.Device? {
        udid.isEmpty ? devices.first : devices.first { $0.udid == udid } ?? devices.first
    }

    func look() {
        guard !looking else { return }
        looking = true
        Task {
            devices = await DeviceTools.connectedDevices()
            looking = false
        }
    }
}

/// The iPhone section of Settings: what "Find" and "Detect" turned up.
@MainActor
final class DeviceState: ObservableObject {
    static let shared = DeviceState()
    enum Kind { case info, ok, warning }

    @Published var devices: [DeviceTools.Device] = []
    @Published var message: String?
    @Published var messageKind = Kind.info
    @Published var busy = false
}
