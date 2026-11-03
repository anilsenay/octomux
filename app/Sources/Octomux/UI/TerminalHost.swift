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
    private var renderedDocId: String?
    private var renderedLayout: PaneNode?
    private var renderedStates: [String: SessionState] = [:]

    var model: AppModel { AppModel.shared }

    func surface(for session: Session) -> TerminalSurfaceView {
        if let s = surfaces[session.id], s.surface != nil { return s }
        let v = TerminalSurfaceView(
            sessionId: session.id,
            command: model.host(for: session.id).attachCommand(session.id),
            env: [Paths.homeVar: Paths.home.path],
            workingDirectory: model.host(for: session.id).isRemote ? NSHomeDirectory() : session.cwd)
        v.onFocus = { [weak self] in
            self?.model.sessionFocused(session.id)
            self?.updateFocusRings(session.id)
        }
        v.onProcessExit = { [weak self, weak v] in
            // `octomux attach` ended: the session exited, was stopped, or removed.
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

    private var renderedZoom: String?

    func render(force: Bool = false) {
        if let doc = model.activeDoc {
            DocHost.shared.activeChanged(doc.id)
            if !force, renderedDocId == doc.id { return }
            renderedDocId = doc.id
            renderedTabId = nil
            renderedLayout = nil
            container.subviews.forEach { $0.removeFromSuperview() }
            if case .newChat = doc.kind {
                let pane = PaneView(sessionId: "")
                pane.setContent(NSHostingView(rootView: NewChatView(docId: doc.id).environmentObject(model)))
                container.setRoot(pane)
                return
            }
            let pane = PaneView(sessionId: "")
            let web = DocHost.shared.controller(for: doc).web
            web.removeFromSuperview()
            pane.setContent(web)
            container.setRoot(pane)
            DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
            return
        }
        if renderedDocId != nil { renderedDocId = nil; DocHost.shared.activeChanged(nil); renderedTabId = "\u{0}" }
        let tab = model.activeTab
        let states = Dictionary(uniqueKeysWithValues: (tab?.layout.sessions ?? []).compactMap { id in model.session(id).map { (id, $0.state) } })
        // Focusing another pane of a zoomed tab (sidebar, ⌥⌘arrows) brings the split back.
        if let tab, let z = model.zoomedPane(in: tab), let f = model.focusedSessionId, f != z, tab.layout.sessions.contains(f) {
            DispatchQueue.main.async { self.model.zoomedPanes[tab.id] = nil }
        }
        let zoomed = model.zoomedPane(in: tab)
        if !force, tab?.id == renderedTabId, tab?.layout == renderedLayout, states == renderedStates, zoomed == renderedZoom { return }
        // Zoom toggled on the tab already on screen: animate the pane between its slot and full size.
        if let tab, tab.id == renderedTabId, tab.layout == renderedLayout, states == renderedStates, zoomed != renderedZoom,
           let id = zoomed ?? renderedZoom, animateZoom(tab: tab, sessionId: id, zoomIn: zoomed != nil) {
            renderedZoom = zoomed
            return
        }
        renderedZoom = zoomed
        renderedTabId = tab?.id
        renderedLayout = tab?.layout
        renderedStates = states
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let tab else {
            container.showEmpty()
            return
        }
        let root = build(zoomed.map { PaneNode.leaf(sessionId: $0) } ?? tab.layout, tabId: tab.id, path: [])
        container.setRoot(root)
        updateFocusRings(model.focusedSessionId)
        DispatchQueue.main.async { self.focusCurrent() }
    }

    private var zoomAnimation = 0

    /// Zoom in: the pane grows from its slot to the whole area, over the split (which then goes away).
    /// Zoom out: the split comes back underneath and the pane shrinks from full size into its slot.
    /// The terminal view itself moves between the two pane cards, so it never goes blank.
    private func animateZoom(tab: Tab, sessionId id: String, zoomIn: Bool) -> Bool {
        guard container.bounds.width > 0, container.window != nil else { return false }
        zoomAnimation += 1
        let gen = zoomAnimation
        let full = container.bounds
        let old = container.subviews

        func slotRect() -> NSRect? {
            container.layoutSubtreeIfNeeded()
            var found: PaneView?
            func walk(_ v: NSView) {
                if found == nil, let p = v as? PaneView, p.sessionId == id { found = p }
                for c in v.subviews where !(c is TerminalSurfaceView) { walk(c) }
            }
            for v in container.subviews { walk(v) }
            return found.map { $0.convert($0.bounds, to: container) }
        }

        var from: NSRect, to: NSRect
        if zoomIn {
            guard let r = slotRect() else { return false }
            from = r; to = full
        } else {
            old.forEach { $0.removeFromSuperview() }
            let root = build(tab.layout, tabId: tab.id, path: [])
            container.setRoot(root)
            guard let r = slotRect() else { return false }
            from = full; to = r
        }
        let pane = build(.leaf(sessionId: id), tabId: tab.id, path: [])   // takes the terminal out of its slot
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        let c = (l: pane.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: from.minX),
                 t: pane.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: from.maxX - full.width),
                 top: pane.topAnchor.constraint(equalTo: container.topAnchor, constant: full.height - from.maxY),
                 b: pane.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -from.minY))
        NSLayoutConstraint.activate([c.l, c.t, c.top, c.b])
        (pane as? PaneView)?.focused = true
        container.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            c.l.animator().constant = to.minX
            c.t.animator().constant = to.maxX - full.width
            c.top.animator().constant = full.height - to.maxY
            c.b.animator().constant = -to.minY
            container.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, gen == self.zoomAnimation else { return }
            if zoomIn {
                // Keep the grown pane as the tab's root; drop the split under it.
                old.forEach { $0.removeFromSuperview() }
                NSLayoutConstraint.deactivate([c.l, c.t, c.top, c.b])
                pane.removeFromSuperview()
                self.container.setRoot(pane)
                self.updateFocusRings(self.model.focusedSessionId)
                self.focusCurrent()
            } else {
                self.render(force: true)   // puts the terminal back into its slot
            }
        })
        return true
    }

    private func build(_ node: PaneNode, tabId: String, path: [Bool]) -> NSView {
        switch node {
        case .leaf(let id):
            guard let s = model.session(id) else { return PlaceholderPane(text: "Session missing") }
            let pane = PaneView(sessionId: id)
            // Split tabs get a title bar per pane (which session, close, chat toggle).
            let header: NSView? = (model.state.tabs.first { $0.id == tabId }?.layout.sessions.count ?? 1) > 1
                ? PaneHeaderHost(rootView: AnyView(PaneHeader(sessionId: id).environmentObject(model))) : nil
            if (s.state == .running || s.state == .interrupted) && model.isChat(id) && model.canChat(s) {
                _ = surface(for: s)   // keep the terminal attached while the chat shows
                pane.setContent(NSHostingView(rootView: ChatView(sessionId: id).environmentObject(model)), header: header)
            } else if s.state == .running || s.state == .interrupted {
                pane.setContent(surface(for: s), header: header)
            } else {
                pane.setContent(NSHostingView(rootView: DormantPaneView(sessionId: id).environmentObject(model)), header: header)
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

    /// Repaints pane backgrounds (workspace tint changed).
    func refreshPaneBackgrounds() {
        func walk(_ v: NSView) {
            if let p = v as? PaneView { p.needsDisplay = true }
            for s in v.subviews where !(s is TerminalSurfaceView) { walk(s) }
        }
        walk(container)
        walk(dockContainer)
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
        if model.activeDoc != nil { return }
        guard let id = model.focusedSessionId, let v = surfaces[id], v.window != nil else { return }
        if v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) }
    }

    func focusNeighbor(_ dir: NSRectEdge) {
        guard let tab = model.activeTab, model.zoomedPane(in: tab) == nil,
              let cur = model.focusedSessionId, let curView = surfaces[cur], let win = curView.window else { return }
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
        // Same rounded card as a terminal pane, so the empty state sits in the layout like one.
        let card = PaneView(sessionId: "")
        card.setContent(NSHostingView(rootView: EmptyStateView().environmentObject(AppModel.shared)))
        empty = card
        setRoot(card)
        empty = card
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
        if !sessionId.isEmpty { registerForDraggedTypes([.string]) }
    }

    // MARK: Drop target (pane headers, top-bar tabs, sidebar sessions)

    private var dropOverlay: NSView?
    private var dropEdge: AppModel.PaneEdge?

    /// What is being dragged, if this pane can take it.
    private func droppable() -> (kind: String, id: String)? {
        guard let d = DragItem.current else { return nil }
        let m = AppModel.shared
        switch d.kind {
        case "pane": return d.id != sessionId ? ("pane", d.id) : nil
        case "tab": return m.state.tabs.first { $0.id == d.id }.map { !$0.layout.sessions.contains(sessionId) } == true ? ("tab", d.id) : nil
        case let k where k.hasPrefix("session:"):
            return d.id != sessionId && m.session(d.id)?.placement == .tab ? ("pane", d.id) : nil
        default: return nil
        }
    }

    /// Nearest edge to the pointer (the pane is split in four triangles).
    private func edge(at p: NSPoint) -> AppModel.PaneEdge {
        let x = p.x / max(1, bounds.width), y = p.y / max(1, bounds.height)   // y up
        let d = [(AppModel.PaneEdge.left, x), (.right, 1 - x), (.bottom, y), (.top, 1 - y)]
        return d.min { $0.1 < $1.1 }!.0
    }

    /// Debug channel: shows the drop highlight without a drag.
    func debugShowDrop(_ e: AppModel.PaneEdge?) { if let e { showDrop(e) } else { hideDrop() } }

    private func showDrop(_ e: AppModel.PaneEdge) {
        guard e != dropEdge || dropOverlay == nil else { return }
        dropEdge = e
        let o = dropOverlay ?? {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = max(4, T.m.cardR - 2)
            v.layer?.borderWidth = 2
            addSubview(v, positioned: .above, relativeTo: nil)
            dropOverlay = v
            return v
        }()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            o.layer?.backgroundColor = T.ns(\.blue).withAlphaComponent(0.18).cgColor
            o.layer?.borderColor = T.ns(\.blue).withAlphaComponent(0.8).cgColor
        }
        let b = bounds.insetBy(dx: 4, dy: 4)
        let half: NSRect
        switch e {
        case .left: half = NSRect(x: b.minX, y: b.minY, width: b.width / 2, height: b.height)
        case .right: half = NSRect(x: b.midX, y: b.minY, width: b.width / 2, height: b.height)
        case .top: half = NSRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)
        case .bottom: half = NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height / 2)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            o.animator().frame = half
        }
    }

    private func hideDrop() {
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
        dropEdge = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppable() != nil else { hideDrop(); return [] }
        showDrop(edge(at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let e = dropEdge ?? edge(at: convert(sender.draggingLocation, from: nil))
        hideDrop()
        guard let d = droppable() else { return false }
        DragItem.current = nil
        AppModel.shared.drop(kind: d.kind, id: d.id, onPane: sessionId, edge: e)
        return true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let m = T.m
        layer.cornerRadius = m.cardR
        layer.borderWidth = m.cardR > 0 ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer.backgroundColor = ThemeStore.shared.transparentPanes ? NSColor.clear.cgColor : WorkspaceTint.canvas(dark: dark).cgColor
            updateSceneBacking()
            layer.borderColor = (focused ? WorkspaceTint.accent(dark: dark).withAlphaComponent(dark ? 0.6 : 0.7) : T.ns(\.border)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    // What the pane shows behind a translucent terminal: the window's live backdrop (nothing here),
    // the scene's gradient only, or a still frame of the scene drawn for this pane.
    private var sceneGradient: CAGradientLayer?
    private var sceneStill: SceneLayerView?

    private func updateSceneBacking() {
        let store = ThemeStore.shared
        let mode = store.terminalSceneMode
        let scene = store.activeScene
        if mode == .color, let scene {
            let g = sceneGradient ?? {
                let g = CAGradientLayer()
                layer?.insertSublayer(g, at: 0)
                sceneGradient = g
                return g
            }()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            g.colors = [NSColor(scene.bottom).cgColor, NSColor(scene.top).cgColor]
            g.frame = bounds
            CATransaction.commit()
        } else {
            sceneGradient?.removeFromSuperlayer(); sceneGradient = nil
        }
        if mode == .still, let scene {
            if let v = sceneStill { v.set(scene) } else {
                let v = SceneLayerView(scene: scene, still: false, frozen: true)
                v.frame = bounds
                v.autoresizingMask = [.width, .height]
                addSubview(v, positioned: .below, relativeTo: subviews.first)
                sceneStill = v
            }
        } else {
            sceneStill?.removeFromSuperview(); sceneStill = nil
        }
    }

    override func layout() {
        super.layout()
        if let g = sceneGradient, g.frame != bounds {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            g.frame = bounds
            CATransaction.commit()
        }
    }

    /// Fills the pane with `v`; with a `header`, the header sits on top (split tabs) and `v` below it.
    func setContent(_ v: NSView, header: NSView? = nil) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        var top = topAnchor
        if let header {
            header.translatesAutoresizingMaskIntoConstraints = false
            addSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
                header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: PaneHeader.height),
            ])
            top = header.bottomAnchor
        }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: top), v.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    /// The size the ratio was last applied at. The ratio is re-applied whenever the split's size changes:
    /// a nested split is first laid out before its parent settles (applied once, it kept that tiny
    /// position and a third pane opened as a sliver); window resizes keep the proportions too.
    private var appliedTotal: CGFloat = 0
    private var applying = false
    private var debounce: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    // Cards themes: an empty gap, so the window background (workspace tint, glass, scene) shows between
    // the cards like around them; a flat fill here read as a line. Flat themes: a hairline.
    override var dividerThickness: CGFloat { T.m.inset > 0 ? T.m.inset : 1 }
    override var dividerColor: NSColor { T.m.inset > 0 ? .clear : T.ns(\.border) }
    override func drawDivider(in rect: NSRect) {
        if T.m.inset > 0 { return }
        super.drawDivider(in: rect)
    }

    override func layout() {
        super.layout()
        let total = isVertical ? bounds.width : bounds.height
        guard !applying, total > 10, arrangedSubviews.count == 2 else { return }
        appliedTotal = total
        // Whatever moved the divider (a nested split laid out before its parent settled, a window resize),
        // put it back where the ratio says. A drag updates `ratio` first, so it is not fought.
        let expected = (total - dividerThickness) * ratio
        let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        guard abs(first - expected) > 1.5 else { return }
        applying = true
        setPosition(expected, ofDividerAt: 0)
        applying = false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drags change the ratio, not our own re-application.
        guard !applying, appliedTotal > 0, arrangedSubviews.count == 2, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        // AppKit also moves the divider (with a divider index) while a new nested split settles; taken as a
        // drag, that stored the tiny first size as the ratio (clamped to 0.1) and the pane stayed a sliver.
        // Only a mouse drag on the divider counts.
        guard let e = NSApp.currentEvent, e.type == .leftMouseDragged || e.type == .leftMouseUp, e.window === window else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 10 else { return }
        let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let r = max(0.1, min(0.9, Double(first / max(1, total - dividerThickness))))
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

final class PaneHeaderHost: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Title bar of one pane in a split tab: icon, title, activity; chat toggle and close on the right.
struct PaneHeader: View {
    static let height: CGFloat = 30
    @EnvironmentObject var model: AppModel
    let sessionId: String
    @State private var hover = false

    var body: some View {
        let focused = model.focusedSessionId == sessionId
        let zoomed = model.isZoomed(sessionId)
        if let s = model.session(sessionId) {
            GeometryReader { g in
            // Narrow panes keep their title: the split buttons stay in the … and right-click menus.
            let roomy = g.size.width >= 300
            HStack(spacing: 7) {
                Image(systemName: "circle.grid.2x3.fill").font(.system(size: 7.5)).foregroundStyle(T.text3.opacity(hover ? 0.9 : 0.45))
                    .frame(width: 8).help("Drag to move this pane")
                AgentIcon(icon: iconName(for: s, model: model), size: 11).opacity(focused ? 1 : 0.6)
                Text(s.displayTitle)
                    .layoutPriority(1)
                    .font(.system(size: 12, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? T.text : T.text3)
                    .lineLimit(1).truncationMode(.tail)
                ActivityIndicator(session: s)
                Spacer(minLength: 6)
                Group {
                    if s.placement == .tab && !zoomed && roomy {
                        Button { model.selectSession(s.id); model.newSession(profileId: nil, split: .right) } label: { Image(systemName: "rectangle.split.2x1") }
                            .help("Split Right (⌘D)")
                        Button { model.selectSession(s.id); model.newSession(profileId: nil, split: .down) } label: { Image(systemName: "rectangle.split.1x2") }
                            .help("Split Down (⇧⌘D)")
                    }
                    Button { model.toggleZoom(s.id) } label: {
                        Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(zoomed ? T.accent : T.text3)
                    }
                    .help(zoomed ? "Restore split (⇧⌘↩)" : "Zoom pane (⇧⌘↩)")
                    .background(zoomed ? RoundedRectangle(cornerRadius: 5, style: .continuous).fill(T.accent.opacity(0.15)) : nil)
                    if model.canChat(s) {
                        Button { model.toggleChat(s.id) } label: { Image(systemName: model.isChat(s.id) ? "terminal" : "text.bubble") }
                            .help(model.isChat(s.id) ? "Show terminal" : "Show as chat")
                    }
                    Menu { SessionMenu(session: s) } label: { Image(systemName: "ellipsis").menuHitBox(20, 20) }
                        .plainMenu().frame(width: 20, height: 20)
                        .hoverHighlight(radius: 5).help("Session")
                    Button { model.remove(s.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .help("Close pane (⌘W)")
                }
                .buttonStyle(IconButtonStyle(size: 20))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(T.text3)
                .opacity(hover || focused || zoomed ? 1 : 0)
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(width: g.size.width, height: g.size.height)
            }
            .background(focused ? T.hover : Color.clear)
            // Over a translucent terminal (glass, scene behind terminals) the header gets the terminal's own
            // tint, else it would show the window background at full strength and read as a separate band.
            .background(ThemeStore.shared.terminalBackgroundOpacity.map { Color(nsColor: WorkspaceTint.canvas(dark: ThemeStore.shared.isDark)).opacity($0) })
            .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .grabCursor()
            .onTapGesture { model.selectSession(s.id) }
            .onDrag {
                DragItem.current = ("pane", s.id)
                NSCursor.closedHand.set()
                return NSItemProvider(object: "octomux-pane:\(s.id)" as NSString)
            } preview: {
                PaneDragPreview(session: s)
            }
            .contextMenu { PaneMenuItems(session: s) }
        }
    }
}

/// The chip shown under the pointer while a pane or tab is dragged.
struct PaneDragPreview: View {
    let session: Session
    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(icon: iconName(for: session, model: AppModel.shared), size: 11)
            Text(session.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.accent.opacity(0.7)))
        .foregroundStyle(T.text)
    }
}

/// Pane context menu (header and terminal right-click share these actions).
struct PaneMenuItems: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        Button("Split Right") { model.selectSession(session.id); model.newSession(profileId: nil, split: .right) }
        Button("Split Down") { model.selectSession(session.id); model.newSession(profileId: nil, split: .down) }
        if (model.tab(containing: session.id)?.layout.sessions.count ?? 1) > 1 {
            Button(model.isZoomed(session.id) ? "Restore Split" : "Zoom Pane") { model.toggleZoom(session.id) }
            Button("Move to New Tab") { model.movePaneToNewTab(session.id) }
        }
        Divider()
        SessionMenu(session: session)
    }
}
