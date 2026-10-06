import SwiftUI

// The weak-Pokémon sweep as it is set up: the IV threshold, the safeguards, and how many it would tag.

extension StepSettings {
    var weak: some View {
        let c = store.config.weak
        // the number has to mean what it says: it counts only what would really get the tag, so the
        // safeguards that are switched on are taken off it
        let inRange = c.maxIV > 0 ? weakAffected(under: c.maxIV) : 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(tr("Označit tagem \(store.config.removeTag) pod", "Tag \(store.config.removeTag) under"))
                    .font(.system(size: 13))
                StepperField(value: $store.config.weak.maxIV, range: 0...100,
                             suffix: "%", height: 30, width: 86)
                if let inRange {
                    Text(tr("\(inRange) dostane tag", "\(inRange) would get the tag"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .contentTransition(.numericText(value: Double(inRange)))
                        .animation(.easeOut(duration: 0.2), value: inRange)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(tr("Vždy nechat", "Always keep"))
                FlowRow(spacing: 6) {
                    PillToggle(title: tr("Legendární", "Legendary"), on: c.keepLegendary) {
                        store.config.weak.keepLegendary.toggle()
                    }
                    PillToggle(title: tr("Mýtičtí", "Mythical"), on: c.keepMythical) {
                        store.config.weak.keepMythical.toggle()
                    }
                    PillToggle(title: "Ultra Beasts", on: c.keepUltraBeast) {
                        store.config.weak.keepUltraBeast.toggle()
                    }
                    PillToggle(title: tr("Regionální formy", "Regional forms"), on: c.keepRegional,
                               help: tr("Alolan, Galarian, Hisuian, Paldean", "Alolan, Galarian, Hisuian, Paldean")) {
                        store.config.weak.keepRegional.toggle()
                    }
                    PillToggle(title: tr("Nejlepší svého druhu", "Best of each species"), on: c.keepBest) {
                        store.config.weak.keepBest.toggle()
                    }
                    PillToggle(title: tr("S PvP nebo Battle tagem", "With a PvP or Battle tag"), on: c.keepBattle) {
                        store.config.weak.keepBattle.toggle()
                    }
                }
            }

            pair {
                LabeledField(label: tr("Vlastní tag ze hry", "Your own tag from the game")) {
                    DesignField {
                        TextField(tr("Bez tagu", "No tag"), text: $store.config.weak.keepTag)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                    }
                }
            } _: {
                StepNote(tr("Shadow, lucky ani oblíbené kusy bot z obrazovky nepozná. Otaguj si je ve hře a vyber ten tag tady.",
                            "The bot can't tell shadow, lucky or favorites from the screen. Tag them in the game and pick that tag here."))
                    .padding(.top, 20)
            }
        }
    }

    /// How many Pokémon the Weak step would actually tag: under the threshold, minus everything a
    /// safeguard keeps. Counted over what the last run read.
    func weakAffected(under maxIV: Int) -> Int? {
        guard let mons = StatsStore.shared.stats?.mons, !mons.isEmpty else {
            return lastBox?.count(in: 0...(maxIV - 1))
        }
        let c = store.config.weak
        let battleTags = Set(store.config.pvp.all.map(\.league.name)
                             + store.config.battle.teams.map(\.tag.name)
                             + [store.config.battle.raid.name])
        // the best of each species is kept by its own safeguard
        var bestOfSpecies: [String: Int] = [:]
        if c.keepBest {
            for m in mons { bestOfSpecies[m.name] = Swift.max(bestOfSpecies[m.name] ?? 0, m.pct) }
        }
        return mons.filter { m in
            guard m.pct < maxIV else { return false }
            if c.keepLegendary && m.legendary { return false }
            if c.keepMythical && m.mythical { return false }
            if c.keepUltraBeast && m.ultraBeast { return false }
            if c.keepBattle && m.tags.contains(where: battleTags.contains) { return false }
            if c.keepBest && bestOfSpecies[m.name] == m.pct { return false }
            if !c.keepTag.isEmpty && m.tags.contains(c.keepTag) { return false }
            return true
        }.count
    }
}
