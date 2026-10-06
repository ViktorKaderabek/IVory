import SwiftUI

/// What a step does, set up right where the step is – in the step itself on the Run screen, not in a
/// panel on the other side of the window. These are the very controls Settings used to hold; Settings
/// now keeps only what isn't about a single step (language, updates, the iPhone, the rest).
struct StepSettings: View {
    let step: Runner.Step

    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var runner: Runner
    @State var colorOpen: UUID?
    @State var draggingTag: UUID?
    @State var draggingPiece: UUID?
    @State var lastBox = LastBox.load()

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // nothing is editable while the bot works – not even the step it is on
            .disabled(runner.isRunning)
            .opacity(runner.isRunning ? 0.65 : 1)
            .onChange(of: runner.finishedAt) { _, _ in lastBox = LastBox.load() }
    }

    @ViewBuilder
    var content: some View {
        switch step {
        case .duplicates: duplicates
        case .iv: ivTags
        case .pvp: pvpTags
        case .rename: rename
        case .battle: battleTags
        case .weak: weak
        }
    }

    /// Two controls side by side, as the design lays the short panels out.
    func pair<A: View, B: View>(@ViewBuilder _ a: () -> A, @ViewBuilder _ b: () -> B) -> some View {
        HStack(alignment: .top, spacing: 14) {
            a().frame(maxWidth: .infinity, alignment: .leading)
            b().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Duplicates

    // MARK: - IV tags

    // MARK: - PvP tags

    // MARK: - Renaming

    // MARK: - Battle tags

    // MARK: - Weak Pokémon

    // MARK: - Helpers

    /// Two columns of the same rows (the live tag counts).
    func twoColumns<T: Identifiable, Row: View>(_ items: [T], @ViewBuilder row: @escaping (T) -> Row) -> some View {
        let columns = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(items) { row($0) }
        }
    }

    func binding(for tag: IVTag) -> Binding<IVTag>? {
        guard let i = store.config.ivTags.firstIndex(where: { $0.id == tag.id }) else { return nil }
        return $store.config.ivTags[i]
    }
}

// MARK: - One IV tag

/// A row of the IV tag editor: order, colour, name in the game, the IV range it covers, remove.
struct IVTagRow: View {
    @Binding var tag: IVTag
    let upper: Int
    let paletteOpen: Bool
    let togglePalette: () -> Void
    let setUpper: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 14)
                    .help(tr("Pořadí určuje rozsah IV", "The order sets the IV ranges"))

                Button(action: togglePalette) {
                    Circle()
                        .fill(tag.color.swatch)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Theme.border))
                        .background {
                            if paletteOpen {
                                Circle().strokeBorder(Theme.accent, lineWidth: 1.5).padding(-2.5)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Změnit barvu", "Change color"))

                DesignField(height: 30, leading: 10, trailing: 10) {
                    TextField(tr("Bez názvu", "Untitled"), text: $tag.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    NumberField(value: $tag.min, range: 0...100)
                    Text("–").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    NumberField(value: Binding(get: { upper }, set: setUpper), range: 0...100)
                    Text("%").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .frame(width: 150, alignment: .leading)

                SmallIconButton(symbol: "trash", help: tr("Odebrat tag", "Remove tag"), action: remove)
            }

            if paletteOpen {
                HStack(spacing: 6) {
                    Text(tr("Barva tagu", "Tag color"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .padding(.trailing, 4)
                    ForEach(TagColor.allCases) { color in
                        Button { tag.color = color; togglePalette() } label: {
                            Circle()
                                .fill(color.swatch)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Theme.border))
                                .background {
                                    if color == tag.color {
                                        Circle().strokeBorder(Theme.text, lineWidth: 1.5).padding(-2.5)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(color.title)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A short numeric field, right aligned, as the IV range uses.
struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State var text = ""
    @FocusState var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(width: 46, height: 30)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: focused ? 1.5 : 1)
            }
            .onAppear { text = "\(value)" }
            .onChange(of: value) { _, new in if !focused { text = "\(new)" } }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onSubmit(commit)
    }

    func commit() {
        let digits = text.filter(\.isNumber)
        value = min(range.upperBound, max(range.lowerBound, Int(digits) ?? value))
        text = "\(value)"
    }
}

// MARK: - Name template

/// One piece of the name template, with the cross that takes it out again.
struct TemplateChip: View {
    let token: NameToken
    let remove: () -> Void

    @State var hovered = false

    var body: some View {
        let info = NamePiece.info(token.k)
        let separator = info.sep != nil
        HStack(spacing: 4) {
            Text(token.k == "text" ? (token.v?.isEmpty == false ? token.v! : info.short) : info.short)
                .font(.system(size: 12, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .opacity(hovered ? 1 : 0.65)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(separator ? Theme.muted : Theme.accentInk)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 26)
        .background(separator ? Color.clear : Theme.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if separator {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// "+ Level" – adds a piece to the template.
struct TemplatePaletteButton: View {
    let title: String
    let action: () -> Void

    @State var hovered = false

    var body: some View {
        Button(action: action) {
            Text("+ \(title)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? Theme.accentInk : Theme.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(hovered ? Theme.accent : Theme.border, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
