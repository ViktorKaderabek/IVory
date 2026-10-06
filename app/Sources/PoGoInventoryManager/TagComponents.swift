import SwiftUI

// MARK: - Tag colors

extension TagColor {
    /// Dot color (the same in light and dark mode, as in the game).
    var swatch: Color {
        switch self {
        case .blue: return .oklch(0.62, 0.15, 255)
        case .green: return .oklch(0.68, 0.15, 150)
        case .purple: return .oklch(0.58, 0.17, 305)
        case .yellow: return .oklch(0.86, 0.15, 92)
        case .red: return .oklch(0.62, 0.2, 25)
        case .orange: return .oklch(0.73, 0.16, 55)
        case .gray: return .oklch(0.64, 0.01, 270)
        case .black: return .oklch(0.2, 0.01, 270)
        }
    }

    /// On a light dot the checkmark is dark.
    var isLight: Bool { [.green, .yellow, .orange, .gray].contains(self) }
}

/// Palette of the 8 game colors; hovering a dot shows the color's name.
struct TagPalette: View {
    @Binding var selection: TagColor
    var disabled = false
    @State private var hovered: TagColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(TagColor.allCases) { c in
                    Button {
                        if !disabled { selection = c }
                    } label: {
                        ZStack {
                            Circle().fill(c.swatch)
                            if c == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(c.isLight ? Theme.nightBg : Theme.white)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Theme.border))
                        .padding(2)
                        .overlay(Circle().strokeBorder(c == selection ? Theme.text : .clear, lineWidth: 2))
                        .scaleEffect(hovered == c ? 1.12 : 1)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                    .help(c.title)
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.15)) { hovered = inside ? c : (hovered == c ? nil : hovered) }
                    }
                }
            }
            Text((hovered ?? selection).title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .opacity(disabled ? 0.5 : 1)
        .animation(.snappy, value: selection)
    }
}

/// Colored dot next to a tag; clicking it opens the "Tag color in the game" palette.
struct ColorDotButton: View {
    @Binding var color: TagColor
    var size: CGFloat = 12
    @State private var open = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { open.toggle() } label: {
            Circle()
                .fill(color.swatch)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Theme.border))
                .background(Circle().fill(color.swatch.opacity(0.22)).padding(-3))
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tr("Barva tagu ve hře: \(color.title)", "Tag color in the game: \(color.title)"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Barva tagu ve hře", "Tag color in the game")).font(.system(size: 13, weight: .semibold))
                TagPalette(selection: $color, disabled: !isEnabled)
            }
            .padding(14)
        }
    }
}
