import AppKit
import SwiftUI

/// Settings as a page of its own: only what isn't about a single step. What a step does is set on Run,
/// right next to the step.
struct SettingsScreen: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            StepsLiveOnRunNote()
            if runner.isRunning { lockedNote }
            WeightedColumns(weights: [1, 1], spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsGroup(title: tr("Obecné", "General")) { GeneralRows() }
                    SettingsGroup(title: "iPhone") { DeviceRows() }
                }
                VStack(alignment: .leading, spacing: 20) {
                    SettingsGroup(title: tr("Upozornění", "Notifications")) { NotificationRows() }
                    SettingsGroup(title: tr("Pokročilé", "Advanced")) { AdvancedRows() }
                    SettingsGroup(title: tr("O aplikaci", "About")) { AboutCard() }
                }
            }
            .disabled(runner.isRunning)
            .opacity(runner.isRunning ? 0.55 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: runner.isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Nastavení", "Settings"))
                .font(.system(size: 26, weight: .medium))
            HStack(spacing: 6) {
                Image(systemName: store.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(store.error == nil ? Theme.green : Theme.orange)
                Text(store.error == nil ? tr("Ukládá se samo do ", "Saves automatically to ")
                                        : tr("Nejde uložit do ", "Can't save to "))
                    .font(.system(size: 13))
                Text("~/.pogo/config.json")
                    .font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(Theme.muted)
        }
    }

    private var lockedNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 14))
            Text(tr("Během třídění nastavení měnit nejde.", "Settings can't be changed while sorting."))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.yellow)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.yellowTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A heading and the card of rows under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }
}

/// One line of a group: a label (with an optional second line) on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var first = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }
}

/// The notice that step settings moved to Run.
struct StepsLiveOnRunNote: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 15))
            Text(tr("Co dělá který krok (tagy, rozsahy, šablona jména) se nastavuje na Spuštění, přímo u kroku.",
                    "How each step works (tags, ranges, the name template) is set on Run, right next to the step."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.accentInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Two or three choices in one little box – the language switch.
struct SegmentedPicker<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T
    let pick: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { pick(value) } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(value == selection ? Theme.onAccent : Theme.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(value == selection ? Theme.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
