import AppKit
import Foundation

/// Moving panes between and within tabs (drag and drop, context menus), and closing groups of tabs.
extension AppModel {
    enum PaneEdge: String { case left, right, top, bottom }

    /// Something dragged (a pane header, a top-bar tab, a sidebar session) dropped on `target`'s `edge`.
    func drop(kind: String, id: String, onPane target: String, edge: PaneEdge) {
        let moving: [String]
        if kind == "tab" {
            guard let t = state.tabs.first(where: { $0.id == id }), !t.layout.sessions.contains(target) else { return }
            moving = t.layout.sessions
        } else {
            guard id != target, session(id)?.placement == .tab else { return }
            moving = [id]
        }
        guard let first = moving.first else { return }
        // The first session goes to the edge; the rest of a dropped tab line up after it.
        movePane(first, next: target, edge: edge) { [weak self] in
            guard let self else { return }
            var prev = first
            let follow: PaneEdge = edge == .left || edge == .right ? .right : .bottom
            for s in moving.dropFirst() {
                let anchor = prev
                self.movePane(s, next: anchor, edge: follow, then: nil)
                prev = s
            }
            self.selectSession(first)
        }
    }

    func movePane(_ id: String, next target: String, edge: PaneEdge, then: (() -> Void)?) {
        client(for: id).call("pane.move", ["session_id": id, "target_session_id": target, "edge": edge.rawValue]) { [weak self] r in
            DispatchQueue.main.async {
                if case .failure(let e) = r { self?.lastError = "Could not move the pane: \(e.localizedDescription)" }
                then?()
            }
        }
    }

    /// Takes a pane out of its split into a tab of its own.
    func movePaneToNewTab(_ id: String) {
        guard let t = tab(containing: id), t.layout.sessions.count > 1 else { return }
        client(for: id).call("pane.move", ["session_id": id, "new_tab": true]) { [weak self] r in
            DispatchQueue.main.async {
                if case .failure(let e) = r { self?.lastError = "Could not move the pane: \(e.localizedDescription)" }
                else { self?.selectSession(id) }
            }
        }
    }

    /// Puts the tab's sessions into the active tab, right of the focused pane.
    func mergeTabIntoCurrent(_ tabId: String) {
        guard let cur = activeTab, cur.id != tabId, let target = focusedSessionId ?? cur.layout.sessions.first else { return }
        drop(kind: "tab", id: tabId, onPane: target, edge: .right)
    }

    // MARK: Closing groups of tabs

    enum CloseScope { case others, right, left, all }

    func tabs(_ scope: CloseScope, of tabId: String) -> [Tab] {
        let all = currentTabs
        guard let i = all.firstIndex(where: { $0.id == tabId }) else { return [] }
        switch scope {
        case .others: return all.filter { $0.id != tabId }
        case .right: return Array(all[(i + 1)...])
        case .left: return Array(all[..<i])
        case .all: return all
        }
    }

    /// Closes several tabs with one confirmation when agents in them are busy.
    func closeTabs(_ tabs: [Tab]) {
        guard !tabs.isEmpty else { return }
        let busy = tabs.flatMap { $0.layout.sessions }.compactMap { session($0) }
            .filter { $0.kind == .agent && !$0.isDormant && ($0.activity == .working || $0.activity == .needsInput) }
        if !busy.isEmpty {
            let a = NSAlert()
            a.messageText = "Close \(tabs.count) tabs?"
            a.informativeText = "\(busy.count) agent\(busy.count == 1 ? " is" : "s are") still working or waiting for input (\(busy.map(\.displayTitle).prefix(3).joined(separator: ", "))). Closing stops them."
            a.addButton(withTitle: "Close Tabs")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        for t in tabs { closeTab(t.id, confirmBusy: false) }
    }

    func docs(_ scope: CloseScope, of docId: String) -> [DocTab] {
        let all = currentDocs
        guard let i = all.firstIndex(where: { $0.id == docId }) else { return [] }
        switch scope {
        case .others: return all.filter { $0.id != docId }
        case .right: return Array(all[(i + 1)...])
        case .left: return Array(all[..<i])
        case .all: return all
        }
    }

    func closeDocs(_ docs: [DocTab]) { for d in docs { closeDoc(d.id) } }
}
