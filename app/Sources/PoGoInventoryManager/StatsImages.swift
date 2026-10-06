import AppKit
import SwiftUI

/// Pictures of the Pokémon in the storage. They are downloaded (PokeImages), not cut out of the phone's
/// screen – the bot no longer saves photos while it reads the IVs. A Pokémon whose species the bot
/// couldn't pin down has no picture, so it gets its type's color and first letter instead.

/// A Pokémon in a list: the game's own icon, which knows the forms.
struct MonIcon: View {
    let m: InventoryStats.Mon
    var size: CGFloat = 34
    var circle = false
    var ring: Color? = nil

    var body: some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        Group {
            if m.dex != nil {
                PokeImage(dex: m.dex, sid: m.sid, kind: .icon, size: size)
            } else {
                MonLetter(m: m, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(ring ?? Theme.border, lineWidth: ring == nil ? 1 : 2))
    }
}

/// A Pokémon shown large – the detail panel, the PvP cards: the official render.
struct MonArtwork: View {
    let m: InventoryStats.Mon
    var size: CGFloat

    var body: some View {
        Group {
            if m.dex != nil {
                PokeImage(dex: m.dex, sid: m.sid, kind: .artwork, size: size)
            } else {
                MonLetter(m: m, size: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Without a picture: the type's color and the first letter of the name.
struct MonLetter: View {
    let m: InventoryStats.Mon
    var size: CGFloat

    var body: some View {
        let color = PokeType.color(m.types.first ?? "")
        ZStack {
            color.opacity(0.22)
            Text(String(m.name.prefix(1))).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(color)
        }
    }
}
