import SwiftUI

// The rows and charts the storage screen lists under its header.

/// The box split by the user's own IV tags, so the bars match the tags that end up in the game.
struct IVDistribution: View {
    let stats: InventoryStats
    let tags: [IVTag]

    private struct Bin: Identifiable {
        let label: String
        let color: Color
        let count: Int
        var id: String { label }
    }

    private var bins: [Bin] {
        let sorted = tags.filter { !$0.name.isEmpty }.sorted { $0.min > $1.min }
        return sorted.enumerated().map { i, tag in
            let upper = i == 0 ? 101 : sorted[i - 1].min
            return Bin(label: tag.name, color: tag.color.swatch,
                       count: stats.mons.filter { $0.pct >= tag.min && $0.pct < upper }.count)
        }.reversed()       // the worst on the left, the best on the right
    }

    var body: some View {
        let bins = bins
        let top = max(1, bins.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tr("Rozložení IV", "IV distribution")).font(.system(size: 15, weight: .medium))
                Text(tr("podle tvých tagů · \(atLeast90) na 90 % a víc",
                        "by your IV tags · \(atLeast90) at 90% or more"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            GeometryReader { geo in
                // the number above and the label below take a fixed slice; the bar gets the rest, so the
                // graph grows with the card instead of leaving a gap under it
                let barRoom = max(40, geo.size.height - 40)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(bins.enumerated()), id: \.element.id) { i, bin in
                        VStack(spacing: 6) {
                            Text("\(bin.count)")
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .entrance(0.3 + 0.05 * Double(i), rise: 4, duration: 0.3)
                            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2,
                                                   bottomTrailingRadius: 2, topTrailingRadius: 6, style: .continuous)
                                .fill(bin.color)
                                .frame(height: max(4, barRoom * Double(bin.count) / Double(top)))
                                .modifier(GrowUp(delay: 0.05 * Double(i)))
                            Text(bin.label)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(minHeight: 170)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
    }

    private var atLeast90: Int { stats.mons.filter { $0.pct >= 90 }.count }
}

/// The footer of a league card: the whole ranking, not just the top five.
struct AllRankedButton: View {
    let count: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(tr("Všech \(count) s pořadím", "All \(count) ranked"))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(Theme.tint.opacity(hovered ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A line of the Collections list: the mark, what it is, how many.
struct CollectionRow: View {
    let count: String
    let meta: String?
    let name: String
    let icon: () -> AnyView
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                icon()
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let meta {
                    Text(meta).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text(count)
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover.opacity(hovered ? 1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// What to type into the search in the game, with the button that copies it.
struct SearchCopyRow: View {
    let text: String
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                StatsSheetModel.shared.copy(text, message: tr("Zkopírováno „\(text)“ · vlož do vyhledávání ve hře",
                                                             "Copied “\(text)” · paste it into the search in the game"))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text(tr("Kopírovat", "Copy")).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(Theme.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
    }
}

/// A bar of the IV spread: it grows out of the axis when the screen opens.
struct GrowUp: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(y: grown ? 1 : 0.02, anchor: .bottom)
            .opacity(grown ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { grown = true; return }
                withAnimation(.design(0.6, delay: delay)) { grown = true }
            }
    }
}

/// One line of a league's ranking. Its own view: as part of the card it was a single expression the
/// compiler could not type-check in reasonable time.
struct RankedRow: View {
    let mon: InventoryStats.Mon
    let rank: Int

    @ObservedObject private var selection = MonSelection.shared
    @State private var hovered = false

    var body: some View {
        Button { selection.open(mon) } label: {
            HStack(spacing: 10) {
                Text("#\(rank)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accentInk)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 22, alignment: .leading)
                MonIcon(m: mon, size: 30, circle: true)
                Text(mon.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(percentText(mon.pct))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .background { highlight }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var highlight: some View {
        let open = selection.isOpen(mon)
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(open ? Theme.tint : Theme.hover.opacity(hovered ? 1 : 0))
    }
}
