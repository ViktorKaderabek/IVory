import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Name template editor (a window over the screen). Pieces are added by clicking and reordered by dragging;
/// custom text is typed straight into the piece. The preview shows 4 Pokémon, and the counter shows the length
/// of the longest of their names.
struct RenameEditor: View {
    @Binding var config: RenameConfig
    let samples: [NameSample]
    /// Closing is the host's job – there is no sheet to dismiss.
    var close: () -> Void = {}
    @State private var tokens: [NameToken] = []
    @State private var dragging: UUID?
    @State private var bodyHeight: CGFloat = 560
    @State private var visibleHeight: CGFloat = 560
    /// Height of the window under the sheet: the sheet must not be taller (it would stick out past the window bottom).
    @State private var parentHeight: CGFloat?
    @State private var sheetHeight: CGFloat = 720

    init(config: Binding<RenameConfig>, samples: [NameSample], close: @escaping () -> Void = {}) {
        _config = config
        self.samples = samples
        self.close = close
        _tokens = State(initialValue: config.wrappedValue.template)
    }

    private var example: [String: String] { samples.first?.values ?? NameSample.design[0].values }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Šablona jména", "Name template")).font(.system(size: 20, weight: .semibold))
                Text(tr("Kusům s IV \(rangeText) dám ve hře tohle jméno.", "Pokémon with IV \(rangeText) get this name in the game."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))

            // The title and buttons stay put, the middle scrolls when the sheet doesn't fit in the window
            // (long template, warning) – otherwise the content would overflow past the sheet's top and bottom edges.
            ScrollView {
                editorBody
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 160, idealHeight: scrollHeight, maxHeight: scrollHeight)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1).opacity(scrolls ? 1 : 0) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1).opacity(scrolls ? 1 : 0) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }

            footer.padding(EdgeInsets(top: 16, leading: 24, bottom: 24, trailing: 24))
        }
        .frame(width: 640)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        .background(ParentHeightReader(height: $parentHeight))
        .foregroundStyle(Theme.text)
        .animation(.snappy, value: overCount)
    }

    private var scrolls: Bool { bodyHeight > visibleHeight + 1 }

    /// The middle is as tall as its content, at most so tall that the whole sheet fits in the window.
    private var scrollHeight: CGFloat {
        guard let parentHeight else { return bodyHeight }
        let chrome = sheetHeight - visibleHeight   // title + buttons
        return max(160, min(bodyHeight, parentHeight - 24 - chrome))
    }

    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 18) {
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
        }
    }

    private var footer: some View {
        HStack {
            Button(tr("Výchozí", "Default")) { withAnimation(.snappy) { tokens = RenameConfig.defaultTemplate } }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            Button(tr("Zrušit", "Cancel")) { close() }
                .buttonStyle(OutlineButtonStyle(color: Theme.text, stroke: Theme.border, hover: Theme.raise))
                .keyboardShortcut(.cancelAction)
            Button(tr("Hotovo", "Done")) {
                config.template = tokens
                close()
            }
            .buttonStyle(FilledButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private var rangeText: String { pctRange(config.min, config.max) }

    // MARK: Template

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

    // MARK: Preview

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
