import SwiftUI

/// Barvy a společné prvky vzhledu.
enum Theme {
    static let teal = Color(red: 0.07, green: 0.70, blue: 0.66)
    static let blue = Color(red: 0.22, green: 0.46, blue: 0.96)
    static let violet = Color(red: 0.49, green: 0.36, blue: 0.95)

    static let accent = LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let hero = LinearGradient(colors: [teal, blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Barva IV tagu podle pořadí (nejlepší nahoře).
    static func tagColor(_ index: Int, of count: Int) -> Color {
        let palette: [Color] = [.purple, .green, .mint, .teal, .blue, .orange, .red, .pink, .indigo, .brown]
        guard count > 0 else { return .gray }
        return palette[min(index, palette.count - 1)]
    }
}

/// Karta s jemným pozadím a okrajem.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }
}

/// Ikona v barevném zaobleném čtverci.
struct IconBadge: View {
    let symbol: String
    var size: CGFloat = 32
    var fill: AnyShapeStyle = AnyShapeStyle(Theme.accent)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Jemná ikona (barevný symbol na světlém podkladu).
struct SoftIcon: View {
    let symbol: String
    var color: Color = Theme.teal
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Záhlaví stránky nastavení.
struct PageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Řádek nastavení: ikona, název, popis a ovládací prvek vpravo.
struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SoftIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, 4)
    }
}

/// Hlavní tlačítko s gradientem.
struct PrimaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.white))
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background {
                if destructive {
                    Capsule().fill(.white)
                } else {
                    Capsule().fill(.white.opacity(0.22))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Banner, když běží úklid a nastavení je zamčené.
struct RunningBanner: View {
    var body: some View {
        Label("Úklid právě běží – nastavení půjde měnit po jeho skončení.", systemImage: "lock.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.22), in: Capsule())
    }
}
