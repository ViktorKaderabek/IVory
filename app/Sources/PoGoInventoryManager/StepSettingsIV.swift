import SwiftUI

// The IV tags as they are set up: the bands, their names and colours, and how far the bot got.

extension StepSettings {
    @ViewBuilder
    var ivTags: some View {
        if runner.isRunning {
            ivTagsLive
        } else {
            ivTagsEditor
        }
    }

    /// While the bot sorts: how far it is and how many went into each tag.
    var ivTagsLive: some View {
        let counts = runner.tagCounts
        return VStack(alignment: .leading, spacing: 12) {
            if let scanned = runner.scanned {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(tr("Čtu IV", "Reading IV")).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 4)
                        Text("\(scanned.done) / \(scanned.total) · \(Int(Double(scanned.done) / Double(max(1, scanned.total)) * 100))%")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.progress)
                                .frame(width: geo.size.width * CGFloat(scanned.done) / CGFloat(max(1, scanned.total)))
                        }
                    }
                    .frame(height: 6)
                    .animation(.easeOut(duration: 0.4), value: scanned.done)
                }
            }
            twoColumns(store.config.ivTags.sorted { $0.min > $1.min }.filter { !$0.name.isEmpty }) { tag in
                HStack(spacing: 10) {
                    TagDot(color: tag.color.swatch, hollow: tag.color == .black, size: 10)
                    Text(tag.name).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text((counts[tag.name] ?? 0).formatted())
                        .font(.system(size: 12).monospacedDigit())
                        .contentTransition(.numericText(value: Double(counts[tag.name] ?? 0)))
                }
                .frame(height: 28)
            }
        }
    }

    /// The tags themselves: name in the game, colour, IV range, order.
    var ivTagsEditor: some View {
        let sorted = store.config.ivTags.sorted { $0.min > $1.min }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 14, height: 1)
                Color.clear.frame(width: 18, height: 1)
                FieldLabel(tr("Název tagu ve hře", "Tag name in the game"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                FieldLabel(tr("Rozsah IV", "IV range")).frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 28, height: 1)
            }
            .padding(.bottom, 4)

            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, tag in
                if let binding = binding(for: tag) {
                    IVTagRow(tag: binding,
                             upper: index == 0 ? 100 : sorted[index - 1].min - 1,
                             paletteOpen: colorOpen == tag.id,
                             togglePalette: {
                                 withAnimation(.easeOut(duration: 0.15)) {
                                     colorOpen = colorOpen == tag.id ? nil : tag.id
                                 }
                             },
                             setUpper: { newUpper in
                                 guard index > 0, let above = self.binding(for: sorted[index - 1]) else { return }
                                 above.wrappedValue.min = min(100, max(tag.min + 1, newUpper + 1))
                             },
                             remove: {
                                 withAnimation(.snappy) {
                                     store.config.ivTags.removeAll { $0.id == tag.id }
                                     colorOpen = nil
                                 }
                             })
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.95))))
                    .reorderable(tag.id, dragging: $draggingTag) { from, to in
                        moveTag(from, before: to)
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sorted.map(\.min))

            HStack(spacing: 10) {
                SmallOutlineButton(symbol: "plus", title: tr("Přidat tag", "Add tag")) {
                    withAnimation(.snappy) {
                        store.config.ivTags.append(IVTag(min: 0, name: "", color: .gray))
                    }
                }
                QuietButton(title: tr("Zpět na 7 výchozích", "Reset to the 7 defaults")) {
                    withAnimation(.snappy) {
                        store.config.ivTags = AppConfig.defaultIVTags
                        colorOpen = nil
                    }
                }
                Spacer(minLength: 8)
                Text(ivNote.text)
                    .font(.system(size: 12))
                    .foregroundStyle(ivNote.warn ? Theme.orange : Theme.muted)
                    .lineLimit(1)
            }
            .padding(.top, 8)
        }
    }

    /// Does every IV have a tag, and does every tag have a name?
    var ivNote: (text: String, warn: Bool) {
        let tags = store.config.ivTags
        if tags.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return (tr("Každý tag potřebuje název", "Every tag needs a name"), true)
        }
        if let lowest = tags.map(\.min).min(), lowest > 0 {
            return (tr("Pro 0–\(lowest - 1) % není tag", "No tag for 0–\(lowest - 1)%"), true)
        }
        return (tr("\(tags.count) tagů · každé IV má svůj", "\(tags.count) tags · every IV has one"), false)
    }

    /// Dragging an IV tag past another swaps which band each of them covers – the bands themselves stay,
    /// so the ranges still cover everything without a gap.
    func moveTag(_ id: UUID, before other: UUID) {
        let sorted = store.config.ivTags.sorted { $0.min > $1.min }
        guard let from = sorted.firstIndex(where: { $0.id == id }),
              let to = sorted.firstIndex(where: { $0.id == other }) else { return }
        let bands = sorted.map(\.min)
        var order = sorted
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        for (i, tag) in order.enumerated() {
            guard let index = store.config.ivTags.firstIndex(where: { $0.id == tag.id }) else { continue }
            store.config.ivTags[index].min = bands[i]
        }
    }
}
