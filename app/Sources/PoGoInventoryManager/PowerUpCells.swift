import SwiftUI

// The cells the Power-ups screen is made of: one candidate per row, its CP bar and the boss it is for.

struct PvPUpgradeCell: View {
    let league: PvPLeague
    let member: PvPMember
    let color: Color
    @ObservedObject private var battle = BattleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MonIcon(m: member.mon, size: 44, circle: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.mon.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text("\(league.name) · L\(levelText(member.mon.level)) → L\(levelText(member.level))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(number(battle.price(member).stardust))
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                    Text(tr("stardustu", "stardust")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            PowerUpCPBar(now: member.mon.cp, after: member.cp, cap: league.cap)
                .padding(.leading, 50)
                .padding(.trailing, 19)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(minHeight: PowerUpRow.height, alignment: .top)
    }
}

/// One height for every row in both lists – otherwise the two columns end at different places and the
/// bottom of the screen looks like a step.
enum PowerUpRow {
    static let height: CGFloat = 104
}

struct RaidUpgradeCell: View {
    let u: RaidUpgrade
    let bosses: [RaidBoss]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MonIcon(m: u.counter.mon, size: 44, circle: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.counter.mon.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("L\(levelText(u.counter.mon.level)) → L40")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                    Text("+" + percentText(Int((u.gain * 100).rounded())))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.green)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Theme.greenTint))
                VStack(alignment: .trailing, spacing: 0) {
                    Text(number(u.price.stardust))
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                    Text(tr("stardustu", "stardust")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .frame(width: 70, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            // the row of bosses keeps its space even when there are none, so the rows stay level
            HStack(spacing: 10) {
                Text(tr("Pomůže proti", "Helps against"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(bosses) { boss in
                    HStack(spacing: 5) {
                        BossThumb(boss: boss, size: 20)
                        Text(boss.name).font(.system(size: 12)).lineLimit(1)
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.raise))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 50)
            .frame(height: 24)
            .opacity(bosses.isEmpty ? 0 : 1)
            .accessibilityHidden(bosses.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(minHeight: PowerUpRow.height, alignment: .top)
    }
}

/// CP now, what the power-up adds, and the league's cap as the line at the end.
struct PowerUpCPBar: View {
    let now: Int
    let after: Int
    let cap: Int?
    var height: CGFloat = 6
    /// The rows write one short line ("1,488 → 1,499 of 1,500 CP"); the recommendation splits it in two.
    var split = false

    var body: some View {
        let top = Double(cap ?? max(after, 1))
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let nowWidth = geo.size.width * min(1, Double(now) / top)
                let addedWidth = max(0, geo.size.width * min(1, Double(after) / top) - nowWidth)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.text.opacity(0.3)).frame(width: nowWidth)
                    Rectangle().fill(Theme.accent).frame(width: addedWidth).offset(x: nowWidth)
                    if cap != nil {
                        Rectangle().fill(Theme.text).frame(width: 2)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.35), value: after)
            if split {
                HStack(spacing: 8) {
                    Text(tr("\(number(now)) CP teď", "\(number(now)) CP now"))
                    Spacer(minLength: 4)
                    Text(tail)
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            } else {
                Text(line)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    private var tail: String {
        guard let cap else { return tr("\(number(after)) po vylepšení", "\(number(after)) after") }
        return tr("\(number(after)) po · limit \(number(cap))", "\(number(after)) after · limit \(number(cap))")
    }

    private var line: String {
        guard let cap else {
            return tr("\(number(now)) → \(number(after)) CP", "\(number(now)) → \(number(after)) CP")
        }
        return tr("\(number(now)) → \(number(after)) z \(number(cap)) CP",
                  "\(number(now)) → \(number(after)) of \(number(cap)) CP")
    }
}

/// A raid boss's picture from LeekDuck, the same one the Raids screen uses.
struct BossThumb: View {
    let boss: RaidBoss
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Circle().fill(Theme.track)
            }
        }
        .frame(width: size, height: size)
        .task(id: boss.id) {
            guard let url = boss.image else { return }
            if let have = BossImages.cached(url) {
                image = have
            } else {
                image = await BossImages.load(url)
            }
        }
    }
}

/// "44" / "44.5" – a level the way the game writes it.
func levelText(_ level: Double?) -> String {
    guard let level else { return "?" }
    return level.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(level))" : String(format: "%.1f", level)
}

final class PowerUpSelection: ObservableObject {
    static let shared = PowerUpSelection()
    @Published private(set) var pick: PowerUpsScreen.Pick?

    func open(_ pick: PowerUpsScreen.Pick) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            self.pick = isOpen(pick) ? nil : pick
        }
    }

    func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { pick = nil }
    }

    func isOpen(_ other: PowerUpsScreen.Pick) -> Bool {
        guard let pick else { return false }
        return pick.key == other.key
    }
}

/// The detail over the Power-ups page: the scrim and the panel from the right.
struct PowerUpDetailHost: View {
    let active: Bool
    @ObservedObject private var selection = PowerUpSelection.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            if active, let pick = selection.pick {
                Color.oklch(0.1, 0.02, 278).opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.close() }
                    .transition(.opacity)
                PowerUpDetail(pick: pick) { selection.close() }
                    .transition(.move(edge: .trailing))
            }
        }
    }
}

/// A row of the lists that opens its detail.
struct RowButton<Content: View>: View {
    let open: () -> Void
    let selected: Bool
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Theme.tint : Theme.hover.opacity(hovered ? 1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A whole card that is a button: it lifts a little on hover instead of looking like a control.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .shadow(color: Theme.accent.opacity(hovered ? 0.18 : 0), radius: 15, y: 6)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.15), value: hovered)
        }
    }
}
