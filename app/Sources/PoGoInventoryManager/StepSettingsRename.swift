import SwiftUI

// Renaming as it is set up: the IV range, the name built from the template, and a live preview of it.

extension StepSettings {
    var samples: [NameSample] {
        lastBox?.samples(in: store.config.rename.min...store.config.rename.max) ?? NameSample.design
    }

    /// The smallest and largest IV sum that falls into the range (percentages are rounded).
    var sumRange: (Int, Int) {
        let r = store.config.rename
        let pct = { (s: Int) in Int((Double(s) / 45 * 100).rounded()) }
        let sums = (0...45).filter { (r.min...r.max).contains(pct($0)) }
        return (sums.first ?? 0, sums.last ?? 0)
    }

    var rename: some View {
        let r = store.config.rename
        let shown = samples.prefix(3)
        let longest = samples.filter { !($0.custom && !r.overwriteCustom) }
            .map { NamePiece.render(r.template, $0.values).count }.max() ?? 0
        let inRange = lastBox?.count(in: r.min...r.max)
        return WeightedColumns(weights: [1.25, 1], spacing: 20) {
            // left: what gets renamed and to what
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        FieldLabel(tr("Rozsah IV", "IV range"))
                        Spacer(minLength: 4)
                        Text(pctRange(r.min, r.max))
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    DualRange(lo: $store.config.rename.min, hi: $store.config.rename.max, compact: true)
                    Text(inRange.map {
                            tr("\(pieces($0)) v rozsahu · součet IV \(sumRange.0)–\(sumRange.1)",
                               "\($0) Pokémon in range · IV sum \(sumRange.0)–\(sumRange.1)")
                        } ?? tr("Součet IV \(sumRange.0)–\(sumRange.1) · kolik kusů to je, ukážu po prvním měření",
                                "IV sum \(sumRange.0)–\(sumRange.1) · how many Pokémon that is shows after the first measurement"))
                        .font(.system(size: 12))
                        .foregroundStyle(inRange == 0 ? Theme.orange : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        FieldLabel(tr("Šablona jména", "Name template"))
                        Spacer(minLength: 4)
                        Text("\(longest)/\(NamePiece.maxLength)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(longest > NamePiece.maxLength ? Theme.red : Theme.text)
                    }
                    templateBox(over: longest > NamePiece.maxLength)
                    FlowRow(spacing: 4) {
                        ForEach(NamePiece.groups.flatMap(\.1), id: \.self) { key in
                            TemplatePaletteButton(title: NamePiece.info(key).short) {
                                withAnimation(.snappy) { store.config.rename.template.append(NameToken(key)) }
                            }
                        }
                        QuietButton(title: tr("Upravit šablonu…", "Edit template…")) { RenameEditorModel.shared.show() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // right: what it will look like, and the three exceptions
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(tr("Náhled", "Preview"))
                    ForEach(shown) { sample in
                        HStack(spacing: 8) {
                            Text(sample.name)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .frame(width: 70, alignment: .leading)
                            previewName(NamePiece.render(r.template, sample.values))
                            Spacer(minLength: 0)
                        }
                        .frame(height: 26)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SwitchRow(title: tr("Přepsat i vlastní přezdívky", "Overwrite custom nicknames too"),
                              isOn: $store.config.rename.overwriteCustom)
                    SwitchRow(title: tr("Vynechat kusy s tagem \(store.config.removeTag)",
                                        "Skip Pokémon tagged \(store.config.removeTag)"),
                              isOn: $store.config.rename.skipRemovable)
                    SwitchRow(title: tr("Jen kusy s tagem", "Only Pokémon with a tag"),
                              isOn: $store.config.rename.onlyTagEnabled)
                    if r.onlyTagEnabled {
                        Menu {
                            ForEach(store.config.allTagNames, id: \.self) { name in
                                Button(name) { store.config.rename.onlyTag = name }
                            }
                        } label: {
                            DesignField(height: 28) {
                                HStack(spacing: 8) {
                                    Text(r.onlyTag.isEmpty ? tr("Vyber tag", "Pick a tag") : r.onlyTag)
                                        .font(.system(size: 12))
                                        .foregroundStyle(r.onlyTag.isEmpty ? Theme.muted : Theme.text)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: r.onlyTagEnabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The name the template makes; anything past the game's 12 characters is struck through in red.
    func previewName(_ name: String) -> some View {
        let keep = String(name.prefix(NamePiece.maxLength))
        let cut = String(name.dropFirst(NamePiece.maxLength))
        return HStack(spacing: 0) {
            Text(keep)
            Text(cut).foregroundStyle(Theme.red).strikethrough()
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
    }

    /// The pieces the name is built from; each one can be taken out again.
    func templateBox(over: Bool) -> some View {
        FlowRow(spacing: 4) {
            ForEach(store.config.rename.template) { token in
                TemplateChip(token: token) {
                    withAnimation(.snappy) {
                        store.config.rename.template.removeAll { $0.id == token.id }
                    }
                }
                .reorderable(token.id, dragging: $draggingPiece) { from, to in
                    movePiece(from, before: to)
                }
            }
        }
        .frame(minHeight: 28, alignment: .topLeading)
        .padding(5)
        .background(Theme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(over ? Theme.red : Theme.border, lineWidth: 1)
        }
    }

    func pieces(_ n: Int) -> String { trCount(n, cs: "kus", "kusy", "kusů", en: "Pokémon", "Pokémon") }

    func movePiece(_ id: UUID, before other: UUID) {
        var list = store.config.rename.template
        guard let from = list.firstIndex(where: { $0.id == id }),
              let to = list.firstIndex(where: { $0.id == other }) else { return }
        let piece = list.remove(at: from)
        list.insert(piece, at: to)
        store.config.rename.template = list
    }
}
