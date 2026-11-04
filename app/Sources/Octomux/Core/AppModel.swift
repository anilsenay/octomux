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
    /// The first catalog from the daemon has arrived. Until then the window shows `LaunchCover`, not an empty
    /// catalog (after an update the daemon restarts first, which takes a few seconds).
    @Published private(set) var loaded = false
    /// Since when the daemon is unreachable (nil while connected): a banner after a few seconds.
    @Published var disconnectedSince: Date?

    /// Octomux as a whole, for Stop / Start in Settings. `stopped`: the user stopped every session and the
    /// daemon; the window is locked until they start it again (nothing restarts it meanwhile).
    enum Power { case running, stopping, stopped, starting }
    @Published var power: Power = .running
    /// The stop animation is running: the stopped screen waits for it.
    @Published var stopFalling = false
    private var stoppedAt = Date.distantPast
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
    @Published var sidebarAgents = UserDefaults.standard.bool(forKey: "octomux.sidebarAgents") {
        didSet { UserDefaults.standard.set(sidebarAgents, forKey: "octomux.sidebarAgents") }
    }
    /// Sidebar shown floating over the content while it is hidden (pointer at the left edge).
    @Published var sidebarPeek = false
    /// Dock terminal opened automatically per project (dropped on close when unused).
    var autoDockSession: [String: String] = [:]
    /// Debug channel only: shows a project row's hover controls in screenshots.
    @Published var debugHoverProject: String?
    /// Debug: a pane stack (any of its session ids) shown fanned out, as if hovered.
    @Published var debugFanStack: String?
    @Published var sidebarWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "octomux.sidebarWidth") as? Double ?? 252) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "octomux.sidebarWidth") }
    }
    @Published var rightPanelVisible = UserDefaults.standard.bool(forKey: "octomux.rightPanel") {
        didSet { UserDefaults.standard.set(rightPanelVisible, forKey: "octomux.rightPanel") }
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
        selectedWorkspaceId = defaults.string(forKey: "octomux.ws")
        selectedProjectId = defaults.string(forKey: "octomux.project")
        activeTabId = defaults.string(forKey: "octomux.tab")
        lastTabPerWorkspace = defaults.dictionary(forKey: "octomux.lastTabs") as? [String: String] ?? [:]
        sidebarVisible = defaults.object(forKey: "octomux.sidebar") as? Bool ?? true
    }

    func start() {
        client.onState = { [weak self] s in self?.apply(s) }
        client.onNotify = { [client] n in NotificationCenterModel.shared.received(n, from: client); Notifier.shared.deliver(n) }
        client.onNotificationsChanged = { [client] in NotificationCenterModel.shared.refresh(client) }
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            self.connected = false
            if self.disconnectedSince == nil { self.disconnectedSince = Date() }
        }
        startUsageRefresh()
        DispatchQueue.global().async { [client] in
            var ok = DaemonClient.ensureDaemon()
            // After an app update the running daemon is the previous build: restart it into the new binary
            // (sessions live in their holders and survive; the new daemon adopts them).
            if ok, !DaemonClient.held, let hello = try? client.callSync("hello") as? [String: Any],
               hello["stale"] as? Bool == true {
                NSLog("daemon binary was updated; restarting the daemon")
                _ = try? client.callSync("daemon.shutdown")
                for _ in 0..<30 where LineSocket(path: Paths.daemonSocket.path) != nil { usleep(100_000) }
                ok = DaemonClient.ensureDaemon()
            }
            DispatchQueue.main.async {
                if !ok { self.lastError = "Could not start the Octomux daemon (\(Paths.cliBinary))." }
                self.client.startSubscription()
            }
        }
    }

    private func saveSelection() {
        defaults.set(selectedWorkspaceId, forKey: "octomux.ws")
        defaults.set(selectedProjectId, forKey: "octomux.project")
        defaults.set(activeTabId, forKey: "octomux.tab")
        if let ws = selectedWorkspaceId, let t = activeTabId, let tab = state.tabs.first(where: { $0.id == t }),
           project(tab.projectId)?.workspaceId == ws { lastTabPerWorkspace[ws] = t }
        defaults.set(lastTabPerWorkspace, forKey: "octomux.lastTabs")
        defaults.set(sidebarVisible, forKey: "octomux.sidebar")
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
        if !loaded { withAnimation(.easeOut(duration: 0.25)) { loaded = true } }
        disconnectedSince = nil
        // A daemon answers again: started from Settings, or by someone else (`octomux` CLI) while stopped.
        // A last state from the daemon that is stopping right now doesn't count.
        if power == .starting || (power == .stopped && Date().timeIntervalSince(stoppedAt) > 2) {
            DaemonClient.held = false
            power = .running
        }
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
        StatusItemController.shared.sync(state: s)
        ThemeStore.shared.sync(from: self)
        updateAmbientMood()
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
        guard ensureManageable() else { return }
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

    /// The project's tabs: pinned ones first (see Pins.swift), each part in its own sort order.
    func tabs(ofProject id: String?) -> [Tab] {
        let all = state.tabs.filter { $0.projectId == id }.sorted { $0.sort < $1.sort }
        let pinned = Set(pinnedTabIds(project: id))
        guard !pinned.isEmpty else { return all }
        return all.filter { pinned.contains($0.id) } + all.filter { !pinned.contains($0.id) }
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

    /// What the tab bar's new-session button starts: a profile id, or nil for a terminal. Remembered per
    /// workspace; a workspace without a pick yet uses its default agent, then the last pick anywhere.
    var lastNewSessionProfile: String? {
        get {
            let ws = selectedWorkspaceId
            let picked = ws.flatMap { defaults.string(forKey: "octomux.lastNew.\($0)") }
                ?? defaultChatProfile(workspace: ws)?.id
                ?? defaults.string(forKey: "octomux.lastNew")
            guard let v = picked, v != "terminal", enabledProfiles.contains(where: { $0.id == v }) else { return nil }
            return v
        }
        set {
            let v = newValue ?? "terminal"
            if let ws = selectedWorkspaceId { defaults.set(v, forKey: "octomux.lastNew.\(ws)") }
            defaults.set(v, forKey: "octomux.lastNew")
            objectWillChange.send()
        }
    }

    /// Closes a tab. With `confirmBusy`, asks first when something in it still runs (see `closeAsking`).
    func closeTab(_ tabId: String, confirmBusy: Bool) {
        guard let tab = state.tabs.first(where: { $0.id == tabId }) else { return }
        let close = { self.client(for: tabId).call("tab.close", ["id": tabId], completion: self.report) }
        guard confirmBusy else { close(); return }
        closeAsking(tab.layout.sessions, noun: "tab", button: "Close Tab", close: close)
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

    /// Applies a setting to the local state before the daemon's echo (for instant UI); nil removes it.
    func setSettingLocally(_ key: String, _ value: JSONValue?, scope: String) {
        if let k = state.settings.firstIndex(where: { $0.scope == scope && $0.key == key }) {
            if let value { state.settings[k].value = value } else { state.settings.remove(at: k) }
        } else if let value {
            state.settings.append(Setting(scope: scope, key: key, value: value))
        }
    }

    func setSetting(_ key: String, _ value: Any?, scope: String = "global") {
        client.call("settings.set", ["scope": scope, "key": key, "value": value ?? NSNull()])
    }

    // MARK: Selection

    func selectWorkspace(_ id: String) {
        guard id != selectedWorkspaceId, state.workspaces.contains(where: { $0.id == id }) else { return }
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

    /// What a workspace has for you (the same rule as a project row): sessions waiting for your input, and ones
    /// with something new you haven't looked at (a finished turn, an error, new output).
    func attention(workspace id: String) -> (waiting: Int, unread: Int) {
        let projects = Set(state.projects.filter { $0.workspaceId == id }.map(\.id))
        let live = state.sessions.filter { projects.contains($0.projectId) && !$0.isDormant }
        return (live.filter { $0.activity == .needsInput }.count, live.filter { $0.unread && $0.activity != .needsInput }.count)
    }

    /// The other workspaces' attention, summed (the workspace menu's dot).
    var attentionElsewhere: (waiting: Int, unread: Int) {
        state.workspaces.filter { $0.id != selectedWorkspaceId }.map { attention(workspace: $0.id) }
            .reduce((0, 0)) { ($0.0 + $1.waiting, $0.1 + $1.unread) }
    }

    /// Agent sessions for the Agents panel: every workspace's, or only the current one's.
    func agentSessions(onlyCurrentWorkspace: Bool) -> [Session] {
        state.sessions.filter { s in
            guard s.isAgent, let p = project(s.projectId) else { return false }
            return !onlyCurrentWorkspace || p.workspaceId == selectedWorkspaceId
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
    func newSession(profileId: String?, projectId: String? = nil, split: SplitDir? = nil, command: String? = nil, title: String? = nil, placement: Placement = .tab, worktree: String? = nil, resume: String? = nil, prompt: String? = nil, chat: Bool = false, extraArgs: [String] = [], done: ((String) -> Void)? = nil) {
        guard ensureManageable() else { return }
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
        if let prompt { params["prompt"] = prompt }
        if !extraArgs.isEmpty { params["extra_args"] = extraArgs }
        if let split, let target = focusedSessionId, let t = tab(containing: target), t.projectId == pid {
            params["split_target"] = target
            params["split_dir"] = split.rawValue
            // Size the panes here (the daemon doesn't know pixels): equal shares in a row, minimum sizes.
            let size = TerminalHost.shared.container.bounds.size
            if size.width > 50, size.height > 50 {
                let div: CGFloat = T.m.inset > 0 ? T.m.inset : 1
                guard let sized = SplitSizing.layout(splitting: target, dir: split, in: t.layout, size: size, divider: div) else {
                    NSSound.beep()
                    lastError = "No room for another pane \(split == .right ? "side by side" : "stacked") here."
                    return
                }
                params["split_ratios"] = SplitSizing.ratios(sized)
            }
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
                if chat {
                    var set = UserDefaults.standard.stringArray(forKey: "octomux.chat") ?? []
                    if !set.contains(id) { set.append(id); UserDefaults.standard.set(set, forKey: "octomux.chat") }
                }
                done?(id)
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

    func stop(_ id: String) { if ensureManageable() { client(for: id).call("session.stop", ["id": id], completion: report) } }
    func restart(_ id: String) { if ensureManageable() { client(for: id).call("session.restart", ["id": id], completion: report) } }

    func remove(_ id: String, confirm: Bool = true) {
        guard ensureManageable() else { return }
        let close = { self.client(for: id).call("session.remove", ["id": id], completion: self.report) }
        guard confirm, confirmsClose, let s = session(id) else { close(); return }
        if s.state == .running, s.kind == .agent, s.activity != .working, s.activity != .needsInput {
            // An idle agent: its process still ends with the pane.
            let a = NSAlert()
            a.messageText = "Close “\(s.displayTitle)”?"
            a.informativeText = "The agent process will be stopped and the session removed. The conversation stays in the agent's history."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { close() }
            return
        }
        closeAsking([id], noun: "pane", button: "Close", close: close)
    }

    func rename(_ id: String, to title: String) { client(for: id).call("session.rename", ["id": id, "title": title], completion: report) }

    func closeFocusedPane() {
        if let d = activeDocId { closeDoc(d); return }
        if let id = focusedSessionId { remove(id) }
    }

    /// Equal shares for every row and column of a split tab (⌘K "Equalize Panes", double-click a divider).
    func equalizePanes(tabId: String? = nil) {
        guard ensureManageable() else { return }
        guard let id = tabId ?? activeTabId, let t = state.tabs.first(where: { $0.id == id }), t.layout.sessions.count > 1 else { return }
        let size = TerminalHost.shared.container.bounds.size
        guard size.width > 50, size.height > 50 else { return }
        let l = SplitSizing.equalized(t.layout, size: size, divider: T.m.inset > 0 ? T.m.inset : 1)
        if l != t.layout { updateLayout(tabId: t.id, layout: l) }
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
        guard ensureManageable() else { return }
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
        guard ensureManageable() else { return }
        guard let p = project(id) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(p.name)” from Octomux?"
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
        ThemeStore.shared.sync(from: self)   // the workspace may have its own scene
        updateAmbientMood()
        ThemeStore.shared.writeTerminalTheme()
        TerminalHost.shared.refreshPaneBackgrounds()
    }

    /// The top bar's +N −M button: shows the right panel on Changes, or hides it when it already shows Changes.
    func toggleChangesPanel() {
        let onChanges = UserDefaults.standard.string(forKey: "octomux.rightTab") == "Changes"
        if rightPanelVisible && onChanges {
            setRightPanel(false)
        } else {
            UserDefaults.standard.set("Changes", forKey: "octomux.rightTab")
            setRightPanel(true)
        }
    }

    /// Shows or hides the right panel, sliding like the sidebar.
    func setRightPanel(_ on: Bool) {
        guard on != rightPanelVisible else { return }
        withAnimation(.easeOut(duration: 0.18)) { rightPanelVisible = on }
    }
    func toggleRightPanel() { setRightPanel(!rightPanelVisible) }

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

    /// "Always show" profile ids of a scope ("global" or "workspace:<id>"); nil when the scope has no list
    /// of its own (a workspace then uses the global one; an empty list means "none" there).
    func alwaysShowList(scope: String) -> [String]? {
        guard case .array(let a)? = settingValue("usage.always_show", scope: scope) else { return nil }
        return a.compactMap { $0.string }
    }

    /// The list in effect: the current workspace's own, else the global one.
    var effectiveAlwaysShow: [String] {
        selectedWorkspaceId.flatMap { alwaysShowList(scope: "workspace:\($0)") } ?? alwaysShowList(scope: "global") ?? []
    }

    var workspaceOverridesAlwaysShow: Bool { selectedWorkspaceId.flatMap { alwaysShowList(scope: "workspace:\($0)") } != nil }

    func usageAlwaysShown(_ profileId: String) -> Bool { effectiveAlwaysShow.contains(profileId) }

    /// Changes the list the current workspace uses: its own when it has one (or `scope` says so), else global.
    func setUsageAlwaysShown(_ profileId: String, _ on: Bool, scope: String? = nil) {
        let target = scope ?? (workspaceOverridesAlwaysShow ? "workspace:\(selectedWorkspaceId ?? "")" : "global")
        var ids = alwaysShowList(scope: target) ?? (target == "global" ? [] : alwaysShowList(scope: "global") ?? [])
        ids.removeAll { $0 == profileId }
        if on { ids.append(profileId) }
        // A workspace keeps its (even empty) list; the global one is cleared when empty.
        setSetting("usage.always_show", target == "global" && ids.isEmpty ? nil : ids, scope: target)
    }

    /// Gives the current workspace its own copy of the global list, or drops it (back to global).
    func setWorkspaceAlwaysShowOverride(_ on: Bool) {
        guard let ws = selectedWorkspaceId else { return }
        setSetting("usage.always_show", on ? (alwaysShowList(scope: "global") ?? []) : nil, scope: "workspace:\(ws)")
    }

    /// Profiles whose limits the status bar shows, with their readings.
    /// Profiles the status bar shows usage for: the focused agent's, then the "always show" ones.
    var usageProfileIds: [String] {
        var ids: [String] = []
        if let s = session(focusedSessionId), s.kind == .agent, let pid = s.profileId { ids.append(pid) }
        for p in enabledProfiles where usageAlwaysShown(p.id) && !ids.contains(p.id) { ids.append(p.id) }
        return ids
    }

    /// Asks the daemons to refresh usage for exactly those profiles: once a minute, and right away when
    /// the set changes (another agent got focus). Nothing else is polled.
    func startUsageRefresh() {
        var last: [String] = []
        var at = Date.distantPast
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive || NSApp.windows.contains(where: { $0.isVisible }) else { return }
            let ids = self.usageProfileIds
            guard !ids.isEmpty, ids != last || Date().timeIntervalSince(at) >= 60 else { return }
            last = ids
            at = Date()
            var byClient: [ObjectIdentifier: (DaemonClient, [String])] = [:]
            for id in ids {
                let c = self.client(for: id)
                byClient[ObjectIdentifier(c), default: (c, [])].1.append(id)
            }
            for (c, ids) in byClient.values { c.call("usage.refresh", ["profile_ids": ids]) }
        }
    }

    func usageProfilesShown() -> [(Profile, [UsageReading])] {
        usageProfileIds.compactMap { id in
            guard let p = profile(id) else { return nil }
            let r = usage(of: id).filter { $0.window == "five_hour" || $0.window == "seven_day" || $0.window == "spend_limit" }
            return r.isEmpty ? nil : (p, Array(r.prefix(2)))
        }
    }
}

extension AppModel {
    /// Opening, closing, stopping or moving tabs needs the daemon (open terminals don't: they talk to their
    /// sessions directly). Disconnected or stopped: those controls are disabled and shortcuts say why.
    var canManage: Bool { connected && power == .running }

    @discardableResult
    func ensureManageable() -> Bool {
        if canManage { return true }
        NSSound.beep()
        lastError = power == .running
            ? "Can't reach the Octomux daemon right now. Open terminals still work; try again once it's back."
            : "Octomux is stopped. Start it to open or change tabs."
        return false
    }

    /// Stops every session's program and the daemon (Settings → Stop Octomux). Tabs come back on Start.
    func stopOctomux() {
        guard power == .running, !host.isRemote else { return }
        power = .stopping
        DaemonClient.held = true
        // The terminals' text falls out first (snapshot taken now), then the stopped screen.
        stopFalling = true
        StopAnimation.run(window: (NSApp.delegate as? AppDelegate)?.mainWindow, area: TerminalHost.shared.container) { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.stopFalling = false }
        }
        TerminalHost.shared.dropSurfaces()
        client.call("daemon.stop_all") { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure = r, LineSocket(path: Paths.daemonSocket.path) != nil {
                    // The daemon is still there (an old one without stop_all): give the window back.
                    DaemonClient.held = false
                    self.power = .running
                    self.report(r)
                    TerminalHost.shared.render(force: true)
                    return
                }
                self.stoppedAt = Date()
                self.connected = false
                self.power = .stopped
            }
        }
    }

    /// Starts the daemon again; it restores the tabs that were open (agents resume their conversations).
    func startOctomux() {
        guard power == .stopped else { return }
        power = .starting
        DaemonClient.held = false
        DispatchQueue.global().async {
            let ok = DaemonClient.ensureDaemon()
            DispatchQueue.main.async {
                if !ok, self.power == .starting {
                    self.power = .stopped
                    self.lastError = "Octomux didn't start. The daemon log may say why (Open Logs)."
                }
            }
        }
    }
}

