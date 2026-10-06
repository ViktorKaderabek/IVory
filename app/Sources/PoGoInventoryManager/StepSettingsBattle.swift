import SwiftUI

// The Battle tags as they are set up: the raid attackers and the PvP teams the app picks.

extension StepSettings {
    var battleTags: some View {
        VStack(alignment: .leading, spacing: 14) {
            pair {
                LabeledField(label: tr("Tag pro raid útočníky", "Tag for raid attackers")) {
                    TagNameField(color: $store.config.battle.raid.color, name: $store.config.battle.raid.name,
                                 placeholder: "Raid")
                }
            } _: {
                LabeledField(label: tr("Útočníků na typ", "Attackers per type")) {
                    StepperField(value: $store.config.battle.raid.perType, range: 1...12)
                }
            }
            pair {
                LabeledField(label: tr("Tagy PvP týmů", "PvP team tags")) {
                    VStack(spacing: 6) {
                        teamRow(.great, $store.config.battle.great)
                        teamRow(.ultra, $store.config.battle.ultra)
                        teamRow(.master, $store.config.battle.master)
                    }
                }
            } _: {
                VStack(alignment: .leading, spacing: 10) {
                    SwitchRow(title: tr("Tagovat raid útočníky", "Tag raid attackers"),
                              isOn: $store.config.battle.raid.enabled)
                    SwitchRow(title: tr("Upozornit na nové raid bosse", "Notify me about new raid bosses"),
                              detail: tr("Když přijde boss, na kterého máš silnou partu. Jen když je IVory otevřená.",
                                         "When a boss arrives that you have a strong party for. Only while IVory is open."),
                              isOn: $store.config.battle.notifyBosses)
                        .onChange(of: store.config.battle.notifyBosses) { _, on in if on { BossAlerts.requestPermission() } }
                }
            }
            StepNote(tr("Tagy PvP týmů berou týmy vybrané na obrazovce PvP týmy. Ve hře je pak najdeš hledáním, třeba #\(store.config.battle.raid.name)&@steel. Kusům, které už vybrané nejsou, tag sundá.",
                        "The PvP team tags come from the teams picked on PvP teams. In the game you then find them by searching, e.g. #\(store.config.battle.raid.name)&@steel. It takes the tag off Pokémon that are no longer picked."))
        }
    }

    func teamRow(_ league: PvPLeague, _ tag: Binding<BattleConfig.TeamTag>) -> some View {
        HStack(spacing: 8) {
            TagNameField(color: tag.color, name: tag.name, placeholder: league.name)
            StepSwitch(on: tag.wrappedValue.enabled) { tag.enabled.wrappedValue.toggle() }
        }
        .opacity(tag.wrappedValue.enabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: tag.wrappedValue.enabled)
    }
}
