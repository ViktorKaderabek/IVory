import AppKit
import SwiftUI

// The pieces the run panels are drawn from: the IV donut, the card frames, titles and buttons.

/// A slice of the IV donut: one of the user's own IV tags, with how many Pokémon fall into it.
struct IVSlice: Identifiable {
    let name: String
    let color: Color
    /// Tags with no color in the game are drawn as an outline, as in the design.
    let hollow: Bool
    let count: Int

    var id: String { name }

    /// The user's IV tags, best first, counted over what the last run read.
    static func all(config: AppConfig, mons: [InventoryStats.Mon]) -> [IVSlice] {
        let tags = config.ivTags.filter { !$0.name.isEmpty }.sorted { $0.min > $1.min }
        return tags.enumerated().map { i, tag in
            let upper = i == 0 ? 101 : tags[i - 1].min
            let count = mons.filter { $0.pct >= tag.min && $0.pct < upper }.count
            return IVSlice(name: tag.name, color: tag.color.swatch, hollow: tag.color == .black, count: count)
        }
    }
}

/// The ring of IV tags. The slices keep the order of the tags, best first.
struct IVDonut<Center: View>: View {
    let slices: [IVSlice]
    var size: CGFloat = 128
    var ringWidth: CGFloat = 15
    var inner: Color
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(stops: stops, center: .center))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(inner)
                .padding(ringWidth)
            VStack(spacing: 0) { center }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: slices.map(\.count))
    }

    /// Hard stops, so the ring reads as separate slices rather than a blend.
    private var stops: [Gradient.Stop] {
        let total = max(1, slices.reduce(0) { $0 + $1.count })
        var out: [Gradient.Stop] = []
        var at = 0.0
        for slice in slices where slice.count > 0 {
            let color = slice.hollow ? Theme.track : slice.color
            out.append(.init(color: color, location: at))
            at += Double(slice.count) / Double(total)
            out.append(.init(color: color, location: min(1, at)))
        }
        if out.isEmpty { return [.init(color: Theme.track, location: 0), .init(color: Theme.track, location: 1)] }
        return out
    }
}

/// The donut's legend: two columns of tag · count.
struct IVLegend: View {
    let slices: [IVSlice]

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    TagDot(color: slice.color, hollow: slice.hollow, size: 8)
                    Text(slice.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(slice.count.formatted())
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                .frame(height: 24)
            }
        }
    }
}

/// A tag's colored dot. A tag with no color in the game is a ring instead of a disc.
struct TagDot: View {
    let color: Color
    var hollow = false
    var size: CGFloat = 8

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(Theme.muted, lineWidth: 1.5)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The card every panel on the right-hand side is made of.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
    }
}

/// A panel's heading: the name on the left, a quiet note on the right.
struct RunPanelTitle: View {
    let title: String
    let note: String

    init(_ title: String, note: String) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 4)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }
}

/// The yellow "look at this before you do anything" box.
struct NoticeBox: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.yellow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.yellowTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "Open results folder" – quiet under the storage card, outlined under the run summary.
struct ResultsFolderButton: View {
    let outlined: Bool
    @EnvironmentObject private var runner: Runner
    @State private var hovered = false

    var body: some View {
        Button { runner.openResults() } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: outlined ? 13 : 12))
                Text(tr("Otevřít složku s výsledky", "Open results folder"))
                    .font(.system(size: outlined ? 13 : 12, weight: .medium))
            }
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, outlined ? 12 : 8)
            .frame(height: outlined ? 32 : 28)
            .frame(maxWidth: outlined ? .infinity : nil)
            .background {
                RoundedRectangle(cornerRadius: outlined ? 8 : 7, style: .continuous)
                    .fill(Theme.tint.opacity(hovered ? 1 : 0))
            }
            .overlay {
                if outlined {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, outlined ? 0 : -8)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A small square icon button on a dark surface (the log header).
struct DarkIconButton: View {
    let symbol: String
    var tint: Color?
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint ?? (hovered ? Color.oklch(0.9, 0.01, 280) : Color.oklch(0.6, 0.02, 280)))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
