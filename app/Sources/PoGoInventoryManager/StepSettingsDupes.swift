import SwiftUI

// The duplicates step as it is set up: how many of each species to keep, and the tag the rest get.

extension StepSettings {
    var duplicates: some View {
        VStack(alignment: .leading, spacing: 14) {
            pair {
                LabeledField(label: tr("Tag pro horší duplicity", "Tag for worse duplicates")) {
                    TagNameField(color: $store.config.removeTagColor, name: $store.config.removeTag,
                                 placeholder: "Removable")
                }
            } _: {
                LabeledField(label: tr("Nechat na druh", "Keep per species")) {
                    StepperField(value: $store.config.keepBest, range: 1...10)
                }
            }
            LabeledField(label: tr("Hledání ve hře", "Search in the game")) {
                DesignField {
                    TextField(AppConfig.defaultSearchQuery, text: $store.config.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                }
            }
            StepNote(tr("Bot to napíše do Search v inventáři a duplicity hledá jen mezi tím, co hledání ukáže. & = a zároveň, ! = kromě. Když tag ve hře chybí, vytvoří se v téhle barvě.",
                        "The bot types this into Search in your storage and looks for duplicates only among the results. & = and, ! = not. If the tag is missing in the game, it's created in this color."))
        }
    }
}
