import SwiftUI

// One step of a run as a row: its name, what it will do, and the switch that turns it off.

/// A step of the pipeline: the tile with its icon on the rail, and the card with what it does.
struct StepRow: View, Equatable {
    /// What the row draws. Everything is a value, so SwiftUI rebuilds a row only when its own line changed.
    struct Model: Equatable {
        let step: Runner.Step
        let isLast: Bool
        let expanded: Bool
        let on: Bool
        let ready: Bool
        let running: Bool
        let finished: Bool
        let subtitle: String
    }

    let model: Model
    let toggleExpand: () -> Void
    let toggle: () -> Void

    @State private var hovered = false

    static func == (lhs: StepRow, rhs: StepRow) -> Bool { lhs.model == rhs.model }

    private var step: Runner.Step { model.step }
    private var isLast: Bool { model.isLast }
    private var expanded: Bool { model.expanded }
    private var on: Bool { model.on }
    private var ready: Bool { model.ready }
    private var running: Bool { model.running }
    private var finished: Bool { model.finished }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            rail
            card
        }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            tile
                .padding(.top, 10)
            if !isLast {
                RoundedRectangle(cornerRadius: 1)
                    .fill(finished ? Theme.green : Theme.track)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 8)
                    .animation(.easeOut(duration: 0.3), value: finished)
            }
        }
        .frame(width: 44)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(tileFill)
            .frame(width: 44, height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(tileRing, lineWidth: 1)
            }
            .overlay {
                Image(systemName: step.symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(tileIcon)
            }
            // the step under way gets the halo from the design, and keeps sending out a ring
            .background {
                if running {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Theme.accent.opacity(0.22))
                        .padding(-4)
                        .shadow(color: Theme.accent.opacity(0.4), radius: 13, y: 10)
                }
            }
            .overlay { if running { PulseRing() } }
            .overlay(alignment: .bottomTrailing) {
                if finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.green))
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                        .offset(x: 5, y: 5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: finished)
            .animation(.easeOut(duration: 0.25), value: running)
            .animation(.easeOut(duration: 0.2), value: on)
    }

    private var tileFill: AnyShapeStyle {
        if running {
            return AnyShapeStyle(LinearGradient(stops: [
                .init(color: Theme.lightTeal, location: 0),
                .init(color: Theme.lightBlue, location: 0.55),
                .init(color: Theme.violet, location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if finished { return AnyShapeStyle(Theme.greenTint) }
        if on {
            return AnyShapeStyle(LinearGradient(colors: [Theme.tint, Theme.tint.opacity(0.35)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(Theme.raise)
    }

    private var tileIcon: Color {
        if running { return Color.oklch(0.98, 0.004, 280) }
        if finished { return Theme.green }
        return on ? Theme.accentInk : Theme.muted
    }

    private var tileRing: Color {
        if running { return .clear }
        if on && !finished { return Theme.accent.opacity(0.35) }
        return Theme.border
    }

    private var card: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpand) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%02d", step.rawValue))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                            Text(step.title)
                                .font(.system(size: 14, weight: .medium))
                        }
                        Text(model.subtitle)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(on ? 1 : 0.45)
                    if ready {
                        StepSwitch(on: on, flip: toggle)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(.easeOut(duration: 0.15), value: expanded)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.hover.opacity(hovered ? 1 : 0))
            // the hover lives on the header alone: on the whole card every move of the mouse would
            // invalidate the open settings panel underneath as well
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)

            if expanded {
                StepSettings(step: step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg.opacity(0.3))
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    .transition(.reveal)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            // 2 points, not 1.5: a half-point line falls between device pixels, so the straight edges came
            // out fainter than the corners, where two of them overlap
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(expanded || running ? Theme.accent : Theme.border,
                              lineWidth: expanded || running ? 2 : 1)
        }
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.2), value: expanded)
    }

    private var subtitleColor: Color {
        if running { return Theme.accentInk }
        if finished { return Theme.green }
        return Theme.muted
    }
}

/// The on/off switch of a step, drawn as in the design rather than as the system one.
struct StepSwitch: View {
    let on: Bool
    var width: CGFloat = 32
    var height: CGFloat = 19
    let flip: () -> Void

    private var knob: CGFloat { height - 4 }

    var body: some View {
        Button(action: flip) {
            Capsule()
                .fill(on ? Theme.accent : Theme.track)
                .frame(width: width, height: height)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(Color.oklch(0.98, 0.004, 280))
                        .frame(width: knob, height: knob)
                        .padding(.horizontal, 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: on)
        .help(tr("Zapnout nebo vypnout krok", "Turn the step on or off"))
    }
}
