import SwiftUI

// Layout helpers for the settings: columns that share the width by weight, and a section that reveals itself.

/// Columns in fixed proportions – SwiftUI has no `1.25fr 1fr`, so the design's split is done here.
///
/// It is worth using even for a plain two-column row: an `HStack` of a flexible column next to a fixed one
/// probes the flexible child with several widths before it settles, so the big column is laid out more than
/// once. Here every column is proposed its exact width, once.
struct WeightedColumns: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 20
    /// A column that is always this wide; the rest share what is left by weight.
    var fixed: [CGFloat?] = []
    /// Each column takes the full height it is offered (the first-start screen); otherwise they stay as
    /// tall as their content (the step panels).
    var fillHeight = false
    /// How far down each column starts (the Run screen's side panel is level with the first step).
    var tops: [CGFloat] = []

    /// The measured height for one width – SwiftUI asks several times per layout pass.
    struct Cache {
        var width: CGFloat?
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 0
        if cache.width != width {
            let widths = widths(in: width, count: subviews.count)
            cache.height = zip(subviews, widths).enumerated()
                .map { $0.element.0.sizeThatFits(ProposedViewSize(width: $0.element.1, height: nil)).height
                        + top($0.offset) }.max() ?? 0
            cache.width = width
        }
        return CGSize(width: proposal.width ?? widths(in: width, count: subviews.count).reduce(0, +),
                      height: fillHeight ? max(cache.height, proposal.height ?? 0) : cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = widths(in: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (i, pair) in zip(subviews, widths).enumerated() {
            let (view, width) = pair
            view.place(at: CGPoint(x: x, y: bounds.minY + top(i)),
                       proposal: ProposedViewSize(width: width,
                                                  height: fillHeight ? bounds.height - top(i) : nil))
            x += width + spacing
        }
    }

    private func widths(in total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        var free = max(0, total - spacing * CGFloat(count - 1))
        let fixedWidths = (0..<count).map { $0 < fixed.count ? fixed[$0] : nil }
        free -= fixedWidths.compactMap { $0 }.reduce(0, +)
        let flexible = (0..<count).filter { fixedWidths[$0] == nil }
        let sum = flexible.reduce(0) { $0 + ($1 < weights.count ? weights[$1] : 1) }
        return (0..<count).map { i in
            if let w = fixedWidths[i] { return w }
            guard sum > 0 else { return 0 }
            return max(0, free) * (i < weights.count ? weights[i] : 1) / sum
        }
    }

    private func top(_ i: Int) -> CGFloat { i < tops.count ? tops[i] : 0 }
}

struct Reveal: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { content }
            .clipped()
            .opacity(Double(min(1, progress * 1.6)))
    }
}

/// Reports only `progress` of the content's height and pins the content to the top (`clipped` cuts off the rest).
///
/// The height is measured once per width and kept in the layout cache. Measuring it on every frame is what
/// made opening a step feel sticky: the settings panel is built from custom layouts, a menu and text fields,
/// so a full measuring pass sixty times a second is not cheap.
struct RevealLayout: Layout {
    struct Cache {
        var width: CGFloat?
        var height: CGFloat = 0
    }

    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Only `progress` changes between frames, so the measurement stays valid.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    private func height(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout Cache) -> CGFloat {
        if cache.width == width { return cache.height }
        let measured = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        cache.width = width
        cache.height = measured
        return measured
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // open: pass straight through, so the panel lays out exactly as it would without the transition
        if progress >= 1 {
            let size = child.sizeThatFits(proposal)
            cache.width = proposal.width
            cache.height = size.height
            return size
        }
        let full = height(proposal.width, subviews, &cache)
        return CGSize(width: proposal.width ?? 0, height: full * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let full = progress >= 1 ? nil : height(bounds.width, subviews, &cache)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: full))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

/// Reorders a list while the pointer is still down: as the dragged thing passes another, the two swap and
/// the list animates into its new shape, so you see the result before you let go.
struct ReorderDrop<ID: Hashable>: DropDelegate {
    let over: ID
    @Binding var dragging: ID?
    /// Moves the dragged item in front of `over`.
    let move: (ID, ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != over else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { move(dragging, over) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
