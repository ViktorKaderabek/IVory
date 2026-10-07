import SwiftUI

/// A phone in the design's two sizes: one big phone, or two side by side. The screenshot fills the
/// screen; `overlay` draws over it (the install banner).
struct SetupPhone<Overlay: View>: View {
    enum Size {
        case single, pair

        var outer: CGSize {
            switch self {
            case .single: return CGSize(width: 290, height: 600)
            case .pair: return CGSize(width: 244, height: 506)
            }
        }
        var pad: CGFloat { self == .single ? 10 : 8 }
        var radius: CGFloat { self == .single ? 46 : 40 }
        var inner: CGFloat { self == .single ? 36 : 32 }
    }

    let art: SetupArt
    var size = Size.pair
    @ViewBuilder var overlay: Overlay

    var body: some View {
        let o = size.outer
        let screen = CGSize(width: o.width - size.pad * 2, height: o.height - size.pad * 2)
        ZStack {
            art == .restart ? Color.black : SW.phoneScreen
            SetupScreenshot(art: art, size: screen)
            overlay
        }
        .frame(width: screen.width, height: screen.height)
        .clipShape(RoundedRectangle(cornerRadius: size.inner, style: .continuous))
        .padding(size.pad)
        .background(SW.phoneBody, in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: SW.shadow, radius: 32, y: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Ukázka obrazovky iPhonu", "Example of the iPhone screen"))
    }
}

extension SetupPhone where Overlay == EmptyView {
    init(art: SetupArt, size: Size = .pair) {
        self.init(art: art, size: size) { EmptyView() }
    }
}

/// The screenshot, cropped to fill the phone's screen.
private struct SetupScreenshot: View {
    let art: SetupArt
    let size: CGSize

    var body: some View {
        if let image = art.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(art == .restart ? 1.05 : 1)
                .clipped()
        }
    }
}

/// One phone of a screen, with what to do on it.
struct PhonePic {
    let art: SetupArt
    let caption: String
}

/// The line over a phone: its number when there are two, a phone icon when it's alone.
struct PhoneCaption: View {
    let text: String
    var number: Int? = nil
    var color = SW.ink
    var symbol = "iphone"

    var body: some View {
        HStack(spacing: 8) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(SW.accent, lineWidth: 1.5))
            } else {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            }
            Text(text).font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(color)
        .frame(height: 22)
    }
}

/// One or two phones on a violet glow; two are numbered, with an arrow between them, and rise in one
/// after the other.
struct PhoneStage: View {
    let phones: [PhonePic]

    var body: some View {
        let pair = phones.count > 1
        FitToSpace(size: pair ? CGSize(width: 244 * 2 + 64, height: 542) : CGSize(width: 290, height: 636)) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [SW.tint, SW.tint.opacity(0)], center: .center, startRadius: 0, endRadius: 310))
                    .frame(width: 620, height: 620)
                    .opacity(0.9)
                HStack(spacing: 16) {
                    ForEach(Array(phones.enumerated()), id: \.offset) { i, pic in
                        HStack(spacing: 16) {
                            if i > 0 { arrow }
                            VStack(spacing: 14) {
                                PhoneCaption(text: pic.caption, number: pair ? i + 1 : nil)
                                SetupPhone(art: pic.art, size: pair ? .pair : .single)
                            }
                        }
                        .modifier(PhoneRise(delay: 0.08 + 0.12 * Double(i)))
                    }
                }
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(SW.ink)
            .frame(width: 32, height: 32)
            .background(SW.surface, in: Circle())
            .overlay(Circle().strokeBorder(SW.border, lineWidth: 1))
            .padding(.top, 34)
    }
}

/// Centres its content in the space it's given, scaled down as a whole when it doesn't fit (`size` is
/// what it needs at full size).
struct FitToSpace<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            content
                .scaleEffect(min(1, (geo.size.width - 8) / size.width, (geo.size.height - 24) / size.height))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Phones come up from below with a slight zoom.
struct PhoneRise: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .scaleEffect(shown ? 1 : 0.97)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(SW.ease(0.5).delay(delay)) { shown = true }
            }
    }
}
