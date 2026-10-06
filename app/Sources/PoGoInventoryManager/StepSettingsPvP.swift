import SwiftUI

// The PvP tags as they are set up: one row per league, with the rank that still gets the tag.

extension StepSettings {
    var pvpTags: some View {
        VStack(alignment: .leading, spacing: 8) {
            leagueRow("great", $store.config.pvp.great)
            leagueRow("ultra", $store.config.pvp.ultra)
            leagueRow("master", $store.config.pvp.master)
            StepNote(tr("Tag dostane kus s pořadím do zadaného čísla. Pořadí 1 = nejlepší IV pro ligu ze 4 096 kombinací pro poslední evoluci pod limitem CP. Jeden kus může mít víc PvP tagů.",
                        "A Pokémon gets the tag when its rank is within the number. Rank 1 = the best IVs for the league out of 4,096 combinations for the final evolution under the CP cap. One Pokémon can get several PvP tags."))
                .padding(.top, 4)
        }
    }

    func leagueRow(_ key: String, _ league: Binding<League>) -> some View {
        HStack(spacing: 12) {
            ColorDotButton(color: league.color, size: 10)
                .padding(-4)
            Text(league.wrappedValue.name)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(tr("pořadí do", "rank up to"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                StepperField(value: league.maxRank, range: 1...4096, step: 10, height: 28, width: 76)
            }
            StepSwitch(on: league.wrappedValue.enabled) { league.enabled.wrappedValue.toggle() }
        }
        .opacity(league.wrappedValue.enabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: league.wrappedValue.enabled)
    }
}
