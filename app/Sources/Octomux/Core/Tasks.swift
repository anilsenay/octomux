import Foundation

/// Octomux's own work items: a thin record tying a title to its project, worktree, agent sessions, state and pull
/// request. Kept by the daemon (`task.*`, `octomux task`, the MCP task tools); the app derives the automatic states
/// from the sessions and the Inbox, and starts the agents.
enum TaskState: String, Codable, CaseIterable {
    case planned, working, needsYou = "needs_you", readyToReview = "ready_to_review", inReview = "in_review", done

    var title: String {
        switch self {
        case .planned: return "Planned"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .readyToReview: return "Ready to review"
        case .inReview: return "In review"
        case .done: return "Done"
        }
    }
    /// The order the Tasks panel lists them in: what needs you first.
    static let shown: [TaskState] = [.needsYou, .readyToReview, .working, .inReview, .planned, .done]
}

struct WorkTask: Codable, Identifiable, Equatable {
    var id: String
    var projectId: String
    var title: String
    var description = ""
    var parentId: String?
    var worktree: String?
    var branch: String?
    var sessions: [String] = []
    var state: TaskState
    var stateManual = false
    var prUrl: String?
    var source: String?
    var agentProfile: String?
    var createdBy = "user"
    var assistantSession: String?
    var turns = 0
    var createdAt = 0
    var updatedAt = 0

    enum CodingKeys: String, CodingKey {
        case id, title, description, worktree, branch, sessions, state, source, turns
        case projectId = "project_id", parentId = "parent_id", stateManual = "state_manual", prUrl = "pr_url"
        case agentProfile = "agent_profile", createdBy = "created_by", assistantSession = "assistant_session"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.decode(String.self, forKey: .projectId)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        sessions = try c.decodeIfPresent([String].self, forKey: .sessions) ?? []
        state = (try? c.decode(TaskState.self, forKey: .state)) ?? .planned
        stateManual = try c.decodeIfPresent(Bool.self, forKey: .stateManual) ?? false
        prUrl = try c.decodeIfPresent(String.self, forKey: .prUrl)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        agentProfile = try c.decodeIfPresent(String.self, forKey: .agentProfile)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? "user"
        assistantSession = try c.decodeIfPresent(String.self, forKey: .assistantSession)
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
    }

    init(id: String, projectId: String, title: String, state: TaskState = .planned) {
        self.id = id; self.projectId = projectId; self.title = title; self.state = state
    }

    /// "jira:SHOP-12" → "SHOP-12", "gh:o/r#12" → "#12" (the chip on its sessions).
    var sourceKey: String? {
        guard let s = source, s != "manual" else { return nil }
        if let i = s.lastIndex(of: "#") { return String(s[i...]) }
        if let i = s.firstIndex(of: ":") { return String(s[s.index(after: i)...]) }
        return s
    }
}

enum TaskRules {
    /// The state a task is in by its sessions and pull request; a state you set by hand stays.
    static func derive(_ t: WorkTask, sessions: [Session], pr: InboxItem?) -> TaskState {
        if t.stateManual { return t.state }
        if let pr, let e = pr.ended { return e.merged ? .done : .readyToReview }
        if t.prUrl != nil { return .inReview }
        let mine = sessions.filter { t.sessions.contains($0.id) }
        guard !mine.isEmpty else { return t.sessions.isEmpty ? t.state : .readyToReview }
        let live = mine.filter { !$0.isDormant }
        if live.contains(where: { $0.activity == .needsInput || $0.activity == .error }) { return .needsYou }
        if live.contains(where: { $0.activity == .working }) { return .working }
        return .readyToReview
    }

    /// A branch name from a title: "Fix the cart total!" → "task/fix-the-cart-total".
    static func branch(_ title: String, id: String) -> String {
        let ascii = title.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? title
        let clean = String(ascii.lowercased().map { c -> Character in c.isASCII && (c.isLetter || c.isNumber) ? c : " " })
        let slug = clean.split(separator: " ").prefix(6).joined(separator: "-")
        return "task/" + (slug.isEmpty ? id : slug)
    }

    /// What the agent is asked when a task starts.
    static func prompt(_ t: WorkTask) -> String {
        var s = t.title
        if !t.description.isEmpty { s += "\n\n" + t.description }
        return s
    }

    /// Tasks of a workspace's projects, by state then newest first; subtasks right after their parent.
    static func ordered(_ tasks: [WorkTask]) -> [WorkTask] {
        let ids = Set(tasks.map(\.id))
        let top = tasks.filter { t in t.parentId.map { !ids.contains($0) } ?? true }
            .sorted { a, b in
                let ia = TaskState.shown.firstIndex(of: a.state) ?? 9, ib = TaskState.shown.firstIndex(of: b.state) ?? 9
                return ia != ib ? ia < ib : a.createdAt > b.createdAt
            }
        var out: [WorkTask] = []
        for t in top {
            out.append(t)
            out += tasks.filter { $0.parentId == t.id }.sorted { $0.createdAt < $1.createdAt }
        }
        return out
    }
}

extension AppModel {
    var tasks: [WorkTask] { state.tasks }
    func task(_ id: String?) -> WorkTask? { state.tasks.first { $0.id == id } }

    /// Tasks of the current workspace's projects.
    var workspaceTasks: [WorkTask] {
        let ps = Set(projects.map(\.id))
        return state.tasks.filter { ps.contains($0.projectId) }
    }

    /// The task a session works on.
    func task(forSession id: String) -> WorkTask? { state.tasks.first { $0.sessions.contains(id) } }

    func createTask(projectId: String, title: String, description: String = "", source: String? = nil, parent: String? = nil, done: ((String) -> Void)? = nil) {
        var p: [String: Any] = ["project_id": projectId, "title": title, "description": description]
        if let source { p["source"] = source }
        if let parent { p["parent_id"] = parent }
        client.call("task.create", p) { [weak self] r in
            switch r {
            case .success(let v): if let id = (v as? [String: Any])?["id"] as? String { DispatchQueue.main.async { done?(id) } }
            case .failure(let e): DispatchQueue.main.async { self?.lastError = "Could not add the task: \(e)" }
            }
        }
    }

    func updateTask(_ id: String, _ patch: [String: Any]) {
        var p = patch
        p["id"] = id
        client.call("task.update", p, completion: report)
    }

    func deleteTask(_ id: String) { client.call("task.delete", ["id": id], completion: report) }

    /// You set the state by hand (planned or done); anything else goes back to following the sessions.
    func setTaskState(_ id: String, _ s: TaskState?) {
        if let s { updateTask(id, ["state": s.rawValue, "state_manual": true]) } else { updateTask(id, ["state_manual": false]) }
    }

    /// The agent a new task, chat or review starts with when none is picked: the workspace's chat default, the
    /// global default (Settings → Agents), the last chat agent, else the first Claude or Codex.
    func defaultAgentProfileId(projectId: String?) -> String? {
        let ws = project(projectId ?? "")?.workspaceId ?? selectedWorkspaceId
        if let ws, case .string(let id)? = settingValue("chat.default_profile", scope: "workspace:\(ws)"), profile(id) != nil { return id }
        if case .string(let id)? = settingValue("agents.default_profile", scope: "global"), profile(id) != nil { return id }
        if let id = UserDefaults.standard.string(forKey: "octomux.chatProfile"), profile(id) != nil { return id }
        return enabledProfiles.first(where: { $0.kind == .claude || $0.kind == .codex })?.id
    }

    /// Starts a planned task: its own worktree on a new branch, an agent there with the task as its first message.
    func startTask(_ t: WorkTask, profileId: String? = nil, select: Bool = true) {
        guard let p = project(t.projectId) else { lastError = "The task's project is gone."; return }
        guard let prof = profileId ?? t.agentProfile.flatMap({ profile($0)?.id }) ?? defaultAgentProfileId(projectId: p.id) else {
            lastError = "No agent to start: add one in Settings → Agents."
            return
        }
        let branch = t.branch ?? TaskRules.branch(t.title, id: t.id)
        updateTask(t.id, ["state": TaskState.working.rawValue, "state_manual": false, "branch": branch])
        newWorktree(project: p, branch: branch, open: prof, prompt: TaskRules.prompt(t), select: select) { [weak self] sid in
            guard let self else { return }
            self.client.call("task.add_session", ["id": t.id, "session_id": sid], completion: self.report)
            ActivityLog.shared.record(.task, "Started “\(t.title)”", detail: p.name, session: sid)
        }
    }

    /// Keeps the tasks' automatic states in step with their sessions and pull requests (writes only real changes),
    /// and fills a task's worktree once its session has one.
    func syncTasks() {
        guard !host.isRemote else { return }
        let items = InboxStore.shared.items
        for t in state.tasks {
            var patch: [String: Any] = [:]
            let pr = t.prUrl.flatMap { u in items.first { $0.url == u } }
            let s = TaskRules.derive(t, sessions: state.sessions, pr: pr)
            if s != t.state { patch["state"] = s.rawValue }
            if t.worktree == nil, let wt = t.sessions.lazy.compactMap({ self.session($0)?.worktree }).first { patch["worktree"] = wt }
            guard !patch.isEmpty else { continue }
            let key = t.id + (patch["state"] as? String ?? "") + (patch["worktree"] as? String ?? "")
            guard TaskSyncMemo.sent[t.id] != key else { continue }
            TaskSyncMemo.sent[t.id] = key
            updateTask(t.id, patch)
        }
    }
}

enum TaskSyncMemo { nonisolated(unsafe) static var sent: [String: String] = [:] }
