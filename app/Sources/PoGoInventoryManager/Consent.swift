import AppKit
import SwiftUI

/// Risk notice: a window over the whole app on first launch (and after the text changes)
/// until the user ticks all three checkboxes. Nothing can be started without consent.
enum Consent {
    /// Version of the notice text. Bump it when the text changes, and the window shows again.
    /// scripts/run.sh has the same number (CONSENT_VERSION).
    static let version = 1

    struct Risk: Identifiable {
        let symbol: String
        let color: Color
        let tint: Color
        let title: String
        let text: String
        var id: String { symbol }
    }

    static var risks: [Risk] {
        [
            Risk(symbol: "exclamationmark.octagon.fill", color: Theme.red, tint: Theme.redTint,
                 title: tr("Můžeš přijít o účet", "You can lose your account"),
                 text: tr("Niantic může účet dočasně nebo natrvalo zablokovat. Přijdeš tím o všechny Pokémony i předměty.",
                          "Niantic can suspend or permanently ban your account. You'd lose all your Pokémon and items.")),
            Risk(symbol: "nosign", color: Theme.orange, tint: Theme.orangeTint,
                 title: tr("Porušuješ podmínky hry", "You break the game's terms"),
                 text: tr("Automatizace je v podmínkách použití Pokémon GO zakázaná.",
                          "Automation is forbidden by the Pokémon GO Terms of Service.")),
            Risk(symbol: "checkmark.shield.fill", color: Theme.green, tint: Theme.greenTint,
                 title: tr("Bot nic nepřevádí", "The bot never transfers anything"),
                 text: tr("Jen taguje a přejmenovává a potvrzovací dialogy vždy zruší. I tak se může splést, tak si tagy před převodem zkontroluj.",
                          "It only tags and renames, and it always cancels confirmation dialogs. It can still get things wrong, so check the tags before you transfer.")),
        ]
    }

    static var checks: [String] {
        [
            tr("Rozumím, že účet může být zablokován, i natrvalo.",
               "I understand my account can be banned, even permanently."),
            tr("Aplikaci používám na vlastní riziko a za svůj účet odpovídám sám.",
               "I use the app at my own risk and I alone am responsible for my account."),
            tr("Beru na vědomí, že IVory nemá nic společného s Niantic ani The Pokémon Company.",
               "I acknowledge that IVory has nothing to do with Niantic or The Pokémon Company."),
        ]
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func isGiven(_ config: AppConfig) -> Bool { config.consentVersion >= version }

    @MainActor static func accept(_ store: ConfigStore) {
        store.config.consentVersion = version
        store.config.consentAt = ISO8601DateFormatter().string(from: Date())
        store.config.consentAppVersion = appVersion
        store.save()
    }

    /// Revoking: the window shows up on the next launch.
    @MainActor static func revoke(_ store: ConfigStore) {
        store.config.consentVersion = 0
        store.config.consentAt = ""
        store.config.consentAppVersion = ""
        store.save()
    }

    /// "3. 10. 2026 13:40" / "Oct 3, 2026 at 1:40 PM"
    static func dateText(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// The list of risks (the consent window and Settings → About).
struct ConsentRiskList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Consent.risks) { r in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: r.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(r.color)
                        .frame(width: 20)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.system(size: 14, weight: .medium))
                        Text(r.text).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The first start: the notice fills the whole window instead of sitting in a dialog. The left half is
/// the app, the right half what has to be agreed to. Nothing else in the window works until all three
/// boxes are ticked.
struct ConsentOverlay: View {
    @EnvironmentObject private var store: ConfigStore
    let onAccept: () -> Void
    @State private var checked = [false, false, false]

    private var count: Int { checked.filter { $0 }.count }
    private var all: Bool { count == checked.count }

    var body: some View {
        WeightedColumns(weights: [0.85, 1], spacing: 0, fillHeight: true) {
            cover
            form
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .ignoresSafeArea()
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Left half

    private var cover: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            AppIconView()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 25, y: 20)
                .pops(0.1)
            Text(tr("Než spustíš IVory", "Before you start IVory"))
                .font(.system(size: 40, weight: .medium))
                .tracking(-1.2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(tr("IVory ovládá Pokémon GO za tebe. Hra to nepovoluje.",
                    "IVory controls Pokémon GO for you. The game doesn't allow it."))
                .font(.system(size: 16))
                .foregroundStyle(Color.oklch(0.82, 0.02, 280))
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(tr("Celé znění je v README a v Nastavení › O aplikaci.",
                    "The full text is in the README and in Settings › About."))
                .font(.system(size: 12))
                .foregroundStyle(Color.oklch(0.68, 0.02, 280))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 70)                   // under the traffic lights
        .padding(.bottom, 40)
        .background { glow }
        .foregroundStyle(Theme.white)
        .clipped()
    }

    private var glow: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [.oklch(0.31, 0.08, 282), .oklch(0.16, 0.025, 278)],
                               center: .topLeading, startRadius: 0,
                               endRadius: max(geo.size.width * 1.1, geo.size.height * 0.8) * 0.7)
                Circle().fill(Theme.violet).blur(radius: 60).opacity(0.35)
                    .frame(width: 420, height: 420)
                    .offset(x: geo.size.width - 260, y: geo.size.height - 280)
                Circle().fill(Theme.lightTeal).blur(radius: 60).opacity(0.2)
                    .frame(width: 320, height: 320)
                    .offset(x: -80, y: geo.size.height * 0.8 - 320)
            }
        }
    }

    // MARK: - Right half

    private var form: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(Consent.risks.enumerated()), id: \.element.id) { i, risk in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: risk.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(risk.color)
                            .frame(width: 34, height: 34)
                            .background(risk.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(risk.title).font(.system(size: 14, weight: .medium))
                            Text(risk.text)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .entrance(0.1 + 0.12 * Double(i), rise: 8, duration: 0.45)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("Potvrď prosím", "Please confirm"))
                        .font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 8)
                    Text(all ? tr("Vše potvrzeno", "All confirmed")
                             : tr("Potvrzeno \(count) ze 3", "Confirmed \(count) of 3"))
                        .font(.system(size: 12))
                        .foregroundStyle(all ? Theme.green : Theme.muted)
                        .contentTransition(.numericText())
                }
                ForEach(Array(Consent.checks.enumerated()), id: \.offset) { i, label in
                    CheckRow(label: label, isOn: $checked[i])
                }
            }
            .padding(.top, 20)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }

            HStack(spacing: 8) {
                Text(tr("Souhlas uložím s datem a verzí aplikace. Když se podmínky změní, zeptám se znovu.",
                        "I save the consent with the date and app version. If the terms change, I'll ask again."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(tr("Ukončit", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(GhostButtonStyle(color: Theme.text, hover: Theme.hover, height: 34))
                Button(tr("Rozumím a pokračuji", "I understand, continue")) {
                    Consent.accept(store)
                    onAccept()
                }
                .buttonStyle(OutlineButtonStyle(height: 34))
                .disabled(!all)
                .keyboardShortcut(.defaultAction)
                .animation(.easeOut(duration: 0.2), value: all)
            }
            .padding(.top, 20)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// A checkbox spanning the whole row (click or Space).
    private struct CheckRow: View {
        let label: String
        @Binding var isOn: Bool
        @State private var hovering = false

        var body: some View {
            Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isOn ? Theme.accent : .clear)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.muted, lineWidth: isOn ? 0 : 1.5)
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    .frame(width: 17, height: 17)
                    .padding(.top, 1)
                    Text(label)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(isOn ? Theme.tint : (hovering ? Theme.hover : Theme.surface),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent : Theme.border, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
            .accessibilityValue(isOn ? tr("zaškrtnuto", "checked") : tr("nezaškrtnuto", "unchecked"))
        }
    }
}

/// Settings → About: version, license, the notice text, the consent date and revoking consent.
struct AboutContent: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var revoked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(tr("Verze", "Version"), Consent.appVersion)
            HStack {
                Text(tr("Licence", "License"))
                Spacer()
                Link("PolyForm Noncommercial 1.0.0",
                     destination: URL(string: "https://github.com/ViktorKaderabek/IVory/blob/main/LICENSE.md")!)
                    .foregroundStyle(Theme.accentInk)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(tr("Upozornění na rizika", "Risks and responsibility"))
                .font(.system(size: 13, weight: .semibold))
            ConsentRiskList()
            Text(tr("IVory nemá nic společného s Niantic, The Pokémon Company ani Nintendo. Pokémon a Pokémon GO jsou ochranné známky svých vlastníků.",
                    "IVory is not affiliated with Niantic, The Pokémon Company or Nintendo. Pokémon and Pokémon GO are trademarks of their respective owners."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: revoked ? "arrow.uturn.backward.circle" : "checkmark.seal.fill")
                    .foregroundStyle(revoked ? Theme.muted : Theme.green)
                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(revoked ? Theme.muted : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !revoked && Consent.isGiven(store.config) {
                Button(tr("Odvolat souhlas", "Revoke consent")) {
                    Consent.revoke(store)
                    withAnimation(.snappy) { revoked = true }
                }
                .buttonStyle(GhostButtonStyle(color: Theme.red, hover: Theme.redTint))
                .padding(.leading, -10)
            }
        }
        .font(.system(size: 14))
        .padding(14)
    }

    private var statusText: String {
        if revoked || !Consent.isGiven(store.config) {
            return tr("Souhlas odvolán. Okno se ukáže při dalším spuštění.",
                      "Consent revoked. The window shows up again on the next start.")
        }
        let when = Consent.dateText(store.config.consentAt).map { " \($0)" } ?? ""
        let version = store.config.consentAppVersion.isEmpty ? "" : tr(" (verze \(store.config.consentAppVersion))",
                                                                         " (version \(store.config.consentAppVersion))")
        return tr("Souhlas potvrzen", "Consent given") + when + version
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(Theme.muted)
        }
    }
}
