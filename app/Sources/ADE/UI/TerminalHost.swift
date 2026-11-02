import AppKit
import SwiftUI

/// Owns the terminal surfaces (one per running session) and renders the active
/// tab's pane tree into a container view. Surfaces are cached so switching tabs
/// or workspaces never re-attaches.
final class TerminalHost {
    static let shared = TerminalHost()

    let container = PaneContainerView()
    let dockContainer = PaneContainerView()
    private var renderedDock: (String?, SessionState?)?
    private var surfaces: [String: TerminalSurfaceView] = [:]
    private var renderedTabId: String?
    private var renderedLayout: PaneNode?
    private var renderedStates: [String: SessionState] = [:]

    var model: AppModel { AppModel.shared }

    func surface(for session: Session) -> TerminalSurfaceView {
        if let s = surfaces[session.id], s.surface != nil { return s }
        let v = TerminalSurfaceView(
            sessionId: session.id,
            command: model.host(for: session.id).attachCommand(session.id),
            env: ["ADE_HOME": Paths.home.path],
            workingDirectory: model.host(for: session.id).isRemote ? NSHomeDirectory() : session.cwd)
        v.onFocus = { [weak self] in
            self?.model.sessionFocused(session.id)
            self?.updateFocusRings(session.id)
        }
        v.onProcessExit = { [weak self, weak v] in
            // `ade attach` ended: the session exited, was stopped, or removed.
            guard let self, let v else { return }
            if self.surfaces[session.id] === v {
                self.surfaces.removeValue(forKey: session.id)
                TerminalRegistry.shared.remove(session.id)
                v.close()
                self.render(force: true)
                self.renderDock(force: true)
            }
        }
        surfaces[session.id] = v
        TerminalRegistry.shared.add(v)
        return v
    }

    /// Drops every surface (host switch).
    func closeAll() {
        for (id, v) in surfaces {
            TerminalRegistry.shared.remove(id)
            v.removeFromSuperview()
            v.close()
        }
        surfaces.removeAll()
        render(force: true)
        renderDock(force: true)
    }

    /// Called whenever daemon state changes.
    func reconcile(with state: DaemonState) {
        let live = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.id, $0) })
        for (id, v) in surfaces {
            guard let s = live[id], s.state == .running || s.state == .interrupted else {
                surfaces.removeValue(forKey: id)
                TerminalRegistry.shared.remove(id)
                v.removeFromSuperview()
                v.close()
                continue
            }
        }
        render()
        renderDock()
    }

    /// Shows the selected dock session of the current project.
    func renderDock(force: Bool = false, focus: Bool = false) {
        let pid = model.currentProject?.id
        let selId = model.isDockOpen(pid) ? model.dockSelection(pid) : nil
        let sel = model.session(selId)
        let key = (selId, sel?.state)
        if !force, let r = renderedDock, r.0 == key.0, r.1 == key.1 { return }
        renderedDock = key
        dockContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let s = sel else { return }
        let pane = PaneView(sessionId: s.id)
        if s.state == .running || s.state == .interrupted {
            let v = surface(for: s)
            pane.setContent(v)
            if focus { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
        } else {
            pane.setContent(NSHostingView(rootView: DormantPaneView(sessionId: s.id).environmentObject(model)))
        }
        dockContainer.setRoot(pane)
    }

    func render(force: Bool = false) {
        let tab = model.activeTab
        let states = Dictionary(uniqueKeysWithValues: (tab?.layout.sessions ?? []).compactMap { id in model.session(id).map { (id, $0.state) } })
        if !force, tab?.id == renderedTabId, tab?.layout == renderedLayout, states == renderedStates { return }
        renderedTabId = tab?.id
        renderedLayout = tab?.layout
        renderedStates = states
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let tab else {
            container.showEmpty()
            return
        }
        let root = build(tab.layout, tabId: tab.id, path: [])
        container.setRoot(root)
        updateFocusRings(model.focusedSessionId)
        DispatchQueue.main.async { self.focusCurrent() }
    }

    private func build(_ node: PaneNode, tabId: String, path: [Bool]) -> NSView {
        switch node {
        case .leaf(let id):
            guard let s = model.session(id) else { return PlaceholderPane(text: "Session missing") }
            let pane = PaneView(sessionId: id)
            if (s.state == .running || s.state == .interrupted) && model.isChat(id) && model.canChat(s) {
                _ = surface(for: s)   // keep the terminal attached while the chat shows
                pane.setContent(NSHostingView(rootView: ChatView(sessionId: id).environmentObject(model)))
            } else if s.state == .running || s.state == .interrupted {
                pane.setContent(surface(for: s))
            } else {
                pane.setContent(NSHostingView(rootView: DormantPaneView(sessionId: id).environmentObject(model)))
            }
            return pane
        case .split(let dir, let ratio, let a, let b):
            let split = RatioSplitView()
            split.isVertical = dir == .right
            split.dividerStyle = .thin
            split.addArrangedSubview(build(a, tabId: tabId, path: path + [false]))
            split.addArrangedSubview(build(b, tabId: tabId, path: path + [true]))
            split.ratio = ratio
            split.onRatioChange = { [weak self] r in
                guard let self, let tab = self.model.state.tabs.first(where: { $0.id == tabId }) else { return }
                let newLayout = tab.layout.withRatio(path: path, ratio: r)
                self.renderedLayout = newLayout
                self.model.updateLayout(tabId: tabId, layout: newLayout)
            }
            return split
        }
    }

    /// Accent border on the focused pane when a tab shows more than one pane.
    func updateFocusRings(_ focusedId: String?) {
        func walk(_ v: NSView, _ out: inout [PaneView]) {
            if let p = v as? PaneView { out.append(p) }
            for s in v.subviews where !(s is TerminalSurfaceView) { walk(s, &out) }
        }
        var panes: [PaneView] = []
        walk(container, &panes)
        for p in panes { p.focused = panes.count > 1 && p.sessionId == focusedId }
    }

    func focusCurrent() {
        render()
        guard let id = model.focusedSessionId, let v = surfaces[id], v.window != nil else { return }
        if v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) }
    }

    func focusNeighbor(_ dir: NSRectEdge) {
        guard let tab = model.activeTab, let cur = model.focusedSessionId, let curView = surfaces[cur], let win = curView.window else { return }
        let curFrame = curView.convert(curView.bounds, to: nil)
        var best: (String, CGFloat)?
        for id in tab.layout.sessions where id != cur {
            guard let v = surfaces[id] else { continue }
            let f = v.convert(v.bounds, to: nil)
            let ok: Bool
            switch dir {
            case .minX: ok = f.maxX <= curFrame.minX + 2
            case .maxX: ok = f.minX >= curFrame.maxX - 2
            case .minY: ok = f.maxY <= curFrame.minY + 2
            default: ok = f.minY >= curFrame.maxY - 2
            }
            guard ok else { continue }
            let d = hypot(f.midX - curFrame.midX, f.midY - curFrame.midY)
            if best == nil || d < best!.1 { best = (id, d) }
        }
        if let (id, _) = best, let v = surfaces[id] { win.makeFirstResponder(v) }
    }

    /// Grid estimate for new sessions so programs start at roughly the right size.
    func estimatedGrid() -> (cols: Int, rows: Int)? {
        if let id = model.focusedSessionId, let v = surfaces[id] {
            let g = v.gridSize
            if g.cols > 0 { return (g.cols, g.rows) }
        }
        let b = container.bounds
        guard b.width > 50 else { return nil }
        return (Int(b.width / 8.5), Int(b.height / 17))
    }
}

/// Root of the terminal area.
final class PaneContainerView: NSView {
    private var empty: NSView?

    func setRoot(_ v: NSView) {
        empty?.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func showEmpty() {
        let v = NSHostingView(rootView: EmptyStateView().environmentObject(AppModel.shared))
        empty = v
        setRoot(v)
        empty = v
    }
}

/// One pane: a rounded card (per theme) holding a terminal or a dormant view.
final class PaneView: NSView {
    let sessionId: String
    var focused = false { didSet { if focused != oldValue { needsDisplay = true; updateLayer() } } }

    init(sessionId: String) {
        self.sessionId = sessionId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let m = T.m
        layer.cornerRadius = m.cardR
        layer.borderWidth = m.cardR > 0 ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = T.ns(\.surface).cgColor
            layer.borderColor = (focused ? T.ns(\.accent).withAlphaComponent(0.55) : T.ns(\.border)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    func setContent(_ v: NSView) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

final class PlaceholderPane: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: centerXAnchor), l.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Split view that applies a stored ratio once laid out and reports drags.
final class RatioSplitView: NSSplitView, NSSplitViewDelegate {
    var ratio: Double = 0.5
    var onRatioChange: ((Double) -> Void)?
    private var applied = false
    private var debounce: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    // Cards themes: a gap in the frame color. Flat themes: a hairline.
    override var dividerThickness: CGFloat { T.m.inset > 0 ? T.m.inset : 1 }
    override var dividerColor: NSColor { T.m.inset > 0 ? T.ns(\.frame) : T.ns(\.border) }

    override func layout() {
        super.layout()
        let total = isVertical ? bounds.width : bounds.height
        if !applied, total > 10, arrangedSubviews.count == 2 {
            applied = true
            setPosition(total * ratio, ofDividerAt: 0)
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard applied, arrangedSubviews.count == 2, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 10 else { return }
        let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let r = max(0.1, min(0.9, Double(first / total)))
        guard abs(r - ratio) > 0.01 else { return }
        ratio = r
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onRatioChange?(r) }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}

extension String {
    var shellQuoted: String {
        if !isEmpty && allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,@+%".contains($0) }) { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
