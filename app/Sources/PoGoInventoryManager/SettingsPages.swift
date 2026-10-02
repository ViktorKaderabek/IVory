import AppKit
import SwiftUI

/// Společný rám stránek nastavení (záhlaví, zámek během běhu, info o uložení).
struct SettingsPage<Content: View>: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    let page: Page
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(symbol: page.symbol, title: page.title, subtitle: subtitle)
                if runner.isRunning { RunningBanner() }
                content
                    .disabled(runner.isRunning)
                SaveInfo()
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(page.title)
    }
}

struct SaveInfo: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        HStack(spacing: 6) {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if let savedAt = store.savedAt {
                Label("Uloženo \(savedAt.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Změny se ukládají samy", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

// MARK: - Duplicity

struct DuplicatesSettingsView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        SettingsPage(page: .duplicates, subtitle: "Stejné Pokémony porovná podle IV, nejlepší nechá a ostatní označí tagem.") {
            Card {
                VStack(spacing: 10) {
                    SettingRow(symbol: "magnifyingglass", title: "Uložené hledání",
                               detail: "Název hledání v boxu, které ukáže duplicity (Search → oblíbené).") {
                        TextField("duplicit", text: $store.config.savedSearch)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    Divider()
                    SettingRow(symbol: "tag", title: "Tag pro horší kusy",
                               detail: "Když ve hře neexistuje, skript ho založí (Add New Tag).") {
                        TextField("Removable", text: $store.config.removeTag)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    Divider()
                    SettingRow(symbol: "star", title: "Nechat nejlepších",
                               detail: "Kolik kusů z každé várky zůstane bez tagu.") {
                        Stepper(value: $store.config.keepBest, in: 1...10) {
                            Text("\(store.config.keepBest)")
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .frame(minWidth: 28)
                        }
                    }
                }
            }
            Card {
                Label {
                    Text("Skript porovnává jen to, co ukáže hledání. Legendy, shiny nebo kostýmy vyřadíš přímo v něm, třeba `count & !legendary & !shiny & !costume`.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                }
            }
        }
    }
}

// MARK: - IV tagy

struct IVTagsSettingsView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        SettingsPage(page: .ivTags, subtitle: "Každý Pokémon v boxu dostane první tag, jehož hranici splní (procenta = součet IV / 45).") {
            Card(padding: 8) {
                VStack(spacing: 0) {
                    let sorted = store.config.ivTags.sorted { $0.min > $1.min }
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, tag in
                        if let binding = binding(for: tag) {
                            IVTagRow(tag: binding, color: Theme.tagColor(index, of: sorted.count),
                                     range: range(for: index, in: sorted)) {
                                withAnimation { store.config.ivTags.removeAll { $0.id == tag.id } }
                            }
                            if index < sorted.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation { store.config.ivTags.append(IVTag(min: 0, name: "")) }
                } label: { Label("Přidat tag", systemImage: "plus") }
                Button {
                    withAnimation { store.config.ivTags = AppConfig.defaultIVTags }
                } label: { Label("Výchozí tagy", systemImage: "arrow.counterclockwise") }
                Spacer()
            }
            Card {
                SettingRow(symbol: "forward.fill", title: "Přeskočit už otagované",
                           detail: "Kdo už má právě jeden z těchto tagů, toho skript neotevírá (výrazně rychlejší).") {
                    Toggle("", isOn: Binding(
                        get: { !store.config.recheckTagged },
                        set: { store.config.recheckTagged = !$0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            Card {
                Label {
                    Text("Názvy musí přesně sedět s tagy ve hře, jinak skript založí nové.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(Theme.blue)
                }
            }
        }
    }

    private func binding(for tag: IVTag) -> Binding<IVTag>? {
        guard let i = store.config.ivTags.firstIndex(where: { $0.id == tag.id }) else { return nil }
        return $store.config.ivTags[i]
    }

    /// Rozsah procent, který tag pokrývá (podle sousedního vyššího tagu).
    private func range(for index: Int, in sorted: [IVTag]) -> ClosedRange<Int> {
        let low = sorted[index].min
        let high = index == 0 ? 100 : max(low, sorted[index - 1].min - 1)
        return low...max(low, high)
    }
}

struct IVTagRow: View {
    @Binding var tag: IVTag
    let color: Color
    let range: ClosedRange<Int>
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(color.gradient)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .padding(.leading, 12)

            TextField("Název tagu", text: $tag.name)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .frame(minWidth: 160)

            RangeBar(range: range, color: color)
                .frame(width: 150, height: 8)

            Text(range.lowerBound == range.upperBound ? "\(range.lowerBound) %" : "\(range.lowerBound)–\(range.upperBound) %")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)

            Stepper("od \(tag.min) %", value: $tag.min, in: 0...100)
                .labelsHidden()
                .help("Od kolika procent IV")

            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Odebrat tag")
            .padding(.trailing, 10)
        }
        .padding(.vertical, 10)
    }
}

/// Vodorovný pruh 0–100 % se zvýrazněným rozsahem tagu.
struct RangeBar: View {
    let range: ClosedRange<Int>
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x0 = w * CGFloat(range.lowerBound) / 100
            let x1 = w * CGFloat(min(100, range.upperBound + 1)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color.gradient)
                    .frame(width: max(6, x1 - x0))
                    .offset(x: x0)
            }
        }
    }
}

// MARK: - iPhone

struct DeviceSettingsView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var devices: [DeviceTools.Device] = []
    @State private var message: String?
    @State private var proposedTeam: String?
    @State private var busy = false

    var body: some View {
        SettingsPage(page: .device, subtitle: "Telefon, který skript ovládá, a podpis WebDriverAgentu.") {
            Card {
                VStack(spacing: 10) {
                    SettingRow(symbol: "iphone.gen3", title: "iPhone (UDID)",
                               detail: "Prázdné = první připojený iPhone.") {
                        HStack {
                            TextField("automaticky", text: $store.config.udid)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                            Button("Najít") { findDevices() }.disabled(busy)
                        }
                    }
                    if devices.count > 1 {
                        Picker("Připojená zařízení", selection: $store.config.udid) {
                            ForEach(devices) { Text("\($0.name) – iOS \($0.os)").tag($0.udid) }
                        }
                        .padding(.leading, 44)
                    }
                    Divider()
                    SettingRow(symbol: "signature", title: "Apple Team ID",
                               detail: "Z Apple ID v Xcode (Settings → Accounts). Prázdné = z certifikátu.") {
                        HStack {
                            TextField("automaticky", text: $store.config.teamId)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            Button("Zjistit") { findTeam() }.disabled(busy)
                        }
                    }
                    if let message {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(message).font(.callout).foregroundStyle(.secondary)
                            if let proposedTeam {
                                Button("Použít \(proposedTeam)") {
                                    store.config.teamId = proposedTeam
                                    self.proposedTeam = nil
                                    self.message = "Team ID: \(proposedTeam)"
                                }
                                .controlSize(.small)
                            }
                            Spacer()
                        }
                        .padding(.leading, 44)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Než začneš").font(.headline)
                    ChecklistRow(text: "iPhone je připojený kabelem a odemčený")
                    ChecklistRow(text: "Na iPhonu je zapnutý Režim pro vývojáře (Nastavení → Soukromí a zabezpečení)")
                    ChecklistRow(text: "Počítači je potvrzená důvěra (při prvním připojení)")
                    ChecklistRow(text: "V Xcode je přihlášené Apple ID (Settings → Accounts)")
                }
            }
        }
    }

    private func findDevices() {
        busy = true
        message = "Hledám připojené iPhony…"
        Task {
            let found = await DeviceTools.connectedDevices()
            devices = found
            if let first = found.first {
                if !found.contains(where: { $0.udid == store.config.udid }) {
                    store.config.udid = first.udid
                }
                message = found.count == 1
                    ? "Nalezen \(first.name) (iOS \(first.os))"
                    : "Nalezeno \(found.count) zařízení – vyber v seznamu."
            } else {
                message = "Žádný iPhone nevidím. Připoj ho kabelem, odemkni a potvrď „Důvěřovat“."
            }
            busy = false
        }
    }

    private func findTeam() {
        busy = true
        message = "Hledám certifikát Apple Development…"
        proposedTeam = nil
        Task {
            if let team = await DeviceTools.teamId() {
                if store.config.teamId.isEmpty {
                    store.config.teamId = team
                    message = "Team ID: \(team)"
                } else if store.config.teamId == team {
                    message = "Team ID sedí s certifikátem."
                } else {
                    // Současnou hodnotu nepřepisovat sám – když podepisování funguje, je správná.
                    proposedTeam = team
                    message = "V certifikátu je \(team). Když ti podepisování funguje se současnou hodnotou, nech ji být."
                }
            } else {
                message = "Certifikát „Apple Development“ jsem nenašel. Přihlas se v Xcode → Settings → Accounts."
            }
            busy = false
        }
    }
}

struct ChecklistRow: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
        }
    }
}

// MARK: - Pokročilé

struct AdvancedSettingsView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        SettingsPage(page: .advanced, subtitle: "Rychlost a omezení běhu, soubory s nastavením a pamětí.") {
            Card {
                VStack(spacing: 10) {
                    SettingRow(symbol: "memorychip", title: "Pamatovat změřená IV",
                               detail: "Opakovaný běh v tomhle čase IV znovu neměří.") {
                        Stepper(value: $store.config.ivCacheHours, in: 0...72) {
                            Text("\(store.config.ivCacheHours) h").font(.body.monospacedDigit()).frame(minWidth: 44)
                        }
                    }
                    Divider()
                    SettingRow(symbol: "number", title: "Max. počet várek duplicit",
                               detail: "Na zkoušku třeba 2. Nula = projde všechny.") {
                        Stepper(value: $store.config.maxGroups, in: 0...999) {
                            Text(store.config.maxGroups == 0 ? "všechny" : "\(store.config.maxGroups)")
                                .font(.body.monospacedDigit())
                                .frame(minWidth: 60)
                        }
                    }
                }
            }
            Card {
                VStack(spacing: 10) {
                    SettingRow(symbol: "doc.text", title: "Soubor s nastavením", detail: ConfigStore.url.path) {
                        Button("Ukázat ve Finderu") {
                            NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
                        }
                    }
                    Divider()
                    SettingRow(symbol: "folder", title: "Výsledky běhů", detail: Runner.resultsURL.path) {
                        Button("Otevřít") { Runner.shared.openResults() }
                    }
                    Divider()
                    SettingRow(symbol: "arrow.counterclockwise", title: "Obnovit výchozí nastavení",
                               detail: "iPhone a Team ID zůstanou.") {
                        Button("Obnovit", role: .destructive) { store.resetKeepingDevice() }
                    }
                }
            }
        }
    }
}
