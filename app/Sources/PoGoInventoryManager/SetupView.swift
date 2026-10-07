import AppKit
import SwiftUI

/// The setup guide, over the whole window like the risk notice.
struct SetupOverlay: View {
    @ObservedObject private var flow = SetupFlow.shared

    var body: some View {
        SetupGuide(flow: flow, prep: flow.prep, signIn: flow.signIn, install: flow.install)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SW.bg)
        .ignoresSafeArea()
        .foregroundStyle(SW.text)
        .font(.system(size: 13))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - the frame every screen sits in

/// How a step looks in the sidebar.
enum RailMark: Equatable { case todo, now, done }

/// Where the user has to look, top right.
enum SetupCue: Equatable { case phone, code, mac }

/// The sidebar with the seven steps, the bar on top saying which step and where to look, the screen,
/// and the buttons at the bottom.
struct SetupShell<Content: View>: View {
    let marks: [SetupStep: RailMark]
    /// The row with the violet background: the step in front.
    let highlight: SetupStep?
    let railSub: String
    let stepLabel: String
    let cue: SetupCue
    let footer: SetupFooterBar
    /// Which sidebar rows can be clicked, and what a click does.
    let canVisit: (SetupStep) -> Bool
    let visit: (SetupStep) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(marks: marks, highlight: highlight, sub: railSub, canVisit: canVisit, visit: visit)
            VStack(spacing: 0) {
                // the window's title bar stays opaque over the top: the bar starts under it
                Color.clear.frame(height: SW.titleBar)
                HStack(spacing: 12) {
                    Text(stepLabel)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(SW.muted)
                    Spacer(minLength: 0)
                    CuePill(cue: cue)
                }
                .padding(.horizontal, 28)
                .frame(height: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(SW.border).frame(height: 1) }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The steps in their three phases. Done ones are green and pop when they turn so, the one in front is
/// ringed and tinted.
private struct SetupSidebar: View {
    let marks: [SetupStep: RailMark]
    let highlight: SetupStep?
    let sub: String
    let canVisit: (SetupStep) -> Bool
    let visit: (SetupStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIconView()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("Nastavení IVory", "IVory setup")).font(.system(size: 15, weight: .medium))
                    Text(sub).font(.system(size: 11)).foregroundStyle(SW.muted)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, SW.titleBar + 24)
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(SetupPhase.allCases) { phase in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phase.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SW.muted)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        ForEach(SetupStep.allCases.filter { $0.phase == phase }) { step in
                            RailRow(step: step, mark: marks[step] ?? .todo, highlighted: step == highlight,
                                    visit: canVisit(step) ? { visit(step) } : nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                legend("laptopcomputer", tr("Na tomto Macu", "On this Mac"))
                legend("iphone", tr("Na iPhonu", "On your iPhone"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(width: Sidebar.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SW.chrome)
        .overlay(alignment: .trailing) { Rectangle().fill(SW.border).frame(width: 1) }
    }

    private func legend(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 14)
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(SW.muted)
    }
}

private struct RailRow: View {
    let step: SetupStep
    let mark: RailMark
    let highlighted: Bool
    let visit: (() -> Void)?

    var body: some View {
        let lit = mark != .todo
        HStack(spacing: 10) {
            ZStack {
                switch mark {
                case .done:
                    Circle().fill(SW.green)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(SW.onAccent)
                case .now:
                    Circle().strokeBorder(SW.accent, lineWidth: 1.5)
                case .todo:
                    Circle().strokeBorder(SW.track, lineWidth: 1.5)
                }
            }
            .frame(width: 18, height: 18)
            .modifier(SetupPop(on: mark == .done, duration: 0.42))
            Text(step.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(lit ? SW.text : SW.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: step.onPhone ? "iphone" : "laptopcomputer")
                .font(.system(size: 13))
                .frame(width: 16)
                .foregroundStyle(mark == .now ? SW.ink : SW.muted)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(highlighted ? SW.tint : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { visit?() }
        .animation(.easeOut(duration: 0.3), value: mark)
        .animation(.easeOut(duration: 0.3), value: highlighted)
        .accessibilityElement(children: .combine)
        .accessibilityValue(mark == .done ? tr("hotovo", "done") : "")
        .accessibilityAddTraits(visit == nil ? [] : .isButton)
    }
}

/// "Look at your iPhone", "The code is on your iPhone" or "On this Mac".
private struct CuePill: View {
    let cue: SetupCue

    var body: some View {
        let phone = cue != .mac
        HStack(spacing: 8) {
            Image(systemName: phone ? "iphone" : "laptopcomputer").font(.system(size: 13, weight: .semibold))
            Text(cue == .phone ? tr("Podívej se na iPhone", "Look at your iPhone")
                 : cue == .code ? tr("Kód je na iPhonu", "Code is on your iPhone")
                 : tr("Na tomto Macu", "On this Mac"))
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(phone ? SW.ink : SW.text)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(phone ? SW.tint : SW.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(phone ? SW.accent : SW.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: cue)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - the buttons at the bottom

struct SetupFooterBar: View {
    struct Action {
        let title: String
        var symbol: String? = nil
        var enabled = true
        let run: () -> Void
    }

    var back: (() -> Void)? = nil
    var secondary: Action? = nil
    let primary: Action

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left").font(.system(size: 12))
                        Text(tr("Zpět", "Back"))
                    }
                }
                .buttonStyle(SetupButton(kind: .back))
            }
            Spacer(minLength: 0)
            if let secondary {
                Button(secondary.title, action: secondary.run)
                    .buttonStyle(SetupButton(kind: .secondary))
                    .disabled(!secondary.enabled)
            }
            Button(action: primary.run) {
                HStack(spacing: 6) {
                    Text(primary.title)
                    Image(systemName: primary.symbol ?? "arrow.right").font(.system(size: 11, weight: .bold))
                }
            }
            .buttonStyle(SetupButton(kind: .primary))
            .disabled(!primary.enabled)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .frame(height: 60)
        .overlay(alignment: .top) { Rectangle().fill(SW.border).frame(height: 1) }
        .animation(.easeOut(duration: 0.2), value: primary.enabled)
    }
}

/// The guide's buttons: an outlined violet one that moves on, a plain one beside it and a quiet Back.
struct SetupButton: ButtonStyle {
    enum Kind { case primary, secondary, back }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind)
    }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let hot = hovering && isEnabled
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(color(hot))
                .padding(.horizontal, kind == .primary ? 16 : kind == .secondary ? 14 : 12)
                .frame(height: 34)
                .background(background(hot), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if kind == .primary {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SW.accent, lineWidth: 1)
                    }
                }
                .opacity(kind == .primary && !isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hot)
        }

        private func color(_ hot: Bool) -> Color {
            switch kind {
            case .primary: return SW.ink
            case .secondary: return SW.text
            case .back: return hot ? SW.text : SW.muted
            }
        }

        private func background(_ hot: Bool) -> Color {
            switch kind {
            case .primary: return hot ? SW.tint : .clear
            case .secondary, .back: return hot ? SW.hover : .clear
            }
        }
    }
}
