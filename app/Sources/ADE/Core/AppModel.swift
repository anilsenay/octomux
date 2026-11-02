import AppKit
import Combine
import SwiftUI

/// UI state + actions. The daemon's state is the source of truth; selection
/// (which workspace/tab/pane is in front) is local and persisted in UserDefaults.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let client = DaemonClient()
    @Published private(set) var state = DaemonState()
    @Published var connected = false
    @Published var selectedWorkspaceId: String? { didSet { saveSelection() } }
    @Published var selectedProjectId: String? { didSet { saveSelection() } }
    @Published var activeTabId: String? { didSet { saveSelection() } }
    @Published var focusedSessionId: String?
    @Published var sidebarVisible = true
    @Published var rightPanelVisible = UserDefaults.standard.bool(forKey: "ade.rightPanel") {
        didSet { UserDefaults.standard.set(rightPanelVisible, forKey: "ade.rightPanel") }
    }
    @Published var lastError: String?
    @Published var renamingSessionId: String?
    @Published var paletteVisible = false
    @Published var paletteQuery = ""
    @Published var usagePopoverOpen = false

    private var lastTabPerWorkspace: [String: String] = [:]
    private let defaults = UserDefaults.standard

    private init() {
        selectedWorkspaceId = defaults.string(forKey: "ade.ws")
        selectedProjectId = defaults.string(forKey: "ade.project")
        activeTabId = defaults.string(forKey: "ade.tab")
        lastTabPerWorkspace = defaults.dictionary(forKey: "ade.lastTabs") as? [String: String] ?? [:]
        sidebarVisible = defaults.object(forKey: "ade.sidebar") as? Bool ?? true
    }

    func start() {
        client.onState = { [weak self] s in self?.apply(s) }
        client.onNotify = { n in Notifier.shared.deliver(n) }
        client.onDisconnect = { [weak self] in self?.connected = false }
        DispatchQueue.global().async {
            let ok = DaemonClient.ensureDaemon()
            DispatchQueue.main.async {
                if !ok { self.lastError = "Could not start the ADE daemon (\(Paths.adeBinary))." }
                self.client.startSubscription()
            }
        }
    }

    private func saveSelection() {
        defaults.set(selectedWorkspaceId, forKey: "ade.ws")
        defaults.set(selectedProjectId, forKey: "ade.project")
        defaults.set(activeTabId, forKey: "ade.tab")
        if let ws = selectedWorkspaceId, let t = activeTabId { lastTabPerWorkspace[ws] = t }
        defaults.set(lastTabPerWorkspace, forKey: "ade.lastTabs")
        defaults.set(sidebarVisible, forKey: "ade.sidebar")
    }

    private func apply(_ s: DaemonState) {
        connected = true
        state = s
        // Keep selection valid.
        if selectedWorkspaceId == nil || !s.workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = s.workspaces.first?.id
        }
        if let t = activeTabId, !s.tabs.contains(where: { $0.id == t }) {
            activeTabId = tabs(ofProject: selectedProjectId).first?.id
        }
        if let p = selectedProjectId, !s.projects.contains(where: { $0.id == p }) {
            selectedProjectId = nil
        }
        if selectedProjectId == nil {
            selectedProjectId = projects.first?.id
        }
        if activeTabId == nil, let p = selectedProjectId {
            activeTabId = tabs(ofProject: p).first?.id
        }
        if let tab = activeTab, focusedSessionId == nil || !tab.layout.sessions.contains(focusedSessionId!) {
            focusedSessionId = tab.activeSessionId ?? tab.layout.sessions.first
        }
        Notifier.shared.updateBadge(state: s)
        ThemeStore.shared.sync(from: self)
        KeyBindings.shared.sync(from: self)
        TerminalHost.shared.reconcile(with: s)
    }

    // MARK: Derived

    var workspace: Workspace? { state.workspaces.first { $0.id == selectedWorkspaceId } }

    var projects: [Project] {
        state.projects.filter { $0.workspaceId == selectedWorkspaceId && !$0.archived }.sorted { $0.sort < $1.sort }
    }

    func project(_ id: String?) -> Project? { state.projects.first { $0.id == id } }
    func session(_ id: String?) -> Session? { state.sessions.first { $0.id == id } }
    func profile(_ id: String?) -> Profile? { state.profiles.first { $0.id == id } }

    func sessions(ofProject id: String) -> [Session] {
        state.sessions.filter { $0.projectId == id && $0.placement == .tab }.sorted { $0.createdAt < $1.createdAt }
    }

    func tabs(ofProject id: String?) -> [Tab] {
        state.tabs.filter { $0.projectId == id }.sorted { $0.sort < $1.sort }
    }

    var activeTab: Tab? { state.tabs.first { $0.id == activeTabId } }
    var currentProject: Project? { project(activeTab?.projectId ?? selectedProjectId) }
    var currentTabs: [Tab] { tabs(ofProject: currentProject?.id) }

    var enabledProfiles: [Profile] { state.profiles.filter { $0.enabled }.sorted { $0.sort < $1.sort } }
    var pinnedProfiles: [Profile] { enabledProfiles.filter { $0.pinned } }

    func tab(containing sessionId: String) -> Tab? { state.tabs.first { $0.layout.sessions.contains(sessionId) } }

    /// Resolved setting: project -> workspace -> global.
    func setting(_ key: String, project: String? = nil) -> JSONValue? {
        var scopes: [String] = []
        if let p = project ?? currentProject?.id {
            scopes.append("project:\(p)")
            if let ws = self.project(p)?.workspaceId { scopes.append("workspace:\(ws)") }
        }
        scopes.append("global")
        for sc in scopes {
            if let s = state.settings.first(where: { $0.scope == sc && $0.key == key }) { return s.value }
        }
        return nil
    }

    func settingValue(_ key: String, scope: String) -> JSONValue? {
        state.settings.first { $0.scope == scope && $0.key == key }?.value
    }

    func setSetting(_ key: String, _ value: Any?, scope: String = "global") {
        client.call("settings.set", ["scope": scope, "key": key, "value": value ?? NSNull()])
    }

    // MARK: Selection

    func selectWorkspace(_ id: String) {
        guard id != selectedWorkspaceId else { return }
        selectedWorkspaceId = id
        if let t = lastTabPerWorkspace[id], let tab = state.tabs.first(where: { $0.id == t }) {
            activeTabId = tab.id
            selectedProjectId = tab.projectId
        } else {
            selectedProjectId = projects.first?.id
            activeTabId = tabs(ofProject: selectedProjectId).first?.id
        }
        focusedSessionId = activeTab?.activeSessionId ?? activeTab?.layout.sessions.first
        TerminalHost.shared.focusCurrent()
    }

    func cycleWorkspace(_ delta: Int) {
        let ws = state.workspaces.sorted { $0.sort < $1.sort }
        guard !ws.isEmpty, let i = ws.firstIndex(where: { $0.id == selectedWorkspaceId }) else { return }
        let n = (i + delta + ws.count) % ws.count
        selectWorkspace(ws[n].id)
    }

    func selectProject(_ id: String) {
        selectedProjectId = id
        if activeTab?.projectId != id { activeTabId = tabs(ofProject: id).first?.id }
        focusedSessionId = activeTab?.activeSessionId ?? activeTab?.layout.sessions.first
        TerminalHost.shared.focusCurrent()
    }

    func selectTab(_ id: String) {
        guard let t = state.tabs.first(where: { $0.id == id }) else { return }
        activeTabId = id
        selectedProjectId = t.projectId
        focusedSessionId = t.activeSessionId ?? t.layout.sessions.first
        TerminalHost.shared.focusCurrent()
    }

    func selectTab(index: Int) {
        let tabs = currentTabs
        guard !tabs.isEmpty else { return }
        let i = index < 0 ? tabs.count - 1 : min(index, tabs.count - 1)
        selectTab(tabs[i].id)
    }

    func cycleTab(_ delta: Int) {
        let tabs = currentTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == activeTabId } ?? 0
        selectTab(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    func selectSession(_ id: String) {
        guard let s = session(id) else { return }
        if let p = project(s.projectId), p.workspaceId != selectedWorkspaceId { selectedWorkspaceId = p.workspaceId }
        selectedProjectId = s.projectId
        if let t = tab(containing: id) {
            activeTabId = t.id
            if t.activeSessionId != id { client.call("tab.update", ["id": t.id, "active_session_id": id]) }
        }
        focusedSessionId = id
        markRead(id)
        TerminalHost.shared.focusCurrent()
    }

    func sessionFocused(_ id: String) {
        guard focusedSessionId != id || session(id)?.unread == true else { return }
        focusedSessionId = id
        markRead(id)
        if let t = tab(containing: id), t.activeSessionId != id {
            client.call("tab.update", ["id": t.id, "active_session_id": id])
        }
    }

    func markRead(_ id: String) {
        if let s = session(id), s.unread || s.activity == .done {
            client.call("session.mark_read", ["id": id])
        }
    }

    func nextNeedingInput() {
        let candidates = state.sessions.filter { $0.activity == .needsInput || ($0.unread && $0.activity == .done) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        if let s = candidates.first(where: { $0.activity == .needsInput }) ?? candidates.first { selectSession(s.id) }
    }

    // MARK: Actions

    func report(_ r: Result<Any, Error>) {
        if case .failure(let e) = r { lastError = "\(e)" }
    }

    /// Creates a terminal (profileId nil) or agent session. With `split`, it joins the focused pane's tab.
    func newSession(profileId: String?, projectId: String? = nil, split: SplitDir? = nil, command: String? = nil, title: String? = nil, placement: Placement = .tab) {
        guard let pid = projectId ?? currentProject?.id else {
            lastError = "Add a project first (⌘⇧O)."
            return
        }
        var params: [String: Any] = ["project_id": pid, "placement": placement.rawValue]
        if let profileId { params["profile_id"] = profileId }
        if let command { params["command"] = command }
        if let title { params["title"] = title }
        if let split, let target = focusedSessionId, tab(containing: target)?.projectId == pid {
            params["split_target"] = target
            params["split_dir"] = split.rawValue
        }
        if let size = TerminalHost.shared.estimatedGrid() {
            params["cols"] = size.cols
            params["rows"] = size.rows
        }
        client.call("session.create", params) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let v):
                guard let d = v as? [String: Any], let s = d["session"] as? [String: Any], let id = s["id"] as? String else { return }
                if let tid = d["tab_id"] as? String {
                    self.activeTabId = tid
                    self.selectedProjectId = pid
                }
                self.focusedSessionId = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { TerminalHost.shared.focusCurrent() }
            case .failure(let e):
                self.lastError = "\(e)"
            }
        }
    }

    func stop(_ id: String) { client.call("session.stop", ["id": id], completion: report) }
    func restart(_ id: String) { client.call("session.restart", ["id": id], completion: report) }

    func remove(_ id: String, confirm: Bool = true) {
        if confirm, let s = session(id), s.state == .running, s.kind == .agent {
            let a = NSAlert()
            a.messageText = "Close “\(s.displayTitle)”?"
            a.informativeText = "The agent process will be stopped and the session removed. The conversation stays in the agent's history."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        client.call("session.remove", ["id": id], completion: report)
    }

    func rename(_ id: String, to title: String) { client.call("session.rename", ["id": id, "title": title], completion: report) }

    func closeFocusedPane() {
        if let id = focusedSessionId { remove(id) }
    }

    func updateLayout(tabId: String, layout: PaneNode) {
        guard let data = try? JSONEncoder().encode(layout), let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        client.call("tab.update", ["id": tabId, "layout": obj])
    }

    func addProject() {
        guard let ws = selectedWorkspaceId else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(path: url.path, workspaceId: ws) }
    }

    func addProject(path: String, workspaceId: String) {
        client.call("project.create", ["workspace_id": workspaceId, "path": path]) { [weak self] r in
            if case .success(let v) = r, let id = (v as? [String: Any])?["id"] as? String { self?.selectProject(id) }
            self?.report(r)
        }
    }

    func updateProject(_ id: String, _ fields: [String: Any]) {
        var p = fields
        p["id"] = id
        client.call("project.update", p, completion: report)
    }

    func removeProject(_ id: String) {
        guard let p = project(id) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(p.name)” from ADE?"
        a.informativeText = "Its sessions are stopped and removed. Files on disk are not touched."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { client.call("project.delete", ["id": id], completion: report) }
    }

    func createWorkspace(name: String) {
        client.call("workspace.create", ["name": name]) { [weak self] r in
            if case .success(let v) = r, let id = (v as? [String: Any])?["id"] as? String { self?.selectWorkspace(id) }
            self?.report(r)
        }
    }

    func updateWorkspace(_ id: String, _ fields: [String: Any]) {
        var p = fields
        p["id"] = id
        client.call("workspace.update", p, completion: report)
    }

    func deleteWorkspace(_ id: String) { client.call("workspace.delete", ["id": id], completion: report) }

    func toggleSidebar() {
        sidebarVisible.toggle()
        saveSelection()
    }
}

// MARK: - Usage limits

extension AppModel {
    func usage(of profileId: String) -> [UsageReading] {
        state.usage.filter { $0.profileId == profileId }.sorted { UsageReading.order($0.window) < UsageReading.order($1.window) }
    }

    func usageAlwaysShown(_ profileId: String) -> Bool {
        if case .array(let a)? = settingValue("usage.always_show", scope: "global") { return a.contains(.string(profileId)) }
        return false
    }

    func setUsageAlwaysShown(_ profileId: String, _ on: Bool) {
        var ids: [String] = []
        if case .array(let a)? = settingValue("usage.always_show", scope: "global") { ids = a.compactMap { $0.string } }
        ids.removeAll { $0 == profileId }
        if on { ids.append(profileId) }
        setSetting("usage.always_show", ids.isEmpty ? nil : ids)
    }

    /// Profiles whose limits the status bar shows, with their readings.
    func usageProfilesShown() -> [(Profile, [UsageReading])] {
        var ids: [String] = []
        if let s = session(focusedSessionId), s.kind == .agent, let pid = s.profileId { ids.append(pid) }
        for p in enabledProfiles where usageAlwaysShown(p.id) && !ids.contains(p.id) { ids.append(p.id) }
        return ids.compactMap { id in
            guard let p = profile(id) else { return nil }
            let r = usage(of: id).filter { $0.window == "five_hour" || $0.window == "seven_day" || $0.window == "spend_limit" }
            return r.isEmpty ? nil : (p, Array(r.prefix(2)))
        }
    }
}
