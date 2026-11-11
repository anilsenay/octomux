import AppKit
import SwiftUI

// Endless animations run by Core Animation in the render server. A SwiftUI `repeatForever` animation re-renders the
// window's whole view tree every frame for as long as it runs (see WorkingRing).

/// A filled dot that breathes: grows and brightens, then shrinks and dims (0.7 s each way).
struct PulsingDot: NSViewRepresentable {
    let color: NSColor
    var size: CGFloat = 7

    func makeNSView(context: Context) -> DotView { DotView() }
    func updateNSView(_ v: DotView, context: Context) { v.color = color }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? { CGSize(width: size, height: size) }

    final class DotView: NSView {
        private let dot = CAShapeLayer()
        var color: NSColor = .clear { didSet { paint() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(dot)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance { dot.fillColor = color.cgColor }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.bounds = CGRect(origin: .zero, size: bounds.size)
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
            animate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            animate()
        }

        private func animate() {
            guard window != nil, dot.animation(forKey: "pulse") == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.85; scale.toValue = 1.25
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.6; fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 0.7
            g.autoreverses = true
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.isRemovedOnCompletion = false
            dot.add(g, forKey: "pulse")
        }
    }
}

/// An SF Symbol turning clockwise, once every `period` seconds.
struct SpinningSymbol: NSViewRepresentable {
    let name: String
    let color: NSColor
    var pointSize: CGFloat = NSFont.systemFontSize
    var period: CFTimeInterval = 0.9

    private var image: NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }

    func makeNSView(context: Context) -> SpinView { SpinView() }
    func updateNSView(_ v: SpinView, context: Context) { v.set(image: image, color: color, period: period) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinView, context: Context) -> CGSize? { image?.size }

    final class SpinView: NSView {
        private let spinner = CALayer()
        private var image: NSImage?
        private var color: NSColor = .labelColor
        private var period: CFTimeInterval = 0.9

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            spinner.contentsGravity = .center
            layer?.addSublayer(spinner)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func set(image: NSImage?, color: NSColor, period: CFTimeInterval) {
            self.image = image; self.color = color; self.period = period
            paint()
        }

        /// The symbol drawn in `color` (a template image takes no tint as layer contents).
        private func paint() {
            guard let image else { spinner.contents = nil; return }
            let scale = window?.backingScaleFactor ?? 2
            spinner.contentsScale = scale
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // Resolved here: the theme colors are dynamic, and the image would be drawn later, outside this
                // appearance. The color, cut to the symbol's shape (a translucent color keeps its own alpha).
                let resolved = NSColor(cgColor: color.cgColor) ?? color
                let tinted = NSImage(size: image.size, flipped: false) { r in
                    resolved.set()
                    r.fill()
                    image.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
                    return true
                }
                var rect = CGRect(origin: .zero, size: image.size)
                spinner.contents = tinted.cgImage(forProposedRect: &rect, context: nil,
                                                  hints: [.ctm: AffineTransform(scale: scale)])
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spinner.bounds = CGRect(origin: .zero, size: bounds.size)
            spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            spin()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            paint()
            spin()
        }

        private func spin() {
            guard window != nil, spinner.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            // Flipped view: a positive angle turns clockwise on screen, like SwiftUI's rotationEffect.
            a.fromValue = 0
            a.toValue = 2 * Double.pi
            a.duration = period
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            spinner.add(a, forKey: "spin")
        }
    }
}

/// The workspace switcher's breathing mark (WorkspaceMark .barBreathing / .glowBreathing), laid over or behind the
/// icon's `width` × 24 frame: the bar under it or the glow behind it, fading 0.35 → 1 and back every 2.6 s (the glow
/// also grows 0.85 → 1). Every mark breathes in step (the phase comes from the clock), like the SwiftUI version did.
struct BreathingMark: NSViewRepresentable {
    enum Kind { case bar, glow }
    let kind: Kind
    let color: NSColor

    func makeNSView(context: Context) -> MarkView { MarkView(kind: kind) }
    func updateNSView(_ v: MarkView, context: Context) { v.color = color }

    final class MarkView: NSView {
        static let period: CFTimeInterval = 2.6
        let kind: Kind
        /// Holds the art and breathes (opacity); the glow's blur sits here so the scaled rectangle stays soft.
        private let holder = CALayer()
        private let shape = CALayer()
        var color: NSColor = .clear { didSet { paint() } }

        init(kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            holder.masksToBounds = false
            shape.cornerCurve = .continuous
            holder.addSublayer(shape)
            layer?.addSublayer(holder)
            if kind == .glow, let blur = CIFilter(name: "CIGaussianBlur") {
                layerUsesCoreImageFilters = true
                blur.setValue(4, forKey: kCIInputRadiusKey)
                holder.filters = [blur]
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let c = NSColor(cgColor: color.cgColor) ?? color
                shape.backgroundColor = (kind == .glow ? c.withAlphaComponent(c.alphaComponent * 0.32) : c).cgColor
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            holder.frame = bounds
            switch kind {
            case .bar:   // Capsule 10 × 2.5, its bottom 1 pt above the frame's bottom.
                shape.bounds = CGRect(x: 0, y: 0, width: 10, height: 2.5)
                shape.cornerRadius = 1.25
                shape.position = CGPoint(x: bounds.midX, y: bounds.height - 1 - 1.25)
            case .glow:  // Rounded rectangle (radius 6) inset 3.
                shape.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 6), height: max(0, bounds.height - 6))
                shape.cornerRadius = 6
                shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            CATransaction.commit()
            animate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            paint()
            animate()
        }

        private func animate() {
            guard window != nil, holder.animation(forKey: "breath") == nil else { return }
            // 0 → 1 → 0 eased like 0.5 − 0.5·cos (sine in-out), starting where the clock says.
            let ease = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
            func breathe(_ key: String, _ from: Double, _ to: Double) -> CABasicAnimation {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from; a.toValue = to
                a.duration = Self.period / 2
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = ease
                a.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
                a.isRemovedOnCompletion = false
                return a
            }
            holder.add(breathe("opacity", 0.35, 1), forKey: "breath")
            if kind == .glow { shape.add(breathe("transform.scale", 0.85, 1), forKey: "breath") }
        }
    }
}
