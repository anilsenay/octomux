import Foundation

/// Pane zoom: one pane of a split tab shown full size for a while, the split kept as is.
extension AppModel {
    /// The zoomed pane of `tab`, if it is still one of the tab's panes and the tab is still split.
    func zoomedPane(in tab: Tab?) -> String? {
        guard let tab, let id = zoomedPanes[tab.id], tab.layout.sessions.count > 1, tab.layout.sessions.contains(id) else { return nil }
        return id
    }

    func isZoomed(_ sessionId: String) -> Bool {
        guard let tab = tab(containing: sessionId) else { return false }
        return zoomedPane(in: tab) == sessionId
    }

    /// Zooms `sessionId` (focusing it), or restores the split if it is already zoomed.
    func toggleZoom(_ sessionId: String? = nil) {
        guard let id = sessionId ?? focusedSessionId, let tab = tab(containing: id), tab.layout.sessions.count > 1 else { return }
        if zoomedPane(in: tab) == id {
            zoomedPanes[tab.id] = nil
        } else {
            selectSession(id)
            zoomedPanes[tab.id] = id
        }
    }
}
