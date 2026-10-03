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

// MARK: - Tag bar

/// A row of the "Tags in your storage" panel: dot, name, bar (fixed scale based on the storage size), count.
/// A tag that just gained Pokémon lights up briefly and shows +N.
struct TagBarRow: View {
    let color: TagColor
    let label: String
    let count: Int?
    let max: Int
    var delta: Int = 0
    var live = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color.swatch).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Theme.border))
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(count == nil ? Theme.muted : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 118, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width * CGFloat(Swift.min(1, Double(count ?? 0) / Double(Swift.max(1, max))))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(color.swatch)
                        .overlay(Capsule().strokeBorder(Theme.border))
                        .frame(width: count == nil ? 0 : Swift.max(count == 0 ? 0 : 3, w))
                        .shadow(color: live ? color.swatch : .clear, radius: 6)
                    if live && delta != 0 {
                        Text(delta > 0 ? "+\(delta)" : "\(delta)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accentInk)
                            .offset(x: Swift.max(count == 0 ? 0 : 3, w) + 6)
                            .transition(.opacity)
                    }
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 24)
            Text(count.map { $0.formatted() } ?? "–")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(live ? Theme.accentInk : ((count ?? 0) > 0 ? Theme.text : Theme.muted))
                .contentTransition(.numericText(value: Double(count ?? 0)))
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 24)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: count)
        .animation(.easeOut(duration: 0.3), value: live)
    }
}

/// The "Tags in your storage" panel: Removable, IV tags and PvP leagues. Fills in during a run and stays after it ends.
struct TagsPanel: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner

    var body: some View {
        let c = store.config
        let ivTags = c.ivTags.sorted { $0.min > $1.min }.filter { !$0.name.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tr("Tagy v inventáři", "Tags in your storage")).font(.system(size: 15, weight: .semibold))
                Spacer()
                badge
            }
            .frame(height: 22)
            VStack(spacing: 6) {
                row(c.removeTag, c.removeTagColor)
                divider
                ForEach(ivTags) { t in row(t.name, t.color) }
                divider
                ForEach(c.pvp.all, id: \.key) { item in row(item.league.name, item.league.color) }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 3)
    }

    private func row(_ name: String, _ color: TagColor) -> some View {
        let live = runner.lastTagChange?.tag == name
        return TagBarRow(color: color, label: name, count: runner.tagCounts[name],
                         max: Swift.max(runner.boxTotal, runner.tagCounts.values.max() ?? 0, 1),
                         delta: live ? runner.lastTagChange?.delta ?? 0 : 0, live: live)
    }

    @ViewBuilder private var badge: some View {
        switch HeroState(runner: runner) {
        case .running:
            HStack(spacing: 5) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text(tr("živě", "live"))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.green)
        case .done, .stopped, .error:
            Text(runner.tagCounts.isEmpty ? tr("plní se během běhu", "fills in during a run")
                                          : tr("shrnutí běhu · \(summaryTime)", "run summary · \(summaryTime)"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .ready:
            Text(runner.tagCounts.isEmpty ? tr("plní se během běhu", "fills in during a run") : tr("poslední běh", "last run"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private var summaryTime: String {
        guard let end = runner.finishedAt else { return "" }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = Calendar.current.isDateInToday(end) ? tr("'dnes' HH:mm", "'today' HH:mm") : tr("d. M. HH:mm", "MMM d, HH:mm")

        return f.string(from: end)
    }
}
