import AppKit
import SwiftUI

/// Nastavení vysunuté z boku: jen to podstatné, zbytek pod „Pokročilé“.
struct SettingsInspector: View {
    var body: some View {
        ScrollView {
            SettingsContent()
        }
    }
}

struct SettingsContent: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @State private var devices: [DeviceTools.Device] = []
    @State private var message: String?
    @State private var proposedTeam: String?
    @State private var busy = false
    @AppStorage("showAdvanced") private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nastavení").font(.title2.weight(.bold))
                Spacer()
                SaveInfo()
            }
            if runner.isRunning {
                RunningBanner().transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                duplicates
                ivTags
                device
                advanced
            }
            .disabled(runner.isRunning)
        }
        .padding(20)
        .animation(.snappy, value: runner.isRunning)
    }

    // MARK: - Duplicity

    private var duplicates: some View {
        InspectorSection(title: "Duplicity", symbol: "square.on.square") {
            LabeledField(label: "Uložené hledání ve hře", hint: "duplicit", text: $store.config.savedSearch)
            LabeledField(label: "Tag pro horší kusy", hint: "Removable", text: $store.config.removeTag,
                         footnote: "Když ve hře neexistuje, skript ho založí.")
            Stepper(value: $store.config.keepBest, in: 1...10) {
                HStack {
                    Text("Nechat nejlepších z várky")
                    Spacer()
                    Text("\(store.config.keepBest)")
                        .font(.body.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(store.config.keepBest)))
                }
            }
            .animation(.snappy, value: store.config.keepBest)
        }
    }

    // MARK: - IV tagy

    private var ivTags: some View {
        InspectorSection(title: "IV tagy", symbol: "tag") {
            let sorted = store.config.ivTags.sorted { $0.min > $1.min }
            VStack(spacing: 6) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, tag in
                    if let binding = binding(for: tag) {
                        CompactTagRow(tag: binding, color: Theme.tagColor(index, of: sorted.count),
                                      range: range(for: index, in: sorted)) {
                            withAnimation(.snappy) { store.config.ivTags.removeAll { $0.id == tag.id } }
                        }
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sorted.map(\.min))
            HStack {
                Button {
                    withAnimation(.snappy) { store.config.ivTags.append(IVTag(min: 0, name: "")) }
                } label: { Label("Přidat", systemImage: "plus") }
                Button {
                    withAnimation(.snappy) { store.config.ivTags = AppConfig.defaultIVTags }
                } label: { Label("Výchozí", systemImage: "arrow.counterclockwise") }
                Spacer()
            }
            .buttonStyle(.borderless)
            Toggle(isOn: Binding(get: { !store.config.recheckTagged }, set: { store.config.recheckTagged = !$0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Přeskočit už otagované")
                    Text("Kdo už má jeden z tagů, toho neotevírá – rychlejší.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Text("Procenta = součet IV / 45. Názvy musí sedět s tagy ve hře.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(for tag: IVTag) -> Binding<IVTag>? {
        guard let i = store.config.ivTags.firstIndex(where: { $0.id == tag.id }) else { return nil }
        return $store.config.ivTags[i]
    }

    private func range(for index: Int, in sorted: [IVTag]) -> ClosedRange<Int> {
        let low = sorted[index].min
        let high = index == 0 ? 100 : max(low, sorted[index - 1].min - 1)
        return low...max(low, high)
    }

    // MARK: - iPhone

    private var device: some View {
        InspectorSection(title: "iPhone", symbol: "iphone.gen3") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Zařízení (UDID)").font(.callout.weight(.medium))
                HStack {
                    TextField("automaticky – první připojený", text: $store.config.udid)
                        .textFieldStyle(.roundedBorder)
                    Button("Najít") { findDevices() }.disabled(busy)
                }
                if devices.count > 1 {
                    Picker("", selection: $store.config.udid) {
                        ForEach(devices) { Text("\($0.name) – iOS \($0.os)").tag($0.udid) }
                    }
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apple Team ID").font(.callout.weight(.medium))
                HStack {
                    TextField("automaticky z certifikátu", text: $store.config.teamId)
                        .textFieldStyle(.roundedBorder)
                    Button("Zjistit") { findTeam() }.disabled(busy)
                }
            }
            if let message {
                HStack(alignment: .top, spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let proposedTeam {
                        Button("Použít") {
                            store.config.teamId = proposedTeam
                            self.proposedTeam = nil
                            self.message = "Team ID: \(proposedTeam)"
                        }
                        .controlSize(.small)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: message)
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

    // MARK: - Pokročilé

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("Pokročilé").font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $store.config.ivCacheHours, in: 0...72) {
                            HStack {
                                Text("Pamatovat změřená IV")
                                Spacer()
                                Text("\(store.config.ivCacheHours) h").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Stepper(value: $store.config.maxGroups, in: 0...999) {
                            HStack {
                                Text("Max. várek duplicit")
                                Spacer()
                                Text(store.config.maxGroups == 0 ? "všechny" : "\(store.config.maxGroups)")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        HStack {
                            Button("Soubor s nastavením") {
                                NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
                            }
                            Spacer()
                            Button("Obnovit výchozí", role: .destructive) {
                                withAnimation(.snappy) { store.resetKeepingDevice() }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Komponenty

struct InspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SoftIcon(symbol: symbol, size: 26)
                Text(title).font(.headline)
            }
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 12) { content }
            }
        }
    }
}

struct LabeledField: View {
    let label: String
    let hint: String
    @Binding var text: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            TextField(hint, text: $text).textFieldStyle(.roundedBorder)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CompactTagRow: View {
    @Binding var tag: IVTag
    let color: Color
    let range: ClosedRange<Int>
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color.gradient)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Název tagu", text: $tag.name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Text(range.lowerBound == range.upperBound ? "\(range.lowerBound) %" : "\(range.lowerBound)–\(range.upperBound) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            Text("od \(tag.min) %")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(tag.min)))
            Stepper("", value: $tag.min, in: 0...100)
                .labelsHidden()
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0.35)
            }
            .buttonStyle(.borderless)
            .help("Odebrat tag")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .animation(.snappy, value: tag.min)
    }
}

struct SaveInfo: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        Group {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if let savedAt = store.savedAt {
                Label("Uloženo", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .id(savedAt)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Label("Ukládá se samo", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .animation(.snappy, value: store.savedAt)
    }
}
