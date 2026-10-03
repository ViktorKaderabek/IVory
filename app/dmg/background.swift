// Nakreslí pozadí okna instalačního DMG (660 × 420 bodů, 1× a 2×).
//   swift app/dmg/background.swift <cílová složka>
// Výsledek (background.png a background@2x.png) spojí scripts/build_dmg.sh do jednoho TIFF.
import AppKit

let size = NSSize(width: 660, height: 420)
let accent = NSColor(srgbRed: 0x79 / 255.0, green: 0x6c / 255.0, blue: 0xbf / 255.0, alpha: 1)
let ink = NSColor(srgbRed: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x26 / 255.0, alpha: 1)
let muted = NSColor(srgbRed: 0x59 / 255.0, green: 0x5d / 255.0, blue: 0x6c / 255.0, alpha: 1)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, top: CGFloat, width: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = 2
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = str.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]).height
    str.draw(with: NSRect(x: centerX - width / 2, y: 420 - top - h, width: width, height: h), options: [.usesLineFragmentOrigin])
}

func blob(_ color: NSColor, center: NSPoint, radius: CGFloat, alpha: CGFloat) {
    let g = NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])!
    g.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // podklad jako v banneru README: jemný fialovo-modrý přechod
    NSGradient(colors: [NSColor(srgbRed: 0xe7 / 255.0, green: 0xe5 / 255.0, blue: 0xfe / 255.0, alpha: 1),
                        NSColor(srgbRed: 0xee / 255.0, green: 0xf0 / 255.0, blue: 0xfa / 255.0, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -35)
    blob(accent, center: NSPoint(x: 600, y: 420), radius: 260, alpha: 0.22)
    blob(NSColor(srgbRed: 0.25, green: 0.72, blue: 0.78, alpha: 1), center: NSPoint(x: 40, y: 20), radius: 240, alpha: 0.14)

    text("Drag IVory to Applications", size: 20, weight: .semibold, color: ink, centerX: 330, top: 38, width: 560)
    text("Přetáhni IVory do Aplikací", size: 13, weight: .regular, color: muted, centerX: 330, top: 66, width: 560)

    // šipka mezi ikonami (střed ikon: x 165 a 495, y 190 shora)
    let y: CGFloat = 420 - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y))
    arrow.line(to: NSPoint(x: 392, y: y))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    accent.withAlphaComponent(0.85).setStroke()
    arrow.setLineDash([2, 9], count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: y + 11))
    head.line(to: NSPoint(x: 398, y: y))
    head.line(to: NSPoint(x: 384, y: y - 11))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // karta s návodem na první spuštění
    let card = NSRect(x: 40, y: 22, width: 580, height: 92)
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    NSColor(srgbRed: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x26 / 255.0, alpha: 0.10).setStroke()
    let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    border.lineWidth = 1
    border.stroke()
    text("First start", size: 12, weight: .semibold, color: ink, centerX: 330, top: 318, width: 540)
    text("If macOS blocks the app: System Settings → Privacy & Security → Open Anyway.\n"
         + "IVory needs Xcode. Node.js, Appium and Python download by themselves on the first run.",
         size: 11.5, weight: .regular, color: muted, centerX: 330, top: 338, width: 560)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let png = render(scale: scale).representation(using: .png, properties: [:])!
    try! png.write(to: out.appendingPathComponent(name))
    print("✔ \(name)")
}
