import AppKit
import SwiftUI

/// Upozornění na rizika: okno přes celou aplikaci při prvním spuštění (a po změně textu),
/// dokud uživatel nepotvrdí všechna tři zaškrtávátka. Bez souhlasu nejde nic spustit.
enum Consent {
    /// Verze textu upozornění. Po změně textu zvýšit – okno se pak ukáže znovu.
    /// Stejné číslo je v scripts/run.sh (CONSENT_VERSION).
    static let version = 1

    struct Risk: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { symbol }
    }

    static var risks: [Risk] {
        [
            Risk(symbol: "nosign", color: Theme.red,
                 title: tr("Můžeš přijít o účet", "You can lose your account"),
                 text: tr("Niantic může účet dočasně nebo natrvalo zablokovat. Přijdeš tím o všechny Pokémony i předměty.",
                          "Niantic can suspend or permanently ban your account. You'd lose all your Pokémon and items.")),
            Risk(symbol: "scroll.fill", color: Theme.orange,
                 title: tr("Porušuješ podmínky hry", "You break the game's terms"),
                 text: tr("Automatizace je v podmínkách použití Pokémon GO zakázaná.",
                          "Automation is forbidden by the Pokémon GO Terms of Service.")),
            Risk(symbol: "checkmark.shield.fill", color: Theme.muted,
                 title: tr("Bot nic nepřevádí", "The bot never transfers anything"),
                 text: tr("Jen taguje a přejmenovává a potvrzovací dialogy vždy zruší. I tak se může splést, tak si tagy před převodem zkontroluj.",
                          "It only tags and renames, and it always cancels confirmation dialogs. It can still make mistakes, so check the tags before you transfer.")),
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

    /// Odvolání: okno se ukáže při dalším spuštění.
    @MainActor static func revoke(_ store: ConfigStore) {
        store.config.consentVersion = 0
        store.config.consentAt = ""
        store.config.consentAppVersion = ""
        store.save()
    }

    /// „3. 10. 2026 13:40“ / „Oct 3, 2026 at 1:40 PM“
    static func dateText(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Seznam rizik (okno se souhlasem i Nastavení → O aplikaci).
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
                        Text(r.title).font(.system(size: 14, weight: .semibold))
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

/// Okno se souhlasem přes celou aplikaci (pod lištou). Nejde zavřít křížkem ani Esc.
struct ConsentOverlay: View {
    @EnvironmentObject private var store: ConfigStore
    let onAccept: () -> Void
    @State private var checked = [false, false, false]

    private var count: Int { checked.filter { $0 }.count }
    private var all: Bool { count == checked.count }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}            // kliknutí mimo okno nic neudělá
            ScrollView {
                dialog
                    .padding(.top, 56)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(Theme.red)
                    .frame(width: 44, height: 44)
                    .background(Theme.redTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Než spustíš IVory", "Before you start IVory"))
                        .font(.system(size: 24, weight: .medium))
                        .tracking(-0.4)
                        .accessibilityAddTraits(.isHeader)
                    Text(tr("IVory ovládá Pokémon GO za tebe. Hra to nepovoluje.",
                            "IVory plays Pokémon GO for you. The game doesn't allow that."))
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(EdgeInsets(top: 26, leading: 28, bottom: 6, trailing: 28))

            ConsentRiskList()
                .padding(.horizontal, 20)
                .padding(.top, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Potvrď prosím", "Please confirm"))
                    .font(.system(size: 13, weight: .medium))
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
                ForEach(Array(Consent.checks.enumerated()), id: \.offset) { i, label in
                    CheckRow(label: label, isOn: $checked[i])
                }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20))

            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 14)
            HStack(spacing: 8) {
                Text(all ? tr("Vše potvrzeno", "All confirmed")
                         : tr("Potvrzeno \(count) ze 3", "Confirmed \(count) of 3"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                Spacer()
                Button(tr("Ukončit", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(OutlineButtonStyle(color: Theme.text, stroke: Theme.border, hover: Theme.raise, height: 34))
                Button(tr("Rozumím a pokračuji", "I understand, continue")) {
                    Consent.accept(store)
                    onAccept()
                }
                .buttonStyle(OutlineButtonStyle(height: 34))
                .fontWeight(.semibold)
                .disabled(!all)
                .keyboardShortcut(.defaultAction)
                .animation(.easeOut(duration: 0.2), value: all)
            }
            .padding(EdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 20))

            Text(tr("Souhlas uložím s datem a verzí aplikace. Když se podmínky změní, zeptám se znovu. Celé znění je v README a v Nastavení → O aplikaci.",
                    "Your consent is saved with the date and the app version. If the terms change, you'll be asked again. The full text is in the README and in Settings → About."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: 28, bottom: 18, trailing: 28))
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.text)
        .frame(width: 580)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Zaškrtávátko přes celý řádek (klik i mezerník).
    private struct CheckRow: View {
        let label: String
        @Binding var isOn: Bool
        @State private var hovering = false

        var body: some View {
            Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isOn ? Theme.accent : .clear)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.muted, lineWidth: isOn ? 0 : 1.5)
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .padding(.top, 1)
                    Text(label)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .background(hovering ? Theme.raise : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
            .accessibilityValue(isOn ? tr("zaškrtnuto", "checked") : tr("nezaškrtnuto", "unchecked"))
        }
    }
}

/// Nastavení → O aplikaci: verze, licence, text upozornění, datum souhlasu a jeho odvolání.
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
