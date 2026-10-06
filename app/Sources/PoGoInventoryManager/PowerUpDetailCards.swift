import SwiftUI

// The cards of the power-up detail: the picture, the cost, what changes, and the IVs and moves.

extension PowerUpDetail {
    var art: some View {
        ZStack {
            RadialGradient(colors: [glow, Theme.bg], center: UnitPoint(x: 0.5, y: 0.7), startRadius: 0, endRadius: 230)
            MonArtwork(m: mon, size: 180)
        }
        .frame(height: 210)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -22)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Image(systemName: isPvP ? "trophy" : "shield")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentInk)
                Text(isPvP ? tr("PvP tým", "PvP team") : tr("Raid parta", "Raid party"))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .padding(14)
        }
        .padding(.top, 24)      // clears the window's title bar, like every screen
    }

    var costCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("L\(levelText(fromLevel))")
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accentInk)
                Text("L\(levelText(toLevel))")
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.accentInk)
                Spacer(minLength: 8)
                Text(steps)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 1) {
                costCell(tr("Stardust", "Stardust"), number(price.stardust))
                costCell(tr("Candy", "Candy"), number(price.candy))
                costCell(tr("Candy XL", "Candy XL"), price.xl > 0 ? number(price.xl) : "–")
            }
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(why)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1) }
    }

    func costCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.bg)
    }

    var beforeAfter: some View {
        SectionBlock(title: tr("Před a po", "Before and after")) {
            VStack(spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.before)
                            .font(.system(size: 13).monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 16)
                        Text(row.after)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(row.good ? Theme.green : Theme.text)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }

    /// PvP: the cap and the team. Raids: what each boss gains.
    @ViewBuilder
    var extra: some View {
        switch pick {
        case .pvp(let league, let member):
            SectionBlock(title: tr("CP proti limitu ligy", "CP and the league limit")) {
                VStack(alignment: .leading, spacing: 6) {
                    PowerUpCPBar(now: member.mon.cp, after: member.cp, cap: league.cap, height: 10)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
            }
            if let team = teamMembers(league) {
                SectionBlock(title: tr("Tým v \(league.name)", "Team in \(league.name)")) {
                    VStack(spacing: 2) {
                        ForEach(Array(team.enumerated()), id: \.offset) { i, m in
                            let isThis = m.id == member.id
                            HStack(spacing: 10) {
                                MonIcon(m: m.mon, size: 32, circle: true)
                                Text(m.role.title.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 52, alignment: .leading)
                                Text(m.mon.name)
                                    .font(.system(size: 13, weight: isThis ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(m.powerUp ? tr("chce vylepšit", "wants a power-up") : tr("na limitu", "at the cap"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(m.powerUp ? Theme.accentInk : Theme.muted)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 46)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Theme.tint.opacity(isThis ? 1 : 0))
                            }
                        }
                    }
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
                }
            }
        case .raid(let upgrade):
            let perBoss = bossGains(upgrade)
            if !perBoss.isEmpty {
                SectionBlock(title: tr("Zisk u jednotlivých bossů", "Gain per boss")) {
                    VStack(spacing: 0) {
                        ForEach(Array(perBoss.enumerated()), id: \.offset) { i, row in
                            if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            HStack(spacing: 10) {
                                BossThumb(boss: row.boss, size: 28)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(row.boss.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(row.place).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.track)
                                        Capsule().fill(Theme.green).frame(width: geo.size.width * row.share)
                                    }
                                }
                                .frame(width: 90, height: 5)
                                Text("+" + percentText(Int((row.gain * 100).rounded())))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.green)
                                    .frame(width: 48, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
                }
            }
        }
    }

    var bottomCards: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("IV \(percentText(mon.pct))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(Array(zip([tr("Út", "Atk"), tr("Ob", "Def"), "HP"], mon.iv)), id: \.0) { label, v in
                    HStack(spacing: 8) {
                        Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .frame(width: 28, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(Theme.accent).frame(width: geo.size.width * Double(v) / 15)
                            }
                        }
                        .frame(height: 4)
                        Text("\(v)").font(.system(size: 11).monospacedDigit())
                            .frame(width: 22, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }

            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Útoky", "Moves")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(moves, id: \.0) { name, color in
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(name).font(.system(size: 12)).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        }
    }
}
