import AppKit
import Combine
import SwiftUI

/// Menu bar item: the logo's pixel octopus (design/brand/octomux-logo.html) at 1pt per pixel, 16×14pt. The menu bar
/// version has one extra head row and 2px legs so it matches the height and stroke weight of system icons.
/// While any agent is working it plays a low-fps bounce (squish, stretch, blink).
/// Setting `menubar.style`: "color" (default, flat purple), "mono" (tonal template image), "hidden".
/// Unread notifications put a dot on its top-right corner (not while it bounces). A click opens a small panel with
/// them (MenuBarPanel); a right-click or Control-click the menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    enum Style: String { case color, mono, hidden }

    private static let body = [
        ".....######.....",
        "...#hhh######...",
        "..#hhh########..",
        ".##hh#########s.",
        ".#############s.",
        ".#############s.",
        ".###we####we##s.",
        ".###ee####ee##s.",
        ".###ee####ee##s.",
        ".#c##########cs.",
        "..###########s..",
    ]
    /// Menu bar legs are 2px wide (the logo's 1px legs read as hairlines at 16pt): four legs, the outer two curl out.
    private static let legs = [
        ".##..##..##..##.",
        ".##..##..##..##.",
        "##...##..##...##",
    ]
    private static let spreadLegs = [".##..##..##..##.", "##..##....##..##"]
    private static let tuckLegs = ["..##.##..##.##..", "..##.##..##.##..", "..#..##..##..#.."]
    private static let height = 15

    /// idle, squish (row 4 dropped, legs pulled in), idle, stretch (row 4 doubled, legs tucked), idle, blink (eyes filled).
    private static let rows: [[String]] = {
        func pad(_ r: [String]) -> [String] { Array(repeating: String(repeating: ".", count: 16), count: height - r.count) + r }
        let idle = pad(body + legs)
        let squish = pad(Array(body[0..<4]) + Array(body[5...]) + spreadLegs)
        let stretch = pad(Array(body[0..<5]) + [body[4]] + Array(body[5...]) + tuckLegs)
        let blink = idle.map { $0.replacingOccurrences(of: "e", with: "#").replacingOccurrences(of: "w", with: "#") }
        return [idle, squish, idle, stretch, idle, blink]
    }()

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    /// Flat purple: the logo's highlight/shadow pixels take the body color so it stays clean at 16pt.
    private static let colorPalette: [Character: NSColor] = [
        "#": rgb(0x8b5cf6), "h": rgb(0x8b5cf6), "s": rgb(0x8b5cf6),
        "e": rgb(0x1e1b4b), "w": rgb(0xffffff), "c": rgb(0xf9a8d4),
    ]
    /// Tonal mono (template image): the logo's light body / dark eyes / bright glint kept as alpha levels, so the eyes
    /// read as eyes rather than holes (solid silhouettes with eye holes looked like a virus/space-invader icon).
    private static let monoPalette: [Character: NSColor] = [
        "#": .black.withAlphaComponent(0.72), "h": .black.withAlphaComponent(0.5), "s": .black.withAlphaComponent(0.85),
        "c": .black.withAlphaComponent(0.5), "e": .black,
    ]

    private static func makeImage(_ rows: [String], palette: [Character: NSColor], template: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: rows[0].count, height: rows.count), flipped: true) { _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = palette[ch] else { continue }
                    c.setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        img.isTemplate = template
        return img
    }
    /// `base` with a dot on its top-right corner, cut out of the icon by a clear ring.
    private static func dotted(_ base: NSImage, color: NSColor, template: Bool) -> NSImage {
        let img = NSImage(size: base.size, flipped: true) { r in
            base.draw(in: r)
            let c = CGPoint(x: r.width - 2.3, y: 2.3)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.4, y: c.y - 3.4, width: 6.8, height: 6.8)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)).fill()
            return true
        }
        img.isTemplate = template
        return img
    }
    private static let colorFrames = rows.map { makeImage($0, palette: colorPalette, template: false) }
    private static let monoFrames = rows.map { makeImage($0, palette: monoPalette, template: true) }
    private static let colorDotted = dotted(colorFrames[0], color: .systemBlue, template: false)
    private static let monoDotted = dotted(monoFrames[0], color: .black, template: true)
    private static let fps: Double = 5
    /// The still icon for Settings' preview of each style (the mono one is a template: tint it like the menu bar).
    static func preview(_ style: Style) -> NSImage? {
        switch style { case .color: return colorFrames[0]; case .mono: return monoFrames[0]; case .hidden: return nil }
    }

    private var item: NSStatusItem?
    private var style: Style = .color
    private var timer: Timer?
    private var frame = 0
    private var working = 0
    private var waiting = 0

    private var frames: [NSImage] { style == .mono ? Self.monoFrames : Self.colorFrames }
    private var unread = 0
    private var unreadSub: AnyCancellable?
    private let menu = NSMenu()
    /// The still icon: with the dot while there are unread notifications.
    private var restingImage: NSImage { unread > 0 ? (style == .mono ? Self.monoDotted : Self.colorDotted) : frames[0] }

    func sync(state: DaemonState) {
        let newStyle = AppModel.shared.setting("menubar.style")?.string.flatMap(Style.init(rawValue:)) ?? .color
        guard newStyle != .hidden else {
            stopAnimating()
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            style = newStyle
            return
        }
        let restyled = newStyle != style
        style = newStyle
        if item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.imageScaling = .scaleNone
            it.button?.target = self
            it.button?.action = #selector(clicked)
            it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            menu.delegate = self
            item = it
        }
        if unreadSub == nil {
            unreadSub = NotificationCenterModel.shared.$items.receive(on: DispatchQueue.main).sink { [weak self] items in
                guard let self else { return }
                let n = items.reduce(0) { $0 + ($1.read ? 0 : 1) }
                guard n != unread else { return }
                unread = n
                item?.button?.toolTip = tooltip
                if timer == nil { item?.button?.image = restingImage }
            }
        }
        if restyled || item?.button?.image == nil { item?.button?.image = timer == nil ? restingImage : frames[frame] }
        working = state.sessions.filter { $0.activity == .working && $0.state == .running }.count
        waiting = state.sessions.filter { $0.activity == .needsInput && $0.state == .running }.count
        item?.button?.toolTip = tooltip
        if working > 0 { startAnimating() } else { stopAnimating() }
    }

    private var summary: String? {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting for input") }
        if unread > 0 { parts.append("\(unread) unread") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    private var tooltip: String { summary.map { "Octomux — \($0)" } ?? "Octomux" }

    private func startAnimating() {
        guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            frame = (frame + 1) % frames.count
            item?.button?.image = frames[frame]
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAnimating() {
        timer?.invalidate()
        timer = nil
        frame = 0
        item?.button?.image = restingImage
    }

    // MARK: Click

    @objc private func clicked() {
        guard let button = item?.button else { return }
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            closePanel()
            item?.menu = menu
            button.performClick(nil)   // shows the menu
            item?.menu = nil
            return
        }
        if panel != nil { closePanel(); return }
        NotificationCenterModel.shared.refreshAll()
        let host = NSHostingView(rootView: MenuBarPanel { [weak self] in self?.closePanel() }.environmentObject(AppModel.shared))
        let size = host.fittingSize
        let w = MenuPanelWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .popUpMenu
        w.appearance = NSAppearance(named: ThemeStore.shared.isDark ? .darkAqua : .aqua)
        w.contentView = host
        // Under the icon, left edges aligned, kept on screen.
        if let bw = button.window {
            let f = bw.convertToScreen(button.convert(button.bounds, to: nil))
            let vis = bw.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let x = min(max(f.minX - 8, vis.minX + 6), vis.maxX - size.width - 6)
            w.setFrameOrigin(NSPoint(x: x, y: f.minY - size.height - 5))
        }
        w.orderFrontRegardless()
        w.makeKey()
        panel = w
        button.highlight(true)
        // Closes on a click anywhere else, Esc, or when the panel loses key.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePanel() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self, let panel else { return e }
            if e.type == .keyDown, e.keyCode == 53 { closePanel(); return nil }
            if e.type == .leftMouseDown, e.window !== panel, e.window !== item?.button?.window { closePanel() }
            return e
        }
        resignObs = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.closePanel()
        }
    }

    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var resignObs: Any?

    private func closePanel() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObs { NotificationCenter.default.removeObserver(o) }
        outsideMonitor = nil; keyMonitor = nil; resignObs = nil
        panel?.orderOut(nil)
        panel = nil
        item?.button?.highlight(false)
    }

    // Debug (DebugActions "menubar")
    func debugClick() { clicked() }
    var debugImage: NSImage? { item?.button?.image }
    var debugPanelWindow: NSWindow? { panel }
    func debugState() -> [String: Any] { ["unread": unread, "animating": timer != nil, "dot": timer == nil && unread > 0, "panel": panel != nil] }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: summary ?? "No agents working", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Octomux", action: #selector(openWindow), keyEquivalent: "").target = self
        let qc = menu.addItem(withTitle: "Quick Composer" + (GlobalHotKey.shared.registered.map { "  \($0.display)" } ?? ""), action: #selector(quickComposer), keyEquivalent: "")
        qc.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Octomux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func quickComposer() { QuickComposer.shared.show() }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.delegate as? AppDelegate)?.openMainWindow()
    }
}

/// The menu bar panel's window: borderless, can take key (for Esc and to know when to close).
private final class MenuPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}
