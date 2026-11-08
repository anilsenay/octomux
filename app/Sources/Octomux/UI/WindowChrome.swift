import AppKit
import Combine
import SwiftUI

/// The main window's traffic lights: in the middle of the top bar's row (with the sidebar and bell buttons and the
/// tabs on the same line), inset from the left as much as from the top. AppKit puts them back in its own place when it
/// lays the title bar out, so they are placed again on resize, key changes, full screen and theme changes (the row's
/// height is the theme's).
enum WindowChrome {
    /// The first light's x and the lights' centre below the window's top, for a top bar `topH` tall.
    static func lights(topH: CGFloat) -> (x: CGFloat, center: CGFloat) {
        let c = (topH / 2).rounded()
        return (c - 7, c)
    }
    static var lights: (x: CGFloat, center: CGFloat) { lights(topH: T.m.topH) }
    /// Between two lights' left edges (AppKit's spacing).
    static let pitch: CGFloat = 20
    /// Where the controls after the lights start (sidebar, bell).
    static var controlsX: CGFloat { lights.x + 2 * pitch + 14 + 15 }

    /// A light's origin in its superview (not flipped): its centre `center` below the top, inside the title bar.
    static func origin(_ i: Int, superHeight: CGFloat, buttonHeight h: CGFloat, topH: CGFloat) -> NSPoint {
        let l = lights(topH: topH)
        let y = max(0, min(superHeight - l.center - h / 2, superHeight - h))
        return NSPoint(x: l.x + CGFloat(i) * pitch, y: y)
    }

    static func place(_ w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen) else { return }   // full screen: AppKit's own title bar
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(kind), let sup = b.superview else { continue }
            let o = origin(i, superHeight: sup.bounds.height, buttonHeight: b.frame.height, topH: T.m.topH)
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
    }

    private static var themeWatch: AnyCancellable?
    /// Places the lights again whenever the theme changes (after its views have taken the new metrics).
    static func follow(_ w: NSWindow) {
        themeWatch = ThemeStore.shared.objectWillChange.sink { [weak w] _ in
            DispatchQueue.main.async { if let w { place(w) } }
        }
    }
}
