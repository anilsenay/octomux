import AppKit
import SwiftUI

/// Octomux's own drop-down panel: borderless, drawn with the app's tokens, under (or over) the control that
/// opened it. Closes with Esc, a click outside (which it swallows, like a menu), or when the window goes away.
/// Simple command menus stay native; this is for pickers that show state (workspaces, keep awake, commit).
final class FloatingPanelController {
    static let shared = FloatingPanelController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private weak var parent: NSWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?
    private var edge: Edge = .bottom
    /// The view that opened the current panel (a second click on it closes instead of reopening).
    private(set) weak var owner: NSView?
    /// Keys go here first (↑ ↓ ↩ in menus); true when handled.
    var onKey: ((NSEvent) -> Bool)?

    var isOpen: Bool { panel != nil }

    func show(from anchor: NSView, edge: Edge, alignment: HorizontalAlignment, content: AnyView, onClose: @escaping () -> Void) {
        close()
        guard let parent = anchor.window else { onClose(); return }
        self.parent = parent
        self.owner = anchor
        self.onClose = onClose
        self.edge = edge
        let host = NSHostingView(rootView: AnyView(content
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size, initial: false) { _, s in FloatingPanelController.shared.resize(to: s) }
            })
            .environmentObject(AppModel.shared)))
        let size = host.fittingSize
        let r = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x = alignment == .trailing ? r.maxX - size.width : alignment == .center ? r.midX - size.width / 2 : r.minX
        let y = edge == .top ? r.maxY + 6 : r.minY - 6 - size.height
        if let vf = parent.screen?.visibleFrame { x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8) }
        let p = Panel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = parent.level   // above its window only (a child window), never over other apps
        p.isReleasedWhenClosed = false
        p.contentView = host
        parent.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)
        p.invalidateShadow()
        panel = p

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel != nil else { return e }
            if e.keyCode == 53 { self.close(); return nil }   // Esc
            if self.onKey?(e) == true { return nil }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, let p = self.panel else { return e }
            if e.window === p { return e }
            self.close()
            return nil   // the click that closes a menu does nothing else
        } as Any)
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.close() }) {
            monitors.append(g)
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            // Another window of ours took the keys (not a sheet or alert this panel opened).
            DispatchQueue.main.async { if NSApp.keyWindow !== self?.panel, NSApp.modalWindow == nil { self?.close() } }
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.close() })
    }

    /// Follows the content's size; the edge next to the control stays put.
    fileprivate func resize(to s: CGSize) {
        guard let p = panel, s.width > 0, s.height > 0 else { return }
        var f = p.frame
        if edge == .bottom { f.origin.y = f.maxY - s.height }
        f.size = s
        p.setFrame(f, display: true)
        p.invalidateShadow()
    }

    /// Debug: the open panel drawn to a PNG, and where it sits on screen (AppKit coordinates).
    func snapshot(to path: String) -> [String: Any]? {
        guard let p = panel, let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: URL(fileURLWithPath: path))
        let f = p.frame
        return ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "screen_h": NSScreen.screens.first?.frame.height ?? 0]
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        onKey = nil
        owner = nil
        if let p = panel {
            panel = nil
            parent?.removeChildWindow(p)
            p.orderOut(nil)
            if let parent, parent.isVisible { parent.makeKey() }
        }
        let c = onClose
        onClose = nil
        c?()
    }
}

/// Puts a floating panel under (`.bottom`) or over (`.top`) this view while `isPresented` is true.
private struct FloatingPanelAnchor<C: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let edge: Edge
    let alignment: HorizontalAlignment
    let content: () -> C

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let c = FloatingPanelController.shared
        if isPresented, c.owner !== v {
            let binding = $isPresented
            DispatchQueue.main.async {
                guard binding.wrappedValue else { return }
                c.show(from: v, edge: edge, alignment: alignment, content: AnyView(content())) { binding.wrappedValue = false }
            }
        } else if !isPresented, c.owner === v {
            DispatchQueue.main.async { if c.owner === v { c.close() } }
        }
    }
}

extension View {
    func floatingPanel<C: View>(isPresented: Binding<Bool>, edge: Edge = .bottom, alignment: HorizontalAlignment = .leading,
                                @ViewBuilder content: @escaping () -> C) -> some View {
        background(FloatingPanelAnchor(isPresented: isPresented, edge: edge, alignment: alignment, content: content))
    }
}

extension Notification.Name {
    /// Debug: opens a floating panel by name (DebugActions "open_panel").
    static let octomuxDebugOpenPanel = Notification.Name("octomux.debugOpenPanel")
}

extension View {
    /// Debug builds: opens this panel when DebugActions asks for `name`.
    func debugOpens(_ name: String, _ open: Binding<Bool>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .octomuxDebugOpenPanel)) { n in
            if n.object as? String == name { open.wrappedValue = true }
        }
    }
}

// MARK: - Look

/// The panel's card: raised fill, hairline edge, the app's radius (the window draws the shadow).
struct PanelCard<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(5)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.border))
            .clipShape(RoundedRectangle(cornerRadius: R.xl, style: .continuous))
    }
}

struct PanelSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6).foregroundStyle(T.text3)
            .padding(.horizontal, 9).padding(.top, 7).padding(.bottom, 3)
    }
}

struct PanelDivider: View {
    var body: some View { Rectangle().fill(T.border).frame(height: 1).padding(.horizontal, 4).padding(.vertical, 4) }
}

/// One row of a panel menu: icon, title, detail, shortcut or check; highlighted by the pointer or the keys.
struct PanelRow<Icon: View>: View {
    let title: String
    var detail: String? = nil
    var detailColor: Color = T.text3
    var shortcut: String? = nil
    var checked = false
    var highlighted = false
    var enabled = true
    @ViewBuilder var icon: () -> Icon
    var body: some View {
        HStack(spacing: 8) {
            icon().frame(width: 16)
            Text(title).font(.system(size: T.k * 13, weight: checked ? .semibold : .regular))
                .foregroundStyle(enabled ? T.text : T.text3).lineLimit(1)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(T.meta).foregroundStyle(detailColor).lineLimit(1) }
            if let shortcut { ShortcutHint(shortcut) }
            if checked { Image(systemName: "checkmark").font(T.icon(10, .bold)).foregroundStyle(T.accent) }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(highlighted && enabled ? T.hover : .clear))
        .contentShape(Rectangle())
    }
}

extension PanelRow where Icon == EmptyView {
    init(title: String, detail: String? = nil, shortcut: String? = nil, checked: Bool = false, highlighted: Bool = false, enabled: Bool = true) {
        self.init(title: title, detail: detail, shortcut: shortcut, checked: checked, highlighted: highlighted, enabled: enabled) { EmptyView() }
    }
}

/// Keyboard and pointer highlight for a panel's rows: ↑ ↓ move, ↩ / Space choose.
final class PanelNav: ObservableObject {
    @Published var index: Int?
    private var actions: [() -> Void] = []

    func set(_ actions: [() -> Void]) { self.actions = actions }

    func attach() {
        FloatingPanelController.shared.onKey = { [weak self] e in
            guard let self, !self.actions.isEmpty else { return false }
            switch e.keyCode {
            case 125: self.index = min((self.index ?? -1) + 1, self.actions.count - 1); return true
            case 126: self.index = max((self.index ?? self.actions.count) - 1, 0); return true
            case 36, 76, 49:
                guard let i = self.index, i < self.actions.count else { return false }
                self.run(i); return true
            default: return false
            }
        }
    }

    func run(_ i: Int) {
        let a = actions[i]
        FloatingPanelController.shared.close()
        a()
    }
}

/// A small pill choice ("1 hour", "4 hours"): filled when on.
struct PanelChip: View {
    let title: String
    var on = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: T.k * 11, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? T.text : T.text2)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(on ? T.selection : hover ? T.hover : T.text.opacity(0.05)))
                .overlay(Capsule().stroke(on ? T.accent.opacity(0.5) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.pointerCursor()
    }
}
