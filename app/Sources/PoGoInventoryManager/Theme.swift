import SwiftUI

/// Barvy a společné prvky vzhledu.
enum Theme {
    static let teal = Color(red: 0.07, green: 0.70, blue: 0.66)
    static let blue = Color(red: 0.22, green: 0.46, blue: 0.96)
    static let violet = Color(red: 0.49, green: 0.36, blue: 0.95)

    static let accent = LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

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

/// Banner, když běží úklid a nastavení je zamčené.
struct RunningBanner: View {
    var body: some View {
        Label("Úklid běží – nastavení půjde měnit po jeho skončení.", systemImage: "lock.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.22), in: Capsule())
    }
}
