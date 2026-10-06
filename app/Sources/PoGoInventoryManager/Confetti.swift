import AppKit
import SwiftUI

/// Confetti in the IV tag colors over the whole window, 3 s.
struct ConfettiView: View {
    let start: Date
    private let pieces = (0..<80).map(Piece.init)

    struct Piece {
        let x: Double, delay: Double, speed: Double, drift: Double, spin: Double, angle: Double
        let color: Color, w: Double, h: Double

        init(_ seed: Int) {
            var s = UInt64(seed &+ 1) &* 6364136223846793005 &+ 1442695040888963407
            func r() -> Double {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                return Double(s >> 11) / Double(1 << 53)
            }
            x = r()
            delay = r() * 0.6
            speed = 0.35 + r() * 0.35
            drift = 10 + r() * 30
            spin = 0.5 + r() * 1.5
            angle = r() * 360
            let colors: [Color] = [Theme.lightTeal, Theme.lightBlue, Theme.violet, .oklch(0.84, 0.14, 85),
                                   .oklch(0.74, 0.15, 30), .oklch(0.72, 0.16, 350), Theme.white]
            color = colors[seed % colors.count]
            w = 5 + r() * 5
            h = 9 + r() * 7
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { ctx, size in
                for p in pieces {
                    let tt = t - p.delay
                    guard tt > 0, tt < 3 else { continue }
                    var c = ctx
                    c.opacity = (tt > 2.3 ? max(0, 1 - (tt - 2.3) / 0.7) : 1) * 0.9
                    let x = p.x * size.width + sin(tt * 3 + p.angle) * p.drift
                    let y = -20 + tt * p.speed * size.height
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .degrees(p.angle + tt * 360 * p.spin))
                    let rect = CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)
                    c.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(p.color))
                }
            }
        }
    }
}
