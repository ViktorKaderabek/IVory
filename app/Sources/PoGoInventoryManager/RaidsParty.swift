import AppKit
import SwiftUI

// What the Raids screen says about a fight: the chance of winning it and the party it suggests.

struct BossTile: View {
    let boss: RaidBoss
    let selected: Bool
    let pick: () -> Void
    @State private var image: NSImage?
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Circle().fill(Theme.track)
                    }
                }
                .frame(width: 56, height: 56)
                Text(boss.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 3) {
                    ForEach(boss.types, id: \.self) { t in
                        Circle().fill(BattleType.color(t)).frame(width: 7, height: 7)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(width: 112)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.tint : (hovered ? Theme.hover : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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

/// How likely a party of N is to win, as a big number with the player count above it.
struct WinChance: View {
    let chances: [Int]?
    @Binding var players: Int?
    let shadow: Bool

    private var pick: Int {
        if let players { return players }
        // the smallest party that still wins comfortably, otherwise the biggest
        guard let chances, chances.count == 6 else { return 3 }
        return (chances.firstIndex { $0 >= 90 }.map { $0 + 1 }) ?? 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let chances, chances.count == 6 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Hráčů", "Players")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    HStack(spacing: 4) {
                        ForEach(1...6, id: \.self) { n in
                            Button { players = n } label: {
                                VStack(spacing: 4) {
                                    Text("\(n)").font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(n == pick ? Theme.accentInk : Theme.text)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(barColor(chances[n - 1]))
                                        .frame(width: 18, height: 3)
                                }
                                .padding(.top, 8).padding(.bottom, 6)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(n == pick ? Theme.tint : Theme.bg))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(n == pick ? Theme.accent : Theme.border, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .animation(.easeOut(duration: 0.15), value: pick)
                        }
                    }
                }
                Text("\(chances[pick - 1])%")
                    .font(.system(size: 64, weight: .medium).monospacedDigit())
                    .foregroundStyle(color(chances[pick - 1]))
                    .contentTransition(.numericText())
                    .pops()
                    .id(chances[pick - 1])
                Text(sentence(chances))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(tr("Pro tuhle úroveň raidu IVory nezná čísla bossů.",
                        "IVory doesn't have the boss numbers for this raid tier."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text(tr("Odhad z veřejných dat, ne simulace souboje", "An estimate from public data, not a battle simulation"))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }

    private func sentence(_ chances: [Int]) -> String {
        let safe = chances.firstIndex { $0 >= 90 }.map { $0 + 1 }
        let head = tr("Když půjdete \(pick) s podobnou partou.", "If \(pick) of you go, each with a similar party.")
        guard let safe else {
            return head + tr(" Ani v šesti to na 90 % nevychází.", " Even six of you don't reach 90%.")
        }
        if safe <= pick { return head }
        return head + tr(" Na 90 % je potřeba \(safe) hráčů.", " It takes \(safe) players for 90%.")
    }

    /// The big number: a win is likely, a coin toss, or unlikely.
    private func color(_ pct: Int) -> Color {
        pct >= 75 ? Theme.green : pct >= 40 ? Theme.text : Theme.red
    }

    /// The little bar under a player count.
    private func barColor(_ pct: Int) -> Color {
        pct >= 90 ? Theme.green : pct >= 40 ? Theme.accent : Theme.red
    }
}

/// One of the six, as a card. The first is the best pick.
struct PartyCard: View {
    let c: RaidCounter
    let rank: Int
    let share: Double

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                (rank == 1 ? Theme.tint : Theme.raise.opacity(0.5))
                MonArtwork(m: c.mon, size: 96)
            }
            .frame(height: 112)
            .overlay(alignment: .topLeading) {
                Text(rank == 1 ? tr("Nejlepší", "Best pick") : "#\(rank)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(rank == 1 ? Theme.onAccent : Theme.muted)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rank == 1 ? Theme.accent : Theme.surface))
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.formName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(BattleFormat.meta(c.mon))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Text("\(c.fast.name) · \(c.charged.name)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(Theme.accent).frame(width: geo.size.width * max(0, min(1, share)))
                        }
                    }
                    .frame(height: 4)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                // the chip is only on some of them, but its room is kept on all – otherwise the cards
                // end at different heights and the grid looks like a staircase
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                    Text(tr("Vylepšit na L40", "Power up to L40")).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.tint))
                .opacity(c.powerUp ? 1 : 0)
                .accessibilityHidden(!c.powerUp)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(rank == 1 ? Theme.accent : Theme.border, lineWidth: rank == 1 ? 1.5 : 1))
    }
}
