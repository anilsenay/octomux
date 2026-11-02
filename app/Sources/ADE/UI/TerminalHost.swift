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
        if let doc = model.activeDoc {
            DocHost.shared.activeChanged(doc.id)
            if !force, renderedDocId == doc.id { return }
            renderedDocId = doc.id
            renderedTabId = nil
            renderedLayout = nil
            container.subviews.forEach { $0.removeFromSuperview() }
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
            layer.backgroundColor = m.glass ? NSColor.clear.cgColor : WorkspaceTint.canvas(dark: dark).cgColor
            layer.borderColor = (focused ? T.ns(\.accent).withAlphaComponent(0.55) : T.ns(\.border)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
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
        if let s = model.session(sessionId) {
            HStack(spacing: 7) {
                Image(systemName: "circle.grid.2x3.fill").font(.system(size: 7.5)).foregroundStyle(T.text3.opacity(hover ? 0.9 : 0.45))
                    .frame(width: 8).help("Drag to move this pane")
                AgentIcon(icon: iconName(for: s, model: model), size: 11).opacity(focused ? 1 : 0.6)
                Text(s.displayTitle)
                    .font(.system(size: 12, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? T.text : T.text3)
                    .lineLimit(1).truncationMode(.tail)
                ActivityIndicator(session: s)
                Spacer(minLength: 6)
                Group {
                    if model.canChat(s) {
                        Button { model.toggleChat(s.id) } label: { Image(systemName: model.isChat(s.id) ? "terminal" : "text.bubble") }
                            .help(model.isChat(s.id) ? "Show terminal" : "Show as chat")
                    }
                    Menu { SessionMenu(session: s) } label: { Image(systemName: "ellipsis").menuHitBox(20, 20) }
                        .plainMenu().frame(width: 20, height: 20).help("Session")
                    Button { model.remove(s.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .help("Close pane (⌘W)")
                }
                .buttonStyle(IconButtonStyle(size: 20))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(T.text3)
                .opacity(hover || focused ? 1 : 0)
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(focused ? T.hover : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { model.selectSession(s.id) }
            .onDrag {
                DragItem.current = ("pane", s.id)
                return NSItemProvider(object: "ade-pane:\(s.id)" as NSString)
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
            Button("Move to New Tab") { model.movePaneToNewTab(session.id) }
        }
        Divider()
        SessionMenu(session: session)
    }
}
