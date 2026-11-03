import Foundation

/// Pinned tabs, per project (`tabs.pinned` at scope `project:<id>`: tab ids). Pinned tabs come first in
/// the project's tab order (tab bar, ⌘1…, sidebar), show as icons in the tab bar, and are left alone by
/// "Close Other Tabs" and friends.
extension AppModel {
    func pinnedTabIds(project id: String?) -> [String] {
        guard let id, case .array(let a)? = settingValue("tabs.pinned", scope: "project:\(id)") else { return [] }
        return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    func isPinned(_ tab: Tab) -> Bool { pinnedTabIds(project: tab.projectId).contains(tab.id) }

    func isPinned(session id: String) -> Bool { tab(containing: id).map(isPinned) ?? false }

    func setPinned(_ tab: Tab, _ on: Bool) {
        let live = Set(state.tabs.filter { $0.projectId == tab.projectId }.map(\.id))
        var ids = pinnedTabIds(project: tab.projectId).filter { live.contains($0) && $0 != tab.id }   // drop closed tabs
        if on { ids.append(tab.id) }
        let scope = "project:\(tab.projectId)"
        setSetting("tabs.pinned", ids.isEmpty ? nil : ids, scope: scope)
        // Show it right away; the daemon echoes the same value.
        setSettingLocally("tabs.pinned", ids.isEmpty ? nil : .array(ids.map { .string($0) }), scope: scope)
    }

    func togglePin(_ tab: Tab) { setPinned(tab, !isPinned(tab)) }
}
