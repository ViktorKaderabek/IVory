import SwiftUI

/// The controls a step's settings are built from. They are small and quiet on purpose: the settings sit
/// inside the step itself on the Run screen, so they have to read as part of the card, not as a form.

// MARK: - Labels and fields

/// "Add tag" – outlined, in the accent colour.
struct SmallOutlineButton: View {
    let symbol: String?
    let title: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.tint.opacity(hovered ? 1 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A quiet text button next to it ("Reset to the 7 defaults").
struct QuietButton: View {
    let title: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? Theme.text : Theme.muted)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.hover.opacity(hovered ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A small square icon button (remove a tag).
struct SmallIconButton: View {
    let symbol: String
    var color: Color = Theme.muted
    var hoverColor: Color = Theme.red
    var hoverBackground: Color = Theme.redTint
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(hovered ? hoverColor : color)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hoverBackground.opacity(hovered ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A rounded pill that is either on (filled) or off (outlined) – the safeguards of the Weak Pokémon step.
struct PillToggle: View {
    let title: String
    let on: Bool
    var help: String?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(on ? Theme.accentInk : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(on ? Theme.tint : Theme.hover.opacity(hovered ? 1 : 0)))
            .overlay { if !on { Capsule().strokeBorder(Theme.border, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: on)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A line with a label on the left and a small switch on the right.
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StepSwitch(on: isOn, width: 28, height: 17) { isOn.toggle() }
                .padding(.top, detail == nil ? 0 : 1)
        }
    }
}

/// The paragraph of explanation under a panel.
struct StepNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Opening a step: the panel is revealed top to bottom (its height grows from zero)
/// and whatever is below slides down smoothly.
extension AnyTransition {
    static var reveal: AnyTransition {
        .modifier(active: Reveal(progress: 0), identity: Reveal(progress: 1))
    }
}

extension View {
    /// Makes a row draggable and a drop target for the others.
    func reorderable<ID: Hashable>(_ id: ID, dragging: Binding<ID?>, move: @escaping (ID, ID) -> Void) -> some View {
        self
            .opacity(dragging.wrappedValue == id ? 0.35 : 1)
            .onDrag {
                dragging.wrappedValue = id
                return NSItemProvider(object: String(describing: id) as NSString)
            }
            .onDrop(of: [.text], delegate: ReorderDrop(over: id, dragging: dragging, move: move))
    }
}
