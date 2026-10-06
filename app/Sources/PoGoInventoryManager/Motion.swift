import AppKit
import QuartzCore
import SwiftUI

// Small reusable motion: a ticking clock for animated views, entrances, a pop, a shimmer and a pulse ring.

struct Ticking: ViewModifier {
    let seconds: Double
    let active: Bool
    let tick: (Date) -> Void

    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active else { return }
            let step = UInt64(seconds * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: step)
                guard !Task.isCancelled else { return }
                tick(Date())
            }
        }
    }
}

/// Fades a view in and lifts it a little as it arrives. One shot, on appear – with a delay it staggers a
/// list so it builds up instead of snapping into place.
struct Entrance: ViewModifier {
    let delay: Double
    let rise: CGFloat
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(.design(duration, delay: delay)) { shown = true }
            }
    }
}

/// The same, but it pops in from slightly too small (the design's `ivPop`).
struct Pop: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.82)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62).delay(delay)) { shown = true }
            }
    }
}

/// The highlight that travels along the active progress bar.
struct Shimmer: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    @ViewBuilder
    func body(content: Content) -> some View {
        // off: not even a clip, so the other five bars cost nothing
        if on && !reduceMotion {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.65), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.4)
                            .offset(x: phase * geo.size.width)
                    }
                    .allowsHitTesting(false)
                    .onAppear {
                        phase = -0.4
                        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1.4 }
                    }
                }
                .clipped()
        } else {
            content
        }
    }
}

/// The ring that keeps expanding out of the step the bot is on.
struct PulseRing: View {
    var color: Color = Theme.accent
    var cornerRadius: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var out = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius + (out ? 16 : 0), style: .continuous)
            .strokeBorder(color.opacity(out ? 0 : 0.6), lineWidth: out ? 1 : 3)
            .padding(out ? -16 : 0)
            .opacity(reduceMotion ? 0 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { out = true }
            }
            .allowsHitTesting(false)
    }
}
