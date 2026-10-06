import SwiftUI

/// "Now reading": the Pokémon the bot has this moment read out of the appraisal, and the few before it.
/// Everything here comes from the bot's `scan` events (core/ivory/scan.py live_mon), so it is as current
/// as the run itself – a new Pokémon lands roughly every three seconds.
struct NowReadingPanel: View {
    @EnvironmentObject private var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NowReadingCard(mon: runner.current, scanned: runner.scanned)
            if !runner.justRead.isEmpty {
                JustReadStrip(mons: runner.justRead)
            }
        }
    }
}

// MARK: - The card

private struct NowReadingCard: View {
    let mon: Runner.LiveMon?
    let scanned: (done: Int, total: Int)?

    @EnvironmentObject private var store: ConfigStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let viewportHeight: CGFloat = 258
    /// The square the Pokémon sits in, between the corner brackets.
    private static let frameTop: CGFloat = 40
    private static let frameHeight: CGFloat = 178

    var body: some View {
        VStack(spacing: 0) {
            viewport
            details
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
        .shadow(color: Theme.accent.opacity(0.14), radius: 20, y: 10)
    }

    // The dark "viewfinder" the Pokémon appears in.
    private var viewport: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                RadialGradient(colors: [.oklch(0.33, 0.09, 282), .oklch(0.15, 0.022, 278)],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: geo.size.width * 0.8)
            }

            PokeImage(dex: mon?.dex, sid: mon?.sid, kind: .artwork, size: 170, pops: true)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 12)
                .padding(.top, 44)
                .id(mon?.seq ?? -1)                      // a new Pokémon pops in rather than cross-fading
                .transition(.opacity)

            brackets
            ScanLine(height: Self.frameHeight - 8)
                .padding(.horizontal, 44)
                .padding(.top, 44)

            liveRow
            chips
        }
        .frame(height: Self.viewportHeight)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: mon?.seq)
    }

    private var liveRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.green)
                .frame(width: 7, height: 7)
                .shadow(color: Theme.green, radius: 4)
            Text(tr("ŽIVĚ · PRÁVĚ ČTU", "LIVE · NOW READING"))
                .font(.system(size: 11, weight: .semibold)).kerning(0.6)
            Spacer(minLength: 4)
            if let scanned {
                Text("\(scanned.done) / \(scanned.total)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.oklch(0.78, 0.02, 280))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(Theme.white)
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    /// The four corners of the viewfinder.
    private var brackets: some View {
        let teal = Theme.teal
        return ZStack {
            ForEach(Array(Bracket.allCases.enumerated()), id: \.offset) { _, corner in
                corner.shape
                    .stroke(teal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: corner.alignment)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, Self.frameTop)
        .padding(.bottom, Self.viewportHeight - Self.frameTop - Self.frameHeight)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let mon {
                chip("CP \(mon.cp)", mono: true)
                if let level = mon.level {
                    chip("L" + (level == level.rounded() ? "\(Int(level))" : String(format: "%.1f", level)))
                }
                if let iv = mon.iv {
                    chip(iv.map(String.init).joined(separator: " / "), mono: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func chip(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 11, weight: .medium).monospacedDigit() : .system(size: 11, weight: .medium))
            .foregroundStyle(Theme.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.35)))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
    }

    // Name, IV bars and the tag the Pokémon is going to get.
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mon?.name ?? "—")
                    .font(.system(size: 20, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let pct = mon?.pct {
                    Text("\(pct)%")
                        .font(.system(size: 24, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                }
            }

            VStack(spacing: 6) {
                ForEach(Array(zip([tr("Útok", "Attack"), tr("Obrana", "Defense"), "HP"], 0..<3)), id: \.1) { label, i in
                    IVBar(label: label, value: mon?.iv?[safe: i])
                }
            }

            tagRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: mon?.seq)
    }

    @ViewBuilder
    private var tagRow: some View {
        if let tag = mon?.tag, !tag.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentInk)
                Text(tr("Dostane tag", "Gets the tag"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Circle().fill(tagColor(tag)).frame(width: 8, height: 8)
                    Text(tag)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accentInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.tint))
            .transition(.opacity)
            .pops(0.4)                 // the tag lands a beat after the Pokémon itself
            .id(mon?.seq ?? -1)
        }
    }

    /// The tag's color in the game, as the user set it up.
    private func tagColor(_ name: String) -> Color {
        store.config.ivTags.first { $0.name == name }?.color.swatch ?? Theme.accent
    }
}

// MARK: - Pieces

/// One of Attack / Defense / HP: the bar fills to the IV out of 15.
private struct IVBar: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.lightTeal, Theme.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(value ?? 0) / 15)
                }
            }
            .frame(height: 5)
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: value)
            Text(value.map { "\($0)/15" } ?? "–")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// The line that sweeps the viewfinder while the bot works. Purely decoration – it says "something is
/// happening", nothing more, so it stands still when the system asks for less motion.
private struct ScanLine: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var down = false

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, Theme.teal, .clear], startPoint: .leading, endPoint: .trailing))
            .frame(height: 2)
            .shadow(color: Theme.teal, radius: 7)
            .offset(y: down ? height : 0)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(height: height)
            .opacity(reduceMotion ? 0 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { down = true }
            }
    }
}

/// The handful of Pokémon read just before this one – it makes the run feel like it is moving.
private struct JustReadStrip: View {
    let mons: [Runner.LiveMon]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Právě přečteno", "Just read"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(mons.prefix(4)) { mon in
                    VStack(spacing: 4) {
                        PokeImage(dex: mon.dex, sid: mon.sid, kind: .icon, size: 44)
                        HStack(spacing: 5) {
                            Circle().fill(dotColor(mon.pct)).frame(width: 7, height: 7)
                            Text(mon.pct.map { "\($0)%" } ?? "–")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mons.first?.seq)
        }
    }

    /// The same reading as the IV tags: the better the Pokémon, the warmer the dot.
    private func dotColor(_ pct: Int?) -> Color {
        switch pct ?? 0 {
        case 100...: return Theme.gold
        case 90...: return Theme.green
        case 80...: return Theme.blue
        case 70...: return Theme.muted
        default: return Theme.track
        }
    }
}

// MARK: -

private enum Bracket: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// An L drawn into the corner, rounded where the two arms meet.
    var shape: Path {
        let s: CGFloat = 18, r: CGFloat = 4
        var p = Path()
        switch self {
        case .topLeading:
            p.move(to: CGPoint(x: s, y: 0))
            p.addLine(to: CGPoint(x: r, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0, y: r), control: .zero)
            p.addLine(to: CGPoint(x: 0, y: s))
        case .topTrailing:
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: s - r, y: 0))
            p.addQuadCurve(to: CGPoint(x: s, y: r), control: CGPoint(x: s, y: 0))
            p.addLine(to: CGPoint(x: s, y: s))
        case .bottomLeading:
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: s - r))
            p.addQuadCurve(to: CGPoint(x: r, y: s), control: CGPoint(x: 0, y: s))
            p.addLine(to: CGPoint(x: s, y: s))
        case .bottomTrailing:
            p.move(to: CGPoint(x: s, y: 0))
            p.addLine(to: CGPoint(x: s, y: s - r))
            p.addQuadCurve(to: CGPoint(x: s - r, y: s), control: CGPoint(x: s, y: s))
            p.addLine(to: CGPoint(x: 0, y: s))
        }
        return p
    }
}
