import AppKit
import SwiftUI

/// Colors from the design (the Nocturne design system). The window follows the macOS light/dark mode;
/// the hero card and the console are always dark.
enum Theme {
    static let appName = "IVory"

    // MARK: Window (--w-* tokens from the design)

    static let bg = Color.adaptive(dark: .oklch(0.175, 0.026, 278), light: .oklch(0.946, 0.008, 280))
    static let chrome = Color.adaptive(dark: .oklch(0.19, 0.027, 278), light: .oklch(0.928, 0.009, 280))
    static let surface = Color.adaptive(dark: .oklch(0.205, 0.028, 278), light: .oklch(0.975, 0.006, 280))
    static let raise = Color.adaptive(dark: .oklch(0.24, 0.027, 280), light: .oklch(0.93, 0.009, 280))
    static let input = Color.adaptive(dark: .oklch(0.183, 0.027, 278), light: .oklch(0.96, 0.02, 290))
    static let text = Color.adaptive(dark: .oklch(0.96, 0.008, 280), light: .oklch(0.16, 0.025, 278))
    static let muted = Color.adaptive(dark: .oklch(0.60, 0.02, 280), light: .oklch(0.38, 0.024, 280))
    static let border = Color.adaptive(dark: NSColor.white.withAlphaComponent(0.09),
                                       light: NSColor.oklch(0.16, 0.025, 278).withAlphaComponent(0.13))
    static let track = Color.adaptive(dark: .oklch(0.29, 0.026, 280), light: .oklch(0.82, 0.014, 280))
    static let accent = Color.adaptive(dark: .oklch(0.70, 0.16, 290), light: .oklch(0.58, 0.19, 290))
    static let accentInk = Color.adaptive(dark: .oklch(0.82, 0.10, 290), light: .oklch(0.50, 0.19, 290))
    static let onAccent = Color.adaptive(dark: .oklch(0.16, 0.025, 278), light: .oklch(0.975, 0.006, 280))
    static let tint = Color.adaptive(dark: .oklch(0.30, 0.09, 290), light: .oklch(0.89, 0.06, 290))

    static let green = Color.adaptive(dark: .oklch(0.8, 0.15, 152), light: .oklch(0.52, 0.13, 152))
    static let greenTint = Color.adaptive(dark: .oklch(0.32, 0.06, 152), light: .oklch(0.93, 0.04, 152))
    static let orange = Color.adaptive(dark: .oklch(0.8, 0.13, 65), light: .oklch(0.58, 0.14, 55))
    static let orangeTint = Color.adaptive(dark: .oklch(0.33, 0.06, 65), light: .oklch(0.94, 0.04, 65))
    static let red = Color.adaptive(dark: .oklch(0.74, 0.16, 22), light: .oklch(0.55, 0.18, 22))
    static let redTint = Color.adaptive(dark: .oklch(0.32, 0.08, 22), light: .oklch(0.93, 0.04, 22))
    static let teal = Color.adaptive(dark: .oklch(0.8, 0.11, 190), light: .oklch(0.52, 0.09, 195))
    static let tealTint = Color.adaptive(dark: .oklch(0.32, 0.05, 190), light: .oklch(0.93, 0.03, 195))
    static let blue = Color.adaptive(dark: .oklch(0.78, 0.11, 255), light: .oklch(0.52, 0.13, 260))
    static let blueTint = Color.adaptive(dark: .oklch(0.32, 0.06, 255), light: .oklch(0.93, 0.03, 260))
    static let pink = Color.adaptive(dark: .oklch(0.78, 0.13, 350), light: .oklch(0.55, 0.15, 350))
    static let pinkTint = Color.adaptive(dark: .oklch(0.32, 0.07, 350), light: .oklch(0.93, 0.04, 350))
    static let yellow = Color.adaptive(dark: .oklch(0.88, 0.12, 92), light: .oklch(0.45, 0.1, 80))
    static let yellowTint = Color.adaptive(dark: .oklch(0.34, 0.07, 90), light: .oklch(0.93, 0.07, 92))

    // MARK: Fixed colors (the same in both modes)

    static let nightBg = Color.oklch(0.16, 0.025, 278)
    static let nightSection = Color.oklch(0.29, 0.07, 282)
    static let ivory = Color.oklch(0.95, 0.03, 90)
    static let white = Color.oklch(0.975, 0.006, 280)
    static let neutral200 = Color.oklch(0.91, 0.01, 280)
    static let neutral300 = Color.oklch(0.82, 0.014, 280)
    static let neutral600 = Color.oklch(0.48, 0.022, 280)
    static let lightTeal = Color.oklch(0.72, 0.13, 195)
    static let lightBlue = Color.oklch(0.62, 0.17, 262)
    static let violet = Color.oklch(0.70, 0.16, 290)
    static let violet200 = Color.oklch(0.89, 0.06, 290)
    static let violet600 = Color.oklch(0.58, 0.19, 290)
    static let violet700 = Color.oklch(0.50, 0.19, 290)

    /// Gradient for the active phase and progress: teal → blue → violet.
    static let progress = LinearGradient(colors: [lightTeal, lightBlue, violet], startPoint: .leading, endPoint: .trailing)
}

// MARK: - OKLCH

extension NSColor {
    /// A color given in OKLCH (as in the design), converted to sRGB.
    static func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> NSColor {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let lin = [
            4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
            -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
            -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_,
        ]
        let rgb = lin.map { x -> Double in
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(1, max(0, v))
        }
        return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha)
    }
}

extension Color {
    static func oklch(_ l: Double, _ c: Double, _ h: Double) -> Color {
        Color(nsColor: .oklch(l, c, h))
    }

    /// A color that switches with light/dark mode.
    static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Shared components

/// Icon on a colored background (rounded square).
struct SoftIcon: View {
    let symbol: String
    var color: Color = Theme.accentInk
    var background: Color = Theme.tint
    var size: CGFloat = 30
    var radius: CGFloat? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.53))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: radius ?? size * 0.3, style: .continuous))
    }
}

/// Text button in the accent color, highlighted on hover.
struct GhostButtonStyle: ButtonStyle {
    var color: Color = Theme.accentInk
    var hover: Color = Theme.tint
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        GhostButton(configuration: configuration, color: color, hover: hover, height: height)
    }

    private struct GhostButton: View {
        let configuration: Configuration
        let color: Color
        let hover: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(hovering && isEnabled ? hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Outlined button (Find, Detect, Settings file…).
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = Theme.accentInk
    var stroke: Color = Theme.accent
    var hover: Color = Theme.tint
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        OutlineButton(configuration: configuration, color: color, stroke: stroke, hover: hover, height: height)
    }

    private struct OutlineButton: View {
        let configuration: Configuration
        let color: Color
        let stroke: Color
        let hover: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(hovering && isEnabled ? hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(stroke))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Form field: height 32, background and border from the design.
struct FieldBox<Content: View>: View {
    var monospaced = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 14, design: .monospaced) : .system(size: 14))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Small up/down arrows (instead of the system Stepper).
struct MiniStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        VStack(spacing: 0) {
            arrow("chevron.up") { value = min(range.upperBound, value + step) }
            Rectangle().fill(Theme.border).frame(height: 1)
            arrow("chevron.down") { value = max(range.lowerBound, value - step) }
        }
        .frame(width: 20)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.muted)
                .frame(width: 20, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// A light "press" effect for buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
