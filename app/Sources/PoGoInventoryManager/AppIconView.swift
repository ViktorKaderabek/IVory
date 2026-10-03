import AppKit
import SwiftUI

/// App icon ("Monogram IV" design): an ivory "IV" on a night background with three lights.
/// The same view draws the icon in the window and the AppIcon.icns file (see `IconExport`).
struct AppIconView: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let inset = s * 0.0977
            let body = s - 2 * inset
            let shape = RoundedRectangle(cornerRadius: body * 0.224, style: .continuous)
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .oklch(0.40, 0.12, 286), location: 0),
                        .init(color: Theme.nightSection, location: 0.48),
                        .init(color: Theme.nightBg, location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.37, y: 0), endPoint: UnitPoint(x: 0.63, y: 1))
                light(Theme.lightTeal, size: 0.72, x: -0.24 + 0.36, y: 1.28 - 0.36, blur: 0.09, opacity: 0.8, of: body)
                light(Theme.violet, size: 0.70, x: 1.26 - 0.35, y: -0.24 + 0.35, blur: 0.09, opacity: 0.75, of: body)
                light(Theme.lightBlue, size: 0.46, x: 0.34 + 0.23, y: 0.36 + 0.23, blur: 0.10, opacity: 0.55, of: body)
                Text("IV")
                    .font(.system(size: s * 0.44, weight: .semibold))
                    .tracking(-s * 0.44 * 0.05)
                    .foregroundStyle(Theme.ivory)
                    .shadow(color: .black.opacity(0.3), radius: s * 0.015, y: s * 0.012)
                    .offset(y: -s * 0.01)
            }
            .frame(width: body, height: body)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: max(0.5, s * 0.0015)))
            .overlay(alignment: .top) {
                // subtle top edge
                shape.stroke(.white.opacity(0.24), lineWidth: max(0.5, s * 0.003))
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)))
            }
            .shadow(color: .black.opacity(0.5), radius: s * 0.017, y: s * 0.014)
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// A blurred light; x, y is its center as a fraction of the icon body size.
    private func light(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat, blur: CGFloat, opacity: Double, of body: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: body * size, height: body * size)
            .blur(radius: body / 0.8046 * blur)  // the design gives the blur in % of the whole icon
            .opacity(opacity)
            .position(x: body * x, y: body * y)
            .frame(width: body, height: body)
    }
}

/// `IVory --export-icon <folder.iconset>`: renders the icon in every size for iconutil.
@MainActor
enum IconExport {
    static func run(to folder: String) -> Int32 {
        let dir = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 256, 512] {
            for scale in [1, 2] {
                let px = size * scale
                let renderer = ImageRenderer(content: AppIconView().frame(width: CGFloat(px), height: CGFloat(px)))
                renderer.scale = 1
                guard let cg = renderer.cgImage else { return 1 }
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                do { try png.write(to: dir.appendingPathComponent(name)) } catch { return 1 }
            }
        }
        return 0
    }
}
