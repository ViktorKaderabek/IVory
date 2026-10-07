import AppKit
import SwiftUI

// The settings themselves, group by group: general, run results, the iPhone, notifications and the advanced ones.

struct GeneralRows: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        SettingsRow(title: tr("Jazyk", "Language"), first: true) {
            SegmentedPicker(options: AppLanguage.allCases.map { ($0, $0.title) },
                      selection: store.config.language) { lang in
                LanguageSwitch.change(to: lang, store: store)
            }
        }
        SettingsRow(title: tr("Aktualizace", "Updates"), detail: updateLine) {
            SmallOutlineButton(symbol: nil, title: tr("Zkontrolovat", "Check now")) { updater.check(manual: true) }
        }
        SettingsRow(title: tr("Kontrolovat aktualizace automaticky", "Check for updates automatically")) {
            StepSwitch(on: store.config.checkUpdates) { store.config.checkUpdates.toggle() }
        }
        RunResultsRow()
    }

    private var updateLine: String {
        var parts = [tr("Verze \(Consent.appVersion)", "Version \(Consent.appVersion)")]
        switch updater.state {
        case .ready(let release, _): parts.append(tr("připravena \(release.version), restartuj v postranním panelu",
                                                     "\(release.version) ready, restart from the sidebar"))
        case .available(let release): parts.append(tr("nová verze \(release.version)", "\(release.version) available"))
        case .downloading(let release, let done):
            parts.append(tr("stahuji \(release.version) · \(percentText(Int(done * 100)))",
                            "downloading \(release.version) · \(percentText(Int(done * 100)))"))
        case .checking: parts.append(tr("kontroluji…", "checking…"))
        case .failed(let why, let release):
            parts.append(release.map { tr("\($0.version) se nepodařilo stáhnout: \(why)", "couldn't download \($0.version): \(why)") }
                         ?? tr("kontrola selhala", "the check failed"))
        case .upToDate: parts.append(tr("máš nejnovější", "up to date"))
        case .idle: break
        }
        return parts.joined(separator: " · ")
    }
}

/// How much space the run folders take, and deleting them.
struct RunResultsRow: View {
    @State private var runs: Int?
    @State private var bytes: Int64 = 0
    @State private var confirming = false
    @State private var freed: Int64?

    var body: some View {
        SettingsRow(title: tr("Výsledky běhů", "Run results"), detail: line) {
            if let runs, runs > 0 {
                Button(confirming ? tr("Opravdu smazat", "Really delete") : tr("Smazat", "Delete")) {
                    if confirming {
                        freed = RunResults.deleteAll()
                        confirming = false
                        scan()
                    } else {
                        withAnimation(.snappy) { confirming = true }
                    }
                }
                .buttonStyle(OutlineButtonStyle(color: Theme.red, stroke: Theme.red, hover: Theme.redTint, height: 28))
            }
        }
        .onAppear(perform: scan)
    }

    private var line: String {
        if let freed { return tr("Uvolněno \(RunResults.text(freed))", "Freed \(RunResults.text(freed))") }
        guard let runs else { return tr("počítám…", "measuring…") }
        if runs == 0 { return tr("Složka je prázdná", "The folder is empty") }
        return tr("\(trCount(runs, cs: "běh", "běhy", "běhů", en: "run", "runs")) · \(RunResults.text(bytes)) na disku",
                  "\(trCount(runs, cs: "běh", "běhy", "běhů", en: "run", "runs")) · \(RunResults.text(bytes)) on disk")
    }

    private func scan() {
        Task.detached(priority: .utility) {
            let result = RunResults.scan()
            await MainActor.run { runs = result.runs; bytes = result.bytes }
        }
    }
}

struct DeviceRows: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var found = DeviceState.shared
    @ObservedObject private var setup = SetupFlow.shared
    @State private var session: AppleAccount.Session?

    private typealias Kind = DeviceState.Kind
    private static let expiryFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField(label: tr("Zařízení", "Device")) {
                HStack(spacing: 6) {
                    deviceField
                    SmallOutlineButton(symbol: nil, title: tr("Najít", "Find")) { findDevices() }
                        .disabled(found.busy)
                }
            }
            if found.message != nil { statusLine }
            LabeledField(label: "Apple ID") {
                HStack(spacing: 8) {
                    Image(systemName: signedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(signedIn ? Theme.green : Theme.orange)
                    Text(appleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(signedIn ? Theme.text : Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if signedIn {
                        SmallOutlineButton(symbol: nil, title: tr("Odhlásit", "Sign out")) {
                            AppleAccount.signOut()
                            refreshSignIn()
                        }
                    } else {
                        SmallOutlineButton(symbol: nil, title: tr("Přihlásit", "Sign in")) { SetupFlow.shared.signInOnly() }
                    }
                }
            }
            Text(tr("""
                    IVory tvým Apple ID podepíše pomocnou aplikaci, bez které iPhone ovládat nejde. \
                    Přihlášení probíhá přímo u Applu a heslo si IVory neukládá; v Macu zůstane jen \
                    přihlášení na asi rok. Odhlášením ho smažeš.
                    """,
                    """
                    IVory signs the helper app the iPhone can't be controlled without with your Apple ID. \
                    The sign-in goes straight to Apple and IVory never stores the password; only the \
                    sign-in stays on the Mac, for about a year. Signing out deletes it.
                    """))
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SmallOutlineButton(symbol: "arrow.counterclockwise", title: tr("Projít nastavení znovu", "Run setup again")) {
                    SetupFlow.shared.rerun()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .animation(.snappy, value: found.message)
        .onAppear { refreshSignIn() }
        .onChange(of: setup.isOpen) { _, _ in refreshSignIn() }
    }

    /// Found iPhones as a menu, otherwise a manually entered UDID.
    @ViewBuilder private var deviceField: some View {
        if found.devices.isEmpty {
            DesignField {
                TextField(tr("automaticky – první připojený", "automatic – first connected"), text: $store.config.udid)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
        } else {
            Menu {
                Button(tr("Automaticky – první připojený", "Automatic – first connected")) { store.config.udid = "" }
                Divider()
                ForEach(found.devices) { d in
                    Button("\(d.name) – iOS \(d.os)") { store.config.udid = d.udid }
                }
            } label: {
                DesignField {
                    HStack(spacing: 8) {
                        Text(selectedDeviceTitle)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var selectedDeviceTitle: String {
        if let d = found.devices.first(where: { $0.udid == store.config.udid }) { return "\(d.name) – iOS \(d.os)" }
        return store.config.udid.isEmpty ? tr("Automaticky – první připojený", "Automatic – first connected") : store.config.udid
    }

    @ViewBuilder private var statusLine: some View {
        if let message = found.message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if found.busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var dotColor: Color {
        switch found.messageKind {
        case .ok: return Theme.green
        case .warning: return Theme.orange
        case .info: return Theme.muted
        }
    }

    private func findDevices() {
        found.busy = true
        found.messageKind = .info
        found.message = tr("Hledám připojené iPhony…", "Looking for connected iPhones…")
        Task {
            let list = await DeviceTools.connectedDevices()
            found.devices = list
            if let first = list.first {
                if !store.config.udid.isEmpty && !list.contains(where: { $0.udid == store.config.udid }) {
                    store.config.udid = first.udid
                } else if store.config.udid.isEmpty {
                    store.config.udid = first.udid
                }
                found.messageKind = .ok
                found.message = list.count == 1
                    ? tr("Nalezen \(first.name) (iOS \(first.os))", "Found \(first.name) (iOS \(first.os))")
                    : tr("Nalezeno \(list.count) zařízení – vyber v seznamu.", "Found \(list.count) devices – pick one from the list.")
            } else {
                found.messageKind = .warning
                found.message = tr("Žádný iPhone nevidím. Připoj ho kabelem, odemkni a potvrď „Důvěřovat“.",
                             "No iPhone found. Connect it with a cable, unlock it and tap “Trust”.")
            }
            found.busy = false
        }
    }

    // MARK: - signing in to Apple

    private var signedIn: Bool {
        guard let session else { return false }
        return session.valid && session.appleId.caseInsensitiveCompare(store.config.appleId) == .orderedSame
    }

    private var appleLine: String {
        if signedIn {
            guard let expires = session?.expires else { return store.config.appleId }
            let f = Self.expiryFormat
            f.locale = L10n.locale
            return tr("\(store.config.appleId) · platí do \(f.string(from: expires))",
                      "\(store.config.appleId) · valid until \(f.string(from: expires))")
        }
        return store.config.appleId.isEmpty ? tr("Nepřihlášeno", "Not signed in")
            : tr("\(store.config.appleId) · přihlášení vypršelo", "\(store.config.appleId) · sign-in expired")
    }

    /// Read from altsign-cli's session file, without asking Apple.
    private func refreshSignIn() {
        session = AppleAccount.session()
    }
}

struct NotificationRows: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        SettingsRow(title: tr("Noví raid bossové", "New raid bosses"),
                    detail: tr("Upozornění otevře bosse na Raidech", "A notification opens the boss on Raids"),
                    first: true) {
            StepSwitch(on: store.config.battle.notifyBosses) {
                store.config.battle.notifyBosses.toggle()
                if store.config.battle.notifyBosses { BossAlerts.requestPermission() }
            }
        }
    }
}

struct AdvancedRows: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        SettingsRow(title: tr("Kolik skupin duplicit projít", "Duplicate groups to check"), first: true) {
            StepperField(value: $store.config.maxGroups, range: 0...999,
                         zeroLabel: tr("všechny", "all"), height: 28, width: 92)
        }
        HStack(spacing: 8) {
            SmallOutlineButton(symbol: "doc.text", title: tr("Soubor s nastavením", "Open settings file")) {
                NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
            }
            Spacer(minLength: 8)
            Button(tr("Obnovit výchozí", "Reset to defaults")) {
                withAnimation(.snappy) { store.resetKeepingDevice() }
            }
            .buttonStyle(GhostButtonStyle(color: Theme.red, hover: Theme.redTint))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

struct AboutCard: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var revoked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIconView()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Theme.appName) \(Consent.appVersion)")
                        .font(.system(size: 14, weight: .medium))
                    HStack(spacing: 4) {
                        Link(tr("Licence", "License"),
                             destination: URL(string: "https://github.com/ViktorKaderabek/IVory/blob/main/LICENSE.md")!)
                        Text("·")
                        Link("README", destination: URL(string: "https://github.com/ViktorKaderabek/IVory")!)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentInk)
                }
                Spacer(minLength: 0)
            }
            Text(tr("IVory nemá nic společného s Niantic, The Pokémon Company ani Nintendo. Pokémon a Pokémon GO jsou ochranné známky svých vlastníků.",
                    "IVory has nothing to do with Niantic, The Pokémon Company or Nintendo. Pokémon and Pokémon GO are trademarks of their owners."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: given ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(given ? Theme.green : Theme.muted)
                Text(statusText)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if given {
                    QuietButton(title: tr("Odvolat", "Revoke")) {
                        Consent.revoke(store)
                        withAnimation(.snappy) { revoked = true }
                    }
                    .foregroundStyle(Theme.red)
                }
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var given: Bool { !revoked && Consent.isGiven(store.config) }

    private var statusText: String {
        guard given else {
            return tr("Souhlas odvolán. Okno se ukáže při dalším spuštění.",
                      "Consent revoked. The window shows up again on the next start.")
        }
        let when = Consent.dateText(store.config.consentAt).map { " \($0)" } ?? ""
        let version = store.config.consentAppVersion.isEmpty ? ""
            : tr(" (verze \(store.config.consentAppVersion))", " (version \(store.config.consentAppVersion))")
        return tr("Souhlas potvrzen", "Consent given") + when + version
    }
}
