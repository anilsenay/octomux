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
    @Published var selectedWorkspaceId: String? {
        didSet {
            saveSelection()
            if oldValue != selectedWorkspaceId { DispatchQueue.main.async { self.workspaceTintChanged() } }
        }
    }
    @Published var selectedProjectId: String? { didSet { saveSelection() } }
    @Published var activeTabId: String? {
        didSet { saveSelection(); if oldValue != activeTabId, activeTabId != nil { activeDocId = nil } }
    }
    /// App-side tabs (file, changes, commit views) shown next to the session tabs; not in the sidebar.
    @Published var docTabs: [DocTab] = DocTab.load() { didSet { DocTab.save(docTabs) } }
    /// The doc tab shown instead of the active session tab (nil: the session tab shows).
    @Published var activeDocId: String? { didSet { if oldValue != activeDocId { TerminalHost.shared.render(force: true) } } }
    @Published var focusedSessionId: String?
    /// Split tab temporarily showing one pane full size (tab id → session id). App-side only.
    @Published var zoomedPanes: [String: String] = [:] { didSet { if oldValue != zoomedPanes { TerminalHost.shared.render(force: true) } } }
    @Published var sidebarVisible = true
    /// Sidebar shows projects (default) or every agent across workspaces, by status.
    @Published var sidebarAgents = UserDefaults.standard.bool(forKey: "ade.sidebarAgents") {
        didSet { UserDefaults.standard.set(sidebarAgents, forKey: "ade.sidebarAgents") }
    }
    /// Sidebar shown floating over the content while it is hidden (pointer at the left edge).
    @Published var sidebarPeek = false
    /// Dock terminal opened automatically per project (dropped on close when unused).
    var autoDockSession: [String: String] = [:]
    /// Debug channel only: shows a project row's hover controls in screenshots.
    @Published var debugHoverProject: String?
    @Published var sidebarWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "ade.sidebarWidth") as? Double ?? 252) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "ade.sidebarWidth") }
    }
    @Published var rightPanelVisible = UserDefaults.standard.bool(forKey: "ade.rightPanel") {
        didSet { UserDefaults.standard.set(rightPanelVisible, forKey: "ade.rightPanel") }
    }
    @Published var lastError: String?
    @Published var renamingSessionId: String?
    @Published var paletteVisible = false
    @Published var paletteQuery = ""
    @Published var usagePopoverOpen = false
    @Published var newWorktreeFor: Project?
    @Published private(set) var hostId = HostStore.currentId

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
        client.onNotify = { [client] n in NotificationCenterModel.shared.received(n, from: client); Notifier.shared.deliver(n) }
        client.onNotificationsChanged = { [client] in NotificationCenterModel.shared.refresh(client) }
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
        if let ws = selectedWorkspaceId, let t = activeTabId, let tab = state.tabs.first(where: { $0.id == t }),
           project(tab.projectId)?.workspaceId == ws { lastTabPerWorkspace[ws] = t }
        defaults.set(lastTabPerWorkspace, forKey: "ade.lastTabs")
        defaults.set(sidebarVisible, forKey: "ade.sidebar")
    }

    // MARK: Multi-host (features.multi_host): extra hosts merged into this window

    /// Daemons of hosts shown alongside the current one, by host id.
    private(set) var extraClients: [String: DaemonClient] = [:]
    private var primaryState = DaemonState()
    private var extraStates: [String: DaemonState] = [:]
    /// Which host owns an id (projects, sessions, tabs, profiles of extra hosts). Absent = current host.
    private(set) var owner: [String: String] = [:]

    var multiHost: Bool { setting("features.multi_host")?.bool ?? false }

    /// Starts/stops extra host connections to match `HostStore.attached`.
    func syncExtraHosts() {
        let want = multiHost ? Set(HostStore.attached.filter { $0 != client.host.id }) : []
        for (id, c) in extraClients where !want.contains(id) {
            c.switchHost(.local); c.stopped = true
            extraClients.removeValue(forKey: id)
            extraStates.removeValue(forKey: id)
        }
        for id in want where extraClients[id] == nil {
            guard let h = HostStore.withLocal.first(where: { $0.id == id }) else { continue }
            let c = DaemonClient(host: h)
            c.onState = { [weak self] st in self?.extraStates[id] = st; self?.publish(); NotificationCenterModel.shared.ensureLoaded(c) }
            c.onNotify = { n in NotificationCenterModel.shared.received(n, from: c); Notifier.shared.deliver(n) }
            c.onNotificationsChanged = { NotificationCenterModel.shared.refresh(c) }
            extraClients[id] = c
            c.startSubscription()
        }
        publish()
    }

    func client(for id: String?) -> DaemonClient {
        guard let id, let h = owner[id], let c = extraClients[h] else { return client }
        return c
    }

    func host(for id: String?) -> Host {
        guard let id, let h = owner[id], let c = extraClients[h] else { return client.host }
        return c.host
    }

    private let rootsLock = NSLock()
    private var extraRoots: [(String, DaemonClient)] = []   // project path → client, read from any thread

    /// Host whose project contains `path` (git / file reads; callable off the main thread).
    func host(forPath path: String) -> (Host, DaemonClient) {
        rootsLock.lock(); let roots = extraRoots; rootsLock.unlock()
        for (root, c) in roots where path == root || path.hasPrefix(root + "/") || path.hasPrefix(root + ".worktrees/") {
            return (c.host, c)
        }
        return (client.host, client)
    }

    private var lastMultiHost: Bool?

    private func apply(_ s: DaemonState) {
        NotificationCenterModel.shared.ensureLoaded(client)
        primaryState = s
        let flag = s.settings.first { $0.scope == "global" && $0.key == "features.multi_host" }?.value.bool ?? false
        if flag != lastMultiHost {
            lastMultiHost = flag
            DispatchQueue.main.async { self.syncExtraHosts() }
        }
        publish()
    }

    /// Hosts merged into this window besides the current one.
    var extraHosts: [Host] { extraClients.values.map(\.host).sorted { $0.name < $1.name } }

    /// Moves a project to a workspace of this window. A project of an extra host keeps its own
    /// workspace on that host; the assignment is remembered here (D14).
    func moveProject(_ id: String, toWorkspace ws: String) {
        if owner[id] != nil {
            var m = HostStore.projectWorkspace
            m[id] = ws
            HostStore.projectWorkspace = m
            publish()
        } else {
            updateProject(id, ["workspace_id": ws])
        }
    }

    func setAttached(_ hostId: String, _ on: Bool) {
        var a = HostStore.attached.filter { $0 != hostId }
        if on { a.append(hostId) }
        HostStore.attached = a
        syncExtraHosts()
    }

    /// Current host's state plus extra hosts' projects/sessions/tabs/profiles/usage. Extra projects join the
    /// workspace with the same name (else the first one).
    private func publish() {
        var s = primaryState
        var own: [String: String] = [:]
        for (hid, st) in extraStates where extraClients[hid] != nil {
            let names = Dictionary(st.workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let pinned = HostStore.projectWorkspace
            for var p in st.projects {
                let wsName = names[p.workspaceId]
                if let w = pinned[p.id], s.workspaces.contains(where: { $0.id == w }) {
                    p.workspaceId = w
                } else {
                    p.workspaceId = s.workspaces.first(where: { $0.name == wsName })?.id ?? s.workspaces.first?.id ?? p.workspaceId
                }
                s.projects.append(p); own[p.id] = hid
            }
            for x in st.sessions { s.sessions.append(x); own[x.id] = hid }
            for t in st.tabs { s.tabs.append(t); own[t.id] = hid }
            for pr in st.profiles { s.profiles.append(pr); own[pr.id] = hid }
            s.usage += st.usage
        }
        owner = own
        var roots: [(String, DaemonClient)] = []
        for (hid, st) in extraStates { if let c = extraClients[hid] { roots += st.projects.map { ($0.path, c) } } }
        rootsLock.lock(); extraRoots = roots; rootsLock.unlock()
        applyMerged(s)
    }

    private func applyMerged(_ s: DaemonState) {
        connected = true
        state = s
        // Keep selection valid.
        if selectedWorkspaceId == nil || !s.workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = s.workspaces.first?.id
        }
        if let t = activeTabId, !s.tabs.contains(where: { $0.id == t }) {
            activeTabId = tabs(ofProject: selectedProjectId).first?.id
        }
        // A tab or project from another workspace (stale saved selection): fall back to this workspace's.
        if let t = activeTab, project(t.projectId)?.workspaceId != selectedWorkspaceId {
            activeTabId = nil
        }
        if let p = selectedProjectId, project(p)?.workspaceId != selectedWorkspaceId {
            selectedProjectId = nil
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
        if let p = pendingSelect, s.projects.contains(where: { $0.id == p }) {
            pendingSelect = nil
            DispatchQueue.main.async { self.selectProject(p) }
        }
        Notifier.shared.updateBadge(state: s)
        ThemeStore.shared.sync(from: self)
        if s.workspaces.first(where: { $0.id == selectedWorkspaceId })?.color != lastTintColor { workspaceTintChanged() }
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

    /// Folder the current context works in: the focused session's worktree, else the project.
    var currentWorkPath: String? {
        if let s = session(focusedSessionId), s.projectId == currentProject?.id, let w = s.worktree { return w }
        return currentProject?.path
    }

    /// The project's tab sessions in tab order (then pane order), so the sidebar matches the tab bar.
    func sessions(ofProject id: String) -> [Session] {
        var rank: [String: Int] = [:]
        for (ti, t) in tabs(ofProject: id).enumerated() {
            for (pi, sid) in t.layout.sessions.enumerated() { rank[sid] = ti * 100 + pi }
        }
        return state.sessions.filter { $0.projectId == id && $0.placement == .tab }
            .sorted { (rank[$0.id] ?? Int.max, $0.createdAt) < (rank[$1.id] ?? Int.max, $1.createdAt) }
    }

    // MARK: Reordering (drag and drop)

    /// Moves `tabId` to `targetTabId`'s place among its project's tabs.
    func moveTab(_ tabId: String, to targetTabId: String) {
        guard tabId != targetTabId, let t = state.tabs.first(where: { $0.id == tabId }),
              state.tabs.first(where: { $0.id == targetTabId })?.projectId == t.projectId else { return }
        var order = tabs(ofProject: t.projectId).map(\.id)
        guard let from = order.firstIndex(of: tabId), let to = order.firstIndex(of: targetTabId) else { return }
        order.remove(at: from)
        order.insert(tabId, at: to)
        applyOrder(order, current: tabs(ofProject: t.projectId).map { ($0.id, $0.sort) }, method: "tab.update")
    }

    /// Moves `projectId` to `targetId`'s place in the current workspace.
    func moveProject(_ projectId: String, before targetId: String) {
        guard projectId != targetId else { return }
        var order = projects.map(\.id)
        guard let from = order.firstIndex(of: projectId), let to = order.firstIndex(of: targetId) else { return }
        order.remove(at: from)
        order.insert(projectId, at: to)
        applyOrder(order, current: projects.map { ($0.id, $0.sort) }, method: "project.update")
    }

    /// Writes sort = index for items whose position changed (each to the daemon that owns it).
    private func applyOrder(_ order: [String], current: [(String, Int)], method: String) {
        let old = Dictionary(uniqueKeysWithValues: current)
        for (i, id) in order.enumerated() where old[id] != i {
            client(for: id).call(method, ["id": id, "sort": i])
            // Apply locally right away (the daemon echoes the same values), so drags reorder
            // without a round trip and inside the caller's animation.
            if method == "tab.update", let k = state.tabs.firstIndex(where: { $0.id == id }) { state.tabs[k].sort = i }
            if method == "project.update", let k = state.projects.firstIndex(where: { $0.id == id }) { state.projects[k].sort = i }
        }
    }

    func tabs(ofProject id: String?) -> [Tab] {
        state.tabs.filter { $0.projectId == id }.sorted { $0.sort < $1.sort }
    }

    var activeTab: Tab? { state.tabs.first { $0.id == activeTabId } }
    var currentProject: Project? { project(activeTab?.projectId ?? selectedProjectId) }
    var currentTabs: [Tab] { tabs(ofProject: currentProject?.id) }

    /// Profiles of the host that owns the current project (each host has its own agents).
    var enabledProfiles: [Profile] {
        let h = owner[currentProject?.id ?? ""]
        return state.profiles.filter { $0.enabled && owner[$0.id] == h }.sorted { $0.sort < $1.sort }
    }
    var pinnedProfiles: [Profile] { enabledProfiles.filter { $0.pinned } }

    /// Enabled profiles of the host that owns `projectId`.
    func enabledProfiles(forProject projectId: String?) -> [Profile] {
        let h = owner[projectId ?? ""]
        return state.profiles.filter { $0.enabled && owner[$0.id] == h }.sorted { $0.sort < $1.sort }
    }

    /// Profiles grouped by agent kind/icon, so two Claude profiles show as one Claude entry with a choice.
    func profileGroups(forProject projectId: String?, pinnedOnly: Bool = false) -> [[Profile]] {
        var order: [String] = []
        var groups: [String: [Profile]] = [:]
        for p in enabledProfiles(forProject: projectId) where !pinnedOnly || p.pinned {
            let key = p.icon
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        return order.compactMap { groups[$0] }
    }

    /// What the tab bar's new-session button starts: a profile id, or nil for a terminal.
    var lastNewSessionProfile: String? {
        get {
            let v = defaults.string(forKey: "ade.lastNew")
            guard let v, v != "terminal", enabledProfiles.contains(where: { $0.id == v }) else { return nil }
            return v
        }
        set {
            defaults.set(newValue ?? "terminal", forKey: "ade.lastNew")
            objectWillChange.send()
        }
    }

    /// Closes a tab. With `confirmBusy` (middle click), asks first when an agent in it is working or waiting.
    func closeTab(_ tabId: String, confirmBusy: Bool) {
        guard let tab = state.tabs.first(where: { $0.id == tabId }) else { return }
        let busy = tab.layout.sessions.compactMap { session($0) }
            .filter { $0.kind == .agent && !$0.isDormant && ($0.activity == .working || $0.activity == .needsInput) }
        if confirmBusy, let s = busy.first {
            let a = NSAlert()
            a.messageText = "Close “\(s.displayTitle)”?"
            a.informativeText = s.activity == .working ? "The agent is still working. Closing the tab stops it." : "The agent is waiting for your input. Closing the tab stops it."
            a.addButton(withTitle: "Close Tab")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        client(for: tabId).call("tab.close", ["id": tabId], completion: report)
    }

    /// Starts a session and remembers the choice for the tab bar's button.
    func newSessionRemembering(profileId: String?) {
        lastNewSessionProfile = profileId
        newSession(profileId: profileId)
    }

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
        activeDocId = nil
        selectedWorkspaceId = id
        if let t = lastTabPerWorkspace[id], let tab = state.tabs.first(where: { $0.id == t }), project(tab.projectId)?.workspaceId == id {
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
        activeDocId = nil
        selectedProjectId = id
        if activeTab?.projectId != id { activeTabId = tabs(ofProject: id).first?.id }
        focusedSessionId = activeTab?.activeSessionId ?? activeTab?.layout.sessions.first
        TerminalHost.shared.focusCurrent()
    }

    func selectTab(_ id: String) {
        guard let t = state.tabs.first(where: { $0.id == id }) else { return }
        activeDocId = nil
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
        activeDocId = nil
        if let p = project(s.projectId), p.workspaceId != selectedWorkspaceId { selectedWorkspaceId = p.workspaceId }
        selectedProjectId = s.projectId
        if let t = tab(containing: id) {
            activeTabId = t.id
            if t.activeSessionId != id { client(for: t.id).call("tab.update", ["id": t.id, "active_session_id": id]) }
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
            client(for: t.id).call("tab.update", ["id": t.id, "active_session_id": id])
        }
    }

    func markRead(_ id: String) {
        if let s = session(id), s.unread || s.activity == .done {
            client(for: id).call("session.mark_read", ["id": id])
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
    func newSession(profileId: String?, projectId: String? = nil, split: SplitDir? = nil, command: String? = nil, title: String? = nil, placement: Placement = .tab, worktree: String? = nil, resume: String? = nil) {
        guard let pid = projectId ?? currentProject?.id else {
            lastError = "Add a project first (⌘⇧O)."
            return
        }
        var params: [String: Any] = ["project_id": pid, "placement": placement.rawValue]
        // Explicit worktree, else inherit the focused session's (same project) so splits and ⌘T stay in it.
        if let wt = worktree ?? (projectId == nil ? session(focusedSessionId).flatMap { $0.projectId == pid ? $0.worktree : nil } : nil) {
            params["worktree"] = wt
        }
        if let profileId { params["profile_id"] = profileId }
        if let command { params["command"] = command }
        if let title { params["title"] = title }
        if let resume { params["resume_agent_session_id"] = resume }
        if let split, let target = focusedSessionId, tab(containing: target)?.projectId == pid {
            params["split_target"] = target
            params["split_dir"] = split.rawValue
        }
        if let size = TerminalHost.shared.estimatedGrid() {
            params["cols"] = size.cols
            params["rows"] = size.rows
        }
        client(for: pid).call("session.create", params) { [weak self] r in
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

    func stop(_ id: String) { client(for: id).call("session.stop", ["id": id], completion: report) }
    func restart(_ id: String) { client(for: id).call("session.restart", ["id": id], completion: report) }

    func remove(_ id: String, confirm: Bool = true) {
        if confirm, let s = session(id), s.state == .running, s.kind == .agent {
            let a = NSAlert()
            a.messageText = "Close “\(s.displayTitle)”?"
            a.informativeText = "The agent process will be stopped and the session removed. The conversation stays in the agent's history."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        client(for: id).call("session.remove", ["id": id], completion: report)
    }

    func rename(_ id: String, to title: String) { client(for: id).call("session.rename", ["id": id, "title": title], completion: report) }

    func closeFocusedPane() {
        if let d = activeDocId { closeDoc(d); return }
        if let id = focusedSessionId { remove(id) }
    }

    func updateLayout(tabId: String, layout: PaneNode) {
        guard let data = try? JSONEncoder().encode(layout), let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        client(for: tabId).call("tab.update", ["id": tabId, "layout": obj])
    }

    var host: Host { client.host }

    /// Connects the window to another host's daemon (or back to this Mac).
    func switchHost(_ id: String) {
        guard id != client.host.id, let h = HostStore.withLocal.first(where: { $0.id == id }) else { return }
        HostStore.currentId = id
        hostId = id
        TerminalHost.shared.closeAll()
        state = DaemonState()
        connected = false
        selectedWorkspaceId = nil
        selectedProjectId = nil
        activeTabId = nil
        focusedSessionId = nil
        client.switchHost(h)
        lastMultiHost = nil
        syncExtraHosts()
    }

    func addProject(onHost hostId: String? = nil) {
        guard let ws = selectedWorkspaceId else { return }
        if let hid = hostId, hid != client.host.id, let c = extraClients[hid] {
            guard let path = askRemotePath(c.host) else { return }
            addProject(path: path, onExtraHost: hid, workspaceId: ws)
            return
        }
        if host.isRemote {
            // No file browser for the other machine: ask for the path.
            let a = NSAlert()
            a.messageText = "Add a project on \(host.name)"
            a.informativeText = "Folder path on that host (~ works)."
            let tf = NSTextField(string: "~/")
            tf.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            a.accessoryView = tf
            a.addButton(withTitle: "Add")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = tf
            if a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty { addProject(path: tf.stringValue, workspaceId: ws) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(path: url.path, workspaceId: ws) }
    }

    private func askRemotePath(_ h: Host) -> String? {
        let a = NSAlert()
        a.messageText = "Add a project on \(h.name)"
        a.informativeText = "Folder path on that host (~ works)."
        let tf = NSTextField(string: "~/")
        tf.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty else { return nil }
        return tf.stringValue
    }

    /// Creates a project on an extra host (in its workspace with the same name, else its first one) and
    /// assigns it to `workspaceId` of this window.
    func addProject(path: String, onExtraHost hid: String, workspaceId: String) {
        guard let c = extraClients[hid] else { return }
        let wsName = state.workspaces.first { $0.id == workspaceId }?.name
        let remote = extraStates[hid]?.workspaces ?? []
        guard let rws = remote.first(where: { $0.name == wsName })?.id ?? remote.first?.id else {
            lastError = "\(c.host.name) has no workspace yet."
            return
        }
        c.call("project.create", ["workspace_id": rws, "path": path]) { [weak self] r in
            if case .success(let v) = r, let id = (v as? [String: Any])?["id"] as? String {
                var m = HostStore.projectWorkspace
                m[id] = workspaceId
                HostStore.projectWorkspace = m
                self?.pendingSelect = id
            }
            self?.report(r)
        }
    }

    /// Project to select once it shows up in merged state (created on an extra host).
    private var pendingSelect: String?

    func addProject(path: String, workspaceId: String) {
        client.call("project.create", ["workspace_id": workspaceId, "path": path]) { [weak self] r in
            if case .success(let v) = r, let id = (v as? [String: Any])?["id"] as? String { self?.selectProject(id) }
            self?.report(r)
        }
    }

    func updateProject(_ id: String, _ fields: [String: Any]) {
        var p = fields
        p["id"] = id
        client(for: id).call("project.update", p, completion: report)
    }

    func removeProject(_ id: String) {
        guard let p = project(id) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(p.name)” from ADE?"
        a.informativeText = "Its sessions are stopped and removed. Files on disk are not touched."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { client(for: id).call("project.delete", ["id": id], completion: report) }
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

    /// Terminal backgrounds follow the workspace color (theme.conf + pane layers).
    private var lastTintColor: String?
    func workspaceTintChanged() {
        lastTintColor = workspace?.color
        ThemeStore.shared.writeTerminalTheme()
        TerminalHost.shared.refreshPaneBackgrounds()
    }

    /// The top bar's +N −M button: shows the right panel on Changes, or hides it when it already shows Changes.
    func toggleChangesPanel() {
        let onChanges = UserDefaults.standard.string(forKey: "ade.rightTab") == "Changes"
        if rightPanelVisible && onChanges {
            rightPanelVisible = false
        } else {
            UserDefaults.standard.set("Changes", forKey: "ade.rightTab")
            rightPanelVisible = true
        }
    }

    func toggleSidebar() {
        sidebarPeek = false
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
