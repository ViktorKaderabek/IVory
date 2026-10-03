import AppKit
import QuartzCore
import SwiftUI

// Nekonečné animace hero karty běží v Core Animation: přehrává je systém (render server), takže
// aplikace mezi snímky nic nepočítá. Dřív je kreslil SwiftUI TimelineView a každý snímek
// (až 120× za sekundu) procházel celé okno na hlavním vlákně – UI se pak sekalo.

// MARK: - Plující světla

/// Tři rozostřená světla na pozadí hero karty. `speed` 1 = jeden přelet za 16 s; 0 = stojí.
struct HeroLights: NSViewRepresentable {
    let colors: [Color]
    let opacity: Double
    let speed: Double
    var cornerRadius: CGFloat = 20

    func makeNSView(context: Context) -> LightsView { LightsView() }

    func updateNSView(_ view: LightsView, context: Context) {
        view.update(colors: colors.map { NSColor($0) }, opacity: Float(opacity), speed: Float(speed),
                    cornerRadius: cornerRadius)
    }

    final class LightsView: NSView {
        /// Velikost, poloha (zlomek šířky/výšky karty), dva klíčové snímky (posun x, y, zvětšení)
        /// a jak pomalu světlo pluje (×). Hodnoty z návrhu.
        private static let specs: [(size: CGFloat, left: CGFloat, top: CGFloat, keys: [(CGFloat, CGFloat, CGFloat)], slow: Double)] = [
            (340, -0.08, 0.35, [(70, 24, 1.18), (-30, 40, 0.94)], 1),
            (380, 0.32, -0.45, [(-80, 30, 0.9), (-20, -30, 1.15)], 1.2),
            (360, 0.68, 0.10, [(40, -40, 1.2), (-60, 10, 1)], 0.9),
        ]
        /// Jak moc je okraj světla rozmazaný (odpovídá `.blur(radius: 56)` z návrhu).
        private static let soft: CGFloat = 56

        private let stage = CALayer()
        private var blobs: [CAGradientLayer] = []
        private var colors: [NSColor] = []

        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.cornerCurve = .continuous
            layer?.addSublayer(stage)
            for spec in Self.specs {
                let blob = CAGradientLayer()
                blob.type = .radial
                blob.startPoint = CGPoint(x: 0.5, y: 0.5)
                blob.endPoint = CGPoint(x: 1, y: 1)
                blob.locations = Self.stops(radius: spec.size / 2).map { NSNumber(value: Double($0.0)) }
                stage.addSublayer(blob)
                blobs.append(blob)

                let move = CAKeyframeAnimation(keyPath: "transform")
                move.values = ([(0, 0, 1)] + spec.keys).map { dx, dy, sc in
                    NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), sc, sc, 1))
                }
                move.keyTimes = [0, 0.5, 1]
                move.duration = 16 * spec.slow
                move.autoreverses = true
                move.repeatCount = .infinity
                move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                move.isRemovedOnCompletion = false
                blob.add(move, forKey: "drift")
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.frame = bounds
            for (blob, spec) in zip(blobs, Self.specs) {
                let side = spec.size + 4 * Self.soft
                blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                blob.position = CGPoint(x: bounds.width * spec.left + spec.size / 2,
                                        y: bounds.height * spec.top + spec.size / 2)
            }
            CATransaction.commit()
        }

        func update(colors new: [NSColor], opacity: Float, speed: Float, cornerRadius: CGFloat) {
            layer?.cornerRadius = cornerRadius
            CATransaction.begin()
            CATransaction.setAnimationDuration(colors.isEmpty ? 0 : 0.6)
            if new != colors {
                colors = new
                for (i, blob) in blobs.enumerated() {
                    let color = new[min(i, new.count - 1)]
                    blob.colors = Self.stops(radius: Self.specs[i].size / 2).map { color.withAlphaComponent($0.1).cgColor }
                }
            }
            stage.opacity = opacity
            CATransaction.commit()
            setSpeed(speed)
        }

        /// Změna rychlosti bez skoku: místní čas vrstvy zůstane, jen poběží jinak rychle.
        private func setSpeed(_ speed: Float) {
            guard stage.speed != speed else { return }
            let now = CACurrentMediaTime()
            let local = stage.convertTime(now, from: nil)
            stage.speed = speed
            stage.timeOffset = local
            stage.beginTime = now
        }

        /// Průběh jasu kruhu o poloměru `r` rozmazaného Gaussem (σ = soft): zastávky radiálního
        /// přechodu od středu do vzdálenosti r + 2σ (kraj vrstvy).
        private static func stops(radius r: CGFloat) -> [(CGFloat, CGFloat)] {
            let end = r + 2 * soft
            return stride(from: 0.0, through: 1.0, by: 0.1).map { f in
                let z = Double((CGFloat(f) * end - r) / (soft * 1.414))
                return (CGFloat(f), CGFloat(max(0, min(1, 0.5 * (1 - erf(z))))))
            }
        }
    }
}

// MARK: - Kruhy kolem tlačítka Spustit

/// V klidu jeden kruh, který se pomalu rozplývá ven; při běhu dvě radarové vlny a točící se oblouk.
struct StartRings: NSViewRepresentable {
    let running: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> RingsView { RingsView() }

    func updateNSView(_ view: RingsView, context: Context) {
        view.configure(running: running, reduceMotion: reduceMotion)
    }

    final class RingsView: NSView {
        private var mode: (Bool, Bool)?
        private var layers: [CALayer] = []

        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            if let mode { build(running: mode.0, reduceMotion: mode.1) }
        }

        func configure(running: Bool, reduceMotion: Bool) {
            guard mode.map({ $0 != (running, reduceMotion) }) ?? true else { return }
            mode = (running, reduceMotion)
            build(running: running, reduceMotion: reduceMotion)
        }

        private func build(running: Bool, reduceMotion: Bool) {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = []
            guard bounds.width > 0, let host = layer else { return }
            if running {
                for delay in [0, 1.3] {
                    let ripple = ring(width: 1, color: NSColor(Theme.lightTeal))
                    ripple.opacity = 0
                    if !reduceMotion {
                        ripple.add(pulse(from: 0.85, to: 2.1, opacity: 0.7, duration: 2.6, delay: delay), forKey: "pulse")
                    }
                    host.addSublayer(ripple)
                    layers.append(ripple)
                }
                host.addSublayer(spinner(reduceMotion: reduceMotion))
            } else if !reduceMotion {
                let glow = ring(width: 2, color: NSColor.white.withAlphaComponent(0.5))
                glow.opacity = 0
                glow.add(pulse(from: 0.97, to: 1.2, opacity: 0.9, duration: 2.4, delay: 0), forKey: "pulse")
                host.addSublayer(glow)
                layers.append(glow)
            }
        }

        /// Kruh vepsaný do pohledu (jako SwiftUI `strokeBorder`), škáluje se od středu.
        private func ring(width: CGFloat, color: NSColor) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.frame = bounds
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = width
            return shape
        }

        /// Kruh se zvětší a zároveň vybledne (ease-out), pořád dokola.
        private func pulse(from: CGFloat, to: CGFloat, opacity: Float, duration: Double, delay: Double) -> CAAnimation {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = from
            scale.toValue = to
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = duration
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)   // ease-out (1 - (1 - p)²)
            group.timeOffset = duration - delay.truncatingRemainder(dividingBy: duration)
            group.isRemovedOnCompletion = false
            return group
        }

        /// Oblouk s přechodem do bílé, otočka za 1,6 s.
        private func spinner(reduceMotion: Bool) -> CALayer {
            let arc = CAGradientLayer()
            arc.frame = bounds
            arc.type = .conic
            arc.startPoint = CGPoint(x: 0.5, y: 0.5)
            arc.endPoint = CGPoint(x: 0.5, y: 0)
            arc.colors = [NSColor.clear, .clear, NSColor(Theme.lightTeal), NSColor(Theme.white)].map(\.cgColor)
            arc.locations = [0, 0.6, 0.86, 1]
            let mask = ring(width: 4, color: .black)
            mask.frame = arc.bounds
            arc.mask = mask
            if !reduceMotion {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 1.6
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                arc.add(spin, forKey: "spin")
            }
            layers.append(arc)
            return arc
        }
    }
}

// MARK: - Pulzování

/// Kroužek, který pulzuje: volitelně výplň, záře kolem (stín) a blikání. Nahrazuje `phaseAnimator`,
/// který by po celou dobu běhu překresloval okno.
struct PulsingCircle: NSViewRepresentable {
    var fill: Color? = nil
    var glow: Color? = nil
    var glowRadius: CGFloat = 5
    /// Záře mezi dvěma sílami (0–1), tam a zpět.
    var glowRange: ClosedRange<Float> = 1...1
    /// Celý kroužek bliká mezi plnou a touto průhledností.
    var blinkTo: Float = 1
    var duration: Double = 1
    var animate = true

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        view.configure(self)
    }

    final class PulseView: NSView {
        private var last: String?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
            layer?.cornerRadius = bounds.width / 2
        }

        func configure(_ c: PulsingCircle) {
            guard let layer else { return }
            let key = "\(String(describing: c.fill))\(String(describing: c.glow))\(c.glowRange)\(c.blinkTo)\(c.duration)\(c.animate)"
            guard key != last else { return }
            last = key
            layer.removeAllAnimations()
            layer.backgroundColor = c.fill.map { NSColor($0).cgColor }
            layer.shadowColor = c.glow.map { NSColor($0).cgColor }
            layer.shadowRadius = c.glowRadius
            layer.shadowOffset = .zero
            layer.shadowOpacity = c.glow == nil ? 0 : (c.animate ? c.glowRange.lowerBound : c.glowRange.upperBound)
            layer.opacity = 1
            guard c.animate else { return }
            var parts: [CAAnimation] = []
            if c.glow != nil && c.glowRange.lowerBound != c.glowRange.upperBound {
                let glow = CABasicAnimation(keyPath: "shadowOpacity")
                glow.fromValue = c.glowRange.lowerBound
                glow.toValue = c.glowRange.upperBound
                parts.append(glow)
            }
            if c.blinkTo < 1 {
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1
                blink.toValue = c.blinkTo
                parts.append(blink)
            }
            guard !parts.isEmpty else { return }
            let group = CAAnimationGroup()
            group.animations = parts
            group.duration = c.duration
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "pulse")
        }
    }
}

// MARK: - Světlo na spojnici fází

/// Krátký světlý pruh, který pořád dokola přejíždí zleva doprava (na spojnici za běžící fází).
struct FlowStripe: NSViewRepresentable {
    let reduceMotion: Bool

    func makeNSView(context: Context) -> StripeView { StripeView() }

    func updateNSView(_ view: StripeView, context: Context) { view.reduceMotion = reduceMotion }

    final class StripeView: NSView {
        private let stripe = CAGradientLayer()
        var reduceMotion = false { didSet { if reduceMotion != oldValue { needsLayout = true } } }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            stripe.startPoint = CGPoint(x: 0, y: 0.5)
            stripe.endPoint = CGPoint(x: 1, y: 0.5)
            stripe.colors = [NSColor(Theme.lightTeal).withAlphaComponent(0), NSColor(Theme.lightTeal),
                             NSColor(Theme.white), NSColor(Theme.violet).withAlphaComponent(0)].map(\.cgColor)
            stripe.locations = [0, 0.55, 0.8, 1]
            layer?.addSublayer(stripe)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
            let width = max(28, bounds.width * 0.45)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stripe.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            stripe.position = CGPoint(x: -width / 2, y: bounds.midY)
            CATransaction.commit()
            stripe.removeAllAnimations()
            stripe.isHidden = reduceMotion
            guard !reduceMotion, bounds.width > 0 else { return }
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -width / 2
            move.toValue = bounds.width + width / 2
            move.duration = 1.5
            move.repeatCount = .infinity
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            move.isRemovedOnCompletion = false
            stripe.add(move, forKey: "flow")
        }
    }
}
