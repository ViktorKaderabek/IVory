import SwiftUI

/// What the run has made of the storage so far: one bar per IV tag, growing as the bot tags.
///
/// It takes over from "Now reading" once every Pokémon has been read – from then on the bot is
/// tagging and renaming, so there is no next Pokémon to show, but the tag counts keep moving. The
/// numbers come from the bot's own `tagcounts` events, so they are the counts in the game, not a
/// guess. The row that has just changed is lit up with what it gained or lost.
struct RunTagChart: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner

    private struct Row: Identifiable {
        let name: String
        let color: Color
        let hollow: Bool
        let count: Int
        var id: String { name }
    }

    private var rows: [Row] {
        store.config.ivTags
            .filter { !$0.name.isEmpty }
            .sorted { $0.min > $1.min }
            .map { Row(name: $0.name, color: $0.color.swatch, hollow: $0.color == .black,
                       count: runner.tagCounts[$0.name] ?? 0) }
    }

    var body: some View {
        let rows = rows
        let peak = max(1, rows.map(\.count).max() ?? 1)
        let total = rows.reduce(0) { $0 + $1.count }
        PanelCard {
            RunPanelTitle(tr("Jak to vychází", "How it is turning out"),
                          note: tr("\(total) otagováno", "\(total) tagged"))
            VStack(spacing: 7) {
                ForEach(rows) { row in
                    bar(row, peak: peak)
                }
            }
            if let change = runner.lastTagChange, rows.contains(where: { $0.name == change.tag }) == false {
                Text(tr("Naposledy: \(change.tag) \(signed(change.delta))",
                        "Last change: \(change.tag) \(signed(change.delta))"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    private func bar(_ row: Row, peak: Int) -> some View {
        let changed = runner.lastTagChange?.tag == row.name
        return HStack(spacing: 8) {
            TagDot(color: row.color, hollow: row.hollow, size: 7)
            Text(row.name)
                .font(.system(size: 11))
                .foregroundStyle(changed ? Theme.text : Theme.muted)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(row.hollow ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(row.color))
                        .frame(width: max(row.count > 0 ? 3 : 0,
                                          geo.size.width * CGFloat(row.count) / CGFloat(peak)))
                }
            }
            .frame(height: 6)
            Text(row.count.formatted())
                .font(.system(size: 11, weight: changed ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(changed ? Theme.accentInk : Theme.text)
                .contentTransition(.numericText(value: Double(row.count)))
                .frame(width: 30, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.45), value: row.count)
    }

    private func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }
}
