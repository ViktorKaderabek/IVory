import SwiftUI
import UniformTypeIdentifiers

/// Editor šablony jména (list nad oknem). Dílky se přidávají kliknutím, pořadí se mění přetažením,
/// vlastní text se píše přímo do dílku. Náhled ukazuje 4 kusy a počítadlo nejdelší jméno z nich.
struct RenameEditor: View {
    @Binding var config: RenameConfig
    let samples: [NameSample]
    @Environment(\.dismiss) private var dismiss
    @State private var tokens: [NameToken] = []
    @State private var dragging: UUID?

    init(config: Binding<RenameConfig>, samples: [NameSample]) {
        _config = config
        self.samples = samples
        _tokens = State(initialValue: config.wrappedValue.template)
    }

    private var example: [String: String] { samples.first?.values ?? NameSample.design[0].values }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Šablona jména", "Name template")).font(.system(size: 20, weight: .semibold))
                Text(tr("Kusům s IV \(rangeText) dám ve hře tohle jméno.", "Pokémon with IV \(rangeText) get this name in the game."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("Šablona", "Template")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    CharCounter(n: longest)
                }
                chipsField
                Text(tr("Klikni na dílek v nabídce, přidá se na konec. Přetažením změníš pořadí.",
                        "Click a piece below to add it to the end. Drag pieces to reorder them."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if overCount > 0 {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("Jméno je moc dlouhé", "The name is too long")).font(.system(size: 13, weight: .semibold))
                            Text(tr("Hra povolí 12 znaků. U \(overCount) \(overCount == 1 ? "ukázky" : "ukázek") se konec odřízne, viz náhled. Zkus zkrácený druh nebo poslední evoluci.",
                                    "The game allows 12 characters. For \(overCount) \(overCount == 1 ? "sample" : "samples") the end gets cut off, see the preview. Try the short species or the final evolution."))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.redTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Dílky", "Pieces")).font(.system(size: 13, weight: .semibold))
                ForEach(NamePiece.groups, id: \.0) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(group.0).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 78, alignment: .leading)
                        FlowRow(spacing: 6) {
                            ForEach(group.1, id: \.self) { k in addButton(k) }
                        }
                    }
                }
            }

            preview

            HStack {
                Button(tr("Výchozí", "Default")) { withAnimation(.snappy) { tokens = RenameConfig.defaultTemplate } }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button(tr("Zrušit", "Cancel")) { dismiss() }
                    .buttonStyle(OutlineButtonStyle(color: Theme.text, stroke: Theme.border, hover: Theme.raise))
                    .keyboardShortcut(.cancelAction)
                Button(tr("Hotovo", "Done")) {
                    config.template = tokens
                    dismiss()
                }
                .buttonStyle(FilledButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
        .animation(.snappy, value: overCount)
    }

    private var rangeText: String { pctRange(config.min, config.max) }

    // MARK: Šablona

    private var chipsField: some View {
        FlowRow(spacing: 6) {
            ForEach($tokens) { $token in
                NameChipView(token: $token, value: value(of: token)) {
                    withAnimation(.snappy) { tokens.removeAll { $0.id == token.id } }
                }
                .opacity(dragging == token.id ? 0.4 : 1)
                .draggable(token.id.uuidString) {
                    NameChipView(token: .constant(token), value: value(of: token))
                        .onAppear { dragging = token.id }
                }
                .dropDestination(for: String.self) { items, _ in
                    defer { dragging = nil }
                    guard let raw = items.first, let from = tokens.firstIndex(where: { $0.id.uuidString == raw }),
                          let to = tokens.firstIndex(where: { $0.id == token.id }), from != to else { return false }
                    withAnimation(.snappy) {
                        let moved = tokens.remove(at: from)
                        tokens.insert(moved, at: to)
                    }
                    return true
                }
            }
            if tokens.isEmpty {
                Text(tr("Šablona je prázdná – přidej dílek z nabídky.", "The template is empty – add a piece from below."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).frame(height: 30)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 50)
        .background(Theme.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(overCount > 0 ? Theme.red : Theme.border))
    }

    private func value(of token: NameToken) -> String {
        token.k == "text" ? (token.v ?? "") : (example[token.k] ?? "")
    }

    private func addButton(_ k: String) -> some View {
        let info = NamePiece.info(k)
        return Button {
            withAnimation(.snappy) { tokens.append(NameToken(k, k == "text" ? "TOP" : nil)) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text(info.label).font(.system(size: 12, weight: .medium))
                Text(info.glyph ?? (k == "text" ? "TOP" : example[k] ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.raise, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .foregroundStyle(Theme.text)
    }

    // MARK: Náhled

    private struct Row {
        let sample: NameSample
        let full: String
        var skip: Bool
        var count: Int { full.count }
    }

    private var rows: [Row] {
        samples.prefix(4).map { s in
            Row(sample: s, full: NamePiece.render(tokens, s.values), skip: s.custom && !config.overwriteCustom)
        }
    }

    private var longest: Int { rows.filter { !$0.skip }.map(\.count).max() ?? 0 }
    private var overCount: Int { rows.filter { !$0.skip && $0.count > NamePiece.maxLength }.count }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Náhled", "Preview")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(tr("znaků", "characters")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.sample.name).font(.system(size: 13, weight: .medium))
                            Text(row.sample.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .frame(width: 150, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        if row.skip {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tr("beze změny", "unchanged")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                Text(tr("vlastní přezdívka", "custom nickname")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                (Text(String(row.full.prefix(NamePiece.maxLength))).foregroundColor(Theme.text)
                                 + Text(String(row.full.dropFirst(NamePiece.maxLength)))
                                    .foregroundColor(Theme.red).strikethrough(true, color: Theme.red))
                                    .font(.system(size: 14, weight: .semibold))
                                if row.count > NamePiece.maxLength {
                                    Text(tr("zkrátí se", "gets cut")).font(.system(size: 12)).foregroundStyle(Theme.red)

                                }
                            }
                        }
                        Spacer()
                        Text(row.skip ? "–" : "\(row.count)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(!row.skip && row.count > NamePiece.maxLength ? Theme.red : Theme.muted)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                }
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        }
    }
}

/// Plné tlačítko v barvě akcentu (Hotovo).
struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Řádek, který se zalamuje (dílky šablony, nabídka dílků).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
