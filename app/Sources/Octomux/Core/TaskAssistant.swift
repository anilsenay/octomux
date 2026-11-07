import Foundation

/// The workspace assistant and Autopilot.
///
/// The assistant is a normal agent session (your own Claude or Codex, nothing on an API key) started in the
/// project with its editing tools off and planner instructions: it turns what you ask into tasks with the Octomux
/// MCP tools, asks Octomux to start agents on them, and follows the agents of the tasks it started (and only those).
///
/// Autopilot is what it may do without asking, per workspace:
/// - Off: it adds planned tasks; starting one waits for you; no updates are sent to it (no tokens spent).
/// - Start: it may start agents (at most `maxAgents` at once) and message its own tasks' agents; Octomux tells it
///   when one of them finishes or waits for you.
/// - Start + PR: also commits, pushes and opens a draft pull request for a task whose agent finished.
/// Never, at any level: answering an agent's permission prompt or question, merging, deleting a worktree, writing to
/// Jira or GitHub issues. Everything it does lands in the activity log ("while you were away").
enum Autopilot: String, CaseIterable, Identifiable {
    case off, start, pr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .start: return "Start agents"
        case .pr: return "Start + draft PRs"
        }
    }
    var desc: String {
        switch self {
        case .off: return "The assistant plans; you start each task."
        case .start: return "The assistant starts agents on its tasks and follows them."
        case .pr: return "Also commits, pushes and opens a draft pull request when a task's agent finishes."
        }
    }
    /// Updates the assistant gets per task, at most (so two agents can't keep each other going).
    static let maxTurns = 5
    static let defaultMaxAgents = 3
}

enum TaskAssistant {
    static let instructions = """
    You are the planner of this Octomux workspace. You never edit code yourself: your editing tools are off. \
    Turn what the user asks into tasks with the Octomux tools: task_create (one task per piece of work that can be \
    done on its own branch; use parent_id for the steps of a bigger one), task_list to see them, task_start to ask \
    Octomux to start an agent on a planned task (the user's Autopilot setting decides whether it starts right away), \
    session_summary and session_send for the agents of tasks you started. Describe each task so an agent can do it \
    alone: what to change, where, and how to check it. Messages that start with [Octomux] are updates about your \
    tasks; answer them briefly and only act when something is needed.
    """

    /// Extra arguments that make an agent the assistant (editing off, the instructions on).
    static func args(for kind: AgentKind) -> [String] {
        switch kind {
        case .claude: return ["--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit", "--append-system-prompt", instructions]
        case .codex: return ["--sandbox", "read-only"]
        default: return []
        }
    }

    /// The first message, for agents that take no instructions on the command line.
    static func firstMessage(for kind: AgentKind) -> String? {
        kind == .claude ? nil : instructions + "\n\nWait for the user to say what needs doing."
    }

    /// The update an assistant gets about its task, or nil when there is nothing to say.
    static func update(_ t: WorkTask, from old: Activity, to new: Activity) -> String? {
        guard old != new else { return nil }
        switch new {
        case .done: return "[Octomux] Task “\(t.title)” (\(t.id)): its agent finished\(t.branch.map { " on branch \($0)" } ?? ""). Check it with session_summary if needed."
        case .needsInput: return "[Octomux] Task “\(t.title)” (\(t.id)): its agent is waiting for the user's answer. Don't answer for them."
        case .error: return "[Octomux] Task “\(t.title)” (\(t.id)): its agent stopped on an error."
        default: return nil
        }
    }

    /// The update to send the assistant, if any: nothing with Autopilot off, nothing past the task's turns.
    static func notify(_ t: WorkTask, from old: Activity, to new: Activity, level: Autopilot) -> String? {
        guard level != .off, t.turns < Autopilot.maxTurns else { return nil }
        return update(t, from: old, to: new)
    }

    /// Whether a requested start may go ahead without you.
    static func mayStart(level: Autopilot, byAssistant: Bool, running: Int, maxAgents: Int) -> Bool {
        byAssistant && level != .off && running < maxAgents
    }
}

extension AppModel {
    private func wsScope(_ ws: String?) -> String? { ws.map { "workspace:\($0)" } }

    func autopilot(workspace ws: String?) -> Autopilot {
        guard let sc = wsScope(ws), case .string(let v)? = settingValue("tasks.autopilot", scope: sc) else { return .off }
        return Autopilot(rawValue: v) ?? .off
    }
    func setAutopilot(_ a: Autopilot, workspace ws: String?) {
        guard let sc = wsScope(ws) else { return }
        setSettingLocally("tasks.autopilot", .string(a.rawValue), scope: sc)
        setSetting("tasks.autopilot", a.rawValue, scope: sc)
    }
    func maxTaskAgents(workspace ws: String?) -> Int {
        guard let sc = wsScope(ws), case .number(let n)? = settingValue("tasks.max_agents", scope: sc) else { return Autopilot.defaultMaxAgents }
        return max(1, Int(n))
    }

    /// The workspace's assistant session (while it exists).
    func assistantSession(workspace ws: String?) -> Session? {
        guard let sc = wsScope(ws), case .string(let id)? = settingValue("tasks.assistant_session", scope: sc) else { return nil }
        return session(id)
    }
    func isAssistant(_ sessionId: String) -> Bool {
        guard let s = session(sessionId), let ws = project(s.projectId)?.workspaceId else { return false }
        return assistantSession(workspace: ws)?.id == sessionId
    }

    /// Opens the workspace's assistant, starting it (in the current project, as a chat) when there is none.
    func openAssistant(projectId: String? = nil) {
        let ws = project(projectId ?? "")?.workspaceId ?? selectedWorkspaceId
        if let s = assistantSession(workspace: ws) {
            if s.isDormant { restart(s.id) }
            selectSession(s.id)
            return
        }
        guard let p = project(projectId ?? currentProject?.id ?? ""), let prof = defaultAgentProfileId(projectId: p.id), let kind = profile(prof)?.kind else {
            lastError = "Add a project and a Claude or Codex agent first."
            return
        }
        newSession(profileId: prof, projectId: p.id, title: "Assistant", prompt: TaskAssistant.firstMessage(for: kind), chat: true,
                   extraArgs: TaskAssistant.args(for: kind)) { [weak self] sid in
            guard let self, let sc = self.wsScope(p.workspaceId) else { return }
            self.rename(sid, to: "Assistant")   // stays "Assistant" whatever the agent calls its conversation
            self.setSettingLocally("tasks.assistant_session", .string(sid), scope: sc)
            self.setSetting("tasks.assistant_session", sid, scope: sc)
        }
    }

    /// Tasks an agent made over MCP: the assistant's become its own (it may follow them).
    func claimAssistantTasks() {
        for t in state.tasks where t.assistantSession == nil && t.createdBy.hasPrefix("agent:") {
            let sid = String(t.createdBy.dropFirst("agent:".count))
            guard isAssistant(sid), TaskSyncMemo.sent[t.id + "#claim"] == nil else { continue }
            TaskSyncMemo.sent[t.id + "#claim"] = sid
            updateTask(t.id, ["assistant_session": sid, "created_by": "assistant"])
        }
    }
}

/// Acts on start requests and agent changes for the assistants' tasks.
final class TaskAutopilot: ObservableObject {
    static let shared = TaskAutopilot()
    /// Tasks someone asked to start that wait for you (task id → who asked).
    @Published private(set) var requested: [String: String] = [:]
    /// Tasks whose draft pull request is being made.
    @Published private(set) var opening: Set<String> = []

    /// `task.start_requested` from the daemon.
    func startRequested(_ data: [String: Any], model: AppModel = .shared) {
        guard let id = data["task_id"] as? String, let t = model.task(id), t.state == .planned else { return }
        let caller = data["caller_session"] as? String ?? ""
        let ws = model.project(t.projectId)?.workspaceId
        let level = model.autopilot(workspace: ws)
        let byAssistant = model.isAssistant(caller)
        let running = model.workspaceTasksRunning(ws)
        if TaskAssistant.mayStart(level: level, byAssistant: byAssistant, running: running, maxAgents: model.maxTaskAgents(workspace: ws)) {
            if t.assistantSession == nil, byAssistant { model.updateTask(t.id, ["assistant_session": caller]) }
            model.startTask(t, select: false)
            ActivityLog.shared.record(.autopilot, "Autopilot started “\(t.title)”", detail: model.project(t.projectId)?.name ?? "")
        } else {
            requested[id] = caller
            let who = byAssistant ? "The assistant" : model.session(caller)?.displayTitle ?? "An agent"
            ActivityLog.shared.record(.autopilot, "\(who) asks to start “\(t.title)”",
                                      detail: level == .off ? "Autopilot is off" : byAssistant ? "\(running) agents already running" : "Only the assistant starts tasks by itself")
        }
    }

    func clearRequest(_ id: String) { requested[id] = nil }

    /// Sessions that changed between two states: updates to the owning assistant, draft PRs at the PR level.
    func observe(old: [Session], new: [Session], model: AppModel = .shared) {
        guard !old.isEmpty else { return }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in new {
            guard let o = before[s.id], o.activity != s.activity, let t = model.task(forSession: s.id),
                  let a = t.assistantSession, let assistant = model.session(a), !assistant.isDormant else { continue }
            let level = model.autopilot(workspace: model.project(t.projectId)?.workspaceId)
            guard level != .off else { continue }
            if let text = TaskAssistant.notify(t, from: o.activity, to: s.activity, level: level) {
                model.updateTask(t.id, ["turns": t.turns + 1])
                model.sendToSession(a, text: text, submit: true)
            }
            if level == .pr, s.activity == .done, t.prUrl == nil, let path = s.worktree ?? t.worktree { openDraftPR(t, path: path, model: model) }
        }
    }

    /// Commits what the agent left, pushes the branch and opens a draft pull request (never merges).
    func openDraftPR(_ t: WorkTask, path: String, model: AppModel) {
        guard !opening.contains(t.id) else { return }
        opening.insert(t.id)
        DispatchQueue.global(qos: .utility).async {
            let dirty = !(GitInfo.git(["status", "--porcelain"], in: path) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if dirty {
                _ = GitInfo.git(["add", "-A"], in: path)
                _ = GitInfo.git(["commit", "-m", t.title], in: path)
            }
            let base = PullRequest.defaultBase(path)
            let ahead = Int(GitInfo.git(["rev-list", "--count", "\(base)..HEAD"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            DispatchQueue.main.async {
                guard ahead > 0 else { self.opening.remove(t.id); return }
                let body = (t.description.isEmpty ? "" : t.description + "\n\n") + "Opened by Octomux Autopilot for task \(t.id)."
                PullRequest.create(path: path, local: !model.host(forPath: path).0.isRemote, base: base, title: t.title, body: body, draft: true) { r in
                    self.opening.remove(t.id)
                    switch r {
                    case .success(let url) where url.absoluteString.contains("/pull/"):
                        model.updateTask(t.id, ["pr_url": url.absoluteString])
                        ActivityLog.shared.record(.autopilot, "Autopilot opened a draft pull request for “\(t.title)”", detail: url.absoluteString)
                    case .success:
                        ActivityLog.shared.record(.autopilot, "Autopilot pushed “\(t.title)”; open its pull request yourself", detail: "gh couldn't create it")
                    case .failure(let e):
                        ActivityLog.shared.record(.autopilot, "Autopilot couldn't open a pull request for “\(t.title)”", detail: "\(e)")
                    }
                }
            }
        }
    }
}

extension AppModel {
    /// Agents of a workspace's tasks that are running now.
    func workspaceTasksRunning(_ ws: String?) -> Int {
        let ps = Set(state.projects.filter { $0.workspaceId == ws }.map(\.id))
        let ids = Set(state.tasks.filter { ps.contains($0.projectId) }.flatMap(\.sessions))
        return state.sessions.filter { ids.contains($0.id) && !$0.isDormant && $0.activity == .working }.count
    }
}
