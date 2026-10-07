import SwiftUI

// The small parts the guide's screens are made of.

/// Grows from small past its size and settles back: a step turning done, a ticked box.
struct SetupPop: ViewModifier {
    let on: Bool
    var duration = 0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 1.0, trigger: count) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.4, duration: 0.001)
                    CubicKeyframe(1.18, duration: duration * 0.6)
                    CubicKeyframe(1, duration: duration * 0.4)
                }
            }
            .onChange(of: on) { _, now in
                if now && !reduceMotion { count += 1 }
            }
    }
}

/// The spinner: a track with one violet quarter going round.
struct SetupSpinner: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle().stroke(SW.track, lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(SW.accent, lineWidth: 2)
                .rotationEffect(.degrees(turn ? 315 : -45))
        }
        .padding(1)
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
        }
    }
}

/// Title and the line under it, the top of every screen.
struct SetupHeading: View {
    let title: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 28, weight: .medium))
                .tracking(-0.56)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(lead)
                .font(.system(size: 14))
                .foregroundStyle(SW.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What IVory is waiting for, or that it's done. It fades in anew whenever its text changes.
struct StatusCard: View {
    enum Kind: Equatable { case waiting, ok, info, manual }
    let kind: Kind
    let text: String
    var detail: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch kind {
                case .waiting: SetupSpinner()
                case .ok: Image(systemName: "checkmark.circle.fill")
                case .info: Image(systemName: "sparkle")
                case .manual: Image(systemName: "hand.point.up.left.fill")
                }
            }
            .font(.system(size: 18))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail).foregroundStyle(SW.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if kind == .waiting {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SW.border, lineWidth: 1)
            }
        }
        .id("\(kind)-\(text)")
        .transition(reduceMotion ? .identity : .asymmetric(
            insertion: .modifier(active: PageIn(y: 10, opacity: 0), identity: PageIn(y: 0, opacity: 1))
                .animation(SW.ease(0.3).delay(0.05)),
            removal: .identity))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch kind {
        case .waiting: return SW.accent
        case .ok: return SW.green
        case .info: return SW.ink
        case .manual: return SW.orange
        }
    }

    private var tint: Color {
        switch kind {
        case .waiting: return SW.surface
        case .ok: return SW.greenTint
        case .info: return SW.tint
        case .manual: return SW.orangeTint
        }
    }
}

/// "I've done it" for the two steps IVory can't check.
struct ConfirmBox: View {
    let label: String
    let isOn: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isOn ? SW.accent : .clear)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(SW.onAccent)
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(SW.muted, lineWidth: 1.5)
                    }
                }
                .frame(width: 17, height: 17)
                .modifier(SetupPop(on: isOn, duration: 0.3))
                Text(label).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SW.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isOn ? SW.tint : (hovering ? SW.hover : SW.surface),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? SW.accent : SW.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? tr("zaškrtnuto", "checked") : tr("nezaškrtnuto", "unchecked"))
    }
}

/// The way through Settings as a list, the last row (what to tap) tinted.
struct PathList: View {
    let items: [String]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let last = i == items.count - 1
                HStack(spacing: 10) {
                    Image(systemName: i == 0 ? "gearshape" : last ? "hand.tap" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(last ? SW.ink : SW.muted)
                        .frame(width: 16)
                    Text(item)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(last ? SW.ink : SW.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(last ? SW.tint : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(4)
        .background(SW.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SW.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Numbered things to do, in order.
struct NumberedSteps: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SW.muted)
                        .frame(width: 20, height: 20)
                        .background(SW.raise, in: Circle())
                    Text(item).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// An icon, a bold line and a muted one under it.
struct SetupPoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(SW.ink).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(text).foregroundStyle(SW.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A column that sits in the middle of the height it's given and scrolls when it doesn't fit.
struct CenteredColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// A step's round mark: green with a tick when done, red with a cross when it failed.
struct StepDot: View {
    enum State { case done, failed }
    let state: State
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(state == .done ? SW.green : SW.red)
            Image(systemName: state == .done ? "checkmark" : "xmark")
                .font(.system(size: size * 0.45, weight: .heavy))
                .foregroundStyle(SW.onAccent)
        }
        .frame(width: size, height: size)
    }
}

/// A thin progress bar.
struct ProgressCapsule: View {
    let value: Double
    var track = SW.track
    var fill = SW.accent

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: g.size.width * min(1, max(0, value)))
                    .animation(.linear(duration: 0.3), value: value)
            }
        }
        .frame(height: 4)
    }
}
