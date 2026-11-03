import AppKit
import QuartzCore

/// Stop Octomux: the text in the terminal area falls out of it, character cell by character cell, before the
/// stopped screen appears. One window snapshot (terminals draw with Metal, so the window server's image, not
/// the views'), cut into cells; only cells with something drawn in them fall. Skipped with Reduce Motion.
enum StopAnimation {
    /// About one terminal character.
    static let cell = CGSize(width: 8, height: 16)
    /// Enough for a full screen of text; beyond that the rest just fades with the blur.
    static let maxPieces = 3500

    /// Takes the snapshot now (call before the terminals go away) and runs the fall; `done` when it ends.
    static func run(window: NSWindow?, area: NSView, done: @escaping () -> Void) {
        guard let window, let content = window.contentView, area.window === window,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let shot = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        else { done(); return }
        let scale = CGFloat(shot.width) / window.frame.width
        let r = area.convert(area.bounds, to: nil)   // window points, origin bottom-left
        let crop = CGRect(x: r.minX * scale, y: (window.frame.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale).integral
        guard r.width > 20, r.height > 20, let image = shot.cropping(to: crop), let pixels = Pixels(image) else { done(); return }

        let overlay = NSView(frame: content.convert(r, from: nil))
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)

        let cols = Int(r.width / cell.width), rows = Int(r.height / cell.height)
        let now = CACurrentMediaTime()
        var longest: Double = 0
        var count = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer: for row in 0..<rows {
            for col in 0..<cols {
                // Image rows run top-down; the overlay's y runs bottom-up.
                let px = CGRect(x: CGFloat(col) * cell.width * scale, y: CGFloat(row) * cell.height * scale,
                                width: cell.width * scale, height: cell.height * scale).integral
                guard pixels.hasInk(px), let piece = image.cropping(to: px) else { continue }
                let l = CALayer()
                l.contents = piece
                l.contentsScale = scale
                l.frame = CGRect(x: CGFloat(col) * cell.width, y: r.height - CGFloat(row + 1) * cell.height, width: cell.width, height: cell.height)
                overlay.layer?.addSublayer(l)
                // Lower lines go first, every piece a little apart; gravity (ease-in) to below the area.
                let depth = Double(row) / Double(max(rows, 1))
                let delay = Double.random(in: 0...0.28) + (1 - depth) * 0.22
                let duration = Double.random(in: 0.55...0.95)
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.byValue = -(l.frame.maxY + 40)
                fall.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.9, 0.6)
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.toValue = CGFloat.random(in: -0.9...0.9)
                let drift = CABasicAnimation(keyPath: "position.x")
                drift.byValue = CGFloat.random(in: -14...14)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0.15
                let g = CAAnimationGroup()
                g.animations = [fall, spin, drift, fade]
                g.duration = duration
                g.beginTime = now + delay
                g.fillMode = .both
                g.isRemovedOnCompletion = false
                l.add(g, forKey: "fall")
                longest = max(longest, delay + duration)
                count += 1
                if count >= maxPieces { break outer }
            }
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.05) {
            overlay.removeFromSuperview()
            done()
        }
    }

    /// RGBA bytes of the snapshot, to tell drawn cells from empty background.
    private struct Pixels {
        let data: [UInt8]
        let width: Int, height: Int
        /// The background: the most common color along the top-left corner region.
        let bg: (Int, Int, Int)

        init?(_ image: CGImage) {
            width = image.width; height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = bytes
            var counts: [Int: Int] = [:]
            for y in stride(from: 0, to: height, by: max(1, height / 40)) {
                for x in stride(from: 0, to: width, by: max(1, width / 40)) {
                    let i = (y * width + x) * 4
                    let key = (Int(bytes[i]) / 8) << 10 | (Int(bytes[i + 1]) / 8) << 5 | Int(bytes[i + 2]) / 8
                    counts[key, default: 0] += 1
                }
            }
            let k = counts.max { $0.value < $1.value }?.key ?? 0
            bg = (((k >> 10) & 31) * 8, ((k >> 5) & 31) * 8, (k & 31) * 8)
        }

        /// Something in the cell differs clearly from the background (a glyph, a cursor, a border).
        func hasInk(_ r: CGRect) -> Bool {
            let x0 = max(0, Int(r.minX)), x1 = min(width, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(height, Int(r.maxY))
            var hits = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    // A bitmap context's memory runs top-down, like the image rows.
                    let i = (y * width + x) * 4
                    let d = abs(Int(data[i]) - bg.0) + abs(Int(data[i + 1]) - bg.1) + abs(Int(data[i + 2]) - bg.2)
                    if d > 90 { hits += 1; if hits >= 2 { return true } }
                }
            }
            return false
        }
    }
}
