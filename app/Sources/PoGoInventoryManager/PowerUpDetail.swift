import SwiftUI

/// The detail of one power-up, opened from the right over the Power-ups screen: where it goes from and to,
/// what it costs, why it is worth it, and what changes. PvP adds the CP against the league's cap and the
/// whole team; raids add what each boss that is up right now gains.
struct PowerUpDetail: View {
    let pick: PowerUpsScreen.Pick
    let close: () -> Void

    @EnvironmentObject var store: ConfigStore
    @ObservedObject var battle = BattleStore.shared

    static let width: CGFloat = 420

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                art
                    .padding(.bottom, -16)      // the blocks start right under the picture
                VStack(alignment: .leading, spacing: 6) {
                    Text(mon.name)
                        .font(.system(size: 26, weight: .medium))
                        .lineLimit(2)
                    FlowRow(spacing: 6) {
                        ForEach(chips, id: \.0) { label, color in
                            HStack(spacing: 6) {
                                Circle().fill(color).frame(width: 7, height: 7)
                                Text(label).font(.system(size: 12))
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raise))
                        }
                    }
                }

                costCard
                beforeAfter
                extra
                bottomCards
                SearchCopyRow(text: "#\(mon.gameName)")
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    struct Change { let label: String; let before: String; let after: String; let good: Bool }

    struct BossGain { let boss: RaidBoss; let gain: Double; let share: Double; let place: String }
}

/// A heading plus whatever belongs under it, the way the detail stacks its blocks.
struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            content
        }
    }
}
